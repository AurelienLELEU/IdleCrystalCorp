#include "idle_notifications.h"
#include "idle_notifications_ios.h"

#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/core/method_bind.hpp>

using namespace godot;

namespace godot {
namespace detail {

static IdleNotifications *s_notifications = nullptr;

} // namespace detail
} // namespace godot

extern "C" {

void idle_notifications_bridge_permission_changed(const char *p_state) {
	if (godot::detail::s_notifications == nullptr) { return; }
	godot::detail::s_notifications->set_permission_state(
			String(p_state != nullptr ? p_state : "unknown"));
}

void idle_notifications_bridge_schedule_completed(const char *p_id, int p_success,
		const char *p_reason) {
	if (godot::detail::s_notifications == nullptr || p_id == nullptr) { return; }
	godot::detail::s_notifications->emit_schedule_completed(
			String(p_id), p_success != 0,
			String(p_reason != nullptr ? p_reason : ""));
}

} // extern "C"

void IdleNotifications::_bind_methods() {
	ClassDB::bind_method(D_METHOD("is_configured"), &IdleNotifications::is_configured);
	ClassDB::bind_method(D_METHOD("get_permission"), &IdleNotifications::get_permission);
	ClassDB::bind_method(D_METHOD("refresh_permission"), &IdleNotifications::refresh_permission);
	ClassDB::bind_method(D_METHOD("request_permission"), &IdleNotifications::request_permission);
	ClassDB::bind_method(D_METHOD("schedule", "id", "title", "body", "delay_seconds"),
			&IdleNotifications::schedule);
	ClassDB::bind_method(D_METHOD("cancel", "id"), &IdleNotifications::cancel);
	ClassDB::bind_method(D_METHOD("cancel_all"), &IdleNotifications::cancel_all);
	ClassDB::bind_method(D_METHOD("open_settings"), &IdleNotifications::open_settings);

	ADD_SIGNAL(MethodInfo("permission_changed",
			PropertyInfo(Variant::STRING, "state")));
	ADD_SIGNAL(MethodInfo("schedule_completed",
			PropertyInfo(Variant::STRING, "id"),
			PropertyInfo(Variant::BOOL, "success"),
			PropertyInfo(Variant::STRING, "reason")));
}

IdleNotifications::IdleNotifications() {
	godot::detail::s_notifications = this;
}

IdleNotifications::~IdleNotifications() {
	if (godot::detail::s_notifications == this) {
		godot::detail::s_notifications = nullptr;
	}
}

bool IdleNotifications::is_configured() const {
	return idle_notifications_ios_is_configured() != 0;
}

String IdleNotifications::get_permission() const {
	return permission_state;
}

void IdleNotifications::refresh_permission() {
	idle_notifications_ios_refresh_permission();
}

void IdleNotifications::request_permission() {
	idle_notifications_ios_request_permission();
}

bool IdleNotifications::schedule(const String &p_id, const String &p_title,
		const String &p_body, double p_delay_seconds) {
	if (p_id.is_empty() || p_delay_seconds <= 0.0) { return false; }
	if (permission_state != "granted" && permission_state != "provisional") { return false; }
	return idle_notifications_ios_schedule(p_id.utf8().get_data(),
			p_title.utf8().get_data(), p_body.utf8().get_data(), p_delay_seconds) != 0;
}

void IdleNotifications::cancel(const String &p_id) {
	idle_notifications_ios_cancel(p_id.utf8().get_data());
}

void IdleNotifications::cancel_all() {
	idle_notifications_ios_cancel_all();
}

void IdleNotifications::open_settings() {
	idle_notifications_ios_open_settings();
}

void IdleNotifications::set_permission_state(const String &p_state) {
	permission_state = p_state;
	emit_signal("permission_changed", permission_state);
}

void IdleNotifications::emit_schedule_completed(const String &p_id, bool p_success,
		const String &p_reason) {
	emit_signal("schedule_completed", p_id, p_success, p_reason);
}
