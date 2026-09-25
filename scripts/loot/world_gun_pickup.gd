class_name WorldGunPickup
extends Node3D
## A generated gun lying on the ground: the assembled model, a rarity-coloured beam so
## it reads at distance, and the Result the card renders from.
##
## Owns no input and no UI. The bed decides which pickup is being looked at and drives
## the single shared GunCard — one card, many pickups, so the card's cost does not scale
## with loot on the floor.

const BEAM_HEIGHT := 2.2
const SPIN_SPEED := 0.8

var result: GunGenerator.Result
var gun: GunInstance

var _spin_root: Node3D


static func create(library: GunPartLibrary, res: GunGenerator.Result) -> WorldGunPickup:
	var p := WorldGunPickup.new()
	p.result = res
	p.name = "Pickup"

	p._spin_root = Node3D.new()
	p.add_child(p._spin_root)

	# Rebuild from the recipe rather than re-generating: a re-roll from the seed would
	# be a DIFFERENT gun the moment any table changes, and the card would disagree with
	# the model the player is looking at.
	p.gun = GunInstance.new()
	var model := GunAssembler.assemble(res.recipe)
	if model != null:
		p.gun.add_child(model)
	p.gun.gun_seed = res.seed
	# Placeholder parts are authored at roughly real-gun scale (~0.5 m body), which reads
	# as a crate on the floor. Shrink to a pickup-sized silhouette.
	p.gun.scale = Vector3.ONE * 0.55
	p._spin_root.add_child(p.gun)
	p._spin_root.position.y = 0.55

	p.add_child(p._beam(res.rarity))
	return p


func _process(delta: float) -> void:
	if _spin_root != null:
		_spin_root.rotate_y(delta * SPIN_SPEED)


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
	mi.position.y = BEAM_HEIGHT * 0.5

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
	return mi
