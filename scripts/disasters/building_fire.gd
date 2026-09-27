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
	var y := box.position.y + (storey + 0.5) * FireSpread.CELL.y
	var inset := 0.8
	var along := lerpf(0.2, 0.8, w)
	var p: Vector3
	match side:
		0: p = Vector3(box.position.x + inset, y, lerpf(box.position.z, box.end.z, along))
		1: p = Vector3(box.end.x - inset, y, lerpf(box.position.z, box.end.z, along))
		2: p = Vector3(lerpf(box.position.x, box.end.x, along), y, box.position.z + inset)
		_: p = Vector3(lerpf(box.position.x, box.end.x, along), y, box.end.z - inset)
	var step := FireSpread.CELL.x * (Vector3(0, 0, 1) if side < 2 else Vector3(1, 0, 0))
	var any := false
	for i in SPARKS:
		any = ctx.ignite(p + step * (i - SPARKS / 2), 0.6) or any
	if any:
		var out: Vector3 = [Vector3.LEFT, Vector3.RIGHT, Vector3.FORWARD, Vector3.BACK][side]
		lit = {"building": ctx.building_at(p), "point": p, "out": out}
