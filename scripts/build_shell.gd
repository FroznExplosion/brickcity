class_name BuildShell

## The cheap tier for a player creation. Docs/BuildMode.md §12, question 3.
##
## A generated tower's shell comes from its parameters -- footprint, courses,
## the vertical bands `TowerRecipe.layout()` walks -- and an arbitrary build has
## none of those. It has a **recipe**: a list of cells and parts, which is the
## truth layer for a build exactly as the parameters are for a tower. So the
## shell is a **voxelisation of that list**, at a resolution far coarser than a
## brick, with the faces between filled voxels culled away.
##
## Three things fall out of choosing the recipe as the source:
##
##   * **Damage is exact, not approximated.** A tower's shell cannot ask "is
##     block N dead" and takes a per-band segment mask instead (gate G1b). A
##     build's shell walks block ids, so it simply leaves the dead ones out. A
##     hole in the wall is a hole in the shell, in the right place.
##   * **It costs nothing to keep.** The recipe is already resident and never
##     LOD'd (Plan §4.2); the shell is derived from it and thrown away.
##   * **It is the same walk for one frame or six.** A rotated frame's blocks
##     are mapped into root ticks and dropped into the same voxel grid, so a
##     sideways panel reads as part of the silhouette rather than as a special
##     case.
##
## What it deliberately is NOT: a box. A player build is the one thing in the
## city somebody chose the shape of, and a box at 60 m throws that away.

const STUD := 0.35
const PLATE := 0.14

## Voxel size in (studs, plates, studs). Two studs and a course is the size of a
## brick face, which is the smallest thing worth drawing at shell range and is
## also exactly what the seam shader tiles.
const DETAIL := Vector3i(2, 3, 2)
## The far-far tier: four studs and three courses.
const COARSE := Vector3i(4, 9, 4)

## Same units the seam shader wants: a brick face, so a shell wall draws brick
## outlines rather than one outline around the whole wall.
const SEAM_UNIT := Vector2(2.0 * STUD, 3.0 * PLATE)


## Voxelise a recipe. Returns voxel coordinate -> colour | material << 8: the
## block's colour index and what it is made of, which together say how it is
## drawn (BrickWorld.get_material_colour).
##
## `dead` is one entry per frame: a Dictionary of block ids that are gone. Pass
## nothing for an intact build.
##
## `world` is needed only for the frame rotations -- a rotated frame's cells are
## its own, and the only authority on what rotation 17 means is the extension.
static func voxels(world: BrickWorld, recipe: BuildRecipe, dead: Array = [],
		step: Vector3i = DETAIL) -> Dictionary:
	var out := {}
	if recipe == null or recipe.is_empty():
		return out
	var t := BrickWorld.ticks_per_stud()
	var pt := BrickWorld.ticks_per_plate()
	var vs := Vector3i(step.x * t, step.y * pt, step.z * t)
	var bases := _frame_bases(world, recipe)
	var offsets := _frame_offsets(recipe)

	for i in recipe.size():
		var f: int = recipe.frame_of(i)
		if f < dead.size() and (dead[f] as Dictionary).has(i):
			continue
		var cell := recipe.cell_of(i)
		var size := BrickPalette.size_of(recipe.part_of(i))
		if size == Vector3i.ZERO:
			continue
		# The block's box in its OWN frame, in ticks.
		var lo := Vector3i(cell.x * t, cell.y * pt, cell.z * t)
		var hi := lo + Vector3i(size.x * t, size.y * pt, size.z * t)
		# Into root ticks. A signed permutation maps a box to a box, so the two
		# opposite corners are all that have to be carried across.
		var b: Basis = bases[f]
		var shift: Vector3i = offsets[f]
		var a: Vector3i = _rot(b, lo) + shift
		var c: Vector3i = _rot(b, hi) + shift
		var box_lo := Vector3i(mini(a.x, c.x), mini(a.y, c.y), mini(a.z, c.z))
		var box_hi := Vector3i(maxi(a.x, c.x), maxi(a.y, c.y), maxi(a.z, c.z))
		var colour := recipe.colour_of(i) | (recipe.material_of(i) << 8)
		for vy in range(_floor_div(box_lo.y, vs.y), _ceil_div(box_hi.y, vs.y)):
			for vz in range(_floor_div(box_lo.z, vs.z), _ceil_div(box_hi.z, vs.z)):
				for vx in range(_floor_div(box_lo.x, vs.x), _ceil_div(box_hi.x, vs.x)):
					var key := Vector3i(vx, vy, vz)
					if not out.has(key):
						out[key] = colour
	return out


## The surface arrays for a voxelisation: one quad per face that has no
## neighbour, which is the same rule the brick mesher follows and is what makes
## the result hollow.
static func build_arrays(world: BrickWorld, recipe: BuildRecipe, dead: Array = [],
		step: Vector3i = DETAIL) -> Array:
	var filled := voxels(world, recipe, dead, step)
	var verts := PackedVector3Array()
	var normals := PackedVector3Array()
	var colours := PackedColorArray()
	var uvs := PackedVector2Array()
	var uv2s := PackedVector2Array()
	var indices := PackedInt32Array()
	var s := Vector3(step.x * STUD, step.y * PLATE, step.z * STUD)

	for key in filled:
		var at: Vector3i = key
		var packed := int(filled[key])
		# Material in the alpha, as the brick mesher writes it, so the shell of
		# an oak build is oak from across the city too.
		var col := BrickWorld.get_material_colour(packed >> 8, packed & 255)
		var o := Vector3(at.x * s.x, at.y * s.y, at.z * s.z)
		# -X, +X, -Y, +Y, -Z, +Z
		if not filled.has(at + Vector3i(-1, 0, 0)):
			_quad(verts, normals, colours, uvs, uv2s, indices, col,
					o, o + Vector3(0, 0, s.z), o + Vector3(0, s.y, 0),
					o + Vector3(0, s.y, s.z), Vector3.LEFT, Vector2(s.z, s.y))
		if not filled.has(at + Vector3i(1, 0, 0)):
			var x := o + Vector3(s.x, 0, 0)
			_quad(verts, normals, colours, uvs, uv2s, indices, col,
					x + Vector3(0, 0, s.z), x, x + Vector3(0, s.y, s.z),
					x + Vector3(0, s.y, 0), Vector3.RIGHT, Vector2(s.z, s.y))
		if not filled.has(at + Vector3i(0, -1, 0)):
			_quad(verts, normals, colours, uvs, uv2s, indices, col,
					o + Vector3(0, 0, s.z), o, o + Vector3(s.x, 0, s.z),
					o + Vector3(s.x, 0, 0), Vector3.DOWN, Vector2(s.x, s.z))
		if not filled.has(at + Vector3i(0, 1, 0)):
			var y := o + Vector3(0, s.y, 0)
			_quad(verts, normals, colours, uvs, uv2s, indices, col,
					y, y + Vector3(0, 0, s.z), y + Vector3(s.x, 0, 0),
					y + Vector3(s.x, 0, s.z), Vector3.UP, Vector2(s.x, s.z))
		if not filled.has(at + Vector3i(0, 0, -1)):
			_quad(verts, normals, colours, uvs, uv2s, indices, col,
					o + Vector3(s.x, 0, 0), o, o + Vector3(s.x, s.y, 0),
					o + Vector3(0, s.y, 0), Vector3.FORWARD, Vector2(s.x, s.y))
		if not filled.has(at + Vector3i(0, 0, 1)):
			var z := o + Vector3(0, 0, s.z)
			_quad(verts, normals, colours, uvs, uv2s, indices, col,
					z, z + Vector3(s.x, 0, 0), z + Vector3(0, s.y, 0),
					z + Vector3(s.x, s.y, 0), Vector3.BACK, Vector2(s.x, s.y))

	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	arrays[Mesh.ARRAY_NORMAL] = normals
	arrays[Mesh.ARRAY_COLOR] = colours
	arrays[Mesh.ARRAY_TEX_UV] = uvs
	arrays[Mesh.ARRAY_TEX_UV2] = uv2s
	arrays[Mesh.ARRAY_INDEX] = indices
	return arrays


static func build_mesh(world: BrickWorld, recipe: BuildRecipe, dead: Array = [],
		coarse: bool = false) -> ArrayMesh:
	var mesh := ArrayMesh.new()
	var arrays := build_arrays(world, recipe, dead, COARSE if coarse else DETAIL)
	if (arrays[Mesh.ARRAY_VERTEX] as PackedVector3Array).is_empty():
		return mesh  # everything shot away: a mesh with no surface, not a crash
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	return mesh


## Collision for the cheap tier: the voxels merged into as few boxes as they go
## into, so that a build can be shot and stood on while it holds no bricks.
##
## Runs along X, then rows of equal runs along Z, one Y layer at a time -- the
## same greedy merge the face bake uses, and the reason a house is a few dozen
## boxes rather than a few hundred.
static func collision_boxes(world: BrickWorld, recipe: BuildRecipe, dead: Array = [],
		step: Vector3i = COARSE) -> Array:
	var filled := voxels(world, recipe, dead, step)
	var s := Vector3(step.x * STUD, step.y * PLATE, step.z * STUD)
	var used := {}
	var out := []
	var keys := filled.keys()
	keys.sort_custom(func(a: Vector3i, b: Vector3i) -> bool:
		if a.y != b.y:
			return a.y < b.y
		if a.z != b.z:
			return a.z < b.z
		return a.x < b.x)
	for key in keys:
		var at: Vector3i = key
		if used.has(at):
			continue
		var w := 1
		while filled.has(at + Vector3i(w, 0, 0)) and not used.has(at + Vector3i(w, 0, 0)):
			w += 1
		var d := 1
		while true:
			var whole := true
			for k in w:
				var probe := at + Vector3i(k, 0, d)
				if not filled.has(probe) or used.has(probe):
					whole = false
					break
			if not whole:
				break
			d += 1
		for dz in d:
			for dx in w:
				used[at + Vector3i(dx, 0, dz)] = true
		out.append({
			"pos": Vector3((float(at.x) + float(w) * 0.5) * s.x,
					(float(at.y) + 0.5) * s.y,
					(float(at.z) + float(d) * 0.5) * s.z),
			"size": Vector3(float(w) * s.x, s.y, float(d) * s.z),
		})
	return out


# ---------------------------------------------------------------------------

## One basis per frame. Frame 0 is the identity; the rest come from the
## extension, because the enumeration of the 24 rotations is its business.
static func _frame_bases(world: BrickWorld, recipe: BuildRecipe) -> Array:
	var out := [Basis()]
	if recipe.is_single_frame() or world == null:
		return out
	var probe := world.create_chunk(Vector3i.ZERO, Vector3i.ONE)
	for f in range(1, recipe.frame_count()):
		world.set_chunk_frame(probe, recipe.frame_rotation(f), Vector3i.ZERO)
		out.append(world.get_chunk_transform(probe).basis)
	world.release_chunk(probe)
	return out


static func _frame_offsets(recipe: BuildRecipe) -> Array:
	var out := [Vector3i.ZERO]
	for f in range(1, recipe.frame_count()):
		out.append(recipe.frame_ticks(f))
	return out


## A signed permutation applied to an integer vector, exactly. Rounding rather
## than truncating: the basis holds +-1 and 0 as floats.
static func _rot(b: Basis, v: Vector3i) -> Vector3i:
	var r: Vector3 = b * Vector3(v)
	return Vector3i(int(round(r.x)), int(round(r.y)), int(round(r.z)))


static func _floor_div(a: int, b: int) -> int:
	@warning_ignore("integer_division")
	var q: int = a / b
	return q if a >= 0 or a % b == 0 else q - 1


static func _ceil_div(a: int, b: int) -> int:
	return _floor_div(a + b - 1, b)


static func _quad(verts: PackedVector3Array, normals: PackedVector3Array,
		colours: PackedColorArray, uvs: PackedVector2Array, uv2s: PackedVector2Array,
		indices: PackedInt32Array, col: Color,
		a: Vector3, b: Vector3, c: Vector3, d: Vector3, n: Vector3, size: Vector2) -> void:
	var seam := Vector2(minf(SEAM_UNIT.x, size.x), minf(SEAM_UNIT.y, size.y))
	var v0 := verts.size()
	for p in [a, b, c, d]:
		verts.push_back(p)
		normals.push_back(n)
		colours.push_back(col)
		uv2s.push_back(seam)
	uvs.push_back(Vector2(0, 0))
	uvs.push_back(Vector2(size.x, 0))
	uvs.push_back(Vector2(0, size.y))
	uvs.push_back(Vector2(size.x, size.y))
	# Corners run a, b, c, d, split along b-c like the brick mesher so the seam
	# shader reads a course as one band -- but wound (a,c,b) and (b,c,d). The
	# other way round, every face pointed INTO the build: back-face culling hid
	# each outside wall and drew the inside of the far one, so a placed build
	# looked hollow and inside-out until it was damaged and drew real bricks.
	for i in [0, 2, 1, 1, 2, 3]:
		indices.push_back(v0 + i)
