class_name GunCard
extends PanelContainer
## The stat card shown when the player looks at a dropped gun.
##
## Presentation rule that cannot bend (QUALITY_NAMING §4.1): the score covers RAW POWER
## only, so it must never appear without its effect icons beside it. A score shown alone
## is a lie about which gun is better.

const RARITY_COLORS: Array[Color] = [
	Color(0.82, 0.82, 0.82),   # common
	Color(0.35, 0.85, 0.35),   # uncommon
	Color(0.30, 0.60, 1.00),   # rare
	Color(0.70, 0.35, 0.95),   # unique
	Color(1.00, 0.60, 0.10),   # legendary
	Color(1.00, 0.25, 0.35),   # mythic
]

var _name_label: Label
var _sub_label: Label
var _score_label: Label
var _stats_box: VBoxContainer
var _effects_label: Label
var _flavor_label: Label


func _ready() -> void:
	custom_minimum_size = Vector2(300, 0)
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_theme_stylebox_override(&"panel", _bg())

	var root := VBoxContainer.new()
	root.add_theme_constant_override(&"separation", 2)
	add_child(root)

	_name_label = _mk_label(root, 18)
	_sub_label = _mk_label(root, 12)
	_sub_label.modulate = Color(0.75, 0.75, 0.78)

	_score_label = _mk_label(root, 26)

	var sep := HSeparator.new()
	root.add_child(sep)

	_stats_box = VBoxContainer.new()
	_stats_box.add_theme_constant_override(&"separation", 0)
	root.add_child(_stats_box)

	_effects_label = _mk_label(root, 12)
	_effects_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART

	_flavor_label = _mk_label(root, 12)
	_flavor_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
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
	var cls: String = String(wc.id).capitalize().replace("_", " ") if wc != null else "Gun"
	_sub_label.text = "%s  ·  %s  ·  Tier %d" % [
		Rarity.NAMES[clampi(res.rarity - 1, 0, 5)], cls, res.tier,
	]

	var arrow := ""
	if compare_score >= 0 and compare_score != res.score:
		arrow = "  ▲" if res.score > compare_score else "  ▼"
	_score_label.text = "SCORE %d%s" % [res.score, arrow]
	_score_label.modulate = col

	for c in _stats_box.get_children():
		c.queue_free()
	var dps: float = float(res.stats.get(&"damage", 0.0)) * float(res.stats.get(&"fire_rate", 0.0))
	# Damage and HP display as ceil-ed integers, never decimals (QUALITY_NAMING §7.2).
	_stat_row("Damage", str(GunQuality.display(float(res.stats.get(&"damage", 0.0)))))
	if wc != null and wc.is_ordnance:
		# Ordnance is cooldown-gated, so fire rate and reload are meaningless to it —
		# showing them would be noise on the one stat the player actually watches.
		_stat_row("Cooldown", "%.2fs" % float(res.stats.get(&"cooldown", 0.0)))
		_stat_row("Blast", "%.1fm" % float(res.stats.get(&"blast_radius", 0.0)))
		_stat_row("DPS", str(GunQuality.display(dps)))
		_stat_row("Charges", str(int(res.stats.get(&"mag_size", 0.0))))
	else:
		_stat_row("Fire rate", "%.2f/s" % float(res.stats.get(&"fire_rate", 0.0)))
		_stat_row("DPS", str(GunQuality.display(dps)))
		_stat_row("Mag", str(int(res.stats.get(&"mag_size", 0.0))))
		_stat_row("Reload", "%.2fs" % float(res.stats.get(&"reload_time", 0.0)))
	_stat_row("Accuracy", "%d%%" % roundi(float(res.stats.get(&"accuracy", 0.0)) * 100.0))
	_stat_row("Crit", "x%.2f" % float(res.stats.get(&"crit_mult", 1.0)))

	# The score deliberately excludes these, so they must always be visible next to it.
	# Abilities are folded in HERE rather than onto the gun: they are a player property,
	# so the card shows what this gun becomes in THIS player's hands.
	var shown: PackedStringArray = res.active_effects
	if abilities != null:
		shown = abilities.apply(res.active_effects)
	var bits := PackedStringArray()
	for e in shown:
		var eid := StringName(e)
		if WeaponAbility.is_upgraded(eid):
			bits.append("◆◆ %s+" % String(WeaponAbility.base_id(eid)).capitalize().replace("_", " "))
		else:
			bits.append("◆ %s" % String(eid).capitalize().replace("_", " "))
	for m in res.merges:
		if m != null:
			bits.append("★ %s" % String(m.id).capitalize().replace("_", " "))
	if bits.is_empty():
		_effects_label.text = "no special parts"
		_effects_label.modulate = Color(0.5, 0.5, 0.52)
	else:
		_effects_label.text = " ".join(bits)
		_effects_label.modulate = Color(1.0, 0.85, 0.4)

	_flavor_label.text = res.flavor
	_flavor_label.visible = res.flavor != ""


func _stat_row(key: String, value: String) -> void:
	var row := HBoxContainer.new()
	var k := Label.new()
	k.text = key
	k.add_theme_font_size_override(&"font_size", 13)
	k.modulate = Color(0.68, 0.68, 0.72)
	k.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var v := Label.new()
	v.text = value
	v.add_theme_font_size_override(&"font_size", 13)
	v.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	row.add_child(k)
	row.add_child(v)
	_stats_box.add_child(row)


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
