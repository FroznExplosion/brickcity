# How brick structures actually fail

Research note, September 2026. Drives the stress model in [Plan.md](Plan.md) §3 and the collapse
behaviour in [`printed-brick-city-spec.md`](printed-brick-city-spec.md) §5.

**Conclusion first: the model built in M2 uses the wrong failure mode.** It crushes bricks under
compression, which is how masonry and concrete fail. A stud-connected brick assembly does almost
the opposite, and getting this right makes collapses *simpler* to simulate as well as more correct.

---

## 1. The two numbers that decide everything

| | Force | Source |
|---|---|---|
| Pull two bricks apart (**tension**, per connection) | **3–5 N** | [The physics of LEGO bricks](https://arti.social/projects/the-physics-of-lego-bricks--3c89275c-2a0a-4542-9961-baafbafbf0a2/asset/clutch-power-lego-bricks-require-about-3-to-5-newt--a64eadbb-5820-43d9-9688-b8894ab9525a), [LEGO clutch testing](https://brickarchitect.com/2021/lego-clutch-test-implements-bricks/) |
| Crush one brick (**compression**) | **~950 lb ≈ 4,200 N** before plastic failure | [Gizmodo, how tall can a LEGO tower be](https://gizmodo.com/how-tall-can-a-lego-tower-be-before-it-crushes-itself-5965451) |

**That is a ratio of roughly 1000 : 1.**

A brick joint is, for gameplay purposes, **infinitely strong in compression and very weak in
tension**. And the structural consequence is explicit in the same research: long before a brick
itself fails, *the tower fails as a structure, by buckling*
([KSL](https://www.ksl.com/article/news/utah/science-and-tech/how-tall-could-a-lego-tower-get-before-self-destructing/23259909)).

So a brick tower **never crushes at its base**. It topples, or a section is pushed or pulled off.

---

## 2. What that means for the look, which is what the spec actually cares about

Everything the brick-film aesthetic does follows from the ratio above:

- **Big sections stay intact.** Bricks in a stack are in compression, and compression joints do not
  fail. There is no mechanism by which a wall away from the impact turns to rubble.
- **Crumbling happens only at the point of destruction**, because that is the only place where
  forces are lateral and concentrated enough to shear many joints at once.
- **A toppling tower that strikes something mid-span splits in half there.** The contact applies a
  lateral load at mid-height; that bends the section; bending puts the joints on the far face into
  **tension**, where capacity is a thousandth of compression. It snaps clean at one course, and the
  two halves stay whole.
- **The material is stiff, not ductile.** ABS barely deflects before a joint lets go, so there is
  no progressive sagging. A structure is rigid, then a joint releases, then a whole piece moves.
  **Failure is a plane, not a gradient.**

This is also why brick destruction reads differently from concrete: concrete pulverises, brick
*unzips*.

---

## 3. What M2 got wrong

`solve_stress` flows weight down the support path and breaks a joint when
`load > contact_cells × capacity_per_cell`. That is a **compression** failure test, and it is the
one failure mode a brick assembly essentially never has.

The symptoms were all visible and were misread at the time:

- A 40-course tower sat at 0.46 of capacity and a 357-course tower needed a capacity **7× larger**
  to stand at all (26 vs 190 per cell). That is the model saying "a tall brick tower crushes under
  its own weight", which is false — the real limit is buckling, and it is far taller than 150 m.
- Crushing had to be made to **consume the brick** before collapses would move at all. That was a
  patch for a different problem: a detached island resting on what is beneath it does not move
  because it is *genuinely supported*, not because material needed removing. Vaporising bricks to
  create a gap is a masonry behaviour imported to hide a staging problem.
- The tuned `capacity_per_cell` constants (26 and 190) are not a material property. They were
  numbers chosen to make a wrong failure mode produce a plausible-looking result.

---

## 4. The model to build instead

Four mechanisms, in order of how often they fire.

### 4.1 Compression is free

A joint carrying weight straight down never fails. **Delete the compression capacity test.** A
standing tower is stable forever, which is correct: a real brick tower does not fall over on its
own, and ours should not either.

This removes `capacity_per_cell` as a tunable and removes the need for it to differ by height.

### 4.2 Tension — the governing joint failure

A joint fails when it is asked to *hold something up from above*: overhangs, cantilevers, a section
hanging off the face of a building, anything whose only path to ground runs upward through a joint.

```
tensile force on joint = weight of everything hanging below it with no downward path to ground
capacity               = contact studs x TENSION_PER_STUD
```

`TENSION_PER_STUD` is a real quantity — 3–5 N at print scale — not a tuned constant. **But it must
be converted to game scale, and the conversion is not 1:1.** See §4.5.

The existing depth-DAG solve already computes exactly the right thing; what changes is **which sign
of load fails a joint**. Load arriving at a block from *below* in the support DAG is tension.

### 4.5 The square-cube law makes a game-scale brick building 44x weaker

This was very nearly a silent error. The first version of the constant used the print-scale
figure directly and the result was a structure that could hang *anything* — a wall section with
nothing under it read 0.0000 of capacity and simply would not fall.

Our bricks are the same shape at a much larger size. One stud is **0.35 m in game against 8 mm in
print**, a linear factor of **s = 43.75**. Under that scaling:

- **Clutch force scales with stud cross-section**: x s² = **1,914**
- **Weight scales with volume**: x s³ = **83,740**

So a game-scale assembly is `s` = **43.75 times weaker relative to its own weight** than the toy on
your desk. Concretely, in brick-weights of hanging load a full 8-stud connection can carry:

| | Hanging bricks a full connection holds |
|---|---|
| Print scale (8 mm stud, 2.5 g brick) | **~1,280** |
| Game scale (0.35 m stud) | **~29** |

That second number is the one that produces brick-film-looking collapses: a section can hang by a
corner, but not a big one, and not for long. Deriving it from the first is the only way to keep the
constant physical rather than tuned.

```
tension per contact cell, in mass units
  = (4 N per stud) / (1 mass unit = 1 g = 0.0098 N) / s
  = 408 / 43.75
  ~ 9.3
```

If the in-game scale ever changes (spec §3 leaves it as a range), **this constant changes with it,
linearly.** That dependency is why it belongs in one place with the derivation attached.

### 4.3 Shear at impact — where the crumbling comes from

A lateral impulse across a joint plane pushes a section off its studs. This is the only mechanism
that produces loose bricks, and it is concentrated where the impact is — which is precisely the
look spec §5 asks for: *"break down only near the contact; distant parts stay clustered."*

A blast already destroys blocks in its radius; shear is what should govern the *ring* around it,
turning a band of joints loose without destroying the bricks themselves.

### 4.4 Toppling — a rigid-body problem, not a stress problem

When a building loses the support under one side, it does not crush: its centre of mass leaves the
support footprint and it rotates. **We already model this correctly** — a disconnected island
becomes a `RigidBody3D` and physics does the rest.

The M2 test that "did not move" was a hollow square resting on its own complete perimeter, which is
genuinely one of the most stable shapes there is. That was a badly chosen test, not a bug.

---

## 5. Bricks separate; they do not vanish

The single most visible change: **a failed joint must leave both bricks intact.** ABS does not
pulverise. A brick that comes loose becomes debris — part of a falling island, or a loose brick in
the wreckage — and it can be picked up, shot again, or printed.

That also matters for the game's premise: every brick on screen is a real part. Deleting bricks to
make a collapse look right would quietly break that.

---

## 6. Consequences for the rest of the design

- **`capacity_per_cell` goes away** as a per-structure tuning knob, replaced by one physical
  tension constant plus a shear constant.
- **Collapse becomes cheaper**, not more expensive: the common case (a standing building) has no
  failing joints at all, so the stress solve is mostly confirming stability.
- **Destruction is driven by damage and by impact**, not by self-weight. That fits the activation
  model in Plan §4.4: a building that nobody has shot needs no solve at all.
- **Debris counts go up**, because bricks survive. The island and rubble-settling paths carry that,
  and the degradation ladder (Plan §4) caps it.

---

## 7. Sources

- [The physics of LEGO bricks — clutch force 3–5 N](https://arti.social/projects/the-physics-of-lego-bricks--3c89275c-2a0a-4542-9961-baafbafbf0a2/asset/clutch-power-lego-bricks-require-about-3-to-5-newt--a64eadbb-5820-43d9-9688-b8894ab9525a)
- [Brick Architect — measuring clutch power](https://brickarchitect.com/2021/lego-clutch-test-implements-bricks/)
- [LEGO — the stud and tube principle](https://www.lego.com/en-us/history/articles/d-the-stud-and-tube-principle)
- [Gizmodo — how tall can a LEGO tower be before it crushes itself](https://gizmodo.com/how-tall-can-a-lego-tower-be-before-it-crushes-itself-5965451)
- [KSL — a tower fails by buckling long before a brick fails](https://www.ksl.com/article/news/utah/science-and-tech/how-tall-could-a-lego-tower-get-before-self-destructing/23259909)
- [StableLego: Stability Analysis of Block Stacking Assembly (arXiv 2402.10711)](https://arxiv.org/abs/2402.10711) — force-balance optimisation over block assemblies; method reference for a more rigorous solve than ours if one is ever wanted.
