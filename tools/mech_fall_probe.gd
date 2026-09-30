extends SceneTree

## Acceptance probe for the fall rule (Docs/AI.md 3.11, A12; AIPlan P7).
##
##     godot --headless --path . --script tools/mech_fall_probe.gd
##
## Three towers of five storeys -- walls six courses high, floors of 10x10 plates
## on the walls and on four posts -- and a mech dropped onto each roof:
##
##   from 5 bricks     it lands: nothing breaks
##   from 6 bricks     it breaks the roof and stops on the next floor down
##   from 12 bricks    it breaks three floors and stops on the fourth down
##
## Every break is a command (SHEAR, whole) in a log; a client building the same
## towers and applying the log has the same blocks let go.

const Arena := preload("res://tools/ai_arena.gd")
const STOREYS := 5
## Plates per storey: six courses of wall and the floor plate on them.
const WALL_PLATES := 18
const STOREY_PLATES := 19
const SIZE := 30
const LIMIT := 30 * 12

var _pass := 0
var _fail := 0
var a: Arena
var log := DamageLog.new()
var drops := [5.0, 6.0, 12.0]
var towers: Array[int] = []
var mechs: Array[Mech] = []
var _settled := {}
var _tick := 0


func _init() -> void:
	print("mech fall probe")
	a = Arena.new(self, 3)
	physics_frame.connect(_on_tick)


func _ok(what: String, cond: bool, detail: String = "") -> void:
	if cond:
		_pass += 1
		print("  ok   %s%s" % [what, ("  " + detail) if detail else ""])
	else:
		_fail += 1
		print("  FAIL %s%s" % [what, (" -- " + detail) if detail else ""])


## A tower at cell x `ox` in `w`: its chunk. Walls one stud thick round SIZE x
## SIZE studs, four posts under the middle floor plate, floors of plate_10x10.
static func build_tower(w: BrickWorld, palette: Dictionary, ox: int) -> int:
	var c := w.create_chunk(Vector3i(ox, 0, 0), Vector3i(SIZE, STOREYS * STOREY_PLATES + 1, SIZE))
	var brick: int = palette["brick_1x1"]
	var plate: int = palette["plate_10x10"]
	for s in STOREYS:
		var base := s * STOREY_PLATES
		for course in WALL_PLATES / 3:
			var y := base + course * 3
			for i in SIZE:
				for at in [Vector3i(i, y, 0), Vector3i(i, y, SIZE - 1),
						Vector3i(0, y, i), Vector3i(SIZE - 1, y, i)]:
					if w.block_at(c, Vector3i(ox, 0, 0) + at) < 0:
						w.place_block(c, Vector3i(ox, 0, 0) + at, brick, 4)
			for post in [Vector3i(10, y, 10), Vector3i(19, y, 10), Vector3i(10, y, 19),
					Vector3i(19, y, 19)]:
				w.place_block(c, Vector3i(ox, 0, 0) + post, brick, 2)
		for px in 3:
			for pz in 3:
				w.place_block(c, Vector3i(ox + px * 10, base + WALL_PLATES, pz * 10), plate, 6)
	w.set_chunk_anchored(c, true)
	w.set_tension_per_stud(c, 9.3)
	return c


## The top of floor `k` (1 = the first floor up, STOREYS = the roof), metres.
static func floor_top(k: int) -> float:
	return ((k - 1) * STOREY_PLATES + WALL_PLATES + 1) * Arena.PLATE


func _build() -> void:
	for i in drops.size():
		var ox := i * 60
		var c := build_tower(a.w, a.palette, ox)
		var body := StaticBody3D.new()
		body.collision_layer = Layers.STRUCTURE
		var built: Dictionary = a.w.add_chunk_shapes(body.get_rid(), c, Vector3.ZERO, false)
		body.transform = a.w.get_chunk_transform(c)
		root.add_child(body)
		a.chunks.append(c)
		a._shapes[c] = [body.get_rid(), built.map]
		a.w.solve_stress(c)
		towers.append(c)
	a.s.ai_world.sync()
	for i in drops.size():
		var feet := Vector3((i * 60 + 15) * Arena.STUD, floor_top(STOREYS) + float(drops[i]) * FallRule.BRICK + 0.02,
				15 * Arena.STUD)
		var m := Mech.spawn(root, feet, 0.0, 1)
		m.fall.floor_at = _floor_at
		m.fall.on_break = _break
		m.fall.next_floor = _next_floor
		mechs.append(m)


## What a foot stands on: a brick of a tower is a floor, T = 6.
func _floor_at(feet: Vector3) -> Dictionary:
	var v := a.s.ai_world.block_at(feet - Vector3.UP * 0.07)
	if v.x < 0:
		return {}
	return {"chunk": v.x, "t": FallRule.T}


## The top of the first solid thing under `from`, straight down.
func _next_floor(from: Vector3) -> float:
	var p := from
	while p.y > -1.0:
		if a.s.ai_world.solid_at(p):
			return (floorf(p.y / Arena.PLATE) + 1.0) * Arena.PLATE
		p.y -= Arena.PLATE * 0.5
	return 0.0


## The host breaks the floor: a command, applied here and logged for the client.
func _break(point: Vector3, radius: float, fl: Dictionary) -> void:
	var e := DamageLog.Entry.new()
	e.kind = DamageLog.Kind.SHEAR
	e.target = int(fl.chunk)
	e.point = point
	e.radius = radius
	e.limit = 48
	e.flags = DamageLog.FLAG_WHOLE
	var gone := DamageLog.apply_entry(a.w, int(fl.chunk), e)
	a._disable(int(fl.chunk), gone)
	a.s.ai_world.sync()
	log.add(e)


func _on_tick() -> void:
	_tick += 1
	if _tick == 1:
		_build()
		return
	a.s.ai_world.sync()
	var all := true
	for i in mechs.size():
		var m := mechs[i]
		if m.body.is_on_floor() and not m.fall.is_carrying():
			_settled[i] = int(_settled.get(i, 0)) + 1
		else:
			_settled[i] = 0
		if int(_settled[i]) < 30:
			all = false
	if all or _tick >= LIMIT:
		_finish()


## Which floor the feet are on: 0 the ground, STOREYS the roof, -1 between.
func _floor_of(y: float) -> int:
	if y < 0.2:
		return 0
	for k in range(1, STOREYS + 1):
		if absf(y - floor_top(k)) < 0.3:
			return k
	return -1


func _finish() -> void:
	physics_frame.disconnect(_on_tick)
	var want := [0, 1, 3]
	for i in mechs.size():
		var m := mechs[i]
		var on := _floor_of(m.feet().y)
		var judged := m.fall.landings.map(func(l): return "%.1f%s" % [float(l[1]), "!" if l[2] else ""])
		_ok("dropped from %d bricks it breaks %d floor(s) and stops on floor %d" % [int(drops[i]),
				want[i], STOREYS - want[i]],
				m.fall.breaks == want[i] and on == STOREYS - want[i],
				"%d broken, on floor %d; landings in bricks of energy %s" % [m.fall.breaks, on, judged])
	# The client: the same towers, the log applied.
	var w2 := BrickWorld.new()
	var pal2 := TowerRecipe.bake_palette(w2)
	var twin: Array[int] = []
	for i in drops.size():
		twin.append(build_tower(w2, pal2, i * 60))
	for e in log.entries:
		DamageLog.apply_entry(w2, twin[towers.find(e.target)], e)
	var same := 0
	var total := 0
	var broken := 0
	for i in towers.size():
		var n := a.w.get_block_count(towers[i])
		for b in n:
			total += 1
			var hb := a.w.is_support_broken(towers[i], b)
			if hb:
				broken += 1
			if hb == w2.is_support_broken(twin[i], b):
				same += 1
	_ok("a client applying the log lets the same blocks go", same == total and broken > 0,
			"%d of %d blocks agree, %d let go, %d command(s)" % [same, total, broken, log.entries.size()])
	print("\n%d passed, %d failed" % [_pass, _fail])
	quit(1 if _fail > 0 else 0)
