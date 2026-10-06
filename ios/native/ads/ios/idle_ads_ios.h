#ifndef IDLE_ADS_IOS_H
#define IDLE_ADS_IOS_H

// Pont vers l'implémentation iOS (Objective-C++).
//
// Deux directions, deux mécanismes, et il faut les distinguer :
//
//   C++ -> Objective-C : ces deux fonctions. Le C++ les appelle, le .mm les
//   définit. Elles existent sur toutes les plateformes cibles ; sur une
//   plateforme sans AdMob, elles renvoient 0 / ne font rien, et le jeu bascule
//   alors sur son simulateur intégré. C'est ce qui permet au simulateur de
//   rester le mode par défaut sur ordinateur.
//
//   Objective-C -> C++ : les `idle_ads_bridge_*` ci-dessous, définies en
//   extern "C" dans idle_ads.cpp. Le .mm les appelle, le C++ les définit.
//
// Aucune des deux ne passe par un en-tête godot-cpp : ce fichier n'inclut que
// l'interface C, ce qui évite que les macros d'Objective-C et celles de godot-cpp
// se marchent dessus. Le .mm n'a donc jamais le type IdleAds sous les yeux et
// n'appelle jamais emit_signal() lui-même.

#ifdef __cplusplus
extern "C" {
#endif

/// Démarre Google Mobile Ads. Renvoie 0 si le SDK n'est pas embarqué ou si
/// l'identifiant est vide.
int idle_ads_ios_configure(const char *p_app_id, const char *p_rewarded_unit_id, int p_debug);

/// Charge et affiche une vidéo récompensée. Asynchrone : le résultat revient
/// par idle_ads_bridge_completed ou idle_ads_bridge_failed.
void idle_ads_ios_show_rewarded(const char *p_reward_id);

// --- Passerelles Objective-C -> C++ ---------------------------------------
// Définies dans idle_ads.cpp. Le premier paramètre est toujours le nom de la
// récompense, pour que le jeu puisse décompter le bon plafond quotidien.

void idle_ads_bridge_completed(const char *p_reward_id);
void idle_ads_bridge_failed(const char *p_reward_id, const char *p_reason);

#ifdef __cplusplus
}
#endif

#endif // IDLE_ADS_IOS_H
