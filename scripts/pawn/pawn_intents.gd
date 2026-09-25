class_name PawnIntents
extends RefCounted
## What a pawn has been asked to do this tick. The only thing Pawn's motor reads.
##
## BoomerBorder's one idea worth taking (Docs/Reference/boomer-border.md section 2):
## a brain FILLS this and a motor READS it, and the motor never knows which brain
## it has. PlayerController fills it from the keyboard and mouse; an AI brain will
## fill it from a behaviour tree (Docs/AI.md). Anything a player can do, an AI can
## ask for the same way -- which is what lets the player's autonomous mech and an
## enemy soldier share every line of movement code.

## Where to go: a WORLD direction, horizontal, length 0..1 (1 = full speed).
var move := Vector3.ZERO
## Where to look, in world yaw and pitch (radians). Movement does not use them;
## a gun and a head do.
var look_yaw := 0.0
var look_pitch := 0.0
## Held.
var run := false
var crouch := false
var fire := false
## Edge-triggered: set by the brain, cleared by the motor once acted on.
var jump := false
var reload := false


## A still, quiet request that keeps looking where it looked. Look is NOT zeroed:
## a pawn handed a cleared struct would snap round to face north.
func clear() -> void:
	move = Vector3.ZERO
	run = false
	crouch = false
	fire = false
	jump = false
	reload = false
