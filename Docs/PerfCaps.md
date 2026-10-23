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
| Sun shadows | 400 m; brick bands cast only within a range of the camera, shadow proxies past it | `CityScene._set_brick_shadows_near` |
| Building collision | one body per band, so a hit rebuilds only the bands it touched | `BuildingCollision` |
| Terrain | detail tiles, chamfer within 12 m, coarse tiers out | `TerrainStreamer`, Terrain.md |
| AI | the heavy-tick scheduler | `ai_sched` |

## 2. To do, in order

### 2.1 The stud upload stall -- DONE (2026-10-23), see 3

The worst near-tier step on a street walk is 8-17 ms with the cap on or off, and nearly all of it
is handing one storey's stud rings to the renderer: `MultiMesh.set_buffer`, 3.8-11.6 ms for 2,166
studs (`big_city.tscn -- --chamfer --cost --street`, `worst_set_ms`). 2,166 studs is 138 KB; the
copy is not the cost. Growing the buffers instead of reallocating them on every resort made no
difference. Find what the call waits on, and stop it waiting. See 3.

### 2.2 Shadows of the bevelled bands

A chamfered band copies its flat band's `cast_shadow`, so up to 120k bevelled triangles are drawn
again into every shadow cascade. At shadow resolution a bevel is invisible: the flat mesh's
shadow is the same picture. Cast the flat band's shadow (shadows only) and never the chamfered
one's. Add a cascade count / split to Options > Video if the cascades are still a large part of
the frame.

### 2.3 Lights

Fires, the wildfire, lightning and meteors make point lights with no limit on how many are alive,
or on how many of them cast shadows. Cap both, nearest (and in front) first.

### 2.4 Collision far away

A standing building keeps its collision bodies however far it is from anything that moves. Turn
off the bodies of bands nothing is near (the player, a vehicle, an AI, a falling piece) and put
them back before anything can reach them. Cap the active physics pieces by distance as well as by
count.

### 2.5 Texture detail by distance

The underside's hollow runs a per-pixel sphere trace within 10 m; give it fewer steps with
distance (through the zoom, as everything else). The print lines fade out past 7-22 m; give them
a cheaper form past about 15 m (one band of shade, no relief) instead of the whole pattern faded.

### 2.6 Effects

Particles, decals and bullet holes have no global cap. One budget for each, oldest and furthest
dropped first.

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

Left: once a run, the FIRST band shown chamfered took ~11.5 ms (its visit going from uploading to
near, `_show_near`), however small the band -- a first-use cost (most likely its material's
pipeline for that mesh), to be warmed at load. And frames over 25 ms are as many as before (15-25
a walk): most of the walk's long frames are not the near tier's, and the next thing to look at in
them is what else runs in those frames.
