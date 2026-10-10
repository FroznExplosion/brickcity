class_name Elements
extends RefCounted
## The game's elements and what each is strong against (Docs/Weapons/COMBAT_DESIGN.md
## section 5). One bonus each, and nothing is weak against an element: an element is
## extra damage where it fits and plain damage where it does not.
##
##   plasma     shield 2x
##   corrosive  armor 2x
##   acid       flesh 1.5x
##   fire       vegetation 2x (plant enemies)
##   ice        neutral damage; slows, then freezes (the status is a later step)
##
## Shock is not here: it belongs to special ordnance weapons. Explosive is not here
## either: it is an attachment.
##
## The single source of truth for both halves -- the Element resources a gun's rounds
## carry, and the EffectivenessMatrix every HealthPool reads unless given its own.

const PLASMA := &"plasma"
const CORROSIVE := &"corrosive"
const ACID := &"acid"
const FIRE := &"fire"
const ICE := &"ice"
## The elements a gun can roll (GunGenerator).
const GUN_ELEMENTS: Array[StringName] = [PLASMA, CORROSIVE, ACID, FIRE, ICE]
## Not an element a gun carries: the damage type of a melee (COMBAT_DESIGN 4.1), here
## so a HealthPool's matrix gives it its 1.5x on shields like any other row.
const MELEE := &"melee"

## [display name, colour, the word a gun's name takes from it]
const INFO := {
	PLASMA: ["Plasma", Color(0.35, 0.75, 1.0), "Charged"],
	CORROSIVE: ["Corrosive", Color(0.55, 0.9, 0.2), "Corroding"],
	ACID: ["Acid", Color(0.85, 1.0, 0.3), "Caustic"],
	FIRE: ["Fire", Color(1.0, 0.45, 0.1), "Burning"],
	ICE: ["Ice", Color(0.7, 0.92, 1.0), "Frozen"],
}

## Element -> {layer type: multiplier}. Flesh appears under both its names.
const TABLE := {
	PLASMA: {&"shield": 2.0},
	CORROSIVE: {&"armor": 2.0},
	ACID: {&"health": 1.5, &"flesh": 1.5},
	FIRE: {&"vegetation": 2.0},
	ICE: {},
	MELEE: {&"shield": CombatScale.SHIELD_MELEE},
}

static var _defs := {}
static var _matrix: EffectivenessMatrix


## The Element resource for `id`, or null for none / unknown.
static func get_def(id: StringName) -> Element:
	if id == &"" or not INFO.has(id):
		return null
	if not _defs.has(id):
		var e := Element.new()
		e.id = id
		e.display_name = INFO[id][0]
		e.color = INFO[id][1]
		# Empty: the element's part of a round lands on the TOP layer like the rest of
		# it (the defences sit over the flesh), multiplied by the matrix there.
		e.tuned_layer_type = &""
		_defs[id] = e
	return _defs[id]


## The word a gun's name takes from its element ("" for none).
static func word(id: StringName) -> String:
	return INFO[id][2] if INFO.has(id) else ""


## The matrix every HealthPool uses unless it was given one of its own.
static func matrix() -> EffectivenessMatrix:
	if _matrix == null:
		_matrix = EffectivenessMatrix.new()
		_matrix.table = TABLE.duplicate(true)
	return _matrix
