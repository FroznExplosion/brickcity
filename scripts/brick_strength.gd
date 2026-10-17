class_name BrickStrength
extends RefCounted

## How hard a stud holds: the one number that says how much comes off a damaged
## building by itself.
##
## A joint between two bricks carries any weight pressing it together and very
## little pulling it apart ([Docs/BrickFailure.md](../Docs/BrickFailure.md)), so
## what fails in a building is a joint asked to hold something up from above --
## an overhang, a wall left hanging over a hole, a top standing off one corner.
## It holds `tension()` mass units for each stud in the joint
## (BrickWorld.set_tension_per_stud, per chunk; CityScene sets it on every
## building it makes bricks).
##
## Two values are physics, and the game's is a choice between them:
##
##   TOY     408   the real clutch, 4 N a stud, in the solve's units -- what a
##                 model on a table has. A full 2x4 connection holds about
##                 1,280 bricks hanging: for its own weight, nothing ever fails.
##   SCALED  9.3   the same clutch on a stud 0.35 m across instead of 8 mm.
##                 Clutch grows with area and weight with volume, so a building
##                 the game's size is 43.75 times weaker for its weight than
##                 the toy: the same connection holds about 29 bricks.
##
## The game ran on SCALED until 2026-10-13, for the look: a section could hang
## by a corner, but not a big one. The aim is the toy breaking apart (the user,
## 2026-10-13: "we should try [it stronger] but likely tune to feel"), so it is
## `times` x SCALED, with `times` a setting (Options > Gameplay, "Stud
## Strength") to be tuned by eye in play. 1 is the building's own physics, 44
## the toy's.
##
## What does NOT follow it, on purpose, until whoever owns each has retuned it:
##   * the sideways load of an earthquake or a wind (DisasterContext.lateral)
##     is still weighed against SCALED: the disasters' strengths were set
##     against it;
##   * a storey crushed by what is above it (CityScene._gravity_fail) gives way
##     at the same load as before, whatever a stud holds in tension.
## A storey TIPPING off what is left of the one below does follow it: that is
## studs holding a top down, which is what this number is.

const TOY := 408.0
const SCALED := 9.3
## The first try. Tuned by feel from here.
const DEFAULT_TIMES := 4.0
const MIN_TIMES := 1.0
const MAX_TIMES := 44.0

## x SCALED. Set from the saved setting (BrickcityMenuHost); a headless run is
## a test and keeps the default, as a test window does.
static var times := DEFAULT_TIMES
## How far a floor reaches past what holds it up, in studs, for a brick of
## plain PLA; stronger materials reach that many times their toughness
## (BrickWorld.cut_spans; Docs/Structures.md 2.3). Options > Gameplay, "Floor
## Reach" (BrickcityMenuHost).
const SPAN_DEFAULT := 20.0
static var span_reach := SPAN_DEFAULT


## What a stud holds in tension, in the solve's mass units.
static func tension() -> float:
	return SCALED * clampf(times, MIN_TIMES, MAX_TIMES)
