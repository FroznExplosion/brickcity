# Collapse, LOD and the AI: how it works now, what is wrong, what to build

An audit, 2026-09-28, of how a building is represented at each distance, what happens to its
interior and its pieces when it comes down, how the AI copes with all of it — and the causes found
for five reported bugs. Nothing here is built yet; §5 is the proposed order.

Sources: `city_scene.gd`, `building_registry.gd`, `island_manager.gd`, `room_manifest.gd`,
`staircase_recipe.gd`, `brick_world.cpp`, `ai_nav.h`, the AI tree, and Plan.md §4, Scale.md §4,
Status.md.

---

## 0. Conclusion first

| Reported | Cause found | Confidence |
|---|---|---|
| A collapse is held up by floating stairs | The staircase is **one structural column from the ground to the roof**, joined to every slab. The stress solve counts it as grounding (compression is free), so floors whose walls are gone stay "grounded" through it — and the column itself never falls. | High — read in the code |
| Interior pieces float where a building stood, after it collapsed out of sight | The **fake room rung caches its drawing per room** and only rebuilds when the room's written-off count changes — which only a redraw can change. A collapse that did not blast a room never invalidates it, and the cache survives the building being given back and rebuilt. | High — read in the code; not yet reproduced |
| The far "rectangle" tier shows no damage | `BuildingShell.build_coarse_mesh` takes **no damage** at all; only the banded shell reads the damage profile. | Certain |
| A collapsing building doubles, then vanishes | The hand-over between a building and the piece leaving it is **a fixed two frames**, but the parent's remesh is queued and budgeted and can land much later — both draw the same bricks until it does. | Likely — timing, not yet measured |
| A piece flickers as it separates | The same hand-over, the other way: the piece's mesh is built on a worker and is **sometimes not up after two frames**. The profiler already counts it: "invisible pieces: 18 went blind, worst 3 tick(s)". | High — measured by the existing counter |

And for the AI: soldiers **evade** falling pieces and disaster hazards, but **nothing that falls
hurts them** (falling pieces do not even collide with pawns), a building toppling with one inside
takes no notice of it, and a soldier whose stairs are gone is **stuck on its floor** — the nav will
step down 1.26 m and a storey is 2.66 m.

---

## 1. The ladder as it is

### 1.1 Buildings

| Tier | When | What exists | Damage shown? | Can it collapse? |
|---|---|---|---|---|
| **Nothing** | > 260 m (+30 hysteresis) | recipe + damage record (dead ids, detached ids, per-band profile) | n/a — not drawn | A hit is resolved against the recipe (`_ray_recipes`), which promotes it to bricks — so yes, as bricks |
| **Coarse shell** | 110–260 m | 10-triangle box, 5 collision boxes | **No** (§2.3) | Only by being hit → promoted |
| **Banded shell** | < 110 m | ~830 triangles, course banding, per-band damage mask, fake window panes; same 5 boxes | Approximately (segment mask per band) | Only by being hit → promoted |
| **Bricks, no mesh** | materialised, > 110 m (`DEMESH_RANGE`) | real blocks, collision; drawn by its shell | yes | yes — full solve |
| **Bricks** | hit, or within `PROMOTE_RANGE` 28 m | real blocks, banded meshes, merged collision once quiet | exact | yes — full solve |

A materialised building is **trimmed** back to a shell once it has been quiet for 12 s and is far
enough away (`TRIM_AFTER_MS`); its damage goes into the record (`_record_damage`: dead and
*detached* ids, so a rebuilt building stays broken). This part is sound: **truth is never LOD'd**
(Plan §4.2), and a promoted building rebuilds exactly as it was left.

### 1.2 Rooms

| Rung | When | What exists |
|---|---|---|
| **Shut** | beyond the others | a seed and a diff; nothing drawn |
| **Fake** | outer rooms of a materialised building within 70 m (`ROOM_VIEW_RANGE`) | manifest drawn unlit, **no collision**, cached per room |
| **Drawn** | within 40 m (`ROOM_RANGE`) | manifest drawn, one collision box per item on the building's furniture body |
| **Real** | touched: a blast reaching it, or the player within 1.5 m on its storey | the items as bricks in the building's chunk |

On a **topple**, untouched rooms are **written off** (`write_off_rooms`; `spill_interiors` would
lay them into the wreck later instead) and the furniture body is freed. Items drawn or opened over
a floor that is gone are written off by `RoomManifest.item_supported`.

### 1.3 Pieces

moving → **settled** (frozen, collision merged; slow 0.7 s, support below or — new — touching
something, never while held by wind) → **asleep** (a record, no body, beyond 150 m) → woken inside
120 m. Beyond `FRACTURE_RANGE` (60 m) a landing breaks nothing and pieces fall merged; small
pieces nobody can see are never spawned; the debris cap (80 small / 24 large / 96 total) evicts
oldest first; a piece that is only furniture is deleted where it comes loose unless within 6 m.

---

## 2. The five bugs

### 2.1 Buildings held up by the staircase

Every generated building has a spiral staircase (`_add_staircase`), built **into the building's
own chunk as ordinary structural blocks** (`place_block` without the decorative flag). It is **one
flight for the building's whole height** (`steps_for_courses(courses)`): each step carries a slice
of a central newel and stacks on the one below, and the shaft is exactly one floor cell, its outer
edge clipped to the slab panels around it on every storey.

So the stairs are a column from the foundation to the roof, joined to every floor. The stress
solve's grounding is reachability from the foundation, joints are free in compression
(BrickFailure §1) — and the solver's one guard against interiors holding structure up
(`grounding_flows`: *"a wall is not held up by the chair"*) applies to **decorative** blocks, which
the staircase is not. Blow the walls out and the floors are still grounded **through the stairs**;
bring the building down and the column stays standing in the rubble.

**Fix:** stairs should carry people, not the building.

* Build the staircase's blocks **decorative** — it then never grounds structure, and is itself
  grounded only from below.
* And **break the flight at every slab**: a storey's flight stands on that storey's floor and ends
  under the next, rather than one column running through all of them. Decorative and per-storey,
  a flight falls with the floor it stands on, and nothing is left standing alone.
* One-off cost: a recipe change (Build mode's `staircase_recipe.gd`), a flag in `Fixture.build_into`,
  and a structure-probe run — the damage record keys on block id, so it takes a
  `RECIPE_VERSION` bump.

### 2.2 Interiors floating after a collapse nobody watched

`_sync_fake` redraws a room only when `room.fake_gone != room.gone.size()` — when the count of
written-off items has changed. But items are written off (`item_supported`: *its floor went*)
**inside `draw_items`**, which that same test skips. So once a room's fake has been drawn, a
collapse that took its floor never changes it: `_fake_dirty` is set only when a blast reached a
room (`compromise_rooms`) or the mesh node changed, and a floor failing under stress, away from any
blast, sets neither. The cache lives on the `Room`, not on the fake: `_drop_fake` does not clear
it, and it survives the building being trimmed and promoted again. Come back, and the pre-collapse
drawing is laid where the floors used to be.

**Fix:** invalidate by **structure**, not by item count. Any change to a building's blocks — a
detach, a solve that failed something, a topple, a promotion — resets `fake_gone` for its rooms
(cheapest: a per-building structure version stamped on the cache). Then every fake, drawn and real
room re-checks its items against the floor that exists. Add the missing case to
`--interior-audit`: collapse a building *out of range*, walk back, count items over air.

### 2.3 The rectangle tier hides damage

`_make_shell(id, coarse=true)` builds `BuildingShell.build_coarse_mesh(footprint, courses)` — no
damage argument. A tower with its top blown off is drawn whole from 110 m out.

**Fix (the rule you proposed):** the coarse tier is for **undamaged** buildings only. A damaged
building keeps the banded shell, which already reads the damage profile, at any distance inside
`SHELL_RANGE`. Cost: ~830 triangles instead of 10 for each *damaged* building, and damaged
buildings are few. Toppled ones have no shell at all (their wreck is a piece, or asleep).

### 2.4 and 2.5 Doubling and flicker at a hand-over

When a piece leaves a building, two things have to happen in the same frame: the piece starts
drawing those bricks and the building stops. `OVERLAP_FRAMES` bridges it with a fixed count — the
building is held drawing for two frames (`_remesh_hold`), then remeshed.

* **Flicker** is the piece being late: its mesh is baked on a worker (`_mesh_jobs`), and when that
  takes longer than two frames there is a gap. The counter already exists and reads it:
  *"invisible pieces: 18 went blind, worst 3 tick(s)"* in an ordinary disaster run.
* **Doubling** is the building being late: its remesh is queued and budgeted, and when many things
  break at once it can land long after the piece has fallen away — the same bricks drawn in two
  places, "respawning for a second, then gone".

**Fix:** make the hand-over **an event, not a count.** The building keeps drawing the bricks until
*every piece that took them has a mesh up*, and then — the same frame — hides them. Hiding should
not wait on a remesh at all: the bands already take index patches (a range of indices zeroed is a
brick gone, no rebake), so the building hides the detached blocks by patch the frame the piece
reports ready, and the real remesh follows whenever the budget allows. A cap (say 10 frames) keeps
a stalled job from holding forever. First, **measure**: log per hand-over the frames from spawn to
piece-ready and to parent-hidden, and the worst of each, so the fix is checked by numbers and not
only by eye.

### 2.6 "Buildings floating after a collapse", generally

Two of the causes above, and one fixed today:

1. The staircase column (§2.1) — the standing part of a building that should have fallen.
2. A piece resting on that column counts as supported — the support rays hit the stairs.
3. Pieces frozen in mid-air after 3 support tries — **fixed 2026-09-28** (Disasters.md §12:
   touching-nothing never settles, `hold_awake`, the settled-piece watchdog).

---

## 3. Collapse at every distance — the proposal

The truth already runs at every distance: a hit anywhere promotes the building and the full solve
decides. What does not scale is the **presentation of the fall**. The ladder should be applied to
the collapse itself, by distance from the nearest player at the moment it happens:

| | Near (< 60 m) | Mid (60–150 m) | Far (> 150 m) |
|---|---|---|---|
| Interior | real rooms ride down; drawn/fake written off | **all written off at the moment of collapse** | none — never materialised |
| Items | real ones fall with their floor | deleted | — |
| How it breaks | full solve, fractures on landing | full solve, **no fracture on landing** (exists: `FRACTURE_RANGE`), falls merged | **a few big pieces only**: cut at storey bands, no solve-driven fracture, no piece under N bricks spawned |
| Small debris | spawned, capped | not spawned (exists: discard unseen) | not spawned |
| After it lands | settles, merges | settles, merges, sleeps early | **straight to a sleep record** |
| Shell afterwards | — | banded, damaged | banded, damaged |

Most of the mid column exists already. The far column is the new part: a **coarse collapse** that
splits a building into storey-band sections (the same SEVER-at-a-slab the wreck gate uses, a few
cuts, no per-brick fracture) and lets the pieces fall and go to sleep, so a far collapse costs a
handful of bodies, not hundreds.

**Rule for interiors at collapse (all distances):** the moment any part of a building detaches, every
room whose floor cells are in the detached set is written off or rides as real bricks — never left
registered to where the building used to be. §2.2's structure stamp makes that automatic.

---

## 4. The AI

### 4.1 Weather and disasters (Disasters.md §9)

What works: the soldier tree puts `InDanger > Evade` above fighting, and every disaster feeds the
AI's danger boxes — a meteor's ring, a stroke's leader, the tornado's funnel swept ahead, every
burning fire cell — and fire smoke blocks sight. The tornado shoves pawns; the quake makes them
stumble.

What does not: **no shelter** — soldiers stand in a lightning storm on an open roof as happily as
indoors; lightning's hazard is only the 0.6 s leader, which nobody can outrun. Nobody **reads** the
weather: rain, smoke and dark do not change sight ranges or accuracy. The quake marks only its
collapsing buildings, not the ground-storey band it is undermining.

### 4.2 Buildings collapsing around them

**Around:** a falling piece is a danger box swept 1.5 s along its fall (`Danger.of_piece`), and
soldiers under it move. That is good and it works.

**On them:** nothing. `FALLING_MASK` does not include `PAWN`, so a falling piece passes through a
soldier; the soldier collides with the piece but a character body is not pushed by a rigid one — it
ends up inside the rubble. **There is no crush damage** anywhere: no path from an island's impact
to a pawn's health.

**With them inside:** a building that topples becomes a moving piece with the soldier standing in
it. Nothing notices: no damage, no ride, no fall. The nav is told the area changed
(`nav_changed`), the soldier re-paths, and finds itself inside a wreck.

### 4.3 Stairs gone: stuck

The nav steps up one course (3 plates) and **down at most 9 plates, 1.26 m** (`AINav.MAX_DROP`);
a storey is 19 plates. With its staircase shot out a soldier has no path off its floor; `move_to`
fails, the task gives up after `MAX_STUCK`, and the soldier idles where it is. Rubble can make a
ramp one course at a time, which is the only way down.

### 4.4 What to add

1. **Crush damage.** When a piece's impact (the landing test in `IslandManager` already measures
   speed lost) happens with a pawn inside its box, damage by momentum; a big piece kills. The same
   for a pawn inside a building at the moment it topples.
2. **Pawns are pushed out of pieces**, not left inside: an overlap test after each move, and a
   depenetration step, rather than adding `PAWN` to `FALLING_MASK` (a rigid piece would stop dead
   on an immovable character).
3. **Drops with a cost.** Let the nav take a drop of one storey (19 plates) as an expensive link,
   and apply fall damage over 1.26 m — a soldier cut off by its stairs jumps down a floor, hurt.
   Upward, only rubble ramps.
4. **Trapped is a state.** A soldier with no path anywhere stops wandering and holds: covers the
   approaches it can see, fires from windows. That is a better fight than an idle soldier.
5. **Shelter.** During a lightning storm, prefer cover under a slab (a ray up finds a ceiling);
   stay off roofs; a soldier caught in the open during a stroke's leader drops prone.

---

## 5. Proposed order

Smallest and most certain first; each merges on its own.

| # | What | Why first | Area |
|---|---|---|---|
| 1 | Coarse shell only for undamaged buildings | a one-line rule, certain, visible at once | City (shared) |
| 2 | Fake/drawn room caches invalidated by structure; the out-of-range case in `--interior-audit` | the floating-interior bug | City (shared) |
| 3 | Measure the hand-over (spawn → piece ready → parent hidden), then make it event-driven with index-patch hiding | doubling and flicker; measure first | City / islands (shared) |
| 4 | Staircase decorative and broken per storey | buildings held up by stairs; needs a recipe version bump and a structure-probe run | Build mode (recipe) + City |
| 5 | Crush damage and push-out for pawns | soldiers survive collapses they should not | AI + islands |
| 6 | Storey drops in the nav, trapped state | soldiers stuck on floors | AI (+ C++ nav) |
| 7 | Coarse collapse for far buildings | cost of far collapses | City / islands |
| 8 | Storm shelter, weather-aware sight | AI and weather | AI |
