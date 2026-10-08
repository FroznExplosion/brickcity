class_name TypeKit
extends RefCounted
## What every type on the roster has whatever its body (Docs/AIRoster.md 3): the
## name over its head and the moment a phase comes. A soldier, a flyer, and later
## a mech or a tank crew use these and keep only what is their own.

## How far a name can be read from, and its colours by side.
const TAG_RANGE := 45.0
const TAG_ENEMY := Color(1.0, 0.55, 0.42)
const TAG_FRIEND := Color(0.5, 0.78, 1.0)


## The words over a type's head: its own name first, unless the tag already says
## it ("Tough Breacher"); else "Veteran  ·  Medium Rifleman".
static func tag_text(derived: Dictionary) -> String:
	var tag := str(derived.get("tag", ""))
	var named := str(derived.get("name", tag))
	var plain := named == "" or tag.to_lower().contains(named.to_lower())
	return tag if plain else "%s  ·  %s" % [named, tag]


## A name over `body`, `above` its middle: the side's colour, readable to
## TAG_RANGE, and hidden by walls as the body is.
static func make_tag(body: Node3D, text: String, team: int, above: float) -> Label3D:
	var l := Label3D.new()
	l.name = "NameTag"
	l.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	l.fixed_size = true
	l.pixel_size = 0.0011
	l.font_size = 26
	l.outline_size = 7
	l.modulate = TAG_FRIEND if team == AIServices.PLAYER_SIDE else TAG_ENEMY
	l.visibility_range_end = TAG_RANGE
	l.position = Vector3.UP * above
	l.text = text
	body.add_child(l)
	return l


## Has the moment `when` come, for a body with this health in this squad (or none)?
static func phase_due(when: String, health: HealthPool, max_health: float, squad: Squad) -> bool:
	match when:
		"armour_gone": return layer_gone(health, EnemyProfiles.ARMOR)
		"shield_gone": return layer_gone(health, EnemyProfiles.SHIELD)
		"health_half": return health.total_current() < max_health * 0.5
		"leader_dead": return squad != null and squad.leader_lost
		"alone": return squad != null and squad.members.size() > 1 and squad.alive().size() <= 1
	return false


## It wore a layer of `type` and that layer is down.
static func layer_gone(health: HealthPool, type: StringName) -> bool:
	for i in health.layer_count():
		if health.layer_type_at(i) == type:
			return health.get_layer_value(i) <= 0.0
	return false


## The best tier a type may run: "smart", or the cheap ones.
static func tier_cap(tier_name: String) -> int:
	return AgentTier.SMART if tier_name == "smart" else AgentTier.DIRECTED
