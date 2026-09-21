# Status — what runs today

Godot 4.6.1 · Jolt · Forward+ · **Vulkan** · C++ GDExtension.
Architecture and milestones: [Plan.md](Plan.md). Prior art: [Reference/](Reference/README.md).
Networking feasibility: [Multiplayer.md](Multiplayer.md).

**M0 through M4 are in.** The 150 m performance gate is essentially met, the 5000-building memory
gate is met outright, and the city scene holds a mean 19.4 ms frame through a 12-building collapse.
Greedy face merging took a 150 m tower from 533 MB of baked mesh to 111 MB, and every expensive
thing the tick does -- damage, promotion, splitting, landings, meshing, the structural solve -- now
runs to a budget.

Two model corrections landed with research behind them: brick joints fail in **tension, never
compression** ([BrickFailure.md](BrickFailure.md)), and the tension constant had to be divided by
the world scale factor. Interiors and item culling are designed but not built
([Interiors.md](Interiors.md)).

Blocks exist on the grid, mesh with face culling, carry real collision, and break. Weight flows
down the structure, overloaded joints crush, the collapse cascades over successive ticks, debris
settles — and a detached island is now a **chunk of its own**, so it can be shot, re-solved and
broken apart when it lands hard. Parts are no longer required to fill their bounding box.

A 150 m tower of 16,590 blocks stands and comes apart with **3 of 302 frames over 33 ms** and a
mean frame time of 17.4 ms — against ~1 fps for three seconds before this pass. Getting there meant
finding three separate quadratic traps, none of them where the guesses said they were.

Above that sits the city: 22 buildings of mixed height standing as **recipes and shell meshes with
no bricks at all** until something hits them, floors that are part of the exterior and hold under
damage, toppling that comes apart in large intact sections, and wreckage that stays breakable and
stays movable once it lands. 5000 registered buildings cost 0.0 MB in `BrickWorld` and 32.8 MB of
resident shell geometry.

---

## Running it

Godot on this machine lives at
`C:\Users\lbaun\Documents\Godot_v4.6.1-stable_win64.exe\Godot_v4.6.1-stable_win64_console.exe`
(the `_console` variant prints to a terminal).

Play:

```bash
godot --path . --resolution 1280x720
```

A city of the big shapes -- up to 28 x 22 m on plan and 84 m tall, 4,000 rooms
in the largest. `--buildings=` sets how many (default 22); six is one of each
shape:

```bash
godot --path . --resolution 1280x720 -- --big
godot --path . --resolution 1280x720 -- --big --buildings=6
```

What interiors cost, measured three ways on the same building:

```bash
godot --path . --resolution 1280x720 -- --interiors --big
```

Capture the scripted collapse to `shots/` and quit:

```bash
godot --path . --resolution 1280x720 -- --shot
```

The 150 m gate tower (16,566 blocks) instead of the 17 m one:

```bash
godot --path . --resolution 1280x720 -- --shot --tall
```

Acceptance probes — headless, no rendering, no physics:

```bash
godot --headless --path . --script tools/m0_probe.gd
```

```bash
godot --headless --path . --script tools/m1_probe.gd
```

```bash
godot --headless --path . --script tools/m2_probe.gd
```

```bash
godot --headless --path . --script tools/m3_probe.gd
```

Floors, and shooting a chunk that has moved:

```bash
godot --headless --path . --script tools/floor_probe.gd
```

Breaking a building that has already fallen, and gravity for a rotated grid:

```bash
godot --headless --path . --script tools/fallen_probe.gd
```

What comes loose when a building is hit, split into flooring and walling:

```bash
godot --headless --path . --script tools/floorshed_probe.gd
```

Integer determinism, command replay and content-derived piece identity -- the substrate a
networked game needs ([Multiplayer.md](Multiplayer.md)):

```bash
godot --headless --path . --script tools/replay_probe.gd
```

Sustained destruction across a bigger city, with rendering on. **This is the same
`scenes/city.tscn`** -- the flags only change how many buildings it registers and make it fire at
them automatically. Without them it is the 22-building scene you fly around by hand:

```bash
godot --path . -- --stress --buildings=200
```

City scale, the registry, and what streaming costs:

```bash
godot --headless --path . --script tools/city_probe.gd
```

Frames -- sideways building, welds, and grounding through them:

```bash
godot --headless --path . --script tools/frame_probe.gd
```

Orientations -- flips, yaw, and the two-bit face masks:

```bash
godot --headless --path . --script tools/orient_probe.gd
```

The same city with nothing fixed to its buildings, for measuring what the fixtures cost:

```bash
godot --path . -- --shot --no-fixtures
```

The chamfer, on and off, close up and from across the street. Writes
`shots/chamfer_on.png` and `shots/chamfer_off.png`:

```bash
godot --path . --resolution 1280x720 -- --chamfer
```

Interiors -- rooms generated from the recipe, contents generated from a seed:

```bash
godot --headless --path . --script tools/interior_probe.gd
```

The same thing with distances, collision and a mesh in it:

```bash
godot --path . --resolution 1280x720 -- --rooms
```

Wreckage given back -- a record that round-trips a chunk exactly:

```bash
godot --headless --path . --script tools/dormant_probe.gd
```

The same thing where the distances and the memory are -- collapse three buildings, walk away, walk
back, and shoot what is asleep:

```bash
godot --path . --resolution 1280x720 -- --dormant
```

Fixtures -- a dormant staircase, what wakes it, and what it does when the building comes down:

```bash
godot --headless --path . --script tools/fixture_probe.gd
```

The same gate where it needs a scene -- bodies, meshes, and a figure standing on a tread. Writes
`shots/fixture_awake.png`, `fixture_standing.png` and `fixture_collapse.png`:

```bash
godot --path . --resolution 1280x720 -- --fixture
```

Walking, flying, and what stops each of them -- the gate for player collision:

```bash
godot --path . --resolution 1280x720 -- --walk
```

Drop a saved workshop build into the city and fly around it. `--build=<path>` for a file other than
the workshop's own `user://workshop_build.json`:

```bash
godot --path . --resolution 1280x720 -- --build
```

Its gate -- a multi-frame creation placed, drawn, collided and shot. Writes `shots/build_placed.png`
and `shots/build_shot.png`:

```bash
godot --path . --resolution 1280x720 -- --buildshot
```

A two-frame demo build to place, for when nothing has been hand-built yet:

```bash
godot --headless --path . --script tools/demo_build.gd
```

Build mode -- the workshop. Place bricks, attach a staircase with `K`, undo, save, and drop the
result into the city:

```bash
godot --path . --resolution 1280x720 res://scenes/workshop.tscn
```

Its own gate -- authoring a fixture, undoing it, reloading it, placing it:

```bash
godot --path . --resolution 1280x720 res://scenes/workshop.tscn -- --gate
```

Its acceptance probe, headless:

```bash
godot --headless --path . --script tools/build_probe.gd
```

Gate G1b -- a damaged building still looks damaged once its bricks are gone:

```bash
godot --headless --path . --script tools/shell_probe.gd
```

An editable chunk -- place, remove, and the two questions a ghost asks:

```bash
godot --headless --path . --script tools/edit_probe.gd
```

The part palette, and whether it is proportioned like the real thing:

```bash
godot --headless --path . --script tools/palette_probe.gd
```

Rebuild the extension (SCons is pip-installed and **not on PATH**):

```bash
python -m SCons -C gdextension/brick platform=windows target=template_debug
```

**Controls:** WASD + Q/E fly · shift fast · alt slow · ESC releases the mouse ·
**LMB / SPACE** blast where you are looking · **X** a 2.6× wider blast ·
**R** rebuild the mesh · **L** toggle block seams · **G** show chunk grids · F1 stats.

> **After adding any script with a new `class_name`, or the first time the project is opened,
> run `godot --headless --path . --editor --quit` once.** GDExtension classes and global script
> classes are registered by an editor import pass; without it the run fails with
> `Could not find type "BrickWorld"`. That pass segfaults at shutdown *after* writing correct
> caches — annoying, not harmful.

---

## What is implemented

### The grid (`gdextension/brick/src/brick_grid.h`)

`x` and `z` in studs, `y` in plates. One stud 0.35 m, one plate 0.14 m, a brick three plates at
0.42 m — spec §3's 1:43.75, so a four-brick figure is 1.68 m. Every block is an integer footprint;
nothing is allowed off the grid, because the integer adjacency test is what the whole destruction
stack rides on. A twelve-entry filament palette is carried per block as a byte and emitted as
vertex colour — no textures, matching spec §2.

### The part palette (`scripts/brick_palette.gd`)

**A part is what a player picks; an archetype is what the extension bakes.** The table lists
**20 parts** -- plates, bricks and tiles at 1x1, 1x2, 1x4, 1x6, 2x2, 2x4 and 4x4 -- and `bake()`
expands each into the **64 archetypes** they need, one per orientation, deduping the squares. Callers index
archetypes exactly as before (`palette.brick_2x4_x`); build mode will show the 13.

That split is the whole point of the file. The first version hand-wrote `_x` and `_z` as separate
table rows, which leaked a runtime representation into the authoring layer: adding a part meant
remembering to add it twice, a square part could pick up a meaningless suffix, and a player would
have been shown two entries for one brick. The duplication belongs in the generator, where it is
free -- and the 8-orientation bake (Docs/BuildMode.md section 3) is the same generator with flips
added.

> **Why not one archetype plus a rotation field on `Block`?** The cost lands in the wrong place.
> Occupancy claiming, `for_each_neighbour`, `joint_exists`, the face bake and the collision
> transform would each have to rotate, and the first three are the hot path -- `for_each_neighbour`
> runs four times per cascade step, and a 3x lookup increase there already measured over 200 ms at
> 16.5k blocks. What it saves is archetype count, which is tens, in the low MB. That is the
> flyweight pattern working as intended: bake the variants, keep the runtime dumb.

**Plates and bricks can be built on; tiles cannot.** A tile is solid, one plate tall, with sockets
underneath and no studs on top -- so a thing rests on one and does not clip to it. That one bit is
the only difference between a tile and the plate of the same size, and it is structural rather than
a finish, so the probe asserts it directly: every studded part stacked on itself joins, every tile
stacked on itself does not, and a tile laid *on* a brick still joins downward. A studless BRICK, for
capping a wall head, is one more table row whenever it is wanted.

Note that none of this is visible yet either way. **Stud geometry is M5** (Plan D4); a stud mask
today is a structural fact the connectivity graph reads, not something on screen.

**Proportions are asserted, not asserted-in-a-comment.** `tools/palette_probe.gd` passes
**532 checks**:

| | |
|---|---|
| Scale | game and print are the same system at **43.75x on every axis** -- checked as one factor, not two, because a part that is the right height and the wrong width looks fine and is wrong |
| Ratios | `plate / stud = 0.4` and `brick / stud = 1.2`, in **both** systems |
| Constants | the GDScript copies are pinned against `grid_to_world()` in the extension, so the two cannot drift |
| Parts | canonical `W <= L`, a `brick` is 3 plates and a `plate` is 1, and no part carries an axis suffix |
| Archetypes | a square part expands to exactly one; others to two that are the same part rotated, with equal mass -- and a suffix on a square part resolves to nothing |
| Mass | a pure function of cell count at 0.1 g per cell, anchored on the real hollow 2x4 at **2.4 g**. A brick weighs exactly three of its own plate |
| Studs | every studded part stacked on itself **joins**; every tile **does not** -- so nothing is unbuildable-on by accident, and no tile quietly behaves like a plate |
| Tiles | same footprint, volume and mass as the plate they match, and a tile laid on a brick still joins downward |

One real bug fell out of writing it. `brick_1x2_x` meant "the 1x2 you reach for when laying a course
along X", which is the piece whose long side runs along **Z**. The convention held for the 2x4 and
inverted for the 1x2, so the name told you the opposite thing depending on which part you asked
about. Renaming was free -- the same shapes go in the same cells -- and `floor_probe.gd` reproduces
its old numbers exactly (842 blocks, 19 removed, 2 loose, 0.2%), which is what confirms it.

### Frames: sideways building, and the one graph that could go stale

Build mode Stage 4, and the only part of build mode that makes DESTRUCTION harder rather than
easier. A **frame** is a chunk at one of the 24 axis-aligned rotations, offset by an exact integer
number of **ticks**. Inside it, studs are studs and plates are plates and every existing solve runs
unchanged -- which is the whole reason a sideways brick is a rotated *frame* and never a rotated
block (rotating a block 90 degrees about X or Z lands on 1.2 studs and the grid cannot express it).

**A tick is `gcd(stud, plate)` = 0.07 m, so a stud is 5 and a plate is 2**, and the probe asserts
`5 plates == 2 studs` in integers rather than trusting it. That coincidence is what lets two frames
at different rotations be offset so their bricks actually meet.

> The tick lattice is **never an occupancy grid**. It is three integers per frame, not per cell, and
> nothing allocates against it. A 0.07 m occupancy grid would be 50x the cells per block and is not
> on the table.

| | |
|---|---|
| `set_chunk_frame(chunk, rotation, ticks)` | The chunk's `Transform3D` is **derived** from these. Ticks are the truth, because only they are exact |
| 24 rotations | Every signed axis permutation with determinant +1. A mirrored part is a different part, not a turned one -- the probe checks all 24 are proper, distinct and axis-aligned |
| `get_block_ticks` | A block's world box in ticks. A signed permutation maps a box to a box **exactly**, so there is no bounding-box slop at any rotation |
| `overlaps_frame` | Occupancy is per chunk, so nothing can see across a frame boundary on its own. Authoring-time only; never on the damage path |

**Cross-frame overlap is a real hole without this.** `place_block` will happily drop a sideways
brick inside an upright one, because the two live in different occupancy grids. `Assembly.place()`
runs the tick-space test first, and it is exact: one tick of overlap is refused, exactly flush is
allowed.

#### Welds derive their aliveness rather than being invalidated

The weld table is the one **stored** graph in the system, and the design note said it would have to
be invalidated whenever a block died. It does not, and the reason is worth keeping:

> **Store the endpoints, derive the aliveness.** A weld is alive exactly while both of its blocks
> are, so `is_weld_alive` asks the blocks. Nothing is cached, so nothing can go stale, and
> `kill_block` and `apply_hit` did not have to learn about welds at all.

That keeps the property Status has claimed since M1 -- *a derived graph cannot go stale when a block
dies* -- for the one edge type that is not derived from the occupancy grid. The weld record
survives its own death, which is what "no dangling weld left behind" means in practice: the record
is still there, it is simply not load-bearing, and `get_live_welds` leaves it out.

#### Grounding crosses a weld

`solve_grounded` floods from a foundation plane. A rotated frame has no foundation of its own -- its
path to ground runs sideways, through a weld, into another chunk -- so left alone every sideways
sub-assembly reads as ungrounded and falls off on the first solve. That is the same failure the
interior floor slabs had, and it would have presented identically.

`solve_grounded_from(chunk, seeds)` floods from an explicit block set instead. `Assembly` walks the
weld tree root-first: a live weld whose parent-side block came out grounded contributes its
child-side block as a seed. Grounding is a connectivity question, so a seed anywhere in a frame
reaches all of it -- the probe seeds a stack from the TOP block and the whole stack grounds.

**The gate is met.** A sideways panel welded to an upright wall by two bricks stands; damage
elsewhere in the wall leaves it alone; killing the two bricks the welds hold kills both welds and
the panel sheds -- with its own bricks intact, because a weld failing separates rather than
destroys. `tools/frame_probe.gd` passes **57 checks**.

#### Six build grids, not one you conjure

The workshop stands **all six build grids up front** -- upright, four sideways, inverted -- all
covering the same volume, and `TAB` switches between them. That is possible because the build box is
48 studs and 120 plates, which are both **240 ticks**: the volume is a cube in tick space, so a grid
covers the same region whichever way it is turned. Each grid's origin is offset by its own rotated
box's minimum corner, which is what puts its cells over that cube rather than into negative space.

Two bugs, both of which made sideways building unusable and neither of which a headless probe would
have caught on its own:

* **A frame created on demand landed somewhere unrelated.** Its offset was derived from the cursor's
  cell in the *previous* grid, so the new grid appeared wherever you had last been pointing rather
  than where you were looking.
* **Aiming converted a world point straight to a cell as if the chunk were at the origin**, which is
  true only of the upright grid. In a rotated one the ghost tracked the cursor into the wrong place
  entirely, so bricks did not appear where they were aimed.

The aim now marches the ray in **world** space and tests **every** grid, because the thing you are
pointing at was very likely built in a different one -- that is what makes six co-located grids
usable rather than six separate scenes. It takes the last sample that was empty in all of them (the
ordinary voxel rule) and converts that point into the **active** grid. Cross-grid placement is then
refused or allowed by the tick-space overlap test, so a sideways brick cannot end up inside an
upright one.

`frame_probe.gd` pins both properties -- every grid's cells inside one tick cube, and a world point
converting into any grid without drifting further than the cell it is in.

#### What frames cost, and the one seam left open

`BuildRecipe` now carries frames: a rotation and a tick offset per frame, and a frame index per
block. A recipe written before frames existed has no per-block frame column, so loading fills it
with zeroes rather than rejecting the file.

That gap was found by running it rather than by reading it: the first multi-frame save wrote 20
bricks and loaded 12, because every brick came back in frame 0 and the sideways ones collided with
what was already there. It reported as a load failure and was an authoring-model failure.

**A multi-frame build cannot be placed in the city yet, and `register_build` refuses it rather than
dropping the frames.** A `Building` holds one chunk and a frame *is* a chunk, so placing an assembly
needs `Building` to hold a whole `Assembly` -- which reaches into materialise, dematerialise, the
damage record, the shell and the streaming loop. That is the next real piece of work, and refusing
loudly is the honest interim.

### Orientations, and the rule that decides what an inverted brick can touch

Build mode Stage 3. A part is baked once in its canonical orientation and every other orientation
comes from `bake_variant(base, name, yaw, flip)`, which transforms the **cell mask and both face
masks together** and dedupes against what is already baked.

**The masks are two bits per column now, not two one-bit masks.** `up_face` and `down_face` each
hold NONE, STUD or SOCKET, and a joint exists when a stud meets a socket:

```
joins  iff  (lower.up == STUD   && upper.down == SOCKET)
		 || (lower.up == SOCKET && upper.down == STUD)
```

The old `studs` / `sockets` pair could not describe a flipped part at all, because a flipped brick
has studs on its **bottom**. `bake_shaped_archetype` keeps its one-bit signature and translates, so
every existing caller is untouched.

> **An upside-down brick cannot clip to a right-way-up one**, and that fell out of the rule rather
> than being designed in. Four pairings, and the useful half is the surprising half:
>
> | | faces meeting | |
> |---|---|---|
> | normal over normal | STUD meets SOCKET | **joins** |
> | inverted over inverted | STUD meets SOCKET | **joins** |
> | inverted over normal | STUD meets STUD | does not |
> | normal over inverted | SOCKET meets SOCKET | does not |
>
> This is exactly true of the real thing -- you need a bracket between them -- and it is what makes
> the newly expressible **double-sided plate** (studs on both faces) worth having: it mates with a
> socket on both sides, so it bridges the two parts that cannot join each other directly. Four of
> the first probe run's assertions were wrong in this way, and the implementation was right.

Only **eight** orientations are grid-legal: 4 yaw x 2 flip. Yaw swaps two stud axes, flip reverses Y
and Z and leaves every extent alone. A sideways brick is not among them and cannot be -- rotating
90 degrees about X or Z swaps a stud axis with the plate axis and lands on 1.2 studs
(Docs/BuildMode.md section 2.1). That is Stage 4's frames, not a rotation.

Dedupe matters: a square footprint yawed 180 degrees is the part it already was, so most parts
resolve to **two or four** archetypes rather than eight. The palette is now **20 parts -> 64
archetypes**, and `bake_variant` returns an existing id rather than baking a duplicate, so the
name -> id map is deliberately many-to-one.

`tools/orient_probe.gd` passes **51 checks**, including that the cell mask and the face masks move
*together*: an inverted slope's downward stud has to be under the column that is actually
full-height, which is the check that catches transforming one and not the other.

**Not done, and deliberately:** side-stud masks (BuildMode section 3.2). They have no consumer until
frames exist, and a mask nothing reads and no test exercises is speculative work. They belong with
Stage 4.

### The two frames a new piece and its parent both draw

`IslandManager.OVERLAP_FRAMES` is **2**, and `J` in the city turns it off.

A piece that has just come off a building is drawn by both of them for two frames. On the frame it
is born there is otherwise an instant where neither draws those bricks, and the building flashes --
disappears and comes back. The same bricks drawn twice in almost the same place cannot be seen; the
gap can.

It is a `static var` rather than a `const` for one reason: **no instrument ever saw the missed
frame.** A framebuffer readback forces the GPU sync that hides it, and the interpolated transform of
every newborn matches its body. The only evidence the fix works is the flash coming back when it is
switched off, so that has to stay switchable in a running scene.

### Walking in the city, and the size of the hole

The camera was a free-fly camera with nothing to collide with, and the destruction tool was on the
space bar. Both changed.

**SPACE twice, quickly, swaps flying for walking.** Walking is a `CharacterBody3D` on the `PAWN`
layer, which existed and was used by nothing, and the camera follows it at eye height. The figure is
**half a plate under three bricks** -- 1.19 m, eye at 1.05 m, a fifth of a metre across -- and every
number in the controller is derived from the grid rather than from a human: it is a minifigure at
the scale the bricks are actually built at, not a person standing in a model village. Speeds are
written in courses per second for the same reason, so resizing the figure keeps them honest. Everything a shot can hit is something to stand on, so the pawn's mask is the hitscan mask:
the ground, a building's shell boxes, its bricks once it has any, a falling section and settled
wreckage alike.

Two decisions are worth keeping:

* **It moves at RENDER rate, not at the 30 Hz physics tick.** `move_and_slide` takes its delta from
  whichever frame it is called in, so calling it from `_process` is legal -- and it is what keeps a
  walking camera smooth. Driving the body from `_physics_process` instead moves the eye thirty times
  a second under a sixty frame picture, and the camera cannot be interpolated out of that, because
  it is the thing mouse-look writes to every frame.
* **It ducks, and it does so without being asked.** A room is a fixed number of courses tall, so
  what you are standing ON decides whether you fit: a tile floor is one plate, a brick is three, and
  those two plates are the difference between walking under a beam and being stopped dead by it.
  That was a real bug -- the same doorway was passable from a tile floor and impassable from a brick
  one. The body now crouches a whole brick (to 0.77 m), and the test is **predictive and along the
  motion**: stand if standing fits where you are going, crouch if it does not and crouching does,
  and stand up again as soon as there is room. CTRL asks for it outright. Because the test is along
  the motion rather than in place, a wall makes no difference to it: being blocked by a wall while
  crouched is no better than being blocked standing, so it stays standing.
* **A kerb is stepped over, a wall is not.** A brick course is 0.42 m and rubble is everywhere after
  a collapse, so a body that stops dead on anything at all is a body that cannot cross its own
  debris. Exactly one course, plus a hair, is raised over, moved across and dropped onto -- and if
  nothing is there to land on, the move is undone, because that was a ledge to walk off rather than
  a step to climb. One course is a third of this figure's height, which is what makes a brick-built
  staircase climbable at all.

**The wheel sets the blast radius**, from 0.5 m to 12 m, a notch at a time -- multiplicatively, so a
notch is the same proportion of the radius at either end. The reticle draws the sphere at the range
it is actually pointing at, because a radius in metres means nothing to the eye until it is a circle
over the wall it is about to remove. The left mouse button fires it. SPACE no longer does, and that
is the point: it is the mode toggle and the jump now.

**Gate met.** `godot --path . -- --walk` passes **22 checks** against the real scene, with
synthesised key events: it falls to the ground and stands at eye height, crosses a 0.3 m kerb, is
stopped by a 1.5 m wall, is stopped by a building's shell and passes straight through the same
shell while flying, walks under a beam standing when it is on the ground and **ducks under the same
beam when it is standing on a brick course**, stands up again once the beam is behind it, the double
tap swaps modes in both directions while a single tap does not, and SPACE destroys nothing.

### A staircase that costs nothing until you walk up to it

Every building in the city now has a spiral staircase up the middle of it, and an untouched city
still holds **0.00 MB of bricks and zero chunks**. That is the whole claim of
[BuildMode §9](BuildMode.md): a **fixture** is a sub-assembly of a building with a materialisation
state of its own, which is Plan §4.2's ladder answering its third question -- buildings, room
contents, and now the things fixed *to* a building.

**Eight steps a revolution, and no frames anywhere.** 45° divides 90, so a wedge step has an integer
footprint and is an ordinary masked archetype (§9.1 option A). The alternative -- a frame per step --
would put 48 entries in a weld table that has to be invalidated on block death, and it would buy a
smoothness the house style does not want. The eight sectors are eight authored masks rather than one
mask in four yaws, so which way the flight winds belongs to the recipe rather than to the
extension's rotation enumeration.

**The steps rest on the newel; they do not hang off it.** [BrickFailure §4.5](BrickFailure.md) says
two studs of contact holds about seven hanging bricks and a step is roughly eight, so a step
cantilevered off a column is *at* the failure threshold. Each step therefore carries its own slice
of the column and clips to the one below: compression, which is free. What overhangs is the tread,
and that is exactly what §9.3 says should shed when something hits the building.

**In the building's own grid, which is the whole of it.** A staircase's blocks go in the host's
chunk, at the host's own cells. That is not what §9.4 designed -- it designed a sub-assembly with a
chunk, a body and a materialisation state of its own -- and building it as designed produced two
bugs that are the same bug from opposite sides:

* **A collapsing building landed on its own staircase and stopped there.** A decorative fixture was
  outside `solve_stress`, but its collision was an ordinary static body, and *anything a falling
  section can rest on is holding the building up, whatever the stress solve believes.*
* Moving it onto a collision layer nothing structural could touch fixed that, and then **a building
  came down around a staircase left standing in the rubble** -- because nothing in the world
  connected the two. A support test that dropped the flight when its floor went made that less
  visible without making it less wrong.

A staircase in a brick building is made of bricks, in the same grid, clipped to the floors it lands
on. With the blocks in the host's chunk, every one of those problems is somebody else's solved
problem: the stress solve carries them, a section that breaks off takes the steps inside it, the
island it becomes has them, the damage record already keys on block id, and something landing on the
flight breaks it the way it breaks anything else. The trade is real and it is accepted rather than
hidden -- **a staircase that comes apart with the building is a staircase the building can lean
on.**

What went with the redesign: three wake triggers, a streaming budget with a wake-per-pass cap, a
sleep range, a per-fixture damage record, a support test, a release path, a debris range, a
collision layer and a merged-box collision builder. None of it is missed, and the file that replaced
it is a record plus a generator.

**Dormancy is inherited rather than implemented.** A building that is still a recipe has no bricks
at all, its staircase included -- which is the tier §9.4 wanted, for free, because the building
already had it.

**A staircase needs a stairwell.** The floors it passes through are the building's own blocks, so
the fixture carves the shaft before laying its steps: `remove_block`, not `kill_block`, because this
is an EDIT and not damage. The cells come back, the ids stay, and `get_dead_blocks` leaves a removed
block out -- so a stairwell never reads as a hole somebody shot, and an undamaged building with a
staircase in it is still undamaged. Without the carve, three steps of a twenty-seven step flight
were silently refused wherever a floor crossed them.

**What it costs.** Measured on a quiet machine against the same city built with `--no-fixtures`:

| | without staircases | with one in every building |
|---|---|---|
| `--shot` mean | 16.7 ms | **16.7 ms** |
| `--shot` over budget | 1 of 729 | 3-9 of ~705 |
| `--stress` mean | 16.7 ms | **17.0 ms** |
| `--stress` over budget | 9 of 2815 (0.3%) | 32 of 2749 (1.2%) |
| `--stress` memory after trim | 142.7 MB | 145.1 MB |

The phase that pays is the damage queue draining (19.2 ms mean, 52 fps): a building with a
staircase in it has more bricks to take apart. That is the cost of the stairs being real, and it is
the same cost any other brick would have.

**Gate met**, in three halves: `tools/fixture_probe.gd` passes **47 checks** on the truth layer,
`godot --path . -- --fixture` passes **17** in the city -- one chunk for a building and not two, a
figure standing on a tread it found by looking, shooting the flight damaging the *building*, and
toppling the building taking the whole flight with it -- and the workshop's own `-- --gate` passes
**15** on the authoring end. `tools/build_probe.gd` is at **93** with the recipe format's share.

**Authored in the workshop, not hard-coded into the city.** `K` drops a staircase where the ghost
is, and `BuildRecipe` v3 carries it -- one record per fixture rather than a column, holding a kind,
a cell, a role and its parameters, in **frame 0's grid**, which is the same coordinates the bricks
are in. That is what makes a fixture rebase with the build, and it is where the interesting bug
would have been: a single-frame placement rebases the CELLS and a multi-frame one rebases the
TRANSFORM (see below), so the fixture had to land in the same place under both. The probe asserts
exactly that, by building the same house twice with and without a second frame.

Two smaller decisions worth keeping. **Undo is one stack**: bricks and fixtures come off in the
order they went on, because two stacks would let a brick be removed from under a staircase that
was authored after it. And the **default flight is measured, not guessed** -- from the placement
cell to the highest brick above it, at two plates a step, never shorter than one revolution --
because a guess produces a staircase to nowhere.

**Gate met**, in three halves now: `tools/fixture_probe.gd` passes **57 checks** on the truth layer,
`godot --path . -- --fixture` passes **32** in the city, including a figure a little under three
bricks tall standing on a tread, and the workshop's own `-- --gate` passes **16** on the authoring
end. `tools/build_probe.gd` is up to **93** with the recipe format's share of it.

### Chamfered edges, for no triangles

A moulded brick has a small 45-degree chamfer on every edge, and it is most of what makes one read
as a moulded object rather than as a box: the bevel catches a highlight along the top edges and goes
dark along the bottom ones, so a corner separates from the face beside it even in flat light.

Built as geometry it is a ring of four quads per face -- **five times the triangles** -- for a facet
that is 13 mm wide at game scale (a real brick chamfers about 0.3 mm on an 8 mm stud, and a stud
here is 0.35 m) and is sub-pixel past about twenty metres. What the eye reads at that size is the
*lighting*, not the silhouette. So it is shaded: `shaders/brick.gdshader` bends the normal to
45 degrees inside a band along each block edge, and leaves the geometry flat.

The machinery was already there. The seam needs distance-to-block-edge, which needs UV in metres and
UV2 as the block's face size, and that is exactly what a chamfer needs too -- so the bevel costs two
texture-space derivatives for a tangent frame and nothing else. No vertex format change, no second
pass, and it works on the **cheap shells** as well, because they carry a brick-sized UV2 for the
same reason.

Three details worth keeping:

* **A chamfer is a flat facet, not a ramp.** The tilt does not fall off with depth into the band --
  it switches on across it, with one pixel of smoothing so the switch does not crawl.
* **The bevel is glossier than the face.** The mould polished it, so roughness drops inside the band
  and a specular line runs along every edge. That is most of what says "plastic" rather than
  "painted box".
* **It fades out by 55 m**, before the seam does at 75 m. A dark line stays legible when it is
  sub-pixel; a highlight shimmers. Same reason the spec gives for layer lines.

`B` toggles it in the city.

**Gate met.** `godot --path . -- --chamfer` passes **5 checks** by differencing rendered frames:
with the bevel on, 4-75% of sampled pixels change up close -- edges, not a tint -- and under 1%
change from a hundred metres away, which is the fade working. A shader with no test is a shader
nobody can tell is broken.

### What is inside a building

[Interiors.md](Interiors.md) argued that contents are where the object count really explodes: 5000
buildings x 20 rooms x 15 objects is 1.5 million items, and spawning those as nodes is not a budget
question but a crash. The answer is the ladder again, one level down -- and the first pass of it is
in.

**A room is generated, not authored.** `RoomManifest.rooms_for` cuts a building into storeys and
quarters by the same rule that lays its floors, so a room is a box in cells, a kind and a seed. Its
**contents** come from `(building seed, room id)` through a hash: the same room always holds the
same things and nothing is stored. A city of 22 buildings holds **no rooms at all** until something
asks one what is in it, and the gate checks exactly that.

**An item is bricks in the host's grid**, which is the lesson `Fixture` learned the hard way, applied
before it could be learned again. Interiors §9.2 wanted furniture decorative, with a body of its
own; that is what a staircase had, and it produced a building that landed on its own staircase and
then a staircase standing in the rubble. A crate is three blocks, a table five, laid into the
building's own chunk -- so it is destructible, meshed, collided, rideable and spillable by paths that
already existed, and Interiors §7 question 3 answers itself.

**Three triggers, and they are not the same urgency** (Interiors §5). PROXIMATE is presentation:
walk within 26 m of a room and it lays its contents, one room per streaming pass; walk past 42 m and
it takes them back. Getting the building itself that far is the other half, and it took a second
pass to see -- "Walking up to a building is what makes it bricks", below. COMPROMISED is truth: a blast opens every
room its volume reaches **before the hit lands**, whether or not anybody is there, because the
contents are part of what the damage does. And VISIBLE is Interiors §3's portal test, below.

**The portals are holes somebody blew.** §3 wanted "can see into it through an opening", and a
generated building has no doors and no windows -- so every opening in the city is damage, and
`openings_of` finds them by walking the room's four wall planes a brick at a time and taking the box
of what is missing. The consequence is the good kind: **an undamaged building has no openings, so
the portal test costs nothing until somebody shoots one.**

Seeing in is then a distance cap (70 m, which is Interiors §7 question 2's answer), a dot product
against the view axis, and one ray per opening -- if the ray reaches the middle of the hole, it went
through the hole. Visibility also *holds a room open* past the range that would otherwise shut it,
which is §3's hysteresis written as a condition rather than a timer.

Two things had to be budgeted, and one of them was a bug first. Re-reading a room's walls is about
two hundred solidity queries, so **two rooms a pass** are re-read and the rest use the last answer,
which for "is there a hole in that wall" is never stale enough to matter. And the room loop was
scoped to the walking range, so the portal test was never asked anything at all until it was scoped
to the view range instead -- a test that cannot fire is worse than one that fails.

**What is kept is the diff, and only the diff.** Closing a room asks which items are still whole;
the ones that are not go in `gone` and never come back. Everything else regenerates. An untouched
room has no record at all.

**A room that fell while nobody was looking resolves rather than simulating** (§5.2). Down is read
from the chunk's own transform -- snap world-down into the room's frame, take the nearest of six --
and each item is placed against whatever face is now the floor, at its authored position with a
seeded offset. Deterministic, instant, and indistinguishable from having watched it tumble.

**A room that came down spills what was in it** (Interiors §4.1). A room that was OPEN when its
building fell needs nothing: its contents are bricks in the chunk that becomes the island, so they
ride it. A room that was SHUT is marked `spilled` and nothing is built -- the middle of a collapse
is the worst possible moment to construct furniture for a room nobody may ever walk to. When
somebody does walk to the pile, within 34 m, the manifest runs **into the wreck**: each item placed
against whatever face is now the floor (§5.2's resolve), with about a third of its bricks killed
from the room's own seed, so the same wreck looks the same on a second visit and on another machine.
Four items are laid in full and the rest are written off -- §4.1's degradation ladder, minus the
generic-rubble item, which does not exist yet.

A kitchen therefore spills kitchen things, and looting a building you flattened finds what was in
it rather than a slot machine. It costs nothing to have, because the manifest was already the cheap
representation.

One bug worth recording, because it was the API's fault and not the caller's: rooms are generated
lazily, and `mark_rooms_spilled` walked the list rather than asking for it -- so a building **nobody
had ever looked inside** spilled nothing at all, which is exactly the building most likely to fall
over unwatched. It generates them now.

**Gate met.** `godot --path . -- --rooms` is at **27 checks**, with the portal case and the spill in
it: from
sixty metres nothing is open, a blast puts a hole in a wall, the rooms are shut again by hand, and
then *looking through the hole opens one* -- and turning away shuts it. `tools/interior_probe.gd`
passes **53 checks**: rooms generate identically twice and
differently for a different building, a manifest is a pure function of its seed, an unopened room
creates no chunk and no bricks, opening one puts its contents inside the room's own box, closing it
takes them out without the building counting it as damage, the diff remembers exactly what was
destroyed, a blast opens the rooms it reaches with nobody there, and a room on its side resolves its
contents to the new floor and does so the same way every time. `godot --path . -- --rooms` passes
**13** in the scene: solid, destructible, streamed by distance, and remembered afterwards.

### Merged collision for standing buildings, and the cost that was not where it looked

One box per brick is what a large body costs the solver, and a census settled who was actually
carrying them: in the 200-building stress pass, **112,321 boxes across 37 standing buildings**
against 1,827 in all the settled wreckage put together. The wreckage already merged when it came to
rest ([limitation 2](#known-limitations)); the buildings never did.

They do now, on the same rule: **once it has stopped.** Not at promotion -- a building materialises
*because* something hit it, so merging there would be undone by the hit that caused it, which is
the mistake `IslandManager.spawn` already records. A building merges when the shooting has moved
on: nothing queued, nothing dirty, every island settled, and ten seconds since its last hit, one
building a tick. **111,580 boxes become 8,634**, for 102 merges costing 112 ms in total and 3.5 ms
at worst, and no un-merges at all in the pass.

**What it bought in frame time: nothing measurable.** 17.2 ms mean either way; the worst frame is
56.9 ms against 69.0 and the settled phase loses its one frame over budget, which is a direction
rather than a result. The thing it should help -- debris landing on many standing buildings at once
-- is not what the stress pass spends its time on. It is kept because 103,000 fewer collision
shapes is a real resource saving with no cost attached, not because the frame got faster.

**And the measurement found something much more expensive on the way.** Merging looked catastrophic
at first: the damage-draining phase ran at 9 fps. It turned out not to be the merging at all -- the
control arm, the same body rebuild with the shapes left per block, was just as slow, and so was a
run with merging switched off entirely. The regression was already there, from the interiors work:
**`_apply_blast` compromised rooms anywhere in the city, and building a room's contents takes its
host's body out of the physics space to add the collision, which wakes everything resting on that
building.** Once per blast, across 2,064 shots.

Interiors §5.1 had already written the fix down -- *"rooms near the camera spawn full contents;
distant ones write spilled into the diff"* -- and it had simply not been implemented that way. Only
rooms within about 39 m of the blast are built now; the rest are resolved in the record for nothing.
The phase went from **107.7 ms a frame (9.3 fps) back to 21.7 ms (46 fps)**, and the whole run from
19.6 ms to 17.2.

Two lessons worth keeping, both about the same thing:

* **Swapping the shapes on a static body is not priced by the shapes.** It is priced by everything
  resting on that body waking up. That is why merging waits for a still scene, and why adding a
  room's furniture mid-firefight was so expensive.
* **Measure the baseline you think you have.** Three arms of this experiment were run against a
  contaminated one, and every conclusion drawn from them was wrong.

### What a room costs, and the two whole-building bills inside it

The question was whether interiors are worth streaming per room, or whether per
building is simpler and good enough. It has no answer at 20x20x18 studs, so `--big` builds the same
city out of buildings up to **28 x 22 m on plan and 84 m tall** and `--interiors` measures the same
one three ways.

Rooms had to scale first. The split was "one, or two per axis if the footprint is at least 20
studs", which says every building has four rooms a storey however big it is -- and would have made
per-room streaming look four times cheaper than it is on exactly the buildings in question. A floor
is cut into rooms of about seven studs per axis now, which leaves the existing city untouched and
gives the 80x64 tower 80 a storey, 4,000 in the building.

On that building -- 50,289 bricks, 4,000 rooms:

| | per unit | whole building | resident |
|---|---|---|---|
| a room (x4000) | 224.7 ms | 899 s | +0.6 MB |
| a storey (x50) | 256 ms | 12.8 s | |
| the building (x1) | 444 ms | 0.44 s | **+50.7 MB, +25,537 boxes** |

**The per-unit costs barely differ, and that is the finding.** 56% of opening one room was the face
bake and another 35% the mesh upload, and both are proportional to the *building* rather than to
what changed. The unit only decided how many times a whole-building bill was paid. So it was never
really a question about rooms.

**Bill one: the face bake.** A chunk's bake is whole-chunk, and placing a block invalidates it --
so a chair invalidated 50,000 bricks' worth of faces. Interiors are out of the bake entirely now
(`place_block(..., decorative = true)` both marks the block and leaves the bake alone, which is why
it is an argument rather than a call afterwards -- by the time you could mark it, the bake is
already gone). They are drawn instead from `FurnitureMesh`: one `MultiMesh` per chunk, one instance
per live decorative block, hung off the node that draws the chunk so it inherits its transform. A
building's furniture hangs off the building's mesh, an island's off the island's, so it rides a
collapse without anything tracking it -- which is Interiors 4.2 still working, and it had to be,
because the alternative was furniture vanishing the instant its building came down.

That the contents are boxes is not an approximation. `_add_room_shapes` has always built one
collision box per item block out of `get_block_ticks`; the mesh uses the same description.

One thing had to go with it: **a decorative block reads as open air to the bake**. It owns its
cells, so without that the floor under a chair bakes with the chair as its `other`, and the draw
rule then hides that floor for as long as the chair is alive -- a chair-shaped hole in the floor it
is standing on.

**Bill two: the collision swap.** With the bake gone, one room cost 104 ms, and 22 ms of that was
`_add_room_shapes` lifting the building's body out of the physics space and putting it back. That
call is priced by the body's shape count, and the body had 56,269 shapes. So a building's open
rooms collide on **their own static body**, made on demand and freed with the bricks. It never has
to ride anything: a piece that breaks off builds its collision from the chunk, decorative blocks
included, so the furniture is already covered by a body that exists.

    a room, before          224.7 ms     +0.6 MB
    with the bake out       104.1 ms     +0.0 MB
    with its own body         0.9 ms     +0.0 MB

	the building's 4,000 rooms:  899 s  ->  4 s
	all of them at once, resident:  +50.7 MB  ->  +1.0 MB

**Per room is now the cheap option as well as the frugal one**, which is not where it started. Per
building is 178 ms in one frame against 4 s spread over 4,000 passes, and it holds 25,537 more
collision boxes to do it.

Two notes on measuring it, both mistakes worth not repeating. The first version of the pass ran one
arm on the 4,000-room tower and the other on a 180-room one, and let `_merge_quiet_buildings`
rebuild the body inside a timed region -- 30 merges and 28 un-merges deep. And when the fixes
landed, the harness went on forcing the bake and mesh the real path no longer does, so it kept
reporting 104 ms for work nothing performs. **A harness that measures the code you replaced is worse
than no harness.**

The last of it was a guard. `_disable` redraws the furniture, and `get_decorative_blocks` walks
every block in the chunk -- so a burst of fire at an *unfurnished* tower paid for a scan of the
whole tower per hit, which cost the stress pass a millisecond of mean frame and nine of its damage
phase. Buildings that have had something laid in them are remembered, and the rest return
immediately.

### Interiors and structure: one grid, two roles

A building and the things inside it are the same bricks in the same grid. They are not the same
object to the solver, and until this thread they were: a room full of furniture made a tower
heavier and moved where it balanced, and a hit hard enough to take a wall out had to carry the
chairs as load on the way down.

**`Block::decorative` changes two things and nothing else.** It weighs nothing in `solve_stress`,
so a furnished tower is not closer to collapse than an empty one; and it is left out of the centre
of mass and the support footprint in `check_stability`, so what a building balances on is what it
is *built* of. Same chunk, same occupancy, same bake, same collision, same damage record. It is
grounded through whatever it rests on, and it is still in the list `check_stability` hands to
`split_island` -- so it rides the island the floor it stands on rides, which is Interiors §4.2 for
nothing.

BuildMode §9.2 asked for this role twice and got the **unit** wrong both times: a decorative
*frame*, with a chunk and a body of its own, gave a building that landed on its own staircase, and
then, with the layers fixed, a staircase standing in the rubble. The unit is the block.

**The probe for it found something much worse underneath.** `RoomManifest` worked its storeys out
from a `COURSES_PER_STOREY` of six while `TowerRecipe` laid a floor every four, and took a slab's
surface to be one plate above its base rather than `SLAB_PLATES` above it. The two numbers had
never agreed and had no way to. The header said the opposite --

> a building is cut into boxes by the same rule that lays its floors, so a room's ceiling is a
> floor and its walls are walls

-- and nothing ever showed it, because a static body holds anything up. **Every item in every room
in the city was laid one plate above the floor**, clutched to nothing. A grounding pass over a
furnished building returned the whole contents of it as detached groups waiting to be spawned as
debris; the only reason the city never did it is that opening a room does not mark the building
dirty. Storeys are read out of `TowerRecipe.layout()` now, so there is one number instead of two.

A tower of 18 courses had 3 fictional storeys and has 5 real ones, so the stress pass compromises
4,400 rooms where it compromised 2,600. `RoomManifest.item_count_for` keeps that from costing what
it looks like it should: a blast nobody is watching no longer generates a manifest in order to
count it, because the count is in the seed and "everything in here is gone" is a set of indices.

	--stress --buildings=200   17.2-17.7 ms  ->  17.6-18.2 ms
	compromise total                             75 ms over 4,400 rooms

That pass moves 10 ms a run in its damage phase, so the mean is the only figure in it worth
reading, and it is up about half a millisecond for having twice as many rooms that are actually
there.

### Windows, and where a hole in a wall may go

Interiors §3 makes visibility a portal test, and every opening in the city was a hole somebody had
blown -- so it could only fire on a building that had already been shot. A room could be walked
into and never seen into.

A window is a gap in a *run*. The run lays the full wall thickness in one pass, so a gap in it is a
hole clean through, and the only question is where the gap may go. **The first answer was wrong in
a way worth keeping.** Cutting the top two courses of a storey and letting the floor slab be the
lintel builds, looks right, and leaves the slab joined to its walls only at the piers:

| | top two courses | one course, brick lintel |
|---|---|---|
| splits | 1,321 | 554-579 |
| breaks | 94 | 33-42 |
| impacts | 428 | 227-250 |
| damage phase | 92-134 ms (**7.5 fps**) | 22-25 ms |
| `--shot` | 18.4 ms, 111.5 MB | **16.7 ms, 77.0 MB** |

A building is held together at the band where its floors meet its walls, and windows do not go
there. So the window is cut in the course *below* the storey's last one, and the lintel is that
last course: the bond alternates which pair of walls owns the corners, so the course above a window
always starts half a brick offset from the one it is cut in, and the bricks over the opening are
carried on the pier at one end each. That is how a brick lintel is built. With the openings also
aligned to a four-stud boundary, a tower has **fewer** blocks than it had with solid walls (695
against 719), because a run breaks into whole bricks either side of an opening instead of closing
each pier with 2x2s.

`openings_for` returns one box per **aperture** now rather than one per side. Per side was harmless
while the only openings were craters -- one blast, one crater -- and wrong the moment a wall had
two windows in it: the bounding box of both is centred on the pier between them, and §3 aims its
ray at that centre, so the answer was always "that hit brickwork".

Two gates had claims that windows falsified, and both are better for it. `--rooms` asserted that an
undamaged wall has no openings; it now asserts the wall has windows, that each opening is one
window rather than a box drawn round two, and that **looking in through one opens the room from
sixty metres with nothing fired**. `--lod` fired at a fraction of a tower's height and hit a piece
its own first shot had knocked off; it aims at a floor slab now -- the one band solid all the way
across -- and walks round the building until the ray reaches the building rather than the debris in
front of it.

### The workshop builds in two layers

Nothing about a brick's shape or position can say whether it is structure. A table built out of
wall bricks is a table, and only its author knows, so the role is authored: `I` switches the
workshop between **STRUCTURE** and **INTERIOR**.

Everything else about placing a brick is identical in both -- same parts, same six grids, same
snapping, same undo -- because they are one build and not two. What differs is one bit per block in
the recipe (v4, and a v3 file loads as structure all through, which is what it is), the ghost's
colour, and the fact that the city reads that bit into `Block::decorative` when it materialises the
build. Undo takes the role with the brick and so does `T`: turning a chair is not a way to make it
load-bearing.

One bug on the way, of a kind worth naming because GDScript will hand it to you again. Collecting
the ids per chunk with

```gdscript
if not by_chunk.has(chunk):
	by_chunk[chunk] = PackedInt32Array()
(by_chunk[chunk] as PackedInt32Array).push_back(id)
```

compiles, runs, and marks nothing at all: a `Packed*Array` is a **value**, so indexing the
dictionary hands over a copy and the push lands on the copy. Read out, append, put back.

### Walking up to a building is what makes it bricks

Rooms only stream for a building that is already bricks, and for a long time the only thing that
made a building bricks was **being shot**. So an intact building had no interior at all, and the
first shot into one materialised it and compromised its rooms in the same frame: the furniture
arrived *in the act of being destroyed*. Walk up to an untouched tower and there was nothing inside
it, because nothing had asked.

The comment above `ROOM_RANGE` used to defend this -- "materialising a whole tower because somebody
walked past it would be the opposite of the point" -- and it was wrong in a specific way. It is only
the opposite of the point if residency is *expensive at rest*, and by this point it is not: a
building that has been quiet for ten seconds merges its collision down ("Merged collision for
standing buildings"), and a resident building past 110 m has already given its mesh back. What was
being protected against had been fixed somewhere else.

So residency is a distance as well as a hit. `PROMOTE_RANGE` is **46 m**, measured from the
building's BOX rather than its origin -- standing with your face against the wall of a forty-metre
tower is not forty metres from that building, and the rooms behind that wall are the ones about to
be asked for. The band is chosen by what sits on either side of it: far enough outside `ROOM_RANGE`
(26 m) that a building is bricks well before its rooms want to open, and far enough inside
`TRIM_RADIUS` (90 m) that the trim can never take back what the walk just gave. Two a pass, nearest
first, capped at a queue of 24 so a spawn or a teleport cannot queue a district at once.

**Promotion without a solve.** A hit changes the structure and the structure has to be re-answered.
Walking up to an intact building changes nothing -- a stress pass, a stability check and a
detached-group walk over every brick would all return "nothing happened". So `_promote` takes a
`solve` flag, and the proximity path passes `b.is_damaged()`: a building that was hit, trimmed, and
has now been walked back up to still gets its solve; one that has never been touched does not.

**And a queue served in the wrong order is a queue that never arrives.** The first attempt looked
like a failure of the range: the building the camera was pressed against went resident and then
furnished nothing, for fifteen seconds. It was not the range. Rooms open **one per streaming pass**,
and the candidates were walked in grid-cell order -- which was harmless while two or three buildings
in the city were bricks, and became a starvation bug the moment a whole district was. The buildings
at one corner of the search took every pass. Rooms are picked nearest-first now, the same order the
promotions use, and the expensive half -- scanning walls for holes to see through -- runs only when
nothing is close enough to walk into, because there is no point paying for a portal test while a
room at arm's length is still waiting.

**Cost: none that the passes can find.** `--shot` 16.8 ms against 16.7; the 200-building `--stress`
17.3 against 17.2, which is the same number twice. The gates say the rest of it: from 150 m the
building is a shell holding nothing, and standing against it makes it bricks, furnishes a room and
lays real bricks **with the building still undamaged and nobody having fired a thing**.

The `--walk` gate lost a claim to this and got a better one. It used to assert that a walker is
stopped by the shell tier's collision, four metres from a wall -- which is now inside
`PROMOTE_RANGE`, so what stops the walker is bricks. The shell's collision is still worth testing
and is still tested, from seventy metres with a ray, which is how a shell gets hit in practice
anyway: `FIRE_RANGE` is 2 km against `SHELL_RANGE`'s 260 m, so most shots that land on a building
land on one of these.

### Wreckage, given back

An island that came to rest kept a chunk, an occupancy grid, a face bake, a mesh and a body for the
rest of the scene, however far away it was and however long nobody had looked at it. That is
[limitation 18](#known-limitations) and the sixth item on this document's own "Next" list, and it is
most of the 1.2 GB worst case.

Every other layer had already been given the ladder: a building is a recipe until something hits it,
a fixture is built with its host, a player creation is a recipe and a shell. Wreckage never was,
because it is the one thing with **no recipe** -- it is the arbitrary leftovers of a collapse, and
the only description of it is the blocks themselves.

So that is the record. `scripts/chunk_record.gd` is a cell, an archetype and a colour per block,
plus where it stands: **17 bytes a block**, against a chunk with an occupancy grid, a bake, a mesh
and a rigid body. `IslandManager` sleeps a settled piece that has been quiet for six seconds and is
more than 150 m away, and wakes it inside 120 m -- one of each per tick, because a sleep is a
capture and a release and a wake is a chunk, a bake and a mesh.

Three properties it has to have, and all three are gated:

* **It is not deletion.** The record round-trips: the same blocks in the same order, so the piece
  somebody walks back to draws byte-identically to the piece they left, and is still breakable.
* **It is not a save.** A record is captured from the world *after* the damage, so what is gone is
  simply not in it. Rubble has no history, only a shape -- which is why it needs no damage record
  where a building does.
* **Asleep is not gone.** A blast wakes what it reaches before it lands ([Plan §4.4](Plan.md):
  applying damage does not need a player nearby, only showing it does), so shooting distant
  wreckage works whether or not it happens to be resident.

**Measured.** In the gate: three toppled buildings, **3,461 blocks of wreckage, 7.7 MB resident ->
0.0 MB plus 57.5 KB of record**. In the 200-building stress pass, **47-60 pieces holding
13,193-15,902 blocks in 219-264 KB**, with resident islands down from 86 to 24 and no measurable
frame cost: 17.1 ms mean and 31 of 2727 frames over budget, against 17.0 and 32 of 2749 before it
existed.

[Interiors §5](Interiors.md) wants the same tier for room contents, which is why the record is a
type of its own rather than three fields on `BrickIsland`.

**Gate met.** `tools/dormant_probe.gd` passes **21 checks** on the record -- round-trip,
byte-identical mesh, damage is absent rather than replayed, a removed block is not part of a shape,
the memory actually comes back, and the world box it keeps answers where it is while it sleeps.
`godot --path . -- --dormant` passes **16** against a real collapse: wreckage settles, sleeps when
you walk away, comes back the same when you walk back, and wakes when a blast reaches it.

### What a creation looks like when nobody is near it

A placed build used to be resident forever. It had no cheap tier -- `building_shell.gd` walks
`TowerRecipe.layout()`'s vertical bands and an arbitrary creation has none -- so `_trim_quiet`
skipped it and the streaming loop ignored it: bricks, a body and a mesh, from the moment it was
placed until the scene ended.

`scripts/build_shell.gd` is the answer to [BuildMode §12 question 3](BuildMode.md#12-open-questions),
and the choice that made it easy was taking the **recipe** as the source rather than a bounding box.
A build's recipe is its truth layer exactly as a tower's parameters are; the shell voxelises it at
two studs and a course, maps every block's box into root ticks -- **a rotated frame included**, so a
sideways panel is part of the silhouette rather than a special case -- and culls the faces between
filled voxels. The demo house is 165 bricks and **868 triangles**.

Two properties fall out of that choice rather than being engineered:

* **Damage is exact.** Gate G1b gives a tower's shell a per-band segment mask because it cannot ask
  "is block N dead". A build's shell walks block ids, so it leaves the dead ones out: the hole is
  where the hole is. `shots/build_shell_damaged.png` is the same house after a shot, with the corner
  missing.
* **A build is a building.** It arrives as a silhouette holding no bricks at all, becomes bricks
  when something shoots it, and goes back to a silhouette when nobody is near -- the same three
  tiers, the same streaming ranges, the same trim.

The trim path itself was lifted out into `_demote(id, dist)` while doing this, because a scripted
pass proving a building came back as a shell should not have to wait out `TRIM_AFTER_MS`.

**Gate met.** `tools/build_probe.gd` is at **105 checks** -- the shell is byte-identical built
twice, the coarse tier draws less, a damaged build draws a damaged shell, a rotated frame is in the
silhouette, a build with nothing left draws no surface rather than crashing, and the collision boxes
cover what they came from. `godot --path . -- --buildshot` passes **21** against the scene: the
build arrives as a shell with no chunks anywhere, a shot turns it into bricks and frames and welds,
and walking away puts back a shell whose triangle count is not the intact one's.

### A creation with more than one grid, placed in the city

`BuildingRegistry.register_build` used to refuse a multi-frame build rather than silently drop its
sideways frames. It does not any more: a `Building` holds an `Assembly` -- one chunk per frame, the
welds between them, and **a damage record per frame**, because a block id only means anything inside
one chunk. Docs/BuildMode.md §11 Stage 4b has the detail; three things had to be true first.

**Welds are part of the recipe now.** They were made at placement time in the workshop and existed
nowhere else, so a saved sideways build loaded with its frames and nothing holding them on, and
every rotated frame fell off on the first solve. `BuildRecipe` v2 carries two block ids per weld --
the frames are already known from the blocks, and a second copy of that fact could only disagree
with the first. A v1 file loads as a weldless v2, which is what it was saved as.

**The rebase went into the transform.** A city placement wants a tight chunk around exactly the
bricks it holds, and frame 0 gets one -- but a rotated frame's offset from the root is stored in
ticks, and moving its grid origin moves its bricks away from the welds. So the whole assembly is
moved by one translation in root space instead, applied to every frame alike: a rigid move, so the
tick lattice is untouched, and the build still lands with its own floor on the ground.

**The city draws one node per frame.** The root frame goes down the path a generated building has
used since M4, index patching and all; the frames past it get a deliberately simpler one -- a static
body and a full mesh rebuild each time -- because a player build is small and nothing under 65,536
vertices can be index-patched anyway. A blast hits every frame it reaches, so a hit on a panel and a
hit on a wall are the same code path.

One bug found on the way, and it was in the *indexing*, not in any of the above: the lookup grid
that answers "which buildings could this blast touch" was filled from the root footprint alone, so a
shot at a panel hanging off the side found no building at all and did nothing. It is built from the
whole assembly's box now, eight corners at a time, which a rotated placement needs anyway.

**Gate met.** `tools/build_probe.gd` is up to **74 checks** and `godot --path . -- --buildshot` adds
**12** against a real scene. `tools/demo_build.gd` writes a two-frame demo so there is something to
place before anything has been hand-built.

### Build mode, Stage 2: the workshop

`scenes/workshop.tscn` + `scripts/workshop.gd`. One frame, upright only -- no sideways building,
no fixtures, no articulation. What it proves is the loop.

**The gate is met:** hand-build a house, save it, place it in the city, shoot it, and it breaks like
a generated building -- because it **is** one. `BuildingRegistry.register_build()` takes a
`BuildRecipe` and everything downstream is unchanged: materialise, damage, de-materialise, replay.
`tools/build_probe.gd` passes **46 checks**.

**`BuildRecipe` (`scripts/build_recipe.gd`)** is the save file, the thing the city places and what
the exporter will walk -- one serialiser, three consumers (mvs-c 7). Parts are stored by **name**,
never by archetype id: ids are assigned by bake order inside one `BrickWorld` and mean nothing
across a save.

> **Placement order IS block id order**, and that is the contract the whole thing rests on.
> `BuildingRegistry` keys its damage record on block id, so id N has to mean the same brick every
> time the recipe is built. It is why `pop()` is the only removal the type allows -- taking a block
> out of the middle would renumber everything after it and silently invalidate saved damage.

Three bugs, all found by running the thing rather than by reading it:

* **`JSON.stringify` serialises a `PackedByteArray` as the STRING `"[4, 7]"`**, not as an array. A
  recipe saved fine, parsed fine, and loaded as zero bricks. `to_dict()` now emits plain Arrays of
  plain numbers -- JSON-safe by construction, so the in-memory dictionary and the file are the same
  thing. JSON also has no integer type, so every array is rebuilt element by element in both
  directions rather than cast.
* **`build()` rebasing the recipe to the chunk origin is right for the city and wrong for the
  workshop.** A city placement wants a tight chunk around exactly these bricks; the workshop's chunk
  is a fixed baseplate and the recipe is already in its coordinates, so rebasing dropped the build a
  course and every brick collided with the baseplate. It presented as "loaded 0 of 5 bricks".
* **An `ImmediateMesh` with no vertices between begin and end is an error, not an empty mesh** --
  and an empty stress overlay is the NORMAL case.

That last one is worth keeping: **compression is free** (BrickFailure 4.1), so a building that is
merely standing loads no joint at all. Measured on a plain five-brick stack: peak load 6.4, max
stress ratio **0.0000**, zero capacities. The overlay drawing nothing means nothing is hanging, not
that it is broken -- and the probe asserts both halves, a stack at zero and a real cantilever above
zero.

**The overlay is the destruction solver, not a second one.** `solve_stress` already measures tension
against the constant derived in BrickFailure 4.5 and `check_stability` already asks whether the
centre of mass is over the footprint. It tints and never gates: "does it fit" refuses a placement,
"will it hold" only colours it, because players brace impossible things on purpose.

### Damaged buildings look damaged -- gate G1b

G1 says damage survives demote -> promote byte-identical, and it did. **The picture did not.**
`_make_shell()` built from `(footprint_x, footprint_z, courses)` and read the damage record
nowhere, while `trim()` happily freed a damaged building's bricks and the streaming loop handed it
a shell back -- an intact one. So a building you blew a hole in, walked away from and looked back at
redrew whole. That is now a standing gate:

> **G1b -- the cheap representation must show the damage the truth layer is holding.**

The obstacle was that a shell is generated from the recipe's vertical bands, not from block ids, so
it cannot ask "is block N dead". It does not have to. `get_column_mask(chunk, y0, y1)` returns one
byte per XZ column saying whether anything alive remains between two heights -- generic, knowing
nothing about courses or walls -- and the registry reduces that to a **segment mask**: per band, per
wall side, 32 bits saying which stretches are still standing.

| | |
|---|---|
| When it is computed | at **de-materialisation**, and only for a damaged building -- exactly when the shell becomes the thing on screen |
| What it costs | **744 bytes and 2.43 ms** for a 40-course building with six holes in it |
| What it draws | standing segments merged into runs, so an intact side is **one quad exactly as before** |
| Intact buildings | byte-identical geometry to before the change -- the probe asserts it, because a feature the common case pays for is the wrong feature |

Two details that are not obvious:

* **A hole in the middle of a wall ADDS triangles**, because the wall splits round it (794 -> 898
  for the measured building). That is the assertion worth having: a mesh that only ever got
  *smaller* would be consistent with quietly deleting walls rather than drawing holes.
* **Inner faces take the same mask as the outer face they back onto.** A hole goes through a wall,
  and without this you could see an intact inner skin through it.

A band whose whole perimeter is gone contributes no walls **and no floor**, or a flattened building
still drew a stack of floating slabs.

`tools/shell_probe.gd` passes **28 checks**.

### Editing, which is not damage (`remove_block`, `can_place`, `would_connect`)

Build mode Stage 1 (Docs/BuildMode.md section 11). Three calls, and the placement loop sits entirely
on them.

**`remove_block(chunk, block_id)` undoes a placement and gives the cells back.** That is the half
`kill_block` deliberately does not do: a destroyed block keeps its cells, so nothing can be rebuilt
into a crater (limitation 22), and an edit has to be the opposite. The two are now separate
operations with separate flags, and the probe pins both directions -- a removed block is **not** in
the damage record, a killed one **is**, and a killed one still refuses a placement on top of itself.

The record survives as a tombstone owning no cells. Compacting would renumber every block after it,
and block ids are what the damage record, the index partition and the block -> shape map all key on.
`archetype` stays valid on a tombstone too, because the face bake and `get_block_boxes` walk every
block and index it with no guard at all -- so the flag they skip on is `removed`, not a null
archetype. That was the one real trap in the change.

**`can_place` and `would_connect` are the ghost, and neither writes anything.** `can_place` is
exactly the occupancy test `place_block` runs, without the write. `would_connect` returns the number
of stud joints a part *would* make -- so the three tint states are one call: **-1 red** (will not
fit), **0 amber** (fits but floats), **positive cyan** (connects). It counts upward and downward
joints alike, so sliding a plate in underneath something already standing reads as connected, and it
honours the stud masks, so a brick on a tile correctly reports **no** connection rather than
promising a joint the solver will not make.

The joint count is contact area, which is what the stress solve charges for: a 1x1 makes one, a 2x2
makes four.

**Gate met.** Build a wall, build the same wall with a placement undone in the middle, and the two
are byte-identical -- same alive count, same faces emitted, same vertex buffer, same colours.
`tools/edit_probe.gd` passes **67 checks**, and a masked part gives back only the cells it owned, so
something sitting in a buttress's notch survives the buttress being removed.

### `BrickWorld` (`gdextension/brick/src/brick_world.{h,cpp}`)

Resident C++ state, not a stateless helper. GDScript talks to it in deltas; block data never
crosses the boundary. **Archetypes** are the flyweight — the tower's blocks resolve to three
distinct collision shapes. **Chunks** are dense: `occupancy` holds a block index per *cell*, so a
block bigger than one cell writes its id into every cell it covers. **One seeded RNG** lives here
and nothing else may draw randomness (Plan D9).

### Connectivity

**Stud connections only, and they are vertical.** Two blocks join when their footprints overlap in
XZ and one sits directly on the other. Two blocks side by side in the same course do **not** join —
that is what makes a bonded course mean something structurally, and the probe pins it.

**The edge list is never stored.** The occupancy grid answers the question in a handful of integer
lookups, and a derived graph cannot go stale when a block dies.

### Stress and collapse (M2)

- **Load follows the support path, not gravity.** `solve_grounded` floods from the foundation and
  records each block's *depth* — how many joints it is from the ground. `solve_stress` then walks
  that BFS order backwards and pushes each block's load to every neighbour of strictly lower depth,
  shared by contact area.
- **Two wrong versions were built first, and both are worth remembering.** Flowing load straight
  down leaves an undercut wall transmitting nothing, so the tower levitated over a hole. Flowing it
  down a *spanning tree* funnels an entire building through one edge — an intact 40-course tower
  measured 12.7× over capacity. A depth DAG with area-weighted sharing is the version that is right
  in both cases: in an intact wall the lower-depth neighbours simply *are* the ones below.
- **Capacity comes from contact area.** `for_each_neighbour` already fires once per shared cell, so
  counting its calls gives the stud contact, and sharing load equally per call shares it by area.
  A brick holding on by two studs carries a quarter of what one holding by eight does.
- **A failed joint consumes its brick.** This is what turns a correct solve into a visible collapse.
  Without it nothing is ever *removed* when a structure fails: the pieces are correctly reclassified
  as debris and then sit exactly where they were, because they are still resting on each other.
- **The cascade runs one round per physics tick**, and continues while *either* crushing or
  detachment is still happening — crushing alone counts, because it removes material and
  redistributes load even when nothing comes loose that round.

### Islands are chunks

A detached island is not a bag of boxes — `split_island` gives it **a chunk of its own**: same
grid, same archetypes, same connectivity, its own `Transform3D`. Everything that works on a
building works on a piece of one, so an island can be shot at, re-solved and split again. That is
what makes impact fracture possible at all.

- **World queries go through the chunk's transform**, so a tumbling island is damaged in its own
  frame and nothing upstream needs to know it moved.
- **Collision goes on the body's RID**, not as `CollisionShape3D` children. 633 shapes as nodes
  measured **1.8 seconds** to spawn; on the RID it is milliseconds — the same
  shapes-before-space lesson as the static body.
- **A hard landing SHEARS JOINTS; it destroys nothing.** `separate_near` marks the joints in the
  contact band as released, so those bricks come loose as debris and everything else stays whole.
  An earlier version called `apply_hit` across the contact face with a radius that grew four times
  faster, so a single landing deleted dozens of bricks — the same masonry assumption the stress
  solve used to make, and just as wrong (Docs/BrickFailure.md).
- **Impact is detected as a sudden loss of speed** rather than a contact signal, which keeps it
  inside one deterministic tick order. It samples across the island's whole bottom face: these are
  hollow wall sections, so a single sample at the bounding-box centre finds empty air.
- **A settled island wakes when anything happens to it**, and so do its neighbours within 6 m. A
  frozen body never re-evaluates, so one that is shot — or that has just lost the piece it was
  resting on — otherwise hangs exactly where it stopped. That was the source of floating wreckage.
- If damage cuts an island in two, `get_components` sees it and the smaller pieces leave as islands
  of their own, inheriting the motion they had.

A cluster that comes to rest freezes into a static body. The **age guard is load-bearing**: a body
reports `sleeping` before it has taken its first step, so freezing on `sleeping` alone froze every
cluster the tick it spawned and the tower came apart into pieces that hung in the air.

### Parts are not required to be boxes

An archetype carries three optional masks, and an empty mask means "the whole box", so the common
case costs nothing:

- `cells` — occupancy inside the bounding box. The cells a part does **not** fill are genuinely
  free, so something else can sit in its notch.
- `studs` — which columns carry a stud on top. A tile is solid but studless: things rest on it and
  nothing clips to it, which the connectivity graph has to see.
- `sockets` — which columns accept a stud underneath.

Placement, meshing, connectivity, stress and collision all read the masks. A box part still
collides as one box; a masked part collides as its solid cells, so **shape index no longer equals
block id** and the caller keeps a block → shape-indices map. The test tower's cornice is a masked
part, so the path carries real load in the real scene rather than only in a probe.

Not built, with the seam left for it: a **baked custom mesh and convex colliders per archetype**.
Today a masked part is a voxel approximation — right for the graph and the physics, visibly stepped
for a true curve.

### Collision

One `PhysicsServer3D` static body per chunk, no nodes. Every block gets its shapes whether alive or
not, so the block → shape-indices map is fixed for the life of the chunk and killing a block is a
handful of `body_set_shape_disabled` calls rather than a body rebuild. Shapes are shared per
distinct footprint: 16,590 blocks resolve to **4 shape RIDs**.

> **Shapes go on before the body joins a space.** Adding them afterwards makes the server
> re-register the body on every call, which is quadratic. At 16.5k blocks that was **18 seconds**
> of load time; moving `body_set_space` after the loop made it **33 ms**. Same for the small tower:
> 37 ms → 1.0 ms.

Collision layers live in `scripts/layers.gd` and nowhere else.

### Meshing

A face exists only where the neighbouring cell is empty or dead — that kills a block's own interior
faces *and* the seam between two touching blocks. The mesher takes an optional mask; with one, only
masked blocks are meshed **and only masked blocks cull each other**, so a group that breaks away
grows a real surface where the break was. Same code path builds the chunk and every cluster.

Blocks walk in id order, cells in (x, y, z), faces in a fixed order, so an identical world meshes
byte-identically. Every block records the **index range it owns**; that partition is measured and
tiles the mesh exactly, and nothing consumes it yet — which is now the single most expensive
omission in the project.

### Block seams (`shaders/brick.gdshader`)

Face culling deletes the geometry between touching blocks, so a run of same-coloured bricks would
mesh into one flat rectangle and read as a slab. The mesher writes, per vertex, `UV` = position
within the **block's** face rectangle in metres and `UV2` = that rectangle's size, so
distance-to-block-edge is `min(UV, UV2 - UV)` and the seam has a constant real-world width whatever
the block size. Cell boundaries inside one block carry no seam, which is what makes a 2×4 read as
one brick rather than eight. Width is floored at one pixel via `fwidth` and fades with distance —
**the same machinery spec §2's layer lines need**, evaluated along `print_axis` instead of the face
plane.

### Recipe

`scripts/tower_recipe.gd` builds the test tower from parameters. Courses alternate which pair of
walls owns the corners, which does two jobs: it offsets every wall course to course so vertical
joints never line up, and it makes the four walls **one structure**. The first version fixed the
corners, so the front and side walls never overlapped in XZ, shared no stud edges, and stood and
fell independently — no structural conclusion from that tower meant anything.

---

## Measured

Vulkan, AMD Radeon, 1280×720, **debug build of the extension**.

### 17 m tower — 756 blocks (12 of them masked cornice parts)

| | |
|---|---|
| Static body | 840 shapes for 756 blocks, 4 distinct, 1.8 ms |
| Intact stress | max ratio 0.467, capacity 26/cell, 0.3 ms |
| Collapse | 7 cascade steps, island dropped 12.5 m |
| Impact | 1 hard landing at 13.3 m/s cost 41 blocks |
| **Frame time** | **mean 16.3 ms, worst 21.1 ms, 0 of 302 frames over 33 ms** |

### 150 m gate tower — 16,590 blocks, 357 courses

| | |
|---|---|
| Recipe build | 11 ms |
| Face bake (once) | 257 ms |
| Static body | 16,758 shapes, 4 distinct, 56 ms |
| Intact stress | max ratio 0.564, capacity 190/cell, **6.6 ms** |
| Collapse | 34 cascade steps, 2,366 blocks lost, 2 islands, largest drop 11.8 m |
| **Cascade step** | **22 ms typical, 67 ms worst** (was 213 / 2654) |
| **Frame time** | **mean 17.4 ms, worst 128.3 ms, 37 of 302 frames over 16.7 ms, 3 over 33.3** |

A cascade step now breaks down as `stress 13 + groups 2 + index 8 + upload 0.1 ms`.

### What the gate cost, and three traps that were not where anyone guessed

| Fix | Before | After |
|---|---|---|
| `body_set_space` **after** adding shapes, not before | 18,000 ms | 33 ms |
| Surface created once, index bytes patched in place | 175 ms upload/step | **0.1 ms** |
| `body_set_shape_disabled` batched outside the space | 245 ms at 74 blocks | ~1 ms |

All three are the same trap wearing different hats: **a physics-server call whose cost is
proportional to the body's total shape count, issued in a loop.** The first two were found by
measurement after a wrong guess; the third by noticing a timing column that tracked the *crushed
block count* rather than the block count.

A fourth change — baking faces once and flipping index slots — took the C++ mesh build from 86 ms
to 4 ms but was **not** the bottleneck it was predicted to be. It only mattered once the upload
stopped dominating.

`tools/m0_probe.gd` passes 22 checks, `m1_probe.gd` 37, `m2_probe.gd` 26, `m3_probe.gd` 41,
`palette_probe.gd` 532, `edit_probe.gd` 67, `shell_probe.gd` 28, `build_probe.gd` 46,
`orient_probe.gd` 51, `frame_probe.gd` 67.

> **Measurement hygiene:** `Engine.get_frames_per_second()` reports frames rendered in the *last
> second*, so one stall drags a whole window down and its "minimum" describes no actual frame. It
> reported min 1 fps on the 17 m tower, whose cascade costs almost nothing. Every figure above is
> per-frame `delta`. Unrelated Godot 4.6.2 processes were also running throughout; these numbers
> should be re-taken on a quiet machine in a release build.

### How many buildings fit — measured, not extrapolated

`tools/city_probe.gd`, headless. What `BrickWorld` alone costs.

**Holding bricks** — the old way, every building materialised:

| | 17 m (756 blocks) | 50 m (3,680) | 150 m (16,590) |
|---|---|---|---|
| Untouched brick data | 0.2 MB | 1.6 MB | 10.0 MB |
| After one mesh build | 9.7 MB | 48.1 MB | **220.4 MB** |
| Ratio | 46× | 31× | 22× |

| | 8 × 150 m | 64 × 17 m |
|---|---|---|
| Meshed | 1,763 MB | 622 MB |
| Fit in 4 GB | ~19 | ~420 |

**Holding recipes** — `BuildingRegistry`, the M3 answer:

| | |
|---|---|
| 5000 buildings registered | **19 ms** |
| `BrickWorld` memory | **0.0 MB across 0 chunks** |
| 12 buildings shot | 47.2 MB, **4.8 ms each** to materialise |
| After trimming those 12 | **back to 0.0 MB, 12 still damaged** |

**Damage is permanent across de-materialisation**, which is the claim that makes this safe:
756 blocks → 735 standing after a hit → bricks freed → rebuilt → **735 standing, the hole came
back**. The record keys on block id, so the recipe has to stay a deterministic generator;
`RECIPE_VERSION` discards a record that no longer matches rather than punching holes in the wrong
bricks.

**19 buildings to 5000, in one change.**

### Floors are structure, and the two bugs they were hiding

A floor is **two offset full-footprint plate layers** -- walls included -- between every four
courses. `TowerRecipe.layout()` returns the vertical band list and **both the brick recipe and the
shell mesh walk it**, so what you see at a distance and what you get when it materialises cannot
disagree, and the slabs add to the building's height rather than being tucked inside it.

Two wrong versions got there first, and both are worth writing down:

1. **Interior-only slabs.** Placement correctly rejected the cells the walls already owned, so the
   plates were laid across the interior alone. They touched nothing.
2. **A single full-footprint layer.** This looked right and still detached, because **stud
   connectivity is vertical only**. Plates side by side in one layer do not connect to each other.
   The perimeter ones rested on the walls; every interior plate was ungrounded the moment bricks
   existed, so *every floor in the building came off on the first solve*. That is exactly what
   "the floors immediately all break as soon as the building takes any damage" was.

The fix is a running bond laid flat: a second layer offset by half a plate, so each plate in it
bridges four in the layer below. It is how a real brick floor holds together too.

Measured, `tools/floor_probe.gd` and the city scene:

| | |
|---|---|
| Intact 24-course building | **0 detached groups, 0 blocks** |
| One hit low in a wall | 19 bricks removed, **2 blocks came loose (0.2%)** |
| One hit in the city scene | 525 bricks, **0 came loose (0.0%)** |

### Falling debris damages what it lands on

An island that lands hard shears its own joints and hands the other half of the collision to
whatever was underneath, via an `on_impact` callback so the island never needs to know what it
hit. Shear, not destroy: a brick struck by falling masonry comes loose.

Both halves of that used to be guesswork, and both were wrong:

* **Where it hit** was the bottom face of the island's *local* bounding box. For anything that had
  rotated -- which is every toppled building -- that face is a vertical wall, so the shear band ran
  up the side instead of across the face that actually landed.
* **What it hit** was "which building's bounding box contains this point". A contact sits ON the
  surface, so whether it counted as inside depended on which side of the skin the solver put it.

Both now come from the solver's own contact manifold: `contact_monitor` on every island body, and
`body_get_direct_state()` for world-space contact points and the collider RID behind each one. The
RID maps straight to a building -- shell tier or brick tier, either counts.

Measured on the 22-building city, same cut both times: **0 -> 6 bricks sheared off buildings by
falling debris**, and two extra buildings promoted purely by being landed on. Island-on-island
shearing over the same run: 21 landings, 282 joints.

### Settled wreckage is still real

A frozen island is woken by any damage near it, and both `wake_near` and the blast's splash damage
measure to the island's **bounding box in world space** rather than to its origin. The origin of a
rigid body is its centre of mass; a toppled building is forty metres long, so an origin test misses
the end you are standing next to and leaves the far end hanging after the wall beneath it is shot
away. A ray that lands on wreckage damages *that* piece directly, by the collider it hit.

Measured: after the city has fallen, a blast aimed at a brick in the largest settled piece takes it
from **2828 to 2805 bricks**. Before, it took none.

### The index partition, and running the GPU out of memory

Status used to end with "one change closes most of the remaining gap: consume the index
partition". It is done, and it was worth more than the time it was expected to save.

`_remesh` handed Godot a fresh `ArrayMesh` on every change, which re-uploads the **entire vertex
buffer**. At city scale that is ~6.8 MB a time, several times a frame during a collapse, and it did
not merely cost time -- it exhausted VRAM:

```
ERROR: Can't create buffer of size: 6772480, error -2.
```

after which the surface draws with a null vertex array and the renderer complains that the vertex
count is not a multiple of three. One run logged **16,680 such errors**. Damage never changes a
vertex; it changes which baked faces are indexed, and `fill_indices` already keeps the buffer a
fixed length by writing degenerate triangles for culled faces. So build the surface once and patch
only the index bytes that moved, via `update_index_region` + `mesh_surface_update_index_region` --
which the sandbox had been doing all along.

| 22-building city, same scripted collapse | before | after |
|---|---|---|
| Renderer errors | 16,680 | **0** |
| Mean frame | 38.9 ms | **17.4 ms** |
| Frames over 33.3 ms | 208 of 303 | **3 of 303** |
| Worst frame | 149.6 ms | 138.3 ms |

Two guards it needs. An `ArrayMesh` with no surface cannot be patched -- a chunk with nothing left
alive produces no arrays. And a patch is only valid while the index buffer is the length the
surface was built at, so the region is bounds-checked against the recorded length and falls back to
a full rebuild rather than writing past the end.

### Streaming, and a third presentation tier

M4's last piece. A registered building beyond `SHELL_RANGE` has no node, no mesh and no collider;
inside it, it gets a shell; inside `SHELL_DETAIL_RANGE` that shell is course-banded, and between
the two it is a box and a cap. Both thresholds carry a 30 m hysteresis band, without which a
building sitting on one rebuilds its mesh every tick as the camera drifts. Both shell tiers keep
the same five collision boxes, because a building you can see is a building you can shoot.

Measured, `tools/city_probe.gd`, 5000 buildings on 13 m spacing with the camera in the middle:

| | |
|---|---|
| Within 260 m | 1256 of 5000 |
| Resident shells | 216 detailed + 1040 coarse |
| Resident geometry | **190,940 triangles, 32.8 MB** |
| If every resident shell were detailed | 1,043,098 triangles, 179.1 MB |
| If nothing were streamed | **712.8 MB** |

712.8 MB to 32.8 MB, and the coarse tier is 82% of that.

### The collapse spike was not collision

The scene stalled when buildings came down, so the obvious suspect was the physics solver. It was
not. Adding per-phase timing to the physics tick (`_report_profile`, printed by every `--shot` run)
put the worst tick at **949 ms**, and named the owner immediately:

```
[prof] worst script tick 949.4 ms  (11 islands)
[prof]   stress 6.8  stability 2.2  detach 0.0  disable 20.7  spawn 806.8  remesh 112.5  islands 11.0
[prof] spawn total 891 ms = split 170 (C++ chunk+blocks) + shapes 73 + node 21 + mesh 626
```

Eleven buildings toppled in the same tick, and **cutting an island out of standing structure is
~77 ms** -- of which 70% is the face bake for the new island's mesh. Nothing in that list is
collision.

Three budgets fixed it, all the same shape: the *world* changes now, the *picture* catches up over
the next few ticks.

| | |
|---|---|
| `MESH_BUILDS_PER_TICK` | 1. An island's first mesh bakes its faces; every later one is an index patch and is free. |
| `SPAWNS_PER_TICK` | 2. Splitting a 2800-brick section costs ~6 ms in the extension alone. |
| `REMESHES_PER_TICK` | 2. Re-indexing a building walks every baked face in its chunk, so it is linear in the whole building however few bricks left it. |

| Worst script tick | |
|---|---|
| Before | **949.4 ms** |
| Deferred island meshes | 334.2 ms |
| + spawn budget | 134.4 ms |
| + remesh budget | **98.7 ms** |

Mean tick over the same collapse is 5.3 ms, of which spawn is 0.71.

### Collision layers: rubble, falling, settled

Three states, because they want different things:

| | Layer | Collides with |
|---|---|---|
| **Rubble** (< 10 blocks) | `RUBBLE` | ground, standing buildings, settled wreckage |
| **Falling** (a large section in motion) | `FALLING` | ground, standing buildings, settled wreckage, other falling sections |
| **Settled** | `DEBRIS` | everything, rubble included -- it is scenery now |

Two pairings are deliberately switched off. **Rubble against a falling section**: a handful of
loose bricks deflecting a toppling tower is neither believable nor cheap. **Rubble against
rubble**: that is the quadratic term in the pair count, and it buys nothing you can see on pieces
that are swept up after 2.5 seconds.

A piece also has to be **at least 3 blocks** to shear what it lands on (`MIN_IMPACT_BLOCKS`). Two
bricks of ABS weigh a few grams; at brick scale nothing that small arrives with the energy to break
a joint, and letting it try produced damage that looked arbitrary. Measured side effect: with
rubble no longer stealing contact slots from the sections that matter, landings that register went
from 21 to 45 and building damage from 6 bricks to 10.

### What a grid costs

A fallen building **is** its own grid: `split_island` gives it a chunk, an occupancy array and a
`Transform3D` of its own. The grid does not rotate -- only the transform does -- so a tower lying on
its side still has the tall, narrow occupancy array it had standing.

"How many grids is too many" turns out to be the wrong axis. Measured on the city after a
12-building collapse:

| 113 live chunks | |
|---|---|
| Occupancy | **8.1 MB** |
| Block records | 1.8 MB |
| Baked mesh (verts, topology, indices) | **549.3 MB** |

Occupancy averages ~72 KB per chunk and is 1.5% of the total. **The mesh bake is 98% of it**, and
that is per *meshed* chunk, not per chunk. So the budget to watch is how many chunks are baked at
once, not how many exist -- a released chunk gives its memory straight back (`release_chunk`), and
chunk ids are never reused, so the id space grows but costs nothing.

### Breaking a building that has already fallen

Three symptoms, one cause. Shooting a settled section lagged the game, made it jitter and slide
across the ground, and left halves that would not come apart -- bricks visibly floating with
nothing joining them.

`split_if_broken` cut the new piece out of the world and out of the mesh, but **never took the
parent's collision with it**. The parent body kept solid, invisible shapes exactly where the new
piece now sat. Two bodies deeply overlapped: the solver pushed at them forever (the jitter and the
slide), they stayed effectively welded (the halves), and anything resting on the ghost shapes hung
in the air.

Three things go with the blocks now, in `_shed`:

* **The shapes.** Disabled on the parent for every block that moved -- whether or not the piece was
  kept, because a discarded one is deleted, not left behind as collision.
* **The mass.** `get_chunk_mass` recomputes it. Without this the parent keeps the inertia of a whole
  building while carrying half of one, and behaves like it is full of lead.
* **One space lift for the whole split.** `body_set_shape_disabled` costs time proportional to a
  body's shape count while the body is in a space, so disabling a thousand of them in a loop is
  quadratic -- the same trap the static chunk bodies hit, and most of the lag.

`tools/fallen_probe.gd` covers it: every brick ends up in exactly one of the two chunks, and the
parent keeps nothing that moved.

### Tension failure on pieces that have already fallen

Standing buildings have had the tension solve since M2. Islands never did, so a fallen section was
structurally frozen: you could disconnect bits off it, but undercutting it did nothing, because
nothing re-asked whether what was left could still hold itself up.

The obstacle is that **a chunk's grid does not rotate when the piece it holds topples** -- only its
transform does. For a building lying on its side, weight no longer flows along grid -Y, and a solve
that assumes it does is solving a building that is not there.

So the solver's "down" is now per chunk. `set_chunk_gravity` takes the world down vector rotated
into chunk space, snaps it to the nearest of the six grid axes, and recomputes the foundation level
from whatever is actually lowest along it. Everything that assumed grid Y -- the grounding seed, the
"is this supporter above me" test that separates tension from compression, `get_load_above` -- goes
through `height_along(cell, up)` instead.

A piece resting on a face, which is where a toppled building ends up, gets an exact answer. One
balanced at an angle gets the nearest of six, which is still far better than pretending it is
upright. Islands also inherit their parent's `tension_per_stud` on the split; without that they got
the default 400 N and were unbreakable.

Measured, `tools/fallen_probe.gd`: a 410-brick building laid on its face has 410 blocks carrying
load, 0 joints over capacity and nothing loose. Undercut its lowest end by 96 bricks and pieces
start coming away. In the city scene, splits over one collapse went from 9 to 143.

### The face bake runs on a worker

It is a pure function of a chunk's geometry -- which blocks sit where, what shape, what colour --
and it reads none of the state damage changes. So it can run off the main thread while the game
plays, which matters because it was 70% of what spawning an island cost.

`bake_chunk_async` starts one; `bake_ready` collects it. Two details make it safe:

* **`chunks` is a `std::deque`, not a `std::vector`.** A worker holds a reference to its chunk, and
  creating another chunk meanwhile must not move the one being baked. deque never invalidates
  references on push_back; vector does.
* **Geometry changes join and discard.** `place_block` invalidates the bake and `release_chunk`
  frees the chunk, so both settle any job in flight first -- a worker must never read a chunk that
  is being rewritten or freed.

| Worst script tick | |
|---|---|
| Before any of this | 949.4 ms |
| Deferred island meshes, spawn and remesh budgets | 98.7 ms |
| + bake on a worker | 68.9 ms |
| + emptied islands retired | **65.2 ms** |

Spawning an island now costs 0.2 ms on the main thread at the worst tick, against 23.9 before.

One more thing fell out of it: a building that has lost **every** brick -- which is what toppling
does -- used to rebuild its mesh anyway, assembling and uploading a third of a million vertices to
draw nothing at all. That was 108 ms of a 139 ms tick on its own.

### Seeing the grids (G)

Press **G** in the city scene to draw every live chunk as a wireframe box:

| | |
|---|---|
| green | standing structure |
| orange | a section still falling |
| blue | wreckage that has settled |
| grey | a chunk with nothing alive left in it |

It makes the grid/transform split visible: a toppled building draws a box lying on its side, and
that box is still the tall narrow grid it had standing. It immediately earned its keep by showing a
scatter of grey boxes with nothing in them -- islands that had shed every block they held and kept
an empty grid and a body forever. Retiring those took the city from **219 live chunks to 87**.

### Shells: floors you can stand on, and brick outlines before damage

Three things were wrong with the cheap LOD shell, all visible only from inside a building, which is
where nobody had looked.

**A floor had one face and it pointed the wrong way.** Godot treats CLOCKWISE winding as
front-facing, so a quad's corners have to make `(b-a) x (c-a)` point *away* from the side it is seen
from. Every wall quad in `building_shell.gd` obeys that; the slab's top cap did not, so it rendered
only from underneath. Standing in a room you saw the bottom of the floor above and nothing at all
where your own floor should be. The cap is now wound like the walls, and slabs get an underside too
-- a floor is seen from both sides once you are inside.

**A wall had one seam outline around the whole wall.** The seam shader measures distance to the edge
of the rectangle UV2 describes, and a shell handed it the entire wall. So an undamaged building had
no brick edges at all and only grew them when it materialised, which read as the building changing
material the instant it was shot.

The fix is one line in the shader: wrap UV by UV2 before measuring.

```glsl
vec2 cell = mod(v_uv, v_face);
vec2 to_edge = min(cell, v_face - cell);
```

For real brick geometry UV never leaves `[0, UV2)`, so this changes nothing. But it lets the shell
hand over a whole wall carrying a **brick-sized** UV2 and get a grid of brick outlines out of it,
for no extra geometry: 17,904 triangles to 18,356 for the whole city, and all of that increase is
the new floor undersides.

**A building blinked out for a frame when it was shot.** Promotion freed the shell and built the
brick mesh in the same call, and the new mesh was not on screen that frame. It now runs in two
halves -- see below -- and the shell stays up until the bricks are actually drawable.

### Promotion in two halves

`_promote` materialises the bricks and their collision, hands the face bake to a worker, and
**leaves the shell up**. `_finish_promotions` picks the building up a tick or two later, when
`bake_ready` says the worker is done, builds the mesh and only then drops the shell.

| Promotion | |
|---|---|
| Before | 43.9 ms per building, on the main thread |
| After | **9.3 ms** per building |

The building is collidable and damageable from the first instant either way; what moved off the main
thread is only the drawing of it. Handing a finished bake to the renderer still costs a full mesh
build and upload (~16 ms for a tall building), and fifteen of those landing together was a 247 ms
tick, so that is budgeted too at one per tick. The shell is still drawn until it happens, so there is
nothing to see.

| Worst script tick | |
|---|---|
| Start of the collapse work | 949.4 ms |
| Budgets | 98.7 ms |
| Worker bake for islands | 68.9 ms |
| Emptied islands retired | 65.2 ms |
| Two-phase promotion | **~92 ms**, but promotion itself fell 43.9 -> 9.3 ms |

The tick figure moved sideways because the scripted cut now finishes its promotions *during* the
sampled window rather than before it. The number that matters for play is the per-promotion one.

The remaining ~140 ms **frame** is the scripted cut itself -- roughly a thousand `_blast` calls in a
single frame to open every tall building at once. It is a test harness artefact, not a game frame.

### Greedy face merging

The bake stored one quad per **cell** face. A 2x4 brick is 4 x 2 x 3 cells, so its six faces came to
52 quads where six would do, and the bake is 98% of what this system costs in memory.

Cells on the same face plane now merge into rectangles when they **agree about what is on the other
side of them** -- which is exactly the condition under which they are drawn or culled together, so
nothing changes about how damage reveals geometry. Merging never crosses a block boundary, because
the two sides of that boundary are owned by different blocks and either could be revealed alone.

Nothing about the seam shader changes either: UV is still position within the *block's* face
rectangle and UV2 is still that rectangle's size, so a merged quad covering eight cells carries one
brick outline, not eight.

| 150 m tower, 48,576 blocks | before | after |
|---|---|---|
| Baked faces | 2,131,896 | **405,216** |
| Triangles drawn | 1,556,400 | **142,480** |
| Baked memory | 533.2 MB | **111.6 MB** |
| Bake time | 546 ms | 139 ms |
| Bytes per block | 11,509 | **2,410** |

The 22-building city went from **559 MB to 119.8 MB**.

One consequence had to be chased down. Godot stores indices as uint16 at 65536 vertices or fewer,
and the old code handled that by refusing to patch small surfaces at all -- fine while only tiny
debris was small. Cutting vertex counts fivefold put most *buildings* under the threshold and turned
every hit into a full mesh rebuild (159 rebuilds in a run, against 30). `update_index_region` now
takes the width and narrows the region itself.

### Everything in the tick has a budget

The 200-building stress run found the last subsystem without one: **the structural solve ran on
every materialised building every tick**, whether or not anything had happened to it.

```
[prof] mean per tick: stress 179.77  stability 47.34  detach 42.34   <- 270 ms of solve
```

Structure only changes when something hits it, so the solve is now driven by that: a building is
marked dirty when it is damaged, when debris shears it, and when it materialises, and it stops being
re-solved once a pass finds no failures, nothing detached and nothing unbalanced.

| 200 buildings, all destroyed inside 12 s, 14,352 shots | before | after |
|---|---|---|
| Mean frame | 123.2 ms | **~76 ms** |
| Frames over 33.3 ms | 92.8% | ~58% |
| Solve, mean per tick | 270 ms | **0.5 ms** |
| Buildings reached before the run ended | 61 of 200 | **200 of 200** |

Four more budgets came out of the same run, each found by the profiler rather than guessed:

* **Damage** (`DAMAGE_PER_TICK`). Hits queue and land a few per tick. A blast also used to test every
  registered building's bounding box; there is a lookup grid now, so a shot costs the same whether
  the city holds twenty buildings or five thousand.
* **Collision and remesh, once per building per tick rather than once per hit.** `_disable` lifts a
  body out of its space and back, and `_remesh` walks every baked face; a burst of fire was paying
  for both repeatedly on the same building.
* **Landings** and **re-solves**, which shear joints and re-solve a whole piece.
* **One shared work budget** across all of the island manager's queues. Three budgets of two is a
  budget of six, which bounded each queue and not the tick -- 290 ms of one at 480 islands.

The HUD also stopped rebuilding its strings sixty times a second; at 400 islands it cost more than
the stress solve did.

### Island LOD

A building has a ladder: recipe, coarse shell, banded shell, bricks. An island had nothing -- a
fallen section kept full brick geometry forever, however far away and however long it had been
lying there. Settled wreckage beyond `ISLAND_MESH_RANGE` now gives its mesh **and its bake** back
(`drop_chunk_bake`), and asks for both again when the player returns. In the stress run 116 of 317
islands were holding no geometry at the end.

### Does it come back? Mostly.

A single mean over a whole run cannot answer "is the game playable again once the dust settles", so
the stress pass buckets frame times by what the city is doing. 200 buildings, all destroyed inside
twelve seconds, 14,352 shots:

| Phase | Mean | fps | Over 33.3 ms |
|---|---|---|---|
| Under fire | 33.4 ms | 29.9 | 69 of 299 |
| Damage queue draining | 133.3 ms | 7.5 | 150 of 150 |
| Collapsing | 60.7 ms | 16.5 | 74 of 180 |
| **Settled** | **16.8 ms** | **59.6** | **0 of 240** |

It recovers -- 60 fps with **not one frame over budget** -- while still holding 200 destroyed
buildings, 331 islands and 1.2 GB of resident geometry. Nothing leaks work into a genuinely idle
state: once the solve has nothing dirty, the island queues are empty and bodies have frozen, the
cost goes away.

**The catch is reaching that state.** A later pass added transverse breaking, which produces half
again as many pieces, and the settled row then measured 21.1 ms with 24 of 240 frames over budget --
because splitting is capped at one piece per pass and a collapse of that size leaves thousands of
re-solves draining for seconds after the last body stops. The recovery is real; how long it takes to
arrive is not yet bounded. See "Where it stands".

The worst phase is not the shooting. It is the **queue draining afterwards**: the test fires 14,352
shots in twelve seconds and `DAMAGE_PER_TICK` lands eight per tick, so ~8,000 hits are still
outstanding when the firing stops. That phase is sustained maximum damage with the whole city
already coming down on top of it, and it is the honest worst case rather than an artefact.

### Cutting an island out of a building

The recommended fix from the last pass. `spawn` was ~24 ms, and the profiler split it three ways:

| Per-run totals, 200-building stress | before | after |
|---|---|---|
| Collision shapes | 1,274 ms | **257 ms** |
| Chunk create + block copy (`split_island`) | 1,529 ms | 1,269 ms |
| Node setup | 193 ms | 185 ms |
| First mesh | 704 ms | 513 ms |
| **Promotion, per building** | **7.6 ms** | **2.3 ms** |

**Shapes moved into the extension.** Building a body's collision was one `body_add_shape` per block
across the script/engine boundary -- 2,800 of them for a toppling building. `add_chunk_shapes` does
the whole chunk in one call, with box shapes cached by size and shared across the city, and dead
blocks disabled as it goes. Five times faster, and it deleted the duplicate shape caches that both
the island manager and the city scene were keeping.

**`place_block` stopped scanning the bake job list.** It is called once per block when an island is
cut out, and it was checking whether a bake was in flight every time; that check is now skipped
outright when nothing is baking.

What is left is `split_island` itself, and it is now 57% of the cost: `create_chunk` allocates an
occupancy grid for the whole bounding box and every block is copied across one at a time. For the
common case -- a whole building toppling -- none of that copying should happen at all, because the
building already *has* a chunk, blocks and shapes. Converting it in place is the next real win.

### Two O(islands)-per-hit loops

Every blast asked **every island** whether it was in range, building a world-space AABB for each.
At 330 islands and eight hits a tick that is 2,600 AABBs per tick. Each island now carries the
distance from its body origin to its own farthest corner, and a sphere test rejects the rest.

That bound is measured from the **body origin, not the box centre** -- the body sits at the centre
of mass, which for a long toppled section is nowhere near the middle of its bounding box. Getting
that wrong made the reject throw away hits on the far end of exactly the pieces it exists to serve:
impacts fell from 71 to 1 and a blast on settled wreckage stopped landing at all. Worth recording,
because the frame times looked *better* while the behaviour was broken.

Shell streaming also dropped to every fourth tick -- fifteen times a second, far faster than anyone
crosses an LOD band.

### Toppling a building without copying it

A toppling building becomes an island holding **every block it has**. The general path cut that
island out with `split_island`: a second chunk, a second occupancy grid, 2,800 `place_block` calls
and a second face bake -- all to build a duplicate of something that was about to be thrown away.
It was 57% of what spawning cost and most of the memory.

So nothing is copied now. `IslandManager.adopt` takes the chunk over whole: the grid, its bake and
its mesh node move across as they are, the chunk stops being anchored, and the only new thing is a
rigid body to carry it. The building's static body is freed and the registry keeps the recipe and
the damage record but lets go of the chunk -- marked `toppled`, so nothing ever materialises or
shells it again and doubles the building.

| 200 buildings destroyed | before | after |
|---|---|---|
| Memory | 1,197 MB | **187 MB** |
| Spawn, whole run | 3,683 ms | **442 ms** |
| of which chunk+block copy | 1,269 ms | **156 ms** |
| Promotion, per building | 7.6 ms | **2.3 ms** |

The 22-building city went from 113 MB to 66 MB for the same collapse.

### Breaking across, not just around

A landing used to shear a ball of joints around each contact point, which sheds a handful of
bricks. A brick tower does not do that. It **snaps**: a beam struck across its middle is in bending,
the tension runs across the whole cross-section at the point of impact, and it comes apart in two
long pieces (Docs/BrickFailure.md).

`separate_plane` severs a slab of the chunk rather than a ball of it, and the rest was already
there -- connectivity treats a sheared block as joined to nothing, so a band torn across a tower
leaves three components: the two halves and a spray of loose brick along the break. Components come
back largest-first, so the halves are what get cut out.

Two things had to be true for it to fire at all:

* **The threshold scales with length.** Measuring impact as the body's own speed drop is measuring
  it at the CENTRE OF MASS, and a toppling tower rotates -- its far end arrives at twenty metres a
  second while its centre barely slows. The first version fired once in a whole city collapse; with
  the threshold scaled by piece length (a thirty-metre section touching down at one metre a second
  is a colossal impact, a one-metre brick at the same speed is nothing) it fires properly.
* **Breaks are spaced and kept off the ends.** Severing within two metres of either end shaves a cap
  off rather than breaking anything, and two breaks within three metres are one break. At most
  three per landing.

The result is what the screenshots show: a tower that falls across its neighbour snaps where it
struck, and one that comes down flat on the ground breaks into a few long segments lying end to
end.

### A budget in milliseconds, not in operations

Every queue in the island manager shared a budget of two operations per tick. That bounds the number
of things done and not the time they take -- and these operations are not interchangeable. A
re-solve that sheds a 2,000-brick half off a toppled tower costs fifty times what one on a chair leg
does, so "two per tick" measured 298 ms on one tick and 0.3 ms on the next.

The budget is now 4 ms on a clock, shared across landings, re-solves and first mesh builds, with a
guarantee of at least one unit so it can never starve.

Two indivisible calls then showed up, each too long for any clock to interrupt.

**A landing that synthesised thirty-six contact points.** When a piece has no live contact manifold
-- it came to rest between frames -- the contact band is sampled across the bottom of its bounding
box instead. That sampler ran up to 6x6, and *every* sample is a full `separate_near` sweep over its
own cell box: 262 ms in one call on a large settled piece, which made landings the single worst
thing in the tick. Nine samples is plenty for a band, and however the contacts were arrived at, only
the first eight are sheared -- a landing is one event, not one per sample point.

**A landing that resolved itself.** Working out what a landing broke off means a stress solve, a
connectivity walk and cutting the pieces out. That is now queued rather than done inline: the
landing records the damage, and `_drain_resolve_queue` deals with the consequences on its own share
of the budget.

And the one that started it: **`rebuild_mesh` baking on the main thread**.
It fell back to `build_chunk_mesh`, which bakes silently when a chunk has no valid bake, and for a
freshly split 2,000-brick half that is most of a second. It now asks the worker and comes back
later, like every other bake. Two O(n^2) paths went with it: `spawn`
called `wake_near` -- O(every island) -- once per piece shed, 4,400 times in a heavy collapse, and
the range loops copied the whole island array per call.

### Bricks are never deleted by a collision

Worth stating plainly, because it looks otherwise when a piece vanishes. `apply_hit` is the only
call that destroys brick, and it appears in exactly two places: `_apply_blast`, which is the player
shooting a building, and `IslandManager.damage`, which is the player shooting wreckage. Both are
weapons.

Every collision path -- a landing, a section striking a building, a section striking another
section -- goes through `separate_near` or `separate_plane`, which sever joints and destroy nothing.
A brick that comes off in a collision still exists; it is in some island somewhere.

Two things do remove brick, and both are the debris budget rather than the damage model:

* a piece under `DEBRIS_MIN_BLOCKS` spawned where **nobody can see it** is deleted rather than
  simulated (`discarded` in the report), and
* a piece under that size is swept up after `DEBRIS_LIFETIME_MS`.

### Falling with some weight to it

Brick models are light and stiff, and at 1g a toppling tower drifts down looking like it is
underwater. Debris now falls at `DEBRIS_GRAVITY` 1.6x, with the speed clamp raised from 22 to 30 m/s
and spin from 12 to 14. That is a feel number rather than a physics one -- it buys the weight the
shapes cannot -- and the harder arrival is what breaks the piece up.

Breaks were also loosened: up to six planes per landing instead of three, two metres apart instead
of three, and the solver keeps six contact points instead of four.

| 22-building collapse | before | after |
|---|---|---|
| Landings | 133 | **243** |
| Joints sheared | 866 | **1,073** |
| Splits | 476 | **598** |
| Transverse breaks | 10 | **19** |
| Biggest single-tick speed loss | 19.1 m/s | 29.7 m/s |
| Mean frame | 20.8 ms | 20.8 ms |

More than twice the destruction for no measurable frame cost, because the work it creates is
budgeted rather than immediate.

### What the frame is actually spent on

Every profile in this document before now reported "0 collision pairs, 0 active bodies" during a
collapse. That was not a quiet scene: **Jolt does not populate the `PHYSICS_3D_*` counters** -- they
are Godot Physics bookkeeping and read zero whoever asks. The `TIME_` monitors are real, and
`TIME_PHYSICS_PROCESS` includes this script's own tick, so subtracting it leaves the solver.

| Phase | Frame | of which physics |
|---|---|---|
| Under fire | 79.3 ms | 48.4 |
| Damage queue draining | 133.2 ms | 83.6 |
| Collapsing | 74.5 ms | 62.8 |
| Settled | 16.7 ms | 19.1 |

Read as a **ratio, not an attribution**: the settled row reports more physics time than the whole
frame, so the monitor is accumulating across physics steps rather than reporting per-frame cost.
What it does say is that physics work roughly triples between settled and collapsing, and that the
script is the minority of a collapse frame. The remaining script cost is landings.

### Landings, again

Raising the break limits made landings more expensive, and they were already the largest script
spike: 60 ms of a 60.9 ms `islands.tick`. Two fixes, no loss of destruction:

* **All the break planes are severed in one walk.** `separate_planes` takes the whole set at once --
  they share a normal, being slices across the same long axis -- instead of walking every block in
  the chunk once per plane.
* **Shear sweeps are capped at three, break planes are not.** Shearing a ball of joints at a contact
  is cosmetic; snapping the piece across is the thing you see. Each sweep walks its own cell box and
  a dozen of them was most of the cost.

A third thing was still inline, and it was the one that scaled with island count. A landing called
`split_if_broken` and `rebuild_mesh` directly -- a connectivity walk and a spawn per piece -- and
then handed the impact to `on_impact` for **every** contact. Each hand-over shears every loose piece
within reach, so six contacts a few centimetres apart did that six times over: 63 ms at 506 islands.
Landing on something is one event. The resolve is queued like `shear` already queued it, and at most
two contacts are handed over.

| 22-building collapse | before this pass | after |
|---|---|---|
| Worst `islands.tick` | 15.1 ms | **12.3 ms** |
| Landings | 133 | **325** |
| Joints sheared | 866 | **1,844** |
| Splits | 476 | **1,085** |
| Transverse breaks | 10 | **27** |
| Debris damage to buildings | 54 bricks | **119** |
| Mean frame | 20.8 ms | 20.9 ms |

Two and a half times the destruction, a lower spike, and the same frame time.

### Why the floors came away in sheets

Reported as "rather than buildings breaking in half they just break a few individual bricks off and
a lot of the flooring". `tools/floorshed_probe.gd` was written to tell "the floors are weak" apart
from "plates are simply smaller, so there are more of them", and the answer was neither:

```
built 842 blocks, 458 of them plates (54% of the building is flooring)
blew out 39 brick(s) of one wall
  detached after the hit: 2 block(s) -- 2 plate, 0 brick
uncapped sweep at r=2.6 m: 86 block(s), 64 plates (74%)
```

Blasts were not doing it -- a hole through a wall detached two plates. **The shear sweep was.** One
landing contact severed 86 joints, three quarters of them flooring, because a sphere measured in
METRES over-selects flat thin geometry: a floor plate is a third of a brick's height and spans the
whole footprint, so a 2.6 m sweep reaches eighteen layers of flooring against six courses of wall.
Three contacts per landing made that 258 blocks.

The cap is not a performance tweak, it is the model: an impact carries finite energy and does not
shear an unbounded area. `separate_near` now takes a maximum and keeps the **nearest** that many, so
the cap keeps what the impact actually reached rather than whatever the sweep visited first.

| One sweep, 24-course tower | |
|---|---|
| Uncapped | 86 blocks |
| Capped at `SHEAR_MAX_BLOCKS` | **14 blocks** |

Across the 22-building collapse that took joints sheared from 1,844 to 1,472 and splits from 1,085
to 866, while transverse breaks held at 23 -- less confetti, the same number of towers snapping in
half.

That 54% figure is worth keeping in view on its own: two full-footprint plate layers every four
courses means **most of a building, by block count, is floor**. Everything that scales with block
count -- the bake, the collision shapes, the solve -- is paying for flooring first.

### Merged collision for settled pieces

One box per brick across 400-odd islands is what a collapse makes the physics solver pay for. A
settled island is inert scenery, so `add_chunk_shapes(..., merge: true)` greedily merges runs of
solid cells into as few boxes as the shape allows, ignoring which block owns them.

The catch is the obvious one: a merged box cannot be disabled per block. So `_reshape` runs the
other way -- `_ensure_per_block` rebuilds the shapes one-to-one -- at the top of every path that
damages a piece: `shear`, `damage`, `fracture_on_impact` and `_shed`. Merging happens when a piece
settles; un-merging when something touches it. In the 22-building collapse, 176 pieces merged down,
and the probe still confirms a blast on settled wreckage takes bricks off it.

### The project settings were untouched

Every number measured in this document up to here was taken with Godot's physics defaults. Nothing
in `project.godot` had been tuned but the engine choice. Four settings, all justified by what this
game actually is:

```
common/physics_ticks_per_second = 30
common/max_physics_steps_per_frame = 4
jolt_physics_3d/simulation/velocity_steps = 6
jolt_physics_3d/simulation/sleep_time_threshold = 0.3
jolt_physics_3d/simulation/sleep_velocity_threshold = 0.06
```

**30 Hz.** A brick collapse is hundreds of bodies settling, not a twitch shooter's character
controller. Halving the tick rate halves every per-tick cost in the game at once -- the solver, the
stress solve, the damage queue, the island queues.

**Four catch-up steps, not eight.** This one was hiding in plain sight. When a frame runs long the
engine replays physics to catch up, and Godot clamps delta at `max_physics_steps_per_frame /
ticks_per_second` -- which at the defaults is 8/60 = **133 ms**. That is exactly the figure the
"damage queue draining" row reported, to the decimal, in every stress run in this document. That row
was never measuring work; it was measuring the clamp. Fewer steps means the simulation slows down
under load rather than trying to catch up and falling further behind.

**Six velocity iterations.** Solver precision buys nothing on a pile of settling rubble.

**Sleep sooner.** A piece that has stopped should leave the active set quickly.

| 200 buildings | before | after |
|---|---|---|
| **Under fire** | 80.5 ms (12.4 fps) | **19.2 ms (52.0 fps)** |
| Damage queue draining | 133.5 ms | **68.0 ms** |
| Collapsing | 63.4 ms | **55.3 ms** |
| Settled | 16.7 ms | 16.7 ms |
| Whole run mean | 54.5 ms | **42.2 ms** |
| Frames over 33.3 ms | 35.3% | **30.7%** |

**And the after column did 1.8x the work.** Faster frames let the scripted pass get through all 200
buildings inside its twelve seconds instead of 111, so that run fired 14,352 shots against 7,968,
produced 9,744 splits against 5,904, and left 734 islands against 398. The under-fire row -- the
phase a player is actually in -- went from 12 fps to 52.

The 22-building scene: mean frame 20.9 to **18.9 ms**, worst frame 148 to **105 ms**.

### 30 Hz or 60 Hz, measured rather than argued

The tick rate is one line, and it decides more than any other single setting, so it was measured
both ways with every other fix held constant — 200 buildings, all destroyed inside twelve seconds:

| | 60 Hz | 30 Hz |
|---|---|---|
| **Under fire** | 49.3 ms (20.3 fps) | **19.2 ms (52.0 fps)** |
| Damage queue draining | 66.7 ms | 68.0 ms |
| Collapsing | 48.8 ms | 55.3 ms |
| Settled | 17.5 ms, 2 frames over | **16.7 ms, 0 over** |
| Whole run mean | 46.1 ms | **42.2 ms** |
| Frames over 33.3 ms | 59.6% | **30.7%** |
| Worst frame | **82.8 ms** | 161.9 ms |

30 Hz wins the phase a player is actually in by two and a half times. 60 Hz wins the worst frame,
and for a specific reason rather than by being faster: the delta clamp is
`max_physics_steps_per_frame / ticks_per_second`, which is 67 ms at 60 Hz against 133 ms at 30 Hz.
At 60 Hz the game gives up and slows down sooner. Different failure mode, not a better one.

**What 30 Hz costs when enemies and shooting arrive**, honestly:

* **Nothing for aiming.** Mouse look belongs in `_process` regardless of tick rate, and hitscan is a
  raycast fired on input — neither is stepped by physics.
* **Nothing for AI.** Navigation and behaviour run on their own timers.
* **Up to 33 ms of input-to-simulation latency on the player's own body**, which is the real cost and
  the only one. Acceptable for most games, wrong for a competitive shooter.
* **Fast projectiles can tunnel.** Raycast projectiles avoid it entirely; Jolt's CCD settings are
  there if physical ones are wanted.
* **Visual judder** — and this is what `physics_interpolation` exists to fix. It is off, because
  turning it on produces 13 `Buffer argument is not a valid buffer of any type` errors per collapse:
  interpolation holds a mesh for an extra frame and `_remesh` frees the old `ArrayMesh` the instant
  it swaps the new one in. **That fix — keep the replaced mesh alive one more frame — is the thing
  to do before a player controller lands**, because it is what makes 30 Hz acceptable to look at.

The decision is reversible in one line, and the numbers above are what to reverse it against.

### Buildings that stood up while they were falling out of themselves

Reported as "two buildings break immediately but then seem to respawn, and the collapsing building
gets stuck inside the undamaged building and moves it upwards". Nothing respawned. The shell never
left.

Promotion deliberately **keeps the shell drawn** until a worker has baked the bricks, so a building
never blinks out when it is first hit. Toppling is decided by `check_stability` on the tick after
the bricks exist, and `_finish_promotions` only completes one building per tick -- so a building can
become unstable in the window where its shell is still up. `_topple` handed the chunk over to an
island and never freed the shell.

The result is exactly what was described: a building that still looks whole and still has its five
collision boxes, with the real bricks falling out of it as a rigid body. The section lodges inside
its own shell and gets pushed up. One line: `_topple` frees the shell first.

It was costing frame time as well, because every falling section was fighting a solid box it should
have been able to fall through. The 22-building collapse went to a **40.9 ms worst frame with 3 of
529 frames over budget** -- the best that scene has measured.

### Interpolation, and the mesh it was actually fighting

`physics_interpolation` is on, so 30 Hz renders like 60. Getting there took three wrong guesses
worth recording, because each was plausible:

* **Not a freed mesh.** `MeshRetirer` holds a replaced `ArrayMesh` for two frames so the renderer
  cannot be left drawing one that has just been let go. Correct hygiene, kept -- and not the bug.
* **Not a same-frame patch.** A guard against patching a surface on the frame it was built changed
  13 errors to 12, and was removed again.
* **Not the adopted surface.** Refusing to patch a mesh carried across by `_topple` changed nothing.

Disabling index patching entirely took 15 errors to 7, which finally said it plainly: **two**
sources, not one, and the second was the MultiMesh. What both have in common is that their
transforms never move and their contents are rewritten in place -- which is the one thing
interpolation's double buffering cannot survive.

So the meshes that get rewritten opt out:

```gdscript
mi.physics_interpolation_mode = Node.PHYSICS_INTERPOLATION_MODE_OFF
```

on the building brick instances, the island mesh instances and the debris MultiMeshes. The bodies
they hang under are still interpolated, which is where the smoothness actually comes from. Zero
errors.

### Merging collision at birth: tried, measured, reverted

The plan was to merge a piece's collision as soon as it spawns rather than waiting for it to settle,
on the grounds that a falling 2,000-brick section is thousands of boxes in the broadphase for
something nothing has touched yet.

It does not work, and the counters say why: **839 boxes saved against 34,978 rebuilt per block**. A
falling piece is hit almost immediately -- by its own landing -- and `_ensure_per_block` has to
rebuild the shapes there and then, so the scene pays for two shape builds instead of one. The
settled phase of the 200-building run went from 16.7 ms to 69.5 ms.

Merging is worth it once a piece has stopped, and only then. The counter stayed, because it is what
made the answer obvious: on settle-only merging the same scene reports **262 merges down to 2,486
boxes**.

### The hole a piece leaves before it has a mesh

Reported as "the island disappears for about a frame right when it breaks from the building". It
was not a frame and it was not the island's fault.

Cutting a piece out removes its bricks from the parent **immediately** -- disabled in the parent's
collision, gone from the parent's mesh -- but gives the new piece an empty `MeshInstance3D` and
queues its face bake. So for as long as the queue took, those bricks existed in the world, collided
with things, and were drawn nowhere.

And the queue took a while, because `_drain_mesh_queue` ran **last**, after re-solves and landings
had spent the shared millisecond budget. A piece could wait several ticks to become visible.

Two changes:

* **Meshes drain first.** A piece that has left its building and has no mesh yet is a hole in the
  world. The other queues only decide what breaks *next*, and they can wait a tick.
* **Small pieces skip the queue entirely** (`SYNC_MESH_MAX_BLOCKS`, 96). Baking a handful of bricks
  is microseconds -- it is only a whole toppled building that has any business going to a worker.
  Most of what breaks off is small, so most of what breaks off is now never invisible.

### A budget caps a tick; it does not set throughput

`SPAWNS_PER_TICK` and `DAMAGE_PER_TICK` were plain counts. Converting them to millisecond budgets
was right in principle -- a count bounds how many things happen, not how long they take, and these
are not interchangeable: cutting a 2,000-brick section costs a hundred times what a chair leg does.
Getting the *shape* right took two wrong versions, and both produced measurements that looked good
and were not.

**Wrong version one: a minimum of one, with the clock as the only other limit.**

```gdscript
while not queue.is_empty() and (hits < DAMAGE_MIN or now < until):   # DAMAGE_MIN = 1
```

If a single hit costs more than the budget -- which a hit that promotes a building does -- this
lands one hit per tick. At 30 Hz that is thirty hits a second, so a burst of fourteen thousand takes
eight minutes. The frame times were superb because the damage was not being applied: the stress run
reported near-60 fps in every phase while damaging **66 of 200 buildings**. It was caught by the
work-done counters printed next to the frame times, and not by the frame times.

**Wrong version two: the old count as a floor, then keep going while under budget.** This does far
*more* than the count whenever work is cheap, which raises per-tick cost rather than bounding it.
The 22-building collapse measured 16.7 ms mean with a plain count of 8 and **75.3 ms** with "8, then
as many more as fit".

**Right version: the count is the cap, the clock is an early-out.**

```gdscript
while not _damage_queue.is_empty() and hits < DAMAGE_PER_TICK         and (hits == 0 or Time.get_ticks_usec() < damage_until):
```

Exactly the old throughput, with the clock able only to stop it short when the work turns out
expensive. The island manager's `WORK_BUDGET_MS` has always had this shape; the building side now
matches it.

Worst script tick on the 22-building collapse: **20.5 ms**, against 54.7 before.

### What the shot pass cannot measure

`--shot` reports one mean frame time for the whole run, and that number is **not stable across
changes to the budgets**. How fast the damage queue drains decides what fraction of the sampled
window sits in the expensive collapse phase against the cheap settled one, so the mean moves when
nothing about per-frame cost has. Several rounds of tuning were spent chasing it in circles.

Use `--stress` for comparisons. It splits frame time by phase and prints work-done counters --
buildings damaged, splits, islands -- beside them, which is what caught both budget errors above.

And check the machine is quiet. A concurrent Godot editor holding the same project will contend for
CPU and GPU; one stress run in this document's history reported 520 ms of "idle process" time, which
is not a measurement of anything.

### Bricks separate at a seam, not into gravel

Two things turned a collapsing building into a cloud of loose brick, and both were the same mistake:
marking a *region* of blocks `support_broken`, which means "joined to nothing", so every block in it
became its own piece.

* **The transverse break.** `separate_planes` marked every block whose centre lay within a
  0.42 m band of the cut. A tower snapping in half therefore produced two halves *and a whole course
  of individual bricks* sprayed out at the break.
* **The impact shear.** `separate_near` marked every block in a ball around the contact. A wall
  struck by falling masonry shed up to fourteen separate bricks.

Both now cut joints instead of isolating blocks, via a new `Block::bottom_broken` — the joints on a
block's underside gave way and nothing else did. `for_each_neighbour` skips that link in both
directions, so a cut is the same whichever side the component walk arrives from.

**`sever_seams`** snaps a piece by severing one course of downward joints. Both sides stay solid and
nothing crumbles in between. It snaps the cut to the nearest course boundary, because a seam is
*between* two courses and never through one — that is what makes it read as bricks coming apart
rather than bricks being sawn.

**`separate_near(..., peel: true)`** severs only the *underside* of the struck region, so it comes
away as one clump. What holds the clump together is the running bond: a brick spanning several cells
links the columns it covers, exactly as in the real toy. A region cut free from below but still
capped by intact wall does not fly off at all — it hangs, the stress solve finds it unsupported, and
the cascade decides what falls.

Measured on the same sweep (`floorshed_probe`):

| | blocks detached |
|---|---|
| shear (isolate a ball) | 14, in 3 groups |
| peel (cut its underside) | **2** |

### The break axis has to be asked in the piece's own space

Joints run along a chunk's local Y and nowhere else, so that is the only direction a clean seam can
cross. `_snap_across` chose its break axis from the piece's **world** AABB — and a tumbling piece's
longest world axis is almost never its local Y. Fourteen of twenty-four breaks therefore found no
seam and fell back to tearing a band into gravel.

Asking in local space took band fallbacks from 13 of 24 to **5 of 20**, and the ones that remain are
pieces genuinely long the other way — floor slabs, which have no seam to find. `band_breaks` counts
them, so a rise in that number is visible rather than silent.

| same 200-building scenario | before | after |
|---|---|---|
| splits | 364 | **218** |
| impact-loosened blocks | 462 | 433 |
| worst frame | 47.9 ms | **50.0 ms** (one; the rest fell) |
| frames over budget | 3.0% | **0.9%** |
| queue-draining phase | 45.7 fps | **57.6 fps** |
| worst script tick | 42.5 ms | 38.2 ms |

The shot pass moved the same way: worst frame 66.7 → **35.7 ms**, worst script tick 47.2 → **32.2
ms**, and the 42 ms `promote_finish` spike disappeared entirely — fewer pieces means fewer impacts
forcing a struck building to materialise mid-collapse.

### What the stress pass could not say

The pass claimed 200 buildings and measured 70.

It fired a full demolition pattern at every building — 14,352 blasts — into a damage queue that
drains at `DAMAGE_PER_TICK` (8) a tick. The queue never emptied; the draining phase ended on its
frame cap with roughly six thousand hits still in it, and **70 buildings ever took a hit**. Every
frame time it reported was taken under a permanent backlog.

It now fires one of two patterns per building:

* `_stress_topple` — a bite out of the bottom of one side, so the centre of mass leaves its support.
  Applied to `--collapse=N` buildings (default 8; `--collapse=all` is the old behaviour).
* `_stress_wound` — eight hits, two thirds of the way up, a quarter of the way in. Damage without
  demolition; removing mass that high makes a building *more* stable, not less. Eight because the
  queue drains eight a tick and the pass fires at one building a frame, so the queue stays level.

And it now reports what it did rather than letting the reader assume: how many buildings took a hit,
how many actually toppled, and **a warning naming the number of hits left in the queue** if it did
not drain. A test that can quietly measure something other than its own description is worse than no
test, because it produces numbers that survive into documents.

### A damaged city does hand its bricks back -- at two buildings every four seconds

The first version of this section said trimming reclaimed nothing. That was wrong, and wrong in a
way worth recording: the tail I measured it over was about 12 seconds, `TRIM_AFTER_MS` is 12
seconds, and `_trim_quiet` only runs every 120 physics frames. The trim had barely become eligible.
A longer tail showed it working -- just far too slowly to matter.

The actual cause was one line:

```gdscript
freed += 1
if freed >= 2:
	break
```

Two buildings per run, one run every four seconds. In the stress scenario **163 of 200 buildings are
outside `TRIM_RADIUS`**, so reclaiming what a single firefight puts out of range would have taken
five and a half minutes. Memory looked like a leak because the reclaim rate was set an order of
magnitude below the rate damage arrives at.

Raising the cap alone barely helped, because a trim cost **5.2 ms** and the budget then allowed one
per run regardless. Timing it in three parts said where:

| | per building |
|---|---|
| `registry.dematerialise` | 3.4 ms |
| freeing bodies, nodes, meshes | 0.65 ms |
| building the replacement shell | 1.0 ms |

Two thirds of it was `_build_damage_profile`: for each of roughly thirty bands it fetched a column
mask and then ran **128 rectangle scans in GDScript** over it. That is a pure walk over occupancy,
so it moved to `BrickWorld::build_damage_profile` -- the recipe still owns where the bands are, the
world now owns what is left standing in them. It went to 0.66 ms, and a whole trim to 1.6 ms.

With the walk in C++ and the budget at 8 buildings / 6 ms per run:

| | before | after |
|---|---|---|
| Trimmed in a 30 s tail | 14 | **136** |
| Resident afterwards | 186 of 200 | **56** |
| Memory afterwards | 723 MB | **212 MB** |
| Frames over budget | 0.9% | **0.4%** |

Peak is still 689 MB while 190 damaged buildings are resident at once, which is the real cost of the
scenario and not a defect. What was a defect was never coming back down.

I guessed twice before measuring -- first that the shell build was the cost (it is 1.0 ms), then
that raising the count cap would help (the clock stopped it). The three-way split took one run and
answered it.

### Superseded: the first diagnosis

With the pass fixed, the first thing it said was new:

```
peak 701.7 MB with 190 resident; after trimming 723.5 MB with 186
```

(Superseded -- the tail was too short and the reclaim rate too low, not absent.)

200 buildings damaged but standing cost **723 MB**, 662 of it bake data, and holding the run 16
seconds past `TRIM_AFTER_MS` reclaimed four buildings and *grew* by 22 MB. `_trim_quiet` only
de-materialises outside `TRIM_RADIUS` (90 m), and a player standing in a city they have been
shooting is inside that radius of most of it.

This is the opposite of the all-collapse case, which settles at 77 MB — a building that falls hands
its bricks to an island, the island settles, and the island gives its mesh back. A building that is
merely *damaged* has no such path. It is now the largest open cost in the project and the memory
numbers elsewhere in this document, all taken from collapse scenarios, do not describe it.

### A piece vanished for a frame when it was shot

Reported twice, and both times I fixed a different thing. The first fix -- draining the mesh queue
before anything else, and baking small pieces synchronously -- was real, but it addressed a piece
that had *no mesh yet*. This is a piece that has one.

`BrickIsland.disable_blocks` lifts the body out of its space before disabling shapes, because
`body_set_shape_disabled` costs time proportional to shape count while the body is in a space. The
lift is correct. What it also does is reset the body's interpolation history: rejoining a space is a
teleport as far as interpolation is concerned, even though the body has not moved a millimetre. For
one frame the piece is drawn from wherever the interpolator last had it.

The island's `MeshInstance3D` is a **child of the body**, so setting `PHYSICS_INTERPOLATION_MODE_OFF`
on the mesh does not save it -- it inherits the body's transform.

The spawn path already knew this and calls `reset_physics_interpolation()` after adding the body,
with a comment explaining exactly this failure. Damage is a second door into the same problem, and so
is `_reshape`, which swaps merged shapes for per-block ones on the same path. Both now reset.

That the cure was already written down thirty lines away is the useful part: the first two attempts
went looking for a *missing* mesh because that is what "disappears" suggested, when the mesh was
there and being drawn in the wrong place.

### Damage carries as far as you can see

`_fire` raycast against collision, and a building past `SHELL_RANGE` (260 m) has no node at all --
no shell, no bricks, nothing for a ray to hit. A tower on the horizon could be lined up and shot at
all day. `tools`-style measurement, via a new `--reach` pass:

```
[reach]  240 m: damage LANDED
[reach]  280 m: damage missed
[reach] damage lands out to 240 m; first miss at 280 m (SHELL_RANGE is 260)
```

The fix costs no memory: when physics finds nothing nearer, the ray is intersected against the
**recipes**. Every building in the city has one, they are a few hundred bytes each, and they are
already resident for all 5000. The hit then goes through `_apply_blast` unchanged, which materialises
whatever it landed on regardless of distance -- so the "turn LOD 0 on for a chunk that is taking
damage" behaviour was already there; only the ability to *reach* it was missing.

Damage now lands at every distance out to `FIRE_RANGE`, 40 m to 480 m, stable across runs.

**The probe lied twice before it was right**, and both times the fault was the test. First a reset
that cleared the damage record and *then* de-materialised -- which refreshes the record from the
chunk and puts the damage straight back, so every distance reported a hit. Then the debug camera:
`capture_mouse` was `not _shot_mode`, so in the new pass the camera kept applying its own movement
and mouse-look on top of the scripted aim, and the probe reported misses at 40 m. Every scripted pass
now takes the camera off input.

### Where the memory actually is

After the trim fix a damaged city settles at ~190 MB. The peak, while damage is still arriving, is
**682 MB across 185 resident buildings** -- and that number has a shape:

```
at peak: 71 resident within 110 m (120,832 blocks), 114 beyond it (193,448 blocks, 62%)
```

**62% of the resident brick data belongs to buildings past `SHELL_DETAIL_RANGE`.** A materialised
building is skipped by `_stream_shells`, so it is drawn as full brick geometry however far away it
is. Nobody can resolve a stud at 150 m.

The tier that fixes it: a building that is materialised but beyond the detail range drops its bake
and its brick mesh, draws a coarse shell, and **keeps its chunk** -- so the damage record stays live
and a hit still lands on real bricks. `drop_chunk_bake` already exists and island LOD already uses
it. What made this unsafe before was collision: a shell body is static and approximate, so bullets at
range would hit the wrong thing. The recipe ray removes that objection -- damage at distance no
longer depends on resident collision at all.

### The middle tier: resident bricks, no mesh

A materialised building is skipped by `_stream_shells`, so it draws full brick geometry however far
away it is. At the peak of a 200-building run, **114 of 185 resident buildings were past
`SHELL_DETAIL_RANGE` and held 62% of the blocks**. Nobody resolves a stud at 150 m.

Past `DEMESH_RANGE` (110 m, with 20 m of hysteresis) a building now drops its bake and its brick
mesh and draws a coarse shell, while **keeping its chunk and its collision**. The damage record stays
live and a shot still lands on real bricks. Coming back into range rebuilds the mesh through the
same machinery a promotion uses, so the shell stays up until the bake lands.

`_trim_quiet` still de-materialises these later and reclaims more. The point of this tier is
*speed*: the trim will not touch a building until it has been quiet for `TRIM_AFTER_MS`, and the peak
is made of buildings that have not been quiet yet. This gives the bake back within a tick or two.

| 200 buildings damaged, 8 collapse | before | after |
|---|---|---|
| Peak | 682 MB / 185 resident | **393 MB / 184 resident** |
| Settled | 190 MB / 50 resident | **141 MB / 37 resident** |
| Frames over budget | 0.8% | 0.5% |

37 is exactly the number inside `TRIM_RADIUS`, so the trim now fully catches up. De-meshing 94
buildings cost 95 ms in total -- about 1 ms each, against 1.3 ms for a full trim.

What made this unsafe before was collision: a shell body is static and approximate, so shots at range
would land on the wrong thing. The recipe ray removed that objection before this was built.

### Walk away, walk back

Dropping a mesh is half a feature. The half that breaks silently is the return -- a building stuck as
a shell forever looks exactly like a building that was never damaged. `--lod` shoots a building,
walks 200 m away, shoots it again from there, and walks back:

```
ok  mesh dropped                              after 1 frame(s)
ok  still resident
ok  damage still recorded                     30 dead
ok  a shot from 200 m still destroys brick    30 -> 58 dead
ok  bricks came back                          after 1 frame(s)
ok  damage survived the round trip            58 dead
```

**This probe was wrong three times before it was right, and every time it accused the game.**

1. It captured its failure counter in a lambda. GDScript lambdas capture locals **by value**, so
   `failures += 1` updated a copy and the probe printed `PASS` directly under its own `FAIL` line.
   The counter is an Array now.
2. It slept a fixed 240 frames waiting for the de-mesh. `TRIM_RADIUS` (90 m) is *inside*
   `DEMESH_RANGE` (110 m), so a wait long enough to be safe is also long enough for `_trim_quiet` to
   fire and take the chunk away entirely -- which reads as the de-mesh tier failing when it is the
   deeper tier working. It polls for the transition now.
3. It fired the second shot at the same point as the first, where every brick was already destroyed,
   and reported that distant shots do no damage.

Only the third of those would have been caught by reading the output; the first made the output
itself untrustworthy.

### A piece vanished for a frame: the third door

The fix recorded above -- resetting interpolation after a space round trip in `disable_blocks` and
`_reshape` -- was right but incomplete. What remained showed only on **large** pieces, which is the
clue that names the cause: `wake()` sets `body.freeze = false`, and only a large island survives long
enough to settle and freeze in the first place. Small ones are swept up before they ever do.

Un-freezing changes the body's mode in the physics server, and that resets its interpolation history
exactly as rejoining a space does. Same one-frame draw from a stale transform, same fix, third site.

Three separate doors into one bug, found one at a time because each fix made the symptom rarer
without making it go away. The pattern worth keeping: *anything that changes a body's relationship
with the physics server is a teleport as far as interpolation is concerned, whether or not the body
moved.*

### Physics on a separate thread: tried, measured, rejected

**First measurement was taken with a Godot editor open and overstated the gap** -- reported as 0.4%
vs 1.1% of frames over budget. Re-run with nothing else on the machine, the honest numbers are:

`physics/3d/run_on_separate_thread` ran without crashing, which was the surprise -- islands create
`RigidBody3D` and `MeshInstance3D` nodes from `_physics_process`, and the scene tree is not thread
safe. It was also **worse on every measure**, on the same 200-building scenario:

| | single thread | separate thread |
|---|---|---|
| Mean frame | 16.7 ms | 16.8 ms |
| Worst frame | **33.3 ms** | 49.2 ms |
| Frames over budget | 7 of 2783 (0.3%) | 10 of 2765 (0.4%) |
| Worst script tick | **34.7 ms** | 43.3 ms |

The reason is the shape of this workload. Threading physics helps when the solver is the cost and the
script leaves it alone. This script is *physics-server-bound*: it creates bodies, builds and clears
shapes, lifts bodies in and out of spaces and disables shapes by the thousand, all from inside the
tick. Every one of those calls has to cross to the physics thread, and the crossings cost more than
the parallelism returns.

Not worth it, and the risks were real even though nothing crashed in these runs -- node creation from
the physics thread is undefined behaviour that happens to work here.

**One thing it did not cause.** The run ended with `94 RID allocations of type 'P10JoltBody3D' were
leaked at exit`, which looked like the thread's fault. A control run with the setting off leaked the
same 94. It is pre-existing and unrelated -- worth chasing separately, and worth remembering that the
first run to show an error is not necessarily the run that caused it.

### A custom AABB sized from an empty mesh

Turning generous AABBs on by default made every falling piece flash as it broke apart -- worse than
the problem it was meant to test for, and entirely self-inflicted.

`_apply_aabb` sized the box from `isl.mesh.get_aabb()`, and at spawn that mesh is **empty**. So a
piece tens of metres across was given a ~2 m custom AABB, and a custom AABB *replaces* the computed
one rather than being merged with it. Every new island was culled until its next rebuild.

Default is back to off, and the function now refuses to size a box from a mesh with no surfaces. The
evidence for generous AABBs was always weak -- "really hard to tell, a few drops looked good" -- and
the real cause turned out to be the cancelled bake above. Key `C` still toggles it.

### The black ring around every roof

Long-standing, and unrelated to the flash: a shell drew a black border round its roof that vanished
the moment the building materialised.

`building_shell.gd` painted any band that was not a `course` with filament 1, and **filament 1 is
black**. The band in question is the cornice -- but `TowerRecipe` does not build a cornice ring. It
places a run of buttresses along the `z=0` edge only:

```gdscript
"cornice":
	for x in range(0, footprint_x - 1, 2):
		world.place_block(chunk_id, Vector3i(x, band.y, 0), palette.buttress_2x2, 1)
```

So the shell drew a full black ring where the bricks have a short black run on one edge, and
`_ring_cap` -- the wall-top cap -- inherited that black for the whole rim. Materialising the building
replaced both with the real top course, which is why damaging a building anywhere fixed its roof.

The shell now skips the cornice band entirely and caps the wall tops in the top course's own colour.
`top_colour` also defaults to grey rather than filament 1, so the fallback can never be black either.

### The flash: hand-off became overlap

What the observations finally pinned down, from a logged session watched in slow motion:

* only pieces **at the moment they are created** flash -- existing pieces never do;
* when a piece breaks apart, only the **part that breaks off** flashes, not the part left behind;
* a building's **first** break flashes whatever the size;
* **single bricks never flash**;
* the flash stays **one frame** however slow the game runs -- so it is a rendered frame, not a tick.

The log settled the mesh question: every multi-brick piece had its mesh in the tick it was born
(`WITHOUT mesh` printed just before the synchronous bake); only pieces over 200 bricks were ever
blind, and only for a tick. A new instrument sampling `get_global_transform_interpolated()` every
rendered frame found every newborn drawn exactly where its body was -- 0 of 1,403 frames off. So
neither the mesh nor the CPU-side transform is wrong.

What every flashing case shares, and every non-flashing case lacks: **a render instance entering the
scenario in the same frame that the bricks stop being drawn by whatever drew them before.** A split
child is a new instance. `adopt` removed the building's node from the tree and re-added it under a new
body. A standing building promoting to bricks never flashes because its instance entered the scenario
frames before its mesh arrived. A single brick never flashes because it is never an instance of its
own -- it is a row in the shared MultiMesh.

The fix does not depend on knowing why a new instance misses its first frame. Every hand-off became
an **overlap** of `OVERLAP_FRAMES` (2): the old drawing stays up while the new one comes up.

| Hand-off | Before | Now |
|---|---|---|
| building → piece | building remeshed the same tick | building's remesh held 2 frames |
| island → piece (`_shed`) | parent's index patch the same tick | parent's rebuild held 2 frames |
| building → whole island (`adopt`) | node removed and re-added | building's node left in place 2 frames; the island gets a **new instance of the same `ArrayMesh`** |

For those two frames the same bricks are drawn twice in almost the same place, which cannot be seen.
**Confirmed by eye as the fix**, A/B'd in slow motion -- no instrument ever saw this artefact, so a
person watching was the only judge available.

### Cleanup after the flash hunt

The hunt left scaffolding, and most of it tested hypotheses that turned out wrong. Removed:

* the live toggles `I` (body interpolation), `M` (mesh interpolation), `P` (index patching), `C`
  (generous AABBs), `N` (MultiMesh bypass), `V` (per-piece logging) and `J` (overlap on/off) --
  overlap is now unconditional;
* two instruments that found nothing: the per-render-frame interpolated-transform check and the
  impossible-jump detector;
* the `--flash` pass. A test that **passes with the bug present** gives false confidence, which is
  worse than no test.

Kept: the overlap fix, the cancelled-bake re-issue, `SYNC_MESH_MAX_BLOCKS` at 200, the interpolation
resets at every space round trip (Godot's documented practice, even though they were not the cause),
the blind-piece counters in the shot and stress reports (they found a real bug), and `O` for slow
motion. The key tables in the sections above describe tools that no longer exist; they are kept as
the record of how the cause was found.

### The flash: a cancelled bake nobody re-issued

Found, and found only after the measurement that had been reporting on it was fixed.

Damaging a chunk **cancels a bake in flight**. `place_block` and `remove_block` both call
`settle_bake_job(chunk_id, false)`, for a good reason -- a bake running against the old geometry is
worthless and is reading the very arrays those calls just rewrote. What neither does is re-issue it.

`_drain_mesh_queue` waits on `bake_ready` and nothing else. So a piece that was hit *again* while its
mesh was baking sat in the queue waiting for a `bake_ready` that could never come, and stayed
invisible until something unrelated happened to ask for a bake of that chunk. Three lines fix it:

```gdscript
if not world.bake_ready(isl.chunk):
    if not world.bake_pending(isl.chunk):
        world.bake_chunk_async(isl.chunk)
    i += 1
    continue
```

| 200-building collapse | before | after |
|---|---|---|
| Worst time a piece spent invisible | **102 ticks** (3.4 s) | **1 tick** |
| Mean | 17.8 ticks (0.6 s) | 1.0 |

This explains every observation. Only moving pieces flash, because only islands go through this
queue -- a standing building keeps its shell up until its bake lands. Shooting a hole does not cause
it, because one hit does not interrupt a bake that is already finished. An impact does, because an
impact damages a piece repeatedly over consecutive ticks, and each hit cancels the bake the previous
one started.

**The counter had been lying, and it was my counter.** The reset branch was attached to `if false:`
and therefore ran on every tick regardless, so a piece's blind time was recorded and zeroed
immediately -- it could not report more than 1 whatever happened. Every "worst 1 tick" in this
document before this section was that artefact, including the numbers used to justify raising
`SYNC_MESH_MAX_BLOCKS`. That change stands on its own (fewer pieces enter the queue at all), but it
was not the fix, and it was reported as one.

Two lessons, both already paid for once in this project: a measurement that has never printed a bad
number has not been validated, and the elimination table below was built on top of a broken
instrument -- which is why five correct-looking eliminations still left the real cause untouched.

### The flash: what it is not

Six hypotheses, five eliminated, and every elimination came from an observation or a measurement
rather than from reading code. Recorded as a list because the reading-code approach produced three
confident wrong answers in a row.

| Hypothesis | How it was killed |
|---|---|
| In-place index patching | Standing buildings use the same patch and never flash; toggling patching off changes nothing |
| Island **body** interpolation | Toggled off live — no change |
| Island **mesh** interpolation mismatched with its parent | Toggled to inherit — no change |
| Pieces with no mesh yet (`blind` ticks) | Measured: 7-9 events in a whole 22-building collapse, one tick each. Far too rare to be "consistent" |
| A mesh that is non-null but has zero surfaces | Counted separately: one extra event |
| The body's origin jumping when its shapes are rebuilt | Measured: **zero** jumps larger than its speed cap allows |

What the observations pin down:

* only pieces that **move** flash — a standing building never does;
* **shooting a hole does not cause it**; a fracture from an impact does;
* the smallest pieces are worst.

The one hypothesis left standing is **culling**. An instance is dropped by its AABB, and
`mesh_surface_update_index_region` never touches one. On a stationary building a stale AABB still
overlaps the real geometry and costs nothing. On a piece travelling metres per tick it does not.
Key `C` gives every island a custom AABB large enough that culling cannot drop it, which settles the
question in one keypress.

**Why measurement keeps failing here.** The artefact is one rendered frame. Every automated
instrument tried so far either samples node state once per physics tick (and the state is correct at
both ends of the tick), or reads the framebuffer back and thereby forces a GPU sync that hides it --
established when a test built for exactly this passed with three fixes deliberately disabled. The
toggles exist because a person watching is the only instrument that has worked.

### Only falling pieces flash, and that names the cause

Two observations narrowed this to one mechanism:

* the flash happens on **every** piece that is damaged or broken, not only newly split ones;
* **standing buildings never flash**, and they go through the *same* in-place index patch.

That rules the index patch out, and it fits one thing precisely. If a body is drawn at a **stale
transform** for a single frame, a stationary piece looks identical -- the stale transform is the same
transform -- and a *moving* piece is drawn somewhere else entirely, which reads as vanishing. The
smaller and faster the piece, the further it travels in that frame, and the more obvious it is. That
is the reported symptom, exactly.

The likely mechanism is a mismatch this code created deliberately: an island's `MeshInstance3D` has
`PHYSICS_INTERPOLATION_MODE_OFF` while being a **child of an interpolated `RigidBody3D`**. Godot does
not properly support an uninterpolated child under an interpolated parent, and the consequences can
only ever show when the parent moves. The mesh was set to OFF to stop `Buffer argument is not a valid
buffer` errors from in-place index patching -- so the two fixes are in direct conflict, and one of
them has to give.

**This is not something automated measurement can settle.** The artefact is one frame, and any test
that reads the framebuffer back forces a GPU sync that hides it -- established earlier when a test
built for exactly this passed with three fixes deliberately disabled. What can be done is to make the
alternatives switchable at runtime so the one instrument that *can* see it -- a person watching --
gets a direct A/B in a single session:

| Key | Toggles | What it tells you |
|---|---|---|
| `M` | island **mesh** interpolation (`INHERIT` vs `OFF`) | the prime suspect; watch the console for buffer errors with it ON |
| `I` | island **body** interpolation | OFF trades the flash for 30 Hz judder; if the flash survives, interpolation was never the cause |
| `P` | in-place index patching | already ruled out by standing buildings, kept so that can be re-checked rather than remembered |

Whichever combination stops it decides the real fix, and the buffer errors then need solving a
different way -- the `MeshRetirer` already exists for precisely that class of problem.

### The disappearing piece, found by counting the right thing

The report that cracked it: *the SMALL piece vanishes; the large one usually does not.* That inverts
the mesh-upload hypothesis below, which predicted the opposite, and it points straight at `_shed`:

```gdscript
spawn(isl.chunk, moved, linear, angular)  # child gets a MeshInstance3D with NO mesh
isl.disable_blocks(moved, RID())          # parent drops those blocks at once
```

`spawn` baked on the calling thread only for pieces of `SYNC_MESH_MAX_BLOCKS` (24) or fewer.
Anything larger was created with an empty `MeshInstance3D` and drew **nothing** until its bake came
back from the worker, while the parent had already stopped drawing those bricks. A large toppling
section never shows it because `adopt` carries its existing mesh across instead of re-baking -- which
is exactly the asymmetry that was reported.

**The first metric was useless and looked convincing.** Counting ticks where *any* piece was
invisible gave 1,304 of ~2,700 -- alarming, and meaningless: during a collapse something is nearly
always mid-bake. What is actually seen is how long ONE piece stays invisible, so each island now
counts its own blind ticks and the report gives worst and mean.

With the right metric the size of the problem, and the fix, are both legible:

| `SYNC_MESH_MAX_BLOCKS` | pieces that went blind | worst |
|---|---|---|
| 24 | 14 | 1 tick |
| **200** | **2-5** | 1 tick |

One physics tick at 30 Hz is two rendered frames -- precisely "a quick flash". The duration is one
tick whatever the threshold; what the threshold changes is how often it happens, and the pieces that
still do it are 1,200-2,700 bricks, the ones the flash was never noticed on.

`SYNC_MESH_PER_TICK` at 16 took it to 3 but pushed the worst frame from 33.4 ms to 53.7 ms. Left at
6. The mesh queue also has its own `MESH_BUDGET_MS` now instead of sharing one budget with resolving
and fracturing -- drawing a piece that already exists is more urgent than either -- though measurement
says the queue was never the bottleneck: `mesh 0.0` in the profile, the wait was the bake.

What remains: a piece over the threshold is still blind for one tick, because nothing holds the
parent's faces until the child can draw its own. Fixing that properly means deferring the parent's
index patch, not raising a threshold.

### The flash test that could not see the flash

Three causes of the one-frame disappearance have been found and fixed by reading code. All three are
real state changes that reset interpolation, and all three are unverified: **the test built to detect
the flash passes with all three fixes deliberately disabled.**

The test renders real frames and counts the pixels a piece covers, differencing each frame against a
baseline captured with the piece hidden. A flash is a frame far below both its neighbours. It watches
two moments: a building toppling (the only place a mesh node is reparented mid-flight) and a settled
piece being damaged and then split, with the damage applied inside `_physics_process` rather than
from the coroutine, because interpolation draws *between* ticks.

The first version failed for a reason worth keeping: **reading the framebuffer back every frame costs
a GPU sync**, which dragged rendering to 38 fps. At 30 Hz physics that is 1.27 render frames per
tick -- so almost every frame landed on a tick boundary and interpolation had nothing to get wrong.
The instrument was destroying the condition it was measuring. Dropping the pass to 10 Hz physics
gives 3.75 render frames per tick and restores it.

It still passes with the fixes off. So either the resets were never the cause, or the same GPU sync
that forced the timing also forces any pending buffer upload to complete -- which would mask the more
likely explanation:

**the mesh swap, not the transform.** A full rebuild assigns a brand-new `ArrayMesh`, and if the
renderer draws before that mesh's buffers are ready the instance draws nothing for exactly one frame.
That fits the report better than interpolation does: it explains why it shows on *large* pieces
(bigger buffers, longer uploads) and why both damage and splitting trigger it (both rebuild). A
readback test cannot distinguish it, because the readback guarantees the upload has finished.

The three resets are kept: they are what Godot's own documentation asks for at those call sites, and
the spawn path already did it. But they are not evidence, and this document should not have implied
they were.

### Where it stands

**Correctness** -- nine probes, zero failures, zero errors, zero warnings:

| | |
|---|---|
| `m0`-`m3` | grid, damage, stress, islands |
| `floor`, `floorshed` | floors hold; what comes loose when a wall goes |
| `fallen` | breaking a building that has already fallen |
| `replay` | integer determinism, command replay, content-derived piece identity |
| `city` | 5000 buildings as recipes, damage across de-materialisation, shell streaming |
| `interior` | rooms, manifests, the spill, and that furniture is not structure |
| `build` | the recipe, the city placement, fixtures, the cheap tier, the two layers |

**Cost.** Taken on a quiet machine -- no editor open on the project, nothing else resident. This
matters more than it sounds: the same shot pass with a Godot editor holding 1.3 GB alongside it
reported *mean 76.0 ms, worst 163.8 ms, 222 of 376 frames over budget*. The editor was four and a
half times the cost of the game.

Re-measured with a staircase in every building (Stage 5), built into the buildings' own grids:

| | 22-building collapse (`--shot`) | 200 damaged, 8 collapse (`--stress`) |
|---|---|---|
| Mean frame | **16.7 ms** | **17.0 ms** |
| Worst frame | 33.3-42.1 ms | 42.9 ms |
| Over 33.3 ms | 3-9 of ~705 (0.4-1.3%) | 32 of 2749 (1.2%) |
| Worst script tick | 31.4 ms | ~39 ms |
| Worst `islands.tick` | ~8 ms | ~10 ms |
| Memory after | ~70 MB | **145.1 MB** (peak 397.6 MB while 186 are resident) |

Without staircases the same two passes measure 16.7 ms with 1 of 729 and 9 of 2815 over, which is
what `--no-fixtures` is for. The difference is brick: a building with a staircase in it has more of
it to take apart.

The first version of Stage 5 -- a fixture with a chunk and a body of its own -- measured **22-24 ms
mean and 78 of 630 frames over budget** on the 22-building scene, and needed merged collision boxes,
a debris range and a no-re-solve rule for rubble to come back to baseline. Putting the blocks in the
host's grid retired all three.

The stress pass holds 58.9-60.0 fps in every one of its five phases:

| Phase | Mean | fps | Over 33.3 ms |
|---|---|---|---|
| under fire | 16.7 ms | 59.9 | 1 of 200 |
| damage queue draining | 17.0 ms | 58.9 | 10 of 362 |
| collapsing | 16.7 ms | 60.0 | 0 of 180 |
| settled | 16.7 ms | 60.0 | 0 of 240 |
| trimmed | 16.7 ms | 59.9 | 3 of 1800 |

Eleven passes, all green on a quiet machine: nine probes (177 checks), `--lod` (12 checks), and
`--reach` (damage lands at every distance from 40 m to 480 m). Zero failures, zero errors, zero
warnings.

Both spikes that dominated the previous measurement are gone, and neither was fixed by touching a
budget. The 42 ms `promote_finish` and the 44.9 ms `remesh` were **consequences of producing too many
pieces**: every loose brick is a piece to spawn, a contact to resolve, and -- when it lands on a
standing building -- a reason to materialise that building mid-collapse. Cutting at seams instead of
crumbling took splits from 364 to 218 and took both spikes with it.

What remains at the top of a worst tick is `spawn` and `fracture`, in that order, and they are the
irreducible cost of pieces genuinely coming apart.

**Memory now comes back.** 200 damaged-but-standing buildings peak at 689 MB and settle to 212 MB
once the trim catches up.

**What the stress pass exercises.** 200 buildings damaged, 8 of them demolished, the damage queue
fully drained, and a final phase held past `TRIM_AFTER_MS` to see what is handed back. It prints how
many buildings took a hit and how many toppled, and warns if any hits were left queued -- see "What
the stress pass could not say" for why it prints all three.

## Known limitations

1. **Two single-item spikes remain**, and they are what the worst frames are made of: one
   `promote_finish` costs 42 ms, and a from-scratch building remesh costs enough that 120 of them
   put 44.9 ms into one tick. Both already run at a count of 1-2 per tick, so the per-tick budget
   has no room left to give -- the operations themselves have to get cheaper or be split. Mean
   frame time is 16.8-17.2 ms and 97.6% of frames are inside budget, so these are spikes rather
   than a throughput problem.
3. **Collision is one box per brick for anything still moving.** Settled pieces merge theirs down,
   and standing buildings now merge once the shooting has moved on (112,321 boxes to 8,634 in the
   stress pass), but a falling section still carries a shape per brick -- and merging one at birth
   was tried and reverted, because its own landing undoes it.
3. **The tail after a big collapse drains slowly.** Splitting is capped at one piece per pass and
   re-queued, so 5,562 splits finish over many seconds. Frames stay near budget during it but not
   reliably under -- the settled phase measured 16.7 ms on one run and 21.1 ms on the next.
4. **Memory under total destruction is 1.2 GB.** 200 simultaneously materialised buildings plus 317
   islands. `_trim_quiet` and the island LOD give geometry back, but only for pieces that are
   distant and quiet, and in that run almost nothing was either.
5. **Budgets trade latency for smoothness, and it shows at the extremes.** A section's bricks leave
   its building the instant the solver says so, but its mesh may be several ticks behind, and a
   piece with more to shed than one pass allows finishes coming apart over the next few ticks.
6. **Presentation lags the world by a few ticks during a heavy collapse.** That is the deliberate
   trade above: a section's bricks leave its building the instant the solver says so, but its mesh
   is built when a worker finishes baking it, one to three ticks later. Visible only if you are
   looking for it, at eleven simultaneous topples.
7. **A piece resting at an angle gets the nearest of six gravity axes.** Exact for anything lying on
   a face, which is most things; approximate for a section balanced on a corner.
8. **The parent of a split keeps its old centre of mass.** Shapes and mass move with the blocks, but
   the body origin does not, so a piece that has lost half of itself rotates about a point that is
   no longer its centre. Cheap to live with, wrong in principle; re-spawning both halves would fix
   it at the cost of two spawns instead of one.
9. **Floor slabs still get launched into the sky occasionally.** A thin wide piece can spawn
   overlapping what it just left and take a large separation impulse out of the solver. The
   parent's shapes are now disabled *before* the island body joins the space, which removes the
   worst of it, and speed and spin are clamped; spawning a piece already clear of its parent is the
   real fix.
10. **Impact damage to buildings is real but sparse** -- 10 bricks over a 22-building collapse. It
   fires on a speed drop, capped at `MAX_IMPACTS` per island, so a slow settle onto a roof does not
   register. The contact points and the collider are now the solver's own, so what remains is the
   trigger, not the geometry.
11. **Small surfaces cannot be index-patched.** Godot stores indices as uint16 at 65536 vertices or
   fewer, and `update_index_region` returns int32, so anything smaller takes a full rebuild. Cheap
   for small meshes, but it means a mid-size island pays a full vertex upload per hit.
12. **The face bake is 237 ms and 220 MB for a 16.5k-block chunk**, on the main thread at load. It
   is a pure function of the chunk and belongs on a worker -- and an undamaged building should not
   have one at all.
13. **A dense occupancy grid costs ~150 cells per block for a hollow tower** (9.5 MB of a 150 m
   tower's 10 MB at rest). Fine for a damaged region, wrong for a whole building.
14. **A masked part is a voxel approximation.** No baked custom mesh and no convex colliders per
   archetype yet, so a true slope or curve reads as a staircase and collides as one. The seam is in
   `Archetype`; the masks already carry the structural truth.
15. **A masked part collides as one box per solid cell.** Blunt but exact; merging runs into larger
   boxes is an optimisation, not a correctness matter.
16. **Rotation is not a runtime feature.** Both orientations of a 2x4 are separate archetypes.
17. **Disconnection is not the same as being unsupported.** An island spawns where it stood and
	will not move if something is still under it. Correct physics -- a hollow square on its own
	perimeter is very stable -- but a collapse only reads as one when material is actually removed.
	The global stability check covers the toppling case; local overhangs are not covered.
18. **Islands are never re-anchored.** One resting on the ground stays an island rather than
	becoming static structure again, and it gets no stress solve. It stays fully breakable and still
	moves when what holds it up is removed, which is what matters for play. What it used to cost was
	a body and a chunk that never went back to being cheap; it now sleeps into a `ChunkRecord` when
	it is far away, so the cost is bounded even though the re-anchoring is not done.
19. **The grounding and stress solves are whole-chunk, not local.** Cheap so far (3-8 ms at 16.5k)
	and linear, but the spec calls for a *local* fill.
20. **A crushed block can never be re-supported.** `support_broken` makes a block permanently
	ungroundable rather than severing one specific joint.
21. **Tension per stud is a tuned constant, not a material property** (9.3 N, derived in
	`BrickFailure.md` §4.5), and it does not account for walls that taper.
22. **One chunk per building.** The 150 m tower's chunk is 48 x 1078 x 48 cells, ~9.9 MB of
	occupancy for 16.5k blocks. Sections, not buildings, are what should materialise (Plan §4.3).
23. **Chunk-boundary faces are always emitted**, so two adjacent chunks draw the wall between them
	twice.
24. **A dead or detached block still owns its cells**, so nothing can be rebuilt into the hole.
25. **No studs.** Deliberate -- Plan D4; M5, with the connector-type edge filter.
26. **Per-cell quads, no greedy merging** -- 685k triangles for one tower is mostly this.
27. **Debug build only.** No `template_release` and no Linux build, both of which the gate needs.
28. **Cluster mass is a guess.** `MASS_SCALE = 10`, with no reference to real density.
29. **A build's shell is a voxel silhouette, not its bricks.** At two studs and a course it keeps
	the shape and the colours and loses the detail; a one-brick decoration disappears into the
	voxel it shares with its neighbours. That is the trade a cheap tier is, but it is coarser than
	the tower shell's course banding.
30. **A sideways frame sheds whole, not locally.** The stress solve and the detached-group search
	run per chunk, so a frame comes off when the welds holding it die -- but bricks *inside* a
	sideways frame do not come loose the way the root frame's do, and its own grid plane reads as a
	foundation it should not have.
31. **A toppling build comes apart into its frames.** Each becomes its own island rather than one
	welded body falling together. A weld is authoring-time structure; real joints are deferred with
	vehicles ([BuildMode §6.3](BuildMode.md)).
32. **A staircase is structure.** It is brick in the building's own grid, so it carries load, it
	is in `solve_stress`, and a building can lean on it. That is the trade for coming apart with the
	building rather than standing in its rubble, and it is deliberate -- but a tower whose walls are
	gone can be left standing on its stairwell.
33. **The stairwell is carved bluntly.** Every block whose cells the shaft touches is removed whole,
	and a floor plate is 4x4 against an 8x8 shaft, so the hole is up to three studs wider than the
	flight on each side.
34. **A staircase in every building is 1.2% of frames over budget** in the 200-building stress pass,
	against 0.3% without them, all of it in the damage-queue phase. More brick per building is more
	brick to take apart.
35. **`Layers.FIXTURE` is unused.** It was written for a staircase with a body of its own and is
	kept for a fixture that is genuinely not brick.
38. **The duck is predictive, not reactive.** It tests the standing capsule along the way it is
	about to move, so walking into a low opening ducks -- but a ceiling that arrives on top of a
	standing figure (a floor settling onto it) does not, because nothing was moving into it.
39. **A tread is a cantilever and will shed.** By design (§9.3), but it means a damaged staircase
	loses treads before it loses its newel, and a flight with its treads gone is still a climbable
	column of stumps.
40. **The workshop offers one fixture and no choice about it.** `K` makes a decorative staircase;
	the structural/decorative flag is not exposed, which is [BuildMode §9.2](BuildMode.md)'s own
	condition rather than an oversight, and railings, cornices and pipework are more masks on the
	same machinery whenever they are wanted.
41. **Occlusion is not wired up.** `OccluderInstance3D` (Interiors §3) would let a building's shell
	hide its own interior; nothing does that yet, so a furnished room is drawn whenever it is
	within the frustum, walls or no walls.
42. **A shell has no windows.** The brick tier is cut through and neither shell tier is, so a
	building gains its windows at the moment it materialises. Inside `PROMOTE_RANGE` that
	usually happens behind the player's back; on the shell/brick boundary it is a pop.
43. **Room collision accumulates shapes.** `PhysicsServer3D` has no remove-shape that keeps the
	other indices, so closing a room disables its shapes rather than removing them. They are
	reclaimed when the building next de-materialises; a room opened and closed many times between
	those leaves disabled shapes on the body.
44. **The chamfer is shading, not geometry.** At a grazing angle or with the camera a few
	centimetres off a brick, the silhouette is still a hard edge -- there is no bevel to see round.
	It also does not reach single bricks drawn from the shared MultiMesh, which use a plain
	`StandardMaterial3D` and have neither seams nor bevel.
45. **The walking body is on the debug camera**, not on a pawn owned by a player slot. It is one
	capsule with no animation, no third person and no networking, and it is deliberately the same
	throwaway rig the free-fly camera always was.
46. **A structural brick resting on a decorative one is still grounded by it.** The role takes a
	block out of the load and out of the balance test; it does not cut the connectivity graph.
	Nothing in the generated city does this, but the workshop's INTERIOR layer allows it, so a
	player can stand a wall on a table and get a bridge for free. BuildMode §9.2 already names
	the rule -- a structural frame may not weld to a decorative one -- and it is not enforced.
47. **Interiors are drawn flat.** `FurnitureMesh` is a MultiMesh of scaled unit cubes under a plain
	`StandardMaterial3D`, so a chair has neither the seams nor the chamfer the brickwork around
	it has. The brick shader reads UV as metres across a face and UV2 as that face's size, and
	a unit cube scaled by an instance transform has neither. Same road the single bricks in
	`IslandManager`'s shared MultiMesh already take.
48. **A room reports the openings of all four exterior walls over its own span**, including the
	two that belong to the room across the floor from it. Harmless for a portal test on one
	open storey -- the ray still has to reach the hole -- and wrong if floors are ever
	partitioned into rooms with walls of their own.

## Next

M0-M4 are done and probed. The three things standing between this and a city that holds 60 fps
under fire, in the order they are worth doing:

1. ~~**Try `physics/3d/run_on_separate_thread`.**~~ **Tried, measured, rejected** -- see "Physics on
   a separate thread". The solver is still the biggest single cost in a collapse; what is left to
   try on it is item 4, not another thread.
2. **Fewer floor plates.** 54% of a building by block count is flooring, and everything that scales
   with blocks pays for it first. This is a design decision about how buildings look, not an
   optimisation to make unilaterally.
3. **Networking**, when it is wanted. The substrate is in and tested
   ([Multiplayer.md](Multiplayer.md)); what is missing is a transport, server authority, and a
   bandwidth budget for physics state.
4. ~~**Merge runs of blocks into larger collision boxes.**~~ **Done for standing buildings** (see
   "Merged collision for standing buildings"), 13x fewer boxes, frame time unchanged. What is left
   is the case that resisted it twice: a section still **falling** carries a box per brick, and
   merging it at birth is undone by its own landing.
5. **Sections, not buildings** (Plan §4.3). A rocket hitting one corner has no business allocating
   a 2.5M-cell grid for the whole tower, and it is the same allocation that makes splitting
   expensive. A *local* stress solve falls out of the same change.
6. **Give islands back to the world.** ✅ **Done, as a dormant tier rather than as re-anchoring**
   (see "Wreckage, given back"). A settled piece far from anybody sleeps into a `ChunkRecord` of 17
   bytes a block and comes back byte-identical; 3,461 blocks of wreckage went from 7.7 MB resident
   to 57.5 KB. What is still not done is making one *static scenery* again -- it wakes as an island,
   not as structure, so it never rejoins the stress solve.
7. **A release build.** Everything measured here is `template_debug`.

Then M5: real studs, with the connector-type edge filter.

Build mode's §11 is complete, Stage 5 included, and so is the cheap tier §12 question 3 asked for:
a build's shell is a voxelised silhouette of its own recipe, so a creation streams and trims like
anything else and shows its damage while it does. The dormant tier that was left over from
fixtures is in too, for the layer that needed it most: wreckage sleeps into a `ChunkRecord` when
nobody is near it. And [Interiors](Interiors.md) §1-§5 are in: rooms from the recipe,
contents from a seed, a diff for what changed, the portal test, §5.2's analytic resolve and
§4.1's seeded spill. What that leaves on the interiors side is occlusion (§3's
`OccluderInstance3D`) and §5.3's audio rule, which needs audio to exist first.

**The measurement everything here rests on has a hole in it: every number in this document is a
`template_debug` build.** Item 7 is cheap to try and would re-baseline the lot.
