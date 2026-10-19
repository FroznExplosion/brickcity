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
the flat mesh's 3,102, **6.1x**, built in 1.1 ms for the whole chunk -- 17,104, **5.5x**, since
inside corners are square (§2.2). Standing six metres from a
638-brick building: three bands, 50,274 triangles, and 3,188 of its 8,734 studs.

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

An **inside corner** (`EDGE_INNER_SHIFT`, a bit a side) is a free edge coded `EXTEND` (§2.2).

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

### 2.2 Inside corners are square

Added 2026-10-16. Every free edge used to be bevelled, the foot of a wall on a floor as much as
the corner of a brick in the open. Where one brick stands against another's face and that face
goes on past it, the two bevels met in a notch: a 45-degree V along the foot of every wall, and
where a floor's seam ran into that, a channel with square corners -- hard, dark, and nothing a
real wall has. A face's side is an **inside corner** when, along all of it, a plain brick stands
against the face round the edge (the floor under the wall) **and** a plain brick is diagonally
across, out past this face's plane (the floor in front of it). "Plain": a full box that hides
this face, not furniture, not an authored shape, not see-through -- and nothing of an authored
shape within a cell of it, since a cheese slope or a round brick does not fill its cells and what
closes a square corner beside one is not worked out (the bevel stays there).

Such a side is coded `EXTEND`: no bevel, the face pushed out under the brick round the corner,
which does the same back. Each backs the other, and the corner is square.

What runs into it from the face's other sides is decided in the bake, a corner at a time
(`FaceBake::corner`, `brick::CORNER_*`), because a facet pushed out with the face would stand in
the other brick's bevel. It stops at the brick's own corner, and then:

| Corner | When | Drawn as |
|---|---|---|
| `CAP` | the face round the edge is square there too (a plain brick diagonally below it), or the facet is a groove's | capped across its end: past it is the inside of the brick behind, drawing nothing |
| `MITRE` | the face round the edge is bevelled along the corner | its far edge a bevel short; it meets that bevel in a mitre, as at a plug |
| `COVERED` | the floor's own top is pushed out under that end and shows there | nothing more: a cap would fight it |

And a corner whose *third* edge -- the one between the two faces round it -- is an inside corner
is a plug: the bevels either side of a square foot meet in a mitre. That includes a side whose
facet the face round the edge draws (`CONVEX_QUIET`): its facet runs on to the mitre too.

Each rule here is a slit the gap probe found when it was missing. The room case is new for this:
a floor of 2x4s and two walls of 1x4s meeting in an inside corner, whole and shot through.

### 2.3 What it does not do

* A shaped part's `FLUSH` side has no bevel and no backing. The heap case of the gap probe (every
  palette part, any way they fit) shows no slit from it.
* An authored surface (a round brick, a spiral step) is copied as it is.
* A facet that was one wall of a groove stays shaded as one after the brick that made the groove
  is shot away. It is the rim of a crater.
* An inside corner stays square after the brick that made it is shot away: the face that was
  pushed out under it hangs a bevel past its edge, and the facet behind is seen past that lip.
  Closed, not re-meshed (§1).

### 2.4 A brick resting on bricks had a flat bottom

Tried 2026-10-17 and gone with 2.5: a plain brick's bottom is bevelled like every other edge, so
courses have a groove between them, as real bricks do.

### 2.5 A plain brick is a whole bevelled box

Since 2026-10-18 a plain box brick (its archetype `is_full_box`, its faces not `EDGE_RAW`) is not
built from its bake rectangles and their edge codes at all. `chamfer_faces_into` draws it whole,
as the standalone brick it is -- six faces each drawn in by the bevel, twelve 45-degree facets, eight
corner triangles, under fifty triangles -- carried by its first face in the bake (`ChamferOut::
carrier`), the block's other faces drawing nothing. That is how Brickadia builds its bricks: the
edge is part of each brick's own mesh, and the texture is fitted to it, so the two cannot disagree.

Why. Sections 2.1-2.4 kept a brick's bevels clear of its neighbours' -- faces pushed out under the
next brick, corners plugged into mitres, facets capped, floors, flat bottoms -- and so wherever a
brick met another its corner stayed square: a top's or a bottom's corner stood out over the
upright bevel at every seam, and through a scope that was all anyone saw. A box has every corner
cut, whatever is next to it.

* Two bricks side by side are two boxes: the groove between them is their two facets, meeting
  where the bricks touch. Every box is closed, so there is no slit to see into a brick through
  (the gap probe: none in any view, where the rules above left a few pixels). Where four corners
  meet, the four upright bevels leave a small diamond channel between the bricks, as real ones do.
* Its hidden faces are drawn as well -- the depth prepass buries them -- so a brick shot away
  uncovers the whole brick behind it with no rebuild: the carrier's quads are drawn while the
  block lives, whatever stands against the face (`chamfer_indices`).
* A facet is shaded as a groove's (`uv.y` 1) where the face either side of it is mostly against
  another brick (`ChamferIn::other`).
* With no bevel there are no boxes: the flat faces, as before.

Shaped parts (`EDGE_RAW`) are copied as they were, and a block that is not a plain box still goes
by 2.1-2.3.

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
  above is empty, none on a smooth part, none of furniture's. They are most of what the tier
  draws, so they step down three times -- by the STUD, not the band. A band is a storey: with
  the camera at one end of it every stud on the floor was "within eight metres", and all 8,734
  of a 638-brick building's were drawn bevelled. A band's studs are sorted into three
  MultiMeshes by their own distance (`BrickWorld.split_studs`), again each time the camera has
  moved a metre, and one past the last ring is not drawn at all: 3,188 of the 8,734, standing
  six metres off.

  | Within | Mesh | Triangles |
  |---|---|---|
  | `stud_bevel_radius`, 8 m | `PieceMeshes.stud()`, the rim bevelled | 38 |
  | `stud_round_radius`, 13 m | `stud_plain()`, an octagon | 22 |
  | `stud_radius`, 18 m | `stud_square()`, a tapered square post of the same plan area | 10 |
  | `stud_card_radius`, 70 m | `stud_card()`, a card turned to the camera | 2 |

  A stud is 0.21 m: 36 pixels wide at 8 m, 22 at 13, 16 at 18 (1080p). Square is visibly square
  at 8 m and a bump at 18, which is why it starts at 13; set `stud_round_radius` to
  `stud_bevel_radius` to go straight to it.

  Past 18 m there were none, and a building across a square was a stack of smooth boxes. The
  card (`shaders/stud_card.gdshader`) is the cheapest stud there is: two triangles, turned to
  the camera in the vertex shader and sized to the outline a cylinder of the stud's radius and
  height has from there -- its height from the side, its diameter from straight above -- its
  foot on the stud's front edge so the brick's top never hides it; flat colour, a normal that
  rounds across it and faces up over its top; no print. A band beyond `stud_radius` holds only
  cards and is sorted again every `STUD_RESORT_FAR` (4 m) of camera travel, not every metre.
  Set `stud_card_radius` to `stud_radius` to turn the ring off. The card never tips back more
  than `max_tilt` (0.6 rad) from upright -- from high above, facing the camera, it lay flat on the
  top as a square tile -- and is drawn long enough that it still covers the stud's outline from
  there; a skirt below its foot, hidden by the brick's top, closes the line of sky under it.

  Only an OPEN stud gets a card: one with no live brick over it anywhere up its column in the
  chunk (`get_chunk_studs_open`, a byte a stud in the same order; `split_studs` puts a closed
  one in the first `CLOSED_RINGS` rings only). A roof, a ledge, a floor a blast opened. A
  storey's floor is under the slab above and seen, if at all, through a window -- and in the big
  city it was 95% of the cards: walking past every building held 200,657 stud instances, 9,827
  without them (2026-10-19), and every band of them was re-sent to the renderer every 4 m.
* **Uploads in flight.** The first renderer call that makes a band's stud instances, or changes
  their count or buffer, waits for any mesh upload running on a worker to finish -- a building
  turning to bricks sends its bands that way. Walking the big city that wait was 9-20 ms, on the
  5% of frames with uploads in flight, and showed in the profiler as `step`, `_visit` and
  `_studs` (one cost, three nested functions). So the owner says how many of its uploads are in
  flight (`uploads`, every frame) and while there are any, or any chamfered band of this class's
  own is uploading, no band's studs are touched; `settle` does not wait. Two runs each way: near
  spikes over 5 ms 16 and 34 without, 6 and 8 with; step mean 0.60-0.85 ms against 0.51.

* **Zoom.** Through a scope the world is as near as it looks. The city passes `step` the zoom
  (the unzoomed field of view's tangent over the camera's, capped at 6) and every distance here
  is divided by it: a wall seen through 4x glass is chamfered and studded -- bevelled studs, not
  cards -- as one a quarter as far off. The shaders take the same factor as the `lod_zoom`
  shader global (its inverse; `project.godot`), so the printed detail comes back too.
* **Damage.** The owner patches its flat bands and calls `damaged(chunk, sections)` with the
  bands that patch moved. The chamfered ones are re-indexed and patched the same way
  (`update_chamfer_regions`), and those bands' studs are counted again, two bands a frame.
* **A new bake** numbers its faces afresh. A band carries the serial of the bake it was built
  from; one built from a bake that has gone is not handed over, and one held from it is called
  stale and dropped rather than patched.

`BrickNear.enabled`, `radius`, `stud_radius`, `stud_bevel_radius`, `stud_round_radius` and
`stud_card_radius` are
static and can be set at run time. The city takes `-- --no-near` for a run without the tier.

The workshop does not use the tracker: it is a few hundred bricks an arm's length away, rebuilt
whole on every edit, so every frame is chamfered always (`build_chunk_chamfer_mesh`) and its stud
MultiMesh swaps between the bevelled and the plain stud at `stud_bevel_radius`. Its placement
ghosts -- the held part, a build in hand -- and the city's (`city_placer`) are chamfered the same
way: what is about to be put down has the edges it will have.

**Instanced builds** (`RecipeMesh`: a tree, an item, drawn as many copies of one mesh by
`ImpostorLod`) are built chamfered too. One mesh serves every near copy and `ImpostorLod` gives
it automatic LODs, so the bevels are drawn on the copies close enough to show them and
simplified away on the rest; the node drawing it takes `geo_bevel` from
`RecipeMesh.geo_bevel(mesh)`. A tree is mostly studs: chamfered it is 4,072 triangles to 3,502
flat (+16%; the four kinds +13% to +22%), and its first LOD is no bigger than the flat one's.

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
| `tools/brick_bevel_gap_probe.gd` (not headless) | A magenta core inside every brick, a centimetre in from each face; counted over 280 close views of a tower, the tower shot through, a room's inside corners, the room shot through, a heap of every palette part, and the heap with three bricks in ten gone. A view may show `LONE_PIXELS` (8) and no more. Flat mesh: 39 / 34 / 19 / 7 / 19 / 30 pixels in all (rasteriser cracks, one to four a view). Chamfered, square inside corners (2026-10-16): 23 / 33 / 16 / 33 / 12 / 20, worst view 7 (they were 20 / 19 / 9 / 27 / 14 / 19 bevelled). `GAP_WHERE=1` names the cell and parts behind each view's worst patch. Writes `shots/brick_bevel_off.png` and `_on.png`. |
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
Radeon, GPU ms a frame:

| | tier | `--no-studs` | `--no-bevel` | `--no-near` |
|---|---|---|---|---|
| Studs a band at a time, all 8,734 bevelled | 10.9, 8.7 | | | 5.9, 5.8 |
| Studs in rings (now), 3,188 drawn | 9.4, 9.1 | 8.4, 9.3 | 8.2, 9.1 | 7.7, 8.1 |

So about **1 to 1.5 ms** now where it was 3 to 5. But another chat's gate was running through
every one of those runs -- the `--no-near` column moved 2 ms between the two rows with nothing
in it changed -- so the differences are the size of the noise. It wants taking again on a quiet
machine.

If it is too much: `BrickNear.radius` and the three stud radii are the knobs, and
`-- --no-studs` / `-- --no-bevel` say which half to turn.

## 7. Not done

* **The terrain's studs** have two steps (bevelled on the tiles round the camera, plain to
  `STUD_RANGE`), not these three. The square stud is in `PieceMeshes` for it to use.
* **A setting.** `BrickNear.radius` is a static; the options menu has no row for it.
* **`build_mesh_internal`** (a masked group's mesh, per cell) has no chamfered form. Pieces are
  chunks and go through the bake.
