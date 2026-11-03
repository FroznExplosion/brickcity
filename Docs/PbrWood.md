# PBR materials: wood, metal, stone, leaves

The natural materials drawn from real texture sets -- colour, roughness and a normal map -- as
SOLIDS: every face of a brick is a cut through one block of the stuff, so a pattern runs on
round its edges, and bricks side by side continue one another. Wood came first (2026-10-31) and
has the most of its own (a grain field, sections 2-3); metal, stone and leaves followed the same
day on the same machinery (section 1.1), and on 2026-11-01 each variant got a set of its own
(walnut a walnut photo, slate a rock, verdigris a patina; section 1.2). On 2026-11-02 PLA's
layer lines, top lines and first layer became a baked texture of our own (section 7); the other
filaments are still drawn by rules (`print_surface.gdshaderinc`).

## 1. What draws it

| Piece | Where |
|---|---|
| The texture sets | `textures/pbr/<material>_albedo_rough.webp`: one 2K slice per set (leaves 1K; 1K read soft from under a metre), colour with roughness packed into alpha; `<material>_normal.webp` the OpenGL normal maps of the sets with relief. Imported as **Texture2DArray** (`2d_array_texture`, slices laid side by side, BC7, mipmapped) |
| Bound | as **global** shader uniforms (`project.godot` `[shader_globals]`, `sampler2DArray`: `wood_albedo_rough`, `wood_normal`, the same for metal, stone, leaf), so every brick material made anywhere has them without being told |
| Which set | `bm_pbr_set` in the vertex shader, from the vertex colour (section 1.2) |
| The field | `bm_wood_coords` in `brick_materials.gdshaderinc` |
| Sampling, the normal map | `bm_pbr`, same file, every set; called from `brick.gdshader` and `printed_core.gdshaderinc` (studs) |
| Which way a brick was cut | `brick_grid.h` `grain_axis`, written into the vertex colour's alpha by the mesher |
| Where a chunk lies | instance uniform `grain_origin`, set by `BrickMaterials.set_grain_origin` |

## 1.1 The other materials

Metal and stone are box-mapped (below), wood a solid field (section 2), leaves box-mapped. Metal's
brushing runs along the grain axis. Polished stone's normal map is flat (spread 0.004), so those
sets have no normal slice and skip the read.

## 1.2 A set per variant

| # | Set (ambientCG, CC0) | Variants | Normal |
|---|---|---|---|
| 0 | Wood049 | oak, teak, ash, cedar | yes |
| 1 | Wood051 | walnut, ebony | yes |
| 2 | Wood066 | cherry, mahogany | yes |
| 3 | Wood095 (2048x1024, stacked twice) | birch, maple, bamboo | yes |
| 4 | Wood096 (grain ran down it: turned a quarter, normal map recomposed) | pine | yes |
| 5 | Wood062 | weathered, driftwood | yes |
| 6 | Metal009, brushed | steel, stainless, aluminium, titanium | yes |
| 7 | Metal055A | iron, gunmetal | -- |
| 8 | Metal053B, rust patches | rusted iron | -- |
| 9 | Metal047A | copper, brass, bronze | -- |
| 10 | Metal058C, patina | verdigris | -- |
| 11 | none: polished, its colour and low roughness | chrome, gold, silver | -- |
| 12 | Marble012 | white marble | -- |
| 13 | Marble016 | black marble, green marble | -- |
| 14 | Granite002A | grey granite, pink granite | -- |
| 15 | Rock058 | slate, basalt | yes |
| 16 | Travertine009 | limestone, travertine | -- |
| 17 | Travertine004, banded | sandstone | -- |
| 18 | Concrete030 | concrete | yes |
| 19 | Clay005 | terracotta | yes |
| 20 | ScatteredLeaves008, three quarters greyed | every leaf colour | yes |

**How a vertex finds its set.** Alpha has one spare bit, not four, and the mesh is unchanged:
the vertex colour IS the variant (`block_rgba` writes the variant's RGB), so `bm_pbr_set`, in
the vertex shader, takes the nearest colour on its material's list (`WOOD_RGB`, `METAL_RGB`,
`STONE_RGB`, brick_grid.h's lists in order) and its set (`WOOD_SET` ...), flat, so nothing is
searched per pixel. `wood_probe` checks the lists match the engine's and every variant comes
back as itself through eight bits. **Add a variant: add it to brick_grid.h AND the shader's
list, with its set.**

Per set (`PBR_*` tables): its material's array and slice, normal slice or -1, colour mean,
roughness mean and gain, bump, tile, and three that hold at any distance: `PBR_ROUGH_SHIFT`
(rougher or glossier than the material's `MAT_ROUGH` -- concrete is not marble),
`PBR_METAL` (of `MAT_METAL`: rust 0.35, patina 0.2) and `PBR_HUE` -- how much of the photo's
own hue survives: 1 is the photo over its mean channel by channel (rust stays orange on any
metal), 0 by brightness alone. A strongly coloured photo wants less: cherry's blue mean is
0.008, and blue over it is noise.

**Packing** (`tools/pack_pbr_sets.py`: the downloads, `python tools/pack_pbr_sets.py <downloads> textures/pbr`): each set's colour and
roughness merged into RGBA, normals as published, resized to the slice size, laid side by side
in rows (no blank slices -- an empty slice is memory), WebP (lossy 92 colour, 95 normals;
WebP stops at 16383 px a side). It prints each set's linear colour mean and roughness mean and
spread for the tables. Add a set: a slice in its material's arrays (`slices/horizontal`,
`slices/vertical` in the `.import`), a row in every `PBR_*` table.

**Memory.** Video: wood 33.5 + 33.5 MB, metal 28 + 5.6, stone 44.7 + 16.8, leaves 1.4 + 1.4 --
about 165 MB (it was ~30 with one set a material). Repo: 72 MB of WebP. Halving a slice to 1K
quarters its share; that, or mip streaming (section 6), is the lever if memory gets tight.

**Box mapping** (`bm_box_coords`): each surface samples the plane of the axis its normal is
nearest -- a top the X-Z plane, a side X-Y or Z-Y -- in the same chunk-plus-grid metres as
wood, so neighbours continue and the pattern meets itself at an edge along the axis the two
planes share. Where the grain axis lies in the plane it goes first, so a metal piece is brushed
along its length (a post upright); an end face takes its other two axes. One projection, not a
blend of three: a brick's faces are square to an axis, and a bevel's seam is a millimetre wide.
A 45-degree slope picks Y every pixel (a small bias), never a coin toss on rounding.

Per set (section 1.2): the colour is the photo over its mean, times the brick's variant
colour, so a brick's average colour is its swatch's; the roughness map's spread
(`PBR_ROUGH_GAIN`), the normal map's strength (`PBR_BUMP`, times the material's `pbr_bump`) and
the metres one repeat covers (`PBR_TILE`, each dividing `PBR_PERIOD`). The means come from the
packing script: Image.histogram through the sRGB curve.

Metal is lit mostly by what it mirrors (`MAT_METAL` 0.8): under a flat background colour it
reads dark and flat, and its relief barely shows -- give it a sky.

## 2. The block of wood

A point's place in the wood is `v_local + grain_origin`: the chunk's own metres plus the chunk's
corner on the grid. In the brick's grain frame -- `q.x` along the grain, `q.y` across it on plan,
`q.z` up (for a post, the two horizontals) --

    t.x = q.x / 2 m                                   along the fibres
    t.y = (q.y / 3 + q.z + 0.06 sin(...)) / 1 m       across the rings

The photograph is side grain: fibres along its x, rings striping down its y. A brick's side
(q.y fixed) samples it as it is; its top (q.z fixed) a cut three times wider through the same
rings, the broad figure of a flat-sawn plank; its end (q.x fixed) a column of the photo swept
across the end, read as rings. The sine bends the rings, as rings bend. A bevel, a slope, a
round, an arch is one more cut through the block and needs nothing of its own.

**Colour** is the photo over its own mean (`WOOD_MEAN`), times the brick's colour: oak, walnut
and cherry are three woods from one set, and a wood brick's average colour is what it was
before. **Roughness** moves by the photo's alpha about its mean, scaled up (`WOOD_ROUGH_GAIN`
2.5: the map's own spread is 0.08, too little to see) over a glossier base (`MAT_ROUGH` 0.42), so
the grain shows as a sheen that moves with the eye and the sun. **The normal map** is bent in
through a tangent frame from screen derivatives (Schueler's cotangent frame), as the bevel's is:
the mesher writes no tangents, and a piece can lie at any angle once it falls.

**Repeat**: the field is periodic every 6 m on every axis (2 m along, 3 and 1 across), so the
chunk origin can be passed modulo `PBR_PERIOD` (96 m) and stay exact far from the world's
origin, where a float holds a texel no longer. Change `WOOD_TILE` and keep `PBR_PERIOD` a
multiple of `2 * WOOD_TILE.x` and `3 * WOOD_TILE.y` (and of every `PBR_TILE`).

## 3. The grain axis, in alpha

The alpha byte held the material (`1 - id/255`) and only fourteen of its values were used. Its
low five bits are now the material and the two above them the grain axis (0 X, 1 Z, 2 Y):
`block_rgba_grain`. `brick_material_id` masks, so every shader that only wants the material
reads past it, and a static_assert says when materials outgrow five bits.

**A quarter step inside the byte.** The renderer stores a vertex colour cut to eight bits, and
the exact value `1 - code/255` came out a hair under its byte for every odd code from 65 up:
cut, it read as the next code. Codes under 64 -- every brick before the grain bits -- happened
to survive, but an upright piece of an odd material did not: a metal post (75) drew as stone
(76), a leaf post (77) as 78, which the clamp hid. `block_rgba_grain` writes
`1 - (code - 0.25)/255`, which lands on the byte whether the cut truncates or rounds and still
reads back as the code; `wood_probe` checks every material in every grain through both cuts.

`grain_axis`: along the part's long side on plan; upright when it stands more than twice as tall
as it is long (a `column_1x1` is a post); a square part by a hash of its GRID cell, so a piece
broken off -- a chunk of its own, starting at its own corner -- keeps its grain. The flat bake,
the chamfered mesh (it copies the bake's colours), the masked per-cell mesh and the studs carry
it; the far coarse shell does not (it is past the range).

A stud is one shared mesh in its own frame: its grain is written in that frame (a turned stud's
X is the chunk's Z). It runs the brick's way but does not continue the brick's figure -- the
stud does not know where in the brick it stands.

## 4. Where it is drawn: the cost knobs

| Uniform (`brick.gdshader`, and the same names on the stud material) | Default | Inside it |
|---|---|---|
| `pbr_range` | 14 m | colour, roughness and the normal map: two texture reads and the frame |
| `pbr_far_range` | 60 m | colour and roughness: one read. Past it the flat colour, which is the photo's mean |
| `pbr_bump` | 1.0 | scales every set's own `PBR_BUMP` (wood 2.0: at 1.0 the photo's baked shading drowned it -- a face lit across the grain changed by ~7 levels in 255, under a low or frontal sun by under one) |

(They were `wood_pbr_range`, `wood_far_range` and `wood_bump` while wood was the only set.)

14 m is `BrickNear.radius`, where the bricks already have real bevels. Only pixels on the screen
are shaded (and the depth pre-pass drops hidden ones), so "only in the player's view" is free;
the ranges are the "only near the player". Distances are scaled by `lod_zoom`, as the rest.

### Cost, measured

`tools/wood_cost_probe.gd`, 2026-10-31, editor closed, no other test running, peak 71 C, not held
back: a wall of chamfered 2x4s filling 1280x720 from 3 m, the renderer's own GPU clock, median of
240 frames, two rounds interleaved. Integrated Radeon (Legion Go).

| | GPU ms |
|---|---|
| PLA (layer lines and all) | 4.29, 4.76 |
| wood, full set | 4.19, 4.80 |
| wood, colour only (`pbr_range` 0) | 4.30, 4.58 |
| wood, flat (`pbr_far_range` 0) | 4.25, 4.21 |
| the procedural wood it replaced (main's shaders in `shots/legacy/`) | 4.43, 4.40 |

All inside the round-to-round drift (~0.5 ms): a screen full of PBR wood costs no more than a
screen of plastic or of the old noise. The 4-octave noise it replaced was about as many
instructions as two texture reads. The ranges stay as knobs for a weaker machine.

Again with the 2K set, `wood_bump` 2 and the roughness gain (same day; two other chats' headless
runs started part way through, so take it as rough): PLA 4.41, 4.39; wood full 4.45, 4.33; colour
only 4.07, 4.10; flat 3.75, 3.92; the old procedural wood 4.04, 4.12. Full PBR wood costs about
what plastic does, and some 0.3-0.5 ms over flat colour with a whole screen of it.

## 5. Gates

* `tools/wood_probe.gd` -- headless: the alpha carries material and grain in the flat mesh, the
  chamfered mesh and the studs; a turned board says Z, a post Y; a PLA brick still reads as PLA
  past its grain bits; a square brick's grain is its grid cell's wherever its chunk starts.
  Windowed it also leaves `shots/wood_*.png`, and checks the normal map is LIGHTING: the stacked
  pair's side under a sun raking down across the grain, relief off and at its default, must
  differ by more than 4 levels in 255 (11.2 at 2.0). Relief shows when light rakes across it; a
  sun behind the face, or square on to it, shows little -- the first version of the check lit
  the back of the bricks and measured nothing at all. Then the same build in metal, stone and
  leaves (`shots/wood_<material>_*.png`), each set with a normal map checked the same way at a
  threshold of its own: wood 4 (11.3), leaves 3 (6.4), metal 1 (1.9: brushed steel's relief is
  fine streaks, spread 0.06 across them and 0.01 along, and it is lit by what it mirrors).
  Headless or not: every material in every grain survives the renderer's cut to eight bits;
  the shader's variant lists are the engine's, every variant finds itself through eight bits
  and names a set of its own material, and every slice a set names is in its arrays. Windowed,
  a wall of every variant per material: `shots/wood_variants_<material>.png`.
* `scenes/workshop.tscn -- --gate` -- places two boards stacked and one turned through the
  workshop's own placement, checks the frame mesh's grain axes and `grain_origin`, and leaves
  `shots/workshop_wood.png`.
* `tools/wood_cost_probe.gd` -- the cost table above. A timing pass.

## 6. Not done

* **Per-brick wood** ("each brick its own piece") as a choice beside "one log": needs each
  brick's origin in the vertex data, which alpha has no room for.
* **Studs continuing the brick's figure**: needs the stud's place in its brick.
* **Leaves by colour**: one set for every filament colour; a second (needles, hedge) would
  want its own key, since leaves take the filament palette, not variants.
* **The rest of the printed plastic** (section 7): the other filaments (three slices each in
  `print_bead`: ABS finer, TPU wide soft beads, carbon, nylon, wood fill).
* **Texture streaming** (Godot 4.8's mip streaming, in beta as of 2026-10-31): with a set per
  variant the sets are ~165 MB, so now worth a look once 4.8 is stable. Whether it reaches
  texture ARRAYS bound as global shader uniforms and sampled with `textureGrad` is untested.
* **Generated sets**: a set could be baked by our own generator (Blender headless, as the
  printable bricks are) instead of downloaded -- needed for the printed plastic, whose look is
  measured from our own sliced G-code (Docs/PrintLook.md) and has no photo to download.

## 7. The printed beads, baked (PLA)

A printed part's beads are a texture since 2026-11-02 -- a side's layers, a top's lines, a
bottom's first layer -- generated rather than downloaded: there is no photo of a 1:43.75 print.
`tools/make_print_beads.gd` (headless, ~20 s) bakes `textures/pbr/print_bead.webp`, a
Texture2DArray with three slices a filament (side, top, bottom; PLA's today), bound as the
global `print_bead`.

| | |
|---|---|
| A slice | 32 beads tall, 64 beads long, 32 px a bead (2048x1024), tiles both ways; ~2.7 MB of video memory each with mips (BC7), ~8 MB for PLA's three. A bead is a layer (8.75 mm) on a side, a line (18 mm top, 20 mm bottom) on a top or bottom |
| R, G | the surface's slope along and across the beads, in beads (a slope is its own tilt), +-1.5 |
| B | shade, mean 1: deep in a groove darker (it sees less sky), and each bead a shade of its own |
| A | roughness offset, mean 0: a groove duller than a crest |
| Side | each layer a squashed half-cylinder with a narrow V to the next (depth 0.25 of a layer); each layer a little prouder or not, the line swelling along its length, the seam between two layers wandering, a fine grain |
| Top | lines pressed flat by the nozzle, flat across the middle and rounding into a shallow V (depth 0.14 of a line, squash 3.5), a fine ripple across each where the extruder pulsed; less shade between lines than a side's layers. Finer than the drawn rules' lines, which read as corrugated |
| Bottom | the first layer, squashed into the bed: hairline seams (depth 0.025), next to no relief, a little duller in the seams. Drawn as on smooth PEI; glass and textured PEI scale it by their share of the bead (`ps_face_k`), and textured PEI keeps its powder-coat grain on top (`ps_bed_grain`) |
| Read by | `ps_bead_tex` (print_surface.gdshaderinc), from `ps_beads`, for a material whose `PS_BEAD_SLICE` is its first slice: bricks, facets, authored parts and studs; side, top, bottom, wall loops, infill, connectors and an open underside's rim loops alike. The wall-infill junction line is kept |
| Placed | across by the bead count `t`. A side's groove sits at every whole layer, where a brick starts and stops; a top's and bottom's lines are CENTRED on whole t (the first wall loop runs round the edge at t 0), so their slices are read half a bead over. Along by metres (`u`): a box side's UV; a top's diagonals across their own direction; a loop round an outline x + y (runs along every edge, continuous round the corners, so no seam in the filtering); an authored face or a facet x + z. The face's seed moves it whole beads across and anywhere along, so no two faces show the same stretch |
| Knobs | `print_bead_texture` (off: the drawn rules, for A/B), `bead_tex_relief` 0.45, `bead_tex_shade` 1 |

What a texture does better than the rules: every layer is its own, and wanders along its
length (the drawn ones are ruled lines); the profile is a real bead's, a squashed round with
sharp grooves, not a sine; and the MIPS filter it -- far off the drawn bead pattern beat
against the pixels (moire on a wall at 10 m), the baked one fades to its mean. The rules' own
fade is kept: the relief gives up squared as a layer nears a pixel and roughness takes what it
drops (ps_beads), since a filtered normal still sparkles.

**Cost** (`tools/wood_cost_probe.gd`, 2026-11-02 evening, editor closed, peak 89 C, not held
back; another chat's headless probe overlapped part of both runs, so take it as rough). GPU ms a
frame, 1280x720 filled, two runs of two rounds:

| | run 1 | run 2 |
|---|---|---|
| PLA wall (sides), baked | 4.33, 4.32 | 4.30, 4.31 |
| the same, drawn by the rules | 4.28, 4.49 | 4.24, 4.27 |
| PLA floor from above (tops), baked | 4.01, 3.97 | 3.96, 3.99 |
| the same, drawn | 3.90, 3.88 | 3.90, 3.92 |

About 0.05 ms dearer either way, inside the round-to-round drift: one texture read costs about
what the drawn bead's arithmetic did. (The probe's old `legacy` case, the procedural wood from
before section 1, no longer compiled and is gone.)

Pictures: `tools/print_look_shot.gd -- --out=<dir> --looks=glass,pei
--views=side,stud,corner,wall,top,tops_close,skin,bottom,under` with and without `--no-bead-tex`.
