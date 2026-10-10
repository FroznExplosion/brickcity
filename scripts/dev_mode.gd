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
