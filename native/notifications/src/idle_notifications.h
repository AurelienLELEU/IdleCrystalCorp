#ifndef IDLE_NOTIFICATIONS_H
#define IDLE_NOTIFICATIONS_H

#include <godot_cpp/classes/object.hpp>

namespace godot {

class IdleNotifications : public Object {
	GDCLASS(IdleNotifications, Object)

	String permission_state = "not_determined";

protected:
	static void _bind_methods();

public:
	IdleNotifications();
	~IdleNotifications();

	bool is_configured() const;
	String get_permission() const;
	void refresh_permission();
	void request_permission();
	bool schedule(const String &p_id, const String &p_title, const String &p_body,
			double p_delay_seconds);
	void cancel(const String &p_id);
	void cancel_all();
	void open_settings();

	void set_permission_state(const String &p_state);
	void emit_schedule_completed(const String &p_id, bool p_success, const String &p_reason);
};

} // namespace godot

#endif // IDLE_NOTIFICATIONS_H
