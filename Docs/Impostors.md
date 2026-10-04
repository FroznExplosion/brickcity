# Impostors: the far city, trees and props as pictures instead of bricks

How the city keeps drawing past the range where real geometry is affordable, and how trees and
props can follow the same ladder. Written after Thomas Murphy's Blender Conference 2026 talk,
*Imposter Syndrome* (sources at the end), and a read of the shell ladder in `city_scene.gd`.

Short answer: impostors are worth building, **but not the kind the talk sells for most of what we
draw.** Our buildings are boxes made from recipes. A box with a painted facade *is* the best
impostor a box can have, and it needs no bake at all. Photograph-style impostors (octahedral cards)
are for the irregular things: trees, rocks, props, player builds that are not boxes.

Decisions this document is written against:

* **everything is done in Godot**, not with the Blender add-on (§1.2);
* **the city is drawn to the horizon**, not cut off at `SHELL_RANGE` (§2);
* **damage must show at every distance** a building is drawn (Collapse.md 2.3 already holds the
  shell ladder to this);
* **collision and shots are not part of this work.** Past `SHELL_RANGE` shots already resolve
  against recipes (`_ray_recipes`), and the coarse tier keeps its bodies. Impostors are drawing only.

---

## 0. Conclusion first

1. **The biggest problem is not cost, it is absence.** Past `SHELL_RANGE` (260 m) a building has no
   node and draws nothing, while `camera.far` is 3000 m. The city has no skyline past 260 m. The
   first stage fixes that for almost nothing.
2. **One MultiMesh of boxes draws the whole far city in one draw call.** Each building is one
   instance: its transform scales a unit box to its footprint and height, its instance data carries
   colour, window pattern and damage. That is the far tier.
3. **The facade is drawn by a shader from the recipe, not baked.** Courses, bands and windows are
   regular; a shader can draw them from four numbers. No atlas, no texture memory, no rebake:
   damage is an update to one instance's data.
4. **The same MultiMesh replaces the coarse tier (110–260 m)** as a draw-call cut. Today every
   coarse shell is its own `MeshInstance3D`.
5. **Baked impostors are for what a shader cannot describe:** player builds (`BuildShell`), badly
   damaged buildings if the shader's damage model proves too coarse, and later trees and props.
   Those get a Godot-side baker: orthographic facade bakes for box-like things, octahedral bakes for
   everything else.
6. **Trees:** for hundreds, Godot's own LOD and MultiMesh are enough. The octahedral tier is worth it
   at thousands, or when forests are seen in depth from high ground (§3.3).

---

## 1. What the talk is, and what we take from it

### 1.1 The technique

An impostor replaces an object with a card: a few triangles textured with pictures of the object
baked beforehand. Murphy's add-on (*Imposter Cards*, Superhive Market) bakes colour, normal and a
packed roughness/metal/AO map, builds a few layered planes per object, and estimates depth with a
tri-planar raycast. Every asset shares one atlas and one shader, so a forest of them is about one
draw call. His own list of limits: not for close-ups, no deforming or animated meshes, the real mesh
is still needed for near LODs, and some shapes bake badly. It exports to Unity and Blender only.

The better-known variant is the **octahedral impostor**: the object photographed from N×N directions
spread over a (hemi)sphere, packed into one atlas; at runtime the card faces the camera and blends
the three nearest views. Colour + normal + depth maps let it take dynamic light and parallax.

### 1.2 Why Godot and not the add-on

* Our buildings are generated at runtime from recipes and damage records. There is no Blender
  scene to bake.
* A damaged building needs a rebake while the game runs. Only an in-engine baker can do that.
* The add-on has no Godot export; its shader would be rewritten anyway, and the shader is the hard
  half.
* Baking in Godot uses the real `brick_material` and the real sun, so the switch between rungs has
  no colour step.

The one fair use of the add-on would be trees modelled in Blender. Once the Godot baker exists it
handles those too.

---

## 2. Where we stand

The building ladder today (`scripts/city_scene.gd`):

| Distance | What draws | Constant |
|---|---|---|
| near, touched | live bricks (materialised) | `TRIM_RADIUS` 70 m decides when they go |
| < 110 m | banded shell, windows with fake rooms behind, collision boxes | `SHELL_DETAIL_RANGE` |
| 110–260 m | coarse shell: a plain box, collision boxes, no windows | `SHELL_RANGE` |
| > 260 m | **nothing** — a recipe and a damage record | `camera.far` is 3000 m |

Hysteresis is 30 m on every edge (`SHELL_HYSTERESIS`); shells are made 4 a tick at ~0.4 ms each
(`SHELLS_PER_TICK`). A damaged building never takes the coarse tier, because a box cannot show
damage — it keeps the banded shell out to 260 m.

The measured cost (Terrain.md §19.5, debug build, Radeon iGPU, 1152x648, worst viewpoint):

| | drawn | calls | GPU frame |
|---|---|---|---|
| big_city, 60 buildings | 686k | 229 | 3.3 ms |
| big_city, 150 buildings | 3.34M | 437 | 10.0 ms |
| 150-building city + 560 m terrain | ~4.5M | ~790 | ~17 ms |

17 ms is the 60 fps line exactly, before materialised bricks and water. That section already names
the lever: building impostors.

---

## 3. Three kinds of stand-in, and which object gets which

### 3.1 The procedural facade box — recipe buildings

A unit box in one `MultiMesh`, one instance per building. Per instance:

* **transform** — the building's `xform`, with the basis scaled to footprint × height. The shader
  recovers the size from the column lengths of `MODEL_MATRIX`, so courses and window spacing stay
  the right size in metres whatever the building's size.
* **`INSTANCE_CUSTOM`** (4 floats) —
  * `x`: window seed (`registry.room_seed_of(id)`), so lit and dark windows match the near shell
  * `y`: intact height as a fraction — the top of a building that has lost its crown
  * `z`, `w`: the per-band damage mask, 24 bands per float (a float holds 24 exact bits). A band
    that is gone draws as a dark gap, or discards on the face it opened.
* **`COLOR`** — the building's brick colour.

The fragment shader draws course lines, band lines and the window grid from local position and
size. Past a few hundred metres that is a handful of ALU per pixel and no texture reads. The roof
is a flat colour.

Why this beats a baked picture here: no atlas memory, no bake time, no rebake, and it is *correct
from every angle*, because the geometry really is the box. A card for a box is a worse box.

### 3.2 The baked facade box — player builds and heavy damage

A `BuildShell` (a player build) is generated from its recipe and has no parameters a shader can
redraw. Bake it once: an orthographic camera in a `SubViewport` renders each of the four sides and
the roof of the real shell into one small atlas (colour + normal). At range it draws as a box, or a
handful of boxes for an L-shape, textured with those faces.

* Size: a 256×256 tile per face is plenty past 110 m; five faces ≈ 0.3 MB uncompressed each.
* Rebake on damage, but only once the building settles, and spread one face per frame.
* Cache by build id, and by recipe hash for identical builds.

The same baker covers a recipe building whose damage the §3.1 mask cannot express, if the gate in
Stage 3 shows one exists.

### 3.3 The octahedral impostor — trees, rocks, props

For irregular, non-box shapes. Baker: `SubViewport`, a camera stepped over a hemi-octahedral grid
(8×8 views to start), 256 px per view into a 2048² atlas holding albedo+alpha and normal+depth.
Shader on a camera-facing quad in a MultiMesh: pick the three nearest views, blend them, offset by
depth, discard by alpha.

When it pays, for trees:

* **Hundreds of trees:** it does not, much. Godot's import LOD, `visibility_range` fades and a
  MultiMesh per tree type already bring hundreds of trees to about one draw call per type and a
  small triangle count. Build that first.
* **Thousands, or forests seen in depth:** it does. Leaf cards overlapping is overdraw, and the
  iGPU is fill-limited; an impostor is one layer of pixels where a tree's leaves are several.
* **Items on the ground:** no. Small; cull them.
* **Enemies at range:** no. Animated impostors need a bake per animation frame; a few mechs are
  cheaper as a lower-poly mesh.

Trees do not exist yet (Terrain.md lists them as authored prefab features), so this is last.

---

## 4. The ladder after this work

| Distance | Recipe building | Player build | Tree (when they exist) |
|---|---|---|---|
| near, touched | live bricks | live bricks | full mesh |
| < 110 m | banded shell (unchanged) | build shell (unchanged) | full mesh < 30 m, import LOD to ~80 m |
| 110–260 m | **far MultiMesh, facade shader** + the existing collision bodies | build shell, then baked box (Stage 4) | octahedral impostor |
| 260 m – fog | **far MultiMesh, facade shader** | **baked box** | octahedral impostor |

Swaps between rungs stay on the existing hysteresis. Stage 5 adds a crossfade so the swap
at 110 m does not pop.

---

## 5. Damage

* **Recipe buildings:** damage already lands in `b.damage_profile`, per band. When it changes, the
  far tier rewrites that instance's `INSTANCE_CUSTOM`. One `multimesh.set_instance_custom_data`
  call, no mesh work, visible the same frame.
* **Toppled buildings** (`b.toppled`): their instance is hidden (zero scale), as the shell ladder
  skips them today.
* **Player builds:** the baked box goes stale. Keep drawing the old bake until the build has been
  quiet for `DEMESH_AFTER_MS`, then rebake it in the background. A distant build changes a few
  seconds late, behind the collapse dust.
* **Never rebake in the same frame as the damage.** Queue it, cap it per tick, in the same shape as
  the other budgets here (a count cap, a clock early-out).

---

## 6. Performance guesses

**These are guesses, not measurements.** Every stage below has a measurement gate on a quiet
machine (no editor open), and these numbers get replaced by what the gate finds.

| Change | Draws now | After | Guess |
|---|---|---|---|
| Far city, 260 m – 3 km | nothing | one call, 12 tris per building | +0.1–0.3 ms for a skyline that did not exist |
| Coarse tier, 110–260 m | one `MeshInstance3D` per building | the same one call | ~100 fewer draw calls with 150 buildings: 1–2 ms CPU in a debug build |
| 150-building bench overall | 437 calls, 10.0 ms | ~300 calls | 10 ms → maybe 7–8 ms GPU |
| Player builds past 110 m | full build shell | baked box | depends on the build: large for detailed builds |
| Trees, hundreds | — | LOD + MultiMesh | ~1–2 ms for the lot, impostors not needed |
| Trees, thousands | — | + octahedral tier | the difference between affordable and not |

The facade shader costs ALU per pixel instead of triangles. Far buildings are small on screen, so
that trade is cheap; the gate checks it at the worst viewpoint anyway.

---

## 7. Stages

Each stage is small, merges on its own, and is measured before the next begins.

### Stage 1 — The far city exists

One `MultiMeshInstance3D` owned by `city_scene.gd`, one instance per registered building, plain
coloured boxes (no facade yet). Instance written when a building enters the far band, hidden
(zero-scale transform) when it gets a shell or topples. Rewritten by the existing stream cursor in
`_stream_shells`, so no new per-frame pass.

**Measure:** `city.tscn -- --bench --buildings=150` from the three §19.5 viewpoints — calls, drawn,
GPU frame, before and after. Screenshot the skyline from the worst viewpoint.

**Done (2026-09-28).** As planned, with one rule added: **far things show what they are.** A box is
the true shape of an intact recipe building only. So past `SHELL_RANGE`:

* an intact recipe building → its far box;
* a **damaged** recipe building or **any player build** → keeps its shell, drawing only, with no
  body (`_shell_far`). Its damage and its shape stay exact at every distance. Stages 3 and 4 move
  these to cheaper forms.

`_ray_recipes` now skips buildings with a shell *body* rather than any shell, so a shot still lands
on a far shell. The far box's colour is the coarse shell's (every recipe building is the same
colour, `BuildingShell.build_coarse_arrays`, which answers §9's colour question), lit like
`brick.gdshader`'s PLA, so there is no colour step at 260 m.

Gate: `big_city.tscn -- --far --buildings=150` — no building undrawn or drawn twice; a far
building shot at 500 m swaps to a body-less shell, takes a shot, and gets its body back inside the
range. 9 ok. `--reach` lands to 480 m; `collapse_probe` 34 ok.

The bench now waits for the shell streamer to settle at each viewpoint. Before this, it sampled
while the 150 placement-time shells were still being freed, and "over the city" swung between
0.66M and 1.7M tris from run to run. Settled, on `big_city`, 150 buildings (ms are noisy: the
editor was open):

| viewpoint | before: tris / calls | after: tris / calls | far boxes |
|---|---|---|---|
| over the city | 3.83M / 257 | 3.83M / 258 | 34 |
| street level | 493k / 171 | 493k / 172 | 37 |
| high and far | 54.5k / 148 | 55.3k / 149 | 73 |

One call and under 1k triangles for up to 73 buildings that used to be missing. Settled, the worst
viewpoint is "over the city" at 3.8M triangles. A coarse shell is about ten triangles, so nearly
all of that is the < 110 m banded shells. Stage 2 can only save draw calls, one per coarse shell;
the triangle weight sits in near-shell detail, which this plan does not touch.

### Stage 2 — The coarse tier joins the MultiMesh

`_make_shell(id, coarse = true)` stops making a `MeshInstance3D` and shows the building's far
instance instead. It keeps making the collision body, which is independent of the mesh.

**Measure:** the same bench; draw calls should fall by roughly the number of coarse shells.
**Gate:** the `--reach` pass still reports damage landing out to `SHELL_RANGE`.

### Stage 3 — The facade shader and damage

`shaders/city_far.gdshader`: courses, bands, windows from instance data (§3.1). Damage mask written
on every `damage_profile` change.

**Gate:** a tower with its top blown off reads as blown off from 110 m, 260 m and 1 km (Collapse.md
2.3's own failure case). Same window pattern either side of the 110 m swap.

**Stages 2 and 3 done (2026-09-28), built together.** What changed from the plan:

* **Damage is a texture, not `INSTANCE_CUSTOM`.** A shell's damage is BuildingShell's segment mask:
  per band, per side, 32 bits. That is up to 128 bits a band, and a tall tower has 240 bands. One
  bit per band would have wiped a whole storey for one hole. So `damage_tex` is RGBA8, one row per
  damaged building, one texel per (band, side) whose bytes are the mask. `INSTANCE_CUSTOM` carries
  courses, the damage row (−1 intact) and the window seed. The profile only changes when a
  building gives its bricks back, and a building with bricks has no far box, so the row is
  written when the box is shown and is never stale.
* **Holes are cut with alpha scissor, not `discard`.** With a raw `discard`, binding the damage
  texture made the whole MultiMesh stop drawing — every building, intact ones included — on the
  Radeon iGPU, with no error printed. `ALPHA` + `ALPHA_SCISSOR_THRESHOLD` draws correctly.
* **Box-filtered, not faded.** Courses, slabs and windows are drawn from running integrals of the
  pattern over each pixel's footprint. A course thinner than a pixel blends into its neighbours
  instead of shimmering, and storeys and windows stay visible as far as they are a pixel or more.
  No LOD switch.
* **The coarse tier takes damaged buildings too** (Stage 2). The old coarse mesh could not show
  damage; the far box can. A coarse recipe shell keeps its node and collision body, but the node
  has no mesh, so the far box draws it (`_shell_box`). What still needs real geometry keeps it:
  a player build, and a *materialised* building, whose damage is in live bricks the profile does
  not have yet.
* **No colour step at 110 m or 260 m any more.** The old coarse tier was one flat tan; the facade
  draws the shell's own course colours.
* The damage profile records **window openings as missing segments** in every damaged band that
  has windows. The shell draws them as holes, and so does the facade.
* **Glass follows the shell's rule:** a storey whose window courses are damaged anywhere, on any
  side, has no glass on any side (`BuildingShell.build_window_mesh`). The facade reads those twelve
  masks for a damaged building, so the two tiers agree across the swap.

Gate, `big_city.tscn -- --far --buildings=150`, 11 ok: one drawer per building; 64 coarse shells
drawn by the far box, all with collision; a tower shot at 500 m with its crown taken off (bands 210–239
of 240 gone) stays a far box with a damage row, takes a shot, is a coarse box with a body at 180 m and
a banded shell inside 80 m. Screenshots `shots/far_top_{130,300,1000}.png`. `--reach` lands to
480 m; `collapse_probe` 50; `--lod`, `--buildshot` 21, `--rooms` 39 pass.

**Measured** (bench, 150 buildings, calls and triangles only: the editor was open, so no frame
times). The bench no longer promotes buildings — a street-level viewpoint materialising its
neighbours at whatever tick made every run a different city — so these are shells only, as
Terrain.md §19.5 defines the bench:

| viewpoint | Stage 1: tris / calls | Stages 2–3: tris / calls |
|---|---|---|
| over the city | 247k / 182 | 247k / 95 |
| street level | 58k / 136 | 45–62k / 56–62 |
| high and far | 71k / 151 | 71–194k / 60–109 |

The ranges are the 110–140 m hysteresis band: which tier a building there holds depends on the path
the camera took, and the bench's three viewpoints are a path.

**What this says about §2's budget.** With nothing materialised, the worst viewpoint is 247k
triangles, not 3.3–3.8M. The millions in §19.5 were brick meshes of buildings the bench happened to
promote, not shells. The expensive thing in this city is materialised bricks; see §7.1.

### 7.1 Where the triangles really are (measured 2026-09-28)

After Stages 1–3 the question was whether the < 110 m banded shells were the next lever. They are
not. Bench, `big_city`, 150 buildings, worst viewpoint ("over the city"), calls and triangles only
(the editor was open, so no frame times):

| what is drawn | tris | calls |
|---|---|---|
| shells only (bench, no promotions) | 247k | 95 |
| the same, sun shadows off | 122k | 88 |
| with 3 materialised buildings nearby (22k + 2 × 6.8k blocks) | 3.83M | 171 |
| the same, sun shadows off | 506k | 79 |
| the same, shadows on with 2 cascades instead of 4 | 2.10M | 124 |

* **A banded shell is cheap:** ~2.7k wall and ~1k window-pane triangles, 2 draw calls. The 20–26
  in view come to about 96k triangles. Moving the intact ones between 75 and 110 m onto the far box
  would save perhaps 25 calls. Not worth doing yet.
* **Materialised bricks in the shadow pass are the cost.** Three brick buildings add ~3.6M drawn
  triangles, and ~3.3M of that is the directional light's shadow cascades drawing their brick
  meshes again, once per cascade (the default is 4). Some of it is the mesher's degenerate
  triangles: a hidden face is kept as a zero-area triangle so a band can be patched in place
  (`brick_world.cpp`). The rasteriser throws them away, but their vertices are still shaded in
  every pass.
* Levers, for whoever owns them: two shadow cascades (−1.7M, a visible change to distant shadow
  quality — a decision, not a fix); a shadow-only proxy for materialised buildings (the brick
  mesh draws no shadow, a shell-shaped caster does), whose damage would show in the shadow only
  once the building gives its bricks back; compacting the degenerates out of a brick mesh once it
  has been quiet for a while.

### 7.2 Shadow LOD (done 2026-09-29)

Big things keep correct shadows at every distance; small things cast cheaply or only near.

* **Sun:** shadows reach 400 m (was the 100 m default), 4 cascades split at 10 / 36 / 120 m, so the
  first cascade is as sharp as before and a tower's long shadow is drawn from far off.
* **Brick buildings:** a materialised building casts with a **shadow-only shell** of itself
  (BuildingShell from the *live* damage profile, or BuildShell for a build), ~3k triangles, holes
  included. Only the bands of its bricks within 15 m of the camera also cast. The decision is per
  band because a tower beside you is mostly far above you. Rebuilt when its alive-brick count
  changes, two a pass.
* **Wreckage:** a piece wider than 2.5 m casts at any range; smaller pieces only inside 30 m.
* **Far boxes** cast again (one MultiMesh, ten triangles a building).
* **Impostor cards** turn to the sun in the shadow pass, and are pushed back along it so a card
  never shadows itself. Small items' cards cast nothing.

`--bench --with-bricks` (new: lets the viewpoints promote), over the city: 3.95M → 2.10M tris,
186 → 145 calls. The rest is the few bands within 15 m.

### Stage 4 — Player builds past SHELL_RANGE (done 2026-09-29)

Not a facade bake but the octahedral baker (§8): an intact build past SHELL_RANGE is a **card**,
baked once from its real bricks (RecipeMesh) and shared by every copy of the same recipe (keyed by
a hash of it). Inside SHELL_RANGE it keeps its own exact shell. A **damaged** build keeps its exact
shell out there too (BuildShell leaves the dead bricks out), rather than rebaking. A copy's card is
made the first time it is needed, so a build that never goes far never pays for a bake.

### Stage 5 — Crossfade (done 2026-09-29)

A banded shell (and its window panes) fades out over 80–140 m with Godot's own visibility-range fade
(FADE_SELF), and its far box is drawn **whole underneath it** for that band, flagged in
`INSTANCE_CUSTOM.w` and inset 6 cm so the shell is always in front. The pixel is
`alpha · shell + (1 − alpha) · box`, a real crossfade. Coarse → banded happens at 130 m and
banded → coarse past 140 m, where the shell has gone, so no swap is ever seen.

How Godot fades is the load-bearing fact, read from its source (4.6): a fading instance is
**alpha-blended**, not dithered; alpha is `smoothstep` of the distance from the camera to the
instance's bounds centre over `[end − margin, end + margin]`. So `end` is 110 and `margin` 30. The
first version assumed a dither over `[end − margin, end]` and drew the box on the complementary
pixels. The gate below caught it: that box z-fought a translucent shell across the band.

Gate: `--far` 19 ok, with Stage 4 (two watchtowers 600 m out on one baked card set, their own
shells closer in, a damaged one on its exact shell) and Stage 5: a banded shell in the band fading
with its box flagged, and **no holes**. Three pictures of a building in mid-band against the sky: as
drawn, with the shell not fading (the reference), and fading with no box. As drawn, 0.0% of the
building is off the reference; with no box, 15%. If an engine update changes how fading works,
this is the check that fails. Screenshots `shots/fade_{70,100,125,150}.png`.

---

## 8. Trees and small items (done 2026-09-29)

### 8.1 The octahedral impostor

`ImpostorBaker` photographs a mesh from 8×8 directions over the upper hemisphere (hemi-octahedral
map) into a colour and an object-space-normal atlas, 1024² (128 px a view), **in one render per
atlas**: 64 turned copies of the object under one orthographic camera. The background is
transparent black, so the result is premultiplied by coverage and the shader divides it back out,
which keeps a dark fringe off every card. `shaders/impostor.gdshader` builds a camera-facing card,
2R across, in the vertex shader and blends the four nearest views, each read where the pixel falls
on that view's own plane (linear, so per vertex). Lit by the baked normals, holes by alpha scissor.

**No swimming, no pop (2026-09-29).** Each view is read where the *view ray* meets that view's own
plane, per pixel. The first version read it where the pixel lay on the card's plane, per vertex,
which put each view's features in a slightly different place, so cards swam as the player moved.
Card against mesh, one tree at 60 m, silhouette overlap is now 0.94 / 0.96 / 0.95 from 2 / 15 / 40 m
up. Across the mesh-to-card range (±5 m round it) a copy is drawn as **both**, dithered into each
other with the same interleaved-gradient noise: the card in its shader, the mesh in a copy of its
material with the fade injected at run time (so `brick.gdshader` is not touched). Mid-band a tree is
2% off its mesh-only picture, against 48% if the mesh faded with no card. In the shadow pass
neither dithers; both cast, one shape.

`ImpostorLod` draws many copies of one mesh in **two draw calls**: the real mesh instanced near, the
card further, nothing past a cull range. It repacks only when something changes tier, and a hidden
copy is in neither buffer. `RecipeMesh` turns any recipe into one real-brick mesh, studs merged,
from a private BrickWorld, so any scene can use it.

### 8.2 Trees

`Trees`: a trunk of round 2×2 bricks (the staircase newel) and a canopy of 4×4 and 2×2 plates and
2×2 bricks in greens, layered so every piece sits on the one below. Plain structure: it stands when
materialised, in compression on the trunk. Four variants, 4.2–6.7 m, 2.8–4.3k triangles.

`Trees.scatter` puts them on a jittered 14-stud grid, thick in noise-field forests and thin in the
open, on grass and dirt (full density), stone (half) and sand (quarter), above the sea, off
building pads, on a trunk footprint with at most a brick of step. Deterministic from the world's
seed, so every scene grows the same trees.

* **City** (terrain mode): each tree is a **registered build**, so destructible like a mini
  building: shot, it materialises, sheds pieces, topples. Intact, it is drawn by its variant's
  ImpostorLod (bricks inside 45 m, cards beyond) and its shell node has no mesh, only collision.
  Shot, it draws itself. Trees grow out to 1200 studs, beyond the city's rock onto the grass round
  it, capped at 800. On the coarse ground ring a tree stands on the field's true height, which the
  coarse mesh matches within a plate or two. The shell streamer's slice now scales with the
  register (a full pass every eight), since trees make it much bigger.
* **Heightfield / terrain editor**: `TerrainTrees`, the same trees drawn the same way, for looking
  at (no brick world to shoot them in), re-scattered half a second after the last edit. Not in the
  terrain bench. 6000 trees cap on the default world.

**Areas.** An ImpostorLod keeps its copies in 128 m squares, each with its own pair of MultiMeshes
and true bounds, so a square out of view or out of every shadow cascade is culled whole; a square
wholly inside or outside a range is decided without a distance check per copy. That is what lets
6000 trees stand in the heightfield scene.

**On the coarse ring.** A city tree past the detail square stands on the ground the coarse tier
DRAWS (`TerrainCoarse.height_at`, which mirrors `build_coarse`: a blocky cell flat at the lowest
of its four corners, a smooth block bilinear through them), not on the field's own height.

Gate: `city.tscn -- --terrain --trees` 8 ok — placed, drawn only by their sets, all four baked,
collision in reach, a tree materialised whole stands, one shot through the trunk comes down.

### 8.3 Small items

`ImpostorItems`, for the weapons and loot code: `kind(key, mesh, material)` once, then
`add` / `move` / `remove` per item on the ground. Each kind is an ImpostorLod with small-item ranges
(mesh inside 12 m, card to 150 m, culled past it), 64 px views, and cards that cast no shadow. A
held item is not in it.

`kind_from_node(key, node)` bakes an assembled thing with its own materials (colour lit by a flat
white ambient; the normal pass is geometry, whatever it is dressed in). Its owner keeps drawing it
up close; `tier_of` says when the card stands in, and a card only takes over once its bake has
landed. 32 px views, about 0.7 MB a kind, because a rolled gun is unique and so is its bake.

`WorldGunPickup` uses it **when the scene has an ImpostorItems** (in the `impostor_items` group):
past 12 m the gun model hides and its card stands in; the rarity beam is untouched, since it is
what reads at range. With no ImpostorItems in the scene nothing changes, which is every scene today;
adding one to the loot range or the game is the weapons area's call.

`tools/impostor_probe.gd`: 24 ok — trees build whole, bake, field of cards; 100 brick guns near,
carded and culled, one moved close becomes a mesh, one removed is gone; the field kept in areas; a
node kind that stays its owner's until baked, then a card in its own material's colour; the card
standing where the mesh stands from three heights; a tree mid-band with no holes.

## 9. Deliberately not in the plan

* **Impostors for individual bricks.** Too small and too many; instancing and culling cover
  them. (Items and loot were on this list; they now have §8.3, because guns on the ground should
  read at range.)
* **Animated impostors for enemies.** A lower-poly mesh is cheaper for the number of mechs we have.
* **Interiors.** A card cannot be entered. Far interiors already have the fake-room rung behind
  windows (Interiors.md); the far tier draws lit windows from the seed and nothing more.
* **Terrain.** It has its own heightfield ladder, and Terrain.md shows it is not the expensive half.
* **The Blender add-on** (§1.2).

---

## 10. Open questions

* Answered: the brick colour is the course table, the same for every recipe building (Stage 1);
  damage needed a texture, not floats (Stage 3); identical builds share a bake by recipe hash
  (Stage 4).
* The crossfade rests on how Godot fades an instance (blended, over [end − margin, end + margin]
  from its bounds centre). Guarded: the `--far` gate's no-holes check fails if that changes.
* The heightfield scene's own coarse tier moves with the camera, so its trees stand on the field's
  true height; past the detail square they can sit a little off its coarse ground. At the ranges
  that happens they are cards.

---

## Sources

* [Imposter Syndrome — Blender Conference 2026](https://conference.blender.org/2026/presentations/4266/)
* [Imposter Syndrome — BCON26 talk video](https://www.youtube.com/watch?v=qBPuZ-1StZc)
* [Imposter Cards add-on thread — Blender Artists](https://blenderartists.org/t/imposter-cards/1639864)

## ImpostorLod's sorting in C++ (2026-10-03)

The per-copy half of `ImpostorLod` — transforms, wanted flags, tiers, squares, the distance sort and
the MultiMesh buffer packing — moved to C++ (`ImpostorSet`, `gdextension/brick/src/impostor_set.cpp`).
The script keeps the nodes, meshes, materials and the bake; its public API is unchanged, so the
city, `ImpostorItems` and `TerrainTrees` did not change. Heightfield scene, 6,000 trees, a full
update of every set while moving: 2.0 ms mean / 3.2 ms worst in GDScript, 0.21 / 0.37 ms now
(other Godot runs alongside both), same near and far counts. `impostor_probe`: 25 ok before and
after, identical tier counts.

Seen while testing, not caused by this: `city.tscn -- --trees` fails "trees were placed -- 0" with
the old script too; the city's `_place_trees` never runs in that pass.
