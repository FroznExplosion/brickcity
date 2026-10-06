class_name BrickFire
extends FireSpread

## Fire, brick by brick (Docs/Disasters.md 29): what a city burns with. The
## same service as FireSpread -- ignite(), douse(), cells for the flames, the
## smoke and the AI -- but what burns is BRICKS, in BrickWorld.fire_step:
##
##   * every brick has heat; a burning one heats what is next to it, three times
##     as much above as beside (fire climbs), more downwind, and across a few
##     cells of air upward and downwind;
##   * a brick catches when its heat passes 1 and it TOUCHES AIR -- so a canopy
##     burns from the outside in and a wall from its faces, with no special case;
##   * it burns for its material's time and size -- leaves in a couple of
##     seconds, plastic in seven, a length of wooden trunk in half a minute --
##     and is then gone, which the building's solve feels like any other loss:
##     burnt supports bring down what they held;
##   * whatever gets hot chars (its material's darkest), metal and stone too,
##     which never burn.
##
## Between buildings -- tree to tree, tree to house -- fire crosses as EMBERS:
## a few points off the burning bricks each step, lifted and carried downwind,
## heating whatever brick they land in.
##
## Host only, like every change to the world: the bricks killed and charred are
## committed as BURN and SCORCH (by ids) through the city (fire_burnt), and a
## client replays those. The heat itself never leaves the host.
##
## HARD CAPS: MAX_BURNING bricks in the whole city, MAX_PER_CHUNK in one
## building; at the cap nothing new catches. Flames are drawn per coarse cell
## (FireSpread.CELL), MAX_CELLS of them, the busiest.

const STEP := 0.25
const MAX_BURNING := 900
const MAX_PER_CHUNK := 300
## A flame put to it (lightning, a meteor, a burning piece, a room alight): heat
## on the bricks within this of the point, enough to catch whatever touches air.
## About a coarse cell's reach -- "a building catches" lights a point in a room,
## a stride in from the wall.
const IGNITE_RADIUS := 0.9
## Embers, per burning building per step: how many are tried, how likely each
## is to fly (x flame x spread_mul), and the heat one brings where it lands --
## times how readily the brick takes it (leaves 1.6: two embers light a leaf).
const EMBERS := 6
const EMBER_CHANCE := 0.45
const EMBER_HEAT := 0.4
const EMBER_RADIUS := 0.5
## Buildings out of brick range an ember may materialise, a step: a tree is
## 30 bricks, a tower thousands, and a forest fire would otherwise bring the
## whole forest in at once.
const BRING_IN := 1
## Wind as DisasterContext.gale (0..1.5) to metres a second.
const GALE_MS := 15.0
## Never quite calm: a light breeze, its way rolled from the seed, so fire with
## no storm behind it still leans somewhere.
const BREEZE := 0.12

## [building id, frame, chunk] near a point: city.fire_chunks.
var chunks_near: Callable
## (building id, frame, killed, charred, at): city.fire_burnt.
var burnt: Callable
## (building id) -> bool: still standing in bricks (city.fire_standing).
var standing: Callable
## () -> Vector3: the gale, 0..1.5 (DisasterContext.gale).
var gale: Callable
var world: BrickWorld

## chunk -> [building id, frame]: every chunk with any heat in it.
var _active := {}
## chunk -> [points, power]: its burning bricks at the last step.
var _points := {}
var _breeze := Vector3.ZERO
## Lit since the last step: burning, though no step has said so yet.
var _lit := false
var _bring_in := 0

## Counters for the probe and the HUD.
var burning_bricks := 0
var peak_bricks := 0
var burnt_bricks := 0
var charred_bricks := 0
var embers_landed := 0


func setup(seed_value: int, visuals := true) -> void:
	super.setup(seed_value, visuals)
	var a := rng.randf() * TAU
	_breeze = Vector3(cos(a), 0.0, sin(a)) * BREEZE


## Put a flame to `point`: the bricks round it take enough heat to catch. Tried
## a little lower too -- a strike on a roof lands in the air above the slab.
func ignite(point: Vector3, heat: float) -> bool:
	if world == null or not chunks_near.is_valid():
		return false
	for p in [point, point + Vector3.DOWN * 0.3]:
		var any := false
		for c in chunks_near.call(p, IGNITE_RADIUS + 0.5, true):
			var chunk: int = c[2]
			if world.fire_heat(chunk, p, IGNITE_RADIUS, 1.0 + heat) > 0:
				any = true
				_lit = true
			_active[chunk] = [c[0], c[1]]
		if any:
			return true
	return false


func count() -> int:
	return cells.size()


func is_burning() -> bool:
	return burning_bricks > 0 or _lit


## Out, now: every brick's heat and flame gone.
func douse() -> void:
	_douse = 3.0
	for chunk in _active:
		world.fire_clear(chunk)
	_active.clear()
	_points.clear()
	burning_bricks = 0
	_lit = false
	_rebuild_cells()


func wind() -> Vector3:
	var g: Vector3 = gale.call() if gale.is_valid() else Vector3.ZERO
	return (g + _breeze) * GALE_MS


func tick() -> void:
	_tick += 1
	_douse = maxf(0.0, _douse - 1.0 / Engine.physics_ticks_per_second)
	var slices := maxi(1, int(round(STEP * Engine.physics_ticks_per_second)))
	if _tick % slices == 0 and not _active.is_empty():
		_step_all()
	if cells.is_empty():
		if not _groups.is_empty():
			_groups = []
			smoke_spots = []
			if _visuals:
				for i in _smoke.size():
					_smoke[i].emitting = false
					_lights[i].visible = false
		return
	peak = maxi(peak, cells.size())
	if _visuals:
		_update_visuals()


func _step_all() -> void:
	_bring_in = BRING_IN
	while not loose.is_empty() and _tick - int(loose[0][1]) > LOOSE_TICKS:
		loose.pop_front()
	var w := wind()
	var wet := raining.is_valid() and bool(raining.call())
	var damp := 0.0 if _douse > 0.0 else (0.4 if wet else 1.0)
	var total := 0
	for chunk in _active.keys():
		var owner: Array = _active[chunk]
		if not world.is_chunk_alive(chunk) \
				or (standing.is_valid() and not bool(standing.call(int(owner[0])))):
			# Toppled, or cut up: pieces now, and its fire goes with them
			# (BurningDebris lights the pieces where it was).
			if _points.has(chunk):
				for q in (_points[chunk][0] as PackedVector3Array):
					loose.append([q, _tick])
			world.fire_clear(chunk)
			_active.erase(chunk)
			_points.erase(chunk)
			continue
		var room := clampi(MAX_BURNING - total, 0, MAX_PER_CHUNK)
		if room == 0:
			capped += 1
		var r: Dictionary = world.fire_step(chunk, STEP, w, damp, room)
		var pts: PackedVector3Array = r.points
		var power: PackedFloat32Array = r.power
		var killed: PackedInt32Array = r.killed
		var charred: PackedInt32Array = r.charred
		caught += int(r.caught)
		total += pts.size()
		if (not killed.is_empty() or not charred.is_empty()) and burnt.is_valid():
			burnt.call(int(owner[0]), int(owner[1]), killed, charred,
					pts[0] if not pts.is_empty() else Vector3.ZERO)
		burnt_bricks += killed.size()
		charred_bricks += charred.size()
		chips += killed.size()
		scorches += charred.size()
		for q in (r.loose as PackedVector3Array):
			loose.append([q, _tick])
		if not bool(r.active):
			_active.erase(chunk)
			_points.erase(chunk)
			continue
		_points[chunk] = [pts, power]
		if not pts.is_empty() and damp > 0.0:
			_embers(chunk, pts, power, w, damp)
	burning_bricks = total
	_lit = false
	peak_bricks = maxi(peak_bricks, total)
	_rebuild_cells()
	# Smoke and light gather per cluster, regrouped as the cells are -- the
	# moment a fire has bricks burning, it has smoke over it.
	_regroup()
	if damage.is_valid():
		for c in cells:
			damage.call(c.at, CELL.x, PAWN_DAMAGE * c.heat * STEP / STEP_S)


## A few points off the burning bricks, tossed and carried downwind; whatever
## brick of ANOTHER building they land in takes their heat (a building's own
## bricks heat each other in fire_step).
func _embers(chunk: int, pts: PackedVector3Array, power: PackedFloat32Array, w: Vector3,
		damp: float) -> void:
	for k in mini(EMBERS, pts.size()):
		var i := rng.randi() % pts.size()
		if rng.randf() >= EMBER_CHANCE * power[i] * spread_mul * damp:
			continue
		# Lofted and come down again: anywhere from a little above where it
		# left to a man's height below, a metre about, and downwind.
		var at := pts[i] + Vector3(rng.randf_range(-1.0, 1.0), rng.randf_range(-1.2, 0.8),
				rng.randf_range(-1.0, 1.0)) + w * (0.12 * rng.randf())
		# An ember may bring a building's bricks in (it has nothing to land
		# in otherwise): BRING_IN a step, the rest land only where bricks are.
		for c in chunks_near.call(at, EMBER_RADIUS, _bring_in > 0):
			var other: int = c[2]
			if other == chunk:
				continue
			if world.fire_heat(other, at, EMBER_RADIUS, EMBER_HEAT, true) > 0:
				embers_landed += 1
			if not _active.has(other):
				_active[other] = [c[0], c[1]]
				_bring_in -= 1


## The coarse cells the flames, smoke, light and the AI's danger are drawn on:
## the burning bricks gathered by FireSpread.CELL, the busiest MAX_CELLS of them.
## A cell keeps its flame emitter while it is still burning.
func _rebuild_cells() -> void:
	var by := {}
	for chunk in _points:
		var pts: PackedVector3Array = _points[chunk][0]
		var power: PackedFloat32Array = _points[chunk][1]
		for i in pts.size():
			var k := key_of(pts[i])
			if by.has(k):
				var e: Array = by[k]
				e[0] += pts[i]
				e[1] += 1
				e[2] = maxf(e[2], power[i])
			else:
				by[k] = [pts[i], 1, power[i]]
	var keys := by.keys()
	if keys.size() > MAX_CELLS:
		keys.sort_custom(func(a, b) -> bool: return by[a][1] > by[b][1])
		keys.resize(MAX_CELLS)
	var kept := {}
	var next: Array[Cell] = []
	for k in keys:
		var e: Array = by[k]
		var c: Cell = _by_key.get(k)
		if c == null:
			c = Cell.new()
			c.key = k
			if _visuals and not _free_emitters.is_empty():
				c.emitter = _free_emitters.pop_back()
				c.emitter.emitting = true
		var at: Vector3 = e[0] / float(e[1])
		c.at = at
		c.heat = clampf(float(e[1]) / 3.0, 0.3, 1.0) * float(e[2])
		if c.emitter != null:
			c.emitter.global_position = at + Vector3.DOWN * 0.2
		kept[k] = c
		next.append(c)
	for c in cells:
		if not kept.has(c.key) and c.emitter != null:
			c.emitter.emitting = false
			_free_emitters.append(c.emitter)
			c.emitter = null
	cells = next
	_by_key = kept
