class_name MineHands
extends Node3D
## What is in the player's hands in the mine world (Docs/Inventory.md 10):
## the selected hotbar slot, whatever it holds. A gun item goes into the
## GunController and the view (the arsenal's way of showing one, without
## the arsenal: the mine world asks PlayerKit for none); anything else puts
## the gun away and lets the builder act (MineBuilder.set_active).
##
## A gun item's stack `data` is the gun itself -- CharacterSave.gun_entry
## (class, seed, tier, rarity, parts) plus `name` and `ammo` -- so it is made
## again exactly from a save, a chest or the ground. Made once while carried
## (`_made`, under a hidden holster); its rounds go back into the stack when
## it is put away and before a save (`sync_ammo`).
##
## The OFF-HAND (Docs/Inventory.md round four): a one-handed gun in the
## active off-hand slot, with the off-hand up (Inventory.offhand), is made the
## same way into its own GunController (`off_gun`) and drawn low on the left
## of the view (`_off_view`), the left arm's C round its grip
## (PlayerView.off_held). RMB is its trigger; it reloads
## by itself when empty, and with R. While anything is in the off-hand, up,
## the main gun's sights rest (PlayerController.hold_aim): RMB is that hand's.
##
## A SHIELD in the off-hand, up: drawn low on the left, held by the left arm;
## RMB held raises it (`blocking`). Raised, it is the pawn's HealthPool.guard:
## a hit from in front (within BLOCK_CONE of the view) is blocked whole and
## wears the shield by its damage (`data.wear`); worn to its `durability` it
## breaks and is gone. Hits from the side or behind land as ever.
##
## The city and the planets keep the arsenal: nothing here is theirs.

var host: Node = null
var inv: Inventory = null
var gun: GunController = null
var view: PlayerView = null
var library: GunPartLibrary = null
var builder: Node = null

## The stack whose gun is in the hands, or null.
var held: ItemStack = null
## The off-hand's gun and the stack it is (round four), or null.
var off_gun: GunController = null
var off_held: ItemStack = null
var _off_view: Node3D
var _off_kick := 0.0
## RMB down, from its events (Input's polled state may lag a synthesised one).
var _rmb_down := false
## The shield in the off-hand in use, its model, and whether it is raised.
var shield_held: ItemStack = null
var blocking := false
## Hits blocked since the world started (the gate reads it).
var blocked_hits := 0
var _shield_view: Node3D
var _shield_node: Node3D
var _raise := 0.0
## A hit is blocked when it comes from within this many degrees of the view.
const BLOCK_CONE := 60.0
## The shield's place, lowered and raised (camera frame), its size, and the
## time it takes to come up.
const SHIELD_LOW := Vector3(-0.21, -0.17, -0.36)
const SHIELD_UP := Vector3(-0.13, -0.1, -0.33)
const SHIELD_SIZE := 0.22
const SHIELD_RAISE := 0.12
## Walking with the shield raised: this share of the speed (Minecraft's
## sneak-slow block).
const BLOCK_WALK := 0.45
## The pawn's move_mult before the shield went up, or -1 while it is down.
var _walk_base := -1.0
var _block_snd: AudioStreamPlayer
## Where the off-hand gun is drawn, in the camera's frame, and how long.
const OFF_POS := Vector3(-0.13, -0.065, -0.3)
const OFF_LENGTH := 0.26
## ItemStack -> GunInstance, the guns made for stacks still carried.
var _made := {}
var _holster: Node3D


func setup(p_host: Node, p_gun: GunController, p_view: PlayerView, p_library: GunPartLibrary,
		p_builder: Node) -> void:
	host = p_host
	gun = p_gun
	view = p_view
	library = p_library
	builder = p_builder
	_holster = Node3D.new()
	_holster.name = "Holster"
	_holster.visible = false
	add_child(_holster)
	off_gun = GunController.new()
	off_gun.name = "OffGun"
	off_gun.rng = RandomNumberGenerator.new()
	off_gun.rng.seed = 0x0FF0
	off_gun.aim = gun.aim
	off_gun.exclude = gun.exclude
	off_gun.on_structure_hit = gun.on_structure_hit
	add_child(off_gun)
	off_gun.fired.connect(func(info: Dictionary) -> void:
		_off_kick = 1.0
		var kit: PlayerKit = host.get("kit")
		if kit != null and kit.feedback != null:
			kit.feedback.on_player_shot(info))
	_off_view = Node3D.new()
	_off_view.name = "OffHandView"
	if view != null and view.camera != null:
		view.camera.add_child(_off_view)
	else:
		add_child(_off_view)
	_off_view.position = OFF_POS
	_shield_view = Node3D.new()
	_shield_view.name = "ShieldView"
	_shield_view.visible = false
	if view != null and view.camera != null:
		view.camera.add_child(_shield_view)
	else:
		add_child(_shield_view)


func set_inventory(p_inv: Inventory) -> void:
	if inv != null:
		if inv.changed.is_connected(refresh):
			inv.changed.disconnect(refresh)
		if inv.active_changed.is_connected(refresh):
			inv.active_changed.disconnect(refresh)
	inv = p_inv
	inv.changed.connect(refresh)
	inv.active_changed.connect(refresh)
	refresh()


static func is_gun(s: ItemStack) -> bool:
	return s != null and ItemCatalog.kind(s.id) == "gun"


## A gun as an item: its entry, its name, the rounds in it.
static func stack_of(g: GunInstance, ammo := -1) -> ItemStack:
	var d := CharacterSave.gun_entry(g)
	d["name"] = g.gun_name
	if ammo >= 0:
		d["ammo"] = ammo
	return ItemStack.make(ItemCatalog.gun_id(StringName(d.get("class", "pistol"))), 1, d)


## The hands follow the selected slot (and the off-hand its own).
func refresh() -> void:
	if inv == null or gun == null:
		return
	# The off-hand's gun let go first, if it is not wanted there any more: a
	# stack moving to the main hand must not be held by both.
	if off_held != null and off_held != _wanted_off():
		_release_off()
	_refresh_main()
	_refresh_off()


func _wanted_off() -> ItemStack:
	var o := inv.offhand()
	return o if is_gun(o) and o != inv.main_hand() else null


func _release_off() -> void:
	if off_held != null and off_gun.gun != null and is_instance_valid(off_gun.gun):
		off_held.data["ammo"] = off_gun.ammo
		var old := off_gun.gun
		off_gun.set_trigger(false)
		off_gun.equip(null)
		if old.get_parent() == _off_view:
			old.reparent(_holster, false)
	off_held = null
	if view != null:
		view.off_held = null


func _refresh_main() -> void:
	var h := inv.main_hand()
	var want_gun := is_gun(h)
	if want_gun and h == held and gun.gun != null:
		return
	if not want_gun and held == null:
		if builder != null and not builder.active:
			builder.set_active(true)
		return
	# Put away what is held.
	if held != null and gun.gun != null and is_instance_valid(gun.gun):
		held.data["ammo"] = gun.ammo
		var old := gun.gun
		gun.set_trigger(false)
		gun.equip(null)
		if view != null:
			view.put_away(old, _holster)
		else:
			old.reparent(_holster, false)
	held = null
	if want_gun:
		var g := _gun_for(h)
		if g != null:
			gun.equip(g)
			if h.data.has("ammo"):
				gun.ammo = mini(int(h.data.ammo), gun.mag_size())
			if view != null:
				view.hold(g)
			held = h
	if builder != null:
		builder.set_active(held == null)


## The off-hand's gun: the one in the off-hand in use, if it is a gun.
func _refresh_off() -> void:
	var want := _wanted_off()
	if want == off_held and (want == null or off_gun.gun != null):
		_prune()
		return
	_release_off()
	if want != null:
		var g := _gun_for(want)
		if g != null:
			off_gun.team = gun.team
			off_gun.exclude = gun.exclude
			off_gun.equip(g)
			off_gun.spread_mult = PlayerView.HIP_SPREAD
			if want.data.has("ammo"):
				off_gun.ammo = mini(int(want.data.ammo), off_gun.mag_size())
			g.reparent(_off_view, false)
			_fit_off(g)
			g.visible = true
			off_held = want
			# The left arm holds it (PlayerView.off_held).
			if view != null:
				view.off_held = g
	_prune()


## The off-hand gun sized and placed in its corner: OFF_LENGTH long, its
## back end at the view node; where the left hand takes it (`view_holds`).
func _fit_off(gi: GunInstance) -> void:
	gi.transform = Transform3D.IDENTITY
	var inv_xf := gi.global_transform.affine_inverse()
	var box := AABB()
	var first := true
	for n in gi.find_children("*", "VisualInstance3D", true, false):
		var vi := n as VisualInstance3D
		var bb: AABB = (inv_xf * vi.global_transform) * vi.get_aabb()
		box = bb if first else box.merge(bb)
		first = false
	if first or box.size.z < 0.01:
		return
	var sc := OFF_LENGTH / box.size.z
	if view != null:
		gi.set_meta(&"view_holds", view.holds_for(gi, inv_xf, box))
	gi.scale = Vector3.ONE * sc
	gi.position = -Vector3(box.get_center().x, box.end.y, box.end.z) * sc


func _process(delta: float) -> void:
	if inv == null or off_gun == null:
		return
	var player: PlayerController = host.get("player")
	if player != null:
		player.hold_aim = inv.offhand() != null
	var down := false
	if off_held != null and off_gun.gun != null:
		var free: bool = host.get("_menu") == null and not host.inventory_open()
		var captured := Input.mouse_mode == Input.MOUSE_MODE_CAPTURED or PlayerCamera.hands_off
		down = free and captured and (_rmb_down or Input.is_mouse_button_pressed(MOUSE_BUTTON_RIGHT))
		if off_gun.ammo <= 0 and not off_gun.is_reloading():
			off_gun.reload()
	off_gun.set_trigger(down)
	_step_shield(delta)
	# A kick back and up on each round, settling.
	_off_kick = maxf(_off_kick - delta * 9.0, 0.0)
	if _off_view != null:
		_off_view.position = OFF_POS + Vector3(0, 0.012, 0.035) * _off_kick
		_off_view.rotation = Vector3(0.18 * _off_kick, 0, 0)
		_off_view.visible = off_held != null


## The shield in the off-hand: its model, raised while RMB is held, and the
## pawn's guard while it is.
func _step_shield(delta: float) -> void:
	var o := inv.offhand()
	var sh := o if o != null and ItemCatalog.kind(o.id) == "shield" else null
	if sh != shield_held:
		if _shield_node != null:
			_shield_node.queue_free()
			_shield_node = null
		shield_held = sh
		if sh != null:
			_shield_node = ItemIcons.make_shield(ItemCatalog.get_def(sh.id).colour)
			_shield_node.scale = Vector3.ONE * SHIELD_SIZE
			_shield_node.set_meta(&"view_holds", {"grip": ItemIcons.SHIELD_GRIP})
			_shield_view.add_child(_shield_node)
	var free: bool = host.get("_menu") == null and not host.inventory_open()
	var captured := Input.mouse_mode == Input.MOUSE_MODE_CAPTURED or PlayerCamera.hands_off
	blocking = sh != null and free and captured \
			and (_rmb_down or Input.is_mouse_button_pressed(MOUSE_BUTTON_RIGHT))
	_raise = move_toward(_raise, 1.0 if blocking else 0.0, delta / SHIELD_RAISE)
	var k := _raise * _raise * (3.0 - 2.0 * _raise)
	_shield_view.visible = sh != null
	_shield_view.position = SHIELD_LOW.lerp(SHIELD_UP, k)
	# Lowered, turned edge-on a little and tipped back; raised, square to the view.
	_shield_view.rotation = Vector3(lerpf(-0.35, 0.0, k), lerpf(0.55, 0.1, k), 0.0)
	if view != null:
		if sh != null:
			view.off_held = _shield_node
		elif view.off_held == _shield_node or (view.off_held != null and not is_instance_valid(view.off_held)):
			view.off_held = null
	var pawn: Pawn = host.get("pawn")
	if pawn != null and pawn.health != null:
		var want := Callable(self, "guard") if blocking else Callable()
		if pawn.health.guard != want:
			pawn.health.guard = want
	# Slower while it is up; back to what it was once it is down.
	if pawn != null:
		if blocking and _walk_base < 0.0:
			_walk_base = pawn.move_mult
			pawn.move_mult = _walk_base * BLOCK_WALK
		elif not blocking and _walk_base >= 0.0:
			pawn.move_mult = _walk_base
			_walk_base = -1.0


## HealthPool.guard while the shield is raised: a hit from in front is
## blocked (0 gets through) and wears the shield; else it lands whole (1).
## Where it came from: its source (a shooter, a thrower) if that is not the
## player, else its point.
func guard(packet: DamagePacket) -> float:
	if shield_held == null or not blocking or packet == null:
		return 1.0
	var pawn: Pawn = host.get("pawn")
	var cam: Node3D = gun.aim if gun != null else null
	if pawn == null or cam == null:
		return 1.0
	var from := Vector3.INF
	var src := packet.source as Node3D
	if src != null and is_instance_valid(src) and src != pawn and not pawn.is_ancestor_of(src):
		from = src.global_position
	elif packet.hit_position != Vector3.ZERO:
		from = packet.hit_position
	if from == Vector3.INF:
		return 1.0
	var to := from - cam.global_position
	if to.length() < 0.01:
		return 1.0
	var fwd := -cam.global_transform.basis.z
	if to.normalized().dot(fwd) < cos(deg_to_rad(BLOCK_CONE)):
		return 1.0
	blocked_hits += 1
	_wear_shield(maxi(1, ceili(packet.amount)))
	_play_block()
	return 0.0


## The thud of a blocked hit: a low knock, made once (CombatFeedback's tones).
func _play_block() -> void:
	if _block_snd == null:
		_block_snd = AudioStreamPlayer.new()
		_block_snd.name = "BlockSound"
		_block_snd.stream = CombatFeedback._tone([330.0, 165.0, 98.0], 0.12, 28.0, 0.55)
		_block_snd.bus = &"Master"
		add_child(_block_snd)
	_block_snd.play()


## `n` more wear on the shield; worn out, it breaks (gone from the off-hand).
func _wear_shield(n: int) -> void:
	var sh := shield_held
	if sh == null:
		return
	var wear := int(sh.data.get("wear", 0)) + n
	var cap := int(ItemCatalog.get_def(sh.id).get("durability", 336))
	if wear >= cap:
		for i in inv.offhands.size():
			if inv.offhands[i] == sh:
				inv.offhands[i] = null
		print("[hands] the shield broke")
		inv.changed.emit()
		return
	sh.data["wear"] = wear
	inv.changed.emit()


func _input(event: InputEvent) -> void:
	if event is InputEventMouseButton and (event as InputEventMouseButton).button_index == MOUSE_BUTTON_RIGHT:
		_rmb_down = event.pressed
	# R reloads the off-hand gun too (the main gun's reload is the pawn's).
	if off_held != null and event is InputEventKey and event.pressed and not event.echo \
			and (event as InputEventKey).keycode == KEY_R:
		off_gun.reload()


func _gun_for(s: ItemStack) -> GunInstance:
	var g = _made.get(s)
	if g != null and is_instance_valid(g):
		return g
	if library == null:
		return null
	var made := CharacterSave.make_gun(s.data, library)
	if made == null:
		return null
	_holster.add_child(made)
	_made[s] = made
	return made


## Guns made for stacks no longer carried (dropped, put in a chest): freed.
func _prune() -> void:
	if inv == null:
		return
	var carried := {}
	for a in inv.all_addrs():
		var s := inv.get_slot(a)
		if s != null:
			carried[s] = true
	if inv.cursor != null:
		carried[inv.cursor] = true
	for s in _made.keys():
		if not carried.has(s) and s != held and s != off_held:
			var g = _made[s]
			_made.erase(s)
			if g != null and is_instance_valid(g) and g != gun.gun and g != off_gun.gun:
				(g as Node).queue_free()


## The rounds in the held gun into its stack (before a save).
func sync_ammo() -> void:
	if held != null and gun != null and gun.gun != null:
		held.data["ammo"] = gun.ammo
	if off_held != null and off_gun != null and off_gun.gun != null:
		off_held.data["ammo"] = off_gun.ammo


## No gun anywhere in the inventory: the character's kit guns
## (CharacterSave.loadout), else a rifle and a pistol rolled from the
## character's seed, into the first free hotbar slots (or storage). True if
## any were given.
func ensure_guns(p_inv: Inventory, loadout: Dictionary) -> bool:
	for a in p_inv.all_addrs():
		if is_gun(p_inv.get_slot(a)):
			return false
	var entries: Array = []
	for key in ["slots", "backpack"]:
		var arr = loadout.get(key, [])
		if arr is Array:
			for e in arr:
				if e is Dictionary and e.has("class") and WeaponClass.gun_ids().has(StringName(str(e["class"]))):
					entries.append(e)
	var stacks: Array = []
	for e in entries.slice(0, 4):
		var g := CharacterSave.make_gun(e, library) if library != null else null
		if g != null:
			stacks.append(stack_of(g))
			g.free()
	if stacks.is_empty() and library != null:
		var rng := RandomNumberGenerator.new()
		rng.seed = 0x1007
		for cid in [&"rifle", &"pistol"]:
			var gen_seed := rng.randi()
			var res := GunGenerator.generate(library, gen_seed, WeaponClass.rolled(cid, gen_seed), 1)
			var g := GunInstance.from_result(res)
			stacks.append(stack_of(g))
			g.free()
	for s in stacks:
		var left := p_inv.add_item(s)
		if left != null:
			push_warning("[hands] no room for %s" % s.id)
	return not stacks.is_empty()
