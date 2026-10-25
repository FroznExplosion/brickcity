extends SceneTree

## Mech pods (Docs/ModularParts.md section 4, "Pods"; stage 7), headless.
##
##     godot --headless --path . --script res://tools/pods_probe.gd
##
##   roll       the same seed, the same pod; every kind of each sort; a pod body says which
##              sort it carries; rarity makes it stronger; names from the pods' own words,
##              never a gun's; a body's name fragment names it; a round trip by its seed
##   fit        two slots; a shield booster makes the shield bigger and stays as full; two
##              stack; taken off, back as it was; on new layers (a chassis's class) it holds
##   use        a passive is not used; a missile pod fires its burst, then cools; a strike
##              arm hits the enemy mech in reach and only that
##   loot       a pod on the ground: a block in a beam of its rarity's colour, its name over it;
##              the player out of reach does not take it, in reach does, once
##   screen     the backpack's mech page: fit from the stash, swap, take off; its text; swap
##              weapon steps to it after the skills when there is a mech

var _pass := 0
var _fail := 0


func _init() -> void:
	print("pods probe")
	_run.call_deferred()


func _ok(what: String, cond: bool, detail: String = "") -> void:
	if cond:
		_pass += 1
		print("  ok   %s%s" % [what, ("  " + detail) if detail else ""])
	else:
		_fail += 1
		print("  FAIL %s%s" % [what, (" -- " + detail) if detail else ""])


func _run() -> void:
	_roll()
	await _fit_and_use()
	await _loot()
	_screen()
	print("pods probe: %d passed, %d failed" % [_pass, _fail])
	quit(1 if _fail > 0 else 0)


func _roll() -> void:
	print("roll")
	var a := PodGenerator.generate(41)
	var b := PodGenerator.generate(41)
	_ok("the same seed, the same pod", a.pod_name == b.pod_name and a.kind == b.kind and a.stats == b.stats,
			a.pod_name)
	var sorts := {}
	for s in 200:
		sorts[PodGenerator.generate(s).sort] = true
	_ok("all three sorts roll", sorts.size() == 3, str(sorts.keys()))
	var body := PartRecord.from_dict({"id": "pb", "family": "pod", "slot": "pod", "pod_kind": "passive",
			"mount": {"interface": "mech.pod"}})
	var only_passive := true
	for s in 50:
		only_passive = only_passive and PodGenerator.generate(s, -1, 1, &"", body).sort == "passive"
	_ok("a passive body only carries passives", only_passive)
	_ok("asked for a kind it cannot carry: one it can", PodGenerator.generate(1, 2, 1, &"missiles", body).sort == "passive")
	var lo := PodGenerator.generate(7, 1, 1, &"missiles")
	var hi := PodGenerator.generate(7, 5, 1, &"missiles")
	_ok("legendary hits harder than common", float(hi.stats.power) > float(lo.stats.power))
	# The grade word is shared with guns on purpose (one grade scale); the rest is the pods'.
	var gun_words := {}
	for w in GunGenerator.NAME_NOUNS:
		gun_words[w] = true
	for w in GunPlaceholderParts.HEAVY_NOUNS:
		gun_words[w] = true
	var clean := true
	var nouns_ok := true
	for s in 120:
		var p := PodGenerator.generate(s)
		for w in p.pod_name.trim_prefix(p.grade_word).split(" ", false):
			if gun_words.has(w):
				clean = false
				print("    clash: ", w, " in ", p.pod_name)
		nouns_ok = nouns_ok and p.pod_name.split(" ")[-1] in PodGenerator.NOUNS[p.kind]
	_ok("no gun's word in a pod's name", clean)
	_ok("its noun is its kind's", nouns_ok)
	var named := PartRecord.from_dict({"id": "nb", "family": "pod", "slot": "pod", "mount": {"interface": "mech.pod"},
			"name_fragment": "Crowbox"})
	_ok("a body's name fragment names it", PodGenerator.generate(3, 2, 1, &"", named).pod_name.ends_with("Crowbox"))
	var back := PodGenerator.deserialize(a.serialize())
	_ok("a round trip by its seed", back.pod_name == a.pod_name and back.stats == a.stats)


func _fit_and_use() -> void:
	print("fit")
	var lib := GunPlaceholderParts.build_library()
	var m := Mech.spawn(root, Vector3.ZERO, 0.0, 0)
	await physics_frame
	var pods := MechPods.attach(m, lib)
	var shield0: float = m.health.layer_configs[0].max_value
	var boost := PodGenerator.generate(5, 2, 1, &"shield_boost")
	pods.fit(1, boost)
	var want := shield0 * (1.0 + float(boost.stats.shield))
	_ok("a shield booster makes the shield bigger", is_equal_approx(m.health.layer_configs[0].max_value, want),
			"%s -> %s" % [shield0, m.health.layer_configs[0].max_value])
	_ok("and as full as it was", is_equal_approx(m.health.get_layer_fraction(0), 1.0))
	pods.fit(0, PodGenerator.generate(6, 2, 1, &"shield_boost"))
	_ok("two stack", m.health.layer_configs[0].max_value > want)
	pods.take_off(0)
	pods.take_off(1)
	_ok("taken off: back as it was", is_equal_approx(m.health.layer_configs[0].max_value, shield0))
	pods.fit(1, boost)
	m._set_layers(MechAssembler.CLASS_LAYERS.heavy)
	_ok("new layers (a heavy chassis): the booster on them", is_equal_approx(m.health.layer_configs[0].max_value,
			600.0 * (1.0 + float(boost.stats.shield))), str(m.health.layer_configs[0].max_value))
	var plate := PodGenerator.generate(8, 2, 1, &"directional_shield")
	pods.fit(0, plate)
	_ok("a brace plate: more armour", is_equal_approx(m.health.layer_configs[1].max_value,
			2400.0 * (1.0 + float(plate.stats.armor))))

	print("use")
	_ok("a passive is not used", not pods.use(1))
	var missiles := PodGenerator.generate(9, 2, 1, &"missiles")
	pods.fit(0, missiles)
	var fired := [0]
	(pods._guns[0] as GunController).fired.connect(func(_i: Dictionary) -> void: fired[0] += 1)
	_ok("a missile pod goes off", pods.use(0) and pods.cool[0] > 0.0)
	_ok("not again while it cools", not pods.use(0))
	for i in 1200:
		await physics_frame
		if pods._bursts[0] == 0:
			break
	_ok("its burst fired", fired[0] == int(missiles.stats.shots) and pods._bursts[0] == 0,
			"%d of %d" % [fired[0], missiles.stats.shots])
	var arm := PodGenerator.generate(10, 2, 1, &"melee_arm")
	pods.fit(1, arm)
	_ok("a strike arm with nobody in reach: nothing", not pods.use(1))
	# Beside it where it is now (with no floor here, it has been falling).
	var friend := Mech.spawn(root, m.feet() + Vector3(4, 0, 0), 0.0, 0)
	var foe := Mech.spawn(root, m.feet() + Vector3(0, 0, 5), 0.0, 1)
	var before := foe.health.total_current()
	var friend_before := friend.health.total_current()
	_ok("a strike arm hits the enemy in reach", pods.use(1) and foe.health.total_current() < before,
			"%s -> %s" % [before, foe.health.total_current()])
	_ok("and not its own side", is_equal_approx(friend.health.total_current(), friend_before))


func _loot() -> void:
	print("loot")
	var pod := PodGenerator.generate(77, 5, 1, &"missiles")
	var w := WorldPodPickup.create(pod)
	root.add_child(w)
	w.global_position = Vector3(100, 0, 100)
	var beam := (w.get_node(^"Beam") as MeshInstance3D).material_override as StandardMaterial3D
	_ok("a block in a beam of its rarity's colour, its name over it", beam != null
			and beam.albedo_color.is_equal_approx(Color(WorldPodPickup.rarity_colour(5), 0.55))
			and (w.get_node(^"Tag") as Label3D).text == pod.pod_name)
	var got := []
	w.picked.connect(func(p: PodGenerator.Result) -> void: got.append(p))
	var player := Node3D.new()
	root.add_child(player)
	player.global_position = Vector3(100, 0, 105)
	w.taker_of = func() -> Node3D: return player
	_ok("out of reach: not taken", not w.check() and got.is_empty())
	player.global_position = Vector3(100, 0, 101)
	_ok("in reach: taken, the pod it holds", w.check() and got == [pod])
	_ok("once", not w.check() and got.size() == 1)
	await process_frame
	_ok("and gone from the ground", not is_instance_valid(w))
	var w2 := WorldPodPickup.create(pod)
	root.add_child(w2)
	w2.taker_of = func() -> Node3D: return null   # the player in a mech: not on foot
	_ok("nobody on foot: not taken", not w2.check())
	w2.queue_free()
	player.queue_free()


func _screen() -> void:
	print("screen")
	var m := Mech.spawn(root, Vector3(60, 0, 0), 0.0, 0)
	var pods := MechPods.attach(m)
	var sc := MechLoadoutScreen.new()
	root.add_child(sc)
	sc.pods = pods
	for k in [&"shield_boost", &"directional_shield", &"laser"]:
		sc.stash.append(PodGenerator.generate(20, 2, 1, k))
	sc.index = 0
	_ok("fit from the stash", sc.fit_selected(0) and pods.slots[0] != null and sc.stash.size() == 2)
	var first: PodGenerator.Result = pods.slots[0]
	sc.index = 0
	sc.fit_selected(0)
	_ok("fit over one: it goes back to the stash", sc.stash.size() == 2 and first in sc.stash)
	_ok("take off", sc.take_off(0) and pods.slots[0] == null and sc.stash.size() == 3)
	sc.fit_selected(1)
	var t := sc.text()
	_ok("its text: the slots and the pods", t.contains("left pod") and t.contains("right pod")
			and t.contains((pods.slots[1] as PodGenerator.Result).pod_name) and t.contains("Up / Down"), t.substr(0, 120))
	var ars := PlayerArsenal.new()
	root.add_child(ars)
	ars.mech_screen = sc
	ars.inventory_open = true
	var pages := [ars.inventory_page]
	for i in 3:
		var e := InputEventAction.new()
		e.action = &"swap_weapon"
		e.pressed = true
		ars._inventory_input(e)
		pages.append(ars.inventory_page)
	_ok("swap weapon: backpack, skills, mech, backpack", pages == [0, 1, 3, 0], str(pages))
	ars.mech_screen = null
	ars.inventory_page = 1
	var e2 := InputEventAction.new()
	e2.action = &"swap_weapon"
	e2.pressed = true
	ars._inventory_input(e2)
	_ok("no mech: no mech page", ars.inventory_page == 0)
