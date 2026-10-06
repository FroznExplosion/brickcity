# Collapse next — what is not done

The task list for destruction, collapse, pieces and their LOD: **what is not done, in the order
to do it**, with the evidence for each and how to tell it is fixed. What was built and why is in
[Collapse.md](Collapse.md) and [Status.md](Status.md) (the sections from "A break, then nothing for
a second" on); the user's priorities are the ones reported in play — lag on the first hit, a pause
before anything falls, things hanging in mid-air, things drawn that are not there.

Last updated **2026-10-06**. First written 2026-10-03; items keep their numbers, because commits
cite them ("CollapseNext.md 1.1"), and a finished one is struck, not removed.

Gates and probes this area keeps green: `--breaklag`, `--jam`, `--drawn` (each also with `--big`),
`--wreck`, `--fixture`, `--walk`, `--dormant`, `--rooms`, `--far`; `tools/collapse_probe.gd`,
`hang_probe.gd`, `solve_probe.gd`, `debris_probe.gd`, `snapshot_probe.gd`, `loopback_probe.gd`,
`float_probe.gd`, `cap_probe.gd`, `shell_probe.gd`, `fakehide_probe.gd`, `storey_probe.gd`,
`far_rules_probe.gd` (the last two are sections of collapse_probe run in a city of their own). Timing passes (`--shot`,
`--stress`, `--big --shot`) only with the editor closed and no other chat running Godot.

---

## 1. Next, in order

### ~~1.1 A damaged shell's collision does not follow its damage~~ — done 2026-10-04 (985f695)
The boxes are built from the same per-band masks as the shell's mesh, with a roof on the highest
floor still standing; a clean cut now counts as damage. `collapse_probe` "shellhit".

### ~~1.2 Wreckage in a room leaves the furniture standing in it~~ — done 2026-10-03 (f6f3d16)
A drawn item a piece lands on is crushed and the room redrawn; faked and drawn furniture in a
section's box is hidden the tick the section leaves. `collapse_probe` "crushdrawn",
`fakehide_probe`.

### 1.3 Single bricks still spray off PIECES
Held bricks (`Block::held`, `BrickWorld.reattach_held_groups`, groups of 8 or fewer) are on for
buildings only. On pieces (`PIECE_SOLVE`) it made `collapse_probe`'s soldier stop riding a toppling
building over in 2 of 3 full runs (0.4 m and 1.0 m against 13 m), so it was taken out. **Do:** find
why holding bricks on a toppling piece changes how it goes over (likely the piece no longer sheds
what let it tip), then put it back for pieces behind that fix. **Check:** `hang_probe` with a piece
case; collapse_probe "rode it" over several full runs.

### 1.4 Hits on pieces still make many medium bodies
`--big --shot`'s body census: ~150 bodies of 49–499 bricks off pieces that were **hit**, 100–150 ms
to make over the run, ~13 % of moving boxes. Groups of 48 or fewer off a piece crumble already.
**Do:** measure what a hit on a falling piece actually cuts (solve groups by size) and decide: a
larger crumble limit for pieces far from the player, or a hit on a falling piece breaks it along
storey lines only. **Check:** the census line in `--big --shot`.

### 1.5 The first stand-in for a big far piece is built on the main thread
A 5,000–7,000-brick chunk falling far off gets its first coarse stand-in in one call: 17–22 ms,
the worst tick of most `--big --shot` runs (`IslandManager._build_coarse`, via the mesh queue).
Rebuilds wait in proportion to cost (`COARSE_TICKS_PER_MS`); the first build does not. **Do:** build
stand-ins on a worker, like bakes (the chunk must not change under it: cancel on edit, as
`settle_bake_job` does). **Check:** `--big --shot` "the slowest mesh the queue made".

### ~~1.6 A building is solved several times in one tick~~ — done 2026-10-06
Once a tick each (`solved_now` in the solve loop; a second solve waits for the next tick). The
`--breaklag --big` tower is still down by tick 15, so the repeats bought nothing. One thing moved:
with two thin corners left under a tower, the stress solve's own cascade now takes the top off
before the storey check gets to it (`storey_probe` asks for the outcome there, not the route).

### 1.7 Clients see nothing where the host sees crumbs — waits for a live client
A group of 9–48 bricks off a piece is cut out on every machine (`FLAG_GONE` in its DETACH) and
drawn as crumbs only on the host (`IslandManager._crumbles_off_a_piece`); a replay just releases
it. There is no live co-op client yet -- `StructureReplayer` is used by saves and the log check
only -- so there is nothing to draw on. **Do, with the client (Multiplayer.md):** when it replays a
gone DETACH from a piece, hand the cut chunk to its IslandManager to crumble before releasing it.

### ~~1.8 Far collapses: cheap by rule, still physics~~ — done 2026-10-06
`IslandManager._far_and_small` (`FAR_DELETE_BLOCKS` 10, past `FRACTURE_RANGE`, `FLAG_GONE`);
`CityScene._mid_collapse` (`COLLAPSE_QUIET_MS`) holds the drawn, fake and real rungs and the wreck
spill. `tools/far_rules_probe.gd`, 9 checks, two of them the same case with the rule off. A blast
already lays a room only when the camera is within 60 m of it, so nothing is made far off. The rule
as the user set it: a collapse far from every player is still simulated -- it has to land where it
would -- but:
* **a piece of fewer than ten bricks is deleted when it breaks off**, on every machine (the host
  says so in the DETACH, as it does for the moving cap);
* **no interior and no items are made for wreckage until somebody is close to it** (rooms spilled
  into a wreck within `SPILL_RANGE`, as now -- and not into a wreck still moving);
* **a building that is mid-collapse when it is upgraded** (made bricks, or come into room range)
  **gets no interior and no items until it has finished**: no rooms drawn, faked or opened in a
  building that is still coming apart.

### 1.9 Interiors by storey group (Interiors.md §8, as amended)
The simplification, with the unit the user set: a group of storeys, each with one interior drawing
and one item drawing, faded by its own distance, rebuilt alone. Stages as Interiors.md §8.7. The
biggest piece of work here; after §1.8 and the small ones below.

### Done since, not from this list
* **Storey by storey** (d560a66, 2026-10-05): `BrickWorld.gravity_check` — a storey that cannot
  carry what is above it tips or crushes (`_gravity_fail`, `CRUSH_PER_STUD`). A building left
  standing on one corner comes down. `collapse_probe` "storeys".
* **Far collapses** (ea53a7d, c9995a8): no second standing copy of a falling section, dust drawn
  as dust, no white box for a demeshed tower, and a building given back mid-bands is drawn as it
  is. `collapse_probe` "farcut".

---

## 2. Waiting on a decision

* ~~One drawing per building for interiors~~ — **decided 2026-10-06:** per **storey group**, not
  per building (the towers are too big for one drawing); see §1.9 and
  [Interiors.md](Interiors.md) §8.2.
* **The unit solve** (storeys as single nodes in the stress solve). Not built, and less needed
  than it was: cascades finish in the tick (`BrickWorld.solve_structure` rounds), mega solving
  halved (1,368 → 690 ms over a `--big --shot`), and the storey check above now decides the case it
  was first wanted for. Build it only if solve time shows up again.
* ~~Collapses far off without the physics engine~~ — **decided 2026-10-06:** no. A far collapse
  stays physics, accurate, and is made cheap by rule instead; see §1.8.
* **Aim-ahead promotion** (`_aim_promote`, 100 m, kept 8 s) makes more buildings bricks while the
  player looks round. No spikes measured; if memory or frame time climbs, lengthen the dwell
  (`AIM_PROMOTE_TICKS`) or cap how many it keeps.

---

## 3. Measurements still owed

* `--big --shot` and `--stress` with the editor closed and nothing else running, after everything
  from 2026-09-30 on (crumbs, airborne pieces, cascade rounds, held bricks, the patch baseline,
  the storey check). The numbers taken so far were under load from other chats' Godot and Blender
  and are rough.
* `--shot` queues ~1,000 blasts that land at eight a tick; with cascades finishing in the tick,
  towers come down while blasts are still landing, and those blasts shatter the falling chunks
  (one run made 136 bodies of 500+ bricks off hit pieces, another 4). Decide whether a queued blast
  should hit pieces that came loose after it was fired, or make the pass fire its blasts at once.

---

## 4. Housekeeping

* **Status notes not on main.** The Status.md sections for 2026-09-30 → 10-02 are on branch
  `far-coarse-status` (8 commits); it cannot merge while the main folder has uncommitted
  `Docs/Status.md` edits (another area's). Merge it once those are committed. The leftover-drawing
  fix (`--drawn`, 4931ed0) has no Status section yet: write it there too.
* **Tests failing on main that are not this area's:** `squad_advance_probe` (flaky),
  `threat_style_probe` (crashes on exit after passing), `impostor_probe` "no holes" (render, on and
  off), and since the several-disasters merge collapse_probe "a lightning storm" and disaster_probe
  "a soldier in a meteor's ring runs out of it". `disaster_probe` "go over" and collapse_probe
  "rode it" vary with physics run to run.
