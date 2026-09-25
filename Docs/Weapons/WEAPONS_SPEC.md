# Weapon Classes, Ammo & Barrels Spec

**Engine:** Godot 4.6 · **Genre:** FPS rogue-lite.
**Pairs with:** [GUN_SCALING_SPEC.md](GUN_SCALING_SPEC.md) §1.5 (`WeaponClass` resource +
per-class base damage/fire rate), [ELEMENTAL_SPEC.md](ELEMENTAL_SPEC.md) Amendment A (`element_ratio`),
[MANUFACTURER_SPEC.md](MANUFACTURER_SPEC.md) (parts/slots — barrel is a slot).

Defines the 8 weapon classes, the 4 shared ammo types, and the barrel-attachment system
that turns any class into a kinetic, hybrid, or laser gun.

---

## 0. Pillars

1. **8 classes, 4 ammo types (paired).** Two classes share each ammo pool — a light and a
   heavy sibling. Keeps ammo economy simple, gives each pool two feels.
2. **Barrels decide projectile + element_ratio, not the class.** Any class can become a
   laser via its barrel part. Lasers reuse the class's ammo (cosmetic "cells/fuel") — no
   5th ammo type.
3. **Class-parity DPS.** Classes differ in *feel* (per-hit vs fire rate, precision vs
   spray), not raw power. Avoids the GUN_SCALING §1.5 "dominated-weapon" trap so all loot
   stays viable. (This leans the §1.5 parity↔ranking choice toward **parity**.)

---

## 1. Ammo types (4)

| ammo | classes | feel |
|---|---|---|
| `light`  | Pistol, SMG        | plentiful, cheap, fast churn |
| `rifle`  | Rifle (AR), LMG    | the workhorse mid pool |
| `sniper` | Sniper, DMR        | scarce, precision, high per-shot |
| `shell`  | Shotgun, Revolver  | scarce, burst, high per-shot |

**Revolver uses `shell`, on purpose.** Powerful revolvers fire large slugs / .410-style
shotshells (real thing — a "Judge"). They get big visual rounds and high crit. **Weak
revolvers are just classified as Pistols** (`light` ammo). So "Revolver" the class = the
heavy hand-cannon; light revolvers live under Pistol.

---

## 2. Weapon classes (8)

`WeaponClass` (`Resource`, GUN_SCALING §1.5). Pistol base_damage = **10** is the reference
and **60 base DPS** is the parity target every class is tuned to. Numbers below are the
shipping values in `WeaponClass._PRESETS`.

| class | ammo | base_dmg | fire_rate | base DPS | mag band | crit× | role / feel |
|---|---|---|---|---|---|---|---|
| Pistol   | light  | 10.0 | 6/s   | 60.0 | 10–16 | 1.75 | versatile all-rounder, reliable |
| SMG      | light  | 4.5  | 13/s  | 58.5 | 25–40 | 1.4  | spray, close, high status uptime, big mag |
| Rifle    | rifle  | 8.0  | 7.5/s | 60.0 | 24–40 | 1.75 | mid-range workhorse |
| LMG      | rifle  | 6.5  | 10/s  | 65.0 | 80–120| 1.5  | suppression, huge mag, spin-up, heavy recoil, slow reload |
| DMR      | sniper | 15.0 | 3.5/s | 52.5 | 12–18 | 2.25 | semi-auto precision, ranged safety |
| Sniper   | sniper | 44.5 | 1.35/s| 60.1 | 4–6   | 3.0  | one-shot precision delete, tiny mag |
| Shotgun  | shell  | 30.0*| 1.6/s | 48.0 | 5–8   | 1.6  | point-blank burst (*spread across pellets*), drops off hard at range |
| Revolver | shell  | 32.0 | 2/s   | 64.0 | 5–7   | 2.75 | big-slug hand-cannon, high crit |

*Shotgun `base_dmg` is total across the pellet spread; per-pellet = total / pellet_count.

> **`base_damage` is a 10× downscale of the original table** (pistol 100 → 10) so a
> level-1 rifle reads ~9 per shot, not ~89. Enemy HP moved by the same constant, so
> shots-to-kill and gun `score` are unchanged —
> [GUN_QUALITY_NAMING_SPEC.md](GUN_QUALITY_NAMING_SPEC.md) §7.2.

> **`base_fire_rate` has a hard floor of 1.25.** The feel roll bottoms at 0.80×, and no
> gun may fire slower than 1.0 shots/sec (QUALITY_NAMING §4.4). Sniper moved from
> `450 / 1.2` to `44.5 / 1.35` for this reason — it was the only class that failed.

> These are the "worst-common, level-1" bases for GUN_SCALING §1.5. Rarity ×mult and
> tier-anchor ×mult apply on top (unchanged). Tune fire_rate/base_dmg per class to hold
> rough DPS parity while keeping the feel distinct; confirm against the 3s TTK target.

---

## 3. Barrels → projectile type & element_ratio

The **barrel** part slot (MANUFACTURER_SPEC §3) sets a gun's projectile behavior and its
`element_ratio` (SPEC Amendment A). Any class accepts any barrel family.

| barrel family | projectile | element_ratio | notes |
|---|---|---|---|
| **Kinetic** (default) | solid slug/bullet, hitscan or fast projectile | `0.0` (or low if an element part is added) | pure kinetic identity: flat, high crit, stagger |
| **Hybrid / Infused** | bullet with elemental coating | `~0.3–0.5` | solid raw + meaningful element |
| **Blaster (laser)** | individual energy bolts, bullet-like (discrete shots) | `~0.5–0.7` | eats class ammo as "cells"; high element, low kinetic |
| **Beam (laser)** | continuous hitscan beam | `~0.6–0.75` | ammo drains per second; highest status uptime; strong on matched layer, weak on wrong |

- Lasers **reuse the class's ammo pool**, cosmetically named cells/fuel per gun. No 5th
  ammo type.
- Optional **heat-vent gimmick** (rare barrel / manufacturer effect, NOT an ammo type):
  the gun never reloads — it vents heat instead. This is the "energy no-reload" fantasy,
  delivered as a gimmick so the 4-ammo economy is untouched. Pairs naturally with beam
  barrels and the Rapid brand.
- Beam barrels change the fire model to continuous: DoT-style application, `on_hit` fires
  per tick — the fire-rate proc normalization (MANUFACTURER_SPEC §7.1) treats a beam's
  tick rate as its fire rate so status doesn't over-proc.

---

## 4. Integration notes

- `WeaponClass.stat_ranges` carries the class's mag band (§2) per GUN_SCALING §3.2
  `absolute_mode`.
- `element_ratio` is set by the barrel part at generation, then lives on `GunStats`
  (SPEC Amendment A.1). A gun with no element rolls `element_ratio` per its barrel but has
  no `element` → the elemental portion is inert (behaves as kinetic) until an element part
  is present. Keep it simple: no element ⇒ treat as fully kinetic regardless of barrel.
- Ammo pools are tracked per `ammo` type on the player, not per gun. Swapping guns that
  share an ammo type draws from the same pool.

---

## 5. Build order

1. `WeaponClass` `.tres` for all 8 (GUN_SCALING §1.5 already defines the resource).
2. 4 ammo-pool types on the player + per-type reserve tracking.
3. Barrel part family (kinetic/hybrid/blaster/beam) setting `element_ratio` + projectile
   model. Prove kinetic + one laser barrel on the same class.
4. Beam continuous-fire model + tick-based proc normalization.
5. Heat-vent gimmick (optional, later).
