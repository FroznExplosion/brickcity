# Real bevels and studs on bricks

The 45-degree chamfer the terrain has had since Terrain.md §22.13, on everything else that is
drawn in bricks: buildings, workshop builds, a build's sideways frames, loose pieces. And stud
geometry on all of them, by the workshop's rule. Built 2026-10-08.

What it replaces is the decision recorded in `shaders/brick.gdshader` and Status.md ("shaded, not
built"): a chamfer on every edge of every block was five times the triangles and meant rebuilding a
baked vertex buffer on a distance test. Both objections were right about the mesh as it then was.
§1 is why they no longer hold.

Files: `gdextension/brick/src/brick_world.cpp` (`bake_faces_into`, `chamfer_faces_into`,
`chamfer_section_async` and friends), `brick_types.h` (`FaceBake::edge`, `FaceBake::floors`,
`EDGE_*`), `scripts/brick_near.gd`, `shaders/brick.gdshader` (`geo_bevel`),
`tools/brick_bevel_gap_probe.gd`, `tools/brick_bevel_probe.gd`, the city's `-- --chamfer` pass.

---

## 1. Why it is affordable now

* **The bake is per brick already.** `bake_faces_into` greedy-merges cells into one rectangle per
  run of a brick's face that has the same neighbour, and a face is drawn by
  `alive[owner] && (other < 0 || !alive[other])`. The chamfered mesh is *those faces, in that
  order*, each a few quads instead of one. So a chamfered face is drawn or not by the same rule,
  and damage is still zeros written over its indices. Nothing is re-meshed on a hit.
* **It is a second mesh, not a rebuild.** A band's flat mesh stays exactly as it was, and goes on
  being patched. The chamfered one is built beside it on a worker, uploaded on another, and
  switched in. Crossing the distance threshold costs the building nothing it was not doing.
* **Only near.** Inside `BrickNear.radius` (14 m) of the camera. At 14 m a 13 mm bevel is a little
  over a pixel (17.8 / distance); past that the drawn seam is the edge, as before.

Measured on a 20 x 16 stud, 24-course tower (`brick_bevel_probe`): 18,938 triangles chamfered to
the flat mesh's 3,102, **6.1x**, built in 1.1 ms for the whole chunk. Standing six metres from a
638-brick building: three bands, 50,274 triangles, 8,734 studs.

## 2. The mesh

One face is: the face itself, drawn in by the bevel on each free edge of its brick; a **facet**
on each of those edges, from the drawn-in edge back to the plane of the face round the corner; a
corner triangle where two facets meet. Two faces of a brick each draw the facet they share --
either may be hidden behind a neighbour while the other is seen -- and the two copies are the same
quad, shaded the same way (§4).

### 2.1 Backing, not agreement

Terrain.md §22.13's lesson, taken whole: *a face never asks what the brick next door is doing.*
Every slit a bevel can open is closed by something the face itself draws, decided when the bake is
made and never again. What a face knows is its own four sides (`brick::EDGE_*`, two bits each in
`FaceBake::edge`):

| Side | Means | Drawn as |
|---|---|---|
| `CONVEX` | a free edge of the brick | drawn in, with a facet |
| `CONVEX_QUIET` | a free edge whose facet the face round the corner draws, that one being open to the air for good | drawn in, no facet |
| `EXTEND` | not an edge of the brick: the same face goes on, under another brick or as another rectangle | pushed **out** by the bevel |
| `FLUSH` | part free edge, part not (a shaped part only) | left alone |

and four kinds of backing, each for a slit the gap probe found:

1. **`EXTEND`.** A brick standing on a slab shows, under its own bevelled bottom edge, a 13 mm
   sliver of the slab's top -- which is a face nobody draws, because the brick is on it. The slab's
   *open* top is pushed out by a bevel under the brick. When the brick dies the hidden rectangle
   appears and overlaps the sliver: same plane, same colour, same UV.
2. **Plugs** (`EDGE_PLUG_SHIFT`, a bit a corner). A corner whose other two faces both stand
   against bricks -- every corner of every brick in a wall -- is where three bevels meet and leave
   a triangular hole into the joint. There the face's two facets do not stop short for a corner
   triangle: they run on to the brick's corner and meet in a mitre. No extra triangle.
3. **Floors** (`FaceBake::floors`, runs of cells along a side). Three bricks on one line: a floor
   tile laid up to the foot of a wall that stands on the block beside the tile. The middle brick's
   edge has both of its faces hidden, nobody draws its facet, and the facets either side of it
   stop a bevel apart. Where there is a block against the face round the edge **and** a third
   block diagonally across, the facet gets a floor: the strip of the other face's plane from the
   facet's end out to the edge.
4. **Caps** (`EDGE_CAP_SHIFT`, a bit each end of each side). A facet that stops where its face
   goes on hidden behind another brick, with a brick against the face round the edge as well: the
   bevelled edge runs on between the three as a tunnel. The facet's end is capped across its
   mouth, with a floor under the last bevel of it.

The first version of (3) kept a strip on every *hidden* face along its brick's free edges, drawn
while the contact held. It closed the same slits and cost a plain wall **12x** the flat mesh's
triangles; it is gone.

### 2.2 What it does not do

* A shaped part's `FLUSH` side has no bevel and no backing. The heap case of the gap probe (every
  palette part, any way they fit) shows no slit from it.
* An authored surface (a round brick, a spiral step) is copied as it is.
* A facet that was one wall of a groove stays shaded as one after the brick that made the groove
  is shot away. It is the rim of a crater.

## 3. The near tier (`BrickNear`)

Whoever draws a chunk goes on drawing it as before and says `track(node, chunk, section)` for
each band of mesh: the city for a building's bands and a build's other frames, `IslandManager` for
a piece's mesh and the bands it carried down. `section` is the chunk's drawing section, or -1 for
a mesh of the whole chunk.

* **Chamfered** within `radius` of the nearest point of the band's box, back to flat `MARGIN`
  (2 m) further out. A switch, never a fade: a fade is per object and the object is a storey
  (Terrain.md §22.15). The chamfered mesh and the studs are *children* of the flat band's node --
  they go where it goes and are freed with it -- and the flat band is hidden by taking its render
  layers away, not by `visible`, which would hide them too.
* **Not while it changes.** A band is left alone for `SETTLE_MS` after it was (re)built or last
  moved: a building rebuilding its bands, a piece in the air or still breaking up. A collapse is
  the worst moment to start meshing what is coming down.
* **Studs** within `stud_radius` (18 m, the terrain's `STUD_RANGE`): one MultiMesh a band from
  `BrickWorld.get_chunk_studs_section` -- a stud where a live block's face offers one and the cell
  above is empty, none on a smooth part, none of furniture's. `PieceMeshes.stud()` inside `radius`,
  `stud_plain()` past it.
* **Damage.** The owner patches its flat bands and calls `damaged(chunk, sections)` with the
  bands that patch moved. The chamfered ones are re-indexed and patched the same way
  (`update_chamfer_regions`), and those bands' studs are counted again, two bands a frame.
* **A new bake** numbers its faces afresh. A band carries the serial of the bake it was built
  from; one built from a bake that has gone is not handed over, and one held from it is called
  stale and dropped rather than patched.

`BrickNear.enabled`, `radius` and `stud_radius` are static and can be set at run time. The city
takes `-- --no-near` for a run without the tier.

The workshop does not use the tracker: it is a few hundred bricks an arm's length away, rebuilt
whole on every edit, so every frame is chamfered always (`build_chunk_chamfer_mesh`) and its stud
MultiMesh swaps mesh by distance.

## 4. The shader

`geo_bevel` (an instance uniform, as in `terrain.gdshader`) is 1 on a chamfered mesh: the drawn
seam and the shaded chamfer fade in from `outline_blend_begin` (3 m) to `outline_blend_end` (9 m),
so they do not double up on the geometry.

A facet carries a **negative UV2**. It takes nothing from its face's UV -- no print, no grain, no
seam band -- so the two copies of a facet cannot differ. Its UV says what the shader cannot work
out: `y` is 1 when the facet is one wall of a groove between two bricks
(`EDGE_GROOVE_SHIFT`), and the groove is darkened by `groove_darken`. Without that, two bricks of
one colour in flat light met in a V nobody could see, and the wall read as one slab -- the thing
the drawn seam was there to stop.

## 5. Gates

| | |
|---|---|
| `tools/brick_bevel_gap_probe.gd` (not headless) | A magenta core inside every brick, a centimetre in from each face; counted over 200 close views of a tower, the tower shot through, a heap of every palette part, and the heap with three bricks in ten gone. A view may show `LONE_PIXELS` (8) and no more. Flat mesh: 39 / 34 / 19 / 30 pixels in all (rasteriser cracks, one to four a view). Chamfered: 20 / 19 / 14 / 19. Writes `shots/brick_bevel_off.png` and `_on.png`. |
| `tools/brick_bevel_probe.gd` (headless) | Bands add up to the chunk; every triangle faces its normal; a hit's patches give exactly a fresh build; a stale bake is refused; studs band by band are the chunk's and follow the workshop's rule. |
| `city.tscn -- --chamfer` | A wall a metre and a half off is chamfered and studded; after a hit the bands' index buffers, read back, draw exactly the bricks left; at a hundred metres nothing is held and the picture is the same either way. |
| `city.tscn -- --chamfer --cost [--no-near \| --no-studs \| --no-bevel]` | Frame times, and the renderer's own CPU and GPU time, beside a building while it is shot at and brought down. A timing run. |

While the mesh was being written the gap probe's worst view went 6,956 pixels (no backing but
`EXTEND`) -> 36 (plugs and the first floors) -> 3.

## 6. Cost, measured

`-- --chamfer --cost`, editor closed, no other test running, twice each way (2026-10-08). The
window is vsynced, so a frame is 16.6 ms or more.

| | near tier | `--no-near` |
|---|---|---|
| Looking at it, 120 frames: mean / worst | 16.5 / 22.6, 16.6 / 22.4 | 16.5 / 23.0, 16.4 / 22.1 |
| Twelve shots, 90 frames: mean / worst | 16.6 / 39.6, 16.6 / 37.8 | 16.6 / 37.0, 16.6 / 32.7 |
| Brought down, 360 frames: mean / worst | 16.7 / 25.4, 16.6 / 22.6 | 16.6 / 23.5, 16.7 / 22.7 |

A hit's patch of the chamfered bands: 0.15 ms mean, 0.29 worst (three bands). `BrickNear.step`:
under 0.1 ms a frame with nothing to build. Taking a finished band 0.6-0.9 ms, hanging it
0.1-0.3, a band's studs 0.5. The stud meshes and their material are made when the tracker is,
not by the first band that wants studs: that was 45 ms.

**The renderer is where it is paid, and that number is not settled.** Frame times cannot show it
(a frame is held to 16.6 ms either way), so the pass also reads the renderer's own clock
(`viewport_get_measured_render_time_gpu`). Looking at the building, on this machine's integrated
Radeon: 10.9 and 8.7 ms of GPU a frame with the tier, 5.9 and 5.8 without -- **3 to 5 ms more**.
But another chat's gate was running through every one of those runs, and later runs under the
same load gave 7.2-9.4 ms in all four arrangements (tier, `--no-studs`, `--no-bevel`,
`--no-near`), which is noise the size of the answer. It wants taking again on a quiet machine.
What is being drawn is 50,274 chamfered triangles and 8,734 studs (22 or 38 triangles each, so
the studs are several times the bevels), all within 18 m.

If it is too much: `BrickNear.radius` and `BrickNear.stud_radius` are the two knobs, and
`-- --no-studs` / `-- --no-bevel` say which half to turn.

## 7. Not done

* **Instanced builds** (`RecipeMesh`: trees, items drawn as many copies of one mesh) are flat with
  bevelled studs merged in, as before. A chamfered merge for the near copies is the same call.
* **Placement ghosts** (workshop, `city_placer`) are flat: they are drawn with a ghost material.
* **A setting.** `BrickNear.radius` is a static; the options menu has no row for it.
* **`build_mesh_internal`** (a masked group's mesh, per cell) has no chamfered form. Pieces are
  chunks and go through the bake.
