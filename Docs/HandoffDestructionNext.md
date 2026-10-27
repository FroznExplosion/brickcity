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
