# Reference — BoomerBorder (mechs, Borderlands guns, elemental damage, swarm)

**Location:** `C:\Users\lbaun\Documents\boomer-border`
**Stack:** Godot 4.6.2 · GDScript · Jolt · `SwarmCore` C++ GDExtension.
**State:** a set of test beds rather than one game. A Titanfall-2 mech you really sit in (motor,
embark/exit, see-through cockpit, camera feel, arm-mounted gun, summon, an AI brain that follows
and holds), a Borderlands-style procedural gun and loot system, a layered elemental damage model,
a 500-agent C++ horde, and a tower-defence module.

**Why it is here:** this game is going to be an FPS with Titanfall-style mechs, and we will use
this project's **weapon system** as-is. It is also the only prior art for a mech that a player and
an AI can both drive — which is the thing the enemy AI and the player's autonomous mech both hang
off. See [../AI.md](../AI.md).

Primary sources: `Docs/Mechs/titan-embodied-piloting-spec.md`, `Docs/SPEC.md` (elemental),
`Docs/WEAPONS_SPEC.md`, `Docs/GUN_SCALING_SPEC.md`, `Docs/MANUFACTURER_SPEC.md`,
`Docs/GUN_QUALITY_NAMING_SPEC.md`, `Docs/INTEGRATION_SPEC.md`, `Docs/swarm_master_plan.md`,
`Docs/MODULE_AUDIT.md`, `Docs/ProceduralChracters/`, and `iteration_summary.md` (the build log,
features A–L, newest first).

---

## 0. Porting checklist — read before copying anything

**Decided 2026-09-23 ([AI.md §0](../AI.md#0-decided), A6):** the weapon system and its docs, and
the procedural generation system, are **copied** into this project — not shared as an addon. Co-op
comes first. So what comes across has to meet this project's rules on the way in, not afterwards.

### The two fixes

**1. Two gameplay rolls use the global RNG.** Verified 2026-09-23:

| Where | What | Why it matters |
|---|---|---|
| `scripts/combat/damage_system.gd:72` | `if randf() < chance:` — the crit / status-proc roll | decides damage |
| `scripts/effects/effect_dispatch.gd:102` | `pool[randi() % pool.size()]` — which target an effect jumps to | decides who is hit |

[Multiplayer.md §2](../Multiplayer.md#2-why-this-maps-unusually-well-onto-printed-brick-city)
states that there is **not a single `randf()` at any call site** in this project, and D9 depends on
it. Copying these in unchanged makes that sentence false. Both take an injected
`RandomNumberGenerator` owned by the host's combat state (seeded, like `BrickWorld`'s). The only
other global roll in the weapon code, `gun_instance.gd:123`, is shot-audio pitch — cosmetic, leave
it.

**2. The art is Synty; ours must be bricks.** The mechs, pilots and cockpit are Synty meshes, and
the cockpit hatch trick (titan spec §4.1) is written around splitting a Synty mesh. Nothing here may
ship a model that is not our own printable part (spec §1, B3, and the legal brief). **Copy the code,
never the assets** — the titan becomes a brick-built mech driven by the same motor, and its hatch is
bricks.

### Because co-op is first

From BoomerBorder's own `Docs/MODULE_AUDIT.md`, the things that block multiplayer there block it
here once copied:

- **No authority seam.** Every mutation is local and immediate — `HealthPool` damage, pickups,
  loot rolls. Damage has to become a request the host confirms, the same change
  [Multiplayer.md §5](../Multiplayer.md#5-what-is-left) item 3 already asks of `_fire`.
- **Three autoloads hold process-global state** — `StatusTicker`, `ElementalManager`, `VfxPool`.
  Key per-entity and per-player state by owner inside them.
- **`SceneRouter` pauses the whole tree** for its menu. Do not copy that behaviour.
- `ElementalManager`'s own damage sim is dead code (INTEGRATION §1) — strip it on the way in rather
  than carry it.

### Fitting it to this world

- **Mechs aim like the player ([AI.md](../AI.md#0-decided) A15).** `TitanWeapon.arm_pitch_range_deg`
  is `(-45, 40)`; open it to the player's full pitch range. The ±55° arm **yaw** limit relative to
  the torso stays — it is what makes the torso's turn rate matter.
- **Units.** BoomerBorder is metres with no grid; state titan dimensions, step height and nav voxel
  sizes in studs and plates (D6).
- **Guns must also hurt bricks.** Add one mapping, in one place, from gun stats to the structural
  hit (`apply_hit` radius and energy) alongside the elemental damage.
- **Collision layers** go through `Layers` (`scripts/layers.gd`), never as literals.
- **`EntityTime`** comes with it (`scripts/core/entity_time.gd`), and the rule that nothing uses
  `Engine.time_scale`.

### What to copy

Code: `scripts/guns/`, `scripts/loot/`, `scripts/combat/`, `scripts/elements/`,
`scripts/status/`, `scripts/effects/`, `autoload/status_ticker.gd`, `autoload/elemental_manager.gd`
(FX half only), `autoload/vfx_pool.gd`, `scripts/core/`.

Added by the AI review ([AIPlan R18](../AIPlan.md#13--worth-knowing)), because the AI needs them:
`scripts/titan/` (motor, weapon, brains, intents — the mech), `scripts/player/` (`PlayerRig`,
bone sockets — the pilot), `swarmcore/` (the C++ horde, built into this project's extension set),
and the weapon and titan test beds, which become probes here. LimboAI 1.7 comes from Red Dawn's
`addons/limboai`, with Windows and Linux binaries. Docs: `SPEC.md`, `WEAPONS_SPEC.md`,
`GUN_SCALING_SPEC.md`, `MANUFACTURER_SPEC.md`, `GUN_QUALITY_NAMING_SPEC.md`, `PROGRESSION_SPEC.md`,
`INTEGRATION_SPEC.md`, `ProceduralGunSystem/`, `ElementalParticales/`. Procedural generation:
**both** — the gun generator (it comes with `scripts/guns/`) and the procedural creatures in
`Docs/ProceduralChracters/` (spec, handoff, gait, active ragdoll and the merge, with their
reference code). The creature system's GDExtension (`creature_forge`) ships only a Linux `.so`
there; it needs a Windows build before it runs here.

---

## 1. What exists

| Piece | Where | What it is |
|---|---|---|
| Titan | `scripts/titan/titan.gd` (190 KB), `titan_motor.gd`, `titan_weapon.gd`, `titan_exit.gd`, `titan_summoner.gd`, `pilot_state.gd`, `pilot_sway_rig.gd` | Titan M1–M5b, all logged `Success`: locomotion, embark + three exits, see-through cockpit, pilot and titan weapons, gun hand, camera feel, summon (skyfall and behind-you grab), AI brain |
| The brain contract | `titan_intents.gd`, `titan_player_brain.gd`, `titan_ai_brain.gd` | One struct the motor reads; two brains that fill it (§2) |
| Guns | `scripts/guns/` (21 files) | Seeded procedural guns: class, rarity, tier, manufacturer parts, effects, merges, skins, physical assembly |
| Loot | `scripts/loot/` | Loot roller, legendary tables, shields, ability loadouts, world pickups |
| Combat | `scripts/combat/` | `DamagePacket`, `DamageSystem`, `DefenseLayer`, `HealthPool` |
| Elements and status | `scripts/elements/`, `scripts/status/`, `autoload/status_ticker.gd` | Seven elements, effectiveness matrix, DoTs ticked by one global loop |
| Horde | `swarmcore/src/swarm_core.{h,cpp}` (140 KB), `lane_graph`, `flow_grid`; `scripts/swarm/` | 500 agents as rows, promoted to nodes when close |
| Tower defence | `scripts/td/` (29 files) | Lanes, flow fields, waves, turrets, barricades. Documented as a reusable module |
| Core | `scripts/core/` | `EntityTime`, `Spring`/`Spring3`, `ComponentCache`, `BodySeparator` — no game types |
| Creatures (docs + reference code) | `Docs/ProceduralChracters/` | Seeded procedural creatures with gait, an active-ragdoll layer, and the two merged |

Test beds are one-node scenes that build their world in code (`test/*_test.tscn`). The titan bed
alone is 383 KB of GDScript and 86 acceptance checks.

---

## 2. The brain contract — **the one idea to take**

`TitanIntents` is the only thing `TitanMotor` reads:

```gdscript
class_name TitanIntents extends RefCounted
var move_dir: Vector2   # TORSO-LOCAL. x = strafe right, y = forward. 0..1
var aim_yaw: float      # WORLD yaw
var aim_pitch: float
var dash: bool          # edge-triggered; the MOTOR detects the edge
var sprint: bool        # held
var crouch: bool
```

A brain fills one of these every physics tick and the motor consumes it. `TitanPlayerBrain`
copies input into it (and never reads the keyboard — the test bed calls `set_move_input()` and
friends). `TitanAIBrain` fills it from a `NavigationAgent3D` and a mode machine. **Swapping which
brain sits in the `BrainSlot` is the whole of the piloted ↔ autonomous transition.**

What the source says about why, worth repeating here:

- *The motor must never know who is driving.* If it ever reads input, a camera or the player,
  AI and pilot drift apart in feel "one convenience at a time".
- *The AI's output vocabulary is a stick, a look angle and three buttons.* A behaviour that
  cannot be expressed as intents belongs in an ability or the motor, not as a special case in a
  brain.
- The struct is reused, not reallocated — it is polled every tick for every titan.
- `move_dir` is torso-local and the body's own basis stays identity forever; the AI rotates its
  nav direction into the torso's frame by hand. Handing the motor a world vector looks right
  while the torso faces north and steers into a wall when it does not.

> **For us this contract is the Intents seam in [../AI.md §2](../AI.md).** Generalise it to every
> pawn — infantry, mechs, flyers, animals — and add fire, melee, jump and ability slots. It is
> also exactly the shape an ONNX policy's action head should have.

---

## 3. The titan's handling — three rates

Numbers from `titan_motor.gd` and `titan_weapon.gd`:

| | |
|---|---|
| Walk / sprint | 9 m/s, ×1.5 sprint (~13.5 m/s) after a 0.4 s spool |
| Accel / decel | 12 / 16 m/s² — deliberately softer than the pilot |
| Dash | 26 m/s for 0.28 s, 2 charges, 5 s regen, 0.15 steering authority mid-dash |
| Step height | 1.2 m — titans walk over pilot-scale cover |
| No jump | Dash only (spec §1, locked). Simplifies navigation |
| Aim → arm → torso → legs | instant → 420 °/s → 240 °/s → 140 °/s past a 35° threshold |
| Arm yaw limit | ±55° **relative to the torso**, so a 180° aim swing makes the arm wait at the stop for the chest to come round |

The layered rates are the "aim is instant, the machine is heavy" feel. **An AI mech gets exactly
the same lag because it drives the same motor** — which is also what keeps enemy mechs readable
and fair.

Titan scale: capsule radius 1.7 m, nav agent radius 2.6 m, agent height 5.6 m. In our units that
is about 13 bricks tall and 15 studs across the avoidance radius.

---

## 4. The titan AI brain (M5) — what is built and what was deferred on purpose

Built: **FOLLOW** (5/8 m hysteresis band, 2 m repath distance, sprint past 25 m, 0.9 throttle so
the AI "reads as deliberate, not frantic") and **HOLD**. Named but refused by
`command()`: **GUARD** and **COME_TO_PILOT** — refused *by name*, so "not built yet" and "typo"
are different answers.

Worth stealing:

- **Titans get their own navigation map.** Baked at radius 2.6, a 3 m doorway has no polygons, so
  "the titan cannot follow you indoors" is a *property of the bake*, not code. A titan on the
  pilot map walks a 5.2 m body through a 3 m corridor and it looks like a physics bug.
- **Unreachable target = wait, re-test every 1 s.** The Titanfall "titan waits below" behaviour
  falls out of a path failure; do not fight it.
- **No nav map = HOLD, and warn once.** Never silently fall back to the default map — it works in
  a test level and walks through the first doorway in a real one.
- **Commands are `StringName`s through one entry point** (`Titan.command(mode, args)`) so a
  radial, a voice system or a squad UI reaches them without importing the brain.
- Every AI timer runs on the titan's own `EntityTime`, so a stasised titan's re-test freezes too.
- Agent `height` is inert unless 3D avoidance is on; 5.6 not 5.5 because Recast ceils to whole
  voxels at 0.2 m cell height.

Not built: any combat. Targeting, firing, threat response and the `on_threat_detected` hook are
all out of scope in the spec (§1 non-goals). **The enemy mech AI starts from zero here** — only
the locomotion half exists.

Ability framework (spec §12, structure only): `TitanAbility` resource with `can_activate(titan)`,
`activate(titan, intents)`, `tick`, `ended`. AI brains activate slots through the same contract.

---

## 5. Weapons — the Borderlands system we are adopting

A gun is `(library, seed)`: replicate the recipe, never node trees (GUN_SCALING §5.8). That is
already this project's rule for buildings ([README rule 3](README.md)).

- **8 classes, 4 ammo pools, paired light/heavy:** Pistol + SMG (`light`), Rifle + LMG (`rifle`),
  DMR + Sniper (`sniper`), Shotgun + Revolver (`shell`). Class-parity DPS around 60 at level 1 —
  classes differ in feel, not power.
- **The barrel decides the projectile and `element_ratio`,** not the class: kinetic, hybrid,
  blaster (energy bolts) or beam (continuous). Lasers draw the class's own ammo.
- **Six rarities** (common 1.0 → mythic 3.0 damage multiplier), tiers and a hidden level with
  decelerating growth, manufacturers whose physical parts carry effects, merge rules between
  effects, brand badges for 2+ parts of one maker, legendaries with fixed recipes.
- `GunInstance` (`Node3D`) holds `stats`, `recipe`, `weapon_class`, `active_effects`, `merges`,
  and presentation (`play_shot_effects`, `play_reload`, `get_muzzle_position`).
- `TitanWeapon` fires one through `set_aim(yaw, pitch)` / `set_trigger_held(bool)` and emits
  `weapon_fired`. **No input, no view, no locomotion inside it** — so an AI fires it the same way.

> **For AI:** an enemy that holds a real `GunInstance` fires the same gun the player loots from
> it. The AI's job is choosing *which* gun — range band against class, and element against the
> target's outer defence layer (§6).

## 6. Elemental damage and defence layers

`HealthPool` is an ordered stack of `DefenseLayer`s (shield, armor, health, any custom type).
Impact always hits the **top living layer**, scaled by the `EffectivenessMatrix`; a DoT status
bypasses to the layer it is tuned against (`apply_to_layer_type`). Seven elements: acid (health),
corrosive (armor), shock (shield), fire, ice (freeze + amplify), slag (amplify all), radiation
(spreading). Vital-layer death and a split `element_ratio` per gun are in SPEC Amendment A.

All DoTs tick in **one** autoload loop (`StatusTicker`) — "500 burning enemies = one loop".

> **For AI:** the matrix is data, so an AI can read it. "Switch to shock, their shield is up" is
> one lookup, and it is the most Borderlands thing an enemy can do. Mech plating is naturally an
> `armor` layer.

---

## 7. SwarmCore — the horde

`Docs/swarm_master_plan.md`. The same conclusion as [reddawn §9](reddawn.md#9-swarm-engine--c-crowd-simulation),
built further:

- **A zombie's default state is a row of floats.** 500 rows in a struct-of-arrays; a node is a
  rationed promotion (`SwarmPromoter.max_promoted`, default 8).
- **The C++/GDScript boundary is exact:** anything per-agent per-tick is C++; GDScript touches
  things once per event or once per frame. Written down as the rule, not a preference.
- Tiered LOD by budget, not just distance, with hysteresis and per-frame transition caps.
- **Flow fields with vertical layers and portals** rather than a 3D field; WWZ-style pile-ups are
  a fitted ramp model, not emergent physics.
- Host-authoritative; client-side deterministic flocking was rejected because float divergence
  amplifies in a feedback swarm.
- `SwarmCore` is one per tree (two segfault — each owns a field worker thread).

> **For us:** animal herds, rat swarms and drone clouds are rows, not nodes.

## 8. Procedural creatures

`Docs/ProceduralChracters/`: seeded DNA → skeleton + mesh → morphology-independent procedural
gait with LOD, plus an active-ragdoll layer that stumbles, knocks down and recovers, and a merge
of the two. Design docs and reference code, verification planned.

> **For us:** the animals. The gait is a pose provider, so AI drives a creature through the same
> intents as anything else and the body works out its legs.

## 9. Process and rules worth keeping

- **The Gauntlet Loop** (`CLAUDE.md`): Step 0 scope lock with REUSE / NEW / acceptance test
  before any code; severity decided mechanically (a failing acceptance test is Major however small
  the cause); hard budget of 4 builder turns per feature; halt on any backwards step. Close cousin
  of [mvs-c §9](mvs-c.md#9-process--the-gauntlet-loop).
- **`EntityTime`, never `Engine.time_scale`** — per-entity dilation, so a stasis bubble stops one
  target and not the co-op game.
- **Systems expose `set_*_input()` and never poll the keyboard.** Beds own input.
- **Seeded RNG at every gameplay decision.** The module audit found two leaks, both in damage —
  see the [porting checklist](#0-porting-checklist--read-before-copying-anything).
- **No authority model exists yet** — every mutation is local and immediate. Multiplayer is
  designed for and not built (`Docs/MODULE_AUDIT.md`).

---

## 10. What to take, and what to leave

**Take directly**

- The brain contract (§2): one intents struct, pluggable brains, a motor that never knows who
  drives. Generalised to every pawn.
- The titan motor's handling model and numbers (§3), and the arm/torso/legs rate split.
- The titan-scale navigation map and its three rules (§4): own map, wait on unreachable, HOLD
  loudly on no map.
- The weapon, loot and elemental systems (§5, §6), as the game's weapon system.
- The swarm boundary rule and row-not-node model (§7) for crowds of animals and drones.

**Take with a change**

- **Scale.** BoomerBorder is metres with no grid; we are on a 0.35 m stud grid (D6). Titan
  dimensions, step height and nav voxel sizes need restating in studs and plates, and the step
  height has to agree with the brick courses a mech is meant to walk over.
- **Damage numbers.** Its guns kill enemies with `HealthPool` values; ours also have to kill
  *bricks*. A gun needs a structural damage term alongside its elemental one — decide the mapping
  from gun stats to `apply_hit` radius and energy once, in one place.
- **Assets.** Its mechs are Synty meshes. Ours must be brick-built and printable (spec §1,
  B3) — take the code, never the assets.
- **The two global-RNG rolls** move onto a seeded, host-owned RNG (§0).

**Leave**

- `Engine.time_scale` anywhere (they already did).
- The `SceneRouter` whole-tree pause — right for a dev bed, wrong for co-op.
- The Synty-specific cockpit hatch split (spec §4.1); our hatch is bricks.
