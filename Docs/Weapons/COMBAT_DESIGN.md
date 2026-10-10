# Combat and weapon design — Borderlands loot, Halo fights

**Status: version 2, agreed 2026-10-09** (version 1 agreed 2026-10-05). Version 2 adds a player
level that grows abilities rather than damage, a much smaller rarity damage step with the power
moved into modifiers, two weapon groups of two guns, floor pickups, tracking-dart alt-fires and
safehouse infusion. Numbers are to tune in play. Supersedes the power curve and rarity table of
`GUN_SCALING_SPEC.md` / `PROGRESSION_SPEC.md` where they differ (§11 lists every change against
what is built; §12 is the build order).

The aim in one line: **Borderlands' loot chase on top of Halo's combat sandbox.** Guns are
generated, tiered and coloured by rarity, and the loot keeps the player searching — but fights are
won Halo's way: strip the defence, then land the precision shot, and melee is a real tool in that
loop rather than a panic button.

What that means for a gun picked up off the floor: **any gun works.** Every gun of a tier hits
about as hard as any other of that tier and class, so a white is a real weapon, not junk. A higher
rarity is better because of *what it carries* — more modifiers, stronger ones, a red-text effect —
not because its numbers are bigger. The player picks up a white, uses it, and finds it worked but
was not as good as the purple they lost: that is what drives the search.

---

## 1. Two progressions, kept apart

| | Player level (1–100) | Weapon tier (1–10) |
|---|---|---|
| Earned by | XP: kills, objectives, missions | the story: each act / zone opens the next tier |
| Grows | skill points: abilities, mobility, cooldowns, melee tricks; health or shields **only if the player spends points there** | gun base damage and enemy durability, together |
| Never touches | gun damage, melee damage | the player's health, abilities |

The two never feed each other. A player level is never part of a damage number, so on level the
shots-to-kill (§3) hold whatever the player's level; a higher level gives the player more *ways* to
fight, not bigger numbers.

### 1.1 Weapon tiers

- **10 tiers**, tied to story progress: tier 1 is the starting outposts, tier 10 the end-game
  zones. A zone drops guns of its own tier (an enemy above the player's tier drops at its own tier;
  one below drops at the player's — `LootRoller.drop_tier`, so a low zone is never a farm).
- **25% per tier**: a gun's base damage, every enemy's durability and the melee (§4.1) are ×1.25
  per tier (`Tier.TIER_STEP = 1.25`). Tier 10 is 7.45× tier 1. They move together, so on level
  shots-to-kill are the same at every tier.
- Being **off tier** is what changes the numbers: a gun one tier behind does 80% of an on-tier gun,
  two behind 64%.
- A gun's tier is fixed when it drops, until it is **infused** (§1.2).

### 1.2 Safehouse infusion

At a safehouse workbench the player spends materials to raise a gun to their **current story tier**.
Everything else about the gun stays: its parts, modifiers, alt-fire, element, name. Only its base
damage moves to the new tier.

- It can never go above the player's current story tier.
- The cost grows with the tiers gained and with the gun's rarity (an infused legendary costs more
  than an infused white).
- This is what keeps a favourite gun alive. A god-roll purple from tier 2 can come along to tier 7.
- Built on what is there: a saved gun is `{class, seed, tier, rarity}` (`CharacterSave.gun_entry`),
  and its tier only scales damage (`GunStats.compute`), never a roll — so infusion is rewriting
  `tier` in the entry. A probe must hold that: the same seed at two tiers gives the same gun except
  damage.

### 1.3 Player level and the skill tree

- **Levels 1–100**, from XP. Each level gives a **skill point**; some levels also unlock an
  **ability** slot or a new ability (grapple hook, overshield, and so on — the mech FPS's kit).
- **No automatic stat growth.** Health and shields do not rise by themselves with level.
- **Health and shields are a player choice:** the tree has nodes that raise them, and the player
  decides whether to spend points there. Their total is capped (about **+30%** over base, all nodes
  bought) so a high level cannot make a tier trivial — on level an enemy still kills you in about
  the same number of hits.
- Everything else in the tree is horizontal: abilities and their cooldowns, mobility (slide, lunge,
  air dash), swap and reload speed, melee augmentations (§4.2), ammo and grenade capacity.
- Where it lives: `CharacterSave.character` already has `level`; XP, skill points and bought nodes
  join it.

## 2. Rarity

Six rarities. Rarity buys **modifier slots and modifier quality**, and a **small** damage step so a
higher colour is felt in the hand — but not so much that a white stops working.

| Rarity | Colour | Damage | Slots | On top |
|---|---|---|---|---|
| Common | white | 1.00× | 1 | — |
| Uncommon | green | 1.03× | 2 | — |
| Rare | blue | 1.06× | 3 | — |
| Unique | purple | 1.09× | 4 | — |
| Legendary | orange | 1.12× | 4 | red text: a hand-written effect |
| Mythic | **red** | 1.12× | 4 | red text + a mythic effect |

- The whole colour range is worth about **half a tier** of damage (ln 1.12 / ln 1.25 = 0.51). A
  colour on its own does not change a shots-to-kill count (§3); a built gun does.
- **Modifier quality climbs with rarity.** A modifier rolls inside a band (§6), and a higher rarity
  rolls nearer the top (`Rarity.stat_roll_quality`, already a field). So a purple's +damage
  modifier is usually bigger than a green's, and it has three more of them.
- Legendary and Mythic share a damage step: a Mythic's own effect is what makes it better.

## 3. Shots to kill — the anchor

Halo's habit: design around shots-to-kill and keep them readable. The anchor, on level, against a
light enemy (the `trash` archetype, `LootRoller.TRASH_BASE_HP` = 64 at tier 1), with a median-roll
pistol (11.05 a shot at tier 1):

| Light enemy, pistol, on level | Damage a shot | Body shots | Headshots (2×) |
|---|---|---|---|
| Common | 11.05 | **6** | **3** |
| Legendary, no modifiers (1.12×) | 12.4 | 6 | 3 |
| Common + one damage modifier (+20%) | 13.3 | 5 | 3 |
| Legendary + one damage modifier (+20%) | 14.9 | 5 | 3 |
| Purple or legendary + two damage modifiers (+40%) | 16.9–17.3 | **4** | **2** |
| Any of the above, one tier behind (×0.8) | — | one more, usually | — |

**The colour gets you nothing alone; the build does.** A two-headshot kill takes a gun with the
slots to carry two damage modifiers (purple and up) *and* the aim. That is the chase: a white works,
a built purple works better, a legendary works better again because its red text does something no
white can.

Power-shot and double-fire modifiers (§6) change the count for some shots of a magazine rather than
every shot; they are counted in their own rows when built.

Every other class gets its own anchor row against the light enemy (a rifle ~8 body / 4 head, a
sniper 2 body / 1 head, a shotgun 1–2 close), so a class's feel is set once and holds at every
tier.

### 3.1 Variance inside one colour

Two guns of the same class, tier and rarity differ in **how** they deal damage, not how much:

- **Named parts carry the trades**, readable on the card: a *Heavy Barrel* +8% damage −10% fire
  rate; a *Rapid Receiver* −8% damage +15% fire rate. A part's trade stays inside **±5–10%** on any
  one stat.
- The hidden power roll shrinks: today a gun's DPS rolls 1.00–1.28× (`GunStats.DPS_WINDOW`), wider
  than the whole rarity range. It comes down to about **1.00–1.10×**, so two guns of one colour
  never sit a shots-to-kill count apart on the roll alone. The damage-vs-fire-rate trade
  (`FIRE_BASE` 0.80–1.25) stays: it is feel, not power.
  Shrinking it lowers the median roll (1.14× to 1.05×), so the light enemy's health is re-anchored
  with it (`TRASH_BASE_HP` about 64 → 59) to keep a median common at 6 shots — the §3 table is
  in shots, and the shots are what must hold.
- Part quality's own swing stays at ±3% (`PART_SWING`).

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

**Melee damage scales with the player's current story tier** — not the gun in hand, not the
player level. One melee = one step at that tier (`CombatScale.melee`): 64 at tier 1, ×1.25 a tier
(156 at tier 5, 477 at tier 10), and **1.5× against shields**, so one melee always breaks one
"melee's worth" of shield. On level the counts never change. An enemy above your tier takes 1.25× per
tier as much, and the extra hit shows there first.

Guns wear the same layers, so an enemy already shot up takes fewer melees — the counts above are
for an untouched enemy, and the HUD should show a cracked shield or armor so the player can read
that too.

### 4.2 Melee in the skill tree — the Vanguard Brawler branch

Melee damage itself never comes from the player level (§1). What the level buys is what a melee
*does*:

| Node | Effect |
|---|---|
| **Kinetic Lunge** (mobility) | +50% melee lunge distance; a sprinting slide-punch launches light enemies backward. Closes the gap on a staggered enemy for the finishing blow. |
| **Shield-Shatter Shockwave** (tactical) | A melee that breaks a shield sends a shockwave, 4 m round: staggers everything in it and strips 25% of *their* shields. |
| **Backstab** (lethality) | A melee from behind does 2.5×, and a heavy enemy's frontal armor plates do not cover its back. This deliberately breaks the §4.1 counts from behind: a paid-for skill, read by position. |
| **Vampiric Impact** (sustain) | A melee kill restores 50% of your shield and refills the magazine of the gun in hand. |

These are the first branch; other branches (marksman, elements, mobility, survival — where the
health and shield nodes live) are to design. The brawler loop they serve: **punch to break a
defence, shoot to finish, refill the shield, push the next one.**

### 4.3 Defences sit over the flesh

An enemy is **flesh** (or, for plant-based enemies, **vegetation**) and may wear **shield** and/or
**armor** over it. Guns break them too.

| Layer | Regenerates | Weak to | Notes |
|---|---|---|---|
| Shield | yes, after a delay | **Plasma**, melee (1.5×) | Absorbs crits: no crit bonus while it holds |
| Armor | no | **Corrosive** | Absorbs crits; can sit on the crit spot itself (a helmet) |
| Flesh | no | **Acid** | Takes crits |
| Vegetation | no | **Fire** | Plant enemies' flesh. Takes crits |

The enemy kinds, in game terms:

- **Shielded infantry** (an "Elite"): a regenerating shield over flesh; the shield eats headshots.
- **Armored brutes and heavy mechs**: armor plates and big health; strip the armor, or get round it
  (Backstab, weak spots).
- **Light swarms** (grunts, drones): little health, many of them; the targets for chain effects —
  Overkill Ricochet, explosive rounds.

Gun shots-to-kill (§3) are against the flesh; defences add their own shots on top, and each enemy
type's card lists both.

### 4.4 Crits are places, not dice

A crit is a hit on a **crit spot** — usually the head, sometimes a weak point (a pack, a joint) per
enemy type. Each pawn gets a small hurtbox per spot. There is no random crit roll.

- **Crit multiplier**: 2× (a DMR or revolver 2.5×, a sniper 3×).
- **Shields and armor absorb crits**: while a shield is up, or while a helmet covers the head, a
  head hit does normal damage to that defence.
- Deterministic: where the round hit decides it — every co-op peer agrees for free.

### 4.5 Shield gating

When a body shot breaks a shield, **only half the damage left over carries into the flesh.** When
a **headshot** breaks it, the gate is skipped and the whole rest carries — the precision shot is
rewarded even through the last sliver of shield.

### 4.6 The loop this is built to encourage (not force)

- **Melee, then the head**: a melee strips a shield or cracks a helmet, and the next headshot crits
  for the kill.
- **Strip, then finish**: plasma takes the shield down fast, a kinetic or acid headshot finishes the
  flesh.
- **Weaken, then punch**: rounds wear the shield or armor thin, a melee breaks it, and the next melee
  (or a headshot) takes the flesh.
- **Tag, then pour**: a tracking dart (§7.2) marks a spot, the follow-up rounds go there.

None of it is required; all of it is faster than holding the trigger on a shield.

**Worked example — the Elite.** A tier-5 Elite Commander: shield over flesh. Group 1 is a blue
plasma pistol (charged-shot alt-fire) and a purple kinetic DMR (two damage modifiers, Overkill
Ricochet).

1. Tap swap to the plasma pistol; hold the trigger and release the charged shot: plasma is 2×
   against shields, and the charged shot takes the whole shield (it costs the pistol's heat — §7.2).
2. Tap swap to the DMR. The shield is down, so the head is open: crits land.
3. Two headshots. The second kills, and Overkill Ricochet carries the excess into the grunt beside
   it.

## 5. Damage types and elements

Elements stay, Borderlands-style: **kinetic** is every gun's baseline, and a gun may carry **one
element** (part of each round is element, the rest kinetic — the per-gun ratio already built). One
element per layer type, so the chart is one line each:

| Element | Strong vs | Status |
|---|---|---|
| **Plasma** | Shield (2×) | — |
| **Corrosive** | Armor (2×) | corrodes: armor keeps losing a little for a few seconds |
| **Acid** | Flesh (1.5×) | — |
| **Fire** | Vegetation (2×) | burns: flesh and vegetation take damage over time |
| **Ice** | — (neutral damage) | slows, and freezes an enemy that takes enough |

- Nothing is weak AGAINST an element (no 0.5× rows): an element is a bonus where it fits and plain
  damage where it does not. Simple enough to hold in your head mid-fight.
- **Statuses are not dice.** In Borderlands a burn is a chance to proc; here the element part of a
  round always builds its status, so co-op peers agree and the player can count on it.
- Building **an element to match the enemy** is the Borderlands half of the loop: a plasma gun in
  one group for shielded infantry, a corrosive one for armor.

**Shock is not a gun element.** It belongs to special weapons (§7.3): a shot that arcs from enemy to
nearby enemy and slows each one it touches.

**Explosive is not an element either** — it is an **attachment** (§6.1).

## 6. Modifiers

Rarity sets the number of slots and how high the modifiers roll (§2). Modifiers are percentages or
counts, so they scale with tier for free. **This is where a gun's power comes from.**

- **Damage**: +X% damage (rolls +10–20%; a higher rarity rolls nearer +20%). Two of them on one gun
  is what moves a shots-to-kill count (§3).
- **Firing personality**:
  - **Power shot**: every Nth round (N = 4–6) does 2×.
  - **Double fire**: every Nth round fires a free extra round (no ammo). A rarer roll makes it
    random instead — about one round in five — drawn from the gun's own seeded stream so every peer
    agrees.
  - **Split rounds**, **conditional damage** (+X% on a staggered enemy, on a shield-broken enemy),
    **Overkill Ricochet** (a killing blow's excess, up to 150%, jumps to a nearby enemy),
    **Shield Buster** (+X% against shields).
- **Stat**: magazine, reload, handling (ADS speed, recoil, sway), swap speed.
- **Utility**: shield regen on kill, ammo back on headshot, longer slide, faster melee.
- **Mechanical**: element conversion; the **explosive attachment** (§6.1).

Legendary red text and Mythic effects are named, hand-written behaviours, not random rolls.

The manufacturer parts already built (parts that add or multiply stats) become the source of
modifiers: a part fills a slot.

### 6.1 The explosive attachment

A gun with it fires rounds that **always explode on impact** — area damage around the hit, in the
round's own element (or kinetic). Rarer rolls change *when* it explodes:

- **Proximity**: the round bursts as it passes near an enemy, even on a miss.
- **Chain**: it bursts near an enemy and keeps flying, bursting again at the next one.

Explosive rounds also **wear bricks harder** (§8) — they chip walls faster but do not blow holes.

## 7. Loadout, alt-fire and ordnance

### 7.1 Two groups of two guns

```
 Group 1          Group 2
 [ A ] [ B ]      [ A ] [ B ]
```

- **Tap swap** (Y on a pad): instantly to the other gun in the active group. This is Halo's
  two-gun swap, built for "strip with one, finish with the other".
- **Hold swap**: to the other group (its last-held gun). For a big change of target — infantry
  clearing to mech killing.
- **Tap must not wait for hold to be ruled out.** The swap starts on the press; if the button is
  still down at the hold threshold (~0.25 s), the in-group swap is cut short and the group swap
  runs instead. A tap never waits.
- Two groups for now. A third is a later choice.
- Swap speed is a real stat (modifiers, skill tree). Ammo per type (light / rifle / sniper / shell)
  is shared across all four guns.
- On a keyboard, number keys pick a slot directly (1–2 group 1, 3–4 group 2) as well as the swap
  key. All of it is rebindable.

### 7.2 Alt-fire

A gun may roll an **alt-fire** (its second trigger). It is part of the gun's personality, like its
modifiers, and stays with it through infusion. Alt-fires are setup tools that still do real damage —
never a zero-damage tag.

**Tracking dart** (hold to charge):

- Hold the alt-fire to charge (~0.5 s), release to fire a heavy **dart**. It does real damage on
  the hit, as a heavy shot would.
- The dart is a **projectile**, deliberately slow (start at about 40 m/s, to tune): the player
  leads a moving target. Landing it is the skill.
- It sticks where it hits and **marks that spot for 2–3 s** (start at 2.5 s), or until the player
  fires another dart — a new dart ends the old mark at once, hit or miss.
- While the mark holds, the player's primary rounds **go to the marked spot**. If the dart is in a
  crit spot (the head), the rounds that go there **crit** — the precision was in landing the dart.
- Shields and helmets still absorb crits (§4.4): a dart in a shielded Elite's head gives no crit
  until the shield is down. Tag-then-pour does not skip the strip.
- Guns are hitscan, so "go to the spot" is a **cone**: a round fired within about 15° of the mark
  is bent onto it; one fired further off flies straight. The player still has to point at the
  target.
- One mark per player.

**Homing (any other homing source)** — a seeker round, a homing launcher: aims at the **centre of
the target's body** and **can never crit**. Halo's needler, not an aimbot.

**Charged shot** (the plasma pistol's): hold to charge, release a shot that takes a whole shield.
It costs the gun's heat (or a large ammo bite) so it cannot be spammed; it is a shield answer, not
a damage answer.

**Other alt-fires** come from the ordnance effects: an underbarrel grenade tube on a rifle, a shock
arc on a pistol, a thermal torch on a corrosive beam (armor melt) — on cooldowns, like ordnance.

### 7.3 Ordnance and grenades

- **Ordnance** is its own slot (Borderlands 4): rocket launchers and **special weapons** — gated by
  a cooldown or charge, not a magazine. **D-pad right** brings it up (a key on the keyboard); swap or
  D-pad right again goes back to the gun you had.
- Special weapons are where unusual effects live, **shock** first: the round arcs across several
  nearby enemies and slows them.
- **Grenades** have a slot of their own and are **thrown with G** (right bumper on a pad) without
  putting the gun away. A grenade is ordnance for bricks (§8): it blasts.

### 7.4 Picking up a gun off the floor

A gun on the floor (`WorldGunPickup`, with its card and rarity beam) can be tried without touching
the loadout:

- **Hold X** (the interact key): pick it up into a **third hand**. The loadout is untouched.
- **Tap swap** while holding it: drop it where you stand and draw the gun you had.
- **Keep it**: hold **D-pad left** to put it in slot A of the active group, **D-pad up** for slot B.
  The gun it replaces drops where you stand (a backpack is a later choice — §13).
- Switching group, or picking up another floor gun, drops the one in the third hand.

### 7.5 Input summary

| Input (pad / keyboard) | Does |
|---|---|
| Y tap / swap key tap | the other gun in the group |
| Y hold / swap key hold | the other group |
| 1–4 (keyboard) | that slot directly |
| D-pad right / ordnance key | the ordnance |
| G / right bumper | throw a grenade |
| X hold / interact hold | pick a floor gun into the third hand |
| D-pad left / up (holding a floor gun) | keep it in slot A / B of the active group |
| Alt-fire (aim button on guns that have one, or its own key) | the gun's alt-fire |
| Right stick click / E | melee |

Alt-fire and aim share a button on a pad, so a gun with an alt-fire either has no aim-down-sights
or puts the alt-fire on a separate bind; to decide when alt-fire is built (§13).

## 8. Bricks

Guns chip bricks (hits to break one brick per class, `StructuralDamage`); **explosive rounds chip
harder**; **ordnance blasts** — rocket launchers and grenades are where big holes come from. Elements
do not change brick damage (fire scorching bricks is a cosmetic mark, already built).

## 9. Version 1 (2026-10-05) in short

What version 2 changed from it, for anyone reading §14's history: rarity damage was
1.0 / 1.15 / 1.30 / 1.45 / 1.75 / 1.75 (a purple viable two tiers; infusion now does that job);
four gun slots with tap-to-cycle and hold-for-ordnance (now two groups of two, ordnance on D-pad
right); no player level at all (now 1–100, abilities only); Mythic was pink (now red); the shot
anchor was "a legendary pistol kills in 4 body / 2 head" (now that takes a built gun).

## 10. Not in this design

- No player level in any damage number, gun or melee.
- No random crits, no random status procs.
- No unbounded scaling: tiers end at 10; past that is a difficulty choice, not more numbers.

## 11. Against what is built

| Built | This design | Change |
|---|---|---|
| `Rarity.MULTS` 1.0 / 1.15 / 1.30 / 1.45 / 1.75 / 1.75 | 1.00 / 1.03 / 1.06 / 1.09 / 1.12 / 1.12 | constant; `combat_numbers_probe` anchor rows rewritten to §3 |
| `GunStats.DPS_WINDOW` 1.00–1.28 | about 1.00–1.10 | constant; the median moves, so `LootRoller.TRASH_BASE_HP` is re-anchored (§3.1) |
| Parts with stat adds/mults, rarity → extra parts | slot-limited modifiers, quality by rarity, named trade parts, red text | parts become modifiers |
| Mythic colour `GunCard.RARITY_COLORS[5]` (1.0, 0.25, 0.35) | red | already red-ish; check it reads as red next to orange |
| `CharacterSave.character.level` (unused) | player level 1–100, XP, skill points, nodes | new: XP sources, tree data, save fields |
| `CombatScale.melee(level)` | the player's current story tier | "level" becomes story tier |
| No pickup flow | third hand, keep to slot | new |
| One gun in hand | two groups of two, ordnance on D-pad right, grenade on G | inventory, HUD, view (swap) |
| Crit spots, layers, gating, five elements (built) | unchanged | — |
| Fire burn, ice slow/freeze (not built) | + corrosive corrode; statuses always build | statuses (`scripts/status/` exists) |

## 12. Build order

Tested in the combat arena (`scenes/combat_arena.tscn`), where the weapons and the soldiers are.

1. ~~Numbers~~ (built; v2 changes them again in step 6).
2. ~~Crit spots~~ (built; deferred until enemies have heads).
3. ~~Layers and elements~~ (built).
4. **Melee**: key, motion, hit, per-layer counts, the melee-then-headshot loop tested.
5. **Two groups, ordnance, grenades, pickups**: inventory, tap/hold swap, D-pad ordnance, G throw,
   the third hand, HUD for the four.
6. **Rarity v2 and modifiers**: the new rarity step and DPS window, slots and quality by rarity,
   the first modifiers (damage, power shot, double fire, Overkill Ricochet), named trade parts, the
   explosive attachment, the first red-text effects.
7. **Alt-fire and special weapons**: tracking dart first, then the charged plasma shot and the shock
   arc.
8. **Elements' statuses**: burn, corrode, ice slow/freeze.
9. **Player level and the skill tree**: XP, points, the Vanguard Brawler branch, health/shield
   nodes with their cap, the first abilities.
10. **Safehouse infusion**: workbench, materials, the same-gun-at-another-tier probe.

## 13. Open questions

- Keep a backpack (Borderlands) or only the four guns plus the floor (Halo)?
- Co-op loot: shared floor guns (first to pick up owns it) or instanced per player?
- Alt-fire bind on a pad (it collides with aim).
- Melee key: E is free on a keyboard (V and F are taken in `city_scene.gd`); right stick click
  on a pad.
- Infusion materials: what they are and where they drop.
- The other skill-tree branches and the ability list.

---

## 14. Progress (what is built)

**Step 1 — numbers: built 2026-10-06.**
- `Tier.TIER_STEP` 1.6 → **1.25**; `GunQuality.LN_STEP` follows (a level is still 100 score
  points).
- `Rarity.MULTS` → **1.0 / 1.15 / 1.30 / 1.45 / 1.75 / 1.75**; the names stay (purple is Unique).
  (Version 2 replaces these with 1.00–1.12 — §2; not built yet, §12 step 6.)
- `LootRoller.TRASH_BASE_HP` (the light enemy) 45 → **64**, set from the §3 anchor: a median common
  pistol (11.05 a shot) kills it in 6. `LootRoller.enemy_hp` already steps with `Tier`, so every
  archetype moved with the curve.
- `tools/combat_numbers_probe.gd` (15 checks) holds §1–3: the curve, the anchor at every level, the
  legendary rows (4 / 2 with headshots / 3 with a modifier / 5 a level behind), what a colour is
  worth, the score step.
- **Not yet joined:** the combat arena's soldiers take their health from the AI's `UnitCatalog`
  (trash 45, standard 113), not from `LootRoller.enemy_hp`. Step 3 (layers per enemy type) is where
  the two become one table.

**Step 2 — crit spots: built 2026-10-06.**
- `CritSpots` (`scripts/combat/crit_spots.gd`): named spheres on a body, each following a node.
  Every pawn gets `head`, a sphere round its Eye (mid-head), so a crouched head is still the head.
  An enemy type can add weak points of its own.
- `GunController._hit_living` asks the struck body's `CritSpots` where the round landed. **The
  random `crit_chance` roll is gone**; a crit is a place, so every peer agrees without a roll and
  the gun's RNG is not touched.
- `DamageSystem.resolve` applies the crit only when the top living layer takes crits
  (`CRIT_LAYERS`: health / flesh / vegetation). A shield or armor over the flesh **absorbs** it:
  the hit lands plain and `DamageResult.crit_absorbed` says so (for a "blocked" hitmarker later).
- Class crit (headshot) multipliers: **2.0** pistol, SMG, rifle, LMG, shotgun; **2.5** DMR,
  revolver; **3.0** sniper.
- `tools/crit_probe.gd` (10 checks): head crits at the gun's multiplier, chest does not, the same
  shot always lands the same with no RNG drawn, a crouched head still crits where it went, a
  shield absorbs the crit until it breaks.
- Helmets (armor guarding the head spot specifically) come with step 3's layers.
- **Deferred (2026-10-06):** pawns get no head spot for now (`Pawn.head_crits = false`): the
  enemies are still capsules. The system stays built and tested (`crit_probe` switches it on);
  turn it on when enemies are figures with heads.

**Step 3 — defences and elements: built 2026-10-06.**
- `CombatScale`: the MELEE is the unit. One melee at level 1 = a light enemy's flesh = 64
  (`LootRoller.TRASH_BASE_HP`, the §3 anchor), ×1.25 a level. A shield of "one melee" holds
  1.5× that (melee is 1.5× vs shields). Shield gating 0.5. Shields regenerate after 3 s, full in
  2 s.
- `EnemyProfiles`: layers in melees, top first — `very_light` (½ flesh), `very_light_shielded`,
  `light` (1 flesh), `light_shielded`, `light_armored`, `medium` (3 armor + 1 flesh),
  `medium_shielded`, `heavy` (2 shield + 3 armor + 2 flesh), `plant` (1 vegetation).
- `Elements`: plasma / corrosive / acid / fire / ice and the effectiveness table every
  `HealthPool` uses by default; bonus-only.
- `DamageSystem`: an element's part of a round lands on the TOP layer (it used to go straight
  past the defences to its "tuned" layer), element first, then kinetic. `HealthPool.apply_impact`
  gates a body shot that breaks a shield; a crit-spot hit is ungated.
- Guns carry an element: `GunGenerator` rolls one for an elemental barrel from its own stream off
  the seed (no other roll moved), names it ("Charged", "Corroding", "Caustic", "Burning",
  "Frozen"), and `GunController` puts it on the round.
- The arena's units are profiles now (`UnitCatalog` "profile" replaces "hp"): rifleman and
  assault light, breacher light-armored, marksman very light, veteran medium, rocketeer
  light-shielded, officer medium-shielded; `WaveDirector.level` sizes them.
- `tools/defence_probe.gd` (19 checks).
- **Not yet:** ice's slow/freeze and fire's burn are statuses — later. An enemy's shield and armor
  are not yet SHOWN on the capsule; the player needs to read them (with melee, step 4). Helmets
  wait for head crits.

---

## 15. Handoff — pick up here (2026-10-06, next steps updated 2026-10-09)

Everything above through step 3 is **built, tested and merged into `main`**. The player side it
sits on (FPS movement, view model, HUD, settings menu) is documented in
[../Reference/ceramicedge.md](../Reference/ceramicedge.md) §0, §2.3–2.4, §7.1.

### 15.1 Next: step 4, melee

What it must do (§4.1, §4.6):

- **One melee = `CombatScale.melee(level)`**, at the player's current story tier (§4.1; never
  the player level). Against a shield it does 1.5×
  (that is why a shield's layer health is ×1.5 in `CombatScale.layer_hp` — the two must match, so
  one melee breaks exactly one shield-melee). Add the 1.5 as a damage type (e.g. a `&"melee"` row in
  `Elements.TABLE` with `&"shield": 1.5`, or a packet flag read in `DamageSystem`).
- **A melee stops at the layer it breaks**: no carry-over (call `apply_impact` with carry-over off
  for that hit — add a packet flag rather than flipping the pool's `impact_carries_over`). That is
  what keeps the table in §4.1 exact: a medium enemy is 3 + 1 = 4 melees, always.
- **Input**: a new rebindable action `melee` in `project.godot` [input] (V is "leave the pawn" and F
  the mech order in `city_scene.gd`; E is free; on a pad, right stick click). `PlayerController`
  reads actions via `_pressed()`/`_down()`; `PawnIntents` gets an edge-triggered `melee`.
- **Hit**: a short sphere/shape cast ahead of the eye (~1.5 m), the first body with a HealthPool,
  through `DamageSystem.resolve` like a round. A quick view-model jab in `PlayerView` (a pose like
  `RELOAD_POS`, ~0.25 s) and a small camera kick.
- **Readability**: the enemy's shield and armor must be SEEN — a shimmer for a shield, plates for
  armor, a crack/flash when one breaks — or the counts cannot be read. `EnemyProfiles.COLOURS` has
  per-layer colours; the soldiers are greybox capsules (`Soldier._greybox`). `DamageResult` and
  `HealthPool.layer_depleted` give the events.
- **Test**: a probe that melees each profile and counts hits to kill (= the §4.1 table, at levels 1
  and 6), checks a melee that breaks a defence leaves the flesh untouched, and the
  melee-then-shoot loop.

### 15.2 After that

Steps 5–10 of §12: two groups of two guns with ordnance on D-pad right, grenades and floor pickups;
rarity v2 and the modifiers; the tracking dart and other alt-fires; element statuses; the player
level and skill tree; infusion. Also open: helmets and head crits (switch `Pawn.head_crits` on when
enemies are figures), and §13's questions.

### 15.3 Where things are

| What | File |
|---|---|
| Power curve, rarity | `scripts/guns/tier.gd`, `scripts/guns/rarity.gd`, `scripts/guns/gun_quality.gd` (`LN_STEP`) |
| Light enemy anchor | `scripts/loot/loot_roller.gd` (`TRASH_BASE_HP`, `enemy_hp`) |
| Melee unit, gating, shield regen | `scripts/combat/combat_scale.gd` |
| Enemy layer profiles | `scripts/combat/enemy_profiles.gd` |
| Elements + effectiveness table | `scripts/elements/elements.gd` |
| Damage routing, crit absorb | `scripts/combat/damage_system.gd`, `scripts/combat/health_pool.gd` |
| Crit spots | `scripts/combat/crit_spots.gd`, `Pawn.head_crits` in `scripts/pawn/pawn.gd` |
| Gun fire, element on the round | `scripts/combat/gun_controller.gd`; element roll in `scripts/guns/gun_generator.gd` |
| Arena units and level | `scripts/ai/commander/unit_catalog.gd` ("profile"), `scripts/ai/wave_director.gd` (`level`) — AI area |
| Player input, view, HUD, moves | `scripts/pawn/player_controller.gd`, `player_view.gd`, `player_hud.gd`, `pawn_moves.gd` |
| Settings menu | `menu/` (Ceramic Edge's module), `scripts/brickcity_menu_host.gd` |

### 15.4 Tests to run before merging

Probes (`--headless --path . --script res://tools/<name>.gd`): `combat_numbers_probe` (15),
`crit_probe` (10), `defence_probe` (19), `moves_probe` (39), and the AI ones that read soldier
health: `commander_probe`, `tactics_sense_probe`, `fights_back_probe`, `soldier_probe`,
`room_clear_probe`. Gates (not headless): `res://scenes/city.tscn -- --play` (14) and `-- --gun`
(7), `res://scenes/combat_arena.tscn -- --gate` (31). Menu: `res://menu/tests/menu_smoke.tscn`
(190), `menu_fit_smoke.tscn` (435).

### 15.5 Traps hit on the way

- **After merging `main`, rebuild the engine library and re-import** (`python -m SCons` in
  `gdextension/brick`, then `--import`). Three times a run "failed" with parse errors that were only
  a stale DLL or class cache (`AgentTier`, `ShapedSampler`, `build_tile_chamfered`).
- **A `GunInstance` never added to the tree crashes the engine at quit** (exit 139 after every
  check passed). Free it before quitting; `crit_probe` shows how. `threat_style_probe` crashes the
  same way and is probably the same cause (AI area, not fixed).
- **Commit the `.uid` of every new script** with it, or the editor in the main folder makes a
  different one and the next merge refuses to overwrite it.
- **`project.godot` in the main folder often has uncommitted edits** (the main scene, the editor
  re-serialising the input actions). A merge that touches it is refused until they are committed.
- **Writing GDScript through Bash heredocs eats backslashes** (line continuations vanish). Write
  patches as Python files with the Write tool.
- **AI-area files were changed** (`unit_catalog.gd`, `wave_director.gd`, `squad.gd`,
  `bt_play_advance.gd`, `callout_hud.gd`); tell the AI chat if it is mid-change there.
- **`squad_advance_probe` flakes** (fails about one run in two on `main` too). Soldier probes'
  timing checks flake under machine load; rerun alone before blaming a change.
