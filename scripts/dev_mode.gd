class_name DevMode
extends RefCounted
## Developer mode (Options > Gameplay > Developer Mode): the developer keys --
## spawning, debug views, the profiler, the terrain and disaster tools -- work
## only while it is on, and Options shows a Developer tab with buttons for the
## tools and the rebinding of those keys (BrickcityMenuHost). On by default:
## this is a dev build.
##
## A static field, like the other settings the game reads (BrickcityMenuHost's
## header): set from the saved setting, read by the city's key handler.

static var on := true

## Invincible (Options > Gameplay, and the Developer tab): the player -- on
## foot, and the mech or vehicle they drive -- takes no damage. Only while
## developer mode is on. On by default for now, while the modes are built.
static var invincible := true


## Whether the player's health is to be held full now.
static func player_invincible() -> bool:
	return on and invincible
