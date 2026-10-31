# Solid PBR wood

Wood bricks (material 10, `Wood`) drawn from a real texture set -- colour, roughness and a
normal map -- as a SOLID: every face of a brick is a cut through one block of wood, so the grain
runs on round its edges, and bricks stacked or laid end to end with their grain the same way
continue one another, as if cut from one plank. Written 2026-10-31. The first material off the
procedural looks (`brick_materials.gdshaderinc`); the plan is all of them, the printed plastic's
layer lines included.

## 1. What draws it

| Piece | Where |
|---|---|
| The texture set | `textures/wood/`: ambientCG **Wood049** (CC0), 1K. `wood049_albedo_rough.png` is the colour with roughness packed into alpha (BC7); `wood049_normal.png` the OpenGL normal map (BC5). Mipmapped. ~2.8 MB of video memory for both |
| Bound | as **global** shader uniforms (`project.godot` `[shader_globals]`: `wood_albedo_rough`, `wood_normal`), so every brick material made anywhere has them without being told |
| The field | `bm_wood_coords` in `brick_materials.gdshaderinc` |
| Sampling, the normal map | `bm_wood_pbr`, same file; called from `brick.gdshader` and `printed_core.gdshaderinc` (studs) |
| Which way a brick was cut | `brick_grid.h` `grain_axis`, written into the vertex colour's alpha by the mesher |
| Where a chunk lies | instance uniform `grain_origin`, set by `BrickMaterials.set_grain_origin` |

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
before. **Roughness** moves by the photo's alpha about its mean. **The normal map** is bent in
through a tangent frame from screen derivatives (Schueler's cotangent frame), as the bevel's is:
the mesher writes no tangents, and a piece can lie at any angle once it falls.

**Repeat**: the field is periodic every 6 m on every axis (2 m along, 3 and 1 across), so the
chunk origin can be passed modulo `WOOD_PERIOD` (96 m) and stay exact far from the world's
origin, where a float holds a texel no longer. Change `WOOD_TILE` and keep `WOOD_PERIOD` a
multiple of `2 * WOOD_TILE.x` and `3 * WOOD_TILE.y`.

## 3. The grain axis, in alpha

The alpha byte held the material (`1 - id/255`) and only fourteen of its values were used. Its
low five bits are now the material and the two above them the grain axis (0 X, 1 Z, 2 Y):
`block_rgba_grain`. `brick_material_id` masks, so every shader that only wants the material
reads past it, and a static_assert says when materials outgrow five bits.

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
| `wood_pbr_range` | 14 m | colour, roughness and the normal map: two texture reads and the frame |
| `wood_far_range` | 60 m | colour and roughness: one read. Past it the flat colour, which is the photo's mean |
| `wood_bump` | 1.0 | normal map strength |

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
| wood, colour only (`wood_pbr_range` 0) | 4.30, 4.58 |
| wood, flat (`wood_far_range` 0) | 4.25, 4.21 |
| the procedural wood it replaced (main's shaders in `shots/legacy/`) | 4.43, 4.40 |

All inside the round-to-round drift (~0.5 ms): a screen full of PBR wood costs no more than a
screen of plastic or of the old noise. The 4-octave noise it replaced was about as many
instructions as two texture reads. The ranges stay as knobs for a weaker machine.

## 5. Gates

* `tools/wood_probe.gd` -- headless: the alpha carries material and grain in the flat mesh, the
  chamfered mesh and the studs; a turned board says Z, a post Y; a PLA brick still reads as PLA
  past its grain bits; a square brick's grain is its grid cell's wherever its chunk starts.
  Windowed it also leaves `shots/wood_*.png`.
* `scenes/workshop.tscn -- --gate` -- places two boards stacked and one turned through the
  workshop's own placement, checks the frame mesh's grain axes and `grain_origin`, and leaves
  `shots/workshop_wood.png`.
* `tools/wood_cost_probe.gd` -- the cost table above. A timing pass.

## 6. Not done

* **Per-brick wood** ("each brick its own piece") as a choice beside "one log": needs each
  brick's origin in the vertex data, which alpha has no room for.
* **Studs continuing the brick's figure**: needs the stud's place in its brick.
* **More woods**: a second set wants a texture array (or a second pair of globals) and a
  variant -> set table.
* **Other materials** -- stone, metal, then the printed plastic's layer lines as a bead texture
  sampled by layer height, its tops' toolpaths as a tile turned with `ps_top_turned`.
* **Generated sets**: a set could be baked by our own generator (Blender headless, as the
  printable bricks are) instead of downloaded -- needed for the printed plastic, whose look is
  measured from our own sliced G-code (Docs/PrintLook.md) and has no photo to download.
