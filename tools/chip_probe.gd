extends SceneTree

## Acceptance probe for guns against bricks: wear, not deletion.
##
##     godot --headless --path . --script tools/chip_probe.gd
##
## A bullet takes hp off a brick (BrickWorld.chip_hit); the brick dies at zero.
## The hp a brick has lost is state like any other, so it has to survive
## everything a brick survives -- the building being let go of and rebuilt, the
## piece going to sleep, the piece breaking in two, a replay of the log -- or a
## wall takes a different number of shots to break on two machines.
## StructuralDamage decides the numbers; this checks it decides them the same
## way at every tier.

var _pass := 0
var _fail := 0


func _init() -> void:
	print("chip probe")
	_check_wear()
	_check_rebuild()
	_check_record()
	_check_split()
	_check_replay()
	_check_mapping()
	print("\n%d passed, %d failed" % [_pass, _fail])
	quit(1 if _fail > 0 else 0)


func _ok(what: String, cond: bool, detail: String = "") -> void:
	if cond:
		_pass += 1
		print("  ok   %s%s" % [what, ("  " + detail) if detail else ""])
	else:
		_fail += 1
		print("  FAIL %s%s" % [what, (" -- " + detail) if detail else ""])


func _city() -> Array:
	var w := BrickWorld.new()
	var palette := TowerRecipe.bake_palette(w)
	var reg := BuildingRegistry.new(w, palette)
	reg.register(12, 12, 10, Transform3D(Basis(), Vector3(11.0, 0.0, -4.0)))
	return [w, reg]


## A standing block in the middle of the building, and a world point inside it.
func _target(w: BrickWorld, chunk: int, skip := 0) -> Array:
	var xf := w.get_chunk_transform(chunk)
	var seen := 0
	for bx in w.get_block_boxes(chunk):
		var d: Dictionary = bx
		if not bool(d.alive) or (d.pos as Vector3).y < 1.0:
			continue
		if seen < skip:
			seen += 1
			continue
		return [int(d.block), xf * (d.pos as Vector3)]
	return [-1, Vector3.ZERO]


func _hp_of(worn: PackedInt32Array, id: int) -> int:
	for k in range(0, worn.size() - 1, 2):
		if worn[k] == id:
			return worn[k + 1]
	return 255


# ---------------------------------------------------------------------------

func _check_wear() -> void:
	print("\na bullet wears the brick it hits, and only that brick")
	var c := _city()
	var w: BrickWorld = c[0]
	var chunk := (c[1] as BuildingRegistry).materialise(0)
	var t := _target(w, chunk)
	var id: int = t[0]
	var at: Vector3 = t[1]
	var pistol := StructuralDamage.chip_hp(WeaponClass.builtin(&"pistol"))
	var first := w.chip_hit(chunk, at, 0.0, pistol)
	var worn := w.get_worn_blocks(chunk)
	_ok("one hit kills nothing", first.is_empty())
	_ok("and wears exactly one brick", worn.size() == 2 and worn[0] == id,
			"%d worn" % (worn.size() / 2))
	_ok("by the pistol's wear", _hp_of(worn, id) == 255 - pistol, "hp %d" % _hp_of(worn, id))
	var hits := 1
	var killed := PackedInt32Array()
	while killed.is_empty() and hits < 20:
		killed = w.chip_hit(chunk, at, 0.0, pistol)
		hits += 1
	_ok("it dies on the hit StructuralDamage says", hits == StructuralDamage.hits_per_brick(
			WeaponClass.builtin(&"pistol")) and killed == PackedInt32Array([id]),
			"%d hits" % hits)
	_ok("and is not worn any more, it is gone", _hp_of(w.get_worn_blocks(chunk), id) == 255)
	var round := w.chip_hit(chunk, at, 0.6, 10)
	_ok("a round of wear takes every brick in reach",
			w.get_worn_blocks(chunk).size() / 2 > 2 and round.is_empty(),
			"%d worn" % (w.get_worn_blocks(chunk).size() / 2))


func _check_rebuild() -> void:
	print("\nwear survives the building being let go of")
	var c := _city()
	var w: BrickWorld = c[0]
	var reg: BuildingRegistry = c[1]
	var chunk := reg.materialise(0)
	for k in 4:
		var t := _target(w, chunk, k * 7)
		w.chip_hit(chunk, t[1], 0.0, 60 + k * 30)
	var before := w.get_worn_blocks(chunk)
	reg.dematerialise(0)
	var again := reg.materialise(0)
	_ok("a rebuilt building has the same bricks worn by the same amount",
			before.size() == 8 and w.get_worn_blocks(again) == before,
			"%d vs %d" % [before.size() / 2, w.get_worn_blocks(again).size() / 2])


func _check_record() -> void:
	print("\nwear survives a piece going to sleep")
	var c := _city()
	var w: BrickWorld = c[0]
	var chunk := (c[1] as BuildingRegistry).materialise(0)
	for k in 5:
		var t := _target(w, chunk, k * 11)
		w.chip_hit(chunk, t[1], 0.0, 40 + k * 20)
	var before := w.get_worn_blocks(chunk)
	var record := ChunkRecord.capture(w, chunk)
	w.release_chunk(chunk)
	var back := record.restore(w)
	_ok("the record keeps it", record.worn.size() == before.size(), "%d pairs" % (record.worn.size() / 2))
	_ok("and it wakes worn the same", w.get_worn_blocks(back) == before)
	var data := ChunkRecord.from_data(w, record.to_data(w))
	_ok("and through a save", data != null and data.worn == record.worn)


func _check_split() -> void:
	print("\nwear survives a piece breaking in two")
	var c := _city()
	var w: BrickWorld = c[0]
	var chunk := (c[1] as BuildingRegistry).materialise(0)
	var total := 0
	for k in 30:
		var t := _target(w, chunk, k * 13)
		if t[0] < 0:
			break
		w.chip_hit(chunk, t[1], 0.0, 50)
		total += 1
	w.separate_plane(chunk, w.get_chunk_transform(chunk) * Vector3(3.0, 5 * 3 * 0.14, 2.0),
			Vector3.UP, 0.42)
	var comps: Array = w.get_components(chunk)
	if comps.size() < 2:
		_ok("the cut made a piece", false, "%d component(s)" % comps.size())
		return
	var cut: Dictionary = w.split_island(chunk, comps[1])
	var kept := w.get_worn_blocks(chunk).size() / 2 + w.get_worn_blocks(int(cut.chunk)).size() / 2
	_ok("every worn brick is still worn, on one side or the other", kept == total,
			"%d of %d" % [kept, total])


func _check_replay() -> void:
	print("\nthe log carries wear to another machine")
	var host := _city()
	var hw: BrickWorld = host[0]
	var hchunk := (host[1] as BuildingRegistry).materialise(0)
	var history := DamageLog.new()
	var smg := StructuralDamage.chip_hp(WeaponClass.builtin(&"smg"))
	var died := 0
	for k in 80:
		var t := _target(hw, hchunk, (k % 8) * 5)
		if t[0] < 0:
			continue
		var e := DamageLog.Entry.new()
		e.kind = DamageLog.Kind.CHIP
		e.target = 0
		e.point = t[1]
		e.radius = 0.0
		e.limit = smg
		died += DamageLog.apply_entry(hw, hchunk, e).size()
		history.add(e)
	var client := _city()
	var cw: BrickWorld = client[0]
	var creg: BuildingRegistry = client[1]
	var rep := StructureReplayer.new(cw, func(id: int, frame: int) -> int:
		return creg.materialise(id) if frame == 0 else -1)
	rep.apply_all(DamageLog.from_data(history.to_data()).entries)
	var cchunk := creg.get_building(0).chunk
	_ok("every CHIP applied", rep.missed == 0 and rep.applied == history.size(),
			"%d of %d" % [rep.applied, history.size()])
	_ok("the same bricks died", cw.get_dead_blocks(cchunk) == hw.get_dead_blocks(hchunk)
			and died > 0, "%d died" % died)
	_ok("the same bricks are worn by the same amount",
			cw.get_worn_blocks(cchunk) == hw.get_worn_blocks(hchunk),
			"%d worn" % (hw.get_worn_blocks(hchunk).size() / 2))
	var ce := DamageLog.Entry.new()
	ce.kind = DamageLog.Kind.CHIP
	var pe := DamageLog.Entry.new()
	pe.kind = DamageLog.Kind.PIECE_CHIP
	_ok("a CHIP is a building's command, a PIECE_CHIP a piece's",
			not ce.is_piece() and pe.is_piece())


func _check_mapping() -> void:
	print("\nStructuralDamage: the class decides, not the roll")
	var hits := {}
	for id in [&"pistol", &"smg", &"rifle", &"lmg", &"dmr", &"sniper", &"shotgun", &"revolver"]:
		hits[id] = StructuralDamage.hits_per_brick(WeaponClass.builtin(id))
	print("  hits per brick: %s" % hits)
	_ok("a pistol breaks a brick in three", int(hits[&"pistol"]) == 3)
	_ok("an SMG takes more hits than a pistol", int(hits[&"smg"]) > int(hits[&"pistol"]))
	_ok("a sniper round breaks one outright", int(hits[&"sniper"]) == 1)
	var lib := GunPlaceholderParts.build_library()
	var same := true
	for tier in [1, 5, 10]:
		for rarity in [1, 5]:
			var g := GunGenerator.generate(lib, 1234 + tier * 7 + rarity,
					WeaponClass.builtin(&"rifle"), tier, rarity)
			var shot := StructuralDamage.for_shot(g.weapon_class, g.active_effects)
			if int(shot.hp) != StructuralDamage.chip_hp(WeaponClass.builtin(&"rifle")) \
					or bool(shot.blast):
				same = false
	_ok("a tier-10 legendary rifle wears a wall like a tier-1 common", same)
	var gren := StructuralDamage.for_shot(WeaponClass.builtin(&"grenade"))
	_ok("ordnance is a blast, and a small one",
			bool(gren.blast) and float(gren.radius) > 0.5 and float(gren.radius) <= 2.0,
			"%.2f m" % float(gren.radius))
	var boom := StructuralDamage.for_shot(WeaponClass.builtin(&"pistol"),
			PackedStringArray(["explosive"]))
	_ok("an explosive gun wears a ball", float(boom.radius) > 0.0)
