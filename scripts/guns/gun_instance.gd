class_name GunInstance
extends Node3D
## The gun as it exists in the world / in hands. Owns the assembled part tree,
## the rolled stats, and the presentation hooks the weapon controller calls:
##   play_reload()                     -> receiver's reload clip
##   play_shot_effects(hit_point)      -> barrel's sound + flash + trail
## Stats/rarity are carried opaquely; their model lives in the stats spec.

var gun_seed: int = 0
var rarity: int = 1
var gun_name: String = ""
var stats: Dictionary[StringName, float] = {}
var recipe: Dictionary = {}
var weapon_class: WeaponClass
var tier: int = 1
var active_effects: PackedStringArray = PackedStringArray()
var merges: Array[MergeRule] = []

var _model_root: Node3D
var _muzzle_point: Node3D
var _receiver_anim: AnimationPlayer
var _shot_audio: AudioStreamPlayer3D

var _receiver_def: GunReceiverDef
var _barrel_def: GunBarrelDef

var current_skin: GunSkinDef


static func create(library: GunPartLibrary, gen_seed: int = -1,
		skin_library: GunSkinLibrary = null) -> GunInstance:
	return from_result(GunGenerator.generate(library, gen_seed), skin_library)


static func from_result(result: GunGenerator.Result,
		skin_library: GunSkinLibrary = null) -> GunInstance:
	var gun := GunInstance.new()
	gun.gun_seed = result.seed
	gun.rarity = result.rarity
	gun.gun_name = result.gun_name
	gun.stats = result.stats
	gun.recipe = result.recipe
	gun.weapon_class = result.weapon_class
	gun.tier = result.tier
	gun.active_effects = result.active_effects
	gun.merges = result.merges
	gun.name = "Gun_%d" % result.seed

	gun._receiver_def = result.recipe.get(GunPartDef.Slot.BODY) as GunReceiverDef
	gun._barrel_def = result.recipe.get(GunPartDef.Slot.BARREL) as GunBarrelDef

	gun._model_root = GunAssembler.assemble(result.recipe)
	if gun._model_root != null:
		gun.add_child(gun._model_root)
		gun._cache_muzzle()
		gun._cache_receiver_anim()
		gun._setup_shot_audio()
		# Manufacturer tint pass: the body's brand picks the default skin.
		if skin_library != null:
			var brand: StringName = (result.recipe[GunPartDef.Slot.BODY]
				as GunPartDef).manufacturer
			gun.apply_skin(skin_library.default_for(brand))
	return gun


## Applies (or swaps) a cosmetic skin across all parts. Idempotent; safe to
## call any time, including on already-skinned guns.
func apply_skin(skin: GunSkinDef) -> void:
	if skin == null or _model_root == null:
		return
	current_skin = skin
	GunSkinApplier.apply(_model_root, skin)


# ------------------------------------------------------------------ reload --

## Plays the receiver's reload clip. Returns its length in seconds so the
## weapon controller can time the ammo refill (0.0 if unavailable).
func play_reload() -> float:
	return play_receiver_animation(&"reload")


## Plays a logical receiver clip (&"reload", &"equip", &"inspect"...), resolved
## through the receiver def so clip names never leak into game code.
func play_receiver_animation(logical_name: StringName) -> float:
	if _receiver_anim == null:
		return 0.0
	var clip := StringName()
	if _receiver_def != null:
		if logical_name == &"reload":
			clip = _receiver_def.reload_animation
		else:
			clip = _receiver_def.extra_animations.get(logical_name, StringName())
	if clip == StringName():
		clip = logical_name # Fallback: logical name == clip name.
	if not _receiver_anim.has_animation(clip):
		push_warning("GunInstance: receiver has no animation '%s'." % clip)
		return 0.0
	_receiver_anim.play(clip)
	return _receiver_anim.get_animation(clip).length


## Safely interrupts a reload/inspect: snaps sockets back to rest pose via the
## RESET animation if the receiver GLB exports one, else just stops playback.
func cancel_animation() -> void:
	if _receiver_anim == null:
		return
	if _receiver_anim.has_animation(&"RESET"):
		_receiver_anim.play(&"RESET")
	else:
		_receiver_anim.stop()


# -------------------------------------------------------------------- shot --

## Barrel-defined presentation for one shot: sound at the muzzle, muzzle flash,
## and a trail toward hit_point (skipped if hit_point is not provided).
## Ballistics/damage stay in the weapon controller; this is presentation only.
func play_shot_effects(hit_point: Variant = null) -> void:
	if _barrel_def == null:
		return
	if _shot_audio != null and _barrel_def.shoot_sound != null:
		_shot_audio.pitch_scale = randf_range(
			_barrel_def.pitch_range.x, _barrel_def.pitch_range.y)
		_shot_audio.play()
	_spawn_muzzle_flash()
	if hit_point is Vector3:
		_spawn_trail(hit_point)


func get_muzzle_point() -> Node3D:
	return _muzzle_point if _muzzle_point != null else _model_root


func get_muzzle_position() -> Vector3:
	return get_muzzle_point().global_position


func describe() -> String:
	var lines: Array[String] = [
		"%s  [%s]" % [gun_name, GunGenerator.RARITY_NAMES[rarity - 1]],
		"seed: %d" % gun_seed,
	]
	for slot: int in recipe:
		var def := recipe[slot] as GunPartDef
		lines.append("  %s: %s" % [
			GunPartDef.Slot.keys()[slot].to_lower(), def.id])
	for key: StringName in stats:
		lines.append("  %s = %.2f" % [key, stats[key]])
	if not active_effects.is_empty():
		lines.append("  effects: %s" % ", ".join(active_effects))
	for m: MergeRule in merges:
		lines.append("  merge: %s  (%s + %s)" % [m.bonus_effect, m.effect_a, m.effect_b])
	return "\n".join(lines)


# --------------------------------------------------------------- internals --

func _spawn_muzzle_flash() -> void:
	if _barrel_def.muzzle_flash_scene == null:
		return
	var flash := _barrel_def.muzzle_flash_scene.instantiate()
	get_muzzle_point().add_child(flash)
	if flash.has_method(&"flash"):
		flash.call(&"flash")
	elif flash is GPUParticles3D:
		var p := flash as GPUParticles3D
		p.one_shot = true
		p.emitting = true
		get_tree().create_timer(p.lifetime + 0.1).timeout.connect(p.queue_free)
	# Otherwise the scene is trusted to clean itself up.


func _spawn_trail(hit_point: Vector3) -> void:
	if _barrel_def.bullet_trail_scene == null:
		return
	var trail := _barrel_def.bullet_trail_scene.instantiate()
	# Trails live in world space, not under the (moving) gun.
	get_tree().current_scene.add_child(trail)
	if trail.has_method(&"setup"):
		trail.call(&"setup", get_muzzle_position(), hit_point)
	elif trail is Node3D:
		(trail as Node3D).global_position = get_muzzle_position()


func _cache_muzzle() -> void:
	# Deepest socket_muzzle in the tree = end of the barrel chain (a muzzle
	# attachment's own socket beats the barrel's).
	var best: Node3D = null
	var best_depth := -1
	for node in _model_root.find_children("socket_muzzle*", "Node3D", true, false):
		var depth := 0
		var cur: Node = node
		while cur != _model_root and cur != null:
			depth += 1
			cur = cur.get_parent()
		if depth > best_depth:
			best_depth = depth
			best = node
	_muzzle_point = best


func _cache_receiver_anim() -> void:
	# The receiver instance is the assembly root; its GLB-imported
	# AnimationPlayer carries the reload/equip clips.
	_receiver_anim = _model_root.find_child("AnimationPlayer", true, false) \
		as AnimationPlayer


func _setup_shot_audio() -> void:
	if _barrel_def == null or _barrel_def.shoot_sound == null:
		return
	_shot_audio = AudioStreamPlayer3D.new()
	_shot_audio.name = "ShotAudio"
	_shot_audio.stream = _barrel_def.shoot_sound
	get_muzzle_point().add_child(_shot_audio)
