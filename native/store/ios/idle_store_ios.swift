// Implémentation iOS de la couche IdleStore — StoreKit 2.
//
// Swift obligatoire : StoreKit 2 n'a pas d'équivalent Objective-C. Les exports
// `@_cdecl` en bas du fichier forment la frontière C que le C++ appelle, et les
// rappels de StoreKit rentrent par `@_silgen_name`.
//
// Quatre points où un jeu autonome se trompe régulièrement, traités
// explicitement ci-dessous :
//
//  1. VÉRIFICATION DE LA TRANSACTION. `Transaction` expose `verificationResult`.
//     On refuse tout ce qui n'est pas `.verified`. Sans ce contrôle, un reçu
//     forgé sur un appareil compromis accorde un entitlement gratuit.
//
//  2. ACHAT EN ATTENTE. `PurchaseResult.pending` signifie que le joueur a payé
//     mais que l'App Store attend encore (contrôle parental, compte en cours de
//     validation). Ce n'est PAS un échec : on ne crédite rien maintenant, et
//     `Transaction.updates` le fera plus tard. Traiter `pending` comme un échec
//     fait perdre l'argent du joueur.
//
//  3. ANNULATION PAR LE JOUEUR. `PurchaseResult.userCancelled` n'est ni une
//     erreur ni un incident à journaliser. Message neutre, jamais un « échec »
//     en rouge qui donne l'impression d'un bug.
//
//  4. PRIX. Le prix affiché vient TOUJOURS de StoreKit, jamais du JSON. Un prix
//     codé en dur est soit faux dans 150 devises, soit la cause d'un refus de
//     la revue parce que l'écran de confirmation ne correspond pas au prix payé.

import Foundation
import StoreKit

// --- État -----------------------------------------------------------------

private var s_entitlements: Set<String> = []
private var s_prices: [String: String] = [:]
private var s_started = false
/// Tampon de retour pour idle_store_ios_price : strdup() fuirait à chaque appel,
/// et l'interface ne lit le prix qu'une fois par ouverture de la boutique.
private var s_price_buffer = [CChar](repeating: 0, count: 512)

// --- Traduction des erreurs ----------------------------------------------

private func describe(_ error: Error) -> String {
    let ns = error as NSError
    if ns.domain == SKError.errorDomain, let code = SKError.Code(rawValue: ns.code) {
        switch code {
        case .paymentNotAllowed:
            return "paiement refusé : moyen de paiement non autorisé"
        case .paymentInvalid:
            return "paiement invalide"
        case .storeProductNotAvailable:
            // SKError.Code n'a AUCUN cas « failed to load products ». Le nom
            // `storeKitErrorFailedLoadProducts` existe bien, mais c'est
            // l'ancienne constante Objective-C (SKErrorStoreKitError...),
            // pas un cas Swift : le compilateur le refuse. La liste réelle
            // a été relevée cas par cas sur le SDK iOS 27, en faisant compiler
            // un fichier de sondes — l'en-tête Objective-C, lui, ne liste que
            // 22 cas sur les 16 réellement exposés en Swift 2.
            return "produit indisponible : vérifiez que les identifiants existent dans App Store Connect, qu'ils sont rattachés au bon groupe de prix et que l'accord de vente est actif"
        case .invalidOfferIdentifier:
            return "identifiant d'offre invalide : l'identifiant du produit ne correspond à rien dans App Store Connect"
        case .unknown:
            return "erreur inconnue du magasin — c'est le cas le plus fréquent quand un product_id est mal orthographié dans game_config.json"
        default:
            return "erreur App Store \(code.rawValue) : \(ns.localizedDescription)"
        }
    }
    return ns.localizedDescription
}

private func copy(_ text: String) -> UnsafePointer<CChar>? {
    let bytes = Array(text.utf8CString)
    guard bytes.count <= s_price_buffer.count else { return nil }
    s_price_buffer.replaceSubrange(0 ..< bytes.count, with: bytes)
    return s_price_buffer.withUnsafeBufferPointer { $0.baseAddress }
}

// --- Écoute des transactions ---------------------------------------------
//
// Doit vivre aussi longtemps que l'application : c'est elle qui rattrape les
// achats « pending » et les transactions reçues hors ligne. Une tâche annulée
// au retour au premier plan fait perdre des achats.

private func startTransactionListener() {
    Task.detached(priority: .utility) {
        for await result in Transaction.updates {
            guard let transaction = try? verified(result) else { continue }
            await transaction.finish()
            await MainActor.run {
                s_entitlements.insert(transaction.productID)
                bridge_purchase_completed(transaction.productID)
            }
        }
    }
}

/// Rejette tout ce qui n'est pas vérifié. Voir point 1 de l'en-tête.
private func verified<T>(_ result: VerificationResult<T>) throws -> T {
    switch result {
    case .verified(let safe):
        return safe
    case .unverified(_, let error):
        throw error
    }
}

// --- API appelée par le C++ ----------------------------------------------

@_cdecl("idle_store_ios_start")
public func idle_store_ios_start(_ p_product_ids_csv: UnsafePointer<CChar>?) -> Int32 {
    if s_started { return 1 }
    s_started = true
    startTransactionListener()

    let ids = (p_product_ids_csv.map { String(cString: $0) } ?? "")
        .split(separator: ",")
        .map { $0.trimmingCharacters(in: .whitespaces) }
        .filter { !$0.isEmpty }

    guard !ids.isEmpty else {
        bridge_purchase_failed("", "aucun identifiant de produit fourni")
        return 0
    }

    // Chargement asynchrone : le jeu reçoit le compte exact par
    // idle_store_bridge_products_loaded, et les prix par la suite.
    Task {
        do {
            let products = try await Product.products(for: ids)
            for product in products {
                // displayPrice respecte la devise et le formatage de la région :
                // c'est cette chaîne qu'il faut afficher, pas un prix codé en dur.
                s_prices[product.id] = product.displayPrice
            }
            bridge_products_loaded(products.count)
        } catch {
            bridge_purchase_failed("", describe(error))
        }
    }
    return 1
}

@_cdecl("idle_store_ios_purchase")
public func idle_store_ios_purchase(_ p_product_id: UnsafePointer<CChar>?) {
    guard let p_product_id else { return }
    let productID = String(cString: p_product_id)

    Task { @MainActor in
        do {
            let products = try await Product.products(for: [productID])
            guard let product = products.first else {
                bridge_purchase_failed(
                    productID,
                    "produit introuvable : vérifiez l'identifiant dans App Store Connect"
                )
                return
            }

            switch try await product.purchase() {
            case .success(let result):
                let transaction = try verified(result)
                await transaction.finish()
                s_entitlements.insert(transaction.productID)
                bridge_purchase_completed(transaction.productID)

            case .pending:
                // Payé, l'App Store attend. On ne crédite rien maintenant ;
                // `Transaction.updates` s'en chargera. Voir point 2.
                bridge_purchase_failed(
                    productID,
                    "paiement en attente de validation par l'App Store"
                )

            case .userCancelled:
                // Choix du joueur, pas une erreur. Voir point 3.
                bridge_purchase_failed(productID, "achat annulé")

            @unknown default:
                bridge_purchase_failed(productID, "résultat d'achat inconnu")
            }
        } catch {
            bridge_purchase_failed(productID, describe(error))
        }
    }
}

@_cdecl("idle_store_ios_restore")
public func idle_store_ios_restore() {
    Task {
        do {
            // sync() interroge le serveur plutôt que de lire les transactions
            // locales : il retrouve donc aussi les achats faits sur un autre
            // appareil.
            try await AppStore.sync()
            var fresh = 0
            for await result in Transaction.currentEntitlements {
                guard let transaction = try? verified(result) else { continue }
                if !s_entitlements.contains(transaction.productID) {
                    s_entitlements.insert(transaction.productID)
                    fresh += 1
                }
            }
            bridge_restored(fresh)
        } catch {
            // -1 distingue « rien à restaurer » d'une erreur réseau.
            bridge_restored(-1)
        }
    }
}

@_cdecl("idle_store_ios_is_purchased")
public func idle_store_ios_is_purchased(_ p_product_id: UnsafePointer<CChar>?) -> Int32 {
    guard let p_product_id else { return 0 }
    return s_entitlements.contains(String(cString: p_product_id)) ? 1 : 0
}

@_cdecl("idle_store_ios_price")
public func idle_store_ios_price(_ p_product_id: UnsafePointer<CChar>?) -> UnsafePointer<CChar>? {
    guard let p_product_id else { return nil }
    return copy(s_prices[String(cString: p_product_id)] ?? "")
}

// --- Rappels Swift -> C++ -------------------------------------------------
//
// Déclarés par @_silgen_name plutôt que par un bridging header : le plug-in
// n'est pas un module Swift compilé séparément, et un bridging header
// obligerait à configurer le projet Xcode généré par Godot, qu'on ne contrôle
// pas. Les symboles sont définis dans idle_store.cpp, en `extern "C"` avec une
// signature `const char *` — Swift ne connaît pas godot::String.

// Voici les points d'entrée C des rappels Swift. Ils ne font que router vers le
// C++, qui émet le signal Godot correspondant. Le préfixe `raw_` est là pour
// les distinguer des enveloppes ci-dessous, qui gèrent la conversion String ->
// C string.

@_silgen_name("idle_store_bridge_products_loaded")
private func raw_products_loaded(_ count: Int32)

@_silgen_name("idle_store_bridge_purchase_completed")
private func raw_purchase_completed(_ productID: UnsafePointer<CChar>)

@_silgen_name("idle_store_bridge_purchase_failed")
private func raw_purchase_failed(
    _ productID: UnsafePointer<CChar>,
    _ reason: UnsafePointer<CChar>
)

@_silgen_name("idle_store_bridge_restored")
private func raw_restored(_ count: Int32)

// Enveloppes : la frontière C ne connaît que `const char *`.

private func bridge_products_loaded(_ count: Int) {
    raw_products_loaded(Int32(count))
}

private func bridge_purchase_completed(_ productID: String) {
    productID.withCString { raw_purchase_completed($0) }
}

private func bridge_purchase_failed(_ productID: String, _ reason: String) {
    reason.withCString { r in
        productID.withCString { p in
            raw_purchase_failed(p, r)
        }
    }
}

private func bridge_restored(_ count: Int) {
    raw_restored(Int32(count))
}
