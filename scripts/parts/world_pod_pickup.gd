class_name WorldPodPickup
extends Node3D
## A pod on the ground (Docs/ModularParts.md section 4, "Pods"): what a destroyed enemy mech
## leaves. A block in a beam of its rarity's colour, turning slowly; the player walking onto
## it on foot takes it -- into the backpack's mech page (MechLoadoutScreen.stash), to fit there.

signal picked(pod: PodGenerator.Result)

## How near the player must come to take it, metres.
const REACH := 2.2
const BEAM_HEIGHT := 3.0

var pod: PodGenerator.Result
## Who may take it: the player's body (a Node3D), or a Callable giving it now (the player may
## be in a mech, or on foot again later) -- null or nothing: nobody.
var taker: Node3D
var taker_of: Callable
var _t := 0.0
var _block: MeshInstance3D


static func create(p: PodGenerator.Result) -> WorldPodPickup:
	var w := WorldPodPickup.new()
	w.name = "PodPickup"
	w.pod = p
	var colour := rarity_colour(p.rarity)
	var block := MeshInstance3D.new()
	block.name = "Block"
	var bm := BoxMesh.new()
	bm.size = Vector3(0.6, 0.45, 0.8)
	block.mesh = bm
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.45, 0.47, 0.5)
	mat.emission_enabled = true
	mat.emission = colour * 0.4
	block.material_override = mat
	block.position = Vector3.UP * 0.4
	w.add_child(block)
	w._block = block
	var beam := MeshInstance3D.new()
	beam.name = "Beam"
	var cm := CylinderMesh.new()
	cm.top_radius = 0.06
	cm.bottom_radius = 0.06
	cm.height = BEAM_HEIGHT
	beam.mesh = cm
	var bmat := StandardMaterial3D.new()
	bmat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	bmat.albedo_color = Color(colour.r, colour.g, colour.b, 0.55)
	bmat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	beam.material_override = bmat
	beam.position = Vector3.UP * BEAM_HEIGHT * 0.5
	beam.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	w.add_child(beam)
	var tag := Label3D.new()
	tag.name = "Tag"
	tag.text = p.pod_name
	tag.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	tag.modulate = colour
	tag.pixel_size = 0.006
	tag.font_size = 32
	tag.outline_size = 8
	tag.position = Vector3.UP * 1.2
	w.add_child(tag)
	return w


## A rarity's colour, as the loot beams read (MechLoadoutScreen's list too).
static func rarity_colour(rarity: int) -> Color:
	return Color.html(MechLoadoutScreen.RARITY_COLOURS[clampi(rarity, 1, 6) - 1])


func _process(delta: float) -> void:
	_t += delta
	if _block != null:
		_block.rotation.y = _t * 0.8
		_block.position.y = 0.4 + sin(_t * 2.0) * 0.06
	check()


## Taken if the taker is in reach: true once taken (it emits `picked` and goes).
func check() -> bool:
	var who: Node3D = taker_of.call() if taker_of.is_valid() else taker
	if pod == null or who == null or not is_instance_valid(who) or not is_inside_tree():
		return false
	if who.global_position.distance_to(global_position) > REACH:
		return false
	var p := pod
	pod = null
	picked.emit(p)
	queue_free()
	return true
