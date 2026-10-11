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
##                 A workbench in reach and in view (Workbench): the bench's page --
##                 arrows choose a gun, Enter infuses it to the story tier for scrap,
##                 Backspace twice breaks a backpack gun down for scrap (Infusion).
##                 Carrying one and none in view: stow it in the backpack. Otherwise:
##                 the gun in hand into its alt-fire mode and back (7.2). (Tapped, R
##                 is still reload: the pawn does that; held, the reload its press
##                 started is called off.)
##   I             the backpack: arrows or wheel choose, 1-4 swap into that slot, Backspace
##                 drops, I closes. Tab turns to the skill tree's page (SkillScreen) and back.
##
## The player's skills (SkillTree, through PlayerController.progress) are put into the
## hands here: `apply_skills`, on every change -- the guns, the legs, the body's health
## and the player's SHIELD (a layer over the health, PLAYER_SHIELD, that recharges after
## SHIELD_DELAY unhurt), the melee augments (the Brawler: Kinetic Lunge, Backstab on the
## pawn; Shield-Shatter Shockwave and Vampiric Impact here, on what a blow did), and the
## ability slot: Q fires the Overshield when the slot holds it (PlayerLevel.ability). A level up says so on the HUD, and the
## HUD's bar shows the XP.
##
## One GunController fires whatever is in hand: a swap re-equips it, and each gun
## keeps its own magazine (`_ammo`). Guns not in hand wait, hidden, under `_holster`
## -- in the tree, so nothing is ever freed out of it.
##
## The kit is kept between sessions (CharacterSave.loadout): `restore` makes it again,
## and `kit_changed` says when what is carried has changed -- a gun kept, stowed, dropped,
## broken down or infused -- for the scene to save.
##
## The keys are input actions (project.godot), so Options rebinds them. A key this
## handles is marked handled, so the scene's debug keys under it do not also fire.

signal changed
## What the kit holds changed (CharacterSave.loadout_dict differs): time to save it.
signal kit_changed

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
## What the skills make of GRENADES_MAX and GRENADE_RECHARGE (apply_skills).
var grenades_max := GRENADES_MAX
var grenade_recharge := GRENADE_RECHARGE
## The floor gun the player would pick up now (in reach, near the crosshair), or null.
var target_pickup: WorldGunPickup
## The workbench the player would use now, or null; the one in use while its page is up.
var target_bench: Workbench
var bench: Workbench
var bench_index := 0
var _salvage_armed := 0.0
var inventory_open := false
var inventory_index := 0
## The open screen's page: 0 the backpack, 1 the skill tree, 2 the workbench (only at one).
var inventory_page := 0
var skills: SkillScreen
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
## The kit as last seen (CharacterSave.loadout_dict), checked every KIT_CHECK seconds.
var _kit_seen := {}
var _kit_clock := 0.0
const KIT_CHECK := 2.0

## The player's shield (COMBAT_DESIGN 1.3): a layer over the health, the size of half
## of it, full again two seconds after it starts to recharge. The tree raises it
## (SkillTree.SHIELD_CAP) and shortens the wait.
const PLAYER_SHIELD := 50.0
const SHIELD_RATE := 25.0
const SHIELD_DELAY := 4.0
const SHIELD_COLOUR := Color(0.35, 0.8, 1.0)
## The Overshield ability: the shield's size doubled and filled, for OVERSHIELD_TIME;
## OVERSHIELD_COOLDOWN from its start to the next (faster with the tree's ability recharge).
const OVERSHIELD_MULT := 2.0
const OVERSHIELD_TIME := 8.0
const OVERSHIELD_COOLDOWN := 30.0
## Shield-Shatter Shockwave: its reach, and the share of each enemy's shield it strips.
const SHOCKWAVE_RADIUS := 4.0
const SHOCKWAVE_STRIP := 0.25
## Vampiric Impact: the share of the shield a melee kill gives back.
const VAMPIRIC_SHIELD := 0.5
const BACKSTAB_MULT := 2.5
const LUNGE_REACH := 1.5

var overshield_left := 0.0
var ability_cool := 0.0
var _melee_pawn: Pawn


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
	if skills == null:
		skills = SkillScreen.new()
		skills.name = "Skills"
		add_child(skills)
	if player != null:
		var pl := player.progress
		skills.progress = pl
		pl.reach_tier(tier)
		if gun != null:
			gun.set_meta(PlayerLevel.SOURCE_META, pl)
		if not pl.changed.is_connected(apply_skills):
			pl.changed.connect(apply_skills)
			pl.leveled_up.connect(_on_level_up)
	apply_skills()


## What the skill tree bought, into the hands, the legs and the body: the reload, the
## magazine, the alt-fire, the grenades, the move speed, and health with its regen.
## Placeholders (SkillTree): never a damage number.
func apply_skills() -> void:
	if player == null:
		return
	var t := player.progress.tree
	if gun != null:
		gun.reload_mult = 1.0 + t.total(&"reload_speed")
		gun.mag_mult = 1.0 + t.total(&"mag_size")
		gun.alt_mult = 1.0 + t.total(&"alt_speed")
		gun.ammo = mini(gun.ammo, gun.mag_size())
	grenades_max = GRENADES_MAX + int(t.total(&"grenade_max"))
	grenades = mini(grenades, grenades_max)
	grenade_recharge = GRENADE_RECHARGE / (1.0 + t.total(&"grenade_recharge"))
	var pawn := player.pawn
	if pawn != null and is_instance_valid(pawn):
		pawn.move_mult = 1.0 + t.total(&"move_speed")
		_apply_shield(pawn.health)
		apply_health(pawn.health, t.total(&"max_health"), t.total(&"health_regen"))
		pawn.melee_speed = 1.0 + t.total(&"melee_speed")
		pawn.melee_lunge = t.has(&"lunge")
		pawn.melee_reach = LUNGE_REACH if pawn.melee_lunge else 1.0
		pawn.melee_backstab = BACKSTAB_MULT if t.has(&"backstab") else 1.0
		if pawn.moves != null:
			pawn.moves.cooldown_speed = 1.0 + t.total(&"ability_cooldown")
		if _melee_pawn != pawn:
			if _melee_pawn != null and is_instance_valid(_melee_pawn) \
					and _melee_pawn.meleed.is_connected(_on_meleed):
				_melee_pawn.meleed.disconnect(_on_meleed)
			pawn.meleed.connect(_on_meleed)
			_melee_pawn = pawn
	changed.emit()


## The player's shield from the tree, onto `pool`, the Overshield's too while it holds.
func _apply_shield(pool: HealthPool) -> void:
	var t := player.progress.tree
	ensure_shield(pool, t.total(&"max_shield"), t.total(&"shield_delay"), t.total(&"shield_rate"),
			OVERSHIELD_MULT if overshield_left > 0.0 else 1.0)


## The player's shield layer on `pool`, put over its health the first time: PLAYER_SHIELD
## grown by `share`, its wait shortened by `delay_cut`, its recharge sped by `rate`, and
## `over` times its size while an Overshield holds. More shield bought is shield had at
## once; a smaller one keeps no more than fits. A shield that breaks lets half of what is
## left of the hit through (shield gating, COMBAT_DESIGN 4.5): the pool carries on.
static func ensure_shield(pool: HealthPool, share := 0.0, delay_cut := 0.0, rate := 0.0,
		over := 1.0) -> int:
	if pool == null:
		return -1
	var idx := shield_index(pool)
	if idx < 0:
		var cfg := DefenseLayer.new()
		cfg.layer_type = &"shield"
		cfg.display_color = SHIELD_COLOUR
		cfg.max_value = PLAYER_SHIELD
		pool.layer_configs.insert(0, cfg)
		pool._current.insert(0, PLAYER_SHIELD)
		pool._regen_timer.insert(0, 0.0)
		# The health stays the vital layer wherever it now sits.
		pool.impact_carries_over = true
		idx = 0
	var c := pool.layer_configs[idx]
	var was := c.max_value
	c.max_value = PLAYER_SHIELD * (1.0 + share) * over
	c.regen_rate = SHIELD_RATE * (1.0 + rate)
	c.regen_delay = SHIELD_DELAY * maxf(1.0 - delay_cut, 0.2)
	if idx < pool._current.size() and not pool.is_dead():
		pool._current[idx] = clampf(pool._current[idx] + maxf(c.max_value - was, 0.0), 0.0, c.max_value)
	return idx


## Where the shield layer is in `pool`, -1 for none. Changes nothing.
static func shield_index(pool: HealthPool) -> int:
	if pool == null:
		return -1
	for i in pool.layer_configs.size():
		if pool.layer_configs[i].layer_type == &"shield":
			return i
	return -1


## The ability slot (Q) fired: the Overshield, if that is what it holds and it is ready.
func use_ability() -> bool:
	if player == null or player.progress.ability() != &"overshield":
		return false
	if ability_cool > 0.0:
		_say("Overshield recharging: %d s" % ceili(ability_cool))
		return false
	overshield_left = OVERSHIELD_TIME
	ability_cool = OVERSHIELD_COOLDOWN / (1.0 + player.progress.tree.total(&"ability_cooldown"))
	var pawn := player.pawn
	if pawn != null and is_instance_valid(pawn) and pawn.health != null:
		_apply_shield(pawn.health)
		var idx := shield_index(pawn.health)
		pawn.health._current[idx] = pawn.health.layer_configs[idx].max_value
	_say("Overshield!")
	changed.emit()
	return true


func _overshield_over() -> void:
	overshield_left = 0.0
	var pawn := player.pawn if player != null else null
	if pawn != null and is_instance_valid(pawn) and pawn.health != null:
		_apply_shield(pawn.health)
		var idx := shield_index(pawn.health)
		pawn.health._current[idx] = minf(pawn.health._current[idx], pawn.health.layer_configs[idx].max_value)


## What a blow of the player's did, for the Brawler's nodes: a shield broken sends the
## Shockwave; a kill feeds Vampiric Impact.
func _on_meleed(info: Dictionary) -> void:
	if info.is_empty() or player == null:
		return
	var t := player.progress.tree
	if t.has(&"shockwave") and info.get("broke_shield", false):
		shockwave(info.point, info.get("target") as Node)
	var r = info.get("result")
	if t.has(&"vampiric") and r != null and r.killed:
		var pawn := player.pawn
		var idx := shield_index(pawn.health) if pawn != null else -1
		if idx >= 0:
			var c := pawn.health.layer_configs[idx]
			pawn.health._current[idx] = minf(pawn.health._current[idx] + c.max_value * VAMPIRIC_SHIELD,
					c.max_value)
		if gun != null and gun.gun != null:
			gun.ammo = gun.mag_size()
		changed.emit()


## Shield-Shatter Shockwave at `at`: every other enemy within SHOCKWAVE_RADIUS loses
## SHOCKWAVE_STRIP of its whole shield, if it has one up. Returns how many it reached.
func shockwave(at: Vector3, hit: Node = null) -> int:
	var world := world_parent.get_world_3d() if world_parent != null else null
	if world == null:
		return 0
	var team := player.pawn.team if player.pawn != null else 0
	var sphere := SphereShape3D.new()
	sphere.radius = SHOCKWAVE_RADIUS
	var q := PhysicsShapeQueryParameters3D.new()
	q.shape = sphere
	q.transform = Transform3D(Basis.IDENTITY, at)
	q.collision_mask = Layers.GUN_MASK
	var seen := {}
	var n := 0
	for r in world.direct_space_state.intersect_shape(q, 64):
		var target := GunController._living(r.collider)
		if target == null or target == hit or seen.has(target):
			continue
		seen[target] = true
		var pawn := target.get_node_or_null(^"Pawn") as Pawn
		if pawn != null and pawn.team == team:
			continue
		var pool := DamageSystem._find_health_pool(target)
		if pool == null or pool.top_layer_type() != &"shield":
			continue
		var i := pool._index_of_living_type(&"shield")
		pool.apply_to_layer_type(pool.layer_configs[i].max_value * SHOCKWAVE_STRIP, &"shield", &"")
		n += 1
	return n


## Health over its base by `share`, and `regen` a second after REGEN_DELAY unhurt. The
## base is kept on the layer the first time, so it never compounds (and a shield put
## over it later, which moves its index, changes nothing); more health bought is health
## had at once.
const REGEN_DELAY := 5.0
static func apply_health(pool: HealthPool, share: float, regen: float) -> void:
	if pool == null:
		return
	for i in pool.layer_configs.size():
		var cfg := pool.layer_configs[i]
		if cfg.layer_type != &"health":
			continue
		if not cfg.has_meta(&"skill_base"):
			cfg.set_meta(&"skill_base", [cfg.max_value, cfg.regen_rate, cfg.regen_delay])
		var base: Array = cfg.get_meta(&"skill_base")
		var was := cfg.max_value
		cfg.max_value = float(base[0]) * (1.0 + share)
		cfg.regen_rate = float(base[1]) + regen
		cfg.regen_delay = REGEN_DELAY if regen > 0.0 else float(base[2])
		if i < pool._current.size() and not pool.is_dead():
			pool._current[i] = clampf(pool._current[i] + maxf(cfg.max_value - was, 0.0), 0.0,
					cfg.max_value)


func _on_level_up(level: int) -> void:
	var free := player.progress.points_free()
	_say("Level %d!  %d skill point%s to spend (I, then Tab)" % [level, free, "" if free == 1 else "s"])


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


## The saved kit `d` (CharacterSave.loadout) made again, in place of an empty loadout;
## the gun the controller held, not part of it, is let go. False when there was no kit to
## make (nothing saved): the caller fills the starting kit then.
func restore(d: Dictionary) -> bool:
	if d.is_empty() or not loadout.all_guns().is_empty() or library == null:
		return false
	CharacterSave.fill_loadout(loadout, d, library)
	if loadout.all_guns().is_empty():
		return false
	for g in loadout.all_guns():
		_adopt(g)
	var old := gun.gun
	_show()
	if old != null and is_instance_valid(old) and not loadout.all_guns().has(old):
		old.queue_free()
	_kit_seen = CharacterSave.loadout_dict(loadout)
	return true


## The kit as a save keeps it.
func kit_dict() -> Dictionary:
	return CharacterSave.loadout_dict(loadout)


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
	elif _pressed(event, &"grapple") and player != null and player.progress.ability() != &"grapple":
		use_ability()
	elif _pressed(event, &"inventory"):
		inventory_open = true
		inventory_index = clampi(inventory_index, 0, maxi(loadout.backpack.size() - 1, 0))
		# Points to spend: open on the tree.
		if player != null and player.progress.points_free() > 0:
			inventory_page = 1
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
	elif _pressed(event, &"swap_weapon"):
		inventory_page = 1 if inventory_page == 0 else 0
	elif inventory_page == 1:
		if skills != null:
			skills.handle(event)
	elif inventory_page == 2:
		_bench_input(event)
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
	if skills != null:
		skills.show_screen(inventory_open and inventory_page == 1 and _active())
	if ability_cool > 0.0:
		ability_cool = maxf(ability_cool - delta, 0.0)
	if overshield_left > 0.0:
		overshield_left -= delta
		if overshield_left <= 0.0:
			_overshield_over()
	_kit_clock += delta
	if _kit_clock >= KIT_CHECK:
		_kit_clock = 0.0
		check_kit()
	if grenades < grenades_max:
		_grenade_clock += delta
		if _grenade_clock >= grenade_recharge:
			_grenade_clock = 0.0
			grenades += 1
			changed.emit()
	if not _active():
		_swap_held = -1.0
		_reload_held = -1.0
		target_pickup = null
		return
	target_pickup = _find_pickup()
	target_bench = _find_bench() if target_pickup == null else null
	_salvage_armed = maxf(_salvage_armed - delta, 0.0)
	# Walked away from the bench: its page closes.
	if inventory_open and inventory_page == 2 and (bench == null or not is_instance_valid(bench)
			or player.pawn == null or player.pawn.feet().distance_to(bench.global_position) > BENCH_LEAVE):
		inventory_open = false
		inventory_page = 0
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
	elif target_bench != null:
		open_bench(target_bench)
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
## `kit_changed`, if the kit is not what it was last time.
func check_kit() -> void:
	if loadout.all_guns().is_empty():
		return
	var now := kit_dict()
	if now != _kit_seen:
		_kit_seen = now
		kit_changed.emit()


# --- the workbench (COMBAT_DESIGN 1.2) -------------------------------------------------

const BENCH_REACH := 3.0
const BENCH_LEAVE := 4.0
const SALVAGE_WINDOW := 2.0


func _find_bench() -> Workbench:
	var cam := get_viewport().get_camera_3d()
	if cam == null:
		return null
	var eye := cam.global_position
	var fwd := -cam.global_transform.basis.z
	var best: Workbench = null
	var best_dot := cos(deg_to_rad(AIM_DEG + 10.0))
	for n in get_tree().get_nodes_in_group(Workbench.GROUP):
		var w := n as Workbench
		if w == null or not w.is_inside_tree():
			continue
		var to := w.use_point() - eye
		var d := to.length()
		if d > BENCH_REACH or d < 0.01:
			continue
		var dot := to.normalized().dot(fwd)
		if dot > best_dot:
			best_dot = dot
			best = w
	return best


## The bench's page, up: every gun the player holds, to infuse or break down.
func open_bench(w: Workbench) -> void:
	bench = w
	inventory_open = true
	inventory_page = 2
	bench_index = clampi(bench_index, 0, maxi(loadout.all_guns().size() - 1, 0))
	if player != null:
		player.progress.reach_tier(tier)


## Every gun at the bench, in the order its page lists them.
func bench_guns() -> Array:
	return loadout.all_guns()


## `g` to the player's story tier, for its scrap.
func infuse(g: GunInstance) -> bool:
	var pl := player.progress
	var why := Infusion.why_not(g, pl.story_tier, pl.scrap)
	if why != "":
		_say(why)
		return false
	var cost := Infusion.cost(g.rarity, g.tier, pl.story_tier)
	# The gun first, then the scrap: spending saves (PlayerLevel.changed), and the save
	# should hold the infused gun with the scrap it cost.
	Infusion.infuse(g, pl.story_tier)
	pl.spend_scrap(cost)
	_kit_seen = kit_dict()
	_say("%s infused to tier %d" % [g.gun_name, g.tier])
	changed.emit()
	return true


## The backpack's gun `g` broken down for scrap. Only from the backpack: a gun in a slot
## is one the player is using.
func salvage(g: GunInstance) -> bool:
	var i := loadout.backpack.find(g)
	if i < 0:
		_say("Only a backpack gun can be broken down")
		return false
	var got := Infusion.salvage_value(g.rarity, g.tier)
	loadout.backpack.remove_at(i)
	_ammo.erase(g)
	g.queue_free()
	player.progress.add_scrap(got)
	_say("Broken down: +%d scrap" % got)
	changed.emit()
	return true


func _bench_input(event: InputEvent) -> void:
	var guns := bench_guns()
	if _step(event) != 0:
		bench_index = clampi(bench_index + _step(event), 0, maxi(guns.size() - 1, 0))
		_salvage_armed = 0.0
	elif event is InputEventKey and event.pressed and not event.echo and bench_index < guns.size():
		var g := guns[bench_index] as GunInstance
		if event.keycode in [KEY_ENTER, KEY_KP_ENTER, KEY_SPACE]:
			infuse(g)
		elif event.keycode in [KEY_BACKSPACE, KEY_DELETE]:
			if loadout.backpack.find(g) < 0:
				_say("Only a backpack gun can be broken down")
			elif _salvage_armed > 0.0:
				_salvage_armed = 0.0
				salvage(g)
				bench_index = clampi(bench_index, 0, maxi(bench_guns().size() - 1, 0))
			else:
				_salvage_armed = SALVAGE_WINDOW
				_say("Backspace again: break it down for %d scrap"
						% Infusion.salvage_value(g.rarity, g.tier))


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
	if grenades == grenades_max - 1:
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
		_ability(font, sz)
		var ord := lo.ordnance as GunInstance
		var ord_txt := "5 %s%s   G %s" % [_label(ord), "  (up)" if lo.ordnance_up else "",
				"●".repeat(arsenal.grenades) + "○".repeat(maxi(arsenal.grenades_max - arsenal.grenades, 0))]
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
		elif arsenal.target_bench != null:
			prompt = "Hold R  workbench: infuse guns to tier %d, break guns down for scrap" \
					% maxi(arsenal.tier, arsenal.player.progress.story_tier if arsenal.player != null else 1)
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
		_level(font, sz)
		if arsenal.inventory_open and arsenal.inventory_page == 0:
			_backpack(font, sz)
		elif arsenal.inventory_open and arsenal.inventory_page == 2:
			_bench(font, sz)

	## The ability slot when it holds the Overshield, where PlayerHud draws the grapple's bar.
	func _ability(font: Font, sz: Vector2) -> void:
		var pl := arsenal.player.progress if arsenal.player != null else null
		if pl == null or pl.ability() != &"overshield":
			return
		var pawn := arsenal.player.pawn
		var bars := pawn.health.layer_count() if pawn != null and pawn.health != null else 1
		var x := 32.0
		var y := sz.y - 44.0 - 20.0 * bars - 6.0
		var full := PlayerArsenal.OVERSHIELD_COOLDOWN / (1.0 + pl.tree.total(&"ability_cooldown"))
		var f := 1.0 - arsenal.ability_cool / full
		var col := PlayerArsenal.SHIELD_COLOUR if arsenal.ability_cool <= 0.0 else Color(0.6, 0.6, 0.6, 0.7)
		var c := _draw_node
		c.draw_rect(Rect2(x - 2, y - 2, 104, 10), Color(0, 0, 0, 0.55))
		c.draw_rect(Rect2(x, y, 100.0 * clampf(f, 0.0, 1.0), 6), col)
		var txt := "Q OVERSHIELD"
		if arsenal.overshield_left > 0.0:
			txt += "  %.0f s" % ceilf(arsenal.overshield_left)
		c.draw_string(font, Vector2(x + 112.0, y + 8.0), txt, HORIZONTAL_ALIGNMENT_LEFT, -1, 13, col)

	## The workbench's page: every gun, its tier, what lifting it costs.
	func _bench(font: Font, sz: Vector2) -> void:
		var c := _draw_node
		var pl := arsenal.player.progress
		var guns := arsenal.bench_guns()
		var w := 640.0
		var h := 96.0 + 22.0 * maxi(guns.size(), 1)
		var r := Rect2(sz.x * 0.5 - w * 0.5, sz.y * 0.5 - h * 0.5, w, h)
		c.draw_rect(r, Color(0.06, 0.05, 0.04, 0.9))
		c.draw_string(font, r.position + Vector2(16, 26), "WORKBENCH   story tier %d" % pl.story_tier,
				HORIZONTAL_ALIGNMENT_LEFT, -1, 16, Color(1.0, 0.85, 0.55))
		var sc := "Scrap %d" % pl.scrap
		var sw := font.get_string_size(sc, HORIZONTAL_ALIGNMENT_LEFT, -1, 16).x
		c.draw_string(font, Vector2(r.end.x - 16 - sw, r.position.y + 26), sc, HORIZONTAL_ALIGNMENT_LEFT,
				-1, 16, Color(1.0, 0.85, 0.4))
		for i in guns.size():
			var g := guns[i] as GunInstance
			var yy := r.position.y + 54.0 + 22.0 * i
			if i == arsenal.bench_index:
				c.draw_rect(Rect2(r.position.x + 8, yy - 15, w - 16, 20), Color(1, 1, 1, 0.15))
			var where := "pack" if arsenal.loadout.backpack.has(g) else "kit"
			c.draw_string(font, Vector2(r.position.x + 16, yy), "%s  %s" % [where, _label(g)],
					HORIZONTAL_ALIGNMENT_LEFT, -1, 14, _colour(g))
			var right := ""
			var rc := Color(1, 1, 1, 0.5)
			if g.tier >= pl.story_tier:
				right = "on tier"
			else:
				var cost := Infusion.cost(g.rarity, g.tier, pl.story_tier)
				right = "T%d -> T%d   %d scrap" % [g.tier, pl.story_tier, cost]
				rc = Color(0.5, 1.0, 0.6) if cost <= pl.scrap else Color(1.0, 0.45, 0.4)
			var rw := font.get_string_size(right, HORIZONTAL_ALIGNMENT_LEFT, -1, 14).x
			c.draw_string(font, Vector2(r.end.x - 16 - rw, yy), right, HORIZONTAL_ALIGNMENT_LEFT, -1, 14, rc)
		c.draw_string(font, Vector2(r.position.x + 16, r.end.y - 30),
				"Infusing keeps the gun -- parts, modifiers, alt-fire, element, name -- and lifts its damage.",
				HORIZONTAL_ALIGNMENT_LEFT, -1, 12, Color(1, 1, 1, 0.55))
		c.draw_string(font, Vector2(r.position.x + 16, r.end.y - 10),
				"Arrows/wheel choose  ·  Enter infuse  ·  Backspace twice: break a pack gun down  ·  I close",
				HORIZONTAL_ALIGNMENT_LEFT, -1, 13, Color(1, 1, 1, 0.6))

	## The level and its XP, a thin bar at the bottom middle; the points waiting.
	func _level(font: Font, sz: Vector2) -> void:
		if arsenal.player == null:
			return
		var c := _draw_node
		var pl := arsenal.player.progress
		var need := PlayerLevel.xp_to_next(pl.level)
		var bw := 260.0
		var at := Vector2(sz.x * 0.5 - bw * 0.5, sz.y - 22.0)
		c.draw_rect(Rect2(at, Vector2(bw, 4.0)), Color(1, 1, 1, 0.18))
		if need > 0:
			c.draw_rect(Rect2(at, Vector2(bw * float(pl.xp) / need, 4.0)), Color(0.4, 0.85, 1.0, 0.9))
		var txt := "Lv %d" % pl.level
		var tw := font.get_string_size(txt, HORIZONTAL_ALIGNMENT_LEFT, -1, 13).x
		c.draw_string(font, Vector2(at.x - tw - 8.0, at.y + 6.0), txt, HORIZONTAL_ALIGNMENT_LEFT, -1, 13,
				Color(1, 1, 1, 0.8))
		var free := pl.points_free()
		if free > 0:
			c.draw_string(font, Vector2(at.x + bw + 8.0, at.y + 6.0), "+%d skill point%s  (I)" % [free,
					"" if free == 1 else "s"], HORIZONTAL_ALIGNMENT_LEFT, -1, 13, Color(1.0, 0.85, 0.4))

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
		if arsenal.player != null:
			title += "      Scrap %d" % arsenal.player.progress.scrap
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
				"Arrows/wheel choose  ·  1-4 swap into slot  ·  Backspace drop  ·  Tab skills  ·  I close",
				HORIZONTAL_ALIGNMENT_LEFT, -1, 13, Color(1, 1, 1, 0.6))
