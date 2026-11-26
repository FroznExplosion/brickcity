extends RefCounted
## -- --gate=farm (Docs/MineFarming.md 12): farming in the real mine world, the
## player's way where it matters (the builder's RMB and LMB, a real fall).
##
##   godot --path . scenes/terrain_test.tscn -- --gate=farm
##
## What each check is for:
##   till      the hoe turns a 2x2 soil brick into ONE tilled brick (farmland,
##             no studs), on its course; a top part way up a course is dug down.
##   plant     seeds go on tilled soil, through the builder's RMB too.
##   water     water dug in beside a field wets the plots within 4 studs (they
##             turn wet farmland) and not the ones past it.
##   grow      two in-game days on: wet wheat is ripe, dry wheat is not.
##   away      a plot out of reach is not touched while the clock runs, and
##             when the player comes back it is exactly where settling it once
##             puts it -- the "grows while unloaded" promise in the real world.
##   harvest   RMB on a ripe crop picks it (produce in the inventory) and
##             replants it; LMB on a growing one pulls it.
##   trample   a real fall from over 3 bricks onto a plot tramples it (dirt,
##             the crop gone); a small hop does not.
##   areas     stage 3, the player's way (MineBuilder.farm_drag_begin/end):
##             a hoe dragged over 4 x 2 plots tills all 8, carrots dragged
##             plant all 8, the watering can fills from the channel (LMB) and
##             a drag waters the dry ones (wet for a day, dark soil); two days
##             on a scythe drag harvests and replants them all, and a scythe
##             click takes the ripe crops 3 x 3 round a plot.
##   chest     a harvest that will not fit the inventory goes into a chest
##             near the field.
##   stage 4   a sapling planted on plain grass (no hoe) grows into a REAL
##             tree -- saved in the trees' planted list, and felled like any
##             other; compost made at a compost bin from crops; compost on a
##             plot raises its fertility; a grow mix dragged over a field
##             boosts every plot; corn, cabbage and melon planted and drawn
##             (user://dev/farm_stage4.png).
##   stage 5   (the checks above run with TROUBLE off, so they are certain)
##             the field is open to animals; a stone ring round the patch
##             closes it (the real flood, on its worker); a gap in the ring
##             opens it again; a scarecrow marks plots near it; weeds are
##             pulled with LMB, the crop staying; mulch goes on; an animals'
##             trample turns a plot to dirt in the world; with trouble on,
##             three days bring events to the open field.
##   stage 6   a seed's traits go into its plant and come back in its
##             harvest's seeds (the label shows them); corn by beans is a
##             companion; a bare plot between two ripe wheat plants sprouts a
##             cross with the better traits; a biome crop is refused outside
##             its biomes; four 3-star pumpkins merge into a giant (chance set
##             to 1 here), drawn as one, and picked for many pumpkins
##             (user://dev/farm_giant.png).
##   stage 7   a sprinkler wets dry plots in reach (dark soil, no water near);
##             a collector given seeds harvests ripe crops in reach into its
##             slots and replants from them (then it is taken away, so the
##             'away' check below sees plain growth).
##   save      the world generated again (saved, loaded): the plots, their
##             state and the clock come back.
##   pictures  user://dev/farm_field.png, farm_guide.png.
## Preloaded by mine_world.gd (`--gate=farm`).

var w: Node = null
var fails: Array[String] = []


func check(what: String, ok: bool) -> void:
	print("[farm-gate] %s %s" % ["ok  " if ok else "FAIL", what])
	if not ok:
		fails.append(what)


func run(host: Node) -> void:
	w = host
	var f: MineFarming = w.farming
	FarmPlant.trouble = false
	var stud := BrickWorld.get_stud_metres()
	var plate := BrickWorld.get_plate_metres()
	w._time = 0.5
	w.world_time = FarmPlant.DAY * 10.5        # noon of day 10
	w.set_on_foot(false)
	await w._frames(30)
	w.builder.aim_trees = false

	# A flat patch by the spawn: 14 x 12 studs of grass over dirt, its top a
	# course's top, with nothing over it.
	var eye: Vector3 = w._eye()
	var x0 := floori(eye.x / stud) + 6
	var z0 := floori(eye.z / stud) - 6
	var s0 := BrickTerrain.surface_plate(x0, z0)
	var top := floori(float(s0 + 1) / 3.0) * 3 - 1
	for res in [BrickTerrain.fill_box(Vector3i(x0, top + 1, z0), Vector3i(x0 + 13, top + 60, z0 + 11), 0, false),
			BrickTerrain.fill_box(Vector3i(x0, top - 9, z0), Vector3i(x0 + 13, top - 1, z0 + 11), BrickTerrain.MAT_DIRT, false),
			BrickTerrain.fill_box(Vector3i(x0, top, z0), Vector3i(x0 + 13, top, z0 + 11), BrickTerrain.MAT_GRASS, false)]:
		w.terrain_edited(res)
	await w._frames(20)

	# --- till: a 3 x 3 field, the first plot through the builder's RMB
	var field: Array[Vector3i] = []
	var bx0 := floori(x0 / 2.0) + 1
	var bz0 := floori(z0 / 2.0) + 1
	for i in 3:
		for k in 3:
			field.append(Vector3i(bx0 + i, top, bz0 + k))
	_hold(&"hoe")
	w.builder.target = {"cell": Vector3i(field[0].x * 2, top, field[0].z * 2), "normal": Vector3i.UP}
	check("the builder's RMB with a hoe tills", w.builder.place_target() and not f.store.get_plot(field[0]).is_empty())
	var tilled_ok := true
	for b in field:
		if f.store.get_plot(b).is_empty():
			f.till({"cell": Vector3i(b.x * 2, top, b.z * 2), "normal": Vector3i.UP})
		for dx in 2:
			for dz in 2:
				tilled_ok = tilled_ok and MineFarming.is_farmland(BrickTerrain.solid_at(b.x * 2 + dx, top, b.z * 2 + dz)) \
						and MineFarming.is_farmland(BrickTerrain.solid_at(b.x * 2 + dx, top - 2, b.z * 2 + dz))
	check("9 plots tilled, each a whole course of farmland (%d plots)" % f.store.count(),
			tilled_ok and f.store.count() == 9)
	# A top one plate up a course: dug down to the course under it.
	var raised := Vector3i(bx0 + 5, top, bz0)
	w.terrain_edited(BrickTerrain.fill_box(Vector3i(raised.x * 2, top + 1, raised.z * 2),
			Vector3i(raised.x * 2 + 1, top + 1, raised.z * 2 + 1), BrickTerrain.MAT_GRASS, false))
	var dug := f.till({"cell": Vector3i(raised.x * 2, top + 1, raised.z * 2), "normal": Vector3i.UP})
	check("a top part way up a course is dug down to a whole tilled brick", dug
			and BrickTerrain.solid_at(raised.x * 2, top + 1, raised.z * 2) == 0
			and MineFarming.is_farmland(BrickTerrain.solid_at(raised.x * 2, top, raised.z * 2))
			and not f.store.get_plot(raised).is_empty())
	check("a side face is not tilled", not f.till({"cell": Vector3i(x0 + 12, top, z0 + 10), "normal": Vector3i.RIGHT}))
	check("stone is not tilled", not _till_stone(f, x0 + 12, z0 + 8, top))

	# --- plant: every crop once, wheat in the rest; the first through RMB
	var ids := FarmCrops.ids()
	_hold(&"wheat_seeds")
	w.builder.target = {"cell": Vector3i(field[0].x * 2, top, field[0].z * 2), "normal": Vector3i.UP}
	check("the builder's RMB with seeds plants", w.builder.place_target() and f.store.get_plot(field[0]).crop == &"wheat")
	for i in range(1, field.size()):
		var crop: StringName = ids[i % ids.size()] if i < ids.size() else &"wheat"
		var c := FarmCrops.get_crop(crop)
		f.plant({"cell": Vector3i(field[i].x * 2, top, field[i].z * 2), "normal": Vector3i.UP}, c.seed)
	f.plant({"cell": Vector3i(raised.x * 2, top, raised.z * 2), "normal": Vector3i.UP}, &"wheat_seeds")
	var planted := 0
	for b in f.store.plots:
		if f.store.plots[b].crop != &"":
			planted += 1
	check("10 plots planted (%d)" % planted, planted == 10)

	# --- water: a channel along the field's -x side, one brick deep
	var tx := field[0].x * 2 - 2
	w.terrain_edited(BrickTerrain.fill_box(Vector3i(tx, top - 2, field[0].z * 2), Vector3i(tx + 1, top, field[2].z * 2 + 1), 0, false))
	@warning_ignore("integer_division")
	var course := (top - 2) / 3
	for z in range(field[0].z * 2, field[2].z * 2 + 2):
		for x in [tx, tx + 1]:
			BrickFluid.place(Vector3i(x, course, z), 1, BrickFluid.SOURCE, 3)
	await w._frames(90)
	for b in f.store.plots.keys():
		f.refresh(b)
	await w._frames(5)
	var wet_ok := true
	for b in field:
		var near := b.x * 2 - (tx + 1) <= MineFarming.WET_STUDS
		wet_ok = wet_ok and bool(f.store.get_plot(b).wet) == near \
				and (BrickTerrain.solid_at(b.x * 2, top, b.z * 2) == BrickTerrain.MAT_WET_FARMLAND) == near
	check("plots within 4 studs of the water are wet (dark), the far row dry", wet_ok)

	# --- grow: two days on
	var dry_wheat := field[8]
	var wet_wheat := field[0]
	f.store.get_plot(dry_wheat).crop = &"wheat"     # (it is wheat by the planting above; made sure)
	w.world_time += FarmPlant.DAY * 2.0
	await w._frames(30)
	f.settle_all()
	check("two days on, wet wheat is ripe", FarmPlant.is_ripe(f.store.get_plot(wet_wheat)))
	check("dry wheat is not (stage %d)" % int(f.store.get_plot(dry_wheat).stage),
			not FarmPlant.is_ripe(f.store.get_plot(dry_wheat)) and int(f.store.get_plot(dry_wheat).stage) > 0)
	check("the crops are drawn (%d instances)" % f.draw.drawn, f.draw.drawn >= 9)

	# The picture: the field from its corner, at noon.
	var mid: Vector3 = f._top_middle(field[4])
	var cam_at := mid + Vector3(-3.2, 2.2, -3.2)
	var d := (mid - cam_at).normalized()
	w._fly_to(cam_at - Vector3(0, 1.6, 0), Vector3(d.x, 0, d.z))
	w.walker.pitch = asin(clampf(d.y, -1.0, 1.0))
	if w._hud_layer != null:
		w._hud_layer.visible = false
	await w._frames(60)
	await w._shot(UserPaths.DEV + "farm_field.png")
	if w._hud_layer != null:
		w._hud_layer.visible = true
	# The look line names the crop and its state.
	var line: String = f.look_text({"cell": Vector3i(wet_wheat.x * 2, top, wet_wheat.z * 2)})
	check("looking at ripe wheat says so: \"%s\"" % line.split("\n")[0], line.contains("Wheat") and line.contains("RIPE"))

	# --- harvest: RMB picks and replants; LMB pulls a growing crop
	var inv: Inventory = w.builder.inv
	var had := _count(inv, &"wheat")
	_hold(&"hoe")
	w.builder.target = {"cell": Vector3i(wet_wheat.x * 2, top, wet_wheat.z * 2), "normal": Vector3i.UP}
	var picked: bool = w.builder.place_target()
	var p0 := f.store.get_plot(wet_wheat)
	check("RMB on ripe wheat harvests it and replants (crop %s, stage %d)" % [p0.crop, p0.stage],
			picked and f.harvested >= 1 and p0.crop == &"wheat" and int(p0.stage) == 0)
	check("the wheat is in the inventory", _count(inv, &"wheat") > had)
	w.builder.target = {"cell": Vector3i(dry_wheat.x * 2, top, dry_wheat.z * 2), "normal": Vector3i.UP}
	check("LMB on growing wheat pulls it", w.builder.break_target() and f.store.get_plot(dry_wheat).crop == &"")

	# --- stage 3: whole rectangles by RMB drag, the can, the scythe
	var a3 := Vector3i(bx0 * 2, top, (bz0 + 3) * 2)
	var b3 := Vector3i((bx0 + 3) * 2, top, (bz0 + 4) * 2)
	var rect: Array[Vector3i] = []
	for i in 4:
		for k in 2:
			rect.append(Vector3i(bx0 + i, top, bz0 + 3 + k))
	_hold(&"hoe")
	await _drag(a3, b3)
	var n_till := 0
	for b in rect:
		if not f.store.get_plot(b).is_empty():
			n_till += 1
	check("a hoe dragged over 4 x 2 plots tills all 8 (%d)" % n_till, n_till == 8)
	_hold(&"carrot")
	await _drag(a3, b3)
	var n_plant := 0
	for b in rect:
		if f.store.get_plot(b).get("crop", &"") == &"carrot":
			n_plant += 1
	check("carrots dragged over them plant all 8 (%d)" % n_plant, n_plant == 8)
	# The can: filled from the channel, looking straight down at it.
	_hold(&"watering_can")
	var can: ItemStack = inv.hand()
	can.data.erase("water")
	var over := Vector3((tx + 1) * stud, (top + 1) * plate + 1.2, (field[1].z * 2 + 1) * stud)
	w._fly_to(over - Vector3(0, 1.6, 0), Vector3.FORWARD)
	w.walker.pitch = -PI * 0.5 + 0.02
	await w._frames(10)
	check("LMB with the can on water fills it (%d)" % int(can.data.get("water", 0)),
			w.builder.fill_can() and int(can.data.get("water", 0)) == MineFarming.CAN_WATER)
	var dry_before := 0
	for b in rect:
		if not bool(f.store.get_plot(b).wet):
			dry_before += 1
	await _drag(a3, b3)
	var watered := 0
	var dark := 0
	for b in rect:
		var p := f.store.get_plot(b)
		if float(p.wet_until) > w.world_time:
			watered += 1
		if BrickTerrain.solid_at(b.x * 2, top, b.z * 2) == BrickTerrain.MAT_WET_FARMLAND:
			dark += 1
	check("a can drag waters the %d dry plots (%d), all 8 dark, %d water left" % [dry_before, watered,
			int(can.data.get("water", 0))], watered == dry_before and dark == 8
			and int(can.data.get("water", 0)) == MineFarming.CAN_WATER - dry_before)
	# Four days: the can's water lasted one, the far ones grow dry after it.
	w.world_time += FarmPlant.DAY * 4.0
	await w._frames(10)
	f.settle_all()
	var ripe := 0
	for b in rect:
		if FarmPlant.is_ripe(f.store.get_plot(b)):
			ripe += 1
	_hold(&"scythe")
	var h0 := f.harvested
	await _drag(a3, b3)
	var replanted := 0
	for b in rect:
		var p := f.store.get_plot(b)
		if p.crop == &"carrot" and int(p.stage) == 0:
			replanted += 1
	check("four days on, a scythe drag harvests the %d ripe carrots (%d) and replants them (%d)" % [ripe,
			f.harvested - h0, replanted], ripe == 8 and f.harvested - h0 == 8 and replanted == 8)
	var ripe_field := 0
	for b in field:
		var p := f.store.get_plot(b)
		if not p.is_empty() and FarmPlant.is_ripe(p):
			ripe_field += 1
	var h1 := f.harvested
	w.builder.target = {"cell": Vector3i(field[4].x * 2, top, field[4].z * 2), "normal": Vector3i.UP}
	w.builder.place_target()
	check("a scythe click takes the ripe crops 3 x 3 round a plot (%d of %d)" % [f.harvested - h1, ripe_field],
			ripe_field > 0 and f.harvested - h1 == ripe_field)
	# A harvest too big for the inventory goes into a chest by the field.
	var cblock := Vector3i(bx0 + 5, top + 1, bz0 + 4)
	w.chests.place(cblock, [], true)
	f._give(&"wheat", 99 * 60, f._top_middle(rect[7]))
	var in_chest := 0
	for sl in w.chests.slots_of(MineChests.key_of(cblock)):
		if sl is ItemStack and (sl as ItemStack).id == &"wheat":
			in_chest += (sl as ItemStack).count
	check("what will not fit the inventory goes into the chest by the field (%d wheat)" % in_chest, in_chest > 0)

	# --- stage 4: saplings, compost, grow mix, the new crops
	var sb := Vector3i(bx0 + 4, top, bz0 + 1)
	_hold(&"oak_sapling")
	w.builder.target = {"cell": Vector3i(sb.x * 2, top, sb.z * 2), "normal": Vector3i.UP}
	var sap_ok: bool = w.builder.place_target()
	var sp := f.store.get_plot(sb)
	check("an oak sapling goes on plain grass, no hoe", sap_ok and not sp.is_empty()
			and sp.crop == &"oak_tree" and sp.ground == "soil"
			and BrickTerrain.solid_at(sb.x * 2, top, sb.z * 2) == BrickTerrain.MAT_GRASS)
	check("seeds do not go on plain grass", not f.plant({"cell": Vector3i((bx0 + 4) * 2, top, (bz0 + 4) * 2),
			"normal": Vector3i.UP}, &"wheat_seeds"))
	# Corn, cabbage and melon on three of the carrot plots (pulled first).
	var newc := [&"corn", &"cabbage_seeds", &"melon_seeds"]
	for i in 3:
		var nb: Vector3i = rect[i * 2 + 1]
		w.builder.target = {"cell": Vector3i(nb.x * 2, top, nb.z * 2), "normal": Vector3i.UP}
		w.builder.break_target()
		f.plant({"cell": Vector3i(nb.x * 2, top, nb.z * 2)}, newc[i])
	check("corn, cabbage and melon planted", f.store.get_plot(rect[1]).crop == &"corn"
			and f.store.get_plot(rect[3]).crop == &"cabbage" and f.store.get_plot(rect[5]).crop == &"melon")
	# Compost at a compost bin, from crops.
	var feet_at: Vector3 = w.player_feet_local()
	var bin := Vector3i(floori(feet_at.x / stud / 2.0) + 1, floori(feet_at.y / plate), floori(feet_at.z / stud / 2.0))
	w.chests.place(bin, [], true, &"compost_bin")
	var near: Array = w.stations_near()
	var rec := {}
	for r in RecipeBook.all():
		if str(r.name) == "Compost from crops":
			rec = r
	var c0 := _count(inv, &"compost")
	var made: Dictionary = inv.craft(rec, near) if not rec.is_empty() else {"made": 0}
	check("compost made at a compost bin from crops (bin in reach: %s, made %d)" % [near.has(&"compost_bin"),
			int(made.made)], near.has(&"compost_bin") and int(made.made) == 1
			# (the chest check above filled the bags: the compost may be in `left`)
			and (_count(inv, &"compost") > c0 or not (made.get("left", []) as Array).is_empty()))
	# Compost on a plot; a grow mix over the field.
	var fb: Vector3i = rect[7]
	f.store.get_plot(fb).fert = 40.0
	_hold(&"compost")
	w.builder.target = {"cell": Vector3i(fb.x * 2, top, fb.z * 2), "normal": Vector3i.UP}
	w.builder.place_target()
	check("compost on a plot: fertility 40 -> %d" % roundi(float(f.store.get_plot(fb).fert)),
			is_equal_approx(float(f.store.get_plot(fb).fert), 70.0))
	_hold(&"grow_mix")
	await _drag(a3, b3)
	var boosted := 0
	for b in rect:
		if FarmPlant.boosted_at(f.store.get_plot(b), w.world_time):
			boosted += 1
	check("a grow mix dragged over the field boosts all 8 plots (%d)" % boosted, boosted == 8)
	# A day and a half on: the new crops half grown, the sapling a small tree.
	w.world_time += FarmPlant.DAY * 1.5
	await w._frames(20)
	f.settle_all()
	var mid4: Vector3 = f._top_middle(rect[3])
	var cam4 := mid4 + Vector3(-2.6, 1.8, -2.4)
	var d4 := (mid4 - cam4).normalized()
	w._fly_to(cam4 - Vector3(0, 1.6, 0), Vector3(d4.x, 0, d4.z))
	w.walker.pitch = asin(clampf(d4.y, -1.0, 1.0))
	if w._hud_layer != null:
		w._hud_layer.visible = false
	await w._frames(60)
	await w._shot(UserPaths.DEV + "farm_stage4.png")
	if w._hud_layer != null:
		w._hud_layer.visible = true
	# Eight more days (dry, maybe a biome it dislikes): the sapling is a tree.
	w.world_time += FarmPlant.DAY * 8.0
	await w._frames(10)
	f.settle_all()
	var tcell := Vector2i(sb.x * 2, sb.z * 2)
	check("the sapling grew into a real tree (%d grown, in the planted list: %s)" % [f.trees_grown,
			w._trees.planted.has(tcell)], f.trees_grown >= 1 and f.store.get_plot(sb).is_empty()
			and w._trees.planted.has(tcell))
	var felled: Dictionary = w.fell_tree(tcell)
	check("and it can be felled like any tree", not felled.is_empty() and not w._trees.planted.has(tcell))

	# --- stage 5: trouble
	var p_field := field[0]
	await _fields_settle(f)
	check("the field is open to animals (%d floods)" % f.fields.floods, bool(f.store.get_plot(p_field).open))
	# A stone ring a stud outside the patch, from well down to two bricks up.
	var ring := [[Vector3i(x0 - 1, top - 6, z0 - 1), Vector3i(x0 + 14, top + 6, z0 - 1)],
			[Vector3i(x0 - 1, top - 6, z0 + 12), Vector3i(x0 + 14, top + 6, z0 + 12)],
			[Vector3i(x0 - 1, top - 6, z0 - 1), Vector3i(x0 - 1, top + 6, z0 + 12)],
			[Vector3i(x0 + 14, top - 6, z0 - 1), Vector3i(x0 + 14, top + 6, z0 + 12)]]
	for side in ring:
		w.terrain_edited(BrickTerrain.fill_box(side[0], side[1], BrickTerrain.MAT_STONE, false))
	await _fields_settle(f)
	check("a stone ring round it closes it", not bool(f.store.get_plot(p_field).open)
			and not bool(f.store.get_plot(field[4]).open))
	# A gap two studs wide, its floor at the field's height: open again.
	w.terrain_edited(BrickTerrain.fill_box(Vector3i(x0 + 6, top + 1, z0 + 12), Vector3i(x0 + 7, top + 6, z0 + 12), 0, false))
	w.terrain_edited(BrickTerrain.fill_box(Vector3i(x0 + 6, top - 6, z0 + 12), Vector3i(x0 + 7, top, z0 + 12),
			BrickTerrain.MAT_GRASS, false))
	await _fields_settle(f)
	check("a gap in the ring opens it again", bool(f.store.get_plot(p_field).open))
	# A scarecrow by the field.
	w.chests.place(Vector3i(bx0 + 4, top + 1, bz0 + 2), [], true, &"scarecrow")
	for b in field:
		if not f.store.get_plot(b).is_empty():
			f.refresh(b)
	check("a scarecrow marks the plots near it", bool(f.store.get_plot(field[4]).scared))
	# Weeds pulled by LMB; mulch on.
	var wb: Vector3i = rect[0]
	f.store.get_plot(wb).weeds = true
	var crop_before: StringName = f.store.get_plot(wb).crop
	_hold(&"hoe")
	w.builder.target = {"cell": Vector3i(wb.x * 2, top, wb.z * 2), "normal": Vector3i.UP}
	w.builder.break_target()
	check("LMB pulls the weeds and leaves the crop", not bool(f.store.get_plot(wb).weeds)
			and f.store.get_plot(wb).crop == crop_before and crop_before != &"")
	_hold(&"mulch")
	w.builder.target = {"cell": Vector3i(wb.x * 2, top, wb.z * 2), "normal": Vector3i.UP}
	w.builder.place_target()
	check("mulch goes on a plot", bool(f.store.get_plot(wb).mulch))
	# An animals' trample: the plot goes back to dirt in the world.
	var pk: Vector3i = rect[6]
	f.store.get_plot(pk).packed = true
	f.settle_all()
	check("animals' trample: the plot is gone, the soil dirt", f.store.get_plot(pk).is_empty()
			and BrickTerrain.solid_at(pk.x * 2, top, pk.z * 2) == BrickTerrain.MAT_DIRT)
	# Trouble on (the world menu's switch, MineWorld.set_farm_trouble), three
	# days: the open field gets visits.
	w.set_farm_trouble(true)
	check("the Farm trouble switch turns it on", FarmPlant.trouble)
	var ev0 := 0
	for b in f.store.plots:
		ev0 += int(f.store.plots[b].get("events", 0))
	w.world_time += FarmPlant.DAY * 3.0
	await w._frames(10)
	f.settle_all()
	var ev1 := 0
	var kinds := {}
	for b in f.store.plots:
		var pl: Dictionary = f.store.plots[b]
		ev1 += int(pl.get("events", 0))
		if str(pl.get("last_event", "")) != "":
			kinds[pl.last_event] = true
	check("with trouble on, three days bring events (%d: %s)" % [ev1 - ev0, ", ".join(kinds.keys())], ev1 > ev0)
	w.set_farm_trouble(false)
	var ev2 := 0
	for b in f.store.plots:
		ev2 += int(f.store.plots[b].get("events", 0))
	w.world_time += FarmPlant.DAY * 3.0
	f.settle_all()
	var ev3 := 0
	for b in f.store.plots:
		ev3 += int(f.store.plots[b].get("events", 0))
	check("switched off: three more days bring none (%d)" % (ev3 - ev2), not FarmPlant.trouble and ev3 == ev2)
	w.save_edits(true)
	var wf = JSON.parse_string(FileAccess.get_file_as_string(w.save_path().get_basename() + ".inv"))
	check("the switch is saved with the world (farm_trouble: %s)" % str(wf.get("farm_trouble", "?") if wf is Dictionary else "?"),
			wf is Dictionary and wf.get("farm_trouble", true) == false)

	# --- stage 6: traits, companions, crossing, biome crops, giants
	var t6: float = w.world_time
	var clear := func(b: Vector3i) -> Dictionary:
		var q := f.store.get_plot(b)
		if q.is_empty():
			f.till({"cell": Vector3i(b.x * 2, top, b.z * 2), "normal": Vector3i.UP})
			q = f.store.get_plot(b)
		if not q.is_empty():
			FarmPlant.settle(q, w.world_time)
			q.crop = &""
			q.giant = 0
			q.fert = 90.0
			q.biome = -1             # a neutral biome: stars do not hang on the spawn's
		return q
	# Traits: seeds with growth 5, yield 2 on a plot; its harvest's seeds keep them.
	var tw: Vector3i = rect[3]           # wet (by the channel): ripe in time
	clear.call(tw)
	f.plant({"cell": Vector3i(tw.x * 2, top, tw.z * 2)}, &"wheat_seeds", {"g": 5, "y": 2})
	check("a seed's traits go into its plant (G%d Y%d)" % [int(f.store.get_plot(tw).tg), int(f.store.get_plot(tw).ty)],
			int(f.store.get_plot(tw).tg) == 5 and int(f.store.get_plot(tw).ty) == 2)
	# Companions: corn beside beans.
	var cb: Vector3i = field[6]
	var bb: Vector3i = field[7]
	clear.call(cb)
	clear.call(bb)
	f.plant({"cell": Vector3i(cb.x * 2, top, cb.z * 2)}, &"corn")
	f.plant({"cell": Vector3i(bb.x * 2, top, bb.z * 2)}, &"beans")
	f.refresh(cb)
	check("corn beside beans has a companion", bool(f.store.get_plot(cb).companion))
	# Crossing: wheat (G1) and wheat (Y2) either side of a bare plot, in the
	# wet column by the channel (N-S); the bare plot looked at now and later.
	var xa: Vector3i = field[2]
	var xm: Vector3i = rect[0]
	var xb: Vector3i = rect[1]
	for q in [xa, xm, xb]:
		clear.call(q)
	f.plant({"cell": Vector3i(xa.x * 2, top, xa.z * 2)}, &"wheat_seeds", {"g": 1})
	f.plant({"cell": Vector3i(xb.x * 2, top, xb.z * 2)}, &"wheat_seeds", {"y": 2})
	f.refresh(xm)
	# Biome crops: cactus fruit only where it grows.
	var cactus := FarmCrops.get_crop(&"cactus_fruit")
	var cf: Vector3i = field[5]
	var here_ok := MineFarming.grows_here(cactus, BrickTerrain.biome_at(cf.x * 2, cf.z * 2))
	var cq: Dictionary = clear.call(cf)
	cq.biome = BrickTerrain.biome_at(cf.x * 2, cf.z * 2)
	var planted_cactus := f.plant({"cell": Vector3i(cf.x * 2, top, cf.z * 2)}, &"cactus_fruit")
	check("cactus fruit planted only where it grows (here: %s, planted: %s)" % [here_ok, planted_cactus],
			planted_cactus == here_ok)
	# Giants: four pumpkins in a 2x2, wet, rich, kept.
	var g4: Array[Vector3i] = [field[0], field[1], field[3], field[4]]
	for q in g4:
		clear.call(q)
		f.plant({"cell": Vector3i(q.x * 2, top, q.z * 2)}, &"pumpkin_seeds")
	MineFarming.giant_chance = 1.0
	w.world_time += FarmPlant.DAY * 4.0
	await w._frames(10)
	f.settle_all()
	for q in g4 + [xm, cb]:
		f.refresh(q)
	MineFarming.giant_chance = 0.4
	var gstate := []
	for q in g4:
		gstate.append(int(f.store.get_plot(q).get("giant", 0)))
	check("four 3-star pumpkins merge into a giant (%s, %d giants)" % [str(gstate), f.giants],
			gstate.count(1) == 1 and gstate.count(2) == 3)
	check("the giant is drawn as one (%s)" % str(f.draw._mmis.keys().filter(func(k): return str(k).contains("giant"))),
			f.draw._mmis.has("pumpkin:giant"))
	var xq := f.store.get_plot(xm)
	var xtr := FarmPlant.traits(xq)
	check("a cross sprouted between the two ripe wheat plants (%s, G%d Y%d H%d)" % [xq.crop, xtr.x, xtr.y, xtr.z],
			xq.crop == &"wheat" and xtr.x >= 1 and xtr.y >= 2)
	# The giant's picture, then picked.
	var gm: Vector3 = f._top_middle(field[0]) + Vector3(stud, 0, stud)
	var gcam := gm + Vector3(-3.0, 2.2, -3.0)
	var gd := (gm - gcam).normalized()
	w._fly_to(gcam - Vector3(0, 1.6, 0), Vector3(gd.x, 0, gd.z))
	w.walker.pitch = asin(clampf(gd.y, -1.0, 1.0))
	if w._hud_layer != null:
		w._hud_layer.visible = false
	await w._frames(50)
	await w._shot(UserPaths.DEV + "farm_giant.png")
	if w._hud_layer != null:
		w._hud_layer.visible = true
	var pk0 := _count(inv, &"pumpkin")
	_hold(&"hoe")
	w.builder.target = {"cell": Vector3i(field[4].x * 2, top, field[4].z * 2), "normal": Vector3i.UP}
	w.builder.place_target()
	var pk1 := _count(inv, &"pumpkin")
	check("picking the giant gives many pumpkins (%d)" % (pk1 - pk0), pk1 - pk0 >= 8
			and int(f.store.get_plot(field[0]).get("giant", 0)) == 0)
	# The traits wheat: ripe by now; its harvest's seeds carry G5 Y2 (or one better).
	var tq := f.store.get_plot(tw)
	FarmPlant.settle(tq, w.world_time)
	var ripe_tw := FarmPlant.is_ripe(tq)
	w.builder.target = {"cell": Vector3i(tw.x * 2, top, tw.z * 2), "normal": Vector3i.UP}
	w.builder.place_target()
	# The replant uses the harvest's own seeds (the bags may be full by now:
	# a traits stack needs a slot of its own).
	var rq := f.store.get_plot(tw)
	var rtr := FarmPlant.traits(rq)
	check("its harvest's seeds carry the traits: replanted G%d Y%d H%d (ripe: %s)" % [rtr.x, rtr.y, rtr.z, ripe_tw],
			ripe_tw and rq.crop == &"wheat" and int(rq.stage) == 0 and rtr.x >= 5 and rtr.y >= 2)
	var lab := ItemCatalog.label(ItemStack.make(&"wheat_seeds", 3, {"g": 5, "y": 2}))
	check("a seed's label shows its traits: \"%s\"" % lab, lab.contains("G5 Y2 H0"))

	# --- stage 7: a sprinkler and a collector
	var dry_b: Vector3i = field[8]          # by the field's dry edge, far from the channel
	var dryq := f.store.get_plot(dry_b)
	FarmPlant.settle(dryq, w.world_time)
	dryq.wet_until = 0.0
	f.refresh(dry_b)
	var dry_was_wet := bool(f.store.get_plot(dry_b).wet)
	w.chests.place(Vector3i(bx0 + 3, top + 1, bz0 + 2), [], true, &"sprinkler")
	f.refresh(dry_b)
	check("a sprinkler wets a dry plot in reach (before: %s, after: %s, dark: %s)" % [dry_was_wet,
			f.store.get_plot(dry_b).wet, BrickTerrain.solid_at(dry_b.x * 2, top, dry_b.z * 2) == BrickTerrain.MAT_WET_FARMLAND],
			not dry_was_wet and bool(f.store.get_plot(dry_b).wet)
			and BrickTerrain.solid_at(dry_b.x * 2, top, dry_b.z * 2) == BrickTerrain.MAT_WET_FARMLAND)
	var cblk := Vector3i(bx0 + 5, top + 1, bz0 + 2)
	w.chests.place(cblk, [], true, &"collector")
	var ckey := MineChests.key_of(cblk)
	var cslots: Array = w.chests.slots_of(ckey)
	cslots[0] = ItemStack.make(&"wheat_seeds", 20)
	cslots[1] = ItemStack.make(&"corn", 20)
	cslots[2] = ItemStack.make(&"beans", 20)
	w.world_time += FarmPlant.DAY * 3.0
	await w._frames(5)
	f.settle_all()
	var col0 := f.collected
	for b in f.store.plots.keys():
		if not f.store.get_plot(b).is_empty():
			f.refresh(b)
	var ckinds := {}
	for sl in cslots:
		if sl is ItemStack:
			ckinds[(sl as ItemStack).id] = int(ckinds.get((sl as ItemStack).id, 0)) + (sl as ItemStack).count
	var cseeds_left := int(ckinds.get(&"wheat_seeds", 0)) + int(ckinds.get(&"corn", 0)) + int(ckinds.get(&"beans", 0))
	check("a collector harvests ripe crops in reach into its slots (%d plots: %s)" % [f.collected - col0, str(ckinds)],
			f.collected - col0 > 0 and ckinds.size() > 3)
	var creplanted := 0
	for b in f.store.plots:
		var q: Dictionary = f.store.plots[b]
		if q.crop != &"" and int(q.stage) == 0 and float(q.planted) >= w.world_time - 1.0:
			creplanted += 1
	check("and replants them from its seeds (%d creplanted)" % creplanted, creplanted > 0)
	w.chests.break_chest(ckey, false)

	# --- away: out of reach, the clock runs, the plot is not touched; back, it
	# is where one settle puts it
	var away_b := field[4]
	FarmPlant.settle(f.store.get_plot(away_b), w.world_time)
	var before: Dictionary = f.store.get_plot(away_b).duplicate()
	w._fly_to(mid + Vector3(400.0, 60.0, 0.0), Vector3.FORWARD)
	await w._frames(10)
	# Until the farm has seen the player go (its in-reach list, once a second).
	for _i in 600:
		if not f._near.has(away_b):
			break
		await w._frames(1)
	w.world_time += FarmPlant.DAY * 0.8
	await w._frames(90)
	check("while away the plot was not settled", is_equal_approx(float(f.store.get_plot(away_b).t), float(before.t)))
	var expect := before.duplicate()
	FarmPlant.settle(expect, w.world_time)
	w._fly_to(cam_at - Vector3(0, 1.6, 0), Vector3(d.x, 0, d.z))
	await w._frames(120)
	var back := f.store.get_plot(away_b)
	check("back again it caught up exactly (stage %d -> %d, %.3f)" % [before.stage, back.stage, back.p],
			is_equal_approx(float(back.t), float(w.world_time)) and int(back.stage) == int(expect.stage)
			and absf(float(back.p) - float(expect.p)) < 1e-6)

	# --- the guide's picture
	w.toggle_inventory()
	await w._frames(10)
	if w._inv_screen != null:
		w._inv_screen.show_page("farming")
	await w._frames(20)
	await w._shot(UserPaths.DEV + "farm_guide.png")
	w.toggle_inventory()
	await w._frames(10)

	# --- trample: a real fall onto a plot
	var tb := field[5]
	var feet: Vector3 = f._top_middle(tb)
	w.set_on_foot(true, feet + Vector3(0, 0.45, 0))
	await w._frames(60)
	check("a small hop onto a plot does not trample it", not f.store.get_plot(tb).is_empty())
	var n0 := f.trampled
	w.set_on_foot(true, feet + Vector3(0, 2.3, 0))
	await w._frames(90)
	check("a fall of %.2f m tramples the plot (back to dirt)" % w.pawn.last_fall, f.trampled == n0 + 1
			and f.store.get_plot(tb).is_empty()
			and BrickTerrain.solid_at(tb.x * 2, top, tb.z * 2) == BrickTerrain.MAT_DIRT)
	w.set_on_foot(false)
	await w._frames(10)

	# --- save: generated again, the farm and the clock come back
	var rows := {}
	f.settle_all()
	for b in f.store.plots:
		rows[b] = str(FarmPlant.to_row(f.store.plots[b]))
	var clock: float = w.world_time
	w.generate(w.settings)
	await w._frames(30)
	var same := f.store.count() == rows.size()
	for b in rows:
		same = same and f.store.plots.has(b) and str(FarmPlant.to_row(f.store.plots[b])) == rows[b]
	check("after generating again: %d plots, the same" % f.store.count(), same)
	check("and the clock (%.0f s)" % w.world_time, is_equal_approx(float(w.world_time), clock))
	check("the tilled soil is still farmland", MineFarming.is_farmland(BrickTerrain.solid_at(field[1].x * 2, top, field[1].z * 2)))

	print("[farm-gate] slowest plot refresh (water, light, soil): %d us" % f.worst_refresh_us)
	print("[farm-gate] refresh parts: %s" % f.prof_line())
	print("[farm-gate] %s" % ("FARM-GATE PASS" if fails.is_empty() else "FARM-GATE FAIL: " + "; ".join(fails)))
	w.get_tree().quit(0 if fails.is_empty() else 1)


func _till_stone(f: MineFarming, x: int, z: int, top: int) -> bool:
	var sx := floori(x / 2.0) * 2
	var sz := floori(z / 2.0) * 2
	w.terrain_edited(BrickTerrain.fill_box(Vector3i(sx, top - 2, sz), Vector3i(sx + 1, top, sz + 1), BrickTerrain.MAT_STONE, false))
	return f.till({"cell": Vector3i(sx, top, sz), "normal": Vector3i.UP})


## The item in the hand: its hotbar slot, else (creative) a stack of it into
## the hand, the way middle click picks (the kit's seeds may be in storage).
func _hold(id: StringName) -> void:
	var inv: Inventory = w.builder.inv
	if not inv.select_item(id):
		inv.pick(id)
	check("%s in the hand" % id, inv.hand() != null and inv.hand().id == id)


## A farm tool's RMB drag from cell a to cell b, the builder's own way.
func _drag(a: Vector3i, b: Vector3i) -> void:
	w.builder.target = {"cell": a, "normal": Vector3i.UP}
	w.builder.farm_drag_begin()
	await w._frames(2)
	w.builder.target = {"cell": b, "normal": Vector3i.UP}
	w.builder.farm_drag_end()
	await w._frames(2)


## Let the fields be worked out (regroup and floods, on the worker).
func _fields_settle(f: MineFarming) -> void:
	await w._frames(5)
	for i in 600:
		if not f.fields.busy():
			break
		await w._frames(1)
	await w._frames(2)


## Seeds of `id` carrying growth 5+ and yield 2+ (a traits stack).
func _count_traits(inv: Inventory, id: StringName) -> int:
	var n := 0
	for a in inv.all_addrs():
		var st := inv.get_slot(a)
		if st != null and st.id == id and int(st.data.get("g", 0)) >= 5 and int(st.data.get("y", 0)) >= 2:
			n += st.count
	return n


func _count(inv: Inventory, id: StringName) -> int:
	var n := 0
	for a in inv.all_addrs():
		var s := inv.get_slot(a)
		if s != null and s.id == id:
			n += s.count
	return n
