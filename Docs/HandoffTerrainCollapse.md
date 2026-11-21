# Handoff: terrain collapse (mine world)

Written 2026-11-20 by the collapse chat (worktree `C:\Users\lbaun\bc-tcollapse`,
branch `terrain-collapse`, all merged into main). The design and what was
measured are in Docs/TerrainCollapse.md (sections 8, 8.1, 8.2). Read it first.

## State

Built and merged:

- The survey: virtual bricks plus the buildings' solve on a private BrickWorld,
  run on a worker. `TerrainCollapse.survey` is in
  `gdextension/brick/src/terrain_collapse.cpp`, and its caller is
  `scripts/terrain/ground_collapse.gd`.
- Sand and gravel fall like Minecraft and land on pieces.
- Pieces:
  - They stay connected while falling.
  - Up to 100 are kept near the player, nearest first.
  - Pieces of 4 or more bricks are unloaded past LOD 0 or over the cap. Smaller ones are deleted.
  - They are saved in `.pieces` (BCMP).
- Shots and pickaxes delete bricks, and only what is left falls.
- The Pickaxe and Mega Pickaxe take whole bricks.
- The top course is cached by `brick::tile_version`.
- The ground's strength is 4 times the buildings' stud strength (`TERRAIN_TIMES`).
- Only groups touching the edit fall.

Tests:

- `--headless --path . --script res://tools/probes/terrain_collapse_probe.gd`
- `res://scenes/terrain_test.tscn -- --gate=collapse` (windowed, 17 checks)
- `-- --gate=stop --walk` (the frame-cost instrumentation, moving phase)

Never run terrain_test.tscn without a `--gate` flag: it re-saves the player's world.

## Do these in this order

### 1. Read the ground's bricks from sections (do this first)

**Wait for the other chat's section work to merge into main first.** Check
`git log main` and Docs/ for its doc.

The problem today: the survey makes up virtual bricks.

- The bond comes from `brick::bond_rect` (terrain_bond.h, Docs/TerrainBond.md).
- The top course comes from `brick::top_columns`, which packs each tile it
  covers. Packing was 97% of a cold survey: 2.5 s seen in play, and still 185 ms
  at worst with the cache.
- The cache (`SharedTops` in terrain_collapse.cpp, keyed by `tile_version`)
  only helps a warm survey.

The change: with sections, ask each cell its real brick (an id plus its
rectangle) and lay those, instead of `bond_rect` and `top_columns`.

- The survey then packs nothing.
- It matches exactly what the player sees.
- `SharedTops`, `TOPS_MAX` and the `tops_ms` timing can probably go. If they do,
  remove the probe's `_check_cache` with them and say why in the commit
  (CLAUDE.md: prune obsolete tests).

Afterwards:

- The probe's 40 real cave ceilings must still drop under 100 cells at most.
- `--gate=collapse` must still pass.
- Re-time the survey with a cold cache and put the numbers in
  TerrainCollapse.md 8.

### 2. Measure frame cost walking in caves

So far only the surface walk was measured: the near tier's worst was 2.3 ms.
The 110-164 ms instance-phase numbers were the load-time fill, not play.

- Use `--gate=stop --walk` with the walk routed through a cave. It may need a
  cave start option.
- **The editor must be closed and no other chat's Godot may be running**
  (CLAUDE.md, "Performance measurements").
- Report the heat with `tools/heat_sum.py`.

### 3. The unexplained 69 ms frame

One frame on the surface walk took 69 ms, 62 of it process time outside the
streamer, during far and deep tier work. It was never traced.

- Catch it again with the walk's instrumentation (mine_world.gd, the moving
  phase).
- If it is the terrain tiers rather than the collapse, hand it to the terrain
  chat.

### 4. "Pieces stay forever" (the user's rule, to change later)

Today kept pieces never go away, only unload. Ask the user what the new rule
is before building: a lifetime, settling into terrain cells, a cap per area, or
something else.

The code involved:

- `_tend` and `_put_away` in ground_collapse.gd
- the `.pieces` save (`to_save` / `restore`)
- `MAX_LOADED`, `SMALL_MAX`

### 5. The rare `--gate=gen --with-collapse` crash

The water chat flagged it (Docs/MineWater.md, open items). The edit-box
splitting and the cell and brick limits (8.1, "Surveys per box") were made for
it, but the crash was never reproduced afterwards.

- Run it a few times, alone and cool. Once is not proof: it was rare.
- If it still crashes, read the crash log for the survey thread.

**Done 2026-11-21:** 5 runs in a row, all clean (exit 0, `[gen-gate] done`),
peak 90 C, never held back. It used to crash about 1 run in 2, so the fix holds.

**Items 2 and 3 done 2026-11-21:** the cave walk is TerrainCollapse.md 8.3.
The slow walking frame (69 ms then, 57-62 now) was the far rings'
re-anchor waiting on the workers, not the collapse: fixed, now 41 ms
(MineWorld.md 14). Its last 14 ms (`_rebuild_ring` in one frame) is the
terrain chat's.

Item 1 still waits for the sections chat. Item 4 stays as it is for now (the
user's answer, 2026-11-21).

## Rules that bit this chat

- After merging main: run `python -m SCons` in gdextension/brick, then
  `--import`. A stale DLL shows up as parse errors.
- Check that mine_world.gd parses before any windowed run. A parse error makes a
  windowed pass hang, and a chained command hid one once.
- Run windowed tests one at a time, launched from Bash, under 80 °C if the last
  run was held back. Kill Godot by PID only.
- GDScript: `-(1 << 30)`, not `-1 << 30`. Give preloaded classes explicit
  types. `maxi` takes two arguments.
