# Combat and weapon design — Borderlands loot, Halo fights

**Status: proposal, agreed in outline 2026-10-05; numbers to tune in play.** Supersedes the
power curve and rarity table of `GUN_SCALING_SPEC.md` / `PROGRESSION_SPEC.md` where they differ
(§9 lists every change against what is built).

The aim in one line: **Borderlands' loot chase on top of Halo's combat sandbox.** Guns are
generated, levelled and coloured by rarity, and a better gun really does more damage (Borderlands
scaling, not Halo's fixed shots-to-kill) — but fights are won Halo's way: strip the defence,
then land the precision shot, and melee is a real tool in that loop rather than a panic button.

---

## 1. Levels and the power curve

- **10 weapon levels** (tiers). A gun's level is fixed when it drops. There is no player level.
- **25% per level**: a gun's base damage, and every enemy's durability, are ×1.25 per level
  (`TIER_STEP = 1.25`). Level 10 is 7.45× level 1. Damage and durability move together, so on
  level, shots-to-kill (§3) stay the same at every level.
- Being **off level** is what changes the numbers: a gun one level behind does 80% of an on-level
  gun of the same rarity, two behind 64%.
- Reaching a new level is expected to take a while, so a good gun carries across a level change.

The 25% is a starting point. It is one constant and enemy health follows it; nothing else needs to
know.

## 2. Rarity

Six rarities. Rarity multiplies base damage (Borderlands), and buys modifier slots (§6).

| Rarity | Colour | Damage | Slots | Worth (levels of growth) |
|---|---|---|---|---|
| Common | white | 1.00× | 1 | — |
| Uncommon | green | 1.15× | 2 | 0.6 |
| Rare | blue | 1.30× | 3 | 1.2 |
| Epic | purple | 1.45× | 4 | 1.7 |
| Legendary | orange | 1.75× | 4 + red text | 2.5 |
| Mythic | pink | 1.75× | 4 + red text + a mythic effect | 2.5 |

"Worth" = ln(rarity) / ln(1.25): how many levels of growth the colour is worth. The rules this
table is built to hold:

- **A purple stays viable for two levels.** One level on, a level N purple (1.45 / 1.25 = 1.16) is
  about a **good uncommon** of level N+1. Two levels on (0.93) a common overtakes it.
- **A blue is worth about one level**: a level N+1 white ≈ a level N blue.
- **Legendary and Mythic share a damage multiplier.** A Mythic's special effect is what makes it
  better; it does not also need more damage. (If play says it does, ~1.9× is the next step.)

## 3. Shots to kill — the anchor

Borderlands scaling, but with Halo's habit of designing around shots-to-kill. The anchor:

> **On level, a common pistol kills a light enemy in 6 body shots (5–7 is the band). A legendary
> pistol of the same level kills it in 2–3.**

A 1.75× legendary alone takes 4 body shots, so the last step comes from **skill or build, not the
colour alone**:

| Light enemy, pistol, on level | Body shots | With headshots (2×) |
|---|---|---|
| Common 1.00× | 6 | 3 |
| Uncommon 1.15× | 6 | 3 |
| Rare 1.30× | 5 | 3 |
| Epic 1.45× | 5 | 3 |
| Legendary 1.75× | 4 | **2** |
| Legendary + one damage modifier (+20%) | **3** | **2** |
| Legendary from last level (1.40×) | 5 | 3 |

Every other class gets its own anchor row against the light enemy (a rifle ~8 body / 4 head, a
sniper 2 body / 1 head, a shotgun 1–2 close), so a class's feel is set once and holds at every
level. The class presets already carry per-class damage at ~60 DPS parity; the anchors become
their acceptance tests.

## 4. Enemies: defences, crits and melee

### 4.1 Melee scales with level

Melee damage is not a flat number: **one melee = a very light enemy's whole health, at the
player's level.** It grows ×1.25 per level like everything else, so against on-level enemies the
melee counts never change:

| Enemy weight | Health (in melees) | Pistol, common, body shots |
|---|---|---|
| Very light | 1 melee | 3 |
| Light | 2 melees | 6 (the anchor) |
| Medium | 3 melees | 9 |
| Heavy | more, plus defences | — |

Off level it drifts the same way guns do: an enemy a level above takes 1.25× as many.

### 4.2 Defences sit over the flesh

An enemy is **flesh** (health) and may wear **shield** and/or **armor** over it. Each type says how
much it has, measured the same way — in melees to break — and guns break them too.

| Defence | Regenerates | Weak to | Notes |
|---|---|---|---|
| Shield | yes, after a delay | **Shock** (and melee, 1.5×) | Absorbs crits: no crit bonus while it holds |
| Armor | no | **Explosive** | Absorbs crits; can sit on the crit spot itself (a helmet) |
| Flesh | no | **Fire** | Takes crits |

Example roster (to tune): a *light trooper* is 2 melees of flesh; a *shielded trooper* is
1 melee of shield over 2 of flesh; a *heavy* is 2 melees of armor over 4 of flesh, with a helmet
(1 melee of armor on the head) guarding the crit spot until it is broken.

### 4.3 Crits are places, not dice

A crit is a hit on a **crit spot** — usually the head, sometimes a weak point (a pack, a joint) per
enemy type. Each pawn gets a small hurtbox per spot. The random `crit_chance` roll goes.

- **Crit multiplier**: 2× (the class may vary it; a sniper higher).
- **Shields and armor absorb crits**: while a shield is up, or while a helmet covers the head, a
  head hit does normal damage to that defence.
- Deterministic: where the round hit decides it, not a roll — every co-op peer agrees for free.

### 4.4 Shield gating

When a body shot breaks a shield, **only half the damage left over carries into the flesh.** When
a **headshot** breaks it, the gate is skipped and the whole rest carries — the precision shot is
rewarded even through the last sliver of shield.

### 4.5 The loop this is built to encourage (not force)

- **Melee, then the head**: a melee strips a shield (1.5×) or cracks a helmet, and the next
  headshot crits for the kill.
- **Strip, then finish**: shock rounds take the shield down fast, a kinetic or fire headshot
  finishes the flesh.
- **Weaken, then punch**: rounds wear the shield thin, and the melee's spillover finishes.

None of it is required; all of it is faster than holding the trigger on a shield.

## 5. Damage types and elements

**Kinetic** is every gun's baseline. On top, a gun may carry one of **three elements** (the
per-gun element ratio already built stays: part of each round is element, the rest kinetic):

| Element | Strong vs | Weak vs |
|---|---|---|
| Shock | Shield (2×) | — |
| Fire | Flesh (1.5×) | Armor (0.75×) |
| Corrosive | Armor (2×) | Shield (0.75×) |

**Explosive** is not an element but a damage type, for two kinds of weapon:

- **Explosive guns** (grenade-round rifles, launchers firing small rounds): bonus vs **armor**
  and **more wear on bricks** per hit — they chip walls faster, they do not blow holes.
- **Ordnance** (rocket launchers, grenades): the big brick destruction — a blast that removes
  bricks outright (`StructuralDamage` already makes ordnance a blast and everything else a chip).

*Open: the Corrosive row overlaps Explosive (both strong vs armor). Keep both (corrosive for
guns, explosive for ordnance), or make the three elements Shock / Fire / Explosive and drop
Corrosive.*

## 6. Modifiers

Rarity sets the number of slots (§2). Modifiers are percentages, so they scale with level for free:

- **Stat**: magazine, reload, handling (ADS speed, recoil, sway), swap speed.
- **Utility**: shield regen on kill, ammo back on headshot, longer slide, faster melee.
- **Mechanical**: element conversion, split rounds, conditional damage (+X% on a staggered
  enemy), **Overkill Ricochet** (a killing blow's excess jumps to a nearby enemy).
- **Damage** (+X%) is a modifier like any other — the "build" half of §3's 2–3 shots.

Legendary red text and Mythic effects are named, hand-written behaviours, not random rolls.

The manufacturer parts already built (parts that add or multiply stats) become the source of
modifiers: a part fills a slot.

## 7. Carrying four guns

Four weapon slots (Borderlands), with swap. Swap speed becomes a real stat, and the HUD shows the
four. Ammo per type (light / rifle / sniper / shell / ordnance) is shared across them.

## 8. Bricks

Guns chip bricks (hits to break one brick per class, `StructuralDamage`); **explosive guns chip
harder**; **ordnance blasts**. Elements do not change brick damage (fire scorching bricks is a
cosmetic mark, already built).

## 9. Against what is built

| Built (BoomerBorder copy) | This design | Change |
|---|---|---|
| `TIER_STEP = 1.6` (68.7× over 10 tiers) | 1.25 (7.45×) | constant; enemy HP table moves with it |
| `Rarity.MULTS` 1.0 / 1.3 / 1.6 / 2.0 / 3.3 / 5.0 | 1.0 / 1.15 / 1.30 / 1.45 / 1.75 / 1.75 | constant; rename *Unique* → *Epic* |
| Crit = random `crit_chance` × class `crit_mult` | crit spots (hurtboxes), 2× | hurtboxes on pawns; `GunController._hit_living` reads the spot hit |
| Defence layers stack, spill over in full | shield / armor / flesh, crits absorbed, shield gating | `HealthPool`: a carry-over factor and a crit flag on the packet |
| 7 elements, effectiveness matrix | 3 elements + explosive type | trim the element list; matrix is data |
| No melee | level-scaled melee, 1.5× vs shield | new: input, motion, hit, damage |
| One gun in hand | four slots, swap | inventory, HUD, view (swap animation) |
| Parts with stat adds/mults, rarity → extra parts | slot-limited modifiers + red text | parts become modifiers; slots by rarity |
| Ordnance blasts bricks, guns chip | + explosive guns chip harder | one multiplier in `StructuralDamage` |

## 10. Build order (proposed)

1. **Numbers**: `TIER_STEP`, rarity table and names, enemy HP; the §3 anchors as a probe.
2. **Crit spots**: head hurtboxes, crit by location, shields/armor absorb crits.
3. **Defences**: shield / armor / flesh per enemy type, shield gating, the three elements.
4. **Melee**: key, motion, hit, level scaling, the melee-then-headshot loop tested.
5. **Four slots**: inventory, swap, HUD.
6. **Modifiers**: slots by rarity, the first modifier set, the first red-text effects.
7. **Explosive guns**: armor bonus, brick wear.
