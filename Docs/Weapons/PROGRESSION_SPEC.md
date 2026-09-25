# Progression Spec — Tier Anchors, Hidden Level, Loot Pacing

**Engine:** Godot 4.6 · **Genre:** FPS rogue-lite (Roboquest / Gunfire Reborn lane).
**Pairs with:** [ELEMENTAL_SPEC.md](ELEMENTAL_SPEC.md) (elemental/damage), [GUN_SCALING_SPEC.md](GUN_SCALING_SPEC.md)
(procedural guns), [META_SPEC.md](META_SPEC.md) (account/class progression).

This spec covers the **run loop**: how difficulty and loot scale across a single run.
Account-loop progression (class trees, challenges, ascension unlocks, currency) lives
in [META_SPEC.md](META_SPEC.md). Keep the two lifetimes separate — that separation is
load-bearing.

---

## 0. Design pillars

1. **Hybrid: curve engine underneath, discrete tiers on top.** The
   `GUN_SCALING_SPEC` §2 `level_multiplier(L)` curve is kept intact. It is only ever
   *sampled at 10 discrete tier anchor points* — never evaluated per player level.
   Guns snap to their tier's anchor; they do not ladder up every kill. **10 tiers** =
   the weapon gets meaningfully better 10 times across the game (~2.3× power per tier).
2. **No visible player level. Ever.** "Level" exists only as an internal difficulty
   scalar. The player sees a **Tier** on the zone, never a number on themselves.
3. **Flat difficulty within a tier.** A tier's anchor is a constant per zone. It does
   NOT increment from kills, time, or player rank. Camping cannot raise difficulty.
4. **High stat floor.** Common and Legendary of the same tier deal roughly the same
   baseline damage (~40% spread, see GUN_SCALING §3.3). Rarity changes *behavior*, not
   raw power. Loot swaps are tactical, not a math chase.
5. **One dial, set by tier + ascension only.** The hidden level is driven by (a) which
   tier the zone is, and (b) the run's ascension offset. Nothing else touches it.

---

## 1. Tiers & anchors

**Files:** `scripts/progression/tier.gd`, `resources/progression/tiers/*.tres`

A `Tier` is a `Resource` describing one Act / difficulty plateau.

`Tier` fields (`@export`):
- `tier_id: StringName` — `&"tier_1"`, `&"tier_2"`, ...
- `display_name: String` — player-facing ("Tier I", "The Rim"). Cosmetic.
- `anchor_level: int` — the hidden level this tier samples the curve at. **This is the
  single number that sets the tier's power band.**
- `enemy_hp_scale: float` — multiplier on enemy base HP for this tier (tunable
  independently of gun scaling so TTK bands can be dialed).

### Shipping tier table (10 tiers; `anchor_level = tier × 10`)

Acts group tiers (a run may span several tiers); the 10 tiers are the *weapon power
bands*, not necessarily 10 separate Acts. Anchors sample the GUN_SCALING §2 curve at
even level steps. Because the curve is decelerating, the per-tier power jump shrinks from
**~3.5× (T1→T2) to ~1.6× (T9→T10)** — fast early churn, gentle late (GUN_SCALING §2.4).
Values below are the exact `pistol base 100 × level_multiplier(anchor)` (verified).

| tier | display | anchor_level | worst-common | worst-mythic (×3) |
|---|---|---|---|---|
| tier_1  | Tier I    | 10  | 340      | 1,019     |
| tier_2  | Tier II   | 20  | 1,205    | 3,615     |
| tier_3  | Tier III  | 30  | 3,873    | 11,620    |
| tier_4  | Tier IV   | 40  | 11,271   | 33,814    |
| tier_5  | Tier V    | 50  | 29,663   | 88,990    |
| tier_6  | Tier VI   | 60  | 70,533   | 211,599   |
| tier_7  | Tier VII  | 70  | 151,366  | 454,099   |
| tier_8  | Tier VIII | 80  | 292,869  | 878,608   |
| tier_9  | Tier IX   | 90  | 510,331  | 1,530,994 |
| tier_10 | Tier X    | 100 | 799,990  | 2,399,971 |

> Anchors are the ONLY tuning knob for tier power spacing. Move an anchor → the whole
> tier re-baselines from one number (the GUN_SCALING §0 "one number controls cadence"
> pillar, preserved). These are the shipping reference numbers a `ScalingCurve` unit test
> must reproduce (start_rate 0.15, end_rate 0.039866, max_level 100).

### Effective hidden level

```
effective_level(tier) = tier.anchor_level + run.ascension_offset
```

- `tier.anchor_level` — fixed per zone.
- `run.ascension_offset` — a per-run global constant chosen BEFORE the run starts
  (see META_SPEC ascension). Never changes mid-run. Never changes from player activity.

Loot rolls and enemy HP for a zone read `effective_level(tier)`, NOT a live player
level. This is the entire coupling between progression and the gun/enemy systems.

---

## 2. Loot pacing

### 2.1 Tier-capped drops (high floor, natural anti-camp)

A zone drops gear rolled at its own tier's `effective_level`. Camping a tier yields no
upgrades — the player exhausts that tier's power band in minutes. Boredom is the
primary anti-camp limiter; no timer needed.

### 2.2 Breadcrumb loot (tension → release)

Near the end of an Act, tougher **invader** enemies (next tier's archetypes) spawn and,
on death, drop **next-tier gear** rolled at the next tier's anchor. Restrict early
breadcrumb drops to **Common/Uncommon** so the player can't grab a next-tier Legendary
early and trivialize the following act.

- Falls out for free: a next-tier gun samples a higher anchor → visibly stronger. No
  special-case damage math.

### 2.3 Enemy demotion (automatic)

An enemy archetype's stats are fixed by its own definition; its *threat* comes from the
gap between its HP and the player's current-tier gun band. So the Act 1 miniboss,
reused in Act 3 unchanged, is fodder because Tier III guns sample a far higher anchor.
No per-act rebalancing of the enemy — demotion is a side effect of the anchor gap.

---

## 3. Anti-farming (defense in depth)

1. **Loot ceiling (primary).** §2.1 — nothing worth farming once the tier band is seen.
2. **Currency cap (meta exploit plug).** Meta-currency (funds the class tree, see
   META_SPEC) is capped per zone/run so a safe low tier can't be ground for account
   progress. Diminishing drops or a per-zone bank cap.
3. **Anti-camp spawn clock (reserve — add only if playtests show camping).** RoR2-style:
   lingering in a room ramps spawn *intensity* (more/tougher mobs), resets on progress.
   Raises **risk, not reward** — camping becomes dangerous, never profitable. Do NOT
   ship preemptively.

---

## 4. What this spec deliberately does NOT do

- No player XP bar, no player stat-level, no per-level player power. All permanent
  player growth is horizontal and lives in META_SPEC.
- The hidden level never increases from kills/time/rank. Only tier + ascension move it.
- No unbounded difficulty scaling. Difficulty is bounded per tier; escalation is a
  player-pulled ascension lever, not an automatic camp punishment.
