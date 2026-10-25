class_name CharacterBuilder
extends CanvasLayer
## The character builder (Docs/ModularParts.md section 10): an action figure put together slot
## by slot from the catalogue's figure parts, seen turning in a preview, saved as a design and
## put in the world. Only parts that fit are ever offered (Figure.why_not_swap), so what is
## built here is always a whole figure.
##
##   Up / Down       pick a slot (torso, head, arms, hands, legs, hat)
##   Left / Right    the part before / after in that slot, of those that fit there
##   R               roll a whole new figure
##   S               save it as a design (user://parts/designs/<name>.json)
##   Enter           put it in the world (`spawned`)
##   Esc             close

signal spawned(f: Figure)
signal closed

const DESIGN_DIR := "user://parts/designs/"

var catalog: PartCatalog
var figure: Figure
var slot := 0
var design_name := "Character"
var note := ""
var _seed := 1
var _panel: PanelContainer
var _text: RichTextLabel
var _view: SubViewport
var _turn: Node3D


func _ready() -> void:
	layer = 6
	_panel = PanelContainer.new()
	_panel.position = Vector2(60, 60)
	add_child(_panel)
	var row := HBoxContainer.new()
	_panel.add_child(row)
	var holder := SubViewportContainer.new()
	holder.stretch = true
	holder.custom_minimum_size = Vector2(320, 420)
	row.add_child(holder)
	_view = SubViewport.new()
	_view.own_world_3d = true
	_view.transparent_bg = true
	holder.add_child(_view)
	var cam := Camera3D.new()
	cam.position = Vector3(0, 1.0, 3.2)
	cam.fov = 40.0
	_view.add_child(cam)
	cam.look_at(Vector3(0, 0.9, 0))
	var sun := DirectionalLight3D.new()
	sun.rotation = Vector3(-0.8, 0.6, 0)
	_view.add_child(sun)
	_turn = Node3D.new()
	_view.add_child(_turn)
	_text = RichTextLabel.new()
	_text.bbcode_enabled = true
	_text.fit_content = true
	_text.custom_minimum_size = Vector2(420, 0)
	_text.add_theme_font_size_override("normal_font_size", 16)
	_text.add_theme_font_size_override("bold_font_size", 16)
	row.add_child(_text)


func open(cat: PartCatalog) -> void:
	catalog = cat
	if figure == null:
		roll()
	visible = true
	_refresh()


## The slots, in the order listed: the root, then the plan's paths.
func slots() -> Array:
	var out := ["root"]
	var paths := (PartStandards.plan(Figure.PLAN).get("sockets", {}) as Dictionary).keys()
	paths.sort_custom(func(a: String, b: String) -> bool:
		return a.count("/") < b.count("/") if a.count("/") != b.count("/") else a < b)
	out.append_array(paths)
	return out


## A whole new figure from the catalogue (custom parts too: it is the player's own).
func roll() -> bool:
	if catalog == null:
		return false
	_seed += 1
	var b := PartBuilder.generate(Figure.PLAN, null, _seed * 7919, catalog, {"custom": true})
	var f := Figure.make(b)
	if f == null:
		note = "no whole figure can be made of these parts: " + "; ".join(b.problems)
		_refresh()
		return false
	_show(f)
	note = ""
	return true


## The parts that fit slot `path` now, in id order (the one there included).
func options(path: String) -> Array:
	if figure == null:
		return []
	var now: PartRecord = figure.build.root if path == "root" else figure.build.at.get(path)
	var slot_name := String(PartStandards.plan(Figure.PLAN).get("root", "")) if path == "root" \
			else String(PartStandards.plan(Figure.PLAN).sockets[path].slot)
	var out := []
	for r in catalog.filter({"family": ["figure"], "slot": [slot_name]}):
		if (now != null and r.id == now.id) or figure.why_not_swap(path, r) == "":
			out.append(r)
	return out


## The part `step` along in the current slot.
func cycle(step: int) -> bool:
	var path: String = slots()[slot]
	var opts := options(path)
	if opts.size() < 2:
		note = "nothing else fits the %s" % path
		_refresh()
		return false
	var now: PartRecord = figure.build.root if path == "root" else figure.build.at.get(path)
	var i := 0
	for k in opts.size():
		if now != null and opts[k].id == now.id:
			i = k
	var next: PartRecord = opts[posmod(i + step, opts.size())]
	var ok := figure.swap(path, next)
	note = "" if ok else "that does not fit"
	_refresh()
	return ok


## Save it as a design: every slot fixed. The path written, or "".
func save(dir: String = DESIGN_DIR) -> String:
	if figure == null:
		return ""
	var d := PartDesign.new()
	d.id = AssetGuns.slug(design_name)
	d.display_name = design_name
	d.plan = Figure.PLAN
	d.slots["root"] = {"fixed": (figure.build.root as PartRecord).id}
	for path in figure.build.at:
		d.slots[path] = {"fixed": (figure.build.at[path] as PartRecord).id}
	var path_out := dir + d.id + ".json"
	if d.save_file(path_out) != OK:
		note = "could not save"
		return ""
	note = "saved as %s" % path_out
	_refresh()
	return path_out


## A figure of what is built, for the world.
func spawn() -> Figure:
	if figure == null:
		return null
	var f := Figure.make({"root": figure.build.root, "at": (figure.build.at as Dictionary).duplicate(),
			"problems": []})
	if f != null:
		spawned.emit(f)
	return f


func _unhandled_input(event: InputEvent) -> void:
	if not visible or not (event is InputEventKey and event.pressed and not event.echo):
		return
	match event.keycode:
		KEY_UP: slot = posmod(slot - 1, slots().size())
		KEY_DOWN: slot = posmod(slot + 1, slots().size())
		KEY_LEFT: cycle(-1)
		KEY_RIGHT: cycle(1)
		KEY_R: roll()
		KEY_S: save()
		KEY_ENTER, KEY_KP_ENTER: spawn()
		KEY_ESCAPE:
			visible = false
			closed.emit()
		_: return
	_refresh()
	get_viewport().set_input_as_handled()


func _process(delta: float) -> void:
	if visible and _turn != null:
		_turn.rotation.y += delta * 0.6


func _show(f: Figure) -> void:
	if figure != null:
		_turn.remove_child(figure)
		figure.queue_free()
	figure = f
	_turn.add_child(f)
	_refresh()


func text() -> String:
	var lines := PackedStringArray(["[b]CHARACTER  %s[/b]" % design_name])
	if figure == null:
		lines.append(note if note != "" else "No figure parts to build with.")
		return "\n".join(lines)
	var ss := slots()
	for i in ss.size():
		var path: String = ss[i]
		var r: PartRecord = figure.build.root if path == "root" else figure.build.at.get(path)
		var name := r.display_name if r != null else "[i]none[/i]"
		var n := options(path).size()
		lines.append("%s %-10s %s%s" % ["[color=#ffd75e]>[/color]" if i == slot else "  ", path, name,
				("   (%d fit)" % n) if n > 1 else ""])
	if note != "":
		lines.append("")
		lines.append(note)
	lines.append("")
	lines.append("[color=#aaaaaa]Up / Down slot   Left / Right part   R roll   S save   Enter put in the world   Esc close[/color]")
	return "\n".join(lines)


func _refresh() -> void:
	if _text != null:
		_text.text = text()
