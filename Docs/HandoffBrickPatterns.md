# Handoff: brick patterns (replace the region fit's picking)

For the chat that takes this over (2026-11-26). Background: Docs/TerrainRegions.md
(sections 11 = the user's decisions, 12.x = what was built and measured).
Worktree that built the region fit: `C:\Users\lbaun\bc-regions`, branch
`terrain-regions` (merged into main up to b521d48f). Make your own worktree.

## Why

The region fit (terrain_fit.cpp) picks LEGO-like bricks of random sizes for the
ground. It works and is exact (probes pass), but it made terrain SLOWER, and
the goal was to make it faster. With it on (`TerrainFit.set_enabled`, preset
`bricks.fitted`; OFF by default):

- a new tile bakes in ~57 ms against the old 2x4 pattern's ~26 (49 tiles in
  streaming order, headless); new ground fills in ~30% slower; ~30 MB caches.
- WHY: it fits whole 16 x 16 regions (every brick, rock nobody sees too), and
  odd courses' squares are shifted 7 studs so half the squares cross tile
  edges: it needs the NEIGHBOUR tile's generated cells, which it makes itself
  (lean noise), and that tile's bake makes the same noise again. ~19 ms a tile
  is that second generation, ~15 ms the fitting (84 regions a tile).
- The old pattern (`brick::bond_rect`, terrain_bond.h) is a stateless rule per
  cell: it reads ~8 neighbouring cells of the sample the bake already has. No
  extra generation, nothing kept.

## The plan (the user approved it)

Keep what the user wants -- random sizes in both directions, the size shares
set in the M menu Bricks tab, tall bricks, bricks crossing chunk edges, the
stagger -- but pick bricks like the old system, per cell, from cells already
in memory:

1. **A library of patterns.** At world set-up, fill a SOLID 16 x 16 square,
   one layer (3 courses) deep, with the existing filler (`Fitter`,
   terrain_fit.cpp) and the world's shares; ~64 different ones (seeds). ~50 KB,
   milliseconds. Calibrate the library's shares (the existing `calibrate` idea)
   so that, after cutting by real ground (step 3), each shape lands within ~5
   points of what is set.
2. **A cell's brick.** Its square (odd courses shifted 7 studs, as now) and
   course choose a pattern by hash; the cell's brick is that pattern's brick
   over it. As cheap as `bond_rect`: no generation, no regions, no caches.
   Bricks cross tile edges as now (squares are global).
3. **Where the ground cuts a brick** (cave wall, a hole, an edit, the top
   course): that brick ALONE is split into the largest listed shapes that fit
   its remaining bond cells, by a fixed procedure that reads only that brick's
   cells -- so every cell of it agrees (the same reason bond_rect is
   consistent). Tall bricks: whole only if every course of it is there, else
   split by course first.
4. **Stagger:** odd courses shifted 7 studs, each course its own pattern;
   measure seams over seams (`region_fit_probe` reports stack/k; region fit:
   ~445 a thousand joints, old pattern 4). Today's stagger is scored within
   each layer only (`stagger_layers` false) and that already halved the cost.

Then: measure against the old pattern with the same tests (below); if it is as
fast or faster, make it the default and DELETE the region fit's lookup and its
caches (region cache, fit cell blocks + lean generation `brick::generated_cells`
if nothing else needs it, `TopCache`, `calibrate` on real ground).

## Where to plug it in

All of it goes through `BondView::rect` (brick_terrain.cpp): with the switch
on it now asks `brick::FitView::at` and falls back to `bond_rect` among cells
no whole fitted brick holds. Replace the fit lookup there with the pattern
rule; keep the rest:

- `BondRect` already carries `c` (bottom course) and `h` (tall).
- The mesher keys faces by `bond_key(r.x, r.c, r.z)`, the overlay lists
  `h`-course boxes, `find_brick`/`find_bricks` take whole bricks, the collapse
  survey (`terrain_collapse.cpp`, `in_fitted`) takes footprints a course.
- The top course: `pack_tile`'s fitted top (`brick::fit_top`) is behind
  `bricks.fit_top` (off, deferred). Leave it off.
- The collapse's "big groups float" (500+ cells, `bricks.float_cells`, fit on
  only) and the tall-bodies stage D (built, `TALL_BODIES` false: a weak-studs
  test fails with it, not understood) are independent of the picking.

## Tests (run fit on with `--fitted`, and off)

Headless: `terrain_bricks_probe`, `terrain_audit_probe`,
`terrain_collapse_probe`, `mine_world_probe` (cold bake under 120 ms),
`fluid_probe` (79 checks), `region_fit_probe` (shares, stack/k; `--lookup`).
Windowed, one at a time, heat summary after each (CLAUDE.md):
`--gate=bricks --fitted`, `--gate=breaklag --burst --fitted`,
`--gate=flight --fitted` (tiles resident after slowing: old 192, fit 131),
`--gate=deep --fitted` (frames to load: old 200, fit 292).
A streaming bench (49 tiles in rings, `build_tile` each, per-tile ms) was a
scratch script: write one again (old pattern ~26 ms a tile, fit ~57).

## Open questions (the user)

- Building materials in the float rule: left out for now (they still fall).
- Deferred until performance is good: the fitted top course, juts, slopes,
  tall bodies.

## Also measured (for whoever does performance next)

`--gate=gpu`, fit off, 1280x720 at 0.75: frame 8.3 ms, GPU 7.6 -- water 3.0
(the sea 2.0), near tiles 1.2, near trees 1.1, far tier 1.0, sun shadows 0.6.
The user's 20 ms is drawing at full window size plus vsync; water is the
largest single part.
