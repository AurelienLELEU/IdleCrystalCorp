#include "idle_notifications.h"

#include <gdextension_interface.h>
#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/core/defs.hpp>
#include <godot_cpp/godot.hpp>

using namespace godot;

void initialize_idle_notifications_module(ModuleInitializationLevel p_level) {
	if (p_level != MODULE_INITIALIZATION_LEVEL_SCENE) { return; }
	ClassDB::register_class<IdleNotifications>();
}

void uninitialize_idle_notifications_module(ModuleInitializationLevel p_level) {
	(void)p_level;
}

extern "C" {

GDExtensionBool GDE_EXPORT idle_notifications_library_init(
		GDExtensionInterfaceGetProcAddress p_get_proc_address,
		GDExtensionClassLibraryPtr p_library,
		GDExtensionInitialization *r_initialization) {
	GDExtensionBinding::InitObject init_obj(p_get_proc_address, p_library, r_initialization);
	init_obj.register_initializer(initialize_idle_notifications_module);
	init_obj.register_terminator(uninitialize_idle_notifications_module);
	init_obj.set_minimum_library_initialization_level(MODULE_INITIALIZATION_LEVEL_SCENE);
	return init_obj.init();
}

} // extern "C"
