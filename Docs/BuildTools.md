# Building tools — the building workshop's rail, shared with the asset workshop

Asked (2026-10-27): bring the asset workshop's brick tools into the building workshop
(`scenes/workshop.tscn`) -- the held-click run that lays bricks as the cursor moves, the tool
rail down the left, the Sketch tool -- and add tools for buildings: shapes of the held brick,
lying flat or standing as a wall, bricks staggered or aligned (circles, rings, triangles,
rectangles, hollow rectangles...). A wall keeps the shape it was drawn as, so a doorway cut
through it later re-lays the bricks round the opening and leaves the rest of the wall. One
copy of each tool's code, so a change to a tool shows in both workshops. Not wanted now: the
SDF clay and the model converter.

## 0. How the two workshops share code

`AssetWorkshop` **extends** the building workshop (`asset_workshop.gd` is
`extends "res://scripts/workshop.gd"`). So anything that both should have goes DOWN into
`workshop.gd` or into a shared file both call, and the asset workshop keeps only what is its
own (parts, the SDF, photos, guns).

| Shared piece | Where | Who uses it |
|---|---|---|
| **The run**: hold LMB and move, a brick at each cell the ghost passes | `workshop.gd` (moved down from `asset_workshop.gd`, same code) | both |
| **The rail**: icon + name + key buttons, a pop-up for each, a hint line for the tool in hand, the tool's options under it | `ToolRail`, `scripts/workshop_rail.gd` (taken out of `AssetWorkshopUI`) | both |
| **Shapes on a grid**: rectangle, hollow rectangle, ellipse/circle, ring, triangle, line, and a drawn outline (polygon) as cells on a plane | `BrickShapes`, `scripts/workshop_shapes.gd` (static) | building shapes, building sketch; the asset sketch's outline fill (`region_cells`) moves here |
| **Courses**: cells to bricks of the held kind, staggered or aligned | `BrickShapes.pack_courses` | building shapes and sketch |
| **The sketch pen**: freehand outline, rectangle, ellipse, clicked polygon, brush -- the stroke being drawn, and the outline it comes to | `SketchPen`, `scripts/workshop_sketch.gd` | both Sketch tools: the asset's fills its part, the building's makes a kept shape |

What a stroke *becomes* stays each workshop's own: in the asset workshop a sketch is a part
seen from three views with slopes fitted on its edges; in a building it is a kept shape
(section 2). The drawing, the outline and the cells are the same code.

## 1. The rail (building workshop)

Down the left under the menu bar, the asset workshop's look: each tool an icon, its name and
its key, a pop-up saying what it does, a line under them for the tool in hand, then its
options. The readout moves to the right of it. Every key still works; the rail only calls
the workshop's own functions and lights what is in hand each frame (as `AssetWorkshopUI`).

| Tool | Key | What it does |
|---|---|---|
| Place | Esc | The hand as now. **Hold LMB and move: a brick at every cell the ghost passes** (the plane stays where the click was, as E) |
| Paint | B | The paint brush and its palette, as now |
| Shapes | K | Drag out a shape of the held brick (section 2) |
| Cut | N | Drag a doorway, window or any shape through a wall: kept shapes are laid again round it (section 3) |
| Sketch | Alt D | Draw an outline (freehand, polygon, rectangle, ellipse, brush) on the plane: it becomes a kept shape |
| Select | L | Click a kept shape: change its height, thickness, bond, brick; delete it; or let it go (keep the bricks, forget the shape) |
| Rooms | O | The spaces tool, as now |

## 2. Shapes, made of the held brick

Options: **kind** (rectangle, hollow rectangle, circle, ring, triangle, line), **lie**
(flat or wall), **tall** (plates; flat only: one course is 3), **thick** (studs: a wall's
depth, and the rim of a hollow rectangle or ring), **bond** (staggered or aligned).

* **Flat**: dragged on the plane the ghost is on (a brick top, the floor, E's height), from
  corner to corner, and `tall` plates high. A floor, a round platform -- or, with a hollow
  rectangle and `tall` 12, the four walls of a room; a ring 18 tall is a round tower.
* **Wall**: stands up on a vertical plane through where the drag started, across the camera's
  view (along X when the camera looks along Z, else along Z), dragged from a bottom corner to
  the top one; `thick` studs deep. A gable is a triangle wall; a round window frame a ring.
* **Circle and ring** fill the dragged box (an ellipse); Shift keeps them round in metres (a
  plate is 0.4 of a stud).
* **Made of the held brick**: the held part is the biggest used; smaller ones of its kind
  (same height, a footprint inside its own) fill the ends. A 1x4 held lays 1x4s with 1x2s and
  1x1s at the ends; a 2x4 may use 2x2s and 1x2s too. Where the height left is less than a
  brick, plates of the same footprints.
* **Bond**: *staggered* is running bond -- every other course starts with half a brick, so
  no seam runs up the wall; and at corners the courses take turns, one course's brick runs
  through the corner along X, the next along Z, so the corners interlock (Docs: destruction
  wants interlocked corners). *Aligned* is stack bond: every course the same, seams straight
  up, corners not tied.

Laying: the cells the shape fills, less its cuts, less what is already built there (hand-laid
bricks stay), packed course by course (`BrickShapes.pack_courses`). One undo.

## 3. A shape stays a shape: cuts

Every shape is **kept** with the build -- `recipe.meta.shapes`, saved and opened with it:
its kind, lie, plane, corners, tall, thick, bond, brick, colour, material, its cuts and the
bricks it laid (`[part, cell]`, found again by the world's cell lookup, as the asset
sketches keep theirs).

* **Cut** drags a shape (rectangle, arch, circle; or a door or window of a set size, clicked)
  onto a face. Its depth is *through the wall*: from the face clicked, in until the shape
  under it ends -- so a door in a room's front wall does not go on through the back wall.
  The cut is added to every kept shape it touches; each is laid again **near the cut only**
  (bricks a course and a brick's length clear of it stay where they are), so the rest of the
  wall keeps its bricks. Hand-laid bricks in the cut are taken up. One undo.
* Changing a kept shape (Select: tall, thick, bond, brick) lays it again whole, cuts kept.
* **Let go** forgets a shape and keeps its bricks: they are plain bricks from then on.
* A brick of a kept shape taken up by hand (RMB) is just gone; the next re-lay of that shape
  puts it back. (Cut is the way to make a lasting hole.)

## 4. What else would make building faster -- proposed, not built

In rough order of what saves the most time:

1. **Doors and windows as one click** -- set sizes (door 4 wide x 5 bricks, window 2x2 bricks
   ...) placed on a wall: the cut plus the frame or glass part. Cut already does the hole.
2. **Storeys**: repeat a selection (or a whole floor) N times up, or along a facade at a
   step -- a floor of a tower once, then "five more"; a window bay along a wall.
3. **Floor fill**: click inside closed walls, the floor (or ceiling) is laid to the walls.
4. **Roof from a footprint**: a kept shape's outline as a gable or hip roof of slopes.
5. **Mirror** (the asset workshop's Alt S, moved down): build half a facade.
6. **Redo**, and a run as one undo (the asset workshop has both).
7. **Wall line**: click, click, click -- a wall along each segment, `tall` high, corners tied.
8. **Stairs between two floors**: the staircase recipe, dragged from one floor to the next.

## 5. Stages

| Stage | What | Check |
|---|---|---|
| 1 | Shared `ToolRail` (the asset workshop on it, unchanged to the eye); the run moved into `workshop.gd`; the building workshop's rail with Place, Paint, Rooms | `workshop_probe`, `asset_ui_probe`, `asset_workshop_probe` (its run check now runs the base's code) |
| 2 | `BrickShapes` (kinds, flat and wall, courses staggered and aligned); Shapes tool | `tools/build_tools_probe.gd`: each kind's cells, bricks are the held kind, no seam straight up when staggered, corners alternate, one undo |
| 3 | Kept shapes and Cut; Select for shapes; saved and opened | probe: a door cut keeps the wall's bricks away from it, a wall re-laid after a cut has the hole, save and open keeps shapes |
| 4 | `SketchPen` shared; Sketch in the building workshop | probe: a polygon becomes a kept shape; the asset sketch probe checks unchanged |
