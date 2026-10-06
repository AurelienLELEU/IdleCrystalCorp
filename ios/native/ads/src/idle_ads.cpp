#include "idle_ads.h"
#include "idle_ads_ios.h"

#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/core/method_bind.hpp>
#include <godot_cpp/variant/utility_functions.hpp>

using namespace godot;

void IdleAds::_bind_methods() {
	ClassDB::bind_method(D_METHOD("is_configured"), &IdleAds::is_configured);
	ClassDB::bind_method(D_METHOD("configure", "app_id", "rewarded_unit_id", "debug"),
			&IdleAds::configure);
	ClassDB::bind_method(D_METHOD("show_rewarded", "reward_id"), &IdleAds::show_rewarded);

	ADD_SIGNAL(MethodInfo("rewarded_completed", PropertyInfo(Variant::STRING, "reward_id")));
	ADD_SIGNAL(MethodInfo("rewarded_failed",
			PropertyInfo(Variant::STRING, "reward_id"),
			PropertyInfo(Variant::STRING, "reason")));
}

namespace godot {
namespace detail {

// --- Passerelles Objective-C -> C++ ----------------------------------------
//
// Définitions des symboles que le .mm appelle. L'instance qui reçoit les
// signaux est mémorisée ici : le .mm n'inclut jamais godot-cpp (macros
// incompatibles), il ne peut donc pas appeler emit_signal() lui-même.
//
// Les delegates d'AdMob sont rappelés sur la file principale, émettre le signal
// directement est donc sûr — un report différé n'apporterait rien et
// introduirait un état intermédiaire où la pub est finie mais pas créditée.

static IdleAds *s_ads = nullptr;

} // namespace detail
} // namespace godot

extern "C" {

void idle_ads_bridge_completed(const char *p_reward_id) {
	if (godot::detail::s_ads == nullptr || p_reward_id == nullptr) { return; }
	godot::detail::s_ads->emit_signal("rewarded_completed", String(p_reward_id));
}

void idle_ads_bridge_failed(const char *p_reward_id, const char *p_reason) {
	if (godot::detail::s_ads == nullptr || p_reward_id == nullptr) { return; }
	godot::detail::s_ads->emit_signal("rewarded_failed",
			String(p_reward_id),
			String(p_reason != nullptr ? p_reason : "publicité indisponible"));
}
}

IdleAds::IdleAds() {
	godot::detail::s_ads = this;
}

IdleAds::~IdleAds() {
	// Un rappel asynchrone du SDK peut arriver après la destruction de l'objet.
	// Le pont C vérifie le pointeur avant d'émettre un signal; le laisser pendant
	// vers un Object libéré transformait un retour tardif en use-after-free.
	if (godot::detail::s_ads == this) {
		godot::detail::s_ads = nullptr;
	}
}

bool IdleAds::is_configured() const {
	return configured;
}

void IdleAds::configure(const String &p_app_id, const String &p_rewarded_unit_id, bool p_debug) {
	app_id = p_app_id;
	rewarded_unit_id = p_rewarded_unit_id;
	debug_mode = p_debug;

	const bool ids_present = !app_id.is_empty() && !rewarded_unit_id.is_empty();
	// Cast explicite : la frontière C renvoie un int, et une conversion
	// implicite int → bool est exactement le genre de conversion qui compile
	// avec un simple avertissement sur un compilateur, et qui échoue sur le
	// suivant.
	configured = idle_ads_ios_configure(
			app_id.utf8().get_data(),
			rewarded_unit_id.utf8().get_data(),
			debug_mode ? 1 : 0) != 0;

	if (!ids_present) {
		UtilityFunctions::push_error(
				"[IdleAds] app_id ou rewarded_unit_id vide — configuration ignorée.");
	} else if (!configured) {
		UtilityFunctions::push_warning(
				"[IdleAds] Google Mobile Ads indisponible. Vérifiez que "
				"GoogleMobileAds.framework est embarqué dans l'export iOS, ou "
				"compilez avec NO_SDK=1 pour revenir au simulateur.");
	}
}

void IdleAds::show_rewarded(const String &p_reward_id) {
	if (!configured) {
		// Le jeu reçoit l'échec et ne crédite rien : un bandeau « indisponible »
		// vaut mieux qu'un écran bloqué.
		emit_signal("rewarded_failed", p_reward_id, String("SDK non configuré"));
		return;
	}
	idle_ads_ios_show_rewarded(p_reward_id.utf8().get_data());
}
