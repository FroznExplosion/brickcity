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

var _stud := 0.35
var _plate := 0.14
var _meshes := {}
## key "crop:stage" -> MultiMeshInstance3D
var _mmis := {}
var _mat: StandardMaterial3D
## Instances drawn at the last rebuild (the gate reads it).
var drawn := 0


func setup() -> void:
	_stud = BrickWorld.get_stud_metres()
	_plate = BrickWorld.get_plate_metres()
	_mat = StandardMaterial3D.new()
	_mat.vertex_color_use_as_albedo = true
	_mat.roughness = 0.42
	_mat.specular_mode = BaseMaterial3D.SPECULAR_SCHLICK_GGX
	_mat.cull_mode = BaseMaterial3D.CULL_DISABLED      # the leaf plates are seen from both sides


func rebuild(plots: Dictionary, eye: Vector3) -> void:
	var by := {}
	var r2 := DRAW_M * DRAW_M
	for b in plots:
		var plot: Dictionary = plots[b]
		if plot.crop == &"":
			continue
		var at := Vector3((b.x * 2 + 1) * _stud, (b.y + 1) * _plate, (b.z * 2 + 1) * _stud)
		if Vector2(at.x - eye.x, at.z - eye.z).length_squared() > r2:
			continue
		var key := "%s:%d" % [plot.crop, plot.stage]
		if not by.has(key):
			by[key] = []
		# A quarter turn and a little size of its own, so a row is not stamped.
		var seed := int(plot.seed)
		var turn := Basis(Vector3.UP, (seed & 3) * PI * 0.5)
		var s := 0.92 + 0.16 * float((seed >> 4) & 255) / 255.0
		by[key].append(Transform3D(turn.scaled(Vector3(s, s, s)), at))
	drawn = 0
	for key in _mmis.keys():
		if not by.has(key):
			(_mmis[key] as MultiMeshInstance3D).multimesh.instance_count = 0
	for key in by:
		var mmi: MultiMeshInstance3D = _mmis.get(key)
		if mmi == null:
			var parts: PackedStringArray = key.split(":")
			var mesh := mesh_for(StringName(parts[0]), int(parts[1]))
			if mesh == null:
				continue
			mmi = MultiMeshInstance3D.new()
			mmi.name = "Crop_" + key.replace(":", "_")
			var mm := MultiMesh.new()
			mm.transform_format = MultiMesh.TRANSFORM_3D
			mm.mesh = mesh
			mmi.multimesh = mm
			mmi.material_override = _mat
			add_child(mmi)
			_mmis[key] = mmi
		var xs: Array = by[key]
		mmi.multimesh.instance_count = xs.size()
		for i in xs.size():
			mmi.multimesh.set_instance_transform(i, xs[i])
		drawn += xs.size()


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
	var k := float(stage) / float(maxi(last, 1))
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


func _box(st: SurfaceTool, c: Vector3, size: Vector3, col: Color) -> void:
	var h := size * 0.5
	var corners := [Vector3(-1, -1, -1), Vector3(1, -1, -1), Vector3(1, 1, -1), Vector3(-1, 1, -1),
			Vector3(-1, -1, 1), Vector3(1, -1, 1), Vector3(1, 1, 1), Vector3(-1, 1, 1)]
	var faces := [[0, 3, 2, 1], [4, 5, 6, 7], [0, 4, 7, 3], [1, 2, 6, 5], [3, 7, 6, 2], [0, 1, 5, 4]]
	st.set_color(col)
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
	st.set_color(col)
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
	st.set_color(col)
	# Both faces, so it reads from either side.
	_quad(st, c - side, c + side, tip + side * 0.4, tip - side * 0.4)
	_quad(st, c + side + t, c - side + t, tip - side * 0.4 + t, tip + side * 0.4 + t)
