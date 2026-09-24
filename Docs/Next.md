# Next — where to pick this up

A handover note, not a design doc. What runs is [Status.md](Status.md); *why*
the design is what it is lives in [Scale.md](Scale.md), [Interiors.md](Interiors.md)
and [Plan.md](Plan.md). This file is only **what is not done, in the order to
do it**, and the traps waiting in each one.

Last updated **2026-09-23**, after the drawn interior rung (§2.1).

---

## 1. Where things stand

The **structure half is finished and clean.** Buildings are laid on a lattice
that starts at the outer face: one `plate_10x10` per floor cell, the edge ones
running under the exterior walls so **every floor is clamped into its walls**,
columns centred on lattice points tying four panels each, interior walls
straddling panel seams, and a stairwell that is one cell clear of the walls.
Twelve shapes build with **zero stress failures and zero detached blocks** and
the biggest tower is 22,507 blocks (it was 50,535 before the lattice and 29,716
before the floors went into the walls). `tools/structure_probe.gd` is the gate;
Docs/Scale.md has the full account, "The seventh: floors IN the walls".

The **interior half is where the work is.** Rooms and their contents exist and
are correct, and now have three states: nothing, drawn, or every brick (§2.1).

Already done and not to be redone:

* the debris cap — two classes, oldest-first eviction, exported as a player
  setting and overridable with `--debris-small=` / `--debris-large=` /
  `--debris-total=`. Measured; `80 / 24 / 96` is the row to keep.
* the workshop's structure/interior layer toggle (`I`) — a building's structure
  and its interior are authored separately already.
* windows, with a lintel course that actually bridges them.

---

## 2. Next steps, in order

### 2.1 The cheap interior rung — **done**

A room is now shut, **drawn** or real. Drawn is the manifest on screen
(`RoomManifest.draw_items` → `FurnitureMesh.attach_drawn`) and one collision
box per item on the building's furniture body, with no blocks laid. Everything
within `ROOM_RANGE` is drawn; a room becomes bricks only when **touched** — a
watched blast reaching it (`compromise_rooms`), or the player within
`ROOM_REACH` (1.5 m) on its own storey — and goes back to drawn past
`ROOM_REACH_RELEASE` (4 m), keeping its diff. A room a blast promoted
(`Room.hit`) stays real until the old sleep range, because a drawing can only
show an item whole or not at all. `interior_probe` checks the drawing is
exactly the bricks it becomes, box for box.

Measured on the biggest `--big` building (204 rooms), `--interiors` arm E
against arm B:

| every room… | bricks laid | collision boxes | time |
|---|---|---|---|
| real (B) | 1,587 | 1,587 | 8–10 ms |
| drawn (E) | **0** | **493** | ~7 ms (+14 ms once per run: first node's pipeline) |

And the streaming pass standing inside it (arm D, 40 passes): mean 1.10 →
1.02 ms, worst **15.4 → 6.5 ms**, rooms real afterwards **18 → 2**.

**Be honest about the size of this.** The numbers the old §2.1 asked to beat
(+25,537 boxes, 189 ms) were from before the lattice rewrite; that rewrite cut
the biggest building to 204 rooms, so the rung's win is 3× fewer boxes and no
bricks, not 50×. What it really buys is §2.2: something that can come back
without coming back as bricks.

Left over: a demotion still goes through `_close_room` → `_disable`, which
un-merges the *building's* collision if it was merged (furniture blocks are in
`add_chunk_shapes` too). Not seen in the measurements; watch for it if walking
through a quiet building hitches.

### 2.2 Delete, don't simulate, during a collapse — **mostly done**

For furniture it is done (Status: "Floating furniture: four causes"):
untouched rooms are written off when their building comes down, and a piece
that is only furniture is deleted where it comes loose unless it is within 6 m
of the player. `--interior-audit` counts what is left at every stage.

For small structure too: a piece of three bricks or fewer breaks off only
within 30 m of the player and in view, and is deleted before it gets a body
anywhere else (`IslandManager.TINY_BLOCKS` / `TINY_RANGE`).

Still open: bigger pieces that do not matter should be deleted and respawned
later if they start to matter, not simulated through the collapse. The debris
cap is the machinery for the first half.

### 2.3 A room neighbour graph, replacing the radius

Scale.md §5.2 item 2 and §6 Stage 4. Replace "rooms within R metres" with "the
room you are in, and the rooms it connects to". Storey-span already took 90% of
the win; the graph is the rest, and it also replaces the raycast portal test
with a walk.

Now that walls and doorways are real geometry, the graph can be built from
`TowerRecipe.plan` directly — `wall_x` / `wall_z` say where the walls are and
`_door_span` says where the holes in them are — instead of from a flood fill.
That is cheaper than the design assumed and worth doing that way.

### 2.4 Fake interiors for FAR buildings — **start here**

The fake rung is in for buildings that are bricks: every room against an
outside wall, within 70 m, drawn unlit from its manifest with no collision
(Status: "Fake interiors"). It replaced the per-window ray test outright.

What is missing is buildings that are still SHELLS, and it is not a matter of
parenting the fake to the shell: **shells have no windows**
(`BuildingShell` draws solid bands), so boxes behind them would never be seen,
and cutting real holes would mean building floors inside every shell as well.
The plan is a window-glass shader on the shell's window courses that paints a
room behind the glass (interior mapping -- the Spider-Man / Matrix Awakens
technique): the room kind from a hash of building and window, no geometry, no
per-room data. `TowerRecipe.window_gaps` / `is_window_course` say where the
windows are, and the shell's UVs are already in metres.

### 2.5 Sections, not buildings, as the unit of materialisation

Scale.md §4.7: never ask a question proportional to the building. A 200-course
tower still materialises as one thing. Band-at-a-time baking is in; making the
*unit* a section rather than a building is not.

### 2.6 Workshop room tools

Scale.md §6 Stage 6. Auto-detect rooms and floors from an authored build, or
set them by hand, and mark what is structure. The layer toggle exists; the room
marking does not.

---

## 3. Open questions and known limits

* **Small footprints get two rooms.** `ROOM_PANELS = 3`, so a 30- or 40-stud
  building has no lattice line far enough in to carry a wall and falls back to
  one wall down the middle. Fine today; revisit if the city gets more small
  buildings.
* **1x4 walls are a switch, not the default.** `ROOM_WALL_THICK` / `WALL_THICK`
  = 1 builds them and every shape stands (columns go in first as pilasters),
  but the worst frame of a collapse goes from 33-47 ms to 80-122 ms: thin wall
  fragments rock instead of settling. Scale.md has the table.
* **`ROOM_PANELS` is a budget decision.** An interior wall is four courses
  running the width of the building on *every* storey. At three panels (~10 m)
  the big tower's interior walls are about 9,000 blocks. At one panel they
  would cost more than the floors do. Do not lower it without measuring.
* **Non-conforming footprints still work, but pay.** A footprint that does not
  divide leaves a strip of 4x4s and 2x2s that reach neither a wall nor a lattice
  column, so they get columns of their own — tied to the building only through
  the base, which on its side comes loose. The city's shape tables conform
  (`k * PANEL`); anything authored in the workshop may not, and that is the cost.
* **Real printable assets are not started.** The decision stands: game parts and
  printable parts are separate assets so each can be designed for its medium,
  and things nobody prints — building structure, terrain, the 10x10 floor panel,
  the columns — need no printable twin. What has to hold is the **grid**: every
  dimension is in studs and plates, so a printed brick lines up.

---

## 4. How to check you have not broken anything

Godot: `C:\Users\lbaun\Documents\Godot_v4.6.1-stable_win64.exe\Godot_v4.6.1-stable_win64_console.exe`

```sh
# every probe -- 28 of them, all should end "0 failed"
for f in tools/*_probe.gd; do "$GODOT" --headless --path . --script "$f"; done

# the city. NAME THE SCENE: main_scene is terrain_test.tscn in the working tree.
# NOT headless: the passes save screenshots, and headless they wait forever.
"$GODOT" --path . --resolution 1280x720 res://scenes/city.tscn -- --shot
"$GODOT" --path . --resolution 1280x720 res://scenes/city.tscn -- --stress
"$GODOT" --path . --resolution 1280x720 res://scenes/city.tscn -- --big --shot
# and what the rooms cost, all four rungs of them (arms A-E); and every interior
# piece counted through a collapse -- all zeros is the pass mark
"$GODOT" --path . --resolution 1280x720 res://scenes/city.tscn -- --interiors --big
"$GODOT" --path . --resolution 1280x720 res://scenes/city.tscn -- --interior-audit
```

`--big` on its own never quits; it needs `--shot` to take its measurement and
exit. The `--shot` pass's "settled wreckage is still breakable" check is
flaky — it aims at one brick of whatever piece landed biggest — so rerun
before believing a FAIL there.

Numbers to beat, as of the floors-in-walls change: 22 buildings in ~20 ms,
16,572 triangles of shell, and `structure_probe` 48/0 -- every one of the twelve
shapes standing with zero stress failures, zero detached blocks and every edge
floor panel joined to its wall. The biggest tower is 22,507 blocks.

Building the GDExtension: `cd gdextension/brick && python -m SCons target=template_debug -j8`
(`scons` is not on PATH; the module is).
