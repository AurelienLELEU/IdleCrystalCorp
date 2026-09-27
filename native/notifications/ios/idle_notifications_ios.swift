// Notifications locales iOS/macOS pour l'extension Godot IdleNotifications.
// Ce n'est PAS du push distant : aucune APNs, serveur ou entitlement Push
// n'est nécessaire. UNUserNotificationCenter conserve la requête quand l'app
// est suspendue ou fermée.

import Foundation
import UserNotifications
#if os(iOS)
import UIKit
#endif
import Dispatch

// Génération par identifiant pour que le callback asynchrone de
// UserNotifications ne puisse pas recréer un rappel après que le joueur est
// revenu au premier plan et que GameManager a demandé son annulation.
private var s_generation: [String: UInt64] = [:]
private var s_permission_state = "not_determined"

private func permissionName(_ status: UNAuthorizationStatus) -> String {
    switch status {
    case .authorized, .provisional:
        return "granted"
    #if os(iOS)
    case .ephemeral:
        return "granted"
    #endif
    case .denied:
        return "denied"
    case .notDetermined:
        return "not_determined"
    @unknown default:
        return "unknown"
    }
}

private func reportPermission(_ status: UNAuthorizationStatus) {
    let state = permissionName(status)
    DispatchQueue.main.async {
        s_permission_state = state
        state.withCString { raw_permission_changed($0) }
    }
}

@_cdecl("idle_notifications_ios_is_configured")
public func idle_notifications_ios_is_configured() -> Int32 {
    return 1
}

@_cdecl("idle_notifications_ios_refresh_permission")
public func idle_notifications_ios_refresh_permission() {
    UNUserNotificationCenter.current().getNotificationSettings { settings in
        reportPermission(settings.authorizationStatus)
    }
}

@_cdecl("idle_notifications_ios_request_permission")
public func idle_notifications_ios_request_permission() {
    UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) {
        _, _ in
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            reportPermission(settings.authorizationStatus)
        }
    }
}

@_cdecl("idle_notifications_ios_schedule")
public func idle_notifications_ios_schedule(
    _ p_id: UnsafePointer<CChar>?,
    _ p_title: UnsafePointer<CChar>?,
    _ p_body: UnsafePointer<CChar>?,
    _ delaySeconds: Double
) -> Int32 {
    guard let p_id, let p_title, let p_body,
          delaySeconds.isFinite, delaySeconds > 0 else { return 0 }

    let identifier = String(cString: p_id)
    guard !identifier.isEmpty else { return 0 }
    let title = String(cString: p_title)
    let body = String(cString: p_body)

    let generation = (s_generation[identifier] ?? 0) + 1
    s_generation[identifier] = generation
	guard s_permission_state == "granted" else {
		reportSchedule(identifier, success: false,
				reason: "autorisation des notifications non accordée")
		return 1
	}

	// Pas de seconde requête getNotificationSettings ici : elle serait
	// asynchrone et l'app peut être suspendue dès le backgrounding. L'état a été
	// vérifié au démarrage, après le dialogue, puis au retour au premier plan.
	let content = UNMutableNotificationContent()
	content.title = title
	content.body = body
	content.sound = .default
	let trigger = UNTimeIntervalNotificationTrigger(
		timeInterval: max(1.0, delaySeconds), repeats: false)
	let request = UNNotificationRequest(
		identifier: identifier, content: content, trigger: trigger)
	UNUserNotificationCenter.current().add(request) { error in
		DispatchQueue.main.async {
			guard s_generation[identifier] == generation else {
				UNUserNotificationCenter.current()
					.removePendingNotificationRequests(withIdentifiers: [identifier])
				return
			}
			reportSchedule(identifier, success: error == nil,
					reason: error?.localizedDescription ?? "")
		}
	}
    // 1 signifie que l'opération asynchrone a été lancée. Son résultat réel
    // arrive ensuite par schedule_completed, jamais par un succès optimiste.
    return 1
}

@_cdecl("idle_notifications_ios_cancel")
public func idle_notifications_ios_cancel(_ p_id: UnsafePointer<CChar>?) {
    guard let p_id else { return }
    let identifier = String(cString: p_id)
    s_generation[identifier] = (s_generation[identifier] ?? 0) + 1
    UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [identifier])
    UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [identifier])
}

@_cdecl("idle_notifications_ios_cancel_all")
public func idle_notifications_ios_cancel_all() {
    for identifier in Array(s_generation.keys) {
        s_generation[identifier] = (s_generation[identifier] ?? 0) + 1
    }
    UNUserNotificationCenter.current().removeAllPendingNotificationRequests()
    UNUserNotificationCenter.current().removeAllDeliveredNotifications()
}

@_cdecl("idle_notifications_ios_open_settings")
public func idle_notifications_ios_open_settings() {
    #if os(iOS)
    DispatchQueue.main.async {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }
    #endif
}

@_silgen_name("idle_notifications_bridge_permission_changed")
private func raw_permission_changed(_ state: UnsafePointer<CChar>)

@_silgen_name("idle_notifications_bridge_schedule_completed")
private func raw_schedule_completed(
    _ id: UnsafePointer<CChar>, _ success: Int32, _ reason: UnsafePointer<CChar>)

private func reportSchedule(_ id: String, success: Bool, reason: String) {
    DispatchQueue.main.async {
        reason.withCString { raw_reason in
            id.withCString { raw_id in
                raw_schedule_completed(raw_id, success ? 1 : 0, raw_reason)
            }
        }
    }
}
