class_name WorldGunPickup
extends RigidBody3D
## A generated gun lying on the ground: the assembled model, a rarity-coloured beam so
## it reads at distance, and the Result the card renders from.
##
## It is a body: dropped, it is tossed up a little and falls, tumbles and comes to rest
## lying on its side, and sleeps there. It wakes when something moves it -- a blast
## near it (`blast`, from every explosion), or the ground under it going (a floor
## broken, a building fallen: a sleeping gun looks under itself now and then). It is
## on the rubble layer, so a walker never trips on it and bullets do not stop at it.
##
## Owns no input and no UI. PlayerArsenal decides which pickup is being looked at and
## the HUD draws the single shared GunCard -- one card, many pickups, so the card's cost
## does not scale with loot on the floor.

const BEAM_HEIGHT := 2.2
## Every pickup is in this group: what a player can reach for (PlayerArsenal).
const GROUP := &"gun_pickups"
## Placeholder parts are authored at roughly real-gun scale (~0.5 m body), which reads
## as a crate on the floor: shrunk to a pickup-sized silhouette.
const MODEL_SCALE := 0.55
const MASS := 3.0
## Asleep, it looks this far under itself this often; nothing there, it wakes and falls.
const GROUND_CHECK := 0.5
const GROUND_REACH := 0.3

var result: GunGenerator.Result
var gun: GunInstance

var _beam_mi: MeshInstance3D
var _half_height := 0.05
var _check := 0.0


static func create(library: GunPartLibrary, res: GunGenerator.Result) -> WorldGunPickup:
	var p := WorldGunPickup.new()
	p.result = res
	p.name = "Pickup"
	p.add_to_group(GROUP)
	p.mass = MASS
	p.collision_layer = Layers.RUBBLE
	p.collision_mask = Layers.RUBBLE_MASK
	p.can_sleep = true
	p.continuous_cd = true
	p.angular_damp = 1.5
	var pm := PhysicsMaterial.new()
	pm.friction = 0.9
	pm.bounce = 0.05
	p.physics_material_override = pm

	# Rebuild from the recipe rather than re-generating: a re-roll from the seed would
	# be a DIFFERENT gun the moment any table changes, and the card would disagree with
	# the model the player is looking at.
	p.gun = GunInstance.new()
	var model := GunAssembler.assemble(res.recipe)
	if model != null:
		p.gun.add_child(model)
	p.gun.gun_seed = res.seed
	p.gun.scale = Vector3.ONE * MODEL_SCALE
	p.add_child(p.gun)
	p._shape()

	p._beam_mi = p._beam(res.rarity)
	p._beam_mi.top_level = true
	p.add_child(p._beam_mi)
	return p


## A box round the model, the body's shape, centred on the body: the model is moved so
## its middle sits on the body's origin, so it tumbles about its middle.
func _shape() -> void:
	var box := AABB()
	var first := true
	for n in gun.find_children("*", "VisualInstance3D", true, false):
		var vi := n as VisualInstance3D
		var xf := _local_to(vi, gun) * vi.get_aabb()
		box = xf if first else box.merge(xf)
		first = false
	if first:
		box = AABB(Vector3(-0.05, -0.05, -0.2), Vector3(0.1, 0.1, 0.4))
	var size := box.size * MODEL_SCALE
	gun.position = -box.get_center() * MODEL_SCALE
	var cs := CollisionShape3D.new()
	var shape := BoxShape3D.new()
	shape.size = Vector3(maxf(size.x, 0.04), maxf(size.y, 0.04), maxf(size.z, 0.08))
	cs.shape = shape
	add_child(cs)
	_half_height = minf(size.x, size.y) * 0.5


## The transform from `n` up to `top` (both out of the tree yet).
static func _local_to(n: Node3D, top: Node3D) -> Transform3D:
	var t := Transform3D.IDENTITY
	var cur: Node = n
	while cur != null and cur != top:
		if cur is Node3D:
			t = (cur as Node3D).transform * t
		cur = cur.get_parent()
	return t


## Dropped: a small toss and a turn, so it falls and lands rather than appearing.
func toss(rng: RandomNumberGenerator = null) -> void:
	var r := rng if rng != null else RandomNumberGenerator.new()
	rotation = Vector3(0.0, r.randf() * TAU, r.randf_range(-0.4, 0.4))
	linear_velocity = Vector3(r.randf_range(-0.6, 0.6), r.randf_range(1.5, 2.5), r.randf_range(-0.6, 0.6))
	angular_velocity = Vector3(r.randf_range(-3.0, 3.0), r.randf_range(-2.0, 2.0), r.randf_range(-3.0, 3.0))


## Where the gun is: its middle (what the player reaches for and looks at).
func centre() -> Vector3:
	return global_position


## Every pickup within `radius` of `at` wakes and is thrown out from it, harder nearer.
## Called by every explosion (a grenade, a blast in the bricks, an explosive round).
static func blast(at: Vector3, radius: float, push := 6.0) -> void:
	var tree := Engine.get_main_loop() as SceneTree
	if tree == null:
		return
	for n in tree.get_nodes_in_group(GROUP):
		var p := n as WorldGunPickup
		if p == null or not p.is_inside_tree() or p.is_queued_for_deletion():
			continue
		var to := p.global_position - at
		var d := to.length()
		if d > radius:
			continue
		var k := 1.0 - d / maxf(radius, 0.01)
		var dir := (to / d if d > 0.01 else Vector3.UP) + Vector3.UP * 0.6
		p.sleeping = false
		p.apply_central_impulse(dir.normalized() * push * k * p.mass)
		p.apply_torque_impulse(Vector3(randf_range(-1.0, 1.0), randf_range(-1.0, 1.0),
				randf_range(-1.0, 1.0)) * 0.05 * k * p.mass)


## The impostor ladder (Docs/Impostors.md 8.3), if the scene has one: past a
## few metres the gun is a baked card and its model is hidden. The beam is not
## touched -- it is what reads at range. Without an ImpostorItems in the scene
## nothing here changes. The card follows the body while it moves.
var _items: ImpostorItems = null
var _item := -1
var _item_key := ""


func _ready() -> void:
	_items = get_tree().get_first_node_in_group(ImpostorItems.GROUP) as ImpostorItems
	if _items == null or gun == null:
		return
	_item_key = "gun_%d" % (result.seed if result != null else get_instance_id())
	_items.kind_from_node(_item_key, gun)
	_item = _items.add(_item_key, gun.global_transform)


func _exit_tree() -> void:
	if _items != null and _item >= 0:
		_items.remove(_item)
		_items.drop_kind(_item_key)
		_item = -1


func _process(delta: float) -> void:
	# The beam stands up out of the gun however the gun lies.
	if _beam_mi != null:
		_beam_mi.global_transform = Transform3D(Basis.IDENTITY,
				global_position + Vector3.UP * BEAM_HEIGHT * 0.5)
	if _item >= 0:
		if not sleeping:
			_items.move(_item, gun.global_transform)
		# Its own model unless the card is standing in for it (not before
		# the first pass has placed it, nor while the bake is still coming).
		gun.visible = _items.tier_of(_item) != 2
	if sleeping:
		_check -= delta
		if _check <= 0.0:
			_check = GROUND_CHECK
			if not _ground_under():
				sleeping = false


## Is there anything right under it to lie on?
func _ground_under() -> bool:
	var from := global_position
	var q := PhysicsRayQueryParameters3D.create(from, from + Vector3.DOWN * (_half_height
			+ GROUND_REACH), collision_mask, [get_rid()])
	return not get_world_3d().direct_space_state.intersect_ray(q).is_empty()


## Rarity-coloured light column. This is the read that lets a player triage a pile of
## loot from across the room without opening a single card.
func _beam(rarity: int) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	var mesh := CylinderMesh.new()
	mesh.top_radius = 0.14
	mesh.bottom_radius = 0.14
	mesh.height = BEAM_HEIGHT
	mesh.radial_segments = 10
	mi.mesh = mesh

	var col := GunCard.RARITY_COLORS[clampi(rarity - 1, 0, 5)]
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(col.r, col.g, col.b, 0.20)
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.emission_enabled = true
	mat.emission = col
	mat.emission_energy_multiplier = 1.6
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	mi.material_override = mat
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	return mi
