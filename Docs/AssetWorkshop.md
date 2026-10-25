# The asset workshop

A workshop scene for blocking out **assets** -- guns first, then mechs, gear and props -- fast,
against a photo or an existing model, with each part kept apart as it is built. Its output goes
to the part kit (`tools/brickify/gunsmith.py`), which turns it into nano bricks, smooth custom
pieces, studs and connections ([Docs/Parts/custom.md](Parts/custom.md)).

    godot --path . res://scenes/asset_workshop.tscn

It is the workshop ([Docs/BuildMode.md](BuildMode.md), `scripts/workshop.gd`) with tools added:
`scripts/asset_workshop.gd` extends it, and everything the workshop does -- placing, sideways
building, the hotbar, paint, undo, save and load -- works here unchanged. Tools that prove out
can move into the main workshop later; that is the build-mode area's call.

Status: all four phases are built (2026-10-14) and checked by the probe (56 checks). The panels and drag tools have been driven by the probe, not yet by hand: what feels wrong in use is the next round.

---

## 1. Units: build in bricks, think in nano

An asset is built here in ordinary bricks. On export every brick becomes its nano twin -- same
studs, half the size -- and a gun's nano model is a quarter of the real gun
([Docs/Parts/joints.md](Parts/joints.md) section 7). So one stud here stands for:

| Here | Nano | Print | The real thing |
|---|---|---|---|
| 1 stud | 1 nano stud | 4 mm | 16 mm |
| 1 plate | 1 nano plate | 1.6 mm | 6.4 mm |

A Thompson is 53 studs long and 3 studs wide here; a pistol about 13 studs.

The ruler, the measure tool and the readouts all show studs and plates **and** print mm and
real mm, so a part can be built straight from a real gun's numbers.

---

## 2. The tools

### Phase 1 -- trace a photo by hand

| Tool | Key | What it does |
|---|---|---|
| **Instructions** | F10 | a page on how to start and every key; opens on start until its tick box is cleared |
| **Ruler** | always on | the cell under the cursor and the build's size, in studs/plates, print mm and real mm |
| **Reference photo** | F2 (panel) | load an image onto a plane -- side, top or front -- behind the build. Calibrate: click two points on it and type the real length between them; the photo scales itself. Move it, set its opacity, hide it, remove it. It is never built on: rays pass through it |
| **Ortho views** | Alt 0-3 | perspective, side, top, front. The flat views line up with the photo planes. Alt + wheel zooms about the cursor, Home / End about the middle |
| **Measure** | Alt M | click two points (on bricks, a photo or the floor): the distance in all four units, drawn as a line |
| **Mirror** | Alt S (Alt shift S: plane under the ghost) | every brick placed is placed again mirrored across the centre plane (a gun's long axis runs along X; the plane is Z = its middle). The plane sits on the middle of a stud, so an odd width (a 3-stud body) is centred |

### After the first use (2026-10-15)

| Change | Why |
|---|---|
| **No F5-F8.** Views, measure and mirror are on Alt chords | run from the Godot editor, F5-F8 are the editor's (run, run scene, pause, stop): F8 stopped the game and lost a build. The workshop's own F5 / F9 can be taken the same way, so run the scene outside the editor or with the editor's game embedding off |
| **Autosave** every few seconds to `user://asset_workshop_autosave.json`, loaded on the next start | so a stop or a crash costs seconds. Scripted runs never write it |
| **Free placement**, on by default (Alt F aims at studs instead) | placing by aiming at studs kept snapping where it was not wanted. The ghost goes where the cursor meets the **working plane** -- the side plane at a depth, the top plane at a height, the front plane at a stud -- mid-air or not, flipped or not; only an overlap stops it. PgUp / PgDn move the plane; a flat view picks its own |
| **No floor**: a floating build area and a starting brick, laid again whenever the build is empty | a floor got in the way |
| **Photos**: a stud grid over a side photo, calibrating in studs ("53s") as well as mm, zoom about the cursor, Alt + drag moves the photo, and "behind the build" / "through its middle" | to check a photo is the size meant, and get it next to the build |
| **Sketch** (Alt D): draw an outline on the working plane -- side, front (a drum is a circle there) or top -- and it is filled with bricks for the current part, as thick as that part is set to be, packed round anything already built. On the side and front planes, an edge climbing two plates a stud gets slopes, an end rounding over three plates in two studs gets a curve; on top edges the right way up, under bottom edges flipped | blocking out by drawing. The catalogue has no piece for an edge shallower or steeper than those, so those stay stepped |
| The workshop's own key list starts hidden (F1 shows it); F10 has this scene's keys | it covered half the screen |

### Round 3 (2026-10-16)

| Change | Why |
|---|---|
| **An RMB delete undoes** (Z lays it back, shift Z takes it again); a box-select delete undoes at once | the workshop dropped a deleted brick from its edits, so it could not come back |
| **One brick a click**: a held click lays a run only once the mouse has moved 14 px and 150 ms have passed | a hand that moved a little while clicking laid two bricks |
| **Sketch is a mode**: each part's sketch is kept (per plane and depth, saved with the build). LMB draws area in, RMB draws it out, the thickness or slope setting changes, and the part's bricks are worked out again -- the old ones taken up, the new ones packed -- as one undo that puts the sketch back too. "Clear this part's sketch" takes it all up | to edit a blocked-out part by drawing, not by hand |
| An outline is filled **to its outermost line**, by winding rather than even-odd, with enclosed holes filled; the yellow line shows the outline of what is filled | a stroke that crossed itself or went round twice left holes |
| **Eager slopes**: slopes on edges climbing one to three plates a stud, a plate proud of or short of the line, not only at their own two; 2x4 slopes where a part is four deep | more slopes, fewer stairs |

### Round 4 (2026-10-16): tools on the left, sketch in three views, studs, explode, hands

Sketching and editing by hand stutter-free first: a sketch stroke works out only the
bricks near what changed (~140 ms -> ~12 ms on a 500-brick part), and a delete no longer
copies every sketch.

| Stage | What | How it works |
|---|---|---|
| 1 | **Tool rail** down the left: Place, Paint, Sketch, Shapes, Select, Studs, Points, Measure, then Explode and Hands; under them the open tool's options | the panels the keys already opened, gathered in one place; every key still works |
| 1 | **Brushes**: paint with a brush of 0-8 studs, round or square, painting colour and material, colour only, or material only. Sketch with the same brush (drag a round or square brush to paint area in or out), or by outline, rectangle, ellipse or clicked polygon | one brush for paint and sketch, sized the same way |
| 1 | In sketch no brick ghost: the brush or the outline is the cursor | nothing is placed one brick at a time there |
| 2 | **A part in three views.** The first plane a part is sketched on is its base and gives it its thickness. An outline drawn for the same part on another plane is a view *through* it: area drawn in keeps only what is inside it, area drawn out cuts right through. So a receiver is a side rectangle, its charging handle slot and ejection port drawn out from the side, then from the front its top corners drawn out at an angle | three views of one part, as a draughtsman draws it. Slopes come from the side and the front: an edge seen at a slope's pitch from either gets one |
| 2 | **Cut depth**: RMB cuts through, or N studs in from the face nearest the camera | a port is a pocket, not a hole through the gun |
| 2 | The other parts' outlines faint on the plane; Y moves on to the next part in sketch, as anywhere | sketch a part, then the next, against the ones done |
| 3 | **Studs anywhere**: a stud on any face of any brick, any of its six ways, on the half-stud lattice of that face. Kept with the build, drawn and exported with it | studs where a gun needs them, not only where bricks put them |
| 3 | **Connection points on studs**: a mount or socket is placed on a stud (J on a stud) and carries its interface | a connection is where two parts meet on studs |
| 4 | **Exploded view** (one button): every part pulled apart about ten bricks along where it sits -- barrel forward of the receiver, stock behind, grip under it, underbarrel under the barrel; the magazine where it is. Edit as normal while apart: what is placed lands in the part's own place when it closes | see and work on a part with nothing in the way |
| 4 | **Move a whole part**: drag it (and with it the assembled place of it) | a magazine or a sight goes where the gun needs it |
| 5 | **Hands**: the game's own brick hands (ViewArms' C and pinch) at the gun's scale -- a game metre is the gun's real size, so the C's hole comes to ~8 mm at print, a grip's thickness. The right C round the grip, its hole along the grip's long axis (from its cells), fingers forward; the left round the underbarrel, else the barrel, else the front of the body. **Play** runs a cycle: three shots (the gun kicks back and its muzzle rises about the grip), then the left hand goes to the magazine, pinches it, takes it out under the gun and puts it back. The parts are baked first -- each laid again on its own, as Explode does -- so they can move apart; making animations here is left for later | see the gun held and worked before it goes in the game |

### Round 5 (2026-10-16)

| Change | Why |
|---|---|
| The rail is narrower (~190 px from ~335): small type, tight buttons, shorter labels | it took a quarter of the screen |
| **RMB in sketch takes up any brick under the stroke** -- hand-laid ones, other parts' -- right through, or only `cut depth` studs in from the camera's side; in the same undo as the sketch change. With nothing sketched for the part, the stroke only erases. A tick box turns it off | the brush could only cut the part's own sketch |

### Round 6 (2026-10-16): the shape brush

| Change | Why |
|---|---|
| **Shape brush, in any tool**: Ctrl + LMB lays a shape round the ghost's cell -- a ball, cube or cylinder, or a flat circle or square lying on the plane the ghost is on (a brick top, E's locked height, or the working plane when placing freely; a cylinder runs through that plane). Ctrl + RMB carves the shape out of whatever is built: every brick it touches is taken up and the rest of it laid again in its own part, colour and material. Held and dragged it stamps every half a shape; a stroke is one undo. Ctrl + wheel sizes it (1-24 studs across, two and a half plates up a stud); its shape and a flat one's thickness are on the rail. Alt + wheel still zooms a flat view | lay and carve blocks of material without changing tool |

### Round 7 (2026-10-16): saving a gun

| Change | Why |
|---|---|
| A build here is a **gun** (recipe kind `gun`; `mech` too): File > Save, Save As and Open use the guns' library -- `res://guns/` shipped, `user://guns/` the player's (`BuildRecipe.LIBRARY_DIRS`) -- not the buildings'. A build saved before (kind `building`) opens as a gun. F5 has its own quick-save slot (`user://asset_workshop_quick.json`), not the building workshop's. The autosave stays | the only save options were for buildings |
| The bar is the asset workshop's own: File is New, Open (lists only guns and mechs), Save, Save As, quick save and load; Insert, Type, Layer, Generated, Test in city and the inserted-build part of Edit are gone, their shortcuts too, and Enter does not send a gun to the city. The building workshop's Open no longer lists guns or mechs | only assets are saved and opened here |

### Into the game, stage 1 (2026-10-16): export

| What | How |
|---|---|
| **Export to game** (rail, Alt X) | each of the gun's parts (its slots: body, barrel, stock, grip, magazine, sight, muzzle, underbarrel) is laid again on its own, meshed as the workshop draws it -- bricks, studs, hand-put studs, colours -- and saved as a scene, `user://guns/<name>/<part>.scn`, with `gun.json` listing them |
| Size and frame | real size (a game metre is the gun's real metre: `GAME_PER_WORKSHOP`), the muzzle along -Z, up +Y, across the gun +X -- the game's guns' frame (`GunPlaceholderParts`). The Thompson comes to 0.88 m |
| Joins | the game's contract (`GunAssembler`): every part but the body has a `mount` at its root; the part it attaches to (`GAME_HOST`: the barrel to the body, the muzzle and underbarrel to the barrel, the rest to the body) has `socket_<slot>` at the same point, so the assembler puts it back exactly where it was built. The point is the part's mount connection point if it has one, else the middle of its bricks -- which is where the game's hands take the grip, the magazine and the barrel (`PlayerView._holds`) |
| Muzzle | `socket_muzzle` at the tip of the foremost part (the muzzle, else the barrel, else the body): the deepest one is where the game fires from |
| Which way it points | read off the build (`settle_muzzle`): the barrel and muzzle forward of the body, the stock behind. The Thompson, built muzzle toward +x, first came out backwards |

### Into the game, stage 2 (2026-10-16): a gun to hold and fire

| What | How |
|---|---|
| **The game finds them** | `AssetGuns` (scripts/guns/asset_guns.gd) reads every exported gun -- `res://guns/<id>/` shipped, `user://guns/<id>/` the player's -- and makes part defs of its scenes. `GunPlaceholderParts.build_library` puts them on the end of the game's part library, each fenced to its own design with `exclusive_to` (as a legendary's barrel is): no random gun takes one, no other gun's roll moves, a saved one loads back by its part ids |
| **A gun of one** | `AssetGuns.generate(lib, id, seed)` -> `GunGenerator.generate_fixed`: the design's own parts, everything else (modifiers, alt fire, stats, quality) rolled from the seed as for any gun, the design's name after the grade word ("Gutter Thompson"). It fires as the class its `gun.json` names, an SMG by default. Brand `workshop`: no skin is set for it, so its bricks keep their colours |
| **The magazine comes off** | a magazine part tagged `detaches` (every exported one) goes with the left hand through a reload, down with the old one and up with the new (`PlayerView._carry_magazine`), and is back home after |
| **To try it** | in developer mode, T cycles the gun classes and then each exported gun. The pass `city.tscn -- --asset-gun=thompson` holds it, fires it and reloads it (shots/asset_gun_*.png) |

### Into the game, stage 3 (2026-10-16): print files

| What | How |
|---|---|
| **Export to print** (rail, Alt B) | the build sheet, then Blender's print kit (`tools/brickify/printkit.py`) in the background: each part one watertight STL at print size (one nano stud = 4 mm), `Documents/brickcity-print/guns/<name>/<part>.stl`, outside the repository like the brick generator's files, with pictures (`_print_iso`, `_print_side`, `_print_under`, `_print_parts`, `_print_holes`) and `<name>.print.json`. The workshop shows the picture and the report when it is done |
| One solid a part | its plain bricks as ONE shell (the outside faces of their cells -- bricks side by side print as one piece, not boxes that only touch); slopes and curves from the catalogue (gunsmith's), welded closed and grown a hair; studs sunk a hair; all unioned (each piece its own operand: pieces overlapping inside one operand are not unioned) |
| Plugging together | where a part sits on another part's studs, a stud hole cut up into it: the stud's diameter plus the grid's side clearance (nano 2.4 + 2 x 0.05 mm), 0.15 mm deeper than the stud. The lower part keeps its studs |
| Checks | every part watertight; no loose bit the size of a stud (a part may be several real pieces -- the Thompson's front and rear sight); edges where two blocks touch only along a line are counted and named ("pinched": printable, nothing holds there). Never a coplanar face in a boolean: every overlap is a deliberate hair, hole cutters start well below the face |
| Apart or in one | every export makes both: `<part>.stl` to print the parts apart and plug them together, and `<name>_whole.stl`, the gun as one solid -- each part again without the stud holes between them (a stud fills where its hole would be), all unioned -- to print in one go |
| The Thompson | 8 parts, 220 x 12 x 59 mm, every part watertight, no loose bits; its body has one pinched edge. Whole: one piece, watertight, 3 pinched edges (the front sight's sides, the grip where it meets the body) |

### Nothing to remember (2026-10-16)

| Change | Why |
|---|---|
| Every action a key does is in a menu on the bar -- View, Part, Brick, Gun, Photos, Help, and Redo under Edit -- with its key beside it (`WorkshopMenu.add_menu`; the menus do not bind the keys, the scene's own handlers keep them, so nothing fires twice). The tools stay on the rail, with a part picker at its top. Held or aimed things (Tab, hold E, the number keys and wheel, the middle button, Ctrl + click) stay keys and are listed under Help | the user should not have to remember a key |

### The shape brush is the Shapes tool's (2026-10-16)

| Change | Why |
|---|---|
| Shapes (K) chooses **drag a box** (fill it, as before) or **brush**: then a plain LMB lays the shape, RMB carves it, held and dragged it goes on, and its options (ball, cube, cylinder, flat circle or square; size; a flat one's thickness; clean or random) are under it. Ctrl + click still does it from any tool | holding Ctrl to use a tool was one more thing to remember |

### Triangles (2026-10-17)

| Change | Why |
|---|---|
| The readout has a **triangle line**: the gun's triangles as Export to game meshes it, its draws, how many of them are studs, the count without the chamfer, and each part's, biggest first. Counted again 0.4 s after the last edit (`triangle_stats`, ~4 ms for the Thompson); the probe checks it equals what the exported gun draws | to see what a gun costs while it is built, and what curves, shells or fewer studs save |

What it showed, the Thompson as saved: **16,196 triangles in 16 draws**. Studs are 7,524 of
them (198 studs at 38 each), the chamfer 2,928, the brick faces 5,744. The bake merges faces
within a brick and no further (`bake_faces_into`), so two bricks stacked keep a side face
each, and the hidden faces between them are culled. At hand size the chamfer is too small
to see; the brick outlines are the shader's already.

### The form, stage 1 (2026-10-17): the shape brush draws into it

A part's **form** is everything drawn for it: its sketches (outlines and brush strokes,
kept finer than the grid) and now its shape-brush strokes. Its bricks are always worked
out from the form -- edge pieces from the views, the inside packed biggest brick first,
bricks on the courses and plates between -- so the form can be laid again whole, which
is what the sliders will do.

| Change | Why |
|---|---|
| A **shape-brush stroke** (Shapes as a brush, or Ctrl + click) is kept in the part's form: one entry a stroke, `"<part>|solid|<n>"` in `sketches`, holding the shape, its size, plane and thickness, lay or carve, and every stamp's centre. Laying goes into the current part; carving into every part whose form it touches, and bricks no form laid (laid by hand) are carved as before. Shapes are laid over the sketch, in the order they were made. A stroke is one undo, whatever parts it touched; moving a part moves its shapes; saved with the gun | brushed shapes laid loose bricks, which nothing could lay again: a slider would have lost them |

The drag box of the Shapes tool (K) still lays loose bricks.

### The form, stage 2 (2026-10-17): the size slider

| Change | Why |
|---|---|
| **Size of the block-out** (Sketch tool, under the slope setting): 25-300%. Let go and every part's form is scaled about the middle of the block-out, on its bottom -- outlines, brush strokes, thicknesses, pocket depths, shapes -- and every part laid again, as one undo; the slider is back at 100%. If the bigger block-out runs off the build area but would fit in it, it slides back in; too big, it is refused and says so. Bricks laid by hand, hand studs and connection points stay where they are | the block-out is drawn at whatever size is handy, then sized |

The Thompson: x0.6 is 80 pieces and 4,594 triangles, x1.4 is 438 pieces and 26,134
triangles, laid in ~100 ms; x1.5 is refused (81 studs long, the build area is 80). Undoing
the x1.4 takes ~1.2 s: it lays hundreds of bricks back one by one.

### The form, stage 3 (2026-10-17): the curve slider

| Change | Why |
|---|---|
| **Curves** (Sketch tool; it replaces the slopes drop-down): 0 steps only, 1 slopes, 2 slopes and curves (as before), 3 fitted from the side and the front whatever views the part was drawn in, 4 eager slopes too. Let go and every part is laid again from its form, as one undo that puts the level back too; saved with the gun | how much a block-out is smoothed is a choice, made once for the whole asset |
| Level 3 is what gives **shape-brush shapes** slopes and curves: they come from no sketch view, so before it they had none | a brushed ball was all steps |
| Slopes at their own pitch, then curves, then eager slopes on what is left: eager slopes no longer take a curve's columns | at eager, the Thompson lost every curve |

The Thompson, every part laid again:

| Level | Pieces | Slopes | Curves | Triangles |
|---|---|---|---|---|
| 0 | 279 | 0 | 0 | 12,424 |
| 1 | 281 | 8 | 0 | 13,068 |
| 2 | 285 | 8 | 10 | 13,116 |
| 3 | 285 | 8 | 10 | 13,116 |
| 4 | 291 | 19 | 7 | 12,678 |

Each takes 20-40 ms. Level 3 adds nothing to the Thompson: its parts are outlines drawn
from the side, so seen from the front they are rectangles.

**Not yet: pieces turned on their side.** Slopes and curves fall along the gun or across it,
right way up or flipped; a corner rounded seen from above wants one lying on its side. The
workshop can build sideways (its six frames), but Export to game, the triangle count and
the print files take only the upright frame's bricks: sideways pieces need those first.

### Build area (2026-10-17): 1000 studs

| Change | Why |
|---|---|
| The build area is **1000 studs along and across and 2500 plates up** (a cube, 5000 ticks each way), from 80 x 200; a new build starts in its middle. The working plane's grid, the mirror sheet, a new photo's size and the flat views' zoom stay an 80-stud window round the build, and follow it | mechs and vehicles, not only guns |
| The engine holds a chunk that big **paged** (`Occupancy`, brick_types.h): pages of 16,384 cells, allocated on a block's first write. Dense, the area would be 2.5 billion cells, 10 GB a frame and six frames; paged it is ~4 MB of page table a frame and 64 KB a page the bricks touch. Every chunk the game makes is under the line (64 M cells; the biggest building is ~1.6 M) and stays dense, one branch from the plain array it was | a dense grid cannot be that big |
| A library without paging (`BrickWorld.paged_chunk_cells` missing: an old DLL) gets the old 80-stud area and a warning, not a 60 GB allocation | other worktrees and the main folder run old DLLs until they rebuild |

A resize that would not fit is now refused from the forms' box, before anything is worked
out at that size (a x200 form was minutes of packing).

### Sideways bricks go out too (2026-10-18)

Bricks built sideways live in grids of their own (the workshop's six frames). Every way
out of the workshop took only the upright grid's; now:

| Where | How |
|---|---|
| **Export to game** | a part's bricks are meshed a frame at a time, each mesh placed where its grid is (`_frame_rel`: the frame's grid in the upright one's); the first is `Bricks`, the others `Bricks<frame>`. Its point, its muzzle tip, which way it points and the gun's length read every brick's cells wherever they are laid (`_cell_points`, `_brick_box`) |
| **Triangle count** | the same meshes: it still equals what the exported gun draws |
| **Print sheet and kit** | a sideways brick is not on the upright grid's cells (on its side a plate is 2 ticks thick along the gun, a stud 5), so the sheet gives it its middle, its `turn` (where its grid's x, y and z point in the gun's frame) and its size. The kit lays it as a solid of its own -- a turned box, or a turned catalogue piece -- welded on like a slope; a plain one's studs come as hand studs, a shaped one's from its profile, turned |

Checked: a 2x4 with a plate and a slope laid sideways on its end exports, counts and
prints -- one watertight piece, 10 studs, the plate's stud pointing out of the end.

Still upright only: Explode, moving a part and the hands' baked parts leave a part's
sideways bricks where they are.

### Shells, stage 1 (2026-10-18)

A **shell** is a part's smooth outside: a custom piece off the grid, with the part's bricks
inside it.

| What | How |
|---|---|
| **Make one** | Sketch tool: "smooth shell on this part", then **thickness** (0-3 studs) and **detail** (1-8 samples a stud: the triangle slider) -- let go and the part is laid again, one undo that puts the settings back too; saved with the gun |
| **The surface** | the part's form sampled `detail` times finer than the grid (its sketches scaled and laid out as a part's volume is: the same outlines, finer cells) and wrapped by `FormMesher.surface` (surface nets, gdextension/brick/src/form_mesher.cpp): one closed surface, smoothed 16 times, no vertex leaving its own cube of samples |
| **The bricks inside** | the form shrunk by the thickness (`FormMesher.erode`), every grid cell whose samples are all left: packed as usual, no slopes or curves (the shell is the outside). Thicker, fewer bricks: the Thompson's stock is 121 bricks bare, 89 inside a shell 0 thick, 35 at half a stud, none at 1.5 |
| **Where it meets another part** | a sample next to a brick that is not the part's own is pinned: the shell stays flat on that face instead of the smoothing pulling it off (the stock came loose from the body without it) |
| **The game** | Export to game writes the shell (`Shell`) and leaves out the bricks it covers; the triangle count counts the shell, not them |
| **Print** | the sheet carries the shell's triangles; the kit makes them the part's solid, grown a hair to weld. The Thompson with its stock and grip shelled: every part watertight, the whole gun one piece |

### Shells, stage 2 (2026-10-18): exact edges, a triangle budget, embedded joins

| Change | Why |
|---|---|
| **The surface is where the outlines are drawn**: the form is sampled as *distances* (`FormMesher.polygon_distance`: each sample's distance to the part's outlines, exact; brush strokes as round strokes; slabs cut to their thickness; views through it intersected, cut-throughs taken out) and the surface laid where the distance crosses zero, interpolated (`FormMesher.surface_sdf`) | sampled as in or out, a slanted outline meeting a flat side stayed a staircase of samples however it was smoothed -- the teeth |
| A part with a depth pocket or a shape-brush shape keeps the in-or-out samples, blurred before the surface is laid (a staircase becomes a slope) | those are not composed as distances yet |
| **Triangles** (a third shell slider, 100 to 30,000 a part, log scale; 1,500 unless set): the surface is decimated to about that many (quadric edge collapse, flat areas first, never folding a face, kept closed, no fan over 14). **Detail** stays: how finely the form is sampled | surface nets put as many triangles on a flat side as on a curve: the stock was 7,196-64,624 |
| **Hard edges**: a corner's normal averages only the faces within 40 degrees of its own | the big flat sides shaded with smudges where the normals were averaged round a sharp edge |
| **Embedded joins**: every cell where a shelled part meets another part's bricks stays a real brick inside the shell, kept in the game and the print. Only another part's bricks pin the shell flat (its own old slopes did, and held their stairs) | the drawn stock stops a little short of the body: the exact surface stood off it and printed loose. The bricks meet it exactly -- and bring their studs, so the body gets the stud holes and the parts plug together |
| The print kit welds a shell by position and grows it 0.08 mm (`SHELL_GROW`) | a hard edge gives each corner its own vertex; a grown hair (0.02 mm) did not reach |

The Thompson, stock and grip shelled at 4 samples a stud, 1,500 triangles each: the gun is
9,516 triangles (13,268 all bricks); a shell takes 70-570 ms; printed, every part
watertight, the stock 6 studs and the grip 7 into the body (19 stud holes), the whole gun
one piece.

### The SDF block-out (2026-10-18)

**What the user wants** (2026-10-18): the block-out is sculpted in 3D as a smooth signed
distance field -- as Zylann's voxel tools sculpt terrain -- tracing a photo, a 3D model, both
or neither. While drawing there are **no bricks**, only the smooth surface; the sliders act
on it; a **Convert** button turns it into the asset. Areas marked as **brick zones** become
bricks, the rest become custom smooth parts joined to them. **Changed the same day**: bricks
are the default -- Convert makes everything bricks except areas **marked smooth**, which
become the part's custom piece (the user had marked nothing and got all smooth pieces). Each part of the asset (barrel,
handguard ...) stays its own: parts blend while sculpting, the split is what is saved. It
can go back and forth: brick edits made after a convert show in the SDF, and converting
again keeps them. Old saves with the 2D sketch form may be dropped.

**The engine side: `SdfForm`** (gdextension/brick/src/sdf_form.cpp), checked by
`tools/sdf_form_probe.gd` (headless, 26 checks):

| What | How |
|---|---|
| One field for the whole asset | a sample a **tick** (a stud 5, a plate 2), so it lines up with the brick grid; distances kept within 6 samples of the surface, in 16^3 blocks stored only where something was drawn |
| A part label and a smooth flag on every sample | an add labels what it changed; Paint relabels; Mark / Unmark set the flag (unmarked = bricks). Parts are one surface while sculpting; `part_field` gives one part's distances, ending where its label does (for its shell) |
| Brushes | add (union), remove (subtraction), both optionally smooth (Quilez's smooth min), smooth (blur in the brush), as capsules or boxes -- as Zylann's VoxelTool does them |
| A 3D model as a solid | `stamp_mesh`: distance to the nearest triangle, inside by ray parity |
| Bricks out | `cells`: a brick cell is solid when the middle of it is inside; its part and smooth flag from that sample |
| Bricks back in, 1:1 | `sync_cells(before, after)` writes only the cells that changed: a brick added is a box unioned, a brick taken a box carved, a part changed relabelled. Untouched smooth surface stays as it was, and `cells` gives back exactly the bricks synced (the field is 1-Lipschitz, so a box never flips a neighbour's middle). A bricks-only asset goes in the same way |
| Whole-asset sliders | `scale` about a pivot, `blur` |
| Live view | `mesh_block`: surface nets a block at a time, each edge meshed by one block so they meet without cracks, normals from the field, colour by part (lighter where marked smooth) |
| Drawing on a surface | `raycast` (sphere tracing) |
| Undo, saving | `begin_edit` / `end_edit` record the blocks an edit touched; `swap_blocks` undoes and gives the redo; `to_bytes` / `from_bytes` |

**In the workshop** (`scripts/asset_sculpt.gd` holds the field in the scene; the tool is in
`asset_workshop.gd`; the probe's `_sculpt` and `_convert` check it):

| What | How |
|---|---|
| **Sculpt in 3D** | the Block out tool's first way to draw (and the default). LMB adds to the current part, RMB carves, Shift smooths; modes for smooth, paint this part, mark smooth (LMB marks, RMB back to bricks; marked areas show lighter). A line under the hint says which state it is in; once converted, clicks do not sculpt (Edit as SDF first). The brush starts on the block-out's surface under the mouse, else on the working plane; an add keeps the depth it started at. The mirror applies. Brush radius 0.2-10 studs, blend 0-3 studs |
| **While sculpting** | only the smooth surface, a mesh a block, coloured by part; no bricks. A stroke is one undo; the field is saved with the asset (`asset.sdf`, zstd) |
| **Sliders and buttons** | size 25-300% (let go: scaled about the bottom middle, one undo), **this part's piece** (its triangles after Convert, 300-30000, default 4000; let go, one undo), smoother, **add a 3D model...** / **model into this part** / **carve the model out** (round 3), clear |
| **Convert** | every solid cell into the asset, in its part. Unmarked cells: bricks (nothing marked: all bricks, no pieces). A part's marked cells: its **custom piece** -- a shell straight from the field (`part_field`, unmarked samples and other parts left out, a sample a tick, `tris` budget) -- over bricks only where the surface holds the whole cell or where it meets bricks (the join: real bricks with studs; the piece wraps each join brick's box, so it never shows through a thin surface). Cells the piece fills with no brick (its edge) are kept as the piece's. A brick from before goes back where its cells still are its part's, colour and shape kept; the rest packed biggest first, in the colour most of the part's old bricks had (else its piece's, else the hotbar's). One undo. The test gun converts in ~0.1 s |
| **Edit as SDF** | the bricks back into the field -- only cells that changed since the last Convert (a brick added unions a box, a brick taken carves one), the piece's own cells counted as still there -- and the block-out shown again; the bricks are put aside for the next Convert. A bricks-only build (the Thompson) goes in whole. Convert again gives the same cells. One undo |

`-- --shot --sculpt [--convert]` draws a test gun (four parts, all marked smooth but the barrel's far half)
and takes the usual pictures.

**Not yet**: a converted brick's slope or curve goes back into the field as a whole cell;
a join brick's studs can show above a piece's top; Move part does not move the field.
**Explode** works only once converted (or with nothing sculpted); Edit as SDF closes it.
The old 2D sketch (drawing in bricks) **stays** -- the user still wants it (2026-10-18).

**Fixed 2026-10-19** (the user's report): Size hung or crashed -- `scale` walked the whole box
round every block (their strokes had drifted 160 m), and scaled down filled empty space;
now only the blocks a block lands on (104 s -> 1.3 s grow, 0.05 s shrink). Strokes curved
round the player -- an add kept a fixed distance from the moving camera; now a stroke stays
on a fixed plane (below). Convert never laid slopes or curves -- it only packed; now it runs
the form's `_edge_runs` (side and front) on the brick cells, as the curve slider has them.
The rail kept keyboard focus (Space pressed buttons) and passed the wheel on to the hotbar.

| Brush placement | after Blender's Grease Pencil "stroke placement" (origin / 3D cursor / surface, drawing plane front / side / top / view) |
|---|---|
| **on a plane facing you** (default) | the stroke starts on the surface under the mouse (else the working plane) and stays on the plane through that point square to the grid axis the camera looks along most; a disc shows it |
| **on the working plane** | the same, the plane parallel to the working plane (PgUp / PgDn) |
| **on the surface** | follows the surface the whole stroke (an add builds up toward the camera, as clay buildup does) |

**Tools other SDF sculptors have** (research 2026-10-19), and what we have:

| Tool | Where | Here |
|---|---|---|
| Add / carve sphere, smooth blend | Zylann `do_sphere` (union / subtract, smoothness) | yes |
| Smooth | Zylann `smooth_sphere`; Substance Modeler: hold Shift | yes (Shift) |
| Grow / shrink gradually | Zylann `grow_sphere`; Substance Modeler Inflate; Blender Inflate | not yet |
| Stamp a mesh | Zylann `stamp_sdf` / `do_mesh` (`VoxelMeshSDF`) | add a 3D model / model into this part (round 3) |
| Primitive stamps: box, cylinder, cone, capsule | Dreams stamp / smear; MagicaCSG, Womp primitives | not yet (box only in code) |
| Flatten to a plane | Substance Modeler Flatten (hard surface); Blender Flatten | not yet |
| Move / grab | Blender Grab; Substance Modeler Warp / Elastic | not yet |
| Crease | Substance Modeler Crease | not yet |
| Split into a new layer, crop | Substance Modeler Split / Crop | paint this part (relabels) |
| Mirror, repeat | Dreams, MagicaCSG, Chisel mirror; arrays | mirror only |
| Hard / soft blend switch | Dreams (a gesture) | blend slider |
| Guides to align | Dreams guides | working plane, photos, guide models |

Next, suggested order for guns: primitive stamps (box, cylinder) dragged out on the stroke
plane; flatten; a straight-line stroke (shift click to click); a lathe for round parts;
grow / shrink; move.

### SDF tools, round 2: stamps, flatten, grow (2026-10-19)

The user (2026-10-19): start implementing the tools from the research, written here first.
They start each gun clean (not from the Thompson). Built in this order; lathe and move come
after.

**Modes** (the sculpt panel's first dropdown; LMB / RMB as before, Shift still smooths):

| Mode | LMB | RMB | Like |
|---|---|---|---|
| add / carve | brush strokes, as now | carve | Zylann `do_sphere` |
| **stamp** | drag a shape out, let go: added | the same, carved | Dreams stamp; MagicaCSG / Womp primitives |
| **flatten** | drag over the surface: pulled onto a plane | -- | Substance Modeler Flatten, Blender Flatten |
| **grow** | drag: the surface swells a little at a time | shrinks | Zylann `grow_sphere`, Substance Modeler Inflate |
| smooth, paint, mark smooth | as now | | |

**Stamp shapes** (a second dropdown, shown in stamp mode). Every shape is dragged on the
stroke plane (the placement dropdown: facing you / working plane / surface start), from where
LMB went down to where the mouse is; a see-through ghost shows it until let go. One undo.

| Shape | The drag | Across the plane |
|---|---|---|
| **box** | corner to corner: its footprint on the plane | thickness = the brush's diameter, centred on the plane |
| **cylinder** | end to end: its axis (a rod: barrels, rails) | radius = the brush radius |
| **cone** | base to tip | base radius = the brush radius, tip 0 (a taper: muzzles, sights) |
| **ball** | centre to edge: the radius | -- |
| **line** | end to end: a straight stroke (the brush's capsule) | radius = the brush radius |

**Snap to the grid** (a checkbox, on by default): a stamp's drag points snap to the brick grid
-- half a stud along, a plate up -- so a box's faces land on brick faces and convert to clean
bricks. The blend slider applies to stamps as to strokes (0: hard edges, as for bricks).

**Flatten**: at the stroke's start the plane is fixed through the surface point under the
mouse, square to the surface there (the field's gradient). While dragging, every sample in
the brush moves toward its distance from that plane, by the strength slider (fills dents,
cuts bumps): a flat side for a receiver. With the placement "on the working plane" the plane
is parallel to the working plane instead, so a side can be flattened square to the grid.

**Grow**: within the brush every sample's distance goes down (LMB, swells) or up (RMB,
shrinks) by the strength slider each dab, full in the middle, fading to the brush's edge.

**Engine** (`SdfForm`): `shape(op, kind, transform, size, blend, part)` -- a box (half extents)
or a capped cone (radius at each end; equal ends: a cylinder) in a local frame placed by a
rigid transform (samples), for ADD / REMOVE / PAINT / MARK; `flatten(center, radius, normal,
point, strength, part)`; op GROW in `stroke` (blend is the signed amount). Checked in
`sdf_form_probe` (each shape's cells, flatten makes a face flat, grow and shrink change the
volume and back) and `asset_workshop_probe` (a stamp is one undo, snaps to the grid,
converts to the box's bricks exactly).

**Built 2026-10-19**, as above. sdf_form_probe 32 (5 new), asset_workshop_probe 244 (3 new).
`-- --shot --sculpt --stamps` adds a box stamp, a cylinder and a cone on the barrel, two
flatten dabs on the body's side and a grow on the grip, and leaves a box's ghost showing.
Shift during a stamp drag does nothing new (Shift at the press smooths, as everywhere).
Next: a lathe for round parts, then move / grab.

Sources: voxel-tools.readthedocs.io (VoxelTool, VoxelToolLodTerrain, changelog);
helpx.adobe.com/substance-3d-modeler (tools, shortcuts); docs.blender.org (sculpt brushes,
Grease Pencil stroke placement); docs.indreams.me (art tips, gestures); blenderartists.org
"The big SDF thread"; womp.com.

### SDF tools, round 3: two tools, a lathe, models, fitted pieces (2026-10-19)

The user (2026-10-19): do the next step (the lathe); more angled and curved bricks in
Convert; a tool that adds a 3D model as SDF; slopes are rare, and come mostly along the
grid's planes; the 2D sketch inside the SDF tool is confusing -- split them: **3D is SDF, 2D
goes straight into bricks**. Written here first, then built in this order.

**1. Two tools on the rail.** The rail's "Block out" becomes two tools:

| Tool | Key | What it is |
|---|---|---|
| **Sculpt** (3D) | Alt V | the SDF block-out: the sculpt panel only (modes, shapes, placement, Convert / Edit as SDF). No bricks while sculpting |
| **Sketch** (2D) | Alt D | the old sketch: outline, brush, rectangle, ellipse, polygon on a plane, laid straight into bricks. No SDF panel |

Inside they stay one tool (`tool == "sketch"`, `sketch_draw == "sculpt"` or a 2D draw), so
saves, undo and the probes are unchanged; the rail shows which. The Sketch tool's draw list
loses "sculpt in 3D"; it remembers the last 2D draw (outline at first). Bricks a 2D sketch lays
while an SDF block-out is showing go into the field at the next Convert, as hand-laid bricks
already do.

**2. Convert fits pieces to the surface.** Before, Convert laid slopes only where a
*slice* of the cells, seen from the side or the front, had a top edge climbing exactly two
plates a stud (or a curve's three plates in two studs). A sculpted surface almost never steps
like that, and a slope could only face along x or z with its high side up -- never on a wall
turning in plan, never a corner. Now each candidate piece is tested against the **field
itself**:

- Surface cells: a part's brick cells with an empty neighbour. The field's slope there
  (its gradient) picks the candidates: every shaped piece, in every turn and flip, whose
  open side faces within ~45 degrees of it, placed every way its box covers that cell.
- A candidate's box must hold only this part's brick cells (not yet taken) or empty space.
- Its **fit** is counted on the field's own samples (5 x 2 x 5 a cell): where the piece is
  solid and the field inside, or the piece empty and the field outside. The plain cells
  (the box's cells as bricks) are counted the same way. A piece goes in when it fits better
  by a margin (8% of its samples; eager, at curve level 4: 4%), best gain first, no two
  overlapping.
- In C++ (`SdfForm.fit_pieces`): the piece's samples come from the catalogue's shapes
  (`ShapedParts`), turned as `BrickWorld` turns a part, built once per piece in GDScript.
- The curve slider keeps its meaning: 0 steps only, 1 slopes, wedges and cheese, 2 and up
  curves too, 4 eager. A fitted piece stands for its box's cells the field had, so Edit as
  SDF and Convert again give the same cells, as before.

**New pieces**, all profiles extruded (so the print kit and the game draw them as they do
slopes): `slope_1x3`, `slope_2x3` (one plate a stud, the shallow 33-degree slope);
**wedge plates** `wedgeplate_2x2`, `wedgeplate_2x4` (a plate cut corner to corner across its
footprint: an edge running diagonally in plan) and **wedge bricks** `wedge_2x2`,
`wedge_2x4` (the same, three plates high). Flipped, a wedge is its mirror image. Convert also
uses the pieces the sketch never did: `cheese_*`, `curve_1x3`, `curve_1x4`, `curve_2x4`.

**3. The lathe** (a stamp shape, "lathe: axis, then outline"): drag the axis as for a
cylinder (LMB to add, RMB to carve); then each LMB click adds a point of the outline -- how
far along the axis, how far out from it, on the stroke plane. The outline turned round the
axis shows as lines on both sides of it as it grows. Enter (or a click on the last point)
lays it, Backspace takes the last point back, Escape drops it. One undo. In C++:
`SdfForm.lathe(op, transform, profile, blend, part)`: the profile (out, along) closed down
to the axis at its two ends, turned about the local y axis (IQ's polygon distance in the
(r, y) half-plane).

**4. A 3D model as SDF.** The sculpt panel gets **add a 3D model...** (glTF, GLB, FBX):
the model loads as a guide (its real length from the guide panel's box, turned and nudged
there) and goes straight into the current part's field (`SdfForm.stamp_mesh`, which was
"fill from guides"), one undo; the guide stays, faint, to trace by. **Model into this part**
and **carve the model out** act on the guide picked in the guide panel, after it is moved.

Checks: `sdf_form_probe` (a lathe's cone and cylinder against the stamp's, fit_pieces lays a
slope on a 45-degree ramp, a wedge on a ramp turned 45 degrees in plan, nothing on a box),
`asset_workshop_probe` (the two rail tools, a sculpted ramp converts with slopes and round
trips, the lathe one undo, a model stamped from a mesh). `palette_probe` and `shaped_probe`
cover the new pieces.

**Built 2026-10-19**, as above, with these differences found on the way:

- The fit's margin is **3%** of a piece's samples (eager 1.5%), not 8%: a wall running
  diagonally in plan matches a wedge exactly only where its line passes through the wedge's
  corners; elsewhere a wedge beats the stairs by 2-4%. The test gun (`-- --shot --sculpt
  --plain --convert`) now converts to 196 bricks of which 122 are shaped (82 cheese 1x1, 21
  curve 2x2, slopes 1x2 / 2x2 / 2x4, a wedge), in 0.13 s; the slice rule gave it almost none.
- "fill from guides" went (it stamped every guide at once); **model into this part** and
  **carve the model out** act on the one picked.
- A lathe being drawn is dropped when another shape or tool is picked.
- The part sheets (`tools/part_sheets.gd`, Docs/Parts) were behind: cheese and the long curves
  had no sheet or profile; they and the new pieces have now.

sdf_form_probe 38 (6 new), asset_workshop_probe 251, palette_probe 1858 (its family-height
rule knows a wedge is a brick), shaped_probe 424, orient_probe 51, workshop_probe 96.
`-- --shot --sculpt --stamps` adds a lathe (a muzzle brake) and leaves a lathe's ghost showing.

### SDF tools, round 4: a model placed by a gizmo, the gun's size, the game's view (2026-10-19)

The user (2026-10-19), after loading a model into the SDF: it converts to bricks very well,
but it **spawns twice** -- a huge blue guide and a small SDF copy -- and only the SDF one is
wanted; a **gizmo** to move, resize and turn it; it spawned far from the grid. And: build in
**sizing**, starting with the SMG -- mark on the grid how long the gun is in nano studs, use
the **pistol grip** as the sizing helper (every gun's grip the same size, so the printed guns
share one hand), and **see it in the game's first-person view**. Written here first, then
built in this order.

**Why two copies.** The test model is skinned (a character on a skeleton). The guide is drawn
posed by its skeleton, which scales and turns it (an armature at 1/100, lying the model down
or standing it up); the stamp read the mesh's raw vertices with only the mesh node's own
transform, so it went in at the bind pose's size and lying the other way. The box that sized
the guide was read the same raw way. Fix: a model is **flattened when it loads** -- every
mesh, a skinned one baked in its current pose (`bake_mesh_from_current_skeleton_pose`), put
into the model's own frame as one mesh. The box, the drawing and the stamp all read that one
mesh, so they agree.

**1. A placed model (the sculpt panel's "add a 3D model...").** No guide any more: the
model goes into the current part's field and stays **placed** -- movable -- until it is laid.

- It spawns **on the grid**: its longest side the gun class's real length (below; the SMG's
  852 mm, 53 studs), standing on the plate, centred on the build area and the mirror plane,
  its long side along x. The view frames it.
- A **gizmo** sits on it: three arrows (x red, y green, z blue) move it along an axis, three
  rings turn it about one, and a white cube at its middle resizes it evenly (drag up or out
  to grow). Moves snap to a quarter stud, turns to 15 degrees, sizes to 1% -- Shift drags
  free. Under the drag the model shows as a see-through ghost in the part's colour; on release
  the field is put back as it was before the model and the model stamped where it now is.
- **Enter** (or "lay the model", or picking another tool) lays it: the gizmo goes, the
  model's stamps from first to last are **one undo**. **Escape** takes it back out. While it
  is placed the panel shows its size: studs long, real and print mm.
- "Carve the model out" carves a placed model's shape out instead of adding it (the same
  gizmo, red ghost).
- The guide panel (F3) still loads guides to trace inside -- blue, see-through, never in the
  field -- for anyone who wants one; "model into this part" stays there for a guide.

**2. The gun's size on the grid.** A gun is built at a quarter of the real one, in nano
bricks (Docs/Parts/joints.md section 7): **one stud here is a nano stud** -- 4 mm printed,
16 mm of the real gun -- half a building brick's stud. The game then shrinks the gun again
to the hands. A **gun class** picker (Gun menu and the sculpt panel; SMG first, then rifle
and pistol from the same table) draws on the grid:

- a **length ruler** along x on the plate, from the butt's end: a tick a stud, numbers every
  5, and the class's length marked -- the SMG's **53 studs = 852 mm real = 213 mm print** --
  with a faint band to it;
- the **grip box**: the one grip every gun shares, where the hand closes -- **6 studs long
  (24 mm print), 3 fore and aft, 2 thick**, standing under the body at an SMG's grip place
  (a quarter of the length from the butt), raked back 15 degrees like a real pistol grip.
  Size a model by its grip: resize it until its grip fills the box, then the rest of it is at
  scale and its grip fits the shared printed hand.

The ruler's butt is at the build's back end once there is one (the field's or the bricks'
box, the muzzle end as `settle_muzzle` reads it), else where a placed model spawns.

**3. The game's view** (View menu, Alt C): the workshop's camera becomes the first-person
one, framed exactly as `PlayerView` frames a held gun: horizontal FOV 90, the gun scaled so
its length is the class's view length (an SMG reads 0.4 m in the hands -- the game scales
each class to that, whatever the model's size), the top of its back end at the hip pose
(0.12 right, 0.06 down, 0.3 ahead), muzzle forward. Alt C again (or any view key) goes back.
Hands (Alt H) show if on. It frames whatever is showing: the field or the bricks. A second
press of the view's button (or right mouse) toggles aiming down the sights (the ADS pose).

Note what the sizes do: in the game's view the class length decides how big the gun looks;
the stud count decides its proportions and that it prints at the right size with the shared
grip.

Checks: `asset_workshop_probe` -- a skinned or scaled mesh stamps where its drawing is (the
field's box against the model's), a placed model moved twice and laid is one undo and Escape
leaves the field as before, the spawn stands on the grid, the ruler's SMG length is 53 studs,
the game view's camera puts the gun's back top at the hip pose. Picture pass: `-- --shot
--sculpt --model` (a placed model with its gizmo, the ruler and grip box) and `--gameview`.

**Built 2026-10-19**, as above, with these differences found on the way:

- The skinned test robot (`TestRobot.glb`, armature at 1/100) now reads standing; its field's
  box matches the model's to 0.05 stud. Godot's own `bake_mesh_from_current_skeleton_pose`
  refuses a scene not yet in the tree, so `ModelMesh` (scripts/model_mesh.gd) skins by hand:
  bone pose times bind pose, weighted. Reading it and the first stamp take about 0.6 s; a
  stamp again on letting go of the gizmo about half that.
- A model's surfaces are stamped as **one** triangle soup (a model split by material is one
  closed solid; stamped a surface at a time, each open surface counted inside wrongly). The
  guide panel's "model into this part" does the same.
- A brush stroke, a tool change, Z / Shift Z or Convert lays a placed model first, so its
  record never covers someone else's edit.
- The size marks are hidden in the game's view. The view takes RMB to aim; Escape, Alt C or a
  view key leaves it.

asset_workshop_probe 271 (20 new: a skinned mesh flattened, a model placed, moved, snapped,
dropped, laid as one undo, the gizmo's handles picked, the ruler, the game view's camera at the
hip and the sights), sdf_form_probe 38, workshop_probe 96. `-- --shot --model` (the gizmo, the
ruler and grip box) and `-- --shot --model --gameview`.

**Fixes and nudges (2026-10-19, later).** The user: moving the SDF with the gizmo made it
disappear; wanted buttons to move it half a stud or a stud each way, since a model sitting
half a stud off converts badly; and which model files load.

- **Why it vanished:** the resize cube scaled by the mouse's distance from the gizmo's middle
  over where the drag began. Grabbed at the middle (where the cube is) that start is a few
  pixels, so a short drag made the model ten or more times over; `stamp_mesh` refuses a model
  that big (over 400 million samples), and the field was left empty. Now 200 px right or up
  doubles it (left or down halves), held between a stud and 250 studs long. An arrow pointing
  nearly at the camera no longer moves (there a pixel meant metres), a move is held to 60 m,
  and the gizmo reads the ray at the event's own position.
- **Nudges** (sculpt panel): left, right, up, down, front, back (as the side view shows them),
  by **half a stud** (up and down: a plate) or **a stud** (a brick). They move the placed
  model, or with none placed the whole block-out (`SdfForm.move`, one undo: exact for whole
  samples; half a stud is 2.5 samples and is resampled). **Snap to studs** puts the placed
  model's (else the block-out's) near corner on a whole stud and its bottom on a plate.
- **Files:** glTF / GLB and FBX (Godot's importers), and now **OBJ** and **STL** (read in
  `ModelMesh`). The size never matters: a model is resized to the gun class's length.

asset_workshop_probe 279 (8 new).

### Symmetric Convert, and what a bigger gun costs (2026-10-20)

The user: a symmetrical SDF (a T-posed robot) converts to bricks that are not symmetrical,
however it is moved left or right; is it the size? A middle line on the stud grid to line
the SDF up with. And: should guns be more studs for detail -- what do 2x studs cost?

**Why it is never symmetrical.** Two causes, and moving only fixes the first:

1. *Where the middle falls.* Cells are solid where their middle is inside. A shape is
   symmetrical in cells only if its middle plane is on a stud line or a stud's middle. A model
   is spawned at the class's length (an SMG 53.25 studs), so its middle lands a quarter stud
   off; "snap to studs" put its *corner* on a stud, which leaves the middle off for a width
   that is not whole.
2. *The packer.* `pack_cells` sweeps each layer along x then z (back and forth a layer, for
   the bond) and takes the first brick that fits, and `fit_pieces` takes the best gain first.
   Even symmetrical cells come out as different bricks on each side.

**The fix.** With the mirror on (Alt S, its plane across z: the gun's left and right):

- **Centre on the mirror** (sculpt panel): moves the placed model, else the block-out, across
  z so its middle is on the mirror plane; and the plane is kept on a **stud line** (a whole
  stud), not a stud's middle -- see the next point. The plane shows as the mirror sheet.
- **Convert mirrors one half.** The cells on the near side (z below the plane) are the truth;
  the far side is made their mirror image. The two columns either side of the plane are packed
  first, only with bricks two studs across (a 1 x 2 turned, a 2 x N) sitting on the plane, so
  the halves are joined -- bricks mirrored half against half would leave the gun in two pieces
  that nothing holds together. The near half is packed and fitted (slopes, wedges, curves) on
  its own, and every brick and piece is mirrored across: a plain brick to the mirrored place,
  a shaped piece to the turn of it whose samples are the mirror image (found by comparing the
  kit's grids). Old bricks are not reused at a symmetrical Convert.
- A plane on a stud's middle cannot be bridged symmetrically (it would need bricks an odd number
  of studs across, centred), so Centre puts it on a stud line, and Convert moves a plane left on
  a stud's middle half a stud first, saying so.

**What 2x studs cost** (measured: the box SMG and the TestRobot, converted at 1x and at 2x):

| | Bricks | Triangles | of them studs | Convert |
|---|---|---|---|---|
| box SMG, 53 studs | 186 | 9,700 | 2,900 | 0.3 s |
| box SMG, 2x (107 studs) | 907 | 46,300 | 20,400 | 1.8 s |
| TestRobot, 52 studs | 835 | 33,500 | 6,000 | 1.0 s |
| TestRobot, 2x | 4,119 | 151,600 | 22,600 | 4.9 s |

Triangles go up about 4.5-5x (the surface, not the volume: hidden faces are not drawn). One
held gun at 50k is cheap; every enemy's gun at that, near, is not (twenty is a million), so
2x guns would want the studs dropped at a distance. The print doubles: an SMG 426 mm instead
of 213, and the shared grip 12 studs. In the game every gun is shown at its class's length
(an SMG 0.4 m), so 2x studs make each stud half as big on screen -- finer detail, and studs
small enough to shimmer. Not decided; the user is told the numbers.

**Built 2026-10-20** as planned. "centre on mirror" (sculpt panel) turns the mirror on if it is off. All 136 turns of the fitted pieces have a mirror twin among their part's turns (52 are their own). asset_workshop_probe 281: a capsule placed a quarter stud off, centred and converted -- every brick has its mirror image, and bricks cross the plane. The mirror plane is across z (the gun's left and right): a model symmetrical left to right as seen from the side (the T-posed robot facing the camera) is turned a quarter first (the gizmo's green ring).

### Models as objects, pieces as parts, spawning at the grid (2026-10-20)

The user (2026-10-20): models (and the ruler) still spawn away from the grid -- why? Keep the
sizes. Each imported model its own thing, several in a scene; a model of several pieces
imported with a colour each, so each piece can be given to one of the gun's parts; the gizmo
comes back after the first placing (it is gone for good once laid, even back in SDF). And:
how would this scale to building-sized models?

**Why away from the grid.** The grid is drawn round the bricks (`build_centre`, the middle of
the recipe); while sculpting that is only the starting brick, the field not counted. A model
spawned at a fixed place instead -- the middle of the 1000-stud area, on its bottom plate --
and the starting brick stands 30 plates up, or wherever a loaded gun's bricks are. The ruler
starts at the model's end and lies on the bottom plate, so it was off too. Fix: one centre.
`build_centre` counts the field and the models while sculpting; a model spawns centred
there (on the mirror plane across); the ruler lies under the build's own bottom; the grid is
drawn again after a model is added or moved.

**1. Models are objects.** Each imported model is kept as itself, not stamped into the
block-out: its own small field (`SdfForm`), drawn as the block-out is (so what is seen is what
converts), moved by the gizmo at any time -- also after Convert and Edit as SDF. Several in a
scene.

- **Pick one**: the sculpt mode **models: pick and move** -- LMB on a model selects it and
  the gizmo comes back; LMB on nothing deselects. Also the models list in the sculpt panel.
  Enter or Esc deselects. **Remove** takes it away.
- Moving one stamps only its own field again (0.3 s for the test robot). Every add, move,
  nudge, part change and removal is one undo.
- **Convert** joins the block-out and every model (`SdfForm.combine`, union or carve) before
  making bricks, and takes them out again after, so the models stay objects. Bricks taken
  away inside a model come back at the next Convert; **bake into SDF** joins a model into the
  block-out for good (then the brushes carve and smooth it, and it is no longer an object).
  The brushes act on the block-out only; to carve a model, bake it.
- Saved with the gun: each model's file, where it stands and its pieces' parts (the file is
  read again on load).

**2. Pieces.** A model is read as its pieces: each mesh node of a glTF / FBX, each `o` or `g`
of an OBJ (an STL is one piece). Each piece is drawn in a colour of its own until it is given
a part; the models section lists the selected model's pieces, each with a part picker (the gun's
parts: body, barrel, stock, grip ...). A piece given a part takes that part's colour and its
cells are that part's at Convert; the rest go to the part that was current when the model was
added. A piece must be closed to fill solid (as before).

**3. Building-sized models, later.** Written down, not built: see the answer in chat
(2026-10-20) -- the field is sparse (only blocks near a surface), but Convert's packer and
fitting are GDScript and go about 800 bricks a second; the stamp builds a dense box (refused
over 400 million samples, about 1000 studs long); and the brick mesher would need distance
levels. A building would want the same field at the building's stud (a stud a sample block
of 5), Convert in C++ chunk by chunk, stamping in chunks, and far levels from the field.

Checks: `asset_workshop_probe` -- two models in a scene, picked by a ray, moved, one undo each,
a piece given a part converts to that part, the models survive Convert and Edit as SDF, bake
joins one into the block-out, spawn at the build's centre; `sdf_form_probe` -- combine.

**Built 2026-10-20** as planned, but the combine is checked in `asset_workshop_probe` (Convert tags a piece's cells with its part; bake) rather than in `sdf_form_probe`. Undo and Remove deselect; Escape and Enter let the selected model go without removing it. asset_workshop_probe 286 (the old placed-model checks rewritten for objects), sdf_form_probe 38. `-- --shot --model`: the model inside the grid, the ruler under it.

### A second model beside the first, undo keeps the pick (2026-10-20)

The user (2026-10-20) picked this from the handoff's gaps: a second model spawns on top of the
first (both centred on the build), and undo lets the selected model go.

- **Where a model spawns.** The first, as now: centred on the build (the grid's middle), on
  the mirror plane, on the bottom plate. Every one after it spawns **beside the models already
  there**, across z on the near side (+z, the side the view looks from): its far side two
  studs past their near side, rounded out to a whole stud so it starts on a stud line; along
  x centred on the build as before; its bottom on theirs (the lowest model's), not lower than
  the bottom plate. So it never overlaps another model and it is framed in front of them. It
  is off the mirror plane; "centre on mirror" puts it there. The block-out does not push it
  aside (a model added onto a sculpt may be meant to join it).
- **Undo and redo keep the selection.** The model selected before Z / Shift Z stays selected
  (the gizmo where it now stands) if it is still there after; one the undo takes away is let
  go. Remove still lets go.

Checks (`asset_workshop_probe`): a second model's box does not meet the first's, starts two
studs or more past it on +z on a stud line, and stands on the same bottom; a move undone
leaves the model selected with the gizmo on its new place.

**Built 2026-10-20** as planned. Z and Shift Z had let the model go before running (left over
from when a placed model was stamped into the block-out and "laid" there); now they note the
pick and give it back after, only while the block-out is showing (an undo back to bricks lets
it go). asset_workshop_probe 288 (2 new).

### Pick and move: sculpted parts, pieces, guides (2026-10-21)

The user (2026-10-21): do all three of the handoff's next items -- move / grab for sculpted
parts, selecting a piece, the gizmo on the F3 guide models. Written here first.

The sculpt mode "models: pick and move" becomes **pick and move** (models, parts, pieces,
guides): LMB picks whatever the mouse's ray meets first -- a model, a part of the block-out,
or a guide -- and the same gizmo (arrows move, rings turn, cube resizes; quarter stud, 15
degrees, 1%; Shift free) goes on it. LMB on nothing lets go. The nudges, "snap to studs" and
"centre on mirror" act on whatever is picked.

**1. A sculpted part moved (grab).** LMB on the block-out picks the part under the mouse (its
label there) and **lifts** it: the part's samples are taken out of the block-out into a field
of their own (`SdfForm.take_part`), drawn on its own, and the gizmo goes on it. While it is
dragged only its drawing moves (no resampling, so a drag is free). When it is let go (Enter,
LMB on nothing, another pick, a brush stroke, Convert, a tool change, Z) it is resampled where
it now stands (`SdfForm.transform`, any turn and size) and joined back (`combine`): the lift
and every move of it are **one undo**. **Escape** puts it back exactly as it was (no undo).
Where the part touched another, the other keeps its own samples (that side is open until
something fills it, as when a part is moved by hand in clay); the lifted part's samples that
were inside are its own. Its colour, smooth marks and label go with it.

Engine (`SdfForm`):

| Call | What |
|---|---|
| `take_part(label)` | a new form holding that part: its samples as they are, every other part's solid counted just outside (as `part_field` does); in this form that part's solid becomes just outside. Recorded by `begin_edit` like any edit |
| `transform(xform)` | the whole form resampled through any affine `xform` (samples to samples): distances trilinear, scaled by the transform's size, labels and flags from the nearest sample. `scale` and `move` become this |

**2. Selecting a piece.** LMB on a model also picks the **piece** under the mouse (the label
its own field has there). The piece shows lighter, its row in the pieces list is marked, and
**give the piece this part** (a button under the list) gives it the current part (one undo,
as its picker does). Picking the model in the models list picks no piece.

**3. The gizmo on guides (F3).** A guide picked in the guide panel's list, or by LMB in pick
and move (its triangles under the ray), gets the gizmo. A guide keeps its fit (real length,
quarter turns, stud offset: the panel's buttons, as before) and gains a free **adjust**: the
gizmo's move / turn / size on top of the fit, saved with it (`meta.asset.guides[].adjust`, 12
numbers). Guides are not in the undo (as before). The panel's buttons still work and keep the
adjust.

Checks: `sdf_form_probe` -- take_part splits a two-part form and combine puts it back to the
same cells; transform by whole samples matches move, a quarter turn swaps a box's sides.
`asset_workshop_probe` -- a part picked by a ray lifts (the block-out without it, gizmo on),
moved two studs and let go is one undo with its cells two studs along, Escape leaves the field
as before; a piece picked by a ray, given a part; a guide picked, moved, its adjust kept
through "turn 90" and saved.

**Built 2026-10-21** as planned. A lifted part keeps the record of its lift; putting it down
first puts the block-out back as it was before the lift and then takes the part out again,
moved, so the one undo starts from before the lift (and Escape is that first step alone).
Edits that need the block-out whole (a brush stroke, Convert, Z, a tool change, "model into
this part") put a lifted part down first; a picked guide stays picked through them. Shift Z
with a moved part lifted puts it down, which is a new edit: nothing is left to redo. The
gizmo now answers in any tool (a guide picked from the F3 panel), not only in Sculpt.
sdf_form_probe 43 (5 new), asset_workshop_probe 296 (8 new). Picture pass: `-- --shot --sculpt
--pick` -- the block-out's barrel lifted, raised and turned under the gizmo, and the test gun as a
model of five pieces beside it, its second piece picked (lighter).

### Convert lost the block-out; one place for everything (2026-10-24)

The user: drew, pressed Convert, and the block-out vanished with no bricks; the measuring was
off from the grid; the gizmo could be clicked but only started drawing. Their autosave: the
mirror on, its plane at 41 studs across -- kept from when the area was 80 studs -- while they drew
near 500. Convert kept the near side of the plane (z < plane) and mirrored it; the drawing was
all past it, so it laid nothing and hid the block-out; Edit as SDF then took every recorded cell
without a brick as deleted and wiped it.

Now: the side holding the drawing is the truth; Convert refuses -- keeping the block-out and
saying why -- when all of it, or its mirror half, would be outside the build area, and says how
many cells it left out when some are; Edit as SDF only takes back cells that could have been
bricks; a mirror image outside the area is not drawn. New puts the mirror and working planes in
the middle of the area with the camera, grid and starting brick, and a loaded plane off the
block-out is moved onto it. The gizmo is "pick and move"'s alone (`set_sculpt_mode`): picking or
adding a model goes there, a drawing mode hides it. asset_workshop_probe `_one_place`.

### The asset workshop's frame (2026-10-25)

The user: the UI is complicated and not intuitive. Wanted: each imported asset one item, its
pieces children of its main body; a list top right of everything, to select from and edit;
fewer tools on the left with a pop-up saying what each does; stages of work, with only what a
stage can do; the gizmo only with Select, drawing only with Draw; Convert gone for what is
already bricks. Looked at first: Substance 3D Modeler (a small palette, a separate gizmo, an
Outliner to select, hide, group), Blender (outliner children under parents; workspaces per kind
of work), BrickLink Studio (submodels, steps), MagicaVoxel (few brushes x attach/erase/paint),
Fusion 360 (a workspace switcher -- and Autodesk's own note that users got lost between modes).

Built (`AssetWorkshopUI`, `scripts/asset_workshop_ui.gd`). It holds no state that matters: every
button calls the workshop's own functions, and what is lit is read back each frame, so a key
does the same as its button.

1. **Stage tabs**, top left: *1 Block out* (clay: SDF), *2 Bricks*, *3 Detail*, *4 Finish*. A tab
   changes the tools, never the build. Beside them one button: **Make bricks** while it is clay
   (Convert, then the Bricks stage), **Back to clay** once it is bricks (Edit as SDF, then
   Block out). On the wrong stage the hint line says which to press.
2. **Outliner**, top right: the asset (its kind, clay or bricks); each imported model one item --
   named for its file and its first piece, the main body -- with its other pieces as children,
   each with its part chosen in its row; the parts (clay, or how many bricks); guide models and
   photos. A tick shows or hides. A row selects: a model or piece goes to Select with the gizmo
   on it. Under it, what the selection can do: Make bricks (only while clay), Back to clay,
   Remove and Bake into clay (models), Mirror through it, Frame it.
3. **Tool rail**, under the tabs: a stage's few tools, each with a pop-up (what it does, its key)
   and a line under them for the tool in hand. Block out: Select, Draw, Shape, Smooth, Import
   model, Measure. Bricks: Place, Select, Paint, Sketch, Shapes, Move part, Measure. Detail:
   Studs, Connection point, Paint, Measure. Finish: Explode, Hands and Play (guns), Export to
   game, Export to print, Save as. The other sculpt modes (flatten, grow, paint, mark smooth)
   stay in Draw's options.
4. **Options**, under the rail: the old rail with its tool list and finish buttons hidden -- the
   part picker and the open tool's own options. Its how-to paragraphs went (the pop-ups say it).
5. **Select alone has the gizmo** (above); Draw, Shape and Smooth only draw.
6. **The selection is the centre**: `build_centre` is the picked thing's middle, so the grid,
   the size marks and the view go to it ("Frame it"); "Mirror through it" puts the plane there.
7. **A kind's menus**: Gun only for a gun, Mech only for a mech.

What the workshop says (a refused Convert, a moved plane) also shows big at the top for a few
seconds, and the building workshop's brick readout is hidden in Block out.
`tools/asset_ui_probe.gd`: 28 checks.

Not yet: renaming or regrouping in the outliner, dragging a piece onto a part (its row's list
does it), a part's own Make bricks (Convert is the whole block-out), icons on the rail.

### Furniture and items (2026-10-23)

The user (2026-10-23): build furniture and household items here, since the tools are better for
them than the building workshop's; place them like bricks, in the workshop and in the game
worlds; filter them by planet, then by furniture or item, then by room. Buildings keep their
generated rooms, and there will also be fully authored buildings with authored rooms.

**Two types, named for the player.** *Furniture* -- beds, desks, shelves, counters, benches --
is `BuildRecipe.Role.INTERIOR`: drawn from far off (60 m), through windows and holes.
*Items* -- cups, books, lamps, food -- are `Role.DETAIL`: drawn only up close (20 m). The code
keeps the role names; only the menus say Furniture. How a building breaks is unchanged for both
(Interiors.md §3.1, §8): they weigh nothing, hold nothing up, ride the floor they stand on, and
a hit lays them as bricks.

**Tags, three levels, from one file.** `data/asset_tags.json` lists the levels in filter order;
`AssetTags` (`scripts/asset_tags.gd`) reads it. Adding a level or a value is a line in that file:
the Save As dialog, the filter and the generator all take it from there.

| Level | Choice | Values | Empty means |
|---|---|---|---|
| 1. Planet | several | Earth (more as they come) | Common: every planet |
| 2. Type | one | Furniture, Item | -- (always set) |
| 3. Room | several | `Room.KINDS` but empty: storeroom, office, kitchen, bedroom, living, bathroom, lab, shop | Any room |

A filter ANDs the levels and ORs within one: Earth, Furniture, Kitchen or Bedroom. An asset's
tags are in its file, `meta.tags` (level -> list), never in folders, because a folder cannot put
one chair under two rooms. A file saved before tags reads its `room_kind`/`room_kinds` as its
rooms and its bricks as its type (all Detail is an item).

**Built 2026-10-23 (stage 1).** *Asset > Make furniture or an item* sets the build's kind to
`item`; Save As then shows the three levels as boxes to tick (Type as one choice) and saves to
`user://items/` -- the folder the generator already furnishes rooms from (`RoomTemplates`), so
a new chair tagged Kitchen turns up in generated kitchens with nothing else done. An item
tagged for some planets only is furnished on those (`RoomTemplates.planet`, Earth today).
Registered as Item, every brick is Detail; as Furniture, a brick is Interior unless it was built
as Detail (a table with a cup: the cup stays an item). Open lists items in the asset workshop
too. `tools/asset_tags_probe.gd`: 32 checks.

**Built 2026-10-23 (stages 2 and 3).**

*The catalogue* (`AssetCatalog`, `scripts/asset_catalog.gd`; the panel `AssetCatalogPanel`):
every file in the item library with its tags, one panel for the workshop and the game. Each
level is a row of chips -- All, then each value with how many it would leave, greyed when that
is none -- over a search box and the list; picking from the list puts the piece in hand. The
filter is remembered (`user://asset_catalog.json`).

*The placer in the workshop* (`FurnishTool`, `scripts/furnish_tool.gd`), both workshops: **F6**
opens the catalogue. The piece in hand is a ghost centred on the stud under the cursor, on top
of the bricks in that column or of a piece already placed (a cup on a table); R turns it a
quarter, LMB places it (it stays in hand), RMB takes away the placed piece under the cursor, Esc
puts it down and then closes. Each place and take-away is one undo step ("furnish").

**A build keeps a placement, not the bricks**: `recipe.placements`, `{asset, cell, turn}`
(`AssetPlacements`). The workshop draws them from the asset's file and keeps them out of its
chunk (block id there is recipe index). They go into the city as bricks
(`AssetPlacements.expand`, called by `BuildingRegistry.register_build` and the city's ghost),
after the build's own so no block id of its own moves: Interior for furniture, Detail for an
item, the author's colours. So a chair edited and saved again is the new chair in every build
laid after. Turning or inserting a build turns and moves its placements; an asset whose file is
gone is left out with a warning. Generated rooms keep placing by seed.
`tools/furnish_probe.gd`: 40 checks.

A trap met on the way: a static var set from a probe was reset when a scene loaded (loading
reloads the scripts). The probe's test folder is kept on `Engine` meta (`AssetCatalog.use_dir`).

**Built 2026-10-23 (stages 4 and 5): placing in a game world** (`WorldFurnisher`,
`scripts/world_furnisher.gd`; the city scene's `_setup_furnisher`). **F6** opens the same
catalogue, filtered to the planet underfoot (`planet`, Earth). The ghost follows the aim; R turns,
LMB places, RMB puts the piece down, Backspace takes back the last piece placed (unless it has
been shot or laid since: then it is the world's), Esc closes. Where the aim lands decides what a
placement is:

* **A room of a generated building** -- the nearest room floor along the aim, or the top of a
  piece already in the room, short of whatever the physics ray hits first (a wall). The piece
  goes into that room's own list, `room.items`, as `{type: item:<id>@<turn>, cell, yaw}`, the
  same record the generator writes. It must stay inside the room, off its columns and clear of
  other pieces. From then on it is the generator's furniture in every way: drawn with its storey
  group by distance (Interiors.md 8.2), laid as bricks when a blast reaches it (8.4), riding a
  floor that falls (8.3). `Room.placed_edits` moves the room's `diff_stamp` so its group redraws.
* **A player build** -- laid at once into its chunk as decorative bricks
  (`RoomManifest.build_item`), inside the build's own box, as its own furniture is.
* **Anywhere else: outdoors** (`OutdoorProps`, `scripts/outdoor_props.gd`) -- on the course just
  above what the aim hit, clear of other props and of every building's box. Cheap until touched:
  - *drawn* as one MultiMesh per (asset, turn) per 16 m tile, Godot's visibility range as the
    LOD: furniture to 60 m, items to 20 m (InteriorGroups' ranges), faded over 6 m. Measured from
    the tile's middle, so the edge is up to a tile's half-diagonal off;
  - *solid*: a box per prop in a static body per tile, on `Layers.WORLD`;
  - *bricks when hit*: `_apply_blast` first promotes every prop it reaches to a small build of
    its own (`OutdoorProps.promote`), its bricks as STRUCTURE (out here nothing else holds it up,
    and a decorative block has no body), indexed, shelled and saved as any placed build is. It
    is then ordinary brick destruction.

`tools/world_furnish_probe.gd`: 31 checks (a room upstairs furnished, a cup stacked on the
placed table, refused into the table and through a wall, the table laid as bricks like a
generated piece; a player build; props drawn and ranged by type, refused on a taken spot and in
a building's box, promoted by a blast at them and only them).

Not yet: pieces placed in rooms or outdoors are not in a save or the damage log (only promoted
props are, as placed builds), so a checkpoint loads without them and a client is not told; the
ghost is not checked against anything but the room's own pieces and walls; and props carry no
distance-ranged LOD finer than on/off.

Open: the asset workshop's gun tools (parts, hands, export) still show for an item; its ruler
reads gun scale (a stud = 16 mm), while an item placed in a building is at city scale (a stud =
0.35 m). Custom and fitted pieces are not yet carried into a room: only bricks are.

### Planned: the form, sliders and shells (2026-10-17, not built)

**How the block-out is used** (the user, 2026-10-17): a quick start. Draw the asset's
shape, size it, then fine-tune with the other tools; it is not expected to be used again on
that asset. So the sliders act on the block-out before the hand work, and nothing has to
keep hand edits in step with the form.

Each part keeps a smooth **form** (its sketch outlines, which are already finer than the
grid, and shape brushes as smooth solids); bricks are always worked out again from it, on
the grid, the inside always filled largest brick first. Sliders: size (done), how many
curves (a curve or slope fitted in any of its 24 turns where the form's surface leans),
smoothness. **Slopes at any pitch** are an option: a generated `ShapedParts` profile per
pitch. **Shells**: a custom part off the grid, from the form's surface in by a chosen
thickness, its inner side hugging the brick core; placed by region, selected and changed
afterwards, with a **triangle slider** of its own (low poly to smooth). Where a shell meets
the rest it is cut round real bricks embedded in it, which give it its studs and sockets,
so it models none; faces between them are culled.

**Small custom parts** (a coffee cup a 1x1 brick big, low poly): a block-out finer than the
grid -- a profile turned round an axis (as `gunsmith.py`'s turned parts), or drawn and
extruded -- made into one custom part with the same triangle slider, taking the cells it
covers on the grid.

In order: the triangle readout (done), the form and the core fill (done), the size slider
(done), the curve slider (done; sideways pieces next), shells with their triangle slider, embedded bricks and culling,
selecting and changing shells, small custom parts.

### Phase 2 -- build a whole gun split by part

| Tool | Key | What it does |
|---|---|---|
| **Part toolbars** | Y cycles | several hotbars, each bound to a part (barrel, stock, grip ...). Every brick placed is tagged with the part of the toolbar it came from, so the split lines are built in. Each part keeps its own nine slots |
| **Drag place** | hold LMB, drag | the held brick laid again and again on the plane of the first one, wherever the cursor passes: a line, a wall, a floor |
| **Connection points** | J | place a mount or a socket on the lattice for the current part and pick its interface (`stock.tang` ...): the gun system's `socket_<slot>` / `mount` |

### Phase 3 -- block out fast

| Tool | Key | What it does |
|---|---|---|
| **Shape drag** | K, then drag | box, rectangle, cylinder, circle, sphere, wedge. Filled **clean** (fewest bricks, studs holding) or **random** (mixed sizes) |
| **Box select** | L, drag | a region: move, copy, delete, or re-pack it clean |
| **Guide models** | F3 (panel) | load an existing model (glTF, FBX, OBJ) on its own locked, see-through layer, and build inside it. A bought model is a guide only: it is never exported ([custom.md](Parts/custom.md) section 6) |
| **Parts catalogue** | F7 (panel) | every saved part, official and custom, to filter by any maker, part, class, gun class, creator or tag, search and sort; **Fits** lists only what goes on the socket of the part being built. Double click a part to **try it on** its slot, fitting or not: drawn where the socket is, marked red with why when it does not fit, never saved ([ModularParts.md](ModularParts.md) sections 6 and 9) |
| **Mech mode** | Asset > Make a mech; the Mech menu | a mech's ten parts (chassis, head, arms, hands, legs, pods), a class and a leg length, a reference mech of joints to build round and every joint's mount and socket laid ready; Save writes each part on its own ([ModularParts.md](ModularParts.md) stage 5) |
| **Section view** | O | hide everything past a plane, to build inside |
| **Isolate / explode** | P | show only the current part, or pull the parts apart; tint bricks by part |

### Phase 4 -- out the other end

| Tool | Key | What it does |
|---|---|---|
| **Mark smooth** | N | paint a part's role: stays bricks, or becomes a smooth custom piece (its brick outline is lofted, as the traced stock and grip were) |
| **Wand** | F4, click a photo | the patch of the photo's colour under the click, filled with bricks for the current part, so many studs across on the mirror plane; then fix it by hand |
| **Live readout** | always on | each part's bricks (~ marks smooth ones) and the asset's length in the game; after an export, the part kit's checks: loose bricks, the grip, joints meeting |
| **Export** | F12 | write the build sheet to `user://asset_exports/`, run the part kit in Blender (`BRICKCITY_BLENDER` if it is not in the usual place), and show its picture and checks here. A smooth part leaves as a loft of its brick outline -- along the gun if it is longer than tall, else up it; the rest leave as laid. The muzzle is the low-x end unless `meta.asset.muzzle` is `+x` |
| **Undo / redo** | Z / shift Z | a fill, a copy or a mirrored pair undoes at once; redo lays it back, each brick in its own part |

---

## 3. What is saved

Everything the asset workshop adds lives in the build's recipe, in `meta.asset` -- the free-form
facts a recipe carries and nothing structural reads (`BuildRecipe.meta`). The recipe's own format
does not change, so a build made here opens in the main workshop and the city as any other.

| Key | Holds |
|---|---|
| `photos` | each photo: file, plane, centre, mm per pixel, opacity, shown |
| `mirror` | on, and the plane |
| `parts` | the part names, and which part each brick is, by recipe index. A brick deleted with RMB takes its own tag; anything else that shortens the recipe (undo, deleting an inserted group) takes tags from the end |
| `points` | mounts and sockets: part, kind, slot, interface, and where: studs along, plates up, studs across |
| `guides` | guide models: file, real length, offset, turn, opacity |
| `smooth`, `muzzle` | which parts leave as smooth pieces; which end is the muzzle |
| `sketches` | each sketch: part, plane, where, thickness, areas drawn in and out (outlines, brush strokes, depth cuts), and its order (a part's first plane is its base) |
| `part_bricks` | the bricks each part's sketches laid, so a change lays only what differs |
| `studs` | studs put on by hand: part, foot, the way it faces, its brick's paint |
| `part_ids`, `part_hashes`, `part_revs` | each part's id in the part catalogue, what it was when last saved and its rev: Save writes every part on its own ([ModularParts.md](ModularParts.md), "Stage 2 as built") |

A photo is referred to by its path and is not copied: a bought or borrowed picture stays out of
the repository.

---

## 4. Checks

`tools/asset_workshop_probe.gd`, headless, drives the scene with exact rays, as the workshop's
own probes do: the units, a photo's calibration, measuring, the mirror's cells and facings, what
is saved and loaded back. Each phase adds its own cases.
