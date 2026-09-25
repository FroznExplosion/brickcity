# shock_effect.gd — SHOCK: arc ribbons orbit the enemy, sparks, and it
# electrifies environmental water.
class_name ShockEffect

const ARC_COUNT := 3

static func on_applied(t: ElementalTarget) -> void:
	var arcs: Array = []
	for i in ARC_COUNT:
		var a := VfxPool.acquire_arc(t.chest_socket)
		a.rotation.y = TAU * float(i) / ARC_COUNT
		# Each ribbon gets a random seed so bolts don't sync.
		for m in a.find_children("*", "MeshInstance3D", true, false):
			m.set_instance_shader_parameter("seed", randf() * 10.0)
			m.set_instance_shader_parameter("intensity", 1.0)
		arcs.append(a)
	t.fx_handles["shock_arcs"] = arcs
	t.fx_handles["shock_sparks"] = VfxPool.acquire_emitter("shock_sparks", t.chest_socket)
	react_surfaces(t.ground_socket.global_position, 1.5)

static func on_removed(t: ElementalTarget) -> void:
	for a in t.fx_handles.get("shock_arcs", []):
		VfxPool.release_arc(a)
	t.fx_handles.erase("shock_arcs")
	if t.fx_handles.has("shock_sparks"):
		VfxPool.release_emitter("shock_sparks", t.fx_handles["shock_sparks"])
		t.fx_handles.erase("shock_sparks")

## Call from shock projectiles at impact too — hitting water directly zaps it.
static func react_surfaces(world_pos: Vector3, radius: float) -> void:
	for surf in Engine.get_main_loop().get_nodes_in_group("elemental_surface"):
		if surf.surface_type == "water" \
				and surf.global_position.distance_to(world_pos) <= radius + surf.reach:
			surf.electrify(4.0)
