class_name BoatBuild
extends RefCounted
## A boat's hull as a build (Docs/Hulls.md 7, step 7): a keel of two plate
## layers crossed (so every plate is clicked to the next), sides of bricks round a
## tapered bow and a square stern, a closed deck over a sealed hold cut into
## watertight stretches by bulkheads, and a bulwark round the deck. The hold's dry air is what floats it (HullAir finds it
## as INSIDE air; Boat counts it in the displaced volume).
##
## The same result SpaceStation._prepare_generated takes from ShipBuild.make:
## {ok, why, recipe, seat, decks, stats}. +X is its bow, as a ship's is.

const KEEL_PLATES := 2
## Its sides below the deck, bricks (3 plates each).
const HOLD_BRICKS := 3
const DECK_PLATES := 2
const BULWARK_BRICKS := 1
## The last this many studs of its length taper to the bow.
const BOW := 12
## Walls across its hold, evenly along it: one more watertight stretch each.
const BULKHEADS := 3


## A boat `length` x `beam` studs. `seed` picks its colours.
static func make(seed: int, length := 40, beam := 14, bulkheads := BULKHEADS) -> Dictionary:
	var r := BuildRecipe.new()
	var rng := RandomNumberGenerator.new()
	rng.seed = hash("boat %d" % seed)
	var hull := 4 + rng.randi_range(0, 3)
	var deck := 2
	var trim := 15
	var keel := 0
	var y_hold := KEEL_PLATES
	var y_deck := y_hold + HOLD_BRICKS * 3
	var y_wall := y_deck + DECK_PLATES
	var hw := func(x: int) -> int:
		# Half its beam at row x: full aft, down to 1 at the bow.
		var into := x - (length - BOW)
		if into < 0:
			return beam / 2
		return maxi(1, int(round(lerpf(float(beam) / 2.0, 1.0, float(into) / float(BOW - 1)))))
	var inside := func(x: int, z: int) -> bool:
		var h: int = hw.call(x)
		var mid := beam / 2
		return x >= 0 and x < length and z >= mid - h and z < mid + h
	# The keel: two plate layers, the upper offset a stud so each 2x2 overlaps four.
	for layer in KEEL_PLATES:
		var off := layer
		for x in range(-1, length + 1, 2):
			for z in range(-1, beam + 1, 2):
				var cx := x + off
				var cz := z + off
				# A 2x2 where all four cells are in the hull, else 1x1 plates.
				var all := true
				for dx in 2:
					for dz in 2:
						all = all and inside.call(cx + dx, cz + dz)
				if all:
					r.add("plate_2x2", Vector3i(cx, layer, cz), keel)
				else:
					for dx in 2:
						for dz in 2:
							if inside.call(cx + dx, cz + dz):
								r.add("plate_1x1", Vector3i(cx + dx, layer, cz + dz), keel)
	# Its sides: the hull's rim, a stud thick, bricks up to the deck; the bulwark over it.
	for x in length:
		for z in beam:
			if not inside.call(x, z):
				continue
			var rim: bool = not inside.call(x - 1, z) or not inside.call(x + 1, z) \
					or not inside.call(x, z - 1) or not inside.call(x, z + 1)
			if not rim:
				continue
			for k in HOLD_BRICKS:
				r.add("brick_1x1", Vector3i(x, y_hold + k * 3, z), hull)
			for k in BULWARK_BRICKS:
				r.add("brick_1x1", Vector3i(x, y_wall + k * 3, z), trim)
	# Its bulkheads: walls across the hold, keel to deck, no door in them -- each
	# stretch of the hold is a room of its own to the air and the water (HullAir),
	# so one hole floods one stretch and the boat lists but floats.
	var walls: Array = []
	for k in bulkheads:
		@warning_ignore("integer_division")
		var x := length * (k + 1) / (bulkheads + 1)
		if x <= 1 or x >= length - 2 or walls.has(x):
			continue
		walls.append(x)
		for z in beam:
			var rim: bool = not inside.call(x - 1, z) or not inside.call(x + 1, z) \
					or not inside.call(x, z - 1) or not inside.call(x, z + 1)
			if not inside.call(x, z) or rim:
				continue
			for j in HOLD_BRICKS:
				r.add("brick_1x1", Vector3i(x, y_hold + j * 3, z), hull)
	# The deck: two plate layers over the hold, crossed as the keel's are, inside
	# the sides (it rests on their tops at its rim).
	for layer in DECK_PLATES:
		var y := y_deck + layer
		var off := layer
		for x in range(-1, length + 1, 2):
			for z in range(-1, beam + 1, 2):
				var cx := x + off
				var cz := z + off
				var all := true
				for dx in 2:
					for dz in 2:
						all = all and inside.call(cx + dx, cz + dz)
				if all:
					r.add("plate_2x2", Vector3i(cx, y, cz), deck)
				else:
					for dx in 2:
						for dz in 2:
							if inside.call(cx + dx, cz + dz):
								r.add("plate_1x1", Vector3i(cx + dx, y, cz + dz), deck)
	var n := r.size()
	var b: Array = r.bounds()
	var lo: Vector3i = b[0]
	var size: Vector3i = b[1]
	r.meta["sections"] = {"budget": n, "kind": "join", "size": n,
			"sections": [{"id": 0, "root": true, "bricks": n, "lo": [lo.x, lo.y, lo.z],
				"hi": [lo.x + size.x - 1, lo.y + size.y - 1, lo.z + size.z - 1]}],
			"joints": [], "of": [[0, n]]}
	r.meta["boat"] = {"length": length, "beam": beam, "deck_y": y_wall, "hold_y": y_hold,
			"bulkheads": walls}
	# On deck amidships: where its crew stands to begin with.
	var seat := Vector3i(length / 3, y_wall, beam / 2)
	return {"ok": true, "why": "", "recipe": r, "seat": seat, "decks": 1,
			"stats": {"modules": 1, "airlock": Vector3i(-1, -1, -1)}}
