# AI roster — putting enemy and friendly types together (plan)

**Status: 2026-10-06. A plan. Nothing here is built except what a section names as existing.**

How every thing that fights is described and assembled: soldiers, creatures, flyers, mechs,
trucks, tanks, helicopters, planes -- enemy and friendly. Read first:
[AI.md](AI.md) (§5.2 archetypes, §6.4 mechs, §8 aggro, §9 the commander, §10.2 who is smart),
[AIVehicles.md](AIVehicles.md), [Tactics/README.md](Tactics/README.md) (the casebook, which
decides what an agent does).

---

## 0. Decided

| # | Decision |
|---|---|
| R1 | A type is a **recipe** of independent parts -- body, class, grade, attack, role, mods, phases -- not a hand-written class. "Very light bomber cannon-fodder flyer" is five words of data. |
| R2 | **Classes: light, medium, heavy, strong**, for every body. Each class has **three grades**. (Grade names proposed here: weak / regular / tough, so "light" and "strong" do not each mean two things. The user's words were light / regular / strong.) |
| R3 | **Size decides where it fits.** People go into buildings. A walking mech goes only into a damaged building, or damages one to get in. |
| R4 | **Attack** is its own part (melee, shooter, bomber...). **Role** is another part on top (defender, leader, attacker, cannon fodder...). |
| R5 | **Phases.** An enemy can change attack, role or body when something happens: a shooter that loses its armour or shield goes berserk and melees (Halo's brute); a second phase can turn it into a flyer or a bomber. |
| R6 | **Mechs: three classes** (light, medium, heavy). The hatch is at the **front** on medium and heavy and at the **back** on light. The hatch can be **broken off**, exposing the pilot; the AI knows when it is. |
| R7 | **Rodeo.** A player on foot can climb an enemy mech and blow its hatch off. Enemies can rodeo a player's mech, but only a type built for it. |
| R8 | **A mech keeps its own aggro** when its pilot gets out. The enemy mech stays on the player's mech while the pilot goes round on foot. |
| R9 | **Two kinds of aircraft.** Hover craft (Halo's banshee): slow, stays in an area, slow attacks. Fast planes: strafing and bombing runs. |
| R10 | **Friendlies use every system here**: the same recipes, brains, casebook and commander. |
| R11 | **A commander runs each side.** The friendly one also takes its lead from what the players are doing. |

---

## 1. The recipe

```
gnat:
  body:   flyer
  class:  light        grade: weak
  attack: bomber
  role:   fodder
  mods:   []
  phases: []
```

From those lines the game works out, and nobody writes by hand:

| Derived | From |
|---|---|
| Mover and navigation map | body, and the class's size |
| Health layers, speed, weight | class x grade (and mods: shielded, armoured) |
| Weapon | attack (+ class: a heavy shooter carries a heavier gun) |
| Brain tier (smart / directed / swarm, AI.md §10.2) | role (fodder is never smart), then the importance budget |
| Casebook facts (`we_flyer`, `we_bomber`, `we_fodder`) | body, attack, role -- so the casebook's curves and odds apply |
| Aggro: how loud it is, whom it prefers | class, role, attack (§6) |
| Points for the commander | all of the above, by formula (§8) |

A recipe is checked when loaded: a combination that cannot work (a mech "fodder swarm", a
bomber with a sniper's role) is refused with the reason, not fielded broken.

## 2. The parts

### 2.1 Body: how it moves

| Body | Navigation | Exists |
|---|---|---|
| walker | AINav, with the class's agent profile (width, head room, step, drop) | soldiers; animals; the mech map (AIPlan P7) |
| flyer | the flyer height field | `Flyer` (P8) |
| wheeled / tracked | a vehicle map with clearance; tracked crushes what wheels cannot cross | the truck drives the foot map (AIVehicles.md) |
| hover craft | the flyer height field, with a loiter area | no |
| fast plane | none: a scripted run along a line (§7) | no |
| boat | the sea's surface | no |

"Walker" covers a person and a walking mech alike. What differs is the class: its size picks
the agent profile, so the same pathfinding sends a person through a door and a mech round the
building -- or through a hole it makes (R3; breach links and the fall rule exist, AIPlan P7).

### 2.2 Class and grade

Class is size and weight; grade is how tough within the class. To be given numbers:

| Class | Walker example | Fits | Weight on floors |
|---|---|---|---|
| light | a person | doors, stairs, rooms | light: any floor |
| medium | a big trooper, a light mech | wide doors, damaged walls | checked against headroom |
| heavy | a mech | damaged buildings, or breaks in | breaks weak floors (fall rule) |
| strong | the biggest of its body | outside, or brings the building down | does not stand on storeys |

Grade (weak / regular / tough) scales health, damage and points, not size.

### 2.3 Attack

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

### 2.4 Role

A role is a set of multipliers over the casebook's moves, plus a place in the squad:

| Role | Leans to | In the squad |
|---|---|---|
| attacker | rush, flank, push | goes first |
| defender | hold, guard the ways out, ambush | has a post and a leash: it does not chase past it |
| leader | call for help, mark, hold back | gives the orders; when it dies the squad's morale breaks |
| fodder | rush, melee, no cover | the cheap brain tier; dies in numbers |
| flanker / hunter | flank, search, goes for the pilot | works alone |
| scout | scout first, mark, fall back | finds, does not fight |

### 2.5 Mods

Shielded, armoured, explodes on death, jetpack, cloaked, carries others, **rodeo** (may climb a
player's mech, R7), heavy weapon. Each is a small, separate piece.

### 2.6 Temper and senses

Temper: how soon it falls back, whether it ever runs, surrenders or fights to the end. Senses:
sight range and cone, hearing -- a creature can be blind and hear well. Both are recipe lines
with defaults by role.

### 2.7 Phases (R5)

```
brute:
  body: walker   class: heavy   grade: regular   attack: shooter   role: attacker
  mods: [armoured]
  phases:
    - when: armour_gone
      become: {attack: melee, role: attacker, temper: berserk}
```

A phase is "when X, these parts change". Triggers: armour gone, shield gone, health under a
share, leader dead, alone, hatch broken, a time. What may change: attack, role, temper, mods,
and body (a second phase that takes off). On a change the game re-derives the weapon, the mover
and the casebook facts; the brain tree stays, because what it does comes from the casebook.

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
aim for the hatch, climb on, shake a rider off, orbit, attack run), mech and aircraft moments,
and a **Roster** tab on the page where a recipe is put together from the parts.

## 4. Mechs

Three classes (R6). A mech's brain is its own tree (it exists, AIPlan P7), deciding from the
casebook's mech section.

### 4.1 The hatch

| Class | Hatch | To get in or out | Its weak side |
|---|---|---|---|
| light | back | from behind | its back |
| medium, heavy | front | from the front | its front |

States: **intact -> damaged -> off**. With the hatch off the pilot can be shot directly.
New facts: our hatch is off; their hatch is off; their hatch side is in sight. New amount:
hatch health.

### 4.2 An AI mech whose hatch is off

It protects the pilot by keeping the hatch side away from the threat:

- **light** (hatch behind): keeps facing the enemy, backs up to a wall, does not turn to run.
- **medium / heavy** (hatch in front): cannot face the enemy without showing the pilot -- it
  turns side-on, backs into cover, has its infantry screen it, or the pilot bails out and the
  mech fights on empty.

Its escort changes too: "screen our armour" becomes "cover the pilot".

### 4.3 Attacking a hatch

Enemies aim for the hatch side: round the back of a light mech, the front of the others. Once
a player's hatch is off, the pilot inside becomes a target of its own (§6).

### 4.4 Getting in and out

An AI pilot paths to the hatch side to mount -- behind a light mech, in front of the others --
and needs that spot clear. Empty mechs are things on the map: an enemy pilot can run for one;
a friendly AI pilot uses the same rules (R10).

### 4.5 Rodeo (R7)

- **The player on an enemy mech:** get to it unseen, climb on, blow the hatch off, then the pilot.
  The mech's answers, from the casebook: shake the rider off, back into a wall, call its escort
  to shoot the rider (carefully -- they are shooting at their own mech), or the pilot bails out.
- **An enemy on the player's mech:** only a type with the rodeo mod. It is called out and shown
  on the HUD, and the player has counters (a shake, the hatch, a teammate, getting out).

## 5. The loop this is all for (R8)

1. The player's mech goes in loud. It takes the enemy's attention, the enemy mech's most of all.
2. The player gets out. The mech keeps fighting by itself (`MechCommand`: follow, hold, attack
   an area) and **keeps its own aggro** -- it is its own row in the table.
3. The enemy mech stays on the player's mech. The pilot goes round on foot, unseen.
4. The pilot climbs the enemy mech and blows the hatch. Its pilot is exposed.
5. Now the enemy has to choose: turn on the rider, protect the pilot, or bail out.

## 6. Aggro

**Exists** (`AggroTable`, AI.md §8): one table per enemy side with a row per pilot and a row
per mech; it grows with damage, noise, being seen and being near, halves every 8 s, moves only
when another row leads by a margin, feeds who gets shot at, and shows as a meter. The
commander can lean it towards the pilot (`pilot_focus`).

**To add:**

| # | Addition | Why |
|---|---|---|
| G1 | A mech draws more for being seen and near than a pilot does, by class | so an empty mech that is still standing there holds attention, not only one that is firing |
| G2 | **Target preference** per recipe: mechs and anti-armour prefer mechs; hunters prefer pilots; bombers take the nearest; a defender ignores what is beyond its leash | so "the enemy mech stays on my mech" is a rule, not luck |
| G3 | A stronger hold for a mech on a mech: it takes more to pull it off | the same |
| G4 | An unseen pilot gains nothing; a pilot seen while a mech holds the focus gains little | sneaking round has to be possible |
| G5 | A rider: no gain until noticed, then a spike on the mech it rides and its escort | the rodeo's moment of risk |
| G6 | **Exposed pilot** as its own row once a hatch is off, weighted high | "aim for the pilot" |
| G7 | Friendly AI and their mechs get rows too | R10: they can draw fire for the player, and the reverse |
| G8 | The meter shows pilot, mech and exposed pilot | so the player can play it |

## 7. Vehicles and aircraft

[AIVehicles.md](AIVehicles.md) has the ground vehicles' plan; the truck is built in its
smallest form. In recipe terms a vehicle is a body with **seats**: driver, gunner and passengers
are agents of their own (recipes of their own) who get out when it dies.

- **Trucks, tanks, APCs:** a vehicle map with clearance; tracked ones crush; infantry screen
  them or ride them (the casebook already has both moves).
- **Helicopters:** the flyer height field, hovering, landing zones, door guns; can fire in
  through a window when it can hover level with the floor.
- **Hover craft (R9):** a flyer agent with a loiter area -- it stays near, circles, makes slow
  attack passes, can be shot down. A full agent, deciding from the casebook's aircraft section.
- **Fast planes (R9):** not agents. The commander buys a **run**: a line across the map, a
  warning (sound, a callout), strafing or bombs along the line, gone. It can be shot at on the
  pass. No navigation, no brain.

## 8. The commander (R11)

**Exists** (AI.md §9.1): one per side, a points budget, a doctrine that shifts with how the
player fights (`ThreatProfile`: demolisher or careful, mech kills or pilot kills), squads and
orders, an HQ, a friendly side that keeps its squad with the player.

**To add:**

- It **buys recipes**. Points come from the recipe by formula, so any combination has a price.
- Its doctrine chooses along the parts: against a player who lives in their mech, more
  anti-armour and rodeo types; against a careful pilot on foot, hunters and marksmen; against
  a demolisher, fewer troops indoors. (The clamps stay: no counter is a hard counter.)
- It reads the tally of what worked (`TacticsTally`) across encounters, as it reads the threat
  profile.
- **The friendly commander** takes its lead from the players: where they go and what they
  shoot at, the mech button (follow / hold / attack there), and -- to be decided -- an explicit
  ping. It sends friendly squads to support that, never in front of the player's gun.

## 9. Order of work

Each step ends in a gate, as AIPlan's phases do.

| Step | What | Shows |
|---|---|---|
| RO1 | Recipes as data, derived values, the validity check; today's five infantry units written as recipes; the Roster tab on the casebook page | no change in behaviour |
| RO2 | Class and grade: sizes, agent profiles, weight, where each fits | a medium walker that cannot use a door a light one can |
| RO3 | Attack types and roles as casebook facts; a melee type, a bomber, a grenadier; a leader whose death breaks the squad; fodder on the cheap tier | "very light bomber fodder" fights |
| RO4 | Phases | the brute loses its armour and charges |
| RO5 | Mover, Senses and Arsenal lifted out of `Soldier`; flyers and creatures decide from the casebook | a flying bomber is the same recipe with a different body |
| RO6 | The hatch: states, damage, facts; AI protects and attacks it; aggro G1-G4, G6, G8 | the §5 loop up to step 3 |
| RO7 | Mounting and dismounting for AI pilots; rodeo for the player, then the rodeo mod | the §5 loop whole |
| RO8 | Hover craft; fast-plane runs | both in the arena |
| RO9 | Crewed vehicles (AIVehicles.md's steps) | a tank with a squad screening it |
| RO10 | The commander buys recipes by points and doctrine; the friendly commander follows the players | a wave that answers how you play |

## 10. Open questions

1. Grade names (weak / regular / tough?), and the numbers for each class: size, health, speed.
2. What the "strong" class is for a walker: the same size as heavy but tougher, or bigger still?
3. Rodeo: what blows the hatch (a charge, a few seconds held on), and what the player's
   counters are when it is done to them.
4. Does the friendly commander get explicit orders from the player (a ping), or only infer?
5. Which vehicles the player can drive.
6. How many phases at most (two?), and whether a phase may change the body for anything but
   bosses.
