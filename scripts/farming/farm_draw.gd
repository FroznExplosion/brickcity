class_name FarmDraw
extends Node3D
## The crops, drawn (Docs/MineFarming.md 10): each crop stage is a small model
## of brick parts -- round 1x1 bars for stalks, plates for leaves, round
## bricks for heads and fruit, studs on their tops -- made once per stage
## (`mesh_for`) and drawn as MultiMesh instances, one MultiMeshInstance3D per
## stage in use. No node per plant.
##
## A child of the mine world with no transform of its own: positions are the
## terrain frame (like MineChests). `rebuild(plots, eye)` lays the instances of
## the plots within DRAW_M of the eye; MineFarming calls it when a stage
## changed, a plot came or went, or the eye moved far.

const DRAW_M := 96.0
## Past DRAW_M a plot is a low patch in its crop's colour out to this far
## (Docs/MineFarming.md 22): a field does not vanish at 96 m.
const FAR_M := 512.0

var _stud := 0.35
var _plate := 0.14
var _meshes := {}
## key "crop:stage" -> MultiMeshInstance3D
var _mmis := {}
var _mat: Material
## The far patches: one MultiMesh of boxes, coloured per instance.
var _far: MultiMeshInstance3D
var _far_mat: Material
## Drawn with the mine world's sky light (crops in a cave as dark as the
## cave): each instance's levels in its custom data -- the plot's own cached
## sky and lamp light (Docs/MineFarming.md 22).
var sky_lit := false
## Instances drawn at the last rebuild (the gate reads them).
var drawn := 0
var far_drawn := 0


func setup(p_sky_lit := false) -> void:
	_stud = BrickWorld.get_stud_metres()
	_plate = BrickWorld.get_plate_metres()
	sky_lit = p_sky_lit
	if sky_lit:
		# The falling sand's sky-lit item shader: COLOR (the crop meshes'
		# vertex colours, the patches' instance colours) times its light.
		var m := MineSkyLit.sand_material().duplicate() as ShaderMaterial
		m.set_shader_parameter("roughness", 0.45)
		_mat = m
		_far_mat = m
	else:
		var std := StandardMaterial3D.new()
		std.vertex_color_use_as_albedo = true
		std.roughness = 0.42
		std.specular_mode = BaseMaterial3D.SPECULAR_SCHLICK_GGX
		std.cull_mode = BaseMaterial3D.CULL_DISABLED      # the leaf plates are seen from both sides
		_mat = std
		_far_mat = std
	_far = MultiMeshInstance3D.new()
	_far.name = "FarFields"
	var fm := MultiMesh.new()
	fm.transform_format = MultiMesh.TRANSFORM_3D
	fm.use_colors = true
	fm.use_custom_data = true
	var box := BoxMesh.new()
	box.size = Vector3.ONE
	fm.mesh = box
	_far.multimesh = fm
	_far.material_override = _far_mat
	_far.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(_far)


## A colour as the material wants it: the sky-lit item shader takes COLOR as
## linear (its own albedo is a source_color uniform), so sRGB colours are
## converted -- unconverted, the crops came out washed out (ripe carrots tan).
func _c(col: Color) -> Color:
	return col.srgb_to_linear() if sky_lit else col


## A plot's light for the sky-lit shader (custom data: r sky, g lamp, 0..1).
static func _light(plot: Dictionary) -> Color:
	return Color(clampf(float(plot.get("sky", 1.0)), 0.0, 1.0), clampf(float(plot.get("lamp", 0.0)), 0.0, 1.0), 0.0, 0.0)


func rebuild(plots: Dictionary, eye: Vector3) -> void:
	var by := {}
	var far: Array = []
	var r2 := DRAW_M * DRAW_M
	var f2 := FAR_M * FAR_M
	for b in plots:
		var plot: Dictionary = plots[b]
		if plot.crop == &"":
			continue
		var at := Vector3((b.x * 2 + 1) * _stud, (b.y + 1) * _plate, (b.z * 2 + 1) * _stud)
		var d2 := Vector2(at.x - eye.x, at.z - eye.z).length_squared()
		if d2 > f2:
			continue
		if str(plot.get("ground", "")) == "tree":
			# A fruit tree: the real tree draws itself (TerrainTrees); its
			# fruit is drawn in its leaves, near only.
			if d2 <= r2:
				_add_fruit(by, plot)
			continue
		if d2 > r2:
			far.append(plot)
			continue
		var giant := int(plot.get("giant", 0))
		if giant == 2:
			continue                 # drawn once, by its corner plot
		var key := "%s:%d" % [plot.crop, plot.stage]
		if giant == 1:
			key = "%s:giant" % plot.crop
			at += Vector3(_stud, 0, _stud)      # the middle of its four plots
		if not by.has(key):
			by[key] = []
		# A quarter turn and a little size of its own, so a row is not stamped.
		var seed := int(plot.seed)
		var turn := Basis(Vector3.UP, (seed & 3) * PI * 0.5)
		var s := 0.92 + 0.16 * float((seed >> 4) & 255) / 255.0
		by[key].append([Transform3D(turn.scaled(Vector3(s, s, s)), at), _light(plot)])
	drawn = 0
	for key in _mmis.keys():
		if not by.has(key):
			(_mmis[key] as MultiMeshInstance3D).multimesh.instance_count = 0
	for key in by:
		var mmi: MultiMeshInstance3D = _mmis.get(key)
		if mmi == null:
			var parts: PackedStringArray = key.split(":")
			var mesh: Mesh
			if parts[1] == "giant":
				mesh = giant_mesh(StringName(parts[0]))
			elif parts[1] == "fruit":
				mesh = fruit_mesh(StringName(parts[0]), int(parts[2]))
			else:
				mesh = mesh_for(StringName(parts[0]), int(parts[1]))
			if mesh == null:
				continue
			mmi = MultiMeshInstance3D.new()
			mmi.name = "Crop_" + key.replace(":", "_")
			var mm := MultiMesh.new()
			mm.transform_format = MultiMesh.TRANSFORM_3D
			mm.use_custom_data = true
			mm.mesh = mesh
			mmi.multimesh = mm
			mmi.material_override = _mat
			add_child(mmi)
			_mmis[key] = mmi
		var xs: Array = by[key]
		mmi.multimesh.instance_count = xs.size()
		for i in xs.size():
			mmi.multimesh.set_instance_transform(i, xs[i][0])
			mmi.multimesh.set_instance_custom_data(i, xs[i][1])
		drawn += xs.size()
	_rebuild_far(far)


## The far patches: a 2 x 2-stud box on each plot, as tall as its crop has
## grown (a plate to about two bricks), in its leaf colour turning to its ripe
## colour. The stage is the plot's own as last settled: a plot out of reach is
## not touched (settled when the player comes back), so a far field shows how
## it stood then.
func _rebuild_far(far: Array) -> void:
	var fm := _far.multimesh
	fm.instance_count = far.size()
	far_drawn = far.size()
	for i in far.size():
		var plot: Dictionary = far[i]
		var b: Vector3i = plot.b
		var crop := FarmCrops.get_crop(plot.crop)
		var last := maxi(int(crop.get("stages", 2)) - 1, 1)
		var k := clampf(float(plot.stage) / last, 0.0, 1.0)
		var h := lerpf(_plate, _plate * 3.0 * 2.0, k)
		var col: Color = (crop.get("leaf", Color(0.3, 0.6, 0.25)) as Color).lerp(
				crop.get("ripe", Color(0.85, 0.7, 0.3)) as Color, k * k)
		var at := Vector3((b.x * 2 + 1) * _stud, (b.y + 1) * _plate + h * 0.5, (b.z * 2 + 1) * _stud)
		fm.set_instance_transform(i, Transform3D(Basis.from_scale(Vector3(2.0 * _stud * 0.9, h, 2.0 * _stud * 0.9)), at))
		fm.set_instance_color(i, _c(col))
		fm.set_instance_custom_data(i, _light(plot))


# ---------------------------------------------------------------------------
# The models: brick parts round the plot's top middle (y up from the soil)

func mesh_for(crop_id: StringName, stage: int) -> Mesh:
	var key := "%s:%d" % [crop_id, stage]
	if _meshes.has(key):
		return _meshes[key]
	var crop := FarmCrops.get_crop(crop_id)
	if crop.is_empty():
		return null
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var last := int(crop.stages) - 1
	# A fruit tree is a sapling up to the stage its tree stands at.
	if int(crop.get("fruit_at", -1)) > 0:
		last = int(crop.fruit_at) - 1
	var k := clampf(float(stage) / float(maxi(last, 1)), 0.0, 1.0)
	var ripe := stage >= last
	var leaf: Color = crop.leaf
	var fruit: Color = crop.ripe
	var S := _stud
	var P := _plate
	match str(crop.shape):
		"grain":
			# Four stalks on the four studs, a head on each from half grown.
			var h := lerpf(P * 1.2, P * 3.0 * 2.6, k)
			var stalk := leaf.lerp(fruit, 0.85 if ripe else k * 0.35)
			for sx in [-0.5, 0.5]:
				for sz in [-0.5, 0.5]:
					var c := Vector3(sx * S, 0, sz * S)
					if stage == 0:
						_cyl(st, c, 0.09, P, leaf)
						continue
					_cyl(st, c, 0.035, h, stalk)
					_leaf(st, c + Vector3(0, h * 0.35, 0), Vector3(sx, 0, sz), h * 0.4, leaf)
					if k >= 0.5:
						_cyl(st, c + Vector3(0, h, 0), 0.07, h * 0.28, leaf.lerp(fruit, 1.0 if ripe else 0.4))
		"root":
			# A tuft of leaf plates, fuller as it grows; ripe, the root's top shows.
			var n := 2 + stage
			var h := lerpf(P * 1.5, P * 3.0 * 1.3, k)
			for i in n:
				var a := TAU * float(i) / n + 0.4
				var out := Vector3(cos(a), 0, sin(a))
				_leaf(st, Vector3(0, P * 0.5, 0) + out * S * 0.08, out, h, leaf.darkened(0.08 * (i % 2)))
			if ripe:
				_cyl(st, Vector3(0, -P * 0.2, 0), 0.13, P * 1.2, fruit)
				_stud_on(st, Vector3(0, P, 0), fruit)
		"legume":
			# A pole with leaf pairs up it; ripe, pods hang from it.
			var h := lerpf(P * 2.0, P * 3.0 * 2.2, k)
			_cyl(st, Vector3.ZERO, 0.04, h, leaf.darkened(0.25))
			var pairs := 1 + stage
			for i in pairs:
				var y := h * (0.25 + 0.7 * float(i) / maxf(pairs, 1.0))
				var a := float(i) * 1.7
				_leaf(st, Vector3(0, y, 0), Vector3(cos(a), 0, sin(a)), S * 0.7, leaf)
				_leaf(st, Vector3(0, y, 0), Vector3(-cos(a), 0, -sin(a)), S * 0.7, leaf)
				if ripe:
					_box(st, Vector3(cos(a) * S * 0.25, y - P * 0.8, sin(a) * S * 0.25),
							Vector3(0.05, P * 1.6, 0.05), fruit)
		"gourd":
			# Vine leaves spread over the plot; the fruit grows from stage 2,
			# green, then a round 2x2 brick in its colour when ripe.
			var leaves := 2 + stage
			for i in leaves:
				var a := TAU * float(i) / leaves
				var out := Vector3(cos(a), 0, sin(a))
				_box(st, out * S * lerpf(0.25, 0.75, k) + Vector3(0, P * 0.25, 0),
						Vector3(S * 0.55, P * 0.5, S * 0.55), leaf.darkened(0.06 * (i % 2)))
			if stage >= 2:
				var g := lerpf(0.3, 1.0, (k - 0.4) / 0.6)
				var col := leaf.lightened(0.15).lerp(fruit, 1.0 if ripe else 0.25)
				var r := S * 0.95 * g
				_cyl(st, Vector3(0, 0, 0), r, P * 3.0 * g, col, 16)
				if ripe:
					for sx in [-0.5, 0.5]:
						for sz in [-0.5, 0.5]:
							_stud_on(st, Vector3(sx * S, P * 3.0 * g, sz * S), col)
				_cyl(st, Vector3(0, P * 3.0 * g, 0), 0.04, P * 1.2, leaf.darkened(0.3))
		"bush":
			# A stack of leaf bricks, bigger each stage; ripe, berries on it.
			var w := lerpf(S * 0.5, S * 1.8, k)
			var h := lerpf(P * 2.0, P * 3.0 * 2.0, k)
			_box(st, Vector3(0, h * 0.35, 0), Vector3(w, h * 0.7, w), leaf)
			_box(st, Vector3(0, h * 0.85, 0), Vector3(w * 0.7, h * 0.3, w * 0.7), leaf.lightened(0.06))
			if w > S * 0.9:
				for sx in [-0.5, 0.5]:
					for sz in [-0.5, 0.5]:
						_stud_on(st, Vector3(sx * S * 0.7, h, sz * S * 0.7), leaf.lightened(0.06))
			if ripe:
				for i in 8:
					var a := TAU * float(i) / 8.0 + 0.3
					var y := h * (0.3 + 0.45 * float(i % 3) / 2.0)
					var c := Vector3(cos(a) * w * 0.5, y, sin(a) * w * 0.5)
					_cyl(st, c - Vector3(0, 0.03, 0), 0.06, 0.07, fruit)
		"vine":
			# A grape vine: a post, a cross bar, leaves along it; ripe, purple
			# bunches (round 1x1s stacked smaller downwards) hang under it.
			var h := lerpf(P * 2.0, P * 3.0 * 2.4, k)
			_cyl(st, Vector3.ZERO, 0.04, h, Color(0.45, 0.32, 0.2))
			if k >= 0.3:
				_box(st, Vector3(0, h - P * 0.25, 0), Vector3(S * 1.7, P * 0.5, 0.06), Color(0.45, 0.32, 0.2))
			var n := 2 + stage * 2
			for i in n:
				var x := lerpf(-S * 0.8, S * 0.8, float(i) / maxf(n - 1, 1)) * clampf(k * 1.5, 0.3, 1.0)
				_leaf(st, Vector3(x, h * 0.85, 0), Vector3(0.3 if i % 2 == 0 else -0.3, 0, 1.0 if i % 2 == 0 else -1.0),
						S * 0.55, leaf.darkened(0.07 * (i % 2)))
			if stage >= last - 1:
				var col := leaf.lightened(0.1).lerp(fruit, 1.0 if ripe else 0.2)
				for x in [-0.55, 0.0, 0.55]:
					for j in 3:
						var r := 0.06 * (1.0 - 0.22 * j)
						_cyl(st, Vector3(x * S, h - P * (1.2 + 0.9 * j), 0.04), r, P * 0.8, col, 8)
		"corn":
			# Two tall stalks with long leaves; ripe, a yellow cob on each.
			var h := lerpf(P * 2.0, P * 3.0 * 4.0, k)
			for sx in [-0.45, 0.45]:
				var c := Vector3(sx * S, 0, -sx * S * 0.6)
				_cyl(st, c, 0.045, h, leaf.darkened(0.1))
				for i in 1 + stage:
					var a: float = float(i) * 2.1 + sx
					_leaf(st, c + Vector3(0, h * (0.2 + 0.13 * i), 0), Vector3(cos(a), 0, sin(a)), S * 0.9, leaf)
				if stage >= 3:
					var cob := leaf.lerp(fruit, 1.0 if ripe else 0.2)
					_cyl(st, c + Vector3(0.06, h * 0.55, 0), 0.06, P * 1.6, cob)
				_cyl(st, c + Vector3(0, h, 0), 0.02, P * 1.0, fruit.darkened(0.3) if k > 0.6 else leaf)
		"head":
			# A cabbage: round plates stacked into a head, wider each stage.
			var r := lerpf(S * 0.2, S * 0.75, k)
			for i in 2 + stage:
				var w := r * (1.0 - 0.18 * i)
				_cyl(st, Vector3(0, P * 0.6 * i, 0), maxf(w, 0.04), P * 0.7,
						leaf.lerp(fruit, float(i) / (2.0 + stage)), 12)
			if ripe:
				_stud_on(st, Vector3(0, P * 0.6 * (2 + stage), 0), fruit)
		"cactus":
			# A green column of round bricks, arms from half grown, fruit on top.
			var h := lerpf(P * 2.0, P * 3.0 * 2.5, k)
			_cyl(st, Vector3.ZERO, lerpf(0.06, 0.13, k), h, leaf, 10)
			if k >= 0.5:
				for sx in [-1.0, 1.0]:
					var y: float = h * (0.35 + 0.15 * sx)
					_box(st, Vector3(sx * 0.13, y, 0), Vector3(0.14, 0.07, 0.07), leaf)
					_cyl(st, Vector3(sx * 0.2, y - 0.03, 0), 0.05, h * 0.3, leaf, 8)
			if ripe:
				for i in 3:
					var a := TAU * float(i) / 3.0
					_cyl(st, Vector3(cos(a) * 0.08, h, sin(a) * 0.08), 0.045, 0.06, fruit, 8)
		"sapling":
			# A thin trunk and a leaf block on it that grows each stage.
			var h := lerpf(P * 1.5, P * 3.0 * 2.0, k)
			_cyl(st, Vector3.ZERO, lerpf(0.025, 0.07, k), h, Color(0.42, 0.28, 0.15))
			var w := lerpf(S * 0.35, S * 1.3, k)
			_box(st, Vector3(0, h + w * 0.35, 0), Vector3(w, w * 0.7, w), leaf)
			if k > 0.4:
				_box(st, Vector3(0, h + w * 0.85, 0), Vector3(w * 0.6, w * 0.4, w * 0.6), leaf.lightened(0.08))
		_:
			_box(st, Vector3(0, P, 0), Vector3(S, P * 2.0, S), leaf)
	st.generate_normals()
	var mesh := st.commit()
	_meshes[key] = mesh
	return mesh


## A standing fruit tree's fruit (HandoffFarming.md 7.1): instanced at the
## tree's own placement (Trees.placement: its recipe rebased to its min
## corner, as TerrainTrees lays it), keyed "crop:fruit:stage". None at the
## bare stage (`fruit_at`).
func _add_fruit(by: Dictionary, plot: Dictionary) -> void:
	var crop := FarmCrops.get_crop(plot.crop)
	if crop.is_empty() or int(plot.stage) <= int(crop.get("fruit_at", 0)):
		return
	var key := "%s:fruit:%d" % [plot.crop, plot.stage]
	if not by.has(key):
		by[key] = []
	var b: Vector3i = plot.b
	var xf := Trees.placement(Vector3i(b.x * 2, b.y + 1, b.z * 2), int(crop.tree))
	by[key].append([xf, _light(plot)])


## Where fruit hangs on tree variant `v`, in its placed recipe's frame: under
## the canopy's wide layer of plates (round the trunk's plate, which hangs
## lower), and on the outer sides of its ragged layer of bricks -- read from
## the recipe itself, so fruit never floats where a brick was left out.
static var _fruit_spots := {}


static func fruit_spots(v: int) -> Array:
	if _fruit_spots.has(v):
		return _fruit_spots[v]
	var r := Trees.recipe(v)
	var o := r.origin()
	var size := BrickWorld.get_cell_size()
	var leaf_parts: Array = []
	var lo := Vector3i(1 << 20, 1 << 20, 1 << 20)
	var hi := -lo
	for i in r.size():
		if r.material_of(i) != Trees.LEAF:
			continue
		var c := r.cell_of(i) - o
		var ps := BuildRecipe.part_size(r.part_of(i))
		leaf_parts.append([c, ps])
		lo = Vector3i(mini(lo.x, c.x), mini(lo.y, c.y), mini(lo.z, c.z))
		hi = Vector3i(maxi(hi.x, c.x + ps.x), maxi(hi.y, c.y + ps.y), maxi(hi.z, c.z + ps.z))
	var spots: Array = []
	# 1. Under the wide plates (the second layer, one plate over the bottom).
	var y_under := (lo.y + 1) * size.y
	for e in leaf_parts:
		var c: Vector3i = e[0]
		var ps: Vector3i = e[1]
		if c.y != lo.y + 1:
			continue
		for x in range(c.x, c.x + ps.x):
			for z in range(c.z, c.z + ps.z):
				# Not over the bottom plate (it hangs a plate lower there).
				var inner := false
				for e2 in leaf_parts:
					var c2: Vector3i = e2[0]
					var p2: Vector3i = e2[1]
					if c2.y == lo.y and x >= c2.x and x < c2.x + p2.x and z >= c2.z and z < c2.z + p2.z:
						inner = true
				if not inner and (x + z) % 2 == 0:
					spots.append([Vector3((x + 0.5) * size.x, y_under, (z + 0.5) * size.z), Vector3.DOWN])
	# 2. The outer sides of the bricks (the third layer) on the canopy's rim.
	for e in leaf_parts:
		var c: Vector3i = e[0]
		var ps: Vector3i = e[1]
		if ps.y < 3:
			continue
		var ym := (c.y + ps.y * 0.5) * size.y
		var mid := Vector3((c.x + ps.x * 0.5) * size.x, ym, (c.z + ps.z * 0.5) * size.z)
		for d in [Vector3i(1, 0, 0), Vector3i(-1, 0, 0), Vector3i(0, 0, 1), Vector3i(0, 0, -1)]:
			# Its face on that side free (no leaf brick beside it).
			var nx := c.x + (ps.x if d.x > 0 else (-1 if d.x < 0 else 0))
			var nz := c.z + (ps.z if d.z > 0 else (-1 if d.z < 0 else 0))
			var covered := false
			for e2 in leaf_parts:
				var c2: Vector3i = e2[0]
				var p2: Vector3i = e2[1]
				if p2.y >= 3 and c2.y == c.y and nx >= c2.x and nx < c2.x + p2.x and nz >= c2.z and nz < c2.z + p2.z:
					covered = true
			if covered:
				continue
			var face := mid + Vector3(d.x * ps.x * 0.5 * size.x, 0, d.z * ps.z * 0.5 * size.z)
			spots.append([face, Vector3(d)])
	# A fixed share of them, so a tree is not a fruit wall (the same per variant).
	var out: Array = []
	for i in spots.size():
		if Trees._hash(v + 11, i, 7) < 0.55:
			out.append(spots[i])
	_fruit_spots[v] = out
	return out


## The fruit of `crop_id` at `stage` on its tree: small and green while it
## grows, round 1x1 bricks in its colour with a stud when ripe.
func fruit_mesh(crop_id: StringName, stage: int) -> Mesh:
	var key := "%s:fruit:%d" % [crop_id, stage]
	if _meshes.has(key):
		return _meshes[key]
	var crop := FarmCrops.get_crop(crop_id)
	if crop.is_empty():
		return null
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var last := int(crop.stages) - 1
	var fa := int(crop.get("fruit_at", 0))
	var k := clampf(float(stage - fa) / float(maxi(last - fa, 1)), 0.0, 1.0)
	var ripe := stage >= last
	var leaf: Color = crop.leaf
	var col := leaf.lightened(0.25).lerp(crop.ripe, 1.0 if ripe else 0.15)
	var r := _stud * lerpf(0.18, 0.42, k)
	var h := _plate * lerpf(1.0, 2.4, k)
	for sp in fruit_spots(int(crop.tree)):
		var p: Vector3 = sp[0]
		var d: Vector3 = sp[1]
		var base: Vector3
		if d == Vector3.DOWN:
			# Hanging: a short stem, the fruit under it.
			_cyl(st, p - Vector3(0, _plate * 0.6, 0), 0.012, _plate * 0.6, leaf.darkened(0.4), 4)
			base = p - Vector3(0, _plate * 0.6 + h, 0)
		else:
			# On a side: sitting against the leaves.
			base = p + d * r * 0.9 - Vector3(0, h * 0.5, 0)
		_cyl(st, base, r, h, col, 10)
		if ripe:
			_stud_on(st, base + Vector3(0, h, 0), col)
	st.generate_normals()
	var mesh := st.commit()
	_meshes[key] = mesh
	return mesh


## A giant (Docs/MineFarming.md 20): one big round brick of the crop's colour
## over its four plots, studs on top, a stem and leaves -- 4 x 4 studs.
func giant_mesh(crop_id: StringName) -> Mesh:
	var key := "%s:giant" % crop_id
	if _meshes.has(key):
		return _meshes[key]
	var crop := FarmCrops.get_crop(crop_id)
	if crop.is_empty():
		return null
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var S := _stud
	var P := _plate
	var col: Color = crop.ripe
	var h := P * 3.0 * 3.0
	_cyl(st, Vector3.ZERO, S * 1.9, h, col, 24)
	_cyl(st, Vector3(0, h * 0.3, 0), S * 1.95, P * 0.6, col.darkened(0.12), 24)
	for sx in [-1.5, -0.5, 0.5, 1.5]:
		for sz in [-1.5, -0.5, 0.5, 1.5]:
			if Vector2(sx, sz).length() < 1.9:
				_stud_on(st, Vector3(sx * S, h, sz * S), col)
	_cyl(st, Vector3(0, h, 0), 0.07, P * 2.0, (crop.leaf as Color).darkened(0.3), 8)
	for i in 4:
		var a := TAU * float(i) / 4.0 + 0.4
		_leaf(st, Vector3(0, h + P * 0.5, 0), Vector3(cos(a), 0, sin(a)), S * 1.4, crop.leaf)
	st.generate_normals()
	var mesh := st.commit()
	_meshes[key] = mesh
	return mesh


func _box(st: SurfaceTool, c: Vector3, size: Vector3, col: Color) -> void:
	var h := size * 0.5
	var corners := [Vector3(-1, -1, -1), Vector3(1, -1, -1), Vector3(1, 1, -1), Vector3(-1, 1, -1),
			Vector3(-1, -1, 1), Vector3(1, -1, 1), Vector3(1, 1, 1), Vector3(-1, 1, 1)]
	var faces := [[0, 3, 2, 1], [4, 5, 6, 7], [0, 4, 7, 3], [1, 2, 6, 5], [3, 7, 6, 2], [0, 1, 5, 4]]
	st.set_color(_c(col))
	for f in faces:
		var q: Array = []
		for i in f:
			q.append(c + (corners[i] as Vector3) * h)
		_quad(st, q[0], q[1], q[2], q[3])


## Corners given counter-clockwise seen from outside; Godot's front faces are
## clockwise, so they go in reversed.
func _quad(st: SurfaceTool, a: Vector3, b: Vector3, c: Vector3, d: Vector3) -> void:
	st.add_vertex(a)
	st.add_vertex(c)
	st.add_vertex(b)
	st.add_vertex(a)
	st.add_vertex(d)
	st.add_vertex(c)


## An upright cylinder standing on `base`, with a top cap.
func _cyl(st: SurfaceTool, base: Vector3, r: float, h: float, col: Color, seg := 8) -> void:
	st.set_color(_c(col))
	for i in seg:
		var a0 := TAU * float(i) / seg
		var a1 := TAU * float(i + 1) / seg
		var p0 := Vector3(cos(a0) * r, 0, sin(a0) * r)
		var p1 := Vector3(cos(a1) * r, 0, sin(a1) * r)
		var up := Vector3(0, h, 0)
		_quad(st, base + p0, base + p0 + up, base + p1 + up, base + p1)
		st.add_vertex(base + up)
		st.add_vertex(base + p0 + up)
		st.add_vertex(base + p1 + up)


## A stud (LEGO's: 0.6 of a stud across, a sixth of a brick tall) on a top.
func _stud_on(st: SurfaceTool, top: Vector3, col: Color) -> void:
	_cyl(st, top, _stud * 0.3, _plate * 0.55, col, 10)


## A leaf plate: a thin plate leaning out from `c` along `dir`, `len` long.
func _leaf(st: SurfaceTool, c: Vector3, dir: Vector3, length: float, col: Color) -> void:
	var d := Vector3(dir.x, 0, dir.z).normalized()
	if d == Vector3.ZERO:
		d = Vector3.RIGHT
	var side := d.cross(Vector3.UP).normalized() * _stud * 0.16
	var tip := c + d * length * 0.55 + Vector3(0, length * 0.75, 0)
	var t := Vector3(0, _plate * 0.12, 0)
	st.set_color(_c(col))
	# Both faces, so it reads from either side.
	_quad(st, c - side, c + side, tip + side * 0.4, tip - side * 0.4)
	_quad(st, c + side + t, c - side + t, tip - side * 0.4 + t, tip + side * 0.4 + t)
