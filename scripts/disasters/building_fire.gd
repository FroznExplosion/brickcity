class_name BuildingFire
extends Disaster

## "A building catches" (Docs/Disasters.md section 5): fire on its own in the
## roll. A standing building near the player catches on one of its upper
## storeys, and the fire service does the rest.
##
## ACTIVE lasts while the fire does (up to active_s). Shift+H douses it: the
## flames die down over a couple of seconds rather than vanish.

const RANGE := 100.0        ## m from the player the building may be
const SPARKS := 3           ## cells lit side by side

## Where it was lit, for the probe: {building, point}. Empty if nothing caught.
var lit := {}


func _init() -> void:
	title = "Fire"
	warning_s = 3.0
	active_s = 90.0
	ending_s = 3.0


func _on_phase(p: Phase) -> void:
	match p:
		Phase.ACTIVE:
			_light()
		Phase.ENDING:
			if ctx.fire != null:
				ctx.fire.douse()
				ctx.fire.spread_mul = 1.0


func _tick_active(_dt: float) -> void:
	# Over when the fire is -- give it a few seconds to take first.
	if phase_t > 5.0 and (ctx.fire == null or not ctx.fire.is_burning()):
		end_now()


func _light() -> void:
	var player := ctx.player_pos()
	var near: Array[AABB] = []
	for box in ctx.building_boxes():
		var c := box.get_center()
		if Vector2(c.x - player.x, c.z - player.z).length() <= RANGE and box.size.y > FireSpread.CELL.y * 2.0:
			near.append(box)
	# Rolled whatever the city holds, so the rng advances the same way.
	var u := rng.randf()
	var v := rng.randf()
	var w := rng.randf()
	var side := rng.randi_range(0, 3)
	if near.is_empty():
		return
	var box := near[mini(int(u * near.size()), near.size() - 1)]
	# An upper storey, just inside one outer wall: where a fire would be seen.
	var storeys := maxi(1, int(box.size.y / FireSpread.CELL.y))
	var storey := clampi(int(lerpf(storeys * 0.3, storeys - 1, v)), 0, storeys - 1)
	var along := lerpf(0.2, 0.8, w)
	var out: Vector3 = [Vector3.LEFT, Vector3.RIGHT, Vector3.FORWARD, Vector3.BACK][side]
	# Find a real wall: a ray in from outside that face, at that storey -- or,
	# if the building has lost it, the storeys below. The recipe's box says
	# nothing about what is still standing.
	var p := Vector3.INF
	while storey >= 0 and p == Vector3.INF:
		var y := box.position.y + (storey + 0.5) * FireSpread.CELL.y
		var face: Vector3
		match side:
			0: face = Vector3(box.position.x, y, lerpf(box.position.z, box.end.z, along))
			1: face = Vector3(box.end.x, y, lerpf(box.position.z, box.end.z, along))
			2: face = Vector3(lerpf(box.position.x, box.end.x, along), y, box.position.z)
			_: face = Vector3(lerpf(box.position.x, box.end.x, along), y, box.end.z)
		var depth := box.size.x if side < 2 else box.size.z
		var hit := ctx.ray(face + out * 2.0, face - out * depth)
		if not hit.is_empty() and ctx.building_at(hit.position, 0.3) >= 0:
			p = (hit.position as Vector3) - out * 0.8
		storey -= 1
	if p == Vector3.INF:
		return
	var step := FireSpread.CELL.x * (Vector3(0, 0, 1) if side < 2 else Vector3(1, 0, 0))
	var any := false
	# Intensity: more of the storey caught at once, and a fire that spreads
	# harder while this disaster lasts.
	var sparks := maxi(1, int(round(SPARKS * intensity)))
	if ctx.fire != null:
		ctx.fire.spread_mul = intensity
	for i in sparks:
		any = ctx.ignite(p + step * (i - sparks / 2), 0.6) or any
	if any:
		lit = {"building": ctx.building_at(p), "point": p, "out": out}
