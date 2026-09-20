# Reference — MvsC (open world, water, vehicles)

**Location:** `C:\Users\lbaun\Documents\mvs-c`
**Stack:** Godot 4.6 · GDScript · Jolt · Forward+ · D3D12 — identical to this project.
**State:** playable. Streamed authored island, ~570 pawns, boats, cars, bikes, aircraft,
traffic, squad AI, police, 2-pane splitscreen, 4-player online coop, save/load.

Its own docs are the primary source: `Docs/Plan.md`, `Status.md`, `Island.md`, `Water.md`,
`Traffic.md`, `Vehicles.md`, `Wanted.md`, `Performance.md`, `Dependencies.md`,
`GauntletLoop.md`, `Air.md`, and seven vehicle specs under `Docs/Vehicales/`.

---

## 1. The four constraints that shaped it

Every structural decision traces to one of these. Ours differ in the specifics but the shape
is the same, so the consequences carry.

| | Constraint | Consequence |
|---|---|---|
| C1 | Up to 4 humans, any mix of local splitscreen and online | **No singleton player state.** Two local players share one network peer, so peer id can never identify a player |
| C2 | The world streams in and out from day one | **No long-lived `Node` references between systems.** Address by `entity_id`, resolve on use |
| C3 | Save at any instant, restore exactly | **No gameplay state that lives only in the scene tree** |
| C4 | First person now, third person later | Camera is a rig **owned by the slot**, never a child of the pawn's visual tree |

### The splitscreen/online trap, stated exactly

Godot's multiplayer authority is per-peer. With splitscreen one machine drives two pawns and
`is_multiplayer_authority()` returns `true` for both.

```gdscript
# WRONG — passes for both local splitscreen players
if pawn.is_multiplayer_authority():
    apply(intent)

# RIGHT
if slot.is_local() and event.device == slot.device_id:
    slot.intent.apply(event)
```

Input routes by **device**, then slot. Network authority is a separate check used only for
replication. Conflating the two is the single most likely way that project breaks.

---

## 2. The five core abstractions

`scripts/core/`, `scripts/autoload/`.

### `ControlIntent` — the only way into a pawn

Nothing ever calls `pawn.move()`. A controller fills an intent; the pawn reads it. Player
input and AI produce the *same* struct, so a pawn cannot tell who is driving it, and AI and
players run identical movement and weapon code.

```gdscript
var move: Vector2          # pawn-local, -1..1
var look: Vector2          # radians this tick
var buttons: int           # held
var buttons_pressed: int   # edge, this tick only
var buttons_released: int
```

Weapon button bits (`FIRE`, `AIM`, `RELOAD`, `SWAP`, `GRENADE`) were **reserved from day one**
even though nothing read them, so adding weapons later touched no plumbing. Do the same for
brick-mode buttons (`PLACE`, `ROTATE`, `PICK`, `DELETE`, `EXPORT`).

### `Pawn` — anything a controller can drive

`@abstract class_name Pawn extends CharacterBody3D`. Carries `entity_id`, `intent`, `faction`,
`get_camera_mount()`, `serialize()`, `deserialize()`.

> **Recorded regret:** it extends `CharacterBody3D`, not `Node3D`. GDScript has single
> inheritance, so a future `RigidBody3D` pawn needs the base split into a component any body
> type can host. **For brickcity, decide this up front** — brick vehicles and debris want to
> be rigid bodies.

### `PlayerSlot` — one per human, local or remote

`slot_index`, `peer_id`, `device_id`, `pawn_id`, `viewport`, `camera_rig`. `SessionManager`
owns `Array[PlayerSlot]`, max 4, and replicates the slot table — never pawn transforms.
Practical limit: one mouse exists, so local slot 0 gets keyboard+mouse and locals 1+ are pads.

### `EntityRegistry` — ID → node, the only legal lookup

Autoload `Dictionary[int, Node]`. **ID allocation is load-bearing:**

- **Authored entities:** `entity_id` is a deterministic hash of `(chunk_coord, node_path)`. It
  must produce the same value every time that chunk streams in, or saves and network sync both
  break the first time a player walks away and returns.
- **Runtime-spawned:** host allocates from a counter, high bits tagged with the spawning peer
  so clients can predict-spawn without collision.

### `WorldState` — one serializer, three consumers

The highest-leverage decision in their plan. Saving the game, sending world state to a joining
client, and persisting a chunk about to unload are **the same operation**.

```
{ format_version, world_seed, world_delta, live_entities, slots, time_of_day, rng_state }
```

- `world_delta` — `Dictionary[entity_id, Dictionary]`, each entity diffed against its authored
  chunk baseline. Written on chunk unload, held in memory, flushed on save.
- **Write safety:** binary `var_to_bytes` → `save.tmp` → rename over `save.dat`. Never write in
  place; a crash mid-save must not destroy the previous save.
- **Restore order:** clear world → install `world_delta` → restore slots and pawn positions →
  stream chunks around those positions → spawn `live_entities` → hand control back.
- In multiplayer only the host saves. Loading live means the host loads and every client takes
  a full resync — the same payload a joining client gets.

**They built save (M4) before netcode (M5) deliberately**, because the snapshot serializer *is*
the join payload. Building networking first means writing that serializer twice.

---

## 3. World streaming and the authored island

### Two independent streaming systems, never conflated

1. **Terrain** — generated per chunk from a pure sampler. (Terrain3D was adopted on paper and
   never needed; it runs its own region streaming and must stay separate from entity streaming.)
2. **Entities and props** — their own `ChunkStreamer` autoload.

They wrote `ChunkStreamer` rather than adopting an addon because streaming is the load-bearing
wall, and the best available addon ships with a "may cause unexpected node deletion" warning.

Key rules:

- Grid of fixed cells, 128 m, radius 3 → 49 live chunks. Generation is pure maths on
  `WorkerThreadPool`; **node building is budgeted to one chunk per frame** so arrivals do not hitch.
- **Never bake a navmesh at runtime** on dense authored geometry. They ended up baking per chunk
  on a worker because the world is generated and there is no authored scene to pre-bake — with
  bakes serialised through a queue and only within `NAV_RADIUS` of a player.
- **Residency rule:** a client loads the union of chunks around *its local viewers*; the host
  loads the union around *every player*, because the host simulates for everyone.
- **Pinned entities:** player pawns and squadmates are flagged `persistent` and never unloaded.
  Without this a squadmate evaporates the moment you drive away.
- On unload, entity state is diffed against baseline into `WorldDelta`.

### The move from procedural to authored, and why

`Docs/Island.md`. The water looked wrong because the *coastline* was wrong. One simplex at one
frequency made every headland ~370 m across and identical; the beach gradient was whatever the
noise happened to do; "fetch" was meaningless in an infinite world.

`IslandMap` is all static and pure so a worker thread calls it without a sampler, and **nothing
in it decides where anything is by noise**: 16 radii by compass point smoothstepped between
neighbours, three octaves of wobble, then bays subtracted and capes added as circles. Beach
profile authored directly (1-in-18 for 80 m, then the plain rising 24 m over 700 m). Relief is
13 named peaks, 3 ridge polylines and one rolling field, `height * u^power` so summit and foot
are both flat. The city is a **disc that suppresses relief** rather than setting a height, so
the authored beach profile always wins at the shore and there is never a step at the waterline.

Numbers: 11.1 km² land, 3968 m N–S, 828 m highest point, roads 30.7% of land.
`tools/island_probe.gd` prints all of it plus an ASCII map headlessly.

**Relevance to us:** a brick city is authored content with a parametric recipe behind it. The
"disc that suppresses relief" trick is exactly how flat build zones at plate-height steps should
meet studded natural ground (spec §4).

### Buildings are map data, not chunk data

`BuildingMap` computes all 972 buildings once at load by walking every chunk through the same
function the chunks use, caches to `user://buildings_<seed>_v<n>.dat`, and draws them from a
**MultiMesh per 512 m cell that never unloads** — about 50 draw calls. Chunks still build the
*colliders* from that same function and the same per-chunk RNG, so physics and the nav bake are
unchanged (the bake reads static colliders, not meshes).

Two non-obvious details:

- **Boxes extend 20 m below their base.** Past the streaming radius the ground is a coarse copy
  sitting up to 18 m low; a building at its true height would hang in the air over it.
- **`LAYOUT_VERSION` must be bumped whenever building rules change**, or a stale cache loads and
  the boxes you see stop matching the boxes you walk into.

### The far distance is one static mesh

`IslandFar`: the whole 6.1 km box at 32 m spacing (~37k verts) built once on a worker at load,
plus a flat sea skirt to 14 km. It never pops, never regenerates, is always complete. A bounded
world pays for itself twice: the far distance becomes a static mesh instead of a streaming ring.

### The view chain — every link must agree

Far plane 12 km · geometry guaranteed to 12.3 km · fog fully closed at 9 km (*inside* the
geometry). Three things were wrong before and each alone capped the view:

1. far plane at 900 m;
2. `fog_density` written in **exponential** units (0.0016) into a **depth**-mode fog, where
   density is *the amount of fog at `fog_depth_end`*, not a rate — so there was effectively no
   fog and the streaming edge stood in clear air;
3. the sky's own ground colour, visible only in the sliver between the last geometry and the
   horizon line, set darker than the fog — a grey band across the whole view.

Fog now takes the sky's horizon colour and so does the sky's ground. A smoke check asserts fog
closes before the rings run out.

### Physics layers and the terrain asymmetry

`scripts/core/layers.gd` is the single source of truth: `TERRAIN`, `PAWN`, `VEHICLE`, `STRUCTURE`.

**Vehicles do not collide with the terrain mesh.** A box collider against a triangle mesh jams on
every slope, so vehicles ride the analytic height field and still collide with buildings, pawns
and each other. Infantry collide with terrain normally. Cost: cars will also climb cliffs that
ought to stop them.

> **Landmine, recorded because it cost a debugging cycle:** Godot derives a face's plane as
> `(p1 - p3) cross (p1 - p2)`, and mesh collision is one-sided. Generated terrain with reversed
> winding is invisible from above *and* lets rays, bullets and falling bodies pass straight through.

---

## 4. Water

`Docs/Water.md` is the most directly reusable document in either project — spec §4's water
section is essentially this system restated in bricks.

### The verdict: build a deterministic Gerstner field; do not adopt an FFT ocean

One pure function, `water(x, z, t, sea_state) → surface`, evaluated in two places from the same
wave table: the **vertex shader** (moves the mesh) and **GDScript** (answers "how high is the
water here and which way is it moving" for swimmers, boats, float-planes). Nothing is simulated,
nothing is read back from the GPU.

Multiplayer consistency then is not a feature to build: every peer evaluates the same function
with the same wave table and a shared clock. That is how Sea of Thieves does it.

| | Gerstner field | FFT ocean |
|---|---|---|
| Look | Flat-shaded low poly — matches the art direction | Photoreal choppy; fights vertex-colour low poly |
| Physics query | Same trig on CPU, no latency | GPU readback a few frames late, or a second CPU FFT |
| Rivers and lakes | Same function, different mask | Ocean only |
| Multiplayer | Wave table + clock, ~40 bytes | Readback makes host/client physics disagree by frames |

### The field

`WaterSampler` — pure per `(x, z, seed)`: `level_at`, `kind_at`, `depth_at`, `wave_mask_at`,
`flow_at`. Ocean is wherever terrain is below sea level. Lakes sit on a jittered 640 m grid with
their **own levels**; the field digs the basin and *raises a rim*; each drains by a straight
leveed stream to the lowest neighbour or the sea.

**Carving happens inside `WorldSampler.height_at`**, so every consumer — chunk mesh, vehicle
ground sampling, spawn placement, nav bake — sees the riverbed for free without knowing water
exists. `height_at` is called 1089 times per chunk build and once per vehicle axle per tick, so
it has to stay cheap.

### The wave function

A `SeaState` is a table of at most **16** waves (direction, wavelength, amplitude, steepness),
padded with zero amplitude so the uniform layout never changes. Speed is **not authored**:
deep-water dispersion gives `c = sqrt(g·λ / 2π)`, so long swells outrun chop correctly.
Two bands: 8–12 swell/chop scaled by the mask, 3–4 ripples present everywhere so lakes are not glass.

Things they found only after looking at a beach:

- **Openness, not mask, per vertex.** The combined mask is near zero exactly where shore waves
  must live, so the mesh carries openness and both sides apply shoaling from depth.
- **Shore band phased on depth, not direction.** `A(depth) · sin(k·depth + ω·t + drift(x,z))` —
  crests become lines of equal depth, so the band always runs along the shore whatever the wind
  does. Phasing on a bending direction was tried on paper and rejected as incoherent.
- **Groups.** Two envelopes (170 m and 240 m) travelling with the wind modulate swell and chop
  ±30%, which is what makes one stretch heaped and the next calm. Steepness capped at 0.65 so a
  group peak never loops a crest.
- **Exposure.** Eight rays to 420 m over raw land, cached per 32 m grid corner, bilinear between
  corners, carried per vertex in `CUSTOM0.r`. Swell gain `smoothstep(0.12, 0.85)`, chop
  `smoothstep(0.04, 0.5)`, shore band keeps 35%. Both sides apply the same curves.
- **Every wave is at least 7.5 m long.** The mesh is a 4 m grid; anything shorter came out as
  moiré streaks across every lake.
- **Far LOD is capped by `max_wave_number`.** Under ~4 samples per wavelength a Gerstner crest
  lands between vertices and the surface boils. The 16 m ring keeps swell of 44 m+ and drops chop;
  the 32 m ring is flat — which is what distant sea looks like anyway.
- **Transparency:** clear at the waterline (turns the jagged seam of two low-poly surfaces into a
  soft edge), opaque past ~180 m and written to the depth pre-pass there so the seabed is culled.
  Each ring hides its own water inside the ring that covers it — an uncovered one reads as a
  second sea from underwater.

> **Direct hit on our spec:** spec §4 says "avoid true alpha, Godot sorts per object not per
> instance." Confirmed here. Their answer is `depth_prepass_alpha` plus opaque-past-a-distance.

### Physics consumers — one query, three users

Nothing touches the physics server. Water is a height function exactly like the terrain field
vehicles already ride.

- **Swimming:** `immersion = surface - feet`. Wet boots from 0.3 m; swim past 1.25 m — gravity
  off, spring toward `surface - 1.35` (head clear), jump surfaces, crouch dives. 22 s of air.
  AI shares the code.
- **Navmesh:** terrain faces with any corner below `SEA_LEVEL - 1 m` go into a *second collider*
  outside the navigation source group — solid to stand on, invisible to the bake. Simpler and
  exact, versus the planned `NavigationObstacle3D` per wet chunk.
- **Boats:** `HullSampler` fits a weighted plane to five probes (bow, stern, port, starboard,
  centre); heave/pitch/roll spring-damped toward it; a hull >0.35 m above its line is airborne.
  Plus planing lift past 7 m/s and a push down the fitted plane at 30% of gravity so an idle boat
  slides down swells.

### Netcode

Host appends `wave_clock` (one float) to every 20 Hz batch, plus the sea-state blend tuple on
change and once a second. **Under 40 bytes total.** Clients slew their clock at ≤5%, snap past
1 s error; phase error stays under ~50 ms, which on a 6 s swell is under 1%.

### Measured cost (GDScript, µs per call)

`height_at` 1.2 over hills / 2.2 in lowlands · wave mask 4.0 · Gerstner height query 23 calm /
25 storm (four inversion passes) · six-probe boat tick with normal 0.25 ms · a chunk with a water
tile generates in 14 ms on the worker vs 11 ms without.

### Consequences for the world generator (do these early)

Adding a sea level touched five places: roads (end at the coast, **bridge carved water** with a
2.6 m clearance deck — without decks a river severed both the road grid and the navmesh into
islands), spawns (skip anything wet), territory, sand colour, and picking `SEA_LEVEL` itself from
a headless sweep (`tools/sea_level_sweep.gd`).

---

## 5. Surfaces, vehicles and traffic

### `Surface` is derived, not painted

Every vehicle spec assumes a painted surface map keyed by collision group. They have no map and
need none — the same analytic field that decides where roads and beaches are answers the question:

```
water over the driving surface  → WATER      (negative on a bridge, so a deck is asphalt)
on the road grid                → ASPHALT
district BEACH                  → SAND
district CITY / CITY_CORE       → CONCRETE
district SUBURB                 → GRASS
district OUTSKIRT               → DIRT
district HILL / MOUNTAIN        → ROCK if steep, else GRASS / GRAVEL
```

Three consequences, and they are why it is worth doing this way: nothing to author or stream;
every peer agrees without talking; and **it answers off the map** — a plane 3 km out can ask what
it would be landing on before anything down there has streamed in.

Per-surface: `looseness`, `roll_drag` (a **force**, not a fraction of speed, which is why sand
nearly stops a light bike and merely slows a heavy one), `roughness`, `wheel`, `can_land`, `floats`.
`looseness` was calibrated so asphalt returns exactly 1.0 and dirt/grass return exactly the tyre's
own number — **the new model changed nothing that already worked**, and an acceptance test pins that.

### One solver: support points

`PlanarChassis` (heave+pitch on N axles, no roll) and `HullSampler` (heave+pitch+roll from a
least-squares plane through N probes) are the same object at two fidelities. Unified as:

```
VehicleFrame
  support points at (forward, right, kind)
  kinds: WHEEL  spring + damper against ground support
         FLOAT  buoyancy against a water plane
         GEAR   a WHEEL that can be retracted
         SKID   rigid contact, no travel
  solves heave, pitch, roll
```

> **A support point does not know what vehicle it is on. It asks the surface what is under it.**

Roll stays **locked** for motorcycles. Not a limitation to fix later — it is the design decision
that makes a bike unable to fall over sideways, and it is what Trials does.

### Locomotion modules, not vehicle classes

Five vehicle types is fifteen hybrid pairs, so hybrids cannot be classes. A vehicle is a frame
plus modules — `Wheels`, `Hull`, `Wing`, `Rotor`, `Thruster` — and **each reports an authority in
0..1** from the medium it is actually in. The frame blends what they produce.

No mode enum, no transition state machine, no "am I a boat right now" branch. A car driving off a
slipway does not switch modes; its wheels run out of ground while its hull finds water, and **the
blend is the transition**. A machine with no hull sinks, honestly, by the same rule.

**This is the pattern for brick vehicles built from parts.** A player-assembled machine is a frame
plus whatever modules its parts contribute.

### Spec tables stay physical, never behavioural

`VehicleSpec` splits into `ChassisSpec / AxleSpec[] / TyreSpec / DriveSpec / AeroSpec / HullSpec? /
WingSpec? / RotorSpec? / RiderSpec? / AidPackage`. Two rules worth not re-litigating:

- **Driver aids are a player setting, not a car property.** The reference projects get this
  structurally wrong.
- **There is no "if sport bike then wheelie less" anywhere.** Four machines feel completely
  different out of one code path because the numbers are physical.

### Traffic — speed is a minimum of constraints

`Docs/Traffic.md`. The part worth keeping if everything else is rewritten:

```
target = min(district limit, corner, junction, whatever is in front)
approach_speed(target, distance) = sqrt(target² + 2 · brake · distance)     # v² = u² + 2as
```

Every constraint is phrased identically — *be down to this by there* — and the driver records
**which constraint won** in `reason`, so a jam is diagnosable rather than guessed at. Braking is
5.5 m/s², deliberately well under the physical limit: traffic braking at its limit reads as panicking.

- **The network is derived, not authored.** A junction coordinate *is* a grid index (`Vector2i`).
  Nothing to build, stream or sync; two vehicles a kilometre apart agree without having met; and
  because identity is a dictionary key, junctions can be **reserved**.
- **Reservations** are first-come-first-served with a 9 s expiry so a wreck cannot lock a
  crossroads. A driver that cannot get one must be *stopped before the box*, which falls out of the
  same `approach_speed` call with target zero. Anything that stops a vehicle being traffic — death,
  culling, a player boarding, leaving the tree — must call `stand_down()`.
- **Corners** are a quadratic Bezier from the incoming lane, through the point where the two lane
  lines actually cross, to the outgoing lane. Using the crossing as the control point is what makes
  the curve hug the correct side instead of cutting across oncoming traffic.
- **What is in front** comes from a spatial bucket (26 m cells) rebuilt once per physics frame and
  read lazily, instead of 450 pawn checks per vehicle per tick.
- `lane_right = direction.cross(Vector3.UP)` — heading north (−Z) puts east (+X) on the right.
  The opposite cross product gives the opposite answer, which is a real bug they hit.

---

## 6. AI, squads and the wanted system

### Squad behaviour — three rules, in the order they win

1. **A casualty outranks a target.** A target will still be there afterwards; a bleedout will not.
   Being badly hurt outranks both, because a dead medic revives nobody.
2. **The leash outranks the fight.** Past 26 m from your leader you fall back toward your formation
   slot, *still shooting on the way*. Without this a squad dissolves on contact and thirty seconds
   later there are five separate fights. Cover selection obeys the same leash.
3. **Formation, not a huddle.** Each member holds an offset in a wedge, snapped onto the navmesh so
   a leader in a doorway does not leave the squad without a reachable destination.

**Dying is two events, not one.** `pawn_died` fires when a member goes *down* (out of the fight
immediately); `pawn_lost` fires when the 25 s bleedout expires. Kit inheritance hangs off the
second — a body that might still be picked up must not have already handed its launcher away.

In combat a body resolves its path against its **current facing** rather than turning to face it,
so it can fall back or walk round a building while still shooting. Before this, `_steer_towards(aim)`
overwrote the yaw after the path had set "forward", and every AI in combat walked straight at
whatever it was shooting at.

### AI level of detail is what makes hundreds of NPCs affordable

Tick rate *and the right to query the navigation server* are both functions of distance to the
nearest player. Beyond ~110 m `AIBrain` drops to direct steering; navigation only covers a 3×3
chunk box around the player. The two ranges are matched deliberately.

### The wanted system — worth reading even though we may not need police

`Docs/Wanted.md` is a model of how to make a reputation system decidable instead of vibes:

```
cost = base weight  ×  what your own side makes of it  ×  who saw you
```

- **Witnesses are tracked individually, not as a boolean**, because *who saw you* decides which
  authority hears about it. Each authority is credited once per crime by its **loudest** witness —
  five civilians watching is not five crimes.
- **Ceilings.** Some offences must never *build*. Brandishing is capped at 1 star however long you
  stand there. Found by looking at a screenshot: it was charged on the 0.4 s witness tick — 0.625
  stars/second — so five stars and ten police arrived after eight seconds of doing nothing.
- **Bodies with radios.** Killing a cop or a soldier reaches that authority at ×0.5 *with nobody
  watching*: the victim called it in. Everything else genuinely needs a witness.
- `HeatManager` and `WantedManager` **share one witness pass**, because tracing line of sight to
  every pawn is the expensive half of both.
- Responders arrive from ~82 m, **at most two per 2.5 s tick**, so nobody watches a squad appear,
  and they are pinned so they are not culled on the way in.
- Responders carry `hunt_id`: looking for **one person**, whatever the hostility matrix says — which
  is how a soldier gets hunted by his own military police, and how a dispatched body converges
  without line of sight the way a radio call works. Firing still needs line of sight.
- **Responders are not saved.** Loading a four-star save should send fresh police, not restore the
  exact eight who happened to be alive.

---

## 7. Netcode model

Host-authoritative. One player hosts (peer 1) and simulates the world and all AI; clients predict
only their own pawn and interpolate everything else.

**Why not rollback** (they researched netfox and rejected it): rollback re-simulates every
rollback-aware entity for N ticks on every misprediction. In a streamed open world with four
players in different chunks and hundreds of AI, that cost scales **with world contents, not with
player count**. Revisit only if the local pawn feels bad, and then apply it to the local pawn alone.

- Transport v1 `ENetMultiplayerPeer`, direct IP/LAN, swappable for `steam-multiplayer-peer` later
  *if nothing above it assumed ENet*.
- **Interest management** drives `MultiplayerSynchronizer.set_visibility_for(peer, bool)` off chunk
  residency. Apply the filter to *every* synchronizer on an entity; a mismatch between two
  synchronizers on one entity produces the classic "spawns but never moves" bug.
- Adopt a shared fixed tick (netfox `NetworkTime`) from M1. Cheap, and everything later hangs off a
  consistent clock.

**Known gaps, stated plainly:** no client-side prediction (a client's own body is simulated on the
host); deaths, damage, wanted levels and the whole squad layer are host-only, so a joining client
gets a body that can move and shoot and nothing else.

---

## 8. Performance discipline

`Docs/Performance.md`. This section is the most transferable thing in the project.

### Measure with a tool, not by reasoning

```bash
godot --path . --resolution 1280x720 -- --perf
```

```bash
godot --headless --path . --quit-after 150000 -- --census
```

`--perf` is an **ablation**, not a profiler: it turns one system off at a time, measures, turns it
back on, with a fresh baseline between every pair. A profiler says which function is hot; this says
*how much of the frame would come back if a system stopped*, which is the number that decides what
to do. `--census` counts bodies over time and runs headless because the question has nothing to do
with drawing.

`-- --shot` prints real engine counters per frame:

```
perf[04_dusk] fps=50 process=22.88ms physics=12.78ms | draw_calls=449 | nav regions=49 agents=219 polys=2243 edges=4660
```

### Read the probe sceptically

With six Godot instances open, baselines for **identical** configurations swung between 36 ms and
133 ms and two systems scored a *negative* cost. **Close the editor before quoting a number.** If a
configuration measured twice disagrees with itself, throw the run away. Repeat any measurement three
times before believing it. Two stray headless processes once produced a consistent, entirely
fictitious 10× slowdown that was initially blamed on navigation.

### The two traps

1. **`persistent` did not mean what it says.** It marks a body the streamer must not despawn, but
   it was *also* read as "simulate at full rate, never cull" (`if controller_slot >= 0 or persistent`).
   Every squad member is persistent, so a couple of dozen bodies ran a full physics step from any
   distance. Cost: **5.8 ms of a 17.3 ms frame** — a third of the budget on squads nobody could see.
   Two things had to come with the fix: LOD distances multiplied per body type
   (`Pawn.phys_lod_scale()` returns 8 for aircraft), and `needs_full_rate()` pinning a body when
   coarse stepping would *diverge* rather than merely coarsen (an aircraft with its wheels down).
2. **A culled body stayed an avoidance agent forever.** `AIBrain._physics_process` returns early when
   culled — correctly — but the brain's own LOD lives *after* that return, so avoidance stayed on
   indefinitely. At 530 culled bodies that is most of the agent count, and **physics time tracks the
   navigation agent count** more closely than anything else (27 agents = 1.8 ms; ~500 agents = 8–13 ms).
   Fixed in `Pawn._set_culled` — it cannot live in the brain, because the brain is what is not running.

### The measured shape of the world

~571 pawns churning to 847 as chunks stream; ~530 culled, ~28 strided, ~13 at full rate; civilians
61% of population. Culling past 110 m took 74 fps → **258** and two-pane splitscreen 56 → **135**,
physics 14 ms → 6.5 ms. **A cull is not a despawn:** state is kept and the body returns intact.

> **The instinct to fix a population cost by fielding fewer NPCs is the wrong one.** The evidence
> pointed at the *rate* bodies were simulated at and at two outright defects.

### Splitscreen, stated plainly

N viewports means the streamed world is rendered N times. Recommendation: **cap local splitscreen
at 2** and reach 4 players only across machines. Two related rules, set before the HUD existed:
HUD is a `CanvasLayer` *inside each player's SubViewport*, never a child of the scene root; and
every gameplay signal carries a `slot_index` or an `entity_id`. Tag every sound `WORLD`
(positional, correct to hear twice) or `PER_SLOT` (must play once into that slot's bus) — getting
this wrong is the classic splitscreen audio bug.

---

## 9. Process — the Gauntlet Loop

`Docs/GauntletLoop.md`. Worth adopting wholesale; it is what makes "good enough" a decision instead
of an opinion.

**No feature enters without a Feature Card:**

```markdown
### Feature: <name>
- **Milestone:** M<n>
- **Acceptance test:** <one sentence a human can execute and get yes/no>
- **Files touched:**
- **Gates that apply:** G1 G2 G3 G4 G5 G6
- **Iteration budget:** Major 3 / Minor 1
- **New signals declared:**
```

**Severity routes against the acceptance test and the gates, not against taste:**

| Severity | Definition | Budget |
|---|---|---|
| Close Enough | Test **passes**; defects cosmetic | Exactly **1** iteration, then accept as-is with a note |
| Major Failure | Test **fails**, or any gate fails | Up to **3** iterations |
| Regressive Loop | More errors than last turn, **or a gate that previously passed now fails** | **Halt immediately** for a human decision |

A gate regression is always a Regressive Loop even if the error count went down.

**Their standing gates** (adapt for us): works with 2 local splitscreen players · survives chunk
unload+reload · survives save→quit→load identically · works as host *and* client · no `Node`
references held across systems · all mutable gameplay state appears in a `serialize()`. The last
two are static review checks from day zero.

---

## 10. What to take, and what not to

**Take directly**

- The five abstractions (§2), especially `ControlIntent` and one-serializer-three-consumers.
- The entire water design (§4). Our spec already describes it; this is the implementation.
- Derived-not-authored surfaces (§5) — for us, brick material under a contact point.
- `VehicleFrame` + locomotion modules (§5) as the model for part-built machines.
- Traffic's minimum-of-constraints (§5) and the derived junction network.
- The performance tooling and measurement hygiene (§8) — build `--perf` and `--census` equivalents early.
- The Gauntlet Loop (§9).

**Take with a change**

- `Pawn extends CharacterBody3D`. Decide the rigid-body split *before* writing pawns; brick debris
  and player-built vehicles want `RigidBody3D`.
- Chunk streaming. Ours also has to stream *brick-level* data, which is a second, finer tier than
  anything here — see [reddawn.md](reddawn.md#7-lod-and-activation-bubbles).
- Navmesh cell size: theirs is 2 m and was picked during a bad measurement. 1 m gave 9014 polygons
  and a 184 ms frame; 2 m gave 2243 and 23 ms. Re-derive ours; do not inherit the number.

**Do not take**

- Rollback netcode (rejected with reasons, §7).
- Four-way local splitscreen (untested and structurally expensive).
- The wanted/heat system as a feature — but read it as a template for any reputation or
  consequence system we do build.
