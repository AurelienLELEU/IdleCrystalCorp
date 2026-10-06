#ifndef IDLE_NOTIFICATIONS_IOS_H
#define IDLE_NOTIFICATIONS_IOS_H

#ifdef __cplusplus
extern "C" {
#endif

int idle_notifications_ios_is_configured(void);
void idle_notifications_ios_refresh_permission(void);
void idle_notifications_ios_request_permission(void);
int idle_notifications_ios_schedule(const char *p_id, const char *p_title,
		const char *p_body, double p_delay_seconds);
void idle_notifications_ios_cancel(const char *p_id);
void idle_notifications_ios_cancel_all(void);
void idle_notifications_ios_open_settings(void);

void idle_notifications_bridge_permission_changed(const char *p_state);
void idle_notifications_bridge_schedule_completed(const char *p_id, int p_success,
		const char *p_reason);

#ifdef __cplusplus
}
#endif

#endif // IDLE_NOTIFICATIONS_IOS_H
