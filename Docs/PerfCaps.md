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
