# Handoff: destruction work (branch `struct-bugs`), 2026-10-20

For the next chat picking this up. The plan and everything measured is in
[DestructionLod.md](DestructionLod.md) (§5 is what was built, in order); open collapse items in
[CollapseNext.md](CollapseNext.md).

## Where things are

- Worktree `C:\Users\lbaun\bc-struct`, branch `struct-bugs`, everything committed and merged into
  `main` (last merge `de3e794`, pushed). Main's DLL was rebuilt after the last C++ merge.
- **The worktree's DLL is stale**: it was built from a temporary revert of the "hits on falling
  pieces" commit (an A/B that was stopped for low memory). Before any run in the worktree:
  `cd gdextension/brick && python -m SCons`, then `--headless --path . --import`.
- `override.cfg` is in the worktree (test windows hands-off). Never in main.
- Main has other areas' uncommitted files (`Docs/Status.md`, `project.godot`, the brickify pyc,
  `Docs/please rename/`, some `.uid`s): leave them.

## Done this session (all in DestructionLod.md §5)

| § | what | key code |
|---|---|---|
| 5.1 | a piece is frozen only on something still; woken when what held it moves 0.3 m or goes | `IslandManager._resting_on_moving`, `_note_holders`, `_check_holders`, `HOLDER_SLIP` |
| 5.2 | damage never changes how an interior is drawn: rooms within 60 m, painted panes on brick buildings past that, no groups until a hit building is known standing | `InteriorGroups.INTERIOR_RANGE`, `CityScene._tend_brick_panes`, `_interior_unsure`, `shaders/window_interior.gdshader` `near_hide` |
| 5.3 | generator markers: floors, columns, stair core in the structure record | `TowerRecipe.frame`, `StructureSpaces.for_tower` |
| 5.4 | rooms-as-unit measured: every generated room faces out, no gain; not built | — |
| 5.5 | hits on falling pieces: mesh once a tick, index patched from what changed (0.57 -> 0.076 ms a hit) | `IslandManager._mesh_later`, `flush_meshes`; C++ `BrickWorld.refill_changed`, `track_indices`, `set_index_check` |
| 5.6 | coarse collision for falling pieces: built, 3-6% fewer boxes, removed | — |
| 5.7 | floors from the record for landing snaps and mega-collapse chunks | `BuildingRegistry.floor_lines`, `IslandManager.floor_lines`, `CollapseDirector.plan(floors)` |

## Open, in the order to do them

1. **`collapse_probe` flickers** (3 runs of 4, with or without 5.7): "an untouched tower of 6
   storeys to test on -- 20 of 22 buildings used already". It takes 20 of the city's 22 towers;
   collateral damage on the last two leaves its last section none. Passed reliably before 5.5.
   - Confirm the cause: in the worktree `git revert --no-commit <5.5 commit>` (log message "Hits
     on falling pieces"), rebuild, run the probe 4x, then `git revert --abort` and rebuild. Run
     one probe at a time (the last attempt was killed for low memory).
   - If 5.5 (more blasts landing on time = more collateral): fix the probe's picker
     (`collapse_probe.gd` `_tower`, ~line 212), e.g. reserve towers far from earlier sections or
     move a section to its own probe as `OWN_PROBE` does. The check is wanted: fix, don't prune.
2. **Frames in `--big --shot` are ~20 ms against ~17.7** since 5.5 -- because every blast now
   lands (4,436 against 3,028), ~40% more pieces moving. The physics step on moving pieces is
   what a collapse costs now (DestructionLod §5.4-5.5). Box count is set by layers, not width
   (§5.6), so the next idea has to cut *moving pieces* or *contacts*, not boxes: e.g. settle
   sooner, fewer small bodies, or a cheaper shape for pieces in the air.
3. `--lodbreak` once had 1 heap brick in mid-air (flaky; the crumb floor ray, CollapseNext 28).
4. Not started from the plan: rubble at rest merged into one static body per tile (§3.5; measured
   only 24 settled pieces at the end of `--big --shot`, low value); a floor finder for player
   builds (Structures §2.4) so builds get `floors` too; the nudge/perch/watchdog patches in
   IslandManager could be retired once their counters stay at 0 (`--big --shot` census
   "support:" line).

## How to check

- Probes (headless): `float` 50, `debris` 29, `hang` 10, `collapse` 63, `heap` 11, `crack` 9,
  `seam` 23, `spaces` 11, `interior_group` 33, `interior` 87, `fixture` 47, `shell` 38,
  `section` 32, `barrage` 8 (keeps the index and components checks on).
- Windowed (Bash, `override.cfg`): `city.tscn -- --groups --big` 25, `--jam --big` 4,
  `--breaklag --big` 7, `--wreck` 2, `big_city.tscn -- --lodbreak` 8.
- Profile: `city.tscn -- --big --shot`; the `[prof]` lines now break damage down
  (`of which damage, mean per tick`, `loose pieces (damage_near)`, `a hit on a piece`).
- Timing only with the editor closed and no other Godot running; alternate A/B pairs; report
  heat (`python tools/heat_sum.py --last N`) after windowed runs.
