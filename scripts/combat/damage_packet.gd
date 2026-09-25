## damage_packet.gd
## Transient, per-hit data. RefCounted (not a Resource) — created and discarded
## each shot. Carries everything DamageSystem needs to resolve one impact.
class_name DamagePacket
extends RefCounted

var amount: float = 0.0
var element: Element
var source: Node
var hit_position: Vector3 = Vector3.ZERO
var hit_normal: Vector3 = Vector3.ZERO
var crit: bool = false

## Multiplies base_status_chance for this specific shot (from the weapon).
var element_chance: float = 1.0

## Fraction of `amount` dealt as ELEMENTAL damage (SPEC Amendment A.1); the rest is
## kinetic. 0 = pure kinetic. Set from the gun's element_ratio (barrel family). If
## `element` is null this is ignored (fully kinetic).
var element_ratio: float = 0.0

## Crit damage multiplier applied when `crit` is true (from the gun's crit_mult).
var crit_multiplier: float = 1.5

## The generator this hit's rolls draw from (the status proc). Null = DamageSystem.rng.
## Never the global RNG: in co-op the host rolls, and a roll only the host can repeat
## is a roll only the host may make (brickcity Docs/Multiplayer.md, D9).
var rng: RandomNumberGenerator


func _init(p_amount: float = 0.0, p_element: Element = null, p_source: Node = null) -> void:
	amount = p_amount
	element = p_element
	source = p_source
