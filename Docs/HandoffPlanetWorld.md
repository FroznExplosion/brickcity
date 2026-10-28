# Handoff: the planet's world -- ground, biomes, trees, the player (Planets.md 11.5-11.10)

For a new chat. Read this, then Docs/Planets.md §11 (11.5 order, 11.6 state, 11.7 port rule,
11.9 biomes, 11.10 trees and its "revised" and timing notes), then the repo's CLAUDE.md. The AI's
nav regions on the planet are ANOTHER chat's (Docs/HandoffPlanetNav.md, branch `planet-nav`):
stay out of `setup_ai`, the squad gate and `scripts/ai/` except small fixes.

## The user's rules for this work

- **Only the terrain is low-poly.** Everything else -- trees, buildings, props -- is bricks,
  furniture and items, reusing the game's own brick assets. (Low-poly box trees were built once
  and thrown out for this.)
- Write the plan into Docs/Planets.md before building; record results there after.
- Merge into main (`--no-ff`) and push when something works, small and often.
- Windowed runs one at a time, start under 80 C, report peak and held-back after each
  (`python tools/heat_sum.py <start> <end>`). Timing only with the editor closed and no other
  chat's runs going; otherwise report numbers as unreliable.

## Where things are (2026-10-24)

Scene `scenes/planet.tscn` (`scripts/planet/planet_scene.gd`): a 10 km planet of smooth voxel
ground (Zylann voxel module, after STA's planets), impostor from orbit, atmosphere, a
shader-only sea, towns and landmarks of buildings that crest the horizon and fade in by size,
a translation-only floating origin at 4 km.

- **Player:** `PlanetPlayerKit` (scripts/planet/planet_player_kit.gd) -- the firefight's kit:
  PlayerHud, PlayerArsenal (slots 1-4, 5 ordnance, pickups, grenades, skills, the saved kit and
  level), aim assist, hit feedback, callouts, aggro meter. Not yet: brick melee context, mech call,
  workbench. F flies (`PlanetWalker`): 50 m/s, wheel to change, **Shift 500 m/s**.
- **Biomes** (11.9): `PlanetBiomes` (scripts/planet/planet_biomes.gd) -- temperature by latitude
  about `PlanetData.climate_axis` less 0.25 C/m, humidity noise, eight biomes. One equirect map
  baked with the impostor (`PlanetImpostorBake`), read by `shaders/planet_ground.gdshader` (snow
  where below freezing at the height; sand, cliff rock live). The spawn's town is on steppe.
- **Trees** (11.10 revised): `PlanetTrees` (scripts/planet/planet_trees.gd) -- 64 m cells on the
  cube-sphere seeded by key (same trees every visit, nothing stored), density and variants by biome
  (`TREES` table), none on pads / sea / >30 deg. Drawn as the heightfield scene draws its trees:
  `Trees.recipe(v)` -> `RecipeMesh` -> `ImpostorLod` (bricks within 45 m, baked cards past, gone
  by 640 m), one set per variant per cube face, the set's node turned so the face normal is +Y.
  Trunk colliders within 96 m on `Layers.FIXTURE` (on WORLD the squad gate failed with the nearest
  trunk 89 m away -- cause never found; vehicles, which do not collide with FIXTURE, drive through).
  `-- --no-trees` leaves them out (for A/B).
- Everything that moves is on local down (§11.7: `Gravity.up_at` and the helpers in
  scripts/gravity.gd, exact in the flat game).

## Tests

Headless (from your worktree): `tools/planet_tree_probe.gd` (10; its two frame times are printed,
not judged), `planet_biome_probe` (8), `planet_nav_grid_probe` (9); planet gates
`res://scenes/planet.tscn -- --gate=pawn` (12), `--gate=mech` (11), `--gate=tank` (12),
`--gate=soldier` (9), `--gate=squad` (10, the nav chat's). Windowed: `-- --gate` (the walker, 9,
shots in shots/planet_gate_*.png), `tools/planet_tree_shot.gd` (trees at 20 / 90 / 300 m).

Last quiet-machine timings: tree fill 5.8-6.4 ms worst a frame, 500 m/s low 8.8-11.5 ms; the
walker gate's frames over 40 ms 10 without trees, 16 with -- the six extra all at the spawn while
it loads (43-247 ms).

Known noise: a windowed run nobody watches stalls (250 / 750 ms frames, display sleep) and then
the walker gate's "no building popped" check can fail on one long frame -- it did once WITHOUT
trees. Rerun before believing it.

## Brick buildings (2026-10-25)

Planets.md 11.11: near buildings are real brick towers (drawn, solid, a front door, bricks to
the AI); `--gate=bricks` 8/8; timed awake (GPU 11.2 ms vs 9.4 with shells only). Next there: stairs (the city's
staircase fixtures); damage and destruction on the planet; furniture.
For D2 (falling): a "chassis" redesign of the city's destruction is being weighed
(Docs/HandoffDestructionNext.md, "Theory: a chassis", not decided). Port today's solve and loose
pieces anyway, but keep "ask the solve" to one call, so a frame graph could replace it for both.
**D2 step 1 built (2026-10-27, branch `planet-fall`):** the one call is `PlanetBuildings._solve_site`
(the city's `solve_structure`); loose groups fall as `PlanetPieces` toward the planet's centre and
freeze where they lie (Planets.md 11.11 "Falling, D2 step 1"); `--gate=damage` 12/12. Next in D2: a
hard landing breaking a piece, hits on pieces, crumbs and a cap, a building toppling whole.

## What is next, in order

1. **Bake the tree cards while the spawn loads** -- built (Planets.md 11.10, "Plan: the cards
   baked while the spawn loads"): one bake per mesh shared by every set, prebaked before the
   walker is let go; gates print the hitches "in play" too. A/B timed awake and quiet: in
   play 9 / 8 with trees vs 9 / 9 without, frame for frame; the trees' extra frames are in the load.
2. **Sway and snow on trees** -- done (Planets.md 11.10 "Sway and snow on the trees"): the
   tree's own up for both, a breeze per cube face, snow caps by the ground's freezing rule. The brick shader's snow and the weather sway are
   world-up; on a planet they need the instance's up. `ImpostorLod.sway` / `snowcap` are off now.
3. **Trees solid to vehicles** -- done (Planets.md 11.10 "Trees and vehicles"): trucks and APCs
   are stopped by trunks (`Layers.TREE`), a tank knocks a tree down; `--gate=trees` 7/7.
4. **Trees in the AI's world** -- done (Planets.md 11.10 "Trees in the AI's world"): trunks are
   proxies in the nav regions (walked round, cover), a knocked one leaves them;
   `planet_tree_ai_probe` 8/8.
5. The spawn town on greener ground (a temperate-grass pad or a nudge to `climate_axis`), if the
   user wants it.
6. From orbit, a darker forest tint -- done (Planets.md 11.10 "Forests from orbit").

## Rules that bite

- Own worktree and branch; `git merge main` first. Main brings C++ often: rebuild your DLL
  (`python -m SCons` in gdextension/brick) and `--import` after every merge -- a parse error right
  after a merge is a stale DLL. Kill Godot by PID only.
- `planet_scene.gd` is shared with the nav chat: small, surgical edits; merge soon.
- Test windows: `cp tools/test_window.cfg override.cfg` once in the worktree, launch from Bash,
  no `--resolution`.
- Write Python patch files with Write, not heredocs (the Bash tool halves backslashes).

## Falling, D2 step 2 (2026-10-27)

Planets.md 11.11 "D2 step 2 built": hard landings shear and snap a piece, small groups are crumbs
(`PlanetCrumbs`), a cap (48 moving, 160 kept). `--gate=fall` 7/7. Step 3, hits on pieces:
built (`PlanetPieces.damage`, `--gate=hits` 8/8; a building's killed bricks are crumbs too).
Step 4, a whole building toppling: built (`PlanetBuildings._topple`, `PlanetPieces.adopt`,
`--gate=topple` 6/6). Next in D2: the city's snap preferences, a storey giving way (TIP / CRUSH),
the AI told where pieces lie. `BrickWorld.is_solid` reads
false for live bricks after a solve -- use `block_at` + `is_block_absent`.
