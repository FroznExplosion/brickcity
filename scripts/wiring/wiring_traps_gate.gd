extends RefCounted
## -- --gate=wiring, the traps kit (Docs/MineWiring.md 19, stages 5-6): real
## trap setups in the real mine world. Run by wiring_gate.gd at its end, or
## alone with `-- --gate=wiring --traps`.
##
## What each check is for:
##   shooter   (id dispenser) laid with the builder facing away from the camera; RMB opens
##             its 9 slots in the chest screen.
##   gun wall  a pressure tile behind a shooter with a gun in it: the player
##             steps on the tile, ONE round goes out of the front through the
##             weapon system and breaks a brick of the wall in front.
##   arrows    a lever beside a shooter of arrows, a zombie walking down its
##             line toward the player behind it: 4 turn-ons shoot 4 arrows and
##             they hurt it (WiringArrow through the damage system).
##   launch    a shooter of plain items (wire): one lands a few metres out,
##             a pickup -- items hurt nobody.
##   grenade   a button beside a shooter of grenades: one is thrown, goes
##             off (a blast) and breaks bricks of the wall it lands by.
##   bucket    a lever: a bucket's water poured into the stud in front.
##   dropper   a lever: one item dropped (DroppedItems).
##   release   a trip string across the way to a bridge over a trench; the
##             bridge rests on release bricks at both ends, wired to the
##             hooks. The player crosses the string: the release bricks let go
##             and the collapse survey drops the bridge (pieces let go, its
##             middle cells air). 2 s after, they grip again. Aimed at, a
##             release brick is the target (not the ground), and a block is
##             laid on it with RMB.
##   alarm     an observer watching a stud; a pulse gate at its back feeds an
##             alarm. A real ground edit there: the alarm sounds and calls the
##             zombie 8 m off, which walks toward the alarm, not the player
##             (25 m the other way).
##   sensors   (section 28) a motion sensor lights its lamp while the player
##             stands in front, and a zombie walking into view sets off the
##             arrow shooter beside it; a light sensor reads >= 12 at noon on
##             a number display, less under a roof, 0 at midnight; water poured
##             in front of a fluid sensor lights its lamp; a button pressed 3
##             times through a counter flashes its lamp on the third only.
##   save      generated again: the gun still in the dispenser, the release
##             bricks holding, the alarm there.
##   pictures  user://dev/wiring_traps.png, wiring_bridge.png,
##             wiring_bridge_fell.png, wiring_sensors.png.

var g = null   # the wiring gate: check, _hold, _picture, w
var w: Node = null


func run(gate) -> void:
	g = gate
	w = gate.w
	var wr: MineWiring = w.wiring
	var stud := BrickWorld.get_stud_metres()
	var plate := BrickWorld.get_plate_metres()
	# Flying (the sections before may end on foot: generating again does), so
	# _fly_to places the player and the builder aims from the flying eye.
	w.set_on_foot(false)
	w.builder.set_active(false)
	await w._frames(10)
	# A flat patch of stone 30 x 30 studs, 12 to 42 studs in front of the eye.
	var eye: Vector3 = w._eye()
	var x0 := floori(eye.x / stud) - 4
	var z0 := floori(eye.z / stud) + 12
	var s0 := BrickTerrain.surface_plate(x0, z0)
	var top := floori(float(s0 + 1) / 3.0) * 3 - 1
	for res in [BrickTerrain.fill_box(Vector3i(x0 - 2, top + 1, z0 - 2), Vector3i(x0 + 31, top + 60, z0 + 31), 0, false),
			BrickTerrain.fill_box(Vector3i(x0 - 2, top - 15, z0 - 2), Vector3i(x0 + 31, top, z0 + 31), BrickTerrain.MAT_STONE, false)]:
		w.terrain_edited(res)
	await w._frames(30)
	var y := top + 1

	# --- dispenser laid with the builder, facing away from the camera (+z)
	var xd := x0 + 2
	var zd := z0 + 2
	var disp := Vector3i(xd, y, zd)
	w._fly_to(Vector3((xd + 0.5) * stud, y * plate, (zd - 3.0) * stud), Vector3(0, 0, 1))
	w.walker.pitch = -0.4
	await w._frames(6)
	g._hold(&"dispenser")
	w.builder.target = {"cell": Vector3i(xd, top, zd), "normal": Vector3i.UP}
	g.check("RMB with a dispenser lays one facing away from the camera (+z)", w.builder.place_target()
			and wr.devices.has(disp) and int(wr.devices[disp].facing) == 2)
	g._hold(&"stone")
	w.builder.target = {"device": disp, "position": wr.device_box(disp).get_center()}
	g.check("RMB on it opens its 9 slots in the chest screen", w.builder.place_target() and w.inventory_open()
			and w.builder.inv.chest_key == WiringTraps.slot_key(disp) and w.builder.inv.chest_slots.size() == 9)
	var gun_stack: ItemStack = null
	for a in w.builder.inv.all_addrs():
		var s: ItemStack = w.builder.inv.get_slot(a)
		if MineHands.is_gun(s) and a.area != &"chest":
			gun_stack = s.copy()
			break
	g.check("a gun from the kit to load it with (%s)" % (String(gun_stack.id) if gun_stack != null else "none"), gun_stack != null)
	if gun_stack != null:
		w.builder.inv.chest_slots[0] = gun_stack
	w.toggle_inventory()
	await w._frames(4)
	g.check("E shuts the screen", not w.inventory_open())

	# --- gun wall: a pressure tile behind it, a stone wall 6 studs in front
	var tile := Vector3i(xd, y, zd - 1)
	wr.place_device(tile, &"pressure_tile")
	var wlo := Vector3i(xd - 1, y, zd + 6)
	var whi := Vector3i(xd + 1, y + 5, zd + 6)
	w.terrain_edited(BrickTerrain.fill_box(wlo, whi, BrickTerrain.MAT_STONE, false))
	await w._frames(20)
	var wall0 := _solid_count(wlo, whi)
	var tb := wr.device_box(tile)
	w._fly_to(Vector3(tb.get_center().x, tb.end.y, tb.get_center().z), Vector3(0, 0, 1))
	await w._frames(16)
	var dd: Dictionary = wr.devices[disp]
	var ctrl: GunController = dd.get("gun_ctrl", null)
	g.check("the player on the tile: one round out of the front (%s, %d fired)" % [str(dd.get("last", "")), int(dd.get("fired", 0))],
			int(dd.get("fired", 0)) == 1 and str(dd.get("last", "")).begins_with("gun ") and ctrl != null)
	w._fly_to(Vector3((xd + 4.5) * stud, y * plate + 1.0, (zd - 4.0) * stud), Vector3(0, 0, 1))
	await w._frames(40)
	var wall1 := _solid_count(wlo, whi)
	g.check("the round broke a brick of the wall in front (%d -> %d cells)" % [wall0, wall1], wall1 < wall0)
	g.check("the gun is still in its slot", dd.slots[0] != null and MineHands.is_gun(dd.slots[0]))

	# --- arrow wall: a shooter of arrows, a zombie walking into its line
	var ax := x0 + 5
	var adisp := Vector3i(ax, y, zd)
	wr.place_device(adisp, &"dispenser", false, false, 2)
	wr.devices[adisp].slots[0] = ItemStack.make(&"arrow", 6)
	var alev := Vector3i(ax - 1, y, zd)
	wr.place_device(alev, &"lever")
	var az = null
	if w.mobs != null:
		w.mobs.auto = false
		az = w.mobs.spawn_zombie(Vector3((ax + 0.5) * stud, y * plate, (zd + 12.5) * stud))
	# The player behind the shooter: the zombie comes down its line.
	w._fly_to(Vector3((ax + 0.5) * stud, y * plate + 1.0, (zd - 6.0) * stud), Vector3(0, 0, 1))
	await w._frames(40)
	var hp0: float = az.hp() if az != null else 0.0
	var hits0 := WiringArrow.hits_on_bodies
	var shots0 := WiringArrow.shot_count
	for k in 4:
		wr.use_device(alev)
		await w._frames(14)
		wr.use_device(alev)
		await w._frames(14)
	await w._frames(20)
	var hp1: float = az.hp() if az != null and is_instance_valid(az) else 0.0
	g.check("4 turn-ons: 4 arrows shot (%d), 2 left" % (WiringArrow.shot_count - shots0),
			WiringArrow.shot_count - shots0 == 4 and wr.devices[adisp].slots[0].count == 2)
	g.check("arrows hit the zombie in its line (%d hits, hp %.0f -> %.0f)" % [WiringArrow.hits_on_bodies - hits0, hp0, hp1],
			az != null and WiringArrow.hits_on_bodies > hits0 and hp1 < hp0)
	if az != null and is_instance_valid(az) and az.pawn != null and not az.dead:
		az.pawn.health.apply_impact(1000.0, &"")

	# --- grenade: a dispenser of grenades, a button at its side, a wall 6 studs out
	var gx := x0 + 8
	var gdisp := Vector3i(gx, y, zd)
	wr.place_device(gdisp, &"dispenser", false, false, 2)
	wr.devices[gdisp].slots[0] = ItemStack.make(&"grenade", 3)
	var gbtn := Vector3i(gx - 1, y, zd)
	wr.place_device(gbtn, &"button")
	var glo := Vector3i(gx - 1, y, zd + 7)
	var ghi := Vector3i(gx + 1, y + 5, zd + 7)
	w.terrain_edited(BrickTerrain.fill_box(glo, ghi, BrickTerrain.MAT_STONE, false))
	await w._frames(20)
	var gwall0 := _solid_count(glo, ghi)
	var blasts0: int = w.blasts
	wr.use_device(gbtn)
	await w._frames(16)
	g.check("the button: a grenade thrown (%s), 2 left" % str(wr.devices[gdisp].get("last", "")),
			str(wr.devices[gdisp].get("last", "")) == "grenade grenade" and wr.devices[gdisp].slots[0].count == 2)
	for i in 120:
		await w._frames(2)
		if w.blasts > blasts0:
			break
	await w._frames(40)
	var gwall1 := _solid_count(glo, ghi)
	g.check("it went off (%d blast) and broke the wall it landed by (%d -> %d cells)" % [w.blasts - blasts0, gwall0, gwall1],
			w.blasts > blasts0 and gwall1 < gwall0)

	# --- bucket and dropper on one lever
	var bx := x0 + 13
	var bdisp := Vector3i(bx, y, zd)
	wr.place_device(bdisp, &"dispenser", false, false, 2)
	wr.devices[bdisp].slots[0] = ItemStack.make(&"bucket", 1, {"tiles": 9})
	var drop := Vector3i(bx + 2, y, zd)
	wr.place_device(drop, &"dropper", false, false, 2)
	wr.devices[drop].slots[0] = ItemStack.make(&"cable", 5)
	var blev := Vector3i(bx + 1, y, zd)
	wr.place_device(blev, &"lever")
	await w._frames(14)
	var drops0: int = w.drops.count()
	wr.use_device(blev)
	await w._frames(30)
	var fcell := Vector3i(bx, floori(y / 3.0), zd + 1)
	var fi: Dictionary = BrickFluid.cell_info(fcell)
	g.check("the lever: the bucket poured water in front (%s, fluid %d, %d tiles left)" % [fcell, int(fi.get("fluid", 0)),
			int(wr.devices[bdisp].slots[0].data.get("tiles", 0))],
			int(wr.devices[bdisp].slots[0].data.get("tiles", 0)) == 6 and wr.devices[bdisp].has("poured"))
	g.check("and the dropper dropped one wire (%d -> %d on the ground, %d left)" % [drops0, w.drops.count(),
			wr.devices[drop].slots[0].count], w.drops.count() == drops0 + 1 and wr.devices[drop].slots[0].count == 4)
	# A shooter of plain items: one wire launched, lying a few metres out.
	var lx := bx + 5
	var ldisp := Vector3i(lx, y, zd)
	wr.place_device(ldisp, &"dispenser", false, false, 2)
	wr.devices[ldisp].slots[0] = ItemStack.make(&"cable", 3)
	var lbtn := Vector3i(lx, y, zd - 1)
	wr.place_device(lbtn, &"button")
	await w._frames(14)
	var n0: int = w.drops.count()
	wr.use_device(lbtn)
	await w._frames(90)
	var far := 0.0
	var from_l: Vector3 = wr.device_box(ldisp).get_center()
	for dr in w.drops.drops.slice(n0):
		far = maxf(far, Vector2((dr.pos as Vector3).x - from_l.x, (dr.pos as Vector3).z - from_l.z).length())
	g.check("a shooter launches a plain item: it lies %.1f m out, a pickup (%s)" % [far, str(wr.devices[ldisp].get("last", ""))],
			w.drops.count() == n0 + 1 and far > 1.5 and str(wr.devices[ldisp].get("last", "")) == "launch cable")
	await g._picture(Vector3((xd + 6) * stud, y * plate, (zd + 3) * stud), Vector3(-2.5, 3.0, -4.5), "wiring_traps.png")

	# --- observer -> pulse -> alarm, a zombie called (before the trench is dug:
	# its way to the alarm is open ground)
	var ox := x0 + 27   # clear of the trench: the zombie's way is open ground
	var oz := z0 + 4
	var ob := Vector3i(ox, y, oz)
	var pl := Vector3i(ox - 1, y, oz)
	var al := Vector3i(ox - 2, y, oz)
	wr.place_device(ob, &"observer", false, false, 0)
	wr.place_device(pl, &"pulse", false, false, 1, 20)
	wr.place_device(al, &"alarm")
	var zb_at := Vector3((ox - 2.5) * stud, y * plate, (oz + 0.5) * stud + 8.0)
	var zombie = null
	if w.mobs != null:
		w.mobs.auto = false
		zombie = w.mobs.spawn_zombie(zb_at)
	# The player far the other way.
	w._fly_to(Vector3((ox - 2.5) * stud, y * plate + 1.0, (oz + 0.5) * stud - 25.0), Vector3(0, 0, 1))
	await w._frames(30)
	var at: Vector3 = wr.device_box(al).get_center()
	var d0: float = (zombie.last_feet as Vector3).distance_to(at) if zombie != null else 0.0
	w.terrain_edited(BrickTerrain.fill_box(Vector3i(ox + 1, y, oz), Vector3i(ox + 1, y + 2, oz), BrickTerrain.MAT_STONE, false))
	var sounded := false
	var siren := false
	for i in 20:
		await w._frames(2)
		if bool(wr.devices[al].on):
			sounded = true
			var snd := (wr.devices[al].node as Node3D).get_node_or_null("Siren") as AudioStreamPlayer3D
			siren = siren or (snd != null and snd.playing)
	var ad: Dictionary = wr.devices[al]
	g.check("a real ground edit before the observer: the alarm sounded (siren %s), called %d" % [siren, int(ad.get("called", 0))],
			sounded and siren and int(ad.get("calls", 0)) >= 1 and int(ad.get("called", 0)) >= 1)
	g.check("the zombie is called to the alarm (%s)" % (zombie.state if zombie != null else "no zombie"),
			zombie != null and zombie.called_to.distance_to(at) < 0.01)
	# Its path is asked for on a worker: give it up to 8 s to get going.
	var d1 := d0
	for i in 120:
		await w._frames(4)
		d1 = (zombie.last_feet as Vector3).distance_to(at) if zombie != null and is_instance_valid(zombie) else d0
		if d1 < d0 - 2.0 or d1 < MobZombie.CALL_THERE + 0.6:
			break
	var dp: float = (zombie.last_feet as Vector3).distance_to(w.player_feet_local()) if zombie != null else 0.0
	g.check("it walked toward the alarm (%.1f -> %.1f m), the player %.1f m away" % [d0, d1, dp],
			zombie != null and (d1 < d0 - 2.0 or d1 < MobZombie.CALL_THERE + 0.6))
	# The pulse is 20 ticks (2 s) from the edit: wait it out.
	for i in 60:
		await w._frames(3)
		if not bool(wr.devices[al].on):
			break
	g.check("the pulse over: the alarm quiet", not bool(wr.devices[al].on))
	if zombie != null and is_instance_valid(zombie) and zombie.pawn != null:
		zombie.pawn.health.apply_impact(1000.0, &"")

	# --- sensors and the counter (Docs/MineWiring.md 28), x0+2..12, z0+24..31
	var zs := z0 + 24
	# Motion sensor facing +z, a lamp at its left, a shooter of arrows at its
	# right facing the same way: what walks into view lights the lamp and
	# takes an arrow.
	var ms := Vector3i(x0 + 4, y, zs)
	wr.place_device(ms, &"motion_sensor", false, false, 2)
	var mlamp := Vector3i(x0 + 5, y, zs)
	wr.place_device(mlamp, &"lamp")
	var mshoot := Vector3i(x0 + 3, y, zs)
	wr.place_device(mshoot, &"dispenser", false, false, 2)
	wr.devices[mshoot].slots[0] = ItemStack.make(&"arrow", 8)
	w._fly_to(Vector3((x0 + 4.5) * stud, y * plate + 1.5, (zs - 8.0) * stud), Vector3(0, 0, 1))
	await w._frames(20)
	g.check("motion sensor: nobody in front, the lamp dark", not wr.is_lit(mlamp) and wr.output_of(ms) == 0)
	w._fly_to(Vector3((x0 + 4.5) * stud, y * plate, (zs + 3.5) * stud), Vector3(0, 0, -1))
	await w._frames(16)
	g.check("the player walks in front of it: the lamp lit (%d)" % wr.output_of(ms), wr.is_lit(mlamp))
	w._fly_to(Vector3((x0 + 4.5) * stud, y * plate + 1.5, (zs - 8.0) * stud), Vector3(0, 0, 1))
	var dark := false
	for i in 40:   # its hold is 5 ticks, the lamp a tick after
		await w._frames(3)
		if not wr.is_lit(mlamp):
			dark = true
			break
	g.check("gone: dark again", dark)
	var mz = null
	var fired0 := int(wr.devices[mshoot].get("fired", 0))
	if w.mobs != null:
		mz = w.mobs.spawn_zombie(Vector3((x0 + 3.5) * stud, y * plate, (zs + 5.5) * stud))
	var seen_z := false
	for i in 40:
		await w._frames(3)
		seen_z = seen_z or wr.output_of(ms) > 0
		if seen_z and int(wr.devices[mshoot].get("fired", 0)) > fired0:
			break
	g.check("a zombie walking into view: seen, and the shooter beside it fired (%d arrow)" % (int(wr.devices[mshoot].get("fired", 0)) - fired0),
			seen_z and int(wr.devices[mshoot].get("fired", 0)) > fired0)
	await w._frames(20)
	if mz != null and is_instance_valid(mz) and mz.pawn != null and not mz.dead:
		mz.pawn.health.apply_impact(1000.0, &"")
	# Light sensor -> number display, at noon, under a roof, at night.
	var ls := Vector3i(x0 + 8, y, zs)
	wr.place_device(ls, &"light_sensor")
	var lsdisp := Vector3i(x0 + 9, y, zs)
	wr.place_device(lsdisp, &"number_display", false, false, 3)
	var t0: float = w._time
	w._time = 0.5
	await w._frames(30)
	var noon: int = wr.output_of(ls)
	g.check("light sensor at noon under the open sky: %d (the display shows %d)" % [noon, wr.output_of(lsdisp)],
			noon >= 12 and wr.output_of(lsdisp) == noon)
	# A second light sensor in a closed room: walls two courses high and ONE
	# placed brick as its roof (loose roof bricks would fall to the collapse).
	var ls2 := Vector3i(x0 + 13, y, zs + 3)
	wr.place_device(ls2, &"light_sensor")
	var rlo := Vector3i(x0 + 11, y, zs + 1)
	var rhi := Vector3i(x0 + 15, y + 5, zs + 5)
	for bx2 in [[rlo, Vector3i(rhi.x, rhi.y, rlo.z)], [Vector3i(rlo.x, rlo.y, rhi.z), rhi],
			[rlo, Vector3i(rlo.x, rhi.y, rhi.z)], [Vector3i(rhi.x, rlo.y, rlo.z), rhi]]:
		w.terrain_edited(BrickTerrain.fill_box(bx2[0], bx2[1], BrickTerrain.MAT_STONE, false))
	var roof_lo := Vector3i(rlo.x, y + 6, rlo.z)
	var roof_hi := Vector3i(rhi.x, y + 8, rhi.z)
	var rres: Dictionary = BrickTerrain.fill_box(roof_lo, roof_hi, BrickTerrain.MAT_STONE, true)
	BrickTerrain.mark_placed(roof_lo, roof_hi, BrickTerrain.MAT_STONE)
	w.terrain_edited(rres)
	var roofed := noon
	for i in 100:   # the sky level is read from the rebaked tile: a few seconds
		await w._frames(3)
		roofed = wr.output_of(ls2)
		if roofed < noon and roofed >= 0 and wr.devices.has(ls2):
			break
	g.check("one in a closed room: darker (%d against %d outside)" % [roofed, noon], wr.devices.has(ls2) and roofed < noon)
	w._time = 0.0
	await w._frames(80)   # it looks again every LIGHT_EVERY ticks (1 s)
	g.check("midnight: 0 (%d)" % wr.output_of(ls), wr.output_of(ls) == 0)
	w._time = t0
	# Fluid sensor facing +z, a lamp at its side; water poured in front.
	var fsn := Vector3i(x0 + 2, y, zs + 4)
	wr.place_device(fsn, &"fluid_sensor", false, false, 2)
	var flamp := Vector3i(x0 + 1, y, zs + 4)
	wr.place_device(flamp, &"lamp")
	await w._frames(16)
	g.check("fluid sensor: dry in front, dark", not wr.is_lit(flamp))
	BrickFluid.place(Vector3i(x0 + 2, floori(y / 3.0), zs + 5), 1, BrickFluid.STILL, 3)
	var wet := 0
	for i in 30:
		await w._frames(3)
		wet = wr.output_of(fsn)
		if wet > 0 and wr.is_lit(flamp):
			break
	g.check("water poured in front: %d, the lamp lit" % wet, wet > 0 and wr.is_lit(flamp))
	# Counter (N = 3): a button at its back, a lamp at its front.
	var cnt := Vector3i(x0 + 8, y, zs + 4)
	wr.place_device(cnt, &"counter", false, false, 2)
	var cbtn := Vector3i(x0 + 8, y, zs + 3)
	wr.place_device(cbtn, &"button")
	var clamp_ := Vector3i(x0 + 8, y, zs + 5)
	wr.place_device(clamp_, &"lamp")
	await w._frames(14)
	var lit := ""
	for k in 3:
		wr.use_device(cbtn)
		var any := false
		for i in 12:
			await w._frames(2)
			any = any or wr.is_lit(clamp_)
		lit += "1" if any else "0"
		for i in 30:   # the button is on for a second: let it go off
			await w._frames(2)
	g.check("the button pressed 3 times through a counter: its lamp flashes on the third only (%s)" % lit, lit == "001")
	await g._picture(Vector3((x0 + 6) * stud, y * plate, (zs + 2) * stud), Vector3(-2.5, 2.8, -4.0), "wiring_sensors.png")

	# --- release bricks under a bridge, a trip string on the way to it
	var xb := x0 + 14
	var zb := z0 + 18
	# The trench: 8 studs across (x), 4 long (z), 4 bricks deep.
	w.terrain_edited(BrickTerrain.fill_box(Vector3i(xb, top - 11, zb), Vector3i(xb + 7, top, zb + 3), 0, false))
	await w._frames(20)
	var rels: Array[Vector3i] = []
	for z in range(zb, zb + 4):
		for x in [xb - 1, xb + 8]:
			var r := Vector3i(x, y, z)
			wr.place_device(r, &"release_brick")
			rels.append(r)
	await w._frames(14)
	var all_held := true
	for r in rels:
		all_held = all_held and wr.devices.has(r) and BrickTerrain.solid_at(r.x, r.y + 1, r.z) != 0
	g.check("8 release bricks on the trench's rims, real ground now", all_held)
	# Aimed at from the side: the release brick is the target, with its face.
	var rr: Vector3i = rels[0]
	var raim := wr.device_box(rr).get_center()
	var rfrom := raim + Vector3(-1.4, 0.3, 0.0)
	var rdir := (raim - rfrom).normalized()
	w._fly_to(rfrom - Vector3(0, 1.6, 0), Vector3(rdir.x, 0, rdir.z))
	w.walker.pitch = asin(clampf(rdir.y, -1.0, 1.0))
	await w._frames(6)
	g._hold(&"stone")
	w.builder.update_target()
	var tgt: Dictionary = w.builder.target
	g.check("looking at a release brick, it is the target, with its face (%s)" % str(tgt),
			tgt.get("device", Vector3i(0, -9999, 0)) == rr and tgt.has("cell"))
	# The bridge: two lapped courses of stone (one course alone is a row of
	# bricks joined to nothing beside them), 4 studs wide, on the release
	# bricks, over the trench.
	w.terrain_edited(BrickTerrain.fill_box(Vector3i(xb - 1, y + 3, zb), Vector3i(xb + 8, y + 8, zb + 3), BrickTerrain.MAT_STONE, false))
	var mid := Vector3i(xb + 4, y + 4, zb)
	await w._frames(40)
	g.check("the bridge stands on them", BrickTerrain.solid_at(mid.x, mid.y, mid.z) != 0)
	# Wire: the hook at the near side -> the near release bricks; round the
	# trench's end to the far ones.
	var ha := Vector3i(xb - 3, y, zb - 2)
	var hb := Vector3i(xb - 3, y, zb + 3)
	wr.place_device(ha, &"trip_hook", false, false, 2)
	wr.place_device(hb, &"trip_hook", false, false, 3)
	for z in range(zb - 2, zb + 6):
		wr.place_cable(Vector3i(xb - 2, y, z))
	for x in range(xb - 1, xb + 10):
		wr.place_cable(Vector3i(x, y, zb + 5))
	for z in range(zb, zb + 5):
		wr.place_cable(Vector3i(xb + 9, y, z))
	await w._frames(14)
	g.check("the hooks pair across the way", wr.pairs.get(ha, Vector3i.ZERO) == hb)
	var groups0: int = w.collapse.groups_let_go if w.collapse != null else 0
	await g._picture(Vector3((xb + 4) * stud, y * plate, (zb + 1) * stud), Vector3(-4.5, 3.2, -4.5), "wiring_bridge.png")
	# The player crosses the string.
	w._fly_to(Vector3((xb - 2.5) * stud, y * plate, (zb + 0.5) * stud), Vector3(0, 0, 1))
	await w._frames(14)
	var let_go := true
	for r in rels:
		let_go = let_go and bool(wr.devices[r].on)
	g.check("the string crossed: all 8 release bricks let go (cells air)", let_go
			and BrickTerrain.solid_at(rels[0].x, y + 1, rels[0].z) == 0 and BrickTerrain.solid_at(rels[7].x, y + 1, rels[7].z) == 0)
	w._fly_to(Vector3((xb - 6.0) * stud, y * plate + 2.0, (zb - 6.0) * stud), Vector3(1, 0, 1).normalized())
	var fell := false
	for i in 60:
		await w._frames(3)
		if BrickTerrain.solid_at(mid.x, mid.y, mid.z) == 0:
			fell = true
			break
	var groups1: int = w.collapse.groups_let_go if w.collapse != null else 0
	g.check("the collapse dropped the bridge (%d groups let go, its middle %s)" % [groups1 - groups0, "air" if fell else "still there"],
			fell and groups1 > groups0)
	await g._picture(Vector3((xb + 4) * stud, (y - 4) * plate, (zb + 1) * stud), Vector3(-4.5, 3.6, -4.5), "wiring_bridge_fell.png")
	for i in 30:
		await w._frames(4)
	var gripped := true
	for r in rels:
		gripped = gripped and not bool(wr.devices[r].on) and BrickTerrain.solid_at(r.x, r.y + 1, r.z) != 0
	g.check("2 s later, nobody on the string: they grip again (solid)", gripped)

	# --- save: generated again
	w.generate(w.settings)
	await w._frames(30)
	var dd2: Dictionary = wr.devices.get(disp, {})
	g.check("after generating again: the gun still in the dispenser", not dd2.is_empty() and dd2.slots[0] != null
			and MineHands.is_gun(dd2.slots[0]))
	var held2 := true
	for r in rels:
		held2 = held2 and wr.devices.has(r) and not bool(wr.devices[r].on) and BrickTerrain.solid_at(r.x, r.y + 1, r.z) != 0
	g.check("the release bricks back, holding; the alarm there", held2 and wr.devices.has(al))


func _solid_count(lo: Vector3i, hi: Vector3i) -> int:
	var n := 0
	for x in range(lo.x, hi.x + 1):
		for yy in range(lo.y, hi.y + 1):
			for z in range(lo.z, hi.z + 1):
				if BrickTerrain.solid_at(x, yy, z) != 0:
					n += 1
	return n
