# Elemental Weapon & Damage System — Technical Spec

**Engine:** Godot 4.6 · **Language:** GDScript · **Style:** Data-driven Resources, inspector-configurable, no hardcoded constants.

This spec is written to be implemented section-by-section. Each section lists the
files it touches and the contracts between them. Implement in the order given;
later sections depend on earlier ones.

---

## 0. Design pillars (the "why")

1. **Impact hits the top bar; status leaks to its tuned layer.** A bullet's raw
   damage always lands on the enemy's outermost defense layer. The *elemental
   status* it applies (DoT, freeze, amplify) can bypass directly to the layer it
   is tuned against. This is the canonical acid-on-shielded-enemy case: the round
   chips the shield, the acid DoT eats the health underneath.
2. **Everything that designers tune is a Resource.** Elements, the effectiveness
   matrix, defense layers, and status definitions are all `.tres` files. Code
   never hardcodes "shock beats shield" — it reads it from data.
3. **Readability through data, not color luck.** Color is presentation only.
   Effectiveness is an explicit matrix so the acid/health, shock/shield, etc.
   relationships are authored, auditable, and re-tunable.

---

## 1. Elements

**Files:** `scripts/elements/element.gd`, `resources/elements/*.tres`

`Element` is a `Resource` describing one damage element. Seven ship at launch:

| id (StringName) | display | color | role |
|---|---|---|---|
| `acid` | Acid | yellow | DoT vs health |
| `corrosive` | Corrosive | green | DoT vs armor |
| `shock` | Shock | blue | DoT vs shield |
| `fire` | Fire | red | DoT vs flesh/plant |
| `ice` | Ice | white | freeze + slow + amplify-taken |
| `slag` | Slag | purple | no DoT; amplifies ALL incoming damage |
| `radiation` | Radiation | green-glow | spreading DoT, jumps to nearby enemies |

`Element` fields (all `@export`):
- `id: StringName`
- `display_name: String`
- `color: Color`
- `status_scene: PackedScene` — the status this element applies on hit (null = pure impact, e.g. a non-elemental "kinetic" element)
- `base_status_chance: float` — 0..1, the gun's element_chance multiplies this
- `tags: Array[StringName]` — freeform classification, e.g. `&"dot"`, `&"freeze"`, `&"amplify"`

> **Open design note:** Acid and corrosive are split (BL folds them into one).
> This is intentional and means a single enemy *can* require three different
> elements (shock→shield, corrosive→armor, acid→health). Treat 3-bar enemies as a
> rare archetype, not the default trash mob, or readability suffers.

---

## 2. Effectiveness matrix

**Files:** `scripts/elements/effectiveness_matrix.gd`, `resources/effectiveness_matrix.tres`

A single `Resource` that answers: *"How effective is element X against layer-type
Y?"* Stored as a dictionary keyed by `StringName` element id → dictionary of
`StringName` layer_type → `float` multiplier.

```
{
  &"shock":     { &"shield": 2.0, &"armor": 0.5, &"health": 1.0 },
  &"corrosive": { &"armor": 2.0,  &"shield": 0.5, &"health": 1.0 },
  &"acid":      { &"health": 1.75, &"armor": 1.0, &"shield": 1.0 },
  ...
}
```

- `get_multiplier(element_id, layer_type) -> float` — returns 1.0 if unspecified.
- Defaults to 1.0 so unlisted combos are neutral, never zero (avoids accidental
  immunity).
- This matrix governs both **impact** scaling on the top bar AND **DoT** scaling
  on the tuned layer.

---

## 3. Defense layers

**Files:** `scripts/combat/defense_layer.gd`, `scripts/combat/health_pool.gd`

A **defense layer** is one bar (shield, armor, health, or any custom type). Fully
data-driven — the system supports any number of layer types.

`DefenseLayer` (`Resource`, used as config; runtime state lives on the node):
- `layer_type: StringName` — e.g. `&"shield"`, `&"armor"`, `&"health"`, extensible
- `max_value: float`
- `regen_rate: float` (per second, 0 = none) — shields regen, health usually 0
- `regen_delay: float` — seconds after taking damage before regen starts
- `display_color: Color`

`HealthPool` is a `Node` on each enemy holding an **ordered** array of live layer
states (top bar = index 0 = outermost). Responsibilities:
- Track current value per layer.
- `apply_impact(amount, element_id)` — subtract from the **topmost living layer**
  only, scaled by the effectiveness matrix for that layer's type. Overkill does
  NOT carry to the next layer by default (configurable flag `impact_carries_over`).
- `apply_to_layer_type(amount, layer_type, element_id)` — used by DoTs to hit a
  specific layer directly, bypassing layers above it. If that layer type is dead
  or absent, fall back to topmost living layer.
- Emits signals: `layer_depleted(layer_type)`, `died()`.

> **Bypass rule, precisely:** impact → `apply_impact` (top bar). A DoT status, when
> it ticks, calls `apply_to_layer_type` against the layer it is tuned for. That is
> the entire "scud damages bottom health bar directly" behavior.

---

## 4. Damage packet & resolution

**Files:** `scripts/combat/damage_packet.gd`, `scripts/combat/damage_system.gd`

`DamagePacket` (`RefCounted`, not a Resource — it's transient per-hit):
- `amount: float` (raw impact)
- `element: Element`
- `source` (who fired it)
- `hit_position: Vector3`, `hit_normal: Vector3`
- `crit: bool`

`DamageSystem` — the single entry point. `resolve(packet, target_health_pool)`:
1. Compute impact multiplier = matrix(element, topmost layer type) × slag bonus ×
   ice "amplify-taken" bonus × crit.
2. `health_pool.apply_impact(scaled_amount, element.id)`.
3. Roll `element.base_status_chance × gun.element_chance`. On success, instantiate
   `element.status_scene` and attach to target's `StatusManager` (Section 5).
4. Return a result struct for hit feedback (numbers, colors).

Keep ALL damage flowing through this one method so multipliers compose in one
place. Do not let weapons subtract health directly.

---

## 5. Status manager & status effects

**Files:** `scripts/status/status_manager.gd`, `scripts/status/status_effect.gd`,
plus one script per concrete status.

`StatusManager` is a `Node` on each enemy. Holds active `StatusEffect` children.
- `apply(effect: StatusEffect)` — handle stacking via each effect's
  `stack_policy` (`refresh` | `stack` | `ignore`).
- Ticks effects each physics frame; removes expired ones.
- Exposes query helpers: `is_frozen() -> bool`, `damage_taken_multiplier() -> float`
  (product of all active multipliers, e.g. slag × frozen).

`StatusEffect` base (`Node`):
- `@export duration: float`, `tick_interval: float`, `stack_policy`
- `tuned_layer_type: StringName` — which layer its DoT bypasses to (empty = topmost)
- `damage_per_tick: float` — the lingering DoT damage each tick.
- `instant_burst_damage: float` — an instant elemental hit dealt the moment the
  effect lands (and on each subsequent re-proc), SEPARATE from the lingering DoT.
- `dot_strength: float` — used for "strongest applier wins" on re-proc.
- virtual `_on_apply()`, `_on_tick()`, `_on_expire()`
- DoT subclasses call `health_pool.apply_to_layer_type(dmg, tuned_layer_type, element_id)`

### The damage model (final — kinetic baseline + element on top)
Every gun deals **kinetic impact** to the topmost living layer (the existing
`DamagePacket.amount` → `apply_impact`). An *elemental* gun ALSO, on a successful
proc, does two things, both bypassing to the element's tuned layer:
1. **Instant burst** (`instant_burst_damage`) — a one-time elemental hit per proc.
2. **Lingering DoT** (`damage_per_tick`) — starts/refreshes the burn.

So your canonical example works exactly: shoot a shield-over-armor enemy with
corrosive → kinetic hits the shield, while the corrosive instant-burst AND the
corrosive DoT both bypass straight to the armor underneath, even with the shield up.

**Where fire-rate scaling lives:** the lingering DoT is FLAT (one stack, refresh —
see below), so it does NOT scale with fire rate. The instant burst fires per
successful proc, so it scales with `fire_rate × element_chance`. Balance elemental
classes by tuning `element_chance` against fire rate (fast guns get low element
chance, slow guns high) so the burst contribution lands in the same band.

### Stacking rules (final)
- **Different elements coexist** independently on one enemy (fire + corrosive both
  burn). They have different `status_id`s, so `StatusManager` holds them side by side.
- **Same element = ONE stack, no per-player ownership.** A re-proc does NOT add a
  second stack. It calls `reapply_from(incoming)`, which:
  - always refreshes the timer;
  - upgrades `damage_per_tick`/`duration` ONLY if the incoming proc is stronger
    (`dot_strength` higher) — "strongest applier wins," so a weak gun can't downgrade
    a strong burn, it just refreshes it;
  - fires the incoming proc's instant burst regardless (per-shot element damage
    always lands).
- This is the simplest model (chosen over per-player stacking) and matches how
  Borderlands behaves: same-element DoT does not stack on reapply, it refreshes.

Concrete statuses to implement:
- **AcidDoT** — tuned to `&"health"`.
- **CorrosiveDoT** — tuned to `&"armor"`.
- **ShockDoT** — tuned to `&"shield"`; high tick, short duration.
- **FireDoT** — tuned to flesh/plant layer; **decision: DoTs keep ticking under
  ice** (freeze does NOT pause them).
- **Slag** — no DoT; sets a `damage_taken` multiplier on StatusManager for its
  duration.
- **Radiation** — DoT that, on each tick, queries nearby enemies (Area3D) and has
  a chance to spread a fresh radiation stack to them.
- **Frozen** — see Section 6.

---

## 6. Freeze & shatter (the showpiece)

**Files:** `scripts/status/frozen_status.gd`, `scripts/enemy/freeze_visual.gd`,
`scripts/enemy/shatter_controller.gd`

### Gameplay behavior
- While frozen: enemy movement/AI halts (lock root motion + nav).
- `damage_taken_multiplier` increases (e.g. ×3) — stacks with slag.
- DoTs continue ticking (per decision above).
- If the enemy is **airborne** when frozen → on thaw/land it takes large fall
  damage proportional to fall distance.
- If the enemy **dies while frozen** → trigger shatter (Section below) instead of
  the normal death.

### Freeze visual (runtime, no pre-authoring required path)
For each limb `MeshInstance3D` on the rig:
1. Duplicate the mesh into a sibling "ice shell" MeshInstance3D.
2. Assign the frozen transparent material (shared, one StandardMaterial3D).
3. Inflate the shell slightly along vertex normals (grow factor `@export`,
   ~1.03–1.08). **Caveat:** normal-inflation splits on hard edges/UV seams. For
   hero enemies, prefer a pre-authored ice-shell mesh per limb assigned in the
   inspector; fall back to runtime inflation for generic mobs.
4. Parent the shell to the same bone so it follows the (now frozen) pose.

### Shatter on death
- Requires per-limb **fracture meshes** (pre-authored) OR reuse the limb meshes as
  whole chunks. Each becomes a `RigidBody3D` chunk.
- On shatter: hide the skinned mesh, spawn chunks at limb transforms, apply
  outward impulse (scaled by remaining velocity + an explosion factor), let
  physics + a despawn timer handle cleanup.
- **Perf caveat:** doing duplicate-per-limb + rigidbody-per-chunk for many enemies
  at once will spike draw calls and physics islands. Cap concurrent shatters and
  pool chunks. This is the most likely thing to need a Rust/GDExtension pass later
  if mobs are dense; keep the visual layer isolated so it can be swapped without
  touching combat logic.

---

## 7. World effects

**Files:** `scripts/status/ice_bomb.gd` (+ decals/area scenes)

- **Ice bomb** → spawns a snow decal/patch on the ground and a `Area3D` "snow
  field." Decide gameplay: at minimum it's visual; recommended it also slows
  enemies and optionally applies light freeze buildup. Author as data so it can be
  visual-only or gameplay depending on the field.

---

## 8. Weapon integration (thin)

**Files:** `scripts/combat/weapon_element.gd` (component)

Weapons stay dumb. A weapon carries:
- `element: Element`
- `element_chance: float` (multiplies `base_status_chance`)
- base damage, fire rate, etc. (existing weapon code)

On a confirmed hit, the weapon builds a `DamagePacket` and calls
`DamageSystem.resolve(packet, target.health_pool)`. That's the only coupling.

---

## 9. Build order (do this in sequence)

1. `Element` + a couple `.tres` elements.
2. `EffectivenessMatrix` + its `.tres`.
3. `DefenseLayer` + `HealthPool` (with impact + apply_to_layer_type).
4. `DamagePacket` + `DamageSystem.resolve`.
5. `StatusManager` + `StatusEffect` base + AcidDoT (proves the bypass end-to-end).
6. Remaining DoTs (corrosive, shock, fire, radiation) + Slag.
7. Frozen status + freeze visual.
8. Shatter controller.
9. Ice bomb + snow field.
10. Weapon component wiring.

Sections 1–5 are the vertical slice that proves the core loop
(shoot shielded enemy with acid → shield chips, health melts).

---

## Amendment A — Split-damage model, element ratio, vital-layer death

**Supersedes** the impact rule in §3/§4 and the death rule in §3 where they conflict.
Pairs with [MANUFACTURER_SPEC.md](MANUFACTURER_SPEC.md) and the rarity/TTK model in
[GUN_SCALING_SPEC.md](GUN_SCALING_SPEC.md) §1.

### A.1 Per-gun element ratio (replaces the "kinetic class vs elemental class" split)
Guns are not "kinetic OR elemental." Each gun carries `element_ratio: float` in `[0,1]`
(a rollable / class-biased stat on `GunStats`):
- `0.0` = pure kinetic · `~0.25–0.5` = standard elemental · `~0.5–0.75` = laser/plasma.

On a hit with total damage `D`:
- `kinetic_portion   = D * (1.0 - element_ratio)`
- `elemental_portion = D * element_ratio`

Same total; only the split differs. **Raw damage is at class-parity** — a kinetic and an
elemental gun of the same class/rarity/tier hit the same base number. There is **no flat
raw penalty either way** (supersedes the earlier "elemental = 75% raw" and the
"pure-kinetic +20% bonus" framings — both dropped). Elemental guns are never a raw
downgrade; kinetic vs elemental is a *utility-vs-reliability* trade, not a damage tier:
- **Elemental upside:** matched-layer bypass + DoT + status/CC (big, situational).
- **Elemental cost (soft, situational only):** only the *elemental portion* is resisted
  vs the *wrong* layer (0.5× on that fraction, not the whole hit — a mismatched laser
  lands ~80% effective, never 50%), plus a lower crit multiplier.
- **Kinetic identity (needs no raw bonus):** highest crit multiplier, stagger, overpen,
  and **never resisted** (flat 1.0 on every layer) — best vs no-layer/flesh enemies and
  precision-crit builds.

### A.2 Split routing (supersedes §4.1 impact-multiplier step)
Per hit, in `DamageSystem.resolve`:
- **Kinetic portion → topmost living layer** via `apply_impact`, at **flat matrix 1.0**
  (kinetic is never resisted or bonused by layer type). Crit / slag / frozen multipliers
  still apply to this portion.
- **Elemental portion:**
  - If the gun's element **matches a layer type present** on the target →
    `apply_to_layer_type(matched)` with the effectiveness-matrix multiplier — the elemental
    *impact itself* bypasses barriers above that layer.
  - Else (no matching layer present) → hits the **top** layer with the matrix multiplier
    (which may be a 0.5× wrong-element penalty). This is the "wrong element = worse" case.
- **DoT proc** (unchanged, §5): `apply_to_layer_type(tuned_layer_type)`.

So a matched-element gun sends BOTH its elemental impact and its DoT to the core, while
kinetic chips the top bar. `element_ratio` decides how much of each hit does which.

### A.3 Vital-layer death (supersedes §3 "all layers depleted → died")
Each enemy designates a **vital layer** (default: the bottom-most layer, typically
`&"health"`). **The enemy dies the instant its vital layer reaches 0**, even if barrier
layers above it still have value.
- **Kinetic / wrong-element path:** `apply_impact` drains barriers top-down (topmost-living
  index descends as layers deplete); it eventually reaches and empties the vital layer →
  death. Universal but slower against multi-layer enemies.
- **Matched-element path:** elemental impact + DoT bypass straight to the vital layer and
  can **kill through intact barriers** — the reward for correct matching.
- **Consequence (intended):** barriers are *skippable* by the correct element. Shields/armor
  are hard walls for the kinetic/wrong-element path and speed-skips for the matched path.

`HealthPool` changes: add `@export vital_layer_index: int = -1` (`-1` = last layer).
`_check_death()` = dead if `_current[vital] <= 0.0` OR `_topmost_living_index() == -1`.

### A.4 Feel (design intent)
- **Pure kinetic** (ratio 0): reliable workhorse — best raw, high crit + stagger, never
  resisted, no matching to think about.
- **Split** (~0.5): solid raw AND procs elements; matched enemy shredded, wrong enemy a
  bit softer but the kinetic half always lands.
- **Laser** (high ratio): tickles the wrong layer, melts the right one + heavy DoT + can
  core-kill through barriers. Specialist, high reward for matching.

The `element_ratio` axis = reliability ↔ specialization, chosen per gun.
