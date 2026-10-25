# Caps and detail by distance

What in the game is limited (a cap: at most so much at once) or thinned with distance (LOD), what
is not yet, and the order the missing ones are being done in. Started 2026-10-23 after the near
tier's cap (BrickBevel.md 3, "The cap") turned out to bound the triangles but not the stutter.

Each item says what it costs, how it is measured, and where the code is. A timing is only taken
with the editor closed (CLAUDE.md), and a pass that times something is named with it.

## 1. What is capped or thinned already

| What | How | Where |
|---|---|---|
| Real bevels near the camera | within 14 m (through a scope's zoom), at most 120k triangles, nearest and in front first; Options > Video | `BrickNear` (BrickBevel.md 3) |
| Stud geometry | 38 / 22 / 10 triangles by the stud's own distance to 18 m, at most 4,000 as geometry, cards to 70 m, open studs only | `BrickNear._sort_studs` |
| Loose pieces | small / large / total live counts | `IslandManager.small_live_max` and the rest |
| Bricks left lying | a count, oldest heaps swept first; Options > Gameplay | `BrickHeap.max_bricks` |
| Bricks in play | a brick budget: quiet storeys furthest from everybody go back to shells | `CityScene` (Space.md 5.3) |
| Printed detail | print lines fade 7-22 m, seams 30-75 m, the shaded bevel 18-55 m | `brick.gdshader`, `print_surface.gdshaderinc` |
| The underside's hollow | sphere-traced within 10 m (`under_parallax_range`), flat past it | `brick.gdshader` |
| Sun shadows | 400 m; brick bands cast only within a range of the camera, shadow proxies past it; a chamfered band casts its flat mesh's shadow; four cascades or two (Options > Video) | `CityScene._set_brick_shadows_near`, `BrickNear._sync_shadow` |
| Building collision | one body per band, so a hit rebuilds only the bands it touched | `BuildingCollision` |
| Terrain | detail tiles, chamfer within 12 m, coarse tiers out | `TerrainStreamer`, Terrain.md |
| AI | the heavy-tick scheduler | `ai_sched` |
| Hit debris | 32 bursts at once, none past 60 m, meshes shared | `MaterialFx._debris` |
| Lights | fixed pools, none shadowed (2.3) | the disasters, `torch_flame` |

## 2. To do, in order

### 2.1 The stud upload stall -- DONE (2026-10-23), see 3

The worst near-tier step on a street walk is 8-17 ms with the cap on or off, and nearly all of it
is handing one storey's stud rings to the renderer: `MultiMesh.set_buffer`, 3.8-11.6 ms for 2,166
studs (`big_city.tscn -- --chamfer --cost --street`, `worst_set_ms`). 2,166 studs is 138 KB; the
copy is not the cost. Growing the buffers instead of reallocating them on every resort made no
difference. Find what the call waits on, and stop it waiting. See 3.

### 2.2 Shadows of the bevelled bands -- DONE (2026-10-23)

A chamfered band copied its flat band's `cast_shadow`, so up to 120k bevelled triangles were drawn
again into every shadow cascade. Now the chamfered mesh casts nothing, and a shadows-only copy of
the flat mesh (`FlatShadow`, the band's own mesh, no upload) casts in its place whenever the band
would (`BrickNear._sync_shadow`). At shadow resolution the bevel is not there. The `--chamfer`
gate checks it ("the chamfered bands cast their flat mesh's shadow, not their own").

Street walk, cap off, two runs each: GPU 12.2-12.8 ms mean against 13.0-13.4 with the chamfered
meshes casting; the worst GPU frame 22-23 ms against 26-29.

The cascades: the same walk drew in 12.9 ms with four, 11.3 with two, 9.2 with no sun shadow. Two
are now an Options > Video row, **Sun Shadow Cascades** (default four, the look as it was): the
near slice as sharp as before (10 m), the far one softer (`BrickcityMenuHost.sun_cascades`, read by
`CityScene._setup_sun_shadows`, put on a city that is up).

### 2.3 Lights -- checked, nothing to cap

The doc's first guess was wrong. Every light the game makes at run time is a fixed pool made once:
fire spread 6, wildfire 4, lightning 2, meteors 8 + 4 flashes, a torch's one, the workbench's one
-- about 25 at the very most, with every disaster going at once -- and none casts a shadow. Forward+
takes that many without a cap.

### 2.4 Collision far away -- checked, capped already

A building past `SHELL_RANGE` (260 m) has no body at all; a shell inside it has one simple body; a
building's brick bodies exist only while it is bricks, which the brick budget (Space.md 5.3) keeps
to what is near somebody; settled debris goes to sleep past 150 m (`IslandManager.SLEEP_RANGE`) and
the live pieces are capped by count. The bodies that are left are static, and Jolt keeps static
bodies apart from moving ones: they cost nothing until something moving comes near. Nothing done.

### 2.5 Texture detail by distance -- measured, not worth doing

The street walk with every print detail switched off -- lines, seams, the shaded bevel, the
underside's hollow and its trace -- drew in 12.39 ms on the GPU against 12.32 with all of it on.
The shader already skips each one past its range (a real branch, not a fade to nothing), and the
underside's trace stops at the first wall it meets. Nothing to save; nothing done.

### 2.6 Effects -- DONE (2026-10-23)

Decals were capped already (hit marks 96, oldest reused; the pools in `VfxPool` and the meteor
shower). What was not: every hit on a brick made a new particle system, with a new mesh and a new
material, and nothing limited how many were alive (`MaterialFx._debris`). Now: at most
`MAX_DEBRIS` (32) bursts at once, the oldest cut short for a new one; none past `DEBRIS_RANGE`
(60 m) of the camera, where a 2 cm chip is under a pixel (the mark and the sound are still made);
one mesh and material per material and colour, shared. `material_probe` checks the cap and the
sharing. A death's burst and a collapse's dust are one each per event, and left as they are.

## 3. The stud upload stall (2.1)

Measured with `big_city.tscn -- --chamfer --cost --street`, the editor closed, every stud
hand-off timed (the ring's `instance_count` and its `set_buffer` apart) and every band visit over
2 ms written down with what it did.

* Size was not it. Of ~1,300 hand-offs on a walk, two to seven were slow, 1-5 ms, and they were
  small ones (80-550 studs). The call was WAITING for the renderer, not doing work.
* The renderer runs on the main thread (the default thread model), so a renderer call made while a
  worker is uploading a mesh waits for that upload. `BrickNear` already held its studs while any
  upload it was told of was in flight (`uploads`, and its own bands' uploads) -- but it decided
  that once, at the top of a step.
* The slow visits were all in the frame a band began uploading its chamfered mesh: the visit that
  started it (8-10.5 ms: its own studs, right after) or a stud resort later in the same step (7 ms).
  A band that started uploading mid-step did not hold the rest of that step. Fixed: `_upload`
  sets `_held` at once.
* The shadow proxies (`BuildingShell.build_mesh`, on a worker) make an ArrayMesh too, and were not
  in `uploads`; they are now (`CityScene`, with the bands' and the pieces').
* Tried first and dropped: growing the rings' buffers in powers of two and drawing part of them
  (`visible_instance_count`) so no resort reallocated. No difference, as the above explains.

| Street walk, cap on, two runs | Worst near-tier step | Worst stud hand-off |
|---|---|---|
| before | 8-17 ms | 3.8-11.6 ms |
| after | 4.6, 5.4 ms | 1.4, 2.0 ms |

Then the ~12 ms show, once or twice a walk (a band's visit going from uploading to near,
`_show_near`). Not a first-use cost, as first guessed: timed in parts, it was all in giving the new
node its mesh, while another upload was in flight -- the same wait. A band whose mesh has come in
now waits to be shown until a step with no upload in flight (`_flying`: the city's and the tier's
own), at most `SHOW_WAIT_MAX` (30) steps; `settle` does not wait. Worst show 12.8 ms -> 0.16-0.19.

Left: frames over 25 ms are as many as before (19-25 a walk). Most of the walk's long frames are
not the near tier's; the next thing to look at in them is what else runs in those frames.

## 4. The long frames of a street walk (2026-10-23)

Section 3 left 15-25 frames over 25 ms a walk that were not the near tier's. `big_city.tscn --
--chamfer --cost --street --long` now prints every frame over 25 ms with the one before and after:
frame time, physics ticks in it, render CPU and GPU, the near tier's step, and the tick's biggest
phases with their parts (`_spike_parts`; new parts: `bd_rest`, `bd_pieces`, `ss_*`, `sp_*`,
`sd_*`, `pn_*`).

Nearly every long frame was a frame with a physics tick in it, and what made the tick long was the
same wait as the studs' (3): a mesh handed to the renderer on the main thread while a worker was
uploading another.

* **Bands** (`bd_upload`, 3-13 ms). A band under 4,000 vertices was uploaded in the tick; most
  bands are. Now every band goes to a worker (`BAND_THREAD_VERTS` 0). Asking first whether any
  upload was in flight was tried and was not enough: terrain and other workers upload too.
* **Panes of a building in bricks** (`sd_panes`, 6-15 ms) and **glass of a shell drawn from its
  bricks** (`gl_here`, 3-8 ms): built and uploaded in the tick, because they ask the bricks which
  panes stand. Now a copy of which cells stand is taken (`BrickWorld.get_solid_cells`, new: 3 ms
  for a big tower) and the panes, and every shell's glass mesh, are made on a worker.
* **Shadow switching** (`ss_shadows`): every node of every building in bricks had its
  `cast_shadow` set every eighth tick, a renderer call each; now only when it changes.
* The new pane and glass jobs count in `BrickNear.uploads`, and the city waits for them, and the
  near tier for its own uploads (`BrickNear.shutdown`), when it quits: a task not waited for kept
  its mesh until after the renderer was gone, and freeing it then crashed on exit.

| Street walk, cap on | Frames over 25 ms | Worst frame | Worst tick part |
|---|---|---|---|
| before | 19-25 | 36-47 ms | bands 13 ms, panes 15, stream 13 |
| after (three quiet runs) | 10-13 | 30-38 ms | panes' copy 3 ms, shadow proxy 2-7 |

Left, and why it is left:
* Most remaining frames over 25 ms have a tick of 1-4 ms: the test window draws at a pinned
  16.6 ms, and a frame a little over that waits for the next one (a 31 ms frame next to a 2 ms
  one). The rest are views over the whole city where the GPU itself takes 20-29 ms.
* A shadow proxy's damage profile (`registry.live_damage_profile`, C++ already) is 2-7 ms on the
  main thread when a big building's proxy is rebuilt. It reads the live bricks; moving it needs the
  same kind of copy as the panes', in the buildings' area.
* The panes' copy could shrink to the outer walls' rows (it copies the whole chunk); 3 ms once per
  building as it turns to bricks.

## 5. A look out over the city (2026-10-23)

`big_city.tscn -- --chamfer --cost --overview`: from the street walk's start, eight directions,
then the dearest one with each kind of node hidden in turn, then the far tier off and on.

The dearest view (down a street of twelve buildings in bricks) drew in 20.5-21.7 ms on the GPU:
653 draws, 4.6M triangles. The buildings in bricks were 16.7 ms of it; the sun's shadow 2.6-2.9,
the far city's MultiMesh and the shadow proxies about 1 each (1 ms is the noise of the method).
Their bands are every brick's faces, out to DEMESH_RANGE (110 m).

**The far tier** (`CityScene._tend_far_coarse`): a building in bricks past `FAR_COARSE_RANGE`
(60 m, past where the print's shaded bevel has faded) that has been quiet for 3 s is drawn as
its coarse stand-in -- `BrickWorld.build_chunk_coarse_mesh`, what a far piece of debris already
is: the outer surface merged across bricks of a colour, brick outlines from its UV2. Built on
the world's worker, uploaded on ours. The bands stay built underneath, hidden, and are what a
hit patches; any change to its bricks (`_remesh`, `_apply_band`, `_take_bands`) shows them at
once, and it goes coarse again once quiet. Back inside `FAR_COARSE_BACK` (50 m).

| Dearest view | GPU | Draws | Triangles |
|---|---|---|---|
| bands | 20.3-20.8 ms | 653 | 4.6M |
| far tier | 11.6-11.8 ms | 191 | 1.65M |

The picture differs at 0.01% of sampled pixels. The pass checks it, and that a hit on a far
building shows at once and that it goes coarse again. Street walk after it: GPU 9.8 ms mean
(was 12.6), worst 17 (was 22-29).

Headless, the renderer is the dummy one, whose meshes are not safe to make on two threads: with
every band, pane and glass mesh on workers it broke its RIDs mid-probe. Headless, those are made
on the main thread as before (`CityScene.worker_meshes`). Two RID errors are left in the
disaster probe from older worker uploads (pieces, shadow proxies); main has the same two.

## 6. Destruction and disasters: what is capped (2026-10-23)

Destruction is capped nearly everywhere already: damage drained 8 hits / 6 ms a tick, solves 4,
cascades 3 ms, promotions queued at 24, live pieces 220 / 60 / 240 and 48 moving, crumbs 1,500,
heaps, impacts, shears, band uploads 60k vertices a tick, shells, demesh and trims all per tick;
collapses at once and in total by the disaster menu (2 / 6).

Disasters: every one makes its lights, particles, decals and sounds once, in pools; fire is hard
capped (900 burning bricks in the city, 300 in a building; the cell fire 48 cells); tornado and
quake pushes go only to the live pieces (the debris cap) and at most 3 buildings pushed over;
lightning, meteors and blasts go through the damage queue. Nothing new is needed.

Measured, the quake (`disaster_probe --only=quake`, new lines): its own tick 0.1 ms, the lateral
checks 6-7 ms and the facade chips 10-11 ms in all over 12 s, the city's tick 2 ms -- of a
"physics tick" the probe reads at 20-23 ms, which is 17.6 ms with no chips and nothing awake. The
probe's tick figure is mostly not the disaster's; it would need splitting before it is a budget.

The disaster probe fails 8 checks, on main as on this branch (none from this work): the meteor
ring left in the AI's world (2), the quake's tall-tower/foundation/authority checks (3: the tower
reads 0.03 of its strength at 0.6 g -- stud strength was raised fourfold since), and snow on a
roof (3).

## 7. AI, pathfinding and the fight's effects (2026-10-25)

AI and pathfinding were already capped: 10 smart agents and 40 directed (ImportanceBudget), 3
promotions a tick (2 from the swarm), tactic decisions 2 ms a tick (AIServices.DECIDE_BUDGET_USEC),
path searches queued best-first in 0.5 ms a tick (NAV_BUDGET_US) with a node budget by distance
(3000-20000), cover searches queued, encounter promotions 3 ms a tick, 8 enemies alive in a wave,
4 allies, support 3 air / 1 tank / 1 mech. Nothing added.

The effects had four nodes made per event with no ceiling. Now capped (`tools/fx_cap_probe.gd`):

- **Damage numbers** (CombatFeedback): up to PELLET_NUMBERS = 5 per body per shot, one per
  pellet; past five the pellets share the five out, so ten hits read as five numbers (the gun
  passes each pellet's damage as `info.each`). At most MAX_NUMBERS = 16 in the air; past it the
  oldest gives up its label. Labels are reused, not freed.
- **Death bursts**: MAX_BURSTS = 8 reused CPUParticles3D, one shared material, the kill's colour
  as the particles' colour. Was a new emitter, box and material per kill.
- **Gun muzzle flashes and trails** (GunInstance): MAX_FLASHES = 12, MAX_TRAILS = 32 over every
  gun, the oldest freed early. No barrel sets either scene yet; this is in place before one does.
- **VfxPool**: an emitter key grows to max_per_key = 16 out at once, arcs to max_arcs = 24, then
  null (callers skip it; shock and radiation arcs check); an unknown key is null, not a crash.
  Shatters keep to max_shatters = 6, the oldest flying one taken over. Its emitter list is empty
  today.
