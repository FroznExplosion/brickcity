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
| The underside | OPEN. A 1x1: a rim alone. A 1xN: a rim and solid pins between the studs. 2xN and up: a diamond round each inside corner of the stud grid, ribs along the grid lines out to the rim | `ps_underside`, `under_*`; the hollow darkened (`under_cavity`) |
| Layer to layer | no two alike | `layer_wobble` (shade) and `layer_relief_wobble` (how proud), per layer, per face |

## 3. What it costs

Nothing new to hold: no textures, no vertex data. The stud's turn is in the instance transform it
already had. The underside is a handful of arithmetic on bottom faces only; the stud top lost an
`atan`. Not timed.

## 4. Not done

* The first layer's elephant's foot (a slight flare at the bed).
* Slopes and curves as stair-steps of layers: a sloped face still takes the side pattern.
* The underside's walls and ribs are flat drawing, not depth: from straight below that is what is
  seen, at a glancing angle the hollow has no sides.
* Godot 4.8's texture streaming changes nothing here: there are no textures to stream. A baked
  per-footprint toolpath map, straight from G-code, is the next step if the drawn rules are not
  enough -- a few MB, one texture read a pixel.

`tools/print_look_shot.gd` takes the pictures: sides, tops, a floor of mixed tops, studs,
undersides, the seam, and a wall at range.
