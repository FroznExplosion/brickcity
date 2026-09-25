extends Node3D
## Drop on a Node3D in a test scene, assign a GunPartLibrary, run.
## R = reroll a random gun, Enter = re-generate the last seed (determinism
## check), S = cycle skins from the skin library.

@export var library: GunPartLibrary
@export var skin_library: GunSkinLibrary
@export var slow_spin := true

var _gun: GunInstance
var _last_seed := -1
var _skin_index := -1


func _ready() -> void:
	_reroll()


func _process(delta: float) -> void:
	if slow_spin and _gun != null:
		_gun.rotate_y(delta * 0.6)


func _unhandled_key_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo:
		match event.keycode:
			KEY_R:
				_reroll()
			KEY_ENTER:
				_reroll(_last_seed)
			KEY_S:
				_cycle_skin()


func _reroll(forced_seed: int = -1) -> void:
	if library == null:
		push_error("gun_forge_test: assign a GunPartLibrary in the inspector.")
		return
	if _gun != null:
		_gun.queue_free()
	_gun = GunInstance.create(library, forced_seed, skin_library)
	_last_seed = _gun.gun_seed
	add_child(_gun)
	print("\n", _gun.describe())


func _cycle_skin() -> void:
	if _gun == null or skin_library == null or skin_library.skins.is_empty():
		return
	_skin_index = (_skin_index + 1) % skin_library.skins.size()
	_gun.apply_skin(skin_library.skins[_skin_index])
	print("skin: ", skin_library.skins[_skin_index].id)
