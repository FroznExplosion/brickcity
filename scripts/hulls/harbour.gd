class_name Harbour
extends Node
## A boat you can play (Docs/Hulls.md 7.2): the city's sea gets one, moored off the
## nearest shore to where the player starts. It owns the boat's ghost space
## (GhostHulls) and runs the player's crossing each tick (GhostHulls.tick): swim or
## jump to it and you are aboard its ghost, walking a deck that rolls with the sea
## (PlayerController draws the view on the real boat). Every gun's ray and the
## AI's sight lines find it through ShipRays (its bricks are only in its ghost),
## and AI soldiers cross onto it as the player does. It cuts the sea out of the
## hull (HullMasks) and, once the boat has sunk and nobody is on it, launches a new
## one at the same berth.

## How far out from the start to look for its berth, metres.
const SEARCH := 1500.0
## Water this deep under every corner of the berth (its keel and some), metres.
const BERTH_DEPTH := 3.0
## Half its footprint, metres: the berth's corners are this far from its middle.
const BERTH_HALF := 9.0
## Sunk this far under the sea and nobody aboard this long: a new boat.
const SUNK_DEPTH := 6.0
const RELAUNCH_AFTER := 12.0

var city: Node
var boat: Boat = null
var ghosts: GhostHulls = null
var berth := Transform3D.IDENTITY
var _sunk_for := 0.0
var _seed := 1


## The harbour for `c` (the city), if its sea has a berth near `from`. Null if
## not (no sea, or no water deep enough in reach).
static func open(c: Node, from: Vector3) -> Harbour:
	if c._sea == null:
		return null
	var at := find_berth(c, from)
	if at == Transform3D.IDENTITY:
		print("[harbour] no water %.0f m deep within %.0f m" % [BERTH_DEPTH, SEARCH])
		return null
	var h := Harbour.new()
	h.name = "Harbour"
	h.city = c
	h.berth = at
	c.add_child(h)
	h.launch()
	return h


## The nearest place to `from` with the sea at least BERTH_DEPTH deep under the
## middle and four corners of a boat's footprint, the boat lying along the shore.
## Identity if none within SEARCH.
static func find_berth(c: Node, from: Vector3) -> Transform3D:
	var sea: float = BrickWave.get_sea_level()
	for r in range(20, int(SEARCH), 10):
		var n := clampi(int(TAU * r / 12.0), 24, 256)
		for k in n:
			var a := TAU * float(k) / float(n)
			var p := from + Vector3(cos(a) * r, 0.0, sin(a) * r)
			var deep := true
			for o in [Vector2.ZERO, Vector2(1, 1), Vector2(1, -1), Vector2(-1, 1), Vector2(-1, -1)]:
				var q := p + Vector3(o.x, 0.0, o.y) * BERTH_HALF
				if c._on_ground(q).y > sea - BERTH_DEPTH:
					deep = false
					break
			if deep:
				# Along the shore: its length (its own x) across the way out.
				return Transform3D(Basis(Vector3.UP, -(a + PI * 0.5)), Vector3(p.x, sea + 0.6, p.z))
	return Transform3D.IDENTITY


## A new boat at its berth.
func launch() -> void:
	if ghosts == null:
		ghosts = GhostHulls.new()
	boat = Boat.launch(city, _seed, berth, ghosts)
	ShipRays.ships.append(boat)
	if city._sea != null and city._sea.near != null:
		var sea_node = city._sea.near
		boat.wave_clock = func() -> float: return float(sea_node._time)
	_sunk_for = 0.0
	print("[harbour] boat %d launched at (%.0f, %.0f)" % [_seed, berth.origin.x, berth.origin.z])


func _physics_process(dt: float) -> void:
	if boat == null or not is_instance_valid(boat):
		return
	var pawn := _pawn()
	var space: RID = city.get_world_3d().space
	if pawn != null:
		GhostHulls.tick(pawn, [boat], space)
	# The AI's soldiers on and off it the same way.
	for so in city.soldiers:
		if is_instance_valid(so) and so.pawn != null and is_instance_valid(so.pawn) and so.pawn != pawn \
				and so.pawn.body != null and so.pawn.body.is_inside_tree():
			GhostHulls.tick(so.pawn, [boat], space)
	# A gun dropped on its deck rides it too (Docs/Hulls.md 7b.4).
	ShipCargo.tick(get_tree(), [boat], space)
	HullMasks.update([boat], city.camera.global_position)
	# Sunk and nobody aboard: a new one at the berth.
	var under: float = BrickWave.get_sea_level() - boat.global_position.y
	if under > SUNK_DEPTH and (pawn == null or pawn.ghost != boat):
		_sunk_for += dt
		if _sunk_for > RELAUNCH_AFTER:
			print("[harbour] boat %d sunk; a new one" % _seed)
			_put_away(boat)
			_seed += 1
			launch()
	else:
		_sunk_for = 0.0


## The player's pawn while it is played; off the boat's ghost when it is not
## (flying the free camera, a vehicle).
func _pawn() -> Pawn:
	var p: Pawn = city._player_pawn
	if p == null or not is_instance_valid(p):
		return null
	if not city._player.is_possessing():
		get_off(p)
		return null
	return p


## `p` off the boat's ghost, if it is on it.
func get_off(p: Pawn) -> void:
	if p != null and is_instance_valid(p) and p.ghost != null and is_instance_valid(p.ghost):
		GhostHulls.get_off(p.body, p.ghost, city.get_world_3d().space)
		p.ghost = null


## `b` gone: whoever is on its ghost off it, out of the rays' list, freed.
func _put_away(b: Boat) -> void:
	for so in city.soldiers:
		if is_instance_valid(so) and so.pawn != null and is_instance_valid(so.pawn) and so.pawn.ghost == b:
			get_off(so.pawn)
	ShipRays.ships.erase(b)
	b.queue_free()


func _exit_tree() -> void:
	get_off(city._player_pawn if city != null else null)
	if boat != null and is_instance_valid(boat):
		ShipRays.ships.erase(boat)
	if ghosts != null:
		ghosts.free_space()
		ghosts = null
