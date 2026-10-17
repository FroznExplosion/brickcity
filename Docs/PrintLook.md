# The printed look, measured

How a printed brick's surfaces are drawn (`shaders/print_surface.gdshaderinc`, `brick.gdshader`,
`printed_core.gdshaderinc`), and where the numbers came from. Written 2026-10-16.

## 1. How it was measured

The printable bricks in `Documents/brickcity-print/stl` (`brick_2x4`, `brick_1x4`, `brick_2x2`,
`brick_1x1`, `plate_2x4`) were sliced with PrusaSlicer 2.9.6's command line -- 0.2 mm layers, a
0.4 mm nozzle, 0.45 mm lines, two walls, Arachne, monotonic top and bottom, 45-degree fill, seam
aligned -- and the G-code drawn a layer at a time with `tools/gcode_draw.py` (colour by feature,
brightness by print order, the seam marked):

    prusa-slicer-console --export-gcode --layer-height 0.2 --first-layer-height 0.2
        --nozzle-diameter 0.4 --extrusion-width 0.45 --perimeters 2 --top-solid-layers 5
        --bottom-solid-layers 4 --top-fill-pattern monotonic --bottom-fill-pattern monotonic
        --fill-angle 45 --perimeter-generator arachne --seam-position aligned --gcode-comments
        --center 50,50 --output brick_2x4.gcode brick_2x4.stl
    python tools/gcode_draw.py brick_2x4.gcode b24 first 9.6 top

## 2. What a sliced brick is

| | Sliced | Drawn as |
|---|---|---|
| Layers | 57: 48 on the body, 9 up the stud | `layer_height` 8.75 mm (0.2 mm at 1:43.75) |
| A top | two wall loops, then ONE path of 45-degree lines joined by short runs along the wall; 0.41 mm apart | `top_bead_width` 18 mm (it was 28), `ps_zigzag` |
| The voids where two lines end at the wall unjoined | specks | `skin_void_darken` 0.7 (they were drawn at 0.45, as teeth) |
| Which way the lines lie | the same way round in the part's own frame on every copy: the bed decides | `ps_top_turned`: from which way the part lies, a square part's from its corner's hash; studs turned to match in `BrickWorld::stud_turn` |
| A stud's top | two loops round the octagon, then about seven short lines the same way as its brick's | `printed_core`, `top_mode` 1 (it was a spiral, which nothing prints) |
| The seam | every layer's outer wall starts and stops on one corner: a vertical line of blobs | `ps_seam` on the part's low-X, low-Z corner, `zseam_*` |
| The underside | OPEN. A 1x1: a rim alone. A 1xN: a rim and solid pins between the studs. 2xN and up: a diamond round each inside corner of the stud grid, ribs along the grid lines out to the rim | `ps_underside`, `under_*` |
| Layer to layer | no two alike | `layer_wobble` (shade) and `layer_relief_wobble` (how proud), per layer, per face |
| The walls round a top or a rim | follow the part's real outline: where the bevel stops, not the rectangle it cut into | `ps_inset`: the distance to the outline less the bevel; nothing on the bevel itself (it ran the loops out over it) |
| The hollow's roof | from every rib and the rim the walls step in a layer at a time at 45 degrees -- a band of terraces about 1.3 mm wide, a line at each step -- then the rest is BRIDGED flat, straight lines across one way. A plate's and a brick's alike | drawn wider than sliced (`under_slope` 0.10: at 1.3 mm the hollow read as a flat drawing), the terraces' slope faces away from the nearest wall (the gradient of `ps_under_sd`, a line a layer up them; then flat, a line a bead across; the hollow sees less sky (AO, `under_cavity`, `under_wall`), not less sun. It was a dark flat cave whose walls were found by walking the view ray into it, which came apart in stripes at range |
| A bevel | printed with the rest: a vertical edge's has the side's layers across it, a top or bottom edge's is a 45-degree staircase | facets counted up the height and stair-stepped (`ps_stairs`); they were left unprinted, smooth strips |
| A top line's profile | NOT ironed (no default profile irons): a squashed bead, flat-ish over its middle, rounding into a shallow V beside the next | `ps_beads`: a top's slope goes as x\|x\| across the bead (it was \|x\|^4, ironed, and the lines all but vanished); a side's stays round (a sine) |
| A stud's top edge | the outer wall's bead turning over: rounded by about half a layer | `PieceMeshes.STUD_BEVEL` 5 mm (it was 13: a wide shiny ring on every stud) |
| The bottom edges | square: a part comes off the bed flat | square in the near mesh where a brick rests on bricks (Docs/BrickBevel.md 2.4); bevelled where it overhangs, which looked wrong square |
| Slopes, cheese, rounds, arches, curves | the same 57 layers; a slope is a staircase of them -- risers and treads, wide terraces on a shallow one | layers counted up the part's height (an authored surface has no face rectangle to count in, and had NO layers until 2026-10-16); `ps_stairs`: of each layer's band, the riser takes 1 - n.y^2, the tread n.y^2 (`stair_strength`) |

## 1.1 Side by side with the G-code

`tools/toolpath_compare.gd` draws a sliced part bead by bead -- every extruding move a flattened
cylinder as wide as its line and as tall as its layer, at 1:43.75 -- beside the same part as the
game draws it, from the same camera under the same sky: the top, a top edge, a stud, the side,
a corner, the underside, and a hand's breadth from the top and the side.

    (slice each part as in 1, into <dir>/<part>.gcode)
    godot --path . --script res://tools/toolpath_compare.gd -- --gcode=<dir> --out=<dir>
        [--pieces=brick_2x4,plate_2x2,slope_2x2,...]

What it showed (2026-10-17), and what changed for it: the top lines are 0.41 mm apart, as drawn,
but the game had ironed them nearly away; a stud's top edge is sharp, not a 13 mm chamfer; the
hollow is not a dark pit but terraces and a bridged roof (the table below). The beads are drawn
round, so the real relief is shallower than in those pictures: they show where the paths go, not
how deep the grooves are.

## 2.1 Parts that are not boxes

A slope, a cheese, a round brick, an arch or a curve is an AUTHORED surface (Archetype::mesh):
triangles, not a face rectangle, so for a long time it took none of a box's rules -- no outline, no
bevel, no walls round its top, no layers. Now the part's own edges are found when its mesh is set
(`BrickWorld::mark_feature_edges`), and the bake hands every triangle its distance to them, which
is what a box's rectangle gives it:

* **Real edges**: where the mesh ends, or turns by more than 30 degrees. Round a curve (22.5 a
  facet) or across a flat face, the triangulation's own edges are not.
* **T-junctions split first**: where a vertex lies along another triangle's edge -- an arch's beam
  over its pillars -- that edge is cut there, so every edge is shared whole or not at all.
* **Distance to the nearest real edges of the face**, up to three, not just the triangle's own:
  a long edge split between two triangles is known to both, or the outline thins at the split.
  As LINES, so linear across a triangle, written per vertex in UV and UV2.x; UV2.y marks the face
  authored (300, or 400 turned as `stud_turn` says).
* **A face with a notch** (an arch's front, round its opening) has edges whose lines run on across
  it. It is cut along the perpendiculars at the ends of each such edge first; a piece then takes
  that edge's line only where it lies beside it.

From that distance `brick.gdshader` gives an authored face the outline, the shaded 45-degree bevel
(at every distance: the near mesh copies authored surfaces as they are, so there is no real one),
a flat top's two walls and turned diagonals, a flat bottom's open rim. Its layers are counted up
its height and stair-step on slopes (above).

## 3. What it costs

Nothing new to hold: no textures, no vertex data. The stud's turn is in the instance transform it
already had. The underside is a handful of arithmetic on bottom faces only, plus three distance
evaluations within 25 m in the hollow; the stairs are a normal blend on authored faces only; the
stud top lost an `atan`. Not timed.

Far off it is cheaper than before: `brick.gdshader` skips whatever has already faded to nothing
-- the drawn seam past `seam_fade_end`, the shaded bevel past `chamfer_fade_end`, the paths'
walls, zigzag, voids, stairs and Z seam past `print_fade_end`, the hollow's roof past
`under_depth_range` -- and a far brick is its colour, its finish and the layers' anisotropy.

## 4. Not done

* The first layer's elephant's foot (a slight flare at the bed).
* An authored part's flat bottom is open at the rim only: its ribs and pins need the footprint,
  which a triangle does not know. No Z seam on authored parts. Their bevel is shaded, not built.
* Godot 4.8's texture streaming changes nothing here: there are no textures to stream. A baked
  per-footprint toolpath map, straight from G-code, is the next step if the drawn rules are not
  enough -- a few MB, one texture read a pixel.

`tools/print_look_shot.gd` takes the pictures: sides, tops, a floor of mixed tops, studs,
undersides, the seam, a wall at range, a ceiling seen from the room under it, a ledge, and
terraces at 17 to 45 m with the studs `BrickNear` draws there (its cards on and off, and
through a long lens).
