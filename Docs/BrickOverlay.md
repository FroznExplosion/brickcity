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

- 2026-11-23: plan written. **Stage 1 done**: `build_tile` and
  `build_section` return `overlay_bricks` (the key `bricks` was taken: the
  curved ground's box bricks), 10 floats a brick -- min corner, max corner
  (metres, absolute, the mine world's terrain frame), material, colour r g b.
  Collected by `note_brick` (brick_terrain.cpp, a thread-local map set for
  the bake's call): every `mask_faces` face's brick (the bond's rect by its
  course, the plates of that course solid in the face's column; a piece's
  course under its top) and every surface piece of kind BRICK or TILE (the
  whole brick across a tile edge, so two tiles list the same brick: dedupe
  by its corner and course), with the tile or plate laid on it as its own
  one-plate brick. `tools/probes/terrain_bricks_probe.gd` (headless): deep
  sections exact (every face on a brick, every brick with a face, no
  overlaps); surface tiles leave 2-16 thin strips a tile on the tile's outer
  edge (filler, no brick's) and 26-44 bricks with no face of their own (a
  piece covered by the tile on it and its neighbours: listed, harmless).
- **Next: stage 2** -- TerrainBricks (the pool, the pick by distance and
  view, one MultiMesh buffer) and the `TERRAIN_BOX` copy of terrain.gdshader.
  Branch `skylit-followups`, worktree `C:\Users\lbaun\bc-skylit2`.
- 2026-11-23 (2nd chat): **Stage 2 done, stage 3 built** on branch
  `skylit-followups` (NOT merged yet). Lists are 17 floats a brick (studs
  flag; sky light at each face's 4 corners, sampled like a flat vertex at the
  nearest DRAWN cell of the face -- a brick through a wall or drawn in an L
  took the open air's light into the room; block light a face; cells drawn a
  face). `BrickTerrain.overlay_pick` (C++, ~0.4 ms) dedupes across tiles, each
  face from the list that drew more of it. TerrainBricks + `TERRAIN_BOX`
  (colour/light packed as 24-bit whole numbers: read with `int(x)`, never
  `int(x + 0.5)`). Recess: bake marks covered flat faces CUSTOM0.b = 64
  (mask faces, packer tops and overlays; packer SIDES not, they can run past
  their brick), shader sinks them 13 mm within `overlay_reach` (set per pick,
  1.5 m fade); boxes pulled 2 mm toward the eye; flat faces grow 13 mm more
  past INSIDE corners (closed the wall-foot slit). Gates: `--gate=bricks`
  PASS, `--gate=seams` 0/0 px, `--gate=seams --deep --at-top` 0 px (old
  chamfer 88). Overlay is ON with Chamfered brick edges; `--old-chamfer` = A/B.
- Stages 2-3 merged (main d65c41a5) after terrain_audit_probe, mine_world_probe
  (the inside-corner reach now stops at the sample's own plates),
  bevel_gap_probe all passed; terrain_probe fails the same 2 checks as main
  (+ its timing, with other runs going).
- **Stage 6 (breaking, first half) built**: a shot brick of the overlay goes
  the frame it is hit (`TerrainBricks.hide_at`): its slot -- and the plate or
  tile on it -- moved away (the pool is never deleted from, only moved), the
  flat ground's faces of that brick folded in the vertex shader
  (`overlay_holes`, up to 8, found from UV/UV2: terrain_bricks_probe checks
  every covered vertex finds its brick; the overlay lips' v now runs up), its
  studs too (printed_core INSTANCE_SKY), an inside-out box in the ground's
  look (`TERRAIN_CAVITY`) for the hole's walls, till the tiles and sections
  the edit rebuilt are drawn at the generations it set (`hole_wait`). A shot
  that finds nothing gives the brick back (`drop_hole`).
  `--gate=breaklag --burst`: 30 of 30 hidden the frame they were shot every 6
  frames, 26 of 30 every frame (the rest hit a brick already hidden); the
  tile's own hole still 49-50 ms (the audit chat's items 1, 3, 4).
- 2026-11-23 (late): **the open items done** (main after this merge):
  - Packer piece SIDES (one brick tall) and the overlay's lips are covered,
    noted faces: side and corner bevels show.
  - A shot brick of the overlay is cleared from its box at once
    (`_break_from_box`, clear_runs; bedrock never): no find_brick worker
    frame. `--gate=breaklag --burst --burst-every=1`: 26 of 30 hidden the
    frame shot, the tile's own hole 35 ms mean (was 49).
  - `overlay_pick(..., hidden)` leaves shot bricks out in C++ (the GDScript
    holes x instances loop was the 5 ms pick); a turn's picks 0.45 ms mean,
    0.65 worst.
  - Light sampled only on drawn faces: the sky pass 6.5 ms a tile (8.3).
  - **Every scene with ground** takes the overlay: TerrainStreamer.setup makes
    a TerrainBricks (`auto_overlay`, `TerrainBricks.overlay_default`) and
    turns the old chamfered near tier off; the mine world keeps its own.
    `bevel_gap_probe` (heightfield scene) 0 px with it; the dev menu's
    "Real chamfers" toggles it. `-- --old-chamfer` anywhere = the old tier.
  - **GPU** (`--gate=gpu`, editor closed, nothing else running, both from
    52 C): on foot 5.45 ms with the overlay, 6.06 ms with the old chamfered
    tier (0.90 vs 0.93 M tris); 25 m up 3.99 vs 4.00. Its own row ("brick
    overlay off") is inside the gate's noise.
- **Stage 7 done 2026-11-24: the old chamfer is DELETED** (the user's call):
  build_tile_chamfered, set_face_bevel / get_face_bevel, the per-thread
  bevel, MeshBuf::quad's facets, mask_faces' convex/square/bound edge rules,
  skirts and backing, the packer's cut corners, skirts and upright facets,
  the curved ground's chamfer floor; TerrainTile.add_bevel / bevel_enabled /
  the chamfered near surface; the streamer's chamfer bakes; the mine world's
  --old-chamfer, the GPU gate's chamfered row; terrain_bench's G key and its
  chamfer shots; terrain_probe's chamfer-width check; terrain.gdshader's
  geo_bevel. ~940 lines. The overlay is the only real bevel; the world
  setting Chamfered brick edges turns it off. Probes: terrain_bricks,
  terrain (same 2 failures as before), mine_world, terrain_audit,
  terrain_cost; --gate=bricks, --gate=seams, --deep --at-top,
  bevel_gap_probe, ground_tools_probe.
- Not done: the city on terrain was not looked at in a picture (its streamer
  makes the overlay as every scene does); --gate=breaklag --streaming does
  not report the overlay.

- **2026-11-24 (the audit chat took over): see-through slits fixed, behind
  faces built.**
  - Slits: the user saw see-through lines along the grid with the overlay on,
    none with it off. Each flat face sank 13 mm along ITS OWN normal, so faces
    meeting at an angle (a top and the side under it) or a sunk face beside an
    unsunk one (a tile's edge strips) moved apart. terrain.gdshader now moves
    each vertex back along its own ray from the eye (13 mm under the face
    along its normal, more at a grazing view, as far as 4x): a vertex stays on
    its pixel, so the ground covers exactly what it covered and no slit can
    open. POSITION is written on every path of the flat branch (a shader that
    writes it anywhere uses it everywhere). New `--gate=slits` (magenta sky,
    162 scoped views across tile edges): overlay whole 39359 -> 3 px, sunk
    with its bricks hidden 600288 -> 6 px, the flat ground alone 46 (its own
    1-3 px T-junction pinholes).
  - **6b. Behind faces** (the user's idea: bake as if the real bricks were
    missing, so what is behind them is not culled). `build_tile` /
    `build_section` (BrickTerrain.set_behind_faces, the mine world; off
    elsewhere) run mask_faces a second time over the cells NOT in an exposed
    brick, keeping each face that touches one (exposed_brick_cells: every
    brick open air touches, its bond rect and course). CUSTOM0.b = 96
    (BEHIND_FACE); `behind_mesh`, a node of its own (TerrainTile
    "SurfaceBehind", visibility to 30 m, no shadow). The shader keeps them
    only within the overlay's reach, sunk like a boxed face; past it they
    collapse. Their sky light is read past the brick in front of them (what
    the hole will have). A shot brick's neighbours' sides are their own
    instances' (whole boxes), so the hole shows real bricks the frame it is
    hit; the stand-in box (TERRAIN_CAVITY) is off while behind faces are on
    (`-- --no-behind`: the old way). The rebuild still brings the under
    brick's studs (~35 ms).
  - Cost (terrain_cost_probe, a tile, sky light on): 2095 behind triangles
    (the flat mesh 592); a bake 4.6 -> 7.1 ms on its worker (exposed cells
    0.6, the faces 0.75, light 0.5, the rest the split). GPU not measured yet
    (`--gate=gpu` needs the editor closed).
  - Not done: a second shot into the brick behind before the rebuild lands
    (~35 ms) has no layer behind it (seen through till then).

  - **Behind faces only round the eye (2026-11-24).** Baked for every tile
    and section they were ~200 MB more and the machine paged
    (`--gate=deep`'s worst frame 82 ms without them, 907-1538 ms with,
    free RAM 1-2 MB). Now only tiles within 2 of the eye's tile and sections
    within 128 plates of it (BrickTerrain.set_behind_centre / behind_wanted);
    the mine world (`_behind_follow`) bakes a tile or section again as it
    comes into that ring and drops them 2 tiles (64 plates) past it; the
    tile keeps no CPU copy. `--gate=deep`: worst 3.5 ms, 304 MB free at
    the least.
  - **Item 4 done another way (MineWorld.md 21).** mask_faces scanned all
    ~140 plates of a sample in six directions (3.7 ms of a 7 ms bake): it
    now scans only from under the lowest open cell to over the highest
    solid one (face_band; the sample's own plates kept for its edge tests),
    and the exposed-brick search the same. Output byte for byte the same
    (30 tiles and their sections, after shots, behind faces on and off); a
    rebuild with behind faces 7.2 -> 3.5 ms (sky light 1.4 of it now).
