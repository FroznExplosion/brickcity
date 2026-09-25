# Gun Quality, Naming & Score Spec

**Engine:** Godot 4.6 · **Pairs with:** [GUN_SCALING_SPEC.md](GUN_SCALING_SPEC.md) (rarity,
level curve, stat rolls), [MANUFACTURER_SPEC.md](MANUFACTURER_SPEC.md) (part effects, merges),
[ProceduralGunSystem/SPEC_procedural_gun_system.md](ProceduralGunSystem/SPEC_procedural_gun_system.md)
(part assembly).

Adds three linked systems on top of the existing generator. None of them change the
part-assembly pipeline.

1. **Part-rarity delta** — parts roll *around* the gun's rarity instead of anywhere inside
   a legal band. Borderlands 1's emergent part-rarity, re-added as a *modifier* on top of
   Borderlands 2's authored rarity.
2. **Name schema** — a fixed 4-slot name where every slot is read off the gun, so the
   name is a build sheet, not flavor.
3. **Gun score** — one number covering raw power (tier × rarity × roll × parts).
   Special effects are deliberately **not** in it.

---

## 0. Pillars

1. **Rarity stays authored.** The drop roll picks the intended tier. Parts never change
   the tier or the color. This preserves the TTK-tuned damage multipliers
   (GUN_SCALING §1) and keeps loot pools tunable.
2. **Parts are the *within-tier* axis.** A gun's tier says what it is; its parts say how
   good a version of it you got. This is the Diablo affix-quality read.
3. **The name carries the information.** Every word in a gun name is derived. No random
   flavor adjectives — a word that means nothing sitting next to words that do makes
   both unreadable.
4. **Score is raw power only.** Effects and merges are shown as icons, never folded into
   the score, so "lower score but better gun" stays a real and legible outcome.
5. **Rarity buys you tiers, not permanence.** Each rarity is worth a fixed fraction of a
   tier of head start (§1). That is the whole point of rarity.

---

## 1. Rarity lifespan — the law that sets the multipliers

> **Superseding decision.** Weapon power is denominated in **PROGRESSION_SPEC tiers**,
> not player levels. There is no player level and no per-kill gun level anywhere in this
> system (PROGRESSION_SPEC §0.2). Earlier drafts of this spec were written in levels;
> every number below is the tier translation.

A gun's rarity is worth a **fixed fraction of a tier**. The multipliers are *derived*
from that, not chosen:

```
rarity_mult    = TIER_STEP ^ lifespan_tiers
lifespan_tiers = ln(rarity_mult) / ln(TIER_STEP)      # TIER_STEP = 1.60
```

| rarity | mult | lifespan (tiers) | score vs Common |
|---|---|---|---|
| Common | 1.00 | 0 (baseline) | 0 |
| Uncommon | 1.30 | 0.56 | +56 |
| Rare | **1.60** | **1.00** | **+100** |
| Unique | 2.00 | 1.48 | +148 |
| Legendary | **3.30** | 2.54 | +254 |
| Mythic | **5.00** | 3.42 | +342 |

**`TIER_STEP = 1.60` and the Legendary/Mythic mults are SOLVED from two authored
calibration points, not chosen:**

```
T1 Legendary == T3 Uncommon   ->  3.30 ~= 1.30 x 1.60^2 = 3.328
T1 Legendary >= T2 Unique     ->  3.30 >= 2.00 x 1.60   = 3.20
```

**Rare is worth exactly one tier** — the anchor to hold when retuning. A fresh Rare
exactly matches a fresh Common one tier up, and every other rarity reads as a fraction or
multiple of that. Rarity now spans MULTIPLE tiers; an earlier `TIER_STEP` of 2.0 confined
every rarity to under one tier and could not satisfy either calibration point.

Measured in the bed: `T1 Legendary 388` vs `T3 Uncommon 390` vs `T2 Unique 382`.

**Legendary now clears Unique by a full tier** (2.54 vs 1.48). The old 2.00/2.00 pair
made orange and purple show the *same score* at the same tier — orange being 4x rarer for
zero visible gain on the headline read.

**`TIER_STEP` is the single number that sets the whole game's power curve.** Total growth
across all 10 tiers is `1.6^9 = 68.7x`. Raising it shortens every rarity's reach; lowering
it makes old guns linger.

> **Why the ladder is not "2 / 3 / 5 / 8" any more.** Those figures were in player
> levels, and the unit changed when player levels were removed. With only 10 tiers, a
> Mythic lasting "8 units" would be nearly the whole game; the calibration points above
> re-solve the ladder to 0.56 / 1.00 / 1.48 / 2.54 / 3.42 tiers, which spends about a
> third of the game's progression on the rarity axis.

> **This contradicts PROGRESSION_SPEC §0.4**, which claims Common and Legendary of the
> same tier deal roughly the same damage (~40% spread) and that rarity changes behaviour
> rather than raw power. The ladder above makes rarity worth up to 3× **within** a tier.
> The ladder wins — it was designed deliberately — and §0.4 needs amending.

---

## 2. Part-rarity delta

### 2.1 New `GunPartDef` fields

```gdscript
## The tier this part is authored for. Distinct from min_rarity/max_rarity, which
## stay as the HARD legality gate. native_rarity is what the generator AIMS at.
## Defaults to min_rarity when left unset, so existing .tres files keep working.
@export_range(1, 6) var native_rarity: int = 1

## Non-empty => this part is exclusive to that legendary's fixed recipe and is
## excluded from every general candidate pool. (§5)
@export var exclusive_to: StringName = &""
```

`min_rarity` / `max_rarity` keep their current meaning and their current `.tres` values —
nothing already authored breaks.

### 2.2 Per-slot offset roll

For each slot, roll an offset and aim at `clamp(base_rarity + offset, 1, 6)`. **Rates are
solved backwards from the gun-level targets, not picked by feel** — the per-slot number
is small because a gun fills ~6 slots and any one of them can trip the grade:

| offset | per-slot weight |
|---|---|
| −2 | 0.1% |
| −1 | 0.8% |
| 0 | **96.0%** |
| +1 | 2.8% |
| +2 | 0.3% |

Solve: `P(gun has ≥1 higher part) = 1 − (1 − p_hi)^6`. With `p_hi = 3.1%` that is
**17.2%**; with `p_lo = 0.9%` the lower side is **5.3%**.

| gun-level outcome | rate |
|---|---|
| at least one higher-tier part | **17.2%** |
| at least one lower-tier part | **5.3%** |
| **two or more** higher-tier parts | **1.3%** |
| all-normal (no grade word from parts) | 77.9% |

Two-or-more at 1.3% is the "unlikely but possible" target. Mean offset collapses to
**+0.024** — see §2.3.

`GunPartLibrary.candidates()` picks parts whose `native_rarity` equals the target and
whose `[min_rarity, max_rarity]` band still contains it. If that pool is empty, walk the
target one step toward `base_rarity` and retry. The legality gate always wins.

> **This table supersedes an earlier one at 28% / 7% per slot.** That version put a
> higher-tier part on **92%** of guns, which made the name prefix meaningless. The
> per-slot rate has to be ~10× smaller than the gun-level rate you actually want,
> because six independent slots each get a roll.

### 2.3 Quality `Q` — slot-weighted, roll-nudged

Slot weight reflects how much the part defines the gun:

| slot | weight |
|---|---|
| BODY, BARREL | 2.0 |
| GRIP, MAGAZINE, STOCK | 1.0 |
| SIGHT, MUZZLE, UNDERBARREL | 0.5 |

```
q = Σ( weight[s] × (native_rarity[s] − base_rarity) ) / Σ( weight[s] )   # filled slots only
Q = q − MEAN_OFFSET + 0.4 × (dq − 0.5)
```

`MEAN_OFFSET` is **derived from the offset table at load**, never typed in. With the §2.2
table it is `+0.024` — small enough to be invisible, but keep the term: it is what stops a
future table retune from silently making the grade meaningless.

**The `dq` term stops grade and score pointing opposite directions.** `dq` is the damage
roll quality (0..1) that already drives the score. Without this term a gun can read
"Outstanding" (great parts) while scoring badly (terrible roll), which is precisely the
confusion the grade exists to remove. Weight `0.4` bounds the nudge at **±0.20** — below
the Tier-1 threshold, so a god roll alone can never *create* a grade and a floor roll can
never fully cancel a `+2` body. Parts stay the driver; the roll only moves guns already
sitting on a band edge.

Reference `q` values for a typical 6-slot gun (`Σweight = 7.5`):

| what rolled up | `q` |
|---|---|
| one +1 sight | 0.067 |
| one +1 grip / mag / stock | 0.133 |
| one +1 **body or barrel** | 0.267 |
| one +2 body or barrel | 0.533 |
| two +1 majors | 0.533 |

---

## 3. Name schema

Four derived slots in fixed order. Two are optional and simply vanish:

```
[Grade] [Element] [Barrel] [Receiver]
```

| slot | source | optional | example |
|---|---|---|---|
| Grade | `Q` band (§3.1) | yes — omitted at normal quality | `Outstanding` |
| Element | `element` (SPEC Amendment A) | yes — omitted if none | `Burning` |
| Barrel | BARREL `name_fragment`, used as an **adjective** | no | `Silenced` |
| Receiver | BODY `name_fragment`, used as the **noun** | no | `AK47` |

`Outstanding Burning Silenced AK47` · `Silenced AK47` · `Rough Corrosive Vented Ravager`

### Two changes to existing code this forces

1. **`NAME_ADJECTIVES` is deleted.** It currently contains `"Rusty"` and `"Gilded"` —
   words that *look* like grades and mean nothing. Sitting next to a real grade word they
   destroy exactly the readability this system exists to buy. Highest-value line to
   delete in the naming code.
2. **The fragment source flips.** `_make_name()` currently prefers the BARREL fragment and
   falls back to any part. New rule: BARREL fragment is the adjective, BODY fragment is
   the noun, both required. Authoring rule: **body fragments must be nouns, barrel
   fragments must be adjectives.** A `.tres` validator should assert both are non-empty on
   every BODY and BARREL def.

**Manufacturer leaves the name.** It is currently the first word. The name is already 3–4
words, and brand identity rides in the receiver fragment ("AK47" reads as a brand). Brand
stays a UI field and a color badge, not a word.

### 3.1 Grade bands

With §2.2's rates, **any** non-zero part delta is rare enough to be worth a word — the
bands only decide *which* word. `Q` is not normally distributed here (78% of guns sit at
exactly zero), so the frequencies below are enumerated, not read off a bell curve.

| `Q` | tier | word pool | freq |
|---|---|---|---|
| ≥ +0.45 | 3 | Immaculate, Pristine, Flawless | **1.1%** |
| +0.20 … +0.45 | 2 | Outstanding, Superb, Exceptional | **6.3%** |
| > 0 … +0.20 | 1 | Fine, Choice, Sharp | **9.8%** |
| 0 (±0.02) | — | *(no word)* | **77.5%** |
| −0.20 … < 0 | −1 | Used, Preowned, Worn | 3.2% |
| −0.45 … −0.20 | −2 | Rough, Dirty, Salvaged | 1.8% |
| ≤ −0.45 | −3 | Scrapped, Junker, Gutter | 0.3% |

**~78% of guns carry no grade word.** Which word inside a tier is picked is cosmetic and
seeded, so a given gun always reads the same.

This delivers the original intent — *a single higher-rarity part earns a prefix, even if
it is only the scope* — because the §2.2 rates make that event rare. A lone +1 sight
(`q = 0.067`) reads `Fine`; a lone +1 barrel (`q = 0.267`) reads `Outstanding`; a +2 body
or two +1 majors (`q = 0.533`) reads `Immaculate`.

> ⚠ **Tier 3 at 1.1% is more common than a Mythic drop (0.5%).** The rarest *word* fires
> twice as often as the rarest *colour*, so players learn the word is the cheaper signal.
> Raise the Tier-3 floor to `Q ≥ 0.50` (single +2 major only, no two-part combos) to land
> it near 0.35%. See §8.3.

---

## 4. Gun score

One number, monotone in **DPS** — not per-shot damage — so any two guns compare directly
regardless of level, tier, or how fast they fire:

```
dps_ratio = (final_damage × final_fire_rate) / (class.base_damage × class.base_fire_rate)
score     = round( 100 + 20 × ln(dps_ratio) / ln(1 + g) )
```

- **DPS, not damage.** A slow hard-hitting gun and a fast light one at the same quality
  score the same. Per-shot damage alone would rank every sniper above every SMG.
- **`20 ×`** — one player level = **20 score**. Wide enough that a roll (35 pts) and a
  rarity step (38–157 pts) are both legible at a glance.
- **`100 +`** — the floor. A level-1 worst-roll Common reads **100**, not 0. Every gun in
  the game carries a 3-digit score.

Range across the whole game: **100 → ~2,283** (level-100 god-roll Mythic).

| gun | dps_ratio | score |
|---|---|---|
| L1 Common, worst roll | 1.00 | **100** |
| L1 Common, mid roll | 1.17 | 123 |
| L5 Unique, mid roll | 4.11 | **302** |
| L10 Common, mid roll | 4.13 | **303** |
| L20 Common, mid roll | 16.71 | 503 |
| L20 Legendary, god roll | 42.12 | 635 |
| L45 Mythic sniper, god roll | 1,868 | **1,178** |
| L100 Mythic, god roll | 4.21 M | 2,283 |

A level-5 Unique ties a level-10 Common at ~302. The tie point is the §1 lifespan ladder
(Unique = 5 levels), visible directly in the number.

Because it derives from DPS, the score already contains level, rarity, damage roll, fire
rate **and** part modifiers. Nothing to keep in sync.

### 4.1 What score deliberately excludes

Effects (`effect_id`) and merges (`MergeRule`) are **not** in the score. A lower-score gun
with a strong merge beating a higher-score gun is a designed outcome, not a bug.

The UI must therefore always show, next to the score, one icon per active effect and a
distinct badge per active merge. **A score shown without its effect icons is a lie** — the
one presentation rule this system cannot bend.

### 4.2 The three reads

| read | axis | answers |
|---|---|---|
| Color | intended rarity | what kind of gun is this |
| Score | raw power | is it stronger than what I hold |
| Grade word | within-tier quality | is this a good version of it |

Three cheap glances, no two encoding the same thing.

### 4.3 The spread budget — the law that keeps colour meaningful

> **This section corrects two real errors, one of them pre-existing.** Read it before
> touching any roll window.

Everything that multiplies into DPS shares one budget:

```
TOTAL_DPS_SPREAD = damage_window × fire_rate_window × part_swing
```

**The law:** `smallest_1_tier_step  <  TOTAL_DPS_SPREAD  <  smallest_2_tier_step`,
i.e. `1.30 < spread < 1.50`. **Target 1.46.**

Above the 1-tier step, a god-roll of one tier beats a floor-roll of the next — low-rarity
guns are never auto-trash, the stated goal. Below the 2-tier step, colour still predicts
power across any gap of two or more. Exactly one tier of overlap, never two.

#### Error 1 (pre-existing): fire rate is unbudgeted

`GunStats` ships `DMG_WINDOW_HI = 1.3` **and** `FIRE_RATE_HI = 1.5`. Both multiply into
DPS, so the real spread is **1.3 × 1.5 = 1.95** — larger than the Rare step (1.50) and
almost the Unique step (2.00). **A god-roll Common out-DPSes every Rare and most Uniques
in the game today.** Colour stops predicting power across three tiers.

The §3.1 coherent-band rule does not save this: a `dq = 1.0` gun rolls its other stats in
`[0.5, 1.0]`, so the 1.5× fire-rate ceiling is fully reachable on the same gun that rolled
max damage. The bands make good guns *coherent*, not *bounded*.

**Fix — split fire rate into a DPS-neutral *feel* trade plus a small budgeted quality
roll.** Fire rate still multiplies into DPS and therefore into score; what changes is that
most of its range no longer *adds* power:

```gdscript
var dps_mult   := lerpf(1.00, 1.28, dq)     # the main power roll
var feel       := rng.randf()               # 0 = slow + hard-hitting, 1 = fast + light
var fire_base  := lerpf(0.80, 1.25, feel)   # DPS-NEUTRAL: traded against damage
var fire_bonus := lerpf(1.00, 1.06, fq)     # small INDEPENDENT fire-rate quality
var fire_mult  := fire_base * fire_bonus
var dmg_mult   := dps_mult / fire_base      # divides by fire_base only, not fire_bonus

# DPS = dmg_mult * fire_mult = dps_mult * fire_bonus     <- the whole spread, explicitly
```

Fire rate keeps a **wider** feel range than the original (0.80–1.25 vs 1.00–1.50) and
still contributes to DPS and score — but only `fire_bonus` (1.06×) counts against the
budget. This is WEAPONS_SPEC §0.3 class-parity applied at the roll level, and it makes the
§3.1 coherent-band hack unnecessary for these two stats. Reload, accuracy and mag do not
multiply into DPS and keep their wide bands.

#### Error 2: the ±15% part-swing cap was wrong

An earlier draft of §6 capped part-delta damage swing at ±15%. That gives
`1.35 × (1.15 / 0.85) = 1.83` — over the 2-tier step, so a well-parted Common would beat a
Rare. **The correct cap is ±3%.**

#### The shipping allocation

| component | window | score pts |
|---|---|---|
| `dps_mult` (damage roll) | 1.00 → **1.28** | 35 |
| `fire_bonus` (fire-rate quality) | 1.00 → **1.06** | 8 |
| `part_mult = 1 + 0.03 × clamp(q, −1, 1)` | 0.97 → **1.03** | 8 |
| **total DPS spread** | **1.438** | **51** |

`1.30 < 1.438 < 1.50` ✓. In score units the within-tier spread is **51 points**, which
sits above the Uncommon step (38) and below the Rare step (58) — the law restated in the
units the player actually sees.

Boundary check at level 1:

| matchup | god-roll lower | floor-roll higher | winner |
|---|---|---|---|
| Common vs Uncommon | 1.398 | 1.261 | **Common** ✓ (overlap intended) |
| Common vs Rare | 1.398 | 1.455 | Rare ✓ |
| Uncommon vs Unique | 1.817 | 1.940 | Unique ✓ |
| Rare vs Mythic | 2.097 | 2.910 | Mythic ✓ |

#### The cost: parts move the score only a little

±3% is **±8 score points** — visible, but a fifth of what a rarity step is worth. Parts
moving the score *a lot* and the rarity ladder holding are mutually exclusive: the budget
is 1.438× wide and rarity has first claim on it.

| carries | signal |
|---|---|
| Score | level, rarity, damage roll, fire rate. Parts contribute ±8 pts. |
| Grade word | parts, almost entirely |
| Effect icons | what parts actually *do* — the real reason to want good parts |

Parts earn their excitement through **effects and merges**, not through the number. That
is also why §4.1 keeps effects out of the score.

### 4.4 Fire-rate floor — no gun fires slower than 1.0 shots/sec

`fire_base` bottoms at 0.80×, so the floor is a **class base-rate requirement**, not a
runtime clamp: `base_fire_rate × 0.80 ≥ 1.0`, i.e. **`base_fire_rate ≥ 1.25`**.

Only the sniper fails it today (1.2 × 0.8 = 0.96/s). Fix in the class preset, holding
class DPS parity at ~600:

| class | old | new |
|---|---|---|
| `sniper` `base_fire_rate` | 1.20 | **1.35** |
| `sniper` `base_damage` | 450 | **445** |

`445 × 1.35 = 600.75` base DPS, worst feel roll = `1.35 × 0.80 = 1.08/s` ✓. Every other
class already clears it (shotgun 1.28/s, revolver 1.60/s, DMR 2.80/s).

> **Do not clamp the rolled value instead.** Clamping fire rate upward without lowering
> damage raises that gun's DPS above its roll, which silently punches a hole in the §4.3
> budget for exactly the class that hits the clamp. Fix the base, keep the math exact.

---

## 4.5 Drop rates, level luck, and the over-level rule

### 4.5.1 Base table — Borderlands 2 world-drop rates

`RARITY_WEIGHTS` currently ships `[55, 25, 12, 5, 2.5, 0.5]`, which puts a Legendary in
the player's hands every ~40 drops. BL2 world drops are roughly an order of magnitude
tighter, and that tightness *is* the cool factor:

| tier | BL2 analog | weight | rate | was |
|---|---|---|---|---|
| Common | white | 76.0 | 76% | 55% |
| Uncommon | green | 17.0 | 17% | 25% |
| Rare | blue | 5.5 | 5.5% | 12% |
| Unique | purple | 1.2 | 1.2% | 5% |
| Legendary | orange | 0.28 | **0.28%** | 2.5% |
| Mythic | pearlescent | 0.02 | **0.02%** | 0.5% |

```gdscript
const RARITY_WEIGHTS: Array[float] = [76.0, 17.0, 5.5, 1.2, 0.28, 0.02]
```

Mythic at 1-in-5,000 is pearlescent-rare and should stay that way — it is the only tier
with nothing above it.

### 4.5.2 Level luck — rarity climbs with the drop's level

One constant, applied as a power so each step up compounds:

```gdscript
const LEVEL_LUCK := 0.006                                  # per level above 1
func luck(level: int) -> float:
    return 1.0 + LEVEL_LUCK * float(level - 1)
# tier i (0-based) weight becomes: RARITY_WEIGHTS[i] * pow(luck, i)
```

| | L1 | L50 | L100 |
|---|---|---|---|
| luck | 1.000 | 1.294 | 1.594 |
| Common | 76% | 68.9% | 61.3% |
| Uncommon | 17% | 20.0% | 21.9% |
| Rare | 5.5% | 8.4% | 11.3% |
| Unique | 1.2% | 2.4% | 3.9% |
| Legendary | 0.28% | 0.71% | **1.46%** |
| Mythic | 0.02% | 0.07% | **0.17%** |

Legendary gets ~5× more common across the whole game, Mythic ~8×. Enough to feel the
climb; not enough to make orange routine.

**The same luck scales part rarity (§2.2).** Multiply the `+1` / `+2` offset weights by
`luck` and divide the `−1` / `−2` weights by it:

| | L1 | L100 |
|---|---|---|
| gun has ≥1 higher part | 17.2% | **26.2%** |
| gun has ≥1 lower part | 5.3% | **3.3%** |

So grade words get commoner and kinder with level, which is the correct direction — a
level-90 gun reading `Rough` should be a rarer insult than a level-5 one.

### 4.5.3 The over-level rule

```gdscript
var delta := clampi(enemy_level - player_level, 0, 10)
var drop_level := maxi(enemy_level, player_level)
var drop_luck := luck(drop_level) * (1.0 + OVERLEVEL_LUCK * float(delta))
const OVERLEVEL_LUCK := 0.08
```

- **Enemy above the player** → the gun drops at the **enemy's** level, with a luck bonus
  of +8% per level of gap, capped at +10 levels.
- **Enemy at or below the player** → the gun drops at the **player's** level, no bonus.
  A low-level enemy is never a downgrade machine and never a farm.

At level 20 fighting a +5 enemy, total luck is 1.56 → Legendary 1.36%, Mythic 0.15%:
roughly **5× the base legendary rate** for taking a fight above your weight.

> **This is the closest thing in any spec to a chase, and it is not a substitute for
> dedicated drops (§8.2).** It creates a reason to punch up, which is real value, but it
> is a *rate* incentive. It cannot produce "I farmed Boss X for that specific gun," which
> is where most BL2 player stories actually come from.

> **Gate equipping by level, BL2-style.** An over-level drop should be visibly better than
> what the player can currently use. That turns the reward into a goal instead of an
> immediate power spike, and it is the only thing stopping a +10 pull from trivialising
> the next ten levels.

## 4.6 Dedicated drops

A named source (boss, named enemy, mission reward, rare chest) can be authored to drop a
specific gun. This is the BL2 chase mechanic and the answer to §8.2.

**The one rule that makes this cheap: a dedicated drop overrides *which* gun, never *how
strong*.** Damage, score, part offsets, grade word, level — all identical to a world drop.
Nothing in §1–§4.5 gets a special case.

```gdscript
class_name DedicatedDropTable
extends Resource

@export var source_id: StringName          ## the named enemy / chest / mission
@export var entries: Array[DedicatedEntry] = []

# DedicatedEntry:
#   gun_id: StringName      -> a legendary recipe id, or a fixed weapon_class + rarity
#   chance: float           -> per-kill, authored (BL2 dedicateds sit around 0.05-0.10)
```

Resolution order on a kill — **dedicated and world drops are independent, BL2-style**:

1. Roll the normal weighted world table (§4.5.1) as for any enemy. A boss's world roll is
   a real roll and can produce its own orange.
2. **Separately**, roll each dedicated entry for this `source_id`. A hit **adds** a gun; it
   does not consume or replace the world drop. A boss can drop its dedicated *and* a world
   legendary in the same kill.
3. **Every gun produced then runs the identical pipeline:** `drop_level` from §4.5.3, part
   offsets on open slots, `GunStats.compute`, `Q` and the grade word, `score`.

Dedicated chance sits **slightly above** BL2's ~10%: **12%** for a boss's own gun. High
enough that a handful of runs usually pays out, low enough that the payout is a moment.

### 4.6.1 The shipping legendaries

Authored in `LegendaryTable._PRESETS`. Each owns **one exclusive barrel** carrying its
effect; `exclusive_to` keeps that part out of every world pool, so a legendary part
appears on its legendary or nowhere.

| id | name | class | effect | signature | flavour |
|---|---|---|---|---|---|
| `boilerplate` | Boilerplate | LMG | `heat_ramp` | dmg ×1.25, fire ×0.80, mag ×1.6 | "Give it a minute." |
| `sermon` | Sermon | Sniper | `kill_refund` | dmg ×1.30, fire ×0.77, crit ×1.25 | "Every word lands twice." |
| `landlord` | Landlord | Shotgun | `pellet_return` | dmg ×0.72, fire ×1.39, acc ×0.85 | "It always comes back around." |
| `hangnail` | Hangnail | Pistol | `crit_bleed` | dmg ×0.85, fire ×1.18, crit ×1.4 | "Small. Persistent. Yours now." |
| `dinner_bell` | Dinner Bell | SMG | `reload_throw` | dmg ×1.15, fire ×0.87, reload ×1.35 | "Come and get it." |

**Every signature keeps its damage×fire_rate product at ~1.0 on purpose.** A legendary
that plays nothing like its class but sits exactly on the DPS budget is the goal; a
signature whose product drifts from 1.0 moves the gun off-budget and its score with it.

Sources and their authored per-kill chances:

| source | entries | total |
|---|---|---|
| `boss` | Boilerplate 6% · Sermon 4% · Landlord 2% | **12%** |
| `badass` | Hangnail 4% · Dinner Bell 2% | **6%** |

Each entry rolls **independently**, so one exceptional kill can pay out twice.

**Measured:** the same legendary spans a **44-point score range** (Sermon 780–824 at
level 30), about 2.2 levels of variance. That is the good-copy/bad-copy spread that makes
farming the same boss twice worth doing, and it fell out of the existing `dq` roll with no
special case.

Consequences worth stating, because they are the reason to build it this way:

- A dedicated legendary still rolls `dq`, so **there is a good Harold and a bad Harold**.
  That is the entire reason BL2 players farm the same boss more than once, and it comes
  free from §4.3 rather than needing its own system.
- A dedicated drop still takes a grade word under the §5 legendary rule (tier 2/3 only),
  so `Outstanding Unkempt Harold` is reachable and `Rough Unkempt Harold` is not.
- Dedicated `chance` is authored per entry and **is not touched by level luck** (§4.5.2).
  Level luck biases the *world* table; a boss's dedicated rate is a designed constant. The
  §4.5.3 over-level bonus likewise applies only to the world roll.

> **Open: does a dedicated hit consume the kill's only drop, or roll alongside it?** BL2
> effectively rolls dedicated separately from the world table, so a boss can drop its
> dedicated *and* a world orange. Step 1 above specifies the stricter version (dedicated
> replaces). Loosening it is a one-line change; decide once loot volume is real.

---

## 5. Legendary and Mythic rules

**Legendary parts are exclusive.** A part with `exclusive_to` set never enters a general
candidate pool; only the named legendary's fixed recipe pulls it. `GunPartLibrary._index()`
sorts these into a separate map so the cost is zero at generation time.

**Legendaries use fixed recipes.** Their defining slots are authored, not rolled. Only
slots the recipe leaves open roll offsets, so `Q` is computed over open slots only.

**Naming:** a legendary uses **its authored name and nothing else** — no element, barrel,
or receiver word. `Unkempt Harold`, never `Burning Silenced Unkempt Harold`.

**Grading — a legendary or mythic ALWAYS carries a prefix, and it is never an insult.**
Negative grade words are hard-off for these two tiers; a bad roll gets a *legend epithet*
instead, which is flavour carrying no quality signal:

| `Q` | word pool |
|---|---|
| ≥ +0.45 | `Immaculate`, `Pristine`, `Flawless` |
| +0.20 … +0.45 | `Outstanding`, `Superb`, `Exceptional` |
| **< +0.20** (normal *or* bad) | `Fabled`, `Storied`, `Notorious`, `Infamous`, `Sovereign` |

So the read is: **a quality word means a good roll; an epithet means normal or below.**
Every legendary still looks like a legend on the ground, and `Rough Unkempt Harold` — which
would undermine the fantasy the drop exists to create — is unreachable.

> ⚠ **Bad and normal are indistinguishable under one epithet pool.** A player cannot tell a
> floor-roll Harold from an average one by name alone (the score still separates them). If
> that matters, split into two pools — `Fabled`/`Storied` for normal, `Notorious`/`Infamous`
> for bad — and accept that the second pool is a soft insult after all. Shipping one pool;
> revisit with VO. See §9.1.

---

## 6. Traps in the current code

| # | where | problem |
|---|---|---|
| 1 | [gun_effects.gd](../scripts/guns/gun_effects.gd) `collect()` | Gates on `rarity >= p.effect_min_rarity` using **gun** rarity. A `+2` part carrying a gated effect on a lower-tier gun gets placed, names the gun "Outstanding", and its effect silently does nothing. **Gate on `part.native_rarity`, not gun rarity.** |
| 2 | [gun_generator.gd](../scripts/guns/gun_generator.gd) `NAME_ADJECTIVES` | Collides with grade words. Delete (§3). |
| 3 | [gun_generator.gd](../scripts/guns/gun_generator.gd) `_make_name()` | Fragment preference is barrel-first-then-any. Must become barrel = adjective, body = noun (§3). |
| 4 | — | **Never add a quality damage multiplier.** Part deltas already move damage through `stat_add` / `stat_mult`. A second multiplier compounds and breaks GUN_SCALING pillar 1 (rarity and level are the only two axes). |
| 5 | [gun_stats.gd](../scripts/guns/gun_stats.gd) `FIRE_RATE_HI` | **1.5 is unbudgeted and breaks the rarity ladder today.** Damage window × fire-rate window = 1.95 DPS spread, wider than the Rare step. Replace with the anti-correlated roll in §4.3. |
| 6 | — | Part-delta damage swing is **±4%**, not the ±15% an earlier draft carried. See §4.3 Error 2 for the boundary table. |

---

## 7. Worked examples

Pistol base 10 dmg / 6.0 fps (60 base DPS) unless noted. `g = 0.15`, CONSTANT.
`score = round(100 + 143.1 × ln(dps_ratio))`.

| # | lvl | rarity | roll | parts | name | dmg/shot | fire | DPS | score |
|---|---|---|---|---|---|---|---|---|---|
| 1 | 1 | Common (rifle) | worst | — | `Ported Mongrel` | 7.8 | 7.7/s | 60 | **100** |
| 2 | 1 | Common (rifle) | mid | — | `Long Pitbull` | 8.9 | 7.9/s | 70 | **123** |
| 3 | 3 | Common | mid | — | `Silenced AK47` | 14.3 | 6.2/s | 88 | **163** |
| 4 | 3 | Common | god | +1 barrel, fire | `Outstanding Burning Silenced AK47` | 18.6 | 5.6/s | 104 | **187** |
| 5 | 5 | Unique | mid | — | `Vented Ravager` | 19.9 | 6.2/s | 123 | **302** |
| 6 | 10 | Common | mid | — | `Long Pitbull` | 40.1 | 6.2/s | 248 | **303** |
| 7 | 20 | Rare (SMG) | low | +1 body, +1 sight, corr. | `Outstanding Corrosive Ported Wasp` | 5.1 | 16.1/s | 1,314 | **484** |
| 8 | 20 | Common | mid | — | `Ported Mongrel` | 166.8 | 6.2/s | 1,003 | **503** |
| 9 | 20 | Legendary | god | +2 mid slot | `Outstanding Unkempt Harold` | 435.4 | 5.8/s | 2,527 | **635** |
| 10 | 45 | Mythic (sniper) | god | −1 stock | `Cryo Bolt-Action Widowmaker` | 76,960 | 1.46/s | 112,250 | **1,178** |

Reads to check:

- **#5 vs #6** — a level-5 Unique ties a level-10 Common at ~302. Unique's ladder value is
  5 levels (§1), visible directly in the score.
- **#3 vs #4** — same level, same colour, **+24 score** and a grade word. "I found an
  outstanding version of that gun."
- **#8 vs #9** — same level, Legendary vs Common: 635 vs 503, a 132-point gap ≈ 6.6 levels.
- **#7 vs #8** — an SMG scoring *below* a same-level Common pistol despite better parts,
  because it rolled a poor `dq`. Score is DPS, so cross-class comparison is honest.
- **#7** — low damage roll, great parts. `Q = 0.333 + 0.4 × (0.2 − 0.5) = 0.213`, which
  keeps Tier 2 but lands it at the very bottom of the band. The §2.3 `dq` nudge doing its
  job: the grade drops *toward* the score instead of contradicting it.
- **#10** — a −1 stock (`q = −0.133`) cancelled by a god roll (`+0.18`) → `Q = 0.047`,
  **no grade word**. Correct: the gun is not a bad version of itself. Fires at 1.46/s,
  clear of the §4.4 floor.
- **#10 vs enemy HP** — 76,960 per shot into a level-45 standard enemy's 52,714 HP is a
  **one-shot**. Mythic sniper, god roll, crit not even needed.

### 7.1 What a score point is worth

| source | score points | = levels |
|---|---|---|
| one player level | **20** | 1 |
| Uncommon over Common | 38 | 1.9 |
| Rare over Common | 58 | 2.9 |
| Unique over Common | 99 | 5.0 |
| Legendary over Common (at ×2.20) | 113 | 5.6 |
| Mythic over Common | 157 | 7.9 |
| worst → best damage roll | 35 | 1.8 |
| worst → best fire-rate quality | 8 | 0.4 |
| worst → best parts | 8 | 0.4 |
| **total within-tier spread** | **51** | 2.6 |

The rarity column **is** the §1 lifespan ladder in score units. And the last row restates
the §4.3 law where the player can see it: within-tier spread (51) beats the Uncommon step
(38), loses to the Rare step (58).

### 7.2 Enemy health — guessed, anchored on rifle shots-to-kill

**Anchor: a level-1 trash enemy dies to 4–6 shots from a level-1 mid-roll Common rifle,
and that rifle reads ≤10 damage per shot.**

Rifle base **8.0** dmg / 7.5 fps. A mid-roll Common at level 1 lands **8.9 per shot**
(`dps_mult 1.14 / fire_base 1.025 × fire_bonus 1.03`). 45 HP → **5.1 shots**; worst roll
5.6, god roll 4.4. The full band sits inside 4–6.

| archetype | × trash | HP @ L1 |
|---|---|---|
| trash | 1.0 | **45** |
| standard | 2.5 | 113 |
| heavy | 7 | 315 |
| badass | 20 | 900 |
| boss | 70 | 3,150 |

All scale on the same curve as guns: `hp(L) = hp(1) × 1.15^(L−1)`.

| level | trash | **standard** | heavy | badass | boss |
|---|---|---|---|---|---|
| 1 | 45 | **113** | 315 | 900 | 3,150 |
| 5 | 79 | **197** | 551 | 1,574 | 5,509 |
| 10 | 158 | **396** | 1,108 | 3,166 | 11,081 |
| 20 | 640 | **1,601** | 4,483 | 12,809 | 44,830 |
| 30 | 2,591 | **6,477** | 18,136 | 51,818 | 181,363 |
| 45 | 21,086 | **52,714** | 147,600 | 421,713 | 1.48 M |
| 60 | 171,563 | **428,906** | 1.20 M | 3.43 M | 12.0 M |
| 80 | 2.80 M | **7.01 M** | 19.6 M | 56.1 M | 196 M |
| 100 | 45.98 M | **114.9 M** | 321.8 M | 919.5 M | 3.22 B |

> **The whole table is a 10× downscale of the previous one, and so are all eight class
> `base_damage` values.** Gun damage and enemy HP moved by the *same* constant, so every
> shots-to-kill number in §7.3 is unchanged, and `score` (§4) is a DPS *ratio* against the
> class base, so it is unchanged too. The only thing that moved is what the player reads
> on the damage card: a level-1 rifle now says **9**, not 89.

> **Standard is 2.5× trash, not 4×.** GUN_SCALING §1's original 3.0 s standard TTK implied
> 4× (22 rifle shots into a mook — spongy). The 4–6-shot trash anchor pulls it to 2.5×,
> giving a 1.6 s standard TTK and a 12.6-shot mook. The §1 TTK *ratios* (3:1
> common:mythic) are untouched; only the absolute anchor moved.

> **The 115 M figure at level 100 is the real cost of Option A** (CONSTANT 15%, §1.1).
> Option C (`max_level` 65) caps standard enemies at ~890 K instead.

#### Display: always round UP, never show a decimal

Every player-facing damage and HP number is `ceili(value)`. Compute and store the full
float; ceil only at the point of display.

A level-1 rifle's roll band is 7.8 → 10.0, which ceils to **8 / 9 / 10** — three distinct
values, coarse but never a decimal point. Granularity recovers immediately: level 5 spans
14–18, level 10 spans 27–35.

**Why ceil and not round:** it biases every displayed number up by ~0.5 on average, which
reads as generous rather than stingy, and it guarantees a gun that deals *some* damage
never displays `0`. GUN_SCALING §2.3's `roundi` is superseded by `ceili`. Enemy HP ceils
by the same rule; the effect on shots-to-kill is under 1%.

### 7.3 Shots to kill — Common rifle, at level

Because guns and enemies ride the same `1.15^(L−1)` curve, **shots-to-kill is constant at
every level** when the gun matches the enemy. This table is the whole game's combat pacing
in nine rows, valid at level 1 and level 100 alike.

Mid-roll Common rifle: **8.9 per shot**, 7.918 shots/sec, 70.5 DPS. Crit ×1.75.

| enemy | body shots | crit shots | TTK |
|---|---|---|---|
| trash | **5.1** | 2.9 | 0.64 s |
| standard | **12.6** | 7.2 | 1.60 s |
| heavy | **35.4** | 20.2 | 4.47 s |
| badass | **101** | 58 | 12.8 s |
| boss | **354** | 202 | 44.7 s |

By rarity, versus a standard enemy at level:

| rarity | dmg/shot | body shots | TTK |
|---|---|---|---|
| Common | 8.9 | **12.6** | 1.60 s |
| Uncommon | 11.6 | **9.7** | 1.23 s |
| Rare | 13.4 | **8.4** | 1.07 s |
| Unique | 17.8 | **6.3** | 0.80 s |
| Legendary (×2.20) | 19.6 | **5.7** | 0.73 s |
| Mythic | 26.7 | **4.2** | 0.53 s |

By level mismatch — Common rifle versus a standard enemy at the player's level. **This
table is the obsolescence curve**, and it is the reason `g` is worth arguing about:

| gun vs enemy | body shots | vs at-level |
|---|---|---|
| **+5 levels** (over-level drop) | 6.3 | 0.50× |
| +3 levels | 8.3 | 0.66× |
| **at level** | **12.6** | 1.00× |
| −2 levels | 16.7 | 1.33× |
| −5 levels | 25.3 | 2.01× |
| −10 levels | 51.0 | 4.05× |
| −15 levels | 102.5 | 8.14× |

Ten levels behind costs **4× the ammo and 4× the time**. That is what "replace guns often"
actually means in play, and it is why a Mythic's 8-level head start (§1) is generous but
not permanent.

---

## 8. Cool-factor review vs Borderlands 2

Ranked by how much each hurts the "I found something amazing" moment.

### 8.1 Legendary drop rate — RESOLVED

Was 2.5% / 0.5%, roughly 10× BL2. Now specified at BL2 world-drop rates in §4.5.1
(**0.28% / 0.02%**), with §4.5.2 level luck and the §4.5.3 over-level bonus as the ramps.
Remaining volume belongs on dedicated tables (§8.2).

### 8.2 Dedicated drops — SPECIFIED, not yet built

Now covered by §4.6. Still the largest *unbuilt* piece: every number in this document is
tuning, and this is the one actual system standing between the loot and BL2's chase.

The design call that keeps it cheap is that a dedicated drop overrides which gun and
nothing else — so "a good Harold vs a bad Harold" falls out of the existing `dq` roll
rather than needing any new machinery.

### 8.3 Immaculate (1.1%) is more common than Mythic (0.5%)

Covered in §3.1. Raise the Tier-3 floor to `Q ≥ 0.50` → ~0.35%.

### 8.4 Unique and Legendary produce the *identical* score

Both sit at ×2.00, so a purple and an orange at the same level and roll show the same
number. Orange is 2× rarer for zero visible gain on the headline read, which is a flat
moment on the rarest drop in the game.

BL2's answer is behavioural (red text, rule-breaking effects), and that is the right
answer here too — but it only works if effects genuinely carry it. **Cheap insurance:**
move Legendary to **×2.20**. That is +7 score over Unique — enough that the number is not
flat — and it barely moves the ladder (lifespan 5.6 vs 5.0). Unique keeps its overlap:
a god-roll Unique (2.81) still beats a floor-roll Legendary (2.11).

### 8.5 55% Common drop rate + 15%/level obsolescence = loot spam

Everything five levels old is at half power, and over half of all drops are Common. Two
things BL2 has that the specs do not mention:

- **Rarity floors that rise with area level** — late areas stop dropping white at all.
- **A fast mark-junk / sell-all flow.** Without it, 55% of drops become 55% of the
  player's clicks.

### 8.6 What is already right

- Common is never *useless*: an at-level Common ties a Mythic 8 levels old. That is the
  stated goal and it holds exactly.
- One tier of overlap and no more (§4.3), so a god-roll white beating a floor-roll green
  is a real story and a god-roll white beating a purple never happens.
- Killing the DECELERATING curve (§1.1) removes the only place where a rarity outlived its
  ladder — a late-game Mythic would have stayed best-in-slot for 28 levels.

---

## 9. ⚠ The GUESSES — revisit in this order

1. **Negative grade words: ON for Common–Unique, hard-OFF for Legendary/Mythic** (§5),
   which use the legend-epithet pool instead. **§9.1 open:** one epithet pool means a bad
   legendary and a normal one read identically by name — only the score separates them.
   Splitting into two pools fixes that but reintroduces a soft insult on the rarest drop
   in the game. Revisit with VO.
2. **The 4th name slot (suffix) is unresolved.** Recommendation if it ships: spend it on
   the active merge (`… of the Hydra`), not a 5th random word. That gives merges a
   presence in the name and reinforces §4.1 — the thing the score can't tell you shows up
   in the name instead.
3. **`g = 0.15` CONSTANT (Option A).** Chosen over the 800k cap. If 10⁸ end-game numbers
   read badly in the HUD, Option C (`max_level` 65) holds both the cap and the ladder and
   costs only level headroom.
4. **Slot weights (2 / 1 / 0.5)** are unmeasured. They decide which single part can
   trigger a grade on its own; retune against real part libraries.
5. **The `5 ×` score constant.** Set so a level-5 Unique reads ~50. Purely presentational.
6. **The `0.4` `dq` nudge weight (§2.3).** Sized so a roll can never create or fully
   cancel a grade, only shift one that is on a band edge. Untested against real drops.
7. **All enemy HP in §7.2.** Derived from the TTK ladder, authored nowhere. The ×0.35 /
   ×3 / ×9 / ×45 archetype spread is a straight guess and should be the first thing
   replaced with real encounter data.

---

## 10. Ordnance — the second equip slot

A BL4-style ordnance slot: grenades, launchers, mines, drones. **Ordnance is a normal
`WeaponClass` with `is_ordnance = true`**, so it runs the identical generator, part,
rarity, stat, grade-word and score path. Only the class pool differs.

| class | dmg | cooldown | fire rate | blast | charges | base DPS |
|---|---|---|---|---|---|---|
| `grenade` | 150 | 2.50 s | 0.40/s | 4.0 m | 2–4 | 60.0 |
| `rocket_launcher` | 240 | 4.00 s | 0.25/s | 5.0 m | 1–2 | 60.0 |
| `grenade_launcher` | 100 | 1.67 s | 0.60/s | 3.0 m | 3–6 | 60.0 |
| `mine_layer` | 120 | 2.00 s | 0.50/s | 3.5 m | 3–5 | 60.0 |
| `drone` | 40 | 0.67 s | 1.50/s | 1.5 m | 1 | 60.0 |

- **`base_fire_rate` is exactly `1 / cooldown`**, so ordnance sits on the same ~60 base
  DPS parity every gun class holds and the score formula needs no special case. A good
  fire-rate roll reads as a *shorter cooldown* — the stat the player actually watches.
- **Ordnance is EXEMPT from the 1.0 shots/sec floor (§4.4).** That floor exists so no
  *gun* feels sluggish; ordnance is meant to be slow, and clamping it upward would raise
  its DPS above its roll and hole the §4.3 spread budget for that class alone. Measured:
  311 of 400 ordnance rolls land under 1.0/s, as intended.
- `mag_size` is **charges held**, not magazine size. The card hides fire rate and reload
  and shows cooldown, blast and charges instead.

> ⚠ **The score undersells ordnance**, because blast damage hits several enemies and DPS
> counts one. This is the same shape of gap §4.1 documents for effects, and it has the
> same answer: the card must always show blast radius next to the score.

---

## 11. Effect stacking — abilities and power-ups are one system

**There is no separate "power-up".** MANUFACTURER_SPEC §8 described an equipped item that
amplifies effects a gun already carries; §11 originally described an ability that grants
them. Those are the same object seen from two sides, and keeping them apart produced two
half-rules. The unified rule is plain counting:

> **Two sources of the same effect upgrade it.** The sources are interchangeable.

| source A | source B | result |
|---|---|---|
| gun part | gun part (the gun rolled it twice) | upgraded |
| gun part | equipped ability | upgraded |
| equipped ability | equipped ability | upgraded |
| — | one source only | base strength |

A third source adds nothing. The cap is deliberate: stacking that escalates without limit
turns one lucky roll into the whole build.

### 11.1 Why counting, and not a special case per pairing

Counting is what lets an ability and a gun part be the **same currency**. A player holding
a Ricochet ability who picks up a gun that already has ricochet gets exactly what a player
with no ability gets from a gun that rolled ricochet twice — so neither path is a dead
end, and neither needs its own code. `GunEffects.stack()` is the whole implementation.

**Duplicate rolls are rarity-gated by pool size, not by a rule.** Parts draw effects from
a short catalog, so the chance two slots land the same effect climbs naturally with how
many slots a gun fills — which climbs with rarity. Legendary and Mythic guns self-upgrade
an effect often; a Common cannot (its parts carry no effects below rarity 3).

### 11.2 Mechanics

- The upgrade is an **id suffix** (`ricochet` → `ricochet_up`), not a flag, so effect
  lists stay flat `PackedStringArray`s that serialise and sync unchanged.
  `WeaponAbility.base_id()` recovers the original, so a handler dispatches once and reads
  the upgrade as a magnitude rather than needing a second code path per effect.
- `stack()` reads an already-upgraded id as **two sources**, which makes it idempotent —
  re-rendering a card cannot double-upgrade.
- **Abilities are a PLAYER property.** Nothing is written back onto a gun's recipe, so
  swapping guns re-applies instantly and swapping abilities never edits a stored weapon.

Shipping abilities: `ricochet` · `explosive` · `lifesteal` · `fire_ramp` · `homing` ·
`power_shot` · `element` · `extra_round`. **3 slots.**

> ⚠ **MANUFACTURER_SPEC §8 is now superseded** and should be deleted or rewritten to
> point here. Leaving both is how the two-half-rules problem started.

---

## 12. Shields — the third loot category

Shields run the same rarity / tier / roll / score pipeline. They have no fire rate, so
they cannot reuse `GunStats`; what they reuse is the part that matters — **capacity is
the power axis**, scaled by `rarity × tier` exactly as gun damage is, and scored with the
same 100-points-per-tier formula. A shield's score is therefore directly comparable to a
gun's. Measured: T1 103 → T2 203.

| class | capacity | recharge delay | rate |
|---|---|---|---|
| `standard` | ×1.00 | 3.0 s | 0.30/s |
| `brick` | ×1.75 | 6.0 s | 0.14/s |
| `sprint` | ×0.55 | 1.2 s | 0.75/s |
| `turtle` | ×2.40 | 11.0 s | 0.10/s |
| `spike` | ×0.80 | 3.5 s | 0.28/s |

Base capacity is **90** against the §7.2 HP anchor: a tier-1 standard enemy has 113 HP, so
a shield absorbs a little under one mook's worth of damage — enough to matter, not a
second life bar.

Capacity and recharge **trade at constant product**, the same shape as the gun
damage/fire-rate trade (§4.3), so a fast-recharge shield is not strictly better than a
big one.

`ShieldGenerator.to_layer()` emits a `shield` `DefenseLayer`, which `HealthPool` already
supports and already orders above `health`.

> ⚠ **Partial.** The generator, scoring and layer conversion are done and probe-covered.
> **Not done:** a shield card, equipping to the player, a world pickup, and recharge
> behaviour at runtime. Shields currently only log on spawn.

---

## 13. Cross-category score parity

A gun, an ordnance and a shield of the **same tier and rarity must score the same**, or
the number stops meaning "tiers of power" and starts meaning "which category did this come
from". Measured at tier 4 / Rare:

| category | score |
|---|---|
| gun (pistol) | **535** |
| ordnance (grenade) | **534** |
| shield (standard) | **522** |

Guns and ordnance agree to within a point, because ordnance `base_fire_rate` is exactly
`1/cooldown` and the score denominator is the class's own base DPS — the ratio is
identical either way.

**Shields sit ~13 points (0.13 tiers) low, and that is explainable rather than a bug:**
guns roll two power sources shields do not have — the fire-rate quality bonus (1.06) and
the part swing (±3%). Closing the gap would mean inventing a second shield roll axis just
to pad the number. Documented instead. Probe tolerance is 20 points for shields, 12 for
ordnance.

---

## 14. Tier overrides (test bed)

The bed separates **player tier** from **enemy tier** so the over-tier drop rule (§4.5.3)
can be exercised without hunting for a higher zone:

```
enemy_tier = clamp(player_tier + enemy_tier_offset, 1, Tier.COUNT)
```

`enemy_tier_offset` runs −3 … `LootRoller.MAX_OVERTIER`. The HUD prints the resulting
enemy tier **and the total luck multiplier**, so the reward for punching up is a number on
screen rather than an inference: at tier 1 with enemies at +1, total luck reads **×1.91**.

The clamp matters — a +3 offset at tier 10 must not invent a tier 13 that no drop table,
enemy HP row or score anchor has ever heard of.

---

## 15. The build menu

`LootBuilderMenu` authors any item by hand: **category → class → rarity → tier → Build**.

The point is falsifiability. Random drops can hide a bug for hundreds of rolls; this makes
"a tier-4 Rare grenade" something you can produce on demand and put beside a tier-4 Rare
pistol. **Every field feeds the same generator the world uses** — the menu picks inputs,
it never constructs an item down a side path, so a bug it fails to reproduce is genuinely
not in the generator.

Abilities appear in the same menu as checkboxes, with no class/rarity/tier rows, because
an ability is a player property rather than a rolled item (§11). The menu and the HUD keys
share one `AbilityLoadout`, so the two can never disagree.
