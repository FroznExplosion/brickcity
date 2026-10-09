# Collapse next — what is not done

The task list for destruction, collapse, pieces and their LOD: **what is not done, in the order
to do it**, with the evidence for each and how to tell it is fixed. What was built and why is in
[Collapse.md](Collapse.md) and [Status.md](Status.md) (the sections from "A break, then nothing for
a second" on); the user's priorities are the ones reported in play — lag on the first hit, a pause
before anything falls, things hanging in mid-air, things drawn that are not there.

Last updated **2026-10-07**. First written 2026-10-03; items keep their numbers, because commits
cite them ("CollapseNext.md 1.1"), and a finished one is struck, not removed.

Gates and probes this area keeps green: `--breaklag`, `--jam`, `--drawn` (each also with `--big`),
`--wreck`, `--fixture`, `--walk`, `--dormant`, `--groups --big` (the interiors gate; `--rooms` is
its old name and runs it), `--view --big`, `--far`; `tools/collapse_probe.gd`,
`hang_probe.gd`, `solve_probe.gd`, `debris_probe.gd`, `snapshot_probe.gd`, `loopback_probe.gd`,
`float_probe.gd`, `cap_probe.gd`, `shell_probe.gd`, `interior_probe.gd`, `interior_group_probe.gd`,
`storey_probe.gd`,
`far_rules_probe.gd` (the last two are sections of collapse_probe run in a city of their own). Timing passes (`--shot`,
`--stress`, `--big --shot`) only with the editor closed and no other chat running Godot.

---

## 1. Next, in order

### ~~1.1 A damaged shell's collision does not follow its damage~~ — done 2026-10-04 (985f695)
The boxes are built from the same per-band masks as the shell's mesh, with a roof on the highest
floor still standing; a clean cut now counts as damage. `collapse_probe` "shellhit".

### ~~1.2 Wreckage in a room leaves the furniture standing in it~~ — done 2026-10-03 (f6f3d16)
A drawn item a piece lands on is crushed and the room redrawn; faked and drawn furniture in a
section's box is hidden the tick the section leaves. `collapse_probe` "crushdrawn" (on the storey
groups since 2026-10-08; `fakehide_probe` went with the fake drawing it measured -- the groups'
form of it is `InteriorGroups.check_floors`).

### 1.3 Single bricks still spray off PIECES
Held bricks (`Block::held`, `BrickWorld.reattach_held_groups`, groups of 8 or fewer) are on for
buildings only. On pieces (`PIECE_SOLVE`) it made `collapse_probe`'s soldier stop riding a toppling
building over in 2 of 3 full runs (0.4 m and 1.0 m against 13 m), so it was taken out. **Do:** find
why holding bricks on a toppling piece changes how it goes over (likely the piece no longer sheds
what let it tip), then put it back for pieces behind that fix. **Check:** `hang_probe` with a piece
case; collapse_probe "rode it" over several full runs.

### ~~1.4 Hits on pieces still make many medium bodies~~ — fixed 2026-10-07; timed 2026-10-08: it cost the collapse pass a third, most of it taken back (§3)
`--big --shot`'s body census: ~150 bodies of 49–499 bricks off pieces that were **hit**, 100–150 ms
to make over the run, ~13 % of moving boxes. Groups of 48 or fewer off a piece crumble already.
**Do:** measure what a hit on a falling piece actually cuts (solve groups by size) and decide: a
larger crumble limit for pieces far from the player, or a hit on a falling piece breaks it along
storey lines only. **Check:** the census line in `--big --shot`.
2026-10-06, same pass: off pieces that were hit, 107 bodies of 49–499 (82 ms) and **349 of 500 or
more (949 ms to make)**; the worst `islands.tick` is 43.6 ms, 41.4 of it rebuilding merged boxes
after a hit. The big ones cost more than the medium ones this item was written about.

**Measured and fixed 2026-10-07.** Counting hits by where the piece was (`IslandManager.hit_census`,
a line in `--big --shot`): **262 hits on pieces in the air made 174 bodies; 155 on pieces that were
down made 12.** A piece's solve stands it on its lowest bricks and asks what their joints can hold --
right for wreckage on the ground, and for a section in free fall a tower's weight hung on a row of
studs that is holding up nothing, so one shot failed it all the way across. Three changes:
* **A piece in the air is not stress-solved** (`solve_island`): it comes apart where a hit
  disconnects it and nowhere else -- the rule for every brick. The landing breaks it, along its
  storeys, when it gets there. `float_probe`: a hole in a falling section's wall leaves it one
  piece; cut clean through, it is two; down, it is solved as before.
* ~~**A hit's solve is queued** like a landing's, not run inside the call: once a piece a tick
  however many blasts reached it, on the pieces' clock.~~ **Taken back 2026-10-08** (§3): it is
  solved in the call again -- queued, pieces under fire stayed whole and moving, and the pass was
  a fifth slower with more long ticks, not fewer. A decision still queued (a landing's, or what
  one pass could not finish shedding) is made before its piece is put to sleep (`_decide_owed`),
  and a save carries whether a piece had landed, so a load decides as the host did
  (`snapshot_probe`).
* **A moving piece's merged collision is rebuilt at most every 6 ticks, 12 in the air**
  (`_flush_reshapes`): it was every tick the piece was hit, the whole piece each time.

`--big --shot`, before -> after (three runs after): bodies of 500+ off hit pieces **159 -> 41-60**,
their making 384 ms -> 109-145; hits in the air 174 bodies -> 3-12; collision rebuilds about
900-1,300 -> 250-360; the worst script tick 52 ms -> 41-57, ticks over 25 ms 10 -> 10-18. The log
still replays into the same structure. **Not shown to be faster overall:** frames averaged 18 ms
before and 22-23 after, with more in motion at once (peak 7,000 boxes -> 18-20,000 -- sections that
used to shatter now come down whole) -- and another chat's Godot was running through all of these,
so no frame time here is to be trusted either way. ~~**Owed:** the same before/after with nothing
else running~~ -- taken 2026-10-08, §3: this change made the pass a third slower (23.5 -> 30.8 ms
a frame, three alternated pairs); a starved queue is fixed and the queued hit solve taken back
(26.8), and what is left is the price of a shot section coming down whole. Hits on pieces already
on the ground still make bodies (612 hits, 124 bodies then; 350-420 hits, 112-162 bodies now).

### ~~1.5 The first stand-in for a big far piece is built on the main thread~~ — done 2026-10-06
A piece of `COARSE_ASYNC_BLOCKS` (1,500) bricks or more has its stand-in built on a worker
(`BrickWorld.coarse_chunk_async`, harvested in `IslandManager._harvest_coarse_jobs`); a block placed
or removed in the chunk, or the chunk released, waits for the worker and drops its build
(`settle_coarse_job`), and the piece asks again. `--big --shot`: 184 stand-ins, 150 of them on a
worker, the slowest on the main thread 1.6 ms (it was 17–22), and the slowest mesh the queue makes
is now a bake at 4.1 ms. `coarse_probe` "on a worker": the worker's build is the one made in place.
What the worst tick is now: `fracture: merged rebuilds`, 41 ms (see 1.4).

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
`CityScene._mid_collapse` (`COLLAPSE_QUIET_MS`) holds the storey groups (it held the rungs and the
wreck spill, until those went, 2026-10-08), and `_stream_pieces` draws nothing new on a piece still
moving. `tools/far_rules_probe.gd`, 9 checks, one of them the same case with the rule off. A blast
lays a piece only when the camera is within 60 m of it, so nothing is made far off. The rule
as the user set it: a collapse far from every player is still simulated -- it has to land where it
would -- but:
* **a piece of fewer than ten bricks is deleted when it breaks off**, on every machine (the host
  says so in the DETACH, as it does for the moving cap);
* **no interior and no items are made for wreckage until somebody is close to it** (inside the
  range a standing building's interior is drawn at -- and not on a piece still moving);
* **a building that is mid-collapse when it is upgraded** (made bricks, or come into range)
  **gets no interior and no items until it has finished**: no storey group is made in a building
  that is still coming apart.

### ~~1.9 Interiors by storey group (Interiors.md §8, as amended)~~ — all five stages done 2026-10-08
The simplification, with the unit the user set: a group of storeys, each with one interior drawing
and one item drawing, faded by distance, rebuilt alone. Stages as Interiors.md §8.7.
* **Stage 1, done, and the default** (Interiors.md §8.8; user, 2026-10-07): `InteriorGroups`.
* **A collapsed building is not empty** (Interiors.md §8.10, 2026-10-07, the user's report): an
  item is on whichever chunk holds most of its floor, so still pieces near the player draw what
  stood on their floors, and a tower that topples whole keeps its furniture on the way down.
  `interior_group_probe` 28, `-- --groups --big` 22. Not covered: pieces the cap has put to sleep.
* **Stage 2, done** (Interiors.md §8.9): a piece whose floor is destroyed is gone that tick; one
  whose floor leaves as a section is drawn on the section and rides it down, and comes off when it
  lands. No index: every piece at that height is asked for its floor, 0.2 ms a time
  (`InteriorGroups.check_floors`). `interior_group_probe` 22, `-- --groups --big` 19.
* **Stage 3, done 2026-10-08** (Interiors.md §8.11): a blast or bullet lays the pieces it reaches
  as bricks, each on its own, and no room; unseen, it writes off those pieces only.
  `interior_group_probe` 34, `-- --groups --big` 24.
* **Stage 4, done 2026-10-08** (Interiors.md §8.12): the drawn, fake and real rungs are gone, with
  room activation by reach, `compromise_rooms`, spill and write-off, and the switch (F6,
  `-- --rungs`). Gone with them: `--interiors`, `--interior-audit`, the old `--rooms` gate (the
  name now runs `--groups`), `fakehide_probe`. Rewritten against the groups: `interior_probe` (87),
  collapse_probe's "fake" (now "interior"), "crushdrawn" and "farrules". `interior_group_probe` 33,
  `-- --groups --big` 23.
* **Stage 5, done 2026-10-08** (Interiors.md §8.13): a loot card dithers away over the last 25 m
  before its range (`ImpostorItems.CULL_FADE`). Nothing visible changes today -- no scene has an
  `ImpostorItems` yet, so loot has no cull edge. `impostor_probe` 30.

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
* **Should a shot shatter a section that is falling?** (2026-10-08, §3.) Today it does not: a piece
  in the air is cut only where a hit disconnects it (1.4), which is the rule for every brick, and
  it lands whole. Stress-solving it in the air as if it stood on its lowest bricks -- how it was
  before 1.4 -- breaks it into many bodies on the way down, which is wrong by that rule and is
  about a sixth faster in `--big --shot` (26.8 ms a frame against 20.5-21.7), because what lands is
  smaller and comes to rest sooner. Kept as it is until decided.
* **Aim-ahead promotion** (`_aim_promote`, 100 m, kept 8 s) makes more buildings bricks while the
  player looks round. No spikes measured; if memory or frame time climbs, lengthen the dwell
  (`AIM_PROMOTE_TICKS`) or cap how many it keeps.

---

## 3. Measurements

**Read frame means with care: the passes run with V-Sync on** (the menu's default), so a frame is
16.7, 33.3 or 50 ms and nothing between. A pass whose frames go from 15 ms of work to 18 reads as
its mean doubling. The script ticks (`[prof]`) are not quantised; compare those first.

* **`--big --shot`, 2026-10-08: what 1.4 cost, and what was taken back.** Quiet machine throughout
  (editor closed, no other Godot before or after any run). Forty-odd runs; what they say first is
  how to read the pass at all:

  * **One run is not a measurement.** The same code read 27 ms a frame and 33 an hour apart, and
    the commit the 2026-10-07 figure below was taken on (17.8 ms, 23 frames over 33.3) read
    21.0-26.5 and 58-109 in four runs today: that figure was a lucky run. The machine also slows
    by a sixth over an hour of runs. **Only alternated runs compare** -- A, B, A, B -- three pairs
    or more; everything below is.
  * Frame means are V-Sync-quantised (above). Frames over 33.3 ms moves the same way and further.

  | compared, alternated | runs each | frames mean, ms | of 906 over 33.3 ms | ticks over 25 ms |
  |---|---|---|---|---|
  | just before 1.4 (aab167a) / just after (b5376ed) | 3 | 23.5 / **30.8** | 90 / **238** | 90 / 72 |
  | 1.4's three parts switched off for the run, one at a time: none / in-air rule / queued hit solve / rebuild limit | 2 | 29.9 / 27.1 / 25.8 / 32.5 | 215 / 144 / 139 / 293 | 48 / 48 / 49 / 76 |
  | in-air rule and queued hit solve both off, rebuild limit kept | 3 | 20.5-21.7 | 60-88 | 28-39 |
  | landings with a unit of their own a tick / without (the fix) | 6 | **28.8** / 33.9 | **190** / 308 | the same |
  | on top of that, a hit solved in the call / queued (the second fix) | 3 | **25.0** / 31.1 | **132** / 269 | **44** / 69 |
  | as the game is now / just before 1.4 | 3 | 26.8 / 23.4 | 149 / 93 | 69 / 59 |

  **What happened.** 1.4 (b5376ed) made this pass a third slower. Of its three parts the rebuild
  limit is a gain and stays; the cost was the other two together, and through one thing: **how many
  pieces are down and still moving**. Per tick, counted: pieces in the air are one piece on
  average and cost nothing; pieces down and moving were 26 against 19, and the physics solver
  takes 2.5-2.9 ms a tick for every thousand of their boxes. They stayed whole and moving because
  * the landing queue was starved (`IslandManager.WORK_MIN`): one unit of queue work a tick
    shared by the re-solves and the landings, re-solves first, and with a hit's solve queued a
    re-solve was nearly always waiting -- up to 25 landings stood in line, each a section that
    should have been broken along its storeys. **Fixed:** each queue has its own first unit;
  * a hit's solve, queued, ran once a piece a tick instead of once a blast, so a piece under fire
    shed less a tick, lay there longer and was hit again -- twice the hits on pieces that were
    down. It also made *more* long ticks, not fewer. **Taken back:** solved in the call, as before
    1.4. `_decide_owed` and the saved `landed` stay, for the solves that are still queued.

  **Where it stands:** 26.8 ms against 23.4 before 1.4, and 149 slow frames against 93. What is
  left is the in-air rule itself: a falling section that is shot is no longer stress-solved as if
  it stood on its lowest bricks, so it comes down whole (the peak is 19,000 boxes in motion
  against 8,000) where it used to arrive already in pieces. That rule is the game's rule for every
  brick -- nothing falls that is still connected and not broken by force -- and switching it off
  as well is the fastest this pass has run (20.5-21.7 ms). **A decision, not a bug** (§2): keep
  the rule and pay about a sixth in the heaviest pass there is, or let a shot shatter what is
  falling. Kept, until somebody says otherwise.

  **Tried, no gain that two to four runs could show:** a blast waking only what rested on what it
  removed (`support_gone`) instead of everything within four radii; not waking a piece a blast
  reached and took nothing from; the queues' 4 ms counted from when they start, not from the top
  of the tick; main's near tier off.
  Also in the worst ticks, unchanged by any of this: one piece's merged collision rebuilt in
  22.5 ms (15,099 bricks, 2,021 boxes); one landing's re-solve 38.4 ms (12,315 bricks); `stream`
  at 33-46 ms on ticks that are 0 or 2 in every four (the shells' pass and the detail/trim pass).
* **`--big --shot`, taken 2026-10-08 before any of that, one run each** (kept for the record; see
  the first point above for what one run is worth): as the game was 32.8 ms, 287 over 33.3, worst
  script tick 63.4, 50 ticks over 25; near tier off 34.1 / 294 / 55.5 / 63.
* **`--stress --buildings=200`, 2026-10-08, quiet** (as above): whole run mean **24.7 ms**, worst
  75.5, 302 of 2,874 frames over 33.3 ms (10.5 %). By phase, mean / worst: under fire 16.7 / 23.0;
  damage queue draining 18.9 / 52.4; collapsing 27.8 / 48.4; settled 37.6 / 75.5 (160 of 240 over
  33.3); trimmed 25.1 / 48.9. Worst script tick 45.1 ms, 93 ticks over 25 ms; mean per tick the
  biggest is `stream` 2.8 ms, then `hud` 1.1. A building given back 8.7 ms on average (54 of
  them), the worst 20.0 (2,850 bricks: dematerialise 7.1 + shell 12.0); a promotion 2.7 ms (200).
  Interior pieces a blast reached: 668, 41 of them laid as bricks, 163 ms in all. Peak 457.5 MB
  with 183 buildings resident, 260.7 MB after trimming. No earlier quiet run to set it against.
* **`--big --shot`, taken 2026-10-07** with the editor closed and no other Godot running when the
  batch began (not re-checked during the pass; on the user's saved settings, which were the menu's
  defaults but for brightness): frames mean **17.8 ms**, worst 67.4, 23 of 906 over 33 ms; worst
  script tick **55.1 ms**, 9 ticks over 25 ms (islands 21 + damage 16 + spawn 11 in the worst; one
  of 34.5 that is all `stream`, at tick 24); the slowest stand-in on the main thread 1.7 ms; worst
  `islands.tick` 21.0 ms. Off pieces that were hit: 58 bodies of 49-499 bricks (49 ms to make) and
  157 of 500 or more (385 ms) -- item 1.4. The log replays into the same structure. For
  scale, the day before, with other chats' Godot and Blender running, the same pass read 90 ms a
  frame and 26 ticks over 25.
* **Passes now run on the menu's default settings** (`TestWindow.use_default_settings`), not on
  whatever is saved in Options, so numbers and pictures are comparable from here on. They were
  not before: the `--far` crossfade control read 8.8 %, 6.4 %, 5.1 % or 4.7 % by the anti-aliasing
  that happened to be saved.
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
* **`--walk` fails one check with storey groups on** ("gets past it rather than stopping dead",
  the debug camera's walker on a brick course under a beam): it ducks, then stays at the beam's
  lip. Not furniture in the way -- nothing overlaps it but the beam and the course, and a test
  step from where it stops is free. Every frame its move goes through (2 cm forward) and it is
  back where it was the next. With the rungs, or with the groups' collision boxes off, the same
  check passes by NOT ducking: the standing test misses the beam and the body goes through it
  12 cm deep. So the check was passing on a miss, and the walker's duck-under does not work; it is
  `DebugCamera._walk`, not interiors. The player pawn's same check (`--play`) passes either way.
  A stand-up probe a body's width ahead did not fix it (tried, reverted).
* **`--play`'s own duck-under check failed once** (2026-10-08, "standing on a brick it ducks under
  the beam and gets past": ducked, feet at 0.03 m -- off the brick course) and passed the three
  runs after it and every run before it that day. The pawn's version of the walker's check above;
  likely the same edge. One in about a dozen so far.
* **`-- --groups --programs` fails one check** (found 2026-10-08; the same on the commit before
  stage 4, so not from it): "a section falls: ... none is left drawn over a floor that has gone" --
  1 tick, up to 3 boxes in the small city; 3 ticks, up to 9 with `--big`. Without `--programs` it
  passes. Not looked into. A guess, untested: an authored piece wide enough to stand on two floor
  panels keeps its place while most of its floor is still there (the rule, §8.10), and the gate
  counts its parts over the panel that has left -- which a built-in piece is too small to do.
  Either the rule or the gate's measure is wrong for wide pieces; trace which rows hang first.
* **Tests failing on main that are not this area's:** `squad_advance_probe` (flaky),
  `threat_style_probe` (crashes on exit after passing), and since the several-disasters merge
  collapse_probe "a lightning storm" (passed in the one run since main's c5314fa, 2026-10-08) and
  disaster_probe "a soldier in a meteor's ring runs out of it". `disaster_probe` "go over" and
  collapse_probe "rode it" vary with physics run to run. `impostor_probe` "no holes" was on this
  list: fixed 2026-10-08 -- the probe's camera was interpolated, so its pictures were taken on the
  way to where it had been put (Interiors.md §8.13).

---

## 5. Tools for looking

**View switches** (`scripts/debug_view.gd`, 2026-10-06), in play:

| Key | What | States |
|---|---|---|
| **7** | structure: bricks of buildings, shells, far boxes, pieces, crumbs | shown / see-through / hidden |
| **8** | interior pieces: a storey group's drawing, laid as bricks, riding a section | shown / hidden |
| **9** | items: a storey group's item drawing, loot | shown / hidden |

Only the drawing changes. What is hidden keeps its bricks, its collision and its shadow, and is
streamed and worked out as before -- so with 7 on hidden, what floats in the air is exactly the
interior that is spawned, and with 8 hidden as well, what is left is the items. The HUD's `view` line
says what is switched and counts what is drawn of each. Far boxes and impostor cards stay solid when
structure is see-through (they cut their own alpha) and go when it is hidden. A piece laid as bricks
draws its small parts with it, so 9 does not separate those. Today a generated city has no
items to hide: no authored item has a DETAIL part and nothing drops loot in the city scene.
Gate: `city.tscn -- --view --big` (10), which writes `shots/view_*.png`.

