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

**Not good enough yet -- the next two stages:**

- **Teeth on edges.** Sampled as in-or-out, an edge running at a slant (a sketch's slanted
  outline meeting the flat side) stays a staircase of samples however much it is
  smoothed. The fix is a *distance* field: how far each sample is from the drawn outline,
  so the surface lands on the line itself (the outlines are exact; only the sampling
  loses them). C++, beside the mesher.
- **Too many triangles.** Surface nets is as dense on a flat side as on a curve: the
  stock's shell is 7,196 triangles at 2 samples a stud, 28,744 at 4, 64,624 at 6, where its
  bricks and studs were ~5,000. The triangle slider should be a budget: decimate the
  surface (quadric edge collapse) to that many, flat sides first.

Also still to come: embedded connection bricks (studs where the shell meets other parts),
regions (a shell over part of a part), selecting and changing shells.

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

A photo is referred to by its path and is not copied: a bought or borrowed picture stays out of
the repository.

---

## 4. Checks

`tools/asset_workshop_probe.gd`, headless, drives the scene with exact rays, as the workshop's
own probes do: the units, a photo's calibration, measuring, the mirror's cells and facings, what
is saved and loaded back. Each phase adds its own cases.
