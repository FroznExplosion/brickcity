# Destruction by distance: three rings, one rule, nearly free

Written 2026-10-19 from the user's questions after wreckage furniture became bricks
(Interiors.md §8.14):

> "im wondering of ways to make destruction nearly free ... the floating part seem to be from parts
> of a building hanging up on something thats activly falling then it goes to sleep as the other
> thing falls away ... it still seems that when a building takes any damage it spawns everthing
> inside then starts to fall but it shouldnt ... we have the better markers for defining rooms so
> could we use them to simplify or add some markers to simplify?"

and, agreeing to the plan below: "we should add the new markers too but could we make them
automatic during generation, although the core and columns should already be marked as they are
structural bricks rather than interior or items."

What is left of collapse work is in [CollapseNext.md](CollapseNext.md); the tiers as they stand
are in [Structures.md](Structures.md) §2.5; interiors in [Interiors.md](Interiors.md) §8.

## 1. What was found (read in the code, 2026-10-19)

### 1.1 Floating: a piece freezes on top of something still falling
A piece freezes (`IslandManager.settle_now`) after it has been slow for 350 ms to 1.5 s, if
`_supported_below` finds anything under it -- and "anything" includes **another piece still
moving**. When that one then falls away, nothing wakes the frozen one:

* the ripple (`support_gone`) fires only for a piece that was frozen and is woken -- a piece
  that never froze moves out from under others without telling them;
* the watchdog (`_audit_settled`) wakes only a piece with nothing under it **and** nothing touching
  it -- one leaning on a wall or the stump stays;
* the backstop (`SETTLE_MAX_MS`, 12 s) freezes anything slower than 2 m/s wherever it is, so a
  piece riding a big section that is sliding slowly is frozen on it.

### 1.2 "Any damage spawns everything inside, then it falls"
An undamaged building between `PROMOTE_RANGE` (28 m) and `DEMESH_RANGE` (110 m) is a shell with
painted windows: no furniture. A hit makes it bricks (`_promote`), and its storey groups are built
for everything within `INTERIOR_RANGE` (100 m) as soon as the building looks quiet
(`_mid_collapse`). The span rule and the region check come up to `SPAN_EVERY_MS` later and cut it:
the furniture pops in, then the building falls. **Damage changed how the interior is drawn.**

### 1.3 Nine ranges that do not line up

| | m |
|---|---|
| bricks when near (`PROMOTE_RANGE`) | 28 |
| hot collapse (`CollapseTier.HOT_RANGE`, `FRACTURE_RANGE`) | 60 |
| 3D furniture (`InteriorGroups.INTERIOR_RANGE`) | 100 |
| bricks drawn as a shell (`DEMESH_RANGE`) | 110 |
| sleeping pieces wake (`WAKE_RANGE`) | 120 |
| bricks lying stop drawing (`BrickHeap.DRAW_RANGE`) | 140 |
| far collapse, pieces sleep (`CollapseTier.FAR_RANGE`) | 150 |
| shell gone (`SHELL_RANGE`) | 260 |
| near tier (BrickBevel.md) | 14 / 70 |

## 2. The rule

**What is drawn and simulated depends on the distance to the nearest player only -- never on
whether the building was hit.** Damage changes the bricks; the ring decides how they are shown.

| ring | building | interior | collapse |
|---|---|---|---|
| **near**, < 60 m | bricks | rooms drawn in 3D, collision near the player | hot: landings break, crumbs, the heap |
| **mid**, 60-150 m | bricks or shell | painted windows (rooms faked in the opening) | a landing breaks nothing, pieces fall whole |
| **far**, > 150 m | shell or stand-in | painted windows | a few big chunks, then asleep |

The near tier's own ranges (14 / 70 m) are drawing detail, not a ring, and stay.

### 2.1 Crossing a ring during each phase

| case | today | wanted |
|---|---|---|
| walk in while a far collapse falls | pieces keep far rules; a landing is judged when it lands | same |
| walk up to a building that fell far away | its pieces carry what stood on their floors, laid when somebody is near (Interiors §8.14); only furniture already laid as bricks before a far collapse is deleted (`CollapseDirector`, its "furniture" group) | same -- corrected 2026-10-19: the manifest's items were never written off by a far collapse |
| walk away from a collapse | pieces sleep 6 s after settling; laid furniture stays | same |
| walk back to sleeping wreckage | a sleeping stand-in carries nothing until woken at 120 m | same; it is laid on waking if it was not before |
| shoot a shell from mid range | it becomes bricks and its furniture pops in | bricks, still painted windows until near |
| walk in mid-collapse | groups held while it comes apart, then pop in | rooms in the near ring, drawn as they become visible |
| building given back to its shell, wreck lying round | shell back after 12 s quiet | same |
| a piece comes to rest on one still falling | frozen there, floats when the other goes | waits; and is woken if what holds it moves |

## 3. The work, in order

### 3.1 A piece is frozen only on something still -- and woken when that moves
Before a piece is frozen, what its rays under it hit is looked at: a piece that is still moving
is not support yet, and the freeze waits (every path: the slow clock, the jitter clock and the
backstop). When it is frozen, the pieces under it are remembered with where they were. A
remembered piece that moves more than a little from there, or goes, wakes what rested on it --
checked in the loop that already walks every moving piece, so it costs a lookup.
Then the patches that existed for the missing link (the down nudge, the perch tip, the watchdog)
are looked at again: those that no longer fire on the passes are candidates to go.

### 3.2 Damage does not change the interior
A building made bricks by a hit, outside the near ring, keeps the shell's painted windows
(the `_far_real` panes, Structures §4.2) and builds no storey groups. Storey groups are made for
the near ring only. A building hit inside the near ring holds its groups as today while it comes
apart.

### 3.3 One set of rings
The ranges of §1.3 read from `CollapseTier` (near 60, far 150), with hysteresis where they have
it now. `INTERIOR_RANGE` comes in from 100 to 60 (the user agreed, 2026-10-19).

### 3.4 Rooms as the unit, by their markers
The room record (`StructureSpaces`, Structures §3.1) says each room's floor, footprint and
openings. A room is drawn when it is in the near ring **and open** -- an opening that is not glass
or a wall shot through. A hit opens the rooms it reaches; a sealed office in a tower's middle is
never drawn. When a room's floor leaves as a piece, the room's furniture is laid on that piece
once, when it settles.

### 3.5 Rubble at rest merges
Settled pieces of one building, in one 32-stud tile, become one static body (Structures §2.5, not
built). Wreckage then costs about what a building costs.

## 4. Markers, made by the generator

Every marker is written when a building is generated (`StructureSpaces.for_tower` and the
generator's record), and found from the bricks for a build, so nobody marks a generated building
by hand.

| marker | how it is made | what uses it |
|---|---|---|
| **rooms** (spaces) | built: the generator's rooms, found by the finder (Structures §3.3) | interiors (3.4), AI |
| **openings** | built, with each room | open / sealed (3.4) |
| **floor slabs**: the plate heights of each floor | the generator lays them (`TowerRecipe._lay_slab`); a build: wide layers of plates found in the grid | the landing's floor-line snap, interiors, the space finder (Structures §2.4) |
| **core and columns** | already structural bricks (`Role` structure); the generator knows which of them are columns (`TowerRecipe.columned`) and the stair core (`stair_rect`) and records their cells; a build: vertical runs of structural bricks through two or more slabs | planning a collapse from the record instead of searching for it |
| **room open** | set when a hit takes an opening's wall or glass, or a floor goes | interiors (3.4) |

## 5. Built

*(each step adds its section here as it lands)*

### 5.1 Frozen only on something still (2026-10-19) -- §3.1
`IslandManager._under` is the rays of `_supported_below`, asked for everything they hit.
* **The freeze waits** while what is under a piece is a body not frozen and faster than
  `SETTLE_SPEED` (`_resting_on_moving`, `settle_waits`). Its slow clocks are kept, so it freezes the
  tick what is under it is still.
* **Frozen, it remembers the pieces under it** and where they were (`_note_holders`, from
  `settle_now`). A remembered piece that moves `HOLDER_SLIP` (0.3 m) from there -- checked in the
  tick's walk over moving pieces -- or is retired wakes it (`_check_holders`, `holder_woken`). The
  ground and buildings are not remembered: their bricks going has its doors already
  (`support_gone`, the solve). Going to sleep takes what rests on it along, as before.
* The nudge, the perch tip and the watchdog stay for now; to look at once the counters have been
  read over a few collapses.

Checks: `float_probe` 50 (new: waits on a moving piece, not on a still one; frozen, it is known to
rest on the one under it; that one -- never frozen -- moving off wakes it, with no ripple); `hang` 10,
`debris` 29, `collapse_probe` 63; `--jam --big` 4, `--lodbreak` 8 (no brick in mid-air at any
range), `--wreck` 2. `--big --shot` census: 7 settles put off for a piece under still moving.

### 5.2 Damage does not change the interior; rooms in the near ring (2026-10-19) -- §3.2, §3.3
* `InteriorGroups.INTERIOR_RANGE` is `CollapseTier.HOT_RANGE`, 60 m (was 100).
* **A building in bricks has painted windows** past that (`CityScene._tend_brick_panes`): the
  shell's panes, each only where its window still stands in the bricks, hung on the brick node,
  one building a pass, nearest first, made again once its bricks have changed and it is quiet.
  The window shader hides them inside `near_hide` (the rooms' range, an instance uniform; 0 on a
  shell) on the same dither the storey groups fade out on, the other way round -- each pixel of a
  window is either the painted room or the drawn one, crossing over from 45 to 60 m.
* **No storey group is made for a building that is not known to be standing**
  (`_interior_unsure`): bands still building, its floors' reach not asked yet (`_span_owed`), or
  hit within `COLLAPSE_QUIET_MS` (`_touched_ms`, set by `_mark_dirty` -- not by being made bricks).
  Before, a building shot from 40 m drew its rooms and then the span rule cut it.
* **The other ranges of §1.3 stay.** Looked at: 110 m (bricks drawn as a shell) is drawing
  detail; 120/150 m (wake/sleep) is one ring with its hysteresis; 140 m (the heap) is the bricks'
  own draw distance. None changes what a player sees happen; moving them is churn.

Checks: `-- --groups --big` 25 (ranges now 14, 40 and 55 m; the last come to from outside the
range, since collision and shadows are kept a way past where they come on; new: past the range
its windows are painted on its bricks, hidden where its rooms are drawn -- `interior_groups_panes`,
and `interior_groups_55` shows the crossover); `interior_group_probe` 33, `interior` 87, `fixture`
47, `shell` 38; `--breaklag --big` 7; `--lodbreak` 8 (one run of two had 3 fails, one brick of a
blast's ring lying in mid-air through the run -- the heap's floor ray, CollapseNext 28; not this).
