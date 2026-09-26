// Implémentation iOS de la couche IdleAds — Google AdMob, rewarded ads.
//
// Langage : Objective-C++ plutôt que Swift. Le SDK Google est Objective-C, et
// le passer par Swift imposerait un bridging header, un module Swift généré et
// des annotations @objc, sans aucun gain ici : tout ce dont on a besoin est
// déjà exposé en Objective-C, et un .mm se compile directement avec les
// bindings C++ de Godot.
//
// MODE DÉVELOPPEMENT — la partie qui casse le plus de projets :
//
//   En développement, on affiche les ANNONCES DE TEST de Google, jamais les
//   vraies. Une unité de test est un identifiant public qui affiche une
//   annonce fictive et ne rapporte aucun revenu. Les vraies annonces ne sont
//   élargies qu'aux appareils de test enregistrés.
//
//   Deux conséquences d'un oubli :
//     - afficher de vraies annonces pendant les tests fait rejeter
//       l'application par Google ;
//     - cliquer sur sa propre annonce est du trafic frauduleux, et c'est le
//       motif de désinstallation le plus fréquent sur ce type de jeu.
//
//   Le mode est piloté par `debug`, issu de `ads.debug` dans
//   data/game_config.json. En production : "debug": false.
//
//   L'identifiant d'application (GADApplicationIdentifier) est posé dans
//   l'Info.plist par le preset d'export. Il n'est volontairement pas
//   surchargeable ici : Google exige que l'identifiant utilisé au démarrage
//   corresponde à celui de l'Info.plist.

#include "idle_ads_ios.h"

#include <string.h>

#ifdef __APPLE__

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

// SDK AdMob. Compilez avec -DIDLE_ADS_NO_SDK si vous n'embarquez pas le SDK ;
// le jeu retombera alors sur son simulateur intégré.
#ifndef IDLE_ADS_NO_SDK
#import <GoogleMobileAds/GoogleMobileAds.h>
#endif

// Unité d'annonce de test fournie par Google — identifiants publics, publiés
// exprès pour cet usage. Sert de repli si aucune unité n'est configurée, pour
// qu'un oubli de configuration n'affiche jamais une vraie annonce.
static NSString *const kAdMobSampleRewardedUnit = @"ca-app-pub-3940256099942544/5224354917";

// Valeur spéciale d'AdMob désignant le simulateur iOS.
static NSString *const kGADSimulatorDeviceId = @"Simulator";

static NSString *s_pending_reward_id = nil;
static NSString *s_rewarded_unit = nil;
static BOOL s_ads_ready = NO;
static BOOL s_loading = NO;

#ifdef IDLE_ADS_NO_SDK

// Extensions sans le SDK AdMob. Les deux actions ne font rien et la
// configuration échoue : le jeu bascule alors sur son simulateur intégré, ce
// qui est le comportement voulu quand on compile sans GoogleMobileAds.
int idle_ads_ios_configure(const char *p_app_id, const char *p_rewarded_unit_id, int p_debug) { return 0; }
void idle_ads_ios_show_rewarded(const char *p_reward_id) { }

#else

#pragma mark - Delegate

@interface IdleAdsDelegate : NSObject <GADFullScreenContentDelegate>
@end

@implementation IdleAdsDelegate

// La vidéo s'est jouée jusqu'au bout, ou a été fermée après le temps minimal
// imposé par une annonce récompensée. C'est le SEUL moment où le joueur a
// droit à sa récompense.
- (void)adDidDismissFullScreenContent:(GADFullScreenPresentingAd *)ad {
	NSString *reward = s_pending_reward_id ?: @"";
	s_pending_reward_id = nil;
	s_loading = NO;
	idle_ads_bridge_completed(reward.utf8().get_data());
}

// Interruption : réseau coupé, appel entrant, sortie de l'application. Rien
// n'est crédité. Ce n'est pas pénalisant, une pub indisponible est normale.
- (void)ad:(GADFullScreenPresentingAd *)ad
		didFailToPresentFullScreenContentWithError:(NSError *)error {
	NSString *reward = s_pending_reward_id ?: @"";
	NSString *why = [NSString stringWithFormat:@"vidéo refusée : %@", error.localizedDescription];
	s_pending_reward_id = nil;
	s_loading = NO;
	idle_ads_bridge_failed(reward.utf8().get_data(), why.utf8().get_data());
}

@end

static IdleAdsDelegate *s_delegate = nil;

#pragma mark - Vue courante

// AdMob refuse d'afficher une pub depuis une vue qui n'est pas présentée, et
// refuse silencieusement : le joueur ne voit rien et la récompense n'arrive
// jamais. D'où cette recherche explicite de la vue présentée au sommet.
static UIViewController *idle_ads_top_view_controller(void) {
	UIWindow *window = nil;
	for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
		if (![scene isKindOfClass:UIWindowScene.class]) { continue; }
		for (UIWindow *candidate in ((UIWindowScene *)scene).windows) {
			if (window == nil) { window = candidate; }
			if (candidate.isKeyWindow) { window = candidate; break; }
		}
		if (window != nil) { break; }
	}
	UIViewController *controller = window.rootViewController;
	while (controller.presentedViewController != nil) {
		controller = controller.presentedViewController;
	}
	return controller;
}

#pragma mark - Initialisation

int idle_ads_ios_configure(const char *p_app_id, const char *p_rewarded_unit_id, int p_debug) {
	if (p_app_id == NULL) { return 0; }
	NSString *app_id = [NSString stringWithUTF8String:p_app_id];
	if (app_id.length == 0) { return 0; }

	NSString *unit = (p_rewarded_unit_id != NULL)
			? [NSString stringWithUTF8String:p_rewarded_unit_id]
			: @"";
	s_rewarded_unit = unit.length > 0 ? unit : kAdMobSampleRewardedUnit;

	if (s_delegate == nil) {
		s_delegate = [[IdleAdsDelegate alloc] init];
	}

	if (p_debug) {
		// Le simulateur est enregistré d'office. Les appareils réels se
		// déclarent ici : Google affiche leur identifiant dans la console au
		// premier lancement ("Use Google Mobile Ads SDK ... test device").
		GADMobileAds.sharedInstance.requestConfiguration.testDeviceIdentifiers =
				@[ kGADSimulatorDeviceId ];
		NSLog(@"[IdleAds] MODE TEST actif — aucune annonce réelle ne sera affichée.");
	} else {
		GADMobileAds.sharedInstance.requestConfiguration.testDeviceIdentifiers = @[];
	}

	[[GADMobileAds sharedInstance] startWithCompletionHandler:^(GADInitializationStatus *status) {
		if (status.adErrors.count > 0) {
			s_ads_ready = NO;
			for (NSError *error in status.adErrors) {
				NSLog(@"[IdleAds] initialisation AdMob refusée : %@", error.localizedDescription);
			}
			return;
		}
		s_ads_ready = YES;
		NSLog(@"[IdleAds] Google Mobile Ads prêt (unité : %@)", s_rewarded_unit);
	}];

	return 1;
}

void idle_ads_ios_show_rewarded(const char *p_reward_id) {
	if (p_reward_id == NULL) { return; }
	if (!s_ads_ready || s_loading) { return; }

	NSString *reward = [NSString stringWithUTF8String:p_reward_id];
	s_pending_reward_id = reward;
	s_loading = YES;

	GADRequest *request = [GADRequest request];
	// Sans délai maximal, un réseau lent immobilise le joueur sur un écran noir
	// pendant une durée indéfinie. Au-delà, l'échec est traité comme une pub
	// indisponible, ce qui est exact.
	request.timeout = 10.0;

	[GADRewardedAd loadWithAdUnitID:s_rewarded_unit
			request:request
			completionHandler:^(GADRewardedAd *ad, NSError *error) {
		if (error != nil || ad == nil) {
			NSString *why = [NSString
					stringWithFormat:@"annonce indisponible : %@",
					error != nil ? error.localizedDescription : @"réponse vide"];
			s_pending_reward_id = nil;
			s_loading = NO;
			idle_ads_bridge_failed(reward.utf8().get_data(), why.utf8().get_data());
			return;
		}
		ad.fullScreenContentDelegate = s_delegate;
		[ad presentFromRootViewController:idle_ads_top_view_controller()];
	}];
}

#endif // IDLE_ADS_NO_SDK

#endif // __APPLE__
