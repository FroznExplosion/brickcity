# Natural disasters

Design and plan for the disaster system: four built now (**meteor shower, lightning storm, fire,
tornado**), the rest deferred with what each one is waiting on.

Written 2026-09-26. Nothing here is built yet; [Status](Status.md) will say when it is.

Decisions this document is written against:

* **Random, started by the player.** One key starts a disaster; which one is rolled. No scheduling,
  no match objectives yet.
* **Small city only** (`scenes/city.tscn`). `--big` / `big_city.tscn` gets none. Measured on the
  small city first because that is where a disaster's cost can be read against a known baseline.
* **No building changes.** Heights and footprints stay as they are (the scale discussion is in
  [Scale.md](Scale.md)); disasters are written against the city that exists.

---

## 0. Conclusion first

1. **Every disaster is an existing hit, sent from somewhere new.** A meteor is a `_blast`, lightning
   is a small `_blast`, fire is a stream of `chip`s, a tornado is `chip`s on the facade plus forces
   on loose pieces. Nothing needs a new way to change bricks, so everything goes through
   `WorldAuthority.request` → `DamageLog` → the damage queue and its `DAMAGE_BUDGET_MS`, exactly as
   a gun does. Replays and checkpoints keep working for free.
2. **No C++ for the first four.** The one disaster that really wants the engine — the earthquake —
   needs sideways loads in `solve_stress`, which is gravity-only today. That is the main reason it
   is deferred, not a lack of interest: it is the best fit for brick physics of all of them
   ([BrickFailure](BrickFailure.md): joints are strong in compression, a thousand times weaker in
   tension; shaking is tension).
3. **They chain.** Lightning and meteors start fires. The storm that brings lightning brings rain,
   and rain slows fire. That turns four small systems into something that feels like weather.
4. **The cost to watch is fire**, because it is the only one that grows on its own. It gets a hard
   cap on burning cells from the start, and a probe that proves the cap holds.
5. **`city_scene.gd` is shared ground and already 8,000 lines.** Disasters live in their own folder
   and reach the city through one small context object. The city gains a node, a key, and a flag.

---

## 1. Shape of the system

```
scripts/disasters/
  disaster_director.gd    the node the city owns: key, roll, one-at-a-time, HUD banner
  disaster_context.gd     the city's API as seen by a disaster (blast, chip, islands, rays...)
  disaster.gd             base class: phases, seed, duration, finished signal
  meteor_shower.gd
  lightning_storm.gd
  fire_spread.gd          not a disaster on its own list -- a SERVICE others start fires with
  tornado.gd
shaders/disaster_*.gdshader   funnel, bolt, meteor glow
tools/disaster_probe.gd
```

Disaster visuals live here, not in `fx/` (Weapons and effects' area) — they can still borrow
`VfxPool` emitters and `MaterialFx.impact` for the per-hit look.

### 1.1 The director

* **`H`** — start a random disaster. Free in the city, camera, pawn and mech bindings (checked).
  Ignored while one is running.
* **`Shift+H`** — end the running disaster now (its `ending` phase still plays, so fires go out
  rather than vanish).
* **`--disaster=meteor|lightning|fire|tornado`** — force the roll, for probes and captures.
  `--disaster-seed=N` fixes the seed.
* **Big city:** the director is not created. `city_scene._ready` adds it only when `not _big`.
* The roll uses its own `RandomNumberGenerator`, seeded from a fixed base and a counter, so the
  N-th disaster of a run is the same disaster every time. Weights start equal; fire alone is in
  the roll as "a building catches" (§5.4).
* One on-screen banner: name, phase, seconds left. Goes in the existing HUD, not a new layer.

### 1.2 The base class

```gdscript
class_name Disaster extends Node3D
enum Phase { WARNING, ACTIVE, ENDING, DONE }
signal finished
var ctx: DisasterContext
var rng := RandomNumberGenerator.new()
var phase := Phase.WARNING
func begin(context: DisasterContext, seed: int) -> void   # sets up, enters WARNING
func tick(dt: float) -> void                              # the director calls this
func end_now() -> void                                    # jump to ENDING
```

**Warning matters.** This is a co-op FPS: a disaster that lands before anyone can react is not
fun. Every disaster has a warning phase — a sound, a sky change, a marker on the ground — of 3–8 s.

### 1.3 The context

What a disaster may touch, and nothing else:

| Call | Goes to | Notes |
|---|---|---|
| `blast(point, radius)` | `city._blast` | through the authority; queued; budgeted |
| `chip(point, radius, hp)` | `city.chip` | same |
| `ray(from, to)` | physics ray on `Layers.HITSCAN_MASK`, then `_ray_recipes` | the recipe fallback is what lets a meteor hit a building that has no node yet — the same trick `_fire` uses |
| `tallest_near(point, radius)` | the building registry's recipes | lightning's target; costs nothing, needs no materialising |
| `material_at(point)` | `MaterialFx.material_at` | **linear over buildings** — fire must cache per building (§5.3) |
| `islands_near(point, radius)` | `IslandManager.islands` | the debris cap bounds this list |
| `wake_near(point, radius)` | `IslandManager.wake_near` | |
| `impact_fx(point, normal)` | `MaterialFx.impact_at` | the per-hit mark, debris and sound |
| `shake(point, strength)` | camera | falls off with distance |
| `player_pos()` | camera / pawn / mech | whichever the player is in |
| `damage_actor(...)` | `DamageSystem` | soldiers and the player: lightning, fire |

Adding a call here is fine. Having a disaster reach into `city_scene` directly is not.

### 1.4 Determinism

Everything that changes a brick is a committed command, so a replay reproduces the damage even
though the disaster's visuals are not replayed. The disaster's own choices (where a meteor lands,
where the tornado walks, which cell catches) come from its seeded `rng`, **ticked on the physics
tick, never on `_process`**, so they do not depend on frame rate.

Forces on loose pieces (tornado) are physics, and physics is not in the log — the same as any
other piece today. Fine for now; multiplayer ([Multiplayer.md](Multiplayer.md)) will treat it like
the rest of debris.

---

## 2. Meteor shower

**The first one built**, because it proves the director, the context, the warning and the budget
with nothing new underneath: every impact is a `_blast`.

**Shape.** 25–40 meteors over ~30 s, in 3–4 bursts. 8 s warning: the sky reddens, a low rumble,
then the first streaks high up that hit nothing.

**Each meteor**

* Target: 60% a building (a random point on a recipe's roof or upper walls), 40% open ground near
  the player (within 80 m, never within 6 m in the first burst).
* Spawns 250 m out along an entry direction shared by the whole shower (a shower comes from one
  side of the sky), 30–60° from vertical, ~120 m/s.
* **Ground marker** from 2.5 s before impact: a glowing ring decal where it will land. The warning
  a player can dodge.
* Moves along a straight segment; each physics tick rays **the segment it covered** (fast mover,
  so no tunnelling), through `ctx.ray` so unbuilt buildings are hit too.
* Impact: `ctx.blast(point, r)` with r 1.5–3.0 m; one in ten is large at `BIG_BLAST * 1.5`
  (4.8 m). Plus `impact_fx`, a dust burst, a shake, a flash light for 0.2 s, and a 15–25% chance
  to start a fire at the point (§5).
* **Ground:** when the city stands on the heightfield, the hit also craters the terrain through
  its chunk (`apply_hit` — [Terrain §11](Terrain.md)). On the flat plane nothing happens to the ground.

**Look.** A small emissive brick cluster (a meteor built from bricks, not a sphere) with a
GPUParticles trail, both from a pool of 8 — no instantiating mid-shower.

**Budget.** A burst of 10 in 2 s is 10 blasts; the damage queue already spreads them at 6 ms a
tick. The worst case is two large ones on the same tower in one tick, which is the same as a player
firing `X` twice — already measured.

---

## 3. Lightning storm

**Shape.** ~45 s. Warning 6 s: the sun dims (`DirectionalLight3D` energy and the sky's colour
eased down), wind sound, rain starts. Then a strike every 1.5–4 s, then the storm clears over 6 s.

**Each strike**

* Target: `ctx.tallest_near(random point, 40 m)`, 70% of the time — lightning goes for the highest
  thing — else a random street point. **Metal** on a roof is preferred when a build has any.
* 0.6 s before: a faint leader flicker at the point (a warning a player can read, barely).
* Strike: `ctx.blast(point, 0.8)` — a bite out of the roof edge, not a crater. `impact_fx`, a
  scorch decal, a 0.15 s white flash (light + sky exposure), a camera shake near it.
* **Thunder is late by distance** / 343 m/s. Cheap and sells the scale more than anything else.
* Actors within 3 m: `SHOCK` damage through `DamageSystem`, and the element overlay
  (`ElementalManager.apply(target, SHOCK)`).
* 35% chance to start a fire at the point (§5) — higher on wood.

**Bolt.** A jagged polyline (6–10 segments, seeded) with 1–2 branches, drawn as a camera-facing
ribbon with an emissive shader, visible 0.25 s with two re-flashes. One mesh, rebuilt per strike.

**Rain.** A GPUParticles box that follows the camera (never a world-sized emitter). While it rains,
fire spread probability is halved (§5.2). Wet streaks on bricks are deferred (§7).

---

## 4. Tornado

**Shape.** ~60 s. Warning 8 s: dark sky, wind sound rising, dust starts turning at a point on the
city edge. The funnel forms, walks a seeded path across the city at 4–7 m/s (a smooth curve through
3–4 waypoints, biased to pass within 30 m of the player), and ropes out at the far edge.

**What it does**

1. **Loose pieces.** Every island within 25 m of the axis gets, per physics tick, a force made of
   tangential (spin), inward and upward parts, falling off with distance and scaled down with the
   piece's mass — small debris flies, a toppled tower half barely slides. Speeds stay under the
   existing `MAX_DEBRIS_SPEED`. Pieces flung past 25 m are released and fall as normal debris,
   so the debris cap handles the rest. `ctx.wake_near` keeps sleeping pieces from ignoring it.
2. **Facades.** Every 0.25 s, 3–6 points on building faces inside the funnel radius (found with
   `ctx.ray` outward from the axis) get `ctx.chip(point, 0.6, hp)`. That strips the skin of a
   building — windows, corners, roof edges — which is what a tornado does, and the chipped
   bricks come loose into (1). No `blast`: a tornado does not crater.
3. **Actors.** The player and soldiers inside 12 m are pushed the same way as pieces, with a cap
   so a player is thrown, not killed by the push alone. The mech resists (mass).

**What it does not do (yet).** Push a standing building over. That is a sideways load on the
structure — the same solver work as the earthquake (§6.1). Until then a tornado can topple a
building only by stripping enough of it for gravity to finish the job, which the stress solve
already handles.

**Look.** Funnel: a tapered cylinder with a scrolling-noise, alpha-blended shader, tilted slightly
with its speed. Orbiting brick bits: a `MultiMeshInstance3D` of ~300 small brick meshes spun in the
shader — **cosmetic**, never physics bodies. Dust ring at the base: one GPUParticles emitter.

**Budget.** The island loop is bounded by the debris cap (96 pieces). The facade rays are 3–6
every quarter second. The chips go through the damage queue.

---

## 5. Fire

Fire is a service first: lightning and meteors call `FireSpread.ignite(point, heat)`. On its own
in the roll it is "a building catches": a random building's random storey ignites.

### 5.1 What burns — this is a printed city

Bricks are filament. That gives fire a rule nobody else's brick game has: **plastic melts before
it burns.** Flammability, per material index in `BRICK_MATERIALS` (brick_grid.h):

| Material | Burn | Notes |
|---|---|---|
| Wood, Wood PLA | 1.0 / 0.8 | burns, chars |
| PLA, PLA matte, PLA silk, Glow PLA | 0.5 | melts early (PLA softens at ~60 °C) |
| Carbon PLA | 0.4 | |
| ABS | 0.4 | softens later |
| PETG | 0.35 | |
| TPU | 0.3 | |
| Nylon | 0.25 | |
| Metal, Stone | 0 | do not burn; stop the spread |

The table lives in `fire_spread.gd` keyed by material index. Materials are append-only, so a new
one just needs a row (default 0.5).

### 5.2 Cells, not bricks

Fire is held on a coarse grid: **cells of 4 × 4 studs × one storey's height** (1.4 × 1.4 × 2.66 m).
Per-brick fire would be tens of thousands of states; a cell is about one furnished corner of a room.

```
FireCell { key: Vector3i, heat: float 0..1, fuel: float, age: float, emitter }
```

Every **0.5 s** (staggered over ticks — a quarter of the cells each tick):

* heat rises to 1 over ~3 s;
* `ctx.chip(cell_centre, 0.9, hp)`, hp scaled by heat × the cell's flammability — so a PLA
  wall **sags and holes** and a wooden one goes faster;
* each of the six neighbours catches with probability
  `flammability(neighbour) × heat × bias × 0.25`, bias **3 up, 1 sideways, 0.3 down** (fire climbs
  a building), halved in rain;
* fuel drops; at 0 the cell dies. An empty cell (air) has no fuel and cannot catch — fire does not
  cross streets unless a burning piece falls across them.

**Hard cap: 48 cells.** At the cap nothing new catches. This is what keeps fire from being the one
disaster whose cost grows without bound. The probe (§8) asserts it.

### 5.3 Reading material cheaply

`MaterialFx.material_at` walks every building. For a cell it is called once when the cell is first
considered, and cached per `(building id, cell key)` in the fire service. The one-line cache
turns 48 cells × 6 neighbours × 2 Hz into a few new lookups per tick. A cell with no brick in it
caches −1 and is never asked again.

Generated towers are PLA today (the recipe does not vary material), so a tower burns as "melting";
furniture and player builds bring wood. That is honest and fine for v1.

### 5.4 Look

* A pooled fire emitter per burning cell (flames scale with heat) and a shared smoke column per
  building rather than per cell. Registered in `VfxPool` so none are made mid-fire.
* **Char.** `BrickWorld.set_block_colour` exists (the paint brush), so bricks a burning cell
  chipped but did not kill can be darkened. That is a change to the world, so it must be a
  committed command to survive replays: **deferred to v2** (a new `DamageLog.Kind.SCORCH`).
  v1 uses scorch decals from `MaterialFx`'s mark pool.
* Actors inside a burning cell: `FIRE` damage and overlay.
* A burning **piece** (an island) carries its fire: v2. In v1 fire lives on building cells only.

---

## 6. Deferred — what else fits, and what each is waiting on

| Disaster | Why it fits | Waiting on |
|---|---|---|
| **Earthquake** | The best fit of all: shaking loads joints in tension, towers snap at a course and topple — the brick-film look ([BrickFailure](BrickFailure.md)) | Sideways load in `solve_stress` (C++): an acceleration vector per solve, not just gravity. Plus a ground-motion curve, fissures, and camera shake |
| **Sinkhole** | Ground opens, a whole building tips into it | Volumetric terrain destruction exists (Terrain §17.10); needs the heightfield city on, and a spreading carve pattern. Cheapest of the deferred ones |
| **Hurricane / wind storm** | A tornado without a funnel: a whole city leaning | The same sideways-load work as the earthquake |
| **Flood / tsunami** | Water through the lower storeys, floating debris | Water area: a moving wave front and a water level over the city; buoyancy for pieces; sideways push |
| **Acid rain** | Printed-city twist: dissolves PLA, spares metal and stone | The `ACID` element exists for actors; bricks need a slow chip over roofs by material. Close to fire's cells — cheap after fire |
| **Blizzard / freeze** | Frozen bricks turn brittle and shatter | A per-building toughness multiplier while frozen; the `ICE` look exists |
| **Volcano / lava** | Lava melts everything it reaches | Lava flow over terrain, a heat source for fire; large |
| **Landslide** | Hillside comes down onto the city | Terrain pieces as islands at scale; heightfield city |

And deferred parts of the four built now:

* **Char as a committed command** (`SCORCH`) and burning pieces (§5.4).
* **Wet bricks** in rain (a shader parameter, city-wide).
* **Wind pushing standing buildings** (§4) — after the sideways-load solver.
* **AI reactions:** soldiers take cover from a storm, flee fire and a funnel ([AI.md](AI.md)).
* **Scheduling:** disasters as match events or objectives rather than a key.
* **Multiplayer:** the host rolls and sends `(kind, seed, start tick)`; clients play the visuals.

---

## 7. Order of work

Each stage merges on its own, small (repo CLAUDE.md).

| Stage | What | Done when |
|---|---|---|
| **D0** | Director, context, base class, `H` / `Shift+H`, banner, `--disaster=`, probe skeleton. Small city only | `H` rolls and runs a do-nothing disaster through all four phases; big city has no director |
| **D1** | Meteor shower | Probe: N meteors → N committed blasts; frame budget within the damage queue's |
| **D2** | Lightning storm (sky dim, bolt, thunder delay, rain, shock damage) | Probe: strikes land on the tallest recipe near the roll ≥ 70% |
| **D3** | Fire service + "a building catches"; meteors and lightning ignite | Probe: fire spreads up, dies out, **never exceeds 48 cells**; metal stops it |
| **D4** | Tornado (islands, facade chip, actors, funnel, orbiting bricks) | Probe: pieces near the path gain speed ≤ `MAX_DEBRIS_SPEED`; facades lose bricks along the path only |

The city change is limited to D0: create the director when `not _big`, pass it a context, route
`H`. Everything after that is inside `scripts/disasters/`.

---

## 8. Testing

`tools/disaster_probe.gd` loads the small city headless and, for each kind with a fixed seed:
runs it at `Engine.time_scale` up, counts committed `DamageLog` entries by kind, samples the worst
tick's damage time, and asserts the per-stage gate above. `--shot` captures a frame at peak for
each, so a change to the look is reviewable. Run it with the probes the city already has
(`city_probe`, `debris_probe`, `cap_probe`) before each merge.

Measure frame times on a quiet machine — an open editor inflates them several times over.
