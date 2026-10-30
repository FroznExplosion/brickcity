# Room modules: rooms built by hand, buildings grown from them

User, 2026-10-30: build a room in the workshop, mark its entries and exits and the other things a
generator needs, then let a procedural building system put such rooms together. Several
generators for several purposes:

* **Grow by connectors** (first): start at an entrance room, snap rooms on door to door, never a
  room inside another, rooms may meet at more than one place, and the whole building has a
  **start** and a **finish** with a path through it. Castles, bunkers, compounds, any shape.
* **Set by shell** (later): a drawn outer shell (Sketch, Walls) whose inside is split into rooms
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
| `role` | `room`, `corridor`, `stair`, `start`, `finish` | what the generator asks it for; `start` and `finish` are where the path begins and ends |
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
  beside the hole. Two modules join where their connectors' `at` is the same cell and their `facing`s
  are opposite: walls back to back, the doorway through both.
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
4. **Loops**: any two open connectors that now meet (the same cell, facing each other, the same
   size) are joined -- rooms meeting at more than one place.
5. **Caps**: every connector left open is walled up (its opening filled with the module's own
   wall brick), except the start's and the finish's.
6. All of it from `(seed, library)`: the same seed grows the same building, on any machine.

The result is a **plan**: `[{module, at: Vector3i, turn}]`, the joins and the caps. Laying it in
bricks is a separate step (in the workshop as a preview, in the city as a building).

## 4. Set by shell
Later. A shell (Sketch, Walls, a floor each storey) split into rooms; modules whose rules say
they fit are put in the pieces; the stairwell a stair-role module.

## 5. In the workshop (stage 1, built)

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
| 1 | markers: connectors from openings (link by hand), stair links, facade spots, module rules on the rail; saved; `module_marks_probe` (9) | built 2026-10-30 |
| 2 | the library: modules read, cells, connectors, turned four ways | |
| 3 | grow: path start to finish, branches, loops, caps, no overlap; seeded; probe | |
| 4 | lay a plan in bricks: Generate on the workshop rail (a preview build); then the city | |
| 5 | facade spots filled (window styles, balconies, hanging rooms) | |
| 6 | set by shell | |
