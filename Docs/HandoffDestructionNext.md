# Handoff: building destruction, next design (2026-10-26)

For the next chat working on building destruction. Read this first, then
`Docs/HandoffStructBugs.md` (the running state of the destruction branch) for detail.

## How to work

- Worktree `C:\Users\lbaun\bc-struct`, branch `struct-bugs`. Merge into main small and
  often (`git merge --no-ff struct-bugs` from the main folder, then `git push origin main`).
  After a C++ merge, rebuild main's DLL with the editor closed:
  `python -m SCons pdb=yes` in `gdextension/brick` (symbols, so a crash names its line).
- Windowed passes: launch from Bash with `override.cfg` in the worktree (never in main).
  One windowed pass per command; check heat after (`python tools/heat_sum.py --last 3`);
  check for other chats' Godot first. Timing only with nothing else running, display awake
  (a `--ring` of about 14-20 s; 40 s or more means the screen is asleep).
- The user is tanks/mechs-free here: test buildings only.

## What the user is seeing now (2026-10-26)

1. **A building that collapses blinks when it lands.** Better since `dcbdbf2` (a toppled
   tower's band meshes now keep drawing until its rebuilt mesh is up), but it still happens.
2. **The landing wakes everything at once.** A collapsing building falls as a lower level of
   detail -- the toppled building's *bands*, with no windows. When it hits the ground and
   breaks, every floor gets its windows (and rooms and furniture "become active") in the same
   moment as it is breaking into pieces. The user's read, which the code supports: the detail
   change and the break happening on the same tick are what cause the trouble.
3. **The user's proposal:** a building that breaks into parts should break **only where the
   breaking happens**, not turn the whole building into real geometry. Far wreckage capped and
   merged is done (below); this is about the hit/landing itself.

## The current system, in one pass

| stage | what draws / simulates it | where |
|---|---|---|
| standing, unhit | a **shell**: one mesh per building, painted windows, glass | `BuildingShell`, `CityScene._shells` |
| first hit | **promotion**: the storeys the hit reaches are laid as real bricks ("storey units", `lay_band`), drawn in **bands** (horizontal slices) with **panes** (glass) per band | `BuildingRegistry.materialise`, `CityScene._promote`, `_tend_brick_panes`, `_submit_glass` |
| damage | bricks die by id; stress solve + span rule + region load check decide what comes loose | `BrickWorld.apply_hit`, `solve_stress`, `cut_spans`, `gravity_check` |
| something comes loose | a **piece** (`BrickIsland`): a new chunk + rigid body. A whole toppled building keeps its building's band meshes (`_instance_bands`), no windows | `IslandManager.spawn`, `_shed` |
| far | coarse stand-in mesh (no bake), mega buildings cut in big chunks by the director | `_starts_coarse`, `CollapseDirector` |
| landing | the piece is broken where it lands (`shear`, `_shed`); any change a band patch cannot carry rebuilds the WHOLE piece's mesh (bake on a worker, then upload) | `IslandManager.rebuild_mesh`, `_patch_bands` |
| at rest | frozen; asleep past 150 m or over the debris cap, drawn by a stand-in; stand-ins merged per 32-stud tile, far tiles capped by apparent size | rubble field (`IslandManager`, DestructionLod 3.5) |

## Why landing goes wrong (what is verified, what is not)

- **Verified:** a toppled tower drawn by bands landed, broke, and needed a full rebuild; the
  bands were freed at once and the new mesh came a worker later, so the piece drew nothing
  (only its window glass was left) -- `big_city.tscn -- --landing --big` showed 69% of its
  bricks undrawn at the landing tick. Fixed in `dcbdbf2` (bands retire when the new mesh
  lands, `_drop_retiring_bands`); `--landing` passes twice since. The user still sees blinks,
  so there is at least one more path.
- **Not verified, likely:** at landing the piece (a) is split into several pieces, each new
  piece baked and uploaded on workers (a big part is blind until then -- `HOLD_MAX_FRAMES`
  keeps the parent drawing for up to 90 frames, but never triggered in tests), (b) goes from
  band meshes to its own full mesh, (c) gets interior furniture laid as bricks (~180 bricks in
  the `--landing` run), and (d) may get panes/glass back as bricks are re-drawn. All on the same
  few ticks. Look at what happens to glass and furniture of a toppled piece on landing:
  `_tend_brick_panes`, `_submit_glass` (city_scene), `registry.compromise_items`,
  `lay_item_into`.
- **Whole-building materialisation:** a hit lays the storeys it reaches, but a collapse makes
  the whole building pieces; each piece carries everything above the cut.

## The proposed system (the user's direction) -- what would change

1. **Break locally.** A hit or a landing turns only the region around it into real, separate
   bricks. The rest of the building (or the falling piece) stays one rigid body with its
   current mesh, its index buffer patched to hide what left. Plans already written for this:
   `Docs/Structures.md` (tiles instead of bands: 32-stud tiles across as well as up, loads by
   region, collapse in three tiers) -- "Bands are slices across the whole building" is named
   there as the reason one hit means one big rebuild.
2. **One level of detail through a fall.** A piece keeps the representation it fell in --
   bands, no windows -- through the landing. Changing its detail (full mesh, panes, furniture)
   waits until it has **settled** and then happens one piece at a time, budgeted, never on
   the same tick as a split. Rule of thumb for the code: *never change topology and detail
   in the same tick; keep the old drawing until the new one is up* (`_drop_retiring_bands` is
   the first instance of that rule).
3. **Windows/glass consistent.** Either a falling piece carries its panes with it, or panes
   stay off until it is at rest and out of the director's way. Today they drop off as it falls
   and come back on all floors at the landing.
4. **Interiors at landing.** Furniture laid as bricks (`compromise_items`) only for the region
   that broke, and after the split, not inside it.

## Suggested first steps

1. Extend `--landing` (city_scene `_run_landing_pass`) to record, per tick around the landing:
   pieces spawned, meshes rebuilt (full vs patch), panes/glass created, furniture laid. That
   shows which of (a)-(d) land on the same tick. Also run it in `city.tscn` and from 100 m.
2. Defer detail changes after a landing: queue "becomes full detail / gets panes / gets
   furniture" until settled + N ticks, one piece a tick.
3. Prototype local breaking at landing: shear only the bricks near the contact (`shear` with a
   radius), patch the piece's own mesh (index regions) instead of rebuilding it.
4. Then tiles instead of bands (Structures.md) for standing buildings.

## Theory: a chassis -- the frame holds the building, the panels break (2026-10-27)

**Not built, not decided.** The user asked for the idea worked through, with no change to the
game: "what if we made the destruction more like Battlefield, so the chassis of a building is the
structure rather than all walls, floors, etc. -- the edges of floors and the support beams. The
centres of a wall or floor could be broken brick by brick, then the edges and actual support
structure is a bit stronger." Would that make destruction faster and more consistent?

In Battlefield (Bad Company 2 on) walls and floors are panels that blow out piece by piece, and
the building stands on a frame; it comes down when enough of its supports are gone. Here every
brick is structure: any brick can carry load, and every hit asks the whole building.

### What it would be here

- **Two kinds of brick** in a generated tower:
  - **Frame**: the columns (`TowerRecipe.frame` "columns" -- the generator already records them,
    DestructionLod 4 / 5.3), the stair core ("core"), and the edges of each floor -- the slab
    ring under the facade and slab strips along the lattice lines (**beams: not in the recipe
    yet**; the interior walls on every third line stand where beams would).
  - **Infill**: the wall panels between frame members and the middle of each floor panel.
- **Infill hangs on its frame cell** (the panel between two columns and two slabs). A hit kills or
  loosens infill bricks one by one, as now, but "does anything fall?" is asked only inside that
  cell -- a flood fill bounded by the frame -- not of the whole building.
- **The frame is a small graph**: a node where a column meets a slab at a lattice point, an edge
  for each column storey and each slab edge between two points. Load and support are solved on
  it. The 80 x 60, 34-storey tower: 9 x 7 lattice points x 35 levels = ~2,200 nodes and ~6,000
  edges, against the 24,522 bricks (and their joints) the solve walks today.
- **A member fails** when force breaks enough of its own bricks (a blast through a column) or
  when the graph says it carries more than it can. When the graph splits, each part with no path
  to the ground leaves as ONE piece: its members and the infill hanging on them.
- **The user's attachment rule still holds** (memory "brick-attachment-rule", `hang_probe`): an
  infill brick still clicked into bricks that stay does not fall. "A bit stronger" should be
  real, not a hidden multiplier: frame members built from parts that are stronger in a real model
  too -- long plates or beams overlapping across the joints -- so it still passes the user's
  yardstick, "what a real brick model does" (2026-10-13).

### Would it be faster?

Against what `--big --shot` measured on 2026-10-23 (HandoffStructBugs item 8) and DestructionLod:

| cost today | with a chassis |
|---|---|
| **Physics of moving pieces**, the mean frame (item 7): 4,000-12,000 boxes in motion; one 23,801-brick piece is 3,008 merged boxes, set by its layers, not its width (DestructionLod 5.6) | A falling piece collides by its members: a column line one box per run, a slab one box per storey -- ~100-200 for that piece, if infill rides without boxes of its own (it cannot fall out of a cell while the cell's frame holds). **The biggest win.** |
| **The stress solve**: mega buildings solved alone 97-143 times a run, 37-60 ms a run, the worst single 1.7-3.4 ms | Most hits touch only infill: no solve, a bounded flood fill in one cell. A hit on the frame: a solve of ~2,000 nodes instead of ~24,000 bricks. |
| **Making a piece**: `split_island` copies its bricks into a new chunk, 5-17 ms for a big one | The same per piece (it is still bricks); pieces come apart at members, so fewer and more predictable ones. |
| **Landing**: broken where it lands; any change a patch cannot carry rebuilds the whole mesh | Local by construction: members at the contact fail, infill near it shatters to crumbs, the rest stays one piece with its mesh patched -- the "break locally" proposal above, with the frame saying where "locally" ends. |
| **Drawing**: meshes, panes, furniture, uploads (the landing blink, stand-in upload stalls) | No change. The chassis decides what breaks, not how it is drawn. |

So: clear wins in physics while things fall and in skipped solves; none in drawing, which is
where the blink and most of the spikes are.

### Would it be more consistent?

- **Breaks follow the frame.** A building comes apart at failed columns and beams, storey by
  storey -- not along whichever panel seams line up (CollapseNext 30; the stagger fixed the
  seams, it does not decide where a building fails).
- **Same hit, same result.** A small graph has few near-ties. Today load routed along one
  grounding path through single bricks is what once sprayed loose bricks (memory
  "brick-attachment-rule").
- **Storey units fit it.** "A storey gave way" (`registry.storey_gave_way`) becomes "this storey's
  columns and walls cannot carry what is over them" -- asked of ~63 columns, not every brick
  topping the storey; and the frame of the whole building can exist before any storey is laid.
- **Holes look like holes.** A wall shot through loses a panel; the opening's edges are the
  frame, which reads as a building, not a cloud of bricks.
- **What it loses:** a building can no longer fail through a wall that is not frame -- the
  interior walls on every third line carry load today and would have to count as frame, or the
  building gets stiffer than its bricks say. Less emergent breakage: no cracks running across
  infill from one cell to the next.

### What it touches (why it is a big change)

- **Generator**: beams (slab edges, lattice lines) as real parts; `TowerRecipe.frame` gains
  "beams"; new long parts in Docs/Parts (and printable).
- **BrickWorld (C++)**: a frame graph per building, a member's capacity from its bricks, the solve
  on the graph, infill connectivity bounded by cells.
- **IslandManager**: pieces collide by members; infill rides a piece without boxes.
- **Co-op**: DamageLog SOLVE/SEVER entries name members -- fewer and smaller.
- **Player builds** have no recipe: a frame by part kind (beams and columns tagged in the
  palette), or inferred (`StructureSpaces.find_floors` for slabs, columns by stack), or builds
  keep today's all-brick solve -- two paths to keep working.
- **Planet buildings** (Docs/HandoffPlanetWorld.md, D2 "falling") copy the city's solve and loose
  pieces next. A frame graph takes a gravity direction and nothing else, so it would port to a
  planet's local down more easily than the brick solve. D2 should not wait for it: port today's
  path, and keep "ask the solve" to one call, so a chassis can replace it for both later.

### If tried: the smallest steps, each measured

1. **Measure first**: what share of hits in `--big --shot` touch only infill (no brick of a member
   from `TowerRecipe.frame`, nor the slab ring). If most do, skipping their solves is worth a lot;
   if not, the solve half of the idea is small.
2. **A frame overlay, data only**: members from `TowerRecipe.frame` plus the slab edges, each
   with its bricks. Ask `storey_gave_way` of it and compare with today's answers over
   `--storeys --big` and `storey_unit_probe` -- same decisions, fewer bricks walked.
3. **Infill hits without a solve**: the bounded flood fill; `hang_probe` and `collapse_probe` must
   pass; the solve ms of `--big --shot` before and after.
4. **Falling pieces collide by members**, infill as passengers: boxes in motion and the mean
   frame of `--big --shot`; `--jam --big` and `--floating` for what that breaks.
5. Only then real beams in the generator (parts, strength), and `--breakshape` for how buildings
   come apart.

## Errors and warnings (2026-10-26)

- **Fixed:** `_field_build(): array.size() != p_vertex_array_len` (rubble field merge; an empty
  UV2 counted as present). `93e913c`, probe case in `rubble_field_probe`. Merged with this doc.
- `instance_set_scenario: BUG, indexing did not unpair geometries from light` (Godot renderer,
  seen once at 2:48 in play): not traced. Possibly a node freed while hidden/reparented
  (stand-ins hidden by the rubble field, retiring bands). Watch whether it repeats.
- **GDScript warnings** in the user's paste are all in other areas' files (weapons, vehicles,
  mech, AI, menu, disasters, planet nav, character) except `city_scene.gd:6031` (`Tank.Seat`
  = -1, vehicles' to fix). City/building scripts are clean (`tools/warn_check.tscn` prints a
  script's warnings: `-d --headless --path . res://tools/warn_check.tscn -- scripts/x.gd`).

## Done in the last sessions (all merged)

- Close-up big-break **crash** (bake worker vs `place_block`), then the freeze it left
  (a write cancels a running bake): `--bigbreak --big`.
- **Staggered floor seams** (every other floor's plates offset): layers 0->4, slices 5->2.
- `--widecheck --big` 10 ok (wide buildings, span rule bay).
- `collapse_probe` push-over check fixed (56/0).
- Patch counters on the census line: nudge and perch still fire, watchdog 0 (kept).
- **Rubble field**: sleeping wreckage merged per tile on workers, far tiles capped by apparent
  size (tall before short), near tiles always drawn. `--rubble --big [--no-field]` measures; the
  near *settled* pieces are what costs (16-30 ms GPU), not the far stand-ins.
- **Landing blink** (band meshes freed before the rebuild was up): fixed, `--landing --big`.

## Open (besides the redesign)

- `--dormant` "with the same bricks" fails about half the time, with or without recent work.
- Near settled pieces' draw cost (16-30 ms GPU in `--rubble`): coarse sooner, or cap the near
  tier on settled pieces.
- `--rubble` is not repeatable (each collapse differs); make it deterministic before A/B work.
- Floating furniture (rare, user still sees it).
- Stair kinds, office furniture by room kind, the shell-piece split (user's call).

## Passes and probes worth knowing

`big_city.tscn -- --landing --big`, `--bigbreak --big [--far]`, `--widecheck --big`,
`--rubble --big [--no-field]`, `--breakshape [--picks=N] [--no-stagger]`, `--lodbreak --big`,
`--breaklag --big`, `--big --shot` (census incl. "patches:"); `city.tscn -- --dormant`,
`--chamfer`. Headless: `collapse`, `float`, `debris`, `dormant`, `hang`, `structure`,
`stagger`, `storey_unit`, `bake_race`, `rubble_field`, `damage_profile`, `room_clear`.
