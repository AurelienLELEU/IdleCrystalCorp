#ifndef IDLE_ADS_H
#define IDLE_ADS_H

// Couche native « IdleAds » — rewarded ads Google AdMob sur iOS.
//
// CONTRACT AVEC core_engine/AdService.gd (ne pas modifier l'un sans l'autre) :
//
//   Objet exposé :  class_name IdleAds
//   Méthodes appelées par le jeu :
//       is_configured() -> bool
//       configure(app_id, rewarded_unit_id, debug) -> void
//       show_rewarded(reward_id: String) -> void
//   Signaux émis vers le jeu :
//       rewarded_completed(reward_id: String)
//       rewarded_failed(reward_id: String, reason: String)
//
// RÈGLE NON NÉGOCIABLE : `rewarded_completed` ne doit être émis qu'à la fin
// RÉELLE de la vidéo. L'émettre au démarrage crédite un joueur qui a quitté
// l'application : c'est la première cause de désinstallation sur un jeu à
// récompense, et le jeu GDScript ne peut pas détecter ce cas. C'est ici qu'il
// se joue.
//
// `rewarded_failed` ne crédite rien et n'est pas pénalisant : une pub
// indisponible est un motif normal, pas une erreur.

#include <godot_cpp/classes/object.hpp>

namespace godot {

class IdleAds : public Object {
	GDCLASS(IdleAds, Object)

	bool configured = false;
	String app_id;
	String rewarded_unit_id;
	bool debug_mode = true;

protected:
	static void _bind_methods();

public:
	IdleAds();
	~IdleAds();

	bool is_configured() const;
	void configure(const String &p_app_id, const String &p_rewarded_unit_id, bool p_debug);
	void show_rewarded(const String &p_reward_id);
};

} // namespace godot

#endif // IDLE_ADS_H
