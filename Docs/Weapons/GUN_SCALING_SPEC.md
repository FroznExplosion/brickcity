# Procedural Gun & Stat-Scaling System — Technical Spec

**Engine:** Godot 4.6 · **Language:** GDScript · **Style:** Data-driven Resources,
inspector-configurable, no hardcoded constants. Pairs with the Elemental Weapon
System spec (an `Element` + `element_chance` are gun stats here).

This spec covers the whole generator: how a gun is rolled, how its stats scale by
level and rarity, and how manufacturer archetypes shape feel. The **scaling math is
the load-bearing part** — read Section 2 carefully; it's where the original design
went wrong and where this spec is most prescriptive.

---

## 0. Design pillars

1. **Two independent axes, never compounded into one.**
   `final_stat = base_stat × level_multiplier(level) × rarity_multiplier(rarity)`.
   Level scaling and rarity are separate multipliers. This is the single most
   important rule — folding rarity into per-level growth makes rarity irrelevant
   within a couple of levels.
2. **Gentle, bounded level growth.** Per-level growth is small and constant (or
   gently decelerating), never compounding near ×2/level. A level-100 gun should
   land in the hundreds-of-thousands range, not 10^18, so numbers stay in int range
   and float precision holds.
3. **Obsolescence is a tunable feel, not an accident.** "Replace guns often" is
   achieved by choosing the per-level growth rate, which determines how fast an old
   gun falls behind. One number controls the whole upgrade cadence.
4. **Everything rolled is data.** Rarities, stat ranges, manufacturers, and parts
   are Resources. The generator reads them; it hardcodes nothing.

---

## 1. Rarity

**Files:** `scripts/guns/rarity.gd`, `resources/guns/rarities/*.tres`

`Rarity` (`Resource`):
- `id: StringName` — `&"common"`, `&"uncommon"`, ...
- `display_name: String`
- `color: Color` — UI tint
- `damage_multiplier: float` — the rarity axis.

**Shipping tiers (6, quality-word scale, genre-standard for zero learning curve):**

| id | display | mult | lifespan (levels) | conventional color |
|---|---|---|---|---|
| `common` | Common | 1.00 | 0 (baseline) | white |
| `uncommon` | Uncommon | **1.30** | 2 | green |
| `rare` | Rare | 1.50 | 3 | blue |
| `unique` | Unique | 2.00 | 5 | purple |
| `legendary` | Legendary | 2.00 | 5 | orange |
| `mythic` | Mythic | 3.00 | 8 | red / cyan |

> **The mults are DERIVED, not chosen — the lifespan ladder is the design law.**
> `rarity_mult = (1 + g) ^ lifespan_levels`, where lifespan = how many player levels a
> fresh drop of that tier stays ahead of a fresh Common. At the shipping `g = 0.15` the
> ladder is 2 / 3 / 5 / 5 / 8. Uncommon moved 1.20 → 1.30 because at 1.20 it only lasted
> 1.3 levels. Full derivation, and the CONSTANT-vs-DECELERATING consequence,
> in [GUN_QUALITY_NAMING_SPEC.md](GUN_QUALITY_NAMING_SPEC.md) §1.

> **Unique == Legendary in raw damage (both 2.00) — deliberate.** Legendary pulls ahead
> only via its special abilities / legendary-only parts (grenade-drop, authored 3-part
> merges; see MANUFACTURER_SPEC), so **Unique still feels great** and is not a strict
> downgrade. These mults were tuned to a TTK ladder (Tier-1 common kinetic rifle vs a
> standard enemy): common 3.0s → uncommon 2.31s → rare 2.0s → unique/legendary 1.5s →
> mythic 1.0s. Enemy HP is derived from these targets, not the reverse.

- `stat_roll_quality: float` — 0..1 bias toward the high end of stat ranges (higher
  rarity → rolls skew better, not just more damage). Optional but recommended.
- `part_count_bonus: int` — how many extra rolled parts/anointments this rarity grants.
- `weight: float` — drop-table weight (rarer = smaller weight).

> **Names are cosmetic and fully data-driven** — change `display_name` in the `.tres`
> any time without touching code or math. The multipliers are what matter.

> **Cross-rarity overlap (intentional):** the within-rarity damage spread is **1.35×**
> (worst→best roll; see §3.3). Rarity steps are **uneven** (×1.30, ×1.50, ×2.00,
> ×2.00, ×3.00); the smallest step is common→uncommon (+30%). Because the within-rarity
> spread 1.35 > 1.30, a god-roll common still slightly beats a floor-roll uncommon (best
> common 135 > worst uncommon 130 at level 1). This is the design goal: low-rarity guns with
> great rolls are NOT auto-discarded. **The window widened 1.3 → 1.35 when Uncommon moved
> 1.20 → 1.30** — at 1.3 vs 1.30 the overlap became an exact tie and the rule died.
> Absolute ceiling under the recommended CONSTANT-15% curve (§2.2 open decision) is a
> best-roll Mythic pistol at L100 ≈ **4.2 M**, against a 115 M-HP standard enemy
> (QUALITY_NAMING §7.2). The old 800k / 3.24M figures belong to the DECELERATING curve
> *and* the pre-÷10 base damage; both are superseded.

> Rarity stays relevant at **every** level precisely because it is a separate
> multiplier applied after level scaling. A Mythic is 3.0× a Common at level 1
> and at level 100.

---

## 1.5 Weapon classes (per-class base damage & fire rate)

**Files:** `scripts/guns/weapon_class.gd`, `resources/guns/classes/*.tres`

Base damage is **per weapon class**, not global. The level curve (§2) and rarity
multipliers (§1) are SHARED across all classes — only the base numbers differ. This
is how "SMGs hit for less per bullet, pistols hit for more" is expressed without
duplicating any scaling logic.

`WeaponClass` (`Resource`):
- `id: StringName` — `&"pistol"`, `&"smg"`, `&"shotgun"`, `&"sniper"`, ...
- `display_name: String`
- `base_damage: float` — the worst-common, level-1 per-hit damage for this class.
  **Pistol = 100 (the reference class).** Others set their own (an SMG might be ~40).
- `base_fire_rate: float` — shots/sec at base. Lower-per-hit classes usually fire faster.
- `stat_ranges: Array[StatRange]` — the rollable stats for this class (§3), incl.
  this class's magazine band (e.g. assault rifle 20→60).
- `crit_multiplier: float` — per-class (snipers high, SMGs low), used by DamageSystem.

### Per-class cap derives from base damage (don't set caps directly)
A class's level-100 ceiling is simply:
```
best_mythic_cap = base_damage × 1.28 (best roll) × 3.0 (mythic) × mult(100)
```
You never tune the cap as a separate number — you pick base damage and the cap falls out
of the shared curve.

> ⚠ **All eight `base_damage` values were divided by 10** (pistol 100 → **10**, rifle
> 80 → **8**) so a level-1 rifle reads ~9 per shot instead of ~89. Enemy HP moved by the
> same constant, so shots-to-kill and `score` are unchanged — see
> [GUN_QUALITY_NAMING_SPEC.md](GUN_QUALITY_NAMING_SPEC.md) §7.2. Every absolute damage
> figure in §2.2–§2.4 below still carries the **old 10× values** and describes the
> DECELERATING curve that §2.2's open decision is likely to replace; treat those numbers
> as historical, not as targets.

### DPS vs per-hit — the class-balance decision (READ THIS)
Per-hit damage is a **feel/display** choice. Real class power is **DPS = per-hit ×
fire rate**. A class with low base_damage but high base_fire_rate can match or exceed
a high-per-hit class's DPS. Two valid philosophies, both supported by these same
fields (it's only a question of what numbers you choose):

- **Rough parity:** tune base_damage × base_fire_rate so all classes land in a
  similar DPS band. Classes differ in feel, not power. Maximizes build variety.
- **Intentional power ranking (CHOSEN):** some classes genuinely out-DPS others
  (e.g. pistols weakest → snipers strongest). Simpler, but beware the
  **dominated-weapon risk**: if a class is flatly weaker in DPS with no compensating
  advantage, players abandon it entirely in the endgame and its loot becomes dead.
  To keep a "weaker" class alive, give it a situational edge (reliability, range,
  mobility, ammo economy, handling) so it's *worse on paper, viable in practice*.
  Otherwise accept that lower-tier classes are explicitly early-game-only.

### Current status
All **8 classes** ship in `WeaponClass._PRESETS` (WEAPONS_SPEC §2). Pistol is the
reference at `base_damage 10.0 / base_fire_rate 6.0` = **60 base DPS**, and every class is
tuned to that same ~60 DPS — the **parity** philosophy, not the ranking one the section
above marks as CHOSEN. WEAPONS_SPEC §0.3 makes parity a pillar, so treat parity as the
live decision and this section's "(CHOSEN)" label as stale.

`base_fire_rate` has a hard floor: **≥ 1.25**, because the feel roll bottoms at 0.80× and
no gun may fire slower than 1.0 shots/sec (QUALITY_NAMING §4.4). Sniper was re-solved to
`44.5 dmg / 1.35 fps` to satisfy it while holding 60 DPS.

Adding a class: pick base_damage + base_fire_rate so their product is ~60, check the fire
floor, and the cap derives automatically. No curve or rarity changes are ever needed.

---

**Files:** `scripts/guns/scaling_curve.gd`, `resources/guns/scaling_curve.tres`

### 2.1 Why the original scheme fails (keep this note in the codebase)

The original idea — level 1 = 100, then +100%, +99%, +98% per level — is
*exponential*. Even decreasing the percent each level, you are still multiplying
every level, so:

| Level | Damage (original scheme) |
|---|---|
| 1 | 100 |
| 10 | ~42,650 |
| 20 | ~21.7 million |
| 50 | ~91 trillion |
| 100 | ~8.3 quintillion (8.3×10^18) |

Problems: blows past float32 integer precision (~1.6×10^7) by level ~20; blows past
int64 by level 100; forces enemy HP onto the same insane curve; and makes the
rarity spread (100→250) smaller than a single level-up by level 2. **Do not ship a
compounding curve above ~1.05/level.**

### 2.2 The model

> ## ⚠ OPEN DECISION — the shipping mode is under review
>
> The DECELERATING default is being reconsidered. **The taper it provides already happens
> for free:** later levels take longer in wall-clock time, so a gun falling behind at a
> constant *per-level* rate falls behind at a slowing *per-hour* rate. DECELERATING stacks
> a second taper on top of that one.
>
> It also **breaks the §1 rarity-lifespan ladder**, which only holds where `g` is
> constant. At the end-game `g ≈ 0.04`, a Mythic stays best-in-slot for **28 levels**
> instead of 8.
>
> Constant `g`, the 800k pistol cap, and the 2/3/5/8 ladder are mutually exclusive — pick
> two. Options table and the recommendation (**CONSTANT 15%, cap moves to ~10⁸**) in
> [GUN_QUALITY_NAMING_SPEC.md](GUN_QUALITY_NAMING_SPEC.md) §1.1. Everything below still
> describes the current DECELERATING shipping values; revise once this is called.

`ScalingCurve` (`Resource`) exposes BOTH supported modes via an enum, so the curve
is swappable in the inspector without code changes:

```
enum Mode { CONSTANT, DECELERATING }
@export var mode: Mode = Mode.DECELERATING        # SHIPPING DEFAULT (see below)
@export var max_level: int = 100

# CONSTANT mode: fixed growth each level. (Kept as an alternative; not the default
# because constant growth gives identical obsolescence at every level, which
# contradicts the "replace fast early, slowly late" goal.)
@export var per_level_rate: float = 0.07          # 7%/level

# DECELERATING mode: growth shrinks linearly from start to end across levels.
# SHIPPING VALUES ("Option C", steep-early), tuned for the PISTOL class
# (base_damage 100): worst-common caps at 800,000 at level 100, and a best-roll
# Mythic caps at 3,120,000. start is the early %, end is the near-max %.
@export var start_rate: float = 0.15              # 15%/level at low levels
@export var end_rate: float = 0.039866            # ~3.99%/level near max
```

> **Why these exact numbers (PISTOL reference class):** with base damage 100, the
> DECELERATING product reaches `mult(100) ≈ 8000`, so worst-common caps at
> **800,000**, worst Mythic (×3.0) at **2,400,000**, and a best-roll Mythic
> (×1.3 roll × 3.0 rarity) at **3,120,000** — the ~3.1M ceiling band. The
> steep early rate (15%) gives a visible damage jump every level at low levels (fast
> gun churn); the low end rate flattens growth near cap (gear stays relevant late).
>
> **The curve (start_rate/end_rate) is SHARED across all weapon classes.** Only
> `base_damage` and `base_fire_rate` differ per class (see §1.5). To set a class's
> cap, you pick its base damage; the cap = `base × 1.3 × 3.0 × mult(100)`. To re-tune
> the curve shape itself, keep start_rate and solve end_rate so the pistol's
> `100 * mult(100)` hits the desired reference (binary search; build-order step 2).

`level_multiplier(level: int) -> float`:
- **CONSTANT:** `pow(1.0 + per_level_rate, level - 1)`.
- **DECELERATING:** product over levels 2..level of `(1 + rate(L))`, where
  `rate(L)` interpolates `start_rate → end_rate` by `(L-2)/(max_level-1)`.
  Cache this in an array at `_ready()` since it's a cumulative product — compute
  once, index by level. Never recompute per shot.

### 2.3 Reference output — SHIPPING CURVE (PISTOL class, base 100, 15%→3.99%)

These are the authoritative values the implementation must reproduce in build-order
step 2. Pistol worst-common base = 100; legendary/mythic = the rarity ×mult.

| Lvl | common (worst) | Mythic (worst) |
|---|---|---|
| 1 | 100 | 300 |
| 10 | ~336 | ~1,008 |
| 50 | ~28,900 | ~86,700 |
| 90 | ~512,000 | ~1,536,000 |
| 100 | **800,000** | **2,400,000** |

Best-roll (×1.35) corners at level 100: best common ≈ **1,080,000**; best Mythic ≈
**3,240,000** (the game's current absolute ceiling, from the pistol class). All
values sit comfortably in GDScript's 64-bit float (double) — no precision concern.

#### Display rounding (IMPORTANT — do NOT divide the displayed value)
- Store and compute damage as the **full-precision float** (e.g. 800000.0, 100.4).
- Display = `roundi(real_value)` (or `"%d" % value`). **Do not divide by 100 or any
  factor for display** — dividing makes early upgrades invisible (100 and 120 both
  collapse to "1") and pushes milestones out of reach. Small-numbers-that-grow is
  achieved by the base (100) being small and the curve climbing every level, not by
  hiding the real value.
- The **gun comparison system compares raw floats**, not displayed values. So a
  100.4-damage gun correctly shows as better than a 100.0-damage gun even though
  both display "100" — show a better/worse arrow on the raw comparison.

### 2.4 Tuning obsolescence

A gun N levels below the player sits at `level_multiplier(player-N)/level_multiplier(player)`
of current power. Because the shipping curve is DECELERATING, this ratio is **not**
constant — it is intentionally harsher early (fast churn) and gentler late (gear
lasts). With the steep-early start_rate of 15%, a low-level gun a few levels old
falls off quickly; near max level the ~4% end_rate keeps old gear useful for ~10
levels. To make early churn even faster, raise start_rate (and re-solve end_rate to
hold the 800k pistol cap); to soften it, lower start_rate.

(CONSTANT mode, if ever used, gives `1/(1+rate)^N` flat obsolescence at every level —
7%/level ≈ 51% at 10 levels old, 10%/level ≈ 39%, 5%/level ≈ 61%.)

---

## 3. Stat block & per-stat ranges

**Files:** `scripts/guns/gun_stats.gd`, `scripts/guns/stat_range.gd`

### 3.1 The roll model — COHERENT guns ("never mix bad and good")

Every gun rolls a **damage quality** in `[0,1]` (continuous — 0.0 worst, 1.0 best;
maps to the 1.0×–1.3× within-rarity damage window). The damage roll then **sets the
allowed band for every other stat's roll**, so a gun is internally coherent: good
guns are good all-around, weak guns are mediocre all-around, only mid guns are wild.

```
damage_quality = randf()                       # 0..1, this gun's headline luck
band = other_stat_band(damage_quality)         # the [lo,hi] window others roll in
for each non-damage stat:
    stat_quality = randf_range(band.lo, band.hi)   # INDEPENDENT roll within the band
```

`other_stat_band(d)` (the coherent rule):
- `d >= 0.67` (damage best)   → others roll in **[0.5, 1.0]** (at least middle)
- `0.34 <= d < 0.67` (middle) → others roll in **[0.0, 1.0]** (full range — wild card)
- `d < 0.34` (damage worst)   → others roll in **[0.0, 0.5]** (worst→middle)

> This is the corrected rule. The earlier "damage worst → others can be best" idea
> was dropped because it produced exactly the mixed good/bad guns we want to avoid.
> Band thresholds (0.34/0.67, the 0.5 floors) are tunable constants on the generator.

Non-damage rolls are **independent of each other** within the band, so within a
coherent gun there's still variety (a high-damage gun might have great reload but
merely-good mag), just never a floor-tier stat on a top-tier gun.

### 3.2 `StatRange` (`Resource`) — one rollable stat

- `stat_id: StringName` — `&"damage"`, `&"fire_rate"`, `&"mag_size"`, `&"reload"`,
  `&"accuracy"`, `&"element_chance"`, etc.
- `worst_mult: float`, `best_mult: float` — multipliers applied to the stat's base at
  roll 0.0 and roll 1.0 respectively. **For "lower is better" stats (reload time),
  `best_mult < worst_mult`** (e.g. worst 1.0, best 0.5 = 50% faster). The roll just
  lerps between them, so direction is encoded in the data, not in code branches.
- `absolute_mode: bool` + `worst_value: float`, `best_value: float` — when true, the
  stat ignores base/mult and lerps directly between two absolute values. Used for
  **magazine size** (assault rifle worst 20, best 60). Fixed-ammo guns set a narrow
  band (or worst==best) and just roll within it.
- `scales_with_level: bool` — **`damage` is the ONLY stat that scales with level.**
  Reload, fire rate, mag, accuracy do NOT scale — a level-100 gun reloads exactly as
  fast as a level-1 gun. This keeps secondary stats readable forever.
- `round_to_int: bool` — true for mag size (whole rounds), false for reload/etc.

### 3.3 Spread targets (shipping defaults)

- **damage:** within-rarity window 1.0×–**1.28×**. This is the `dps_mult` roll and it is
  **not** the whole within-tier spread — fire-rate quality (1.06×) and parts (±3%)
  multiply into DPS alongside it for a total of **1.438×**. That total is what must sit
  between the smallest 1-tier step (1.30) and the smallest 2-tier step (1.50), so a
  god-roll of one tier edges out a floor-roll of the next but never the tier above that.
  **Sized against the rarity steps — if §1's Uncommon mult moves, the budget moves with
  it.** Full allocation and boundary table:
  [GUN_QUALITY_NAMING_SPEC.md](GUN_QUALITY_NAMING_SPEC.md) §4.3.
- **reload time:** up to ~50% worst→best. e.g. base 2.4s, worst_mult 1.0, best_mult
  0.5 → 2.4s down to 1.2s.
- **fire rate:** ⚠ **BROKEN AS WRITTEN — do not implement the 1.0→1.5 window.** It
  multiplies into DPS alongside the damage window, giving a real spread of
  1.35 × 1.5 = **2.03×**, wider than the Rare step (1.50) and the Unique step (2.00). A
  god-roll Common out-DPSes every Rare in the game. The coherent-band rule (§3.1) does not
  bound this — a `dq = 1.0` gun rolls fire rate in `[0.5, 1.0]`, so the ceiling is fully
  reachable on the same gun that rolled max damage. **Replace with the anti-correlated
  roll** in [GUN_QUALITY_NAMING_SPEC.md](GUN_QUALITY_NAMING_SPEC.md) §4.3: roll DPS once,
  then trade damage against fire rate at constant product. Fire rate then varies
  0.80×–1.25× (a wider *feel* range) while contributing zero to the power spread.
- **magazine (non-fixed):** absolute_mode, per gun class. Assault rifle 20→60.
- **magazine (fixed-ammo guns):** absolute_mode with a narrow band; just rolls the amount.
- **accuracy / others:** modest windows (e.g. ±6%), designer's call per class.

### 3.4 `GunStats` and resolution

`GunStats` — the resolved final numbers on a generated gun (plain object/dict):
core stats plus `element`, `element_chance`, `level`, `rarity`, and the raw
`damage_quality` (kept for the comparison UI). This is what the weapon consumes.

Resolution per stat:
```
q = (stat is damage) ? damage_quality : randf_range(band.lo, band.hi)
if stat.absolute_mode:
    value = lerp(stat.worst_value, stat.best_value, q)
else:
    value = stat.base * lerp(stat.worst_mult, stat.best_mult, q)
if stat.scales_with_level:                 # damage only
    value *= scaling_curve.level_multiplier(level)
if stat_id == &"damage":
    value *= rarity.damage_multiplier        # rarity axis applies to damage only
if stat.round_to_int:
    value = roundi(value)                    # storage; display rounding is separate
```
> Only **damage** takes the rarity damage multiplier AND the level multiplier. Other
> stats vary by roll and manufacturer, not by rarity/level — otherwise higher rarity
> would be strictly better at everything and rarity collapses to one number.

---

## 4. Manufacturer archetypes

**Files:** `scripts/guns/manufacturer.gd`, `resources/guns/manufacturers/*.tres`

`Manufacturer` (`Resource`) gives guns identity beyond numbers:
- `id`, `display_name`, `color/branding`
- `stat_modifiers: Dictionary` — multiplicative tweaks to specific stat_ids
  (e.g. a "high fire rate, low accuracy" maker: `{&"fire_rate":1.3, &"accuracy":0.8}`).
- `recoil_pattern: Resource` — reference to a recoil curve/resource (sprayed,
  vertical climb, predictable horizontal, etc.).
- `gimmick: StringName` + `gimmick_params: Dictionary` — the manufacturer's signature
  mechanic, dispatched by the weapon. Examples to support:
  - `&"no_reload_vent"` — never reloads; overheats instead.
  - `&"ricochet_on_crit"` — crits spawn a bouncing round.
  - `&"explosive_reload"` — throw the empty mag as a grenade.
  - `&"charge_up"` — hold to charge for a damage/burst bonus.
- `element_bias: Dictionary` — weights for which elements this maker tends to roll.

Gimmicks are dispatched by `StringName` so adding one is a data entry + a small
handler, never a change to the generator core.

---

## 5. Parts & the generation pipeline

**Files:** `scripts/guns/gun_part.gd`, `scripts/guns/gun_generator.gd`

`GunPart` (`Resource`) — barrel, grip, sight, stock, mag, element accessory. Each
part carries its own `stat_modifiers` dict and optional `element`. (Reuses your
tag-compatibility patterns from prior weapon-builder work — parts can declare
`compatible_tags` so the generator only assembles valid combos.)

> **Part rarity is no longer a flat band pick.** Parts roll a per-slot rarity *offset*
> around the gun's rolled rarity (skewed high), which produces the gun's quality grade,
> its name prefix, and its score. See
> [GUN_QUALITY_NAMING_SPEC.md](GUN_QUALITY_NAMING_SPEC.md) §2–§4. The gun's tier and
> colour are still authored by step 2 below and are never changed by parts.

`GunGenerator.generate(level: int, context) -> GunStats`:
1. **Pick gun class** (pistol/SMG/shotgun/...) — sets which `StatRange` set applies.
2. **Roll rarity** from weighted drop table (context may bias luck).
3. **Pick manufacturer** (optionally constrained by gun class).
4. **Roll parts** — per-slot rarity offset (QUALITY_NAMING §2.2), `base_parts +
   rarity.part_count_bonus`, respecting tag compat and `exclusive_to`.
5. **Roll each core stat** via its `StatRange` with rarity quality bias.
6. **Apply modifiers in fixed order:** parts → manufacturer → (then scaling/rarity
   in Section 3 resolution). Order matters for reproducibility; document it.
7. **Assign element** from manufacturer/part `element_bias` (may be none).
8. **Apply level + rarity scaling** (Section 2/3) to produce final `GunStats`.
9. Return `GunStats`. Generation should be **deterministic given a seed** so drops
   can be reproduced/networked — take an optional `rng_seed`.

> Determinism matters for multiplayer: generate from a shared seed so all clients
> roll the identical gun without syncing every stat. Fits your multiplayer-ready
> architecture preference.

---

## 6. Integration with the elemental system

- `GunStats.element` is an `Element` (from the elemental spec).
- `GunStats.element_chance` feeds `DamagePacket.element_chance`, which multiplies
  `Element.base_status_chance` in `DamageSystem.resolve`.
- Gun `damage` is the `DamagePacket.amount` (raw impact). The elemental
  effectiveness matrix and status bypass happen downstream, unchanged.

So the gun system produces a `GunStats`; the weapon component turns each hit into a
`DamagePacket`; the elemental system resolves it. Clean seam, no circular coupling.

---

## 7. Build order

1. `Rarity` + the six `.tres` rarities.
2. `ScalingCurve` (both modes) + a `.tres`. **Unit-test `level_multiplier` against
   the Section 2.3 tables before anything else** — this is the part that must be right.
3. `StatRange` + `GunStats` + per-stat resolution.
4. `GunGenerator` core (rarity roll + stat roll + scaling), no manufacturers yet —
   verify a generated pistol's numbers match the reference tables.
5. `Manufacturer` + archetype modifiers + recoil reference.
6. `GunPart` + tag-compatible part assembly.
7. Gimmick dispatch.
8. Determinism/seed pass for multiplayer.

Steps 1–4 are the slice that proves the scaling is sane and rarity stays relevant.
Do not proceed to manufacturers/parts until the reference tables reproduce exactly.
