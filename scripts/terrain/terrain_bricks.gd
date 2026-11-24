class_name TerrainBricks
extends Node3D
## THE BRICK OVERLAY (Docs/BrickOverlay.md 3): real bricks laid over the flat
## ground near the camera. The flat mesh is drawn everywhere, whole; here the
## bricks within `range_m` of the eye and in its view are drawn over it as
## ONE MultiMesh of bevelled boxes (BrickNear.bevel_box_mesh, scaled to each
## brick, the 13 mm bevel taken off in the shader: terrain.gdshader with
## `#define TERRAIN_BOX`). Nothing is baked: the instances are moved and
## retinted.
##
## The bricks are the bakes' own lists (TerrainTile.overlay, every drawn
## surface tile and deep section); BrickTerrain.overlay_pick dedupes them (a
## brick across a tile edge is in both tiles' lists), keeps those in range and
## in a cone a margin wider than the view, nearest first, up to `max_bricks`,
## and writes the MultiMesh buffer. Picked again when the eye moves `move_m`,
## turns `turn_deg`, or a tile changes (TerrainTile.overlay_version). Main
## thread, CPU arrays only: nothing read back from the renderer.
##
## A child of the mine world, at its origin: the lists are in its terrain
## frame, so the origin shift moves this with everything else.
##
## A BROKEN BRICK GOES AT ONCE (Docs/BrickOverlay.md stage 6, MineWorld.md
## 21): a shot that hits a brick of the overlay hides it the same frame --
## `hide_at` moves its slot away (nothing is deleted: the pool's slots are
## only ever moved), the flat ground's faces of that brick fold to nothing in
## the shader (`overlay_holes`), and an inside-out box stands in for the
## hole's walls -- until the rebuilt tile that has the hole is drawn
## (`hole_wait`: the tiles' and sections' generations), then the hole is the
## ground's own.

## On for every scene with ground (TerrainStreamer.setup makes one); off,
## the old chamfered near tier as before (-- --old-chamfer).
static var overlay_default := not ("--old-chamfer" in OS.get_cmdline_user_args())

## How far round the eye bricks are laid (metres, to the brick's box).
@export var range_m := 12.0
## The most instances drawn; past it the farthest are left out (and `far_m`
## says how far the overlay reached).
@export var max_bricks := 6000
## Degrees added round the view's half diagonal: turning, the bricks coming
## into view are already there for a pick or two.
@export var cone_margin_deg := 18.0
## Pick again when the eye has moved this far, or turned this many degrees.
@export var move_m := 0.35
@export var turn_deg := 4.0

## The mine world (untyped: it holds this).
var world: Node3D = null
var enabled := true

## Counters, for the readout and the gate.
var count := 0
var inside := 0
var seen := 0
var far_m := 0.0
var fills := 0
var fill_ms := 0.0
var worst_fill_ms := 0.0
var lists := 0
## The last pick's buffer as uploaded (CPU side, for the gate).
var buffer := PackedFloat32Array()

var _mmi: MultiMeshInstance3D = null
var _mm: MultiMesh = null
var _mat: ShaderMaterial = null
var _ground: ShaderMaterial = null
var _cap := 0
var _eye_at := Vector3.INF
var _fwd_at := Vector3.ZERO
var _version := -1
var _sync_in := 0.0
var _params: Array[StringName] = []

const STRIDE := 20
const CAP_STEP := 512

## Holes shown at once, each {id, lo, hi, want (tile -> gen), deep (key ->
## gen), rect, at (msec), waiting (no field edit yet)}. The shader takes
## MAX_HOLES; past it the oldest still waits for its tile.
const MAX_HOLES := 8
## A hole whose shot found nothing (no edit) goes after this; any after this.
const HOLE_NO_EDIT_MS := 600
const HOLE_MAX_MS := 3000
var holes: Array = []
var hidden_total := 0
var _hole_id := 0
## The holes' stand-in walls: bevelled boxes seen from inside (TERRAIN_CAVITY).
var _cav_mm: MultiMesh = null

static var _box_shaders := {}
static var _cavity_shaders := {}


## The box shader seen from inside: front faces culled, normals turned in.
static func cavity_shader(sky_light: bool) -> Shader:
	if not _cavity_shaders.has(sky_light):
		var code: String = box_shader(sky_light).code
		var s := Shader.new()
		s.code = code.replace("cull_back", "cull_front").insert(code.find("\n") + 1, "#define TERRAIN_CAVITY\n")
		_cavity_shaders[sky_light] = s
	return _cavity_shaders[sky_light]


## terrain.gdshader with `#define TERRAIN_BOX` (and SKY_LIGHT when the
## ground has it), made once each.
static func box_shader(sky_light: bool) -> Shader:
	if not _box_shaders.has(sky_light):
		var code: String = (load("res://shaders/terrain.gdshader") as Shader).code
		var at := code.find("\n") + 1
		var s := Shader.new()
		s.code = code.insert(at, ("#define SKY_LIGHT\n" if sky_light else "") + "#define TERRAIN_BOX\n")
		_box_shaders[sky_light] = s
	return _box_shaders[sky_light]


## `ground`: the flat ground's material (TerrainTile.ground_material); the
## boxes draw with a copy of it, kept in step (`_sync`).
func setup(w: Node3D, ground: ShaderMaterial, sky_light: bool) -> void:
	world = w
	_ground = ground
	_mat = ground.duplicate() as ShaderMaterial
	_mat.shader = box_shader(sky_light)
	WeatherFx.register(_mat)
	for u in _mat.shader.get_shader_uniform_list():
		_params.append(StringName(u.name))
	_mm = MultiMesh.new()
	_mm.transform_format = MultiMesh.TRANSFORM_3D
	_mm.use_colors = true
	_mm.use_custom_data = true
	_mm.mesh = BrickNear.bevel_box_mesh()
	_mmi = MultiMeshInstance3D.new()
	_mmi.name = "Boxes"
	_mmi.multimesh = _mm
	_mmi.material_override = _mat
	# The ground casts no sun shadow in the mine world (mine_world.gd).
	_mmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_mmi.physics_interpolation_mode = Node.PHYSICS_INTERPOLATION_MODE_OFF
	add_child(_mmi)
	# The holes' stand-in walls: the hidden brick's box seen from inside, in
	# the ground's own look (terrain.gdshader TERRAIN_CAVITY), lit as its top.
	_cav_mm = MultiMesh.new()
	_cav_mm.transform_format = MultiMesh.TRANSFORM_3D
	_cav_mm.use_colors = true
	_cav_mm.use_custom_data = true
	_cav_mm.mesh = BrickNear.bevel_box_mesh()
	_cav_mm.instance_count = MAX_HOLES
	_cav_mm.visible_instance_count = 0
	var cav := MultiMeshInstance3D.new()
	cav.name = "Cavities"
	cav.multimesh = _cav_mm
	var cm := _mat.duplicate() as ShaderMaterial
	cm.shader = cavity_shader(sky_light)
	cav.material_override = cm
	cav.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	cav.physics_interpolation_mode = Node.PHYSICS_INTERPOLATION_MODE_OFF
	add_child(cav)


func set_enabled(on: bool) -> void:
	enabled = on
	if _mmi != null:
		_mmi.visible = on
	if not on and _ground != null:
		_ground.set_shader_parameter(&"overlay_reach", 0.0)
	_version = -1


## Pick again next frame whatever moved.
func refresh() -> void:
	_version = -1


func _process(delta: float) -> void:
	if world == null or _mm == null or not enabled:
		return
	# The camera drawing (a gate's own, or the walker's / the free one's).
	var cam := get_viewport().get_camera_3d()
	if cam == null:
		return
	_sync(delta)
	if not holes.is_empty():
		_release_holes()
	var eye: Vector3 = world.to_local(cam.global_position)
	var fwd: Vector3 = world.global_transform.basis.inverse() * -cam.global_transform.basis.z
	if _version == TerrainTile.overlay_version and eye.distance_to(_eye_at) < move_m \
			and fwd.dot(_fwd_at) > cos(deg_to_rad(turn_deg)):
		return
	fill(eye, fwd, cam)


## Pick and upload now.
func fill(eye: Vector3, fwd: Vector3, cam: Camera3D) -> void:
	var t0 := Time.get_ticks_usec()
	_version = TerrainTile.overlay_version
	_eye_at = eye
	_fwd_at = fwd
	var half := _half_view(cam) + deg_to_rad(cone_margin_deg)
	var tile_m := float(BrickTerrain.get_tile_studs()) * BrickWorld.get_stud_metres()
	var src: Array = []
	for t in TerrainTile.overlay_tiles.values():
		var tile := t as TerrainTile
		if tile == null or tile.overlay.is_empty() or not tile.is_visible_in_tree():
			continue
		# Its footprint (XZ) within reach of the eye.
		var o: Vector3 = world.to_local(tile.global_position)
		var dx := maxf(maxf(o.x - eye.x, eye.x - (o.x + tile_m)), 0.0)
		var dz := maxf(maxf(o.z - eye.z, eye.z - (o.z + tile_m)), 0.0)
		if dx * dx + dz * dz > range_m * range_m:
			continue
		src.append(tile.overlay)
	lists = src.size()
	var hid := PackedVector3Array()
	for h: Dictionary in holes:
		hid.append(h.lo)
		hid.append(h.hi)
	var r: Dictionary = BrickTerrain.overlay_pick(src, eye, fwd, range_m, cos(minf(half, PI)), max_bricks, hid)
	count = int(r.count)
	inside = int(r.inside)
	seen = int(r.seen)
	far_m = float(r.far_m)
	var buf: PackedFloat32Array = r.buffer
	if count > _cap or count < _cap - 4 * CAP_STEP:
		_cap = maxi(CAP_STEP, ceili(float(count) / CAP_STEP) * CAP_STEP)
		_mm.instance_count = 0
		_mm.use_colors = true
		_mm.use_custom_data = true
		_mm.instance_count = _cap
	if buf.size() < _cap * STRIDE:
		buf.resize(_cap * STRIDE)
	_mm.buffer = buf
	buffer = buf
	_mm.visible_instance_count = count
	# The flat ground sinks under the boxes as far as they reach from here,
	# less the walk before the next pick (terrain.gdshader overlay_reach).
	_ground.set_shader_parameter(&"overlay_reach", maxf(far_m - move_m, 0.0) if count > 0 else 0.0)
	fills += 1
	fill_ms = float(Time.get_ticks_usec() - t0) / 1000.0
	worst_fill_ms = maxf(worst_fill_ms, fill_ms)


## The view's half angle to its corner (radians).
func _half_view(cam: Camera3D) -> float:
	var size := get_viewport().get_visible_rect().size if get_viewport() != null else Vector2(16, 9)
	var aspect := size.x / maxf(size.y, 1.0)
	var tv := tan(deg_to_rad(cam.fov) * 0.5)
	var th := tv * aspect
	if cam.keep_aspect == Camera3D.KEEP_WIDTH:
		th = tv
		tv = th / aspect
	return atan(sqrt(tv * tv + th * th))


## The ground material's parameters copied over: the sun each frame, the rest
## once a second (the dev menu's toggles).
func _sync(delta: float) -> void:
	if _ground == null:
		return
	_mat.set_shader_parameter(&"sun_dir", _ground.get_shader_parameter(&"sun_dir"))
	_sync_in -= delta
	if _sync_in > 0.0:
		return
	_sync_in = 1.0
	for p in _params:
		if p == &"overlay_reach" or p == &"overlay_holes" or p == &"overlay_hole_lo" \
				or p == &"overlay_hole_hi":
			continue
		var v = _ground.get_shader_parameter(p)
		if v != null:
			_mat.set_shader_parameter(p, v)


func readout() -> String:
	return "overlay bricks %d of %d in reach (%d read, %d lists), to %.1f m, fill %.2f ms (worst %.2f)" \
			% [count, inside, seen, lists, far_m, fill_ms, worst_fill_ms]


# ---------------------------------------------------------------------------
# Broken bricks, hidden at once.

## The shot at `point` (terrain frame) going `dir`: the overlay brick it hit,
## hidden now. Returns the hole's id, or -1 (no brick of the overlay there).
func hide_at(point: Vector3, dir: Vector3) -> int:
	if not enabled or count == 0:
		return -1
	var q := point + dir.normalized() * 0.01
	for i in count:
		var k := i * STRIDE
		var size := Vector3(buffer[k], buffer[k + 5], buffer[k + 10])
		if size.x <= 0.0:
			continue
		var c := Vector3(buffer[k + 3], buffer[k + 7], buffer[k + 11])
		var lo := c - size * 0.5
		var hi := c + size * 0.5
		if q.x < lo.x or q.y < lo.y or q.z < lo.z or q.x > hi.x or q.y > hi.y or q.z > hi.z:
			continue
		# Its top's sky light, for the stand-in walls' shade.
		var top_sky := 0.0
		for corner in 4:
			var n := 8 + corner
			top_sky += float((int(buffer[k + 16 + int(n / 6.0)]) >> (4 * (n % 6))) & 15) / 4.0
		var slot := buffer.slice(k, k + STRIDE)
		_zero_slot(buffer, i)
		_mm.set_instance_transform(i, Transform3D(Basis().scaled(Vector3.ZERO), c))
		# A piece is a brick and the plate or tile laid on it (two boxes, one
		# footprint): a shot takes both.
		for j in count:
			var kj := j * STRIDE
			var sj := Vector3(buffer[kj], buffer[kj + 5], buffer[kj + 10])
			if sj.x <= 0.0:
				continue
			var cj := Vector3(buffer[kj + 3], buffer[kj + 7], buffer[kj + 11])
			var loj := cj - sj * 0.5
			var hij := cj + sj * 0.5
			if absf(loj.x - lo.x) > 1e-3 or absf(hij.x - hi.x) > 1e-3 or absf(loj.z - lo.z) > 1e-3 \
					or absf(hij.z - hi.z) > 1e-3:
				continue
			if absf(loj.y - hi.y) < 1e-3 or absf(hij.y - lo.y) < 1e-3:
				lo.y = minf(lo.y, loj.y)
				hi.y = maxf(hi.y, hij.y)
				_zero_slot(buffer, j)
				_mm.set_instance_transform(j, Transform3D(Basis().scaled(Vector3.ZERO), cj))
		_hole_id += 1
		holes.append({"id": _hole_id, "lo": lo, "hi": hi, "want": {}, "deep": {}, "rect": Rect2i(),
				"at": Time.get_ticks_msec(), "waiting": true, "slot": slot, "sky": top_sky})
		hidden_total += 1
		_push_holes()
		return _hole_id
	return -1


## The shot's edit landed: the hole shows till these tiles (Vector2i ->
## generation) and deep sections (Vector3i -> generation) are drawn at
## least at those generations, and `rect` (tiles) is no longer pending.
func hole_wait(id: int, want: Dictionary, deep: Dictionary, rect: Rect2i) -> void:
	for h: Dictionary in holes:
		if int(h.id) == id:
			h.want = want
			h.deep = deep
			h.rect = rect
			h.waiting = false


## The hole's box (terrain frame), or an empty AABB.
func hole_box(id: int) -> AABB:
	for h: Dictionary in holes:
		if int(h.id) == id:
			return AABB(h.lo, h.hi - h.lo)
	return AABB()


## The shot found nothing to clear: its brick comes back.
func drop_hole(id: int) -> void:
	for i in holes.size():
		if int(holes[i].id) == id:
			holes.remove_at(i)
			_push_holes()
			refresh()
			return


func _release_holes() -> void:
	var now := Time.get_ticks_msec()
	var streamer = world.get("_streamer")
	var deep = world.get("_deep")
	var gone := false
	var i := 0
	while i < holes.size():
		var h: Dictionary = holes[i]
		var age := now - int(h.at)
		var done := age > HOLE_MAX_MS or (bool(h.waiting) and age > HOLE_NO_EDIT_MS)
		if not done and not bool(h.waiting):
			done = true
			for c in h.want:
				if streamer == null or int(streamer.drawn_gen.get(c, -1)) < int(h.want[c]):
					done = false
			for k in h.deep:
				if deep == null or int(deep.drawn_gen.get(k, -1)) < int(h.deep[k]):
					done = false
			if done and h.rect.has_area() and world.has_method("tiles_fresh") \
					and not bool(world.call("tiles_fresh", h.rect)):
				done = false
		if done:
			holes.remove_at(i)
			gone = true
		else:
			i += 1
	if gone:
		_push_holes()
		refresh()


## The holes to the ground's shader (world space: the tiles' MODEL_MATRIX)
## and to the stand-in walls.
func _push_holes() -> void:
	var los := PackedVector3Array()
	var his := PackedVector3Array()
	var n := mini(holes.size(), MAX_HOLES)
	var cb := PackedFloat32Array()
	cb.resize(MAX_HOLES * STRIDE)
	for j in MAX_HOLES:
		if j < n:
			var h: Dictionary = holes[holes.size() - n + j]
			los.append(to_global(h.lo))
			his.append(to_global(h.hi))
			# The stand-in: the hole's box a millimetre in, its colour and
			# material, every face lit as the top (whole numbers, as packed).
			var sl: PackedFloat32Array = h.slot
			var size: Vector3 = (h.hi - h.lo) - Vector3(0.002, 0.002, 0.002)
			var mid: Vector3 = (h.lo + h.hi) * 0.5
			var lv := clampi(roundi(float(h.sky)), 0, 15)
			var blk := (int(sl[13]) >> 8) & 15
			var o := j * STRIDE
			var vals := [size.x, 0.0, 0.0, mid.x, 0.0, size.y, 0.0, mid.y, 0.0, 0.0, size.z, mid.z,
					sl[12], float(blk * 0x111111), 0.0, sl[15],
					float(lv * 0x111111), float(lv * 0x111111), float(lv * 0x111111), float(lv * 0x111111)]
			for q in STRIDE:
				cb[o + q] = vals[q]
		else:
			los.append(Vector3.ZERO)
			his.append(Vector3.ZERO)
	_cav_mm.buffer = cb
	# With behind faces baked (BrickTerrain.set_behind_faces) the hole's own
	# walls are already there: the stand-in, a millimetre inside them, would
	# cover them.
	_cav_mm.visible_instance_count = 0 if BrickTerrain.get_behind_faces() else n
	# The ground, and its studs (a hidden brick's studs go with it).
	for m: ShaderMaterial in [_ground, TerrainTile.sky_stud_material()]:
		if m == null:
			continue
		m.set_shader_parameter(&"overlay_holes", n)
		m.set_shader_parameter(&"overlay_hole_lo", los)
		m.set_shader_parameter(&"overlay_hole_hi", his)


static func _zero_slot(buf: PackedFloat32Array, i: int) -> void:
	var k := i * STRIDE
	buf[k] = 0.0
	buf[k + 5] = 0.0
	buf[k + 10] = 0.0
