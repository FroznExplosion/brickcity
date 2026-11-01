# PBR materials: wood, metal, stone, leaves

The natural materials drawn from real texture sets -- colour, roughness and a normal map -- as
SOLIDS: every face of a brick is a cut through one block of the stuff, so a pattern runs on
round its edges, and bricks side by side continue one another. Wood came first (2026-10-31) and
has the most of its own (a grain field, sections 2-3); metal, stone and leaves followed the same
day on the same machinery (section 1.1). The printed filaments are still procedural
(`brick_materials.gdshaderinc`); the plan is all of them, the plastic's layer lines included.

## 1. What draws it

| Piece | Where |
|---|---|
| The texture set | `textures/wood/`: ambientCG **Wood049** (CC0), 2K (1K read soft from under a metre). `wood049_albedo_rough.png` is the colour with roughness packed into alpha (BC7); `wood049_normal.png` the OpenGL normal map (BC5). Mipmapped. ~11 MB of video memory for both |
| Bound | as **global** shader uniforms (`project.godot` `[shader_globals]`: `wood_albedo_rough`, `wood_normal`), so every brick material made anywhere has them without being told |
| The field | `bm_wood_coords` in `brick_materials.gdshaderinc` |
| Sampling, the normal map | `bm_pbr`, same file, every set; called from `brick.gdshader` and `printed_core.gdshaderinc` (studs) |
| Which way a brick was cut | `brick_grid.h` `grain_axis`, written into the vertex colour's alpha by the mesher |
| Where a chunk lies | instance uniform `grain_origin`, set by `BrickMaterials.set_grain_origin` |

## 1.1 The other sets

| Material | Set (ambientCG, CC0) | Size | Mapped | Normal map |
|---|---|---|---|---|
| 11 Metal | **Metal009**, brushed steel | 2K | box (below), streaks along the grain axis | yes, `PBR_BUMP` 1.5 |
| 12 Stone | **Marble012**, polished veined marble | 2K | box | none: polished stone's map is flat (spread 0.004), so its read is skipped |
| 13 Leaf | **ScatteredLeaves008**, three quarters greyed so the brick's green is the colour | 1K | box | yes, 1.5 |

`textures/<material>/`, packed and imported as wood's (BC7 colour + roughness, BC5 normal,
mipmapped). Video memory: wood ~11 MB, metal ~11, stone ~5.6, leaves ~2.8 -- about 30 MB.

**Box mapping** (`bm_box_coords`): each surface samples the plane of the axis its normal is
nearest -- a top the X-Z plane, a side X-Y or Z-Y -- in the same chunk-plus-grid metres as
wood, so neighbours continue and the pattern meets itself at an edge along the axis the two
planes share. Where the grain axis lies in the plane it goes first, so a metal piece is brushed
along its length (a post upright); an end face takes its other two axes. One projection, not a
blend of three: a brick's faces are square to an axis, and a bevel's seam is a millimetre wide.
A 45-degree slope picks Y every pixel (a small bias), never a coin toss on rounding.

Per set (`brick_materials.gdshaderinc`): the colour's linear mean and the roughness map's mean
(the colour is the photo over its mean, times the brick's variant colour, as wood's), how far
the roughness map is spread (`PBR_ROUGH_GAIN`), the normal map's strength (`PBR_BUMP`, times
the material's `pbr_bump`) and the metres one repeat covers (`PBR_TILE`, each dividing
`PBR_PERIOD`). The means come from the packing script: Image.histogram through the sRGB curve.

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
  Headless or not: every material in every grain survives the renderer's cut to eight bits.
* `scenes/workshop.tscn -- --gate` -- places two boards stacked and one turned through the
  workshop's own placement, checks the frame mesh's grain axes and `grain_origin`, and leaves
  `shots/workshop_wood.png`.
* `tools/wood_cost_probe.gd` -- the cost table above. A timing pass.

## 6. Not done

* **Per-brick wood** ("each brick its own piece") as a choice beside "one log": needs each
  brick's origin in the vertex data, which alpha has no room for.
* **Studs continuing the brick's figure**: needs the stud's place in its brick.
* **A set per variant**: one set a material today -- granite, slate and sandstone are marble
  tinted, copper and gold are steel tinted. More sets want a texture array (or more globals)
  and a variant -> set table; mind the memory (section 1.1).
* **The printed plastic** -- its layer lines as a bead texture sampled by layer height, its tops'
  toolpaths as a tile turned with `ps_top_turned`.
* **Texture streaming** (Godot 4.8's mip streaming, in beta as of 2026-10-31): not needed at
  ~30 MB; worth a look once there are many sets. Whether it reaches textures bound as global
  shader uniforms and sampled with `textureGrad` is untested.
* **Generated sets**: a set could be baked by our own generator (Blender headless, as the
  printable bricks are) instead of downloaded -- needed for the printed plastic, whose look is
  measured from our own sliced G-code (Docs/PrintLook.md) and has no photo to download.
