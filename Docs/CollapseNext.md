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
`float_probe.gd`, `cap_probe.gd`, `shell_probe.gd`, `fakehide_probe.gd`. Timing passes (`--shot`,
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

### 1.6 A building is solved several times in one tick
A building re-marked dirty while the solve loop runs is solved again in the same tick, up to
`SOLVES_PER_TICK` times; with cascade rounds (`CASCADE_ROUNDS`, 3 ms each) that is up to 12 ms on
one building. It also fooled the director's stall count (fixed: once a tick). **Do:** solve a
building at most once a tick unless its first solve was cut short by the budget. **Check:**
`--breaklag --big` timeline and `[prof] solves`.

### 1.7 Clients see nothing where the host sees crumbs
A group of 9–48 bricks off a piece is cut out on every machine (`FLAG_GONE` in its DETACH) and
drawn as crumbs only on the host (`IslandManager._crumbles_off_a_piece`); a client's replay just
releases it. **Do:** when a client replays a gone DETACH from a piece, draw it as crumbs too.
**Check:** `loopback_probe` with a count of crumbs drawn on each side.

### Done since, not from this list
* **Storey by storey** (d560a66, 2026-10-05): `BrickWorld.gravity_check` — a storey that cannot
  carry what is above it tips or crushes (`_gravity_fail`, `CRUSH_PER_STUD`). A building left
  standing on one corner comes down. `collapse_probe` "storeys".
* **Far collapses** (ea53a7d, c9995a8): no second standing copy of a falling section, dust drawn
  as dust, no white box for a demeshed tower, and a building given back mid-bands is drawn as it
  is. `collapse_probe` "farcut".

---

## 2. Waiting on a decision

* **One drawing per building for interiors** — [Interiors.md](Interiors.md) §8, a proposal, not
  built: replace the real / drawn / fake / chunk-furniture ladder with one drawing by distance and
  pieces held by their floor bricks. It would remove the cause behind most "furniture drawn where
  nothing holds it" reports, and several fixes above with it. The biggest open piece of work here.
* **The unit solve** (storeys as single nodes in the stress solve). Not built, and less needed
  than it was: cascades finish in the tick (`BrickWorld.solve_structure` rounds), mega solving
  halved (1,368 → 690 ms over a `--big --shot`), and the storey check above now decides the case it
  was first wanted for. Build it only if solve time shows up again.
* **Collapses far off without the physics engine** (beyond ~150 m a collapse falls on a simple
  path and settles as stand-ins). Far collapses are already coarse — a few big chunks,
  `CollapseDirector` — and this would remove even those bodies.
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
