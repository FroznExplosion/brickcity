## titan_intents.gd
## The one thing a [TitanMotor] consumes. Spec §6.
##
## ─── WHY THIS IS ITS OWN TYPE ──────────────────────────────────────────────────────────
##
## The motor must never know who is driving. The pilot's brain and the AI brain both fill
## one of these and hand it over, so "how a titan moves" is written once and cannot drift
## between piloted and unmanned play (spec §1, locked decision "Locomotion sharing"). If
## the motor ever reads input, a camera or the player, that guarantee is gone — and it
## goes quietly, one convenience at a time.
##
## ─── FRAME CONVENTIONS (the spec leaves these open; pinning them here) ─────────────────
##
## * [member move_dir] is TORSO-LOCAL: `x` = strafe right, `y` = forward. Not camera-local.
##   Spec §6.1: "movement is relative to torso yaw, not camera yaw" — strafing has to feel
##   like driving a chassis, and reading this as camera-local is exactly the mistake that
##   turns a titan back into an FPS body. Magnitude 0..1; the motor normalises anything
##   longer.
## * [member aim_yaw] is a WORLD yaw in radians, matching [PlayerRig]: a yaw of `y` faces
##   `(-sin y, 0, -cos y)`.
## * [member dash] is EDGE-triggered. The motor latches on the rising edge, so a brain that
##   leaves it true does not burn every charge it owns.
##
## Reused rather than reallocated: a brain owns one of these for its lifetime and mutates
## it in place, because this is polled every physics tick for every titan alive.
class_name TitanIntents
extends RefCounted

## Torso-local movement request. x = strafe right, y = forward. Magnitude 0..1.
var move_dir: Vector2 = Vector2.ZERO
## World yaw the torso should chase (piloted: the pilot's look yaw; AI: facing target).
var aim_yaw: float = 0.0
## For future arm/weapon aim. Unused by locomotion — carried so the AI and the pilot keep
## filling the same struct when weapons land.
var aim_pitch: float = 0.0
## Edge-triggered dash request.
var dash: bool = false
## Held.
var sprint: bool = false
## Embark pose request (AI only for now).
var crouch: bool = false


## Back to a standing-still request that still faces `yaw`. Aim is NOT zeroed to 0.0:
## a titan handed a cleared struct would snap its torso to world north.
func clear(yaw: float = 0.0) -> void:
	move_dir = Vector2.ZERO
	aim_yaw = yaw
	dash = false
	sprint = false
	crouch = false
