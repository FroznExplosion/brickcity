# Weapons, loot and elements — copied from BoomerBorder

Copied 2026-09-24 from `C:\Users\lbaun\Documents\boomer-border` ([AI.md](../AI.md) A6,
[AIPlan](../AIPlan.md) P1). These are BoomerBorder's specs as they stood; the code they describe
now lives here and is ours to change. `SPEC.md` is renamed [ELEMENTAL_SPEC.md](ELEMENTAL_SPEC.md)
so it is not mistaken for this project's spec.

| Doc | What |
|---|---|
| [WEAPONS_SPEC.md](WEAPONS_SPEC.md) | Classes, rarity, parts, the generator |
| [GUN_SCALING_SPEC.md](GUN_SCALING_SPEC.md) | Damage and fire rate per class and tier |
| [MANUFACTURER_SPEC.md](MANUFACTURER_SPEC.md) | Brands, native effects, mods, merges |
| [GUN_QUALITY_NAMING_SPEC.md](GUN_QUALITY_NAMING_SPEC.md) | Quality rolls and names |
| [PROGRESSION_SPEC.md](PROGRESSION_SPEC.md) | Zone tier, no player level |
| [ELEMENTAL_SPEC.md](ELEMENTAL_SPEC.md) | Elements, defence layers, split damage (Amendment A) |
| [INTEGRATION_SPEC.md](INTEGRATION_SPEC.md) | How the elemental FX and the sim were joined |
| [ProceduralGunSystem/](ProceduralGunSystem/) | Generator and skin specs |
| [ElementalParticales/](ElementalParticales/) | Emitter specs for the element FX |

## Where the code went

`scripts/guns/`, `scripts/loot/`, `scripts/combat/`, `scripts/elements/`, `scripts/status/`,
`scripts/effects/`, `scripts/core/`, `scripts/enemy/` (`ElementalTarget`, `FreezeVisual` — the FX
view components), `autoload/` (`StatusTicker`, `ElementalManager`, `VfxPool`), `fx/elements/`,
`fx/shaders/`, `shaders/gun_skin.gdshader`. The suites are scenes, because autoloads do not load
for a `--script` main loop:

    godot --headless --path . res://test/core_test.tscn
    godot --headless --path . res://test/loot_range_test.tscn -- --probe

## Guns and bricks

A bullet that hits something with a `HealthPool` goes through `DamageSystem` as here. A bullet
that hits anything else hits the city, and the city has its own rule: `StructuralDamage`
(`scripts/combat/structural_damage.gd`) — wear by weapon class, blind to tier, rarity and crits.
`GunController` (`scripts/combat/gun_controller.gd`) is what fires a gun for any owner.

## What changed on the way in

Per the [porting checklist](../Reference/boomer-border.md#0-porting-checklist--read-before-copying-anything):

- **No global RNG in a gameplay roll.** The status-proc roll (`DamageSystem.resolve`) and the
  ricochet's target pick (`EffectDispatch._random_enemy_near`) draw from `DamagePacket.rng` /
  `EffectContext.rng`, else the seeded `DamageSystem.rng` that whoever owns combat seeds. What is
  still `randf()` is cosmetic: shot-audio pitch, shatter shards, arc shader seeds.
- **`ElementalManager` is FX only.** Its own damage sim — DoT ticks, slag amplification — and
  `ElementalTarget`'s private `health` / `take_damage` are gone; nothing in the real pipeline
  called them (INTEGRATION_SPEC §1). Damage is `DamageSystem` → `HealthPool`, statuses are
  `StatusEffect` ticked by `StatusTicker`. `ElementalTarget.on_killed()` plays the death look,
  and a frozen landing is a `frozen_landing(damage)` signal for the owner to route.
  Radiation's spread-on-death, which applied a status from a visual hook, is now just the burst.
- **No third-party assets.** The loot bed's character model is a capsule; the dummy's ice
  crystals are a `PrismMesh`; `VfxPool` has no emitter scenes registered until we make our own.
  `fx/emitter_factory.gd` (Synty textures) and `fx/Assets/` were not copied.
- **Autoload state** was already per effect and per target; `VfxPool` is presentation only, so
  each machine keeps its own. `SceneRouter`, which paused the whole tree, was not copied.
