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

**Being replaced (2026-11-06):** section 20 is the plan for one editor kit both workshops compose
(`addons/workshop_kit/`), in place of this inheritance. This section is rewritten to describe the kit
when its last stage lands.

| Shared piece | Where | Who uses it |
|---|---|---|
| **The run**: hold LMB and move, a brick at each cell the ghost passes | `workshop.gd` (moved down from `asset_workshop.gd`, same code) | both |
| **The rail**: icon + name + key buttons, a pop-up for each, a hint line for the tool in hand, the tool's options under it | `ToolRail`, `scripts/workshop_rail.gd` (taken out of `AssetWorkshopUI`) | both |
| **Shapes on a grid**: rectangle, hollow rectangle, ellipse/circle, ring, triangle, line, arch, stairs, wall lines, a drawn outline and a plan as cells on a plane | `WkShapes` in the editor kit (`addons/workshop_kit/services/wk_shapes.gd`, static); `BrickShapes` (`scripts/workshop_shapes.gd`) keeps kept shapes, plans, roofs and courses on top of it | both workshops |
| **Courses**: cells to bricks of the held kind, staggered or aligned | `BrickShapes.pack_courses` | building shapes and sketch |
| **The sketch pen and the Sketch tool**: freehand outline, rectangle, ellipse, clicked polygon, brush -- the stroke being drawn, and the outline it comes to | `WkSketchPen` and `WkSketchTool` in the editor kit (`addons/workshop_kit/`, section 20); the workshop answers through `BrickWorkshopContext` | both: the asset workshop's Sketch, the building workshop's Draw (outlines) and Cut |

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

## 9. Floor plans: sketch it, raise it, storey by storey (2026-10-28)

Asked: an option in Sketch to choose the grid the sketch (and its bricks) goes on; bricks that
follow the sketch's outline at the held brick's thickness; and a way to build a building from
a floor plan -- draw it (with shapes inside the sketch), drag the walls up along its outline,
floors placed by themselves at the heights wanted, windows that repeat on every floor, and a
new sketch on top to go on up with another outline.

### The flow

1. **Choose the level** (Sketch's "draw on"): where you aim (the first stroke's surface), or
   a set level -- a plate number with up and down buttons a course at a time, and "on top of
   the last building". The level's grid is drawn while Sketch is out.
2. **Draw the plan**: strokes add to one outline on that level -- freehand, brush,
   rectangle, ellipse or clicked corners, as many as you like (the shapes in the sketch);
   RMB (or "cuts them out") takes area away (a courtyard, a notch). The plan shows as its
   outline; Take back removes the last stroke, Clear all of it.
3. **Raise it**: the Raise button, Enter, or a click (no drag) inside the plan -- then the
   height follows the cursor and a click places it, as everything else (section 8). What it
   makes is Sketch's "makes":
   * **solid**: the plan filled, course on course (as before);
   * **walls**: walls along the plan's outline, as thick as the held brick is wide -- the
     bricks follow the outline;
   * **a building**: walls along the outline and a **floor every storey** -- each storey a
     floor (a plate, the whole plan, under the walls, so the walls stand on it and tie into
     it) and `storey` courses of wall; pulled a storey at a time; a flat roof on top if
     ticked.
   The see-through preview shows the bricks, floors included.
4. **Windows on every floor**: Cut's door and window have "every floor": clicked on a
   building's wall, the opening is cut at the same place on each of its storeys (where it
   fits in that storey's wall), frames and glass with it. One undo.
5. **Go on up**: "On top of the last building" sets the level to its top; "...with its plan"
   also starts the new plan from the last one's outline, to add to or cut from (a setback, a
   tower on a podium). Raise, and so on.

### Underneath

* One kept shape for what a plan makes: kind `plan`, `points` {adds, subs} (the strokes, as
  the pen gives them), `fill`, `storey` (wall plates a storey; 0 none), `floor` (1 plate),
  `roof`. Its cells come from `BrickShapes.plan_cells`; the courses restart above each floor
  (`course_starts`), so every storey's walls are whole bricks from its floor up.
* A standing sketch (Sketch on "standing") keeps the old way: one stroke, then its thickness.

### As built (2026-10-28)

Merged; `tools/build_tools_probe.gd` 148 checks.

* Sketch on "flat": strokes go into `WorkshopTools._draft` ({at, adds, subs}); `raise_plan`
  makes a `plan` record and hands it to the section 8 height flow; a building pulls a storey
  (`step`: its walls and its floor) at a time, its flat roof added on (`extra`). A tap (no
  stroke) inside the plan raises it; Enter too.
* "Solid" sketches are `plan` shapes now (filled), no longer `outline`; old saves' `outline`
  shapes still lay as before.
* A building's courses restart above each floor (`BrickShapes.course_starts`, passed to
  `pack_courses` as `starts`): the probe checks every brick of its walls starts on a course
  from its storey's floor, and the floors are plates.
* Windows "on every floor" (`_every_floor`) only where the opening and its frame fit inside
  that storey's wall band; a door on a building stands on its storey's floor. Openings are
  cut when placed: raising the building higher later does not add them to the new storeys
  (Repeat a storey, or place them again).
* The level is a plate number; the grid drawn is the level's, a stud apart, over the plate.
  Plans are on the upright grid only.

## 10. Simpler: two cameras, a pop-out, draw then drag everywhere (2026-10-31)

Asked: suggestions for a simpler UI, and: a pop-out beside the rail showing all of a tool's
shapes; clicking back into the scene must not fire the tool; an FPS camera and a 360 orbit
camera with the cursor, as in Godot's viewport; a swap key that is not Esc (Esc is the pause
menu); walls that meet at a corner and interlock; floor-plan walls 1-3 studs thick; every
tool able to use only the held brick, or to fill gaps with others; Cut as in Fusion 360 --
draw a shape, drag the depth -- and most tools the same.

### Being built

* **Two cameras** (`WorkshopView`, `scripts/workshop_view.gd`). **Orbit** (the default): the
  cursor is free and tools work where it points. MMB drag orbits round what is under the
  cursor, Shift + MMB pans, the wheel zooms toward the cursor (Shift + wheel: the toolbar), RMB
  held and moved looks round (WASD flies, as Godot's viewport); a plain RMB click and a plain
  MMB click do what they did (take away, pick). **FPS**: the mouse looks, tools work at the
  dot. **Y** or the rail's FPS button swaps them. In FPS, **hold Alt** for the cursor (to use
  the rail); let go and it is FPS again -- a click in the scene never fires a tool by
  grabbing the mouse.
* **Esc** cancels what is being drawn; otherwise it is the pause menu (as the city's).
* **Pop-out**: a tool's options leave the rail for a panel beside it. Choices are buttons with
  pictures, not dropdowns: every shape, cut, way of drawing, bond.
* **Bricks**: every brick-laying tool has "fill gaps with smaller bricks" or "only this brick"
  (as many as fit; the rest left empty, and it says how many).
* **Wall thickness**: Walls and Sketch's walls: the brick's width, or 1, 2 or 3 studs.
* **Walls meet**: a wall's ends snap to the walls near them, and one drawn to meet another at
  the same height (a corner, or a T) joins it -- one shape, so the courses interlock. Its
  height starts at, and sticks to, the wall it meets.
* **Cut as Fusion 360**: press on a face, drag the profile, let go; click at once to cut
  through the wall, or drag for a depth first. Door and window stay one click. **Shapes** the
  same way: pressed on a wall's face, the shape is drawn on that face and drags out of it.

### More suggestions, not built -- pick what you want

1. **One Draw tool instead of four.** Shapes, Walls, Floor and Sketch are now the same thing:
   draw a base, drag it. One Draw tool whose pop-out has the outlines (line, rectangle, circle,
   ring, triangle, freehand, polygon) and "makes" (solid, walls, floor, building). Rail: 14
   tools down to about 9.
2. **Pick, Paint and Place as one hand**; **Builds into Select** (click anything: a shape or
   an inserted build). Rail down to about 7.
3. **Hand / Edit / View out of the rail**, into a thin bar across the top: the rail is then only
   tools, and never scrolls.
4. **The numbers at the cursor**: size and height beside the cursor while drawing, not in the
   rail. Type a number while dragging for an exact size, as Fusion does.
5. **Push-pull afterwards**: hover a placed shape's top and drag it to change its height; drag
   a wall sideways to move it. Select's numbers go.
6. **Draw on any face in Sketch** too, and draw cuts with the pen (a freehand hole).
7. **Windows stay with a building**: raise it later and new storeys get them.

### As built (2026-10-31)

"Being built" above, all of it, merged; `tools/build_tools_probe.gd` 178 checks.

* `WorkshopView` owns the mouse in the building workshop: the camera's click-to-capture is off
  there (`click_captures`, `ctrl_descends`). The asset workshop's camera is as it was, and so is
  its Esc. Esc pauses through `workshop.gd`'s `pause_allowed`, never over a test window or a gate.
* An RMB in orbit waits to see if it moves: moved, it looks round; a plain click is replayed to
  the tools on release. So Shapes' RMB-drag cut needs Cut or "Cut out" in orbit. With a drawing
  under way RMB cancels at once, as before.
* The pop-out is `ToolRail.pop_out` / `pictures`, only the building workshop's so far. Lists
  that are long or data-driven (Rooms' module rules) stay dropdowns.
* "Only this" is `strict` on a shape: `parts_for` gives just the held brick; a staggered course
  starts with a gap, not a half brick. The status line says how many cells stay empty.
* Walls join through `_commit_wall`: a joined wall is `points.more`, more lines in one shape.
  They must match in height, thickness, brick, colour, material and bond; a wall that differs
  stays its own, and its bricks go round the other's. Off while the mirror is on.
* `face_under` also gives `front` and `into`. Cut, a Shapes "Cut out" and a Shape pressed on a
  wall's side all start from `_begin_on_face`.

## 11. One Draw tool (2026-10-31)

Asked: Shapes, Walls, Floor and Sketch as one tool (section 10, suggestion 1). They had become
the same thing: draw a base, drag it up, click.

**Draw** (K, Alt D) has two rows of pictures in its pop-out:

* **Outline**: Line, Box, Circle, Triangle, Arch, Freehand, Brush, Corners.
* **Makes**: **Solid** (filled), **Walls** (along the outline, the thickness set), **Floor** (filled,
  and a click with no drag fills the walls round it), **Building** (walls and a floor each storey).

Any outline makes any of them: a Circle that makes Walls is a round tower (the old ring); a Box
that makes Walls is a room (the old hollow rectangle) and joins walls it meets; a Line that makes
Walls is a wall. Hollow and Ring leave the list for that reason, and Stairs (the Stairs tool
does it). It starts on Line and Walls. Old saves' shapes still lay.

Everything else is as it was: press, drag, let go, pull the height, click. "Draw on" (a set
level) now works for every outline. **Combine outlines**, ticked, keeps outlines of any kind in
one plan until Raise (or a click inside it); "Cut out" then takes area from the plan.

An RMB outside a drawing is now always the workshop's own (takes a brick away); cutting while
drawing is the "Cut out" button, or the Cut tool.

The rail: Place, Pick, Paint, Draw, Roof, Stairs, Cut, Repeat, Select, Builds, Rooms: 11 tools.

### As built (2026-10-31)

Merged; `tools/build_tools_probe.gd` 204 checks. Pick, Paint and Place, and the other section
10 suggestions, are still open.

* `set_outline` and `makes` are the tool's whole state; `_route` says how a drag goes (walls,
  floor, shape, cut). `_plan_record` is the one way from outlines to a `plan` shape, and a plan
  can now hold grid shapes as well as pen strokes (`BrickShapes._entry_cells`, `map_plan`).
* A Box that makes Walls is a closed `polyline`, so it joins walls it meets. Combined, it goes
  into the plan instead (a plan's walls do not join other walls).
* A Line that makes a Building is a wall: a line has no inside to floor.
* The level's grid is drawn for a set level or a plan being drawn, not while aiming.
* Hollow, Ring and Stairs are still kinds (old saves, `add_shape`), just not on the pop-out.

## 12. The rest of the list (2026-10-31)

Section 10's other suggestions, all of them:

* **Hand**: Place, Pick and Paint are one tool; its pop-out says which. Pick goes back to
  Place after a click.
* **Select takes inserted builds too**: click one, and Move, Copy, Delete are there. The Builds
  tool goes. Rail: Hand, Draw, Roof, Stairs, Cut, Repeat, Select, Rooms: 8.
* **A top bar** holds Hand, Edit and View's buttons, across the screen under the menus; the
  rail is only tools. The keys panel starts hidden (Keys shows it).
* **Numbers at the cursor**: the size while dragging a base, the height while pulling. While
  pulling, type a number for an exact height (plates; storeys for a building; studs for a depth);
  Backspace takes a digit back, Enter or a click places.
* **Push-pull** (Select): press on a kept shape's top and drag: its height follows, and letting
  go lays it. Press on its side and drag: the whole shape moves along that face's way. Select
  loses its height and rim numbers.
* **Windows stay with a building**: windows and doors "on every floor" are kept with the building;
  raised with push-pull, its new storeys get them; lowered, those above go.
* **Sketch on any face**: with a pen outline (Freehand, Brush, Corners), a press on a wall's
  side draws on that wall, as dragged shapes do; and **Cut** has Freehand and Corners.

### As built (2026-10-31)

All of it, merged; `tools/build_tools_probe.gd` 228 checks.

* `active()` still answers place, pick or paint; `rail_id` folds them into Hand for the rail.
  B still toggles the brush. Hand remembers which of the three it was on.
* The top bar is `ToolRail.actions(..., bar)`, in a `PanelContainer` the tools own; the rail,
  the keys panel and the readout start under it (`bar_height`).
* A typed number stops the cursor pulling until Backspace empties it; digits only go there while
  pulling, so 1-9 still pick the toolbar slot otherwise. A cut's or a shape's depth is in
  studs (plates through a floor).
* Push-pull is `begin_push_pull`, with `resize_shape` and `move_shape` doing the laying; each
  is one undo. The top must be the shape's own top layer. A standing shape only moves. A move
  takes along the frames and glass of the doors and windows cut in it.
* A building keeps `openings`, each as if on its first storey. `resize_shape` lays them on new
  storeys and takes off frames and glass above the new top; its cuts stay on the record (harmless
  above the top).
* Pen strokes on a face go through `_stroke_plane`; a stroke on a wall's side needs Solid (or Cut
  out). Cut's Freehand and Corners use the same pen.

## 13. Out of the way while placing (2026-10-31)

Asked: a button under the tools for the brick menu (Tab); and the pop-out takes too much of the
screen while placing.

* **Bricks** is a button under the tools, lit while the brick menu is open: it opens and
  closes it, as Tab does. All parts leaves the top bar.
* **The pop-out gets out of the way.** With a tool that places (Hand, Draw, Roof, Stairs, Cut) it
  shows when the tool is picked, goes as soon as the cursor moves out into the scene, stays gone
  while anything is drawn or pulled and in FPS, and comes back when the cursor points at the
  tool's button. Select, Repeat and Rooms keep theirs: their options are what they are for.
* What the tools say (the status line) lived in the pop-out; it is now a line over the toolbar
  at the bottom, so it stays when the pop-out goes.

## 14. Repeat copies a building, edits and all (2026-11-02)

Asked: a building should be drawn, decorated, then copied up with everything on it; a 3-storey
start raises by 3 storeys. Repeat "doesn't seem to repeat edits": should it be fixed, or a
Buildings tool added? **Fixed**: a Buildings tool would be Draw and Repeat again under a second name.

What it missed: its default, "the picked shape", copied only that shape (a building's holes, not
its frames, glass, stairs or hand-laid bricks). "A storey" asked for plate numbers. Neither
copied furniture or rooms.

* **What**: **Whole building** (the default), **One storey**, or **One shape**. A click on any
  brick of a building picks the building.
* **Everything goes with it**: its window and door cuts, frames and glass, stairs, floors, every
  hand-laid brick, inserted builds, furniture, and the rooms marked in it.
* **Up, it lands on top**: a building of 3 storeys, repeated once, is 6. It stays one building, so
  picking it again copies all 6 (a Times of 1 gives 12). One storey copies to the top, whichever
  storey it was. A flat roof goes to the new top, and what stands on the building (a roof, a
  setback) rises with it.
* Along X or Z it is a separate copy, a gap apart.
* **You see where it goes**: a box for each copy, and the numbers, before you press Repeat.
* One undo for all of it, and redo.
* Sideways bricks (on a bracket) only copy when the move lands on their own stud grid; the rest
  are left out, and it says how many.

### As built (2026-11-02)

Merged; `tools/build_tools_probe.gd` 257 checks.

* `_repeat_group(dir)` gathers; `_gather` takes what lies between two layers inside the picked
  thing's footprint, three studs round it, so a second building beside it is left alone.
* Up, a plan is not copied: `_raise_building` deepens it and copies the cuts in the band, so it
  stays one shape and Select's push-pull and Repeat go on working on all of it.
* A building's picked by any brick within two studs of its plan; One shape picks just that.
* Walls with no plan (Draw's Walls, not Building) copy as separate shapes on top, a storey being
  their own height; the shapes and bricks inside their footprint go with them.
* A shape only partly in the band (a building's walls, for One storey along X or Z) is copied as
  plain bricks. Going up it stays part of the building.
* Rooms copied are seeded in the copy and found again from the bricks, so a door's kind set by
  hand in a room comes back as what the bricks say. Marks and points are not copied.
* Later edits do not follow: a copy is a copy. Edit first, then Repeat.

## 15. Six-brick storeys and a build area of a thousand bricks

Asked 2026-11-02: a storey is 6 bricks tall, not 4; the workshop 1000 bricks tall and 1000 x 1000
wide.

**Storey.** A storey's wall band is 6 bricks (18 plates), whatever is held: a plate in the hotbar
used to make it 4 plates. The floor stays one plate on top, so floors are 19 plates apart. That
matches the city's towers, whose floors stand six bricks apart. A door was 18 plates plus a 3-plate
head, which no longer leaves a wall in the band: it is 15 now, so head and door fill the band.

**Area.** 1200 x 1200 studs by 3000 plates (1000 bricks), up from 48 x 48 by 120. Not 1000 wide:
the six grids are one volume, and that only holds for a cube in ticks (Workshop.height_plates), so
wide follows tall. 350 m would leave a sideways grid short of the top.

What the size breaks, and the answer to each:

* **Memory.** Six dense grids of 4.3 billion cells cannot be allocated. They page, as the asset
  workshop's do (Docs/AssetWorkshop.md); an old brick library falls back to 96 studs with a warning.
* **The floor.** Every edit remeshes every grid whole, so a floor of real plates (14,400 of the
  biggest, 1.4 million studs) would slow each brick. The floor is one quad with drawn studs, not
  bricks: a brick on the bottom course counts as clipped to it, and the stress solve's foundation
  is that course.
* **The grid.** A line per stud at this size draws nothing but a grey square: it is a window of
  120 studs round the ghost, redrawn as the ghost walks.
* **Rays.** `_first_hit` marched 120 m through six grids a step at a time. It marches only through
  the boxes of the grids that hold bricks, as far as they go.
* **The camera.** Far plane 2500 m. A new build starts in the middle of the area, framed as the old
  plate was; loading a build frames the build, since old ones sit in the corner. The wheel's step
  grows with the distance.
* **Old builds.** Upright bricks keep their cells. A sideways grid in an old save sits where the
  small volume put it, so loading adds a grid there rather than losing its bricks.
* **Walls that close.** The flood that finds a floor stops at the build's box: past that it is open
  ground, so it no longer needs a cell limit that a big building would hit.

### As built (2026-11-02)

Merged; `tools/build_tools_probe.gd` 274 checks, workshop gate 19.

* A floor hit is `{floor: true, block: -1}` in frame 0: ask `hit.block >= 0` before asking the world
  about it. Its point is just inside the floor, as a hit's was in a plate. The room finder sees
  y = 0 as solid.
* Space is no longer the limit; edits are. Every edit remeshes every grid whole. Rough timings,
  headless, other runs possibly going: 11,900 bricks 240 ms a brick, 89,000 bricks (a 20-storey block
  80 studs wide) 2 to 4 s a brick, of which a remesh is 2 s (the chamfer mesh 0.7 s, the rest mostly
  building the ArrayMesh). Laying a whole shape is one remesh, so it is hand placing that suffers.
  Section 16 is the answer.

## 16. Edits that cost what they touch

Asked 2026-11-02, after section 15's timings: a brick placed on a big building should not take
seconds. Every edit rebuilt every grid: at 89,000 bricks the bake 0.7 s, the chamfer 0.7 s, the
ArrayMesh 0.5 s, and side studs walked the whole build six times.

The engine can already cut a chunk into sections, tiles of `section_studs` by `section_plates`,
and the city draws a mesh a section. That is not enough here: a section's mesh is a slice of a bake
of the whole chunk, and any new brick throws that bake away. So:

* **A bake of one section.** `bake_faces_into` takes the blocks to bake. A block's faces depend on
  the cells round it, not on the other faces, so this is the same faces as a slice would be.
  `build_sections_chamfer_mesh` bakes the sections' blocks, chamfers them, and leaves the chunk's
  own bake alone.
* **The engine says what changed.** `take_changed_sections(chunk, margin)` stamps every block
  (place, part, colour, material, alive) and compares with the stamps it kept last time, so no
  edit path has to remember to report itself. A change marks the sections its box touches, grown by
  `margin`: a brick changes the faces and bevels of the bricks round it, and those may be in the
  next section. A block is drawn by the section its lowest cell is in.
* **Script.** A grid's node keeps its transform and holds a child mesh, with its studs, for each
  section that has bricks: `_remesh` rebuilds only what the engine names. Sections are 48 studs by
  60 plates, so a tall building is a few hundred meshes, and a section out of view is not drawn.
* **Old library.** Without these calls the workshop meshes whole as before. The asset workshop
  stays whole too: its builds are small and it reads the meshes in other ways.

### As built (2026-11-02)

Merged; `tools/build_tools_probe.gd` 291 checks. Its `_sections_match_whole` compares what the
sections draw with one mesh of the whole grid, vertex and colour, after each kind of edit and across
section lines.

Rough timings on one 89,061-brick building (headless, 63 sections): a brick against it 30 to 43 ms,
was 2 to 4 s; a brick off on its own 4 ms; undo 34 ms. Laying the whole building at once is still
about 15 s, nearly all of it in GDScript working out and laying the bricks, not in meshing.

Other things to know:

* A grid's node (`_frame_meshes`) has no mesh of its own now, only children. Ask `_frame_box(f)`
  for what a grid fills and `_sections[f]` for its meshes.
* `_frame_studs` is keyed by `Vector2i(chunk, section)` here and by chunk id in the asset workshop.
* The workshop no longer makes `chunk.bake` at all, so `update_chamfer_regions` and the like have
  nothing to read in it. Nothing here wants them: `take_changed_sections` is its way of patching.
* The library has to be rebuilt for this; without it the workshop falls back to meshing whole.

## 17. Whole buildings as fast as bricks

Asked 2026-11-02: laying whole buildings, placing prebuilt ones and adding storeys should be quick.
Measured on a 29,000-brick block (six storeys, 80 studs wide), section 16 in:

| | |
|---|---|
| Lay it | 3 s: the packer 1.5 s, meshing 0.6 s, placing the bricks only 0.17 s |
| Undo that | 103 s |
| Add its height again with Repeat | 85 s |

Undo and storeys are quadratic, so at 89,000 bricks they are many minutes. Three causes:

* **Finding a brick walks the build.** `_recipe_id_at` is a scan of `_placed_at`, and taking a shape
  up asks it once per brick. It becomes a map, kept up to a watermark: an append needs nothing, a
  removal lowers the watermark and the next look-up mends only what moved.
* **Taking a brick up shifts everything after it.** `remove_rids` takes many at once in one pass,
  in `_placed_at` and in the recipe (`remove_many`).
* **The packer walks every cell left for every layer**, and sorts in script. It buckets by layer
  once and sorts numbers. A cell's runs were counted to 64 cells each way, when what is asked of them
  is only whether they pass two brick widths: they stop there, with the same answer.

And work that need not be done at all:

* **Adding storeys keeps the storeys already there.** `_lay` with `near` already knew how to leave
  a shape's other bricks alone, for cuts. Repeat and push-pull lay from just under the old top. A
  course's bricks depend only on its layer and the cells round it, so what stands is what a fresh lay
  would give; a probe compares the two.
* **Undo keeps what both versions share**, and only moves the difference.
* **A door on every floor is one cut, not one a floor**: one `_lay` over the column they stand in.
  `shape_cells_in` works out a shape's cells inside a box, so a cut in a big building does not pay
  for the whole building. Records stop deep-copying `bricks` when nothing changes them.

The packer's output must not change: it is checked against what it gave before, shape by shape.

Meshing is what is left, so it goes side by side: baking and chamfering a section read the chunk and
write only their own bake, so `build_sections_chamfer_mesh` hands sections to up to eight threads.
A saved file over 5,000 bricks has no indents: a number a line was most of the time saving took.
Undoing a stamp, and deleting a group, take their bricks up at once: one at a time, each was an edit.
A stamp whose box is clear of every grid's bricks fits without asking about each brick, and a big one
is carried as a plain ghost.

### As built (2026-11-02)

Merged; `tools/build_tools_probe.gd` 323 checks. `_books_agree` holds the recipe against the world
brick by brick after each big edit; made taller is compared with the same building made that tall at
once. The packer's output was compared with the old one on twelve shapes, and is identical.

Rough timings on the 89,061-brick block, headless, on the thread count of a Legion Go:

| | Section 16 | Now |
|---|---|---|
| Lay it | 15 s | 2.5 s |
| Undo that | many minutes (103 s at 29,000 bricks) | 0.55 s |
| Redo that | | 1.2 s |
| A storey more, push-pull | many minutes | 0.5 s |
| A window on every floor | | 0.85 s |
| Copy it along, Repeat (94,000 bricks, 85 shapes) | | 3.6 s |
| Save | 11 s | 0.35 s |
| Open a saved one | | 1.6 s |
| Drop it from the hand (a stamp) | | 2.3 s |
| Undo the drop | never finished | 0.15 s |

What is left of laying is the packer, about 1.2 s of it, in script. Moving it to the engine would
halve laying, at the price of keeping two copies of it while old libraries are about.

Other things to know:

* `shifted` empties a shape's `bricks`: a copy gets them from `_add_copy`, which lays what the source
  has and only packs if something is in the way. A copy is the same bricks, so a phase that depends on
  where it stands (`pack_courses`, a run's first half brick) is the source's until it is cut.
* Undoing a stamp no longer leaves its bricks on the redo list: undoing a stamp was always meant to
  forget (`_undo_step`).
* `_recipe_id_at` is a map now, mended up to `_rid_synced`. Anything that takes from `_placed_at`
  lowers it; appending needs nothing.
* A saved file of 5,000 bricks or more has no indents.

## 18. The packer in the engine

Asked 2026-11-03 ("please continue", after section 17 named it as what was left): the packer is
about 1.2 s of the 2.5 s it takes to lay the 89,000-brick block, in script.

* `BrickWorld.pack_courses` is `BrickShapes.pack_courses` in C++, line for line: the same buckets,
  runs, half-brick starts and scores, the same order, so the same bricks.
* `BrickShapes.pack_courses` calls it when the library has it, and `pack_courses_script` (the old
  body) when it does not. Two copies of one rule is the price; `build_tools_probe` pays it down by
  packing a spread of shapes both ways and asking for the same bricks, so they cannot drift apart
  unnoticed.

And a fix found on the way: `world` is typed `BrickWorld`, so a call to a method an older library
lacks does not fall back, it fails to compile. Section 16's calls go through an untyped handle, and
the packer through `ClassDB.class_call_static`, so a stale library meshes whole and packs in script as
section 16 said it would.

### As built (2026-11-03)

Merged; `tools/build_tools_probe.gd` 325 checks. Its packer check lays twelve shapes both ways and
gets the same bricks in the same order; they are also the bricks the packer gave before section 17.

On the 89,061-brick block's 252,981 cells, three runs: the script 721 to 765 ms, the engine 229 to
264 ms. Whole operations were not timed again: another chat was running a planet gate and probes and
the chip reached 99 C, so they would say more about the machine than the change.

The fallback for an older library could not be run: no older library is left that has section 15's
paging but not these calls. It rests on the calls being untyped or through `class_call_static`, which
compile either way.

## 19. Far away, laid over frames, and the loose ends

Asked 2026-11-05: the five things section 18 left open are all to be done.

* **Floors two plates, as the city's.** A building's floor (and its flat roof) is
  `TowerRecipe.SLAB_PLATES` thick, so a storey is 18 plates of wall over 2 of floor and storeys are 20
  plates apart, as the city's towers. The Floor tool starts at two plates too.
* **The asset workshop draws in sections too.** `_draws_sections` no longer asks for the building
  workshop's tools.
* **A big change is drawn over frames, nearest the camera first.** The engine names the sections
  that changed; they go in a queue, and each frame meshes as many as there are threads (8). Edits
  that reach no more than that are drawn at once, as before. A ray still finds bricks not drawn yet:
  a grid's box takes in the queued sections. Off headless, where a probe looks straight after an
  edit (`mesh_over_frames`).
* **Far sections are cheap.** As the city does it (BrickNear): a section within `BrickNear.radius` of
  the camera is chamfered, past it flat with the seams drawn by the shader (`geo_bevel` 0); studs are
  drawn to `STUD_RANGE`. A section that crosses the line goes back in the queue to be meshed the
  other way, with the city's margin so it does not flicker. Off headless (`draw_far_flat`).
* **The fallback for an older library, run.** A build of this library without its newer calls bound,
  and the probes on it: the workshop must load, draw whole and pack in script.

### As built (2026-11-05)

Merged; `tools/build_tools_probe.gd` 338 checks, workshop gate 19, asset workshop probe 343.

* **Far away.** Three 20-storey blocks 80 studs wide (476,406 bricks, 147 sections) seen from across
  the area, the renderer's own clock, twice each way, other chats' headless runs going:

  | | GPU a frame | Primitives |
  |---|---|---|
  | Every section chamfered, every stud drawn | 771-781 ms | 203 million |
  | Far sections flat, studs to 40 m | 16-34 ms | 7.6 million |

* **Stud culling no longer asks the renderer.** `_stud_lod` read each MultiMesh's box, a renderer
  read-back every frame (Docs/WhereWorkRuns.md), and empty headless. It uses the boxes kept here, and
  only looks again when the camera has moved or studs were made.
* **The stud count went to nought** whenever a remesh found nothing changed; it is counted after
  every one now.
* **Floors.** `WorkshopTools.floor_plates`, the city's two. The older probe checks set one: their
  heights were written for it, and they test what they test either way.
* **The old library, run.** This library built without its five newer calls bound: the workshop
  loads, meshes whole and packs in script; building, storeys, undo and the asset workshop pass, and
  only the checks about sections fail, with one line saying to rebuild.

## 20. One editor kit for both workshops (plan, 2026-11-06)

Asked 2026-11-06: turn the two workshops' tools into one shared, modular editor kit that both use,
and that can be copied into another Godot project and kept in sync. In stages, each merged on its
own. **This section is the plan; stage 1 is built (see "As built" at the end).**

### Today (main `874edd82`)

* `asset_workshop.gd` (12,399 lines) **extends** `workshop.gd` (4,454) and overrides 26 of its
  functions (`_ready`, `_process`, `_input`, `_unhandled_input`, `_aim`, `_mouse_ray`, `_place`,
  `_undo`, `set_mirror`, `mirror_here`, `_after_edit`, `_load_recipe`, `_write`, ...; 17 `super`
  calls) and reads ~45 of its variables (`recipe` 221 times, `world` 44, `mirror_z` 46, `_camera` 71,
  `_edits` 30). No tool stands alone: a tool is functions spread over the two classes.
* `workshop_tools.gd` (3,543) is the building workshop's tools in one class (Draw, Roof, Stairs,
  Cut, Repeat, Select, Rooms and the actions).
* Shared already (section 0): `ToolRail`, `SketchPen`, `BrickShapes`, `WorkshopHotbar`,
  `BrickPalette`, `paint_palette.gd`.
* **Undo is six stacks.** The base keeps `_edits` (a list of kind names: "brick", "shape", "paint",
  "stamp", "tower", "ungroup", "furnish", "fixture"), `_brick_groups`, `_redo_list`, `_paints`,
  `_tower_undo`, `_fixture_blocks`; `WorkshopTools` its own `_undo`; the asset workshop adds
  `_edit_groups`, `_redo`, `_stud_log`, `_deleted` and sketch snapshots, and calls the base's
  `_undo` for bricks. One rule holds them together: **a brick is only ever undone from the end**
  (taking one out of the middle renumbers every block after it). Stamp, tower, fixture and ungroup
  undo but do not redo. The building workshop's RMB delete is not undoable; the asset's is.
* **Two of everything else:** mirror (`set_mirror`/`mirror_here` in both, `mirrored_x/z` in the
  base), camera (`WorkshopView` orbit/FPS in the building workshop; the asset's own flat views
  `set_view` and `_zoom_input`), selection (kept shapes and groups; the asset's box select and
  model pick), menus (`WorkshopMenu` vs `AssetWorkshopUI`, neither on `menu/core/MenuTheme.gd`).

### What it becomes

A folder **`addons/workshop_kit/`**, built the way `menu/` is (menu/docs/01_menu_system.md): no game
class inside, a seam the game fills in, its own docs and test.

```
addons/workshop_kit/
  README.md            what it is, port steps, how to keep it in sync
  VERSION              0.1.0, raised with every change merged here
  core/
    wk_undo_stack.gd   WkUndoStack: push / undo / redo, groups, merge, a "can't redo" command
    wk_command.gd      WkCommand: do(), undo(), merge(next) -> bool, can_redo(), label
    wk_context.gd      WkContext: THE SEAM -- every game call, each a neutral default
    wk_tool.gd         WkTool: activate(ctx), deactivate(), input(e) -> bool, process(dt),
                       options_ui() -> Control, hint() -> String, id / label / key / icon
    wk_toolbox.gd      WkToolbox: the tool list, which is in hand, input routed to it, keys
  services/
    wk_camera.gd       WkCamera: orbit, fly, flat views (side/top/front), zoom to cursor
    wk_mirror.gd       WkMirror: the plane (axis, offset, on), its gizmo, the toggles
    wk_grid.gd         WkGrid: the grid overlay on the working plane
    wk_ghost.gd        WkGhost: the preview node, valid/invalid tint; its mesh from the context
    wk_shapes.gd       WkShapes: cells of a rectangle, ring, ellipse, polygon... (today BrickShapes'
                       cell half; packing cells into bricks stays game-side)
    wk_sketch_pen.gd   WkSketchPen (today SketchPen, unchanged)
  tools/               one file per shared tool
    wk_place_tool.gd   place and the held-click run     wk_erase_tool.gd
    wk_paint_tool.gd   wk_select_tool.gd                 wk_shape_tool.gd  (Draw / Shapes)
    wk_sketch_tool.gd  wk_cut_tool.gd                    wk_measure_tool.gd
    wk_move_tool.gd    wk_fill_tool.gd (wand)            ...
  ui/
    wk_frame.gd        WkFrame: menu bar, rail, option panel, outliner, hint line
    wk_rail.gd         WkRail (today ToolRail)
  tests/
    wk_smoke.gd/.tscn  headless: undo stack, toolbox routing, a fake context driving each tool
```

* **The seam is `WkContext`**, as `MenuHost` is for the menus. The kit never names `BrickWorld`,
  `BuildRecipe`, `BrickPalette`, `PlayerCamera`, `MenuTheme` or any other game class; it calls the
  context: cell and grid math (`cell_size`, `world_to_cell`, `cell_to_world`), the pick ray and
  what it hit, the ghost's mesh, `place_cells(cells)` / `remove_cells` / `paint_cells` **in arrays**
  (one call per edit, never one per cell), the selection, the held item, `mirror_item(item, plane)`
  (a brick's footprint and turn are the game's), `capture_mouse(on)` (so `PlayerCamera.hands_off`
  stays the game's rule), and `theme() -> Theme` (this game answers `MenuTheme.theme()`). Each
  workshop has one adapter: **`BrickWorkshopContext`** in `scripts/workshop/`.
* **A workshop = a tool list + its adapter + its own tools.** Asset: SDF sculpt, parts, photos,
  guides, studs, connection points, guns, mech, export. Building: Roof, Stairs, Repeat, Rooms,
  doors and windows, storeys, generate. Those are `WkTool`s too, one file each, but under
  `scripts/workshop/tools/` -- they name game classes, so they stay out of the kit.
* **One tool, two outcomes.** Where both workshops have a tool that does the same drawing and a
  different result (Shapes, Sketch, Cut, Select), the kit tool does the drawing and hands the
  result to the context (`ctx.commit_shape(spec)`, `ctx.commit_outline(outline, plane)`): the asset
  fills its part, the building makes a kept shape -- as `SketchPen` already works.
* **Undo.** Every edit is one `WkCommand` pushed to the one `WkUndoStack`. A run, a mirrored pair,
  a fill are a group (`begin_group` / `end_group`) and undo as one. A command whose `can_redo()`
  is false (stamp, tower, fixture, ungroup today) clears the redo list when undone, as now. The
  stack is strictly last-in-first-out, which is what keeps the brick-from-the-end rule.
* **Hot loops stay where they are.** The kit routes input events and one call per frame; brick
  packing, meshing, the run's per-cell loop and section drawing stay inside the game objects that
  do them now.

### Keeping it in sync between projects

Recommended: **its own repository, brought in with `git subtree`.** The kit's files are committed
in this repo as ordinary files under `addons/workshop_kit/` (so every worktree has them, Godot sees
plain files, nothing to junction -- the godot-cpp submodule's worktree trouble does not come back),
and the kit's repo is a remote:

```
git subtree pull --prefix addons/workshop_kit kit main --squash   # take the kit's changes
git subtree push --prefix addons/workshop_kit kit main            # send ours back
```

Another project does the same with its own prefix. A submodule would also work but needs
`git submodule update` in every worktree and clone, and this repo's worktrees already trip on the
one it has. Until there is a second project, the kit lives here only; the README says how to split
it out (`git subtree split --prefix addons/workshop_kit`) when that day comes. **VERSION** is raised
with each change to the kit, so two projects can see which is newer.

### Stages

Each stage: own branch, merged `--no-ff`, pushed. Every stage passes, as on main: the workshop gate
(`res://scenes/workshop.tscn -- --gate`, windowed: heat log after), `place_probe`,
`city_place_probe`, `palette_probe`, `shaped_probe`, `scale_probe`, `build_tools_probe`,
`workshop_probe`, `workshop_spaces_probe`, `asset_workshop_probe`, `asset_ui_probe`,
`mech_workshop_probe`, and from stage 1 on the kit's `wk_smoke`.

| Stage | What | Check |
|---|---|---|
| 1 ✅ | Kit folder, README, VERSION, `WkCommand`, `WkGroup`, `WkUndoStack`; every undo list in both workshops (`_edits`, `_brick_groups`, `_redo_list`, `_paints`, `_tower_undo`, `_stamp_marks`, `_ungrouped`, `WorkshopTools._undo`, the furnish tool's, and the asset's `_edit_groups`, `_redo`, `_stud_log`, `_deleted`, sketch snapshots) becomes commands on one stack, `ws.undo_stack` | `wk_smoke` (the stack alone); every probe above. Planned as 1a (building) and 1b (asset); done as one, because the asset workshop's undo read and wrote the base's list |
| 2a ✅ | `WkTool`, `WkContext`, `WkToolbox`; `BrickWorkshopContext` (`scripts/workshop/brick_context.gd`) for both; SketchPen -> `WkSketchPen`, and the stroke handling of both workshops' sketching into **`WkSketchTool`** | probes; `wk_smoke` drives the tool through a pretend context |
| 2b ✅ | **Paint** into a kit tool: the stroke (press, drag, release as one undo), the brush's reach, pick a colour; what a brick's colour is stays the workshop's | probes; `wk_smoke` |
| 2c ✅ | **Shapes**: the grid geometry (`BrickShapes`' rectangle, ellipse, ring, polyline, region cells) into `WkShapes`; packing cells into bricks and kept shapes stay game-side. The Shapes *tool* goes with Draw/Cut/Select in stage 5: the two workshops' gestures differ (asset: drag a box, ball, cylinder or wedge and fill it; building: draw an outline, then pull its height), so one tool needs a design choice first | probes; `wk_smoke` cells checks |
| 3a ✅ | `WkMirror`: the plane (on, axis, x, z) and its cell arithmetic; both workshops' mirror state is it, through properties | probes; `wk_smoke` |
| 3b ✅ | `WkCamera`: WorkshopView's orbit, pan, zoom to the cursor and click-or-drag, and the asset workshop's flat views (side, top, front; orthographic zoom at the cursor). The FPS fly stays the game's camera, behind the context (no new fly code) | probes; gate pictures as before |
| 3c ✅ | `WkGrid` (the grid overlay) and `WkGhost` (the preview node and its valid/invalid tint; its mesh from the context) | probes; gate |
| 4a ✅ | `WkRail` (ToolRail moved into the kit) in both workshops, with the game's look through the context (`style_ui`, `panel_box`: `GameUI`, on `MenuTheme`) | probes, gate |
| 4b ✅ | `WkFrame` for the building workshop: the menu bar (`WorkshopMenu`'s menus as data the workshop gives), the rail, the option panel and the hint line, laid out and themed in one place | `workshop_probe`, gate |
| 4c ✅ | The asset workshop's tabs, outliner and actions on `WkFrame` | `asset_ui_probe` |
| 5a ✅ | **Place** (the hand: click, held-click run, RMB takes away) into the kit, the toolbox's default tool and the hand under any tool for a click it does not take | probes, gate |
| 5b ✅ | The rest of the shared tools into the kit, one file each: measure, fill (wand), move, select, and the Shapes tool -- one tool, two gestures (asked 2026-11-08: the asset workshop's one drag, the building workshop's outline then height); Cut is the Shapes tool with a cut for its outcome. The building workshop's RMB delete is undoable (asked the same day) | probes; `wk_smoke` per tool |
| 6a | Each of the 26 overrides becomes a context call or a tool (the asset still extends) | probes |
| 6b | **No more `extends workshop.gd`**: the brick world, recipe, frames, save and load in one component both workshops own; each workshop `extends Node3D` and composes the kit | every probe, gate; a scan finds no game class named under `addons/workshop_kit/` |

Done when both workshops run on the kit, each shared tool is one file under it, the kit names no
game class, the probes and gate pass as on main, and section 0 describes the kit.

### Open questions

* **Name.** `addons/workshop_kit/`, classes `Wk...` (short, and no clash with `KitFurnish` or
  Godot's `Editor...` classes). Another name is a rename now, a long one later.
* **FPS fly in `WkCamera`.** The building workshop flies on the game's `DebugCamera` today. The kit
  cannot name it, so `WkCamera` gets its own fly (WASD, Space, Q/Ctrl, Shift fast, Alt slow); it
  should feel the same but is new code. Alternative: the fly stays the game's, behind the context.
* **The building workshop's RMB delete** -- settled 2026-11-08: undoable, as the asset
  workshop's already was (stage 5b). Z lays the brick back on the end of the build, not at its
  old index (the stage 1 history finds bricks by part and cell, so the order does not matter).

### As built: stage 1, one undo (2026-11-07)

`addons/workshop_kit/` 0.1.0: `WkCommand`, `WkGroup`, `WkUndoStack`, README (port steps, `git subtree`
sync), `tests/wk_smoke.gd` (35 checks, headless). Both workshops keep one `undo_stack`; every edit is
a command on it, made with `WkCommand.make(kind, data, undo_fn, do_fn)` -- the workshop keeps the
logic, the command its data. What changed underneath, and the few things that behave differently:

* **A brick's edit holds its recipe id**, moved down whenever bricks leave from the middle
  (`_forget_rids`, called before they go). The old list held only the word "brick", and undo popped
  the newest brick whoever's it was; it worked by counting, so a brick laid back by an undo (an RMB
  delete undone, a cut undone, a lifted group put back) went with the next Z whatever that Z was for.
  Now each Z takes back its own edit's brick.
* **An edit outlives its brick leaving** (RMB, a cut): it remembers the brick by part and cell, and
  if an undo lays that brick back, the edit finds it again. An edit with nothing left to take back
  is skipped (`WkCommand.alive`), so Z never does nothing. *Different:* in the asset workshop, Z
  after undoing a delete goes on to the edits before it (the old list took the laid-back brick away
  again first). `asset_workshop_probe`'s check for it now expects that order.
* **An opened build's bricks have no command each.** The old list held a word per brick of the file
  so Z could go on into it; a command each would be ~3 µs a brick (1.4 s on a 476,000-brick build)
  and a scan of them all on every RMB. Instead `undo_stack.on_empty` calls `_undo_opened` once the
  history runs out: the file's fixtures, then its bricks, newest first, one a Z, as before. The
  gate's check for it reads `_opened_bricks` and `_opened_fixtures`.
* **An insert (stamp) or a bake is one command** with where the recipe's lists stood; its bricks
  have no edits of their own (they had one each, popped together).
* **T (turn the last brick)** takes it up and lays it again turned under the same edit, rather than
  going through undo -- which after a run took the whole run back.
* **Redo** is the stack's for everything that has a `do`: bricks, shapes, deletes, studs, sketch
  and model changes. Paint, fixtures, inserts, generated buildings, lifted groups and furniture
  undo but do not redo, as before; undoing one forgets the redo list.
* Gathered edits (`_begin_gather`/`_end_gather`) are a group begun and ended on the stack, flattened
  so the groups made inside it undo as one, in the order they were made, with their sketch
  snapshots after (`WkGroup` tails).

### As built: stage 2a, the tool seam and Sketch (2026-11-07)

Kit 0.2.0: `WkContext` (the seam, every method a neutral default), `WkTool`, `WkToolbox`,
`WkSketchPen` (was `SketchPen`, `scripts/workshop_sketch.gd`, unchanged inside) and `WkSketchTool`:
press, drag and release (or click corners of a polygon), RMB to take away or -- with `rmb_cancels`
-- to give the stroke up. `wk_smoke` 49 checks.

* **One tool, two outcomes, as planned.** Where the stroke lies and what it becomes are asked of
  the context: `sketch_begin` (the plane, or null to refuse), `sketch_point`, `sketch_removes`,
  `sketch_commit`, `sketch_cancel`. `BrickWorkshopContext` hands them to `ws._sketch_host()` (as `wk_sketch_begin` ...): the
  building workshop's tools (a kept shape, a plan, a cut) or the asset workshop itself (a part's
  sketch).
* The building workshop has no Sketch tool of its own any more (section 11 folded it into Draw):
  the kit tool is taken up while Draw is on an outline or Cut is on the pen, and put down
  otherwise. In the asset workshop it is taken up with Sketch (not its sculpt brush).
* `WorkshopTools.pen`, `_sk`, `brush_size` and `brush_square` are the tool's, through
  properties, so the probes and the option buttons read and set them as before. The probes now
  finish a stroke through the tool (`t.sketch.commit()`), the path a mouse takes.

### As built: stage 2b, Paint (2026-11-07)

Kit 0.3.0: **`WkPaintTool`** -- LMB press, drag, release is one stroke; MMB takes a paint; - =
the brush's reach (`radius`, held to `radius_max`); Page Up/Down the next or previous paint.
Each frame it asks the context to show the brush (`paint_hover`) and, while LMB is held, to
paint on (`paint_at`). `wk_smoke` 58 checks.

* The brush is the same in both workshops (the asset workshop inherits it), so
  `BrickWorkshopContext` sends every paint question to the workshop itself: `wk_paint_begin`
  (a new stroke), `wk_paint_at` (`_paint_ray` down the mouse ray), `wk_paint_end` (`_end_stroke`,
  one "paint" command), `wk_paint_hover` (the ghost box or reach ball, was the top half of
  `_paint_process`), `wk_paint_pick` (the eyedropper), `wk_paint_step` (the palette's next
  material), `wk_paint_radius_changed`.
* B (`_set_painting`) takes the tool up and puts it down; `_paint_radius` is the tool's, through
  a property, so the option spinners and the asset workshop's brush size set it as before. The
  base input's own LMB-paints, - = and Page Up/Down branches are gone: the tool takes them.
* The Sketch tool is put down only when it is the one in hand, so taking up one never drops
  the other mid-stroke.
* `place_probe` +4: the brush is the tool, = through the workshop's input widens it, a stroke
  through the tool is one undo, B puts it down.

### As built: stage 2c, grid shapes (2026-11-07)

Kit 0.4.0: **`WkShapes`** (static, no editor classes) -- `cells_2d` (rect, hollow, jamb, circle, ring,
triangle, line, arch, stairs, outline, cells, polyline, plan), `polyline_cells`, `outline_cells`,
`plan_region`, `entry_cells`, `ring`, `to_3d` / `from_3d`, `in_ellipse`, `segment_dist`, `v2i`, and
`KINDS`, `LIES`, `STAIR_STEP` (3: a step every three cells up -- three plates in this game).
`wk_smoke` 68 checks.

* Moved out of `BrickShapes` unchanged inside, by a script: its calls, `WorkshopTools`' and
  `build_tools_probe`'s now name `WkShapes`. The private helpers other files used became public
  (`_v2` -> `v2i`, `_in_ellipse` -> `in_ellipse`, `_segment_dist` -> `segment_dist`,
  `_entry_cells` -> `entry_cells`).
* `BrickShapes` keeps what is bricks: `aspect` (plates against studs), kept shapes' cells and cuts,
  plan bands, roofs, reflections, shifts, parts and course packing. `BrickShapes.KINDS` and `LIES`
  are the kit's.
* The Shapes *tool* is stage 5's, with Draw, Cut and Select.

### As built: stage 3a, the mirror (2026-11-07)

Kit 0.5.0: **`WkMirror`** -- `on`, `axis` (0 across X, 2 across Z), `x`, `z`, a `changed` signal;
`turn_on(cell)` (a plane never set starts at the cell), `mirror_cell(cell, size)`, `mirror_dir`
(a front turned across the plane), `through(cell, size)` (the plane through a thing's middle),
`across` / `mirrored_x` / `mirrored_z`. `wk_smoke` 75 checks.

* The workshop's `mirror_on`, `mirror_z`, `mirror_x`, `mirror_axis` are properties on `ws.mirror`,
  so the asset workshop's own `set_mirror`, `mirror_here`, `set_mirror_z` and its sheet, and the
  building workshop's tools and their reflected shapes, read and set them as before.
  `mirrored_z`/`mirrored_x`, `set_mirror`, `mirror_here` and `_place_mirrored` use it.
* What a mirror image *is* stays the game's: a brick turned to face the other way
  (`_place_mirrored`), a kept shape reflected (`BrickShapes.reflected`). The drawn plane (the asset
  workshop's sheet, the building workshop's lines) stays each workshop's for now: both are drawn
  round the build's own box.

### As built: stage 3b, the camera (2026-11-07)

Kit 0.6.0: **`WkCamera`** -- `scripts/workshop_view.gd` (WorkshopView) moved into the kit, its
workshop calls turned into context questions (`camera`, `camera_ray`, `camera_hit`,
`camera_captured`, `camera_set_captured`, `camera_drive_keys`, `camera_busy`, `camera_rmb_free`,
`camera_wheel_free`, `camera_click`, `camera_replay`, `camera_wheel_shift`, `camera_flat`), and the
asset workshop's flat views added: `flat(view, centre)`, `perspective()`, `zoom_flat`, `zoom_at`,
`ortho_size`. `wk_smoke` 86 checks (a real Camera3D: orbit, zoom, clicks handed back, FPS, flat
views and back). The smoke test now runs from `_initialize` so a node can be in the tree.

* **The fly stays the game's** (section 20's open question, settled the cheap way): FPS and the
  keys flying with the cursor free are the workshop's DebugCamera; the kit only says when the
  mouse is taken and when the keys fly. No new fly code, nothing feels different.
* The building workshop's tools keep `view` (now a `WkCamera`), set up with the workshop's
  context; the DebugCamera's `click_captures` and `ctrl_descends` are turned off where it is made.
* The asset workshop does not take up orbit or FPS (that would change how it handles): its
  `set_view`, `zoom` and `zoom_at` are `cam_ctl.flat` / `perspective` / `zoom_flat` / `zoom_at`,
  and `_ortho_size` is the kit camera's, through a property.

### As built: stage 3c, grid and ghost (2026-11-07)

Kit 0.7.0: **`WkGrid.lines(window, cell)`** -- the overlay's faint lines and a stronger one every 4
cells, as an ImmediateMesh in the node's XZ plane -- and **`WkGhost`** -- the see-through preview
node and its material, `place(mesh, xf)`, `fits(ok)` (the cyan and red), `tint`. `wk_smoke` 90.

* The building workshop's `_build_grid` places the node and draws `WkGrid.lines`. One difference:
  the stronger lines across were counted from the window's x; each direction now counts from its
  own edge, so both fall every 4 studs from the build's corner.
* The workshop's `_ghost` and `_ghost_material` are the kit ghost's node and material, so every
  place that sets the ghost's mesh, place or colour (both workshops, the furniture tool) is as it
  was; "does not fit" is `ghost.fits(false)`. The layer tints (structure, interior, detail) and
  the ghost's studs stay the workshop's.
* The asset workshop's working plane (its grid in three views, the photo grid) stays its own: it
  is drawn round the build and the flat view in use, not a window round the ghost.

### As built: stage 4a, the rail (2026-11-07)

Kit 0.8.0: **`WkRail`** -- `scripts/workshop_rail.gd` (ToolRail) moved into the kit unchanged
inside, plus `restyle(panel)`; `WkContext.style_ui(root)` and `panel_box()` (neutral: the rail's own
look).

* Both workshops' rails take the game's look: `BrickWorkshopContext` answers with the game's UI
  kit -- `GameUI.style` (the menus' Theme, put on again when the text scale or high contrast
  changes) and `GameUI.panel_box` -- so the rails match the menus and follow Options >
  Accessibility. The kit names neither: the game's context does.
* `menu/core/MenuTheme.gd` (`_text_scale`): a settings module with no value yet (a probe run as a
  script, before settings load) gave `float(null)`, an error for every themed panel. It is read
  as the default now. A one-line fix in another area's file.

### As built: stage 4b, the menu bar and the frame (2026-11-07)

Kit 0.9.0: **`WkMenuBar`** -- menus from rows the editor gives (`[label, id, shortcut]`, `[]` a
separator), a label already there taking more rows after a separator, radio checks, a title on
the right -- and **`WkFrame`**, which places the pieces each frame: the bar, a band under it across
the window, the rail a margin under that, and says where the editor's own readouts start
(`content_left`). `wk_smoke` 99.

* `WorkshopMenu` builds its bar with `WkMenuBar` (both workshops have it: the asset workshop adds
  its menus with `add_menu`, now the kit bar's); its dialogs and what each item does stay
  game-side -- they name recipes, kinds, tags and towers.
* **Not themed, on purpose.** Giving the menu bar and the tool bar the menus' Theme (`style_ui`,
  as the rail has) made both larger -- the menus' fonts and padded buttons are sized for a
  menu screen -- and at 1280x720 the tool bar wrapped to two rows, pushing the rail down. They
  keep their compact look; a compact editor variant of the game's theme would be the way to
  match them.
* The building workshop's tools hand their tool bar (the band) and rail to a `WkFrame`, whose
  `layout` replaces the hand-placed positions in `WorkshopTools.process`, to the pixel.
* The hint line stays the rail's (`WkRail` has had it since stage 1 of section 5).

### As built: stage 4c, the asset workshop on the frame (2026-11-07)

Kit 0.10.0: `WkFrame` takes a band that is not across the window (`band_wide`, `band_left`), a
gap under the bar (`band_gap`), a set room for the band (`band_space`) and a panel down the right
(`side`, its top kept under the bar). `wk_smoke` 100.

* `AssetWorkshopUI` hands its pieces to a `WkFrame` each frame -- the menu bar, the stage tabs
  (the band: 8 under the bar, 30 high), the tool rail and the outliner -- and its hand-placed
  positions are gone; the numbers are the ones it had (tabs at bar + 8, rail at bar + 46,
  outliner from bar + 8).
* What is in them -- the stages, the tools of each, the outliner's rows, the toast -- stays the
  asset workshop's: they name parts, models, guides and the sculpt.
* Both workshops now lay out through the same frame and build their menus on the same bar.

### As built: stage 5a, the hand (2026-11-07)

Kit 0.11.0: **`WkPlaceTool`** -- LMB `place_begin`, LMB up `place_end`, RMB `erase_at_cursor`; each
frame `place_hover` (aim the preview) and, while a run is under way (`place_running`) and LMB is
held, `place_drag`; a run whose button is up ends. `WkToolbox.default_id`: the tool in hand when
none is asked for, so putting down Paint or Sketch hands back the hand. `wk_smoke` 107.

* The base workshop's LMB-places / RMB-deletes branch and the per-frame aim and run in `_process`
  are the tool's now; its host methods are `wk_place_begin` (`_place` + `_begin_run`),
  `wk_place_end` (`_end_run`), `wk_place_running`, `wk_place_hover` (`_aim`, `_update_ghost`),
  `wk_place_drag` (`run_step`), `wk_erase_at_cursor` (`_delete_ray`). The asset workshop's own
  `_place`, `_delete_ray` and `_aim` are still what runs (it extends the base).
* The tool is also called as the hand under another tool: a click Paint or Sketch does not take
  (RMB while painting, or outside a stroke in Draw) still takes a brick away, as before.
* `place_probe`'s check after B now reads "the hand is back in hand".

### As built: stage 5b, the rest of the shared tools (2026-11-08)

Kit 0.13.0: five more tools under `tools/`, one file each, with their questions on `WkContext`.
`wk_smoke` 143.

| Tool | What it does | Asks the context | In |
|---|---|---|---|
| `WkMeasureTool` | two clicks, the distance; a third starts again | `measure_point`, `measure_show` | asset (Alt M) |
| `WkFillTool` | a click fills the patch under the cursor, `width` wide | `fill_at_cursor` | asset (the wand, F4) |
| `WkMoveTool` | press, drag on the axis plane most square to the view, let go | `move_grab`, `move_to`, `move_drop` | asset (Alt G) |
| `WkSelectTool` | CLICK: pick what is under the cursor; BOX: drag a box | `select_at_cursor`; `select_box_begin` / `_drag` / `_end` | building (L, CLICK), asset (L, BOX) |
| `WkShapeTool` | DRAG_SOLID: press, drag, let go makes it; OUTLINE_HEIGHT: the base, let go, the height (moved or typed), click; RMB or Esc gives up | `shape_begin`, `shape_base`, `shape_base_done`, `shape_height`, `shape_typed`, `shape_release_commits`, `shape_commit`, `shape_cancel` | building (Draw, Cut, Select's push-pull: OUTLINE_HEIGHT), asset (K: DRAG_SOLID) |

* **One Shapes tool, two gestures** (the user's choice, 2026-11-08): `mode` says which. The tool
  keeps the gesture -- `drag`, a Dictionary only the editor fills in (the tool reads its
  `phase` and `button`), and the digits typed -- and the editor answers what the shape is. The
  building workshop's `_drag` and `typed` are the tool's, through properties, so its code and
  `build_tools_probe` read and set them as before; `_make_input` hands the event to the tool,
  and what it did is now `wk_shape_begin` (where a drag starts: a face, a wall's end, the
  plane at the ghost) and `wk_shape_base_done` (one more outline of a plan, or on to the height).
* **Cut is the Shapes tool, not a tool of its own.** In the building workshop a cut is drawn
  exactly as a shape is; the context makes it a cut (`tool == "cut"` or Draw's cut). Its one-click
  door and window (`_cut_input`) name openings and storeys, so they stay game-side, before the
  tool. In the asset workshop a cut is a sketch drawn with RMB (`WkSketchTool`). A
  `wk_cut_tool.gd` would hold nothing the Shapes tool does not.
* **Select's push-pull is the Shapes tool's height.** A click on a kept shape's top or side
  (`wk_select_at_cursor`) starts a drag already in its height; letting go makes it
  (`shape_release_commits`). The height's clicks and the drawing's keys go to the Shapes tool
  whichever building tool is in hand, as before.
* **The building workshop calls its kit tools directly**, as the base calls the hand: they are
  in `ws.toolbox` (so they have the context) but not taken up with `use`, because Draw, Cut and
  Select share one drag. The asset workshop takes them up with `set_tool` (`KIT_TOOLS`: its
  tool name -> the toolbox id); taking up any of them puts Measure down.
* **RMB delete is undoable in the building workshop too.** The delete command
  (`_push_delete` / `_undo_delete` / `_redo_delete`) moved from the asset workshop into
  `workshop.gd`. A kept shape's brick goes back into its shape (`forget_brick` returns what it
  took; `own_brick`). `place_probe` and `build_tools_probe` expected Z to pass over a brick taken
  by RMB; they now expect it laid back, and still check that a brick taken some other way (as a
  cut does) has its edit skipped: place 150, build_tools 346.
* One small difference: RMB with Draw on a non-upright frame takes a brick away (the hand's);
  it used to be swallowed with the "Shapes go on the upright grid" message.
