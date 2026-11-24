# Real bricks over the ground (the brick overlay)

The user's design (2026-11-23), for the mine world first, then every scene with
ground. Status at the end.

## 1. Why

The ground near the camera had real chamfers by drawing a SECOND mesh of each
near tile with every face bevelled (`build_tile_chamfered`, TerrainTile
`add_bevel`). Wherever that mesh met ground drawn flat -- the next tile past
the near ring, the deep sections under the tile floor (caves are always
flat) -- the bevel was half a groove with no other half: slits to daylight,
seen as white dots and dashed lines along cave walls (MineWorld.md 19). Each
fix moved the slits; turning chamfers off removed them. Two meshes that must
meet edge to edge will keep leaking.

## 2. The idea

- The FLAT ground mesh is drawn everywhere, always whole. Nothing ever has to
  meet anything: no slits possible.
- Near the camera and in its view, REAL bricks are laid over it: a pool of
  instanced bevelled boxes (BrickNear.bevel_box_mesh, the city's boxed
  bands: one unit box, scaled to the brick, the 13 mm bevel taken off in the
  shader) -- moved and retinted, never baked. A few hundred to a few thousand
  instances, nearest and most in view first.
- Under them the flat mesh is pushed back by the bevel (13 mm) in the terrain
  shader, so it does not z-fight the instances' faces and does not fill their
  chamfers. Between two real bricks the groove's floor is that pushed-back
  flat surface: the gap is always filled.
- A brick about to break, or broken, already has real geometry; later the
  overlay can hand it to the pieces without a rebake (stage 6).

## 3. What each part does

| Part | Where | Does |
|---|---|---|
| Exposed bricks | C++ `mask_faces` / the packer, `build_tile`, `build_section` | Each bake also returns the bricks that have a face drawn: box (min corner, size, metres), material byte, colour, sky and block light (`bricks` key, floats a brick). Pieces' tops (the packer) and mask bricks (walls, caves). |
| TerrainBricks | `scripts/terrain/terrain_bricks.gd` (new), a child of the mine world | Holds the drawn tiles' and sections' brick lists; each frame picks those within `range_m` of the eye and inside the view (a margin wider than the frustum), nearest first, up to `max_bricks`; writes one MultiMesh buffer (transform = the brick's box, colour, custom: material, sky, block). Rebuilt when the eye moves a cell, turns past a step, or a tile/section changes. Main thread, CPU arrays only (no read-back). |
| The look | `shaders/terrain.gdshader`, `#define TERRAIN_BOX` copy | The instance's box face as the flat mesh's quad would be: material from custom data, UV/UV2 from the scale (brick_boxed.gdshaderinc), sky/block light from custom data, the bevel facets plain. Same print lines, seams, stud-less tops (studs stay the tiles' instances). |
| The recess | `shaders/terrain.gdshader` vertex | Within `range_m` of the camera (the same sphere TerrainBricks fills; a short fade at its edge) every flat vertex moves 13 mm back along its normal. |
| The old chamfer | TerrainTile, TerrainStreamer | `add_bevel` / `build_tile_chamfered` are not baked while the overlay is on (`TerrainTile.bevel_enabled = false`); retired once the overlay holds (stage 7). |

The recess is by distance only, the instances by distance AND view: a brick
behind the camera is recessed with no instance over it, which nobody sees;
turning, its instance comes in the next fill (a frame or two), and the 13 mm
sunken face is hard to see for that time.

## 4. Stages

1. **Bricks out of the bake.** `build_tile` / `build_section` return
   `bricks`; probe: every drawn face lies on some brick's box, every brick has
   a drawn face, counts per tile (`terrain_bricks_probe`, headless).
2. **TerrainBricks + TERRAIN_BOX.** The pool, the pick, the buffer, the
   shader copy. Gate `-- --gate=bricks`: the stone room (MineWorld.md 19) with
   the overlay on: pictures, instance counts, fill ms.
3. **The recess.** Gates: `--gate=seams` and `--gate=seams --deep --at-top`
   must be 0 px with the overlay on and the old chamfer off;
   `bevel_gap_probe` for the heightfield scene.
4. **Light.** Sky and block light per instance (the bake's own value at the
   brick's open faces); `--gate=skylit` pictures with the overlay.
5. **Cost.** Fill ms, instance count, GPU ms (`--gate=gpu`, editor closed,
   quiet) against the old chamfered tiles; tune `range_m`, `max_bricks`, the
   view margin.
6. **Breaking.** Edits update the lists (they already rebake the tiles);
   a broken brick's instance goes at once. Later: hand a falling brick its
   instance (no wait for a piece's mesh).
7. **Retire** `build_tile_chamfered`, `add_bevel`, the chamfer's `bound`/
   skirt/backing code in `mask_faces` once nothing uses them; the heightfield
   scene and the city on terrain take the overlay too.

## 5. Status

- 2026-11-23: plan written; stage 1 started (branch `skylit-followups`,
  worktree `C:\Users\lbaun\bc-skylit2`).
