## entity_time.gd
## Per-entity time dilation.
##
## THE reason this exists: `Engine.time_scale` is GLOBAL, and every game planned on
## this stack is 4-player co-op. If one player's execution, Phantom Slice
## (ProceduralCombat §5) or stasis bubble (§6) drops the engine timescale, it slows
## the other three players' worlds too. So time scale is a property of an ENTITY here,
## never of the engine. Retrofitting that later would touch every system that consumes
## delta, which is why the seam goes in before the systems do.
##
## Add a child node named "EntityTime" to anything that can be slowed (players,
## enemies, projectiles, vehicles, titans). Consumers read it with the static helpers,
## which return 1.0 for entities that DON'T have one — so this is opt-in per entity and
## nothing needs changing to keep working:
##
##     delta = EntityTime.delta_for(entity_root, delta)
##
## Sources are NAMED and MULTIPLICATIVE, so overlapping effects compose instead of
## fighting over one float: a stasis bubble (&"stasis" = 0.15) inside a melee hit-stop
## (&"hitstop" = 0.0) resolves to 0.0, and cleanly returns to 0.15 when the hit-stop
## clears — no source has to know what the others did.
##
## Consumers to wire as they land: StatusEffect (done), GaitController,
## ActiveRagdoll PD gains, AnimationTree advance, CharacterBody3D movement,
## projectile integration.
class_name EntityTime
extends Node

## Emitted whenever the effective scale changes. Systems that cache derived values
## (PD gains, animation speeds) should recompute here rather than polling per frame.
signal scale_changed(scale: float)

const NODE_NAME := &"EntityTime"
const META_KEY := &"_cc_entity_time"

## World-wide multiplier, folded into every entity's scale (including entities with
## no EntityTime node). Single-player-only slow-mo can use this instead of
## `Engine.time_scale`, which keeps physics/audio/UI running at real rate.
## In co-op LEAVE THIS AT 1.0 and dilate entities individually.
static var world_scale: float = 1.0

## Baseline for this entity, before any effect sources. Lets a heavy unit run its own
## clock (e.g. a titan reading slower than infantry) without a status effect.
@export var base_scale: float = 1.0:
	set(v):
		base_scale = v
		_recompute()

var _sources: Dictionary = {}   # StringName -> float
var _scale: float = 1.0         # base_scale * product(sources). Excludes world_scale.


func _ready() -> void:
	_recompute()


# --- Read ---

## Effective scale including `world_scale`. 1.0 = real time, 0.0 = fully stopped.
func get_scale() -> float:
	return _scale * world_scale


## This entity's own scale, ignoring `world_scale`.
func get_local_scale() -> float:
	return _scale


func scaled_delta(delta: float) -> float:
	return delta * get_scale()


func is_stopped() -> bool:
	return get_scale() <= 0.0


# --- Write ---

## Add or update a named multiplier. Idempotent — re-setting the same value is free
## and emits nothing, so a per-frame `set_source(&"stasis", 0.15)` from a field
## effect is fine.
func set_source(id: StringName, multiplier: float) -> void:
	var m: float = maxf(multiplier, 0.0)
	if _sources.has(id) and is_equal_approx(float(_sources[id]), m):
		return
	_sources[id] = m
	_recompute()


func clear_source(id: StringName) -> void:
	if _sources.erase(id):
		_recompute()


func has_source(id: StringName) -> bool:
	return _sources.has(id)


## Drop every source (death, respawn, entity returned to a pool).
func clear_all_sources() -> void:
	if _sources.is_empty():
		return
	_sources.clear()
	_recompute()


func _recompute() -> void:
	var s: float = maxf(base_scale, 0.0)
	for v in _sources.values():
		s *= float(v)
	if is_equal_approx(s, _scale):
		return
	_scale = s
	scale_changed.emit(get_scale())


# --- Static helpers (the consumer-facing API) ---

## The entity's EntityTime, or null. Cached on the root — safe to call per frame.
static func of(root: Node) -> EntityTime:
	return ComponentCache.find(root, NODE_NAME, META_KEY) as EntityTime


## Scale for an entity that may not have an EntityTime node. Falls back to
## `world_scale`, so an un-instrumented entity still honours global slow-mo.
static func scale_of(root: Node) -> float:
	var t: EntityTime = of(root)
	return t.get_scale() if t != null else world_scale


## The one-liner every consumer should use.
static func delta_for(root: Node, delta: float) -> float:
	return delta * scale_of(root)
