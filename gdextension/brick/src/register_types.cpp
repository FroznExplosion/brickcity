#include "register_types.h"
#include "brick_world.h"
#include "brick_terrain.h"
#include "creature/mesh_forge.h"
#include "swarm/flow_grid.h"
#include "swarm/lane_graph.h"
#include "swarm/swarm_core.h"

#include <gdextension_interface.h>
#include <godot_cpp/core/defs.hpp>
#include <godot_cpp/godot.hpp>

using namespace godot;

void initialize_brick_module(ModuleInitializationLevel p_level) {
    if (p_level != MODULE_INITIALIZATION_LEVEL_SCENE) {
        return;
    }
    ClassDB::register_class<BrickWorld>();
    ClassDB::register_class<BrickTerrain>();
    ClassDB::register_class<BrickWave>();
    // SwarmCore, from BoomerBorder (src/swarm/).
    ClassDB::register_class<SwarmCore>();
    ClassDB::register_class<LaneGraph>();
    ClassDB::register_class<FlowGrid>();
    // MeshForge, the procedural creatures' mesh builder (src/creature/).
    ClassDB::register_class<MeshForge>();
}

void uninitialize_brick_module(ModuleInitializationLevel p_level) {
    if (p_level != MODULE_INITIALIZATION_LEVEL_SCENE) {
        return;
    }
}

extern "C" {
GDExtensionBool GDE_EXPORT brick_library_init(
        GDExtensionInterfaceGetProcAddress p_get_proc_address,
        const GDExtensionClassLibraryPtr p_library,
        GDExtensionInitialization *r_initialization) {
    godot::GDExtensionBinding::InitObject init_obj(p_get_proc_address, p_library, r_initialization);

    init_obj.register_initializer(initialize_brick_module);
    init_obj.register_terminator(uninitialize_brick_module);
    init_obj.set_minimum_library_initialization_level(MODULE_INITIALIZATION_LEVEL_SCENE);

    return init_obj.init();
}
}
