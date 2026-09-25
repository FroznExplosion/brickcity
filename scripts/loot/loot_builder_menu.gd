class_name LootBuilderMenu
extends PanelContainer
## Author any item by hand: pick category, class, rarity and tier, then Build.
##
## The point is falsifiability. Random drops can hide a bug for hundreds of rolls — this
## makes "a tier-4 Rare grenade" a thing you can produce on demand and compare against a
## tier-4 Rare pistol side by side. Every field here feeds the SAME generator the world
## uses; nothing is constructed by a special path.

signal build_requested(category: StringName, class_id: StringName, rarity: int, tier: int)
signal ability_toggled(ability_id: StringName)

const CATEGORIES: Array[StringName] = [&"gun", &"ordnance", &"shield", &"ability"]

var _category := &"gun"
var _class_opt: OptionButton
var _rarity_opt: OptionButton
var _tier_opt: OptionButton
var _class_row: HBoxContainer
var _ability_box: VBoxContainer
var _abilities: AbilityLoadout


func setup(abilities: AbilityLoadout) -> void:
	_abilities = abilities
	_build()


func _build() -> void:
	custom_minimum_size = Vector2(300, 0)
	add_theme_stylebox_override(&"panel", _bg())

	var v := VBoxContainer.new()
	v.add_theme_constant_override(&"separation", 4)
	add_child(v)

	var title := Label.new()
	title.text = "BUILD ITEM"
	title.add_theme_font_size_override(&"font_size", 16)
	v.add_child(title)

	var cat_row := HBoxContainer.new()
	v.add_child(cat_row)
	var cat_lbl := Label.new()
	cat_lbl.text = "Category"
	cat_lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	cat_row.add_child(cat_lbl)
	var cat_opt := OptionButton.new()
	for c in CATEGORIES:
		cat_opt.add_item(String(c).capitalize())
	cat_opt.item_selected.connect(_on_category)
	cat_row.add_child(cat_opt)

	_class_row = HBoxContainer.new()
	v.add_child(_class_row)
	var class_lbl := Label.new()
	class_lbl.text = "Class"
	class_lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_class_row.add_child(class_lbl)
	_class_opt = OptionButton.new()
	_class_row.add_child(_class_opt)

	_rarity_opt = _labelled_option(v, "Rarity", Rarity.NAMES)
	# Rarity and tier both default to the middle of their range: a tier-1 Common is the
	# least informative thing the menu can build.
	_rarity_opt.select(2)

	var tiers: Array = []
	for t in range(1, Tier.COUNT + 1):
		tiers.append("Tier %d" % t)
	_tier_opt = _labelled_option(v, "Tier", tiers)
	_tier_opt.select(3)

	_ability_box = VBoxContainer.new()
	v.add_child(_ability_box)

	var build_btn := Button.new()
	build_btn.text = "BUILD"
	build_btn.focus_mode = Control.FOCUS_NONE
	build_btn.pressed.connect(_on_build)
	v.add_child(build_btn)

	var hint := Label.new()
	hint.text = "B closes"
	hint.add_theme_font_size_override(&"font_size", 10)
	hint.modulate = Color(0.5, 0.5, 0.55)
	v.add_child(hint)

	_refresh_classes()


func _labelled_option(parent: Node, text: String, items: Array) -> OptionButton:
	var row := HBoxContainer.new()
	var l := Label.new()
	l.text = text
	l.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(l)
	var opt := OptionButton.new()
	for it in items:
		opt.add_item(str(it))
	row.add_child(opt)
	parent.add_child(row)
	return opt


func _on_category(idx: int) -> void:
	_category = CATEGORIES[clampi(idx, 0, CATEGORIES.size() - 1)]
	_refresh_classes()


## Abilities have no class/rarity/tier — they are a player property, not a rolled item
## (§11) — so those rows hide rather than showing controls that would do nothing.
func _refresh_classes() -> void:
	for c in _ability_box.get_children():
		c.queue_free()

	var is_ability := _category == &"ability"
	_class_row.visible = not is_ability
	_rarity_opt.get_parent().visible = not is_ability
	_tier_opt.get_parent().visible = not is_ability

	if is_ability:
		for id: StringName in AbilityLoadout.all_ids():
			var a := AbilityLoadout.get_ability(id)
			var cb := CheckBox.new()
			cb.text = a.display_name
			cb.focus_mode = Control.FOCUS_NONE
			cb.button_pressed = _abilities != null and _abilities.has(id)
			cb.toggled.connect(func(_on: bool): ability_toggled.emit(id))
			_ability_box.add_child(cb)
		return

	_class_opt.clear()
	for id: StringName in _class_ids():
		_class_opt.add_item(String(id).capitalize().replace("_", " "))


func _class_ids() -> Array:
	match _category:
		&"ordnance": return WeaponClass.ORDNANCE_IDS
		&"shield": return ShieldGenerator.class_ids()
		_: return WeaponClass.gun_ids()


func _on_build() -> void:
	if _category == &"ability":
		return
	var ids := _class_ids()
	var idx := clampi(_class_opt.selected, 0, ids.size() - 1)
	build_requested.emit(_category, ids[idx],
		_rarity_opt.selected + 1, _tier_opt.selected + 1)


## Re-read the ability checkboxes from the loadout, so toggling from the HUD keys and
## toggling from this menu never disagree.
func sync_abilities() -> void:
	if _category == &"ability":
		_refresh_classes()


func _bg() -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.06, 0.07, 0.10, 0.95)
	sb.border_color = Color(0.40, 0.55, 0.70)
	sb.set_border_width_all(1)
	sb.set_corner_radius_all(4)
	sb.set_content_margin_all(10)
	return sb
