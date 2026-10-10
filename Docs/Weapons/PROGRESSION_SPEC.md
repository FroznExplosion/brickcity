# Progression Spec — Weapon Tiers, Player Level, Loot Pacing

**Engine:** Godot 4.6. **Rewritten 2026-10-09** to match the code (`scripts/guns/tier.gd`,
`scripts/loot/loot_roller.gd`) and the combat design's version 2
([COMBAT_DESIGN.md](COMBAT_DESIGN.md) §1). The BoomerBorder original sampled a 100-level
decelerating curve at ten anchors (~2.3× a tier) and had no player level at all; both are gone.
COMBAT_DESIGN overrides this file where they differ.

---

## 0. Pillars

1. **Two progressions, kept apart.** The **weapon tier** (1–10, from the story) sets gun damage and
   enemy durability. The **player level** (1–100, from XP) sets abilities and options. Neither feeds
   the other; no player level appears in any damage number.
2. **One constant sets the power curve.** ×1.25 a tier (`Tier.TIER_STEP`), for guns, enemies and
   melee alike, so on level every shots-to-kill count is the same at every tier.
3. **Flat difficulty inside a tier.** A zone's tier is fixed. It never rises from kills, time or the
   player's level. Camping cannot raise it.
4. **Loot swaps are about what a gun does.** Inside a tier, colours differ in damage by at most 12%
   (COMBAT_DESIGN §2); what a better gun has is modifiers and effects.

---

## 1. Weapon tiers

**Files:** `scripts/guns/tier.gd` (`Tier.power_mult`, `Tier.COUNT`).

| Tier | Power (×1.25 a tier) | Where (to write per act) |
|---|---|---|
| 1 | 1.00 | starting outposts |
| 2 | 1.25 | |
| 3 | 1.56 | |
| 4 | 1.95 | |
| 5 | 2.44 | |
| 6 | 3.05 | |
| 7 | 3.81 | |
| 8 | 4.77 | |
| 9 | 5.96 | |
| 10 | 7.45 | end-game zones |

- A gun's damage is `class base × roll × rarity × Tier.power_mult(tier)` (`GunStats.compute`).
- An enemy's health is `LootRoller.TRASH_BASE_HP × archetype hp_mult × Tier.power_mult(tier)`
  (`LootRoller.enemy_hp`).
- Melee is `CombatScale.melee(tier)` at the player's current story tier.
- Acts open tiers; an act may span several. The tier a zone shows is the only number the player
  needs to read about difficulty.
- **Ascension** (a harder repeat of the game) is an offset added to the tier
  (`Tier.power_mult(tier, ascension_offset)`), chosen before a run and never changed during it.
- `ScalingCurve` and `Tier.anchor_for` / `effective_level` are left from the old curve and no longer
  drive gun scaling.

### 1.1 Infusion

A gun keeps its drop tier until the player **infuses** it at a safehouse up to their current story
tier: same gun, new base damage (COMBAT_DESIGN §1.2). Never above the current story tier.

---

## 2. Player level

**Levels 1–100** from XP (kills, objectives, missions). Each level gives a skill point; some unlock
an ability. Nothing grows automatically: health and shields rise only through skill-tree nodes the
player chooses, capped at about +30% in all. The tree is in COMBAT_DESIGN §1.3 and §4.2.

Because the level never enters a damage number, an over-levelled player in a low zone has more
options, not a faster kill — the tier still decides that.

---

## 3. Loot pacing

**File:** `scripts/loot/loot_roller.gd`.

### 3.1 Drop tier

`LootRoller.drop_tier(enemy_tier, player_tier) = max(enemy_tier, player_tier)`: an enemy above the
player's tier drops at its own tier (the reward for punching up); one at or below drops at the
player's. A low zone is never a downgrade machine or a farm.

### 3.2 Rarity odds

World drops use Borderlands 2's rates (`RARITY_WEIGHTS` 76 / 17 / 5.5 / 1.2 / 0.28 / 0.02, common to
mythic). Luck tilts them: +7% a tier (`TIER_LUCK`), +55% for each tier the enemy is above the player
(up to 3), and the archetype's own bonus (a boss 3.5×). Named legendaries roll separately and never
get commoner from luck.

### 3.3 Breadcrumb loot

Near the end of an act, tougher **invader** enemies of the next tier may appear and drop next-tier
gear — restricted to Common/Uncommon so a next-tier legendary cannot trivialise the next act. (Not
built.)

### 3.4 Enemy demotion

An enemy kind's stats are fixed by its definition; its threat is the gap between its tier and the
player's guns. The act 1 miniboss met again in act 3 at its old tier is fodder. No per-act
rebalancing.

---

## 4. Anti-farming

1. **Loot ceiling.** §3.1: nothing in a low zone is worth farming.
2. **XP and currency caps.** XP and currency from a zone well below the player's story tier fall off,
   so a safe zone cannot be ground for levels or materials.
3. **Anti-camp spawn clock (reserve).** Only if playtests show camping: lingering ramps spawn
   intensity and resets on progress — more risk, never more reward. Do not ship preemptively.
