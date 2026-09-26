#ifndef IDLE_STORE_H
#define IDLE_STORE_H

// Couche native « IdleStore » — achats intégrés StoreKit 2 sur iOS.
//
// CONTRACT AVEC core_engine/StoreService.gd (ne pas modifier l'un sans l'autre) :
//
//   Objet exposé :  class_name IdleStore
//   Méthodes appelées par le jeu :
//       is_configured() -> bool
//       start() -> void                    // charge le catalogue
//       purchase(product_id: String) -> void
//       restore() -> void
//       is_purchased(product_id: String) -> bool
//   Signaux émis vers le jeu :
//       products_loaded(count: int)
//       purchase_completed(product_id: String)
//       purchase_failed(product_id: String, reason: String)
//       purchase_restored(count: int)
//
// StoreKit 2 est une API **Swift uniquement** : il n'existe aucun équivalent
// en Objective-C. C'est pourquoi ce module est en Swift, avec des exports
// `@_cdecl` pour la frontière C, là où le module AdMob est en Objective-C++.
// Un seul des deux a besoin de Swift, pas les deux.
//
// RÉFLEXIONNEZ AVANT LE PREMIER ACHAT — la règle que les jeux autonomes
// enfreignent le plus souvent :
//
//   Le prix affiché doit venir de StoreKit, jamais du JSON de configuration.
//   Un prix codé en dur est soit faux dans 150 devises, soit — cas le plus
//   fréquent — la cause d'un refus de la revue, parce que l'écran de
//   confirmation ne correspond pas au prix réellement payé.

#include <godot_cpp/classes/object.hpp>

namespace godot {

class IdleStore : public Object {
	GDCLASS(IdleStore, Object)

	bool configured = false;

protected:
	static void _bind_methods();

public:
	IdleStore();

	bool is_configured() const;
	void set_configured(bool p_value) { configured = p_value; }

	void start(const String &p_product_ids_csv);
	void purchase(const String &p_product_id);
	void restore();
	bool is_purchased(const String &p_product_id);

	/// Prix localisé renvoyé par StoreKit (« 3,99 € »), dans la devise de la
	/// région. Vide tant que le catalogue n'est pas chargé.
	String get_price(const String &p_product_id);
};

} // namespace godot

#endif // IDLE_STORE_H
