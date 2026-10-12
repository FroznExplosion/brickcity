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
- Built on what is there: a saved gun is `{class, seed, tier, rarity, ...}` (`CharacterSave.gun_entry`),
  and its tier only scales damage (`GunStats.compute`), never a roll — so infusion is rewriting
  `tier` in the entry. A probe must hold that: the same seed at two tiers gives the same gun except
  damage.

As built (step 10): the material is **scrap** — kills drop it, and a gun broken down at the bench
gives it. The bench lifts a gun straight to the story tier (the highest tier of fight the player
has reached); it never lowers one. Infusing scales the gun's damage by the step between the two
tiers and leaves everything else as it is, a legendary's signature and a forced rarity included
(`GunGenerator.retier`).

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

**The tree's shape (built in step 9, `SkillTree`):** one tree, after Borderlands — a trunk at the
bottom that forks into three limbs (Gunner, Survivor, Tactician), each forking again into two twigs
and meeting at a top node. Eight tiers, bottom to top. **A tier opens on points spent anywhere in
the tree** — 5 a tier, so the top tier opens at 35 spent (level 36) — and every point counts for
every limb: a player who spent everything on one limb can still buy the top of another. No node
needs its parent bought; the limbs are how the tree reads. By level 40 the whole tree is open, but
it holds 140 ranks against the 99 points of level 100, so no one fills it: a build is what the
player left out. Points come back only all at once (a free reset, for now).

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

Rewritten 2026-10-12 with the user, on the Armory Ledger's Time to kill tab (the page is the
working copy; this is the record).

**The unit is a medium enemy's health**: 60 at tier 1, ×1.25 a tier — one melee
(`CombatScale.MELEE_BASE`). Every enemy is stated in it (`EnemyProfiles`, §4.1) and so is every
gun's damage a round (`WeaponClass._PRESETS`, `DMG_UNIT`), judged at **Unique** with a median
roll and no modifiers, on level. Because guns and enemies grow by the same step, every count
below holds at every tier.

**The medium enemy: shield 0.6, armor 1.2, health 1** (2.8 in all). All damage carries into
the next layer; a crit lands half its extra on a shield and all of it on armor and health (§4.4).

| Gun (Unique) | Dmg / round | Crit | Rate /s | Health only: body / crit | Whole medium: body, time | Whole medium: crits, time |
|---|---|---|---|---|---|---|
| Pistol | 0.20 | ×2 | 8 | 5 / 3 | 14, 1.6 s | 8, 0.9 s |
| Magnum (heavy pistol) | 0.55 | ×2 | 3 | 2 / 1 | 6, 1.7 s | 3, 0.7 s |
| Revolver | 0.20 | ×2.5 | 8 | 5 / 2 | 14, 1.6 s | 7, 0.75 s |
| Hand Cannon (heavy revolver) | 0.55 | ×2.5 | 3 | 2 / 1 | 6, 1.7 s | 3, 0.7 s |
| SMG | 0.09 | ×2 | 14 | 11 / 6 | 31, 2.1 s | 17, 1.1 s |
| Heavy SMG | 0.15 | ×2 | 9.5 | 7 / 4 | 19, 1.9 s | 10, 0.95 s |
| Rifle (auto) | 0.12 | ×2 | 12 | 9 / 5 | 24, 1.9 s | 13, 1.0 s |
| Battle Rifle (3-round burst) | 0.17 | ×2 | 7.8 (2.6 bursts) | 6 / 3 | 17, 2.0 s | 9 = 3 bursts, 0.87 s |
| LMG | 0.126 | ×2 | 13 | 8 / 4 | 22, 1.6 s | 12, 0.85 s |
| Heavy Machine Gun | 0.16 | ×2 | 9 | 7 / 4 | 18, 1.9 s | 10, 1.0 s |
| DMR | 0.40 | ×2 | 3.5 | 3 / 2 | 7, 1.7 s | 4, 0.86 s |
| Heavy DMR | 0.84 | ×2 | 1.8 | 2 / 1 | 4, 1.7 s | 2, 0.56 s |
| Sniper | 1.00 | ×3 | 1.4 | 1 / 1 | 3, 1.4 s | 2, 0.7 s |
| Anti-Materiel Rifle | 1.45 | ×3 | 0.7 | 1 / 1 | 2, 1.4 s | 1, instant |
| Pump Shotgun (all pellets) | 1.00 a blast | ×2 | 1.4 | 1 / 1 | 3, 1.4 s | 2, 0.7 s |
| Auto Shotgun | 0.45 a blast | ×2 | 2.8 | 3 / 2 | 7, 2.1 s | 4, 1.1 s |
| Heavy Shotgun | 1.45 a blast | ×2 | 0.7 | 1 / 1 | 2, 1.4 s | 2, 1.4 s |

The intents behind it: every gun kills a whole medium in about 1.4–2.3 s of body shots and
0.5–1.1 s of crits; the battle rifle's three headshot bursts match the DMR's four headshots; the
magnum fires at about the DMR's pace; the heavy sniper fires half as fast as the light and one
crit kills; the heavy shotgun is a blast and a melee; a shotgun loses damage as fewer pellets
land (¾ of them: 4 pump blasts; half: 6).

`tools/combat_numbers_probe.gd` checks every row through the real DamageSystem at tiers 1, 5
and 10. Each type's own anchor sets its heavy (`WeaponClass.KINDS`); the shotgun's light kind
is the pump and half of light shotguns roll the auto kind (`AUTO_CHANCE`).

**Modifiers are the build on top**: a damage modifier (+10–20%) can take a count down by one;
the colour alone is about half a tier (§2).

### 3.1 Variance inside one colour

Two guns of the same class, tier and rarity differ in **how** they deal damage, not how much:

- **Named parts carry the trades**, readable on the card: a *Heavy Barrel* +8% damage −10% fire
  rate; a *Rapid Receiver* −8% damage +15% fire rate. A part's trade stays inside **±5–10%** on any
  one stat.
- The hidden power roll is small: a gun's DPS rolls **1.00–1.10×** (`GunStats.DPS_WINDOW`; v1's
  1.00–1.28× was wider than the whole rarity range), so two guns of one colour rarely sit a
  shots-to-kill count apart on the roll alone. The damage-vs-fire-rate trade (`FIRE_BASE`) is
  feel, not power, and was narrowed to 0.90–1.11 (2026-10-12) so it moves a count by one at most
  rarely. The fire-rate floor is 0.4/s (the heavy sniper and heavy shotgun fire 0.7/s).
  Shrinking it lowered the median roll (1.14× to 1.05×), so the light enemy's health was
  re-anchored with it (`TRASH_BASE_HP` 64 → 60) to keep a median common at 6 shots — the §3 table
  is in shots, and the shots are what must hold.
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

As built (2026-10-10): the four are the Brawler limb of the tree (§14, "the skill kit"). The
Shockwave staggers every enemy in it, the struck one too: 1 s held (`Pawn.stagger`, `is_held` —
no moving, firing or turning, and a soldier's mind waits) and knocked 4 m/s away from the blow.
Not yet: Kinetic Lunge's slide-punch launch, and Backstab past frontal armor plates (no enemy has
plates yet) — Backstab is the 2.5x alone.

### 4.3 Defences sit over the flesh

An enemy is **flesh** (or, for plant-based enemies, **vegetation**) and may wear **shield** and/or
**armor** over it. Guns break them too.

| Layer | Regenerates | Weak to | Notes |
|---|---|---|---|
| Shield | yes, after a delay | **Plasma**, melee (1.5×) | Takes half a crit's extra (§4.4) |
| Armor | no | **Corrosive** (mechs and vehicles only) | Takes crits fully |
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

- **Crit multiplier**: 2× (a revolver 2.5×, a sniper 3×; the DMR is 2× since 2026-10-12).
- **A shield takes half a crit's extra** (`CombatScale.SHIELD_CRIT_SHARE`): a 2× crit lands
  1.5× on it, a sniper's 3× lands 2×. **Armor and health take crits fully.** Each layer works
  out its own share (`CombatScale.layer_crit`, in `HealthPool.apply_impact`). Helmets (crit-spot
  armor) are deferred to bigger enemies.
- Deterministic: where the round hit decides it — every co-op peer agrees for free.

### 4.5 Everything carries

**All damage carries into the next layer** (2026-10-12; the old shield gate that halved a body
shot's carry is gone). A melee is still one step: it breaks one layer and stops (§4.1).

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

How the statuses build (built in step 8, `ElementStatus`), from what the element part of a round
dealt, on the layer it landed on:

| Status | Builds from | Does |
|---|---|---|
| **Burn** | fire's part landing on flesh or vegetation | 60% more of it over 3 s, while the flesh is bare; a shield or armor coming up puts it out |
| **Corrode** | corrosive's part landing on armor | 50% more of it over 3 s, on the armor only |
| **Chill** | ice's part, on any layer | slows up to 50%; ice worth a quarter of the enemy's whole health **freezes** it for 2 s (no moving, firing or turning), then 1.5 s before it can freeze again; the chill thaws on its own a second after the ice stops |

- The extra damage is plain: the element's multiplier was already in the part that built it.
- A player is slowed by ice, never frozen. A mech has none of this (its hits are its own,
  `MechLayers`).

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

**The score leaves modifiers out.** A gun's score is tiers of power from its tier, colour and roll —
the same currency as an ordnance's or a shield's, 100 a tier — and its modifiers are listed beside
it on the card, never folded into it. The card's damage and DPS rows show the gun with its
modifiers.

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
  is shared across all four guns. As built: the time to put the last gun away and bring this
  one up, by class (`WeaponClass.SWAP_TIMES`: pistol 0.36 s up to LMG 0.8 s; a heavy 1.25x),
  on the card and in the hands (`PlayerView`).
- **On the keyboard the swap key is C** (decided 2026-10-11; Tab and the wheel still work).
  Crouch is Ctrl alone.
- On a keyboard, number keys pick a slot directly (1–2 group 1, 3–4 group 2) as well as the swap
  key. All of it is rebindable.

### 7.2 Alt-fire

A gun may roll an **alt-fire**. It is part of the gun's personality, like its modifiers, and stays
with it through infusion. Alt-fires are setup tools that still do real damage — never a zero-damage
tag.

**It is a mode, switched by holding reload** (decided 2026-10-10). Tap reload reloads; hold it
(~0.3 s) and the gun flips to its alt-fire mode — the fire button now fires the alt-fire — and
holding it again flips back. Aim keeps its button, so no gun loses aim-down-sights for having an
alt-fire. The HUD shows which mode the gun is in. A gun with no alt-fire ignores the hold.

As built (step 7): an alt-fire **fires once and the gun is back on its primary** — dart, then
pour, with no second hold — and the primary waits for the trigger to come up. A trigger held
through the switch fires nothing. The press of a held reload starts a reload; the hold calls it
off. A gun carries at most one alt-fire, rolled from its seed (`GunAltFire`): 10% of whites up to
every mythic that can; never ordnance, never a sniper.

**Tracking dart** (hold to charge):

- In alt-fire mode, hold fire to charge (~0.5 s), release to fire a heavy **dart**. It does real damage on
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

**Charged shot** (the plasma pistol's): in alt-fire mode, hold fire to charge, release a shot that takes a whole shield.
It costs the gun's heat (or a large ammo bite) so it cannot be spammed; it is a shield answer, not
a damage answer. Built as a 0.8 s charge for a quarter of the magazine (at least 2 rounds), on
pistols, SMGs and revolvers; off a shield it is one plain round.

**Shock arc** (built): in alt-fire mode, press fire — the struck enemy takes 1.5 rounds, then the
arc jumps to the nearest enemy within 6 m not yet touched, up to three more, each 80% of the last,
each slowed 40% for 1.5 s. Shock is no element (kinetic). A 5 s cooldown, no ammo. On pistols,
shotguns and revolvers.

**Other alt-fires** come from the ordnance effects: an underbarrel grenade tube on a rifle, a shock
arc on a pistol, a thermal torch on a corrosive beam (armor melt) — on cooldowns, like ordnance.

As built: the **grenade tube** (rifles, LMGs) — press: a grenade lobbed down the aim (32 m/s, real
drop) that bursts where it strikes, 6 rounds' worth to what it struck and less out to 3.5 m, a
grenade's blast in the bricks; 6 s cooldown. The **thermal torch** (SMGs, shotguns; there is no beam
class) — hold: a 6 m cone, 25° either side, 6 rounds' worth a second of pure corrosive (so armor
takes 2× and corrodes) for up to 2 s of fuel, then 6 s to cool. Adding them moved some rifles',
LMGs', SMGs' and shotguns' alt-fire roll.

### 7.3 Ordnance and grenades

- **Ordnance** is its own slot (Borderlands 4): rocket launchers and **special weapons** — gated by
  a cooldown or charge, not a magazine. **D-pad right** brings it up (a key on the keyboard); swap or
  D-pad right again goes back to the gun you had.
- Special weapons are where unusual effects live, **shock** first: the round arcs across several
  nearby enemies and slows them.
  Built: the **arc caster** (`WeaponClass` `arc_caster`, ordnance, 2–3 charges): each charge is a
  shock arc of its own damage through up to six enemies, each 85% of the last within 8 m, each
  slowed 2.5 s. A third of ordnance drops (`CityScene.drop_loot`).
- **Grenades** have a slot of their own and are **thrown with G** (right bumper on a pad) without
  putting the gun away. A grenade is ordnance for bricks (§8): it blasts.

### 7.4 Picking up a gun off the floor

A gun on the floor (`WorldGunPickup`, with its card and rarity beam) is **in reach** when it is
near the crosshair and within 2.6 m, or -- Halo's -- simply at the player's feet (within 1.4 m),
looked at or not. Two holds (decided 2026-10-11):

- **Hold reload** (R; X on a pad, as in Halo): **take it for keeps.** It goes into the active
  group's empty slot if there is one, else in place of the gun in hand, which drops to the floor
  (`Loadout.take`). Carrying a tried gun, that one drops and this one is kept as a slot key keeps
  (the slot's gun to the backpack). Tapped, reload still reloads.
- **Hold swap** (C): **try it** in a **third hand**. The loadout is untouched. With a floor gun in
  reach a tap of swap waits for the key to come up (a hold may mean "try it") and then swaps as
  ever; away from floor guns the tap starts on the press.
- **Tap swap** while holding it: drop it where you stand and draw the gun you had.
- **Keep it**: a slot key (1–4) puts it in that slot; on a pad, hold **D-pad left** for slot A of
  the active group, **D-pad up** for slot B. The gun it replaces goes into the **backpack**
  (dropped where you stand only when the backpack is full).
- **Stow it**: hold reload again with no floor gun in view (D-pad down on a pad) to send it
  straight to the backpack without touching the loadout.

Hold reload is one button with several jobs, in this order: a floor gun looked at → take it;
a mech's hatch or a vehicle beside → get in (what M does); a floor gun at the feet → take it; a
workbench → its page; carrying a tried gun → stow it; otherwise → the alt-fire mode switch (§7.2).
- Switching group, or picking up another floor gun, drops the one in the third hand.

### 7.5 The backpack

Borderlands' backpack (decided 2026-10-10): guns the player owns but is not carrying in the two
groups. Opened from the inventory screen, where a gun is moved between the backpack and any of the
four loadout slots, compared on its card, or dropped. It starts small (about 10 guns) and grows
with skill points or upgrades. A saved gun is its recipe (`CharacterSave.gun_entry`), so the
backpack is a list of those.

### 7.6 Co-op loot

- **Shared** (the default): a gun on the floor is one gun in the world, for everyone. A dropped gun —
  discarded from the third hand, replaced, or thrown out of the backpack — lies there for any player
  to pick up. First to take it owns it.
- **Instanced** (an option in the session settings, as in Borderlands 3): each player sees and gets
  their own drops; a gun one player drops is still a real gun the others can take, so trading still
  works.
- The host decides what drops either way (Multiplayer.md): an instanced drop is the host rolling one
  gun per player and showing each only to its owner.

### 7.7 Input summary

| Pad | Keyboard / mouse | Does |
|---|---|---|
| Y tap | C (or Tab) tap, mouse wheel | the other gun in the group |
| Y hold | C (or Tab) hold | the other group · a floor gun in reach: try it (third hand) |
| — | 1–4 | that slot directly |
| D-pad right | 5 | the ordnance, and back |
| Right bumper | G | throw a grenade |
| X tap | R tap | reload |
| X hold | R hold | floor gun in reach: take it for keeps · beside a mech or vehicle: get in · carrying a tried gun: stow it · else: alt-fire mode |
| D-pad left / up (carrying) | 1–4 (carrying) | keep the floor gun in that slot |
| — | I | the backpack (arrows / wheel choose, 1–4 swap into a slot, Backspace drops) |
| Right stick click | E | melee (next to an enemy mech: climb it) |

Every keyboard bind is an input action, rebindable in Options. Pad bindings do not exist yet.

### 7.8 Light and heavy kinds of every class (decided and built 2026-10-11)

The user's call: every gun class comes in two kinds, **light** and **heavy**. They are
different guns to hold -- different models, different feel -- not a stat roll on one model.
A light pistol is a Glock: fast semi-auto, or full-auto. A heavy pistol is a magnum, the Halo:
Combat Evolved magnum. A light shotgun fires fast with little knock-back until it is nearly
touching; a heavy shotgun hits harder and knocks back from further off. And so on for each
class.

**The kind is an archetype on the class, not a new class.** `shotgun`, `pistol` and the rest
stay the classes (their tables, loot pools, saves and the view's feel all keyed by them); the
gun carries `archetype` (`&"light"` / `&"heavy"`), rolled by the generator, which picks the
kind's parts (its model) and scales the class's base numbers. Heavies roll rarer than lights.

**A heavy spends two rounds a shot.** That is the ammo balance between the kinds, and the
heavy's damage, fire rate, reload and knock-back are set to justify the cost: it should feel
powerful, but not like a power weapon. How it reads to the player:

- The **reserve** is counted in the class's rounds and is shared: 100 spare pistol rounds
  carried with a light pistol in hand still show as 100 with a heavy pistol in hand.
- The heavy's **magazine** shows shots, not rounds: a magazine that holds 12 rounds shows 6.
  The magazine is the right size; a reload takes twice the rounds per shot shown out of the
  reserve.
- (Ammo reserves are not built yet, §15.1; this is what they must do when they are.)

**Legendaries may break the trade**: a heavy with a light's fire rate, or a light with a
heavy's damage, without the other kind's penalty.

**Hit reactions read the kind already.** A round's flinch or stumble (`HitReaction`, built
2026-10-11) is the class's impact by range; a gun's `archetype`, when it has one, scales it
(`HitReaction.ARCHETYPE`: light 0.6x impact over half the range, heavy 1.6x over 1.6x the
range). Nothing there needs to change when the kinds land -- only the property must exist on
`GunInstance` with those two values.

**As built** (`WeaponClass.KINDS`, `tools/gun_kind_probe.gd`):

| Class | Heavy is | Heavy x damage / fire rate / reload | Light |
|---|---|---|---|
| pistol | Magnum | 2.5 / 0.42 / 1.15 | the class as it was |
| revolver | Hand Cannon | 2.0 / 0.65 / 1.15 | as it was |
| smg | Heavy SMG | 2.2 / 0.5 / 1.15 | as it was |
| rifle | Battle Rifle | 2.3 / 0.5 / 1.15 | as it was |
| lmg | Heavy Machine Gun | 2.2 / 0.5 / 1.15 | as it was |
| dmr | Heavy DMR | 2.1 / 0.6 / 1.15 | as it was |
| sniper | Anti-Materiel Rifle | 2.0 / 0.93 / 1.2 | as it was |
| shotgun | Heavy Shotgun | 2.2 / 0.8 / 1.2 | Auto Shotgun: 0.55 damage, 1.8 fire rate, 1.4 magazine |

- A heavy's damage a round is 1.0-1.25x the light's; its damage a second 1.05x (pistol) to 1.86x (sniper) (the slow
  classes cannot halve their rate without going under the 1/s floor, so they pay in
  magazine and reload). The score is read against the kind's own base, so a grade means the
  same on both.
- The kind is `WeaponClass.archetype`, made by `with_kind`; `WeaponClass.rolled(class, seed,
  rarity)` rolls it on its own stream off the seed: heavies 15% of commons up to 40% of
  mythics, a legendary or mythic crossed 35% of the time. A light gun rolls exactly the parts,
  stats and name its seed always rolled.
- Only the player's loot rolls a kind: the default kit (`PlayerArsenal._roll`) and enemy drops
  (`CityScene`). A gun no one gave a kind -- an enemy's, a vehicle's -- is the class as it was.
- Heavies are built of their own parts (`GunPartDef.kind`): the placeholder library's heavy
  receivers and barrels are chunkier, with a dark slab and a braked muzzle.
- The magazine stat stays in rounds; `GunController.mag_size()` is in shots (rounds /
  `rounds_per_shot`), so the HUD, the AI and the arsenal count shots. The card shows
  "6 (12 rounds)". The reserve, when built, spends `rounds_per_shot` a shot.
- Saves keep the kind (`CharacterSave.gun_entry`: "kind", "crossed"); so does
  `Result.serialize`. Old saves come back light.
- In the hands a heavy is 12% longer and kicks 1.7x; the auto shotgun kicks 0.55x.
- Not done: semi-auto versus full-auto (every gun fires while the trigger is held), and real
  art per kind.

### 7.9 How a gun fires: trigger, pellets, charge (built 2026-10-11)

The user's call: semi, full-auto and burst guns with different rates, burst sizes and gaps;
shotgun blasts with different spreads and falloff; and "dual fire" -- a semi or burst gun
that can be held to charge a different shot. `GunFireMode` rolls it off the seed (its own
stream) for every gun of a kind (§7.8); a gun with no kind -- an enemy's -- fires as before.

- **Trigger.** Semi: one round a press, at most the fire rate, a press up to 0.15 s early is
  kept. Auto: rounds while held. Burst: 2-5 rounds (3 most often) at 2-3.2x the fire rate,
  then a gap; held, burst follows burst, and over a burst and its gap the gun fires at its
  fire rate, so a burst gun is shaped differently, not stronger. Per class and kind (magnum,
  revolver, DMR, sniper, heavy shotgun: semi; LMG: auto; the rest mixed):
  `GunFireMode.MODES`.
- **Pellets** (shotguns of a kind). Light (the Auto Shotgun): 6-8 pellets, 8-12 deg, full
  damage to 3-5 m, down to 15% by 10-14 m. Heavy: 8-10 pellets, 4-7 deg, full to 6-9 m, 25%
  by 16-22 m. The pellets share the shot's damage. A blast reports once for each thing it
  hit, damage summed (`pellets_hit` of `pellets`), and chips brick once. A stumble is
  scaled by the share of pellets that struck: the light shotgun stumbles a soldier at arm's
  length and only makes him flinch from a few steps.
- **Charge** (semi and burst guns; 10% of commons, 15% of greens, up to 70% of mythics). A tap
  fires as ever; held past 0.3 s the gun stops and charges (0.7-1.1 s), and let go full it
  fires an *overcharge* (one shot at 3x, for three shots), a *hyper burst* (burst guns:
  twice the burst at 1.6x its speed) or a *long burst* (semi guns: ten rounds). Each carries
  one effect: *shield break* (a shield up is taken whole), *armor break* (armor on top
  taken whole, `DamagePacket.strip_armor`) or *knockback* (a stumble 3x as hard). In the
  hands the gun draws back and trembles while it charges, and bucks when it goes.
- **The card** (`GunCard`, drawn by the arsenal's HUD), laid out like Borderlands 4's: the
  floor gun in reach, or the gun chosen in the backpack or at the bench. Name, rarity, kind,
  tier and the score against the gun in hand; the damage large (x pellets), in the element's
  colour; then the plain stats a row each -- fire rate, fire mode, range (shotguns),
  accuracy, reload, magazine, swap speed, element (and what it is strong against), crit,
  DPS; then **SPECIAL**, an entry each: the charge-up, the alt-fire, the burst, the
  modifiers, the trade parts, abilities; the legendary's red text last.
- **A gun on the floor is a body** (`WorldGunPickup`): dropped, it is tossed and falls,
  lies on its side and sleeps; every explosion (`WorldGunPickup.blast`: grenades, blasts in
  the bricks, explosive rounds) wakes and throws it; a sleeping gun checks under itself
  every half second and falls when the floor has gone. It is on the rubble layer: walkers
  do not collide with it. At rest it is frozen where it lies, so nothing nudges it -- a
  walker, a soldier, the solver -- until a blast or a missing floor wakes it.

Tests: `tools/fire_mode_probe.gd`, `tools/pickup_physics_probe.gd`, and the `--arms` pass
(the card, a dropped gun at rest, the shotguns' stumbles).

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
| `Rarity.MULTS` 1.0 / 1.15 / 1.30 / 1.45 / 1.75 / 1.75 | 1.00 / 1.03 / 1.06 / 1.09 / 1.12 / 1.12 | **done** (step 6) |
| `GunStats.DPS_WINDOW` 1.00–1.28 | about 1.00–1.10 | **done**: 1.10, `TRASH_BASE_HP` 60 |
| Parts with stat adds/mults, rarity → extra parts | slot-limited modifiers, quality by rarity, named trade parts, red text | **done** for the first set (step 6, §14) |
| Mythic colour `GunCard.RARITY_COLORS[5]` (1.0, 0.25, 0.35) | red | **done**: (0.95, 0.12, 0.12) |
| `CharacterSave.character.level` (unused) | player level 1–100, XP, skill points, nodes | new: XP sources, tree data, save fields |
| `CombatScale.melee(level)` | the player's current story tier | "level" becomes story tier |
| No pickup flow | third hand, keep to slot, backpack | new |
| — | co-op loot shared, or instanced as a session option | new (Multiplayer) |
| One gun in hand | two groups of two, ordnance on D-pad right, grenade on G | inventory, HUD, view (swap) |
| Crit spots, layers, gating, five elements (built) | unchanged | — |
| Fire burn, ice slow/freeze (not built) | + corrosive corrode; statuses always build | **done** (step 8): `ElementStatus`, not the older `scripts/status/` dice |

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
7. ~~**Alt-fire and special weapons**: tracking dart first, then the charged plasma shot and the shock
   arc.~~ (built as alt-fires; the special ordnance weapons are still to come)
8. ~~**Elements' statuses**: burn, corrode, ice slow/freeze.~~ (built)
9. ~~**Player level and the skill tree**: XP, points, the Vanguard Brawler branch, health/shield
   nodes with their cap, the first abilities.~~ (the level, XP, the tree and its screen are built,
   with placeholder stat nodes; the Brawler's nodes, shields and abilities are still to come)
10. ~~**Safehouse infusion**: workbench, materials, the same-gun-at-another-tier probe.~~ (built;
    the workbench stands by the player's start until there are safehouses)

## 13. Open questions

- The backpack's size and how it grows.
- There are no pad bindings in `project.godot` yet: the pad column above is the plan.
- Infusion materials: one, scrap, for now (step 10). Kinds of material (a rare one for
  legendaries, one per zone) are still open.
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

**Step 4 — melee: built 2026-10-10.**
- **E** (rebindable action `melee`; "Melee / Climb a Mech" in Options). `PawnIntents.melee`,
  `Pawn.melee()`: a blow down the eye, then `MeleeStrike.RECOVERY` 0.65 s before the next; the gun
  is down (no firing) for the first `GUN_DOWN` 0.35 s. Next to an enemy mech the same press climbs
  it (`PlayerController.melee_context` -> `CityScene._melee_context`), and on its back E held
  plants the charge, as before.
- `MeleeStrike.strike`: a 1.8 m ray from the eye, else a 0.5 m sphere at the end of it for the
  living body nearest the line that the eye can see (a blow forgives aim but never lands through a
  wall). Damage `CombatScale.melee(Pawn.melee_tier)` — the arena's level, else 1.
- `DamagePacket.melee`: `DamageSystem` lands it as damage type `Elements.MELEE` (1.5x on shields,
  a row of the matrix), never a crit, and `HealthPool.apply_impact(..., stop_at_layer)` stops it at
  the layer it hits. `HealthPool._damage_index` now zeroes a float sliver (< 1e-5 of the layer), so
  N melees of a layer take exactly N.
- The view: a gun bash (`PlayerView.MELEE_POS/ROT`), a shake and dip when it connects; a landed
  blow shows the hitmarker and number like a round (`Pawn.meleed` -> `CombatFeedback.on_player_shot`).
- **Readable defences**: `DefenceLook` dresses every capsule-bodied arena unit
  (`UnitCatalog.apply_health`): a shield is a translucent cyan shell, brighter the fuller, that
  flashes when hit and bursts when it breaks; armor is an amber chest plate that shrinks from the
  shoulders as it wears and is gone when it breaks. It reads the HealthPool, so nothing else
  needs to call it.
- `tools/melee_probe.gd` (36 checks): every profile's count at tiers 1 and 6, a blow stops at the
  layer it breaks, 1.5x on shields, never a crit, melee-then-headshot crits, a tier-1 blow on a
  tier-2 enemy, reach / whiff / wall, the recovery, and the look.
- **Not yet:** pad binding (no pad bindings exist yet); the soldiers' own melee
  (`Soldier.melee`, a flat 45) is still theirs (AI area); a lunge toward the target (§4.2's
  Kinetic Lunge is a skill).

**Step 5 — groups, ordnance, grenades, pickups, backpack: built 2026-10-10.**
- `Loadout` (`scripts/loot/loadout.gd`): the rules as plain state — four slots in two groups, the
  hand per group, ordnance, the third hand, the backpack (10). Every operation that lets go of a
  gun returns it, so nothing is lost.
- `PlayerArsenal` (`scripts/pawn/player_arsenal.gd`): the keys (§7.7), one `GunController` firing
  whatever is in hand — each gun keeps its own magazine over a swap — guns not in hand hidden in
  the tree under a holster, floor pickups (in reach 2.6 m, within 28° of the crosshair), drops as
  `WorldGunPickup`s in front of the player, and its own HUD: the four slots in two rows (active
  group bright, gun in hand boxed), the ordnance and grenades, the prompt under the crosshair, the
  backpack panel. A key it handles is marked handled, so `city_scene`'s debug keys under it
  (1, 2, G, I) do not also fire while playing.
- Tap swap acts on the press; held past 0.25 s the tap is undone and the group changes.
- The starting kit (`fill_default`): the arena's rifle, a pistol, a shotgun, a sniper, and a
  rocket launcher for the ordnance, all of the fight's tier.
- **Grenades**: three, G throws one at the crosshair (25 m, onto the ground beyond), the AI's
  `Grenade` with `damage` sized to 2.5 melees of the fight's tier; one comes back every 20 s (a
  stand-in until there are ammo pickups).
- **Loot**: `CityScene.drop_loot` rolls `LootRoller` drops of the fight's tier on its own seeded
  stream; every arena soldier drops on death (the HQ officer as a badass) — WaveDirector, one
  line, AI area. `GunInstance.result` keeps what a gun was made from, so it can be dropped again.
- **A dead soldier always drops the gun in its hands** (decided 2026-10-12): the very gun it
  fired, beside where it fell (`WaveDirector.held_gun_result`, `CityScene.drop_gun`), and its
  loot roll on top as before. A bomber or a brawler has none to drop.
  `tools/held_gun_drop_probe.gd` (5 checks).
- **Idea, not built:** a soldier lets go of its gun before death -- knocked back hard, or giving
  up to a mech.
- `tools/loadout_probe.gd` (31 checks).
- **Not yet:** ammo reserves per type (magazines still refill from nothing); the swap has no draw
  time (swap speed as a stat needs one); co-op (shared or instanced drops); pad bindings; a gun card on the floor gun (the prompt names it).

**The kit saved: built 2026-10-10** (step 5's leftover).
- `CharacterSave.loadout`: the four slots, the ordnance, the backpack and its size, the group and
  hand (`loadout_dict` / `fill_loadout`). A tried floor gun is not kept.
- A gun's entry (`gun_entry`) is what makes it again: class, seed, tier, the rarity it was
  **forced** to (`GunGenerator.Result.forced_rarity`; loot is forced, and forcing skips a roll, so
  the seed alone would make a different gun), its luck, its legendary id, and its parts' ids as a
  check — if the part library changed under the save, `make_result` builds the saved parts
  (`GunGenerator.deserialize`) instead of what the seed now rolls. An infused gun is its entry at
  the new tier.
- `PlayerArsenal.restore` puts the saved kit in the hands (the controller's first gun let go);
  `fill_default` only fills an empty kit. Every 2 s the arsenal compares the kit with what it last
  saw and says `kit_changed`; `CityScene._load_kit` makes it once and saves on that signal (with
  the level, `_save_progress`). Not in a pass or a test window. An infusion changes the gun before
  spending the scrap, so the save the spend makes holds both.
- `tools/kit_save_probe.gd` (21 checks).
- **Not yet:** ammo in the magazines (a loaded kit comes back full); several characters.

**Step 6 — rarity v2 and modifiers: built 2026-10-10.**
- **Numbers**: `Rarity.MULTS` 1.00 / 1.03 / 1.06 / 1.09 / 1.12 / 1.12; `GunStats.DPS_WINDOW_HI`
  1.10; `LootRoller.TRASH_BASE_HP` 60. `combat_numbers_probe` rewritten to §3's rows (20 checks).
  The player's shield capacity reads the same `Rarity.damage_mult`, so shields' colour step shrank
  with it.
- **Mythic is red** on the card, the HUD and the floor beam.
- `GunModifiers` (`scripts/guns/gun_modifiers.gd`): slots by colour (`Rarity.SLOTS`
  1 / 2 / 3 / 4 / 4 / 4, always full), quality by colour (`Rarity.QUALITY`: the floor of the roll
  inside a modifier's band), rolled from the gun's seed on a stream of its own, so a save or a peer
  rebuilds the same list. The first set: +damage (10–20%, may repeat, adds), power shot (every
  6th–4th round 2×), double fire (every 5th–3rd round a free extra; from purple, the rarer roll:
  15–25% of rounds, from the owner's seeded stream), Shield Buster (+20–40% on a shield),
  Overkill Ricochet (green and up: a kill's excess ×1.0–1.5 to the nearest enemy in 12 m),
  magazine (+20–40%), reload (−10–25%), and the **explosive attachment** (blue and up: every round
  bursts for 35–60% of its damage over 3 m, half at the edge, not through walls, and wears bricks
  harder through `StructuralDamage`). Ordnance rolls only the ones that do not count rounds.
- They reach the game as stats (`GunModifiers.apply`); `GunController` reads them as it fires.
  Splash and ricochet are hits of their own (`side_hit`, marked on the HUD like a round) through
  the same `DamageSystem`, never a crit, never onto the holder's side (`GunController.team`).
  Shield Buster is `DamagePacket.shield_mult`.
- **Named trade parts**: every tier's second barrel is a *Heavy Barrel* (+8% damage, −10% fire
  rate) and its second receiver a *Rapid Receiver* (−8% / +15%), on the card. The placeholder parts
  no longer carry the old part effects (ricochet, explosive, lifesteal, fire ramp): a gun's
  behaviours are its modifiers now. Authored legendary barrels keep theirs.
- **The score leaves modifiers out** (`Result.base_stats`, §6).
- **First red text**: Boilerplate winds up to +60% fire rate over 2 s of held trigger; Sermon puts
  the round back on a kill. The card says what each does (`LegendaryTable.EFFECT_TEXT`).
- The card lists the modifiers, one a line, and the trade parts.
- `tools/modifiers_probe.gd` (19 checks). `test/loot_range_test.gd --probe` passes again: its v1
  calibration rows (a legendary worth two tiers, a rare one) were replaced by v2's half a tier,
  and the narrower roll fixed its gun-vs-shield score rows.
- **Not yet:** the explosive attachment's proximity and chain rolls; split rounds, conditional
  damage, the handling, swap-speed and utility modifiers; element conversion; Mythic effects; the
  other three legendaries' red text (Landlord, Hangnail, Dinner Bell); mechs ignore Shield Buster
  (`MechLayers` judges its own hits).

**Step 7 — alt-fire: built 2026-10-10.**
- `GunAltFire` (`scripts/guns/gun_alt_fire.gd`): the roll from the seed (`Result.alt_fire`,
  `GunInstance.alt_fire`), so a save rebuilds it; the card's line.
- The mode: `GunInstance.alt_mode`, flipped by `GunController.toggle_alt()` from
  `PlayerArsenal.interact()` — the third job of held reload. The HUD shows the mode over the slots,
  the charge under the crosshair, and the mark as a diamond with its time.
- **Tracking dart** (`scripts/combat/tracking_dart.gd`): 0.5 s charge, one round, 40 m/s with a
  little drop, 2× a round's damage where it strikes (a crit spot counts). It rides along in what
  it struck and marks it 2.5 s; a new dart ends the mark at once. A primary round fired within 15°
  of the mark goes to it and lands in the dart's crit spot (a shield over it still takes it plain).
  The mark is the controller's: one a player, kept through a swap.
- **Plasma charge**: `DamagePacket.strip_shield` — a shield up takes all of it and the hit stops.
- **Shock arc**: through `side_hit` (marked on the HUD), with `ArcFlash` for the look.
- `tools/alt_fire_probe.gd` (30 checks).
- **Not yet:** the underbarrel grenade tube and the thermal torch; shock as a special ordnance
  weapon (§7.3); a heat bar instead of the charge's ammo bite; AI soldiers never use alt-fires.

**Step 8 — element statuses: built 2026-10-10.**
- `ElementStatus` (`scripts/elements/element_status.gd`): made on a target by
  `DamageSystem.resolve` from what the element part dealt (§5's table), ticked by itself, nothing
  random, gone when its last status ends or the target dies. A see-through shell round the body
  in the element's colour shows it.
- The slow and the freeze are `Pawn.speed_mult` and `Pawn.frozen`; `Pawn.is_player` (set by
  `PlayerController.possess`) keeps a player from being frozen.
- The shock arc's slow is a status here too (`ElementStatus.shock`).
- `tools/status_probe.gd` (19 checks).
- **Not yet:** no hit-number colours for status damage. (The shatter, and a frozen soldier's
  mind held: "special fire" and "held", below.)

**Special fire — the tube, the torch, the arc caster, the shatter, soldiers' alt-fires: built
2026-10-10.**
- `GunAltFire.TUBE` / `TORCH` and the arc caster: §7.2 and §7.3's built notes. `TubeGrenade`
  (`scripts/combat/tube_grenade.gd`) flies and calls `GunController.tube_burst`; the torch is
  `GunController._step_torch` / `_burn_cone`; the shock arc is now `_arc_down_aim` (amount,
  jumps, range, falloff, slow), shared by the alt-fire and the arc caster.
- **Frozen is brittle** (`ElementStatus`): every hit on a frozen thing lands 1.5×
  (`DamageSystem._resolve`), and with its defences down it **shatters** — dies at once, an ice
  burst — on a melee, or on a hit that leaves its flesh at a quarter or less
  (`ElementStatus.try_shatter`, from `DamageSystem.resolve`; `DamageResult.shattered`). A shield or
  armor up, no shatter. The old `FrozenStatus` stays unused.
- **Soldiers use their alt-fires** (`GunController.ai_alt`, on in `Soldier`): while the trigger is
  held, at most once every 6 s — the arc and the tube whenever, a dart to open a burst, the plasma
  charge only when a shield is under the aim. Never the torch.
- `tools/special_fire_probe.gd` (23 checks).
- **Not yet:** a heat bar instead of the charge's ammo bite; other special weapons; the shatter's
  pieces.

**Held — frozen and staggered, body and mind; the torch's flame: built 2026-10-10.**
- `Pawn.is_held()`: frozen, or staggered (`Pawn.stagger(seconds, push)`, `stagger_left`; never a
  player). Held, the pawn's intents are zeroed and it does not turn. A held `Soldier` skips its
  tick: no sensing, no thinking (its think clock stops with it, so it resumes where it was), no aim
  or fire. A plain walker's knock goes on its `shove`.
- The Shockwave staggers (§4.2's built note).
- **The torch's flame** (`TorchFlame`, `scripts/combat/torch_flame.gd`): CPU particles out of the
  muzzle down the aim, world-space so a swung torch leaves its fire behind — a narrow bright core
  (added) inside a 9° jet of soft puffs (mixed, so it never clips to white over a bright wall)
  that slows, billows and rises from yellow-green to dark green smoke over ~5 m, with a green
  glow light. Dim at the nozzle so it does not cover the crosshair. Out on letting go, on running
  dry, on a swap; switched off mid-burn it still cools. `tools/torch_look.gd` (not headless)
  renders it to `shots/`.
- `tools/frozen_soldier_probe.gd` (10 checks); the Shockwave's stagger in `skill_kit_probe` (33),
  the flame in `special_fire_probe` (25).
- `fights_back_probe` fails one check ("while it hid, the rounds went into the wall": 4 of 15
  reached it) on this branch from before this step too (checked at f2c42d8 and with `ai_alt` off) —
  AI area's to look at.

**Step 9 — player level and the skill tree: built 2026-10-10.**
- `PlayerLevel` (`scripts/progression/player_level.gd`): level 1–100, a point a level from level
  2. XP to the next level `60 × level^1.2` (60 at level 1, 951 at 10, 5019 at 40). A kill pays
  0.3125 XP a point of the target's whole health (a light enemy at tier 1, 64 health: 20 XP; at
  most 600), 300 for a mech or a tank. Both grow with the tier, so a level costs about as many
  kills all the way up. Placeholder numbers.
- **Who gets the XP:** `DamageSystem.resolve` calls `PlayerLevel.credit_kill(packet.source,
  target)` on a kill. A node the player owns carries their `PlayerLevel` under the meta
  `player_level`: the possessed pawn (melee, grenades), the player's `GunController` (rounds, side
  hits, the alt-fires), the player's mech's gun. A target pays once; never one of the player's own
  side. A burn or a corrode that kills pays whose round built it (`ElementStatus.source`).
- `SkillTree` (`scripts/progression/skill_tree.gd`): the data (35 nodes, 140 ranks), the tier gates,
  buying, the reset, the stats' totals, the save (re-bought tier by tier, so a save holding more
  than its level allows is trimmed).
- **Placeholder skills**, all stats and none of them damage: max health (+30% in all, the cap),
  health regen after 5 s unhurt, reload speed, magazine size, move speed, grenades carried and their
  recharge, alt-fire charge and recharge. `PlayerArsenal.apply_skills` puts them into the
  `GunController` (`reload_mult`, `mag_mult`, `alt_mult`), the pawn (`move_mult`, health) and the
  grenades, on every change.
- **The screen** (`SkillScreen`): the backpack's second page — I, then Tab (I opens straight on it
  when there are points). Arrows choose, Enter spends, Backspace twice resets; `+` levels up in
  developer mode. The HUD shows the level, an XP bar and the points waiting; a level up says so.
- **Saved** in `CharacterSave.character` (`level`, `xp`, `skills`), loaded when the player first
  takes a pawn and written on every change — never in a scripted pass or a test window.
- `tools/skill_tree_probe.gd` (36 checks).
- **Not yet:** XP for objectives and missions; a respec cost; the mouse on the tree's screen; a
  co-op player's own level (one `PlayerLevel`, the host's player). (The real nodes: "the skill
  kit", below.)

**The skill kit — the player's shield, the ability slot, the Brawler: built 2026-10-10.**
- **The tree's limbs** are now Gunner (reload, magazines, alt-fire; unchanged), Survivor (health,
  the shield, grenades, the Overshield) and **Brawler** (the Vanguard Brawler, §4.2, in place of
  the Tactician: melee speed, mobility, ability recharge, and the four melee nodes). 40 nodes, 153
  ranks. A node gives a stat (`SkillTree.total`) or, at one rank, a flag (`has`). An old save's
  Tactician points come back free (`from_dict` drops a node that is gone).
- **The player's shield** (`PlayerArsenal.ensure_shield`): a layer over the health, 50 (half the
  health), recharging at 25/s after 4 s unhurt — a Halo shield. What breaks it carries
  on into the health (§4.5). Survivor's Shield Cells and Layered Cells grow it to
  +30% (`SkillTree.SHIELD_CAP`), Fast Charge shortens the wait to 60%, Flash Charge speeds the
  recharge. The HUD's bars already drew every layer. The health's skill base is kept on its layer
  now, so the shield moving it down an index changes nothing.
- **The ability slot (Q)**: holds the grapple until the tree buys an ability. `PlayerLevel.tactical`
  (saved); Enter on a bought ability node puts it in the slot, again takes it out. With another
  ability there, Q fires it (`PlayerArsenal.use_ability`) and the grapple's hold is off
  (`PlayerController`). **Overshield** (Survivor, tier 3): the shield doubled and filled for 8 s,
  30 s from one to the next; its bar sits where the grapple's does. Hook Shot and Quick Recovery
  (Brawler) speed both its recharge and the grapple's (`PawnMoves.cooldown_speed`).
- **The Brawler's melee** (`Pawn.melee_speed / melee_reach / melee_lunge / melee_backstab`,
  `MeleeStrike.strike`'s `reach` and `backstab`): Heavy Hands, Brutal Rhythm and Iron Knuckles
  shorten the recovery; **Kinetic Lunge** +50% reach, and a blow landed past the plain 1.8 m
  carries the pawn in at 9 m/s; **Backstab** 2.5x when the blow travels the way the target faces;
  **Shield-Shatter Shockwave** — a blow that breaks a shield strips 25% of every other enemy's
  shield within 4 m; **Vampiric Impact** (the top) — a melee kill gives back half the shield and
  refills the gun in hand. A blow's info now says what it hit, whether it broke a shield, and
  whether it was a backstab.
- `tools/skill_kit_probe.gd` (30 checks); `skill_tree_probe` moved to the new nodes and to the
  health under the shield.
- **Not yet:** more abilities and a second slot; the slide-punch launch and armor
  plates for Backstab (§4.2); the shield's break and recharge sounds and screen edge.

**Step 10 — safehouse infusion: built 2026-10-10.**
- `Infusion` (`scripts/progression/infusion.gd`): the cost, `100 × 1.25^(t−1)` scrap for each tier
  gained into tier t, times the rarity (white 1, green 1.25, blue 1.6, purple 2, legendary 2.5,
  mythic 3): a white from tier 1 to 4 is 381. A broken-down gun gives `20 × rarity cost × rarity ×
  1.25^(tier−1)` (a tier-3 purple: 250). A kill drops a quarter of its XP as scrap (a light enemy at
  tier 1: 5). All three grow 1.25× a tier. Placeholder numbers.
- `GunGenerator.retier(result, tier)`: the gun in place at another tier — its damage (and so its
  score) times the step between the tiers, nothing re-rolled. The gun in hand fires at the new
  damage at once. A saved gun's infusion is its entry's tier (`Infusion.infuse_entry`).
- `PlayerLevel.scrap` and `story_tier` (the highest fight tier reached, `reach_tier`), saved with
  the level in `CharacterSave.character`.
- **The bench** (`Workbench`, `scripts/progression/workbench.gd`): a greybox counter with a lamp.
  Looked at and held R, the backpack opens on its page: every gun the player holds, its tier and
  what lifting it costs. Enter infuses; Backspace twice breaks a backpack gun down (never a kit
  gun). Walking away closes it. `CityScene._place_workbench` sets one down by the player's start,
  not in a scripted pass.
- `tools/infusion_probe.gd` (23 checks).
- **Not yet:** safehouses (the bench is a stand-in by the start); kinds of material; a story tier
  from the story
  (today it is the highest fight tier reached).

---

## 15. Handoff — pick up here (updated 2026-10-10)

Everything above through step 10 — the whole of §12's plan — is **built, tested and merged into
`main`**. The player side it
sits on (FPS movement, view model, HUD, settings menu) is documented in
[../Reference/ceramicedge.md](../Reference/ceramicedge.md) §0, §2.3–2.4, §7.1.

### 15.1 Next

§12's ten steps are built. What is left, by weight:

- **The time-to-kill base (2026-10-12):** §3 and §4.4–4.5. The AI roster (`data/ai/roster.json`, AI area) still states its units' layers in old melees; it should be re-exported against the medium enemy (shield 0.6, armor 1.2, health 1), and `roster_probe` / `roster_field_probe` compare the two until it is.
- More of the skill kit: abilities past the Overshield and a second slot, the marksman and
  element branches (§4.2).
- Special weapons past the arc caster; a heat bar for the plasma charge.
- Aim assist: built ([AIM_ASSIST.md](AIM_ASSIST.md)); controller look still to come.
- Step 5's other leftovers: ammo reserves, co-op drops, pad bindings. (A swap now takes about
  half a second in the hands -- the old gun goes down out of view, the new one comes up,
  no firing while it is down: `PlayerView`, 2026-10-10.)
- Light and heavy kinds: built (§7.8). Left: semi- versus full-auto, real art per kind, and the
  reserve's two-rounds-a-shot when reserves exist.
- Helmets and head crits (switch `Pawn.head_crits` on when enemies are figures), and §13's
  questions.

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
| Modifiers, slots and quality | `scripts/guns/gun_modifiers.gd`, `Rarity.SLOTS` / `QUALITY`; the card `scripts/guns/gun_card.gd` |
| Alt-fire | roll `scripts/guns/gun_alt_fire.gd`; firing `GunController` (alt-fire section); `scripts/combat/tracking_dart.gd`, `arc_flash.gd`; mode and HUD `scripts/pawn/player_arsenal.gd` |
| Tube, torch, arc caster, AI alt-fire | `GunController` (`_fire_tube`, `tube_burst`, `_step_torch`, `_burn_cone`, `_arc_down_aim`, `_ai_alt`), `scripts/combat/tube_grenade.gd`, `WeaponClass` `arc_caster` |
| Element statuses | `scripts/elements/element_status.gd` (the shatter: `try_shatter`); built from `DamageSystem.resolve`; `Pawn.speed_mult` / `frozen` |
| Infusion and scrap | `scripts/progression/infusion.gd`, `workbench.gd`; `GunGenerator.retier`; the bench's page in `PlayerArsenal` (`open_bench`, `infuse`, `salvage`) |
| The kit saved | `CharacterSave` (`gun_entry`, `make_result`, `loadout_dict`, `fill_loadout`); `PlayerArsenal.restore`, `kit_changed`; `CityScene._load_kit` |
| Player shield, ability slot, Brawler | `PlayerArsenal` (`ensure_shield`, `use_ability`, `_on_meleed`, `shockwave`); `Pawn.melee_*`; `MeleeStrike.strike` (`reach`, `backstab`); `PlayerLevel.tactical` |
| Level, XP, skill tree | `scripts/progression/` (`player_level.gd`, `skill_tree.gd`, `skill_screen.gd`); kept on `PlayerController.progress`; applied by `PlayerArsenal.apply_skills`; saved by `CityScene._load_progress` |
| Arena units and level | `scripts/ai/commander/unit_catalog.gd` ("profile"), `scripts/ai/wave_director.gd` (`level`) — AI area |
| Player input, view, HUD, moves | `scripts/pawn/player_controller.gd`, `player_view.gd`, `player_hud.gd`, `pawn_moves.gd` |
| Settings menu | `menu/` (Ceramic Edge's module), `scripts/brickcity_menu_host.gd` |

### 15.4 Tests to run before merging

Probes (`--headless --path . --script res://tools/<name>.gd`): `combat_numbers_probe` (20), `modifiers_probe` (19), `alt_fire_probe` (30), `status_probe` (19), `skill_tree_probe` (36), `infusion_probe` (23), `kit_save_probe` (21), `skill_kit_probe` (33), `special_fire_probe` (25), `frozen_soldier_probe` (10),
`crit_probe` (10), `defence_probe` (19), `melee_probe` (36), `loadout_probe` (31), `moves_probe` (39), and the AI ones that read soldier
health: `commander_probe`, `tactics_sense_probe`, `fights_back_probe`, `soldier_probe`,
`room_clear_probe`. Gates (not headless): `res://scenes/city.tscn -- --play` (14) and `-- --gun`
(7), `res://scenes/combat_arena.tscn -- --gate` (35), `res://test/loot_range_test.tscn -- --probe`. Menu: `res://menu/tests/menu_smoke.tscn`
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
- **`fights_back_probe`'s "rounds went into the wall" check sits on its line**: 2 of 14 rounds
  reach the hiding soldier on `main` before step 6 against a 15% limit; step 6's numbers (a lower
  median damage, light enemies at 60) make it 4 of 15 and it fails, deterministically. The fight
  itself is unchanged (the soldier still leaves its cover with time in it). AI area: its gun is a
  seeded loot roll, so any loot change moves it.
- **`threat_style_probe` crashes on exit** (exit 139, after "7 passed") on `main` as it is: its
  checks pass; the crash is in the AI area's teardown.
- **Physics runs at 30 ticks a second** (`project.godot`), not 60: a probe that waits seconds
  must count `Engine.physics_ticks_per_second` ticks.
- **`loot_range_test --probe` rolls unseeded** (`_rng.randomize()`): its gun-vs-shield category
  row fails about one run in three on a gun and a shield scored close together (seen: T8 R1, gun
  840 vs shield 865). Rerun before blaming a change.
- **`squad_advance_probe` flakes** (fails about one run in two on `main` too). Soldier probes'
  timing checks flake under machine load; rerun alone before blaming a change.
