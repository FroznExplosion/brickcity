class_name MechLoadoutScreen
extends CanvasLayer
## The mech page of the backpack (Docs/ModularParts.md section 4, "Pods"; stage 7): the
## player's mech -- its class, its parts -- its two pod slots, and the pods the player has.
## Pods are fitted here, never in the workshop (the workshop makes pod bodies).
##
##   Up / Down, wheel   pick a pod in the stash
##   1 / 2              fit it on the left / right pod; what was there goes to the stash
##   Shift 1 / 2        take that pod off, into the stash
##
## Opened from the backpack: swap weapon steps to it after the skills (PlayerArsenal).

## Common .. mythic, as the loot colours read.
const RARITY_COLOURS := ["d0d0d0", "5fd35f", "4f9dff", "c070ff", "ffa030", "ff4f6f"]

var pods: MechPods
## The pods the player has, not fitted.
var stash: Array = []
var index := 0
var _panel: PanelContainer
var _text: RichTextLabel


func _ready() -> void:
	layer = 5
	_panel = PanelContainer.new()
	_panel.visible = false
	_panel.position = Vector2(60, 80)
	_panel.custom_minimum_size = Vector2(620, 0)
	add_child(_panel)
	_text = RichTextLabel.new()
	_text.bbcode_enabled = true
	_text.fit_content = true
	_text.custom_minimum_size = Vector2(600, 0)
	_text.add_theme_font_size_override("normal_font_size", 16)
	_text.add_theme_font_size_override("bold_font_size", 16)
	_panel.add_child(_text)


func show_screen(on: bool) -> void:
	if _panel == null:
		return
	if on and not _panel.visible:
		index = clampi(index, 0, maxi(stash.size() - 1, 0))
	_panel.visible = on
	if on:
		_text.text = text()


## What a key does here. True if it was this screen's.
func handle(event: InputEvent) -> bool:
	var step := PlayerArsenal._step(event)
	if step != 0:
		index = clampi(index + step, 0, maxi(stash.size() - 1, 0))
		return true
	for slot in MechPods.SLOTS:
		if PlayerArsenal._pressed(event, StringName("slot_%d" % (slot + 1))) \
				or (event is InputEventKey and event.pressed and event.keycode == KEY_1 + slot):
			if event is InputEventWithModifiers and event.shift_pressed:
				take_off(slot)
			else:
				fit_selected(slot)
			return true
	return false


func fit_selected(slot: int) -> bool:
	if pods == null or index < 0 or index >= stash.size():
		return false
	var pod: PodGenerator.Result = stash[index]
	stash.remove_at(index)
	var was := pods.fit(slot, pod)
	if was != null:
		stash.insert(mini(index, stash.size()), was)
	index = clampi(index, 0, maxi(stash.size() - 1, 0))
	return true


func take_off(slot: int) -> bool:
	if pods == null:
		return false
	var was := pods.take_off(slot)
	if was == null:
		return false
	stash.append(was)
	return true


func text() -> String:
	var lines := PackedStringArray(["[b]MECH[/b]"])
	if pods == null or pods.mech == null:
		lines.append("No mech of yours yet.")
		return "\n".join(lines)
	var m := pods.mech
	var parts: Dictionary = m.get_meta(&"mech_parts", {})
	if parts.is_empty():
		lines.append("The stock frame (no parts).")
	else:
		var cat := MechAssembler.catalog()
		var root := cat.get_part(String(parts.get("root", "")))
		lines.append("%s chassis, legs %s long" % [root.weight_class.capitalize() if root != null else "?",
				_leg_length(cat, parts)])
	lines.append("")
	for slot in MechPods.SLOTS:
		var pod: PodGenerator.Result = pods.slots[slot]
		lines.append("[b]%d  %s pod[/b]   %s" % [slot + 1, "left" if slot == 0 else "right",
				pod_line(pod) if pod != null else "[i]empty[/i]"])
	lines.append("")
	lines.append("[b]Pods[/b]" if not stash.is_empty() else "[b]Pods[/b]   none in the backpack")
	for i in stash.size():
		lines.append("%s %s" % ["[color=#ffd75e]>[/color]" if i == index else "  ", pod_line(stash[i])])
	lines.append("")
	lines.append("[color=#aaaaaa]Up / Down pick   1 / 2 fit left / right   Shift 1 / 2 take off   in the mech: 1 / 2 use[/color]")
	return "\n".join(lines)


## One pod in a line: its name, rarity, kind and what it does.
static func pod_line(pod: PodGenerator.Result) -> String:
	var k: Dictionary = PodGenerator.KINDS[pod.kind]
	var what := ""
	if pod.sort == "passive":
		var bits := PackedStringArray()
		for stat in ["shield", "armor"]:
			if pod.stats.has(stat):
				bits.append("+%d%% %s" % [roundi(float(pod.stats[stat]) * 100.0), stat])
		what = ", ".join(bits)
	else:
		what = "%.1f s cooldown, x%.2f" % [float(pod.stats.cooldown), float(pod.stats.power)]
	return "%s  [color=#%s]%s[/color]  %s (%s): %s" % [pod.pod_name, RARITY_COLOURS[pod.rarity - 1],
			GunGenerator.RARITY_NAMES[pod.rarity - 1], k.name, pod.sort.replace("_", " "), what]


static func _leg_length(cat: PartCatalog, parts: Dictionary) -> String:
	var leg := cat.get_part(String(parts.get("leg_L", "")))
	return str(int(leg.param("length"))) if leg != null and leg.param("length") != null else "?"
