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
| 8 | sections: generated builds cut into parts with joints, split into builds of their own, shown in the workshop; `build_sections_probe` (7) | built 2026-10-31 |
| 9 | the station grower: core, spine, docks, bridging tubes, solar wings, radiators; Generate station; `room_station_probe` (8) | built 2026-10-31 |
| 11 | ship interiors packed into a hull: decks, spine, well, bulkheads as sections, zones, shared walls, nooks; Generate interior; `room_pack_probe` (9) | built 2026-10-31 |
| 10 | stations in space: a kit and ties so a station holds by its studs, a keel its anchor; generated stations for every station but home's, a section shot off drifting whole; `station_sections_probe` (5), `room_station_probe` (10) | built 2026-10-31 |
| 12 | ships: ShipBuild (hull, ship rooms, airlock), flown as a SpaceShip -- the bridge's seat, decks anchored, bulkheads joints with hit points; the parked ship generated in play; `ship_build_probe` (4) | built 2026-10-31 |

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

### 7.1 Sections: one generated build in parts (stage 8, built 2026-10-31)

Both generators cut what they make into sections, because stations and ships both need it and it
can be seen in the workshop before anything flies. `scripts/build_sections.gd`, `BuildSections`:

* **Units** a section is made of: a grown building's placements (a module is never split), a
  tower's storeys. Every brick goes with the unit its cell is in -- a module's columns, its rows
  -- or the nearest one within 6 cells (a cap, a step, a balcony); a tower's by its row.
* **Cut**: from the root unit (the grow's start, the tower's ground storey) outward along the
  plan's joins (storey to storey), each section filled to an even share of the bricks -- as few
  sections as `section_bricks` (both generators' parameter, default 8000) allows -- then the
  smallest section joined to the smallest one it touches while the two stay under it. A unit
  over the budget alone is a section of its own. Section 0 is the root.
* **Joints**: where two sections' bricks touch, the cells on both sides (`of_plan`); the build
  keeps how many.
* `RoomGrow.lay` writes `meta["sections"]` = `{budget, kind ("join" | "storey"), size, sections:
  [{id, root, bricks, lo, hi}], joints: [{a, b, cells}], of: [[section, run]...]}` -- each brick's
  section, run-length, read back by `BuildSections.of_build`; a build whose bricks changed since
  (`size`) has none (stale).
* `BuildSections.split(r)` / `RoomGrow.lay_sections(lib, plan)` -> `[{id, root, recipe, offset}]`:
  each section a build of its own, moved to start at 0, `offset` puts it back; its rooms, doors,
  fixtures and furniture with it (the section of their cell, or nearest: its own row first); a
  lift split into one a section, with that section's stops (two at least).
* Workshop: the rooms panel's *section (most bricks)* sets the budget for both generators; a
  generated build with two sections or more shows a box round each and *section N (ROOT) bricks*
  over it; the message counts sections, their bricks and joints.
* Costs: a 4-storey tower's generate 120 -> ~175 ms (the joints walk every cell); a 14-module
  grown building ~75 ms with the lay.

`tools/build_sections_probe.gd` (7): several sections under a small budget, the start's the root;
no module in two sections; every section touching another; split and moved back the same bricks,
every room and door in one; a tower in bands of whole storeys, a lift in each; the meta read back
and stale once edited; the default budget (a 12-storey tower: six sections of ~7k).
`module_marks_probe` (14): the sections shown.

Not yet: joints have no hit points (stage 10); the city and the workshop still lay a build whole.

### 7.2 The station grower (stage 9, built 2026-10-31)

`scripts/room_station.gd`, `RoomStation.generate(lib, {seed, modules, spine, docks, bridges, wings,
section_bricks})` -> `{ok, why, recipe, plan, stats}`: the grow (3) with a station's roles --
`RoomStation` extends `RoomGrow`, which now names its roles in variables (`path_roles`,
`branch_roles`, `start_role`, `finish_role`) and has two hooks, `_more` (after the branches) and
`_dress` (a facade spot of a kind it does not know).

| role | what (built by hand in the workshop; `tools/station_module_kit.gd` for the probes) |
|---|---|
| `core` | the root: the station grows from it (no core in the library: says so); its section is the root |
| `node` | a hub: a short room with ports on several faces |
| `tube` | a passageway: a port each end -- the spine's and the branches' corridors |
| `pod` | a pressurised room off a node: lab, quarters, galley; windows, radiator spots |
| `truss` | a frame out from a node with `panel` spots (a room in the kit; any build with a port) |
| `dock` | a port to the outside, linked *finish*: the docking ring |

* **Ports** are the grow's door connectors; up and down are stair links (one "down" for the
  station: its deck's gravity, so it spreads mostly flat, the ISS's way).
* **Grown**: the core, a **spine** of tubes and nodes `spine` long ending in a dock (the grow's
  path), branches of pods, nodes, tubes and trusses to `modules`, more **docks** on the open ports
  furthest from the core till there are `docks` (their outer ports left open with a door, not
  capped: `keep`), then **bridging tubes** (`bridges` at most): two open ports facing each other
  across a clear gap up to 24 studs along and 8 aside get a tube cut to fit -- wide enough for
  both doorways, a stud of wall, floor and ceiling round it in the first port's wall brick -- and
  are joined through it (a loop: rooms reached two ways). Then the grow's loops, caps, facade.
* **Dressing**: a `panel` spot gets a **solar wing** (a 3-stud boom, then 8 x 16 studs of 2x2
  tiles, dark blue), a `radiator` spot a radiator (4 x 8, white), flat out from the wall where
  nothing is (`wings`, the chance). New facade spot kinds in the rooms tool's click marks:
  *station: a solar wing*, *station: a radiator*; new module roles on the rail: core, node, pod,
  tube, truss, dock.
* Laid with its lowest row at 1 (a station has no ground row); `meta["generated"]` says
  `generator: "station"`; in sections (7.1) by its placements, the core's the root.
* Workshop: *Grow a station* on the rooms panel: seed, modules, spine, docks, bridging tubes,
  **Generate station**, **Next seed**; the message counts docks, loops, tubes, wings, radiators,
  caps and sections.

`tools/room_station_probe.gd` (8): 10 seeds each a station with one core and two docks, no module
in another, all joined to the core (~90 ms a station of 19 modules); bridging tubes in most, each
open through both doorways; docks open with a door; wings and radiators clear of every module;
lowest row 1; sections with the core's the root; same seed same station; no core says so.
`module_marks_probe` (15): Generate station.

Not yet: tubes bridge on one level only (no ramp or ladder between levels); the abstract look is
the modules' own (round pods where the user builds them round); no station colour band.

### 7.3 Stations in space (stage 10, built 2026-10-31)

**Held by its studs.** In space nothing stands on the ground, so a generated station has to
hold together by stud joints alone (`solve_grounded` walks studs only). Built that way:

* **The kit** (`scripts/station_kit.gd`, `StationKit`, the game's own station modules; the
  player's station modules are used instead when they have a core): floors and ceilings two
  plate layers, the upper a stud in so every seam of the lower is bridged; walls brick columns
  on the floor's rim under the ceiling's. Core, node, tube, short tube, pod (a window, a radiator
  spot), truss (a panel spot), dock. `tools/station_module_kit.gd` is now this kit.
* **Ties**: under every seam where two modules meet door to door, a 2x2 plate under both walls
  (plates stacked under the higher one down to it); a bridging tube is two plate layers for its
  floor and its ceiling (staggered across when it is only two studs long), brick walls, and tied
  under each end where the module has its wall.
* **Wings and radiators** lie flat on the module's roof at the wall and out past it: a boom two
  studs wide in two layers a stud apart, its last plate over the panel's first row, the panel two
  staggered layers.
* **The keel**: a stack of 2x2 plates under the core's middle, two rows below anything else --
  the station's lowest row and its only anchor (its foundation, row 0 when laid).

**In space.** `OrbitalData.layout` "generated" (`StarSystem` gives every station but home's: home's
stays the story's tower): `SpaceStation.prepare` grows it from `orbital_seed` (12-23 modules, a
spine of 3-5; ~0.25 s, so there, ahead of arrival, not at load) and builds its template (~0.35 s);
its box, frame, shell and shell collision become a box round each of its sections
(`SECTION_BRICKS` 2000); `activate` lays it from the template (~3 ms) with its foundation at the
keel. A hit's solve for a generated station is by studs alone (`find_detached_groups`; in orbit
nothing weighs on it, Space.md 3.2): what a hit leaves joined to nothing that reaches the keel
comes away -- small as crumbs, a section cut off at its joints whole, drifting (`drifted`, step 6's
rigid pieces). The home station and ships keep the stress solve.

`tools/room_station_probe.gd` (10): adds laid in a brick world with only the keel on the
foundation row nothing is loose, and a leaf section's joint killed sends that section away whole.
`tools/station_sections_probe.gd` (5): home's station a tower and the rest generated (5 systems);
prepare grows the same station for the seed, a shell box a section; laid frame by frame, nothing
loose; a leaf section's joint shot away -- it drifts off as one piece. `system_probe` 31/31 as
before. The workshop's *Generate station* uses the shipped kit when the player has no core.

Not yet: the people of a drifting section are not carried with it (its furniture is, 7.7); a station's damage is kept as
before (dead ids) but sections are not; no windowed pass has looked at one (`--gate=system`
visits home's, a tower).

### 7.4 Ship interiors: as much of the hull as rooms (stage 11, built 2026-10-31)

The shell's idea turned inside out: the **hull is the outside**, given, and rooms are packed into
it. `scripts/room_pack.gd`, `RoomPack.generate(lib, {seed, hull, pitch, corridor, room_max,
section_studs, passes, fore})` -> `{ok, why, recipe, plan, stats}`; `RoomPack` extends
`RoomShell`, which gained a base row (`_yb`) and hooks for it (`_before_fill`, `_prelay`,
`_plan_at`, `_kind`, `_plan_more`, `_door_x_ok`, `_sealed`, `_shares`, `_outside_ok`, `nooks`).

* **The hull** is a build's bricks (in the workshop: the build open). Turned a quarter first if it
  is longer along Z (`stats.turned`; the made build is in that frame). **Decks** `pitch` apart up
  from its lowest row while one has 60 columns: a deck's footprint is the columns the hull closes
  round (a row's cells not reached from outside its bounds) at every row of the deck, its floor
  and ceiling rows inside or the hull's own. Its bricks are kept whole; nothing is laid outside.
* **Fore** is the narrower end of the lowest deck (`fore`: "+x", "-x" or "auto").
* **The well amidships**: a stair hall where every deck has it, its walls and the spine's band,
  nearest the middle; flights deck to deck (none through the roof). **The spine**: one corridor
  through the well both ways, as far as each deck has its band, a wall across each end.
* **Bulkheads** every `section_studs` (32) from the aft end, moved clear of the well: a wall
  across every deck with a doorway and a door at the spine; no module across one, no filler
  doorway through one. Each stretch between them is a **section** (7.1, kind "bulkhead"), the
  fore one the root.
* **Zones**: a module's `zone` rule (the rooms panel's *zone*: any, fore, mid, aft, core, hull) --
  fore/mid/aft the thirds of the length, core the middle third not touching the hull, hull
  touching it. Modules with a `min` go first, biggest first, wherever their zone has room
  (`stats.short` counts those that found none); then each side of each deck is packed fore and aft
  along the spine, at every stud **the biggest module that fits** (after the first pass a quarter
  of the time one by weight).
* **Walls shared**: two modules side by side share a wall (a column solid from the floor to the
  top in both); a module's solid wall may stand in the hull's (the module's bricks there cut, the
  hull's kept; `stats.in_hull`).
* **The rest**: filler rooms off the spine as the shell's (split every `room_max`, 10); what is too
  small for a doorway or never reached is a closed **storage nook** (`kind` storage).
* **Using the space**: `stats.fill` = columns in a room (modules', the spine and well, filler,
  nooks) over the decks' footprint columns; `passes` (4) runs, the best kept.
* Workshop: *Fill this build as a ship's hull* on the rooms panel: seed, passes, bulkhead every,
  **Generate interior** (the build open is the hull; after one, **Next seed** fills the same
  hull again), and a *zone* choice in the module rules.

Measured (`tools/room_pack_probe.gd`, 9): a 96 x 28 hull 43 plates high narrowing fore -- three
decks, nothing outside it, the hull whole; bridge fore, engine room aft, reactor at the core; fill
**75.7%** with the probe's box modules; every room but the nooks reached from the well; two
bulkheads with doors on every deck, three sections, the bridge's the root; more passes never
worse, same seed same ship; a hull along Z turned; no hull says so. ~0.7 s a pass.
`module_marks_probe` (16): Generate interior, then the same hull again.

**Why not 85% yet**: every room has its own walls a stud thick; in a 25-stud deck with a 4-stud
spine, rooms 8 deep lose a quarter of each side to walls. The fill rises with modules sized to the
deck (as deep as the band, the hull for their back wall: the probe's cabin) and with walls shared.
Not yet: a lift (`lift` off), portholes in the hull, an airlock to the outside, decks of their own
pitch.

### 7.5 The ship flies its rooms (stage 12, built 2026-10-31)

`scripts/ship_build.gd`, `ShipBuild.make(seed)` -> RoomPack's result with `seat` and `decks`:

* **The hull** from the seed: 56-96 studs long along +X, 26-30 across, 1-3 decks `PITCH` (15)
  apart, its half-beam falling over the fore quarter to a third at the bow; a floor of plates on
  row 1, brick side walls, a roof of two plate layers (each seam bridged).
* **The rooms** (`ShipBuild.modules`, or the player's when one of theirs is a bridge): bridge
  (fore, one), engine room (aft, one), reactor (core, one), quarters, galley, med bay, cargo
  (hull), cabin -- a floor of plates, brick walls, two ceiling layers, a door each long side.
  Packed by RoomPack (7.4) with `airlock`: a doorway and a door through the stern where the spine
  meets it on the lowest deck. Bulkheads every 24-32 studs; the **root section is the bridge's**
  (`plan.root_x`, RoomPack names its required fore module's).
* `seat`: the middle of the bridge's room, on its floor.
* **Engines and a fin** on the roof aft (`ShipBuild._engines`): two housings 4 studs across, three
  courses of 2x2 bricks in a running bond (1x1s where a course falls short), a quarter of its
  length, hanging 2 studs out past the stern; a fin of 1x1 columns on the middle line stepping
  down forward. `meta.engines` is each housing's back: SpaceShip puts its glow there (the old
  engine meshes only on the plain ship).
* **Swept wings** (`ShipBuild._wings`) over its middle and aft: two plate layers a stud apart on
  the roof's sides, their roots 4 studs in over the roof, out a quarter of its beam at the trailing
  edge and a third of that at the leading; on the 2-stud grid, so the lower layer is all 2x2s and
  no 1x1 sits on a 1x1 (a pair of them holds nothing -- six loose groups before).

**Flown.** `OrbitalData.layout` "generated" on a ship: `SpaceShip.setup_ship` grows it at once
(~0.5 s, and its template ~0.6 s: its seat and hull box are wanted before anything else); its
frame turns the build so its bow is the ship's nose (-Z) and centres it; `seat()` is the bridge's;
its hull box and engines from its size. Laid with its floor (row 0) the foundation and every deck's
floor row an anchor (`set_anchor_levels`), so nothing hangs loose. **Bulkheads are joints with hit
points** (Space.md 3.2): the bricks where two sections touch; after a hit's solve, a joint with
under `JOINT_HOLD` (35%) of them left is broken, and whatever no unbroken joint joins to the
bridge's section leaves whole -- split off and drifting (`drifted`), its bricks then as any
piece's. The rest still flies. The parked ship in planet.tscn is a generated one (seed 7) in
play; the gates keep the plain one they were written round.

Also: `RoomGrow.lay` lays what is left of a box brick that overlaps one already laid (a wall two
modules share) column by column, as it did for a cut -- the floors and ceilings of modules with a
shared wall had holes, and in a ship those plates hung loose.

`tools/ship_build_probe.gd` (4): 8 seeds -- 1-3 decks, the bridge's seat on its floor in the fore
third, the engine room aft, an airlock open onto the spine, fill 76-78%, sections; a generated
SpaceShip -- its seat forward of the middle, its hull box long along Z; laid frame by frame with
nothing loose; a bulkhead of the bridge's section shot through -- the part beyond (324 bricks)
drifts off whole, the bridge stays.

**A gangway.** Parked in its bricks on a planet with nobody at its controls, a generated ship
lowers a stair of bricks from its airlock to the ground (`SpaceShip.gangway_step`, from
`PlanetSystem._ship_bricks`): steps a brick up (the pawn's step), two studs deep, four across, the
top one level with the deck outside the doorway (no step up under its lintel), down until one is
within a brick of the ground under it (the planet's heights, as it lands by); a collision box a
step, a child of the ship. Taken up when it is flown.

**The pawn's height.** The pawn is 12 plates tall (9 crouched). Rooms of 12 plates and doorways of
9 (RoomShell's `DOORWAY`, the kits' first sizes) were too low to walk through, crouched or not.
Ship rooms (`ShipBuild.H`) and station kit rooms (`StationKit.H`) are now 16 plates inside, their
doors 14 (a tower's are 15). RoomShell and RoomPack take `doorway` (plates, default 14), cut
as tall as the storey lets (`pitch - 3`; 9 the least a storey takes); RoomShell's storey when no
module says is 19 plates (was 14). A tower grown from modules 14 plates high still gets
11-plate doorways and 12-plate rooms -- the modules' own height: build them 17+ for the pawn.
`room_shell_probe` (16) checks the doorways: 11 in 14-plate storeys, 14 in 19-plate ones.

**Boarded.** A generated ship's sill can stand metres over the ground (it is long and parks
level over a slope: 4.4 m at seed 7's stern), and E boards only within 8 m of the seat, deep in
the bridge -- so on foot at its airlock, **E steps through it** (`PlanetScene._through_airlock`):
in onto the deck, or out onto the ground. `SpaceStation.airlock_cell`, `cell_point`, `cell_at`.

**Flown in its bricks.** Over a planet a flown ship moves in the planet's frame, and its brick
collision is placed in the world, so the plain ship puts its bricks away while flown. A generated
one **rides** instead (`SpaceStation.ride` / `unride`, from `PlanetSystem._ship_bricks`): its band
meshes, its own children, stay drawn and move with it; its brick collision is put away and its
shell box stands in; nothing on it is damaged meanwhile. Stopped (out of its seat, or the frame in
open space) its bricks' transform is set where it is and their collision is built again.

`planet.tscn -- --gate=hull` (windowed, 10 checks, 2026-11-02): the parked ship generated, laid with
the player by it, nothing loose; its gangway down (11 steps, the sill 4.7 m up); walked up it and
in through the airlock onto its deck and 16 studs on along the spine; its gangway taken up when flown; into the bridge's seat, flown 270 m up in its bricks (riding); out of the seat on the bridge's floor, laid again
round its pilot with nothing loose. Shots `hull_gate_*`.

**Doors and lifts** (2026-11-02): a generated station or ship hangs its recipe's doors and lifts
(`meta.doors`, `meta.lifts`) once its bricks are solid -- a BuildDoors and a BuildLifts of its own,
their source its one chunk (`SpaceStation.doors`, `lifts`), dropped when its bricks are put away.
A flown (riding) ship keeps its chunk's transform on itself each frame so they go with it.
RoomPack's airlock cut a hull wall brick over the doorway's top row whole, leaving a one-plate gap
under the next: no lintel, no door; what a cut brick leaves outside the hole is now kept as 1x1
plates. `ship_build_probe` checks every door has its lintel on 8 seeds; `station_sections_probe`
(6) that a station hangs all its doors (21 of 21); `--gate=hull` (11) all of the ship's (41) and
walks in through the airlock's.

Not yet: a section that drifts off
takes no one with it (its furniture goes, 7.7); the hull is a box with a bow and
its engines and wings on the roof (no windows).

### 7.6 Order and choices

Stage 8 (sections) first: everything after leans on it and it is all in this area. Then 9 (the
station grower, workshop only), then 11 (ship interiors, workshop only), and 10 and 12 with the
planets area's chat. Each stage merged with its probe, as stages 1-7.

Defaults taken unless the user says otherwise: a station keeps one "down" (its deck's gravity),
not zero-g inside; pods are box-shaped with round parts where the part library has them;
`section_bricks` 8000.

### 7.7 Furnished rooms (built 2026-11-02)

A generated station's and ship's rooms are furnished (`KitFurnish.furnish(recipe, seed)`; ShipBuild.make,
SpaceStation's prepare for a station): each the city's way -- `RoomManifest.items_for` on a `Room`
made from the space (its columns' box, the cells outside them posts), so two to five built-in
items of its kind, or an authored room template of that kind, and authored items tagged for it.
A ship room's name gives its kind (bridge office, engine room / reactor / med bay lab, quarters and
cabins bedroom, galley kitchen, cargo storeroom); a plain room (`office`: RoomPack's fillers, a
station's pods) is one of office, bedroom, lab, storeroom, kitchen, living by its seed. A station
module's space kind is now its role's (core living, pod office, dock hall, the rest corridor);
corridors, halls and closed nooks (`storage`) are left empty.

Kept clear: a lane a stud either side from each door to the room's middle, and two studs round the
middle (a hub's way through, the bridge's seat). An item is laid all or none, every cell free and in
the room, a floor brick under it. The items are **plain bricks** at the end of the build
(`meta.furniture` {from, items}), not the interior role: a station's and a ship's meshes are their
face bake, which leaves interior bricks out (the city draws those apart, FurnitureMesh). So they are
drawn with studs, hold by them, collide, and go with their section -- a section that drifts off
takes its furniture; each new brick is in the section of the floor under it (`meta.sections`).

`ship_build_probe` (4): on 8 seeds 44-107 items, none in a doorway or the cells beside one (with the
lanes off it finds 9-17 such cells a seed), nothing loose, every brick in a section.
`station_sections_probe` (6) as before, the station regrown with its furniture. `--gate=hull` (12):
241 furniture bricks; shot `hull_gate_room` from the middle of its most furnished room (cargo:
crates). A station of 16 spaces got 8 items (its core and two pods).

Not yet: items stand square (the manifest's `yaw` is not used, as in the city); a bridge 6 x 6 is
mostly lane and middle, so it gets little; the player's own modules are furnished as well when
their spaces have a city kind, beside what they hold.
