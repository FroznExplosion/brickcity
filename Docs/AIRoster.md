# AI roster — putting enemy and friendly types together (plan)

**Status: 2026-10-09. A plan; steps RO1 to RO8 (§9) are built: pilots get in and out, and the §5 loop runs whole.** A mech's AI knows its own
layers and its target's, and a mech is a row of its own in aggro: the §5 loop runs up to step 3. A mech is killed in layers
(`MechLayers`, §4.2): every mech in the game has them now. The commander fields six new
types from recipes -- a melee type, a bomber, a grenadier, a sergeant, the brute and a hound --
a type can change in a fight (phases), and flyers are roster types that decide from the casebook
(a flying bomber, a drone). Types are described as recipes
on the Tactics Casebook page's Roster tab, exported to `data/ai/roster.json` and read by `Roster`
(`scripts/ai/roster/roster.gd`). `UnitCatalog` reads a unit's name, weapon, points and health
from its recipe; every soldier carries its type's name over its head and tells the casebook what
it is; each size of body has a navigation map of its own (`AIServices.nav_for`).
`tools/roster_probe.gd` and `tools/roster_field_probe.gd` check it. Everything else here is
planned unless a section names it as existing.
The numbers are first guesses, sized from the weapons and health code as it stands.

How every thing that fights is described and assembled: soldiers, creatures, flyers, mechs,
trucks, tanks, helicopters, planes -- enemy and friendly. Read first:
[AI.md](AI.md) (§5.2 archetypes, §6.4 mechs, §8 aggro, §9 the commander, §10.2 who is smart),
[AIVehicles.md](AIVehicles.md), [Tactics/README.md](Tactics/README.md) (the casebook, which
decides what an agent does).

---

## 0. Decided

| # | Decision |
|---|---|
| R1 | A type is a **recipe** of independent parts -- body, size, class, grade, attack, role, mods, phases -- not a hand-written class. "Very light bomber cannon-fodder flyer" is a few words of data. |
| R2 | **Classes: light, medium, heavy, strong**, for every body, each in **three grades: weak, regular, tough**. Class and grade are **how much it takes to kill and what sort of enemy it is** -- not how big it is. Weak ones are usually cannon fodder; tough ones usually defenders, attackers, leaders. |
| R3 | **Size is its own part**, and decides where a thing fits: people go into buildings; a walking mech goes only into a damaged building, or damages one to get in. |
| R4 | **Attack** is its own part (melee, shooter, bomber...). **Role** is another on top (defender, leader, attacker, cannon fodder...). |
| R5 | **Phases.** An enemy can change attack, role or body when something happens: a shooter that loses its armour or shield goes berserk and melees; a defender turns attacker; a second phase can make it a flyer or a bomber. **Two phases at most**; bosses may have more. Each type changes for its own reason. |
| R6 | **Mechs: three classes.** Light: more shield, less armour. Medium: the middle of both. Heavy: more armour than shield. The hatch is at the **front** on medium and heavy, at the **back** on light. |
| R7 | **A mech is killed in layers** (§4.2): shield, then armour, then health; the hatch and the power-cell door are armour of their own; the pilot and the power cell are what they cover. |
| R8 | **Rodeo.** A player on foot can climb an enemy mech and plant a charge that blows its hatch off. Enemies can rodeo a player's mech, but only a type built for it. A rider can be crushed, scraped off, or smoked off (§4.5). |
| R9 | **A mech keeps its own aggro** when its pilot gets out. The enemy mech stays on the player's mech while the pilot goes round on foot. |
| R10 | **Two kinds of aircraft.** Hover craft (Halo's banshee): slow, stays in an area, slow attacks. Fast planes: strafing and bombing runs. |
| R11 | **Friendlies use every system here**: the same recipes, brains, casebook and commander. |
| R12 | **A commander runs each side.** The friendly one takes its lead from what the players do. |
| R13 | **The player orders only their own mech**: go to an area, hold, follow. No orders to other allies. |
| R14 | **The player can rodeo and drive every vehicle** -- but not an enemy mech: it starts to self-destruct the moment a pilot of another side tries to get in. |
| R15 | **People's weapons and mech weapons are two scales** (§4.6). Mech guns and anti-mech weapons are **rolled by the same generator as a pilot's guns**, on the mech's scale; one that rolls enough damage kills a person or an animal in one hit, and most do. A pilot's gun does nothing to a mech -- except explosives, an element the mech's current layer is weak to (a little: plasma on a shield, corrosive on bare armour), and anti-mech weapons (good damage, always). |
| R16 | **Self-destruct is quick: high damage, small area.** **Nuke eject** is a mod (Nuker) only some enemies have, and the player can have: a doomed mech throws its pilot clear and goes off big -- unless it is finished with a takedown while doomed, or its power cell is destroyed (then it just blows up). |
| R17 | **A name over the head** of every enemy and every non-player ally says what it is, as in Borderlands 4: "Heavy Gunner Nuker" is a heavy mech with a machine gun that will nuke; "Light Melee Nuker" runs at you, punches, and goes off the moment it is doomed. |
| R18 | Settled readings of §4.2: armour gone drops the doors to very low rather than taking them off; the power cell can be destroyed as soon as its door is off; a mech in auto mode is weaker than one with a pilot (no abilities, no smoke). |

---

## 1. The recipe

```
gnat:
  body:   flyer        size: small
  class:  light        grade: weak
  attack: bomber
  role:   fodder
  mods:   []
  phases: []
```

From those lines the game works out, and nobody writes by hand:

| Derived | From |
|---|---|
| Mover and navigation map; where it fits; its weight on floors | body and size |
| Health layers (flesh, armour, shield) | class x grade, and mods |
| Weapon | attack (and class: a heavier shooter carries a heavier gun) |
| Brain tier (smart / directed / swarm, AI.md §10.2) | role (fodder is never smart), then the importance budget |
| Casebook facts (`we_flyer`, `we_bomber`, `we_fodder`) | body, attack, role -- so the casebook's curves and odds apply |
| Aggro: how loud it is, whom it prefers | size, role, attack (§6) |
| Points for the commander | all of the above, by formula (§8) |

A recipe is checked when loaded: a combination that cannot work is refused with the reason,
not fielded broken.

## 2. The parts

### 2.1 Body: how it moves

| Body | Navigation | Exists |
|---|---|---|
| walker | AINav, with the size's agent profile (width, head room, step, drop) | soldiers; animals; the mech map (AIPlan P7) |
| flyer | the flyer height field | `Flyer` (P8) |
| wheeled / tracked | a vehicle map with clearance; tracked crushes what wheels cannot cross | the truck drives the foot map (AIVehicles.md) |
| hover craft | the flyer height field, with a loiter area | no |
| fast plane | none: a scripted run along a line (§7) | no |
| boat | the sea's surface | no |

### 2.2 Size (R3)

Size picks the agent profile, so one pathfinder sends a person through a door and a mech round
the building -- or through a hole it makes (breach links and the fall rule exist, AIPlan P7).
It also sets weight on floors and how much attention the thing draws by being seen.

| Size | Example | Tall x wide | Fits | Weight on floors |
|---|---|---|---|---|
| small | a dog, a drone | 0.6 x 0.4 m | anywhere a person does, and gaps | none to speak of |
| person | a soldier | 1.68 x 0.52 m (today's pawn) | doors, stairs, rooms | any floor |
| large | a brute | 2.6 x 1.0 m | wide doors, damaged walls | checked against the floor's headroom |
| huge | a mech, a tank | 6.7 x 3.5 m (today's mech) | damaged buildings, or breaks in | breaks weak floors (the fall rule) |

### 2.3 Class and grade (R2)

Twelve steps of "how much it takes to kill", and the sort of enemy it is. Size is not in it: a
person-sized enemy can be strong/tough, a huge one light/weak.

Counted in **melees to break each layer**, the fight's own unit (COMBAT_DESIGN.md 4.1: one
melee is a light enemy's whole flesh -- 64 health at level 1, +25% a level; a shield holds 1.5x).
"def" is the one defence a light or medium type wears: armour, or a shield with the Shielded mod.

| | weak | regular | tough |
|---|---|---|---|
| **light** | flesh 0.5 -- **1** | flesh 1 -- **1** | def 1, flesh 1 -- **2** |
| **medium** | def 2, flesh 1 -- **3** | def 3, flesh 1 -- **4** | def 4, flesh 1 -- **5** |
| **heavy** | shield 1, armour 2, flesh 2 -- **5** | shield 2, armour 3, flesh 2 -- **7** | shield 3, armour 4, flesh 2 -- **9** |
| **strong** | shield 3, armour 5, flesh 3 -- **11** | shield 4, armour 6, flesh 3 -- **13** | shield 6, armour 8, flesh 4 -- **18** |

Bold is melees to kill. These contain today's profiles exactly: very light = light/weak,
light = light/regular, light armoured or shielded = light/tough, medium = medium/regular,
heavy = heavy/regular. Usual roles: light/weak is fodder; medium is the line; heavy and strong
are defenders, attackers and leaders. Grade also scales damage and points.

**Points** (what a commander pays) = (0.5 + half the melees to kill) x attack x role x mods --
which gives today's prices: rifleman 1, breacher 1.5, veteran 2.5, marksman 4, rocketeer 5,
officer 8.

### 2.4 Attack

| Attack | What it does | Casebook | Exists |
|---|---|---|---|
| shooter | guns | the default curves | yes |
| marksman | long range, relocates | `we_marksman` | yes |
| melee | closes in and hits | `we_melee` | the move, yes; a melee type, no |
| bomber | runs or flies in and detonates (the creeper) | `we_bomber`: detonate takes 95% in reach | no |
| grenadier | grenades first | `we_grenadier` | grenades, yes; the type, no |
| anti-armour | rockets at mechs and vehicles | `we_anti_armour` | no (rocketeer is in the catalogue, unbuilt) |
| gunner | suppresses; slow to move | `we_gunner` | no |
| shield / support | covers or mends others | later | no |

### 2.5 Role

A role is a set of multipliers over the casebook's moves, plus a place in the squad:

| Role | Leans to | In the squad |
|---|---|---|
| attacker | rush, flank, push | goes first |
| defender | hold, guard the ways out, ambush | has a post and a leash: it does not chase past it |
| leader | call for help, mark, hold back | gives the orders; when it dies the squad's morale breaks |
| fodder | rush, melee, no cover | the cheap brain tier; dies in numbers |
| flanker / hunter | flank, search, goes for the pilot | works alone |
| scout | scout first, mark, fall back | finds, does not fight |

### 2.6 Mods

Shielded, armoured, explodes on death, jetpack, cloaked, carries others, **rodeo** (may climb a
player's mech, R8), heavy weapon. Each is a small, separate piece.

### 2.7 Temper and senses

Temper: how soon it falls back, whether it ever runs, surrenders or fights to the end. Senses:
sight range and cone, hearing -- a creature can be blind and hear well. Both are recipe lines
with defaults by role.

### 2.8 Phases (R5)

```
brute:
  body: walker   size: large   class: heavy   grade: regular   attack: shooter   role: attacker
  mods: [armoured]
  phases:
    - when: armour_gone
      become: {attack: melee, temper: berserk}
```

A phase is "when X, these parts change". Triggers: armour gone, shield gone, health under a
share, leader dead, alone, its post lost (the defender turned attacker), hatch broken, a time.
What may change: attack, role, temper, mods, and body (a second phase that takes off). On a
change the game re-derives the weapon, the mover and the casebook facts; the brain tree stays,
because what it does comes from the casebook. Two phases at most, more for a boss.

Every phase change is **shown and called out** -- the armour bursts off, a shout -- so the
player reads it as a new threat and not as the AI cheating.

## 3. How it is put together in code

One agent = a body + four parts behind fixed seams:

| Part | Is | Today |
|---|---|---|
| Mover | paths and steering for the body | inside `Soldier`, `Flyer`, `MechBrain`, `TransportTruck` separately |
| Senses | what it sees and hears, into the side's shared knowledge | inside each, separately |
| Arsenal | weapons: guns, melee, grenades, detonate | `Soldier` (gun, melee, grenade) |
| Brain | a behaviour tree per body family, asking the casebook what to do | `SoldierTree`, the mech tree |

Shared by all: `AIServices` (knowledge, aggro, tokens, callouts, the scheduler and budget),
`TacticsSense` + `BookCombatPolicy` (the casebook decides), `TacticsTally` (what happened),
squads and the commander. The work is to lift Mover, Senses and Arsenal out of `Soldier` so a
flyer, a mech and a tank crew use the same ones, and to give mechs and aircraft their own
**sections of the casebook** (their moments and moves) rather than their own decision code.

The casebook gains: kinds (`we_bomber`, `we_grenadier`, `we_gunner`...), roles (`we_leader`,
`we_defender`, `we_fodder`...), moves (detonate, guard a post, shield the hatch, bail out, mount,
aim for the hatch, aim for the power cell, climb on, scrape a rider off, electric smoke, the
finisher, orbit, attack run), mech and aircraft moments, and a **Roster** tab on the page where
a recipe is put together from the parts.

## 4. Mechs

A mech's brain is its own tree (it exists, AIPlan P7), deciding from the casebook's mech section.

### 4.1 Classes (R6)

| Class | Shield | Armour | Health | Hatch armour | Cell-door armour | Hatch | Points |
|---|---|---|---|---|---|---|---|
| light | 1400 | 800 | 800 | 200 | 150 | back | 20 |
| medium | 1000 | 1500 | 1250 | 350 | 250 | front | 25 |
| heavy | 600 | 2400 | 1500 | 500 | 350 | front | 30 |

Grade scales the pools: weak x0.75, regular x1, tough x1.3. Doomed health 250; the power cell
300, hit for x3. (Today's mech is one pool of 2500 and costs 25.) Against a mech gun of about
350 damage a second that is 9 to 13 seconds for one mech to kill another.

### 4.2 How a mech dies (R7)

Three pools, in order, and two doors with armour of their own:

```
shield  ->  armour  ->  health            (+ hatch armour over the PILOT,
                                             + cell-door armour over the POWER CELL)
```

| Rule | |
|---|---|
| Shield first | the armour takes nothing while the shield is up. |
| Mech melee goes through shields | a mech can be punched to death at full shield. |
| Armour is one pool, hit anywhere | every hit on the mech takes from it, wherever it lands. |
| The hatch and the cell door have their own armour | hits ON them also wear that; either can come off before the armour pool is gone. |
| Armour gone, doors still on | the hatch and the cell door drop to very low: the next hit or two takes them off. |
| Hatch off | the pilot can be shot. |
| Cell door off | the power cell can be shot, for critical damage. |
| The shield comes back | it recharges even with the armour gone -- but no longer covers the pilot or the cell. |
| Pilot killed inside | the pilot dies; the mech lives and goes to **auto mode** (it fights on by itself). |
| Power cell destroyed | the mech is destroyed, and the pilot in it. |
| Armour gone and health drained | **doomed**, whether or not the doors are still on: its shield dies at once, a few hits finish it, and another mech can **finish it with a melee**. |

What the AI has to know, as casebook facts and amounts, for its own mech and the one it fights:
shield up or down, armour share, hatch on / low / off, cell door on / low / off, doomed,
piloted or auto.

### 4.3 What an AI mech does with that

- **Hatch off or nearly off:** keeps the hatch side away from the threat. A light mech (hatch
  behind) keeps facing the enemy and backs to a wall; a medium or heavy (hatch in front) turns
  side-on, backs into cover, has its infantry cover the pilot, or the pilot bails out and the
  mech fights on in auto mode.
- **Cell door off:** the same for the cell's side, and harder: losing the cell loses everything.
- **Shield down:** breaks off to let it recharge, when it can.
- **Doomed:** by its temper -- a last rush, or the pilot ejects. It keeps out of melee reach of
  enemy mechs (the finisher).
- **Against a doomed mech:** closes to melee for the finisher.
- **Against any mech:** aims for a door that is off or low (the pilot's or the cell's), and gets
  to the side it is on; uses melee on one whose shield it cannot wear down.

### 4.4 Getting in and out

An AI pilot paths to the hatch side to mount -- behind a light mech, in front of the others --
and needs that spot clear. Empty mechs are things on the map; a friendly AI pilot uses the same
rules (R11). **A mech belongs to its side**: if a pilot of another side tries to get in, it
starts to self-destruct (R14) -- so nobody steals a mech, the player included. An AI must not
try, and should get clear of one that has been set off.

### 4.5 Rodeo (R8)

**Breaking a hatch from outside** takes a rider with a planted charge, or several mech melee
hits on the hatch.

**The player on an enemy mech:** get to it unseen, climb on, plant the charge. The mech's
answers, from the casebook:

| Counter | How | The catch |
|---|---|---|
| Crush | rams its top into something | needs something overhead to ram |
| Scrape | walks under something just low enough | needs such a place near; the AI has to path to it |
| Electric smoke | a cloud round itself | it recharges, so it can be **baited**: jump on, jump off, get back on while it is down. It damages the mech's own shield (an upgrade may spare it), and with the hatch off it hurts its own pilot |
| Escort | infantry shoot the rider | they are shooting at their own mech |

So an AI mech with the hatch off should be much less willing to use smoke, and one that has
just used it should guard its back until it recharges.

**An enemy on the player's mech:** only a type with the rodeo mod. It is called out and shown on
the HUD; the player has the same counters.

**Vehicles:** the player can rodeo and drive all of them (R14).

### 4.6 People's weapons and mech weapons (R15)

| Shooter -> target | What it does | First guess |
|---|---|---|
| mech weapon -> person, animal | its rolled damage, as any gun's: enough kills in one hit, and most mech guns have enough | mech weapon classes in the same generator (`WeaponClass`), with base damage about 6 melees a round for a cannon and 2 for a machine gun. So a cannon one-shots up to the medium class at its level; heavy and strong infantry take 2-4 hits and stay worth fielding against a mech; a low roll, or a mech gun under the enemy's level, may not |
| pilot's gun -> mech | **nothing** | 0 |
| pilot's gun with the **element the mech's current layer is weak to** | a little | 10% of the gun's damage. Plasma on a shield -- and nothing once it reaches the armour; corrosive on bare armour -- and nothing while the shield is up |
| pilot's **explosive** (grenade, rocket, launcher) | some, on any layer | 50% of its damage: a grenade 75, a rocket 120 |
| **anti-mech weapon** (new classes in the same generator) | good, on any layer; may roll an element for extra effect | about 400 a shot at base: 8-11 shots for a whole mech |
| mech melee -> mech | **through the shield**, into armour and health; on the hatch, into the hatch's own armour too | 500 a blow: a light mech dies in about 4, a heavy in about 8; a hatch comes off in 1-2 |
| mech melee -> doomed mech | the **finisher** | kills |

### 4.7 Self-destruct and nuke eject (R16)

| | When | Fuse | Reach | Damage |
|---|---|---|---|---|
| Self-destruct | a pilot of another side tries to get in; or its power cell is destroyed | 2 s | 8 m | kills people; 1000 to a mech |
| **Nuke eject** (the Nuker mod) | it becomes doomed: the pilot is thrown clear and the mech goes off | 4 s, loudly | 30 m | kills people; 2500 to a mech |

A nuke is **stopped by a takedown** (the melee finisher) while the mech is doomed, and a mech
whose **power cell** is destroyed never nukes -- it just blows up. So the name over its head
tells the player which of those to go for. An AI with the mod plays to it: a "Light Melee
Nuker" closes, punches, and wants to be doomed next to its target.

### 4.8 The name over its head (R17)

Worked out from the recipe, so it never lies: for a mech, class + attack + mods ("Heavy Gunner
Nuker"); for anything else, grade (unless regular) + class (unless light) + attack + mods +
body (unless a walker) + "Leader" for a leader ("Tough Breacher", "Weak Bomber Flyer"). A
recipe may carry a name of its own ("Veteran", "Brute"), shown with the tag. It follows the
phase: a brute whose armour has gone reads "Heavy Melee". Shown over enemies and non-player
allies, in the side's colour.

## 5. The loop this is all for (R9)

1. The player's mech goes in loud. It takes the enemy's attention, the enemy mech's most of all.
2. The player gets out and orders it: hold, follow, or go there (R13). It keeps fighting by itself
   and **keeps its own aggro** -- it is its own row in the table.
3. The enemy mech stays on the player's mech. The pilot goes round on foot, unseen.
4. The pilot climbs the enemy mech, baits its smoke, gets back on, plants the charge. The hatch
   is off.
5. Now the enemy has to choose: turn on the rider, protect the pilot, or bail out.

## 6. Aggro

**Exists** (`AggroTable`, AI.md §8): one table per enemy side with a row per pilot and a row
per mech; it grows with damage, noise, being seen and being near, halves every 8 s, moves only
when another row leads by a margin, feeds who gets shot at, and shows as a meter. The
commander can lean it towards the pilot (`pilot_focus`).

**To add:**

| # | Addition | Why |
|---|---|---|
| G1 | A mech draws more for being seen and near than a pilot does, by size | so an empty mech that is still standing there holds attention, not only one that is firing |
| G2 | **Target preference** per recipe: mechs and anti-armour prefer mechs; hunters prefer pilots; bombers take the nearest; a defender ignores what is beyond its leash | so "the enemy mech stays on my mech" is a rule, not luck |
| G3 | A stronger hold for a mech on a mech: it takes more to pull it off | the same |
| G4 | An unseen pilot gains nothing; a pilot seen while a mech holds the focus gains little | sneaking round has to be possible |
| G5 | A rider: no gain until noticed, then a spike on the mech it rides and its escort | the rodeo's moment of risk |
| G6 | **Exposed pilot** and **exposed power cell** as rows of their own once a door is off, weighted high | "aim for the pilot", "aim for the cell" |
| G7 | A doomed mech draws other mechs (the finisher) | so the finisher happens |
| G8 | Friendly AI and their mechs get rows too | R11: they can draw fire for the player, and the reverse |
| G9 | The meter shows pilot, mech, and what is exposed | so the player can play it |

## 7. Vehicles and aircraft

[AIVehicles.md](AIVehicles.md) has the ground vehicles' plan; the truck is built in its
smallest form. In recipe terms a vehicle is a body with **seats**: driver, gunner and passengers
are agents of their own (recipes of their own) who get out when it dies. The player can take
any seat of any vehicle, and rodeo any of them (R14).

- **Trucks, tanks, APCs:** a vehicle map with clearance; tracked ones crush; infantry screen
  them or ride them (the casebook already has both moves).
- **Helicopters:** the flyer height field, hovering, landing zones, door guns; can fire in
  through a window when it can hover level with the floor.
- **Hover craft (R10):** a flyer agent with a loiter area -- it stays near, circles, makes slow
  attack passes, can be shot down. A full agent, deciding from the casebook's aircraft section.
- **Fast planes (R10):** not agents. The commander buys a **run**: a line across the map, a
  warning (sound, a callout), strafing or bombs along the line, gone. It can be shot at on the
  pass. No navigation, no brain.

## 8. The commander (R12)

**Exists** (AI.md §9.1): one per side, a points budget, a doctrine that shifts with how the
player fights (`ThreatProfile`: demolisher or careful, mech kills or pilot kills), squads and
orders, an HQ, a friendly side that keeps its squad with the player.

**Added (RO11, built):**

- It **buys recipes**. Points come from the recipe by formula, so any combination has a price.
- Its doctrine chooses along the parts: against a player who lives in their mech, more
  anti-armour and rodeo types; against a careful pilot on foot, hunters (not marksmen: AIPlan
  P9 keeps those the demolisher's answer); against a demolisher, fewer troops indoors. (The
  clamps stay: no counter is a hard counter.) It buys support too: air and a tank.
- It reads the tally of what worked (`TacticsTally`) across encounters, as it reads the threat
  profile.
- **The friendly commander** gets no orders from the player (R13). It infers: where the players
  go and what they shoot at, and what they have told their mechs to do. It sends friendly
  squads to support that, never in front of a player's gun (`PlayerIntent`; the RO11 row says
  how, and what is not yet).

## 9. Order of work

Each step ends in a gate, as AIPlan's phases do.

| Step | What | Shows |
|---|---|---|
| RO1 | **Built.** Recipes as data, derived values, the validity check; today's infantry units written as recipes; the Roster tab on the casebook page | no change in behaviour: `roster_probe` shows the recipes give today's units their own health, weapon and points |
| RO2 | **Built.** Units fielded from recipes (`UnitCatalog` reads the roster: change a recipe on the page, export, and the unit changes); the name over the head of every soldier, enemy or ally; the type's facts into the casebook; a navigation map per size | `roster_field_probe`: "Tough Breacher" over its head; through a door two studs wide a person has a way and a large body has none. **Not yet:** a large BODY (the pawn is still person-sized -- it comes with the first large type, RO3), and the brain-tier cap (with fodder, RO3) |
| RO3 | **Built.** Attack types and roles as casebook facts (bomber, grenadier, gunner, anti-armour; attacker, defender, leader, fodder, flanker, scout); the bomber's move, "go off" (95% in reach); five types the commander fields: **Brawler** (melee, no gun), **Weak Bomber** (fodder: runs in, lights a 0.7 s fuse, 80 damage within 4.5 m; shot dead first, it does not go off), **Grenadier** (six grenades), **Sergeant** (a leader: its death breaks its squad and its soldiers know), **Brute** (the first large body, 2.6 m, on the large map, spawned outside); fodder capped at the cheap tier, where a type with no gun still closes and hits or goes off | `roster_types_probe` (9 checks); the arena gate with all five in its waves. **Not yet:** the flying bomber (RO5); a defender's post and leash beyond its casebook lean; gunner and anti-armour as fielded types |
| RO4 | **Built.** Phases: when its trigger comes (armour gone, shield gone, health under half, leader dead, alone) a type's attack, role, casebook facts, brain cap and the name over its head change, it shouts, turns orange, and decides again at once | the brute loses its armour, becomes "Heavy Melee", drops its gun and charges. **Not yet:** a phase that changes the body (RO5); the post, hatch and doomed triggers (with those systems); the armour visibly bursting off (a colour change stands in) |
| RO5 | **Built, in its first form.** `TypeKit` holds what every type shares whatever its body (the name over it, when a phase comes, the brain cap); `Flyer.set_type` makes a flyer a roster type, and with the casebook as policy its mode is the book's move (`BookCombatPolicy.decide_air`, `TacticsSense.read_air`): circle and fire, a strafing run, break off, or -- a bomber -- dive under the clearance and go off. Fielded: **Weak Bomber Flyer** (gnat), **Drone**, and a **Hound** (a small body on the small map, the cheap tier, bites). The arena brings two flyers with each reinforcement from the second on. On the cheap tier a no-gun type's last metres are a path followed every tick | `roster_air_probe` (8 checks): the flying bomber is the bomber's recipe on a flyer. **Not yet:** Mover, Senses and Arsenal as separate parts lifted out of `Soldier` (today the two bodies share `TypeKit` and the casebook, and each still carries its own movement, sight and weapons -- to be split when the mech and the vehicle crew need them, RO6-RO10); a phase that changes the body; wildlife (`Animal`) stays as it was |
| RO6 | **Built.** `MechLayers` (`scripts/mech/mech_layers.gd`): shield, armour, health and a doomed pool as the mech's HealthPool layers (so bars, the shield's regen and whatever already hurt a mech keep working), the hatch's and the cell door's own armour, the pilot and the power cell, auto mode; the damage scales of §4.6 (`DamagePacket.scale`, a branch in `DamageSystem.resolve`); mech melee through the shield and the finisher (`Mech.melee`); self-destruct and nuke eject. `Mech.set_type` gives a mech its class's numbers, its hatch's side, the Nuker mod and the name over it. A mech's arm gun is mech-scale and its rounds count eight times (`Mech.GUN_MULT`) -- a stand-in until mech weapons are rolled as classes of their own | `mech_layers_probe` (18 checks): a mech killed each of the ways §4.2 allows; a rifle that does nothing to it. **Shield gating applies** (COMBAT_DESIGN 4.4): the hit that breaks the shield carries half of what is left into the armour. **Not yet:** a hit knows hatch and cell door by where it lands on the torso (a ball of 1.15 m round each), not by hurtboxes of their own; a splash (EffectDispatch) is still a person's hit to a mech; no pilot is put on the ground when a Nuker ejects or a pilot bails out (RO8); the blast does nothing to bricks; nobody -- AI or player -- throws the punch yet (RO7, and the mech's controls) |
| RO7 | **Built.** *The casebook's mech section:* one moment (`mech_fight`), five moves (stand off and fire, close in, punch, back off, turn the open side away) and the facts "Mech against mech" (the target a mech, on foot, doomed, a Nuker; our shield down, hatch off, cell door off, doomed, on auto, a Nuker; a doomed mech within reach). `TacticsSense.read_mech` reads them, `BookCombatPolicy.decide_mech` rolls, `MechBrain.Stance` does it -- only when the mech has no order from its pilot. *A mech is a target:* `Mech.make_target` gives it a pawn that does not step, so knowledge, aggro and soldiers' aiming see it as they see a person. *Aiming (§4.3):* `MechLayers.aim_point` -- the pilot when the hatch is off and its side is towards you, then the cell, else the hull; soldiers, flyers and mechs use it; soldiers know `p_hatch_off`. *Guarding:* a mech with a door off in front turns it away and gives ground, and remembers what it is guarding from for 12 s. *The finisher:* a mech holds its fire on a doomed Nuker and walks up to punch it. *Target preference (G2, G3, G7), in `MechBrain`:* a mech prefers mechs, prefers a doomed one, and holds what it has unless another scores well clear of it. *Aggro (`AIServices._aggro_tick`):* a mech's presence counts 2.5 times a person's (G1), half as much again with its hatch off and a pilot inside (G6); while a mech holds the focus a pilot in sight gains three tenths and a pilot nobody sees gains nothing (G4). The meter says "hatch off" (G9) | `mech_fight_probe` (7 checks): the player's mech fights on alone and the enemy mech stays on it with the pilot twelve metres behind it; aiming; guarding; the finisher on a doomed Nuker; soldiers' rifles reach an exposed pilot and nothing else. **As built, G4 is narrower than written:** with no mech holding the focus, a player who is near gains attention seen or not, as before -- taking that away lost squads the player who had gone indoors (the arena gate's room clearing, `many_probe`). **Not yet:** target preference per recipe for soldiers (hunters, anti-armour); the exposed pilot and cell as aggro rows of their own (G6 is a multiplier on the mech's row); G5 (riders, RO8), G8 (friendly AI rows); the player has no control for the mech's punch; a grenade's blast reaches a mech as an explosive, other splash still as a person's hit |
| RO8 | **Built.** *Getting in and out:* `Mech.mount` / `dismount` / `park`: a pilot gets in from within 1.6 m of the spot on its hatch's side (`Mech.mount_point` -- in front of a medium or heavy, behind a light), and only if that spot is clear of bricks and on the walking map. Inside, an AI pilot's pawn is put away (out of the side's pawns: nobody sees or aims at it; its hits come through an open hatch, `MechLayers.pilot`) and the mech's brain wakes; a parked mech sleeps. `Soldier.go_board` walks a soldier to a mech of its own side and in -- never another side's. A pilot of another side who tries sets off the self-destruct (R14), and a lit fuse is a danger zone the size of its blast (soldiers get clear). *Bail out* (`m_bail`, a casebook move needing the hatch off or doomed; never on auto or for a Nuker): the pilot is put on the ground at the hatch, a target again, and the mech fights on, on auto. A Nuker's pilot is thrown clear of the nuke (36 m). A mech destroyed with its pilot in kills the pilot. The enemy's mech in the city carries a soldier as its pilot; on foot the player gets into their mech from its hatch side (M) and out the same way, and M at an enemy mech's hatch lights its fuse. *Rodeo* (`Rodeo`, `scripts/mech/rodeo.gd`, one per mech). A pawn of another side on foot within 3.2 m of the hull climbs on (E in the city) and rides on the back of the torso; held for 2.5 s (E held) the charge is planted, and 1.5 s later the hatch is off, rider or not; jump gets off. *Noticed (G5):* after 1 s on it, or as soon as a soldier of its side sees the rider (the mech cannot see its own back, nor aim at it); until then the rider draws no attention, then a spike of 60. *The counters* are the casebook's new moment "A rider on us" (`mech_ridden`; `TacticsSense.read_ridden`, `BookCombatPolicy.decide_ridden`): **electric smoke** (`m_smoke`: the rider is thrown off and takes 45; it costs the mech 300 of its own shield and hurts its own pilot with the hatch off; 15 s to come back, none on auto -- so it can be baited), **scrape** (`m_scrape`: it walks to the nearest place within 32 m with bricks over its head and under the rider's, `MechBrain.find_low_spot`), **crush** (`m_crush`: it backs hard into a wall within 14 m behind it, `MechBrain.wall_behind`; 120 to the rider), or fight on and let the **escort** shoot (`m_fire`, more likely with its soldiers within 40 m). With its smoke spent it minds its back: the last rider within 16 m is felt even unseen and comes first. A mech answers a rider whatever its orders, so the player's mech out of the cockpit does too (on auto: no smoke). *The rodeo mod:* the **Boarder** ("Tough Assault Boarder", light/tough, SMG, flanker, `mods: [rodeo]`) goes round behind a hostile mech its side knows of within 35 m, climbs on, plants, and gets off before the charge goes; thrown off, it tries again 3 s later. The commander fields it (weight 0.4, doubled against a player whose mech does the killing). *The player's answers in the cockpit:* C lets off the smoke; scrape and crush are driving under something low or backing into a wall; the log calls the rider out. **Not yet:** the rider and the charge are not drawn, nor shown on a HUD (the log says what happens); the electric smoke is a sight-blocking cloud for the AI but has no effect drawn | `mech_mount_probe` (11 checks); `mech_rodeo_probe` (10 checks): **the §5 loop whole** on the casebook as it is -- the enemy mech on the player's mech, the pilot round behind it unseen, on its back unnoticed and then noticed, smoked off, back on while the smoke is down, the charge planted, the hatch off, and the enemy choosing (it turned the open side away and on the rider); and scrape, crush and escort each on a book told to; a Boarder on the player's mech blows its hatch, and smoke from the cockpit throws one off and it comes back (12 checks). The arena gate fields Boarders |
| RO9 | **Built.** *Hover craft:* a recipe whose body is `hover` is a `Flyer` held to a **loiter area** (`Flyer.set_loiter`, 40 m round; `in_area`): slower and higher than a gnat (6 m/s, 12 m up; passes at 9 m/s), it circles and makes slow passes as the casebook's air moves say, never dives, fights a target outside its area from the area's edge and goes back over it with nothing to fight. Shot down, any flyer now falls (`Flyer._fall`), and a hover craft hits the ground with a crash (90 within 5 m). Fielded: the **Skimmer** ("Medium Gunner Hover craft", LMG, defender), one at a time over the focus building from the second reinforcement on. *Fast planes:* `AirSupport` (`AIServices.air_of(team)`, one per side) and `AirStrike` (`scripts/ai/air_strike.gd`): not an agent, a run -- a 3 s warning (the caller shouts, the engine is heard), then a line across the map at 70 m/s, 30 m over the tallest thing under it: a **strafing run** (rounds walk along the ground ahead of it, 30 each within 2 m, with a clear line from the plane; a mech takes them on its hull) on a target in the open, a **bombing run** (six bombs along 80 m, 160 within 6 m, the bricks broken) on one with a roof over it. It can be shot down on its pass (400 health): it crashes along its line and the run is over. One run at a time, then 45 s. The casebook's `call_air` needs the fact `air_avail`, which a soldier now reads (`TacticsSense`); saying it brings the run onto the contact, across the caller's view of it. In the arena as played both come, bought by the commander (RO11): the Skimmer and the other flyers as support, the planes when a soldier calls and the commander can pay (`--air` fields the air wing free with every wave); the gate has neither, as it has no flyers (its fights are compared run to run). **Not yet:** the friendly side's air; the plane is two grey boxes, with no sound of its own and no smoke trail; a hover craft has no casebook moves of its own (it uses the flyer's); the casebook gives `call_air` odds in four moments only (player dug in, crossing, have heavy, player leaving), so an arena nobody plays -- the player standing where it was put back -- sees no plane (3 min with `--air`, 2026-10-09) | `air_support_probe` (8 checks): the Skimmer circles and passes over its area and shoots the player in it, and stays at its edge when the player leaves; shot down it crashes and hurts what is under it; a strafing run is warned of, hurts a body on its line and not one 20 m off it, and is gone; a bombing run breaches the roof over its target; a plane shot down on its pass crashes and ends the run; a soldier's call for air brings one run onto the contact. |
| RO10 | **First part built: the tank.** *The tank* (`Tank`, `scripts/ai/vehicles/tank.gd`): a hull on tracks -- it turns on the spot -- under a turret with a **cannon that opens walls** (a rocket-class gun on a mech's scale, one round each 4 s) and a **machine gun**. It is **armour**: a person's round does 3% of its damage, a rocket all of it, a mech's gun 60% (`Tank.ARMOUR`, through `DamageSystem`'s new `takes_packet` meta), 3000 in all. Everybody senses and shoots it through a target pawn, as they do a mech (a heavy: soldiers facing it are outgunned). *Seats:* a **driver** (it moves) and a **gunner** (it shoots), real soldiers put away inside as a mech's pilot is; wrecked, they **climb out hurt** (25) and fight on, and the wreck is no target. Nobody gets into another side's crewed tank; an **empty one is anybody's** and changes side (R14). *Its crew's brain* (`TankBrain`): sees all round from the cupola and tells its side; drives where it is sent on the walking map's path, pivoting into sharp bends; **stops when it sees the enemy itself within 60 m** (30 m when only its side does): fire support, not a ram, and the streets narrow near the fight; **stuck three times** on the way to one goal, it gives the goal up and fights from where it is; keeps its **escort's pace** (waits when they are 14 m behind); the gunner turns the turret on the side's best contact and fires the cannon when on target -- **at a contact out of sight too, seen or heard in the last 6 s, through its wall** -- and the machine gun at bodies in sight within 45 m, never with a friend near the line. *The player drives it* (`TankPilot`): M beside a tank gets in (both seats), WASD drives, the mouse aims the turret, LMB cannon, RMB machine gun, M gets out on foot; Z puts an enemy tank with its screening squad ahead, SHIFT+Z an empty one of ours. *Screening* (AIVehicles.md 4): a soldier with a crewed tank or a piloted mech of its side within 30 m reads the fact `heavy_near` and the moment **"Our heavy support is here"** (`have_heavy`, before "outgunned"); the casebook's `screen_heavy` (now built) sends it to the heavy's **flank towards the threat**, squadmates shared out over both flanks, and `heavy_leads` into its **lee** behind it (`BTManoeuvre.screen_point`). In the arena with `--tank` a crewed tank comes with each reinforcement from where a truck would start, to the focus's street, with that wave's squad as its escort, and the log says every 10 s what it and its escort are doing and what kept its gunner from firing (3 min, 2026-10-09: 27 rounds, stuck short of the street and fought from there). **Not yet:** crushing, damage zones as brick groups, a brick-built body and a vehicle map with clearance (it drives the foot map and can stick where that is narrow); riding on it and rodeo; the APC, IFV, helicopters and boats | `tank_probe` (16 checks): a crewed tank drives where it is sent, pivoting; armour; its gunner hits a player in the open with the cannon and the machine gun and holds off it; a player behind a wall is shot through it; a squad reads "Our heavy support is here" and screens it on both flanks, or follows in its lee; it waits for a squad behind; wrecked, its crew climb out and fight; seats and sides. |
| RO11 | **Built.** *First part: it buys recipes, and support.* *By parts* (`Doctrine.PART_MULS`): the answers to how the player fights are made along a recipe's attack, role, mods and class, not its name -- a sniper meets attackers and flankers and fewer marksmen; a rusher armour, grenadiers and fodder; a demolisher marksmen and the bigger classes (and fewer put indoors); a player whose **mech** kills anti-armour and **rodeo** types, attackers and marksmen for the pilot, no fists; a **careful** player on foot **hunters** (flankers, scouts). A recipe takes the product of the lines it matches, clamped x0.5..x2, over its base weight. Every recipe on foot that can be fielded is in the roster -- **one authored on the page and named nowhere in the code is fielded** (at `NEW_RECIPE` 0.5 before the answers). *Support* (`Doctrine.support`, `Commander.buy_support`): every 20 s the commander considers buying **air** (one of the roster's flyers or hover craft, up to 3 up) or a **tank** (20 points, one at a time), each at the doctrine's weight -- air first against a demolisher or a sniper, a tank against a mech or a rusher -- if the points leave 4 over; the host fields it (`WaveDirector._field_support`). **A plane run costs its commander 6 points** (`AirSupport.payer`): with fewer, a soldier does not know air as available. The arena no longer hands out air free from the second wave; `--air` and `--tank` still field them free, for trying them out; a gate buys none (its checks count soldiers). In a 4-minute arena nobody played (2026-10-10): a gnat, three drones, then a tank when the budget reached 30, and three paid plane runs. *Second part: it learns, and the friendly commander follows the players.* **Learning** (`Doctrine.learn`): at the start of an encounter the commander reads the casebook's tally across runs (`TacticsTally`, user://): each move judged 10 times or more lifts or lowers the parts that make it (`MOVE_PARTS`: flank the flankers, rush and advance the attackers, melee, detonate, grenade, hold, suppress and trade theirs) by its mean reward -- +30 is x1.33, and x0.75..x1.33 at most -- one more answer inside the same clamp; gates do not load the tally. **The friendly commander** (`Commander.intent`, a `PlayerIntent`): the player gives it no orders (R13), so it reads them -- the FOCUS is the enemy a player shot at in the last 8 s, else where a player's mech was sent to attack, else where the players are heading (4 s on at their pace), else where they stand; a player's LANE is the line from its eye along its look, 60 m out, 3.5 m wide. Its squads go *beside* the players on the way (MOVE) and, with an enemy in hand, bound (ADVANCE with the order's new `to_point`, so `BTPlayAdvance` bounds to the point, suppressing the enemy, done when the whole squad is there) first *out to the side* of the line from the players to the fight, then to the fight's *flank*, square to that line -- never to a place in a lane. Its soldiers do not close (push, rush, melee, detonate) on an enemy in a lane -- they flank instead (`BTChooseTactic`, `AIServices.lanes`) -- and their own flank, push, screen and sidestep spots skip lanes. In the arena `--allies` gives the player's side such a commander, fielding friendly squads behind the player (8-20 m out, on ground at its level), with a 10 s log line of how many are near and how many in a lane. **Not yet:** a path between two safe places can still cross a lane (the walking map does not know them); a lane that sweeps after an enemy walking round the player crosses whoever is there; friendly mechs and air; co-op is read as the nearest player; §8's "marksmen against the careful player" is left out, as AIPlan P9's gate wants marksmen to be the demolisher's answer | `commander_probe` (39 checks, 9 new): a recipe named nowhere is fielded; hunters against the careful player and anti-armour and rodeo against the mech, by parts; air against a demolisher and a tank against a mech; squads on foot only; a tank bought with points, one at a time, never without the points; air from the roster's flyers; left to itself it buys air up to its cap; a plane run needs its points. `threat_style_probe` (7). `ally_probe` (13): the tally lifts flankers and lowers attackers, a move judged too seldom teaches nothing, the clamp holds; the focus is the enemy shot at, else the mech's attack point, else where the player walks; lanes; support points beside the player and out of every lane, one squad each side; in an arena the friendly squad goes out to the side and then to the flank of what the player shoots at, never sent into a lane and 0-0.3 % of its member-ticks in one (42 % before the out-to-the-side leg and the soldiers' lane rules). |

RO6 is the mech's own damage model: it touches the mech (`scripts/mech/`) and the weapons'
damage rules, so it is agreed with those areas before it starts.

## 10. Open questions

1. The numbers in §2.2, §2.3, §4.1, §4.6 and §4.7 are first guesses: to be played and changed.
2. Whether a non-boss phase may change the body.
