# Collapse next — what is not done

The task list for destruction, collapse, pieces and their LOD: **only what is not done, in the
order to do it**, with the evidence for each and how to tell it is fixed. What was built and why
is in [Collapse.md](Collapse.md) and [Status.md](Status.md) (the sections from "A break, then
nothing for a second" on); the user's priorities are the ones reported in play — lag on the first
hit, a pause before anything falls, things hanging in mid-air, things drawn that are not there.

Last updated **2026-10-03**, after the leftover-drawing fix (`--drawn`).

Gates and probes this area keeps green: `--breaklag` (and `--big`), `--jam` (and `--big`),
`--drawn` (and `--big`), `--wreck`, `--fixture`, `--walk`, `--dormant`, `--rooms`;
`tools/collapse_probe.gd`, `hang_probe.gd`, `solve_probe.gd`, `debris_probe.gd`,
`snapshot_probe.gd`, `loopback_probe.gd`, `float_probe.gd`, `cap_probe.gd`. Timing passes
(`--shot`, `--stress`, `--big --shot`) only with the editor closed and no other chat running Godot.

---

## 1. Next, in order

### 1.1 A damaged shell's collision does not follow its damage
A building handed back damaged is drawn by a banded shell that shows its holes, but its collision
is still the recipe's: four full-height walls and a ground plate (`BuildingShell.collision_boxes`,
`CityScene._make_shell_body`). Where storeys are gone there are invisible walls, and wreckage can
come to rest on them in mid-air — a floater that is real to the physics and not to the eye. The
roof added on 2026-10-02 is only on undamaged shells for the same reason.
**Do:** build the boxes from the damage profile, band by band, as the shell mesh is; a roof on the
highest band still standing. **Check:** a `--drawn`-style gate: a building damaged, handed back,
a slab dropped on it from above where its top is gone — it falls past, not onto, the missing
storeys.

### 1.2 Wreckage in a room leaves the furniture standing in it
Furniture no longer holds anything up (its body is `Layers.FIXTURE`), so a falling section goes
through a drawn room's table — and the table stays drawn inside the wreckage until the floor under
it goes (`_recheck_drawn`). **Do:** in `_on_island_impact`, undraw the drawn rooms the landing
point is in (`registry.undraw_room`, then `_sync_drawn`). **Check:** `--rooms`/collapse_probe —
a piece dropped into a drawn room, the room undrawn within a tick.

### 1.3 Single bricks still spray off PIECES
Held bricks (`Block::held`, `BrickWorld.reattach_held_groups`) are on for buildings only. On pieces
(`PIECE_SOLVE`) it made `collapse_probe`'s soldier stop riding a toppling building over in 2 of 3
full runs (0.4 m and 1.0 m against 13 m), so it was taken out. **Do:** find why holding bricks on a
toppling piece changes how it goes over (likely the piece no longer sheds what let it tip), then
put it back for pieces behind that fix. **Check:** `hang_probe` with a piece case; collapse_probe
"rode it" over several full runs.

### 1.4 Hits on pieces still make many medium bodies
`--big --shot`'s body census: ~150 bodies of 49–499 bricks off pieces that were **hit**, 100–150 ms
to make over the run, ~13 % of moving boxes. Groups of 48 or fewer off a piece crumble already.
**Do:** measure what a hit on a falling piece actually cuts (solve groups by size) and decide:
a larger crumble limit for pieces far from the player, or a hit on a falling piece breaks it along
storey lines only. **Check:** the census line in `--big --shot`.

### 1.5 The first stand-in for a big far piece is built on the main thread
A 5,000–7,000-brick chunk falling far off gets its first coarse stand-in in one call: 17–22 ms,
the worst tick of most `--big --shot` runs (`IslandManager._build_coarse`, via the mesh queue).
Rebuilds now wait in proportion to cost (`COARSE_TICKS_PER_MS`); the first build does not.
**Do:** build stand-ins on a worker, like bakes (the chunk must not change under it: cancel on
edit, as `settle_bake_job` does). **Check:** `--big --shot` "the slowest mesh the queue made".

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

---

## 2. Waiting on a decision

* **The unit solve** (storeys as single nodes in the stress solve). Not built. Its two goals are
  met another way: cascades finish in the tick (`BrickWorld.solve_structure` rounds) and mega
  solving halved (1,368 → 690 ms over a `--big --shot`). A solve on rigid storeys also decides
  differently what fails, so it is a change of the physics, not only of its speed. Build it only if
  solve time shows up again.
* **Collapses far off without the physics engine** (the original plan's last phase: beyond ~150 m
  a collapse falls on a simple path and settles as stand-ins). Far collapses are already coarse
  (a few big chunks, `CollapseDirector`); this would remove even those bodies.
* **Aim-ahead promotion** (`_aim_promote`, 100 m, kept 8 s) makes more buildings bricks while the
  player looks round. No spikes measured; if memory or frame time climbs, lengthen the dwell
  (`AIM_PROMOTE_TICKS`) or cap how many it keeps.

---

## 3. Measurements still owed

* `--big --shot` and `--stress` with the editor closed and nothing else running, after everything
  from 2026-09-30 on (crumbs, airborne pieces, cascade rounds, held bricks, the patch baseline).
  The numbers taken so far were under load from other chats' Godot and Blender and are rough.
* `--shot` queues ~1,000 blasts that land at eight a tick; with cascades finishing in the tick,
  towers come down while blasts are still landing, and those blasts shatter the falling chunks
  (one run made 136 bodies of 500+ bricks off hit pieces, another 4). Decide whether a queued blast
  should hit pieces that came loose after it was fired, or make the pass fire its blasts at once.

---

## 4. Housekeeping

* **Status notes not on main.** The Status.md sections for 2026-09-30 → 10-02 are on branch
  `far-coarse-status`; it cannot merge while the main folder has uncommitted `Docs/Status.md`
  edits (another area's). Merge it once those are committed.
* **Tests that fail and are not this area's:** `squad_advance_probe` (flaky), `threat_style_probe`
  (crashes on exit after passing), `impostor_probe` "no holes" (render, fails on and off).
  `disaster_probe` "go over" and collapse_probe "rode it" vary with physics run to run.
