class_name EffectContext
extends RefCounted
## Per-hit data handed to effect handlers (EffectDispatch). Carries everything an
## effect needs to spawn secondary damage (splash, ricochet, chains) without knowing
## about the weapon. Reused for the whole on-hit chain of one shot.

var shooter: Node                  ## the gun (for get_tree() / group queries)
var target_root: Node              ## the enemy the bullet directly hit
var hit_point: Vector3
var base_damage: float = 0.0
var crit: bool = false
var crit_mult: float = 1.5
var element: Element               ## null = kinetic
var element_ratio: float = 0.0
var element_chance: float = 1.0
## Gun-mod amplifiers (MANUFACTURER §8): which effects are supercharged, and a flat
## boomer-mod splash fraction applied to every hit.
var supercharges: Dictionary = {}
var universal_splash: float = 0.0
## Per-effect brand-match magnitude (MANUFACTURER §3.5): effect_id -> multiplier.
var effect_mults: Dictionary = {}
## Optional VFX hook: call(from: Vector3, to: Vector3, color: Color) to draw a secondary
## trail (ricochet, chain). The weapon layer supplies it; dispatch stays render-agnostic.
var vfx: Callable = Callable()
## Overkill+ricochet merge: leftover kill damage to bounce onto a random enemy (0 = none).
var overkill_ricochet: float = 0.0
## Where this chain's rolls come from (which enemy a ricochet picks, the procs of the
## secondary hits). Null = DamageSystem.rng. Never the global RNG.
var rng: RandomNumberGenerator
