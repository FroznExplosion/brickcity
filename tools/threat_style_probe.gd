extends SceneTree

## Acceptance probe for the commander answering the player (Docs/AIPlan.md P9;
## AI.md 9, A7, A14).
##
##     godot --headless --path . --script tools/threat_style_probe.gd
##
## Two scripted players, three minutes each, as the host reports them to the
## commander's ThreatProfile:
##
##   A  a DEMOLISHER whose MECH does the killing: hundreds of bricks a minute,
##      kills mostly the mech's
##   B  a CAREFUL PILOT: hardly a brick broken, kills mostly on foot
##
## Each encounter ends into a CharacterSave, written to disk. The NEXT encounter
## is a fresh commander that knows the player only from the save, and its
## doctrine and rosters must differ, measurably, between A and B -- within the
## clamps (no weight outside x0.5..x2 of its base). The save keeps the character,
## the mech, the guns (made again the same from what made them) and missions.
## Then the FRIENDLY side: a player-side commander keeps its squad with the
## player (Commander.rally) as the player walks off.

const Arena := preload("res://tools/ai_arena.gd")
const DRAWS := 400

var _pass := 0
var _fail := 0
var a: Arena
var lib: GunPartLibrary
var _tick := 0
var _t0 := -1.0
var _friend: Commander
var _fsquad: Squad
var _player: Pawn
var _log := {}


func _init() -> void:
	print("threat style probe")
	lib = GunPlaceholderParts.build_library()
	_styles()
	a = Arena.new(self, 9)
	physics_frame.connect(_on_tick)


func _ok(what: String, cond: bool, detail: String = "") -> void:
	if cond:
		_pass += 1
		print("  ok   %s%s" % [what, ("  " + detail) if detail else ""])
	else:
		_fail += 1
		print("  FAIL %s%s" % [what, (" -- " + detail) if detail else ""])


## Three minutes of one style, a second at a time, as a host reports it.
func _play(style: String) -> ThreatProfile:
	var p := ThreatProfile.new()
	for t in 180:
		p.decay(1.0)
		if style == "A":
			p.note_bricks(4)                    # a blast a second
			p.note_shot(true, 26.0, false, 2)
			if t % 8 == 0:
				p.note_kill(true)               # the mech's
			if t % 45 == 0:
				p.note_kill(false)
			p.sample(20.0, 1.0)
		else:
			p.note_shot(t % 3 != 0, 15.0, false, 0)
			if t % 8 == 0:
				p.note_kill(false)              # the pilot's
			if t % 45 == 0:
				p.note_kill(true)
			p.sample(14.0, 1.0)
	return p


## An encounter over: into a save, on disk, with a character, a mech and guns.
func _save(style: String, p: ThreatProfile) -> String:
	var s := CharacterSave.new()
	s.character["name"] = "Player " + style
	s.character["level"] = 7
	s.missions = {"clear_block_3": {"state": "done"}, "find_the_radio": {"state": "open", "progress": 2}}
	for i in 3:
		var g := GunInstance.from_result(GunGenerator.generate(lib, 1000 + i + (50 if style == "A" else 0),
				WeaponClass.builtin([&"rifle", &"smg", &"shotgun"][i]), 3))
		s.guns.append(CharacterSave.gun_entry(g))
		_log["gun_%s_%d" % [style, i]] = [g.gun_name, g.stats.duplicate()]
	var cm := Commander.new()
	cm.profile = p
	var table := AggroTable.new()
	var pilot := RefCounted.new()
	var mech := RefCounted.new()
	table.track(pilot, 0, "pilot")
	table.track(mech, 0, "mech")
	table.add(pilot, 30.0 if style == "A" else 80.0)
	table.add(mech, 70.0 if style == "A" else 20.0)
	s.take_encounter(cm, table, 0)
	cm.free()
	var path := "user://threat_style_%s.json" % style
	s.save(path)
	return path


## The next encounter: a fresh commander that knows the player only from the save.
func _next_encounter(path: String) -> Dictionary:
	var s := CharacterSave.load_from(path)
	var cm := Commander.new()
	cm.profile = s.profile()
	cm.doctrine.update(cm.profile, 0.0, 0.6)
	var rng := RandomNumberGenerator.new()
	rng.seed = 42
	var counts := {}
	var n := 0
	for i in DRAWS:
		for k in cm.doctrine.draw(Commander.SQUAD_SIZE, 30.0, rng):
			counts[k] = int(counts.get(k, 0)) + 1
			n += 1
	var share := {}
	for k in counts:
		share[k] = float(counts[k]) / maxf(n, 1)
	var clamped := true
	for id in Doctrine.BASE:
		var w := float(cm.doctrine.roster[id]) / float(Doctrine.BASE[id])
		if w < 0.5 - 1e-4 or w > 2.0 + 1e-4:
			clamped = false
	var out := {"save": s, "style": cm.profile.style(), "armor": cm.profile.armor_style(),
			"share": share, "inside": cm.doctrine.inside_share, "focus": cm.doctrine.pilot_focus,
			"aggression": cm.doctrine.aggression, "clamped": clamped, "profile": cm.profile,
			"roster_rocketeer": float(cm.doctrine.roster[&"rocketeer"])}
	cm.free()
	return out


func _styles() -> void:
	var pa := _play("A")
	var pb := _play("B")
	var da := pa.to_dict()
	var ea := _next_encounter(_save("A", pa))
	var eb := _next_encounter(_save("B", pb))
	_ok("the two players are read as what they are",
			ea.style == "demolisher" and ea.armor == "mech" and eb.style != "demolisher" and eb.armor == "pilot",
			"A %s / %s, B %s / %s" % [ea.style, ea.armor, eb.style, eb.armor])
	var back: Dictionary = (ea.profile as ThreatProfile).to_dict()
	var same := true
	for k in da:
		if absf(float(da[k]) - float(back[k])) > 1e-4:
			same = false
	var sa: CharacterSave = ea.save
	var guns_same := true
	for i in sa.guns.size():
		var g := CharacterSave.make_gun(sa.guns[i], lib)
		var was: Array = _log["gun_A_%d" % i]
		if g.gun_name != was[0] or g.stats != was[1]:
			guns_same = false
	_ok("the save carries the player to the next encounter: profile, character, missions, guns made again the same",
			same and sa.character.name == "Player A" and int(sa.character.level) == 7
			and str(sa.missions.find_the_radio.state) == "open" and guns_same and sa.guns.size() == 3,
			"%d gun(s), aggro %s" % [sa.guns.size(), sa.aggro])
	var ra := float(ea.share.get(&"rocketeer", 0.0))
	var rb := float(eb.share.get(&"rocketeer", 0.0))
	var ma := float(ea.share.get(&"marksman", 0.0))
	var mb := float(eb.share.get(&"marksman", 0.0))
	var hunt_a := float(ea.share.get(&"assault", 0.0)) + ma
	var hunt_b := float(eb.share.get(&"assault", 0.0)) + mb
	_ok("against the mech that kills: it goes for the pilot -- the troops that reach and pick them off, and its fire",
			hunt_a - hunt_b > 0.05 and float(ea.focus) >= 0.5 and float(eb.focus) == 0.0
			and float(ea.roster_rocketeer) > float(eb.roster_rocketeer),
			"assault + marksmen %.1f %% vs %.1f %% of %d squads; pilot focus %.1f vs %.1f; rocketeer weight %.2f vs %.2f (not fielded yet: %.1f %%)" % [
			hunt_a * 100.0, hunt_b * 100.0, DRAWS, float(ea.focus), float(eb.focus),
			float(ea.roster_rocketeer), float(eb.roster_rocketeer), ra * 100.0])
	_ok("against the demolisher: out of the buildings, marksmen from outside; the careful player: in",
			float(ea.inside) < 0.4 and float(eb.inside) >= 0.8 and ma > mb * 1.5,
			"inside share %.2f vs %.2f; marksmen %.1f %% vs %.1f %%" % [float(ea.inside),
			float(eb.inside), ma * 100.0, mb * 100.0])
	_ok("and no counter is a hard counter: every weight within x0.5..x2 of its base",
			bool(ea.clamped) and bool(eb.clamped))
	# The commander hands its pilot focus to its side's aggro.
	var s := AIServices.new()
	var cm := Commander.new()
	cm.setup(s, 1)
	cm.profile = ea.profile
	cm.think(1.0)
	_ok("its pilot focus goes into the side's aggro: gains on the pilot count more",
			is_equal_approx(float(s.aggro_of(1).bias.pilot), 1.0 + float(ea.focus)),
			"pilot bias %.2f" % float(s.aggro_of(1).bias.pilot))
	cm.free()


# --- the friendly side ------------------------------------------------------------------

func _on_tick() -> void:
	_tick += 1
	if _tick == 1:
		_player = a.player(Vector3.ZERO)
		var members: Array[Soldier] = []
		for i in 4:
			var so := a.soldier(a.s.ai_nav.snap(Vector3(-40.0 + i * 1.2, 0.0, 10.0)), 0, 70 + i)
			members.append(so)
		_fsquad = Squad.make(a.s, root, members, 0)
		_friend = Commander.new()
		_friend.name = "FriendlyCommander"
		root.add_child(_friend)
		_friend.setup(a.s, 0)
		_friend.adopt(_fsquad)
		_log["d0"] = _fsquad.center().distance_to(_player.feet())
		return
	a.tick()
	var now := a.s.now()
	if _t0 < 0.0:
		_t0 = now
	var t := now - _t0
	# The player walks off; the friendly commander's rally is where the player is.
	_player.intents.move = Vector3.BACK if t > 2.0 and t < 12.0 else Vector3.ZERO
	_friend.rally = _player.feet()
	if t >= 40.0:
		var d := _fsquad.center().distance_to(_player.feet())
		var moved := int(_friend.orders_given.get("MOVE", 0))
		_ok("the friendly side: its commander keeps its squad with the player",
				moved >= 1 and d < 12.0,
				"%d MOVE order(s); %.1f m -> %.1f m from the player" % [moved, float(_log.d0), d])
		print("\n%d passed, %d failed" % [_pass, _fail])
		quit(1 if _fail > 0 else 0)
