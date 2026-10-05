class_name SurfaceSounds
extends Node3D

## The sound of weather on what it falls on (Docs/Disasters.md 24): rain
## pattering, hail clattering -- each drop or stone heard as the material it
## struck. The points come from RainSplash, whose rays down from the sky find
## what is open to it: a roof, the ground, the sea. A floor under a roof is
## never hit, so it never sounds, and from indoors the storm is heard on the
## roof overhead.
##
## Each hit point is filed by family when it is found (BrickMaterials.family):
## a brick by its material, the ground by the terrain's, below the sea level
## as water. Sounds are BrickMaterials' own synthesised impacts -- plastic high
## and short, wood hollow, metal ringing, stone dull -- pitched and levelled
## for what is falling: rain small and soft, hail hard.

const VOICES := 14
const NEAR := 16.0                ## m: only hits this close are played

## How hard what is falling hits, and how often a second a hit is heard at full
## rate: "rain" or "hail".
var kind := "rain"
var rate := 18.0
var played := 0
## How many plays per family, for the probe.
var by_family := {}

var _points: Array = []           ## [point, family]
var _voices: Array[AudioStreamPlayer3D] = []
var _next := 0
var _owed := 0.0
var _rng := RandomNumberGenerator.new()


func setup(p_kind: String) -> void:
	kind = p_kind
	rate = 26.0 if kind == "hail" else 18.0
	_rng.seed = hash(kind)
	for i in VOICES:
		var p := AudioStreamPlayer3D.new()
		p.unit_size = 3.0 if kind == "hail" else 2.0
		p.max_distance = NEAR * 1.5
		p.attenuation_model = AudioStreamPlayer3D.ATTENUATION_INVERSE_DISTANCE
		add_child(p)
		_voices.append(p)


## The points the rain found to land on, re-read with every refresh: filed by
## family, nearest kept.
func set_points(hits: Array, at: Vector3, host: Node, ctx: DisasterContext) -> void:
	_points.clear()
	var sea := BrickWave.get_sea_level()
	var terrain: bool = host.has_method("has_terrain") and host.has_terrain()
	for h in hits:
		var p: Vector3 = h[0]
		# Across, not through: the rain on the roof overhead is near.
		if Vector2(p.x - at.x, p.z - at.z).length() > NEAR:
			continue
		_points.append([p, _family_at(p, h[1], sea, terrain, ctx)])


func _family_at(p: Vector3, n: Vector3, sea: float, terrain: bool, ctx: DisasterContext) -> String:
	if terrain and p.y <= sea + 0.25:
		return "water"
	var m := ctx.material_at(p - n * 0.05)
	if m >= 0:
		return BrickMaterials.family(m)
	if terrain:
		var stud := BrickWorld.get_stud_metres()
		var tm := BrickTerrain.material_at(floori(p.x / stud), floori(p.z / stud))
		var names: PackedStringArray = BrickTerrain.material_names()
		var name := names[tm].to_lower() if tm >= 0 and tm < names.size() else ""
		if name.contains("stone") or name.contains("rock") or name.contains("gravel"):
			return "stone"
		if name.contains("sand") or name.contains("snow") or name.contains("dirt"):
			return "soft"
	return "plastic"


## `amount` 0..1: how much is falling now.
func step(delta: float, amount: float) -> void:
	if _points.is_empty() or amount <= 0.01:
		return
	_owed += rate * amount * delta
	while _owed >= 1.0:
		_owed -= 1.0
		var pt: Array = _points[_rng.randi() % _points.size()]
		_play(pt[0], pt[1])


func _play(at: Vector3, fam: String) -> void:
	var v := _voices[_next]
	_next = (_next + 1) % _voices.size()
	var water := fam == "water"
	v.stream = BrickMaterials.hit_sound("soft" if water else fam, _rng.randi() % 3)
	v.global_position = at
	if kind == "hail":
		v.pitch_scale = _rng.randf_range(1.15, 1.6) * (1.6 if water else 1.0)
		v.volume_db = _rng.randf_range(-10.0, -3.0) - (6.0 if water else 0.0)
	else:
		v.pitch_scale = _rng.randf_range(1.7, 2.4) * (1.4 if water else 1.0)
		v.volume_db = _rng.randf_range(-24.0, -16.0)
	v.play()
	played += 1
	by_family[fam] = int(by_family.get(fam, 0)) + 1
