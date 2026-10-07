class_name Roster
extends RefCounted
## Every type that fights, as a recipe of parts (Docs/AIRoster.md): body, size,
## class and grade, attack, role, mods, phases -- and everything worked out from
## them. Authored on the Tactics Casebook page's Roster tab and written to
## data/ai/roster.json by tools/tactics_export.js, which runs the page's own
## code: this class derives nothing, it reads.
##
##   derived.layers   [[layer type, melees], ...] top first -- EnemyProfiles' rows
##   derived.mech     a mech's pools: shield, armor, health, hatch, cell_door...
##   derived.tag      what shows over its head ("Heavy Gunner Nuker")
##   derived.facts    the casebook facts it brings (we_melee, we_leader...)
##   derived.tier     the best brain it may run: smart, directed, swarm
##   derived.points   what it costs a commander
##   derived.phases   what it becomes, and when
##
## UnitCatalog reads a unit's health, weapon, points and name from here (AIRoster.md
## RO2), so changing a recipe on the page changes the unit in the game.

const PATH := "res://data/ai/roster.json"

var parts := {}
var recipes := {}

static var _shared: Roster
static var _shared_tried := false


## The one roster the game runs on, loaded the first time it is asked for. Null
## (once, loudly) if it will not load: callers fall back to UnitCatalog's own table.
static func shared() -> Roster:
	if not _shared_tried:
		_shared_tried = true
		_shared = load_roster()
	return _shared


static func load_roster(path := PATH) -> Roster:
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		push_error("Roster: can't open %s" % path)
		return null
	var d = JSON.parse_string(f.get_as_text())
	if not d is Dictionary or not d.has("recipes"):
		push_error("Roster: %s is not a roster" % path)
		return null
	var r := Roster.new()
	r.parts = d.get("parts", {})
	r.recipes = d.recipes
	return r


func has(id: String) -> bool:
	return recipes.has(id)


func ids() -> Array:
	return recipes.keys()


func recipe(id: String) -> Dictionary:
	return recipes.get(id, {})


func derived(id: String) -> Dictionary:
	return recipe(id).get("derived", {})


## Can it be fielded: no errors in its recipe.
func fit(id: String) -> bool:
	return has(id) and (derived(id).get("errors", []) as Array).is_empty()


## What shows over its head.
func tag(id: String) -> String:
	return str(derived(id).get("tag", ""))


## Its name: the recipe's own, else its tag.
func name_of(id: String) -> String:
	return str(derived(id).get("name", id))


func facts(id: String) -> Array:
	return derived(id).get("facts", [])


func points(id: String) -> float:
	return float(derived(id).get("points", 0.0))


## The recipe that stands for a UnitCatalog unit, or "".
func for_unit(unit: StringName) -> String:
	for id in recipes:
		if StringName(str(recipes[id].get("unit", ""))) == unit:
			return id
	return ""


## What a size's pathfinding is told (AINav.set_agent): [studs wide, plates of head
## room standing, squeezing, plates it steps up, drops off an edge, drops unhurt].
func size_nav(size: String) -> Array:
	return (parts.get("sizes", {}) as Dictionary).get(size, {}).get("nav", [])


## Its health layers at `level`, top first, ready for a HealthPool -- built as
## EnemyProfiles.layers builds a profile's. Empty for a mech (derived.mech).
func layers(id: String, level: int) -> Array[DefenseLayer]:
	var out: Array[DefenseLayer] = []
	for row in derived(id).get("layers", []):
		var type := StringName(str(row[0]))
		var l := DefenseLayer.new()
		l.layer_type = type
		l.max_value = CombatScale.layer_hp(type, float(row[1]), level)
		l.display_color = EnemyProfiles.COLOURS.get(type, Color.WHITE)
		if type == EnemyProfiles.SHIELD:
			l.regen_delay = CombatScale.SHIELD_REGEN_DELAY
			l.regen_rate = l.max_value / CombatScale.SHIELD_REGEN_SECONDS
		out.append(l)
	return out
