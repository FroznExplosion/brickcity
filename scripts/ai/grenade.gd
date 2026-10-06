class_name Grenade
extends Node3D
## A soldier's hand grenade (the casebook's "grenade" move, Docs/Tactics).
##
## Thrown in an arc to a point, it lies there FUSE seconds -- long enough to see
## it and run -- then goes off: up to DAMAGE to every body within RADIUS (more
## than half a soldier's or a player's health, never all of it), less with
## distance and none behind bricks; a small blast in the bricks (ordnance,
## StructuralDamage); a bang everyone near hears. While it lies there its ball is
## a danger zone (AIWorld), so soldiers -- the thrower's side too -- get out of it.
## The flight ignores walls: it is lobbed over them, which is the point of it.

const RADIUS := 4.0
const DAMAGE := 60.0
const FUSE := 1.2
## Metres above the straight line at mid flight, and the throw's speed.
const ARC := 2.5
const SPEED := 13.0
## How far the bang is heard.
const HEARD := 45.0
const DANGER_ID_BASE := 700000

static var _next_id := 0

var s: AIServices
var thrower: Pawn
var from := Vector3.ZERO
var to := Vector3.ZERO
var flight := 1.0
var t0 := 0.0
var landed := false
var exploded := false
## [pawn, damage] for each body it hurt, for gates.
var hits: Array = []
var _danger_id := -1

signal went_off(point: Vector3)


static func throw(services: AIServices, by: Pawn, start: Vector3, target: Vector3, parent: Node) -> Grenade:
	var g := Grenade.new()
	g.s = services
	g.thrower = by
	g.from = start
	g.to = target
	g.flight = clampf(start.distance_to(target) / SPEED, 0.5, 1.6)
	g.t0 = services.now()
	var m := MeshInstance3D.new()
	var sphere := SphereMesh.new()
	sphere.radius = 0.07
	sphere.height = 0.14
	m.mesh = sphere
	g.add_child(m)
	parent.add_child(g)
	g.global_position = start
	return g


func _physics_process(_delta: float) -> void:
	if exploded:
		return
	var now := s.now()
	var t := (now - t0) / flight
	if not landed:
		if t < 1.0:
			var p := from.lerp(to, t)
			p.y += ARC * 4.0 * t * (1.0 - t)
			global_position = p
			return
		landed = true
		global_position = to
		_next_id += 1
		_danger_id = DANGER_ID_BASE + _next_id
		var r := Vector3(RADIUS, 1.5, RADIUS)
		s.ai_world.set_danger(_danger_id, AABB(to - Vector3(RADIUS, 0.5, RADIUS), r * 2.0))
	if now - t0 >= flight + FUSE:
		_explode()


func _explode() -> void:
	exploded = true
	if _danger_id >= 0:
		s.ai_world.remove_danger(_danger_id)
	var at := to + Vector3.UP * 0.3
	var done := {}
	for p in s.pawns:
		if not is_instance_valid(p) or p.health == null or p.health.is_dead() or done.has(p):
			continue
		done[p] = true
		var d := p.chest().distance_to(at)
		if d >= RADIUS or not s.ai_world.line_clear(at, p.chest()):
			continue
		var dmg := DAMAGE * (1.0 - d / RADIUS)
		p.health.apply_impact(dmg, &"")
		hits.append([p, dmg])
	if s.on_structure_hit.is_valid():
		s.on_structure_hit.call(to, Vector3.DOWN, StructuralDamage.for_shot(WeaponClass.builtin(&"grenade")))
	s.noise(to, HEARD, thrower)
	went_off.emit(to)
	queue_free()


func _exit_tree() -> void:
	if not exploded and _danger_id >= 0 and s != null:
		s.ai_world.remove_danger(_danger_id)
