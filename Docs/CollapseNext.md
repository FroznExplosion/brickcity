# Collapse next — what is not done

The task list for destruction, collapse, pieces and their LOD: **what is not done, in the order
to do it**, with the evidence for each and how to tell it is fixed. What was built and why is in
[Collapse.md](Collapse.md) and [Status.md](Status.md) (the sections from "A break, then nothing for
a second" on); the user's priorities are the ones reported in play — lag on the first hit, a pause
before anything falls, things hanging in mid-air, things drawn that are not there.

Last updated **2026-10-13**. First written 2026-10-03; items keep their numbers, because commits
cite them ("CollapseNext.md 1.1"), and a finished one is struck, not removed.

**The test for a collapse rule (user, 2026-10-13): is that what a real brick model does?** The aim
is real LEGO breaking apart ([BrickFailure.md](BrickFailure.md)); a rule that is faster and wrong
by that test is not taken.

Gates and probes this area keeps green: `--breaklag`, `--jam`, `--drawn` (each also with `--big`),
`--wreck`, `--ring`, `--fixture`, `--walk`, `--dormant`, `--groups --big` (the interiors gate; `--rooms` is
its old name and runs it), `--view --big`, `--far`; `tools/collapse_probe.gd`,
`hang_probe.gd`, `solve_probe.gd`, `debris_probe.gd`, `snapshot_probe.gd`, `loopback_probe.gd`,
`float_probe.gd`, `cap_probe.gd`, `shell_probe.gd`, `interior_probe.gd`, `interior_group_probe.gd`,
`barrage_probe.gd`, `stud_strength_probe.gd`, `blast_ring_probe.gd`, `seam_probe.gd`, `push_probe.gd`,
`storey_probe.gd`,
`far_rules_probe.gd` (the last two are sections of collapse_probe run in a city of their own). Timing passes (`--shot`,
`--stress`, `--big --shot`) only with the editor closed and no other chat running Godot.

---

## 0. Everything that is left, in one list (2026-10-13)

In the order to do it. Each line points at where the item is written up.

**Done 2026-10-13** (timed: §1.10)
1. ~~A loose piece is a rigid chunk~~ -- never stress-solved; it parts where a hit cuts it and
   where a landing snaps it. §1.10 (1).
2. ~~Wreckage at rest stays at rest when it is shot~~ -- woken only if the hit cut it in two or
   took what it rests on. §1.10 (2).

3. ~~Stud strength: try it stronger, then tune by feel~~ (user, 2026-10-13) -- four times what
   it was, and a slider in Options to move it. §1.10 (6).

4. ~~A blast loosens the ring round it instead of deleting it~~ -- the middle of a blast is
   gone and the ring round it is thrown out as crumbs; the structure and the log are what they
   were. §1.10 (3).

5. ~~A snap goes at the weakest seam near the contact, not the nearest storey line~~ -- a
   tower's piece now parts along a row of windows, its columns pulled off their feet. §1.10 (5).

6. ~~Things are pushed and bounce~~ -- a blast shoves the loose pieces it reaches (light ones
   thrown, heavy wreckage hardly moved), and loose bricks bounce before they settle; a slider in
   Options for each. §1.10 (4).

**Next, the brick model (§1.10)**: nothing left on this list.

**Left over from earlier lists**
7. ~~Single bricks spraying off pieces~~ (§1.3) -- checked 2026-10-14: the stress solve's
   spray went with item 1; a piece struck by another now peels a clump, not a spray of bricks;
   what is left comes from blasts and from bands (item 18).
8. ~~A queued blast in `--shot` hits pieces that came loose after it was fired~~ -- decided
   2026-10-14: let it, and leave the pass as it is (§3, last point).
9. Interiors ([Interiors.md](Interiors.md) §8.12-8.13): furniture drawn on wreckage is not turned
   to bricks when the wreckage is hit; a written-off piece leaves no debris; pieces the cap has
   put to sleep carry no interior; a rolled gun swaps to its card at 12 m in one frame.
10. Not looked at yet: how the new brick vehicles' crushing and the mechs' breaching
    (AIVehicles.md, AI.md) sit with these rules -- they damage buildings by their own paths.

**Proposed, the user's call**
17. Bricks that stay where they fall. A crumb is gone a second and a half after it comes loose
    (`CRUMB_LIFE_MS`), so a hole has nothing lying under it. One that has landed costs nothing
    to keep -- it is an instance in a MultiMesh that no longer moves -- so a pool of landed
    bricks (a few thousand, the oldest taken first, none where a piece comes to rest on them)
    would leave the heap a real wall leaves. They would be drawn only: nothing to stand on,
    hide behind or pick up. Not started.

18. A piece long the other way tears a band of loose bricks when it snaps (§1.3): the most
    single bricks a landing makes now. Cracking it along its bond instead needs a joint cut on
    its own -- the engine cuts all of a block's lower joints (`bottom_broken`) or all of them
    (`support_broken`), never one pair. Not started.

**Waiting on something else**
11. Clients see nothing where the host sees crumbs (§1.7) -- needs a live co-op client.
12. Status notes for 2026-09-30 to 10-02, on branch `far-coarse-status` (§4) -- needs the main
    folder's uncommitted `Docs/Status.md` committed first.

**Tests that are red or flicker (§4)**
13. `--walk`: one check, the debug camera's walker does not duck under a beam.
14. `--groups --programs`: one check, boxes drawn over a floor that has gone for a tick.
15. `--jam --big`: about one run in six, a small piece resting on one still creeping.
16. `--play`: the pawn's duck-under check, about one run in twelve.

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

### ~~1.3 Single bricks still spray off PIECES~~ — checked 2026-10-14; the bands are item 18
**Checked 2026-10-14**, counting what comes off pieces by why and how big
(`IslandManager.shed_census`, a line in `barrage_probe` and `--big --shot`). The stress solve
on pieces, which this was about, went with 1.10 (1): nothing fails a piece's joints any more.
Before this check a barrage made, in single bricks: 332 off hits, 211 off landings, **234 off
pieces something landed on** -- that last one a shear with every brick in the ball "joined to
nothing", where a building's and a landing's peel a clump off by its underside. It peels now
(`IslandManager.shear`, `DamageLog.FLAG_PEEL`): **42**, and 79 groups of two to eight. What is
left (one barrage, 2026-10-14): **328** off hits -- bricks whose neighbours a blast took, loose
as a brick model's would be; **136** off landings -- the clump peeled where one touched down,
some of them one brick; **241** off bands torn across pieces long the other way, a quarter as
many breaks as make the rest (item 18 in §0). All of them are crumbs (eight or fewer), drawn
falling and gone.
And `barrage_probe`'s check on wreckage at rest asks what rule 2 says, now: no hit on a piece at
rest wakes it but by cutting it in two (`rest_hits_cut`; `rest_hits_woke` is the rest, and stays
0). It asked that more were left at rest than woken, which turned on how often a barrage cuts.

The held-bricks note below is from before 1.10 (1), kept for the record:
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

### 1.10 Proposed, not started: where a collapse still differs from a real brick model (2026-10-13)
Read against [BrickFailure.md](BrickFailure.md) and the code as it is. What already matches: no
compression failure; a landing peels a clump at the contact and severs one seam of studs at a
storey line, destroying nothing (`fracture_on_impact`, `_snap_across`); a piece in the air is
rigid. What does not, most worth doing first -- each is also less work for the machine:

1. ~~A loose piece on the ground is still stress-solved when it is hit~~ -- **done 2026-10-13.**
   A loose piece is a rigid chunk everywhere: `IslandManager.solve_island` cuts off what a hit or
   a landing has disconnected (`split_if_broken`) and does nothing else. The tension solve on
   pieces is gone, with its command (`PIECE_SOLVE` is still read, for a log written when it was
   written, and never written).
   *Measured* (`tools/barrage_probe.gd`: four towers brought down headless, four blasts a tick
   into each for eight seconds; two runs each way): a hit on a piece that was down made a new body
   **14-18 % of the time before, 2-3 % now** (56-67 bodies a run, then 7-15).
   *What the probe cases say, and do not:* no single piece could be built that the old solve
   failed -- a tower lying on its side holed or slotted from end to end, with the city's studs,
   passes float_probe before and after. The solve only failed pieces in the states a collapse
   leaves them in (one solve in seven had a failure), so the proof is the count, and the line in
   `barrage_probe` (under 8 %) is drawn between the two.
2. ~~Wreckage at rest is woken whole by any shot that reaches it~~ -- **done 2026-10-13.** A hit
   takes its bricks out of a settled piece where it lies (`damage`): frozen, merged, its boxes
   rebuilt round the hole within six ticks. It wakes for two reasons only: the hit **cut it in
   two** (`_shed`), or **took the bricks it stood on** -- `support_gone` over where the bricks
   were, which wakes every settled piece touching that and not wholly below it, this one
   included; the watchdog (`_audit_settled`) is behind that for what it misses.
   The blanket wakes are gone from the shots' path: everything within six metres of a hit piece
   (`damage`), within four radii of any blast (`CityScene._apply_blast`, which now wakes what
   touches where a blast took bricks from a *building*) or bullet (`_fire`), within six metres of
   a piece that shed something (`_shed`) or of a piece newly made (`adopt`).
   A merged piece on the ground that sheds a *body* has its boxes rebuilt at once, not at the
   rate a hit's rebuild is put off to: what leaves it lies exactly inside its old boxes.
   *Measured* (the same probe): 23-34 hits a run found a piece at rest and 19-30 of them left it
   at rest; merged rebuilds 512-577 a run before, 260 now. Under a barrage most hits (about 480
   of 560) still land on pieces that are down and *moving* -- nothing gets time to settle; in
   play, where firing stops, more of them will be at rest.
   **Left as it was:** a piece struck by one that lands on it still wakes everything within six
   metres (`shear`), as do a fire's burnt bricks (`CityScene.fire_burnt`) and the disasters'
   own calls (`wake_near`): not shots, and the first is the next to look at.
   **Timed 2026-10-13** (`--big --shot`, three alternated pairs, every run with no other Godot
   before or after it, one windowed run at a time; 91 C at the peak, never held back):

   | | frames mean, ms | of 906 over 33.3 ms | worst frame | pieces in motion | bodies off hits on pieces that were down |
   |---|---|---|---|---|---|
   | main before this (4d5cb64) | 24.7, 20.3, 20.8 -- **21.9** | 113, 41, 47 -- **67** | 155-159 | 27.8, 27.0, 21.6 | 107, 55, 73 |
   | with it | 19.3, 19.2, 18.6 -- **19.0** | 37, 40, 43 -- **40** | 91-135 | 9.5, 7.5, 8.1 | 0, 0, 0 |

   A seventh fewer milliseconds a frame, two fifths fewer slow frames, a third as many pieces
   moving at once. Ticks over 25 ms are the same within the noise (12-28, then 24-29).
   An earlier try that morning had other chats testing through it and is not counted.
   Checks: `float_probe` 46 (ten new: a piece shot at rest stays one piece, frozen where it lay,
   the piece beside it asleep; its boxes follow; a blast that takes nothing changes nothing; one
   that takes what it stands on wakes it; what stood on the bricks taken wakes; cut clean
   through, it is two and awake), `barrage_probe` 4, `snapshot_probe` 48 (a shot leaves the
   piece whole, so it is saved both awake and asleep), and the rest of the list unchanged.
3. ~~A blast deletes every brick in its radius~~ -- **done 2026-10-13: the middle goes, the
   ring round it is thrown out.** Of the bricks a blast kills, those whose middle is within half
   its radius (`IslandManager.BLAST_CORE`) are gone -- the round going through -- and the rest
   leave as crumbs: drawn, thrown off the face (`BLAST_THROW`, 3 m/s at most) and each its own
   way from the middle of the blast, falling, gone a second and a half on
   (`IslandManager.throw_killed`, from `CityScene._apply_blast` for a building and `damage` for a
   piece). A gun's wear destroys nothing: the brick the last round finishes is knocked off whole.
   **The structure is what it was, to the brick.** They are dead in the grid the moment the blast
   lands, as before, so the damage log, a replay, a save and a client's world do not change.
   *Why not knocked loose and left for the solve* (what this item first said, and what
   `separate_near` does: without `peel`, every brick in the ball is "joined to nothing"; a
   landing uses `peel`, which cuts a clump off by its underside): a brick joined to nothing is a
   group of one, and a group of eight or fewer is crumbled where it comes loose
   (`DEBRIS_MAX_BLOCKS`). So the same brick ends as the same crumb -- after the next solve has
   found it, a DETACH has been written for it, and a grid has been cut out for it and freed,
   a dozen or two times a blast. It is drawn as the crumb straight away instead.
   *Where they come down:* two rays a blast, not one -- what is under the hole, and what is under
   the air a metre past its face; a brick comes down on the second if it is out past the face
   before it has dropped a course below the first (`CRUMB_SILL`). With one floor for all of them
   the bricks that cleared the wall lay in the air beside the hole, at the storey's floor.
   *This machine's own, as every crumb is:* none drawn past 60 m, out of view, in a tornado's
   wind (what it tears off is the tornado's to show), or past `CRUMBS_MAX`; a big charge throws
   every so-manyth brick of its ring, 48 at most (`BLAST_CRUMBS_MAX`).
   *Counted* (`barrage_probe`, four towers under 3,840 blasts of 1.3 m): 5,744 bricks killed --
   **345 in a core, 5,390 thrown, 9 not drawn**. A brick is big beside a blast (a 2x4 is 1.4 m
   long; the core of a 1.3 m blast is 0.65 m), so few have their middle in one: nineteen in
   twenty of the bricks a blast takes now leave it in one piece.
   *Left as it was:* furniture a blast kills is gone (a lone block of it is a blank cube); what
   fire burns out is gone; a client draws none of it (§1.7, with every other crumb). **And a
   crumb is gone in a second and a half** -- thrown out, the bricks still do not lie where they
   fell. A heap that stays is §0's item 17.
   **Timed 2026-10-13** (`--big --shot`, three alternated pairs on a quiet machine -- no editor,
   no other Godot before or after any run -- one windowed run at a time; 87 C at the peak, never
   held back):

   | | frames mean, ms | of 906 over 33.3 ms | ticks over 25 ms |
   |---|---|---|---|
   | ring not thrown | 18.6, 17.8, 18.2 -- **18.2** | 31, 36, 20 -- **29** | 18, 12, 16 |
   | thrown | 18.0, 17.8, 18.1 -- **18.0** | 46, 23, 26 -- **32** | 13, 12, 14 |

   No difference to be seen -- **and that pass is not where one would show**: its blasts land
   far from its camera, and of the 3,100 bricks they kill it draws 70 (2,800 are too far or out
   of view). What it costs where they ARE drawn is counted in `barrage_probe`, camera 28 m off,
   240 blasts a second for sixteen seconds: **throwing 5,390 bricks took 105 ms -- 0.02 ms a
   brick, 1.4 ms the worst blast** (48 bricks, or the first of a size, which makes its mesh) --
   and moving every crumb there was took 0.4 ms a tick on average, 1.6 ms at the worst, with 944
   in the air at once. A rocket a second is twenty crumbs.
   *Tests:* `tools/blast_ring_probe.gd` 19 (the grid is unchanged by the throw; ring and core
   by count; where they start and which way they go; fallen and gone; a blast in the air; far,
   unseen, wind, a big charge; a gun's last round; a piece in the street, which stays at rest),
   `barrage_probe` 6 (the count above adds up; what throwing them costs), and
   `city.tscn -- --ring` (4), which writes `shots/city_ring_0.png` and `_1.png` -- a tenth and
   half a second after one rocket.
4. ~~Nothing is ever pushed~~ -- **done 2026-10-14: a blast shoves what it reaches, and loose
   bricks clatter.** Both are feel numbers, each with a slider in **Options > Gameplay**:
   *"Blast Push (Developer)"*, 0x to 3x, default 1x (`IslandManager.push_times`), and *"Brick
   Bounce (Developer)"*, 0 to 0.8, default 0.25 (`crumb_bounce`). A headless run keeps the
   defaults whatever is saved.
   *The push* (`IslandManager.push_near`, from `damage_near` and the debug gun's direct hit on a
   piece; a gun's wear pushes nothing): every loose piece within 2.5 radii of a blast is given a
   shove away from it and a little up (`PUSH_LIFT`), at the side nearest the blast, so a blast at
   one end of a beam turns it. 4 m/s for a piece of 20 bricks at the blast's middle, nothing at
   the edge of its reach; a smaller piece faster by the cube root of how much smaller, a bigger
   one slower by the whole of how much bigger -- a blast only meets as much face as is within its
   reach, so past that size the shove is the same and the mass is not. A 256-brick heap a rocket
   lands half a metre from gets 0.3 m/s. At most 8 m/s.
   *What stays put:* a piece that is down -- at rest, or sliding to a stop -- takes no shove
   under 1 m/s (`PUSH_WAKE_SPEED`); its friction would take it back in a moment, and pushing
   every piece that was down kept everything under fire moving. So wreckage at rest still stays
   at rest when it is shot, unless the shot moves it properly (1.10 (2)); a piece in the air
   takes every shove.
   *The bounce* (`_update_crumbs`): a crumb that comes down faster than 1.5 m/s
   (`CRUMB_REST_SPEED`) goes back up at a quarter of that speed and on at half its speed along,
   still turning; slower, it stops. Only crumbs: a brick or a handful is light, hard, and what a
   blast throws. A section's landing is spent breaking it (`fracture_on_impact`), and one that
   sprang back up would land and break again -- bodies keep bounce 0. At 0.35 a crumb from two
   storeys up was still bouncing when it faded (`CRUMB_LIFE_MS`); 0.25 lets it come to rest.
   *Under fire* (`barrage_probe`, now three bursts a tower with quiet between -- under a blast
   every tick for eight seconds nothing got to rest at all, and what a shot does to wreckage at
   rest is half of what it asks): about 1,600-1,900 shoves a run, 45 of them waking a piece from
   rest, 1,800-2,100 shrugged off by pieces that were down; with the push off the same probe has
   11 hits on wreckage at rest where it has 6-7 with it.
   **Timed 2026-10-14** (`--big --shot`, three alternated pairs, push and bounce off then on, no
   editor and no other Godot before or after any run, one windowed run at a time, the chip let
   cool under 80 C before each; 85 C at the peak, never held back):

   | | frames mean, ms | of 906 over 33.3 ms | ticks over 25 ms | pieces in motion |
   |---|---|---|---|---|
   | off | 18.3, 18.0, 18.1 -- **18.1** | 25, 24, 31 -- **27** | 18, 17, 16 | 12.3, 7.5, 8.9 |
   | on | 19.8, 19.6, 17.6 -- **19.0** | 38, 41, 32 -- **37** | 21, 29, 8 | 14.2, 14.5, 12.9 |

   **About a twentieth more a frame, a third more slow frames, and four more pieces moving** --
   the shoves keep what they reach moving for longer, and that is what costs. The slider at 0
   takes it all back. A first try that morning crawled at 76-90 ms a frame with the display
   asleep and is not counted (a short `--ring` takes 13 s awake and 45 asleep).
   *Tests:* `tools/push_probe.gd` 16 (a handful knocked over, away and up; a heap of 256
   shrugs; out of reach untouched; nearer is harder; 0 on the slider pushes nothing; a gun's wear
   pushes nothing; a falling piece is knocked sideways; all of it settles; crumbs bounce, never
   sink, and come to rest; 0 on the slider, no bounce), `barrage_probe` 6 (`-- --push=N`,
   `--bounce=F` to see what the numbers move).
5. ~~A snap goes at the storey line nearest the contact~~ -- **done 2026-10-13: at the weakest
   seam near it.** A landing that snaps a piece across its own Y (`_snap_across`) asks
   `BrickWorld.seam_studs` what holds each course boundary within half a storey of the contact
   (1.3 m on a build with no storeys), and severs the one that lets go of the fewest studs
   (`IslandManager._weak_seam`): the nearer of two as weak as each other, and a storey line
   unless something else is clearly weaker -- under three quarters of it
   (`SEAM_PREFERS_FLOOR`; the slab goes with the walls it is the floor of, and the interiors
   ride on that). Counted once a landing, not once a contact: the count walks every block of the
   piece, about 0.2 ms on a tower of 859.
   *What a recipe tower is held by* (28 x 16, first storeys): its storey line, 208 studs, nothing
   running through; each course boundary in a row of windows, **112 studs**, with the six
   columns of that storey running through it (a column is one block a storey tall). So a tower
   that comes down across something parts through its windows now, as a brick model would.
   *The columns:* a seam that a block runs through leaves the two sides joined by that block,
   so `sever_seams` takes `through` -- such a block is cut too, at its own foot, and goes with
   the upper side, as a pillar pulls off its studs at one end. In a recipe tower the columns are
   stacks of their own (pad, column, pad, standing on the ground, joined to no wall: a tower whole
   is one part of 793 bricks and six stacks of eleven), so there the walls part either way and
   each stack parts at that storey; in a build, a column under a beam is what held the two sides.
   The snap's command says so (`DamageLog.FLAG_STEP`), so a client and a replay cut the same --
   and a snap recorded before it replays as it was made.
   *Counted* (`barrage_probe`): 89 snaps, **54 at the weakest seam in reach**, 10 on a storey
   line, 34 torn as a band (a piece long the other way, which has no seam to find -- unchanged);
   the seams chosen held with 8,676 studs all told against 11,665 across the storey lines beside
   them. `--shot`: 16 of 17. They used to be 137 of 147 on storey lines.
   *Tests:* `tools/seam_probe.gd` 22 (the count, brick by brick; a column through a seam holding
   the two sides, and pulled off its foot; a recipe tower's line and its windows; where a piece
   of one snaps, and that it does; a wall with no windows still goes at its storey line; an old
   command replays as it was made). Every other probe and gate as before.
6. ~~How strong a stud is~~ -- **done 2026-10-13: one number, tunable; the first try is four
   times what it was.** `BrickStrength` (`scripts/brick_strength.gd`): `SCALED` 9.3 (the toy's
   clutch on a 0.35 m stud, which the game ran on), `TOY` 408 (the toy itself, 44 times that), and
   the game's `tension()` = `SCALED` x `times`. `times` is a setting -- **Options > Gameplay, "Stud
   Strength (Developer)", 1x to 44x, default 4x** -- that buildings in bricks take the moment it
   is moved (`CityScene._restud`); what has already fallen is not put back. The user's call:
   try it stronger, then tune by feel. It is theirs to move from here.
   *What it moves, counted* (`barrage_probe -- --stud=N`: four towers brought down under fire,
   one run each): building solves with a joint failed in tension **17 of 437 at 1x (312
   joints), 6 of 425 at 4x (54 joints), none at 44x**. And one case (`stud_strength_probe`): a tower
   hanging over two thirds of its ground storey fails 2 joints and drops 34 bricks at 1x; at 4x
   and at the toy's none fail and 19 drop -- the ones the shots cut off.
   *What that says about the number:* a joint failing in tension was already rare -- one solve
   in twenty-five at the old strength. Buildings come down because they are cut through, or their
   weight is off what is left (toppling, `check_stability`; a storey tipping or crushed,
   `gravity_check`). So this is not a big lever on how much falls; where it shows is an overhang
   holding on, and **a top held down by its studs when it stands off a corner** (the tip rule
   weighs studs at their lever, and follows it). `storey_probe` still tips a top off one corner
   at 4x, 6x and 8x, by a margin that is not steady (1.2 to 2.5 times what it can hold): if tops
   start standing on corners in play, that is this number too high.
   *What does not follow it, on purpose:* an earthquake's or a wind's sideways load
   (`DisasterContext.lateral`) is still weighed against 9.3 -- the disasters' strengths were set
   against it -- and a storey is crushed at the same load whatever a stud holds
   (`_gravity_fail` hands the check its limit over `times`). Whoever retunes the disasters takes
   three lines out.
   *Tests:* a headless run keeps the default whatever is saved in Options, as a test window does;
   a checkpoint carries the strength it was saved at and is loaded at it (the log's solves are
   that strength's). `stud_strength_probe` 9 (the name `stud_probe` is build mode's, for drawn
   studs). At the new default: collapse_probe 62, storey 4, far_rules 9, barrage 4, float 46,
   hang 10, snapshot 48, loopback 32, cap 17, dormant 33, debris 29; disaster_probe 153 of 155,
   the two that fail failing the same without this; `--jam --big` 4, `--checkpoint` 9, `--wreck`
   2, `--breaklag --big` 7, `--play` 15, `--groups --big` 23, `--dormant` 21.

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
* ~~Should a shot shatter a section that is falling?~~ — **decided 2026-10-13 (user): no.** "I'm
  trying to replicate real LEGOs breaking apart. A falling LEGO tower would likely stay as one
  piece until it hits something." So a piece in the air is cut only where a hit disconnects it
  (1.4) and lands whole, and the sixth it costs `--big --shot` (26.8 ms a frame against 20.5-21.7
  with it off, §3) is paid. **The test for every collapse rule from here: is that what a real
  brick model does?** ([BrickFailure.md](BrickFailure.md) is the note on what it does.) What that
  asks for next is §1.10.
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
* ~~`--shot` queues ~1,000 blasts that land at eight a tick; with cascades finishing in the tick,
  towers come down while blasts are still landing, and those blasts shatter the falling chunks
  (one run made 136 bodies of 500+ bricks off hit pieces, another 4). Decide whether a queued blast
  should hit pieces that came loose after it was fired, or make the pass fire its blasts at once.~~
  **Decided 2026-10-14: it should, and the pass stays as it is.** What made it matter has gone: a
  piece is a rigid chunk (1.10 (1)), so a late blast on a falling one takes its bricks and cuts it
  only where it disconnects it -- 95-135 such hits a `--big --shot` now make 10-13 bodies, all of
  49-499 bricks, none bigger (three runs, 2026-10-13/14). In play a blast lands a tick or two after
  it is fired; the queue only stretches out in this pass, and changing how the pass fires would
  make every number in this section incomparable with the next.

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
* **A `--big --shot` run crashed as it closed** (2026-10-13, one run of nine: signal 11 after the
  whole report had printed; "2 RID allocations of type Mesh were leaked at exit", then
  `~ArrayMesh` with the renderer already gone). Two meshes outlive the scene -- a stand-in built
  on a worker and not collected, or a mesh kept in a static, are the places to look. It costs no
  result; it is not the machine switching itself off.
* **Tests failing on main that are not this area's:** `squad_advance_probe` (flaky),
  `threat_style_probe` (crashes on exit after passing), and since the several-disasters merge
  collapse_probe "a lightning storm" (passed in the one run since main's c5314fa, 2026-10-08) and
  disaster_probe "a soldier in a meteor's ring runs out of it". `disaster_probe` "go over" and
  collapse_probe "rode it" vary with physics run to run. Since 2026-10-13 (found then; main as
  it was, before anything of that day's): collapse_probe "trapped" -- "asked again and again for a
  way there is not, it is trapped", 20.0 s, every run that morning -- the AI's, after its
  navigation changes; passing again by the afternoon, with main's later merges. And
  disaster_probe's "soldiers react": "the ring is gone from the AI's world once it lands" and
  "once out, neither is left" fail on main as it is (2026-10-13, with and without that day's
  stud strength).
  `impostor_probe` "no holes" was on this
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

