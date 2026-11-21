# The ground's bond: one brick rule for drawing, breaking and falling

Scene: `scenes/terrain_test.tscn` (the mine world), and every scene with brick
ground (the walls of terraces, craters and caves).

## 0. What the user asked for (2026-11-20)

"The bricks don't seem to be connected like LEGO how they should, since they
seem only connected in columns, but need to connect staggered."

What was there (the audit, 2026-11-20):

| | below the top course |
|---|---|
| drawn (`mask_faces`) | seams from a random cut lattice (`cut_before`), paint only |
| broken (`find_brick`, `find_bricks`: shots and both pickaxes) | ONE 1x1 cell, a course tall |
| fallen (`TerrainCollapse.survey`) | its own "found" bond, packed from the bottom of each survey's region, so the same cell was in a different brick from one survey to the next |

Three answers to "which brick is this cell in", none agreeing. What broke was
a column cell, what was drawn was a 2x4's outline, and what held was a third
pattern nobody saw.

## 1. The rule

One function, `brick::bond_rect(x, course, z, group)` (src/terrain_bond.h),
answers for any ground cell below the top course: the rectangle of the brick
it is in. Stateless, from absolute coordinates, the same in every tile, every
survey and every pickaxe. A cell is a stud by a course (3 plates), of the
material of its lowest solid plate.

- **Groups** (`bond_group`): loose (sand, red sand, gravel), medium (dirt,
  grass and its colours, snow, clay, podzol), strong (everything else: stone,
  ores, sandstone, ...). Loose is always 1x1 (joined only up and down; sand
  falls as columns). Medium and strong share one lattice.
- **Footprints**: a course is laid in 4 x 4 blocks, each two 4 x 2
  footprints, both along X or both along Z by a hash (a floor runs both
  ways); each row of blocks is shifted 0 or 2 studs by another hash.
- **No seam over a seam**: on course `c` every seam, in X and in Z (block
  edges, the split inside a block, a footprint's halves), is on a stud line
  of the same parity as `c`; on the next course they are all on the other
  parity. So a full brick never has a seam right over a seam under it,
  whatever the shape around it -- the failure that made the collapse's first
  fixed bond come apart ("a 2-course arm came apart in two",
  Docs/TerrainCollapse.md, what changed while building).
- **Clipped where the ground is not**: a footprint holding air, loose ground,
  or the top course's cells is cut. A 2x4 is whole only when all eight cells
  are strong (a long brick only through rock, as the collapse doc had it);
  otherwise it splits into its two 2x2 halves (a half may cross a rock/dirt
  border: a dirt ledge is bonded to the rock under it). A half not whole is
  cut into its full 2-wide columns, then single rows. Every cell of a
  footprint works out the same split, so all of them agree.
- **The top course, in the mine world, is on the bond too**
  (`BrickTerrain.set_bond_top(true)`, set by mine_world.gd and its probes):
  `pack_tile` lays the surface on the same blocks and parity, a brick being
  the run of top cells of one exact top plate, material and colour inside a
  footprint. Without it the packer's ladder put pieces wherever a cell was
  free, and where a top seam stood over the bond's under it a two-course arm
  split (terrain_collapse_probe's arms failed exactly so). Every other scene
  keeps the ladder's look; their walls are on the bond.
- **Bricks across a tile edge**: odd courses' bricks straddle tile edges
  (their seams are on odd studs, tile edges on even ones). Each tile draws
  its part (`Piece.bx/bz/bsx/bsz` is the whole brick), and every quad's UV is
  its place in the WHOLE brick with UV2 the brick's face, so the seam shader
  outlines one brick with no line at the tile edge. Tint, smooth-tile and
  overlay hashes go by the brick's corner, so both parts agree. Breaking a
  top brick takes all of it, in both tiles.
- **Placed blocks keep their shape** (`BrickTerrain.mark_placed`, called by
  the builder after its `fill_box`): a block the player lays is ONE brick --
  drawn, broken and falling as one -- and the bond clips round it. Saved
  beside the edits (`<save>.placed`, `BCPB` format 1, 4 ints a cell); any
  other edit to one of its cells makes that cell ground again.

## 2. Who asks it

- **Drawing** (`mask_faces`): a face merges only within one brick (the
  rectangle's key), so the seams of walls, cave roofs and cave floors are the
  bricks' own edges. Cells past the tile's sample margin are read from the
  field (`solid_at`, `surface_plate`) so two tiles agree on a brick across
  their edge.
- **Breaking** (`find_brick`, `find_bricks`): a wall, cave face or pit face
  gives up the whole brick, not one cell.
- **Falling** (`TerrainCollapse.survey`): its virtual bricks are the bond's
  rectangles, and its top course is the packer's pieces (the same pieces the
  tile draws and a shot breaks). What holds is what you see.

## 3. Checks (2026-11-20)

- `mine_world_probe` `_check_bond`: every cell of a brick names the same brick
  (0 disagree); no seam over a seam (0 of 324 joints, the top course on the
  one under it and two courses of deep rock); a buried brick broken takes its
  4x2 and no more; a wall hit takes its whole brick.
- `terrain_collapse_probe`: all pass -- the stone arm holds, falls whole with
  its pillar, a dirt arm needs stronger studs than stone, the 40-stud arm
  holds and falls as one group (it split in 11 with the top course on the
  ladder), and a placed 2x2 falls as one.
- `--gate=collapse` passes in the game (survey worst 30 ms on the worker);
  `bevel_gap_probe` 0 holes with the chamfer and without; terrain_probe,
  fluid_probe pass.
- The collapse survey now packs the top course's tiles (`top_columns`, a few
  ms a tile, cached across a survey's grown attempts).
