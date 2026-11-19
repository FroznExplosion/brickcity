extends Node

## FLOATING AND SINKING DEBRIS (Docs/MineWater.md 14.8): what comes off the
## ground in the mine world -- the bricks a shot throws (terrain_debris.gd)
## and the pieces that come loose (ground_collapse.gd's PlanetPieces) -- in
## water or lava floats or sinks by what it is MOSTLY made of: mostly wood or
## leaves floats, mostly anything else (stone, dirt, sand ...) sinks.
##
## Each physics tick, for every body in a fluid: the part of it under the
## surface (its box against MineWater.surface_at) lifts it by that share of
## its weight over its density, the fluid slows it and running water carries
## it. A floater settles riding high or low by its density; a sinker goes down
## slowly and rests on the bed. Lava is three times as dense as water: wood
## floats on it too (and burns there in a later step).
##
## Preloaded by path, not named (see terrain_scene.gd).

## Density over water's, by material name; anything not here sinks as STONE.
const FLOATS := { "wood": 0.6, "leaves": 0.35, "ice": 0.9 }
const STONE := 2.4
const LAVA_DENSITY := 3.0
## How much the fluid slows a body (1/s at full submersion), spin too.
const DRAG := 2.2
const SPIN_DRAG := 1.5
## Running water's pull, as a share of reaching its speed in a second.
const CARRY := 1.5

var host: Node = null
var water: Node = null
## How many bodies were in a fluid last tick (readout, gates).
var wet_bodies := 0
var floating := 0

## Filament colour -> material, for the bricks a shot throws (they carry only
## their colour). Built once from the terrain's own table.
var _by_colour: Array = []           ## [[Color, material name], ...]
## Piece chunk -> [version, density].
var _piece_density := {}
var _gravity := 9.8


func setup(p_host: Node, p_water: Node) -> void:
	host = p_host
	water = p_water
	_gravity = float(ProjectSettings.get_setting("physics/3d/default_gravity", 9.8))
	var names := BrickTerrain.material_names()
	for m in names.size():
		var col := BrickWorld.get_filament_colour(BrickTerrain.material_filament_index(m))
		_by_colour.append([col, names[m]])


## The density (over water's) of a material name.
static func density_of(material: String) -> float:
	return float(FLOATS.get(material, STONE))


## The material a colour is closest to (the ground's filaments are distinct).
func material_of_colour(col: Color) -> String:
	var best := ""
	var best_d := INF
	for e in _by_colour:
		var c: Color = e[0]
		var d := (c.r - col.r) * (c.r - col.r) + (c.g - col.g) * (c.g - col.g) + (c.b - col.b) * (c.b - col.b)
		if d < best_d:
			best_d = d
			best = e[1]
	return best


## By the MAJORITY: more floating bricks than sinking ones, it floats (at the
## mean density of its floating bricks); otherwise it sinks.
func majority_density(materials: Array) -> float:
	var floats := 0
	var sum := 0.0
	for m in materials:
		var d := density_of(m)
		if d < 1.0:
			floats += 1
			sum += d
	if floats * 2 > materials.size():
		return sum / floats
	return STONE


func _piece_density_of(p) -> float:
	var bricks: BrickWorld = host.collapse.bricks
	var v: int = bricks.get_chunk_version(p.chunk)
	var known = _piece_density.get(p.chunk)
	if known != null and int(known[0]) == v:
		return float(known[1])
	var mats := []
	var n := bricks.get_block_count(p.chunk)
	for i in n:
		var c := bricks.get_block_rgba(p.chunk, i)
		mats.append(material_of_colour(Color(c.r, c.g, c.b)))
	var d := majority_density(mats)
	_piece_density[p.chunk] = [v, d]
	return d


func _physics_process(delta: float) -> void:
	if host == null or water == null:
		return
	wet_bodies = 0
	floating = 0
	var debris = host.get("debris")
	if debris != null:
		for body in debris.bodies:
			if not is_instance_valid(body) or body.freeze:
				continue
			if not body.has_meta("density"):
				# One brick: its own material is its majority.
				body.set_meta("density", density_of(material_of_colour(body.get_meta("colour", Color.GRAY))))
			var size: Vector3 = body.get_meta("size", Vector3.ONE * 0.3)
			var d := float(body.get_meta("density", STONE))
			var half := Vector3(0.0, size.y * 0.5, 0.0)
			_float(body, body.global_position - half, body.global_position + half, d, delta)
	var collapse = host.get("collapse")
	if collapse != null and collapse.pieces != null:
		for p in collapse.pieces.pieces:
			if p.body == null or not is_instance_valid(p.body) or p.body.freeze:
				continue
			var box: AABB = collapse.pieces.world_box(p)
			_float(p.body, box.position, box.end, _piece_density_of(p), delta)


## One body whose world box runs from `lo` to `hi` (only their heights and the
## middle's x, z are used), density `d` over water's.
func _float(body: RigidBody3D, lo: Vector3, hi: Vector3, d: float, delta: float) -> void:
	var mid := (lo + hi) * 0.5
	var local: Vector3 = host.to_local(Vector3(mid.x, lo.y, mid.z))
	var top: float = water.surface_at(local + Vector3.UP * 0.02)
	if is_inf(top):
		# Fully under: the surface over the middle, asked higher up.
		top = water.surface_at(host.to_local(mid))
		if is_inf(top):
			return
	var height := maxf(hi.y - lo.y, 0.05)
	var frac := clampf((top - local.y) / height, 0.0, 1.0)
	if frac <= 0.0:
		return
	wet_bodies += 1
	var fluid_density := 1.0
	if water.fluid_at(local + Vector3.UP * 0.02) == 2:
		fluid_density = LAVA_DENSITY
	if d < fluid_density:
		floating += 1
	# A body at rest on a bed sleeps, and a sleeping body takes no force: a
	# wood brick that touched the bottom stayed there.
	if body.sleeping:
		body.sleeping = false
	var g := _gravity * body.gravity_scale
	var lift := body.mass * g * frac * fluid_density / d
	body.apply_central_force(Vector3.UP * lift)
	var v := body.linear_velocity
	var flow: Vector3 = water.flow_at(local + Vector3.UP * 0.05)
	body.apply_central_force(((flow - v) * CARRY - v * DRAG * 0.5) * body.mass * frac)
	body.angular_velocity *= maxf(0.0, 1.0 - SPIN_DRAG * frac * delta)
