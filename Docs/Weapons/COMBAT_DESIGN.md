# Combat and weapon design — Borderlands loot, Halo fights

**Status: proposal, agreed in outline 2026-10-05 (melee counted per layer and the element set
revised the same day); numbers to tune in play.** Supersedes the
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

### 4.1 Melee counts are readable

The goal: **a player who looks at an enemy knows exactly how many melees it takes.** So melee is
counted per LAYER, not as one pool of health:

- Every defence (shield or armor) says how many melees break it.
- **Flesh is one melee, for every enemy up to medium.** Heavier enemies may need more.
- **A melee that breaks a defence stops there** — it does not spill into the flesh. One hit is one
  step, always.

| Enemy | Defence | Flesh | Melees to kill |
|---|---|---|---|
| Very light, bare | — | 1 | **1** |
| Very light, shielded or armored | 1 | 1 | **2** |
| Light | 1–2 | 1 | **2–3** |
| Medium | 3 | 1 | **4** |
| Heavy | more | more | per type |

Melee damage is sized to that: **one melee = one step at the player's level**, and grows ×1.25 per
level with everything else, so on level the counts never change. An enemy above your level takes
1.25× per level as much, and the extra hit shows up there first.

Guns wear the same layers, so an enemy already shot up takes fewer melees — the counts above are
for an untouched enemy, and the HUD should show a cracked shield or armor so the player can read
that too.

### 4.2 Defences sit over the flesh

An enemy is **flesh** (or, for plant-based enemies, **vegetation**) and may wear **shield** and/or
**armor** over it. Guns break them too.

| Layer | Regenerates | Weak to | Notes |
|---|---|---|---|
| Shield | yes, after a delay | **Plasma**, melee (1.5×) | Absorbs crits: no crit bonus while it holds |
| Armor | no | **Corrosive** | Absorbs crits; can sit on the crit spot itself (a helmet) |
| Flesh | no | **Acid** | Takes crits |
| Vegetation | no | **Fire** | Plant enemies' flesh. Takes crits |

Gun shots-to-kill (§3) are against the flesh; defences add their own shots on top, and each enemy
type's card lists both. A very light enemy's flesh can be less than a light one's for guns (a
common pistol: 3 shots vs 6) while still being one melee for both.

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

- **Melee, then the head**: a melee strips a shield or cracks a helmet, and the next headshot
  crits for the kill.
- **Strip, then finish**: plasma rounds take the shield down fast, a kinetic or acid headshot
  finishes the flesh.
- **Weaken, then punch**: rounds wear the shield or armor thin, a melee breaks it, and the next
  melee (or a headshot) takes the flesh — the count the player can read.

None of it is required; all of it is faster than holding the trigger on a shield.

## 5. Damage types and elements

**Kinetic** is every gun's baseline. On top, a gun may carry **one element** (the per-gun element
ratio already built stays: part of each round is element, the rest kinetic). One element per
layer type, so the chart is one line each:

| Element | Strong vs | Also |
|---|---|---|
| **Plasma** | Shield (2×) | — |
| **Corrosive** | Armor (2×) | — |
| **Acid** | Flesh (1.5×) | — |
| **Fire** | Vegetation (2×) | burns plant enemies over time |
| **Ice** | — (neutral damage) | slows, and freezes an enemy that takes enough |

Nothing is weak AGAINST an element (no 0.5× rows): an element is a bonus where it fits and plain
damage where it does not. Simple enough to hold in your head mid-fight.

**Shock is not a gun element.** It belongs to special weapons (§7): a shot that arcs from enemy to
nearby enemy and slows each one it touches — a Wunderwaffe.

**Explosive is not an element either** — it is an **attachment** (§6.1), as in Borderlands 4.

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

### 6.1 The explosive attachment

A gun with it fires rounds that **always explode on impact** — area damage around the hit, in the
round's own element (or kinetic). Rarer rolls change *when* it explodes:

- **Proximity**: the round bursts as it passes near an enemy, even on a miss.
- **Chain**: it bursts near an enemy and keeps flying, bursting again at the next one.

Explosive rounds also **wear bricks harder** (§8) — they chip walls faster but do not blow holes.

## 7. Carrying four guns, and ordnance

**Four gun slots** (Borderlands), with swap. Swap speed becomes a real stat, and the HUD shows the
four. Ammo per type (light / rifle / sniper / shell) is shared across them.

**Ordnance** is a separate slot (Borderlands 4): rocket launchers, grenades, and **special
weapons** — cooldown- or charge-gated rather than magazine-gated (the ordnance classes already
built work this way). Special weapons are where unusual effects live, **shock** first: the round
arcs across several nearby enemies and slows them.

The same ordnance effects can also roll onto a gun as an **underbarrel / alternate fire** (a
grenade tube under a rifle, a shock arc on a pistol's second trigger), on the same cooldown rules.

## 8. Bricks

Guns chip bricks (hits to break one brick per class, `StructuralDamage`); **explosive rounds chip
harder**; **ordnance blasts** — rockets and grenades are where big holes come from. Elements do not
change brick damage (fire scorching bricks is a cosmetic mark, already built).

## 9. Against what is built

| Built (BoomerBorder copy) | This design | Change |
|---|---|---|
| `TIER_STEP = 1.6` (68.7× over 10 tiers) | 1.25 (7.45×) | constant; enemy HP table moves with it |
| `Rarity.MULTS` 1.0 / 1.3 / 1.6 / 2.0 / 3.3 / 5.0 | 1.0 / 1.15 / 1.30 / 1.45 / 1.75 / 1.75 | constant; rename *Unique* → *Epic* |
| Crit = random `crit_chance` × class `crit_mult` | crit spots (hurtboxes), 2× | hurtboxes on pawns; `GunController._hit_living` reads the spot hit |
| Defence layers stack, spill over in full | shield / armor / flesh / vegetation; crits absorbed; shield gating; melee stops at the layer it breaks | `HealthPool`: a carry-over factor and crit/melee flags on the packet |
| Elements incl. shock, corrosive, acid, fire; weak-against rows | plasma / corrosive / acid / fire / ice, bonus-only; shock on special weapons | element list and matrix (data); ice's slow/freeze is a status |
| "Explosive" as a gun effect | an attachment: always area damage; proximity and chain variants | effect becomes an attachment with variants |
| No melee | per-layer, level-scaled melee | new: input, motion, hit, damage |
| One gun in hand | four gun slots + an ordnance slot; alt-fire | inventory, HUD, view (swap) |
| Parts with stat adds/mults, rarity → extra parts | slot-limited modifiers + red text | parts become modifiers; slots by rarity |
| Ordnance blasts bricks, guns chip | + explosive rounds chip harder | one multiplier in `StructuralDamage` |

## 10. Build order (proposed)

Tested in the combat arena (`scenes/combat_arena.tscn`), where the weapons and the soldiers are.

1. **Numbers**: `TIER_STEP`, rarity table and names, enemy HP; the §3 anchors as a probe.
2. **Crit spots**: head hurtboxes, crit by location, shields/armor absorb crits.
3. **Layers**: shield / armor / flesh / vegetation per enemy type, shield gating, the five
   elements.
4. **Melee**: key, motion, hit, per-layer counts, the melee-then-headshot loop tested.
5. **Four slots + ordnance**: inventory, swap, HUD, the ordnance slot.
6. **Modifiers**: slots by rarity, the first modifier set, the explosive attachment, the first
   red-text effects.
7. **Special weapons and alt-fire**: the shock arc first.
