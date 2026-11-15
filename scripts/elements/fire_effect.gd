# fire_effect.gd — FIRE: body burn + emitters, ignites oil, melts env ice.
class_name FireEffect

static func on_applied(t: ElementalTarget) -> void:
	t.set_overlay(ElementalManager.ELEMENT_COLOR[ElementalManager.Element.FIRE],
		0.0, 0.0, 1.0)   # burn_amount full: shader animates the ember front
	t.fx_handles["fire_body"] = VfxPool.acquire_emitter("fire_body", t.chest_socket)
	t.fx_handles["fire_smoke"] = VfxPool.acquire_emitter(
		"fire_smoke", t.chest_socket, Vector3.UP * 0.4)
	# A burning enemy is itself an ignition source for what they stand on.
	react_surfaces(t.ground_socket.global_position, 1.2)

static func on_removed(t: ElementalTarget) -> void:
	t.set_overlay_param("burn_amount", 0.0)
	for k in ["fire_body", "fire_smoke"]:
		if t.fx_handles.has(k):
			VfxPool.release_emitter(k, t.fx_handles[k])
			t.fx_handles.erase(k)
	t.clear_overlay_if_unused()

## Also call this from fire projectiles/explosions at their impact point so
## shooting the ground directly ignites oil / melts ice sheets.
static func react_surfaces(world_pos: Vector3, radius: float) -> void:
	for surf in Engine.get_main_loop().get_nodes_in_group("elemental_surface"):
		if surf.global_position.distance_to(world_pos) > radius + surf.reach:
			continue
		match surf.surface_type:
			"oil":
				surf.ignite()
			"ice":
				surf.melt()   # spawns SurfaceWater beneath, see surface_ice.gd
