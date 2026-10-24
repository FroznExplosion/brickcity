# Handoff: destruction work (branch `struct-bugs`), 2026-10-20

For the next chat picking this up. The plan and everything measured is in
[DestructionLod.md](DestructionLod.md) (§5 is what was built, in order); open collapse items in
[CollapseNext.md](CollapseNext.md).

## Where things are (struct-bugs)

- Worktree `C:\Users\lbaun\bc-struct`, branch `struct-bugs`, everything committed and merged into
  `main` (last merge `d3d78df`, 2026-10-23, pushed). No C++ changed since the worktree's DLL was
  built; after `git merge main`, rebuild only if main brought C++ (`python -m SCons` in
  `gdextension/brick`), then `--headless --path . --import`.
- A merge of main can stop on untracked `.uid` files that `--import` made in the worktree and
  main now tracks: delete those (only the ones git names) and merge again.
- `override.cfg` is in the worktree (test windows hands-off). Never in main.
- Main has other areas' uncommitted files (`Docs/Status.md`, `project.godot`, the brickify pyc,
  `Docs/please rename/`, some `.uid`s): leave them.
- The heat-aware runner for windowed passes: `gates_seq.sh` and `gate1.sh` in
  `C:\Users\lbaun\AppData\Local\Temp\claude\C--Users-lbaun-Documents-brickcity\892fd689-e560-4645-be18-932f9272afb1\scratchpad\`
  -- copy both to your own scratchpad and set `SP=` in both to it (`ROOT` is bc-struct).
  `bash gates_seq.sh <name> <args joined by +>`, `big:` before the args for `big_city.tscn`
  (e.g. `big:--lodbreak`, `--big+--shot`). It waits for heat under 80 C and for no other
  windowed Godot, runs ONE pass under a 900 s timeout, prints its ok/FAIL and the heat of that
  run. One call per command -- never chain two.

## The merged plan (2026-10-20) -- start here

**Storey units (2026-10-21, a third chat):** a hit makes bricks of the storeys it reaches, not the
building; the rest is the building's rest shell, and a storey that gives way sends what is above
it off as one shell piece. Plan and numbers: [Space.md](Space.md) §5.3a-b. Every probe and gate
below was run with it on (2026-10-21); `collapse_probe`'s "farcut" moved to `farcut_probe`.

**State 2026-10-21 (the second chat):** worktree `C:\Users\lbaun\bc-struct`, everything merged into
`main` and pushed, the worktree's DLL built from main's C++. Done: 0 (baseline), 1, 11, 12, and the
floating check's blind spots (2's first half). Open, in order: 2 (one real heap brick in mid-air,
flaky -- the next `--lodbreak` failure says what it lay on), 3-5, 7-8, 9 (user: stagger the seams;
see 9 below), 10, 13-16. 6 waits for the user to look in play.

**State 2026-10-22 (the third chat):** main merged in (storey units), DLL rebuilt. 2: not seen in
6 `--lodbreak` runs since storey units (the tracker stays on). 3: walls drawn at every stop in all
6. 5: what is left of it is physical -- see 5 below; `--lodbreak` gates it now (16 checks). Open,
in order: 4, 7-8, 9, 10, 13-16; 6 waits for the user. Aside, for the storey-units chat: the
`--ring` pass prints `[city] FAIL the log does not replay into the same structure` (host 862
bricks, replay 1506: the replay lays the whole building, the host only the storeys it reached).
**2026-10-23:** 4 found and fixed -- see 4 below; `--lodbreak` 21. The replay FAIL above is gone
since storey units' log commands (`--ring` 4 of 4, no FAIL line). Open, in order: 7-8, 9, 10,
13-16; 6 waits for the user.

**State 2026-10-23, end of the third chat -- the next chat starts here.** Merged and pushed
(`d3d78df`). Done since the 10-22 state:
- 4 (ghost walls from 110 m): partial towers drawn from their bricks past `DEMESH_RANGE`;
  `--lodbreak` counts walls drawn where no brick is, with its own control (item 4 below).
- 7-8 (performance), measured and two spikes cut (item 8 below): every tick over 25 ms now
  prints what inside its biggest phase it was (`CityScene._spike_parts`); storeys laid a run a
  `lay_band` (`BuildingRegistry._lay_runs` -- a shell piece made bricks was quadratic in
  storeys, 68.5 ms for 34); a shell drawn from its bricks refreshed in place after a hit
  (`_refresh_real_shell`, ~15 ms a time).

**Open, in order:**
1. ~~Re-time `--big --shot` on a quiet machine~~ -- done 2026-10-23 evening (code at `8c67313`,
   before perf caps `c35046e`; editor closed, `--ring` 14 s, peak 73-80 C, not held back): two
   clean runs 18.1 ms mean / 21 of 906 over 33.3 ms (worst 64.0) and 18.1 / 17 (worst 88.1); a
   third with another chat's headless probe up said 17.6 / 26 (unreliable). Inside the nine of
   item 8 (16.8-20.2, 8-74): the two fixes did not move the mean; the earlier 16.8 / 5 was noise.
2. **The rest of 8, from the spike lines** (`[prof] N tick(s) over 25 ms`; since `c35046e` also
   `big_city.tscn -- --chamfer --cost --street --long`, Docs/PerfCaps.md 4). **2026-10-23
   evening, done, not yet timed:** every stand-in now uploads on a worker
   (`IslandManager._finish_coarse`), and `build_damage_profile` walks only the outer-wall columns
   with alive read per block (`damage_profile_probe`: same answer as the full walk, 0.12 ms mean
   vs 0.40 on a 40x30x34 tower) -- the shadow proxy's profile stays on the main thread; time it
   with `--cost --street --long` before moving it. 2026-10-24: the panes' copy is only the window
   rows and outer-wall columns (`BuildingShell.standing_copy`, `get_solid_cells_at`;
   `pane_copy_probe`: same panes, 0.028 ms vs 0.147). **Watch:** `--lodbreak` failed "60 m: no
   wall drawn where its bricks are gone" in 2 of 7 runs with these changes (3-4 of 62 hits, on a
   band, both times the tower's corner at y ~49 -- the top laid storey under the cut, storeys
   16-24 laid, cut at 25 -- persisting two stops, gone by the third) and 0 of 3 on the scripts of
   `300e2f5`; one other run failed "no piece frozen over air drops" (item 5's kind). Nothing in
   the copy touches band meshes; a timing-exposed miss in a cut storey's band patch is the guess.
   Was: a stand-in's
   `add_surface_from_arrays` stalling 9-216 ms (the renderer; idea: every stand-in through the
   worker upload path, `IslandManager._submit_mesh_job`); a shell piece's split 5-17 ms
   (`spawn` -> `split_island`; `adopt` would skip it but `spawn` holds the move caps, crumbling,
   landmark rules and co-op piece ids -- ask the user first). Two more from the perf-caps chat
   (`c35046e`, which moved band uploads, brick panes and real-shell glass to workers):
   `_make_shadow_proxy` calls `registry.live_damage_profile` on the main thread, 2-7 ms for a
   big building, worst during collapses -- take a copy (like `get_solid_cells`, or a C++
   snapshot) and build the profile on the worker with the proxy mesh; and `_standing_copy`
   copies the whole chunk (~3 ms for a big tower, once as it turns to bricks) where the panes
   only read outer-wall cells within `WALL_THICK`+2 of each face on the sill, lintel and floor
   rows -- a wall-ring or rows-only copy.
3. **9: stagger the slab seams** (user's decision; design under item 9, columns and walls stay on
   the lattice). A/B with `big_city.tscn -- --breakshape` and the part count before merging.
4. 10, 13-16 as listed. 6 waits for the user to look in play.

Two one-offs to watch for (item 8 below): `--lodbreak` "160 m: no stud drawn on a brick that has
gone" on pieces still moving at the gate, and Godot crashing at exit after the results.

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
2. `--lodbreak`: the odd heap brick in mid-air (CollapseNext 28; "Open" 3 below). **The
   check (2026-10-20):** `--floating` failed the baseline the same way -- three heap bricks "with
   nothing under them" at 135 m, lying on the first floor of a building given back to its shell.
   `_floating_furniture` (both gates' test) knew only the ground and grids: blind to buildings in
   bricks 120-140 m off (its radius shrank with 5.2's `INTERIOR_RANGE`; heap bricks are asked to
   `BrickHeap.DRAW_RANGE`, 140), to a shell's floors (drawn, not in the grid, no collision) and
   to asleep pieces (stand-ins). Fixed (`_float_supports`, `_float_held`); 2026-10-21 `--floating`
   6 of 6, `--lodbreak` no brick in mid-air 4 of 4. But the next run had one real one (item 3).

**2. What the user sees in play**
3. CollapseNext 29(b): from far (LOD 3) a building sometimes vanishes, then close up its interior
   is drawn whole and its walls invisible, until it is shot again. Look first at the two things
   that change what draws a building at range: the far view from its own bricks
   (`CityScene._far_real`, Structures 2.1) and the painted panes on brick buildings
   (`_tend_brick_panes`, DestructionLod 5.2).
   **2026-10-21:** `--lodbreak` now asks at every stop inside SHELL_RANGE that something draws
   the tower's walls (shell, far box, instanced set, brick mesh or bands: `_walls_drawn_by`), and
   comes at each tower from a side with no other building in the way (`_clear_way`): at 160 m
   its shot had been landing on building 10, in front of the tower it asks about (11), so that
   tier never shot its tower. With both: 160 m shot lands, walls drawn at every stop (far box,
   bricks, shell from its bricks, bands). Not reproduced yet; the check is there for when it is.
   Same run, "no brick lying in mid-air" failed at all three tiers on ONE heap brick at 45 m
   on the 60 m tower, 1.96 m over the building's collision -- item 2 is real after all, and
   flaky (passed the run before, and the run after). Each heap brick now keeps what it came
   down on and when, while `--lodbreak` runs (`BrickHeap.track`): the next failure prints it.
4. ~~CollapseNext 29(a): from mid range (LOD 2) parts of a wall that should be gone stay drawn until
   the player comes close.~~ -- found and fixed 2026-10-23. **The check:** at every `--lodbreak`
   stop, 24 x 48 rays from the camera across the tower against the triangles of what draws it from
   its bricks (brick mesh, bands, shell, rest shell); half a cell into each face hit, no live brick
   within a cell is a ghost (`CityScene._ghost_walls`). Storeys not laid (storey units) are drawn
   whole by design and not asked. Gated from 8 s after the shot on: at most 2 hits or 3% a stop.
   Its own control, once a pass: the bricks its rays hit are killed with no redraw, and it must
   then see ghosts (`_ghost_control`). **What it found:** past `DEMESH_RANGE` (110 m) a damaged
   tower still in bricks is drawn from them (`_far_real`, Structures 2.1) -- but not one laid a
   storey at a time (`registry.is_partial`), and since storey units every tower hit is. That one
   got the recipe shell with the damage profile, a hole per band, its floors drawn across the
   crater: on the 320 m tower 14-31 ghost hits of 337-355 from 8 s to 110 m, 0 once its bricks
   were drawn at 60 m. **Fixed:** a partial tower is drawn from its bricks too, and its rest shell
   draws the storeys not laid beside them once that mesh is up (`_rest_drawn`,
   `_far_real_done`); 0 ghosts at every stop. `--lodbreak` 21, `--storeys --big` 13,
   `--far --buildings=150` 19.
5. ~~CollapseNext 29: from 320 m an 829-brick piece stays frozen 22 m over what is under its middle
   -- the perched-piece rule (`IslandManager._tip_if_perched`) on that case.~~ -- looked at
   2026-10-22, after storey units: now a 54-brick piece, 9 x 9 m on plan, frozen 21 m over what is
   under its middle (`--lodbreak --pick=3 --at=320` gets it every run). It is the broken bottom
   storey of the standing top, one corner on the building and its weight 1.5 m past that: the
   perch rule tipped it three times and it came back each time, and woken with the camera close
   (1.5 s to begin tipping) it moved 0.0 m -- levered under the standing top, held. The pass's
   piece lines now say the gap under each of the nine support rays and what they hit, and why the
   perch rule let it be frozen (`IslandManager.perch_say`); at each tower's end every piece frozen
   over more than 3 m of air is pictured, woken close up and gated: "no piece frozen over air
   drops when woken close up" (`CityScene._wake_hung_pieces`).
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
   **2026-10-23, measured (9 `--big --shot` runs, editor closed, no other Godot, display awake,
   storey units in):** frames mean **16.8-20.2 ms** (run to run, ~3 ms of noise), 8-74 of 906 over
   33.3 ms, worst 40-162. Every spike now says what inside its biggest phase it was (`[prof] N
   tick(s) over 25 ms`, `CityScene._spike_parts`: damage, stream, bands, promote parts, the
   islands tick's own split, a shell piece's). What comes back:
   - **A shell piece made bricks by a blast** (`_blast_shell_pieces` -> `_piece_to_bricks`,
     storey units): every run, the same three ticks (~90, ~258, ~339), **23-32 ms**; one run
     **99 ms** (23,801 bricks: laid 68.5 + spawn 19.6, its split 16.7). The whole piece is laid
     from the template (`lay_band`, ~1.3-2.9 us a brick) and cut into a new chunk (`spawn` ->
     `split_island`) in the blast's tick. **The laying, fixed 2026-10-23:** it was a storey a
     `lay_band`, from the bottom up, and every call that reached past the grid's window built
     the grid again for every brick laid so far -- quadratic in storeys. Now a run of storeys a
     call (`BuildingRegistry._lay_runs`, also for the storeys a hit reaches): same bricks, same
     absent ones, same grid (`storey_unit_probe`, 42), 12,484 bricks over 18 storeys 13.3 ->
     2.4 ms. Left: the split, 5-17 ms. Not built: lay the chunk a storey a tick while it falls
     (a barrage converts a piece within a tick or two of it forming, so likely no help); take
     the laid chunk whole (`IslandManager.adopt`) instead of splitting a copy -- but `spawn`
     also holds the move caps, crumbling, landmark rules and the co-op piece ids.
   - **A shell rebuilt for a building still in bricks** (`_stream_detail`, `st_reshell`): 15-19
     ms = `live_damage_profile` 7.2 + recipe shell mesh 7.3. When it is drawn from its bricks
     (`_far_real`), both are spent on a shell that draws for a tick or two. **Fixed 2026-10-23:**
     a shell drawn from its bricks and hit again is asked again in place -- its coarse mesh and
     its panes, each drawing what it has until the new one lands (`_refresh_real_shell`;
     `_hang_glass` replaces a shell's panes). `--lodbreak` 21 (display awake).
   - Once each: an islands tick of 226 ms that was ONE 76-brick stand-in rebuilt in the mesh
     queue (its build 1.1 ms at most); a landing of 36.8 ms; promote 71.8; render 33-38. Caught
     again smaller (`coarse_split`): a 77-brick stand-in 10.9 ms = build 0.7 + **`add_surface_
     from_arrays` 9.1** + hung 0.9 -- the renderer, not the build. Not built: send stand-ins
     through the worker upload path (`_submit_mesh_job`) whatever their size.
   - **After both fixes** (one run, two other Godot processes up at its start -- unreliable): frames
     mean 16.8 ms, worst 50.0, **5 of 906 over 33.3 ms** (8-74 before), 2 ticks over 25 ms, no shell
     piece or reshell among them. Time it again on a quiet machine.
   - Seen once each in `--lodbreak` (2026-10-23, after these): "160 m: no stud drawn on a brick
     that has gone" 172 of 119,555, on pieces still moving at the gate (the tower alone passed,
     and the next full run); and Godot crashing at exit (signal 11, after the results: an
     ArrayMesh freed after the RenderingServer -- likely a mesh or band job still in flight when
     the pass quits, just after `_ghost_control` kills bricks).

**4. How buildings break**
9. **User, 2026-10-21: stagger the seams.** Worked out, not built: two offset layers make a cut
   equally cheap on every 5-stud line, the same lines every storey, so swapping the layers (a
   5-stud shift) changes nothing. A real stagger shifts the pair by a non-multiple of 5 on
   alternate storeys (lower 2, upper 6: real LEGO plates 2x10, 4x10, 6x10, 2x8, 8x8, 6x6, 4x6, new
   palette parts), about 1-4 parts a cell instead of 1, and a recipe-version bump. A jog
   between storeys costs only a few wall studs, so the gain is uncertain: build it as an A/B and
   measure `big_city.tscn -- --breakshape` (pieces, slices, layers) and the part count before
   merging. **Only the slab plates shift; columns and interior walls do not** (user, 2026-10-21:
   "the support columns should line up with each floor"). They stay on the 10-stud lattice every
   storey -- `plan()` is per footprint, not per storey, and `columned` only adds lattice points
   lower down, so every column already stands on one below it. On a shifted storey a 2x2 column
   top lands inside one lower panel instead of on a four-panel corner (4 studs into one plate, not
   1 into each of four); that is fine, the two layers tie their own seams. Two traps: lay the
   shifted layer from its own cut list, not by changing `lattice()` (columns and walls read it);
   and keep `_build_plan`'s small-strip rule (a column at a strip plate's corner) off the shifted
   layout, or alternate storeys grow off-lattice columns.
   Was: CollapseNext 30: buildings still come apart in vertical slices along the floor-panel seams
   (13 pieces against 21 since two-layer floors). Decide with the user: accepted as what a shot
   face does physically, or the generator staggers the panel seams storey to storey so vertical
   cuts stop lining up.
10. Wide buildings (CollapseNext 25): checks of their own -- `--breaklag --big` and `--far` keep
    to towers (`CityScene._wide_ids`); what the wide ones failed there, and the span rule
    (Structures 2.3) in play on them.
11. ~~A floor finder for player builds~~ -- built 2026-10-20 (Structures 2.4: `find_floors`, `floors_of_build`; `floor_lines` uses it). Was: so builds have `floors`
    for landing snaps and mega-collapse chunks as generated buildings do.

**5. Tools and content**
12. ~~The spaces tool's limits (Structures 3.2)~~ -- all three lifted 2026-10-21 (user: "all three"): a beam under the ceiling splits a room, a room
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

- Probes (headless): `float` 50, `debris` 29, `hang` 10, `collapse` 56, `shellhit` 2, `farcut` 5, `storey_unit` 42, `heap` 11, `crack` 9,
  `seam` 23, `spaces` 20, `interior_group` 33, `interior` 87, `fixture` 47, `shell` 38,
  `section` 32, `barrage` 8 (keeps the index and components checks on).
- Also (lod-collapse's, headless): `barrage` 7-8, `push` 16, `blast_ring` 19, `storey` 4,
  `far_rules` 9, `replay` 13, `loopback` 32, `snapshot` 48, `dormant` 33, `span` 6,
  `workshop_spaces` 8 (all passed 2026-10-20, `far_rules` after `ad080d8`).
- Windowed (Bash, `override.cfg`): `city.tscn -- --storeys --big` 13 (and `--whole` for today's
  numbers), `city.tscn -- --groups --big` 25, `--jam --big` 4,
  `--breaklag --big` 7, `--wreck` 2, `big_city.tscn -- --lodbreak` 21,
  `big_city.tscn -- --far --buildings=150` 19, `city.tscn -- --floating` 6.
- Profile: `city.tscn -- --big --shot`; the `[prof]` lines now break damage down
  (`of which damage, mean per tick`, `loose pieces (damage_near)`, `a hit on a piece`).
- Timing only with the editor closed and no other Godot running; alternate A/B pairs; report
  heat (`python tools/heat_sum.py --last N`) after windowed runs.
