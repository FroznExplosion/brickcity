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

> **Superseded for tier 0 by §2.2** — the pieces bob smoothly and snap to nothing. Kept because
> the arithmetic still governs `brick_steps` mode and the wave-gain gate.

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

### 2.2 Superseded for tier 0 — the pieces bob SMOOTHLY

> Everything in §2 is about *where to snap the surface*. Tier 0 no longer snaps it at all.

Each 1x1 keeps its flat top and its level attitude and rides the wave continuously, so the sea
is a field of bricks at slightly different heights rather than a staircase locked to 0.42 m.
This is the one place in the project where the grid should not win: nothing is ever stacked *on*
the water, so nothing needs a piece to land on a course.

What that changes:

* **Nothing is created or destroyed** — still true, and still the point.
* **The drawn surface and `BrickWave.height_at` are now the same number.** The 0.42 m
  disagreement `stepped_at` exists to describe only comes back with `brick_steps` on. A swimmer
  floats exactly at the surface being drawn.
* **Stop-motion goes with the steps.** A 12 Hz hold on a continuous height is a stutter, not a
  brick-film look — that look comes from the pieces being bricks, not from the clock. The two
  are one flag (`WaterSurface.set_brick_steps`, `V` in both test scenes).
* **Terrace width is now a steepness diagnostic, not a design target.** The number still gates
  the wave gain in the probe, because slope is what sets the riser height below.

#### The risers, and why they were the only visible cost

A smooth surface cut into 1x1 cells shows a riser wherever it slopes away from the eye, as tall
as the height change across one stud — **about 3 cm** at this sea state, measured. In world
terms nothing; on screen, everything: at grazing incidence from a metre above the water a 3 cm
face covers twenty-odd pixels and hides the rows behind it, and the sea read as hard dark
stripes. (Shadows were the first suspect and are not involved — the stripes are identical with
the sun's shadow map off. Measuring beat guessing here, twice.)

Two fixes, both in shading rather than geometry, because the geometry is correct:

1. **Side faces are shaded 85% of the way toward the surface they belong to.** Lighting a 3 cm
   riser as a wall is what made it look like one.
2. **Foam reaches the risers too**, at 0.75 strength. Foam started as a top-face effect, which
   made the stripes a *colour* problem as well as a lighting one — a white crest over mid-blue
   risers is a hard edge no normal shading can hide.

Tilting each piece to the local gradient would remove the risers outright. Not taken: a brick
that does not sit level stops reading as a brick.

#### And the same problem from below: no sides at all

Four attempts, and each one was the previous one's fix taken too far:

1. **A full brick of skirt on every piece** — from underwater, a wall of brick
   sides in every direction.
2. **A plate of skirt** — better, and still wrong: a side face one plate tall
   is still a side face, and underwater you are looking ALONG the sheet, so
   every piece showed its edge as a stripe.
3. **No column at all** — the sides collapse into the top plane and stop
   existing. Clean, and it opened a GAP wherever two pieces sat at different
   heights, which on a swell is everywhere.
4. **One seal for the piece** — the drop to the *lowest* neighbour. Closed,
   and wrong in a way that is obvious once seen: all four sides hang to the
   depth only one of them needed.
5. **Per face, per corner** — each bottom corner reaching for its own
   neighbour and for the diagonal. Exact, and it slanted the bottom edge of
   every side, so from below the sheet was a mesh of wedges. A brick has no
   sloped bottom.
6. **Per face, flat.** Both bottom corners of a face go to the same depth:
   the drop to the neighbour that face looks at. Rectangles, no angles.

The diagonal is not a hole in practice. Four pieces meet at a corner POINT
and each wall beside it drops to its own neighbour, so what stays open there
is a slit of zero width. A wedge you can see beats a slit you cannot.

The floor under it is 5 mm rather than zero: the drop is computed from a
float wave and the two pieces either side of a seam do not agree to the last
bit. Above the waterline the floor is a full plate, so the sea still reads as
bricks from a boat.

That needs the top face to be visible from below, and the piece mesh has no
bottom face — it is a top and four sides. So the water draws `cull_disabled`
and flips the normal on back faces. The cost is the back faces of a thin
sheet; the alternative was adding a bottom face to every piece, which is the
same triangles permanently instead of only while submerged.

#### Why the sheet is a PLATE thick and not a brick

Seen from underwater the sheet was a wall of brick sides in every direction, because the minimum
column depth was a full 0.42 m and every piece hung that skirt whether it needed it or not.

The rule that matters is the one already there — a piece reaches down to its lowest neighbour and
no further — and the floor under it is what was wrong. One plate (0.14 m) instead: the sheet is
still sealed wherever the surface slopes, because the drop to the neighbour is what sets the
depth, but where the sea is level there is nothing to see edge-on. Floating bricks are not
stacked ones; only the part under the water has to be there.

The diagonal neighbours are not sampled — that would be eight wave evaluations a vertex — but a
diagonal can only be as far down as the two axis drops put together, so the depth is
`drop_x + drop_z`, a bound rather than a guess, and exact for a plane.

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

### 3.1 Tier 1 — BUILT, as a coarse ring of the same pieces

> The plan below was a separate stepped mesh. What got built is simpler: the
> **same shader, the same wave, the same MultiMesh path**, with the piece
> scaled to four studs and everything inside tier 0's radius dropped.

One sheet that stops at 20 m is a disc of water with a cliff round it, and it
was in every wide shot. The ring runs 19–80 m at 4 studs a piece: 13,225
instances, the same count as tier 0, for sixteen times the area. Painted
studs are off out there — a stud is under a pixel past 20 m, which is the
same argument §7.2 of Terrain makes for the ground's stud tiers.

Three uniforms carry it: `piece_scale` (the piece is a 1x1 plate mesh scaled
in the vertex shader), `inner_radius` (tier 0 covers the join, so the cut is
never seen), and `stud`, which was already the grid pitch. The tier's origin
snaps to its OWN pitch, or the two sheets slide against each other as the
camera moves.

What it does not do is tier 2 or the horizon. 80 m is where the ring stops
and the sky starts.

#### The original plan

### 3.1b Tier 1 — stepped mesh with shader studs, 20–120 m

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

### 3.2 Tier 2 — BUILT: one sheet to the world's edge

Tier 0 is real 1x1 bricks to 20 m, tier 1 coarse bricks to 80 m, and past
that the sea simply stopped. Invisible while the terrain stopped at 56 m, and
glaring the moment it reached 560: from any hilltop the ocean ended in
mid-air.

It is NOT bricks. At 80 m a 0.35 m piece is under a pixel and a brick tier
out there would cost 64k instances to say "blue". It is a static mesh whose
cells double with distance — the same cascade the terrain's coarse tier uses
— displaced in the vertex shader by the one wave function, with no steps, no
studs and no print. **7,224 triangles** for everything from 76 m to the
horizon.

Built once, because the world has edges: the sheet has edges too and neither
has to follow the camera.

#### The seabed texture covered 28 m of a 1,120 m world

Every water tier asks that texture where the shore is, and outside it the
answer is "dry land". It was built over the old fixed 5x5 field — ±28 m —
while tier 1 reaches 80 m and tier 2 reaches the horizon, so both were culled
everywhere except around the origin. **There was no sea in the world and
nothing reported an error.**

It covers the whole authored world now at one texel per 8 studs: a 3,200-stud
world in a 400x400 image. The shoreline is a cull mask and an absorption
depth; neither needs stud resolution.

The hunt for that took three wrong turns, and the last one is worth writing
down: the water is hidden by default in the terrain scene, and the captures
that go looking for water never turned it on. Some of "there is no sea
anywhere" was a switched-off ocean.

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

### 3.6 Tall waves, and the one place the amplitude is allowed to live

Tall waves are wanted, and the brick step is what makes them cheap: a 3 m swell is seven steps of
existing geometry, not a ramp that needs more vertices. Raising the swell needs two things that
are easy to get wrong in opposite directions.

**A taller swell is also a longer one.** The gain scales wavelength as well as amplitude, so
wave steepness — and with it the terrace width, which is §2's whole argument — does not move.
Scaling amplitude alone at gain 2.2 tripled the surface slope and cut the terraces from 2.1
studs to **1.0**: every cell on a different step, the sea reading as a field of sheer walls
rather than as a swell, and precisely the failure §2 warned about for plate quantisation. It is
also the physical answer, since real swell holds H/L roughly constant. Speed follows for free,
because omega comes from the wavelength. The probe now measures the terrace at the gain the
scenes actually run, not only at gain 1.

**The gain belongs to `BrickWave`, not to the shader.** It was added as a `wave_gain` uniform
first, which drew a sea 2.2x taller than the one `BrickWave::height_at` reports — so the drawn
crest and the surface a swimmer floats on were a metre apart, and every buoyancy sample was
wrong. §1's rule is not decoration: anything that changes the surface has to change the one
function. `set_wave_gain` now scales the amplitudes inside `height_at` *and* inside
`uniform_array`, and the shader has no amplitude knob at all. The probe catches the divergence
because it reconstructs the surface from the packed uniforms and compares.

**The shore taper stops the swell driving through the beach.** Amplitude is scaled by
`clamp(depth / 2.5 m, 0, 1)`, so the surf is half height a couple of metres out and flat at the
waterline. Both sides compute it: the shader from the seabed texture, C++ from
`(BrickTerrain::height_at + 1) * brick`, which is the same quantity the texture is built from.
They agree to within the texture's own quantisation rather than by construction, which is the
honest description — `BrickWave::shore_gain` exposes the CPU side so a caller (and the probe)
can reproduce the drawn surface exactly.

One consequence measured immediately: the terrain generator's floor sits barely under the old
1.1 m sea, so the test field's deepest water was **0.82 m**, the taper cut every wave to a third,
and a system built for tall waves had nowhere to put one. Sea level is now a world knob
(`set_sea_level`). A sea that cannot be moved is a generator constant pretending to be a design
one.

The right level is a property of the **seed**, not of the water, and is worth measuring rather
than guessing. Sampled inland on a 140-stud grid:

| seed | min | median | 1.9 m | 2.4 m | 3.0 m |
|---|---|---|---|---|---|
| 20260919 (terrain_test) | 0.42 m | 2.10 m | floods 37% | 53% | 79% |
| 20260921 (heightfield_test) | 1.54 m | 3.08 m | floods 3% | 22% | 47% |

So terrain_test runs at 1.9 m and heightfield_test at 2.8 m, and both get a coast. At 1.9 m the
second seed had 8 cm of water in it.

### 3.6b Two colour fixes the captures forced

**The crest is normalised against the LOCAL wave height, not the open-sea one.** Against the
open-sea amplitude a tapered shore wave never left the middle of the range, so inshore water had
no crest tint and no foam at all — and the surf is exactly where foam belongs. Dividing by
`amplitude × taper` puts a white top on a half-metre shore wave and on a three-metre swell
alike.

**Foam is gated on the ABSOLUTE wave height**, not the normalised one:
`clamp((local amplitude − half a brick) / brick, 0, 1)`. Normalising the crest and then foaming
off it whitened every millpond — a 5 cm ripple reaches "1.0 of its own height" and went white,
and the heightfield bay was a sheet of foam. No whitecaps under half a brick of swell.

**Water stops at the edge of the seabed texture** unless `water_outside_field` says otherwise.
For a streaming world the texture is a window onto an infinite field and there is sea beyond it;
for a bounded one — every test scene — there is not, and saying yes drew water hovering over the
void past the last tile with the sky's ground colour under it. The default is the bounded case,
because that is the one that renders wrong.

**Depth drives absorption**, which is the seabed texture's second job (§5). Without it a bay and
an open ocean are the same flat blue, which is most of what makes a brick sea read as a painted
floor. `mix(albedo, deep_tint, clamp(depth / 6 m, 0, 0.75))`, and in the top-down capture the
shallow bay and the off-field deep water separate immediately.

### 3.7 Under the surface: the column collapses, and the whole view is fogged

Tall water looks like it has one real objection: a column tall enough to make a good crest is,
seen from below, a forest of brick sides filling the screen. **It does not, and the fix for it
was worse than the thing it fixed.**

A column only ever reaches its *lowest neighbour*, never the seabed, so from below what shows is
the underside of a sheet with risers at the steps — a ceiling, not a forest. Collapsing every
column to one brick when the camera went under, which was the first answer, opened a hole at
every step instead: the underwater capture was a shredded ceiling with sky through it. The
column rule is now the same above and below, and the submerged view is the tint alone.

That handles the water. It does not handle the *view*, and this is the part that gives the trick
away: below the surface the sky is still bright, the horizon is still crisp, and the ground 40 m
off is still sharp, so the camera reads as having moved below a pane of glass. §6 planned a
waterline post-process for this. What is built is smaller and needed no pass of its own:
`Underwater` (scripts/underwater.gd) switches the `Environment` to exponential fog at 0.085
density in a green-blue tint, with `fog_sky_affect` at 1 so the sky fogs to the same colour as the
far water. **Removing the horizon is the whole trick.** Ambient goes to a flat underwater colour
and saturation drops slightly. Caustics and light shafts from §6 are still not built.

The split-screen waterline of §6 — the near plane crossing the surface, half the image fogged —
is still not built either. It matters only for the moment the eye is exactly at the surface.

### 3.8 The pieces were 2.9x oversized for six passes

`PieceMeshes.unit_plate()` is a UNIT plate — one METRE on a side, because it
is a mesh and not a brick. The grid it sits on is one stud, 0.35 m. The
vertex shader placed each piece at its cell and never scaled it, so every
piece of water overlapped its neighbours three deep in each direction.

Nothing about that was visible head-on. The studs are painted in WORLD space
from `floor(xz / 0.35)`, so they stayed exactly where they belonged whatever
size the pieces were, and the surface read as correct water. What it actually
explains is a run of symptoms that got treated one at a time:

* the "risers" that read as hard dark stripes and needed their normals shaded
  flat — those were overlapping pieces cutting through each other
* the underside being a thicket of sides no matter how thin the sheet got
* every seal fix helping and never quite finishing

The fix is one line: the piece is `stud` across, which is this tier's pitch in
metres and therefore exactly the size a piece should be. `piece_scale` is gone
with it — tier 1's pieces are 1.4 m because its `stud` is 1.4 m.

**The lesson is the one this file keeps relearning: a world-space pattern will
hide a geometry error indefinitely.** The studs looked right, so the pieces
were assumed right.

### 3.8b The piece grid sat half a cell off the stud lattice

`grid_side` is odd, so `grid_side * 0.5` ends in .5 and every piece was placed
half a cell off the world lattice. The painted studs run on that lattice —
`floor(xz / stud)` — so each stud straddled the corner of four pieces. One
`floor()` on the half-extent.

The studs were right and the pieces were wrong, which is the same shape of
mistake as §3.8: a world-space pattern is not evidence that the geometry
under it is placed correctly.

Water studs are **off** now regardless — a flat-topped water brick is what
this wants, and studs on water say "you could build on this" about a surface
that is a wave. The uniform stays, because the lattice they run on is still
what proves the pieces are aligned.

### 3.9 The water prints too

Nozzle paths across the top of each piece, layer lines down its sides, the
same numbers and the same analytic filter as the ground. Albedo only — no
bead relief, because a ridged normal on a surface this specular is a field of
moving highlights, which is the one thing water does not need more of.

The layers are measured DOWN FROM THE PIECE'S OWN TOP rather than from world
zero, so they ride with the piece as it bobs instead of swimming through it.
The top is loops all the way in: a part one stud across has no room for
infill.

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

### 7.2 Swimming, built

`DebugCamera` takes a `water_probe: Callable` — given a point, return the surface height there —
and a world with no water simply never sets one. The camera does not know `WaterSurface` exists.

Three things make it read as water rather than as flying:

* **Wade, then swim.** Swimming starts when the surface is more than 0.72 body heights above the
  feet — chest deep. Below that the feet still have the floor and the normal walk runs, which is
  what a beach needs.
* **Steering is the look direction**, not the ground plane. W under water goes where you are
  pointed; that single difference is most of what makes a dive feel like a dive.
* **Buoyancy is a spring, not a force and a volume.** The figure is a capsule of unknown density
  in a sea made of bricks. What matters is that letting go of the keys leaves it bobbing with its
  head out, and a spring to `surface − 0.35 × body height` does that in one line. Velocity is
  lerped toward the target rather than set, and the lag *is* the feel of being in water.

Swimming cannot leave the sea: upward velocity is clamped to zero above the float line, because a
figure that can hover a metre over the water by holding SPACE stops the water reading as water.

The continuous surface is what gameplay asks (`WaterSurface.surface_at` → `BrickWave.height_at`),
never the stepped one — a swimmer must not teleport 0.42 m when the bricks take a step.

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

## 9.5 Two tiers, a sea that follows you, and waves that come ashore

Reported: smooth water near the camera, then a ring of blocky water, then
smooth again — and the water "disappearing" constantly.

**What it was.** Three tiers: studded bricks to 20 m, four-stud blocks to
80 m, and a sheet beyond. The sheet was built once round the world's ORIGIN,
hole and fine rings included, and never moved. Anywhere else, the sheet and
the brick tiers drew the same water in the same place and fought for the
pixels; the four-stud tier was the blocky donut; and the tiers were being
switched on and off by the wet-area check as the camera moved.

**Now two tiers.** The studded bricks to 20 m (LOD 0), and the sheet for
everything else (LOD 1 on): no block tier between them. The sheet FOLLOWS the
camera, snapped to its finest cell (1.4 m, out to 40 m, doubling outward), is
filled to the middle, and leaves a hole in the shader exactly where the
studded tier draws — none when that tier is hidden — so there is never water
twice, or none. Rings meet on the coarser ring's lattice; they used to
overlap by up to a cell. Measured at one shore view away from the origin:
671k triangles drawn before, 399k after; the heightfield bench view 814k →
541k and 4.3 → 3.0 ms.

**Waves, after MvsC** (`Docs/Reference/mvs-c.md` §4). One formula, in
`BrickWave::height_at` for swimmers, buoyancy and the collider, and restated
in `water.gdshader`; the probe reproduces the CPU surface from the shader's
uniforms to 1e-7 m.

  * **Groups.** Two long envelopes, 170 m and 240 m, travel with the swell at
    group speed and scale it ±15% each: one stretch heaped, the next calm.
    (The probe measures 0.70 .. 1.28.)
  * **The shore band.** `A(d) · sin(k·d + ω·t + drift)`, phased on DEPTH, not
    on a direction: a crest is a line of equal depth, so it runs along every
    shore and rolls IN toward it whatever the swell is doing. Alive from
    0.3 m deep, full from 1.5 m, gone past 9 m. Depth is the ground BILINEAR
    over the seabed lattice (8 studs), the same corners the texture holds, so
    CPU and shader agree. The probe checks the motion: what is in deeper
    water now is in shallower water (d₂ − d₁)·k/ω seconds later, to 2 mm.
  * **Far LOD caps the wave number.** Each sheet vertex carries its ring's
    spacing; a wave shorter than ~4 samples fades out (and the band, which is
    short, only draws on the finest rings). Under that a crest lands between
    vertices and the surface boils.

Not done yet from the reference: **exposure** (swell reduced behind land,
eight rays per 32 m grid corner) — the next step if sheltered bays should be
calmer than open coast.

## 9.6 Near water that vanished, a band phased on distance, and a LOD view

**The near water vanished**, and came back when the camera turned. The
studded tier draws its pieces round the camera in the vertex shader, but its
culling box was set once, round the world's ORIGIN. Anywhere else the engine
culled the whole tier whenever that box was off screen — and the sheet still
left its hole, so there was no water at all. The box now moves with the
pieces (`WaterSurface.follow`). Four headings over open water 300 m from the
origin all draw it.

**The studded tier is 40 m now** (`WaterSea.NEAR_RADIUS`), up from 20: 52k
pieces. The sheet's finest ring starts at 2.8 m cells and reaches 80 m,
since the studded tier covers the first 40.

**The shore band is phased on DISTANCE to the shore**, not depth. Depth was
MvsC's choice and on this terrain it was invisible: the seabed drops steeply,
every line of equal depth was crammed into a few metres at the waterline, and
the swell moving one way was all anyone saw. `BrickWave.build_shore_field`
builds the distance to the nearest dry ground on the seabed lattice (a
two-pass chamfer, into the seabed texture's G channel), and the band is
`A(s) sin(k s + ω t + drift)`: crests 15 m apart parallel to every coast,
rolling in, reaching 70 m out. Within that reach the swell keeps 35%, so the
band is what the eye follows near a coast. The probe checks the roll: what is
further out arrives nearer (s₂ − s₁)·k/ω seconds later, to 1 cm.

**L** in heightfield_test tints the ground and the sea by LOD level:

| level | ground | sea |
|---|---|---|
| 0 red | the detailed tiles, ±4 tiles round the camera (~±50 m), kept to ±6 | studded bricks, 0–40 m |
| 1 orange | coarse, blocky, a sample every 4 studs (1.4 m), out to 16 tiles (179 m) | sheet, 2.8 m cells, to 80 m |
| 2 yellow | smooth, every 8 studs, 16–32 tiles (179–358 m) | 5.6 m, to 160 m |
| 3 green | smooth, every 16 studs, 32 tiles to the world's edge (560 m) | 11.2 m, to 320 m |
| 4 cyan | — | 22.4 m, to 640 m |
| 5 blue | — | 44.8 m, to the horizon |

(Ground blocks split to sit next to the detail are level 1 whatever ring they
came from.)

## 9.7 The waterline, the seam, calmer shores, leaning tiles and a tile grid

**The waterline.** A studded piece was drawn only where the seabed texel
under its middle was below the sea, and a texel is 2.8 m: the water stopped
short of the sand in places and was cut mid-tile in others. Now a piece (and
a sheet vertex) is dropped only where every seabed corner round it is more
than a metre above the sea. Whole pieces run under the beach, the terrain
hides them, and the waterline is exactly where the ground meets the water.

**The seam between the studded tier and the sheet.** The sheet's hole is now
3 m INSIDE the studded tier's edge, and the sheet sinks 0.18 m there
(`seam_sink`), fading back over the next few metres: the two overlap, and any
slit between them shows water rather than the seabed.

**Calm at the beach.** The swell keeps 15% at the waterline, growing to all
of it by the band's reach (70 m), and the shore band now GROWS out to sea
(ripples at the beach, rollers on the approach) at 0.35 m × gain. Measured by
the probe: the surface moves at most 0.29 m 3–8 m from a shore, 1.53 m 60–70 m
out.

**Leaning tiles** (`tile_tilt`, 0.6). A studded tile's top leans toward the
wave at each corner, and two neighbours share a corner, so the step between
them shrinks by the same factor and the sides are cut to it. It leans fully
(1.0) by 10 m from the camera: past a few metres a riser is under a pixel and a
field of them is moiré — rendered A/B, flat tiles drew rings of dots across the
middle distance and fully leaned ones drew none.

**The tile grid** (`grid_lines`). A thin line on every stud boundary (0.35 m,
the terrain's lattice) over the studded tier AND the sheet, anti-aliased, and
faded out where a stud is under ~6 pixels so it never turns to moiré.

## 9.8 A cone under the feet, ring seams, and a sea that rolls to its shores

**The cone.** A sheet vertex over dry land was collapsed to the node's
origin — harmless while the sheet sat at the world's origin, and since the
sheet follows the camera, that origin is under the player's feet: every
shoreline triangle stretched down to one point below the camera, a cone seen
from underwater. Dry vertices now sink 3 m below the sea WHERE THEY ARE, inside
the terrain.

**Seams at the ring borders.** Each ring faded waves by its own spacing, so
at a border the finer ring kept waves the coarser one had dropped and the two
edges stood at different heights. The fade is now by DISTANCE from the camera
(`lod_base_cell`, `lod_inner_radius` — the same spacing the rings step through,
but continuous), so both sides of a border draw the same height; and every
ring but the last hangs a 1.5 m skirt from its outer edge, which covers the
T-junction cracks where the coarser ring has half the vertices.

**Not still at the beach.** The swell keeps 45% at the waterline (15% read as
a pond) and the shore band a third of its height there. Probe: 0.77 m moving
3–8 m from shore against 1.59 m 60–70 m out.

**The swell rolls toward the shore.** Within 250 m of land each swell
component is phased on distance to the nearest shore — `sin(k·s + ω·t + φ +
drift)` — so on a lake or a bay the sea rolls out from its middle toward every
shore, crests parallel to the coast; past 400 m, in open ocean with no coast in
reach, it is the directional swell, blended between
(`BrickWave.swell_blend_uniform`). A slow per-component drift keeps crests off
exact contour lines. CPU and shader are the same formula; the probe reproduces
the CPU surface from the shader's uniforms to 1e-7 m.

## 9.9 Seams that were a missing row, the world's edge, flat tiles, strength by distance

**The seams at every LOD border were a missing row.** The sheet keeps a cell
in a ring if its nearest corner is outside the ring's inner edge — and
-358.4 + 16 × 11.2 lands a hair INSIDE 179.2 in floating point, so the whole
first row of every ring was dropped: a band of nothing one coarse cell wide.
A tolerance fixes it. Where a ring's outer edge has a vertex the next ring
lacks, the shader gives it the middle of its two neighbours — the line the
next ring draws — so the edges agree exactly, the way the studded tiles'
sides agree with their neighbours. The skirts are gone.

**Past the world's edge is open sea** (`water_outside_field` on both tiers).
It read as dry land, so from the edge looking out the water sank out of sight
— the "gaps one way, fine the other" report.

**Tiles are flat** and only move up and down (`tile_tilt` 0). Past ~10 m a
tile's sides are lit like its top: a side is a pixel or two tall there, and
lit as a wall a field of them is moiré.

**Wave strength by distance to the shore, and nothing else.** No depth
clamp and no shore band (both read as the sea being cut off at the beach):
full in the middle of the water, a quarter where it meets the beach, rising
over 150 m. The swell is still steered toward the nearest shore within 250 m
(9.8). Probe: 0.43 m moving 3–8 m from shore against 0.88 m 60–70 m out; the
swell rolls shoreward — what is a metre further out now is a metre nearer a
moment later to 1.7 cm, against 33 cm the other way.

## 9.10 The sea at the sand

The generator's natural sand is all ground at or below 0.84 m — and the sea
was at 14.9 m (30% of the ground round the origin), 14 m above every beach the
terrain has. A new world's sea now sits AT THE SAND: 0.5 m
(`TerrainWorld.SEA_AT_SAND`, chosen by a drowned fraction of 0), leaving a
strip of sand above the water and the rest of it as seabed. About a third of
the world's ground is still under it. A world file that names its own
fraction keeps it (the city's worlds, 0.20, 10.3 m).

(A first attempt drew a new sand band 1.3 m above wherever the sea was; that
moved the sand instead of the water, and is gone.)

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

## 12. Plan: brick water that flows (after STA's blocky water)

Status: **plan, not built.** Today's water is one wave function over a fixed sea level: the ocean.
Nothing flows, fills a crater, or pours off a cliff. STA designed that for a blocky grid
(`Docs/Reference/sta.md`; STA `Docs/24_CUBED_SPHERE_WATER.md`). This adapts it to bricks and to
the hybrid terrain of Terrain.md §22.

### 12.1 Three kinds of water, by where it is

| where | model | cost (estimate) |
|---|---|---|
| **open sea, and all water at LOD 1+** | today's heightfield water: `BrickWave`, the studded tier, the sheet | as now |
| **near water on HEIGHT tiles** | **2.5D column water**: per stud column a water depth over the ground and four outflow rates ("virtual pipes"). Pools, rivers, a crater filling from the sea, a sheet pouring over a terrace edge | a few adds per active column; 30 k active columns at 30 Hz is well under 1 ms |
| **water inside VOLUME tiles** (caves, under overhangs) | **3D cell automaton**, STA's rules: `mass u16`, `MAX 4096`, down / side / up with the `COMPRESS` term for hydrostatics, gather form, active set only, trapped-air cap in sealed pockets | STA's budget: 100 k active cells ~3 ms on a worker |

The split mirrors the terrain: 2.5D where the ground is 2.5D, 3D only where it is not. A cave
mouth is where column water hands mass to cell water and back.

### 12.2 Water in bricks, and slopes hold water too

* A cell is **one stud by one brick** (0.35 x 0.42 m). Column water keeps its depth in plates, so
  a pool's surface steps by a plate and reads as laid bricks.
* **Slopes and curves hold water.** A column topped by a slope has less room: its capacity is the
  air above the slope surface (`column_surface`, §19.24 of Terrain.md, over the stud). The water
  renders as a flat top at its level, clipped where the level is below the slope (the same
  seabed-texture clip the sea uses), so water lies in the hollow of a curved slope and its
  waterline follows the slope instead of sitting in brick steps above it.
* **Render:** top at the level, corners averaged with wet neighbours so a stream's surface falls
  toward lower water (STA §3); sides where water borders air; a flow vector per column drives
  foam. A column whose outflow drops over a terrace edge gets a **waterfall sheet** on the step.

### 12.3 Who is infinite

* **The ocean:** columns below sea level, open to the sky, never dug, read as full and are never
  written (STA §10.6). A crater breached from the sea fills from them at the rate the breach
  admits.
* **Springs:** authored river sources, finite rate.
* Everything else is finite: a crater lake, a broken water tower, a dammed river. Sand and dirt
  absorb a little each tick, so spills dry.
* **Trapped air** only matters in VOLUME tiles (sealed caves): STA's pocket cap.

### 12.4 Meeting the ocean

Where column water touches the ocean, the ocean is the reservoir and the wave function keeps
drawing it. Column water is calm; near the join the ocean's waves fade over a few metres so the
two meet at sea level.

### 12.5 LOD

* **Sim ring** (~100–150 m from any player): column and cell water tick.
* **Frozen ring:** stored depth, no tick. A stream frozen mid-flow resumes when someone returns
  (STA, Enshrouded).
* **Far:** a per-tile water-top map baked when a tile leaves the frozen ring; the far water sheet
  draws inland water at those levels, so a filled crater lake is visible from a distance.

### 12.6 Build order

1. Column water core in C++ (depth + pipes, active set). Headless gate: mass conserved; a crater
   next to the sea fills to sea level and stops; a pool on a slope runs downhill and settles.
2. Render: plate-stepped top, corner averaging, sides, slope clipping. Gate: water lying in a
   curved slope shows its waterline on the slope face.
3. Ocean coupling and the wave fade; springs; absorption.
4. Swim / buoyancy / flow push read column water where it exists, `BrickWave` elsewhere.
5. Cell water for VOLUME tiles (after Terrain.md §22 step 4); trapped air.
6. Save, multiplayer diffs (STA §10.8–10.9), far water-top map.

### 12.7 Built: pools — dug ground fills from the sea (2026-10-02)

The first step of §12, cut down to what the game needs now: **the sea stays infinite and never
drains; ground dug below it fills by flowing, and the water in the hole is a pool of its own.**

* **What is sea.** A column is sea where the field AS GENERATED (noise and pads, no sculpt —
  `BrickTerrain.generated_plate`) is below sea level. Ground dug below the sea where the world was
  dry is not sea: `build_shore_field` reads it as dry ground, so the sea tiers do not draw there.
  A slope whose face dips under the sea on a natural beach is land, as it was.
* **Pools** (`BrickPools`, `src/brick_pools.cpp`): one water depth per stud column, held in
  32x32 tiles only where something is dug or water has flowed. Virtual-pipe flow (flux per
  neighbour with momentum, damped 0.95 a step), 60 Hz fixed sub-steps, active set only. Sea
  columns are a fixed level, an infinite source and sink. The floor is `column_surface` at the
  column's middle, so a slope holds water and the drawn top is clipped by the slope face.
* **Two ways in.** Through a breach (the hole reaches a sea column): fills in a few seconds and
  ends level with the sea. Through the sand (`set_seep`, default 10 studs, 0.08 m/s): a hole up
  the beach fills slowly to 3 cm under the sea, so it never feeds a loop back into it. A hole
  below the sea far inland stays dry.
* **Drawn** (`water_pools.gd`, `shaders/water_pool.gdshader`): a top per column at its level,
  each corner the mean of the wet columns and sea columns round it — so water coming in through a
  breach is a surface sloping down from the sea into the hole, rising from the floor — and sides
  only toward dry ground. Calm — no wave function — coloured by depth, foam bands travelling in
  the direction of flow (COLOR.ba). Re-meshed at 20 Hz, only tiles whose level moved 4 mm.
* **The sea kept off the pool.** The sea tiers cull on the seabed every 8 studs by the lowest
  corner, so they drew their waves over a hole dug beside them — in the pool, and full in the hole
  the moment it was dug. `BrickPools.sea_mask` is a byte per stud (255 on pool columns that are not
  sea) over a 512-stud window round the camera; `water.gdshader` discards there.
* **Flow speed** 0.3 of gravity in the pipes (`set_flow_speed`): at full strength a crater filled
  in about a second, too fast to see it come in; now several seconds.
* **A leak, fixed.** Water sent to a still column under the wake threshold was never added to it
  (pass 2 only updates ticked columns), and the sea topped the loss up for ever. Any flow now wakes
  the neighbour; a trickle wakes it without resetting its calm count.
* **Wired** through `water_sea.gd`: `refresh_seabed(studs)` tells the pools where the ground
  changed (the editor's strokes via `terrain_changed`; a whole-world change resets them);
  `surface_at` / `submerged_at` answer a pool's level, -INF in a dry dug hole, else the wave. A
  loaded world's sculpt is scanned and its pools settled full before the first frame.
* **Not saved**: a pool is refilled from the sea at load, so only pools fed by the sea come back.
  Nothing digs the heightfield in play yet — the editor's brush does; a weapon crater writes the
  same sculpt and needs only the same `terrain_changed` call.
* **Probe**: `tools/pools_probe.gd` (breach fills, then stills; seep; inland stays dry; poured
  water conserved and flat; dug sea stays sea; seabed dry in the hole). Pictures:
  `tools/pools_shot.gd` (needs a window).
* **The sea lies still against a pool** (2026-10-02). The mask's G channel is how much of its wave
  the sea keeps: 0 against pool water, full 14 studs off (chamfer distance, smoothstep).
  `water.gdshader` scales the whole surface offset by it, so where the two meet the sea is at its
  still level — the pool's — and no crest stands over the calm water. Re-read when pool water
  moves, at most 5 Hz.
