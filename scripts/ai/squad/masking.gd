class_name Masking
extends RefCounted
## Is a move masked from a threat (Docs/AI.md 6.1)? A mover goes only while it
## is, and holds where it is -- down, still -- the moment it is not. Masked when:
##
##   SUPPRESSED  a squadmate's rounds are landing round the threat;
##   AWAY        the threat is looking elsewhere -- the mover is outside its aim
##               cone -- or it is reloading;
##   OCCLUDED    bricks (DDA) or smoke lie between the threat's eye and the mover.
##
## A threat known only by a noise has no known facing: only suppression and
## occlusion count against it. One DDA and a few dot products: cheap enough to
## ask every physics tick for the one or two agents moving.

## Half the cone a threat is taken to watch, degrees.
const CONE_DEG := 50.0

const NONE := ""
const SUPPRESSED := "suppressed"
const AWAY := "looking away"
const OCCLUDED := "occluded"


## Why `mover` is masked from contact `c`, or NONE.
static func why(s: AIServices, mover: Pawn, c: FactionKnowledge.Contact) -> String:
	if c == null:
		return OCCLUDED
	var t: Pawn = c.pawn if c.pawn != null and is_instance_valid(c.pawn) else null
	if t != null and s.is_suppressed(t):
		return SUPPRESSED
	var eye := t.eye.global_position if t != null else c.pos + Vector3.UP * CoverSearch.STAND_EYE
	var chest := mover.chest()
	if s.ai_world.bricks_between(eye, chest) > 0 or s.ai_world.smoke_blocks(eye, chest):
		return OCCLUDED
	if t != null:
		if t.gun != null and t.gun.is_reloading():
			return AWAY
		var look := -Basis.from_euler(Vector3(t.intents.look_pitch, t.intents.look_yaw, 0.0)).z
		var to := chest - eye
		if to.length() > 0.01 and rad_to_deg(look.angle_to(to.normalized())) > CONE_DEG:
			return AWAY
	return NONE
