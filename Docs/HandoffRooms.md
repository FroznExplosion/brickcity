# Handoff: room interiors -- spawn fewer, by room, by where the player looks

Written 2026-11-14 at the end of the brick-system audit chat (worktree
`.claude/worktrees/sleepy-satoshi-5cd1f2`, branch `claude/sleepy-satoshi-5cd1f2`, main at
`f9244bfc`). That chat's own record is [HandoffPerf.md](HandoffPerf.md) section 8; the design
of interiors is [Interiors.md](Interiors.md) section 8 (8.2: one drawing per storey group, by
distance only -- the rule this work replaces).

**State (2026-11-14, branch `room-streaming`):** sections 4.1-4.5 built --
[Interiors.md](Interiors.md) 8.15 says how. The user's numbers: 8 rooms at once, 2 of them by
view, a room kept 3 s after it leaves view. 4.6 (a cap inside huge rooms) not built: no room
needs it.

## 1. What the user asked for

After bands became a box a brick (HandoffPerf 8.5) the user played and said (2026-11-13):

> "i think a lot of the lag we get are from building updates and spawning room interiors also
> the windows look like they are flashing as i move the camera around and entire floors start to
> spawn. i think we should limit the amount of rooms that can be spawned in at once to just a
> few near the player and like one or two that are in the players view and when in players view
> prioritize the room near the center of the screen. ideally spawn room objects then fade away
> the window screen. ... if a player is in a room the entire room contents should be spawned
> but maybe for huge rooms that might be too much so should we have a distance spawning or lod
> system inside rooms?"

They also pasted an article on streaming small objects (instancing, async loading, a spawn
budget, prefetch by velocity, rooms as cells) and asked whether the game already does it. The
answer given is section 3.

**Not decided by the user yet** -- ask before building, or start from the proposal's numbers
and say so:

* how many rooms at once (proposed: 6-8 in all, 2 of them picked by view);
* whether a room stays up a while after it leaves view (proposed: about 3 s, to stop churn).

## 2. How rooms are spawned today (read from the code 2026-11-14)

* **No node a piece of furniture.** `InteriorGroups` (`scripts/rooms/interior_groups.gd`) draws
  a GROUP -- up to `GROUP_STOREYS` (4) storeys of one building, every room on them -- as two
  MultiMeshes hung on the building's brick node: its interior pieces (desks, beds, shelves) and
  its items (the small things). `FurnitureMesh.attach_group` joins the group's per-room row
  buffers into one buffer and hands it over whole; any room changing rewrites the group's.
* **What is in a room comes from its seed**, not from disk: `RoomManifest.items_for(room)` and
  `RoomManifest.draw_items(world, chunk, palette, room, offset)` -- which reads the world (is
  the floor under each piece still there), so it is main-thread work as it stands.
  `InteriorGroups.work` does it a room at a time inside `BUDGET_MS` (2 ms a pass), 0.05-0.15 ms
  a room, and keeps each room's rows apart: `Group.pieces[k]`, `items[k]`, `boxes[k]`,
  `piece_rows[k]`, `room_row0`, `room_item0`.
* **Who is near what** is `CityScene._stream_groups(here)` (`scripts/city_scene.gd`), every
  fourth physics tick (`st_rooms` in the profile). For each building in bricks within
  `INTERIOR_RANGE + RELEASE` (60 + 12 m): each group by its box's distance; a group not shown
  and inside 60 m is queued, nearest first; `work` then `_group_show` (`attach`). Nothing asks
  where the camera looks, and nothing caps how many groups are up.
* **Fading is by distance, in the shaders.** `shaders/interior_group.gdshader`: each piece
  fades over `fade_band` (15 m) at the end of `fade_range` by its own distance (pieces 60 m,
  items `ITEM_RANGE` 20 m). The painted windows of a building in bricks
  (`CityDrawing.tend_brick_panes`, one mesh a building from `BuildingShell.window_arrays`, made
  on a worker) carry the instance uniform `near_hide` = `INTERIOR_RANGE`:
  `shaders/window_interior.gdshader` dithers them out between 45 and 60 m as the pieces dither
  in. **Both dithers move with the camera** -- this is the "windows flashing as I move the
  camera around".
* **Collision** for furniture is `CityScene._group_cover`: within `ROOM_RANGE` (40 m, kept to
  `ROOM_SLEEP_RANGE` 58) and `ROOM_STOREY_SPAN` (1) storey of the camera, one box shape a piece
  on the building's furniture body (`_room_body`), the body lifted out of the physics space and
  put back for every change.
* **A piece that is hit becomes bricks, alone** (`BuildingRegistry.compromise_items`, called
  from `CityScene._apply_blast`; Interiors 8.11). Pieces of wreckage carry their floor's
  furniture (`_stream_pieces`, `InteriorGroups.piece_work`).
* **A building not known to be standing draws no rooms** (`CityScene._interior_unsure`: bands
  building, floors' reach not asked, hit within `COLLAPSE_QUIET_MS`).
* Only a building in bricks has groups. A shell has painted windows only.

What is NOT under any budget: `_group_show` / `attach` (the MultiMesh buffers: a renderer
call, which waits behind any upload in flight -- PerfCaps.md 3), `_group_cover` (physics
shapes), the panes' hang, `_stream_pieces`. One `--big --shot` tick on 2026-11-11 was 26 ms
with `st_rooms` 10.9 of it.

## 3. The article against what the game does

| The article | Here |
|---|---|
| GPU instancing, not a node an object | yes |
| an instance woken into a real object when it is touched | yes: a hit piece is laid as bricks |
| grouped by cell, not a distance an object | yes, by storey group; the fade a piece is the GPU's |
| hysteresis between loading and unloading | yes (`RELEASE`, 12 m) |
| a spawn budget spread over frames | partly: working rooms out is budgeted, putting them on screen, their collision and the panes are not |
| prefetch along the player's velocity | for buildings (`CityScene._path_promote`, `_aim_promote`), not for rooms |
| disk reads on a worker | does not apply: nothing is read from disk |
| rooms as the cell, with a visibility test | no: the cell is a whole floor plate times four storeys, nothing looks at the view, nothing caps the count |

Two things in it do not fit this game: a room's shell cannot be baked into one mesh (it is
destructible bricks), and the stutter here is not disk I/O -- it is the unit's size and the
steps outside the budget.

## 4. The proposal (agreed in outline, not in numbers)

1. **The unit is a room.** The rows are already kept a room (section 2), so a group's
   MultiMesh can hold only the rooms chosen: rows of the others left out (or the buffer ordered
   chosen-first and `visible_instance_count` set). Keep two MultiMeshes a group -- a MultiMesh a
   room would be hundreds of draws.
2. **Which rooms.** Each pass, score the rooms of the buildings in range:
   * the room the camera is in, and the ones next to it on its storey: always, whole;
   * then the best few by view -- the angle between the camera's forward and the room's
     window, then distance; only a room with an opening facing the camera
     (`Room.openings`, `Room.has_opening`);
   * a cap on rooms up at once, the worst-scored given back first, a room kept a few seconds
     after it leaves view.
3. **Spawn, then fade the window -- by time.** When a room's rows are on screen, fade ITS
   painted window out over about 0.3 s; when the room is given back, fade the window in first
   and then drop the rows. This needs the fade a room, where today it is one `near_hide` a
   building: the panes' mesh would carry which room each pane is (a vertex attribute written by
   `BuildingShell.window_arrays`) and the shader read a fade for it (a small texture a
   building, a row a room, written when a room's state changes -- from the main thread:
   CLAUDE.md "Where new code runs"). The pieces' own distance dither can then go, or be kept
   only as the far limit.
4. **Everything under the tick's clock.** `attach`, `_group_cover` and the panes' hang take
   their turn from `TickClock.until(...)` (`scripts/core/tick_clock.gd`, HandoffPerf 7), a room
   or a group a tick, not all that is due.
5. **Collision only where a pawn can be**: the camera's room and its neighbours (and wherever
   the AI's pawns are, if they need it -- ask `_all_pawns`).
6. **Huge rooms.** The distance fade a piece is already an LOD inside a room (items 20 m,
   pieces 60 m). Add a cap on a room's rows, nearest first, only if a room passes a few hundred
   pieces; none does today (4-6 rooms a storey, 2-5 pieces a room).

Order to build in: 4 first (small, and it shows in the profile at once), then 1 + 2 (the cap
and the choosing), then 3 (the fade), then 5.

## 5. What to measure and what guards it

* `city.tscn -- --big --shot` and `big_city.tscn -- --shot`: `st_rooms` in the tick's profile
  (`[prof] mean per tick`, and the ticks over 25 ms), frames over 33 ms.
* `city.tscn -- --groups --big` (25 checks: groups shown by range, panes on bricks past the
  range, the crossover at 55 m). Several of its checks ARE the distance rule this replaces:
  rewrite those for the new rule in the same change and say why in the commit (CLAUDE.md "Know
  what a test measures").
* Headless: `interior_group_probe`, `interior_probe`, `fixture_probe`, `shell_probe`,
  `room_clear_probe`; `collapse_probe` (two checks in it are flaky on unchanged code: the
  trapped soldier, and "pushed over, it turns").
* A timing run is only fair started cool and quiet: one windowed run a command, launched when
  no Godot is running and the last minute's peak is under about 78 C, the order alternated, and
  `python tools/heat_sum.py --last 2` after each. Compare the tick and slow-frame counts, not
  the renderer's GPU ms (HandoffPerf 8.1).

## 6. Things to know from the audit chat

* **Bands are a box a brick now** (`BrickBoxes`, `scripts/render/brick_boxes.gd`): a band's
  node has no mesh of its own (or only its slopes' and stairs'), and its bricks are a child
  MultiMesh `Boxes`. A helper that looks for `mesh != null` misses it. The groups hang on the
  building's brick node (`CityScene._brick_nodes[id]`), which is unchanged.
* **A building in bricks far off is drawn by its coarse mesh alone** and has no bands
  (`CityDrawing.coarse_only`); it still has its brick node.
* **`--breaklag` has four failing checks that are not yours**: its far-shell checks wait for a
  far building to go back to a shell, which the one coarse path no longer does (HandoffPerf
  8.5).
* A piece broken off a building has no power: lamp bricks are dark on it
  (`IslandManager.unpower`, the brick shader's `powered`).
* The city tick shares one clock (`TickClock`, 8 ms): a queue gets only its first unit once it
  is spent, so choose the unit with that in mind (a boxed building's bands are one unit for
  that reason).
