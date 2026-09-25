# Integration Spec — Merging the Three Systems

**Engine:** Godot 4.6. Reconciles three bodies of work into one stack:
- **Our design specs** — [ELEMENTAL_SPEC.md](ELEMENTAL_SPEC.md) (elemental sim + Amendment A),
  [GUN_SCALING_SPEC.md](GUN_SCALING_SPEC.md), [MANUFACTURER_SPEC.md](MANUFACTURER_SPEC.md),
  [WEAPONS_SPEC.md](WEAPONS_SPEC.md), [PROGRESSION_SPEC.md](PROGRESSION_SPEC.md),
  [META_SPEC.md](META_SPEC.md), and the moved core in `scripts/`.
- **ProceduralGunSystem** (imported) — physical gun assembly + skins.
- **ElementalParticales** (imported) — element FX package.

This spec is the **authoritative ownership + seam map.** Where any imported code disagrees
with it, this spec wins.

---

## 0. Layer ownership (final)

| layer | owner | notes |
|---|---|---|
| Generation, stats, effects, merges, rarity | **ours** | GUN_SCALING + MANUFACTURER + WEAPONS |
| Gun model: assembly, sockets, skins, reload/shot presentation | **ProceduralGunSystem** | keep as-is |
| Combat sim: defense layers, matrix, bypass, vital-death, element_ratio | **ours** | scripts/combat + scripts/status + SPEC Amendment A |
| Status **ticking loop** (perf) | **ElementalParticales pattern** | single global autoload, flat array — runs OUR status model |
| Element **FX**: overlay, particles, shatter, dissolve, surfaces | **ElementalParticales** | demoted to FX-only |
| Enemy meshes/gaits | **ProceduralChracters** (GDExtension) | later; enemies get HealthPool + ElementalTarget |

---

## 1. Ruling 1+5 — Elemental: our sim, their ticker, their FX

### Sim = ours
`Element` (`.tres`), `EffectivenessMatrix`, `DefenseLayer`, `HealthPool` (layered, matrix,
`apply_impact` / `apply_to_layer_type`, `vital_layer_index`, vital-death), `DamageSystem`,
`StatusEffect` model (bypass to `tuned_layer_type`, strongest-applier-wins, instant burst +
lingering DoT). All from SPEC §1–6 + Amendment A. **Unchanged.**

### Ticker = their perf pattern, our model (supersedes SPEC §5 per-enemy ticking) — ✅ DONE
Chosen for horde perf ("500 burning enemies = one loop", no per-enemy Timers).

- **New autoload `StatusTicker`** (`autoload/status_ticker.gd`): owns ONE flat
  `Array[StatusEffect]` and the single `_physics_process` hot loop. It calls `fx.tick(delta)`
  on each of **our** `StatusEffect` nodes and auto-prunes freed/expired ones. `StatusEffect`
  no longer runs its own `_physics_process` (renamed to `tick()`), so there is exactly one
  loop. Each effect still routes its DoT through the target's **`HealthPool.apply_to_layer_type`**
  (bypass to tuned layer) — never a flat `health` float.
- **`StatusManager`** stays the per-enemy orchestrator + view: stacking (refresh /
  strongest-applier-wins), `is_frozen()`, `damage_taken_multiplier()` (slag × frozen) for
  `DamageSystem`, and it **registers** each applied effect with the global ticker. It runs no
  `_physics_process` of its own. Effects stay decoupled from the ticker (no back-reference).
- **Deferred to the slice (step 7):** `ElementalManager`'s sim (`ELEMENT_PARAMS`, its private
  `StatusEffect`, `deal_damage`/`take_damage`) + `ElementalTarget.health` are now **dead —
  nothing in our pipeline calls them** — but the strip + FX-rewire happens when FX can be
  verified on a live enemy. `ElementalManager` is retained meanwhile as the FX-material
  service `ElementalTarget` references. Health/death authority is already `HealthPool`.

### FX = theirs, driven by the sim
Their `ElementalTarget` becomes a **pure view component** (mesh refs, sockets,
`set_overlay` / `begin_dissolve` / `set_frozen` / fx_handles) + death FX. Their static
toolboxes (`acid_effect.gd`, `fire_effect.gd`, …) stay as FX-only and pair 1:1 with our sim
statuses:

```
StatusTicker (our model, global loop)
  on apply/tick/expire of a status
    → target.HealthPool.apply_to_layer_type(...)        [SIM: our damage]
    → target.ElementalTarget.set_overlay/begin_dissolve  [FX: their visuals]
    → <Element>Effect.on_applied/on_update/on_removed     [FX: their toolbox]
HealthPool.died
    → ElementalTarget.play_death_fx()  (shatter if frozen, via VfxPool)  [FX]
```

### Element bridge (id ↔ FX)
Our elements are `Element` resources keyed by `id: StringName`; their FX used a hardcoded
`enum`. Bridge with a registry `element_id → { fx_toolbox, color }`. The 7 ids match the 7
enum entries (acid/corrosive/shock/fire/ice/slag/radiation), so the map is 1:1. FX reads
color from the `Element` resource; sim reads matrix/tuned-layer from data. No enum in sim.

---

## 2. Ruling 2 — Rarity: our 6 tiers replace their 5

Their `GunGenerator` ships 5 tiers (Common–Legendary, weights `[55,25,12,6,2]`, no Mythic,
`damage×(1+0.12·(r-1))`). Replace with GUN_SCALING §1:

| id | mult | note |
|---|---|---|
| common | 1.00 | |
| uncommon | 1.20 | |
| rare | 1.50 | |
| unique | 2.00 | renamed from their "epic" |
| legendary | 2.00 | == unique raw; differs by special abilities/parts |
| mythic | 3.00 | new top tier |

- Add a 6th weight + the `mythic` band. Update `RARITY_NAMES` → 6 entries.
- Rarity affects **damage only** via our `GunStats` (not their flat `+12%/tier`). Rarity
  also raises the number of filled part slots (more effects → more merges), per MANUFACTURER
  §0.3.

---

## 3. Ruling 3 — Effects ride on real parts, plus modless mods, plus brand badges

Three effect sources, all feeding the same effect list the merge system reads:

### 3a. Real parts carry effects (primary)
Extend their **`GunPartDef`** (physical: slot + `scene` + sockets + `manufacturer`) with an
**effect payload**:
```
@export var effect_id: StringName            # &"ricochet", &"explosive", ... ("" = none)
@export var effect_params: Dictionary
@export var effect_compat_tags: PackedStringArray
@export var effect_incompatible_tags: PackedStringArray
@export var effect_min_rarity: int
```
So a physical barrel part both **assembles a model** (their system) and **carries a mechanical
effect** (our MANUFACTURER system). One resource, two roles. The generator respects
`effect_incompatible_tags` when filling slots (MANUFACTURER §4).

> Slot reconciliation: their `Slot` enum (BODY/BARREL/STOCK/GRIP/MAG/SIGHT/MUZZLE/UNDERBARREL)
> is the **physical model slot**. Our "effect slots" were logical — an effect simply rides on
> whichever physical part hosts it. **Merges are slot-agnostic**: they read the gun's
> aggregate effect list, no matter which part contributed each effect.

### 3b. Gun mods (equipped power-ups, NO physical part)
`PowerUp` (MANUFACTURER §8) stays a separate equipped item that carries a weapon power-up
**without** a physical gun part: universal buff to all guns + supercharge of a matching
effect the gun already carries. These do NOT assemble geometry.

### 3c. Manufacturer badges (brand-affinity reward) — NEW
Rewards running brand-pure without forcing it (set-bonus flavor, keeps mix-and-match free):
- The gun tracks **brand affinity** = count of physical parts per `manufacturer`.
- A **`ManufacturerBadge`** (`Resource`) can be slotted onto a gun **only if the gun has
  ≥N parts from that manufacturer** (`required_brand_parts`, default 2). It grants that
  brand's **set bonus** (a strong brand-flavored effect).
- Data: `badge_id`, `manufacturer_id`, `required_brand_parts`, `effect_id`, `effect_params`.
- Fully optional: mixed-brand guns just don't qualify for badges but lose nothing else.

All three sources append to one `active_effects: Array` on the resolved gun; merges,
supercharge, and badges all read that single list.

---

## 4. Ruling 4 — Stats: our GunStats replaces their stub

Replace their `GunStats.compute()` (base `damage 10`, `+12%/tier`) with the GUN_SCALING +
WEAPONS model:
- Per-**WeaponClass** base damage / fire rate (WEAPONS §2; pistol=100 reference).
- Tier-anchor level multiplier (PROGRESSION §1 `effective_level` → GUN_SCALING §2 curve).
- Rarity damage multiplier (§2 above), applied to damage only.
- Coherent stat rolls (GUN_SCALING §3.1), `StatRange` per class.
- **`element_ratio`** on the resolved `GunStats` (SPEC Amendment A), set by the barrel part
  family (WEAPONS §3: kinetic 0 → beam 0.75).
- Their per-part `stat_add`/`stat_mult` payloads are kept as an **additional modifier pass**
  (parts/manufacturer tweaks) layered under our scaling — their carrier, our curve.

Their generator's determinism (`(library, seed)` → gun, serializable recipe) is **kept** —
it satisfies GUN_SCALING §5 step 8 (multiplayer/seed). We extend it, not replace it.

---

## 5. Gun ↔ combat seam

The weapon controller is the bridge (thin, per MANUFACTURER §8 / SPEC §8):
1. Reads final `GunStats` (ours) off the `GunInstance` (theirs).
2. On a confirmed hit, builds a `DamagePacket`: `amount` = the hit's total damage, plus
   `element` (`Element` resource), `element_chance`, `element_ratio`, `crit`.
3. Calls `DamageSystem.resolve(packet, target_root)`. `DamageSystem` splits kinetic/elemental
   by `element_ratio` (Amendment A.2), routes to `HealthPool`, rolls status → `StatusTicker`.
4. `GunInstance.play_shot_effects()` handles muzzle/trail/sound (theirs). Effects
   (ricochet/explosive/…) are dispatched by the weapon controller off `active_effects`.

No circular coupling: generation → stats → instance (model) → weapon controller →
DamageSystem → HealthPool/StatusTicker → FX.

---

## 6. Conflict-resolution summary

| # | collision | resolution |
|---|---|---|
| 1 | two elemental sims | our sim; their **ticker pattern**; their FX (demoted) |
| 2 | rarity 5 vs 6 | our 6 tiers (+unique +mythic), our mults |
| 3 | effects home | real parts carry effects + gun mods + **manufacturer badges** |
| 4 | two GunStats | our GunStats (their per-part payloads kept as a modifier pass) |
| 5 | element enum vs resource | our `Element` resources; id↔FX bridge registry |

---

## 7. Proposed res:// layout (merge target)

```
res://
  scripts/
    elements/   element.gd, effectiveness_matrix.gd              [ours]
    combat/     defense_layer, health_pool, damage_packet, damage_system   [ours]
    status/     status_effect, status_manager(→registry/view), acid_dot, frozen_status, ...  [ours]
    guns/       gun_part_def(+effects), gun_receiver_def, gun_barrel_def, gun_part_library,
                gun_assembler, gun_generator(ours-extended), gun_stats(ours), gun_instance,
                gun_skin_def/library/applier, weapon_class, rarity, manufacturer,
                power_up, manufacturer_badge, merge_rule                   [merged]
    enemy/      freeze_visual, elemental_target(FX view)          [ours + theirs]
  autoload/
    status_ticker.gd   (was elemental_manager; global loop, our model)
    vfx_pool.gd        [theirs]
  fx/
    elements/  acid_effect, fire_effect, corrosive, shock, slag, radiation, ice, arc_ribbon  [theirs]
    shaders/   elemental_overlay, acid_dissolve, ice_shard, puddle_decal, electric_arc, ground_fire  [theirs]
    emitters/  (generated by emitter_factory)
    surfaces/  surface_base/ice/oil/water                          [theirs]
  shaders/     gun_skin.gdshader                                    [theirs]
  resources/   *.tres (elements, matrix, rarities, classes, manufacturers, parts, skins, badges)
```

Imported code currently sits under `Docs/ProceduralGunSystem/` and `Docs/ElementalParticales/`;
migration moves it into the tree above (mechanical, like the elemental-core move).

---

## 8. Migration / build order

1. **Move** imported scripts/shaders into the `res://` layout (§7). Register autoloads
   `StatusTicker`, `VfxPool`.
2. **Rarity → 6 tiers** in the generator (§2).
3. **GunStats → ours** (§4); keep per-part payloads as a modifier pass. Verify a generated
   pistol reproduces GUN_SCALING §2.3 reference numbers.
4. **GunPartDef += effect payload** (§3a); merge detection reads aggregate `active_effects`.
5. **Refactor ElementalManager → StatusTicker** (§1): our `StatusEffect` model, global loop,
   routes to `HealthPool`, drives FX toolboxes. Strip their sim + `ElementalTarget.health`.
6. **DamageSystem split routing + vital-death** (SPEC Amendment A) in `health_pool.gd` /
   `damage_system.gd`.
7. **Vertical slice** (revised): assemble a gun (their assembler + our stats) → fire →
   `DamagePacket` → `DamageSystem` → layered `HealthPool` + `StatusTicker` → `ElementalTarget`
   FX. Prove: shoot shield-over-health enemy with a matched-element gun → shield chips from
   kinetic, elemental bypass melts core through the shield, vital-death fires, frozen kill
   shatters.
8. Gun mods (§3b), manufacturer badges (§3c), merges — on top of the proven slice.

---

## 9. Enemy layer (creatures) + FX-update notes

The `ProceduralChracters` folder is a self-contained procedural enemy-body generator
(seeded DNA → skeleton + skinned mesh → physics gait → animation LOD, optional C++
MeshForge). It is **complementary** to this stack, not competing — the body our combat +
FX attach to. **Deferred**; kept as reference. Integration notes so they aren't lost:

### 9.1 Enemy composition
`enemy = ProcCreature (body) + HealthPool (our sim) + ElementalTarget (FX view) +
StatusManager (view)`. `ElementalTarget` export mapping: `body_mesh` = the creature's
`"Body"` `MeshInstance3D`; accent/eye surfaces → `extra_meshes`; creatures have **no**
`AnimationTree` (leave it empty — the updated component treats it as optional).

### 9.2 Freeze on creatures
Creatures animate via `GaitController` + the `SkeletonModifier3D` stack, **not** an
`AnimationTree`. `ElementalTarget.set_frozen` halts motion by calling
`set_movement_enabled(false)` on the creature root — so the creature root must disable its
`GaitController`/`CreatureLOD` in that method. Airborne-freeze fall damage (updated
`ElementalTarget`) uses `CharacterBody3D` ballistics; RigidBody enemies fall on their own.

### 9.3 Acid dissolve on procedural bodies
Dissolve-to-skeleton wants an inner `skeleton_mesh`; procgen bodies have none. Use the
fallback dark emissive-edge silhouette until an inner shell is authored — leave
`skeleton_mesh` empty on procgen enemies.

### 9.4 FX sim-coupling to rewire (migration steps 5–6)
The imported (updated) `ElementalTarget`/`VfxPool` still call
`ElementalManager.deal_damage` / `ElementalTarget.take_damage` and hold a flat `health` —
the **demoted** sim path. Steps 5–6 rewire: fall-damage + status ticks route through our
`DamageSystem`/`HealthPool`; `ElementalTarget.take_damage`/`health` are removed; death
authority = `HealthPool.died` → `ElementalTarget` plays death FX (shatter if frozen).

### 9.5 Native creature extension
The shipped `MeshForge` GDExtension lib is **Linux-only** (`.so`); on Windows
`PartMeshLib.backend = "auto"` falls back to GDScript automatically. A Windows build is
deferred — not needed for the vertical slice.
