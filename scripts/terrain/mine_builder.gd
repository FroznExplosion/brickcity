extends Node3D

## The ITEMS HANDS in the mine world (Docs/Inventory.md 1-2, Docs/MineWorld.md
## 8): break and place blocks, pour and scoop, Minecraft's way, in brick --
## with whatever the inventory puts in the hand.
##
##   B        guns <-> items (on foot or flying)
##   LMB      break the block looked at (held: keeps breaking); a bucket
##            scoops, a test fluid takes the fluid looked at
##   RMB      use the item in hand: place its block on the face looked at
##            (held: repeats), pour a fluid
##   MMB      pick the block looked at into the hand
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
## through water.
##
## Creative (`inv.creative`, the default): nothing is used up and breaking
## gives nothing. Survival: a block of n x n studs uses n*n of the stack
## (one item is a 1x1 stud brick), and breaking gives the broken material,
## a brick for every 3 plates.
##
## Preloaded by path, not named (see terrain_scene.gd).

const REACH := 6.0
const REPEAT := 0.22
const SIZES := [2, 1, 4]
const BAR_KEYS := [KEY_1, KEY_2, KEY_3, KEY_4, KEY_5, KEY_6, KEY_7, KEY_8, KEY_9]

var host: Node = null
var active := false
var size_i := 0
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


func block_studs() -> int:
	return SIZES[size_i]


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


func set_active(on: bool) -> void:
	active = on
	_hud.visible = on
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
		if event.pressed and k == KEY_B:
			set_active(not active)
			get_viewport().set_input_as_handled()
			return
		if not active:
			return
		if k == KEY_X:
			if event.pressed:
				_x_down = Time.get_ticks_msec()
				_x_held_used = false
			else:
				if _x_down >= 0 and not _x_held_used:
					inv.toggle_hotbar()
				_x_down = -1
			get_viewport().set_input_as_handled()
		elif event.pressed and (k == KEY_E or k == KEY_TAB):
			host.toggle_inventory()
			get_viewport().set_input_as_handled()
		elif event.pressed and k == KEY_Z:
			size_i = (size_i + 1) % SIZES.size()
			_refresh_bar()
			get_viewport().set_input_as_handled()
		elif event.pressed and BAR_KEYS.has(k):
			inv.select_slot(BAR_KEYS.find(k))
			get_viewport().set_input_as_handled()
		return
	if not active or not (event is InputEventMouseButton):
		return
	if Input.mouse_mode != Input.MOUSE_MODE_CAPTURED and not PlayerCamera.hands_off:
		return            # a click that captures the mouse is the camera's
	var mb := event as InputEventMouseButton
	if not mb.pressed:
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
		MOUSE_BUTTON_WHEEL_UP:
			inv.scroll(-1)
		MOUSE_BUTTON_WHEEL_DOWN:
			inv.scroll(1)
		_:
			return
	get_viewport().set_input_as_handled()


func _process(delta: float) -> void:
	_land_picks()
	if not active or host == null:
		return
	if _x_down >= 0 and not _x_held_used and Time.get_ticks_msec() - _x_down >= Inventory.HOLD_MS:
		_x_held_used = true
		inv.toggle_offhand()
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
	if target.is_empty():
		_outline.visible = false
		return
	var b := _block_of(target.cell)
	var lo := _cell_lo(b)
	var size := _block_size_m()
	_outline.visible = true
	_outline.global_transform = Transform3D(Basis.from_scale(size * 1.004),
			host.to_global(lo - size * 0.002))


## The block (on this size's lattice) holding plate cell `cell`.
func _block_of(cell: Vector3i) -> Vector3i:
	var s := block_studs()
	return Vector3i(floori(float(cell.x) / s), floori(float(cell.y) / 3.0), floori(float(cell.z) / s))


func _cell_lo(block: Vector3i) -> Vector3:
	var s := block_studs()
	var stud := BrickWorld.get_stud_metres()
	return Vector3(block.x * s * stud, block.y * 3 * BrickWorld.get_plate_metres(), block.z * s * stud)


func _block_size_m() -> Vector3:
	var s := block_studs()
	var stud := BrickWorld.get_stud_metres()
	return Vector3(s * stud, 3.0 * BrickWorld.get_plate_metres(), s * stud)


## Plate-cell bounds (inclusive) of a block.
func _cells(block: Vector3i) -> Array[Vector3i]:
	var s := block_studs()
	var lo := Vector3i(block.x * s, block.y * 3, block.z * s)
	return [lo, lo + Vector3i(s - 1, 2, s - 1)]


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
	var half := area / 2
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
	target = {}
	# Survival: the broken bricks into the inventory; what does not fit drops
	# where the block was.
	var id := ItemCatalog.block_item(material)
	if not inv.creative and id != &"":
		var left := inv.add_item(ItemStack.make(id, ceili(int(res.changed) / 3.0)))
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
				holder[0] = BrickTerrain.find_bricks(lo, hi), false, "pickaxe area")
	else:
		var point: Vector3 = target.position
		var n := Vector3(target.get("normal", Vector3i.UP))
		task = WorkerThreadPool.add_task(func() -> void:
				holder[0] = BrickTerrain.find_brick(point, n), false, "pickaxe")
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
		var id := ItemCatalog.block_item(int(job[2]))
		if not inv.creative and id != &"":
			inv.add_item(ItemStack.make(id, ceili(removed / 3.0)))


func _exit_tree() -> void:
	for job in _pick_jobs:
		WorkerThreadPool.wait_for_task_completion(int(job[0]))
	_pick_jobs.clear()


func place_target() -> bool:
	if target.is_empty():
		update_target()
		if target.is_empty():
			return false
	if target.has("chest"):
		# RMB on a chest opens it, whatever is in the hand (Minecraft's).
		host.open_chest(target.chest)
		target = {}
		return true
	var d := hand_def()
	var k := str(d.get("kind", ""))
	if k == "chest":
		return _place_chest()
	var b := _block_of(target.cell)
	var n: Vector3i = target.normal
	var to := b + n
	var c := _cells(to)
	if _is_fluid_item(k):
		return pour(to)
	if k != "block":
		return false            # tools, chests (stage 5), an empty hand
	var s := block_studs()
	if not inv.creative and inv.hand().count < s * s:
		return false
	if _blocks_player(to) or host.chests.overlaps(AABB(_cell_lo(to), _block_size_m())):
		return false
	var res: Dictionary = BrickTerrain.fill_box(c[0], c[1], int(d.material), true)
	if int(res.changed) == 0:
		return false
	# One brick, the block laid: the ground's bond keeps it whole -- drawn,
	# broken and falling as one (Docs/TerrainBond.md 1).
	BrickTerrain.mark_placed(c[0], c[1], int(d.material))
	inv.consume_hand(ceili(int(res.changed) / 3.0))
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
		inv.pick(&"chest")
		return
	inv.pick(ItemCatalog.block_item(int(target.material)))


## The chest item's RMB: a chest standing on the face looked at -- its x and z
## on the 2-stud lattice, its bottom the plate past the face (MineChests).
func _place_chest() -> bool:
	var cell: Vector3i = target.cell + Vector3i(target.normal)
	var blk := MineChests.block_of(cell)
	if _box_hits_player(host.chests.box_of(blk)) or not host.chests.place(blk):
		return false
	inv.consume_hand(1)
	placed += 1
	log_blocks.append("place chest %s" % MineChests.key_of(blk))
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
	var s := block_studs()
	var what := ItemCatalog.label(inv.hand())
	if hand_kind() == "block":
		what += "  -  block %dx%d studs, 1 brick" % [s, s]
	_hud.caption = "%s%s   (B guns  X bar, hold: off-hand  Z size  MMB pick)" % [
			what, "" if inv.creative else "  [survival]"]
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
