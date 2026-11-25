extends Node3D

## The ITEMS HANDS in the mine world (Docs/Inventory.md 1-2, Docs/MineWorld.md
## 8): break and place blocks, pour and scoop, Minecraft's way, in brick --
## with whatever the inventory puts in the hand.
##
##   (the selected slot is in the hands: a gun fires, anything else builds)
##   LMB      break the block looked at (held: keeps breaking); a bucket
##            scoops, a test fluid takes the fluid looked at
##   RMB      use the item in hand: place its block on the face looked at
##            (held: repeats), pour a fluid
##   MMB      pick the block looked at into the hand
##   farming (Docs/MineFarming.md, MineFarming): a hoe's RMB tills soil, a
##            seed's RMB plants on tilled soil, RMB on a ripe crop harvests,
##            LMB on a crop harvests or pulls it
##   1-9, wheel   a slot of the active hotbar
##   X        tap: the other hotbar; held: the other off-hand slot
##   Z        block size: 2x2, 1x1 or 4x4 studs, one brick tall
##   E, Tab   the inventory screen (host.toggle_inventory; InventoryScreen)
##
## The guns are the arsenal's and stay there: with the items in hand the gun
## neither fires nor aims (PlayerController.hold_fire) and is put away, and
## the slot keys, the wheel and X do not reach the arsenal or the fly speed.
## `inv` (Inventory) is the player's items; this node is their hands and HUD.
##
## A block is BrickTerrain's own edit: `fill_box` writes plate cells, the
## streamer rebakes the tiles behind the old ones (`host.terrain_edited`), so
## a placed block is ground like any other -- packed into pieces, studded,
## collided with, broken again by a shot. Blocks sit on a lattice of their
## size, so placed ones line up.
##
## Fluids (Docs/MineWater.md 10), each an item:
##   bucket: holds 9 tiles (3 bricks), kept in its stack (`data.tiles`). LMB
##      on still water scoops a brick (3 tiles); LMB on a source (all sea
##      water is) fills it to 9 and the source stays. RMB pours a brick of
##      still water.
##   source bucket: LMB scoops one source brick, water or lava
##      (`data.fluid`); RMB puts it down, a spring.
##   water source, water brick, lava source (creative): RMB pours one in
##      every stud of the block, LMB takes the fluid looked at.
## Blocks placed into water delete it (13.4): the builder's aim passes
## through water. Not where they would float: a block in water must stand
## on ground or hang under it (floats_on_water, R3).
##
## Creative (`inv.creative`, the default): nothing is used up and breaking
## gives nothing. Survival: a block of n x n studs uses n*n of the stack
## (one item is a 1x1 stud brick), and breaking gives the broken material,
## a brick for every 3 plates.
##
## Preloaded by path, not named (see terrain_scene.gd).

const REACH := 6.0
const REPEAT := 0.22
## The SHAPES a material is laid in (Docs/Inventory.md 11): name, studs
## across (x), studs deep (z), plates tall. Z cycles them, R turns a long one,
## V the material's colour. A shape sits on a lattice of its own size, so
## laid ones line up; it costs the plate cells it fills.
const SHAPES := [
	["2x2 brick", 2, 2, 3], ["1x1 brick", 1, 1, 3], ["4x4 brick", 4, 4, 3], ["1x2 brick", 1, 2, 3],
	["2x4 brick", 2, 4, 3], ["1x1 plate", 1, 1, 1], ["2x2 plate", 2, 2, 1], ["2x4 plate", 2, 4, 1]]
const BAR_KEYS := [KEY_1, KEY_2, KEY_3, KEY_4, KEY_5, KEY_6, KEY_7, KEY_8, KEY_9]

var host: Node = null
var active := false
## The shape (SHAPES index; the name is older than the shapes).
var size_i := 0
## A long shape turned a quarter (R).
var turned := false
## Each material's chosen colour (material id -> index into its colours, V).
var _colour := {}
var inv := Inventory.new()
## A piece's brick looked at, nearer than the ground: [piece, point inside
## it], or empty.
var piece_target: Array = []
## The ray's answer this frame (BrickTerrain.ray_cell), or empty.
var target := {}
var placed := 0
var broken := 0
## The last blocks placed and broken (block coordinates), for the gate.
var log_blocks: Array[String] = []

var _outline: MeshInstance3D
var _hud: HotbarHud
var _hold_break := 0.0
## A pickaxe's breaks being found on a worker: [task, holder, material].
## Which whole bricks a break takes packs the tile (~10 ms); the main thread
## only clears them (BrickTerrain.find_brick / find_bricks, clear_runs).
var _pick_jobs: Array = []
const MAX_PICK_JOBS := 2
var _hold_place := 0.0
## X: when it went down (ms), or -1; and whether this hold already swapped the off-hand.
var _x_down := -1
var _x_held_used := false
## A gate that tests the keys the player's way (--gate=inventory) turns this on.
var gate_keys := false
## Trees are looked at (Docs/Inventory.md 13); a gate aiming at the ground
## beside one turns it off.
var aim_trees := true


func setup(p_host: Node, hud_layer: CanvasLayer) -> void:
	host = p_host
	inv.seed_default()
	_outline = MeshInstance3D.new()
	_outline.name = "Target"
	_outline.mesh = _box_lines()
	var m := StandardMaterial3D.new()
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	m.albedo_color = Color(0.05, 0.05, 0.05)
	m.no_depth_test = false
	_outline.material_override = m
	_outline.visible = false
	_outline.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(_outline)
	_hud = HotbarHud.new()
	_hud.name = "Hotbars"
	hud_layer.add_child(_hud)
	_hud.visible = false
	set_inventory(inv)


## Hand the hands another inventory (a world loaded its own).
func set_inventory(p_inv: Inventory) -> void:
	if inv != null and inv.changed.is_connected(_refresh_bar):
		inv.changed.disconnect(_refresh_bar)
	inv = p_inv
	inv.changed.connect(_refresh_bar)
	_hud.bind(inv)
	_refresh_bar()


## The shape's size: studs across, plates tall, studs deep.
func dims() -> Vector3i:
	var s: Array = SHAPES[size_i]
	return Vector3i(int(s[2]) if turned else int(s[1]), int(s[3]), int(s[1]) if turned else int(s[2]))


func block_studs() -> int:
	return dims().x


## The terrain colour the material in hand lays (its chosen one).
func lay_material(d: Dictionary) -> int:
	var cols: PackedInt32Array = d.get("colours", PackedInt32Array())
	if cols.is_empty():
		return int(d.get("material", 0))
	return cols[posmod(int(_colour.get(d.id, 0)), cols.size())]


## What the hand holds, and its catalog entry ({} for an empty hand).
func hand() -> ItemStack:
	return inv.hand()


func hand_def() -> Dictionary:
	var h := inv.hand()
	return ItemCatalog.get_def(h.id) if h != null else {}


func hand_kind() -> String:
	return str(hand_def().get("kind", ""))


## Put the item `id` in the hand (a gate's way of pressing its slot key).
func select(id: StringName) -> bool:
	return inv.select_item(id)


## The bucket in hand's water, tiles (0 when the hand holds no bucket).
func bucket_tiles() -> int:
	var h := inv.hand()
	return int(h.data.get("tiles", 0)) if h != null and hand_kind() == "bucket" else 0


## The hand holds a block, tool or item (true) or a gun (false): MineHands
## says which (Docs/Inventory.md 10). The hotbars show either way.
func set_active(on: bool) -> void:
	active = on
	_hud.visible = true
	if not on:
		_outline.visible = false
		target = {}
		_x_down = -1
	var player: PlayerController = host.player
	if player != null:
		player.hold_fire = on
	var view: PlayerView = host.view
	if view != null and host.on_foot:
		view.rig.visible = not on
	_refresh_bar()


## The view changed hands (walk/fly): the gun shows again only on foot and
## only with the guns in hand.
func on_mode_changed() -> void:
	var view: PlayerView = host.view
	if view != null and host.on_foot:
		view.rig.visible = not active


# ---------------------------------------------------------------------------
# Input: first, before the arsenal, the camera and the walker see it.

func _input(event: InputEvent) -> void:
	if host == null or host.get("_menu") != null or host.inventory_open():
		return
	# A gate drives the hands itself; it may send the keys it tests (gate_keys).
	if host.get("_gate") and not gate_keys:
		return
	if event is InputEventKey and not event.echo:
		var k := (event as InputEventKey).keycode
		# No B any more: what is in the selected slot is in the hands, a gun
		# or anything else (MineHands). The hotbar keys work either way.
		if k == KEY_X:
			if event.pressed:
				_x_down = Time.get_ticks_msec()
				_x_held_used = false
			else:
				if _x_down >= 0 and not _x_held_used:
					inv.toggle_hotbar()
				_x_down = -1
			get_viewport().set_input_as_handled()
		elif event.pressed and k == KEY_G:
			host.throw_grenade()          # whatever is in the hand (Docs/Inventory.md 10)
			get_viewport().set_input_as_handled()
		elif event.pressed and (k == KEY_E or k == KEY_TAB):
			host.toggle_inventory()
			get_viewport().set_input_as_handled()
		elif event.pressed and k == KEY_Z:
			size_i = (size_i + 1) % SHAPES.size()
			_refresh_bar()
			get_viewport().set_input_as_handled()
		elif event.pressed and k == KEY_R and active and hand_kind() == "block":
			turned = not turned          # with a gun R is the gun's reload
			_refresh_bar()
			get_viewport().set_input_as_handled()
		elif event.pressed and k == KEY_V and active and hand_kind() == "block":
			var d := hand_def()
			_colour[d.id] = int(_colour.get(d.id, 0)) + 1
			_refresh_bar()
			get_viewport().set_input_as_handled()
		elif event.pressed and BAR_KEYS.has(k):
			inv.select_slot(BAR_KEYS.find(k))
			get_viewport().set_input_as_handled()
		return
	if not (event is InputEventMouseButton):
		return
	if Input.mouse_mode != Input.MOUSE_MODE_CAPTURED and not PlayerCamera.hands_off:
		return            # a click that captures the mouse is the camera's
	var mb := event as InputEventMouseButton
	if not mb.pressed:
		return
	# The wheel walks the hotbar whatever is in the hand (Shift + wheel: left
	# to the flight's speed).
	if mb.button_index in [MOUSE_BUTTON_WHEEL_UP, MOUSE_BUTTON_WHEEL_DOWN] and not mb.shift_pressed:
		inv.scroll(-1 if mb.button_index == MOUSE_BUTTON_WHEEL_UP else 1)
		get_viewport().set_input_as_handled()
		return
	if not active:
		return            # a gun: the clicks are the gun's
	if mb.button_index == MOUSE_BUTTON_LEFT and hand_kind() == "grenade":
		host.throw_grenade()
		get_viewport().set_input_as_handled()
		return
	match mb.button_index:
		MOUSE_BUTTON_LEFT:
			break_target()
			_hold_break = _break_repeat() * 1.5
		MOUSE_BUTTON_RIGHT:
			place_target()
			_hold_place = REPEAT * 1.5
		MOUSE_BUTTON_MIDDLE:
			pick_target()
		_:
			return
	get_viewport().set_input_as_handled()


func _process(delta: float) -> void:
	_land_picks()
	if host == null:
		return
	if _x_down >= 0 and not _x_held_used and Time.get_ticks_msec() - _x_down >= Inventory.HOLD_MS:
		_x_held_used = true
		inv.toggle_offhand()
	if not active:
		return
	update_target()
	var captured := Input.mouse_mode == Input.MOUSE_MODE_CAPTURED
	if captured and Input.is_mouse_button_pressed(MOUSE_BUTTON_LEFT):
		_hold_break -= delta
		if _hold_break <= 0.0:
			break_target()
			_hold_break = _break_repeat()
	if captured and Input.is_mouse_button_pressed(MOUSE_BUTTON_RIGHT):
		_hold_place -= delta
		if _hold_place <= 0.0:
			place_target()
			_hold_place = REPEAT


# ---------------------------------------------------------------------------
# The block looked at

func update_target() -> void:
	var c: Camera3D = host._eye_camera()
	# The field is in the mine world's terrain frame (its origin shift).
	var from: Vector3 = host.to_local(c.global_position)
	var dir := -c.global_transform.basis.z
	target = BrickTerrain.ray_cell(from, dir, REACH)
	# A piece of fallen ground in front of the ground: its brick is the one
	# looked at (Docs/TerrainCollapse.md).
	piece_target = []
	if host.collapse != null:
		var gfrom := c.global_position
		var q := PhysicsRayQueryParameters3D.create(gfrom, gfrom + dir * REACH,
				Layers.DEBRIS | Layers.FALLING)
		var hit: Dictionary = host.get_world_3d().direct_space_state.intersect_ray(q)
		if not hit.is_empty():
			var p: PlanetPieces.Piece = host.collapse.piece_of_body(hit.collider)
			var ground := INF if target.is_empty() else from.distance_to(target.position)
			if p != null and gfrom.distance_to(hit.position) < ground:
				# A stud's height in, past the studs' shapes: inside the brick.
				var inside: Vector3 = hit.position - (hit.normal as Vector3) * 0.1
				var xf = host.collapse.piece_brick_xform(p, inside)
				if xf != null:
					piece_target = [p, inside]
					target = {}
					_outline.visible = true
					_outline.global_transform = xf
					return
	# A chest nearer than the ground is what is looked at (MineChests).
	var ch: Dictionary = host.chests.ray(from, dir, REACH)
	if not ch.is_empty() and (target.is_empty() or float(ch.dist) < from.distance_to(target.position)):
		target = {"chest": ch.key, "position": ch.point}
		var box: AABB = host.chests.box_of(host.chests.chests[ch.key].block)
		_outline.visible = true
		_outline.global_transform = Transform3D(Basis.from_scale(box.size * 1.01),
				host.to_global(box.position - box.size * 0.005))
		return
	# A device (lever, lamp) nearer than the ground (Docs/MineWiring.md).
	if host.wiring != null:
		var dv: Dictionary = host.wiring.ray_device(from, dir, REACH)
		if not dv.is_empty() and (target.is_empty() or float(dv.dist) < from.distance_to(target.position)):
			target = {"device": dv.cell, "position": dv.point}
			var dbox: AABB = host.wiring.device_box(dv.cell)
			_outline.visible = true
			_outline.global_transform = Transform3D(Basis.from_scale(dbox.size * 1.02),
					host.to_global(dbox.position - dbox.size * 0.01))
			return
	# A tree nearer than the ground (Docs/Inventory.md 13): its trunk or its
	# canopy, outlined; LMB fells it.
	var tr: Dictionary = host.tree_ray(from, dir, REACH) if aim_trees else {}
	if not tr.is_empty() and (target.is_empty() or float(tr.dist) < from.distance_to(target.position)):
		target = {"tree": tr.cell, "position": tr.point}
		var tbox: AABB = tr.box
		_outline.visible = true
		_outline.global_transform = Transform3D(Basis.from_scale(tbox.size * 1.01),
				host.to_global(tbox.position - tbox.size * 0.005))
		return
	if target.is_empty():
		_outline.visible = false
		return
	# A cable tile on the top looked at: it is what LMB breaks (the ground's
	# target stays, so a block is still laid there).
	if host.wiring != null and Vector3i(target.normal) == Vector3i.UP \
			and host.wiring.cables.has(Vector3i(target.cell) + Vector3i.UP):
		var cc: Vector3i = Vector3i(target.cell) + Vector3i.UP
		target["cable"] = cc
		var cbox: AABB = host.wiring.cable_box(cc)
		_outline.visible = true
		_outline.global_transform = Transform3D(Basis.from_scale(cbox.size * 1.02),
				host.to_global(cbox.position - cbox.size * 0.01))
		return
	var b := _block_of(target.cell)
	var lo := _cell_lo(b)
	var size := _block_size_m()
	_outline.visible = true
	_outline.global_transform = Transform3D(Basis.from_scale(size * 1.004),
			host.to_global(lo - size * 0.002))


## The block (on this size's lattice) holding plate cell `cell`.
func _block_of(cell: Vector3i) -> Vector3i:
	var d := dims()
	return Vector3i(floori(float(cell.x) / d.x), floori(float(cell.y) / d.y), floori(float(cell.z) / d.z))


func _cell_lo(block: Vector3i) -> Vector3:
	var d := dims()
	var stud := BrickWorld.get_stud_metres()
	return Vector3(block.x * d.x * stud, block.y * d.y * BrickWorld.get_plate_metres(), block.z * d.z * stud)


func _block_size_m() -> Vector3:
	var d := dims()
	var stud := BrickWorld.get_stud_metres()
	return Vector3(d.x * stud, d.y * BrickWorld.get_plate_metres(), d.z * stud)


## Plate-cell bounds (inclusive) of a block.
func _cells(block: Vector3i) -> Array[Vector3i]:
	var d := dims()
	var lo := Vector3i(block.x * d.x, block.y * d.y, block.z * d.z)
	return [lo, lo + d - Vector3i.ONE]


## NO BRICKS ON WATER (Docs/MineWaterNext.md R3; decision A, the user
## 2026-11-24): a block put where water (or lava) is must be built up from
## ground under it or down from ground over it -- terrain bricks join only
## top to bottom, so one laid sideways off a shore over water held nothing
## and fell. Where it does go, it takes the water's place and the water
## round it stays (R4: a beach there; broken, the body heals).
func floats_on_water(to: Vector3i) -> bool:
	var c := _cells(to)
	var wet := false
	for x in range(c[0].x, c[1].x + 1):
		for z in range(c[0].z, c[1].z + 1):
			if int(BrickFluid.cell_info(Vector3i(x, to.y, z)).fluid) != 0:
				wet = true
	if not wet:
		return false
	for x in range(c[0].x, c[1].x + 1):
		for z in range(c[0].z, c[1].z + 1):
			if int(BrickFluid.cell_info(Vector3i(x, to.y - 1, z)).solid) & 4:
				return false            # built up from the ground under it
			if int(BrickFluid.cell_info(Vector3i(x, to.y + 1, z)).solid) & 1:
				return false            # down from the ground over it
	return true


func _is_fluid_item(k: String) -> bool:
	return k == "bucket" or k == "source_bucket" or k == "fluid"


## Seconds between breaks while the button is held: the tool's own
## (`break_repeat` in its item, the Mega Pickaxe's 0.05) or REPEAT.
func _break_repeat() -> float:
	return float(hand_def().get("break_repeat", REPEAT))


## The plate cells a break clears: the block looked at, or for a tool with a
## `break_area` (the Mega Pickaxe: 5) that many blocks by that many across
## the face looked at, one block deep, centred on the block.
func _break_cells() -> Array[Vector3i]:
	var b := _block_of(target.cell)
	var c := _cells(b)
	var area := int(hand_def().get("break_area", 1))
	if area <= 1:
		return c
	var n: Vector3i = target.get("normal", Vector3i.UP)
	var half := area >> 1   # area is a positive brush size
	var lo := b
	var hi := b
	for axis in 3:
		if n[axis] == 0:
			lo[axis] -= half
			hi[axis] += area - 1 - half
	var a := _cells(lo)
	var z := _cells(hi)
	return [a[0], z[1]]


func break_target() -> bool:
	if _is_fluid_item(hand_kind()):
		return take_fluid()
	if target.is_empty() and piece_target.is_empty():
		update_target()
	if not piece_target.is_empty():
		var ok: bool = host.collapse.mine_piece(piece_target[0], piece_target[1])
		piece_target = []
		if ok:
			broken += 1
			log_blocks.append("break piece brick")
		return ok
	if target.is_empty():
		return false
	if target.has("chest"):
		# Its contents fall out; survival: the chest too (MineChests).
		host.chests.break_chest(target.chest, not inv.creative)
		broken += 1
		log_blocks.append("break chest %s" % target.chest)
		target = {}
		return true
	if target.has("device"):
		host.wiring.remove_device(target.device)
		broken += 1
		log_blocks.append("break device %s" % target.device)
		target = {}
		return true
	if target.has("cable"):
		host.wiring.remove_cable(target.cable)
		broken += 1
		log_blocks.append("break cable %s" % target.cable)
		target = {}
		return true
	if target.has("tree"):
		return _fell(target.tree, target.position)
	# A crop on tilled soil: harvested if ripe, else pulled (MineFarming).
	if host.farming != null and host.farming.break_target(target):
		broken += 1
		log_blocks.append("crop %s" % target.cell)
		target = {}
		return true
	var material := int(target.get("material", 0))
	if hand_kind() == "tool":
		return _pick(material)
	var c := _break_cells()
	var res: Dictionary = BrickTerrain.fill_box(c[0], c[1], 0, false)
	if int(res.changed) == 0:
		return false
	broken += 1
	log_blocks.append("break %s" % _block_of(target.cell))
	var at := _cell_lo(_block_of(target.cell)) + _block_size_m() * 0.5
	host.terrain_edited(res)
	MineRain.melt(material, c[0], c[1])
	if host.farming != null:
		host.farming.cells_changed(c[0], c[1])
	target = {}
	# Survival: the broken bricks into the inventory; what does not fit drops
	# where the block was.
	var id := ItemCatalog.block_item(material)
	if not inv.creative and id != &"":
		var left := inv.add_item(ItemStack.make(id, int(res.changed)))
		if left != null:
			host.drops.spawn(left, at)
		_find_seeds(material, at)
	return true


## Survival: grass and the like broken by hand may give a crop's seed
## (FarmCrops.found_in, the crops' "found").
func _find_seeds(material: int, at: Vector3) -> void:
	var names: PackedStringArray = BrickTerrain.material_names()
	if material <= 0 or material >= names.size():
		return
	for f in FarmCrops.found_in(names[material]):
		if randf() < float(f[1]) and ItemCatalog.has(f[0]):
			var left := inv.add_item(ItemStack.make(f[0], 1))
			if left != null:
				host.drops.spawn(left, at)
			log_blocks.append("found %s" % f[0])


## LMB on a tree, by hand or with a tool (Docs/Inventory.md 13): the whole
## tree comes down. Survival: its trunk as wood, its canopy as leaves, in
## plate cells (Trees.yield_cells); what does not fit drops where it stood.
func _fell(cell: Vector2i, at: Vector3) -> bool:
	var got: Dictionary = host.fell_tree(cell)
	target = {}
	if got.is_empty():
		return false
	broken += 1
	log_blocks.append("fell tree %s" % cell)
	if not inv.creative:
		for k in ["wood", "leaves"]:
			var id := StringName(k)
			if int(got.get(k, 0)) > 0 and ItemCatalog.has(id):
				var left := inv.add_item(ItemStack.make(id, int(got[k])))
				if left != null:
					host.drops.spawn(left, at)
	return true


## A pickaxe breaks BRICKS, whole, the way a shot does (Docs/MineWorld.md
## 10): the surface piece looked at all of it, or one brick cell in a wall --
## never a block-lattice box cut through them, which made the packer lay the
## ground round the hole again. The Mega Pickaxe takes every brick its 5 x 5
## face touches, each whole (BrickTerrain.find_bricks).
func _pick(material: int) -> bool:
	if _pick_jobs.size() >= MAX_PICK_JOBS:
		return false
	var holder := [{}]
	var task := -1
	if int(hand_def().get("break_area", 1)) > 1:
		var c := _break_cells()
		var lo: Vector3i = c[0]
		var hi: Vector3i = c[1]
		task = WorkerThreadPool.add_task(func() -> void:
				holder[0] = BrickTerrain.find_bricks(lo, hi), true, "pickaxe area")
	else:
		var point: Vector3 = target.position
		var n := Vector3(target.get("normal", Vector3i.UP))
		task = WorkerThreadPool.add_task(func() -> void:
				holder[0] = BrickTerrain.find_brick(point, n), true, "pickaxe")
	_pick_jobs.append([task, holder, material])
	target = {}
	return true


## Finished pickaxe breaks: clear the bricks each found. Never waits.
func _land_picks() -> void:
	var i := 0
	while i < _pick_jobs.size():
		var job: Array = _pick_jobs[i]
		if not WorkerThreadPool.is_task_completed(int(job[0])):
			i += 1
			continue
		WorkerThreadPool.wait_for_task_completion(int(job[0]))
		_pick_jobs.remove_at(i)
		var runs: PackedInt32Array = (job[1][0] as Dictionary).get("runs", PackedInt32Array())
		if runs.is_empty() or host == null:
			continue
		var res: Dictionary = BrickTerrain.clear_runs(runs)
		var removed := int(res.get("removed", 0))
		if removed == 0:
			continue
		broken += 1
		log_blocks.append("pick %d plates" % removed)
		host.terrain_edited(res)
		if res.has("box_lo"):
			MineRain.melt(int(job[2]), res.box_lo, res.box_hi)
		var id := ItemCatalog.block_item(int(job[2]))
		if not inv.creative and id != &"":
			inv.add_item(ItemStack.make(id, removed))


func _exit_tree() -> void:
	for job in _pick_jobs:
		WorkerThreadPool.wait_for_task_completion(int(job[0]))
	_pick_jobs.clear()


func place_target() -> bool:
	if target.is_empty():
		update_target()
		if target.is_empty():
			return false
	if target.has("tree"):
		return false           # nothing is built onto a tree
	if target.has("chest"):
		# Shift + RMB on a backpack put down: picked up and worn (swapped for
		# the one worn); else RMB opens it, whatever is in the hand.
		if Input.is_key_pressed(KEY_SHIFT) and ItemCatalog.kind(host.chests.item_of(target.chest)) == "backpack":
			host.take_backpack(target.chest)
		else:
			host.open_chest(target.chest)
		target = {}
		return true
	if target.has("device"):
		# RMB on a lever turns it, whatever is in the hand (Docs/MineWiring.md).
		var used: bool = host.wiring.use_device(target.device)
		if used:
			log_blocks.append("use device %s" % target.device)
		target = {}
		return used
	var d := hand_def()
	var k := str(d.get("kind", ""))
	if k == "wire" or k == "device":
		return _place_wiring(k, d.id)
	# Farming (MineFarming): a ripe crop is picked whatever is in the hand;
	# a hoe tills, a seed plants.
	if host.farming != null:
		if host.farming.harvest_target(target):
			log_blocks.append("harvest %s" % target.cell)
			target = {}
			return true
		if k == "hoe":
			var ok: bool = host.farming.till(target)
			if ok:
				placed += 1
				log_blocks.append("till %s" % target.cell)
			target = {}
			return ok
		if k == "seed":
			var ok2: bool = host.farming.plant(target, d.id)
			if ok2:
				inv.consume_hand(1)
				placed += 1
				log_blocks.append("plant %s %s" % [d.id, target.cell])
			target = {}
			return ok2
	if k == "chest" or k == "station" or k == "backpack":
		return _place_chest()          # a workbench, furnace or backpack stands like a chest
	var b := _block_of(target.cell)
	var n: Vector3i = target.normal
	var to := b + n
	var c := _cells(to)
	if _is_fluid_item(k):
		return pour(to)
	if k != "block":
		return false            # tools, chests (stage 5), an empty hand
	var dd := dims()
	if not inv.creative and inv.hand().count < dd.x * dd.y * dd.z:
		return false
	if _blocks_player(to) or host.chests.overlaps(AABB(_cell_lo(to), _block_size_m())) \
			or (host.wiring != null and host.wiring.overlaps(AABB(_cell_lo(to), _block_size_m()))):
		return false
	if floats_on_water(to):
		log_blocks.append("refused on water %s" % to)
		return false
	var lay := lay_material(d)
	var res: Dictionary = BrickTerrain.fill_box(c[0], c[1], lay, true)
	if int(res.changed) == 0:
		return false
	# One brick, the block laid: the ground's bond keeps it whole -- drawn,
	# broken and falling as one (Docs/TerrainBond.md 1).
	BrickTerrain.mark_placed(c[0], c[1], lay)
	# The plate cells it filled (Docs/Inventory.md 11).
	inv.consume_hand(int(res.changed))
	placed += 1
	log_blocks.append("place %s" % to)
	host.terrain_edited(res)
	target = {}
	return true


## A fluid item's RMB: the fluid in every stud of block `to`, its course.
func pour(to: Vector3i) -> bool:
	var c := _cells(to)
	var h := inv.hand()
	var d := hand_def()
	var cell := Vector3i(c[0].x, to.y, c[0].z)
	match str(d.get("kind", "")):
		"bucket":
			var tiles := int(h.data.get("tiles", 0))
			if tiles <= 0:
				return false
			var n := mini(3, tiles)
			BrickFluid.place(cell, 1, BrickFluid.STILL, n)
			_set_data(h, "tiles", tiles - n)
			log_blocks.append("bucket pour %d %s" % [n, cell])
			target = {}
			return true
		"source_bucket":
			var fl := int(h.data.get("fluid", 0))
			if fl == 0:
				return false
			BrickFluid.place(cell, fl, BrickFluid.SOURCE, 3)
			log_blocks.append("source bucket pour %s" % cell)
			_set_data(h, "fluid", 0)
			target = {}
			return true
	var fluid := int(d.get("fluid", 1))
	var kind := BrickFluid.STILL if d.get("fluid_kind", "") == "still" else BrickFluid.SOURCE
	for x in range(c[0].x, c[1].x + 1):
		for z in range(c[0].z, c[1].z + 1):
			BrickFluid.place(Vector3i(x, to.y, z), fluid, kind, 3)
	placed += 1
	log_blocks.append("pour %s %s" % [d.get("name", "?"), to])
	target = {}
	return true


## A stack's per-stack state changed: 0 clears the key, so an empty bucket is
## the same kind as a new one.
func _set_data(s: ItemStack, key: String, v: int) -> void:
	if v == 0:
		s.data.erase(key)
	else:
		s.data[key] = v
	inv.changed.emit()


## A fluid item's LMB: the fluid cell looked at goes (a source too).
func take_fluid() -> bool:
	var cam: Camera3D = host._eye_camera()
	var hit: Dictionary = BrickFluid.ray_cell(host.to_local(cam.global_position),
			-cam.global_transform.basis.z, REACH)
	if hit.is_empty() or int(hit.fluid) == 0:
		return false
	var h := inv.hand()
	match hand_kind():
		"bucket":
			var tiles := int(h.data.get("tiles", 0))
			var full := ItemCatalog.BUCKET_TILES
			if int(hit.fluid) != 1 or tiles >= full:
				return false
			if int(hit.kind) == BrickFluid.SOURCE:
				tiles = full                    # the source stays: it is infinite
			elif int(hit.kind) == BrickFluid.STILL:
				var n := mini(mini(3, int(hit.amount)), full - tiles)
				BrickFluid.remove(hit.cell, n)
				tiles += n
			else:
				return false                    # running water slips out
			_set_data(h, "tiles", tiles)
			log_blocks.append("bucket fill %d %s" % [tiles, hit.cell])
			return true
		"source_bucket":
			if int(h.data.get("fluid", 0)) != 0 or int(hit.kind) != BrickFluid.SOURCE:
				return false
			_set_data(h, "fluid", int(hit.fluid))
			# The ocean is infinite: a bucket of it takes nothing away
			# (Docs/MineWater.md 11.9). Only placing a brick moves sea water.
			if not bool(hit.get("ocean", false)):
				BrickFluid.remove(hit.cell, -1)
			log_blocks.append("source bucket take %s" % hit.cell)
			return true
	BrickFluid.remove(hit.cell, -1)
	broken += 1
	log_blocks.append("take %s" % hit.cell)
	return true


func pick_target() -> void:
	if target.is_empty():
		return
	if target.has("chest"):
		inv.pick(host.chests.item_of(target.chest))
		return
	if target.has("tree"):
		inv.pick(&"wood")
		return
	if target.has("device"):
		inv.pick(host.wiring.devices[target.device].item)
		return
	if target.has("cable"):
		inv.pick(&"cable")
		return
	# The material that lays it, set to that colour.
	var m := int(target.material)
	var fam := ItemCatalog.block_item(m)
	if inv.pick(fam):
		var cols: PackedInt32Array = ItemCatalog.get_def(fam).get("colours", PackedInt32Array())
		if cols.has(m):
			_colour[fam] = cols.find(m)
		_refresh_bar()


## The chest item's RMB: a chest standing on the face looked at -- its x and z
## on the 2-stud lattice, its bottom the plate past the face (MineChests).
func _place_chest() -> bool:
	var cell: Vector3i = target.cell + Vector3i(target.normal)
	var blk := MineChests.block_of(cell)
	var h := inv.hand()
	var bag := ItemCatalog.kind(h.id) == "backpack"
	if _box_hits_player(host.chests.box_of(blk)) \
			or not host.chests.place(blk, h.contents if bag else [], false, h.id):
		return false
	if bag:
		# The backpack itself goes down, with its contents: out of the hand
		# even in creative (or the same things would be in two places).
		inv.set_slot(inv.hand_addr(), null)
		inv.changed.emit()
	else:
		inv.consume_hand(1)
	placed += 1
	log_blocks.append("place chest %s" % MineChests.key_of(blk))
	target = {}
	return true


## A cable tile or a device on the face looked at: the plate cell past it
## (Docs/MineWiring.md). A cable needs ground under it; a device too.
func _place_wiring(k: String, id: StringName) -> bool:
	if target.has("cable") or not target.has("cell"):
		return false
	var cell: Vector3i = Vector3i(target.cell) + Vector3i(target.normal)
	var ok := false
	if k == "wire":
		ok = host.wiring.place_cable(cell)
	elif not _box_hits_player(host.wiring.device_box(cell)) and not host.chests.overlaps(host.wiring.device_box(cell)):
		ok = host.wiring.place_device(cell, id)
	if not ok:
		return false
	inv.consume_hand(1)
	placed += 1
	log_blocks.append("place %s %s" % [id, cell])
	target = {}
	return true


## Would a block there stand inside the player?
func _blocks_player(block: Vector3i) -> bool:
	return _box_hits_player(AABB(_cell_lo(block), _block_size_m()))


func _box_hits_player(box: AABB) -> bool:
	var feet: Vector3
	if host.on_foot:
		feet = host.to_local((host.pawn as Pawn).feet())
	else:
		feet = host.to_local((host.walker as Node3D).global_position)
	var me := AABB(feet - Vector3(0.3, 0.0, 0.3), Vector3(0.6, 1.75, 0.6))
	return box.intersects(me)


# ---------------------------------------------------------------------------
# The HUD

func _refresh_bar() -> void:
	if _hud == null:
		return
	var what := ItemCatalog.label(inv.hand())
	var keys := "1-9 / wheel hand  X bar  E items"
	if hand_kind() == "block":
		var d := hand_def()
		var dd := dims()
		var cols: PackedInt32Array = d.get("colours", PackedInt32Array())
		if cols.size() > 1:
			var lm := lay_material(d)
			var mn := BrickTerrain.material_names()
			# A building colour (MAT_FIL_BASE + filament) is named by its filament.
			what += " (%s)" % (mn[lm] if lm < mn.size() else BrickWorld.get_material_colour_name(0, BrickTerrain.material_filament_index(lm)))
		what += "  -  %s%s, %d cells" % [SHAPES[size_i][0], " turned" if turned and dd.x != dd.z else "",
				dd.x * dd.y * dd.z]
		keys = "Z shape  R turn  V colour  " + keys
	_hud.caption = "%s%s   (%s)" % [what, "" if inv.creative else "  [survival]", keys]
	_hud.redraw()


static func _box_lines() -> ArrayMesh:
	var v := PackedVector3Array()
	var c := [Vector3(0, 0, 0), Vector3(1, 0, 0), Vector3(1, 0, 1), Vector3(0, 0, 1),
			Vector3(0, 1, 0), Vector3(1, 1, 0), Vector3(1, 1, 1), Vector3(0, 1, 1)]
	for e in [[0, 1], [1, 2], [2, 3], [3, 0], [4, 5], [5, 6], [6, 7], [7, 4],
			[0, 4], [1, 5], [2, 6], [3, 7]]:
		v.append(c[e[0]])
		v.append(c[e[1]])
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = v
	var m := ArrayMesh.new()
	m.add_surface_from_arrays(Mesh.PRIMITIVE_LINES, arrays)
	return m
