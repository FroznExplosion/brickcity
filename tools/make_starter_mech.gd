extends SceneTree

## Builds the starter mech: the first official mech parts (Docs/ModularParts.md, "Starter
## parts"). One normal-class Korr mech, legs 2 long, blocked out in the asset workshop's mech
## mode on the reference's joints, saved as official parts in res://parts/mech/ and its build
## as res://mechs/starter_normal.json (open it in the workshop to change it, Save writes the
## parts again).
##
##     godot --headless --path . --script res://tools/make_starter_mech.gd
##
## Sized to the city: the pilot's eye 4.2 m up looks straight into a second-storey window
## (Docs/Parts/nano.md section 1), the cockpit window is drawn round it, and the whole mech
## stands about two storeys tall. Units are the workshop's: nano studs along (x, the mech faces
## -x) and across (z, its left +z), nano plates up from the ground.

const BUILD := "res://mechs/starter_normal.json"
const NAME := "Starter Normal"
const MAKER := "korr"

## Colours, by the plain material's names (BrickWorld.get_material_colour_name).
const BODY := 13      # light grey
const FRAME := 3      # dark grey
const ACCENT := 33    # mustard
const GLASS := 9      # light blue
const VISOR := 46     # cyan
const DARK := 14      # charcoal

var _ws
var _frames := 0
var _o := Vector3i.ZERO   # the reference's origin cell: between the feet, on the ground


func _init() -> void:
	_ws = load("res://scenes/asset_workshop.tscn").instantiate()
	_ws.auto_start_brick = false
	root.add_child(_ws)
	_ws._no_autosave = true
	process_frame.connect(_tick)


func _tick() -> void:
	_frames += 1
	if _frames != 3:
		return
	_ws.set_process(false)
	_ws._hotbar.save_path = "user://_starter_hotbar.json"
	_ws.toolbars_save = "user://_starter_toolbars.json"
	_build()


## Cells x0..x1, y0..y1, z0..z1 (inclusive, relative to the origin; z relative to the middle
## cell, so -a..a is symmetric about the mirror) laid as part `part` in `colour`.
func _box(part: String, x0: int, x1: int, y0: int, y1: int, z0: int, z1: int, colour: int) -> int:
	_ws.select_part(_ws.part_names.find(part))
	_ws._colour = colour
	_ws._mat = 0
	var cells := {}
	for x in range(x0, x1 + 1):
		for y in range(y0, y1 + 1):
			for z in range(z0, z1 + 1):
				cells[_o + Vector3i(x, y, z)] = true
	return _ws.fill_cells(cells)


## The same box on the left (+z) and, mirrored, on the right.
func _pair(part_l: String, part_r: String, x0: int, x1: int, y0: int, y1: int, z0: int, z1: int, colour: int) -> void:
	_box(part_l, x0, x1, y0, y1, z0, z1, colour)
	_box(part_r, x0, x1, y0, y1, -z1, -z0, colour)


func _build() -> void:
	_ws._new_build()
	_ws.set_asset_kind("mech")
	_ws.set_mech_class("normal")
	_ws.set_leg_length(2)
	_ws.part_maker = MAKER
	_ws.recipe.name = NAME
	var o: Vector3 = _ws.mech_origin()
	_o = Vector3i(int(o.x), int(o.y), int(floor(o.z)))
	var j := MechReference.joints("normal", 2)
	print("[starter] joints: hip %d, shoulder %d, neck %d, wrist %d plates up; eye at 60 (4.2 m)" % [
			j.chassis.y, j.arm_L.y, j.head.y, j.hand_L.y])

	# Legs, hips 48 plates up, 5 studs out: a thigh to the knee (24), a shin to the ankle (7),
	# a foot reaching forward. Each piece starts on its bend, so a bend is a seam.
	_pair("leg_L", "leg_R", -4, 3, 40, 47, 3, 7, FRAME)      # hip joint block
	_pair("leg_L", "leg_R", -4, 3, 24, 39, 3, 7, BODY)       # thigh
	_pair("leg_L", "leg_R", -3, 2, 7, 23, 3, 7, BODY)        # shin
	_pair("leg_L", "leg_R", -4, 3, 21, 23, 2, 8, ACCENT)     # knee pad, front
	_pair("leg_L", "leg_R", -7, 4, 0, 6, 2, 8, FRAME)        # foot

	# Chassis: the hips between the legs, the body from the hips (48) to the neck (66), the
	# cockpit window round the pilot's eye (60), a hatch outline under it, shoulders' frame.
	_box("chassis", -4, 3, 40, 47, -2, 2, FRAME)             # hip block, between the thighs
	_box("chassis", -6, 5, 48, 65, -8, 8, BODY)              # body
	_box("chassis", -7, -7, 57, 62, -4, 4, GLASS)            # cockpit window, on the front
	_box("chassis", -7, -7, 50, 55, -3, 3, DARK)             # hatch
	_box("chassis", -7, -7, 63, 64, -8, 8, ACCENT)           # brow stripe
	_box("chassis", -3, 4, 52, 63, 9, 9, FRAME)              # shoulder frame, left
	_box("chassis", -3, 4, 52, 63, -9, -9, FRAME)            # shoulder frame, right

	# Head on the neck (66): a sensor head, a visor at the front, a mast.
	_box("head", -4, 3, 66, 75, -3, 3, BODY)
	_box("head", -5, -5, 69, 71, -2, 2, VISOR)
	_box("head", 1, 1, 76, 83, 0, 0, DARK)

	# Arms: shoulder 54 plates up, 11 studs out; a pad over the shoulder, the upper arm down to
	# the elbow (42), the forearm to the wrist (30, 2 studs ahead).
	_pair("arm_L", "arm_R", -5, 4, 50, 61, 10, 13, ACCENT)   # shoulder pad
	_pair("arm_L", "arm_R", -3, 2, 42, 49, 10, 12, BODY)     # upper arm
	_pair("arm_L", "arm_R", -5, 0, 30, 41, 10, 12, BODY)     # forearm
	# Hands: a fist under the wrist.
	_pair("hand_L", "hand_R", -5, 0, 22, 29, 10, 12, FRAME)

	# Pod bodies: on the chassis's top, either side of the head, behind it (pods at the neck,
	# 3 studs back, 7 out).
	_pair("pod_L", "pod_R", 0, 7, 66, 72, 5, 9, FRAME)
	_pair("pod_L", "pod_R", 0, 7, 73, 74, 5, 9, ACCENT)

	var counts: Dictionary = _ws.part_counts()
	print("[starter] bricks: ", counts)
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(BUILD.get_base_dir()))
	_ws._current_path = BUILD
	var ok: bool = _ws._write(BUILD)
	print("[starter] build written: %s, parts in %s" % [ok, _ws.parts_dir()])
	var cat := PartCatalog.new()
	print("[starter] official parts: %d" % cat.load_dir(_ws.parts_dir(), "official"))
	var b := PartBuilder.generate("mech", null, 1, cat, {"class": "normal"})
	print("[starter] a mech rolls from them: %s" % ("yes" if (b.problems as Array).is_empty() else str(b.problems)))
	quit(0 if ok and (b.problems as Array).is_empty() else 1)
