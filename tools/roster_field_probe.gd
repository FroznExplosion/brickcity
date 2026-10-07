extends SceneTree

## Probe for types fielded from recipes (Docs/AIRoster.md RO2).
##
##     godot --headless --path . --script tools/roster_field_probe.gd
##
## 1. UnitCatalog reads the roster: a unit's name, weapon, points and health come
##    from its recipe, and a type that exists only as a recipe is a unit too.
## 2. A soldier made a type carries the name over its head -- the side's colour,
##    readable to 45 m, hidden by walls -- and tells the casebook what it is.
## 3. Size decides where a body fits: through a door two studs wide a person has
##    a way and a large body has none; through one four studs wide both have,
##    and a huge body still has none.

const Arena := preload("res://tools/ai_arena.gd")

var _pass := 0
var _fail := 0
var a: Arena
var _tick := 0
var _so: Soldier
var _friend: Soldier
var _marks: Soldier
var _player: Pawn


func _init() -> void:
	print("roster field probe")
	a = Arena.new(self, 31)
	physics_frame.connect(_on_tick)


func _ok(what: String, cond: bool, detail: String = "") -> void:
	if cond:
		_pass += 1
		print("  ok   %s%s" % [what, ("  " + detail) if detail else ""])
	else:
		_fail += 1
		print("  FAIL %s%s" % [what, (" -- " + detail) if detail else ""])


func _catalog() -> void:
	var r := Roster.shared()
	var br := UnitCatalog.get_unit(&"breacher")
	_ok("a unit is read from its recipe: name, weapon, points",
			r != null and str(br.get("recipe", "")) == "breacher" and str(br.weapon) == "shotgun"
			and is_equal_approx(float(br.points), 1.5) and bool(br.built),
			"%s: %s, %s pts, recipe %s" % [br.name, br.weapon, br.points, br.get("recipe")])
	var same := true
	var totals := []
	for unit in [&"rifleman", &"assault", &"breacher", &"marksman", &"veteran"]:
		var p1 := HealthPool.new()
		var p2 := HealthPool.new()
		var got := UnitCatalog.apply_health(p1, unit, 3)
		var want := EnemyProfiles.apply(p2, UnitCatalog.UNITS[unit].profile, 3)
		totals.append("%s %.0f" % [unit, got])
		if not is_equal_approx(got, want):
			same = false
		p1.free()
		p2.free()
	_ok("and its health, the same as before for every unit fielded today", same, ", ".join(totals))
	var brute := UnitCatalog.get_unit(&"brute")
	var gnat := UnitCatalog.get_unit(&"gnat")
	var nobody := UnitCatalog.get_unit(&"no_such_thing")
	_ok("a type that exists only as a recipe is a unit, built or planned; one nobody knows is a rifleman",
			str(brute.get("recipe", "")) == "brute" and str(brute.name) == "Brute" and bool(brute.built)
			and is_equal_approx(float(brute.points), 4.0) and str(gnat.get("recipe", "")) == "gnat"
			and not bool(gnat.built) and str(nobody.weapon) == "rifle",
			"%s: %s pts, built %s; %s: built %s" % [brute.name, brute.points, brute.built, gnat.name, gnat.built])
	_ok("only units the game can field are offered to the commander",
			UnitCatalog.built().has(&"rifleman") and UnitCatalog.built().has(&"brute")
			and not UnitCatalog.built().has(&"rocketeer") and not UnitCatalog.built().has(&"gnat")
			and not UnitCatalog.built().has(&"mech"), str(UnitCatalog.built()))


func _setup() -> void:
	var r := Roster.shared()
	_player = a.player(Vector3(0.0, 0.0, -12.0))
	_so = a.soldier(Vector3(0.0, 0.0, 0.0), 1, 51)
	_so.set_type("breacher", r)
	_friend = a.soldier(Vector3(3.0, 0.0, 0.0), 0, 52)
	_friend.set_type("veteran", r)
	_marks = a.soldier(Vector3(-3.0, 0.0, 0.0), 1, 53)
	_marks.set_type("marksman", r)


func _tags() -> void:
	var t := _so.name_tag
	_ok("the name over an enemy's head says what it is", t != null and t.text == "Tough Breacher"
			and t.get_parent() == _so.pawn.body and t.modulate.is_equal_approx(Soldier.TAG_ENEMY),
			"\"%s\"" % (t.text if t != null else ""))
	var f := _friend.name_tag
	_ok("and over a non-player ally's, in the friendly colour", f != null and f.text.contains("Medium Rifleman")
			and f.modulate.is_equal_approx(Soldier.TAG_FRIEND), "\"%s\"" % (f.text if f != null else ""))
	_ok("readable to 45 m, hidden by walls, above the body", t != null and is_equal_approx(t.visibility_range_end, Soldier.TAG_RANGE)
			and not t.no_depth_test and t.position.y > Pawn.BODY_HEIGHT * 0.5)
	_so.set_name_tag("Heavy Melee")
	_ok("it follows a phase: the same label, new words", _so.name_tag == t and t.text == "Heavy Melee")
	var k := _marks.knowledge()
	k.saw(_player, _player.feet(), a.s.now(), _marks)
	var sense := TacticsSense.read(_marks, k.of(_player), {})
	_ok("the casebook is told what the type is", sense.facts.has("we_marksman") and _marks.type_id == "marksman",
			str(_marks.type_facts))


## Is there a way from outside a walled room to its middle, for a body of `size`?
func _way_in(size: String, x0: int, z0: int) -> bool:
	var nav := a.s.nav_for(size)
	var inside := Vector3((x0 + 8) * Arena.STUD, 0.0, (z0 + 8) * Arena.STUD)
	var outside := Vector3((x0 + 8) * Arena.STUD, 0.0, (z0 - 14) * Arena.STUD)
	return not nav.find_path(nav.snap(outside), nav.snap(inside), 60000).is_empty()


func _sizes() -> void:
	# Two rooms 16 studs square, walls 8 courses (3.4 m): one with a door two
	# studs wide (0.7 m), one with a door four studs wide (1.4 m).
	a.room(200, 0, 16, 16, 8, 207, 2)
	var narrow := {}
	var wide := {}
	for size in ["person", "large", "huge"]:
		narrow[size] = _way_in(size, 200, 0)
	a.room(400, 0, 16, 16, 8, 406, 4)
	for size in ["person", "large", "huge"]:
		wide[size] = _way_in(size, 400, 0)
	_ok("a door two studs wide: a person has a way in, a large body has none",
			bool(narrow.person) and not bool(narrow.large) and not bool(narrow.huge), str(narrow))
	_ok("a door four studs wide: a large body has a way too; a huge one still has none",
			bool(wide.person) and bool(wide.large) and not bool(wide.huge), str(wide))
	_ok("each size walks a map of its own, kept",
			a.s.nav_for("person") == a.s.ai_nav and a.s.nav_for("large") != a.s.ai_nav
			and a.s.nav_for("large") == a.s.nav_for("large") and a.s.nav_for("large").get_span() == 3
			and a.s.nav_for("huge").get_span() == 10)


func _on_tick() -> void:
	_tick += 1
	if _tick == 1:
		_catalog()
		_setup()
		return
	if _tick < 5:
		return
	_tags()
	_sizes()
	print("\n%d passed, %d failed" % [_pass, _fail])
	quit(1 if _fail > 0 else 0)
