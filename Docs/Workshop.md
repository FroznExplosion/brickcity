# Workshop — menus, composition, generated buildings, rooms

Plan and running record for the workshop's second pass. Builds on
[BuildMode.md](BuildMode.md) §11 (placement, frames, fixtures — all done) and
[Interiors.md](Interiors.md) (rooms, manifests, the drawn/real rungs — all done).
Where the two disagree with this file, the code won; the section says so.

---

## 0. What was asked, and the answer to the one real question

1. Proper menus: load an existing build, save, save as, clear the build space.
2. Place existing builds into the workshop as part of a new build — and
   **decide whether a placed build should be stored as a reference** (saved
   once) or as a copy.
3. Split build mode by *what* is being built — buildings, mechs, guns, cars,
   planes. Buildings only for now.
4. Spawn a generated building and drag it bigger — width, depth, height — with
   floors and walls made automatically, stairs and interior walls optional.
5. Author rooms, so interiors look real when small items go in them.
6. A third class of brick besides structure and interior: **detail**, never
   spawned until the player is close enough to see it or in the room with it.
7. Choose which rooms a generated building has, and fill them procedurally
   from authored pieces.

### Reference or copy? Copy, with provenance. References only where the generator already is one.

**A player build placed inside another is stored as a copy of its bricks,
tagged with where it came from.** Not a reference. The reasons are all in the
contracts the rest of the project already rides on:

| Problem a reference causes | Why it is not hypothetical here |
|---|---|
| **Block ids shift when the source is edited** | Block id == placement order is *the* damage contract (BuildMode §8, M3). Edit `cottage` and every parent that references it renumbers every brick after the insert; every saved damage record on every placed parent silently points at the wrong bricks. |
| **Editing one build edits every build that uses it** | A player tweaking a door on `kiosk` would change twenty buildings already standing in the city, some of them half shot. |
| **Missing / renamed / cyclic files** | `A` includes `B` includes `A`; `B` deleted; `B` saved with a newer VERSION. Every one is a load-time failure in a parent the player did not touch. |
| **Frames have to be merged anyway** | A multi-frame child's sideways grids have to be matched onto the parent's grids to be built at all, so the "reference" is expanded to bricks on every load regardless. |
| **What it saves is small** | A 500-brick house is tens of KB of JSON. Disk is not the constraint; the city stores recipes, not bricks. |

What the copy keeps is a **group record** — `{source, name, first, count, turn,
offset}` — so the workshop can still select, move and delete a placed build as
one thing, and a later "update from source" is a deliberate, one-build,
undoable action rather than a side effect.

**Where references ARE worth it: the generator.** A generated building is
already a reference — its bricks are re-derived from parameters every time, and
nothing is stored. Rooms and items authored in the workshop are consumed the
same way: the generator names a room template or an item by name, and builds
it on demand. That is where "saved once" pays: five thousand buildings × twenty
rooms share a handful of authored templates. Changing a template changes every
generated room that has not been touched — which is exactly how `ITEMS` in
`room_manifest.gd` already behaves.

---

## 1. Build kinds

`BuildRecipe.kind` (v6): `building` (default, and every older file), `room`,
`item`, and — listed, not yet enabled — `mech`, `gun`, `vehicle`, `aircraft`.
The workshop's **Type** menu picks it. It changes what the recipe *is for*
(what the library offers where, how the city anchors it — BuildMode §8.1) and
nothing about how bricks are placed. `room` and `item` are the authoring side of
§5 and §6.

---

## 2. Stages

Each stage runs, carries a check, and is merged on its own.

### Stage A — menus ✅
A top menu bar, visible whenever the mouse is free (ESC):

* **File** — New (clear), Open…, Save, Save As…, Place in city test.
* **Insert** — Build from library… (Stage B), Generated building (Stage C).
* **Type** — Building ✓ / Room template / Item / Mech, Gun, Vehicle, Aircraft (later, greyed).
* **Layer** — Structure / Interior / Detail (Stage D).

Open lists `res://builds/` and `user://builds/` (the city placer's library, so
every save is placeable with `P`). Save As names the file. Clear asks first.
The F-keys keep working. `ctrl+N / ctrl+O / ctrl+S / ctrl+shift+S`.

### Stage B — placing a build inside a build ✅
Insert → a library build is held as a ghost, snapped to the baseplate's studs,
`R` turns it a quarter, LMB stamps it. Its bricks are appended to the recipe in
its own order (so its internal welds and fixtures survive), its interior/detail
roles and materials come with it, and one **group** is recorded. Undo takes the
whole stamp back as one edit. Multi-frame sources stamp unturned only (their
frames are matched to the workshop's six standing grids; a turn would need a
frame rotation composed with each of them — later).

### Stage C — a generated building you drag bigger ✅
Insert → Generated building drops a `TowerRecipe` block-out on the baseplate:
footprint in whole panels (10 studs), height in whole storeys. Three handles —
+X face, +Z face, top — are dragged with LMB; each snaps to a panel or a
storey and the preview rebuilds. Options: interior walls, stairs, windows.
It is saved as ONE record (`BuildRecipe.towers`: `{cell, params}`), not as
bricks, and **Bake** turns it into ordinary bricks for hand editing.

What the implementation settled:

* **The preview is the generator, not a copy of its rules.** `TowerBlockout.bricks`
  builds the building for real into a scratch chunk and reads the bricks back
  (`get_block_ticks`), so the workshop, a Bake and the city can never disagree
  about how a building is laid. The extension names a baked variant
  `plate_10x10#base`, which is not a palette key; ids are mapped back to the
  palette's own names (`TowerBlockout.names_of`).
* **The city gets bricks, laid first.** `BuildingRegistry.register_build` and
  `CityPlacer.hold` flatten the records (`TowerBlockout.flatten`), generated
  bricks before the author's, so a brick on a roof lands on the roof.
* **Three panels is the smallest building with stairs.** `TowerRecipe.stair_line`
  needs a lattice cell clear of the walls, and a 20-stud footprint has none. The
  default is 30×30, two storeys, at (4, 1, 4) so it can be dragged to 40.
* **The baseplate caps it at 40×40 studs and 120 plates** (five storeys). The
  workshop volume is a tick cube (`PLATE_STUDS`/`HEIGHT_PLATES`) that every saved
  sideways frame's origin depends on, so it was not enlarged.
* `TowerRecipe.build` takes `options` — `rooms: false` lays no interior walls,
  `windows: false` cuts none. Missing means on, so the city is unchanged.

`tools/workshop_probe.gd` — **61 checks**: v6 round-trips, a turn checked cell by
cell against the baked masks (slopes and curves included), flatten, the drag
handles driven by exact rays, save/open/new, bake and its undo, a stamp and its
undo, the detail layer, and a room template's metadata.

### Stage D — the detail class
Role byte per block: 0 structure, 1 interior, **2 detail**. `I` cycles the
three. Detail is interior (decorative: weighs nothing, holds nothing up) with
one more rule: the city never draws or lays it in the *drawn* room rung, only
when the room is **real** — the player inside it or touching it. Old files read
0/1 exactly as before.

### Stage E — room and item templates
Type = Room template or Item, then save. A room template is a build whose
interior/detail bricks are the furniture, stored in `user://rooms/<kind>/`, with
a size in panels and a kind tag. An item is a small build in `user://items/`.
`RoomManifest` prefers an authored template of the room's kind that fits,
chosen by the room's seed, and falls back to the built-in `ITEMS`.

### Stage F — a building's program
Which room kinds a generated building has: a **program** (weights per kind) on
the tower record and on the city's shapes, read by `RoomManifest.rooms_for`
instead of the fixed hash. The workshop's generated building exposes it.

---

## 3. What is deliberately not here

* Mechs, guns, vehicles, aircraft — listed in the Type menu, disabled. They need
  BuildMode §6's articulated links, which stay deferred.
* Editing a placed build in the city (BuildMode §12 question 1) — unchanged.
* Live references between player builds — §0.
