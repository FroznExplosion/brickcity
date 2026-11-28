class_name WiringGuide
extends RefCounted
## The wiring guide (the inventory screen's Wiring tab, beside Farming): how
## wiring works, then every wiring part by what it does -- its icon, what the
## item says, and a tip where one helps -- then traps to build. The parts'
## own lines come from the item catalog (content/base/data/items/wiring.json),
## so the guide and the items never say different things. Docs/MineWiring.md.

const HOW := [
	"1  GET THE PARTS: in creative, E > the Creative tab (search \"wire\", \"gate\", \"sensor\"...). There are no recipes for them yet.",
	"2  WIRE: right-click the top of the ground to lay a wire tile. Wires that touch -- side by side, or up or down a step of one brick -- are ONE circuit, and the whole circuit is on or off at once. There is no fading over distance and no need for repeaters.",
	"3  POWER: a part that gives power (a lever, a button, a sensor...) powers the wires and the parts right beside it. A part that uses power (a lamp, a door, a shooter...) works while a powered wire or part touches it. Parts never join circuits: two runs on either side of a lamp stay two circuits.",
	"4  LEVELS: power is a level from 0 to 15. Switches give 15; the light and fluid sensors give a level in between. Anything above 0 counts as on.",
	"5  FACING: some parts face a way (an arrow, a lens, a mouth). They are placed facing AWAY from you, so stand behind where they should point. Gates take their inputs at the back, left and right, and give their output only out of the front.",
	"6  THE WRENCH: hold it and every wire shows through walls; look at a wire or part to read its level, inputs and output. Right-click a facing part to turn it a quarter; shift + right-click any part to take it back.",
	"7  TIME: the wiring works in ticks, ten a second. A gate takes one tick; a delay 1-10; a sequencer runs a program of ticks.",
	"8  BREAKING: left-click a wire or part to take it. A shot cuts a wire or breaks a part, a grenade clears what is round it, and a part whose ground is dug out breaks -- so every trap can be disarmed by shooting its wire.",
]

## The groups of the page, in order: [title, ids].
const GROUPS := [
	["Wire and tools", [&"cable", &"wire_brick", &"wrench"]],
	["Switches", [&"lever", &"button", &"pressure_tile", &"trip_hook"]],
	["Sensors", [&"motion_sensor", &"light_sensor", &"fluid_sensor", &"observer"]],
	["Logic", [&"not_gate", &"and_gate", &"or_gate", &"xor_gate", &"latch", &"delay", &"pulse", &"counter", &"sequencer"]],
	["Shows and opens", [&"lamp", &"number_display", &"door", &"trapdoor", &"gate_tile"]],
	["Moves bricks", [&"piston", &"sticky_piston", &"release_brick"]],
	["Traps", [&"dispenser", &"arrow", &"dropper", &"alarm"]],
	["Wireless", [&"wire_transmitter", &"wire_receiver"]],
]

## A line more for the parts that need one.
const TIPS := {
	&"cable": "Lay a run up a placed block: a wire climbs or drops one brick at a time.",
	&"wire_brick": "Build it into a wall or a floor to hide a circuit; it is still a brick a shot can break.",
	&"lever": "The simplest switch: on until you turn it off.",
	&"pressure_tile": "Creatures press it too -- a zombie walking in springs your trap.",
	&"trip_hook": "Put the string across a corridor at shin height; creatures cross it too.",
	&"motion_sensor": "It sees only in front, 3 studs wide: walk round its box and it never knows.",
	&"light_sensor": "As a night sensor beside a lamp: a light that comes on at dusk.",
	&"fluid_sensor": "At the bottom of a room, wired to its doors: they shut as it floods.",
	&"observer": "Point it at a wall: when someone digs through, it fires.",
	&"not_gate": "Feed its back from its own front and it flickers: a clock.",
	&"or_gate": "Use one where two circuits must not join: power goes through it one way only.",
	&"counter": "Right side: reset. Three people over a bridge? Let the third one fall.",
	&"sequencer": "A turn-on while it runs is ignored; the wrench shows its program.",
	&"number_display": "Put it beside a light or fluid sensor to see the level.",
	&"door": "Open by hand AND by power: a hidden switch can lock a player out.",
	&"gate_tile": "A row of them is a bridge that vanishes; a gate tile with nothing holding it falls.",
	&"piston": "It moves blocks you placed (and loose sand or gravel), never the world's own ground. Whatever stands on what it pushes rides along.",
	&"release_brick": "Hold a bridge or a roof up on release bricks: power them and the real collapse drops it. One course of bricks alone is not joined sideways -- build two lapped courses so the rest holds until you let go.",
	&"dispenser": "Weapons do damage (arrows, a gun's rounds, grenades); anything else lands as an item a few metres out. A gun stays in it and reloads by itself.",
	&"dropper": "The quiet one: it only ever drops a pickup.",
	&"alarm": "Wire it to an observer or a motion sensor: dig into the vault and the zombies come.",
	&"wire_transmitter": "Same two antenna colours = same channel. Use it to fire a trap far away with no wire to follow.",
}

## Traps to build, from the parts above.
const TRAPS := [
	"ARROW WALL: a motion sensor facing the corridor, shooters loaded with arrows beside it facing the same way. Disarm: shoot the sensor, or walk round its box.",
	"COLLAPSING BRIDGE: a bridge two courses thick resting on release bricks at both ends; a trip string or pressure tile before it, wired to every release brick (a wire round the gap reaches the far ones). Disarm: cut the wire, jump.",
	"CAVE-IN: release bricks in a cave roof (with rock above them), a trip string across the cave. The real collapse brings the rock down.",
	"GRENADE NEST: a shooter loaded with grenades aimed at a doorway, a pressure tile inside it. Add a delay so the grenade lands after the player is in.",
	"VAULT ALARM: observers facing the vault walls, all wired to an alarm through a pulse (20 ticks) so the siren is heard. Digging in calls every zombie near.",
	"FLOOD ROOM: a pressure tile inside the room -> a NOT gate -> the door, so stepping in shuts it; the same tile -> a shooter loaded with a water or lava bucket over the room. A fluid sensor at the bottom can open the door again when it is full.",
	"LAMP LURE: a night sensor turning on lamps over a path of pressure tiles at dusk.",
	"THE THIRD STEP: a pressure tile -> a counter set to 3 -> a trapdoor just past the tile: the third time someone steps on it, the floor drops.",
]


static func _item_name(id: StringName) -> String:
	return str(ItemCatalog.get_def(id).get("name", String(id)))


## The lines for one part: its name, what the item says, and its tip.
static func part_text(id: StringName) -> String:
	var d := ItemCatalog.get_def(id)
	var lines := PackedStringArray()
	lines.append(_item_name(id).to_upper())
	var desc := str(d.get("description", ""))
	if desc != "":
		lines.append(desc)
	if TIPS.has(id):
		lines.append("Tip   " + str(TIPS[id]))
	return "\n".join(lines)


## Every part the guide lists (probes: each must be an item).
static func part_ids() -> Array[StringName]:
	var out: Array[StringName] = []
	for g in GROUPS:
		for id in g[1]:
			out.append(id)
	return out


## The whole page: the how-to, then each group with a row per part (its icon
## beside its lines), then traps to build. `make_slot` (id, count) -> a Control
## showing an item.
static func build(make_slot: Callable) -> VBoxContainer:
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 10)
	var how := Label.new()
	how.text = "\n".join(HOW)
	MenuFit.fit_label(how, true)
	v.add_child(how)
	for g in GROUPS:
		v.add_child(HSeparator.new())
		var head := Label.new()
		head.text = str(g[0]).to_upper()
		head.add_theme_font_size_override("font_size", 18)
		v.add_child(head)
		for id in g[1]:
			if not ItemCatalog.has(id):
				continue
			var row := HBoxContainer.new()
			row.add_theme_constant_override("separation", 12)
			row.add_child(make_slot.call(id, 1))
			var l := Label.new()
			l.text = part_text(id)
			MenuFit.fit_label(l, true)
			l.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			row.add_child(l)
			v.add_child(row)
	v.add_child(HSeparator.new())
	var th := Label.new()
	th.text = "TRAPS TO BUILD"
	th.add_theme_font_size_override("font_size", 18)
	v.add_child(th)
	var traps := Label.new()
	traps.text = "\n\n".join(TRAPS)
	MenuFit.fit_label(traps, true)
	v.add_child(traps)
	return v
