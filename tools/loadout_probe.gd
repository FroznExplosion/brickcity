extends SceneTree

## The player's guns (Docs/Weapons/COMBAT_DESIGN.md 7): Loadout's rules, then
## PlayerArsenal putting them into a real GunController.
##
##     godot --headless --path . --script res://tools/loadout_probe.gd
##
##   tap / hold   tap swap is the other gun of the group; hold is the other group, at
##                the gun last held there; a tap with the other slot empty stays
##   slots        a slot key draws that slot's gun
##   ordnance     up and away again; a swap puts it away
##   third hand   a floor gun goes in hand without touching the four; a tap drops it;
##                a slot key keeps it there, the gun it replaced to the backpack;
##                stowed, it goes to the backpack; a full backpack refuses and the
##                replaced gun goes to the floor instead
##   backpack     a backpack gun swaps into a slot; dropped, it leaves
##   nothing lost every gun let go of comes back to the caller
##   arsenal      the gun in hand is the controller's; each gun keeps its magazine
##                over a swap; a dropped gun is a pickup on the floor; picking one up
##                takes it off the floor; hold swap changes group, tap does not;
##                hold reload picks up the gun in view

var _pass := 0
var _fail := 0


func _init() -> void:
	print("loadout probe")
	_run.call_deferred()


func _ok(what: String, cond: bool, detail: String = "") -> void:
	if cond:
		_pass += 1
		print("  ok   %s%s" % [what, ("  " + detail) if detail else ""])
	else:
		_fail += 1
		print("  FAIL %s%s" % [what, (" -- " + detail) if detail else ""])


func _ticks(n: int) -> void:
	for i in n:
		await physics_frame


func _gun(name: String) -> RefCounted:
	var o := RefCounted.new()
	o.set_meta(&"n", name)
	return o


func _n(o: Object) -> String:
	return str(o.get_meta(&"n")) if o != null else "-"


func _rules() -> void:
	var lo := Loadout.new()
	var a := _gun("A"); var b := _gun("B"); var c := _gun("C"); var d := _gun("D")
	lo.set_slot(0, a); lo.set_slot(1, b); lo.set_slot(2, c); lo.set_slot(3, d)
	_ok("starts on slot 1", lo.in_hand() == a)
	lo.tap_swap()
	_ok("tap swap: the other gun of the group", lo.in_hand() == b)
	lo.switch_group()
	_ok("hold swap: the other group", lo.in_hand() == c)
	lo.tap_swap()
	lo.switch_group()
	_ok("and back to the gun last held there", lo.in_hand() == b, _n(lo.in_hand()))
	lo.select(3)
	_ok("a slot key draws that slot", lo.in_hand() == d and lo.group == 1)
	var e := _gun("E")
	lo.set_slot(1, null)
	lo.select(0)
	lo.tap_swap()
	_ok("a tap with the other slot empty stays", lo.in_hand() == a)
	lo.set_slot(1, b)

	var o := _gun("O")
	lo.ordnance = o
	lo.toggle_ordnance()
	_ok("the ordnance comes up", lo.in_hand() == o)
	lo.tap_swap()
	_ok("and a swap puts it away", lo.in_hand() == a)

	var dropped := lo.pick_up(e)
	_ok("a floor gun goes in hand without touching the four", lo.in_hand() == e
			and dropped.is_empty() and lo.slots == [a, b, c, d])
	dropped = lo.tap_swap()
	_ok("a tap drops it, back to the gun held", dropped == [e] and lo.in_hand() == a
			and lo.third_hand == null)
	lo.pick_up(e)
	dropped = lo.select(2)
	_ok("a slot key keeps it there", lo.slots[2] == e and lo.in_hand() == e and dropped.is_empty())
	_ok("and the gun it replaced goes to the backpack", lo.backpack == [c])
	var f := _gun("F")
	lo.pick_up(f)
	_ok("stowed, it goes to the backpack", lo.stow() and lo.backpack == [c, f] and lo.third_hand == null)
	lo.backpack_size = 2
	var g := _gun("G")
	lo.pick_up(g)
	_ok("a full backpack refuses", not lo.stow() and lo.third_hand == g)
	dropped = lo.keep(0)
	_ok("and a replaced gun goes to the floor instead", dropped == [a] and lo.slots[0] == g)
	lo.equip_from_backpack(0, 3)
	_ok("a backpack gun swaps into a slot", lo.slots[3] == c and lo.backpack[0] == d)
	dropped = lo.drop_from_backpack(1)
	_ok("dropped, it leaves the backpack", dropped == [f] and lo.backpack == [d])
	var all := lo.all_guns()
	_ok("nothing lost: every gun is held or was handed back", all.size() == 6 and not all.has(a)
			and not all.has(f), "%d held" % all.size())


func _run() -> void:
	_rules()

	# --- the arsenal, with a real gun controller -----------------------------------
	var floor := StaticBody3D.new()
	floor.collision_layer = Layers.WORLD
	var fs := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(40.0, 1.0, 40.0)
	fs.shape = box
	floor.add_child(fs)
	root.add_child(floor)
	floor.global_position = Vector3(0.0, -0.5, 0.0)
	var world := Node3D.new()
	root.add_child(world)

	var pawn := Pawn.spawn(world, Vector3.ZERO, 0)
	var cam := Camera3D.new()
	world.add_child(cam)
	cam.current = true
	var pc := PlayerController.new()
	pc.drive_uncaptured = true
	world.add_child(pc)
	pc.possess(pawn, cam)
	var gc := GunController.new()
	gc.aim = cam
	gc.rng = RandomNumberGenerator.new()
	world.add_child(gc)
	pawn.gun = gc
	var lib := GunPlaceholderParts.build_library()
	var ars := PlayerArsenal.new()
	world.add_child(ars)
	ars.setup(pc, gc, null, null, lib, world, 1)
	var rng := RandomNumberGenerator.new()
	rng.seed = 5
	ars.fill_default(rng)
	await _ticks(3)
	var lo := ars.loadout
	_ok("the kit: four guns and an ordnance", lo.slots.count(null) == 0 and lo.ordnance != null)
	_ok("the gun in hand is the controller's", gc.gun == lo.in_hand() and gc.gun != null)

	var first := gc.gun
	gc.ammo = 3
	ars._apply(lo.tap_swap())
	_ok("a swap re-equips the controller", gc.gun == lo.slots[1] and gc.gun != first)
	_ok("the drawn gun has a full magazine", gc.ammo == gc.mag_size())
	ars._apply(lo.tap_swap())
	_ok("and the first keeps its magazine over the swap", gc.gun == first and gc.ammo == 3,
			"%d rounds" % gc.ammo)
	_ok("the holstered gun is in the tree, hidden", (lo.slots[1] as Node).is_inside_tree())

	# A gun on the floor, in front, picked up and dropped.
	var res := GunGenerator.generate(lib, 99, WeaponClass.builtin(&"smg"), 1, 3)
	var pickup := WorldGunPickup.create(lib, res)
	world.add_child(pickup)
	pickup.global_position = Vector3(0.0, 0.0, -1.2)
	cam.global_transform = Transform3D(Basis.looking_at(Vector3(0, 0.55, -1.2) - Vector3(0, 1.6, 0)),
			Vector3(0, 1.6, 0))
	# process_frame comes before the nodes' own _process: two, so the arsenal has looked.
	await process_frame
	await process_frame
	_ok("a floor gun in reach and view is the target", ars.target_pickup == pickup)
	ars.interact()
	await process_frame
	var gone := not is_instance_valid(pickup) or pickup.is_queued_for_deletion()
	_ok("hold reload picks it up: in hand, off the floor", lo.third_hand != null
			and gc.gun == lo.third_hand and (lo.third_hand as GunInstance).gun_seed == 99 and gone)
	var before := get_nodes_in_group(WorldGunPickup.GROUP).size()
	ars._apply(lo.tap_swap())
	await process_frame
	var after := get_nodes_in_group(WorldGunPickup.GROUP)
	_ok("tapped away, it is a pickup on the floor again", after.size() == before + 1
			and (after[after.size() - 1] as WorldGunPickup).result.seed == 99)
	_ok("and the hands have the gun they had", gc.gun == first)

	# Hold vs tap on the real input action.
	var g0 := lo.group
	Input.action_press(&"swap_weapon")
	var ev := InputEventAction.new()
	ev.action = &"swap_weapon"
	ev.pressed = true
	ars._unhandled_input(ev)
	await create_timer(PlayerArsenal.HOLD_SWAP + 0.15).timeout
	await process_frame
	Input.action_release(&"swap_weapon")
	_ok("swap held: the other group", lo.group == 1 - g0 and gc.gun == lo.in_hand())
	ars._unhandled_input(ev)
	Input.action_release(&"swap_weapon")
	await process_frame
	_ok("tapped: still that group", lo.group == 1 - g0)

	_ok("grenades start full", ars.grenades == PlayerArsenal.GRENADES_MAX)

	print("loadout probe: %d ok, %d FAIL" % [_pass, _fail])
	for c in root.get_children():
		c.queue_free()
	await _ticks(2)
	quit(1 if _fail > 0 else 0)
