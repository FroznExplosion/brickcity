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

	# --- away: out of reach, the clock runs, the plot is not touched; back, it
	# is where one settle puts it
	var away_b := field[4]
	FarmPlant.settle(f.store.get_plot(away_b), w.world_time)
	var before: Dictionary = f.store.get_plot(away_b).duplicate()
	w._fly_to(mid + Vector3(400.0, 60.0, 0.0), Vector3.FORWARD)
	await w._frames(40)
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


func _count(inv: Inventory, id: StringName) -> int:
	var n := 0
	for a in inv.all_addrs():
		var s := inv.get_slot(a)
		if s != null and s.id == id:
			n += s.count
	return n
