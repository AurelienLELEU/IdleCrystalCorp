#ifndef IDLE_STORE_IOS_H
#define IDLE_STORE_IOS_H

// Pont vers l'implémentation iOS (Swift).
//
// Chaque fonction existe sur toutes les plateformes cibles. Sur une plateforme
// sans StoreKit, elles ne font rien et renvoient 0 / false : le jeu bascule
// alors sur sa boutique simulée, ce qui garde le mode mock par défaut sur
// ordinateur.

#ifdef __cplusplus
extern "C" {
#endif

/// Démarre l'écoute des transactions et charge le catalogue. Les identifiants
/// arrivent en une seule chaîne séparée par des virgules — c'est le seul
/// format qu'un `const char *` traîne sans allocation ni ambiguïté d'encodage.
int idle_store_ios_start(const char *p_product_ids_csv);

void idle_store_ios_purchase(const char *p_product_id);
void idle_store_ios_restore(void);
int idle_store_ios_is_purchased(const char *p_product_id);

/// Prix localisé d'un produit au format StoreKit (« 3,99 € »), dans un tampon
/// interne à l'appelant : à copier avant l'appel suivant. Vide si le produit
/// est inconnu. Le jeu affiche CE prix, jamais celui du JSON.
const char *idle_store_ios_price(const char *p_product_id);

// --- Rappels Swift -> C++ --------------------------------------------------
//
// Il n'y a ici AUCUNE passerelle directe : Swift n'appelle pas ces fonctions
// via @_cdecl, mais via @_silgen_name sur les quatre `idle_store_bridge_*`
// définies dans idle_store.cpp. Deux frontiers, deux mécanismes, et c'est
// volontaire : @_cdecl exporte une fonction Swift vers C, alors que
// @_silgen_name déclare un symbole C que Swift appelle. Les confondre est
// l'erreur classique du portage StoreKit vers une GDExtension.

#ifdef __cplusplus
}
#endif

#endif // IDLE_STORE_IOS_H
