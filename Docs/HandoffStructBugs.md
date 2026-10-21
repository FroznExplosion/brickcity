# Handoff: destruction work (branch `struct-bugs`), 2026-10-20

For the next chat picking this up. The plan and everything measured is in
[DestructionLod.md](DestructionLod.md) (§5 is what was built, in order); open collapse items in
[CollapseNext.md](CollapseNext.md).

## Where things are (struct-bugs)

- Worktree `C:\Users\lbaun\bc-struct`, branch `struct-bugs`, everything committed and merged into
  `main` (last merge `de3e794`, pushed). Main's DLL was rebuilt after the last C++ merge.
- **The worktree's DLL is stale**: it was built from a temporary revert of the "hits on falling
  pieces" commit (an A/B that was stopped for low memory). Before any run in the worktree:
  `cd gdextension/brick && python -m SCons`, then `--headless --path . --import`.
- `override.cfg` is in the worktree (test windows hands-off). Never in main.
- Main has other areas' uncommitted files (`Docs/Status.md`, `project.godot`, the brickify pyc,
  `Docs/please rename/`, some `.uid`s): leave them.

## The merged plan (2026-10-20) -- start here

Two chats worked on destruction: this branch (`struct-bugs`, DestructionLod.md) and `lod-collapse`
(worktree `C:\Users\lbaun\Documents\brickcity\.claude\worktrees\lod-collapse`; CollapseNext.md items
19-30, Structures.md). Both are merged into `main`. From here **one chat and one worktree** carries
both lists, in this order; the detail of each item is where it points.

**0. Baseline, first**
- Pick one worktree (bc-struct or lod-collapse), `git merge main`, rebuild its DLL (both are stale
  against main's C++), `--import`.
- Run every probe and gate in "How to check" below with its pass count; then one `--big --shot`
  timing pass with the editor closed, no other Godot running and the display awake (time a
  `-- --ring` first: ~14 s awake, 50+ s asleep). On 2026-10-20 the gates were cut short at 99-100 C
  with two other chats' probes running: heat first (`python tools/heat_sum.py --last 3`), one
  windowed sequence per command, never two at once.

**1. Test health**
1. ~~`collapse_probe` flickers about 3 runs in 4~~ -- fixed 2026-10-20: "inside"'s toppling tower
   hits the one beside it, the first-fit picker shifts, the last six-storey tower goes to a
   four-storey ask. "shellhit" has a city of its own (`shellhit_probe`); DestructionLod 5.7.
2. ~~`--lodbreak`: the odd heap brick in mid-air~~ (CollapseNext 28; "Open" 3 below). **The
   check (2026-10-20):** `--floating` failed the baseline the same way -- three heap bricks "with
   nothing under them" at 135 m, lying on the first floor of a building given back to its shell.
   `_floating_furniture` (both gates' test) knew only the ground and grids: blind to buildings in
   bricks 120-140 m off (its radius shrank with 5.2's `INTERIOR_RANGE`; heap bricks are asked to
   `BrickHeap.DRAW_RANGE`, 140), to a shell's floors (drawn, not in the grid, no collision) and
   to asleep pieces (stand-ins). Fixed (`_float_supports`, `_float_held`); 2026-10-21 `--floating`
   6 of 6, `--lodbreak` no brick in mid-air 4 of 4.

**2. What the user sees in play**
3. CollapseNext 29(b): from far (LOD 3) a building sometimes vanishes, then close up its interior
   is drawn whole and its walls invisible, until it is shot again. Look first at the two things
   that change what draws a building at range: the far view from its own bricks
   (`CityScene._far_real`, Structures 2.1) and the painted panes on brick buildings
   (`_tend_brick_panes`, DestructionLod 5.2).
4. CollapseNext 29(a): from mid range (LOD 2) parts of a wall that should be gone stay drawn until
   the player comes close.
5. CollapseNext 29: from 320 m an 829-brick piece stays frozen 22 m over what is under its middle
   -- the perched-piece rule (`IslandManager._tip_if_perched`) on that case.
6. CollapseNext 26: furniture floating where a collapsing building was (small city). Not
   reproduced by `--floating`; DestructionLod 5.2 (no groups until a hit building is known
   standing) and wreckage furniture as bricks may have fixed it -- ask the user to look again
   before working on it.

**3. Performance**
7. `--big --shot` frames ~20 ms against ~17.7 since 5.5: every blast lands, ~40% more pieces moving
   ("Open" 2 below). Cut moving pieces or contacts -- settle sooner, fewer small bodies, a cheaper
   shape in the air -- not boxes (5.6).
8. CollapseNext 24: with the display awake, a single 50-66 ms `islands` tick now and then. The
   `[prof] worst islands.tick` line and its "of which" lines name the part. (The RUNS of 150-480
   ms ticks are the display asleep -- not this.) May be the same as 7.

**4. How buildings break**
9. CollapseNext 30: buildings still come apart in vertical slices along the floor-panel seams
   (13 pieces against 21 since two-layer floors). Decide with the user: accepted as what a shot
   face does physically, or the generator staggers the panel seams storey to storey so vertical
   cuts stop lining up.
10. Wide buildings (CollapseNext 25): checks of their own -- `--breaklag --big` and `--far` keep
    to towers (`CityScene._wide_ids`); what the wide ones failed there, and the span rule
    (Structures 2.3) in play on them.
11. ~~A floor finder for player builds~~ -- built 2026-10-20 (Structures 2.4: `find_floors`, `floors_of_build`; `floor_lines` uses it). Was: so builds have `floors`
    for landing snaps and mega-collapse chunks as generated buildings do.

**5. Tools and content**
12. The spaces tool's limits (Structures 3.2): a beam under the ceiling splits a room, a room
    needs a ceiling, a wall built sideways is not seen.
13. Stair kinds (Structures 3.4).
14. "Generate office": a room's furniture from its kind (Structures 4.3).

**6. Cleanup, last**
15. Retire the nudge / perch / watchdog patches once their counters stay at 0 ("Open" 4 below).
16. Rubble at rest merged into one static body per tile (DestructionLod §3.5) -- only if 7 still
    needs it (24 settled pieces at the end of a `--big --shot`).

**Off the list:** rooms as the unit of interiors (DestructionLod 5.4: measured, every generated
room faces out, no gain; Structures 2.6 and 4.2's "drawn/live" states with it -- the painted
panes are the faked state, built); CollapseNext 11 (needs a live co-op client); 13 and 16 (other
areas' tests).

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

## Open on this branch (the detail; the order is the merged plan's)

1. ~~**`collapse_probe` flickers**~~ -- fixed 2026-10-20 ("shellhit" in a city of its own). Not
   5.5: the A/B with it reverted hit the same neighbour as often (DestructionLod 5.7).
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

- Probes (headless): `float` 50, `debris` 29, `hang` 10, `collapse` 61, `shellhit` 2, `heap` 11, `crack` 9,
  `seam` 23, `spaces` 14, `interior_group` 33, `interior` 87, `fixture` 47, `shell` 38,
  `section` 32, `barrage` 8 (keeps the index and components checks on).
- Also (lod-collapse's, headless): `barrage` 7-8, `push` 16, `blast_ring` 19, `storey` 4,
  `far_rules` 9, `replay` 13, `loopback` 32, `snapshot` 48, `dormant` 33, `span` 6,
  `workshop_spaces` 8 (all passed 2026-10-20, `far_rules` after `ad080d8`).
- Windowed (Bash, `override.cfg`): `city.tscn -- --groups --big` 25, `--jam --big` 4,
  `--breaklag --big` 7, `--wreck` 2, `big_city.tscn -- --lodbreak` 8,
  `big_city.tscn -- --far --buildings=150` 19, `city.tscn -- --floating` 6.
- Profile: `city.tscn -- --big --shot`; the `[prof]` lines now break damage down
  (`of which damage, mean per tick`, `loose pieces (damage_near)`, `a hit on a piece`).
- Timing only with the editor closed and no other Godot running; alternate A/B pairs; report
  heat (`python tools/heat_sum.py --last N`) after windowed runs.
