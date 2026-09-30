class_name ImpostorLod
extends Node3D

## Many copies of one small thing -- a tree, an item, a gun on the ground --
## drawn in two draw calls an AREA however many there are
## (Docs/Impostors.md 3.3, 8).
##
##   near  the real mesh, instanced;
##   far   an octahedral impostor card (ImpostorBaker), instanced;
##   past `cull_range`, nothing.
##
## Each instance has a transform and a "wanted" flag its owner sets -- a tree
## that has been shot is drawn by its own bricks, not by this. `update` sorts
## the wanted ones into near and far by distance and repacks only the areas
## where something changed tier; a hidden instance is in no buffer, so it
## costs nothing on the GPU.
##
## AREAS. Copies are kept in CHUNK-metre squares, each with its own pair of
## MultiMeshes and true bounds, so a square behind the camera or out of every
## shadow cascade is culled whole -- one MultiMesh for a world of trees could
## never be. And a square wholly inside or outside a range is decided at once,
## so only the squares a range edge crosses pay a distance check per copy.
##
## Two sources. A MESH (a brick tree, RecipeMesh) is drawn near by this node.
## A NODE (an assembled gun with its own materials) is baked the same way but
## drawn near by its OWNER: `tier_of` says 1 while the owner should show it,
## 2 while the card stands in, 0 when neither.
##
## The bake is asynchronous and needs a renderer. Until it lands (or with no
## renderer at all) the far tier draws the real mesh, so nothing is missing;
## a node source draws nothing far until then.

const CHUNK := 128.0

var near_range := 40.0
var cull_range := 3000.0
var hysteresis := 5.0

var mesh: Mesh
var source: Node3D
var material: Material
var bake := {}

var _xf: Array[Transform3D] = []
var _want := PackedByteArray()
var _tier := PackedByteArray()     ## 0 hidden, 1 near, 2 far
var _chunk_of: Array[Vector2i] = []
var _free: Array[int] = []
var _tile := 128
var _far_shadows := true
var _card_mat: ShaderMaterial = null
## The near mesh's material, with the band's fade in it (_fading).
var _near_mat: Material = null
## Shader -> its fading copy, so every set sharing a material shares one.
static var _fading_shaders := {}
var _quad: QuadMesh = null
## Vector2i -> {near: MMI, far: MMI, members: Array[int], dirty: bool}
var _chunks := {}
## Wind sway for the up-close copies (WeatherFx.sway_tree): (height, lean,
## Hz), 0 height for none. Set before the first add().
var sway := Vector3.ZERO
var near_count := 0
var far_count := 0


## `far_shadows` off for small things: a card a few pixels across throws a
## shadow nobody can see, and the cascades draw it again for each (7.2).
func setup(p_mesh: Mesh, p_material: Material, p_near_range: float = 40.0,
		p_cull_range: float = 3000.0, far_shadows: bool = true, tile: int = 128) -> void:
	mesh = p_mesh
	material = p_material
	near_range = p_near_range
	cull_range = p_cull_range
	_far_shadows = far_shadows
	_tile = tile
	_near_mat = _fading(material, near_range, hysteresis)
	WeatherFx.adopt(_near_mat, material)
	_bake_later()


## The same, for a node its owner draws up close (see the class notes).
func setup_node(p_source: Node3D, p_near_range: float = 12.0,
		p_cull_range: float = 150.0, far_shadows: bool = false, tile: int = 64) -> void:
	source = p_source
	near_range = p_near_range
	cull_range = p_cull_range
	_far_shadows = far_shadows
	_tile = tile
	_bake_later()


func _bake_later() -> void:
	# A frame first, so the host is in the tree.
	await get_tree().process_frame
	var what: Variant = source
	if mesh != null:
		what = mesh
	var got: Dictionary = await ImpostorBaker.bake(self, what, ImpostorBaker.GRID, _tile)
	if got.is_empty() or not is_instance_valid(self):
		return
	bake = got
	_quad = QuadMesh.new()
	_quad.size = Vector2.ONE
	_card_mat = ShaderMaterial.new()
	_card_mat.shader = load("res://shaders/impostor.gdshader")
	WeatherFx.adopt(_card_mat, material)
	_card_mat.set_shader_parameter("albedo_atlas", got.albedo)
	_card_mat.set_shader_parameter("normal_atlas", got.normal)
	_card_mat.set_shader_parameter("grid", float(got.grid))
	_card_mat.set_shader_parameter("radius", float(got.radius))
	_card_mat.set_shader_parameter("centre", got.centre)
	# The band a mesh copy fades into its card over (shaders/impostor.gdshader);
	# a node source's owner has no fade, so it has none.
	_card_mat.set_shader_parameter("lod_near", near_range if mesh != null else -1.0)
	_card_mat.set_shader_parameter("lod_band", hysteresis)
	for key in _chunks:
		_dress_far(_chunks[key])
		_chunks[key].dirty = true
	# A node source's copies can take their far tier now: re-sort them all.
	if mesh == null:
		for i in _tier.size():
			if _tier[i] == 1:
				_tier[i] = 0


func _chunk(key: Vector2i) -> Dictionary:
	if _chunks.has(key):
		return _chunks[key]
	var c := {"near": null, "far": null, "members": [], "dirty": true}
	if mesh != null:
		c.near = _make_mmi(mesh, _near_mat)
		if sway.x > 0.0:
			(c.near as MultiMeshInstance3D).set_instance_shader_parameter("weather_sway", sway)
		add_child(c.near)
	var far_mesh: Mesh = mesh
	c.far = _make_mmi(far_mesh, material)
	if not _far_shadows:
		(c.far as MultiMeshInstance3D).cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(c.far)
	_chunks[key] = c
	if _card_mat != null:
		_dress_far(c)
	return c


## Cards for a square's far tier, with bounds that cover them: a card is built
## in the shader round each object's centre, so the quad's own say nothing.
func _dress_far(c: Dictionary) -> void:
	var far: MultiMeshInstance3D = c.far
	far.multimesh.mesh = _quad
	far.material_override = _card_mat


static func _make_mmi(m: Mesh, mat: Material) -> MultiMeshInstance3D:
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.mesh = m
	var mmi := MultiMeshInstance3D.new()
	# NOT interpolated. The project has physics interpolation on, and an
	# interpolated MultiMesh blends each SLOT from its last transform to its
	# new one. A repack puts different copies in the same slots, so for a
	# frame every slot slid from one tree towards another: trees flickering
	# and moving whenever the player moved, right beside them too. These
	# copies never move by themselves; nothing here wants interpolating.
	mmi.physics_interpolation_mode = Node.PHYSICS_INTERPOLATION_MODE_OFF
	mmi.multimesh = mm
	if mat != null:
		mmi.material_override = mat
	return mmi


static func _key(p: Vector3) -> Vector2i:
	return Vector2i(floori(p.x / CHUNK), floori(p.z / CHUNK))


## A new copy. Returns its handle, which stays its own until `remove`.
func add(xf: Transform3D, wanted: bool = true) -> int:
	var h: int
	if not _free.is_empty():
		h = _free.pop_back()
		_xf[h] = xf
		_want[h] = 1 if wanted else 0
		_tier[h] = 0
		_chunk_of[h] = _key(xf.origin)
	else:
		h = _xf.size()
		_xf.append(xf)
		_want.append(1 if wanted else 0)
		_tier.append(0)
		_chunk_of.append(_key(xf.origin))
	var c := _chunk(_chunk_of[h])
	(c.members as Array).append(h)
	c.dirty = true
	return h


## Moved (an item kicked across the floor), into another square if need be.
func move(handle: int, xf: Transform3D) -> void:
	if handle < 0 or handle >= _xf.size():
		return
	_xf[handle] = xf
	var k := _key(xf.origin)
	var old: Dictionary = _chunks[_chunk_of[handle]]
	if k != _chunk_of[handle]:
		(old.members as Array).erase(handle)
		old.dirty = true
		_chunk_of[handle] = k
		var c := _chunk(k)
		(c.members as Array).append(handle)
		c.dirty = true
	elif _tier[handle] != 0:
		old.dirty = true


## Gone for good (picked up, destroyed). Its handle is reused.
func remove(handle: int) -> void:
	if handle < 0 or handle >= _xf.size() or _free.has(handle):
		return
	_want[handle] = 0
	var c: Dictionary = _chunks[_chunk_of[handle]]
	(c.members as Array).erase(handle)
	c.dirty = true
	_tier[handle] = 0
	_free.append(handle)


func count() -> int:
	return _xf.size() - _free.size()


func chunk_count() -> int:
	return _chunks.size()


func set_wanted(handle: int, on: bool) -> void:
	if handle < 0 or handle >= _want.size():
		return
	var v := 1 if on else 0
	if _want[handle] != v:
		_want[handle] = v
		(_chunks[_chunk_of[handle]] as Dictionary).dirty = true


func is_drawn(handle: int) -> bool:
	return handle >= 0 and handle < _tier.size() and _tier[handle] != 0


func tier_of(handle: int) -> int:
	return _tier[handle] if handle >= 0 and handle < _tier.size() else 0


## Sort into tiers from `here`, and repack the squares where anything changed.
func update(here: Vector3) -> void:
	var here2 := Vector2(here.x, here.z)
	near_count = 0
	far_count = 0
	for key in _chunks:
		var c: Dictionary = _chunks[key]
		# The square's nearest and furthest points, flat: a whole square on
		# one side of a range edge is decided without looking inside it.
		var lo := Vector2(key) * CHUNK
		var nearest := here2.clamp(lo, lo + Vector2.ONE * CHUNK).distance_to(here2)
		var furthest := maxf(maxf(here2.distance_to(lo), here2.distance_to(lo + Vector2(CHUNK, 0))),
				maxf(here2.distance_to(lo + Vector2(0, CHUNK)), here2.distance_to(lo + Vector2.ONE * CHUNK)))
		var whole := -1
		if nearest > cull_range + CHUNK:
			whole = 0
		elif nearest > near_range + hysteresis + CHUNK * 0.1 and furthest < cull_range:
			whole = 2
		var changed: bool = c.dirty
		c.dirty = false
		# A node source has nothing to draw far until its bake lands: until
		# then its owner keeps drawing it at any range.
		var no_card := mesh == null and bake.is_empty()
		# A mesh copy crossing the band is drawn as BOTH, dithered into each
		# other (tier 3) -- once there is a card to cross into.
		var blend := mesh != null and _card_mat != null
		for h in c.members:
			var t := 0
			if _want[h] != 0:
				if whole >= 0:
					t = whole
				else:
					var d := _xf[h].origin.distance_to(here)
					if d > cull_range:
						t = 0
					elif blend:
						# The band is the fade itself: no hysteresis needed,
						# nothing pops at either edge of it.
						if d < near_range - hysteresis:
							t = 1
						elif d > near_range + hysteresis:
							t = 2
						else:
							t = 3
					elif _tier[h] == 1:
						t = 1 if d < near_range + hysteresis else 2
					else:
						t = 1 if d < near_range - hysteresis else 2
				if t == 2 and no_card:
					t = 1
			if t != _tier[h]:
				_tier[h] = t
				changed = true
		if changed:
			_repack(c)
		if c.near != null:
			near_count += (c.near as MultiMeshInstance3D).multimesh.visible_instance_count
		else:
			for h in c.members:
				if _tier[h] == 1 or _tier[h] == 3:
					near_count += 1
		far_count += (c.far as MultiMeshInstance3D).multimesh.visible_instance_count


func _repack(c: Dictionary) -> void:
	var near := PackedFloat32Array()
	var far := PackedFloat32Array()
	var box := AABB()
	var first := true
	for h in c.members:
		if _tier[h] == 0:
			continue
		var x := _xf[h]
		var row := PackedFloat32Array([x.basis.x.x, x.basis.y.x, x.basis.z.x, x.origin.x,
				x.basis.x.y, x.basis.y.y, x.basis.z.y, x.origin.y,
				x.basis.x.z, x.basis.y.z, x.basis.z.z, x.origin.z])
		if _tier[h] == 1 or _tier[h] == 3:
			near.append_array(row)
		if _tier[h] == 2 or _tier[h] == 3:
			far.append_array(row)
			box = AABB(x.origin, Vector3.ZERO) if first else box.expand(x.origin)
			first = false
	@warning_ignore("integer_division")
	var n_near := near.size() / 12
	@warning_ignore("integer_division")
	var n_far := far.size() / 12
	if c.near != null:
		_fill((c.near as MultiMeshInstance3D).multimesh, near, n_near)
	var far_mmi: MultiMeshInstance3D = c.far
	_fill(far_mmi.multimesh, far, n_far)
	if _card_mat != null and not first:
		# The cards' own bounds: every far copy's origin, grown by what a card
		# can reach round it (the bake's centre is inside that, radius beyond).
		var r: float = float(bake.radius) * 2.0 + (bake.centre as Vector3).length()
		far_mmi.custom_aabb = AABB(box.position - Vector3.ONE * r, box.size + Vector3.ONE * r * 2.0)


## A copy of `mat` whose shader fades the copy out over the band on the pixels
## the card fades in on (shaders/impostor.gdshader: the same interleaved-gradient
## noise, the same distance to the instance's origin). Injected at run time into
## a copy, so the shader it came from -- brick.gdshader, the build area's --
## is not touched. Only a ShaderMaterial can be given it; anything else is
## returned as it is and pops at the switch, as before.
static func _fading(mat: Material, near: float, band: float) -> Material:
	if not (mat is ShaderMaterial) or (mat as ShaderMaterial).shader == null:
		return mat
	var src: Shader = (mat as ShaderMaterial).shader
	var sh: Shader = _fading_shaders.get(src)
	if sh == null:
		var code := src.code
		var v := code.find("void vertex() {")
		var f := code.find("void fragment() {")
		if v < 0 or f < 0:
			return mat
		var head := ("\nuniform float lod_near = -1.0;\nuniform float lod_band = 5.0;\n"
				+ "varying float v_lod_d;\n"
				+ "float lod_ign(vec2 px) {\n"
				+ "    return fract(52.9829189 * fract(dot(px, vec2(0.06711056, 0.00583715))));\n}\n\n")
		var in_vertex := "\n    v_lod_d = distance(MODEL_MATRIX[3].xyz, CAMERA_POSITION_WORLD);"
		var in_fragment := ("\n    {\n"
				+ "        float lod_t = lod_near > 0.0 ? clamp((v_lod_d - (lod_near - lod_band)) / (2.0 * lod_band), 0.0, 1.0) : 0.0;\n"
				+ "        bool lod_gone = PROJECTION_MATRIX[3][3] < 0.5 && lod_ign(FRAGCOORD.xy) < lod_t;\n"
				+ "        ALPHA = lod_gone ? 0.0 : 1.0;\n"
				+ "        ALPHA_SCISSOR_THRESHOLD = 0.5;\n    }")
		# Fragment first: inserting at the vertex moves everything after it.
		code = code.insert(f + "void fragment() {".length(), in_fragment)
		code = code.insert(v + "void vertex() {".length(), in_vertex)
		code = code.insert(v, head)
		sh = Shader.new()
		sh.code = code
		_fading_shaders[src] = sh
	var out := (mat as ShaderMaterial).duplicate() as ShaderMaterial
	out.shader = sh
	out.set_shader_parameter("lod_near", near)
	out.set_shader_parameter("lod_band", band)
	return out


static func _fill(mm: MultiMesh, buf: PackedFloat32Array, n: int) -> void:
	if mm.instance_count < n or mm.instance_count > n * 4 + 64:
		mm.instance_count = maxi(n * 2, 16)
	var full := buf
	full.resize(mm.instance_count * 12)
	mm.buffer = full
	mm.visible_instance_count = n
