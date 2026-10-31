# Room modules: rooms built by hand, buildings grown from them

User, 2026-10-30: build a room in the workshop, mark its entries and exits and the other things a
generator needs, then let a procedural building system put such rooms together. Several
generators for several purposes:

* **Grow by connectors** (first): start at an entrance room, snap rooms on door to door, never a
  room inside another, rooms may meet at more than one place, and the whole building has a
  **start** and a **finish** with a path through it. Castles, bunkers, compounds, any shape.
* **Set by shell** (stage 6, section 4): an outer shell (Sketch, Walls) whose inside is split into rooms
  and filled. Skyscrapers and other buildings whose outside is fixed.

The markers live where the rooms already do: the spaces tool's record (Docs/Structures.md 3.1,
`recipe.meta["structure"]`), so a module is any build whose rooms have been found and marked.

## 1. A module

A **module** is a build with `recipe.meta["module"]` on. Unlike a room template
(`RoomTemplates`, furniture only), a module keeps its **structure bricks**: its walls, floor and
ceiling are what the generator lays. One module may hold one room or several (a corridor with two
offices off it is one module).

The rules on the module itself (`recipe.meta["module"]`, set on the rail):

| field | | |
|---|---|---|
| `on` | bool | the generator may use it |
| `role` | `room`, `corridor`, `stair`, `start`, `finish`, `hang` | what the generator asks it for; `start` and `finish` are where the path begins and ends; `hang` a small room made to hang off a wall (the only kind a hang spot takes when the library has one) |
| `min`, `max` | int | how many of it a building has at least / at most (`max` -1: no limit) |
| `weight` | float | how often it is picked among those that fit |
| `storeys` | `any`, `ground`, `upper`, `top` | where it may go |

## 2. The markers

All in the build's grid (studs across, plates up). Found where they can be, set by hand where
they are wrong, kept by hand through an edit the way an opening's kind already is.

### 2.1 Connectors (entries and exits)
Every **doorway, door, arch or open side** of a room that leads out of the module is a connector
-- found, not placed: the spaces tool already finds the openings (Structures.md 3.2). An opening
between two rooms of the same module is inside it, not a connector. A window is not a connector
(it is a facade spot, 2.4).

```
{"kind": "door", "space": 0, "at": [x, y, z], "facing": 0..3, "size": [w, h],
 "link": "auto" | "off" | "start" | "finish"}
```

* `at`: the low corner of the opening's bottom row (lowest X or Z along the wall) on the
  module's **outer face** -- the first cell past the wall, its thickness read from the bricks
  beside the hole (`depth`; 0 for an open side). Two modules join where the second's `at` is
  the first's last wall cell (`b.at == a.at - a's facing`), their `facing`s opposite: walls back
  to back, the doorway through both.
* `facing`: out of the room, 0 +X, 1 +Z, 2 -X, 3 -Z.
* `size`: the opening's width in studs and height in plates. Two connectors join only when the
  sizes are the same.
* `link`, set by hand on the opening (a click with **Link** on the rail): `auto` (a connector
  when it leads out), `off` (never: a door that stays shut), `start` (the building's entrance
  from outside), `finish` (the building's way out, or its goal: the vault, the roof hatch).

### 2.2 Stair links
Placed by hand on a room's floor (**down**) or under its ceiling (**up**): where a stair or a shaft
joins this room to the storey below or above. Two modules join at a stair link when the upper
one's down link stands over the lower one's up link, its floor on the lower one's ceiling.

```
{"kind": "stair_up" | "stair_down", "space": 0, "at": [x, y, z]}
```

### 2.3 Module rules
Section 1.

### 2.4 Facade spots
Places on an outside wall where the generator may put something: a **window** (a style picked
per building), a **balcony**, or a **hang** point, where a small room may hang off the wall.
Placed by hand with a facing; the windows and glass the finder already sees count as window
spots too.

```
{"kind": "window" | "balcony" | "hang", "space": 0, "at": [x, y, z], "facing": 0..3}
```

The hand-placed ones (stair links, facade spots) are `marks` in the record; the connectors are
worked out again from the openings and the stair links whenever the rooms are found again:

```
"structure": {"spaces": [...], "openings": [... "link"], "points": [...],
              "marks": [{"kind", "space", "at", "facing"}], "connectors": [...]}
```

## 3. Grow by connectors

1. **The library**: every build with a module on, read once: its cells (what it fills, column
   by column with the plates each column fills, 2.5D), its connectors, its rules -- and each
   turned four ways.
2. **The path first**: put a `start` module (one with a `start` connector) at the origin. Grow a
   chain from its open connectors -- each step a module that fits (sizes match, it overlaps no
   cell already filled, its storey rule holds), picked by weight -- to the path's length, then a
   `finish` module. A dead end steps back (backtracking, a limit on tries).
3. **Branches**: rooms on the path's open connectors until the building's room budget, the
   modules' `min`s met first, their `max`s never passed.
4. **Loops**: any two open connectors that now meet (back to back, facing each other, the same
   size) are joined -- rooms meeting at more than one place.
5. **Caps**: every connector left open is walled up (its opening filled with the module's own
   wall brick), except the start's and the finish's.
6. All of it from `(seed, library)`: the same seed grows the same building, on any machine.

The result is a **plan**: `[{module, at: Vector3i, turn}]`, the joins and the caps. Laying it in
bricks is a separate step (in the workshop as a preview, in the city as a building).

### 3.1 As built (stages 2-5, 2026-10-30)

**The library** (`scripts/room_modules.gd`, `RoomModules`): `library()` reads every build in the
building and room libraries with its module on; `make(recipe)` gives `{name, rules, turns[4]}`.
Each build's rooms are found again from its bricks (`refresh`: the record's seeds, its links,
kinds and marks kept), so an old save still has the right connectors. A turn holds the turned
recipe (`BuildRecipe.turned`), its structure cells, its columns as 2.5D spans (bricks and room
air), connectors and facade spots turned with it (facing + turns), windows, rooms (kind, seed,
columns). A build in more than one grid is not a module yet (no sideways turn).

*A module built on the workshop's baseplate* has no floor in its recipe -- the baseplate is its
floor. `with_floor` gives it one on row 0 under every column it has bricks in or closes round
(plates 4x4, 2x2, 1x1), so it is a whole room on the ground or up a stair.

**The grow** (`scripts/room_grow.gd`, `RoomGrow.grow(lib, {seed, rooms, path, tries, balcony,
hang})`): a start module (role `start` or a `start` link; any module when there is none) at the
origin, turned at random; the path grown from it by backtracking, `path` modules then a finish
module (role or link; with none, the path ends at its last room), shorter if the tries run out;
the `min`s; branches until `rooms`, a connector nothing fits marked dead; loops; caps. A fit is:
no column span of it in one already placed, the `max` not passed, the storey rule (`ground`: its
lowest row the start's; `upper`: above it; `top`: nothing over it ever). Stair links join up to
down, the upper module's lowest brick in that column on the lower one's highest. A hang spot is
an open connector any doorway as high as the room fits; a branch takes one with the chance
`hang`, and puts a `hang`-role module there (a room-role one when the library has none). About 4 ms a 12-module building.

**The facade** (stage 5): one window style a building (`open` or `glass`: every window hole of
every module glazed); a window spot cuts a 2 x 6 window through the wall there (glazed in the
glass style); a balcony spot, with the chance `balcony` and where nothing is, a 4 x 3 slab at the
room's floor with a rail a brick high and a doorway out to it; a hang spot, used, a doorway cut
for the room hung there. A stair join lays a straight stair two studs wide in the lower room
ending at the link, a stud of tread and two plates of rise a step (the workshop's own stair rise,
`StaircaseRecipe.STEP_PLATES`; a brick a step where the room has no floor for the longer flight),
and cuts the slab cells over the steps that would have less than 15 plates of headroom.

**Laying** (`RoomGrow.lay(lib, plan, on_ground)`): every placement's bricks -- furniture and
detail too, fixtures, placed furniture -- turned and moved; a plain brick or plate partly in a
cut laid again as 1x1s of what is left (a slope or custom piece left out whole), furniture with a
cell in a cut left out; then caps, steps, balconies and glass where nothing is. A cap is the
wall's own brick -- the colour and material beside the doorway (`wall` on the connector) -- in
courses of 1x6/1x4/1x2 along it in a running bond, plates under the lintel. A room's seed a step
or a cap now stands on moves to a free cell of that room. Its
rooms go in `meta["structure"]` (each module's, moved), so the spaces tool, interiors and AI see
them; `meta["generated"]` says the seed, the modules and the counts. `on_ground` moves it to the
plate's corner and leaves the ground row (the ground floors) to the ground, as a workshop build
stands.

**In the workshop** (stage 4): under the module's rules on the rooms panel, *Grow a building from
saved modules*: seed, modules, path length, **Generate** and **Next seed**. It opens the building
as a new build (a build with unsaved changes asks first: press again within 4 s); a building
wider than the baseplate makes the plate bigger. **Enter** places it in the city as any build
(the city takes builds whole: `BuildingRegistry.register_build`).

### 3.2 Doors (built 2026-10-31)

A door is the one thing in a building that moves, so it is not a brick in the grid (a staircase
fixture is): `scripts/build_doors.gd`, `BuildDoors`, a node in the city and in the workshop that
hangs a leaf in each door hole of every build that is bricks, follows its chunk, swings it open
(a quarter turn) when a figure -- any CharacterBody3D -- comes within 1.6 m of the doorway and
shuts it when they have gone. A shut leaf stops what a body stops. While the brick over the
middle of the doorway is gone (shot away, or a storey not laid yet) the door is not there.

Where the doors are is the recipe's: `meta["doors"]` = `[{"lo", "size", "colour", "material"}]`,
the hole's box in the build's cells (`BuildDoors.hole` from a connector), and any opening set to
kind *door* by hand in the spaces tool (its cells' box). The leaf runs along the longer flat side
of the box, hinged at its low end, a plate short of the hole, brown unless said. The grow puts
one in the first wall of every joined doorway, a hung room's and the way in and out (with the
chance `doors`, 1); the shell in every doorway it has. `tools/build_doors_probe.gd` (10, doors
and lifts).

## 4. Set by shell (stage 6, built 2026-10-31)

`scripts/room_shell.gd`, `RoomShell.generate(lib, {seed, width, depth, footprint, storeys, pitch,
setback, setback_every, setback_sides, corridor, room_max, window_every, fill, lift, balcony})` ->
`{ok, why, recipe, plan, stats}`. The outside first: a **footprint** -- the box `width` x `depth`, or any shape,
`footprint` the columns it stands on (in the workshop: the outline the open build closes round,
drawn with Sketch or Walls, `RoomShell.footprint_of` / `RoomModules.footprint`) -- `storeys`
high, `pitch` plates a storey (0: the height most room-role modules have, `pitch_of`; 14 for a
floor plate, twelve plates of room and a ceiling), stepped in by `setback` studs every
`setback_every` storeys on the sides `setback_sides` names (of "nsew", north +Z, east +X; all
four unless said). A storey's outer wall is its footprint's edge (corners too); the
rest is inside.

* **The stair hall** where the top storey has room for it and six studs of corridor east of it,
  its band as near the middle as it fits, then as far west: the corridor's width and a stud each
  side, the same place every storey. One straight flight a storey, two studs wide, two plates a
  step, in two lanes so each flight starts beside the cut over the one below; the top flight comes
  up through the roof (the finish).
* **The lift** (`lift`, where it fits): a 4 x 4 shaft past the hall's north wall (else its south),
  a doorway to the hall each storey, no slab in it between the ground and the top storey, a stop
  a storey. `scripts/build_lifts.gd`, `BuildLifts`, a node as doors are: a platform a plate thick
  in the shaft; stood on 0.8 s it rides a storey up (down from the top) at 2 m/s; stood by on
  another storey (within 3 studs of the shaft) with nobody on it, it comes there.
  `meta["lifts"]` = `[{"lo", "size", "stops"}]`.
* **The corridor** `corridor` studs wide (at least 4: the two lanes) east from the hall as far as
  the storey has its whole band, a wall across its end.
* **Each side** filled west to east: a room- or corridor-role module, turned so a door faces the
  corridor, its door's outer face on the corridor's first row and its own wall standing in the
  corridor wall's line, inside the storey's footprint, clear of the hall and the lift, no higher
  than the pitch, its storey rule and `max` kept, picked by weight -- with the chance `fill`, else
  a stud on. Its other doors are walled up (the grow's caps). A stair-role module too, below the
  top storey, when it has a stair link up.
* **Stairs between modules** (built 2026-10-31): before the rest of a storey is filled, over each
  module of the storey below with a stair link up, a module with a stair link down in the same
  column whose door opens onto the same side's corridor, where one fits (any of the room,
  corridor and stair roles, weighted). Joined as the grow joins them (`RoomGrow._stair`: the steps
  in the room below, the ceiling and the floor over them cut); the shell's slab is not laid in a
  cut. `stats.stairs`, `plan.stacks`.
* **Module facade spots** (built 2026-10-31) where the module's wall is the tower's outer wall
  (outside the storey past it): a window spot cut 2 x 6 (glazed in a glass tower), a balcony spot
  built out (the grow's balcony) with the chance `balcony` above the ground storey, where nothing
  of the ground storey's footprint is under it. `stats.windows`, `stats.balconies`. Hang spots
  are not used in a tower.
* **Filler rooms**: whatever of the storey is left, split by a wall every `room_max` studs either
  way, each given a doorway (two columns) to the corridor, the hall or a filler room already
  reached, round by round, so every room is reached; a piece under 4 columns stays closed.
* **The way in**: a doorway in the ground storey's outer wall with the corridor or the hall
  inside, the furthest east first.
* **The shell's walls** -- the outer wall and the inner ones (hall, lift, corridor, splits) -- in
  straight runs, courses of 1x4/1x2/1x1 in a running bond, never in a module's columns. Floors in
  the biggest square plates over the storey's footprint and the one under it (a terrace is the
  storey below's roof), not in a module's columns, over a flight or in the lift shaft. Windows
  2 x 6 every `window_every` studs along each straight face of the outer wall, not at its ends,
  one style a tower (open or glazed, the modules' windows too). A rail a brick high round the roof
  and round each terrace. A door in every doorway (3.2).

Laid by `RoomGrow.lay` (the plan says where it stands, `at`); the record gets the modules' rooms
and the shell's own (a corridor with its hall a storey, the filler rooms); `meta["generated"]`
says `generator: "shell"`. In the workshop: under the grow on the rooms panel, *Set a tower by its
shell*: seed, width, depth, storeys, setback, every, *sides in* N S E W, *this build's outline
as the footprint*, **Generate tower**, **Next seed** (the plate and the volume over it grow to hold
a tall one). `tools/room_shell_probe.gd` (15: adds a north-only setback, stacked stair modules
open room to room, facade windows and balconies).

Not yet: hang spots in a tower; a cap and a facade window on the same wall cells (a module made
so) leaves the cap.

## 5. Markers in the workshop (stage 1, built)

Rail, the rooms tool (O): **click marks** picks what a click does -- *rooms* (as before: find a
room, select it, turn an opening's kind), *link* (an opening's link round: auto, off, start,
finish), *points*, *stair link up* (click under a ceiling), *stair link down* (click a floor),
*facade: window / balcony / hang* (click a wall from inside; again on it takes it away). Under it
the module's rules: **Module** on, its role, where (storeys), at least, at most, weight.

Drawn: each connector an arrow out of its doorway from the outer face, white (auto), green with
START, red with FINISH; stair links an orange arrow up or down; facade spots a violet box with a
tick out. The status line counts connectors and marks and says MODULE when it is on.

Code: `StructureSpaces.connectors` / `door_connector` / `cycle_link` (record side),
`WorkshopSpaces.mark`, `link_click`, `toggle_mark`, `module`, `set_rule` (the tool), the rail in
`WorkshopTools` (the rooms box). `tools/module_marks_probe.gd`.

## 6. Stages

| # | what | status |
|---|---|---|
| 1 | markers: connectors from openings (link by hand), stair links, facade spots, module rules on the rail; saved; `module_marks_probe` | built 2026-10-30 |
| 2 | the library: modules read, cells, connectors, turned four ways (3.1) | built 2026-10-30 |
| 3 | grow: path start to finish, branches, loops, caps, no overlap; seeded; `room_grow_probe` (12) | built 2026-10-30 |
| 4 | lay a plan in bricks: Generate on the workshop rail; Enter puts it in the city; `module_marks_probe` (11) | built 2026-10-30 |
| 5 | facade spots filled (window styles, balconies, hanging rooms), stairs laid | built 2026-10-30 |
| 6 | set by shell: a box tower, stair hall, corridor, modules on it, filler rooms, windows; Generate tower; `room_shell_probe` (9) | built 2026-10-31 |
| -- | the grow's "not yet": hang role, two-plate steps, stair and doorway cuts by the cell, caps in the wall's brick in a bond | built 2026-10-31 |
| 7 | doors in doorways (BuildDoors); towers in a drawn outline, setbacks, a lift (BuildLifts); `build_doors_probe` (10) | built 2026-10-31 |
| -- | the shell's "not yet": stair modules stacked, module facade spots, setbacks by side; `room_shell_probe` (15) | built 2026-10-31 |
| 8-12 | stations and ship interiors (section 7) | planned |

## 7. Plan: stations in space and ship interiors (2026-10-31)

The user: the generated structures should also make **space stations**, fully generated in
space -- abstract, ISS-like, many rooms and passageways joined up; later the same system fills
**ships** with rooms, using as much of a confined hull as it can, the rooms part of a flyable ship
(planet.tscn's `SpaceShip`). Ships are in parts and break brick by brick a section at a time;
stations follow that.

What exists to build on: the grow (3) and the shell (4) over one library of hand-built modules;
doors and lifts as nodes following a chunk (3.2, 4); `SpaceStation` / `SpaceShip`
(Docs/Planets.md 11.12 steps 2, 3, 3b): one chunk from a template, hits (`DamageLog`), what comes
loose solved (`solve_structure`), big loose groups drifting (`drifted`), down toward a virtual
centre under the deck; Docs/Space.md 3.2: a big ship or station is **sections**, each about a
city building (5-15k bricks), joined by **joints** with hit points, the section that holds the
bridge or core the **root**; a section cut off from the root leaves whole.

### 7.1 Sections: one generated build in parts (stage 8)

Both generators learn to cut what they make into sections, because stations and ships both need
it and it can be probed in the workshop before anything flies.

* A **section** is a set of whole placements (a module is never split) plus the shell bricks
  between them; `plan.sections` = `[{id, placements, root}]`, `plan.joints` = `[{a, b, cells,
  kind}]` -- the bricks where two sections meet (a tube's collar, a bulkhead), each joint's own
  hit points to come.
* Cut where the plan is thinnest: the grow cuts at joins whose two sides are each over a brick
  budget (`section_bricks`, default 8000) -- a corridor or tube between clusters; the shell
  (ships) cuts at bulkheads, below.
* `RoomGrow.lay_sections(lib, plan)` -> one `BuildRecipe` per section, each with its own rooms,
  doors and lifts, and the transform that puts it back with the others; `lay` stays the one-build
  form. A door or lift never crosses a joint (it goes in one section's bricks).
* Workshop: the preview tints each section; the status line counts sections, joints, bricks a
  section. Probe: no placement in two sections; each section's bricks under the budget; the
  sections laid together are the same bricks as `lay`.

### 7.2 The station grower (stage 9)

A third generator, `RoomStation` (`scripts/room_station.gd`), the grow's rules in all three
directions, with station roles in the module rules:

| role | what (built by hand in the workshop as now, a kit to start) |
|---|---|
| `node` | a hub: a short box or round room with **ports** on up to six faces |
| `pod` | a pressurised module: a long room (lab, quarters, galley, storage), ports at its ends, windows |
| `tube` | a passageway: 4 x 4 inside, 4-20 studs, a port each end -- the station's corridors |
| `core` | the root: control, power; one a station (`min` 1, `max` 1); its section is the root |
| `truss` | open lattice (no room), carries `panel` and `radiator` spots; not pressurised |
| `dock` | a port to the outside with a docking ring: where the ship holds (step 3b's docking) |

* **Ports** are the grow's door connectors (a doorway, its size, a facing) plus **up and down**:
  a vertical port is a pair of stair links with a ladder or a lift (BuildLifts) -- one "down"
  for the whole station as now (the deck's gravity), so pods lie flat and the station spreads
  mostly in a plane, the ISS's shape, with a few levels.
* **Grown from the core**: the path is replaced by a **spine** (core -> nodes -> a dock at each
  end), then branches (pods off nodes, tubes to new nodes) and loops (two nodes whose ports face
  across a gap a tube fits get the tube: the "many interconnected passageways"). The grow's
  checks hold: no module in another, every room reached, same seed same station.
* **The abstract look** comes from the kit and the dressing, not the grower: pods in white and
  light grey with a colour band a station, round modules where the part library has the rounds;
  trusses as long open frames sticking out of nodes with `panel` spots filled by **solar wings**
  (flat plate arrays, 2-4 per truss) and `radiator` spots by fins; windows on pods by the grow's
  facade spots, a cupola by a `window` spot on a node's down face.
* Sections (7.1): a node with its pods is a section; a tube between two is a joint. The core's
  section is the root.
* Workshop: *Grow a station* on the rooms panel (seed, modules, loops, solar wings); in the city
  it is just another generated build until stage 10.

### 7.3 Stations in space (stage 10, with the planets area)

`SpaceStation` lays a generated station instead of a tower's recipe: **one chunk a section**
(each from its own template, so laying stays ~1-3 ms), placed by the section transforms; the
shell boxes and the far look (`look`) made from the section boxes. Hits as now, per section. A
joint's bricks are tracked: when a hit leaves a section joined to the root through no joint, the
section **leaves whole** -- the `drifted` path, as one rigid piece with its bricks, rooms, doors
and anyone inside riding its frame; under the budget it can break again brick by brick (Space.md
3.2-3.3). Generated systems get generated stations (seeded from the orbital's seed); home's
station stays the story's until the user says.

This is in `scripts/space/` (the planets area): its work, or small changes merged soon, agreed
first.

### 7.4 Ship interiors: as much of the hull as rooms (stage 11)

The shell's idea turned inside out: the **hull is the outside**, given, and rooms are packed into
it. `RoomShell` gets a `hull` mode (or a sibling, `RoomPack`):

* **The hull's inside**: a ship build's bricks (a hull made in the workshop or by the converter)
  -> per deck, the columns inside the hull at that deck's height (the hull's cross-section, as
  `RoomModules.footprint` finds an outline); decks `pitch` apart where the hull is tall enough.
  So every deck has its own footprint, as setbacks give storeys theirs.
* **A spine, not a hall**: one corridor fore to aft down each deck's middle (it bends with the
  hull), a ladder well and a lift where the decks overlap most, a hatch to the bridge.
* **Zones** in the module rules: `zone` = fore / mid / aft / core / hull / any, `min`: a bridge
  fore (its `seat` spot is the pilot's seat), an engine room aft (its `engine` spots where the
  engines mount), a reactor at the core, then quarters, galley, med bay, cargo, airlock by weight.
  Required ones first, biggest first.
* **Using the space** -- the goal, and a number to probe: `stats.fill` = room air cells / the
  hull's inside cells, aimed at 85% or more. Modules are tried at every stud along the spine (not
  only west to east once), each seed tries its fits largest first and keeps the best of a few
  passes; what is left goes to filler rooms as now, then to **storage nooks and crawlways**
  (pieces under 4 columns become lockers or ducts, not dead space). Walls one stud, shared.
* **Bulkheads are the sections**: across the hull every `section_studs` (about a building's
  length, 24-40 studs), a wall with a pressure door at the spine; no module straddles one. Each
  section a chunk, the bulkheads its joints; the bridge's section the root.

### 7.5 The ship flies its rooms (stage 12, with the planets area)

`SpaceShip` builds from a generated hull and interior instead of its 24 x 36 tower module: the
bridge's `seat` spot is `seat()`, the engines on the engine room's spots, its hull box from the
sections' boxes; sections as stations' (7.3): a section shot off its joints leaves whole and can
then be broken brick by brick, the rest still flies. planet.tscn's parked ship the first one.

### 7.6 Order and choices

Stage 8 (sections) first: everything after leans on it and it is all in this area. Then 9 (the
station grower, workshop only), then 11 (ship interiors, workshop only), and 10 and 12 with the
planets area's chat. Each stage merged with its probe, as stages 1-7.

Defaults taken unless the user says otherwise: a station keeps one "down" (its deck's gravity),
not zero-g inside; pods are box-shaped with round parts where the part library has them;
`section_bricks` 8000.
