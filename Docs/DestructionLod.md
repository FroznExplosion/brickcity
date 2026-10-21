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

### 5.3 The frame, made by the generator (2026-10-19) -- §4
`TowerRecipe.frame(footprint_x, footprint_z, courses, keepouts, rooms, world, chunk)` says from
the recipe what `build` lays that holds a building up: `floors` (`[y, plates]`, the base and every
slab), `columns` (`[x, z, w, l, y, plates]`, each as build lays it -- given the bricks, only where
it stands whole: on a wall line with a doorway the wall took its place) and `core` (the stairwell
on plan). `StructureSpaces.for_tower` puts them in the record beside the rooms; `empty()` has them
empty, for a build, until they are found in its bricks (Structures §2.4, not done). Nothing reads
them yet: the room-open flag and rooms as the unit (§3.4) are next, then the floor-line snap.

Checks: `spaces_probe` 11 (new: a 12-storey tower's frame -- 13 floors, 7 columns -- every cell of
them bricks), `workshop_spaces_probe` 8.

### 5.4 Rooms as the unit (§3.4): measured first, not built (2026-10-20)
Drawing only the rooms that can be seen into saves something only where a room has no opening
to the outside. Counted over every shape the city builds (`RoomManifest.rooms_for`, a room
within two studs of the outer wall's inner face counts as outer): **every room of every tower
is against an outer wall** -- 12 of 12 up to 204 of 204 -- and so is every room of the
240 x 50 wide building; only the 200 x 80 one has inner rooms, 20 of 84 (45 of its 200 items).
Every room has windows, so every room is seen from outside, and the open flag would draw what
is drawn now. Left until the generator makes deep plans (halls, cores of rooms).

**Where a collapse's time goes instead** (`--big --shot`, 2026-10-20, editor closed but two other
chats' headless runs going -- rough): the script's tick 9.5 ms on average, of which damage 5.6
(`loose pieces`: blasts on falling pieces) and the pieces' tick 2.4; the physics step on top, with
18 pieces in motion on average carrying 5,260 collision boxes (53 and 9,460 at the peak). The
worst ticks: a merged rebuild of a 24,000-brick piece (36 ms of rebuilds in one tick, 8.2 ms for
the worst single one, 2,564 boxes), a 44 ms damage tick, the first frame's render. So "nearly
free" is in the moving phase -- fewer boxes on falling pieces, cheaper hits on them -- not in
interiors or wreckage at rest (24 settled pieces at the end of that pass).

### 5.5 Hits on falling pieces: a patch from what changed (2026-10-20)
Of the damage pass's 5.5 ms a tick (`--big --shot`), 5.1 was `IslandManager.damage_near`, and of
that, 1.65 s of the run's 1.95 s was the mesh update each hit made on the spot: a big piece -- one
mesh, 24,000 bricks -- had its index buffer refilled from every face it has, 2-9 ms a hit,
`BrickWorld.update_index_region`, and a piece under automatic fire paid it once a bullet.
* **Once a piece a tick** (`IslandManager._mesh_later`, `flush_meshes`): the bricks and the
  collision change in the hit, the drawing at the end of the tick's hits (CityScene, after its
  damage queue; the pieces' tick for hits from anywhere else).
* **Only the faces a change reaches** (`BrickWorld.refill_changed`): the buffer keeps a slot a
  face, so a patch needs only the faces of blocks whose alive flag changed since the last fill
  and the faces those blocks hid. Each chunk keeps what its buffer was filled against
  (`track_indices`: a byte a block, each block's faces, and for each block the faces it hides);
  which blocks changed is a byte compare a block, not a walk of the faces. A change of bake, or a
  quarter of the blocks, fills in full as before.
`barrage_probe` checks every patch against a full fill beside it (`set_index_check`,
`get_index_patch_stats`): 347-387 patches a run, **0 differing**.

**What it did** (three alternated pairs, editor closed, no other Godot running): a hit on a piece
**0.57 ms -> 0.076 ms**; the damage pass **3.5-4.4 -> 1.9 ms a tick**; mesh updates of hits
1.0-1.5 s -> 0.11-0.12 s a run. Frames came out *slower* -- 17.2-18.1 ms -> 19.7-20.2, 15-37 of 906
over 33.3 ms -> 48-81 -- and not from this: the old hits used up `DAMAGE_BUDGET_MS`, so the
pass's blasts queued, and 3,028 of them had landed by the end against 4,436 now. All of them
landing on time is ~40% more pieces moving (13.9 -> 19.9 on average, 5,500 -> 8,000 boxes), and
that is the physics step's. Which is §5.6.

### 5.6 Coarser collision while falling: measured, not kept (2026-10-20)
Built and timed: a falling piece's merged boxes on a 2-stud grid across (every plate up, a cell
solid where any of it is), rebuilt exact when it settles. Three alternated `--big --shot` pairs
showed nothing: frames 19.1-19.6 ms either way, boxes in motion 5,900-7,500 coarse against
6,500-6,600 exact. Asked directly of whole towers (`add_chunk_shapes` merged): 310 -> 291 boxes
(30 x 30), 728 -> 691 (40 x 40), 2,522 -> 2,435 (80 x 60) -- **3-6% fewer**; 3 or 4 studs, 25%. A
piece's boxes are set by its layers -- slabs, window rows, courses -- and the height is the one
thing a falling piece must keep exact to come to rest where its bricks do. Taken out again.

### 5.7 Floors from the record, not every 20 plates (2026-10-20) -- §4
`BuildingRegistry.floor_lines(id)`: the plate heights of a building's floors from its structure
record -- a generated building's frame (`TowerRecipe.frame`), a build's own `floors` when it has
them -- worked out once a building. What used one storey height for everything reads them:
* a landing's snap (`IslandManager._weak_seam`, `_floor_line`, `_is_floor_line`): the floor
  lines it prefers, and how far it looks (half the storey there);
* a mega collapse's chunks (`CollapseDirector.plan`): closed between floors.
A recipe tower's floors are every 20 plates from 0, as the constant had them, so towers break as
before; a floor anywhere else -- a mezzanine, a build with floors marked -- is a floor too.
`seam_probe` 23 (new: floors at 0, 9, 18, 30, 45, struck a plate over 30, it goes at 30, and 27
is no floor). `storey` 4, `far_rules` 9, `float` 50, `debris` 29.

**`collapse_probe` flickers since 2026-10-20**: "an untouched tower of 6 storeys to test on --
20 of 22 buildings used already", 3 runs of 4 with these floors and 3 of 4 without them, so not
this. The probe takes twenty of the city's twenty-two towers and any collateral damage to the
last two leaves its last section none. Suspect: §5.5's hits landing on time (more of each blast's
work done, more collateral); the A/B without it was stopped for low memory, not finished.
**Fixed 2026-10-20 (second chat):** the probe now says which building a section's wreckage
reached and, when a section finds no tower, why each tall enough one was passed over. 4 runs of 7:
"inside" topples the 13-storey tower 17 and its wreckage hits tower 16, 3 m beside it (4 storeys);
`_tower` is first fit, so every section after it took the next tower along, and "farcut" (asking
four) got tower 21, the last of six storeys or more -- "shellhit", last in line, had none.
"shellhit" now runs in a city of its own (`tools/shellhit_probe.gd`, 2), as "storeys" and
"farrules" do: `collapse_probe` 61, 3 runs of 3 (one with tower 16 hit). **Not §5.5:** with
it reverted, tower 16 was hit in 2 runs of 4; with it, 5 of 10 -- the same. How tower 17 comes
down decides it.
