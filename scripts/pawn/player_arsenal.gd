class_name PlayerArsenal
extends Node
## The player's guns in play (Docs/Weapons/COMBAT_DESIGN.md 7): the Loadout's rules
## put into the hands, the keys, the floor and the HUD.
##
##   Tab           tap: the other gun in the group (the swap starts on the press); held
##                 past HOLD_SWAP: the other group instead. The mouse wheel taps.
##   1-4           that slot. Carrying a floor gun: keep it in that slot.
##   5             the ordnance, and back
##   G             throw a grenade, gun up
##   R held        a floor gun in reach and in view: pick it up into the third hand.
##                 Carrying one and none in view: stow it in the backpack. Otherwise:
##                 the gun in hand into its alt-fire mode and back (7.2). (Tapped, R
##                 is still reload: the pawn does that; held, the reload its press
##                 started is called off.)
##   I             the backpack: arrows or wheel choose, 1-4 swap into that slot, Backspace
##                 drops, I closes
##
## One GunController fires whatever is in hand: a swap re-equips it, and each gun
## keeps its own magazine (`_ammo`). Guns not in hand wait, hidden, under `_holster`
## -- in the tree, so nothing is ever freed out of it.
##
## The keys are input actions (project.godot), so Options rebinds them. A key this
## handles is marked handled, so the scene's debug keys under it do not also fire.

signal changed

const HOLD_SWAP := 0.25
const HOLD_INTERACT := 0.35
## How far from the eye a floor gun can be picked up, and how near the crosshair.
const REACH := 2.6
const AIM_DEG := 28.0
const GRENADES_MAX := 3
## A stand-in until there are ammo pickups: one grenade back every this many seconds.
const GRENADE_RECHARGE := 20.0
const THROW_RANGE := 25.0
## A player's grenade at the middle of its blast, in melees of the fight's tier: enough
## for a light shielded enemy (1.5 + 1) caught square.
const GRENADE_MELEES := 2.5

var loadout := Loadout.new()
var player: PlayerController
var gun: GunController
var view: PlayerView
var services: AIServices
var library: GunPartLibrary
## Where dropped guns and grenades go.
var world_parent: Node3D
## The fight's tier: grenades are sized to it, and guns it rolls are of it.
var tier := 1
var grenades := GRENADES_MAX
## The floor gun the player would pick up now (in reach, near the crosshair), or null.
var target_pickup: WorldGunPickup
var inventory_open := false
var inventory_index := 0
## Short notes for the HUD ("Backpack full").
var note := ""
var _note_left := 0.0

var _holster: Node3D
var _ammo := {}
var _grenade_clock := 0.0
var _swap_held := -1.0
var _swap_grouped := false
var _pre_tap_hand := 0
var _reload_held := -1.0
var _reload_used := false
var _hud: ArsenalHud


func setup(p_player: PlayerController, p_gun: GunController, p_view: PlayerView,
		p_services: AIServices, p_library: GunPartLibrary, p_world: Node3D, p_tier: int) -> void:
	player = p_player
	gun = p_gun
	view = p_view
	services = p_services
	library = p_library
	world_parent = p_world
	tier = p_tier
	if _holster == null:
		_holster = Node3D.new()
		_holster.name = "Holster"
		_holster.visible = false
		add_child(_holster)
	if _hud == null:
		_hud = ArsenalHud.new()
		_hud.arsenal = self
		add_child(_hud)
	if gun != null and not gun.alt_refused.is_connected(_say):
		gun.alt_refused.connect(_say)


## The starting kit: whatever the controller already holds in slot 1, then a pistol,
## a shotgun and a sniper, and a rocket launcher for the ordnance, all of this tier.
func fill_default(rng: RandomNumberGenerator) -> void:
	if not loadout.all_guns().is_empty():
		return
	if gun.gun != null:
		_adopt(gun.gun)
		loadout.set_slot(0, gun.gun)
	else:
		loadout.set_slot(0, _roll(&"rifle", rng))
	var kit: Array[StringName] = [&"", &"pistol", &"shotgun", &"sniper"]
	for i in range(1, Loadout.SLOTS):
		loadout.set_slot(i, _roll(kit[i], rng))
	loadout.ordnance = _roll(&"rocket_launcher", rng)
	_show()


## Swap the gun in hand for `g` (the debug gun cycle). The old one is freed.
func replace_in_hand(g: GunInstance) -> void:
	var old := loadout.in_hand() as GunInstance
	_adopt(g)
	if loadout.third_hand != null:
		loadout.third_hand = g
	elif loadout.ordnance_up and loadout.ordnance != null:
		loadout.ordnance = g
	else:
		loadout.slots[loadout.active_slot()] = g
	_show()
	if old != null and old != g:
		_ammo.erase(old)
		old.queue_free()


func _roll(class_id: StringName, rng: RandomNumberGenerator) -> GunInstance:
	var res := GunGenerator.generate(library, rng.randi(), WeaponClass.builtin(class_id), tier)
	var g := GunInstance.from_result(res)
	_adopt(g)
	return g


## A gun this now holds: into the holster until it is drawn.
func _adopt(g: GunInstance) -> void:
	if g.get_parent() == null:
		_holster.add_child(g)
	elif g != gun.gun:
		g.reparent(_holster, false)


func _active() -> bool:
	return player != null and player.is_possessing() and player._active()


# --- input --------------------------------------------------------------------------

func _unhandled_input(event: InputEvent) -> void:
	if not _active() or event.is_echo():
		return
	if inventory_open:
		_inventory_input(event)
		return
	var handled := true
	if _pressed(event, &"swap_weapon"):
		_pre_tap_hand = int(loadout.hand[loadout.group])
		_apply(loadout.tap_swap())
		_swap_held = 0.0
		_swap_grouped = false
	elif _pressed(event, &"slot_1"):
		_apply(loadout.select(0))
	elif _pressed(event, &"slot_2"):
		_apply(loadout.select(1))
	elif _pressed(event, &"slot_3"):
		_apply(loadout.select(2))
	elif _pressed(event, &"slot_4"):
		_apply(loadout.select(3))
	elif _pressed(event, &"ordnance"):
		_apply(loadout.toggle_ordnance())
	elif _pressed(event, &"grenade"):
		throw_grenade()
	elif _pressed(event, &"inventory"):
		inventory_open = true
		inventory_index = clampi(inventory_index, 0, maxi(loadout.backpack.size() - 1, 0))
	else:
		handled = false
	if handled:
		get_viewport().set_input_as_handled()


## Up or down the backpack list: the arrow keys or the wheel (W and S still walk).
static func _step(event: InputEvent) -> int:
	if event is InputEventKey and event.pressed:
		if event.keycode == KEY_UP:
			return -1
		if event.keycode == KEY_DOWN:
			return 1
	if event is InputEventMouseButton and event.pressed:
		if event.button_index == MOUSE_BUTTON_WHEEL_UP:
			return -1
		if event.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			return 1
	return 0


static func _pressed(event: InputEvent, action: StringName) -> bool:
	return InputMap.has_action(action) and event.is_action_pressed(action)


func _inventory_input(event: InputEvent) -> void:
	var n := loadout.backpack.size()
	if _pressed(event, &"inventory"):
		inventory_open = false
	elif _step(event) != 0:
		inventory_index = clampi(inventory_index + _step(event), 0, maxi(n - 1, 0))
	elif event is InputEventKey and event.pressed and (event.keycode == KEY_BACKSPACE or event.keycode == KEY_DELETE):
		_apply(loadout.drop_from_backpack(inventory_index))
		inventory_index = clampi(inventory_index, 0, maxi(loadout.backpack.size() - 1, 0))
	else:
		for i in Loadout.SLOTS:
			if _pressed(event, StringName("slot_%d" % (i + 1))):
				loadout.equip_from_backpack(inventory_index, i)
				_show()
				break
	# Nothing under the backpack acts while it is open: not the debug keys, not a slot.
	get_viewport().set_input_as_handled()


func _process(delta: float) -> void:
	if _note_left > 0.0:
		_note_left -= delta
		if _note_left <= 0.0:
			note = ""
	if grenades < GRENADES_MAX:
		_grenade_clock += delta
		if _grenade_clock >= GRENADE_RECHARGE:
			_grenade_clock = 0.0
			grenades += 1
			changed.emit()
	if not _active():
		_swap_held = -1.0
		_reload_held = -1.0
		target_pickup = null
		return
	target_pickup = _find_pickup()
	# Hold swap: undo the tap the press made, and change group instead.
	if _swap_held >= 0.0:
		if not Input.is_action_pressed(&"swap_weapon"):
			_swap_held = -1.0
		else:
			_swap_held += delta
			if _swap_held >= HOLD_SWAP and not _swap_grouped:
				_swap_grouped = true
				loadout.hand[loadout.group] = _pre_tap_hand
				_apply(loadout.switch_group())
	# Hold reload: pick up, or stow.
	if InputMap.has_action(&"reload") and Input.is_action_pressed(&"reload") and not inventory_open:
		if _reload_held < 0.0:
			_reload_held = 0.0
			_reload_used = false
		_reload_held += delta
		if _reload_held >= HOLD_INTERACT and not _reload_used:
			_reload_used = true
			# The press reloaded; the hold meant something else.
			if gun.is_reloading() and gun.reload_elapsed() <= _reload_held + 0.05:
				gun.cancel_reload()
			interact()
	else:
		_reload_held = -1.0


## The hold-reload action: the floor gun in view into the third hand, else the one in
## the third hand into the backpack, else the gun in hand into its alt-fire mode and
## back (a gun with none ignores it).
func interact() -> void:
	if target_pickup != null:
		pick_up(target_pickup)
	elif loadout.third_hand != null:
		if loadout.stow():
			_show()
			_say("Stowed in the backpack")
		else:
			_say("Backpack full")
	elif gun.toggle_alt():
		changed.emit()


func pick_up(p: WorldGunPickup) -> void:
	if p == null or p.result == null:
		return
	var g := GunInstance.from_result(p.result)
	_adopt(g)
	p.queue_free()
	if target_pickup == p:
		target_pickup = null
	_apply(loadout.pick_up(g))


## The floor gun nearest the crosshair, in reach.
func _find_pickup() -> WorldGunPickup:
	var cam := get_viewport().get_camera_3d()
	if cam == null:
		return null
	var eye := cam.global_position
	var fwd := -cam.global_transform.basis.z
	var best: WorldGunPickup = null
	var best_dot := cos(deg_to_rad(AIM_DEG))
	for n in get_tree().get_nodes_in_group(WorldGunPickup.GROUP):
		var p := n as WorldGunPickup
		if p == null or not p.is_inside_tree() or p.is_queued_for_deletion():
			continue
		var at := p.global_position + Vector3.UP * 0.55
		var to := at - eye
		var d := to.length()
		if d > REACH or d < 0.01:
			continue
		var dot := to.normalized().dot(fwd)
		if dot > best_dot:
			best_dot = dot
			best = p
	return best


func throw_grenade() -> void:
	if grenades <= 0 or services == null or player == null or player.pawn == null:
		_say("No grenades")
		return
	var cam := get_viewport().get_camera_3d()
	var eye := cam.global_position
	var fwd := -cam.global_transform.basis.z
	var ex: Array[RID] = [player.pawn.body.get_rid()]
	var space := cam.get_world_3d().direct_space_state
	var hit := space.intersect_ray(PhysicsRayQueryParameters3D.create(eye, eye + fwd * THROW_RANGE,
			Layers.GUN_MASK, ex))
	var to: Vector3
	if not hit.is_empty():
		to = hit.position
	else:
		# Into the open: where the line comes down at its full range.
		var far := eye + fwd * THROW_RANGE
		var down := space.intersect_ray(PhysicsRayQueryParameters3D.create(far, far + Vector3.DOWN * 60.0,
				Layers.PAWN_MASK, ex))
		to = down.position if not down.is_empty() else far
	var g := Grenade.throw(services, player.pawn, eye + fwd * 0.5, to, world_parent)
	g.damage = CombatScale.melee(tier) * GRENADE_MELEES
	grenades -= 1
	if grenades == GRENADES_MAX - 1:
		_grenade_clock = 0.0
	changed.emit()


# --- the hands ----------------------------------------------------------------------

## Do what a Loadout operation asked: drop what it let go, then draw what is in hand.
func _apply(dropped: Array) -> void:
	for g in dropped:
		_drop(g as GunInstance)
	_show()
	for g in dropped:
		var gi := g as GunInstance
		if gi != null and gi != gun.gun:
			_ammo.erase(gi)
			gi.queue_free()


## A gun let go of: a pickup of it on the floor in front of the player.
func _drop(g: GunInstance) -> void:
	if g == null or g.result == null or world_parent == null or player == null or player.pawn == null:
		return
	var pawn := player.pawn
	var fwd := Vector3(-sin(pawn.intents.look_yaw), 0.0, -cos(pawn.intents.look_yaw))
	var p := WorldGunPickup.create(library, g.result)
	world_parent.add_child(p)
	p.global_position = pawn.feet() + fwd * 1.0


## Put what the loadout has in hand into the hands, if it is not there already.
func _show() -> void:
	var want := loadout.in_hand() as GunInstance
	if want == gun.gun:
		changed.emit()
		return
	var old := gun.gun
	if old != null and is_instance_valid(old):
		_ammo[old] = gun.ammo
		if loadout.all_guns().has(old):
			old.reparent(_holster, false)
	gun.set_trigger(false)
	gun.equip(want)
	if want != null:
		if _ammo.has(want):
			gun.ammo = int(_ammo[want])
		if view != null:
			view.hold(want)
		else:
			var cam := get_viewport().get_camera_3d()
			if want.get_parent() != cam:
				want.reparent(cam, false)
			want.position = Vector3(0.22, -0.2, -0.45)
		want.visible = true
	changed.emit()


func _say(s: String) -> void:
	note = s
	_note_left = 2.0


## Every gun freed (the scene is going).
func _exit_tree() -> void:
	for g in loadout.all_guns():
		if is_instance_valid(g) and (g as Node).get_parent() == null:
			(g as Node).free()


# --- the HUD ------------------------------------------------------------------------

class ArsenalHud extends CanvasLayer:
	var arsenal: PlayerArsenal
	var _draw_node: Control

	func _ready() -> void:
		layer = 4
		_draw_node = Control.new()
		_draw_node.set_anchors_preset(Control.PRESET_FULL_RECT)
		_draw_node.mouse_filter = Control.MOUSE_FILTER_IGNORE
		_draw_node.draw.connect(_draw_all)
		add_child(_draw_node)

	func _process(_delta: float) -> void:
		var on := arsenal != null and arsenal._active()
		_draw_node.visible = on
		if on:
			_draw_node.modulate.a = PlayerHud.opacity
			_draw_node.queue_redraw()

	func _colour(g: GunInstance) -> Color:
		if g == null:
			return Color(1, 1, 1, 0.3)
		return PlayerHud.RARITY_COLOURS[clampi(g.rarity - 1, 0, PlayerHud.RARITY_COLOURS.size() - 1)]

	func _label(g: GunInstance) -> String:
		if g == null:
			return "-"
		return "%s %s" % [g.gun_name, ("T%d" % g.tier)]

	func _draw_all() -> void:
		var c := _draw_node
		var font := ThemeDB.fallback_font
		var sz := c.size
		var lo := arsenal.loadout
		# The four slots, two rows by group, over the ammo; the active group bright.
		var right := sz.x - 32.0
		var y := sz.y - 120.0
		for grp in [1, 0]:
			var row_y: float = y - (0.0 if grp == 0 else 22.0)
			var x := right
			for k in [1, 0]:
				var slot: int = grp * 2 + k
				var g := lo.slots[slot] as GunInstance
				var held: bool = lo.in_hand() == g and g != null
				var txt := "%d %s" % [slot + 1, _label(g)]
				var w := font.get_string_size(txt, HORIZONTAL_ALIGNMENT_LEFT, -1, 14).x
				x -= w
				var col := _colour(g)
				col.a = 1.0 if grp == lo.group else 0.45
				if held:
					c.draw_rect(Rect2(x - 4.0, row_y - 15.0, w + 8.0, 20.0), Color(1, 1, 1, 0.18))
				c.draw_string(font, Vector2(x, row_y), txt, HORIZONTAL_ALIGNMENT_LEFT, -1, 14, col)
				x -= 18.0
		var ord := lo.ordnance as GunInstance
		var ord_txt := "5 %s%s   G %s" % [_label(ord), "  (up)" if lo.ordnance_up else "",
				"●".repeat(arsenal.grenades) + "○".repeat(PlayerArsenal.GRENADES_MAX - arsenal.grenades)]
		var ow := font.get_string_size(ord_txt, HORIZONTAL_ALIGNMENT_LEFT, -1, 14).x
		c.draw_string(font, Vector2(right - ow, y - 44.0), ord_txt, HORIZONTAL_ALIGNMENT_LEFT, -1, 14,
				Color(1, 1, 1, 0.8))
		# Under the crosshair: what can be done with the floor.
		var mid := sz * 0.5
		var prompt := ""
		var pcol := Color(1, 1, 1, 0.9)
		if arsenal.target_pickup != null and arsenal.target_pickup.result != null:
			var r := arsenal.target_pickup.result
			prompt = "Hold R  pick up %s  (%s %s, tier %d)" % [r.gun_name,
					Rarity.NAMES[clampi(r.rarity - 1, 0, 5)],
					String(r.weapon_class.id) if r.weapon_class != null else "", r.tier]
			pcol = PlayerHud.RARITY_COLOURS[clampi(r.rarity - 1, 0, 5)]
		elif lo.third_hand != null:
			prompt = "Trying %s:  1-4 keep in that slot  ·  hold R stow  ·  Tab drop" % (lo.third_hand as GunInstance).gun_name
		if prompt != "":
			var pw := font.get_string_size(prompt, HORIZONTAL_ALIGNMENT_LEFT, -1, 16).x
			c.draw_string(font, Vector2(mid.x - pw * 0.5, mid.y + 70.0), prompt,
					HORIZONTAL_ALIGNMENT_LEFT, -1, 16, pcol)
		_alt(font, sz, right, y - 66.0)
		if arsenal.note != "":
			var nw := font.get_string_size(arsenal.note, HORIZONTAL_ALIGNMENT_LEFT, -1, 16).x
			c.draw_string(font, Vector2(mid.x - nw * 0.5, mid.y + 94.0), arsenal.note,
					HORIZONTAL_ALIGNMENT_LEFT, -1, 16, Color(1.0, 0.85, 0.4))
		if arsenal.inventory_open:
			_backpack(font, sz)

	## The alt-fire (COMBAT_DESIGN 7.2): its mode over the slots, its charge under the
	## crosshair, and the dart's mark where it is in the world.
	func _alt(font: Font, sz: Vector2, right: float, y: float) -> void:
		var c := _draw_node
		var gc := arsenal.gun
		var id := gc.alt_fire()
		if id == &"":
			return
		var cyan := Color(0.3, 1.0, 0.85)
		var txt := ""
		var col := Color(1, 1, 1, 0.5)
		if gc.alt_on():
			txt = "ALT  %s" % GunAltFire.display_name(id)
			col = cyan
		else:
			txt = "hold R: %s" % GunAltFire.display_name(id)
		if gc.alt_cooldown_left() > 0.0 and id == GunAltFire.ARC:
			txt += "  %.1fs" % gc.alt_cooldown_left()
		elif id == GunAltFire.CHARGE:
			txt += "  (%d rounds)" % gc.charge_cost()
		var w := font.get_string_size(txt, HORIZONTAL_ALIGNMENT_LEFT, -1, 14).x
		c.draw_string(font, Vector2(right - w, y), txt, HORIZONTAL_ALIGNMENT_LEFT, -1, 14, col)
		var mid := sz * 0.5
		var k := gc.alt_charge_progress()
		if gc.alt_on() and k > 0.0:
			var bw := 90.0
			c.draw_rect(Rect2(mid.x - bw * 0.5, mid.y + 30.0, bw, 5.0), Color(1, 1, 1, 0.25))
			c.draw_rect(Rect2(mid.x - bw * 0.5, mid.y + 30.0, bw * k, 5.0),
					cyan if k >= 1.0 else Color(1, 1, 1, 0.85))
		if gc.has_mark():
			var cam := c.get_viewport().get_camera_3d()
			var at := gc.mark_point()
			if cam != null and not cam.is_position_behind(at):
				var s := cam.unproject_position(at)
				var r := 11.0
				var pts := PackedVector2Array([s + Vector2(0, -r), s + Vector2(r, 0),
						s + Vector2(0, r), s + Vector2(-r, 0), s + Vector2(0, -r)])
				c.draw_polyline(pts, cyan, 2.0)
				var left := gc.mark_left() / GunController.MARK_SECONDS
				c.draw_rect(Rect2(s.x - r, s.y + r + 4.0, 2.0 * r * left, 3.0), cyan)

	func _backpack(font: Font, sz: Vector2) -> void:
		var c := _draw_node
		var lo := arsenal.loadout
		var w := 520.0
		var h := 70.0 + 22.0 * maxi(lo.backpack.size(), 1)
		var r := Rect2(sz.x * 0.5 - w * 0.5, sz.y * 0.5 - h * 0.5, w, h)
		c.draw_rect(r, Color(0.05, 0.06, 0.08, 0.85))
		var title := "BACKPACK  %d / %d" % [lo.backpack.size(), lo.backpack_size]
		c.draw_string(font, r.position + Vector2(16, 26), title, HORIZONTAL_ALIGNMENT_LEFT, -1, 16,
				Color(1, 1, 1))
		if lo.backpack.is_empty():
			c.draw_string(font, r.position + Vector2(16, 52), "empty", HORIZONTAL_ALIGNMENT_LEFT, -1, 14,
					Color(1, 1, 1, 0.5))
		for i in lo.backpack.size():
			var g := lo.backpack[i] as GunInstance
			var yy := r.position.y + 52.0 + 22.0 * i
			if i == arsenal.inventory_index:
				c.draw_rect(Rect2(r.position.x + 8, yy - 15, w - 16, 20), Color(1, 1, 1, 0.15))
			var txt := "%s   %s %s" % [_label(g), Rarity.NAMES[clampi(g.rarity - 1, 0, 5)],
					String(g.weapon_class.id) if g.weapon_class != null else ""]
			c.draw_string(font, Vector2(r.position.x + 16, yy), txt, HORIZONTAL_ALIGNMENT_LEFT, -1, 14,
					_colour(g))
		c.draw_string(font, Vector2(r.position.x + 16, r.end.y - 10),
				"Arrows/wheel choose  ·  1-4 swap into slot  ·  Backspace drop  ·  I close",
				HORIZONTAL_ALIGNMENT_LEFT, -1, 13, Color(1, 1, 1, 0.6))
