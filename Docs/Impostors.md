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

Swaps between rungs stay on the existing hysteresis. Stage 5 adds a dithered crossfade so the swap
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

### Stage 4 — The baker, for player builds

`scripts/impostor_baker.gd`: `SubViewport`, orthographic camera, five faces into one atlas;
queued, one face per frame, cached by build id. `BuildShell` builds past 110 m draw as baked boxes.

**Measure:** bake time per face, atlas memory with 20 builds in the city.

### Stage 5 — Crossfade

Dithered alpha fade over the hysteresis band at 110 m, shell and far instance drawn together for
those few metres. Check shadows: are far buildings inside the directional shadow distance at all?
If not, the far tier casts none and nothing is lost.

### Stage 6 — Octahedral impostors, when trees exist

The baker grows an octahedral mode (§3.3), plus a `visibility_range` setup for tree types:
mesh → import LOD → impostor → culled. Built when the first tree prefab lands, and only if a
forest scene measures fill-bound.

---

## 8. Deliberately not in the plan

* **Impostors for individual bricks, items and loot.** Too small and too many; instancing and
  culling cover them.
* **Animated impostors for enemies.** A lower-poly mesh is cheaper for the number of mechs we have.
* **Interiors.** A card cannot be entered. Far interiors already have the fake-room rung behind
  windows (Interiors.md); the far tier draws lit windows from the seed and nothing more.
* **Terrain.** It has its own heightfield ladder, and Terrain.md shows it is not the expensive half.
* **The Blender add-on** (§1.2).

---

## 9. Open questions

* How many distinct recipes does a real city have? It does not matter for §3.1 (no bake), but it
  decides whether §3.2's cache by recipe hash is worth having.
* Does the brick colour live in the recipe, the material or vertex colour? The far instance has to
  match the near shell at 110 m.
* Is 24 bands per float enough for the tallest tower, or does the mask need both floats per axis?
* Ownership: `city_scene.gd` is shared ground and the `terrain-city` worktree works in it too.
  Stages 1–2 are small changes, but coordinate before starting them.

---

## Sources

* [Imposter Syndrome — Blender Conference 2026](https://conference.blender.org/2026/presentations/4266/)
* [Imposter Syndrome — BCON26 talk video](https://www.youtube.com/watch?v=qBPuZ-1StZc)
* [Imposter Cards add-on thread — Blender Artists](https://blenderartists.org/t/imposter-cards/1639864)
