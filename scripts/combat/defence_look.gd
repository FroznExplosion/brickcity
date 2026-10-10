class_name DefenceLook
extends Node3D
## What an enemy wears, SEEN (Docs/Weapons/COMBAT_DESIGN.md 4.1): the melee counts
## only read if the player can see the shield and the armor, and see them go.
##
##   shield   a translucent shell round the body, brighter the fuller it is; it flashes
##            when hit and bursts outward when it breaks; it fades back in as it
##            regenerates
##   armor    amber plates over the chest and shoulders; they shrink as the armor wears
##            and flash off when it breaks
##
## Reads the body's HealthPool every frame -- whatever layers it has, from a profile or
## a roster recipe -- so nothing that damages it needs to know this is here. Sized from
## the body's capsule, so a crouch or a big roster body is covered too.

const SHIELD_COLOUR := Color(0.35, 0.75, 1.0)
const ARMOR_COLOUR := Color(0.95, 0.7, 0.25)
const SHIELD_PAD := 0.07
const ARMOR_PAD := 0.035
## Seconds a hit flash and a break burst last.
const FLASH := 0.12
const BURST := 0.3

var pool: HealthPool
var _shape: CollisionShape3D
var _shield: MeshInstance3D
var _shield_mat: StandardMaterial3D
var _armor: MeshInstance3D
var _armor_mat: StandardMaterial3D
var _shield_i := -1
var _armor_i := -1
var _last_shield := 0.0
var _last_armor := 0.0
var _flash := 0.0
var _burst := 0.0
var _armor_flash := 0.0


## Dress the body that owns `p` (its parent) with its defences, once. Nothing to show
## (no shield, no armor) adds nothing.
static func dress(p: HealthPool) -> DefenceLook:
	if p == null or p.get_parent() == null:
		return null
	var body := p.get_parent()
	# A person-shaped body only: a capsule to wrap. A flyer or a vehicle is its own
	# shape and shows its damage its own way.
	var capsule := false
	for c in body.get_children():
		if c is CollisionShape3D and (c as CollisionShape3D).shape is CapsuleShape3D:
			capsule = true
			break
	if not capsule:
		return null
	var had := body.get_node_or_null(^"DefenceLook") as DefenceLook
	if had != null:
		had._bind()
		return had
	var look := DefenceLook.new()
	look.name = "DefenceLook"
	look.pool = p
	body.add_child(look)
	look._bind()
	return look


func _bind() -> void:
	_shield_i = -1
	_armor_i = -1
	for i in pool.layer_count():
		match pool.layer_type_at(i):
			&"shield":
				if _shield_i < 0:
					_shield_i = i
			&"armor":
				if _armor_i < 0:
					_armor_i = i
	_last_shield = pool.get_layer_value(_shield_i)
	_last_armor = pool.get_layer_value(_armor_i)
	for c in get_parent().get_children():
		if c is CollisionShape3D and (c as CollisionShape3D).shape is CapsuleShape3D:
			_shape = c
			break
	if _shield_i >= 0 and _shield == null:
		_shield_mat = _material(SHIELD_COLOUR)
		_shield = _capsule(_shield_mat)
	if _armor_i >= 0 and _armor == null:
		_armor_mat = _material(ARMOR_COLOUR)
		_armor_mat.transparency = BaseMaterial3D.TRANSPARENCY_DISABLED
		_armor_mat.shading_mode = BaseMaterial3D.SHADING_MODE_PER_PIXEL
		_armor_mat.metallic = 0.6
		_armor_mat.roughness = 0.35
		_armor = MeshInstance3D.new()
		var plate := CylinderMesh.new()
		plate.radial_segments = 8
		plate.rings = 1
		_armor.mesh = plate
		_armor.material_override = _armor_mat
		add_child(_armor)
	if _shield != null:
		_shield.visible = _shield_i >= 0
	if _armor != null:
		_armor.visible = _armor_i >= 0
	set_process(_shield_i >= 0 or _armor_i >= 0)


func _material(c: Color) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = Color(c.r, c.g, c.b, 0.25)
	m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	m.emission_enabled = true
	m.emission = c
	m.cull_mode = BaseMaterial3D.CULL_BACK
	return m


func _capsule(mat: Material) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	var cap := CapsuleMesh.new()
	cap.radial_segments = 16
	cap.rings = 4
	mi.mesh = cap
	mi.material_override = mat
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(mi)
	return mi


func _process(delta: float) -> void:
	if pool == null or not is_instance_valid(pool):
		queue_free()
		return
	var r := Pawn.BODY_RADIUS
	var h := Pawn.BODY_HEIGHT
	var centre := Vector3(0.0, h * 0.5, 0.0)
	if _shape != null:
		var cs := _shape.shape as CapsuleShape3D
		r = cs.radius
		h = cs.height
		centre = _shape.position
	var dead := pool.is_dead()

	if _shield != null:
		var now := pool.get_layer_value(_shield_i)
		var frac := pool.get_layer_fraction(_shield_i)
		if now < _last_shield - 0.001:
			_flash = FLASH
			if now <= 0.0:
				_burst = BURST
		_last_shield = now
		_flash = maxf(_flash - delta, 0.0)
		_burst = maxf(_burst - delta, 0.0)
		var cap := _shield.mesh as CapsuleMesh
		cap.radius = r + SHIELD_PAD
		cap.height = h + SHIELD_PAD * 2.0
		_shield.position = centre
		var pop := 1.0 + (1.0 - _burst / BURST) * 0.35 if _burst > 0.0 else 1.0
		_shield.scale = Vector3.ONE * pop
		var a := 0.06 + 0.2 * frac
		var glow := 0.4 + 0.8 * frac
		if _flash > 0.0:
			a += 0.35 * _flash / FLASH
			glow += 2.0 * _flash / FLASH
		if _burst > 0.0:
			a = 0.5 * _burst / BURST
			glow = 3.0 * _burst / BURST
		_shield_mat.albedo_color.a = a
		_shield_mat.emission_energy_multiplier = glow
		_shield.visible = not dead and (frac > 0.0 or _burst > 0.0)

	if _armor != null:
		var now := pool.get_layer_value(_armor_i)
		var frac := pool.get_layer_fraction(_armor_i)
		if now < _last_armor - 0.001:
			_armor_flash = FLASH
		_last_armor = now
		_armor_flash = maxf(_armor_flash - delta, 0.0)
		# A plate round the chest, from the waist up to the shoulders; as the armor wears
		# it shrinks down from the shoulders, so how much is left reads at a glance.
		var full := h * 0.42
		var plate := _armor.mesh as CylinderMesh
		plate.top_radius = r + ARMOR_PAD
		plate.bottom_radius = r + ARMOR_PAD
		plate.height = maxf(full * frac, 0.001)
		var waist := centre.y - h * 0.05
		_armor.position = Vector3(centre.x, waist + plate.height * 0.5, centre.z)
		_armor_mat.emission_energy_multiplier = 0.15 + 2.5 * _armor_flash / FLASH
		_armor.visible = not dead and frac > 0.0
