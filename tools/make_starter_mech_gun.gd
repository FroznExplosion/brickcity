extends SceneTree

## Builds the starter mech gun: the first official mech-scale gun (Docs/ModularParts.md section
## 5: mech guns are guns at mech scale, their own mgun.* joints). A Korr LMG -- body, barrel,
## grip, box magazine -- blocked out in the asset workshop's gun mode at nano scale, saved as
## official parts in res://parts/gun/ and its build as res://guns/starter_mech_lmg.json.
##
##     godot --headless --path . --script res://tools/make_starter_mech_gun.gd
##
## Units: nano studs along the gun (x; the muzzle is -x), plates up, studs across (z). At mech
## scale a stud is 0.175 m: the gun is 26 studs, 4.6 m, a little longer than the mech's arm is
## from shoulder to fist, as a titan's gun is.

const BUILD := "res://guns/starter_mech_lmg.json"
const NAME := "Starter Mech LMG"
const MAKER := "korr"
const FRAME := 3      # dark grey
const BARREL := 14    # charcoal
const ACCENT := 33    # mustard
const GRIP := 1       # black
const BODY := 13      # light grey

var _ws
var _frames := 0
var _o := Vector3i.ZERO


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
	_ws._hotbar.save_path = "user://_starter_gun_hotbar.json"
	_ws.toolbars_save = "user://_starter_gun_toolbars.json"
	_build()


func _box(part: String, x0: int, x1: int, y0: int, y1: int, z0: int, z1: int, colour: int) -> void:
	_ws.select_part(_ws.part_names.find(part))
	_ws._colour = colour
	_ws._mat = 0
	var cells := {}
	for x in range(x0, x1 + 1):
		for y in range(y0, y1 + 1):
			for z in range(z0, z1 + 1):
				cells[_o + Vector3i(x, y, z)] = true
	_ws.fill_cells(cells)


## A mount on `part` and the socket on the body that takes it, at cell `c` (relative), in the
## middle across (the mirror's line).
func _joint(part: String, slot: String, iface: String, c: Vector3) -> void:
	var at := [float(_o.x) + c.x, float(_o.y) + c.y, _ws.mirror_z]
	_ws.select_part(_ws.part_names.find(part))
	_ws.toggle_point(at, "mount", slot, iface)
	_ws.select_part(_ws.part_names.find("body"))
	var at2 := [at[0], at[1], at[2] + 0.5]   # one spot a point: the socket a half stud over
	_ws.toggle_point(at2, "socket", slot, iface)


func _build() -> void:
	_ws._new_build()
	_ws.set_asset_kind("gun")
	_ws.set_gun_scale("mech")
	_ws.set_gun_class("lmg")
	_ws.part_maker = MAKER
	_ws.muzzle_end = "-x"
	_ws.recipe.name = NAME
	_o = Vector3i(_ws.plate_studs / 2, 40, int(floor(_ws.mirror_z)))

	# Body: the receiver, 10 studs long, 12 plates tall, 5 studs across; a carry rail on top.
	_box("body", 0, 9, 6, 17, -2, 2, FRAME)
	_box("body", 1, 8, 18, 19, -1, 1, ACCENT)
	_box("body", 0, 9, 10, 11, 3, 3, ACCENT)                 # side stripe, left
	_box("body", 0, 9, 10, 11, -3, -3, ACCENT)               # and right
	# Barrel: a shroud and the bore, 14 studs ahead of the body.
	_box("barrel", -10, -1, 9, 14, -1, 1, BARREL)
	_box("barrel", -14, -11, 10, 13, 0, 0, BARREL)
	_box("barrel", -10, -9, 8, 15, -2, 2, FRAME)             # shroud collar
	# Box magazine under the front of the body.
	_box("magazine", 1, 5, 0, 5, -2, 2, ACCENT)
	# Grip under the back: what the mech's fist holds.
	_box("grip", 7, 8, 0, 5, -1, 1, GRIP)
	# Stock: a short butt behind.
	_box("stock", 10, 13, 8, 15, -1, 1, BODY)

	# The joints, mech gun interfaces (standards.json mgun_interfaces).
	_joint("barrel", "barrel", "mgun.barrel.collar", Vector3(0, 12, 0))
	_joint("magazine", "magazine", "mgun.mag.wide", Vector3(3, 6, 0))
	_joint("grip", "grip", "mgun.grip.pin", Vector3(8, 6, 0))
	_joint("stock", "stock", "mgun.stock.tube", Vector3(10, 12, 0))

	print("[starter gun] bricks: ", _ws.part_counts())
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(BUILD.get_base_dir()))
	_ws._current_path = BUILD
	var ok: bool = _ws._write(BUILD)
	print("[starter gun] build written: %s, parts in %s" % [ok, _ws.parts_dir()])
	var cat := PartCatalog.new()
	cat.load_dir(_ws.parts_dir(), "official")
	var made := AssetGuns.designs(cat, "mech")
	print("[starter gun] mech gun designs: ", made.keys())
	var lib := GunPlaceholderParts.build_library()
	var res := AssetGuns.generate(lib, &"starter_mech_lmg", 1, 1, 3, cat, "mech")
	print("[starter gun] rolled: %s" % (res.gun_name if res != null else "nothing"))
	quit(0 if ok and res != null else 1)
