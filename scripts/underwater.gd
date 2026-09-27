class_name Underwater
extends RefCounted

## What the world looks like from under the sea. [Docs/Water.md](../Docs/Water.md) §3.6.
##
## The water bricks tint themselves when the camera goes under them, but that
## only darkens the water — everything ELSE stays a bright, crisp, dry scene,
## which is what gives away that the camera merely moved below a sheet of
## geometry. The submerged look has to be applied to the whole view.
##
## It is `Environment` fog and nothing more: no post-process pass, no extra
## quad, no render target. Exponential fog with `fog_sky_affect` at 1 turns
## the sky into the same green as the far water, which is the whole trick —
## there is no horizon under water, and drawing one is what makes a scene
## look dry.
##
## The only state is a bool, so a scene calls [method set_submerged] every
## frame and it does nothing on the frames where nothing changed.

## Visibility under water, roughly: 1/density metres to heavy fog. 12 m is
## clear tropical sea, which is the look — a murky one hides the bricks and
## the bricks are the point.
const DENSITY := 0.085
const TINT := Color(0.09, 0.34, 0.42)
## Light is eaten from the top down, so the ambient goes with it.
const AMBIENT := Color(0.34, 0.60, 0.70)

var _on := false


## `dry_ambient_energy` is what the scene set for air, restored on the way out.
func set_submerged(env: Environment, on: bool, dry_ambient_energy := 0.55) -> bool:
	if on == _on:
		return false
	_on = on
	if on:
		env.fog_enabled = true
		env.fog_mode = Environment.FOG_MODE_EXPONENTIAL
		env.fog_light_color = TINT
		env.fog_light_energy = 1.0
		env.fog_density = DENSITY
		# The sky is not visible from down here. Fogging it is what removes
		# the horizon, and the horizon is the tell.
		env.fog_sky_affect = 1.0
		env.fog_sun_scatter = 0.35
		env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
		env.ambient_light_color = AMBIENT
		env.ambient_light_energy = dry_ambient_energy * 1.35
		env.adjustment_enabled = true
		env.adjustment_saturation = 0.85
		env.adjustment_brightness = 0.92
	else:
		env.fog_enabled = false
		env.ambient_light_source = Environment.AMBIENT_SOURCE_SKY
		env.ambient_light_energy = dry_ambient_energy
		env.adjustment_enabled = false
	return true


func is_submerged() -> bool:
	return _on
