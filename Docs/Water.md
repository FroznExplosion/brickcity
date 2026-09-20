# Water

Design note. Expands [spec §4](printed-brick-city-spec.md)'s water section into something with
numbers behind it, and revises the parts where the arithmetic disagrees. Nothing here is built.

Water shares its stud system with [Terrain.md §7](Terrain.md) — the same `stud_at`, the same dome
shader, the same colour rule. The differences are that water **moves**, so nothing can be baked,
and that it is **one object**, which turns out to solve the transparency problem on its own.

---

## 1. One wave function, and it lives in C++

Spec §4's strongest line: *one wave function drives everything, evaluated identically on GPU
(visuals) and in C++ (buoyancy, swimming, boats, knockback).* This is a D9 determinism obligation
as much as a rendering one — buoyancy is physics, and physics has to be reproducible.

```
BrickWorld:
    set_wave_state(waves, time)          // amplitude, wavelength, direction, phase, per component
    sample_wave_height(world_xz) -> float
    sample_wave_heights(PackedVector2Array) -> PackedFloat32Array   // batched; the one gameplay uses
    get_wave_uniforms() -> PackedFloat32Array                        // the SAME numbers, for the shader
```

The shader does not have its own constants. It receives `get_wave_uniforms()` and runs the same
expression. One place to change a wave, and no possibility of the render and the swim disagreeing
about where the surface is.

### 1.1 Vertical-only, not true Gerstner — and why

A Gerstner wave displaces **XZ** as well as Y; that horizontal pinch is what sharpens crests. It
also **shears the stud grid**, and a brick world cannot have that: a floating brick, a boat's hull
and the water's own studs all have to sit on the same integer lattice the rest of the city is on
(D5). A sheared surface makes "this piece is on the grid" meaningless.

It also does not buy anything here. The surface is quantised to brick steps (§2), and terracing
destroys crest sharpness before the Gerstner pinch could add any.

**Decision: vertical-only sum of sines, plus wave packets for variety.** Cheaper, trivially
invertible (`height_at(xz)` needs no iteration, which true Gerstner does), CPU/GPU parity is
free, and the grid survives. This is a spec §4 revision.

### 1.2 Ripples are cosmetic and are NOT in the function

Spec §4 wants a small wave-equation sim on a texture around the camera, pushed by debris impacts.
That is a GPU-only feedback texture; replicating it in C++ is a second simulation and a
determinism hazard.

**Ripples are excluded from the gameplay function.** They perturb the normal and add a few
centimetres of displacement for the eye. Buoyancy, swimming and knockback never see them. Stated
here so nobody later tries to make a boat bob on a ripple.

---

## 2. Brick steps, not plate steps

Terrain quantises to plates (0.14 m). Water must not, and the arithmetic says why.

A wave of amplitude **A = 1 m** and wavelength **λ = 12 m** has a mean surface slope of
2πA/λ = **0.52**. The horizontal width of one quantisation terrace is `step / slope`:

| Step | Terrace width | In studs | Reads as |
|---|---|---|---|
| 1 plate (0.14 m) | 0.27 m | **0.76** | every single cell is a different step — noise, not terraces |
| 1 brick (0.42 m) | 0.80 m | **2.3** | a two-to-three-stud terrace. Chunky. The brick-film look |
| 3 bricks (1.26 m) | 2.4 m | 6.9 | too coarse; the wave reads as three plateaux |

**Water quantises to one brick (0.42 m).** That also halves the geometry the stepped tier needs,
because skirts only exist where a step happens (§3.2).

Over ±1 m of wave that is about five terraces from trough to crest — enough to read as a stack,
few enough to read as one wave.

### 2.1 Slopes add, so a stepped sea carries two or three components, not a spectrum

**The arithmetic above is for ONE component, and the first implementation ignored that.** Four
components with amplitudes 1.00, 0.55, 0.28 and 0.14 summed to a slope of **1.67**, giving a
**0.72-stud terrace** — under one stud, which is precisely the "reads as noise, not terraces"
failure this section warns about for plate quantisation. `tools/terrain_probe.gd` caught it.

The general rule falls out of the same sum: **a component whose amplitude is below the 0.42 m step
cannot move the stepped surface at all**, so it spends slope budget and buys no visible detail.
Small-scale texture belongs in the normal and in §1.2's cosmetic ripples, not in the wave sum.

`BrickWave` now carries two crossing swells — A=0.90/λ=13 and A=0.45/λ=21 — summing to slope 0.57
and a **measured 2.1-stud terrace**.

---

## 3. Four presentation tiers

All four evaluate the same wave function at the same world XZ, so the surface is continuous across
every boundary and only the *representation* changes.

### 3.0 Tier 0 — real pieces, 0–20 m

A `MultiMesh` of 1×1 round plates, its instance grid **fixed relative to the camera and snapped to
the stud lattice**. The CPU never rewrites the buffer: it sets one `snapped_origin` uniform and
the vertex shader derives each instance's world XZ, evaluates the wave, snaps to a brick step and
writes Y. Instances are created once, at startup.

| | |
|---|---|
| Radius | **20 m** |
| Instances | π·20²·8.16 = **10.3k** |
| Mesh | 8-sided round plate, no stud geometry (§4), no bottom cap above water = **22 tris** |
| Total | **~226k triangles**, one draw call |

> **Spec §4 says "~50 m radius, ~20k instances" and those two numbers cannot both be right.**
> At 1×1 pitch a 50 m disc is 64k instances, not 20k; 20k is a 28 m disc. Either way, 50 m of
> real pieces is 1.4M triangles and is not affordable. 20 m at 1×1, handing off to tier 1, is.

**Columns.** Each instance stretches down toward the local trough so the steps are solid walls from
the side and from below — spec §4's requirement, and it is one extra scale factor in the same
vertex shader. The column depth is `this cell's step − the lowest neighbouring step`, clamped, so
a flat patch costs a flat plate and only step edges pay for a wall.

**Undersides** get the rib grid as geometry in the bottom cap, enabled only when the camera is
below the surface — a shader branch on a uniform, so the above-water case never pays.

### 3.1 Tier 1 — stepped mesh with shader studs, 20–120 m

Fixed-topology grid mesh, camera-following and stud-snapped, **one independent quad per cell plus
four skirt quads**. The skirts collapse to degenerate triangles in the vertex shader when the
neighbouring cell lands on the same brick step, so they cost vertex work and no rasterisation.

Worst case is 10 tris a cell. Average, from §2's 2.3-stud terrace width, is about
2 + 4·(1/2.3) = **3.7 rasterised tris a cell**.

| Band | Cell | Cells | Rasterised tris |
|---|---|---|---|
| 20–50 m | 1 stud | π(50²−20²)·8.16 = 53.8k | ~200k |
| 50–120 m | 2 studs | π(120²−50²)·8.16/4 = 76.2k | ~282k |

The 2-stud cell beyond 50 m is not a visual compromise — a 0.35 m cell is under two pixels wide at
that range.

Vertex cost is the real bill: 130k cells × 20 vertices = 2.6M vertex invocations, each running the
wave sum. That is fine on desktop and is the first thing to cut on the Deck (drop tier 1's outer
band to 3-stud cells, or pull tier 2 inward).

### 3.2 Tier 2 — banded smooth surface, 120 m+

A coarse grid, one quad per ~4 m, no quantisation in geometry. The brick steps come back as
**colour banding** in the fragment shader — `floor(height / 0.42)` picked off a small ramp. At
120 m a 0.42 m step is under a pixel tall, so drawing it as geometry is drawing nothing.

### 3.3 Tier 3 — the horizon

Whatever the sky and a flat plane can do. Not a system.

### 3.4 Pieces that appear and vanish — the arithmetic

The proposal was that water bricks are **constantly deleted and created** to make a wave, or,
put the other way in the same breath, that *the pieces just start to move up and down*. Those are
two different implementations of one look, and the gap between them is about five orders of
magnitude.

**As literal create/destroy.** Deep-water dispersion gives a wave of λ = 12 m a period of
`T = sqrt(2πλ/g)` = **2.77 s**. Mean vertical speed over a cycle is `4A/T` = **1.44 m/s** at
A = 1 m. A column therefore crosses a 0.42 m brick step `1.44 / 0.42` = **3.4 times a second**:

| Radius | Columns | Block events a second | Per 30 Hz tick |
|---|---|---|---|
| 20 m | 10.3k | 35k | **1,180** |
| 50 m | 64.1k | 220k | **7,340** |

Each event would touch `occupancy`, the `blocks` vector, the face bake, the index buffer and
connectivity. For scale: M2c's measured cascade **step** — a one-off, after three separate
quadratic traps were found and fixed — is 22 ms. This would be that shape of work every tick,
forever, for scenery. **Dead.**

**As pieces that move.** The instance never dies. Its Y is recomputed in the vertex shader from
the wave function every frame (§3.0). Zero CPU, zero allocation, zero state change, and the
`MultiMesh` buffer is written exactly once at startup.

The look survives intact, because everything that *reads* as a piece vanishing is already there:

- **Occlusion does the deleting.** A piece whose step drops below its neighbours is hidden behind
  their columns. It looks like it went away. Nothing happened.
- **At the shoreline**, where water genuinely retreats off the seabed, the instance scales to zero
  in the vertex shader. Still no CPU, still no allocation.
- **The pop is free.** Y is snapped to brick steps (§2), so a piece *jumps* 0.42 m in one frame
  rather than sliding. That discontinuity is the whole brick-film read, and it is a side effect of
  quantisation rather than something to build.
- **Stagger the jumps.** A per-instance hash holds a new step for one or two frames so a whole row
  does not flip together. This is spec §2's stop-motion "on twos", applied to water — the same
  idea, in the vertex shader, for nothing.

What stays true either way: water pieces are **never physics bodies** and never enter the
destruction path (§7). If they should be — a rocket leaving a real hole in the sea — that is
§11 question 1, and it is a presentation hack, not a chunk.

### 3.4b The two gap bugs, and what they had in common

Moving water showed holes. Both causes were the same mistake: **a cell deciding whether a
NEIGHBOUR would cover it, using numbers only it had.**

1. **The stop-motion hold was per cell.** Each cell quantised time with its own hash jitter, so
   neighbours sampled the wave at different instants, disagreed about which brick step they were
   on, and each assumed the other would draw the piece. The hold is now **per row**, so every cell
   a piece can span shares one clock. A plain global `floor(t * 12) / 12` would never have had
   this bug; the per-cell stagger was a step beyond it and that is precisely what broke.
2. **The two rows of a bonded pair had different cut lattices**, because `row_offset` is hashed
   per row. The odd row collapsed expecting the even row to cover it, and the even row was not an
   origin at that cell. A bonded pair now shares the **even row's** lattice, clock and step, so
   the odd row is covered by construction and every agreement check disappeared.

The cost of the second fix is that a bonded pair renders at the even row's step, so a terrace is
two studs deep in Z. That reads as more brick-like, not less.

The general rule, worth keeping: **in a shader that packs, every cell of a piece must derive the
piece from identical inputs.** Any per-cell randomness inside a piece is a hole waiting to happen.

### 3.5 Varied piece shapes on water — mostly not worth it, and the arithmetic says why

[Terrain §6.2](Terrain.md) packs the ground out of 1×2, 2×2, 1×6 and so on, and it works because
the ground is **static**: pack once, bake, never think about it again. Water's terraces move every
frame, so the same packing would have to be recomputed every frame, which is the CPU churn §3.4
just ruled out.

It *can* be done on the GPU. The vertex shader already evaluates the wave for its own cell, so
evaluating it at ~6 neighbours lets the hashed-cut rule from [Terrain §6.3](Terrain.md) run
per-instance: each instance scales to its piece's extent and the ones it swallowed scale to zero.
At 10.3k instances that is ~62k extra wave evaluations a frame, which is affordable.

**The reason not to bother is that there is nowhere to put a big piece.** A piece must be flat, so
it cannot be longer than one terrace, and §2 already measured the terrace at **2.3 studs** for
A = 1 m, λ = 12 m. That admits 1×2 and the occasional 2×2 and nothing else — barely distinguishable
from the 1×1 round plates spec §4 already asks for.

But it is a function of wave steepness, and that is the interesting part:

| Sea state | Slope 2πA/λ | Terrace width | Longest piece that fits |
|---|---|---|---|
| A = 1 m, λ = 12 m | 0.52 | 0.80 m | **2.3 studs** — 1×2, sometimes 2×2 |
| A = 0.3 m, λ = 20 m (calm) | 0.094 | 4.5 m | **12.8 studs** — 1×6 and 2×6 lay flat |

So **calm water would genuinely pave itself with big flat pieces and rough water would break down
into 1×1s**, from one rule, with no authoring. That is a good-looking behaviour and physically
motivated.

**Built, and it was worth it.** A field of 1×1 rounds read as studs rather than as bricks, which
is not the look. `water.gdshader` now runs the packer in the vertex shader: each instance walks
back along its row to find whether it is a piece ORIGIN, and if it is not, it scales to zero. An
origin scales one unit plate to its run and depth. Row pairs bond into 2×N.

Three things made it affordable:

- **The unit plate is the only mesh.** Footprint [0,1]×[0,1] with its origin at the min corner, so
  one mesh covers every size the packer produces. 10 triangles, against 22 for the 8-sided round.
- **The cut lattice is shorter than the ground's** — `PERIOD` 8, `MAX_RUN` 4. §2 measures the
  terrace at 2.1 studs, so a longer piece almost never survives the all-one-step test and asking
  for one only wastes the walk.
- **A collapse is the same operation as the shore cull** already in the shader, so "not an origin"
  costs nothing new.

The piece outline is drawn from the same UV/UV2 contract the ground uses. Without it a 2×4 of
water is a flat rectangle and only the studs suggest it is a brick at all.

---

## 4. Studs on water

Same rule and same dome shader as [Terrain §7](Terrain.md), with two deliberate differences.

- **No stud geometry at any tier, including tier 0.** A round 1×1 plate's own silhouette already
  sells the piece, water is in motion, and a modelled 8-gon stud is +14 tris on a 22-tri
  instance — a 64% cost increase for a profile nobody can read on a moving surface. The dome
  normal in the fragment shader does the whole job.
- **No faked contact shadows.** Terrain §7.4's stadium-shadow is worth it on still ground; on a
  moving, specular, terraced surface it reads as noise. Skip it, and save the two taps.

Colour comes from the water's own albedo, so the "match what they sit on" rule is satisfied by
construction — there is nothing else for a water stud to sit on.

`stud_at` on water is the same equality test: a stud where all four neighbours share this cell's
brick step, a bare tile on the slope between terraces. On a wave that means **studs sit on the
terraces and the step faces are clean**, which is exactly the toy-water look and, again, falls
out of quantisation rather than being authored.

---

## 5. Transparency solves itself

Spec §4 worries, correctly, that Godot sorts transparency per object and not per instance, so a
`MultiMesh` of alpha pieces sorts wrong. Two facts make the problem disappear:

1. **The whole surface is one object per tier.** One `MultiMesh`, one grid mesh. There is nothing
   to sort against anything else.
2. **The pieces are opaque.** Depth comes from colour, not from alpha.

Absorption depth without a depth prepass: the vertex shader samples the **terrain heightmap**
(already a resident texture, [Terrain §2](Terrain.md)) at the cell's XZ to get the seabed height,
and `surface_y − seabed_y` drives the absorption ramp — reds fade first, per spec §4. It is a
texture fetch in a vertex shader, it needs no screen-space anything, and it is correct under
every piece including the ones the camera is looking through the side of.

Dithered alpha stays available as a fallback for the shoreline, where the depth goes to zero and a
hard opaque edge would show.

---

## 6. The waterline split

Two wave samples at the near plane's bottom corners give the surface line's screen-space equation
directly. Below it, the underwater post-process; above it, the normal view. Samples come from the
C++ function, so the line is exactly where the geometry is.

Underwater: depth fog to 20–40 m, colour absorption, light shafts, and caustics **snapped to the
stud grid** — the same `floor(xz / 0.35)` cell maths everything else uses, which is what makes
them read as brick caustics instead of generic ones.

---

## 7. Swimming and buoyancy

| | |
|---|---|
| Character state | three samples — feet, chest, head. Wading, surface swim, dive. Optional air meter |
| Debris | 2–4 sample points per rigid body, batched through `sample_wave_heights` once per physics tick |
| Heavy chunks | sink. A cluster's mass is already tracked (`get_chunk_mass`); displaced volume comes from its block count. Below a density threshold it floats |
| Collision | **none.** Water is not a body. Buoyancy is a force, swimming is a character state, and nothing in Jolt knows the sea exists |

Max depth ~30 m per spec §4, and fog limits visibility to 20–40 m, so the seabed is the terrain
system with a different colour byte and there is no deep-ocean anything.

Physics runs at 30 Hz (`project.godot`), so one batched wave sample per body per tick is the whole
CPU cost: 1000 floating pieces × 3 points × 30 Hz = 90k evaluations a second of a four-term sine
sum. Negligible.

---

## 7.1 Three ways to collide with a wave, and which one we take

An outside analysis framed the overhead-wave problem as three options. Mapped onto what is built:

| | Their option | Us |
|---|---|---|
| **A** | analytical CPU wave formula, no collision shapes | **Built.** `BrickWave::sample_heights`, batched, the same expression the shader runs. §1 and §7 |
| **B** | a pool of `BoxShape3D` colliders snapped to the brick steps every 1/12 s | **Not built, and it is the right next step.** It is the only way a rigid body rests ON the steps rather than being pushed by a force |
| **C** | a dual-layer concave mesh re-baked at 12 fps | **Rejected.** Plan §3: no `ConcavePolygonShape3D` in the destruction path, ever. Re-baking a trimesh BVH at runtime is the documented #1 scaling killer, and doing it twelve times a second is that trap on purpose |

A and B are not alternatives — they answer different questions. A is right for the player,
swimming and buoyancy, and costs nothing. B is right for a barrel that should sit on a crest, and
its cost is repositioning a few dozen box transforms at the stop-motion rate, which is the same
clock the surface already runs on. The pool only needs to cover the active region near the player.

Their stated con for A — that rigid bodies will not bounce or rest on steps without custom forces
— is accurate, and §7 accepts it: debris floats by buoyancy force, not by contact. The case that
actually needs B is something a player can **stand** on, which a brick sea makes plausible in a
way a smooth one does not. That is an open question, not a settled one.

---

## 8. Splashes, and big waves

- **Splashes** are GPU particles using piece meshes that tumble and land, per spec §4. They are
  presentation only and never enter the destruction path.
- **Curling waves** are a separate spline-tube actor filled with instanced pieces, blending back
  into the surface at both ends. Gameplay asks a volume check along the spline, not the wave
  function. This is a set piece, not a system, and should not be built until the flat surface
  holds its budget.

---

## 9. Where water and terrain meet

The shoreline is the only place the two systems have to agree, and they agree on the grid because
both are quantised on the same integer lattice — terrain to plates, water to bricks, both to
multiples of the same 0.14 m.

Two things to get right and neither is hard:

1. **A terrain cell whose terrace is below the wave trough is never drawn as dry.** The tile mesh
   does not need to know; the water surface covers it, opaquely.
2. **The shore band** — cells the wave crosses — is where absorption depth goes to zero and the
   opaque trick shows its seam. That is what the dithered-alpha fallback in §5 is for, on the
   shore band only.

Whether the seabed needs studs is [Terrain §15 question 5](Terrain.md); the answer from here is
yes, unchanged — at 20–40 m visibility they are only ever seen close.

---

## 10. Order of work

Water comes after [Terrain.md §14](Terrain.md)'s T0–T4, because the seabed, the stud shader and
the heightmap texture the absorption ramp samples are all terrain's.

| Step | Deliverable | Gate |
|---|---|---|
| **W0** | The wave function in `BrickWorld`, plus `get_wave_uniforms`. A flat unquantised grid mesh driven by it | CPU and GPU sample the same height at the same XZ to float precision |
| **W1** | Brick-step quantisation, tier 1's collapsing skirts | The terraces read; the skirt count matches §3.1's 3.7 tris a cell within 20% |
| **W2** | Tier 0 pieces, columns, the fixed camera-snapped `MultiMesh` | No buffer upload per frame; no crawl as the camera moves |
| **W3** | Studs (terrain's dome shader, reused), opaque absorption from the terrain heightmap | Water studs align with a brick floated on the surface |
| **W4** | Buoyancy and swimming — samples, states, debris flotation | A collapsing building's debris floats or sinks by mass, deterministically (**G6**) |
| **W5** | Waterline split, underwater fog/absorption/caustics, undersides | The camera can cross the surface at any angle with no seam |
| **W6** | Ripples and splashes, cosmetic only | Physics is byte-identical with ripples on and off |

**W6's gate is the important one.** It is the check that §1.2 was actually honoured.

---

## 11. Open questions

1. **Does the water surface need to be destructible?** It obviously is not, but a brick surface
   that a rocket passes straight through will look wrong. Cheapest answer is a splash and a
   short-lived hole in the instance grid, which is a presentation hack and not a chunk.
2. **Boats.** Vehicles are unscoped (Plan §8 is silent, BuildMode §6.3 defers joints). A boat is
   the first thing that needs more than point buoyancy, and probably wants a swept hull volume.
   Not water's problem until vehicles exist.
3. **Tide or fixed level.** A fixed sea level makes the shore band static and bakeable. A tide
   makes it not. Recommend fixed until something asks otherwise.
4. **Wave amplitude is a gameplay number, not an art one.** §2's whole quantisation argument is
   pinned to A = 1 m, λ = 12 m. If storms want A = 3 m, the terraces get wider in studs and the
   look changes; re-derive rather than re-tune.
5. **What happens to an island that lands in the water?** Currently an island resting anywhere
   stays an island forever (Status.md limitation 6). In water it would need buoyancy per tick
   forever. The same "give islands back to the world" fix covers it, and water makes it more
   urgent.
