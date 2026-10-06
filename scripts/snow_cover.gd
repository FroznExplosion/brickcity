class_name SnowCover
extends Node3D

## Snow lying (Docs/Disasters.md 21): smooth tiles on every top open to the
## sky, on the ground and on buildings, grown and melted by `weather_snow`
## (shaders/snow.gdshader). Made by the disaster context the first time it
## snows, freed when the last of it has melted.
##
##   * THE GROUND, where the host has terrain (`has_terrain()`): squares of
##     CHUNK studs round the camera out to RADIUS, one built a physics tick.
##     Each cell's top from the heightfield (BrickTerrain.surface_plate); a ray
##     down from above finds whether anything stands over it -- a building, a
##     site, a tree with collision -- and there is none under that. None on
##     ground under the sea either. BrickWorld.build_snow_cover_tops merges the
##     cells into tiles.
##   * BUILDINGS whose bricks are in (the host's `snow_buildings()`): a cover
##     for each, BrickWorld.build_snow_cover -- every column's highest living
##     top -- under the building's own node, so it moves and sways with it.
##     Built again when the building's structure changes (a hole in a roof
##     lets snow onto the floor below), no more than every REBUILD_S.
##
## The tiles are THICKNESS deep at full depth: a plate and a little more, so
## the studs under them are gone.

const CHUNK := 32
const RADIUS := 70.0
const DROP := 25.0                ## m past RADIUS before a square is let go
const THICKNESS := 0.16
const REBUILD_S := 1.0

var host: Node3D
var material: ShaderMaterial
## Squares built, by key.
var squares := {}
## id -> {node, version, at}
var covers := {}
var square_builds := 0
var cover_builds := 0
## The slowest square and building cover built, ms (the probe reads them).
var worst_square_ms := 0.0
var worst_cover_ms := 0.0

var _stud := 0.32
var _plate := 0.133


func setup(p_host: Node3D) -> void:
	host = p_host
	_stud = BrickWorld.get_stud_metres()
	_plate = BrickWorld.get_plate_metres()
	material = ShaderMaterial.new()
	material.shader = load("res://shaders/snow.gdshader")
	material.set_shader_parameter("thickness", THICKNESS)
	material.set_shader_parameter("stud", _stud)
	WeatherFx.register(material)


func _physics_process(_delta: float) -> void:
	if host == null:
		return
	var cam := get_viewport().get_camera_3d()
	if cam == null:
		return
	var at := cam.global_position
	if host.has_method("has_terrain") and host.has_terrain():
		_ground(at)
	if host.has_method("snow_buildings"):
		_buildings(at)


# --- The ground -----------------------------------------------------------------

func _ground(at: Vector3) -> void:
	var span := CHUNK * _stud
	var cx := floori(at.x / span)
	var cz := floori(at.z / span)
	var reach := ceili(RADIUS / span)
	# Let go of what is far behind.
	for key in squares.keys():
		var k: Vector2i = key
		var centre := Vector2((k.x + 0.5) * span, (k.y + 0.5) * span)
		if centre.distance_to(Vector2(at.x, at.z)) > RADIUS + DROP:
			var node = squares[key]
			if is_instance_valid(node):
				(node as Node).queue_free()
			squares.erase(key)
	# Build the nearest missing one: one a tick.
	var best := Vector2i(1 << 30, 0)
	var best_d := INF
	for z in range(cz - reach, cz + reach + 1):
		for x in range(cx - reach, cx + reach + 1):
			var k := Vector2i(x, z)
			if squares.has(k):
				continue
			var d := Vector2((x + 0.5) * span, (z + 0.5) * span).distance_to(Vector2(at.x, at.z))
			if d <= RADIUS and d < best_d:
				best_d = d
				best = k
	if best_d < INF:
		var t0 := Time.get_ticks_usec()
		squares[best] = _build_square(best)
		worst_square_ms = maxf(worst_square_ms, float(Time.get_ticks_usec() - t0) / 1000.0)


## One square of ground snow. Null when there is none in it (the sea, all
## covered); remembered either way so it is not tried again.
func _build_square(k: Vector2i) -> MeshInstance3D:
	var sea := BrickWave.get_sea_level()
	var space := get_world_3d().direct_space_state
	var tops := PackedInt32Array()
	tops.resize(CHUNK * CHUNK)
	var gx0 := k.x * CHUNK
	var gz0 := k.y * CHUNK
	var any := false
	for z in CHUNK:
		for x in CHUNK:
			var gx := gx0 + x
			var gz := gz0 + z
			var plates := BrickTerrain.surface_plate(gx, gz) + 1
			var ground := float(plates) * _plate
			var cell := -2000000000
			if ground > sea + 0.05:
				var px := (gx + 0.5) * _stud
				var pz := (gz + 0.5) * _stud
				var q := PhysicsRayQueryParameters3D.create(Vector3(px, ground + 40.0, pz),
						Vector3(px, ground + 0.3, pz))
				if space.intersect_ray(q).is_empty():
					cell = plates
					any = true
			tops[x + CHUNK * z] = cell
	square_builds += 1
	if not any:
		return null
	var arrays: Array = BrickWorld.build_snow_cover_tops(tops, CHUNK, CHUNK, _stud, _plate,
			THICKNESS, Vector2(gx0 * _stud, gz0 * _stud))
	if arrays.is_empty():
		return null
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	var mi := MeshInstance3D.new()
	mi.mesh = mesh
	mi.material_override = material
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(mi)
	return mi


# --- Buildings ------------------------------------------------------------------

func _buildings(at: Vector3) -> void:
	var now := Time.get_ticks_msec()
	var seen := {}
	var built := false
	for e in host.snow_buildings():
		var id: int = e.id
		var parent: Node3D = e.parent
		seen[id] = true
		if parent.global_position.distance_to(at) > RADIUS * 2.0:
			continue
		var c: Dictionary = covers.get(id, {})
		var stale: bool = c.is_empty() or not is_instance_valid(c.node) \
				or (c.node as Node).get_parent() != parent or int(c.version) != int(e.version)
		if not stale or built:
			continue
		if not c.is_empty() and now - int(c.at) < int(REBUILD_S * 1000.0) \
				and is_instance_valid(c.node) and (c.node as Node).get_parent() == parent:
			continue
		# One building a tick: a tall one is a few milliseconds.
		built = true
		if not c.is_empty() and is_instance_valid(c.node):
			(c.node as Node).queue_free()
		var mi: MeshInstance3D = null
		var t0 := Time.get_ticks_usec()
		var arrays: Array = host.world.build_snow_cover(int(e.chunk), THICKNESS)
		if not arrays.is_empty():
			var mesh := ArrayMesh.new()
			mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
			mi = MeshInstance3D.new()
			mi.name = "Snow"
			mi.mesh = mesh
			mi.material_override = material
			mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
			mi.set_instance_shader_parameter("weather_sway", e.get("sway", Vector3.ZERO))
			parent.add_child(mi)
		worst_cover_ms = maxf(worst_cover_ms, float(Time.get_ticks_usec() - t0) / 1000.0)
		covers[id] = {"node": mi, "version": e.version, "at": now}
		cover_builds += 1
	# A building whose bricks went: its snow goes with it.
	for id in covers.keys():
		if not seen.has(id):
			var node = covers[id].node
			if is_instance_valid(node):
				(node as Node).queue_free()
			covers.erase(id)


## How many squares of ground and buildings carry snow now.
func square_count() -> int:
	var n := 0
	for v in squares.values():
		if v != null and is_instance_valid(v):
			n += 1
	return n


func cover_count() -> int:
	var n := 0
	for c in covers.values():
		if c.node != null and is_instance_valid(c.node):
			n += 1
	return n


func _exit_tree() -> void:
	for c in covers.values():
		if c.node != null and is_instance_valid(c.node):
			(c.node as Node).queue_free()
	covers.clear()
