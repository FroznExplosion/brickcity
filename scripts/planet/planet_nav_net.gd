class_name PlanetNavNet
extends RefCounted

## Many nav regions on a planet (Docs/Planets.md 11.8, N4). One region is 8 x 8
## terrain tiles (256 studs, 89.6 m): a PlanetNavRegion with its own framed
## AIWorld and AINav, exactly as N2's one region. They lie on a lattice round an
## ANCHOR direction -- cell (i, j) is the gnomonic square (i, j) of the tangent
## plane there, its region the tangent frame at that square's centre -- and each
## is built MARGIN studs wider than its cell, so the cells' borders are inside
## both neighbours' grids.
##
## A border carries PORTALS, points on the ground every PORTAL_STEP metres along
## it. What it costs to walk between two portals of a region (a LEG) is worked
## out in the background, a request at a time per region on its own AINav (whose
## service() slices every search to its budget);
## until then a leg is its straight line times LEG_ESTIMATE. A path whose ends
## are in different regions is an A* over the portals first, then the real
## path a region at a time between the portals it chose, joined end to end. A
## stretch that has no way through closes that leg and the route is planned
## again.
##
## The API is AINav's for paths -- request_path / service / get_status /
## get_path / release, find_path, snap, can_stand -- so a soldier's move_to
## walks it as it walks one region's map. Positions are world positions.
##
## MAPS: who walks it. "person" is the region's own AINav; any other (a size's,
## a mech's, a vehicle kind's -- add_map) is an AINav its maker builds on the
## region's world the first time it is asked for there, with portals checked and
## legs worked out for it alone. map_view(name) is that map as one object with
## AINav's path calls (PlanetNavMap), for whoever drives it.
##
## Regions are made round whoever is fighting (keep_around) and dropped behind
## them. Building proxies go into every region they reach (set_sites).

const REGION_STUDS := 256
const MARGIN_STUDS := 16
const STEP := 4
const PORTAL_STEP := 12.0
const LEG_ESTIMATE := 1.3
## A route's first and last legs (from its ends to a portal), never worked out
## before the route is walked: the straight line times what eight-way steps
## round nothing much cost. Kept near the legs' real ratio, or the route favours
## short end legs and long known ones.
const END_ESTIMATE := 1.08
## A leg's search budget (nodes): across a region and round what is in it.
const LEG_EXPANSIONS := 40000
## Routes planned again after a stretch failed, before the request fails.
const MAX_TRIES := 6
## Buildings this far past a region's edge go into its world too: they are
## outside its walking map, but a sight line from inside it reaches them.
const LINE_REACH := 100.0
## Most regions a single request may make on its way.
const MAX_ROUTE_REGIONS := 64

enum { PENDING = 0, DONE = 1, FAILED = 2, UNKNOWN = 3 }

## One map in one region: its AINav and the legs between the region's portals.
class MapState:
	var nav: AINav
	## Vector2i(a, b), a < b -> metres (INF: no way).
	var legs := {}
	var leg_queue: Array[Vector2i] = []
	## The leg being worked out: its pair and its request on `nav` (-1: none).
	var leg_at := Vector2i(-1, -1)
	var leg_id := -1


class Region:
	var key := Vector2i.ZERO
	var nav_region: PlanetNavRegion
	var world: AIWorld
	## The person's map (maps["person"].nav).
	var nav: AINav
	## Portal ids on its four borders.
	var portals: Array[int] = []
	## map name -> MapState
	var maps := {}
	var made_ms := 0.0


class Req:
	var id := 0
	var map := "person"
	## Where each stretch goes through bricks (a breaching map), joined.
	var breaches := PackedVector3Array()
	var from := Vector3.ZERO
	var to := Vector3.ZERO
	var priority := 0.0
	var max_expansions := 60000
	var status := PENDING
	var path := PackedVector3Array()
	## One region: [nav, its request id].
	var single: Array = []
	## Across regions: the route, as world points, and which region each stretch is in.
	var route: Array[Vector3] = []
	var route_keys: Array[Vector2i] = []
	var route_portals: Array[int] = []
	var stretch := 0
	var stretch_nav: AINav
	var stretch_id := -1
	var tries := 0
	## Metres between one stretch's last point and the next's first: where
	## the regions' frames meet.
	var joins: Array[float] = []
	## Legs this request found closed from its own ends: "s:<portal>" / "g:<portal>".
	var closed := {}


var data: PlanetData
## The planet's node (its transform is the world's frame); null: at the origin.
var planet: Node3D
var anchor := Vector3.UP
var ax := Vector3.RIGHT
var az := Vector3.BACK
## The cell's width, metres.
var cell_m := 0.0
var regions := {}
## id -> {at: planet-local point on the ground, a: Vector2i, b: Vector2i,
## ok: {map: 0 no way across there, 1 a way}, snap: {map: planet-local point
## where both regions stand that map's body}}
var portals := {}
var _border_portals := {}
var _next_portal := 1
## Building boxes: [planet-local centre transform, size].
var sites: Array = []
var _reqs := {}
var _turn := 0
var _next_id := 1
var regions_made := 0
## Build regions' ground grids on worker threads (the game; the grid is most of a
## region's cost: tens of milliseconds on a planet with towns' pads). Off,
## keep_around builds them in the call (probes).
var threaded := false
## key -> [WorkerThreadPool task, {"nr": PlanetNavRegion}]
var _building := {}
var regions_dropped := 0
var legs_done := 0
## find_path's last request: its joins and replans (probes).
var last_joins: Array[float] = []
var last_tries := 0
## service()'s longest call (us) and its parts: builds finished, the regions'
## own queues, routes, legs.
var worst_service_us := 0
var worst_service_parts: Array = [0, 0, 0, 0]


## map name -> Callable(AIWorld) -> AINav
var _makers := {}
var _views := {}


static func make(p_data: PlanetData, p_anchor: Vector3, p_planet: Node3D = null) -> PlanetNavNet:
	var n := PlanetNavNet.new()
	n._makers["person"] = func(w: AIWorld) -> AINav:
		var a := AINav.new()
		a.set_ai_world(w)
		AIServices.use_hierarchy(a)
		return a
	n.data = p_data
	n.planet = p_planet
	n.anchor = p_anchor.normalized()
	# The tangent axes Gravity.tangent_basis and PlanetNavRegion use.
	var ref := Vector3.FORWARD if absf(n.anchor.dot(Vector3.FORWARD)) < 0.9 else Vector3.RIGHT
	n.ax = ref.cross(n.anchor).normalized()
	n.az = n.ax.cross(n.anchor)
	n.cell_m = REGION_STUDS * BrickWorld.get_stud_metres()
	return n


## Building boxes to put into the regions they reach, as proxies: each
## [planet-local transform of its centre, size].
func set_sites(p_sites: Array) -> void:
	sites = p_sites


func _planet_xf() -> Transform3D:
	return planet.global_transform if planet != null else Transform3D.IDENTITY


# --- the lattice ------------------------------------------------------------

## The gnomonic coordinates (metres in the anchor's tangent plane) of a
## planet-local direction; INF on the far hemisphere.
func _plane_of(dir: Vector3) -> Vector2:
	var c := dir.dot(anchor)
	if c <= 0.05:
		return Vector2.INF
	var t := data.radius / c
	return Vector2(dir.dot(ax) * t, dir.dot(az) * t)


func _dir_of(q: Vector2) -> Vector3:
	return (anchor * data.radius + ax * q.x + az * q.y).normalized()


func key_of_local(local: Vector3) -> Vector2i:
	var q := _plane_of(local.normalized())
	if q.x == INF:
		return Vector2i(1 << 30, 1 << 30)
	return Vector2i(roundi(q.x / cell_m), roundi(q.y / cell_m))


## The cell a world point is in.
func key_at(p: Vector3) -> Vector2i:
	return key_of_local(_planet_xf().affine_inverse() * p)


func region_at(p: Vector3) -> Region:
	return regions.get(key_at(p))


func nav_at(p: Vector3, map := "person") -> AINav:
	var r := region_at(p)
	return _ms(r, map).nav if r != null else null


# --- maps ---------------------------------------------------------------------

## Who else walks the net: `maker` builds the map's AINav on a region's world.
func add_map(name: String, maker: Callable) -> void:
	if not _makers.has(name):
		_makers[name] = maker


func has_map(name: String) -> bool:
	return _makers.has(name)


## The map as one object with AINav's path calls (PlanetNavMap).
func map_view(name: String) -> PlanetNavMap:
	if not _views.has(name):
		var v := PlanetNavMap.new()
		v.net = self
		v.map = name
		_views[name] = v
	return _views[name]


## Map `map` in region `r`, made the first time it is asked for there.
func _ms(r: Region, map: String) -> MapState:
	var m: MapState = r.maps.get(map)
	if m != null:
		return m
	m = MapState.new()
	m.nav = (_makers[map] as Callable).call(r.world)
	if not is_nan(r.nav_region.sea_y):
		m.nav.set_water_level(r.nav_region.sea_y)
	for a in r.portals.size():
		for b in range(a + 1, r.portals.size()):
			m.leg_queue.append(Vector2i(r.portals[a], r.portals[b]))
	r.maps[map] = m
	return m


## Something changed here (world box): every region's every map forgets it.
func invalidate_box(box: AABB, map := "") -> void:
	for r in regions.values():
		for name in (r as Region).maps:
			if map == "" or name == map:
				((r as Region).maps[name] as MapState).nav.invalidate_box(box)


func world_at(p: Vector3) -> AIWorld:
	var r := region_at(p)
	return r.world if r != null else null


# --- regions ----------------------------------------------------------------

## Make the region of cell `k` if there is none; returns it. Its grid being
## built on a thread, waits for that.
func ensure(k: Vector2i) -> Region:
	if regions.has(k):
		return regions[k]
	if _building.has(k):
		var b: Array = _building[k]
		WorkerThreadPool.wait_for_task_completion(int(b[0]))
		_building.erase(k)
		return _finish(k, (b[1] as Dictionary).nr, 0.0)
	var t0 := Time.get_ticks_usec()
	var nr := _grid(k)
	return _finish(k, nr, (Time.get_ticks_usec() - t0) / 1000.0)


func _grid(k: Vector2i) -> PlanetNavRegion:
	return PlanetNavRegion.make(data, _dir_of(Vector2(k) * cell_m), REGION_STUDS + 2 * MARGIN_STUDS, STEP)


## Start building cell `k`'s grid on a worker thread.
func _start_build(k: Vector2i) -> void:
	if regions.has(k) or _building.has(k):
		return
	var box := {"nr": null}
	var task := WorkerThreadPool.add_task(func() -> void: box.nr = _grid(k), false, "nav region")
	_building[k] = [task, box]


## Finish the grids built since: at most `max_n`.
func _collect_builds(max_n: int) -> void:
	var n := 0
	for k in _building.keys():
		if n >= max_n:
			return
		var b: Array = _building[k]
		if not WorkerThreadPool.is_task_completed(int(b[0])):
			continue
		WorkerThreadPool.wait_for_task_completion(int(b[0]))
		_building.erase(k)
		if not regions.has(k):
			_finish(k, (b[1] as Dictionary).nr, 0.0)
		n += 1


func regions_building() -> int:
	return _building.size()


## The region round a grid built: its framed world, its proxies, its nav.
func _finish(k: Vector2i, nr: PlanetNavRegion, grid_ms: float) -> Region:
	var t0 := Time.get_ticks_usec()
	var r := Region.new()
	r.key = k
	r.nav_region = nr
	r.world = AIWorld.new()
	r.world.set_world(BrickWorld.new())
	r.world.set_frame(_planet_xf() * nr.frame)
	r.world.set_ground_grid(Vector2(-nr.half, -nr.half), nr.step_m, nr.size, nr.heights)
	r.world.set_terrain_ground(true)
	var inv := nr.frame.affine_inverse()
	var n := 0
	for s in sites:
		var xf: Transform3D = s[0]
		var size: Vector3 = s[1]
		var l := inv * xf.origin
		var reach := nr.half + LINE_REACH + Vector2(size.x, size.z).length() * 0.5
		if absf(l.x) > reach or absf(l.z) > reach:
			continue
		r.world.set_proxy(n, _planet_xf() * xf, size, 1.0 / BrickWorld.get_stud_metres())
		n += 1
	r.world.sync()
	for side in 4:
		for pid in _border(k, side):
			r.portals.append(pid)
	r.nav = _ms(r, "person").nav
	regions[k] = r
	regions_made += 1
	_relink(k)
	var xf := _planet_xf()
	for id in _dangers:
		var box: AABB = xf * (_dangers[id] as AABB)
		if _reaches(r, box):
			r.world.set_danger(id, box)
	r.made_ms = grid_ms + (Time.get_ticks_usec() - t0) / 1000.0
	return r


func drop(k: Vector2i) -> void:
	if regions.erase(k):
		regions_dropped += 1
		_relink(k)


## Each region of `k` and its eight neighbours told who its neighbours are now
## (AIWorld.set_peers: the ground a sight line passes over off its own grid).
func _relink(k: Vector2i) -> void:
	for di in range(-1, 2):
		for dj in range(-1, 2):
			var c := k + Vector2i(di, dj)
			var r: Region = regions.get(c)
			if r == null:
				continue
			var peers: Array = []
			for ei in range(-1, 2):
				for ej in range(-1, 2):
					var o: Region = regions.get(c + Vector2i(ei, ej))
					if o != null and o != r:
						peers.append(o.world)
			r.world.set_peers(peers)


# --- danger -------------------------------------------------------------------

## id -> AABB, planet-local: what set_danger was given, for regions made later.
var _dangers := {}


## A danger box (world) in every region it reaches -- and in any made later --
## so a grenade by a border is avoided from both sides (AIWorld.set_danger).
func set_danger(id: int, box: AABB) -> void:
	_dangers[id] = _planet_xf().affine_inverse() * box
	for r in regions.values():
		if _reaches(r, box):
			(r as Region).world.set_danger(id, box)
		else:
			(r as Region).world.remove_danger(id)


func remove_danger(id: int) -> void:
	_dangers.erase(id)
	for r in regions.values():
		(r as Region).world.remove_danger(id)


func _reaches(r: Region, box: AABB) -> bool:
	var l := r.nav_region.frame.affine_inverse() * (_planet_xf().affine_inverse() * box.get_center())
	var reach := r.nav_region.half + box.size.length() * 0.5
	return absf(l.x) <= reach and absf(l.z) <= reach


## Regions round every point in `points` (world) within `radius` metres made,
## and those further than twice that from all of them dropped -- but never one
## a request in hand is walking. At most `max_new` made a call (each is a few
## tens of milliseconds).
func keep_around(points: Array, radius: float, max_new := 1) -> void:
	var want := {}
	var inv := _planet_xf().affine_inverse()
	var reach := int(ceil(radius / cell_m))
	var centres: Array[Vector2] = []
	for p in points:
		var q := _plane_of((inv * (p as Vector3)).normalized())
		if q.x == INF:
			continue
		centres.append(q)
		var c := Vector2i(roundi(q.x / cell_m), roundi(q.y / cell_m))
		for di in range(-reach, reach + 1):
			for dj in range(-reach, reach + 1):
				var k := c + Vector2i(di, dj)
				if (Vector2(k) * cell_m).distance_to(q) <= radius + cell_m * 0.71:
					want[k] = true
	var made := 0
	for k in want:
		if regions.has(k):
			continue
		if threaded:
			_start_build(k)
		elif made < max_new:
			ensure(k)
			made += 1
	var busy := {}
	for rq in _reqs.values():
		for k in (rq as Req).route_keys:
			busy[k] = true
	for k in regions.keys():
		if want.has(k) or busy.has(k):
			continue
		var far := true
		for q in centres:
			if (Vector2(k) * cell_m).distance_to(q) <= 2.0 * radius + cell_m:
				far = false
				break
		if far:
			drop(k)


## A translation-only re-centre (PlanetFrame) moved the scene by `offset`.
func shift_origin(offset: Vector3) -> void:
	for r in regions.values():
		(r as Region).world.shift_origin(offset)


# --- portals ----------------------------------------------------------------

## Portal ids on side `side` of cell `k` (0 +x, 1 -x, 2 +z, 3 -z), made the
## first time either neighbour asks.
func _border(k: Vector2i, side: int) -> Array:
	# A border is named by its lower cell and its axis.
	var lo := k
	var axis := 0
	match side:
		0:
			axis = 0
		1:
			lo = k - Vector2i(1, 0)
			axis = 0
		2:
			axis = 1
		3:
			lo = k - Vector2i(0, 1)
			axis = 1
	var bk := Vector3i(lo.x, lo.y, axis)
	if _border_portals.has(bk):
		return _border_portals[bk]
	var ids: Array = []
	var hi := lo + (Vector2i(1, 0) if axis == 0 else Vector2i(0, 1))
	var n := maxi(1, int(floor(cell_m / PORTAL_STEP)))
	for i in n:
		var along := (float(i) + 0.5) / float(n) - 0.5
		var q: Vector2
		if axis == 0:
			q = Vector2((lo.x + 0.5) * cell_m, (lo.y + along) * cell_m)
		else:
			q = Vector2((lo.x + along) * cell_m, (lo.y + 0.5) * cell_m)
		var pid := _next_portal
		_next_portal += 1
		portals[pid] = {"at": data.surface_point(_dir_of(q)), "a": lo, "b": hi, "ok": {}, "snap": {}}
		ids.append(pid)
	_border_portals[bk] = ids
	return ids


## Where portal `pid` is crossed on `map`: where both regions stand its body,
## once looked at (portal_ok); its point on the ground until then.
func portal_world(pid: int, map := "person") -> Vector3:
	var p: Dictionary = portals[pid]
	var at: Vector3 = (p.snap as Dictionary).get(map, p.at)
	return _planet_xf() * at


## Can a body cross at portal `pid`? Both its regions must stand it at one
## place: a portal in a wall that runs along the border snaps to one side in
## one region and the other side in the other, and the join would go through
## it. Looked at once both regions are there; until then, maybe (true).
const PORTAL_AGREE := 0.5


func portal_ok(pid: int, map := "person") -> bool:
	var p: Dictionary = portals[pid]
	var ok: Dictionary = p.ok
	if ok.has(map):
		return int(ok[map]) == 1
	var ra: Region = regions.get(p.a)
	var rb: Region = regions.get(p.b)
	if ra == null or rb == null:
		return true
	var w := _planet_xf() * (p.at as Vector3)
	var na := _ms(ra, map).nav
	var nb := _ms(rb, map).nav
	var sa := na.snap(w)
	var sb := nb.snap(w)
	# A wider body's snap may sit further off the line; the two must still agree.
	var good := na.can_stand(sa) and nb.can_stand(sb) and sa.distance_to(sb) <= PORTAL_AGREE \
			and sa.distance_to(w) <= 2.0 + na.get_span() * BrickWorld.get_stud_metres()
	ok[map] = 1 if good else 0
	if good:
		(p.snap as Dictionary)[map] = _planet_xf().affine_inverse() * sa
	return good


## The leg between two portals of region `r`: metres, worked out or estimated.
func _leg(r: Region, a: int, b: int, map: String) -> float:
	var k := Vector2i(mini(a, b), maxi(a, b))
	var m := _ms(r, map)
	if m.legs.has(k):
		return m.legs[k]
	return (portals[a].at as Vector3).distance_to(portals[b].at) * LEG_ESTIMATE


## Below every path a soldier asks for: legs are spare-time work.
const LEG_PRIORITY := -100.0


func _work_legs(until_usec: int) -> void:
	for r in regions.values():
		for name in (r as Region).maps:
			var m: MapState = (r as Region).maps[name]
			if m.leg_id >= 0:
				var st := m.nav.get_status(m.leg_id)
				if st == AINav.PENDING:
					continue
				var p := m.nav.get_path(m.leg_id)
				m.legs[m.leg_at] = _length(p) if st == AINav.DONE and p.size() > 1 else INF
				m.nav.release(m.leg_id)
				m.leg_id = -1
				legs_done += 1
			while not m.leg_queue.is_empty() and Time.get_ticks_usec() < until_usec:
				var k: Vector2i = m.leg_queue.pop_back()
				if not portal_ok(k.x, name) or not portal_ok(k.y, name):
					m.legs[k] = INF
					continue
				m.leg_at = k
				m.leg_id = m.nav.request_path(portal_world(k.x, name), portal_world(k.y, name),
						LEG_PRIORITY, LEG_EXPANSIONS)
				break


func legs_pending(map := "") -> int:
	var n := 0
	for r in regions.values():
		for name in (r as Region).maps:
			if map != "" and name != map:
				continue
			var m: MapState = (r as Region).maps[name]
			n += m.leg_queue.size() + (1 if m.leg_id >= 0 else 0)
	return n


static func _length(p: PackedVector3Array) -> float:
	var s := 0.0
	for i in range(1, p.size()):
		s += p[i].distance_to(p[i - 1])
	return s


# --- paths ------------------------------------------------------------------

func request_path(from: Vector3, to: Vector3, priority: float, max_expansions := 60000,
		map := "person") -> int:
	var rq := Req.new()
	rq.map = map
	rq.id = _next_id
	_next_id += 1
	rq.from = from
	rq.to = to
	rq.priority = priority
	rq.max_expansions = max_expansions
	var ka := key_at(from)
	if ka == key_at(to) and regions.has(ka):
		var sn := _ms(regions[ka], map).nav
		rq.single = [sn, sn.request_path(from, to, priority, max_expansions)]
		rq.route_keys.append(ka)
	_reqs[rq.id] = rq
	return rq.id


func get_status(id: int) -> int:
	var rq: Req = _reqs.get(id)
	if rq == null:
		return UNKNOWN
	if not rq.single.is_empty():
		return (rq.single[0] as AINav).get_status(int(rq.single[1]))
	return rq.status


func get_path(id: int) -> PackedVector3Array:
	var rq: Req = _reqs.get(id)
	if rq == null:
		return PackedVector3Array()
	if not rq.single.is_empty():
		return (rq.single[0] as AINav).get_path(int(rq.single[1]))
	return rq.path if rq.status == DONE else PackedVector3Array()


## Where a breaching map's path goes through bricks (AINav.get_breaches).
func get_breaches(id: int) -> PackedVector3Array:
	var rq: Req = _reqs.get(id)
	if rq == null:
		return PackedVector3Array()
	if not rq.single.is_empty():
		return (rq.single[0] as AINav).get_breaches(int(rq.single[1]))
	return rq.breaches


func release(id: int) -> void:
	var rq: Req = _reqs.get(id)
	if rq == null:
		return
	if not rq.single.is_empty():
		(rq.single[0] as AINav).release(int(rq.single[1]))
	elif rq.stretch_nav != null and rq.stretch_id >= 0:
		rq.stretch_nav.release(rq.stretch_id)
	_reqs.erase(id)


func pending() -> int:
	var n := 0
	for id in _reqs:
		if get_status(id) == PENDING:
			n += 1
	return n


## A path now, serviced until it is done (probes, set-up).
func find_path(from: Vector3, to: Vector3, max_expansions := 60000, map := "person") -> PackedVector3Array:
	var id := request_path(from, to, 1.0, max_expansions, map)
	var t0 := Time.get_ticks_msec()
	while get_status(id) == PENDING and Time.get_ticks_msec() - t0 < 20000:
		_advance(_reqs[id], Time.get_ticks_usec() + 1000000, true)
		for r in regions.values():
			for name in (r as Region).maps:
				((r as Region).maps[name] as MapState).nav.service(100000)
	var p := get_path(id)
	var rq: Req = _reqs.get(id)
	last_joins = rq.joins if rq != null else ([] as Array[float])
	last_tries = rq.tries if rq != null else 0
	release(id)
	return p


## A point's own region's map, the region made if there is none yet (a goal
## sent far off: a few tens of milliseconds, once).
func _nav_made(p: Vector3, map: String) -> AINav:
	var k := key_at(p)
	if k.x == 1 << 30:
		return null
	return _ms(ensure(k), map).nav


func snap(p: Vector3, map := "person") -> Vector3:
	var n := _nav_made(p, map)
	return n.snap(p) if n != null else p


func can_stand(p: Vector3, map := "person") -> bool:
	var n := _nav_made(p, map)
	return n != null and n.can_stand(p)


## Work everything for up to `budget_usec`: each region's own queue, the
## routes in hand, then the legs not worked out yet. Returns requests finished.
func service(budget_usec: int) -> int:
	var t0 := Time.get_ticks_usec()
	var until := t0 + maxi(budget_usec, 0)
	_collect_builds(1)
	var t1 := Time.get_ticks_usec()
	# The regions with work, in turn from a different one each call, each
	# given what is left: AINav keeps to the budget it is given.
	var navs: Array[AINav] = []
	for r in regions.values():
		for name in (r as Region).maps:
			navs.append(((r as Region).maps[name] as MapState).nav)
	for i in navs.size():
		var left := until - Time.get_ticks_usec()
		if left <= 0:
			break
		var nv := navs[(_turn + i) % navs.size()]
		if nv.pending() > 0:
			nv.service(maxi(100, left / 2))
	_turn += 1
	var t2 := Time.get_ticks_usec()
	var finished := 0
	var order := _reqs.values()
	order.sort_custom(func(x: Req, y: Req) -> bool: return x.priority > y.priority)
	for rq in order:
		if Time.get_ticks_usec() >= until:
			break
		if (rq as Req).single.is_empty() and (rq as Req).status == PENDING:
			_advance(rq, until, false)
			if (rq as Req).status != PENDING:
				finished += 1
	var t3 := Time.get_ticks_usec()
	_work_legs(until)
	var t4 := Time.get_ticks_usec()
	if t4 - t0 > worst_service_us:
		worst_service_us = t4 - t0
		worst_service_parts = [t1 - t0, t2 - t1, t3 - t2, t4 - t3]
	return finished


## One request on: plan its route if it has none, then its stretches in turn.
func _advance(rq: Req, until_usec: int, sync: bool) -> void:
	while rq.status == PENDING and Time.get_ticks_usec() < until_usec:
		if rq.route.is_empty():
			var planned := _plan(rq)
			if planned == 0:
				rq.status = FAILED
			elif planned < 0 and not sync:
				return
			continue
		if rq.stretch_id < 0:
			var k := rq.route_keys[rq.stretch]
			var r: Region = regions.get(k)
			if r == null:
				r = ensure(k)
			rq.stretch_nav = _ms(r, rq.map).nav
			rq.stretch_id = rq.stretch_nav.request_path(rq.route[rq.stretch], rq.route[rq.stretch + 1],
					rq.priority, rq.max_expansions)
		var st := rq.stretch_nav.get_status(rq.stretch_id)
		if st == AINav.PENDING:
			if sync:
				rq.stretch_nav.service(100000)
				continue
			return
		var piece := rq.stretch_nav.get_path(rq.stretch_id)
		var cuts := rq.stretch_nav.get_breaches(rq.stretch_id)
		rq.stretch_nav.release(rq.stretch_id)
		rq.stretch_id = -1
		if st != AINav.DONE or piece.size() < 2:
			_close(rq)
			rq.tries += 1
			rq.route.clear()
			rq.path = PackedVector3Array()
			rq.breaches = PackedVector3Array()
			if rq.tries >= MAX_TRIES:
				rq.status = FAILED
			continue
		if not rq.path.is_empty():
			rq.joins.append(rq.path[rq.path.size() - 1].distance_to(piece[0]))
		var start := 0 if rq.path.is_empty() else 1
		for i in range(start, piece.size()):
			rq.path.append(piece[i])
		rq.breaches.append_array(cuts)
		rq.stretch += 1
		if rq.stretch >= rq.route.size() - 1:
			rq.status = DONE


## The stretch that failed: close its leg, for this request (an end) or for
## everyone (two portals).
func _close(rq: Req) -> void:
	var i := rq.stretch
	var last := rq.route.size() - 2
	if i == 0:
		rq.closed["s:%d" % rq.route_portals[0]] = true
	elif i == last:
		rq.closed["g:%d" % rq.route_portals[rq.route_portals.size() - 1]] = true
	else:
		var a := rq.route_portals[i - 1]
		var b := rq.route_portals[i]
		var r: Region = regions.get(rq.route_keys[i])
		if r != null:
			_ms(r, rq.map).legs[Vector2i(mini(a, b), maxi(a, b))] = INF


## A* over the portals between the request's ends: 1 planned, 0 no way, -1
## not yet. Regions along the straight line between them (and either side of
## it) are made first, MAKE_PER_PLAN a call, so a long route is not one hitch.
const MAKE_PER_PLAN := 2


func _plan(rq: Req) -> int:
	var ka := key_at(rq.from)
	var kb := key_at(rq.to)
	if ka.x == 1 << 30 or kb.x == 1 << 30:
		return 0
	# The corridor: every cell the straight line passes, and its neighbours.
	var steps := maxi(1, int(ceil(Vector2(kb - ka).length() * 2.0)))
	var corridor := {}
	for s in steps + 1:
		var c := Vector2(ka).lerp(Vector2(kb), float(s) / float(steps))
		for di in range(-1, 2):
			for dj in range(-1, 2):
				corridor[Vector2i(roundi(c.x), roundi(c.y)) + Vector2i(di, dj)] = true
	if corridor.size() > MAX_ROUTE_REGIONS:
		return 0
	var made := 0
	if threaded:
		_collect_builds(MAKE_PER_PLAN)
	for k in corridor:
		if not regions.has(k):
			if threaded:
				_start_build(k)
				made += 1
				continue
			if made >= MAKE_PER_PLAN:
				return -1
			ensure(k)
			made += 1
	if made > 0:
		return -1
	rq.route_keys.clear()
	rq.route_portals.clear()
	rq.stretch = 0
	if ka == kb:
		rq.route = [rq.from, rq.to] as Array[Vector3]
		rq.route_keys.append(ka)
		return 1
	var ra: Region = regions[ka]
	var map := rq.map
	# Nodes: portal ids; the start is 0, the goal -1.
	var g := {0: 0.0}
	var parent := {}
	# The region each node was reached through: its stretch's region.
	var via := {}
	var open: Array = []
	_push(open, _h(rq.from, rq.to), 0)
	var done := {}
	var best_goal := INF
	var goal_parent := -2
	while not open.is_empty():
		var cur: Array = _pop(open)
		var n: int = cur[1]
		if done.has(n):
			continue
		if float(cur[0]) >= best_goal:
			break
		done[n] = true
		var here := rq.from if n == 0 else portal_world(n, map)
		var gn: float = g[n]
		# Into the goal: from a portal of the goal's region.
		if n != 0 and _in_region(n, kb) and not rq.closed.has("g:%d" % n):
			var c := gn + here.distance_to(rq.to) * END_ESTIMATE
			if c < best_goal:
				best_goal = c
				goal_parent = n
		var nexts: Array = []
		if n == 0:
			for pid in ra.portals:
				if not rq.closed.has("s:%d" % pid) and portal_ok(pid, map):
					nexts.append([pid, rq.from.distance_to(portal_world(pid, map)) * END_ESTIMATE, ka])
		else:
			for side_key in [portals[n].a, portals[n].b]:
				var r: Region = regions.get(side_key)
				if r == null:
					continue
				for pid in r.portals:
					if pid == n or not portal_ok(pid, map):
						continue
					var c := _leg(r, n, pid, map)
					if c < INF:
						nexts.append([pid, c, side_key])
		for e in nexts:
			var m: int = e[0]
			var gm: float = gn + float(e[1])
			if gm < float(g.get(m, INF)):
				g[m] = gm
				parent[m] = n
				via[m] = e[2]
				_push(open, gm + _h(portal_world(m, map), rq.to), m)
	if goal_parent == -2:
		return 0
	var chain: Array[int] = []
	var at := goal_parent
	while at != 0:
		chain.push_front(at)
		at = parent[at]
	rq.route = [rq.from] as Array[Vector3]
	rq.route_portals = chain
	for i in chain.size():
		rq.route.append(portal_world(chain[i], map))
		rq.route_keys.append(via[chain[i]])
	rq.route.append(rq.to)
	rq.route_keys.append(kb)
	return 1


func _in_region(pid: int, k: Vector2i) -> bool:
	return portals[pid].a == k or portals[pid].b == k


static func _h(a: Vector3, b: Vector3) -> float:
	return a.distance_to(b)


## A binary heap of [f, node] for the route search, least f on top.
static func _push(heap: Array, f: float, n: int) -> void:
	heap.append([f, n])
	var i := heap.size() - 1
	while i > 0:
		var up := (i - 1) / 2
		if float(heap[up][0]) <= f:
			break
		heap[i] = heap[up]
		i = up
	heap[i] = [f, n]


static func _pop(heap: Array) -> Array:
	var top: Array = heap[0]
	var last: Array = heap.pop_back()
	if heap.is_empty():
		return top
	var i := 0
	var n := heap.size()
	while true:
		var c := 2 * i + 1
		if c >= n:
			break
		if c + 1 < n and float(heap[c + 1][0]) < float(heap[c][0]):
			c += 1
		if float(heap[c][0]) >= float(last[0]):
			break
		heap[i] = heap[c]
		i = c
	heap[i] = last
	return top
