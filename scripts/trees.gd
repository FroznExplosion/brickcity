class_name Trees

## Brick trees: what they are made of and where they stand (Docs/Impostors.md 8).
##
## A tree is a BuildRecipe, like a player build -- which is what makes it
## destructible like a mini building in the city: registered, shelled, shot,
## materialised, toppled into pieces by the same code as everything else.
##
##   trunk   round 2x2 bricks stacked up the middle, the staircase newel's part;
##   canopy  plates and bricks in greens, in overlapping layers so every piece
##           sits on the layer below and the whole of it bears down on the
##           trunk: compression, which the brick physics carries for free.
##           Plain structure, not INTERIOR -- interior blocks are drawn by the
##           furniture path, not the chunk mesher, and a canopy is not furniture.
##
## Where: `scatter` walks the heightfield on a jittered grid, in forests where a
## noise field says so, above the sea, most thickly on grass and dirt, off building pads and steep
## ground. Deterministic from the seed, so every scene that asks gets the same
## trees in the same places.

const VARIANTS := 4
## Filament indices (brick_grid.h's palette order).
const BROWN := 10
const CHOCOLATE := 27
const GREEN := 7
const DARK_GREEN := 34
const BRIGHT_GREEN := 35
const OLIVE := 37

const TRUNK_HEIGHTS := [7, 9, 11, 13]       ## round bricks, per variant
const TRUNK_COLOURS := [BROWN, CHOCOLATE, BROWN, CHOCOLATE]
const LEAF_COLOURS := [[GREEN, DARK_GREEN], [DARK_GREEN, OLIVE],
		[BRIGHT_GREEN, GREEN], [GREEN, OLIVE]]
const WIDE := [true, false, true, true]      ## an 8-stud canopy, or a 6-stud one

## Studs between candidate spots, and the share of them that grow a tree in a
## forest and in the open.
const SPACING := 14
const FOREST_CHANCE := 0.55
const OPEN_CHANCE := 0.05
## Share of spots kept by what the ground is made of (BrickTerrain's
## Material: 1 grass, 2 dirt, 3 sand, 4 stone).
const GROUND_DENSITY := {1: 1.0, 2: 1.0, 3: 0.25, 4: 0.5}
## Steepest ground a tree stands on: plates of rise under its trunk. One brick.
const MAX_STEP_PLATES := 3

const TRUNK_CORNER := Vector3i(3, 0, 3)

static var _recipes := {}


## The recipe of one variant. The trunk's corner is at TRUNK_CORNER; `trunk_offset`
## says where it is once the recipe is rebased to its min corner, which is how
## a placed build is laid out.
static func recipe(variant: int) -> BuildRecipe:
	variant = posmod(variant, VARIANTS)
	if _recipes.has(variant):
		return _recipes[variant]
	var r := BuildRecipe.new()
	r.name = "tree_%d" % variant
	r.kind = "item"
	r.meta = {"tree": variant, "impostor_key": "tree_%d" % variant}
	var trunk_h: int = TRUNK_HEIGHTS[variant]
	# Every cell from the min corner, as a placed build's are: the canopy
	# reaches three studs past the trunk, so the trunk's corner is at (3, 0, 3).
	var o := TRUNK_CORNER
	for k in trunk_h:
		r.add("round_2x2", o + Vector3i(0, k * 3, 0), TRUNK_COLOURS[variant])
	var y := trunk_h * 3
	var leaf: Array = LEAF_COLOURS[variant]
	var a: int = leaf[0]
	var b: int = leaf[1]
	var interior := BuildRecipe.Role.STRUCTURE
	# 1. A 4x4 plate on the trunk's top.
	r.add("plate_4x4", o + Vector3i(-1, y, -1), a, 0, interior)
	y += 1
	# 2. Four 4x4 plates round it, each overlapping it by 2x2: 8x8 of canopy.
	#    The narrow variant is nine 2x2 plates, 6x6, every one overlapping it.
	var wide: bool = WIDE[variant]
	if wide:
		for q in [Vector3i(-3, 0, -3), Vector3i(1, 0, -3), Vector3i(-3, 0, 1), Vector3i(1, 0, 1)]:
			r.add("plate_4x4", o + Vector3i(q.x, y, q.z), a, 0, interior)
	else:
		for px in [-2, 0, 2]:
			for pz in [-2, 0, 2]:
				r.add("plate_2x2", o + Vector3i(px, y, pz), a, 0, interior)
	y += 1
	# 3. Bricks over the plates, not every one, so the canopy is ragged. The
	#    four in the middle always, so the layers above have something to sit on.
	var lo := -3 if wide else -2
	var hi := 5 if wide else 4
	for x in range(lo, hi, 2):
		for z in range(lo, hi, 2):
			var middle := x >= -1 and x < 3 and z >= -1 and z < 3
			var keep := middle or _hash(variant, x, z) < 0.6
			if keep:
				r.add("brick_2x2", o + Vector3i(x, y, z), b if (x + z) % 4 == 0 else a, 0, interior)
	y += 3
	# 4. A 4x4 plate and a 2x2 brick on top: the crown.
	r.add("plate_4x4", o + Vector3i(-1, y, -1), b, 0, interior)
	y += 1
	r.add("brick_2x2", o + Vector3i(0, y, 0), a, 0, interior)
	_recipes[variant] = r
	return r


## Where the trunk's (0, 0, 0) corner is in a placed tree's frame, in cells.
static func trunk_offset(variant: int) -> Vector3i:
	return TRUNK_CORNER - recipe(variant).origin()


## Height of a variant, metres.
static func height_m(variant: int) -> float:
	var r := recipe(variant)
	var b: Array = r.bounds()
	return float((b[1] as Vector3i).y) * BrickWorld.get_plate_metres()


## Trees over `rect` (studs) of the heightfield, as
## [{"cell": Vector3i (trunk corner, studs and plates), "variant": int}].
## `max_trees` caps it; the grid is walked in a fixed order, so the cap keeps
## the same trees every time.
static func scatter(rect: Rect2i, world_seed: int, max_trees: int = 2000) -> Array:
	var out := []
	var noise := FastNoiseLite.new()
	noise.seed = world_seed ^ 0x7ee5
	noise.frequency = 0.004
	var sea_plate := int(floor(BrickWave.get_sea_level() / BrickWorld.get_plate_metres()))
	var x0 := int(ceil(float(rect.position.x) / SPACING)) * SPACING
	var z0 := int(ceil(float(rect.position.y) / SPACING)) * SPACING
	for gz in range(z0, rect.end.y, SPACING):
		for gx in range(x0, rect.end.x, SPACING):
			var forest := noise.get_noise_2d(gx, gz) > 0.0
			var chance := FOREST_CHANCE if forest else OPEN_CHANCE
			if _hash(world_seed, gx, gz) >= chance:
				continue
			# Jitter inside the cell, keeping a trunk clear of the next cell's.
			var x := gx + int(_hash(world_seed + 1, gx, gz) * (SPACING - 4))
			var z := gz + int(_hash(world_seed + 2, gx, gz) * (SPACING - 4))
			# Grass and dirt at full density, stone and sand thinner; never
			# dark stone or road. The worlds so far are mostly stone above the
			# water -- their grass is largely drowned seabed.
			var ground := BrickTerrain.material_at(x, z)
			var keep: float = GROUND_DENSITY.get(ground, 0.0)
			if keep <= 0.0 or _hash(world_seed + 4, gx, gz) >= keep:
				continue
			if BrickTerrain.pad_at(x, z) >= 0 or BrickTerrain.pad_at(x + 1, z + 1) >= 0:
				continue
			# The trunk's own 2x2: it stands on the highest of its four
			# columns, so it never sinks into one; at most a brick of step
			# under it, so it never visibly floats off one.
			var lo_p := 1 << 30
			var hi_p := -(1 << 30)
			for d in [Vector2i(0, 0), Vector2i(1, 0), Vector2i(0, 1), Vector2i(1, 1)]:
				var p := BrickTerrain.surface_plate(x + d.x, z + d.y)
				lo_p = mini(lo_p, p)
				hi_p = maxi(hi_p, p)
			if hi_p - lo_p > MAX_STEP_PLATES or lo_p <= sea_plate + 2:
				continue
			out.append({"cell": Vector3i(x, hi_p + 1, z),
					"variant": int(_hash(world_seed + 3, gx, gz) * VARIANTS) % VARIANTS})
			if out.size() >= max_trees:
				return out
	return out


## Where a tree's placed recipe (rebased to its min corner) goes so its trunk
## corner lands on `cell` -- a Transform3D for BuildingRegistry.register_build.
## `ground_m`, if given, is the height it stands at instead of the cell's: the
## ground that is DRAWN there, where that is a coarse tier (TerrainCoarse.height_at).
static func placement(cell: Vector3i, variant: int, ground_m: float = NAN) -> Transform3D:
	var off := trunk_offset(variant)
	var c := cell - off
	var size := BrickWorld.get_cell_size()
	var y := c.y * size.y if is_nan(ground_m) else ground_m - off.y * size.y
	return Transform3D(Basis(), Vector3(c.x * size.x, y, c.z * size.z))


static func _hash(s: int, x: int, z: int) -> float:
	var h := (s * 374761393 + x * 668265263 + z * 2147483647) & 0x7fffffff
	h = ((h ^ (h >> 13)) * 1274126177) & 0x7fffffff
	h = h ^ (h >> 16)
	return float(h & 0xffffff) / float(0x1000000)
