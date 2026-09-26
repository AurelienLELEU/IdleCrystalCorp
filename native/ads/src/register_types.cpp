// Point d'entrée de la GDExtension « IdleAds ».
//
// C'est la seule fonction que la GDExtension exporte. Godot l'appelle au
// chargement de la bibliothèque, avant la première scène.

#include "idle_ads.h"

#include <gdextension_interface.h>
#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/core/defs.hpp>
#include <godot_cpp/godot.hpp>

using namespace godot;

void initialize_idle_ads_module(ModuleInitializationLevel p_level) {
	if (p_level != MODULE_INITIALIZATION_LEVEL_SCENE) {
		return;
	}
	ClassDB::register_class<IdleAds>();
}

void uninitialize_idle_ads_module(ModuleInitializationLevel p_level) {
	(void)p_level;
}

extern "C" {

GDExtensionBool GDE_EXPORT idle_ads_library_init(
		GDExtensionInterfaceGetProcAddress p_get_proc_address,
		GDExtensionClassLibraryPtr p_library,
		GDExtensionInitialization *r_initialization) {
	GDExtensionBinding::InitObject init_obj(p_get_proc_address, p_library, r_initialization);

	init_obj.register_initializer(initialize_idle_ads_module);
	init_obj.register_terminator(uninitialize_idle_ads_module);
	init_obj.set_minimum_library_initialization_level(MODULE_INITIALIZATION_LEVEL_SCENE);

	return init_obj.init();
}
}
