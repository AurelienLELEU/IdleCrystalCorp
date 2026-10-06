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
//   En développement, on force l'UNITÉ DE TEST Rewarded iOS de Google, jamais
//   l'unité de production fournie par la configuration. Un device de test mal
//   enregistré ne peut donc pas afficher de vraies impressions.
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

#include <dispatch/dispatch.h>
#include <string.h>

// `__APPLE__` ne veut PAS dire « iOS » : il est défini sur macOS aussi. Le
// garde-fou `#ifdef __APPLE__` laissait donc cette compilation aller jusqu'à
// `#import <UIKit/UIKit.h>`, inexistant sur Mac, et la cible `macos`
// échouait. Le test correct est `TARGET_OS_IOS`, qui vient de
// TargetConditionals.h. UIKit est un SDK iOS, pas un SDK Mac : la confusion
// était le premier obstacle réel à la compilation sur cette machine.
#include <TargetConditionals.h>

#if defined(__APPLE__) && TARGET_OS_IOS

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
// Identifiant officiel iOS Rewarded (1712485313). L'ancien suffixe 5224354917
// est celui des annonces Rewarded Android : sur iOS, il ne teste pas le format
// demandé et peut renvoyer une unité invalide.
static NSString *const kAdMobSampleRewardedUnit = @"ca-app-pub-3940256099942544/1712485313";

// Valeur spéciale d'AdMob désignant le simulateur iOS.
static NSString *const kGADSimulatorDeviceId = @"Simulator";

static NSString *s_pending_reward_id = nil;
static NSString *s_rewarded_unit = nil;
static BOOL s_ads_ready = NO;
static BOOL s_loading = NO;
static BOOL s_reward_earned = NO;
static NSUInteger s_load_generation = 0;

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

// La fermeture n'est PAS une preuve de récompense. Seul le callback
// `userDidEarnRewardHandler` autorise le crédit; quitter avant celui-ci est un
// échec normal, sans crédit.
- (void)adDidDismissFullScreenContent:(GADFullScreenPresentingAd *)ad {
	if (s_pending_reward_id == nil) { return; }
	NSString *reward = [s_pending_reward_id copy];
	BOOL earned = s_reward_earned;
	s_pending_reward_id = nil;
	s_loading = NO;
	s_reward_earned = NO;
	if (earned) {
		idle_ads_bridge_completed([reward UTF8String]);
	} else {
		idle_ads_bridge_failed([reward UTF8String],
				"la vidéo a été fermée avant la validation de la récompense");
	}
}

// Interruption : réseau coupé, appel entrant, sortie de l'application. Rien
// n'est crédité. Ce n'est pas pénalisant, une pub indisponible est normale.
- (void)ad:(GADFullScreenPresentingAd *)ad
		didFailToPresentFullScreenContentWithError:(NSError *)error {
	if (s_pending_reward_id == nil) { return; }
	NSString *reward = [s_pending_reward_id copy];
	NSString *why = [NSString stringWithFormat:@"vidéo refusée : %@", error.localizedDescription];
	s_pending_reward_id = nil;
	s_loading = NO;
	s_reward_earned = NO;
	idle_ads_bridge_failed([reward UTF8String], [why UTF8String]);
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
	// Le drapeau debug force l'unité de test, même si la configuration contient
	// déjà l'identifiant de production. Enregistrer uniquement « Simulator »
	// comme appareil de test ne protège pas un iPhone physique : il recevrait
	// sinon de vraies impressions pendant le développement.
	s_rewarded_unit = (p_debug || unit.length == 0)
			? kAdMobSampleRewardedUnit
			: unit;

	if (s_delegate == nil) {
		s_delegate = [[IdleAdsDelegate alloc] init];
	}

	if (p_debug) {
		// Le simulateur est déclaré comme test device. Sur un iPhone physique,
		// l'unité d'annonce est de toute façon forcée vers l'unité Rewarded de
		// test ci-dessus; aucun identifiant d'appareil privé n'est nécessaire.
		GADMobileAds.sharedInstance.requestConfiguration.testDeviceIdentifiers =
				@[ kGADSimulatorDeviceId ];
		NSLog(@"[IdleAds] MODE TEST actif — aucune annonce réelle ne sera affichée.");
	} else {
		GADMobileAds.sharedInstance.requestConfiguration.testDeviceIdentifiers = @[];
	}

	[[GADMobileAds sharedInstance] startWithCompletionHandler:^(GADInitializationStatus *status) {
		s_ads_ready = NO;
		for (NSString *adapter_name in status.adapterStatusesByClassName) {
			GADAdapterStatus *adapter = status.adapterStatusesByClassName[adapter_name];
			if (adapter.state == GADAdapterInitializationStateReady) {
				s_ads_ready = YES;
				break;
			}
		}
		if (!s_ads_ready) {
			NSLog(@"[IdleAds] aucun adaptateur AdMob n'est prêt; les pubs seront refusées proprement.");
			return;
		}
		NSLog(@"[IdleAds] Google Mobile Ads prêt (unité : %@)", s_rewarded_unit);
	}];

	return 1;
}

void idle_ads_ios_show_rewarded(const char *p_reward_id) {
	if (p_reward_id == NULL) { return; }

	NSString *reward = [NSString stringWithUTF8String:p_reward_id];
	if (!s_ads_ready) {
		idle_ads_bridge_failed([reward UTF8String], "SDK AdMob pas prêt");
		return;
	}
	if (s_loading || s_pending_reward_id != nil) {
		idle_ads_bridge_failed([reward UTF8String], "une publicité est déjà en cours");
		return;
	}
	if (reward.length == 0) {
		idle_ads_bridge_failed("", "identifiant de récompense vide");
		return;
	}

	s_pending_reward_id = reward;
	s_loading = YES;
	s_reward_earned = NO;
	const NSUInteger request_generation = ++s_load_generation;

	// `GADRequest` n'expose pas de propriété `timeout`. Le délai est géré ici,
	// sur la file principale, et l'identifiant de génération rend inoffensif un
	// callback SDK tardif après l'expiration.
	dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 15 * NSEC_PER_SEC),
		dispatch_get_main_queue(), ^{
			if (!s_loading || request_generation != s_load_generation) { return; }
			NSString *pending = [s_pending_reward_id copy] ?: reward;
			s_pending_reward_id = nil;
			s_loading = NO;
			s_reward_earned = NO;
			idle_ads_bridge_failed([pending UTF8String], "délai de chargement dépassé");
		});

	GADRequest *request = [GADRequest request];
	[GADRewardedAd loadWithAdUnitID:s_rewarded_unit
			request:request
			completionHandler:^(GADRewardedAd *ad, NSError *error) {
		if (!s_loading || request_generation != s_load_generation) { return; }
		if (error != nil || ad == nil) {
			NSString *why = [NSString
					stringWithFormat:@"annonce indisponible : %@",
					error != nil ? error.localizedDescription : @"réponse vide"];
			NSString *pending = [s_pending_reward_id copy] ?: reward;
			s_pending_reward_id = nil;
			s_loading = NO;
			s_reward_earned = NO;
			idle_ads_bridge_failed([pending UTF8String], [why UTF8String]);
			return;
		}
		UIViewController *presenter = idle_ads_top_view_controller();
		if (presenter == nil) {
			NSString *pending = [s_pending_reward_id copy] ?: reward;
			s_pending_reward_id = nil;
			s_loading = NO;
			s_reward_earned = NO;
			idle_ads_bridge_failed([pending UTF8String], "aucune fenêtre active pour afficher la publicité");
			return;
		}
		NSError *present_error = nil;
		if (![ad canPresentFromRootViewController:presenter error:&present_error]) {
			NSString *pending = [s_pending_reward_id copy] ?: reward;
			NSString *why = [NSString stringWithFormat:@"publicité impossible à afficher : %@",
					present_error.localizedDescription ?: @"présentation refusée"];
			s_pending_reward_id = nil;
			s_loading = NO;
			s_reward_earned = NO;
			idle_ads_bridge_failed([pending UTF8String], [why UTF8String]);
			return;
		}
		ad.fullScreenContentDelegate = s_delegate;
		s_loading = NO;
		[ad presentFromRootViewController:presenter userDidEarnRewardHandler:^{
			s_reward_earned = YES;
		}];
	}];
}

#endif // IDLE_ADS_NO_SDK

#else // pas iOS : macOS, Linux, Windows

// Le .h déclare idle_ads_ios_configure et idle_ads_ios_show_rewarded SUR
// TOUTES les plateformes, en annonçant que sur une plateforme sans AdMob elles
// « renvoient 0 / ne font rien ». L'implémentation de ces stubs n'existait
// nulle part : sans elle, l'édition de lien échoue sur toute cible non-Apple
// avec un `undefined symbol` pointant sur ce fichier-ci. Ils sont donc ici, et
// le jeu bascule sur son simulateur intégré, comme documenté dans le .h.

int idle_ads_ios_configure(const char *p_app_id, const char *p_rewarded_unit_id, int p_debug) { return 0; }
void idle_ads_ios_show_rewarded(const char *p_reward_id) { }

#endif // TARGET_OS_IOS
