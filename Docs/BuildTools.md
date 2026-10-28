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
| 1 ✅ | Shared `ToolRail` (the asset workshop on it, unchanged to the eye); the run moved into `workshop.gd`; the building workshop's rail with Place, Paint, Rooms | `workshop_probe`, `asset_ui_probe`, `asset_workshop_probe` (its run check now runs the base's code) |
| 2 ✅ | `BrickShapes` (kinds, flat and wall, courses staggered and aligned); Shapes tool | `tools/build_tools_probe.gd`: each kind's cells, bricks are the held kind, no seam straight up when staggered, corners alternate, one undo |
| 3 ✅ | Kept shapes and Cut; Select for shapes; saved and opened | probe: a door cut keeps the wall's bricks away from it, a wall re-laid after a cut has the hole, save and open keeps shapes |
| 4 ✅ | `SketchPen` shared; Sketch in the building workshop | probe: a polygon becomes a kept shape, an RMB brush stroke cuts it; `asset_workshop_probe` unchanged (318) |

### As built (2026-10-27)

All four stages, merged. `tools/build_tools_probe.gd`: 67 checks. Notes from building it:

* **Shapes**: the kinds are rectangle, hollow rectangle, circle, ring, triangle, line and
  arch. RMB drag in Shapes cuts the same shape out (as the asset workshop's RMB carves).
  A wall stands on the plane through the ghost, across the camera's view.
* **"Long both ways"** (a corner or a floor, where the course picks the way) means both runs
  through the cell are longer than two of the held brick's widths -- so a two-stud wall still
  runs its own way, and a room's corners interlock.
* **Near only**: a cut lays again the shape's bricks within a brick's length and a course of
  it, along the cut's plane only -- not behind it, so the side walls a door's wall meets keep
  theirs.
* **Door and window**: 4 x 18 plates and 4 x 9 (`WorkshopTools.DOOR`, `WINDOW`); a door stands
  on the lowest of the build's own bricks under the click (never the baseplate).
* **Sketch**: the asset workshop's stroke code moved into `SketchPen`
  (`scripts/workshop_sketch.gd`) -- press, move, polygon clicks and keys, the preview lines,
  `drag_shape`, `brush_entry`, `region_cells`, `brush_cells`. The asset workshop's `_sketch`,
  `_sketch_out`, `_sketch_anchor` are its pen's now, and its static helpers call the pen's,
  so a change to the pen changes both workshops. `BrickShapes.outline_cells` is the pen's too.
* **Undo**: one Z per shape edit (lay, change, cut, delete, let go). A run is still a brick
  per Z (as in the asset workshop). A shape's bricks have no "brick" edit of their own; RMB on
  one takes it out of the shape (laying the shape again puts it back). Hand-laid bricks a cut
  took up come back on undo, but at the end of the build, so their own Z is gone.
* Not done: Select shows no gizmo to move a kept shape; shapes are upright-grid only (a
  sideways frame refuses them); the asset workshop does not use Shapes/Cut yet (its Shapes
  tool is its own: box, ball, cylinder, wedge, brush).

## 6. Doors, windows and storeys (2026-10-28)

Asked: the next two of section 4 -- doors and windows in one click, with their frame; and
repeating a floor or a selection N times up, or along a wall.

### Doors and windows with frames

Cut's **door** and **window** are one click on a wall, as before, now with options:

* **Size**: width in studs, height in plates (door 4 x 18, window 4 x 9 to start).
* **Frame** (on by default): a band one stud wide round the opening, as deep as the wall, of
  the held brick in the held colour -- pick a white 1x2 and click, and the door has white
  jambs. A window's frame goes all round (the sill under it, the head over it, a brick's
  height each); a door's has no sill -- its sides and its head only, the floor stays open.
* **Glass** (windows, on by default): the opening filled with see-through bricks (the
  translucent material, PETG) one stud deep, in the middle of the wall's thickness.
* How: the wall gets ONE cut, the opening and its frame together, laid again near it as any
  cut; the frame and the glass are **kept shapes of their own** (kinds `jamb` -- a hollow
  rectangle with no bottom -- `hollow` and `rect`), so Select can change or delete them like
  any shape. All of it is one undo.

### Repeat: storeys and bays

A new rail tool, **Repeat** (J):

* **What**: the *picked shape* (click one of its bricks here, or pick it in Select), or a
  *storey*: everything built between two plate heights (from / to; clicking a brick sets them
  to that brick's shape's height, or the brick's own course). A storey copies the kept shapes
  wholly inside it as shapes (with their cuts, so its doors and windows come too) and every
  other brick inside it as plain bricks.
* **Which way**: up, along X, along Z. **Times**: how many copies. **Gap**: studs (or plates
  going up) left between one copy and the next.
* The step is the size of what is copied plus the gap: a 12-plate storey repeated 4 times up
  is a five-storey tower; a window repeated along X with a 2-stud gap is a row of windows (cut
  copies cut the wall they land on).
* One undo for all the copies. A copy that runs into something already built goes round it
  (shapes pack round what is there; a plain brick that does not fit is left out).

| Stage | What | Check |
|---|---|---|
| 5 ✅ | Door and window: size, frame, glass | probe: a window's frame and glass are their own shapes, the glass is the translucent material, the door's floor stays open, undo puts the wall back exactly |
| 6 ✅ | Repeat: picked shape or storey, up / along, times, gap | probe: a storey repeated twice up fills the floors above with its shapes and doors; a shape repeated along X with a gap; one undo takes all copies |

### As built (2026-10-28)

Both merged; `tools/build_tools_probe.gd` 86 checks.

* An opening's spec (`WorkshopTools.opening_spec`: kind, plane, the opening's corners, frame,
  glass, the frame's brick and colour) is kept in its frame's and glass's records as
  `opening`. Repeat with a frame or a glass picked repeats the whole opening: the cut into
  whatever wall the copy lands on, and a new frame and glass.
* Glass is `WorkshopTools.glass_paint()`: the first see-through material
  (`BrickWorld.is_material_translucent`, PETG) in its clearest-named colour.
* A frame's head and a window's sill are a brick's height (3 plates); its sides a stud.
* A storey copies the shapes wholly inside its plates; a shape that reaches past them (a door
  taller than the storey's walls: its head) is copied as plain bricks instead. A storey with
  a door copies the door too -- upper floors get one; leave it out of the band (or cut it off
  upstairs) when that is not wanted.
* Undo now takes up everything an edit laid before putting back what was there (a frame
  stands where its wall's bricks go back).
* Fixed on the way: a sketched brush stroke laid with LMB passed a Dictionary to a
  parameter typed Array (`add_shape` now takes a Variant); only the RMB cut path was tested.

## 7. Everything a button; the rest of the list (2026-10-28)

Asked: things must be tool buttons on the rail, not key presses to remember; and finish the
rest of section 4.

### Every key has a button

The rail keeps every key, and adds a button for each:

* **Tools in two columns** (icon and name; the key in the pop-up), so more fit: Place, Pick,
  Paint, Shapes, Walls, Floor, Roof, Stairs, Cut, Sketch, Repeat, Select, Builds, Rooms.
* **Hand** buttons: Rotate (R), Flip (F), Turn last (T), Lock height (E -- now a button that
  stays on, as well as the held key), Side studs (V), Layer (I: says which), Mirror and Mirror
  here, Colour back / on (, .), All parts (Tab).
* **Edit**: Undo (Z), Redo (shift Z).
* **View**: Grid (G), Stress (H), Keys (F1), Room guide (U).
* Toggles show lit while on. The rail scrolls when it is taller than the window.
* What was a modifier is an option: Shapes and Sketch have **lay / cut out** (RMB still
  cuts), Shapes **keep round** (Shift still does), a polygon has **Close** and **Take back a
  corner** (Enter, Backspace), and anything being drawn a **Cancel** (Esc).
* **Pick** is the middle click as a tool: click a brick to hold its part and colour.
* **Builds** is X, M, C, Delete as a tool: click an inserted build, then Move, Copy, Delete.
* **Rooms** shows its kind with back / on buttons, the opening point kind, and "click marks a
  point" in place of P.
* **Paint** shows its brush size (- =).

### The rest of the list

* **Redo**, and **a run as one undo**: a held run (and a mirrored click's pair) undoes with
  one Z; Shift Z or Redo lays back what Z took (bricks and shape edits; anything else undone
  clears it). A redone brick is laid again as it was, but a weld it had is not.
* **Mirror**, moved down from the asset workshop (`_place_mirrored`, `mirrored_z`): across a
  plane along X or along Z, through the middle of the plate or "here" (the ghost). Placing and
  runs lay the mirror image too; so do Shapes, Walls, Floor, Sketch (the kept shape's mirror
  is a kept shape).
* **Walls** (wall line): click corners on the plane you aim at; each click a corner, a wall
  `thick` studs and `tall` plates along each segment; Finish (or a click on the first corner,
  which closes it). Straight keeps segments along X or Z. One kept shape (`polyline`), so its
  corners interlock like a hollow rectangle's.
* **Floor**: click inside closed walls: the floor is the space the walls close in, `tall`
  plates thick (1: a plate). "On top of the walls" lays it over the walls' tops instead, out
  to their outer faces: the next storey's floor, or a flat roof. Refused when the walls do not
  close (the fill would run out of the plate). A kept shape (`cells`).
* **Stairs**: click the lower floor, then the upper: a straight stair, a brick high a step,
  each step one stud over the one below, `wide` studs across. A kept shape (`stairs`, standing).
* **Roof**: click a kept shape (a room's walls): a roof on top of it, its footprint plus the
  overhang. Gable (sloped on the two long sides, the ends closed) or hip (all four; brick
  corners: there are no corner slopes yet). Each course steps in a stud, its edge a row of
  45-degree slopes (`slope_1x2`) facing out, the ridge bricks. A kept shape (`roof`).

### As built (2026-10-28)

All of it, merged; `tools/build_tools_probe.gd` 115 checks.

* `ToolRail` (shared) gained `columns` (the tools in a grid), `actions` (sections of small
  buttons, toggles lit by `show_toggles`, text changed by `set_action_text`) and a scrolling
  mode (`fit_height`). The asset workshop's rail is unchanged (one column, no actions).
* `WorkshopTools.ACTIONS` lists the buttons; `act(id)` does what the key does. Lock height is
  `plane_locked` on the workshop (E held still works). The keys all still work.
* Redo and run grouping are the building workshop's (`_redo_list`, `_brick_groups`,
  `redo_last`); the asset workshop keeps its own `_redo`/`_edit_groups`. A shape edit's undo
  and redo are one routine (`WorkshopTools._apply`), each giving back the other's record.
* The mirror's state and `_place_mirrored` moved into `workshop.gd`, generalised to a plane
  across X or Z; the asset workshop draws and saves its plane as before (across Z only). Kept
  shapes, cuts and doors/windows are mirrored with `BrickShapes.reflected`.
* Roof slopes: `slope_1x2` turned so `BrickPalette.front_of` is the way out; a slope's front
  cell's top plate is its open face, so the roof's cells leave it out. Ridges and hip corners
  are bricks.
* Floor "on top of the walls" also takes the corners (they touch the inside only across a
  diagonal).
* Not done: corner slopes for hip roofs; the asset workshop's options are still its old
  panel (its tools were already buttons).

## 8. Draw the base, pull the height; the held brick, seen (2026-10-28)

Asked: most tools are confusing. Every tool should use the brick selected in the toolbar at
the bottom. Walls: click and hold, drag a line, let go; then aim up to the height wanted and
click again to place. The same for floors and shapes. And finish what section 7 left.

### One way to make things: base, then height

Walls, Floor, Shapes and Sketch all work the same:

1. **Base**: press on the surface you aim at (the floor, a brick top) and drag -- a line
   (Walls), a rectangle (Floor), the shape's outline (Shapes), the stroke (Sketch) -- and let
   go. A floor clicked without a drag fills the space the walls round it close in.
2. **Height**: now move the cursor up: the height follows it, a course of the held brick at a
   time (3 plates for a brick, 1 for a plate). A standing shape is pulled toward or away from
   you instead -- its thickness. **Click** to place. Right-click or Esc cancels.
3. While both happen, the **bricks it will lay are shown**: the held brick, in the held
   colour, laid as they will be (staggered or aligned), see-through.

Walls drawn one after another, each starting where the last ended at the same height, are one
wall line: its corners interlock, and ending on the first corner closes it.

### The held brick is the brick

* Everything lays the brick selected in the toolbar at the bottom, in its colour and material:
  smaller ones of its kind fill the ends.
* A wall's thickness, and the rim of a hollow rectangle or a ring, is the held brick's width
  (a 1x4: one stud; a 2x4: two). No separate thickness to set.
* The height snaps to the held brick's own height.
* A roof's edges: the held brick when it is a slope, else 45-degree 1x2 slopes, in the held
  colour.
* The rail loses the numbers it no longer needs (tall, thick, rim, floor thickness): what
  is pulled is what is laid. Select still changes a placed shape's height.

### Section 7's leftovers

* **Corner slopes**: a new part, `slopecorner_2x2` (two 45-degree slopes meeting at an outer
  corner: the back stud carries a stud, the other three cells fall away), in the Slopes
  category. Drawn as its own triangles; sampled and collided as stacked slabs (the shape is
  the intersection of two slope prisms, convex but not a prism). Hip roofs put one on each
  corner of each course.
* **The asset workshop's options** go inside its tool rail, under the tools -- one panel, as
  in the building workshop -- and the rail scrolls when it is taller than the window.

### As built (2026-10-28)

All of it, merged; `tools/build_tools_probe.gd` 130 checks, `palette_probe` 2104, `shaped_probe`
438.

* The flow is `WorkshopTools._make_input` (press, drag, let go), `_to_height`, `_pull_height`
  (where the cursor's ray passes closest to the line straight up from the base's middle --
  so it works aiming freely or through the middle of the screen) and `commit_pending`. It
  only re-reads the cursor when it moved. Enter places too.
* The preview is `_plan_for` (the same `pack_courses` the laying uses, cached while the shape
  does not change) drawn as see-through boxes; the probe checks the wall laid is exactly the
  bricks shown.
* Walls join (`_commit_wall`) when drawn from the last wall's end at the same height and
  brick; not while the mirror is on (the mirror image would not follow the join).
* A shape laid with a part that is no brick, plate or tile (a slope in hand) fills with a
  brick of its footprint (`_fill_part`); a roof uses a held 1x2 or 2x2 slope or curve.
* `slopecorner_2x2` (`ShapedParts._slope_corner`): its triangles cut per cell where they lie
  on a cell face, as a prism's walls are; six half-plate slabs collide and give its cells
  (the back cell three plates, the other three two). `shaped_probe` checks the slabs' volume
  against the drawn one to 3% (`approx`), not exactly.
* The asset workshop's old rail is moved into its `ToolRail`'s options (a scrolling rail);
  `_rail_right` and the paint palette read its global place.
* The probes' programmatic paths (`add_shape`, `floor_at`, `finish_walls`) keep `tall` and
  `floor_tall`; the rail no longer shows them.
