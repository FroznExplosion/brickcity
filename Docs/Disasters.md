# Natural disasters

Design and plan for the disaster system: four built now (**meteor shower, lightning storm, fire,
tornado**), the rest deferred with what each one is waiting on.

Written 2026-09-26. **D0–D6 are built**: the director, the meteor shower, the lightning storm,
fire, the tornado, soldiers who get out of the way, and — D6, 2026-09-27 — a disaster menu with
intensity, a stronger tornado, and an **earthquake with collapse caps** (§2.1, §3.1, §4.1, §4.2,
§5.5, §9, §10, §11 have what was measured and what changed from the plan).

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

* **`H`** — open the disaster menu (§11). Free in the city, camera, pawn and mech bindings
  (checked). (Until D6 it started a random disaster straight away.)
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

### 2.1 Built — what differs from the plan above, and what was measured

* **No craters in the ground.** The city's blasts do not touch terrain (the flat plane has none,
  and heightfield mode does not route blasts to its chunks). A ground strike is a blast on
  whatever stands there. Craters wait for the terrain area to take a blast.
* **Fire was rolled before it existed.** Each meteor rolled its 20% from D1 on, so a seed's
  shower did not change when D3 made `ctx.ignite` real. It did change the cost: with fires
  burning after the strikes, the shower's worst tick went from 17 ms to ~45 ms headless (mean
  3.1 → 4.3 ms) — fire's chips on top of the blasts.
* **The tint is mild.** The first pass washed the bricks red; a player has to read what is being
  hit. Sun `(1, 0.8, 0.66)` at 85%, sky towards a dusty mauve.
* **The trail runs every frame** (`fixed_fps = 0`) with puffs wider than a frame's travel. At the
  default 30 fps a 120 m/s meteor left a row of dots 4 m apart.
* **The ring's glow has its own texture**, premultiplied. Decal emission ignores alpha, so the
  shared texture lit the decal's whole square.
* **A hit on a building is found by box** (`ctx.building_at`), not by the collider's layer: the
  city's structure bodies are server RIDs, so the ray's collider is not a node.

Probe (seed as the director rolls it, #4): **31 meteors in 3 bursts, all landed, 17 on buildings,
18 committed BLASTs, nearest to the player 21.8 m**; physics tick mean 3.1 ms, worst 17.3 ms
headless. Windowed with captures the worst tick is ~94 ms — the ticks a screenshot is saved on.
`-- --disaster-shot` (windowed) frames the first meteor and saves `shots/disaster_meteor_*.png`.

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

### 3.1 Built — what differs, and what was measured

* **No element on the shock.** No `Element` resources exist yet, so a stroke hurts pawns with a
  plain kinetic `DamagePacket` (60 within 3 m) through `DamageSystem.resolve` — handed the pawn's
  `HealthPool` directly, because the lookup from the pawn root did not find it. No overlay.
* **Metal is not preferred.** Strokes go for the tallest standing building near the roll, at a
  roof corner. Preferring metal waits for buildings that have metal on top.
* **The sky flash is the sun.** `ctx.set_sky(..., flash)` adds to the sun's energy while a stroke
  is lit, plus a 60 m omni light at the strike; the flicker is three flashes over 0.3 s.
* **Rain from halfway through the warning.** `ctx.raining` is true from then until 70% through
  the ending; fire reads it.

Probe: **15 strokes over 45 s, every one landed; 4 of 4 aimed at the tallest nearby hit it;
4 committed BLASTs** (a blast is committed only when it kills a brick, so a stroke on a corner
already taken can commit nothing — the gate asks for most, not all); a soldier beside a stroke
100 → 40 hp, one 10 m off untouched; sky dark and back.

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

### 4.1 Built — what differs, and what was measured

* **It walks at 5 m/s and ACTIVE follows the path**, not the other way round: the small city's
  crossing is ~143 m, so ACTIVE is ~30 s (clamped 25–75). Fitting the speed to a fixed 60 s made
  it crawl at 2.5 m/s.
* **Pieces over 800 bricks are left alone**, and a settled small piece is woken first (every
  0.5 s) — frozen bodies ignore velocity. The pull closes 18% of the gap to the wanted velocity per
  tick, scaled by `60 / bricks`, capped at 90% of `MAX_DEBRIS_SPEED`.
* **Pawns have a `shove`** (`Pawn.gd`): a velocity added to the walk each step, lifting when its y
  is positive, bled off at 3/s. The tornado sets it every tick a pawn is inside 12 m. A small
  change in the pawn's area; nothing else sets it yet.
* **The funnel** is `shaders/disaster_funnel.gdshader` on an open cylinder (2.5 m at the foot,
  16 m at 50 m up) that grows out of the dust as it forms; the bricks round it are a 300-instance
  MultiMesh spun by `shaders/disaster_orbit.gdshader`. Its sky is a green-grey.

Probe: **143 m at 5.0 m/s; passes 0.5 m from the player; 12 loose pieces pulled, fastest
16 m/s; 310 facade chips, every one inside the funnel, all committed CHIPs; the soldier ran
(§9)**; physics tick mean 4.5 ms, worst 14.6 ms headless.

### 4.2 Stronger (D6)

The first tornado was too weak to see work: it only chipped facades, so there was little loose for
it to lift, and it left pieces over 800 bricks alone. Now, at Medium: 30 m reach, 24 m/s round,
lift 14 m/s, pieces up to 2,500 bricks, and **half its facade hits tear a clump off whole**
(`ctx.shear` → the city's own `_shear_building`, a SHEAR command) — those clumps are what it
throws. Above 38 m pieces are flung outward and fall. Radii scale with √intensity, forces and
damage with intensity; the funnel and the orbiting bricks widen with it.

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

### 5.5 Built — what differs, and what was measured

* **The spread is 0.06, not 0.25.** At 0.25 every cell set about nine others alight: a 1,089-cell
  block of PLA burnt 1,037 of them, the fire sat at the cap, and the city took 2,677 CHIPs in
  48 s. At 0.06 a PLA cell sets about 1.5 alight — a fire grows, climbs, and runs out of building.
* **Fire is the director's, not a disaster's.** It outlives the storm or shower that lit it. The
  banner shows `FIRE — n burning` whenever cells burn. Ending "Fire" (`Shift+H`) douses:
  no more spread, fuel cut, out in a couple of seconds.
* **Flames vent.** A cell's flames are drawn at its face onto open air (a flammability-0
  neighbour), so fire in a room shows at the window. Chips still land at the cell's centre.
* **An unmaterialised building reads as solid PLA.** `material_at` answers PLA for any point in a
  recipe building's box until its bricks exist; the first chip materialises it and later samples
  are real. The cache keeps the early answer. Harmless so far; worth knowing.
* **No char yet** (§5.4, still v2).

Probe, fire alone (a block of PLA 11 × 9 × 11 cells): **37 caught, peak 13 of 48, 36 above the
spark and 0 below, out in 43 s, a metal storey stops it, 2 caught in rain against 37 dry.** In
the city, "a building catches": peak 15 cells, 49 caught, out in 43 s, 487 CHIPs.

---

## 6. Deferred — what else fits, and what each is waiting on

The game's terrain is a **heightfield** and stays one: nothing that needs destructible terrain
is planned. That drops the **sinkhole** and **meteor craters** in the ground (a meteor still
craters buildings). Deferred by decision (2026-09-28), not blocked:

| Disaster | Why it fits | What it would need |
|---|---|---|
| **Flood / tsunami** | Water through the lower storeys, floating debris | A moving water level over the city; buoyancy for pieces; the sideways load for the push |
| **Blizzard / freeze** | Frozen bricks turn brittle and shatter | A per-building toughness multiplier while frozen; the `ICE` look exists |
| **Volcano / lava** | Lava melts everything it reaches | Lava flow over the heightfield, a heat source for fire; large |
| **Landslide** | Hillside comes down onto the city | Terrain pieces as islands at scale — against the heightfield rule; would have to be rubble thrown down a slope instead |

Built since this table was first written: the hurricane (§18), the earthquake's sideways load (§17), acid rain
(§14), char and burning debris (§15), wind pushing standing buildings (§17), soldiers
sheltering from storms, meteors and the tornado, weather on the AI's aim (§13), and co-op (§16).

Still deferred:

* **Wet bricks** in rain (a shader parameter, city-wide).
* **Fire in co-op:** a client sees what fire does to bricks (the host's commands) but not its
  flames; the fire service would have to send its cells.
* **AI choosing to fight near a fire** because its smoke hides them.
* **Scheduling:** disasters as match events or objectives rather than a key.

---

## 7. Order of work

Each stage merges on its own, small (repo CLAUDE.md).

| Stage | What | Done when |
|---|---|---|
| **D0** ✅ | Director, context, base class, `H` / `Shift+H`, banner, `--disaster=`, probe skeleton. Small city only | `H` rolls and runs a do-nothing disaster through all four phases; big city has no director |
| **D1** ✅ | Meteor shower | Probe: N meteors → N committed blasts; frame budget within the damage queue's |
| **D2** ✅ | Lightning storm (sky dim, bolt, thunder delay, rain, shock damage) | Probe: strikes land on the tallest recipe near the roll ≥ 70% |
| **D3** ✅ | Fire service + "a building catches"; meteors and lightning ignite | Probe: fire spreads up, dies out, **never exceeds 48 cells**; metal stops it |
| **D4** ✅ | Tornado (islands, facade chip, actors, funnel, orbiting bricks) | Probe: pieces near the path gain speed ≤ `MAX_DEBRIS_SPEED`; facades lose bricks along the path only |
| **D5** ✅ | Soldiers react (§9): hazards into the AI's danger boxes, fire smoke blocks sight | Probe: a soldier leaves a meteor's ring; burning cells are danger; smoke blocks sight; all gone when the fire is |

The city change is limited to D0: create the director when `not _big`, pass it a context, route
`H`. Everything after that is inside `scripts/disasters/`.

---

## 8. Testing

`tools/disaster_probe.gd` (`--headless --path . --script res://tools/disaster_probe.gd`, add
`-- --also-big` to also check the big city has no director, `-- --disaster-shot` windowed for
captures, `-- --only=meteor,fire,lightning,pawn,soldiers,tornado,real,intensity,quake,acid,char,coop` for sections) loads the small city headless and, for each kind with a fixed seed:
runs it at `Engine.time_scale` up, counts committed `DamageLog` entries by kind, samples the worst
tick's damage time, and asserts the per-stage gate above. `--shot` captures a frame at peak for
each, so a change to the look is reviewable. Run it with the probes the city already has
(`city_probe`, `debris_probe`, `cap_probe`) before each merge.

The roll holds only built kinds. The **drill** (`drill_disaster.gd`): every phase, a light tremor, no
brick changed) is not in it, but `--disaster=drill` still runs one.

**Flag names must not collide with the city's.** The probe's first `--big` and `--shot` were read
by `city_scene` too and turned the small city into the big one / started its own capture pass.
The probe's flags are `--also-big` and `--disaster-shot` for that reason.

The city's own gates (`-- --gun` etc.) are scene passes: run them windowed
(`--path . --resolution 1280x720 res://scenes/city.tscn -- --gun`), never `--headless` — their
screenshots wait forever without a window.

Measure frame times on a quiet machine — an open editor inflates them several times over.


---

## 9. Soldiers react (D5)

The AI already had the mechanism: `AIWorld` holds **danger boxes**, and the soldier's tree puts
`InDanger > Evade` above everything, fighting included ([AI.md](AI.md) 3.5 — it was built for
falling pieces). Disasters now feed it.

* **`ctx.set_hazard(id, box)` / `clear_hazard(id)`**, pushed to the AI by
  `ctx.push_hazards(ai_world)` — which the city calls every AI tick right after
  `Danger.update`, because that clears every danger box first. Disaster ids are negative so they
  never meet a chunk id.
* **What is marked:** a meteor's ring (its blast radius + 1.5 m, from the ring appearing to the
  strike); a lightning stroke's 3 m for its 0.6 s leader (a soldier on that roof may not make it,
  but tries); the tornado's funnel, 28 m across and 38 m high, swept 2 s ahead; every burning
  fire cell, grown 0.8 m.
* **Smoke:** each cluster of burning cells puts a smoke sphere over itself in the AI's world
  (`set_smoke`) — it blocks sight, not bullets, so a fire changes a fight.
* **`BTEvade` looks further**, a small change in the AI's area: a second ring of candidates at
  14 m besides the 6 m one, and it picks again when it arrives still inside. With only 6 m and no
  re-pick a soldier stood still inside anything as big as a funnel.

Probe: a soldier inside a ring is clear of it (2.1 m out) in 1.3 s; a burning cell is danger and
its smoke blocks a sightline through it; both are gone when the fire is. The tornado's soldier
ran every time it was measured — faster than the funnel walks, so the shove gate accepts "shoved
or got clear", and the shove itself is checked on its own (6 m along, 2.1 m up in 20 ticks).
`city.tscn -- --soldier` and `-- --play` still pass.


---

## 10. Earthquake (D6)

The concern that shaped it: an earthquake hits every building at once, and every building
collapsing together would be the worst tick the game has. So the design splits it:

* **The shaking is cheap and city-wide.** Camera shake; every loose piece jolted every 6 ticks;
  pawns stumble (`Pawn.shove`); a few bricks a quarter-second shaken off buildings within 80 m —
  60% chips, 40% clumps torn loose (SHEAR) that fall.
* **Collapses are rationed.** At the start each building within 120 m rolls whether it fails and
  when; tall, slender buildings are likelier (risk = 0.12 × intensity × height/width × a roll).
  Two caps from the menu: **max collapsing at once** (a collapse counts until its building has
  toppled and come to rest, or 14 s) and **max collapses in total**. A failure that finds the cap
  full waits for a slot; if the shaking ends first it never happens.
* **A failure is a soft storey** — how real buildings go down in quakes. A band of blasts goes
  through the ground storey on one side, over 60% of the depth. The city's own stability test
  then sees the centre of mass past what still holds it up, and **the whole building topples as
  one piece through the city's normal topple path** (TOPPLE), with rooms, collision and debris
  handled as any topple is. If it still stands after 3 s the band is cut to 80%; after 7 s it
  counts as survived.

**Tried first and dropped (then revived in §17):** cut the tower through at a storey's slab
(SEVER) and tip the freed top over. Tops of 1,100 bricks would not turn — 0.00 rad/s under any
push. Undermining worked at once, so that is what shipped then.

**Superseded for near buildings by §17:** a building whose bricks are in now fails where its
joints do, from a sideways load in the solver. The rolled soft storey above is still how a
building out of reach fails. (The tops that would not turn: the staircase threading through the
cut — [Collapse](Collapse.md); `CityScene._with_stairs` takes the stairs with the piece now.)

Probe (Extreme, 1 at once, 3 in all): **3 failures, never more than 1 falling at a time, 7 held
back by the total cap; all 3 toppled (32–42°, leaning on their stumps), 69 BLAST + 3 TOPPLE
commands; 308 chips and 199 clumps shed; with 0 at once nothing topples.** More intensity plans
more failures: 2 / 5 / 8 at Low / Medium / Extreme. Frame time, measured with other Godot
processes running so read it as rough: shaking alone ~6–15 ms mean; with collapses capped at one
at a time, worst ticks 38–60 ms — the collapses are the cost, which is why the cap is the knob.

---

## 11. The menu and intensity (D6)

`H` opens a menu (centre of the screen, mouse freed; closing gives the mouse back to the camera
only if it had it): **Disaster** (Random or any of the six), **Intensity** (a slider 0.25–3 that
snaps to Low 0.5 / Medium 1 / High 1.6 / Extreme 2.5), and the earthquake's two caps (greyed
unless Random or Earthquake is chosen). **Start** or Enter runs it; Stop ends the running one;
Esc or H closes. The choice is remembered. The banner shows the intensity, and for a quake
`collapsing n/cap · k of total so far`.

Intensity at 1 is exactly what each disaster was before; at other values:

| Disaster | What scales |
|---|---|
| Meteor shower | count × i, radius × √i, big-meteor chance × i, fire chance × i (≤ 80%) |
| Lightning storm | strokes come i× as often, strike radius × √i, shock × i, fire chance × i (≤ 90%) |
| Building fire | sparks × i, spread × i while it lasts |
| Tornado | §4.2 |
| Earthquake | ground acceleration × i (§17), risk × i for far buildings, length 14 + 6i s, shaking and shedding × i |
| Acid rain | drops × i, wear × i, burn × i |

A seed at intensity 1 is the same disaster it always was; at another intensity it is its own,
still deterministic, disaster — more meteors draw more numbers.

---

## 12. Real bricks, and pieces that sleep in mid-air (2026-09-28)

**Lightning went for the recipe.** "Tallest nearby" read the recipe's box, so a building with its
top half blown away still had its roof, and the stroke's ray down only reached 30 m below that —
it hit the air. Now `ctx.top_of(box)` rays straight down at the middle and near the four corners
and takes the highest thing hit; `tallest_near` compares those real tops; the stroke rays from
above its target all the way to the ground. Probe: the tallest tower cut in half reads 15.1 m (its
roof was 35.1 m), lightning aims there, and a stroke from above lands on bricks.

**Fire burned the air.** Two causes. `MaterialFx.brick_at` answered PLA for any point inside a
materialised building's box, bricks or not — fixed there (it also served impact sounds). And a
building the city had given its bricks back to — far away, damage kept in its record — read as
whole from its recipe. Fire's `ctx.material_at` now counts a brick only where building collision
(`Layers.STRUCTURE`) is: the damage lives in the collision either way. Fire's cached flammability
expires after 4 s, and "a building catches" finds a real wall by a ray in from the facade,
dropping a storey at a time if the one it rolled is gone.

**Pieces frozen in mid-air.** The settle rule was: slow for 0.7 s, then rays down from the
underside — nothing under it, a nudge down instead of a freeze, but after `SUPPORT_TRIES` (3) it
settled anyway, so that a beam wedged across a gap could rest. A tornado holds a piece slow at the
top of its climb with nothing under it: three tries, frozen, left hanging when the wind moved on.
Three changes in `IslandManager`:

1. **Touching nothing is never settling.** The wedged-beam allowance now needs the piece to be
   touching something — one box query, `TOUCH_MARGIN` 0.15 m round its box. A piece touching
   nothing is nudged down again and again until it lands (`floating_refused` counts these).
2. **`hold_awake(piece, ms)`**: something outside physics holding a piece up — the tornado's wind —
   keeps it from settling until the hold runs out (1.5 s after the wind lets go), and wakes it if it
   had settled. `BrickIsland.hold_until_ms`.
3. **A watchdog.** `AUDIT_PER_TICK` (4) settled pieces a tick, round-robin, are asked the same two
   questions — anything under it? anything touching it? — and a piece that answers no to both is
   woken and falls (`audit_woken`). It catches every other way support goes without a ripple.

`tools/float_probe.gd` checks all three: a piece held still in the air past its tries is not
frozen, and falls and settles on the ground once let go; the watchdog finds a piece frozen 15 m up
and it falls, while one frozen on the ground is left alone; a held piece does not settle until the
hold runs out. After a tornado the disaster probe finds **0 of 31 settled pieces floating** — with
`hold_awake` in, the tornado never got as far as a refused settle or a watchdog wake in that run,
so the direct evidence for (1) and (3) is `float_probe`'s.

---

## 13. Weather on the lens, and on the AI (2026-09-28)

**The lens.** `shaders/disaster_screen.gdshader`, a full-screen overlay under the HUD and over the
3D view: rain streaks (three layers, slanted) and a dust haze thick at the edges and low down.
`ctx.set_screen(rain, dust, dust_colour, rain_colour)`; both dials at 0 draw nothing. The
lightning storm rains on it, the meteor shower and tornado raise dust (the tornado's thicker the
nearer the funnel), the earthquake a little dust with the shaking, acid rain rains green.

**The AI.** `ctx.set_weather(amount, sight, aim, intensity)` sets `AIServices.sight_mul` and
`aim_mul`: soldiers see somewhat less (never below 60%) and aim a good deal worse — a storm is
0.85 sight / 2.2x spread, the quake 1.0 / 3x (nobody shoots straight on moving ground), acid rain
0.9 / 1.3x. `ctx.set_storm(true)` sends soldiers with nothing to fight under a roof (`BTShelter`:
the nearest standable spot with something solid overhead). Meteor showers and the tornado set it
too. All cleared at DONE.

---

## 14. Acid rain

A printed city's own weather: it eats filament. `acid_rain.gd`, 40 s active.

* Every 0.3 s, 5 × intensity drops round the player (55 m); each is followed straight down to the
  first thing it meets and wears the brick there by **how much its material minds acid** — PLA 1.0,
  ABS 0.7, PETG 0.5, TPU 0.4, nylon 0.3, wood 0.2, metal and stone 0. A CHIP of 60 hp × that ×
  intensity: wear through the authority, never blasts.
* **Rain pools.** Most drops (65%) land in one of up to 24 puddles earlier drops found on a roof,
  so a roof thins in places and then holes, rather than every brick losing a little.
* Anyone with no roof over them loses 1 hp a second (40 over the storm at intensity 1 — the first
  number, 2 per round, killed a soldier in the open outright). Soldiers shelter; aim 1.3x worse.

Probe: 670 drops, 284 wore a brick (284 CHIPs), 144 fell on metal or stone and did nothing; a
soldier held in the open went 100 → 60; sight 0.90, aim 1.30; the lens streaks; all clear after.

Also found: `GunPlaceholderParts._pack` never freed the template node it packed — 101 orphan
MeshInstance3Ds leaked at exit whenever a soldier was armed.

---

## 15. Char, and burning debris

**Char is a command.** `BrickWorld.scorch_hit(chunk, point, radius)` gives every brick in a ball
its material's **darkest colour** (black filament, the darkest wood, metal or stone variant) and
marks it `scorched`. The city commits it as **`DamageLog.Kind.SCORCH`** — colour only, nothing dies,
no joint changes — replayed like a CHIP, so every machine sees the same black walls. The registry
keeps the scorched ids (`Building.scorched`) across a building being handed back, as it keeps
wear. A split copies the colour, so a piece off a charred wall is charred.

* Fire chars a cell's walls once, when its heat first passes 0.5 (radius 1.5 m).
* A meteor chars 1 m past its crater, a lightning stroke 0.7 m past its hole.
* Only a building whose bricks are in: a colour is not worth materialising a building for.

**A colour is in the vertices**, which the city's usual index patch never touches, so a charred
building gets a full band rebuild, gathered over `RECOLOUR_TICKS` (15) so a fire's many scorches
are one rebuild. Finding this also found a latent stall: a band build that met a dropped bake
waited on `has_bake`, which never adopts a finished async bake — it waited forever. It asks
`bake_ready` now.

**Burning debris** (`burning_debris.gd`): every 0.5 s, any moving piece whose box comes within
2.5 m of a burning cell catches — by its box, since a storey coming away has its centre metres
from the fire at its corner. Flames ride it for 12 s (counted on the physics tick), up to 8 at
once. Where it comes to rest it lights what it lies against (`ignite`, which does nothing where
nothing burns), and it burns anyone within 1.8 m.

Probe: 5–7 bricks blacken per 1 m scorch, as one SCORCH; again changes nothing; the record keeps
them; a new fire chars within a tick of taking hold; with the storey under a burning wall cut
through, the falling pieces caught (8 in all), burned out after 12 s, and lit 3 fires where they
landed.

---

## 16. Co-op

The host decides, clients watch — the same rule as the world authority, and like it
transport-free: the owner fills in the Callables.

* **Host:** `start()` rolls, then sends every `add_client()`
  `["start", kind, seed, start tick, intensity, options]`; `stop()` sends `["stop", tick]`. A
  client added mid-disaster is sent the running one's start at once.
* **Client** (`set_client(send)`): `receive(event)` runs the same disaster from the same seed and
  **catches up** to the host's tick by ticking it (up to 120 s' worth). Its context does not decide
  (`DisasterContext.decides`): blast, chip, scorch, shear, sever, ignite and pawn damage do nothing
  there. What the disaster does to bricks and people arrives as the host's commands like
  everything else; what the client plays is the sky, the rain, the meteors in the air, the funnel.
* A client's menu, `H` and `Shift+H` send `["request", kind, intensity, options]` /
  `["request_stop"]`; the host starts or stops it and tells everyone.

Probe (a second director in the same city as the client, the wire two arrays): joining 9 s late,
the client's shower is in the same phase at the same time with the same rng state; a late client
is sent the running one; the client's context changes nothing; stop reaches it; its request
starts the host's lightning at the intensity asked, and its stop request stops both.

---

## 17. The sideways load: a true earthquake, and wind on buildings

**`BrickWorld.lateral_check(chunk, accel_g, dir)`** — a pure query. At every course boundary above
the foundation it weighs what is above: the inertial force a·W at its centre of mass tries to
overturn it about the **toe** (the last contact on the far side), and two things hold it —
gravity (W times how far the centre of mass is behind the toe) and **the studs across the
boundary**, each carrying `tension_per_stud` at its own lever from the toe. A block that runs
through a boundary instead of meeting at it holds like 4 studs a cell. It returns the worst
boundary's demand / capacity, and where it is. ~0.1 ms for a 2,800-brick tower.

The small city at 1 g (demand / capacity, worst direction): 8.5 m blocks 0.3, 11–14 m 0.5–0.7,
19 m 1.1, 27 m 1.2–1.8, 35 m 2.5 — all failing at the ground storey's first course boundary
(1.8 m): a soft storey found by the numbers rather than assumed.

**The earthquake** puts **PGA 0.45 g × intensity × shaking** to every building within 120 m whose
bricks are in, once a second, along the quake's seeded axis both ways. Medium takes the 35 m
towers, High the 27 m ones, Extreme the 19 m ones; a tower already shot through fails sooner
because its studs are gone. A failure is cut at that boundary — **`SEVER` with `FLAG_SEAM`**
(`BrickWorld.sever_seams`: both sides stay whole, not a band of loose brick) — and the freed top is
tipped over its toe (`Earthquake.tip`) for 4 s. The caps are unchanged. A building out of reach,
or one whose bricks went while it waited for a slot, fails the old way (§10).

**The tornado** puts up to **0.45 g × intensity** at the funnel wall, falling to 0 at 0.6 of its
lift radius, along the swirl (snapped to the building's grid), once a second; a building that
gives is cut and tipped downwind, up to 3 × intensity in a tornado.

Probe: at 0.6 g the tallest tower fails (1.48) and the squattest holds (0.17), at 1.8 m; Extreme
quake, 1 at once, 3 in all — all 3 cut by the solver (≈290 checks), one SEVER seam each, all 3
over (22–133°); the tornado pushed 1 over, one seam. Full probe 115 / 115. Run alone the quake
passed every time; one earlier full run (before §17) saw a top come to rest at 8° — physics, with
the city already wrecked round it.

---

## 18. Hurricane — on the heightfield coast

The first disaster made for the terrain rather than the city. `heightfield_test.tscn` hosts a
director now (`H`, `Shift+H`, as in the city), offering only what needs no buildings — the
hurricane (`DisasterDirector.setup(host, kinds)`). The context tolerates a host that is not a city:
it needs a `camera` and a `_sun`; buildings, pieces, soldiers and the AI are used where the host
has them. `hurricane.gd`: WARNING 10 s, ACTIVE 80 s, ENDING 20 s.

* **The surge.** The sea rises `SURGE_M` (1.6 m) × intensity at the storm's height and comes back
  to exactly where it was at DONE. Through the host's `disaster_sea(surge, wave_mul)`
  (`ctx.set_sea`): **BrickWave's own sea level**, so the drawn sea, what a swimmer floats in and
  the water's collision rise together. The flood itself costs nothing — the water shader compares
  the ground (the seabed map) with `sea_level` per pixel — but where the studded tier shows and
  how waves steer to the shore come from the seabed map's wet cells, and re-reading that is ~30 ms,
  so it is done every 0.5 m of level, no more than every 2 s. The surge lags the wind by ~6 s and
  follows the storm's envelope, not the eye's lull: a surge does not drain in the eye.
* **The waves.** Gain × (1 + 1.4 × intensity) at full strength — 2.2 → 5.3 at Medium.
* **The wind.** Gusting (three sines from the seed), veering ±0.5 rad, and it **turns round after
  the eye**. It leans on whoever is out in it: `DebugCamera.wind`, up to 2.2 m/s × intensity of
  drift walking, 60% of it swimming. In a city it would push loose pieces (small ones most) and put
  up to 0.25 g × intensity of sideways load on buildings — one cut and blown over per intensity —
  but the heightfield has none of either yet.
* **Rain** driven along the wind (7,000 streaks round the camera), **litter and spray** blowing
  past low down, **lightning** in the cloud every 3.5–9 s past 40% strength (a flash of the whole
  scene, thunder 0.6–3 s later), the sky near dark, rain and haze on the lens, wind and rain
  sounds. The AI: sight 0.75, aim 2.2x worse, and `storm` sends soldiers under a roof.
* **The eye.** Halfway, 12 s of calm: wind to 8%, the rain stops, the sky opens — then the wind
  comes back from the other side.

Probe (`tools/hurricane_probe.gd`; `-- --hurricane-shot` windowed saves calm / storm / eye): the
sea rises +1.60 m and more ground is wet (1,212 cells against 1,036); gain 2.20 → 5.28; a walker
standing still is carried 9.1 m in 5.6 s; 0.08 m/s in the eye and the wind reversed after it; 10
flashes; the sea, gain and wet map exactly back at the end; the wind and the lens clear.

Not yet: waves that break over the new shoreline (the shore band is re-read, but no surf or
spray at the waterline), and the hurricane in the city: it would run there — rain, wind, pieces,
buildings — but it is not in the city's list yet, and the city's sea is not wired to
`disaster_sea`. (Wet ground and bending trees: §19.)

---

## 19. Wet in the rain, and swaying in the wind

`shaders/weather.gdshaderinc`, included by the brick shader, the terrain shader, the printed
pieces' core (the laid ground, studs, tufts), the impostor cards and the far city. Every uniform
defaults to "no weather", so an unregistered material draws exactly as before.

* **Wet** (`weather_wet`, 0..1): a surface darkens a little (plastic 14%, the terrain's ground
  22%, metal not at all), goes far glossier (roughness toward 0.07) and more specular — most on
  what faces the sky. The disaster context eases it: **up over 15 s while it rains, drying over
  120 s after**, so the city stays wet a while after a storm passes.
* **Sway** (`weather_wind`, the wind's direction × strength, and a per-object `instance uniform
  weather_sway` = height, lean per metre at wind 1, Hz): the object bends about its base, the lean
  growing with the square of the height — a steady lean downwind, a sway about it and a flutter,
  each object on its own phase. **Trees** 5 cm per metre of height at wind 1, 0.55 Hz — a 6 m
  tree's crown moves ~30 cm in a hurricane; **standing buildings** 1.5 mm per metre, 0.22 Hz — a
  35 m tower's top a few centimetres. Set only on trees (ImpostorLod's near copies; a city tree
  that is bricks up close gets it on its bands) and building bands (`CityScene._sway_of`), so a
  piece of debris or a chair never sways. Visual only: collision does not move.
* **Who sets the wind:** the hurricane (up to ~1.5 in gusts), the tornado (along its walk, harder
  the nearer it is), the lightning storm (a stiff breeze, 0.4), acid rain (0.2).

`WeatherFx` (static) holds the values and pushes them into every registered material — the
city's and heightfield's brick and terrain materials, TerrainTile's printed materials, the far
city's — and adopts copies made from a registered one (ImpostorLod's fading copies and cards:
`duplicate()` takes parameters as they are and would not follow). Not Godot's global shader
uniforms: those live in `project.godot`, which is kept open by another area.

Not yet: see-through (glass) bricks do not sway with their building (their pass has no
include — a few centimetres at a tower's top), puddles and ripples, streaks running down walls,
and grass tufts in the wind.

Probe (`hurricane_probe`): bricks 1.00 wet at the height of the storm, the terrain's and the
printed materials registered; still wet just after, drying; 4 tree sets swaying, gale up to 1.06
and back to zero with the storm. Windowed, every shader compiles; `-- --hurricane-shot` saves
`land_dry` / `land_wet` over the same trees. City `--play`, `--rooms`, the workshop gate and the
disaster probe (115) pass.
