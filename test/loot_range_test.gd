extends Node3D
## LOOT RANGE — the bed for the drop/score/naming pipeline.
##
## Controls:
##   WASD + mouse (hold RMB to look)  move / aim
##   LMB                              fire the equipped gun at a dummy
##   G                                spit out a random gun at the current tier
##   O                                spit out a random ORDNANCE
##   H                                spit out a random SHIELD
##   1 / 2 / 3                        toggle a weapon ability in that slot
##   B                                open the build menu (author any item by hand)
##   = / -                            enemy tier offset up / down (over-tier drops)
##   L                                force a random dedicated legendary
##   E                                equip the gun you are looking at
##   [ / ]                            tier down / up (1..10)
##   K                                kill the dummy you are looking at
##   C                                clear the floor
##
## Headless probe: `--headless -- --probe` runs the acceptance assertions and exits.
## Screenshot:     `-- --shot`.
##
## The bed owns ALL input (project convention): systems expose setters and never poll
## the keyboard, so a menu can withhold input without the system knowing.

const SHOT_FRAMES := 45
const PROBE_SAMPLES := 4000
const LOOK_RANGE := 40.0
const MOVE_SPEED := 7.0

## Same greybox for every archetype, scaled up the ladder so a boss reads as a boss at a
## glance. The bed is about loot triage, not combat feel. (BoomerBorder loaded a
## character model here; brickcity ships none that is not its own, so it is a capsule.)

const ARCH_LAYOUT: Array[Dictionary] = [
	{"id": &"trash",    "pos": Vector3(-9, 0, -10),   "scale": 0.85},
	{"id": &"standard", "pos": Vector3(-4.5, 0, -10), "scale": 1.00},
	{"id": &"heavy",    "pos": Vector3(0, 0, -10),    "scale": 1.30},
	{"id": &"badass",   "pos": Vector3(4.5, 0, -10),  "scale": 1.60},
	{"id": &"boss",     "pos": Vector3(9, 0, -10),    "scale": 2.00},
]

var library: GunPartLibrary
## There is no player level (PROGRESSION_SPEC §0.2). This is the zone tier, 1..10.
var player_tier: int = 1
## Enemy tier RELATIVE to the player's, so the over-tier drop rule (§4.5.3) can be
## exercised without hunting for a higher zone. Positive = enemies out-tier the player,
## which is the only path to a drop above your own tier.
var enemy_tier_offset: int = 0

var _cam: Camera3D
var _player: Node3D
var _card: GunCard
var _hud_level: Label
var _hud_equipped: Label
var _hud_log: Label
var _dummies: Array[LootDummy] = []
var _pickups: Array[WorldGunPickup] = []
var _equipped: GunGenerator.Result
var _looking_at: WorldGunPickup
## Abilities are a PLAYER property: they rewrite every gun's effect list on the fly and
## are never written back onto a stored weapon (AbilityLoadout).
var _abilities := AbilityLoadout.new()
var _hud_abilities: Label
var _builder: LootBuilderMenu

var _yaw := 0.0
var _pitch := -0.05
var _mouse_look := false
var _shot_mode := false
var _shot_countdown := SHOT_FRAMES
var _rng := RandomNumberGenerator.new()


func _ready() -> void:
	_rng.randomize()
	library = GunPlaceholderParts.build_library()

	if OS.get_cmdline_user_args().has("--probe"):
		_run_probe()
		return

	_build_world()
	_build_player()
	_build_hud()
	_build_dummies()

	_shot_mode = OS.get_cmdline_user_args().has("--shot")
	if _shot_mode:
		# Populate the floor and pre-select a card so the screenshot proves the UI,
		# not just an empty range. A headless run proves nothing about any of this.
		# One of each category, plus two abilities on, so the shot proves ordnance stats,
		# the ability grant/upgrade markers and a legendary all at once.
		_abilities.equip(&"ricochet")
		_abilities.equip(&"explosive")
		_spawn_gun()
		_spawn_ordnance()
		_spawn_shield()
		# A legendary last, and selected: the screenshot must prove the authored name,
		# the orange tier colour and the red flavour line, none of which headless sees.
		_spawn_legendary()
		_look_at_pickup(_pickups[_pickups.size() - 1])
		# Enemies one tier up and the builder open: the shot must prove the tier
		# override and the authoring menu, neither of which headless can see.
		_set_enemy_offset(1)
		_toggle_builder()


# --------------------------------------------------------------------------- world

func _build_world() -> void:
	var env := WorldEnvironment.new()
	var e := Environment.new()
	e.background_mode = Environment.BG_COLOR
	e.background_color = Color(0.07, 0.08, 0.10)
	e.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	e.ambient_light_color = Color(0.5, 0.52, 0.58)
	e.ambient_light_energy = 0.7
	env.environment = e
	add_child(env)

	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-52, -38, 0)
	sun.light_energy = 1.1
	sun.shadow_enabled = true
	add_child(sun)

	var floor_body := StaticBody3D.new()
	var mi := MeshInstance3D.new()
	var plane := PlaneMesh.new()
	plane.size = Vector2(60, 60)
	mi.mesh = plane
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.16, 0.17, 0.19)
	mat.roughness = 0.95
	mi.material_override = mat
	floor_body.add_child(mi)
	var col := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(60, 0.2, 60)
	col.shape = box
	col.position.y = -0.1
	floor_body.add_child(col)
	add_child(floor_body)


func _build_player() -> void:
	_player = Node3D.new()
	_player.name = "Player"
	_player.position = Vector3(0, 1.6, 2.0)
	add_child(_player)

	_cam = Camera3D.new()
	_cam.current = true
	_cam.fov = 72.0
	_player.add_child(_cam)
	_apply_look()


func _build_dummies() -> void:
	for entry in ARCH_LAYOUT:
		_make_dummy(entry["id"], entry["pos"], float(entry["scale"]))


func _make_dummy(archetype: StringName, pos: Vector3, model_scale: float) -> void:
	var d := LootDummy.new()
	d.name = "Dummy_%s" % archetype
	d.position = pos

	var model := Node3D.new()
	var body := MeshInstance3D.new()
	var capsule := CapsuleMesh.new()
	capsule.radius = 0.45
	capsule.height = 1.8
	body.mesh = capsule
	body.position = Vector3(0, 0.9, 0)
	model.add_child(body)
	d.add_child(model)
	var mesh := _find_mesh(model)
	model.scale = Vector3.ONE * model_scale

	var col := CollisionShape3D.new()
	var shape := CapsuleShape3D.new()
	shape.radius = 0.45
	shape.height = 1.8
	col.shape = shape
	col.position = Vector3(0, 0.9, 0)
	d.add_child(col)

	var pool := HealthPool.new()
	pool.name = "HealthPool"
	var layer := DefenseLayer.new()
	layer.layer_type = &"health"
	layer.max_value = LootRoller.enemy_hp(archetype, enemy_tier())
	layer.display_color = Color(0.9, 0.2, 0.2)
	pool.layer_configs = [layer]
	pool.vital_layer_index = -1
	d.add_child(pool)

	var sm := StatusManager.new()
	sm.name = "StatusManager"
	d.add_child(sm)

	var hp_label := Label3D.new()
	hp_label.position = Vector3(0, 2.2, 0)
	hp_label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	hp_label.no_depth_test = true
	hp_label.pixel_size = 0.005
	d.add_child(hp_label)

	var name_label := Label3D.new()
	name_label.position = Vector3(0, 2.55, 0)
	name_label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	name_label.no_depth_test = true
	name_label.pixel_size = 0.005
	name_label.modulate = Color(1.0, 0.85, 0.4)
	d.add_child(name_label)

	add_child(d)
	d.add_to_group(&"enemy")
	d.setup(pool, hp_label, mesh, model, false)
	d.setup_loot(archetype, enemy_tier(), name_label)
	d.dropped_loot.connect(_on_dropped_loot)
	_dummies.append(d)


# ----------------------------------------------------------------------------- HUD

func _build_hud() -> void:
	var layer := CanvasLayer.new()
	add_child(layer)

	var left := VBoxContainer.new()
	left.position = Vector2(16, 14)
	left.add_theme_constant_override(&"separation", 6)
	layer.add_child(left)

	_hud_level = _hud_label(left, 26)
	_hud_equipped = _hud_label(left, 14)

	var row := HBoxContainer.new()
	row.add_theme_constant_override(&"separation", 6)
	left.add_child(row)
	_button(row, "Tier +", _tier_up)
	_button(row, "Tier -", _tier_down)
	_button(row, "Spawn gun  [G]", _spawn_gun)
	_button(row, "Legendary  [L]", _spawn_legendary)
	_button(row, "Clear  [C]", _clear_floor)

	var row2 := HBoxContainer.new()
	row2.add_theme_constant_override(&"separation", 6)
	left.add_child(row2)
	_button(row2, "Ordnance  [O]", _spawn_ordnance)
	_button(row2, "Shield  [H]", _spawn_shield)
	_button(row2, "Enemy +", func(): _set_enemy_offset(enemy_tier_offset + 1))
	_button(row2, "Enemy -", func(): _set_enemy_offset(enemy_tier_offset - 1))
	_button(row2, "Build…  [B]", _toggle_builder)

	_hud_abilities = _hud_label(left, 13)
	_hud_abilities.modulate = Color(0.55, 0.85, 1.0)

	_hud_log = _hud_label(left, 12)
	_hud_log.modulate = Color(0.65, 0.65, 0.7)

	var help := _hud_label(left, 11)
	help.modulate = Color(0.5, 0.5, 0.55)
	help.text = "RMB look · WASD · LMB fire · E equip · K kill · [ ] tier · G gun · O ordnance · H shield · L legendary · 1-3 abilities"

	_builder = LootBuilderMenu.new()
	_builder.visible = false
	_builder.set_anchors_preset(Control.PRESET_TOP_RIGHT)
	_builder.offset_right = -16
	_builder.offset_top = 16
	_builder.offset_left = -330
	layer.add_child(_builder)
	_builder.setup(_abilities)
	_builder.build_requested.connect(_on_build_requested)
	_builder.ability_toggled.connect(_on_ability_toggled)

	_card = GunCard.new()
	_card.position = Vector2(16, 0)
	_card.visible = false
	layer.add_child(_card)
	# Anchor the card to the bottom-left once it has laid out.
	_card.set_anchors_preset(Control.PRESET_BOTTOM_LEFT)
	_card.offset_left = 16
	_card.offset_bottom = -16
	_card.offset_top = -320

	_refresh_hud()


func _hud_label(parent: Node, size: int) -> Label:
	var l := Label.new()
	l.add_theme_font_size_override(&"font_size", size)
	parent.add_child(l)
	return l


func _button(parent: Node, text: String, cb: Callable) -> void:
	var b := Button.new()
	b.text = text
	b.focus_mode = Control.FOCUS_NONE      # else the button eats WASD after a click
	b.pressed.connect(cb)
	parent.add_child(b)


func _refresh_hud() -> void:
	if _hud_abilities != null:
		var ids := AbilityLoadout.all_ids()
		var bits := PackedStringArray()
		for i in mini(AbilityLoadout.MAX_SLOTS, ids.size()):
			var a := AbilityLoadout.get_ability(ids[i])
			var on := _abilities.has(ids[i])
			bits.append("[%d]%s%s" % [i + 1, a.display_name, "*" if on else ""])
		_hud_abilities.text = "abilities  " + "  ".join(bits)
	if _hud_level != null:
		var et := enemy_tier()
		var luck := LootRoller.total_luck(et, player_tier, &"standard")
		_hud_level.text = "TIER %d / %d    enemies T%d (%+d)    luck x%.2f" % [
			player_tier, Tier.COUNT, et, enemy_tier_offset, luck]
	if _hud_equipped != null:
		if _equipped == null:
			_hud_equipped.text = "equipped: none — press G then E"
		else:
			_hud_equipped.text = "equipped: %s  (score %d)" % [
				_equipped.gun_name, _equipped.score,
			]


func _log(msg: String) -> void:
	if _hud_log != null:
		_hud_log.text = msg


# ------------------------------------------------------------------------- actions

func _tier_up() -> void:
	_set_tier(player_tier + 1)


func _tier_down() -> void:
	_set_tier(player_tier - 1)


## The tier enemies actually spawn at. Clamped into the real tier range, so a +3 offset
## at tier 10 does not invent a tier 13 the rest of the game has never heard of.
func enemy_tier() -> int:
	return clampi(player_tier + enemy_tier_offset, 1, Tier.COUNT)


func _set_enemy_offset(v: int) -> void:
	enemy_tier_offset = clampi(v, -3, LootRoller.MAX_OVERTIER)
	for d in _dummies:
		if is_instance_valid(d):
			d.set_tier(enemy_tier())
	_refresh_hud()
	_log("enemies now T%d (%+d vs player)" % [enemy_tier(), enemy_tier_offset])


func _set_tier(t: int) -> void:
	player_tier = clampi(t, 1, Tier.COUNT)
	for d in _dummies:
		if is_instance_valid(d):
			d.set_tier(enemy_tier())
	_refresh_hud()
	_log("tier %d — dummies rescaled (x%.0f power)" % [
		player_tier, Tier.power_mult(player_tier)])


## Guns always drop at the player's level here; the over-level path is exercised by the
## dummies, which can outlevel the player when the bed is driven from a probe.
## Spawns land in an arc IN FRONT of the player, never around them: a gun dropped at
## the player's feet fills the screen with a metre-wide placeholder box and hides the
## range behind it.
func _spawn_gun() -> void:
	# Roll a real rarity off the world table so the spawn button exercises the actual
	# drop odds rather than always handing back a Common.
	var luck := LootRoller.tier_luck(player_tier)
	var res := _generate(LootRoller.roll_rarity(_rng, luck), player_tier, luck)
	_place(res, _drop_spot(_player.global_position, -Basis(Vector3.UP, _yaw).z))
	_log("dropped %s (score %d)" % [res.gun_name, res.score])


## Debug shortcut only — the real path is killing a boss or badass. Bypassing the 12%
## roll here would hide a broken dedicated table, so this never touches LootRoller.
func _spawn_legendary() -> void:
	var ids := LegendaryTable.all_ids()
	var leg_id: StringName = ids[_rng.randi_range(0, ids.size() - 1)]
	var res := _generate_legendary(leg_id, player_tier, 1.0)
	_place(res, _drop_spot(_player.global_position, -Basis(Vector3.UP, _yaw).z))
	_log("FORCED %s (score %d)" % [res.gun_name, res.score])


func _drop_spot(origin: Vector3, forward: Vector3) -> Vector3:
	var fwd := Vector3(forward.x, 0.0, forward.z).normalized()
	if fwd.length_squared() < 0.01:
		fwd = Vector3.FORWARD
	var spread := _rng.randf_range(-0.7, 0.7)
	var dist := _rng.randf_range(4.0, 6.5)
	return origin + fwd.rotated(Vector3.UP, spread) * dist


func _generate(rarity: int, tier: int, luck: float) -> GunGenerator.Result:
	var wc := WeaponClass.builtin(_random_class())
	return GunGenerator.generate(library, _rng.randi(), wc, tier, rarity, luck)


## Ordnance is a normal weapon class with is_ordnance set, so it runs the identical
## generator, stat, score and grade path. Only the CLASS POOL differs.
func _spawn_ordnance() -> void:
	var luck := LootRoller.tier_luck(player_tier)
	var ids := WeaponClass.ORDNANCE_IDS
	var wc := WeaponClass.builtin(ids[_rng.randi_range(0, ids.size() - 1)])
	var res := GunGenerator.generate(library, _rng.randi(), wc, player_tier,
		LootRoller.roll_rarity(_rng, luck), luck)
	_place(res, _drop_spot(_player.global_position, -Basis(Vector3.UP, _yaw).z))
	_log("ORDNANCE %s (score %d, %.1fs cd)" % [
		res.gun_name, res.score, float(res.stats.get(&"cooldown", 0.0))])


func _spawn_shield() -> void:
	var luck := LootRoller.tier_luck(player_tier)
	var res := ShieldGenerator.generate(_rng.randi(),
		LootRoller.roll_rarity(_rng, luck), player_tier)
	_log("SHIELD %s (score %d, %d cap, %.1fs delay)" % [
		res.shield_name, res.score, GunQuality.display(res.stats[&"capacity"]),
		res.stats[&"recharge_delay"]])


func _toggle_builder() -> void:
	if _builder == null:
		return
	_builder.visible = not _builder.visible
	_builder.sync_abilities()


## Hand-authored item. Routes through the SAME generator the world uses — the menu picks
## the inputs, it never constructs an item by a side path.
func _on_build_requested(category: StringName, class_id: StringName,
		rarity: int, tier: int) -> void:
	if category == &"shield":
		var sh := ShieldGenerator.generate(_rng.randi(), rarity, tier, class_id)
		_log("BUILT %s (score %d, %d cap)" % [
			sh.shield_name, sh.score, GunQuality.display(sh.stats[&"capacity"])])
		return
	var wc := WeaponClass.builtin(class_id)
	var res := GunGenerator.generate(library, _rng.randi(), wc, tier, rarity, 1.0)
	_place(res, _drop_spot(_player.global_position, -Basis(Vector3.UP, _yaw).z))
	_log("BUILT %s (score %d)" % [res.gun_name, res.score])


func _on_ability_toggled(id: StringName) -> void:
	if _abilities.has(id):
		_abilities.unequip(id)
	else:
		_abilities.equip(id)
	_refresh_hud()
	_look_at_pickup(_looking_at)


func _toggle_ability(slot: int) -> void:
	var ids := AbilityLoadout.all_ids()
	if slot >= ids.size():
		return
	var id: StringName = ids[slot]
	if _abilities.has(id):
		_abilities.unequip(id)
		_log("ability OFF: %s" % id)
	elif not _abilities.equip(id):
		_log("ability slots full (%d)" % AbilityLoadout.MAX_SLOTS)
		return
	else:
		_log("ability ON: %s — applies to every gun you hold" % id)
	_refresh_hud()
	if _builder != null:
		_builder.sync_abilities()
	_look_at_pickup(_looking_at)   # re-render the card through the new loadout


func _generate_legendary(leg_id: StringName, tier: int, luck: float) -> GunGenerator.Result:
	return GunGenerator.generate_legendary(
		library, _rng.randi(), LegendaryTable.get_def(leg_id), tier, luck)


func _random_class() -> StringName:
	var ids := WeaponClass.gun_ids()
	return ids[_rng.randi_range(0, ids.size() - 1)]


func _place(res: GunGenerator.Result, at: Vector3) -> void:
	var p := WorldGunPickup.create(library, res)
	p.position = Vector3(at.x, 0.0, at.z)
	add_child(p)
	_pickups.append(p)


func _clear_floor() -> void:
	for p in _pickups:
		if is_instance_valid(p):
			p.queue_free()
	_pickups.clear()
	_looking_at = null
	if _card != null:
		_card.visible = false
	_log("floor cleared")


func _on_dropped_loot(archetype: StringName, enemy_tier: int, origin: Vector3) -> void:
	var drops := LootRoller.roll_drops(archetype, enemy_tier, player_tier, _rng)
	var names := PackedStringArray()
	for i in drops.size():
		var d := drops[i]
		var res := (_generate_legendary(d.legendary_id, d.tier, d.luck) if d.dedicated
			else _generate(d.rarity, d.tier, d.luck))
		var a := TAU * float(i) / float(maxi(drops.size(), 1))
		_place(res, origin + Vector3(sin(a) * 1.2, 0, cos(a) * 1.2))
		names.append("%s%s" % [res.gun_name, "  [DEDICATED]" if d.dedicated else ""])
	_log("%s dropped %d: %s" % [String(archetype).to_upper(), drops.size(), ", ".join(names)])


# --------------------------------------------------------------------------- input

func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		if mb.button_index == MOUSE_BUTTON_RIGHT:
			_mouse_look = mb.pressed
			Input.mouse_mode = (Input.MOUSE_MODE_CAPTURED if mb.pressed
				else Input.MOUSE_MODE_VISIBLE)
		elif mb.button_index == MOUSE_BUTTON_LEFT and mb.pressed:
			_fire()
	elif event is InputEventMouseMotion and _mouse_look:
		var mm := event as InputEventMouseMotion
		_yaw -= mm.relative.x * 0.0025
		_pitch = clampf(_pitch - mm.relative.y * 0.0025, -1.4, 1.4)
		_apply_look()
	elif event is InputEventKey and event.pressed and not event.echo:
		match (event as InputEventKey).keycode:
			KEY_G: _spawn_gun()
			KEY_O: _spawn_ordnance()
			KEY_H: _spawn_shield()
			KEY_L: _spawn_legendary()
			KEY_B: _toggle_builder()
			KEY_EQUAL: _set_enemy_offset(enemy_tier_offset + 1)
			KEY_MINUS: _set_enemy_offset(enemy_tier_offset - 1)
			KEY_1: _toggle_ability(0)
			KEY_2: _toggle_ability(1)
			KEY_3: _toggle_ability(2)
			KEY_C: _clear_floor()
			KEY_E: _equip_looked_at()
			KEY_K: _kill_looked_at()
			KEY_BRACKETRIGHT: _tier_up()
			KEY_BRACKETLEFT: _tier_down()


func _apply_look() -> void:
	if _player != null:
		_player.rotation = Vector3(0, _yaw, 0)
	if _cam != null:
		_cam.rotation = Vector3(_pitch, 0, 0)


func _process(delta: float) -> void:
	if _shot_mode:
		_shot_countdown -= 1
		if _shot_countdown <= 0:
			_take_shot()
		return
	_move(delta)
	_update_look_target()


func _move(delta: float) -> void:
	if _player == null:
		return
	# Raw key reads so the bed does not depend on project input actions existing.
	var dir := Vector3(
		float(Input.is_key_pressed(KEY_D)) - float(Input.is_key_pressed(KEY_A)),
		0.0,
		float(Input.is_key_pressed(KEY_S)) - float(Input.is_key_pressed(KEY_W)))
	if dir.length_squared() <= 0.0:
		return
	var basis := Basis(Vector3.UP, _yaw)
	_player.global_position += basis * dir.normalized() * MOVE_SPEED * delta


# ------------------------------------------------------------------- look / combat

func _ray() -> Dictionary:
	if _cam == null:
		return {}
	var from := _cam.global_position
	var to := from - _cam.global_transform.basis.z * LOOK_RANGE
	var q := PhysicsRayQueryParameters3D.create(from, to)
	q.collide_with_areas = false
	return get_world_3d().direct_space_state.intersect_ray(q)


## Nearest pickup to the aim ray. Pickups have no collider (they are cosmetic), so this
## is an angular test rather than a raycast — cheap, and it lets a player read a card
## without having to hit a small spinning model precisely.
func _update_look_target() -> void:
	if _cam == null:
		return
	var origin := _cam.global_position
	var fwd := -_cam.global_transform.basis.z
	var best: WorldGunPickup = null
	var best_dot := 0.985
	for p in _pickups:
		if not is_instance_valid(p):
			continue
		var to_p := (p.global_position + Vector3(0, 0.6, 0)) - origin
		if to_p.length() > 12.0:
			continue
		var d := fwd.dot(to_p.normalized())
		if d > best_dot:
			best_dot = d
			best = p
	_look_at_pickup(best)


func _look_at_pickup(p: WorldGunPickup) -> void:
	_looking_at = p
	if _card == null:
		return
	if p == null or p.result == null:
		_card.visible = false
		return
	_card.visible = true
	_card.show_gun(p.result, _equipped.score if _equipped != null else -1, _abilities)


func _equip_looked_at() -> void:
	if _looking_at == null or _looking_at.result == null:
		return
	_equipped = _looking_at.result
	_refresh_hud()
	_log("equipped %s" % _equipped.gun_name)


func _fire() -> void:
	if _equipped == null:
		_log("nothing equipped — look at a gun and press E")
		return
	var hit := _ray()
	if hit.is_empty():
		return
	var d := hit.get("collider") as LootDummy
	if d == null or d.pool == null or d.pool.is_dead():
		return
	var dmg := float(_equipped.stats.get(&"damage", 0.0))
	d.pool.apply_impact(dmg, &"kinetic")
	_log("hit %s for %d" % [String(d.archetype).to_upper(), GunQuality.display(dmg)])


func _kill_looked_at() -> void:
	var hit := _ray()
	var d := hit.get("collider") as LootDummy if not hit.is_empty() else null
	if d == null or d.pool == null or d.pool.is_dead():
		return
	d.pool.apply_impact(d.pool.total_current() * 2.0, &"kinetic")


# ------------------------------------------------------------- shot / headless probe

func _take_shot() -> void:
	var img := get_viewport().get_texture().get_image()
	var path := "user://loot_range.png"
	img.save_png(path)
	print("shot saved: ", ProjectSettings.globalize_path(path))
	get_tree().quit()


## Acceptance assertions (Gauntlet Step 0). Every number checked here is one this
## project's spec claims, so a spec edit that breaks the math fails the bed.
func _run_probe() -> void:
	var fails := 0

	# 1. THE TWO AUTHORED CALIBRATION POINTS. Tier.TIER_STEP and Rarity.MULTS were solved
	# from exactly these, so if either drifts the whole economy has moved:
	#     T1 Legendary == T3 Uncommon      (legendary is worth two tiers of uncommon)
	#     T1 Legendary >= T2 Unique        (legendary clears unique by a full tier)
	# 100 score = one tier, so a 10-point tolerance is a tenth of a tier.
	var pistol := WeaponClass.builtin(&"pistol")
	var t1_com := _mid_roll_score(pistol, 1, 1)
	var t2_com := _mid_roll_score(pistol, 2, 1)
	var t3_unc := _mid_roll_score(pistol, 3, 2)
	var t2_uni := _mid_roll_score(pistol, 2, 4)
	var t1_leg := _mid_roll_score(pistol, 1, 5)
	var t2_rare := _mid_roll_score(pistol, 2, 3)
	fails += _expect(absi(t1_leg - t3_unc) <= 10,
		"CALIBRATION: T1 Legendary (%d) must match T3 Uncommon (%d)" % [t1_leg, t3_unc])
	fails += _expect(t1_leg >= t2_uni - 4,
		"CALIBRATION: T1 Legendary (%d) must be >= T2 Unique (%d)" % [t1_leg, t2_uni])
	fails += _expect(absi((t2_com - t1_com) - 100) <= 10,
		"one tier should be ~100 score, measured %d" % (t2_com - t1_com))
	# Rare is the retuning anchor: worth exactly one tier, so a T1 Rare ties a T2 Common.
	var t1_rare := _mid_roll_score(pistol, 1, 3)
	fails += _expect(absi(t1_rare - t2_com) <= 10,
		"ANCHOR: T1 Rare (%d) must be worth exactly one tier vs T2 Common (%d)" % [
			t1_rare, t2_com])

	# 2. Tier luck must push rarity UP, not merely wobble it.
	var lo := _rarity_mean(1, &"trash")
	var hi := _rarity_mean(Tier.COUNT, &"trash")
	fails += _expect(hi > lo, "tier luck: T10 mean rarity %.3f !> T1 %.3f" % [hi, lo])

	# 3. Archetype must matter: a boss out-drops trash at the same tier.
	var trash := _rarity_mean(5, &"trash")
	var boss := _rarity_mean(5, &"boss")
	fails += _expect(boss > trash, "boss mean rarity %.3f !> trash %.3f" % [boss, trash])

	# 4. Grade words must stay RARE — the whole point of §2.2's rates.
	var graded := 0
	for i in PROBE_SAMPLES:
		var res := _generate(1, 1, 1.0)
		if res.grade_word != "":
			graded += 1
	var pct := 100.0 * float(graded) / float(PROBE_SAMPLES)
	fails += _expect(pct >= 12.0 and pct <= 30.0,
		"grade-word rate %.1f%% outside 12-30%% (spec target ~17%% at rarity 1)" % pct)

	# 5. Sign integrity: a gun whose parts are all at-or-above tier must NEVER read as
	# a negative grade. Added because the damage-roll nudge could flip a +1 sight into
	# "Used" — a MAJOR the first four checks all passed straight over.
	var inverted := 0
	for i in PROBE_SAMPLES:
		var res := _generate(_rng.randi_range(2, 5), _rng.randi_range(1, Tier.COUNT), 1.4)
		if GunQuality.raw_q(res.recipe, res.rarity) > 0.0 and _is_negative_word(res.grade_word):
			inverted += 1
	fails += _expect(inverted == 0,
		"%d guns with above-tier parts read as a NEGATIVE grade word" % inverted)

	# 5b. The clamp's other half: an off-tier part must ALWAYS produce a word, whatever
	# the damage roll does. Collapsing to zero instead was what dragged the rate to 10%.
	var swallowed := 0
	for i in PROBE_SAMPLES:
		var res := _generate(3, _rng.randi_range(1, Tier.COUNT), 1.4)
		if not is_zero_approx(GunQuality.raw_q(res.recipe, res.rarity)) and res.grade_word == "":
			swallowed += 1
	fails += _expect(swallowed == 0,
		"%d guns with off-tier parts were swallowed to NO grade word" % swallowed)

	# 6. Legendary parts must NEVER reach a world drop (QUALITY_NAMING §5). This is the
	# rule that keeps a legendary's identity its own.
	var leaked := 0
	for i in PROBE_SAMPLES:
		var res := _generate(_rng.randi_range(5, 6), 5, 3.5)
		for def: Variant in res.recipe.values():
			if def is GunPartDef and (def as GunPartDef).exclusive_to != &"":
				leaked += 1
	fails += _expect(leaked == 0,
		"%d exclusive legendary parts leaked into world drops" % leaked)

	# 7. A dedicated legendary must still VARY — same gun, different rolls, or there is
	# no reason to farm the same boss twice (§4.6).
	var leg_lo := 999999
	var leg_hi := -1
	for i in 600:
		var res := _generate_legendary(&"sermon", 5, 1.0)
		leg_lo = mini(leg_lo, res.score)
		leg_hi = maxi(leg_hi, res.score)
		if i == 0:
			fails += _expect(res.legendary_id == &"sermon", "legendary id not stamped")
			fails += _expect(res.flavor != "", "legendary has no flavor text")
			fails += _expect(res.gun_name.ends_with("Sermon"),
				"legendary name '%s' should end in its authored name" % res.gun_name)
	fails += _expect(leg_hi - leg_lo >= 15,
		"Sermon score spread only %d (%d..%d) — no good/bad copies" % [
			leg_hi - leg_lo, leg_lo, leg_hi])

	# 9. ORDNANCE must ride the same pipeline: real score, real grade, and it must be
	# EXEMPT from the 1.0/s fire-rate floor (a 4s-cooldown rocket is 0.25/s by design).
	var ord_slow := 0
	var ord_bad := 0
	for i in 400:
		var oc := WeaponClass.builtin(WeaponClass.ORDNANCE_IDS[
			_rng.randi_range(0, WeaponClass.ORDNANCE_IDS.size() - 1)])
		var res := GunGenerator.generate(library, _rng.randi(), oc,
			_rng.randi_range(1, Tier.COUNT), _rng.randi_range(1, 6), 1.0)
		if float(res.stats.get(&"fire_rate", 9.0)) < 1.0:
			ord_slow += 1
		if res.score < 100 or not res.stats.has(&"cooldown") \
				or float(res.stats.get(&"blast_radius", 0.0)) <= 0.0:
			ord_bad += 1
	fails += _expect(ord_slow > 0,
		"ordnance never rolled under 1.0/s — the fire-rate floor is not exempting it")
	fails += _expect(ord_bad == 0, "%d ordnance rolled without cooldown/blast/score" % ord_bad)

	# 9c. SCORE PARITY ACROSS CATEGORIES. A gun, an ordnance and a shield of the same
	# tier and rarity must land on the same score, or the number stops meaning "tiers of
	# power" and starts meaning "which category did this come from".
	for t: int in [1, 4, 8]:
		for r: int in [1, 3, 5]:
			var g := _mean_score_of(WeaponClass.builtin(&"pistol"), t, r)
			var o := _mean_score_of(WeaponClass.builtin(&"grenade"), t, r)
			var sh := _mean_shield_score(t, r)
			fails += _expect(absi(g - o) <= 12,
				"T%d R%d: gun %d vs ordnance %d — categories disagree" % [t, r, g, o])
			fails += _expect(absi(g - sh) <= 20,
				"T%d R%d: gun %d vs shield %d — categories disagree" % [t, r, g, sh])

	# 9b. DPS parity: ordnance must sit on the same ~60 base DPS every gun class holds,
	# or its score is denominated in a different currency from every other drop.
	for oid: StringName in WeaponClass.ORDNANCE_IDS:
		var oc := WeaponClass.builtin(oid)
		var dps := oc.base_damage * oc.base_fire_rate
		fails += _expect(absf(dps - 60.0) <= 3.0,
			"ordnance %s base DPS %.1f is off the 60 parity" % [oid, dps])

	# 10. UNIFIED STACKING (§11): two sources of an effect upgrade it, and the sources
	# are interchangeable. Part+part, ability+part and ability+ability must all land in
	# the same place, or "power-up" and "weapon ability" are two systems again.
	var pp := GunEffects.stack(PackedStringArray(["ricochet", "ricochet"]))
	fails += _expect(pp.size() == 1 and pp.has("ricochet_up"),
		"part+part did not stack into one upgrade (got %s)" % str(pp))
	var aa := AbilityLoadout.new()
	aa.equip(&"ricochet")
	fails += _expect(aa.apply(PackedStringArray(["ricochet"])).has("ricochet_up"),
		"ability+part did not stack")
	fails += _expect(GunEffects.stack(PackedStringArray(["ricochet_up", "ricochet"]))
		.has("ricochet_up"), "stack() is not idempotent over an existing upgrade")
	# A third source must NOT escalate past the single upgrade tier.
	var triple := GunEffects.stack(PackedStringArray(["ricochet", "ricochet", "ricochet"]))
	fails += _expect(triple.size() == 1 and triple.has("ricochet_up"),
		"three sources escalated past one upgrade tier (got %s)" % str(triple))

	# 10b. Weapon abilities: GRANT when absent, UPGRADE when present, and be idempotent.
	var abil := AbilityLoadout.new()
	abil.equip(&"ricochet")
	var granted := abil.apply(PackedStringArray(["explosive"]))
	fails += _expect(granted.has("ricochet"),
		"ability did not GRANT its effect to a gun lacking it")
	var upgraded := abil.apply(PackedStringArray(["ricochet", "explosive"]))
	fails += _expect(upgraded.has("ricochet_up") and not upgraded.has("ricochet"),
		"ability did not UPGRADE a gun that already had the effect")
	fails += _expect(upgraded.size() == 2,
		"upgrade must REPLACE the base effect, not add alongside it (got %d)" % upgraded.size())
	fails += _expect(abil.apply(abil.apply(PackedStringArray(["ricochet"]))).has("ricochet_up"),
		"apply() is not idempotent — double-applying changed the result")
	fails += _expect(WeaponAbility.base_id(&"ricochet_up") == &"ricochet",
		"base_id() cannot recover the effect an upgrade came from")

	# 10c. An UPGRADED effect must still satisfy a merge that asks for its base form.
	# Without normalisation, stacking an effect silently breaks every merge it takes part
	# in — turning the stacking reward into a penalty.
	var base_merges := MergeRule.detect(PackedStringArray(["ricochet", "explosive"]))
	var up_merges := MergeRule.detect(PackedStringArray(["ricochet_up", "explosive"]))
	fails += _expect(base_merges.size() > 0,
		"ricochet+explosive should be a shipping merge; table may be empty")
	fails += _expect(up_merges.size() == base_merges.size(),
		"upgrading ricochet lost %d merge(s)" % (base_merges.size() - up_merges.size()))

	# 11. Shields must score on the SAME scale as guns, so the two compare directly.
	var s_t1 := ShieldGenerator.generate(1234, 1, 1, &"standard").score
	var s_t2 := ShieldGenerator.generate(1234, 1, 2, &"standard").score
	fails += _expect(absi((s_t2 - s_t1) - 100) <= 12,
		"one tier of shield should be ~100 score, measured %d" % (s_t2 - s_t1))
	var s_layer := ShieldGenerator.to_layer(ShieldGenerator.generate(99, 3, 4, &"brick"))
	fails += _expect(s_layer.layer_type == &"shield" and s_layer.max_value > 0.0,
		"shield did not produce a usable HealthPool layer")

	# 8. Every gun must assemble and score above the floor.
	for i in 200:
		var res := _generate(_rng.randi_range(1, 6), _rng.randi_range(1, Tier.COUNT), 1.0)
		if res.recipe.is_empty() or res.score < 100:
			fails += _expect(false, "bad gun: %s score %d" % [res.gun_name, res.score])
			break

	print("\n--- loot range probe: %s ---" % ("PASS" if fails == 0 else "%d FAIL" % fails))
	print("  T1 Common %d | T1 Rare %d | T1 Legendary %d" % [t1_com, t1_rare, t1_leg])
	print("  calib: T1 Leg %d ~= T3 Uncommon %d | T2 Unique %d | T2 Rare %d" % [
		t1_leg, t3_unc, t2_uni, t2_rare])
	print("  one tier = %d score (T1 Common %d -> T2 Common %d)" % [
		t2_com - t1_com, t1_com, t2_com])
	print("  mean rarity  T1 %.3f -> T10 %.3f" % [lo, hi])
	print("  mean rarity  trash %.3f -> boss %.3f (T5)" % [trash, boss])
	print("  grade-word rate %.1f%%" % pct)
	print("  sign-inverted %d | swallowed %d | leaked exclusive %d" % [
		inverted, swallowed, leaked])
	print("  Sermon score spread: %d..%d (%d wide)" % [leg_lo, leg_hi, leg_hi - leg_lo])
	print("  ordnance: %d/400 under 1.0/s (exempt OK), %d malformed" % [ord_slow, ord_bad])
	print("  shield T1 %d -> T2 %d (one tier = %d)" % [s_t1, s_t2, s_t2 - s_t1])
	print("  merges: base %d, upgraded %d (must match)" % [
		base_merges.size(), up_merges.size()])
	print("  parity T4/R3  gun %d | ordnance %d | shield %d" % [
		_mean_score_of(WeaponClass.builtin(&"pistol"), 4, 3),
		_mean_score_of(WeaponClass.builtin(&"grenade"), 4, 3),
		_mean_shield_score(4, 3)])
	get_tree().quit(1 if fails > 0 else 0)


func _mean_score_of(wc: WeaponClass, tier: int, rarity: int) -> int:
	var total := 0
	var n := 300
	for i in n:
		total += GunGenerator.generate(library, _rng.randi(), wc, tier, rarity, 1.0).score
	return roundi(float(total) / float(n))


func _mean_shield_score(tier: int, rarity: int) -> int:
	var total := 0
	var n := 300
	for i in n:
		total += ShieldGenerator.generate(_rng.randi(), rarity, tier, &"standard").score
	return roundi(float(total) / float(n))


func _is_negative_word(word: String) -> bool:
	return (GunQuality.TIER_N1.has(word) or GunQuality.TIER_N2.has(word)
		or GunQuality.TIER_N3.has(word))


## Mean score for a rarity/tier over many seeds, so one unlucky roll cannot fail the
## run. Note this is E[log(dps)] not log(E[dps]) — close enough at these tolerances,
## and it is the average gun of that kind, which is what the anchors are about.
func _mid_roll_score(wc: WeaponClass, tier: int, rarity: int) -> int:
	var total := 0
	var n := 400
	for i in n:
		total += GunGenerator.generate(library, _rng.randi(), wc, tier, rarity, 1.0).score
	return roundi(float(total) / float(n))


func _rarity_mean(tier: int, archetype: StringName) -> float:
	var total := 0
	var n := 0
	for i in PROBE_SAMPLES:
		for d in LootRoller.roll_drops(archetype, tier, tier, _rng):
			total += d.rarity
			n += 1
	return float(total) / float(maxi(n, 1))


func _expect(ok: bool, msg: String) -> int:
	if not ok:
		push_error("PROBE FAIL: " + msg)
		print("  FAIL: ", msg)
		return 1
	return 0


func _find_mesh(node: Node) -> MeshInstance3D:
	if node is MeshInstance3D:
		return node
	for c in node.get_children():
		var found := _find_mesh(c)
		if found != null:
			return found
	return null
