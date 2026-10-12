class_name GunCard
extends PanelContainer
## The weapon card: a floor gun in reach, or the gun chosen in the backpack or at the
## bench. Laid out like Borderlands 4's: the name and what it is, the damage large, the
## plain stats in rows -- fire rate, fire mode, accuracy, reload, magazine, swap speed,
## element, crit -- and under them, one entry each, what makes this gun more than its
## numbers: its charge-up, its alt-fire, its modifiers, its trade parts, its abilities.
## The legendary's red text last.
##
## Presentation rule that cannot bend (QUALITY_NAMING §4.1): the score covers RAW POWER
## only, so it must never appear without its effects under it. A score shown alone
## is a lie about which gun is better.

const RARITY_COLORS: Array[Color] = [
	Color(0.82, 0.82, 0.82),   # common
	Color(0.35, 0.85, 0.35),   # uncommon
	Color(0.30, 0.60, 1.00),   # rare
	Color(0.70, 0.35, 0.95),   # unique
	Color(1.00, 0.60, 0.10),   # legendary
	Color(0.95, 0.12, 0.12),   # mythic: red (COMBAT_DESIGN 2)
]
const KEY_COLOUR := Color(0.68, 0.68, 0.72)
const TEXT_COLOUR := Color(0.88, 0.88, 0.9)
const SPECIAL_COLOUR := Color(1.0, 0.85, 0.4)

var _name_label: Label
var _sub_label: Label
var _score_label: Label
var _damage_label: Label
var _stats_box: VBoxContainer
var _special_head: Label
var _special_box: VBoxContainer
var _flavor_label: Label


func _ready() -> void:
	custom_minimum_size = Vector2(320, 0)
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_theme_stylebox_override(&"panel", _bg())

	var root := VBoxContainer.new()
	root.add_theme_constant_override(&"separation", 2)
	add_child(root)

	_name_label = _mk_label(root, 18)
	_sub_label = _mk_label(root, 12)
	_sub_label.modulate = Color(0.75, 0.75, 0.78)

	var top := HBoxContainer.new()
	root.add_child(top)
	_damage_label = _mk_label(top, 26)
	_damage_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_score_label = _mk_label(top, 14)
	_score_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	_score_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_score_label.size_flags_vertical = Control.SIZE_FILL

	root.add_child(HSeparator.new())

	_stats_box = VBoxContainer.new()
	_stats_box.add_theme_constant_override(&"separation", 0)
	root.add_child(_stats_box)

	root.add_child(HSeparator.new())

	_special_head = _mk_label(root, 11)
	_special_head.text = "SPECIAL"
	_special_head.modulate = KEY_COLOUR
	_special_box = VBoxContainer.new()
	_special_box.add_theme_constant_override(&"separation", 4)
	root.add_child(_special_box)

	_flavor_label = _mk_label(root, 12)
	_flavor_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_flavor_label.custom_minimum_size.x = 296
	_flavor_label.modulate = Color(1.0, 0.35, 0.35)   # the "red text" slot


## Fill from a generated gun. `compare_score` draws the better/worse arrow; pass -1 for
## no comparison.
func show_gun(res: GunGenerator.Result, compare_score: int = -1,
		abilities: AbilityLoadout = null) -> void:
	if res == null:
		return
	var col := RARITY_COLORS[clampi(res.rarity - 1, 0, 5)]

	_name_label.text = res.gun_name
	_name_label.modulate = col

	var wc := res.weapon_class
	var cls: String = wc.kind_name() if wc != null else "Gun"
	if wc != null and wc.crossed:
		cls += " (rapid)" if wc.archetype == &"heavy" else " (heavy rounds)"
	_sub_label.text = "%s  ·  %s  ·  Tier %d" % [
		Rarity.NAMES[clampi(res.rarity - 1, 0, 5)], cls, res.tier,
	]

	var arrow := ""
	if compare_score >= 0 and compare_score != res.score:
		arrow = " ▲" if res.score > compare_score else " ▼"
	_score_label.text = "SCORE %d%s" % [res.score, arrow]
	_score_label.modulate = col

	# Damage and HP display as ceil-ed integers, never decimals (QUALITY_NAMING §7.2);
	# a shotgun's a pellet, times its pellets.
	var dmg := float(res.stats.get(&"damage", 0.0))
	_damage_label.text = str(GunQuality.display(dmg))
	if res.fire.has("pellets"):
		_damage_label.text += " ×%d" % int(res.fire.pellets)
	_damage_label.modulate = Elements.color(res.element_id) if res.element_id != &"" else Color.WHITE

	for c in _stats_box.get_children():
		_stats_box.remove_child(c)
		c.queue_free()
	_stats(res)

	for c in _special_box.get_children():
		_special_box.remove_child(c)
		c.queue_free()
	_specials(res, abilities, col)
	if _special_box.get_child_count() == 0:
		_special_entry("", "no special effects", Color(0.5, 0.5, 0.52))

	var red := res.flavor
	var what := LegendaryTable.effect_text(res.legendary_id)
	if what != "":
		red += "\n" + what
	_flavor_label.text = red
	_flavor_label.visible = red != ""


## The plain numbers, a row each.
func _stats(res: GunGenerator.Result) -> void:
	var wc := res.weapon_class
	var ordnance := wc != null and wc.is_ordnance
	var dps: float = float(res.stats.get(&"damage", 0.0)) * float(res.stats.get(&"fire_rate", 0.0))
	if ordnance:
		# Ordnance is cooldown-gated, so fire rate and reload are meaningless to it —
		# showing them would be noise on the one stat the player actually watches.
		_stat_row("Cooldown", "%.2f s" % float(res.stats.get(&"cooldown", 0.0)))
		_stat_row("Blast", "%.1f m" % float(res.stats.get(&"blast_radius", 0.0)))
		_stat_row("Charges", str(int(res.stats.get(&"mag_size", 0.0))))
	else:
		_stat_row("Fire rate", "%.2f /s" % float(res.stats.get(&"fire_rate", 0.0)))
		_stat_row("Fire mode", fire_mode_text(res.fire))
		if res.fire.has("pellets"):
			_stat_row("Range", "full to %.0f m, %d%% by %.0f m" % [float(res.fire.near),
					roundi(float(res.fire.falloff) * 100.0), float(res.fire.far)])
	_stat_row("Accuracy", "%d%%" % roundi(float(res.stats.get(&"accuracy", 0.0)) * 100.0))
	if not ordnance:
		_stat_row("Reload", "%.2f s" % float(res.stats.get(&"reload_time", 0.0)))
		# A heavy's magazine in shots, and the rounds it takes (two a shot).
		var rounds := int(res.stats.get(&"mag_size", 0.0))
		var rps := wc.rounds_per_shot if wc != null else 1
		_stat_row("Magazine", str(rounds) if rps <= 1 else "%d  (%d rounds)" % [rounds / rps, rounds])
		_stat_row("Swap speed", "%.2f s" % (wc.swap_time() if wc != null else WeaponClass.SWAP_TIME_BASE))
	if res.element_id != &"":
		var strong := Elements.strong_against(res.element_id)
		_stat_row("Element", "%s %d%%%s" % [Elements.display_name(res.element_id),
				roundi(float(res.stats.get(&"element_ratio", 0.0)) * 100.0),
				("  · " + strong) if strong != "" else ""], Elements.color(res.element_id))
	else:
		_stat_row("Element", "Kinetic")
	_stat_row("Crit", "×%.2f" % float(res.stats.get(&"crit_mult", 1.0)))
	_stat_row("DPS", str(GunQuality.display(dps)))


## What the trigger does. A gun no one gave a fire mode fires as guns always have:
## held, at its rate.
static func fire_mode_text(fm: Dictionary) -> String:
	if fm.is_empty():
		return "Full-auto"
	match StringName(fm.mode):
		GunFireMode.SEMI:
			return "Semi-auto"
		GunFireMode.AUTO:
			return "Full-auto"
		GunFireMode.BURST:
			return "Burst ×%d" % int(fm.get("burst", 3))
	return "—"


## The special effects, one entry each: a title and what it does.
func _specials(res: GunGenerator.Result, abilities: AbilityLoadout, col: Color) -> void:
	var soft := col.lerp(Color.WHITE, 0.45)
	var fire_rate := float(res.stats.get(&"fire_rate", 0.0))
	if res.fire.has("charge"):
		var e := GunFireMode.charge_entry(res.fire)
		_special_entry(e[0], e[1], SPECIAL_COLOUR)
	if res.alt_fire != &"":
		var d := GunAltFire.describe(res.alt_fire)
		var cut := d.find(":")
		var title := d.substr(0, cut) if cut > 0 else "Alt-fire"
		var body := d.substr(cut + 1).strip_edges() if cut > 0 else d
		_special_entry("Alt-fire: " + title.capitalize(), body + " (hold R to switch to it)",
				SPECIAL_COLOUR)
	if StringName(res.fire.get("mode", &"")) == GunFireMode.BURST:
		_special_entry("Burst", "%d rounds a pull at %.0f a second, then a pause" % [
				int(res.fire.burst), fire_rate * float(res.fire.burst_speed)], soft)
	# The modifiers: where this gun's power comes from (COMBAT_DESIGN 6).
	for m in res.modifiers:
		_special_entry("", "+ " + GunModifiers.describe(m), soft)
	# The named trade parts (3.1): how it deals its damage.
	for def: Variant in res.recipe.values():
		if def is GunPartDef and (def as GunPartDef).tags.has("trade"):
			_special_entry("◇ " + (def as GunPartDef).display_name,
					_trade_text((def as GunPartDef).stat_mult), soft)
	# Abilities are folded in HERE rather than onto the gun: they are a player property,
	# so the card shows what this gun becomes in THIS player's hands.
	var shown: PackedStringArray = res.active_effects
	if abilities != null:
		shown = abilities.apply(res.active_effects)
	for e in shown:
		var eid := StringName(e)
		if GunModifiers.DEFS.has(eid):
			continue   # a modifier, listed above
		if WeaponAbility.is_upgraded(eid):
			_special_entry("◆◆ %s+" % String(WeaponAbility.base_id(eid)).capitalize().replace("_", " "),
					"", SPECIAL_COLOUR)
		else:
			_special_entry("◆ %s" % String(eid).capitalize().replace("_", " "), "", SPECIAL_COLOUR)
	for m in res.merges:
		if m != null:
			_special_entry("★ %s" % String(m.id).capitalize().replace("_", " "), "", SPECIAL_COLOUR)


## Every line the card shows, top to bottom (probes read it).
func text() -> String:
	var out := PackedStringArray()
	for n in find_children("*", "Label", true, false):
		var l := n as Label
		if l.visible and l.text != "" and not l.is_queued_for_deletion():
			out.append(l.text)
	return "\n".join(out)


static func _trade_text(mult: Dictionary) -> String:
	var bits := PackedStringArray()
	for k: StringName in mult:
		var pct := roundi((float(mult[k]) - 1.0) * 100.0)
		bits.append("%s%d%% %s" % ["+" if pct >= 0 else "−", absi(pct),
				String(k).replace("_", " ")])
	return ", ".join(bits)


func _stat_row(key: String, value: String, value_colour := TEXT_COLOUR) -> void:
	var row := HBoxContainer.new()
	var k := Label.new()
	k.text = key
	k.add_theme_font_size_override(&"font_size", 13)
	k.modulate = KEY_COLOUR
	k.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var v := Label.new()
	v.text = value
	v.add_theme_font_size_override(&"font_size", 13)
	v.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	v.modulate = value_colour
	row.add_child(k)
	row.add_child(v)
	_stats_box.add_child(row)


## One special effect: its name over what it does.
func _special_entry(title: String, body: String, colour: Color) -> void:
	var box := VBoxContainer.new()
	box.add_theme_constant_override(&"separation", 0)
	if title != "":
		var t := _mk_label(box, 13)
		t.text = title
		t.modulate = colour
	if body != "":
		var b := _mk_label(box, 12)
		b.text = body
		b.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		b.custom_minimum_size.x = 296
		b.modulate = TEXT_COLOUR if title != "" else colour
	_special_box.add_child(box)


func _mk_label(parent: Node, size: int) -> Label:
	var l := Label.new()
	l.add_theme_font_size_override(&"font_size", size)
	parent.add_child(l)
	return l


func _bg() -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.06, 0.06, 0.08, 0.92)
	sb.border_color = Color(0.35, 0.35, 0.40)
	sb.set_border_width_all(1)
	sb.set_corner_radius_all(4)
	sb.set_content_margin_all(10)
	return sb
