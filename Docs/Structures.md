# Structures: any shape, described once, broken by the bricks

Written 2026-10-16 from the user's questions after the big city got its wide buildings
(CollapseNext item 25):

> "wide buildings will likely be much more than tall buildings so we should support them more.
> ideally the system is as automatic as possible other than in the build mode we just need to
> describe what the structure, interior and items are ... ideally I'd like to support any type of
> structure: castle walls that are huge with connecting long rooms in the walls and towers at
> corners, wide buildings with towers, and still tall buildings with many rooms and rooms hanging
> off the side."

This is the plan, and the record of what is built of it. Status per section.

## 1. What is tied to towers today

What breaks a building does not know about floors: the stress solve on stud joints, the load
check (`BrickWorld.gravity_check`, every plate boundary), the weakest-seam snap, and the search for
what came off (`get_components_near`) all go by the bricks. What does know about floors, and what a
wide building, a castle or a hall shows up:

1. ~~**Bands are slices across the whole building**~~ (tiles since 2026-10-17, 2.2) (`Chunk::section_of_y`). Mesh, collision, the near
   tier and every rebuild after a hit are a band at a time. A band of a 240 x 80-stud floor plan is
   all of it at that height: one hit, the whole floor rebuilt.
2. ~~**The load check takes a whole boundary at once.**~~ One bay of a wide building with its columns
   shot away hardly moves the sum over the boundary, so it never fails. (By region as well since
   2026-10-17, 2.3; a bay shot across falls by the span rule.)
3. **Interiors and a landing's floor-line snap use the recipe's storey height**
   (`TowerRecipe.STOREY_PLATES`). A double-height hall or a mezzanine half a storey up is not a
   storey.
4. **A mega collapse is cut bottom to top** (`CollapseDirector`).
5. **Far off, a building in bricks draws its recipe's coarse shell** with holes punched where bands
   are damaged (`CityScene.DEMESH_RANGE`, 110 m). A hole cannot say "this fell down": from far away
   a collapsed wide building stood as a skeleton of floors and columns while close up it was rubble
   (user's pictures, 2026-10-16).

## 2. The plan, in order

### 2.1 Far view from the real bricks — built 2026-10-16
A damaged recipe building in bricks, past `DEMESH_RANGE`, is drawn by a coarse mesh of its own grid
(`CityScene._far_real`; a worker past `IslandManager.COARSE_ASYNC_BLOCKS`), the shell drawing until
it is ready; asked again whenever the shell is (`_shell_stale`, after a hit). No windows on it: its
holes are where its bricks are gone. The shell node stays, with its collision. `--far` 19 of 19
unchanged (its damaged-build checks read the shell node, which is still there).

(First read of the test pass's picture -- a 200 x 80 building, its ground storey shot through
along its length -- was floors standing over the gap. Wrong: they had dropped the storey and lay on
the ground, in sections 14-49 m long, the debris in front hiding where they met it.)

The plan as it was:
A damaged building's far tier is a coarse mesh of its own grid (`BrickWorld.coarse_chunk_async`, as
a far piece's stand-in already is), rebuilt when its bricks change, on a worker. An undamaged one
keeps the shared recipe shell (cheap, `CityScene._recipe_shell_mesh`).

**Where to start (handoff, 2026-10-16).** Past `DEMESH_RANGE` the demesh loop
(`CityScene`, the loop over `_materialised` just above `_demesh`) calls `_demesh(id)`, which drops
the bake and the brick node and calls `_make_shell(id, true)`: the RECIPE's shell with its bands'
damage punched in -- what drew the standing skeleton. `_shell_stale` re-makes it when the bricks
change. The change: in `_demesh` (and where `_shell_stale` is served), a building whose bricks are
damaged (`b.damage_profile` not empty, or fewer live bricks than its template) gets a node drawing
`BrickWorld.coarse_chunk_async(b.chunk)` instead, taken when done the way
`IslandManager._build_coarse` / `_coarse_jobs` / `_finish_coarse` take a far piece's (copy that
pattern; the stand-in is in chunk space, so the node's transform is `b.xform` as the brick node's
is). Keep the shell's collision as it is (`_make_shell_body`); only the drawing changes. Check:
`big_city.tscn -- --far --buildings=150` (its "damaged build ... far shell" check reads the shell and
will want to read the stand-in instead -- say so in the commit), `--view --big`, and a picture of a
collapsed wide building from 150 m against one from 20 m (the user's two pictures).

### 2.2 Tiles, not bands — built 2026-10-17 (the drawing and collision)
**Built.** A building's sections are tiles: `BrickWorld.set_chunk_section_studs` cuts each layer of
sections (`set_chunk_section_plates`, as before: at least 24 plates, at most 16 layers) into squares
`CityScene.SECTION_STUDS` (32) studs across -- the load check's region width. A block is in the
tile its lowest corner is in (`Chunk::section_of`), and tiles are numbered layer by layer from the
bottom, so everything that went by a section number -- the face bake's order, a band's mesh, its
index patch, its collision body (`BuildingCollision`), the near tier's chamfered meshes and studs,
the bands a toppling building hands its piece -- takes tiles without a change of its own. A tower
30 studs wide is one tile a layer, as it was one band; the 80 x 60 tower is 6 a layer (up to 96),
the 240 x 50 wide building 16. `section_probe` 32 (8 on tiles: a 120 x 70 building's tiles are
exactly its mesh, each at most a brick past 32 studs, and a blast at one end of the ground floor
moves its own tile, not that floor's other three).
Not tiles yet: the shell's bands (a recipe drawing, `BuildingShell`), and the interiors' storey groups.

The plan as it was:
Every structure is cut into 3D tiles of about 32 x 32 studs by one storey, each with its own mesh,
collision, near tier, far mesh and dirty flag. A tower is a stack of tiles, a wide building a grid,
a castle tiles along its walls. A hit rebuilds a tile. `Chunk::section_of_y` becomes a tile index;
the band code paths (`build_chunk_mesh_section`, `add_band_shapes`, `BrickNear` bands, the shell
bands) take tiles.

### 2.3 Loads by region, and spans — the span rule built 2026-10-16, regions 2026-10-17
**Built: how far a floor reaches** (`BrickWorld.cut_spans`, `cut_spans_resting`). A stud column of
a block is **held** when it stands on the foundation, or on the block under it held in that same
column and joined to it; a block is held when any column of it is. (By block, not column, "held"
crept half a brick a course out over a gap through a wall's bond -- a corbel 36 studs long over
three storeys; by the block under its middle, a floor panel lying on walls at its edges was not
held. Both tried, `span_probe`.) Every other block's **reach** is its distance on plan, through its
joints, from the nearest held block; past `BrickStrength.span_reach` (20 studs; Options > Gameplay, "Floor Reach") times its material's
toughness (stone 2.5, metal 4) it has nothing near enough under it, and the **rim** of what has
nothing -- its blocks joined to what has -- is cut (joined to nothing): what the rim bounded falls
as one piece.
* **A standing building**: owed after a solve that finds nothing falling, paid one building a tick,
  each at most every `SPAN_EVERY_MS`, and never while it is still coming apart (`_mid_collapse`:
  the stress solve, the storeys' tip and crush and the director first -- asked first, it cut the
  floors over a storey shot down to one corner, which tips off it whole) (`CityScene._pay_span_owed`);
  a cut is a SEVER command with
  `DamageLog.FLAG_SPAN` (every machine finds the same rim from the same bricks). 2.9 ms for the
  23,000-brick tower, 0.6 ms for a 2,500-brick wide building; nothing whole is ever near it (no point
  of a floor is more than a panel from a wall or a column, TowerRecipe.plan).
* **A piece come to rest lying level** (`CityScene._span_piece`, from `_wreck_settled`, after its
  weight is put on what it lies on): held where it rests -- a brick with a building's solid cell or
  the ground just under it. Not past `FRACTURE_RANGE` of everybody, where a collapse is a few big
  pieces by rule (cut there, a far one came down in three, `collapse_probe`). Cut on the host;
  what leaves is a DETACH like any piece's. Resting on another piece does not hold it yet, and on
  terrain the ground does not (no seeds there: nothing is cut).
`tools/span_probe.gd`, 6. Still to do: the reach tuned by feel (the slider is in).

**Built 2026-10-17: the load check by region.** `BrickWorld.gravity_check` weighs, besides the
whole boundary, each **region** of it: the footprint cut into columns `GRAVITY_REGION` (32) studs
square, a tile's width (2.2), each region's mass above against its own stud contact, crushed past
the same limit (`region_ratio`, `region`). Where the whole boundary holds and a region does not,
`CityScene._region_fail` tears loose the storey under that region only -- a SEVER with
`DamageLog.FLAG_REGION`, the slab a crush cuts kept to the region on plan (`separate_plane`'s
`within`; `DamageLog.region_crush` makes it) -- and what stood on it is then held by its neighbours
or not (the stress solve, the span rule). A region with no contact at all is skipped: what hangs
over nothing is the span rule's.
*What it is for, measured first:* one bay of a wide building shot out across its depth already
falls by the span rule (120 x 40, 40 studs of ground storey gone: a rim of 58 cut; the whole
boundary read 0.05, the region 0.31), and a bay inside with its walls kept stands, its floor
reaching 15 studs to a wall. The region check is for **one part much heavier than the rest** --
a tower on a wide base, a castle tower on its wall: the 80 x 60 tower cut down to three storeys
but for a 32-stud corner, the columns under the corner shot out, reads **0.22 over the whole
boundary before and after, and 1.52 in the region under the tower**.
*No false alarms:* every shape the city builds, whole, has its worst region at 0.02-0.54 (the
246-course tower; its whole boundary 0.54), at most 0.12 over its whole boundary.
`tools/region_probe.gd`, 6.

The plan as it was:
The load check per column of tiles rather than over the whole boundary, and a **span rule**: a floor
reaches so far between supports -- further for a thicker one, further for a stronger material
(`BRICK_MATERIALS[].toughness`: stone 2.5, metal 4) -- and past that sags and breaks mid-span. That
is what an open hall, a long room in a castle wall and a room hanging off the side need.

### 2.4 Floors found in the bricks — not started
A floor is a wide layer of plates, found in the grid at whatever height it is. Interiors, the
floor-line snap and the space finder (3.2) use found floors, so a mezzanine or a double-height hall
is a floor like any other.

### 2.5 Collapse in three tiers — built, as rules already there; named 2026-10-18
Looked at before building it: most of this was already in, spread over ten constants. They now
read two numbers, `CollapseTier.HOT_RANGE` (60 m) and `FAR_RANGE` (150 m) (`scripts/collapse_tier.gd`),
so the tiers move together:

| tier | from the nearest player | what it does today |
|---|---|---|
| hot | under 60 m | every group the solve lets go is a piece; a landing breaks what lands; small pieces, crumbs and the brick heap; furniture falls within 6 m; a mega building in chunks of 1,500 bricks |
| rest | 60-150 m | a landing breaks nothing (`FRACTURE_RANGE`); a small piece is deleted where it comes loose (`SMALL_KEEP_RANGE`); a mega building in chunks of 4,000 |
| far | past 150 m | any building in a few big chunks, furniture written off (`CollapseDirector.is_far`); settled pieces put to sleep, drawn by a stand-in (`SLEEP_RANGE`) |

Measured (`collapse_probe` "far", a 5-storey tower undercut): 3-14 pieces from 30 m, 2-3 from 100 m,
1 from 260 m. Hot at 60 m, not the ~30 m written below: 60 m is where landings stop breaking
today, and moving it in changes what the player sees at 30-60 m.
**Not built, and why not yet:** far collapses *resolved without physics* (a far collapse is 1-3
bodies; there is little to save), chunks cut *along tile edges* (they are cut between storeys), and
pieces at rest *merged into one static rubble mesh* (settled pieces are frozen bodies, and past
150 m asleep). Each is worth doing when a measurement says it costs something.

The plan as it was:
* **Hot** -- the damaged tiles and the tiles within ~30 m of the player: real bricks, crumbs,
  furniture with collision, items with physics.
* **The rest** -- big rigid chunks cut along tile edges, merged collision, coarse meshes, no
  interiors, no crumbs.
* **Far** -- big chunks only, small pieces deleted (`IslandManager._far_and_small`), resolved rather
  than simulated, dust.

A player **in** a room that falls keeps that room's tile hot: its furniture rides the chunk (built:
`_rider_add`), and loose items take physics when the floor tilts past a limit or the room hits
something. Chunks at rest merge into one static rubble mesh.

### 2.6 Rooms as the unit of interiors — not started (see 4)
The spaces (3) are the rooms it will use.

## 3. What a structure describes

Everything else is found: floors, ground contact (a building's lowest row is ground), supports,
what hangs off the side, far meshes.

| What | Who says it | Used for |
|---|---|---|
| **Roles**: structure / interior / detail | build mode (`BuildRecipe.Role`, key I) -- built | what holds it up, what is furniture, what is an item |
| **Spaces**: rooms, halls, corridors, stairwells, with a kind | build mode (spaces tool) or the generator | interiors, visibility, AI, the procedural fill (4.3) |
| **Openings**: doorway, door, window, glass, arch, open side | found, then set by hand where wrong | the faked room behind glass, what is seen into, AI routes |
| **Points** (optional): spawn, loot, cover | build mode | play |
| **Materials** | per brick -- built (`set_block_material`) | strength, the span rule, glass |

### 3.1 The record — built 2026-10-16
In a build: `recipe.meta["structure"]`, saved with it. From the generator: the same dictionary,
made from a generated building's bricks (`StructureSpaces.for_tower`, 3.3). One reader and one
finder for both (`scripts/structure_spaces.gd`).

```
{"spaces":   [{"id": 0, "kind": "office", "frame": 0, "seed": [x, y, z],
               "floor_y": y, "ceil_y": y, "columns": [[x, z], ...]}],
 "openings": [{"id": 0, "kind": "window", "space": 0, "cells": [[x, y, z], ...],
               "set": false}],
 "points":   [{"kind": "loot", "at": [x, y, z]}]}
```

Cells are the build's grid (studs across, plates up). `set` is true where somebody chose the kind
by hand: it survives the space being found again after an edit.

### 3.2 Finding a room (the spaces tool) — built 2026-10-16
Click the floor of a room. From the cell above the click:
1. **Floor and ceiling**: down to the first solid cell (the floor), up to the next (the ceiling).
2. **The room's footprint**: from that column, across the floor in four directions. A column is
   **inside** when it has the floor under it, the ceiling over it and air all the way between; it is
   a **wall** when any cell between floor and ceiling is solid; it is **outside** when the floor or
   the ceiling is missing. The fill goes through inside columns only.
3. **Openings**: every wall column and outside column the footprint touches, and their cells
   between floor and ceiling. A run of air cells in a wall is an opening -- a **doorway** when it
   starts at the floor, a **window** when there is wall under it (a sill). A run of see-through
   bricks (`translucent` materials) is **glass**; a door part (an archetype named `door...`, none
   yet) is a **door**. An outside column is an **open** side. Neighbouring cells of one kind are one
   opening.
4. A fill that grows past `MAX_COLUMNS` stops and says so: a click outside, or a room with a whole
   wall missing.

A wrong kind is clicked to cycle it; a missing opening is a wall that should not be one (no
window was left). The space is found again from its seed after every edit, and the kinds set by
hand stay on the openings that are still there.

**In the workshop** (`scripts/workshop_spaces.gd`, key **O**; the build's other tools are as they
were):

| | |
|---|---|
| O | the spaces tool out / away (the ghost brick goes while it is out) |
| LMB on a room's floor | find the room, as a space of the kind K is on |
| LMB on an opening | its kind, round: doorway, door, window, glass, arch, open (the same hole seen from the room on its other side turns with it) |
| LMB in a room found | select it |
| K / shift K, or the wheel | the selected room's kind; with none selected, the next room's |
| RMB in a room | forget it |
| P / shift P | a point (spawn, loot, cover) where the cursor is, or take it away; shift: which kind P puts |

Rooms are outlined at floor and ceiling (yellow selected, red when the room cannot be found any
more and why), openings boxed in their kind's colour, points crossed, each room's kind written over
it. Furniture and detail (the I layer) are air to the finder: a room is not walled by its desks.
Only the upright grid is looked at yet. The asset workshop has its own O, K and P and never sees
this tool.

Limits as built: a beam below the ceiling is a wall to the finder, so it splits a room (with a
doorway between the halves); a room needs a ceiling; a wall built sideways is not seen.

`tools/spaces_probe.gd` (9: the finder, and a generated building) and
`tools/workshop_spaces_probe.gd` (8: the tool in the workshop, an edit, a save and load).

### 3.3 The generator — built 2026-10-16
`StructureSpaces.for_tower(world, chunk, footprint_x, footprint_z, courses, building_seed,
program)`: every room `RoomManifest.rooms_for` gives a generated building, found from the free cell
nearest its middle by the same finder, as a space of the room's own kind. A two-storey 30 x 30 tower:
8 of 8 rooms, 24 windows and 8 doorways, 18 ms -- about 2 ms a room, so it is asked for a building
when something wants it (its interiors, its AI), not for a city at load.

**The stairwell is solid to the finder (2026-10-18).** It is a shaft one floor cell wide
(`TowerRecipe.stair_rect`) through every slab, and the slab's hole read as "no floor" to the
rooms it cut through: on a 40 x 40 two-storey tower with its shaft carved, 3 of 12 rooms could not
be found at all. With the shaft solid, 12 of 12, every one sealed (`spaces_probe`, 10). A
staircase is a space of its own later (3.4); until then it is a wall to the rooms beside it.

**Seeing it in the city: Shift+O** (`SpacesView`) draws what the finder makes of the nearest
building in bricks -- each room outlined at floor and ceiling, cyan when sealed and red with
"OPEN" when a side of it is open, its kind over it, every opening boxed in its kind's colour
(doorway green, window blue, glass pale, door dark green, open red), the stairwell orange storey
by storey -- found again a second after its bricks change, so a shot shows what it did to the
rooms. `big_city.tscn -- --roomsview` takes its pictures: a 40 x 30 tower of 60 courses, 40 of
40 rooms found and sealed, 160 windows, 40 doorways, 106 ms.

### 3.3.1 Room kinds
`office, corridor, hall, stairwell, storeroom, kitchen, bathroom, bedroom, living, shop, lab,
armory, barracks, workshop, empty, other` -- the city's room kinds (`Room.KINDS`) are all among
them by the same names.

### 3.4 Stairs
The staircase every generated building has now (`staircase_recipe.gd`, a spiral in a stairwell) will
not be the one every building uses. A stairwell is a **space** of kind `stairwell` that spans floors,
joined to each floor by an opening; what fills it is chosen by its footprint and height -- straight
run, switchback, spiral, ladder, ramp, lift shaft -- the way a room's kind chooses its furniture.
Castle towers want spirals, wide buildings switchbacks and ramps, a tower lifts.

## 4. Interiors

### 4.1 Today
Rooms come from the recipe's program (office, storeroom, kitchen, ...). A room holds **interior
pieces** (desks, tables, shelves: `Role.INTERIOR`, seen to ~100 m) and **items** (cups, books,
guns, ammo: `Role.DETAIL` and loot, to ~20 m). Both are drawn per **storey group** (up to four
storeys, `InteriorGroups`) and faded in and out by distance; interior pieces get collision only near
the player. An item stands while most of its floor does (Interiors.md 8.10); a piece that is shot
becomes bricks, alone (8.11). Past ~100 m the shell's windows paint a room behind the glass.

### 4.2 The plan: a room has three states
1. **Faked** -- a room painted in the window itself (an interior-mapping shader on the opening), for
   buildings in bricks as well as shells. Nothing per item. **Built for bricks 2026-10-18:** a
   damaged building past `DEMESH_RANGE`, drawn from its bricks (`CityScene._far_real`), had no
   windows at all; it now gets the shell's panes (`BuildingShell.build_window_mesh`, its
   `standing` question), each only where the bricks still frame it -- the sill under it, the lintel
   over it, the floor 4 studs in behind it. A tower shot through at 160 m: 0 painted windows before,
   201 after (`big_city.tscn -- --lodbreak --at=160`); `shell_probe` checks a whole building in
   bricks gets every pane and one with a sill shot out loses that one. Inside `DEMESH_RANGE` the
   drawn rooms (InteriorGroups, to 100 m) are what shows through a brick building's openings.
2. **Drawn** -- its furniture drawn, no physics, only when it can be seen through an opening.
3. **Live** -- collision, items that can be picked up, physics in a collapse: the room the player is
   in and its neighbours.

A room that is not live when it comes down is resolved, not simulated: a few crumbs and its loot
where its floor lands.

### 4.3 Generated interiors
A space's kind is what a procedural fill reads: "generate office" lays an office's pieces in that
space, against its walls and clear of its openings. Not started.

## 5. If every building were 1x1 plates

Measured 2026-10-16 (four big-city buildings made bricks; every solid cell is one 1x1 plate):

| building | bricks | as 1x1 plates | x |
|---|---|---|---|
| 40 x 30 studs, 60 courses | 2,806 | 68,610 | 24.5 |
| 80 x 60, 204 courses | 22,354 | 665,938 | 29.8 |
| wide 240 x 50, 12 courses | 3,602 | 111,442 | 30.9 |
| wide 200 x 80, 24 courses | 8,845 | 272,976 | 30.9 |

**25-31 times the blocks.** What grows with them: block memory (48 bytes each; these four went
from 1.8 MB to ~55 MB), the joints, and every walk over a chunk -- the stress solve, the grounding
walk, the search for what came off, a piece's shapes when it is small enough to be a box a brick --
all roughly 25-30 times the work. What does not: the occupancy grid (by cells, already the biggest
part, 20.7 MB for these four), the far tiers, and merged collision (by cells too).

And it would not stand as a brick wall does: a 1x1 plate meets only the plates straight above and
below it, so a wall of them is a row of separate columns with nothing across. Bricks laid in a bond
are what make a wall one thing. Plates where plates belong -- floors, trim, detail.
