#include "idle_store.h"
#include "idle_store_ios.h"

// ClassDB, D_METHOD, MethodInfo, PropertyInfo : tous définis dans class_db.hpp.
#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/core/method_bind.hpp>
using namespace godot;

namespace godot {
namespace detail {

// --- Passerelles Swift -> C++ --------------------------------------------
//
// Définitions des symboles que le Swift déclare via @_silgen_name. La
// signature est en `const char *` et non en godot::String : Swift ne connaît
// pas godot::String, et @_silgen_name n'applique aucun mangling de type.
//
// Émettre un signal Godot depuis une tâche Swift est sûr : chaque fonction Swift
// qui appelle une de ces passerelles s'exécute sur la file principale, soit
// parce qu'elle est marquée @MainActor, soit parce qu'elle attend un await
// dessus.

static IdleStore *s_store = nullptr;

static void bridge_products_loaded(int p_count) {
	if (s_store == nullptr) { return; }
	s_store->emit_signal("products_loaded", p_count);
}

static void bridge_purchase_completed(const char *p_product_id) {
	if (s_store == nullptr || p_product_id == nullptr) { return; }
	s_store->emit_signal("purchase_completed", String(p_product_id));
}

static void bridge_purchase_failed(const char *p_product_id, const char *p_reason) {
	if (s_store == nullptr) { return; }
	s_store->emit_signal("purchase_failed",
			String(p_product_id != nullptr ? p_product_id : ""),
			String(p_reason != nullptr ? p_reason : "échec inconnu"));
}

static void bridge_restored(int p_count) {
	if (s_store == nullptr) { return; }
	s_store->emit_signal("purchase_restored", p_count);
}

} // namespace detail
} // namespace godot

// Symboles exportés attendus par @_silgen_name côté Swift. « extern "C" » est
// indispensable : Swift cherche ces noms tels quels, sans mangling C++.
extern "C" {

void idle_store_bridge_products_loaded(int p_count) {
	godot::detail::bridge_products_loaded(p_count);
}

void idle_store_bridge_purchase_completed(const char *p_product_id) {
	godot::detail::bridge_purchase_completed(p_product_id);
}

void idle_store_bridge_purchase_failed(const char *p_product_id, const char *p_reason) {
	godot::detail::bridge_purchase_failed(p_product_id, p_reason);
}

void idle_store_bridge_restored(int p_count) {
	godot::detail::bridge_restored(p_count);
}
}

void IdleStore::_bind_methods() {
	ClassDB::bind_method(D_METHOD("is_configured"), &IdleStore::is_configured);
	ClassDB::bind_method(D_METHOD("start", "product_ids_csv"), &IdleStore::start);
	ClassDB::bind_method(D_METHOD("purchase", "product_id"), &IdleStore::purchase);
	ClassDB::bind_method(D_METHOD("restore"), &IdleStore::restore);
	ClassDB::bind_method(D_METHOD("is_purchased", "product_id"), &IdleStore::is_purchased);
	ClassDB::bind_method(D_METHOD("get_price", "product_id"), &IdleStore::get_price);

	ADD_SIGNAL(MethodInfo("products_loaded", PropertyInfo(Variant::INT, "count")));
	ADD_SIGNAL(MethodInfo("purchase_completed", PropertyInfo(Variant::STRING, "product_id")));
	ADD_SIGNAL(MethodInfo("purchase_failed",
			PropertyInfo(Variant::STRING, "product_id"),
			PropertyInfo(Variant::STRING, "reason")));
	ADD_SIGNAL(MethodInfo("purchase_restored", PropertyInfo(Variant::INT, "count")));
}

IdleStore::IdleStore() {
	// Enregistrement de l'instance qui recevra les signaux. Swift n'a pas
	// besoin de la connaître : ses quatre passerelles @_silgen_name entrent ici
	// et retrouvent s_store, ce qui évite de faire transiter un pointeur C++
	// à travers la frontière arithmétique des chaînes.
	godot::detail::s_store = this;
}

IdleStore::~IdleStore() {
	// Les tâches StoreKit vivent potentiellement plus longtemps que le nœud qui
	// a démarré le SDK. Les passerelles ignorent leurs rappels si l'objet est
	// détruit; sans cela, le pointeur statique resterait pendant.
	if (godot::detail::s_store == this) {
		godot::detail::s_store = nullptr;
	}
}

bool IdleStore::is_configured() const {
	return configured;
}

void IdleStore::start(const String &p_product_ids_csv) {
	configured = idle_store_ios_start(p_product_ids_csv.utf8().get_data()) != 0;
	if (!configured) {
		emit_signal("purchase_failed", String(""), String("catalogue non chargé"));
	}
}

void IdleStore::purchase(const String &p_product_id) {
	idle_store_ios_purchase(p_product_id.utf8().get_data());
}

void IdleStore::restore() {
	idle_store_ios_restore();
}

bool IdleStore::is_purchased(const String &p_product_id) {
	return idle_store_ios_is_purchased(p_product_id.utf8().get_data()) != 0;
}

String IdleStore::get_price(const String &p_product_id) {
	// Le tampon Swift est réutilisé à chaque appel : copie immédiate obligatoire.
	return String(idle_store_ios_price(p_product_id.utf8().get_data()));
}
