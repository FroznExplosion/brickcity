class_name MineWiring
extends Node3D
## WIRING in the mine world, stage 1 (Docs/MineWiring.md 3.3, 4, 10): cable
## tiles, the nets they make, a lever and a lamp.
##
##   cable   a 1x1 smooth tile, one plate tall, laid on the ground's top (on
##           its studs, as a real tile sits), a cable along it. NOT a terrain
##           material: its own sparse layer (the water's pattern, MineWater.md
##           1), so a net lighting up never rebakes ground. No collider.
##   net     cables that touch: four sides, and up or down a step of up to a
##           brick (3 plates) -- so a run climbs a block. A net's level is the
##           highest of what drives it (0-15); the whole net changes at once:
##           no fading with distance, no repeaters (section 4).
##   device  a node on the stud lattice, 1 stud x 1 brick, standing on ground
##           (the chests' pattern, MineChests). It reads or drives the nets of
##           the cables beside it (four sides, a step up or down) and the
##           devices beside it. Devices never join nets: a lamp between two
##           runs keeps them two.
##   lever   RMB toggles it; on, it drives 15.
##   lamp    lit while anything beside it is above 0.
##
## Rules run in a TICK at 10 Hz (with the water), only when something changed:
## a placed or broken cable re-floods only the nets that touched it; a lever
## turned re-reads the levels. One tick from a lever to its lamp.
##
## Broken by LMB, a shot (`shot`), a blast (`blast`), or the ground going
## (`check`: the cell filled, or nothing under it) -- what breaks drops as an
## item in survival. Saved with the world's items (`to_save` / `restore`).
##
## A child of the mine world with no transform: positions are the terrain
## frame (plate cells: stud x plate x stud), as the chests'.

const TICK := 0.1
const LEVEL_MAX := 15
## How far up or down a cable reaches its neighbour: a brick.
const STEP := 3
## check()'s default box: everything (far from int overflow when grown).
const WHOLE := 1 << 30
## A device is one stud by a brick.
const DEVICE_PLATES := 3
## What each device does.
const DEVICES := {&"lever": {"drives": true}, &"lamp": {"reads": true}}
const SIDES: Array[Vector3i] = [Vector3i(1, 0, 0), Vector3i(-1, 0, 0), Vector3i(0, 0, 1), Vector3i(0, 0, -1)]

const COL_TILE := Color(0.24, 0.25, 0.27)
const COL_OFF := Color(0.42, 0.24, 0.13, 0.0)
const COL_ON := Color(1.0, 0.32, 0.12, 1.0)

var host: Node = null
var drops: DroppedItems = null
## Survival: what breaks drops. Creative (default) drops nothing.
var survival := false
## Is plate cell (x, y, z) solid ground? BrickTerrain's by default; a probe
## gives its own.
var solid_fn: Callable = func(x: int, y: int, z: int) -> int: return BrickTerrain.solid_at(x, y, z)

## cell -> true: a cable tile there.
var cables := {}
## bottom cell -> {"item": StringName, "on": bool, "lit": bool, "node": Node3D}
var devices := {}
## cable cell -> net id; net id -> {"cells": Array[Vector3i], "level": int}.
var net_of := {}
var nets := {}
var _next_net := 1

var _changed_cells: Array[Vector3i] = []
var _logic_dirty := false
var _draw_dirty := false
var _clock := 0.0
## Ticks run (probes), cells flooded by the last rebuild.
var ticks := 0
var last_flooded := 0

var _stud := 0.35
var _plate := 0.14
var _tiles_mi: MultiMeshInstance3D = null
var _cable_mi: MultiMeshInstance3D = null


func setup(p_host: Node, p_drops: DroppedItems) -> void:
	host = p_host
	drops = p_drops
	_stud = BrickWorld.get_stud_metres()
	_plate = BrickWorld.get_plate_metres()
	_make_draw()


func _ready() -> void:
	if _tiles_mi == null:
		_stud = BrickWorld.get_stud_metres()
		_plate = BrickWorld.get_plate_metres()
		_make_draw()


func _process(delta: float) -> void:
	_clock += delta
	if _clock < TICK:
		return
	_clock = fmod(_clock, TICK)
	tick()


## One tick: nets rebuilt where cables changed, levels read again, drawn.
func tick() -> void:
	ticks += 1
	if not _changed_cells.is_empty():
		_rebuild(_changed_cells)
		_changed_cells.clear()
		_logic_dirty = true
		_draw_dirty = true
	if _logic_dirty:
		_logic_dirty = false
		_evaluate()
	if _draw_dirty:
		_draw_dirty = false
		_redraw()


static func key_of(c: Vector3i) -> String:
	return "%d,%d,%d" % [c.x, c.y, c.z]


static func is_device(item: StringName) -> bool:
	return DEVICES.has(item)


func cell_of(p: Vector3) -> Vector3i:
	return Vector3i(floori(p.x / _stud), floori(p.y / _plate), floori(p.z / _stud))


func cable_box(c: Vector3i) -> AABB:
	return AABB(Vector3(c.x * _stud, c.y * _plate, c.z * _stud), Vector3(_stud, _plate, _stud))


func device_box(c: Vector3i) -> AABB:
	return AABB(Vector3(c.x * _stud, c.y * _plate, c.z * _stud), Vector3(_stud, DEVICE_PLATES * _plate, _stud))


func _solid(c: Vector3i) -> bool:
	return int(solid_fn.call(c.x, c.y, c.z)) != 0


## The device whose box holds plate cell `c`, as its bottom cell, or null.
func _device_at(c: Vector3i):
	for dy in DEVICE_PLATES:
		var b := c - Vector3i(0, dy, 0)
		if devices.has(b):
			return b
	return null


# ---------------------------------------------------------------------------
# Placing and breaking

## Would a cable fit at `c`: air, ground under it, nothing there.
func can_place_cable(c: Vector3i) -> bool:
	return not cables.has(c) and _device_at(c) == null and not _solid(c) and _solid(c + Vector3i.DOWN)


func place_cable(c: Vector3i, force := false) -> bool:
	if not force and not can_place_cable(c):
		return false
	cables[c] = true
	_changed_cells.append(c)
	_changed()
	return true


func can_place_device(c: Vector3i) -> bool:
	if not _solid(c + Vector3i.DOWN):
		return false
	for dy in DEVICE_PLATES:
		var k := c + Vector3i(0, dy, 0)
		if _solid(k) or cables.has(k) or _device_at(k) != null:
			return false
	return true


func place_device(c: Vector3i, item: StringName, on := false, force := false) -> bool:
	if not is_device(item) or (not force and not can_place_device(c)):
		return false
	var node := _device_node(c, item)
	add_child(node)
	devices[c] = {"item": item, "on": on, "lit": false, "node": node}
	_show_device(c)
	_logic_dirty = true
	_changed()
	return true


## RMB on a device: a lever turns. True if it did something.
func use_device(c: Vector3i) -> bool:
	if not devices.has(c) or not bool(DEVICES[devices[c].item].get("drives", false)):
		return false
	devices[c].on = not bool(devices[c].on)
	_show_device(c)
	_logic_dirty = true
	_changed()
	return true


func remove_cable(c: Vector3i, drop := true) -> bool:
	if not cables.has(c):
		return false
	cables.erase(c)
	_changed_cells.append(c)
	if drop:
		_drop(&"cable", cable_box(c).get_center())
	_changed()
	return true


func remove_device(c: Vector3i, drop := true) -> bool:
	if not devices.has(c):
		return false
	var d: Dictionary = devices[c]
	devices.erase(c)
	if is_instance_valid(d.node):
		(d.node as Node).queue_free()
	if drop:
		_drop(d.item, device_box(c).get_center())
	_logic_dirty = true
	_changed()
	return true


func _drop(item: StringName, at: Vector3) -> void:
	var surv := survival
	if host != null and "survival" in host:
		surv = bool(host.survival)
	if not surv or drops == null:
		return
	drops.spawn(ItemStack.make(item, 1), at, Vector3(randf_range(-0.8, 0.8), 2.5, randf_range(-0.8, 0.8)))


## Does a device stand in `box` (terrain frame)? A block is not put there.
func overlaps(box: AABB) -> bool:
	for c in devices:
		if device_box(c).grow(-0.01).intersects(box):
			return true
	return false


## The nearest device along a ray (terrain frame) within `reach`:
## {cell, dist, point} or {}. Few devices: every box is tried, as the chests'.
func ray_device(from: Vector3, dir: Vector3, reach: float) -> Dictionary:
	var best := {}
	for c in devices:
		var hit = device_box(c).intersects_ray(from, dir)
		if hit == null:
			continue
		var d := from.distance_to(hit)
		if d <= reach and (best.is_empty() or d < best.dist):
			best = {"cell": c, "dist": d, "point": hit}
	return best


## A bullet reached `p` (terrain frame): a device or cable there breaks. A
## shot cuts a wire (Docs/MineWiring.md 3.1). True if something broke.
func shot(p: Vector3) -> bool:
	for c in devices:
		if device_box(c).grow(0.06).has_point(p):
			remove_device(c)
			return true
	# A cable has no collider: the bullet hits the ground under it, at the
	# cable's bottom face.
	for k in [cell_of(p), cell_of(p + Vector3(0, _plate * 0.4, 0))]:
		if cables.has(k) and cable_box(k).grow(0.04).has_point(p):
			remove_cable(k)
			return true
	return false


## A blast at `c` (terrain frame): everything within `radius` goes.
func blast(c: Vector3, radius: float) -> int:
	var n := 0
	for k in devices.keys():
		if device_box(k).get_center().distance_to(c) <= radius + 0.2:
			remove_device(k)
			n += 1
	var r2 := (radius + 0.2) * (radius + 0.2)
	for k in cables.keys():
		if cable_box(k).get_center().distance_squared_to(c) <= r2:
			remove_cable(k)
			n += 1
	return n


## The ground changed (inside `lo`..`hi`, plate cells, when given): a cable
## or device whose cell filled, or with nothing under it, breaks.
func check(lo := Vector3i(-WHOLE, -WHOLE, -WHOLE), hi := Vector3i(WHOLE, WHOLE, WHOLE)) -> int:
	var lo2 := lo - Vector3i(1, DEVICE_PLATES + 1, 1)
	var hi2 := hi + Vector3i(1, 1, 1)
	var gone := 0
	for c in cables.keys():
		if _inside(c, lo2, hi2) and (_solid(c) or not _solid(c + Vector3i.DOWN)):
			remove_cable(c)
			gone += 1
	for c in devices.keys():
		if not _inside(c, lo2, hi2):
			continue
		var bad := not _solid(c + Vector3i.DOWN)
		for dy in DEVICE_PLATES:
			bad = bad or _solid(c + Vector3i(0, dy, 0))
		if bad:
			remove_device(c)
			gone += 1
	return gone


static func _inside(c: Vector3i, lo: Vector3i, hi: Vector3i) -> bool:
	return c.x >= lo.x and c.y >= lo.y and c.z >= lo.z and c.x <= hi.x and c.y <= hi.y and c.z <= hi.z


func clear() -> void:
	for c in devices:
		if is_instance_valid(devices[c].node):
			(devices[c].node as Node).queue_free()
	devices.clear()
	cables.clear()
	net_of.clear()
	nets.clear()
	_changed_cells.clear()
	_draw_dirty = true
	_logic_dirty = true


func _changed() -> void:
	if host != null and host.has_method("world_items_changed"):
		host.world_items_changed()


# ---------------------------------------------------------------------------
# Nets

## The cables `c` joins: four sides, up to a brick up or down.
func links(c: Vector3i) -> Array[Vector3i]:
	var out: Array[Vector3i] = []
	for s in SIDES:
		for dy in range(-STEP, STEP + 1):
			var n := c + s + Vector3i(0, dy, 0)
			if cables.has(n):
				out.append(n)
	return out


## Only the nets the changed cells touched are flooded again.
func _rebuild(changed: Array[Vector3i]) -> void:
	var seeds := {}
	for c in changed:
		seeds[c] = true
		for s in SIDES:
			for dy in range(-STEP, STEP + 1):
				var n := c + s + Vector3i(0, dy, 0)
				if cables.has(n):
					seeds[n] = true
	var redo := {}
	for s in seeds:
		if net_of.has(s):
			var id: int = net_of[s]
			if nets.has(id):
				for c in nets[id].cells:
					redo[c] = true
				nets.erase(id)
		if cables.has(s):
			redo[s] = true
	for c in redo:
		net_of.erase(c)
	last_flooded = 0
	for c in redo:
		if not cables.has(c) or net_of.has(c):
			continue
		var id := _next_net
		_next_net += 1
		var cells: Array[Vector3i] = [c]
		net_of[c] = id
		var i := 0
		while i < cells.size():
			for n in links(cells[i]):
				if not net_of.has(n):
					net_of[n] = id
					cells.append(n)
			i += 1
		nets[id] = {"cells": cells, "level": 0}
		last_flooded += cells.size()


## The nets beside a device: cables at its four sides, a step up or down
## from its bottom.
func device_nets(c: Vector3i) -> Array:
	var out := []
	for s in SIDES:
		for dy in range(-STEP, STEP + 1):
			var n := c + s + Vector3i(0, dy, 0)
			if net_of.has(n) and not out.has(net_of[n]):
				out.append(net_of[n])
	return out


## The devices touching a device at its sides (their boxes overlap in height).
func device_neighbours(c: Vector3i) -> Array:
	var out := []
	for s in SIDES:
		for dy in range(-(DEVICE_PLATES - 1), DEVICE_PLATES):
			var n := c + s + Vector3i(0, dy, 0)
			if devices.has(n):
				out.append(n)
	return out


func _output(c: Vector3i) -> int:
	var d: Dictionary = devices[c]
	if bool(DEVICES[d.item].get("drives", false)) and bool(d.on):
		return LEVEL_MAX
	return 0


## Levels read again: each net the highest of its drivers, each reader lit
## by its nets or a driver beside it.
func _evaluate() -> void:
	for id in nets:
		nets[id].level = 0
	for c in devices:
		var out := _output(c)
		if out <= 0:
			continue
		for id in device_nets(c):
			nets[id].level = maxi(int(nets[id].level), out)
	for c in devices:
		var d: Dictionary = devices[c]
		if not bool(DEVICES[d.item].get("reads", false)):
			continue
		var lvl := 0
		for id in device_nets(c):
			lvl = maxi(lvl, int(nets[id].level))
		for n in device_neighbours(c):
			lvl = maxi(lvl, _output(n))
		var lit := lvl > 0
		if lit != bool(d.lit):
			d.lit = lit
			_show_device(c)
	_draw_dirty = true


## The level at a cable (0 if none), a lamp's state (probes, the readout).
func level_at(c: Vector3i) -> int:
	return int(nets[net_of[c]].level) if net_of.has(c) and nets.has(net_of[c]) else 0


func is_lit(c: Vector3i) -> bool:
	return devices.has(c) and bool(devices[c].lit)


# ---------------------------------------------------------------------------
# Drawing

const _SHADER := """
shader_type spatial;
varying vec4 tint;
void vertex() { tint = COLOR; }
void fragment() {
	ALBEDO = tint.rgb;
	ROUGHNESS = 0.45;
	EMISSION = tint.rgb * tint.a * 1.6;
}
"""


func _make_draw() -> void:
	var sh := Shader.new()
	sh.code = _SHADER
	var mat := ShaderMaterial.new()
	mat.shader = sh
	_tiles_mi = _multi("CableTiles", _box_mesh(Vector3(0.94, 0.86, 0.94)), mat)
	_cable_mi = _multi("Cables", _box_mesh(Vector3(1, 1, 1)), mat)


func _multi(n: String, mesh: Mesh, mat: Material) -> MultiMeshInstance3D:
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.use_colors = true
	mm.mesh = mesh
	var mi := MultiMeshInstance3D.new()
	mi.name = n
	mi.multimesh = mm
	mi.material_override = mat
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(mi)
	return mi


static func _box_mesh(size: Vector3) -> BoxMesh:
	var b := BoxMesh.new()
	b.size = size
	return b


## Every cable tile and its cable, from the CPU's own records (no renderer
## read-back). Rebuilt whole when anything changed: stage 1's counts are
## small; per terrain tile when big builds need it.
func _redraw() -> void:
	if _tiles_mi == null:
		return
	var tiles := _tiles_mi.multimesh
	var arms := _cable_mi.multimesh
	var tile_h := _plate * 0.86
	var cab_h := _plate * 0.22
	var cab_w := _stud * 0.26
	var parts: Array = []   # [Transform3D, Color]
	tiles.instance_count = cables.size()
	var i := 0
	for c in cables:
		var base := Vector3((c.x + 0.5) * _stud, c.y * _plate, (c.z + 0.5) * _stud)
		tiles.set_instance_transform(i, Transform3D(Basis.from_scale(Vector3(_stud, _plate, _stud)),
				base + Vector3(0, tile_h * 0.5, 0)))
		tiles.set_instance_color(i, COL_TILE)
		i += 1
		var col := COL_ON if level_at(c) > 0 else COL_OFF
		var top := base.y + tile_h + cab_h * 0.5
		parts.append([Transform3D(Basis.from_scale(Vector3(cab_w, cab_h, cab_w)), Vector3(base.x, top, base.z)), col])
		for s in SIDES:
			var linked := false
			for dy in range(-STEP, STEP + 1):
				if cables.has(c + s + Vector3i(0, dy, 0)):
					linked = true
			if not linked:
				continue
			var half := _stud * 0.5
			var len_x := half if s.x != 0 else cab_w
			var len_z := half if s.z != 0 else cab_w
			var mid := Vector3(base.x + s.x * half * 0.5, top, base.z + s.z * half * 0.5)
			parts.append([Transform3D(Basis.from_scale(Vector3(len_x, cab_h, len_z)), mid), col])
	arms.instance_count = parts.size()
	for k in parts.size():
		arms.set_instance_transform(k, parts[k][0])
		arms.set_instance_color(k, parts[k][1])


func _device_node(c: Vector3i, item: StringName) -> Node3D:
	var box := device_box(c)
	var root := Node3D.new()
	root.name = "%s_%s" % [String(item).capitalize(), key_of(c).replace(",", "_").replace("-", "m")]
	root.position = Vector3(box.get_center().x, box.position.y, box.get_center().z)
	match item:
		&"lever":
			var stone := _mat(Color(0.5, 0.5, 0.52), 0.6)
			_add_box(root, Vector3(_stud * 0.92, _plate, _stud * 0.92), Vector3(0, _plate * 0.5, 0), stone)
			var pivot := Node3D.new()
			pivot.name = "Arm"
			pivot.position = Vector3(0, _plate, 0)
			root.add_child(pivot)
			_add_box(pivot, Vector3(_stud * 0.16, _plate * 2.1, _stud * 0.16), Vector3(0, _plate * 1.05, 0),
					_mat(Color(0.45, 0.3, 0.16), 0.7))
			_add_box(pivot, Vector3(_stud * 0.3, _stud * 0.3, _stud * 0.3), Vector3(0, _plate * 2.1, 0),
					_mat(Color(0.75, 0.1, 0.08), 0.4))
		&"lamp":
			var body := StaticBody3D.new()
			body.collision_layer = Layers.WORLD
			body.collision_mask = 0
			var shape := CollisionShape3D.new()
			var bs := BoxShape3D.new()
			bs.size = box.size
			shape.shape = bs
			shape.position = Vector3(0, box.size.y * 0.5, 0)
			body.add_child(shape)
			root.add_child(body)
			var glass := _mat(Color(0.95, 0.85, 0.55), 0.2)
			glass.emission_enabled = true
			glass.emission = Color(1.0, 0.8, 0.45)
			glass.emission_energy_multiplier = 0.0
			var mi := _add_box(root, box.size * Vector3(0.96, 0.98, 0.96), Vector3(0, box.size.y * 0.49, 0), glass)
			mi.name = "Glass"
			var stud := MeshInstance3D.new()
			var cyl := CylinderMesh.new()
			cyl.top_radius = _stud * 0.3
			cyl.bottom_radius = _stud * 0.3
			cyl.height = _plate * 0.6
			stud.mesh = cyl
			stud.material_override = glass
			stud.position = Vector3(0, box.size.y + _plate * 0.3, 0)
			root.add_child(stud)
			var light := OmniLight3D.new()
			light.name = "Light"
			light.light_color = Color(1.0, 0.82, 0.55)
			light.omni_range = 4.5
			light.light_energy = 1.4
			light.shadow_enabled = false
			light.position = Vector3(0, box.size.y * 0.6, 0)
			light.visible = false
			root.add_child(light)
	return root


func _add_box(parent: Node3D, size: Vector3, at: Vector3, mat: Material) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	mi.mesh = _box_mesh(size)
	mi.material_override = mat
	mi.position = at
	parent.add_child(mi)
	return mi


static func _mat(col: Color, rough: float) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = col
	m.roughness = rough
	return m


## A device's look follows its state: the lever's arm leans, the lamp glows.
func _show_device(c: Vector3i) -> void:
	var d: Dictionary = devices[c]
	var node: Node3D = d.node
	if not is_instance_valid(node):
		return
	match d.item:
		&"lever":
			var arm := node.get_node_or_null("Arm") as Node3D
			if arm != null:
				arm.rotation = Vector3(deg_to_rad(40.0 if bool(d.on) else -40.0), 0, 0)
		&"lamp":
			var glass := node.get_node_or_null("Glass") as MeshInstance3D
			if glass != null:
				(glass.material_override as StandardMaterial3D).emission_energy_multiplier = 3.0 if bool(d.lit) else 0.0
			var light := node.get_node_or_null("Light") as OmniLight3D
			if light != null:
				light.visible = bool(d.lit)


# ---------------------------------------------------------------------------
# Saving

## {"cables": [x, y, z, ...], "devices": {"x,y,z": {"item", "on"}}}: JSON.
func to_save() -> Dictionary:
	var flat: Array = []
	for c in cables:
		flat.append_array([c.x, c.y, c.z])
	var devs := {}
	for c in devices:
		devs[key_of(c)] = {"item": String(devices[c].item), "on": bool(devices[c].on)}
	return {"cables": flat, "devices": devs}


func restore(saved) -> void:
	clear()
	if not (saved is Dictionary):
		return
	var flat = saved.get("cables", [])
	if flat is Array:
		for i in range(0, flat.size() - 2, 3):
			place_cable(Vector3i(int(flat[i]), int(flat[i + 1]), int(flat[i + 2])), true)
	var devs = saved.get("devices", {})
	if devs is Dictionary:
		for k in devs:
			var p := str(k).split(",")
			var e = devs[k]
			if p.size() != 3 or not (e is Dictionary):
				continue
			place_device(Vector3i(int(p[0]), int(p[1]), int(p[2])), StringName(str(e.get("item", ""))),
					bool(e.get("on", false)), true)
	tick()
