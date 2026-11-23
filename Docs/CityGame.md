# City Game: a brick Robin Hood open world

A design direction for an open-world city mode: Saints Row: The Third's arcade freedom, Fast &
Furious's crew and car tone, in a brick city that is shot apart and rebuilt. Teen-rated (ESRB T /
PEGI 12). Written 2026-11-22 from a research chat; nothing here is built yet. Decisions the user
has made are marked **Decided**; the rest are proposals.

Related: [Structures.md](Structures.md) (buildings, storeys), [Hulls.md §9](Hulls.md#9-repair-two-front-ends-one-core)
(restore core the rebuild reuses), [AI.md](AI.md), [Reference/mvs-c.md §6](Reference/mvs-c.md#6-ai-squads-and-the-wanted-system)
(the wanted system model), [Inventory.md](Inventory.md), [Multiplayer.md](Multiplayer.md).

---

## 1. What we take from whom

### 1.1 Saints Row: The Third (2011) -- why people like it

From reviews and fan write-ups (sources at the end):

| What players praise | What it means for us |
|---|---|
| Never serious; "the Saturday-morning-cartoon GTA IV" | Comic tone, toy world. Bricks already say "toy". |
| **Notoriety** is forgiving: chaos is allowed, escape is easy | Heat (§4) rises fast and falls fast. Escaping is a game, not a punishment. |
| Arcade shooting and driving, more playable than GTA IV | Snappy guns (the weapons area's arcade feel), loose car handling. |
| Progression removes chores: no fall damage, unlimited sprint, infinite ammo late on | Perks that remove friction, so the game gets *more* fun, not harder. |
| Deep customisation: character, cars, crew, hideouts | Bricks make this native: cars and hideouts are builds. |
| Short repeatable activities (Mayhem, Insurance Fraud, Heli Assault) | Every district has a few 2-5 minute chaos loops (§6). |
| Criticised: flat generic city, lost depth from SR2, looks worse than GTA IV | The city must be varied (handmade buildings, Structures.md); destruction is our depth. |

### 1.2 GTA IV, V, VI -- what we do *not* copy

GTA IV is the closest comparison and the opposite pole: heavy realistic car physics, grim tone,
punishing wanted system. GTA V is satire on a grounded base; GTA VI (Nov 2026) pushes realism and
crowd density further. We keep only GTA IV's **weight**: crashes and collapses that feel physical.
Brick physics gives that crunch without the realism.

### 1.3 Fast & Furious -- the tone

**Decided:** Fast & Furious, not Ocean's 11. Car-first, a crew that is family, stealing from people
worse than you, stunts bigger than physics allows, PG-13. Missions are **short**: hit, smash,
chase, done. No long planning phases, no elaborate heist setup.

### 1.4 Is anything like this out there?

Nobody has shipped **brick city + shooting with real destruction + a city that rebuilds itself**.

| Game | Has | Lacks |
|---|---|---|
| LEGO City Undercover (2013/2017) | Open brick city, missions, cars, family rating | Almost no destruction; more platformer than shooter |
| Brick Rigs | Brick vehicles, destruction, GTA-RP servers | No city life or missions |
| LEGO Worlds | Brick worlds, weapons that break creations | No GTA structure |
| Teardown | Best destruction (voxels), heist missions | Not bricks, not open world, no city life |
| Mercenaries: Playground of Destruction (2005) | Open world, blow up buildings, T-rated | Not bricks, nothing rebuilds |
| The Simpsons: Hit & Run (2003) | Cartoon GTA, police chases, T-rated | No destruction |

Every game with destruction leaves the damage there for good (Red Faction, Teardown) or barely has
any (GTA). **Rebuilding is ours.**

---

## 2. The core loop

**Decided:** the player is a Robin Hood. They raid villain hideouts, wreck them, take cash and
jewellery, and spend it rebuilding the community. Gangs attack the rebuilds.

```
  hit a hideout ──> loot (cash, jewellery) ──> heat rises, police coming ──> escape by car
        ^                                                                          │
        │                                                                          v
  district flips <── defend the rebuild from the gang <── fund a community rebuild
```

1. **Hit.** Find a gang hideout (a handmade building), shoot through the gang, smash walls and
   floors to reach the safe or vault. Destruction is the reward and the route.
2. **Loot.** Cash bags and jewellery are carried items (Inventory.md). Carrying loot slows you a
   little and drops some when you are knocked down: a reason to drive, not dawdle.
3. **Leave.** Fighting raises heat (§4). Police arrive; that is the cue to go.
4. **Escape.** A chase: alleys, jumps, garages, car swaps. Lose the heat, then the loot is banked.
5. **Rebuild.** Banked money funds a **community project** in a damaged block: a park, a shop row,
   housing, a clinic. The crew rebuilds it storey by storey (§5).
6. **Defend.** While the site is up, the gang strikes back (§6, "Defend the build").
7. **Flip.** A finished project raises the district's **standing**: cheaper gear, safe houses,
   neighbours who warn you of gangs and hide your car, a faster repair crew.

The gang loses hideouts, you gain districts. The city map turns over district by district.

---

## 3. The world

* **The city** is the brick city we have: handmade buildings, rooms, furniture (Structures.md,
  RoomModules.md, the asset placer). Districts each have a gang, a look and a few landmarks.
* **Gangs** are the villains: each has a boss, a colour, hideouts, vehicles, a trademark (mechs,
  drones, tuned cars). Bosses are crooks with comic schemes, not realistic cartels.
* **Civilians** live in the city and are never targets (§7).
* **Police** are a force of nature: they show up, they push you out, they are not an enemy
  you are meant to fight (§4).
* **Camera:** first person by default (the arms already exist, viewmodel-arms); a third-person
  camera for driving and maybe on foot as an option. Undecided.
* **Brick-built cars** are content like any build, so the player's garage is customisation for free.

---

## 4. Heat: police show up, and it is time to leave

**Decided:** the player *can* shoot police, but it is always a bad idea. The game's rhythm is
"shoot the gang; police arrive; leave".

Built on the wanted model in Reference/mvs-c.md §6 (witnesses, ceilings, responders arriving off
screen, not saved).

### 4.1 What raises heat

| Act | Heat | Notes |
|---|---|---|
| Shooting gang members, wrecking a hideout | slow, steady | Police are *coming*, not chasing yet. A timer the player can read. |
| Driving wild, smashing street props | small, capped | Ceiling like mvs-c's brandishing: never builds past 1. |
| Hurting a civilian | large | Always a loss (§7). |
| **Shooting police** | very large, immediate | Jumps straight to pursuit and climbs fast. |

### 4.2 Escalation

1. **Sirens:** two cars head for you. Leaving now is easy.
2. **Pursuit:** cars, roadblocks, spike strips.
3. **Tactical:** armoured vans, a helicopter, net launchers.
4. **Heavy:** an armoured police mech (our mech work), only if the player keeps fighting police.

Police gear is **non-lethal**: stun guns, nets, foam, spike strips. Being caught means "busted":
lose the loot you carry and some cash, wake up at a safe house. No death screen from police.

### 4.3 Why shooting police never pays

* No money, items or progress from police, ever.
* Heat climbs faster than from anything else, straight to tactical.
* Loot carried takes a cut ("evidence").
* District standing drops: repair crews slow down, neighbours stop helping.

### 4.4 Losing heat

Out of sight long enough, a garage or car swap, a paint shop, a friendly district hiding you.
Heat falls fast once you are clear, as in Saints Row: escape is the fun part, not a chore.

---

## 5. The rebuild

Damage in the city does not stay. Damaged buildings are fenced off, then a crew rebuilds them.
**What it rebuilds to** is the building's recipe: "the recipe minus what is there" (Hulls.md §9).

### 5.1 What the player sees

1. **Fenced off.** Within a few seconds of a hit, the damaged part is closed: tape, cones, brick
   barriers. A collapsed building gets a site fence round it.
2. **Crew arrives.** NPC workers in a truck; a crane and scaffolding for a big building.
3. **Grows back storey by storey.** For a collapse, the ground storey first, then each storey up,
   like the ship rebuild in planet.tscn. A storey grows behind scaffold sheeting and the sheeting
   comes off finished. The player sees a building growing, not bricks popping.
4. **Opened.** The fence comes away; the building is whole and usable again.

The brick-by-brick part is hidden (behind sheeting, or while nobody is looking), so it can be as
cheap or as exact as the engine needs.

### 5.2 What it uses (already built)

* **`BrickWorld.revive_blocks`** brings blocks back in their own cells with their ids, so the
  damage record and collision hold (Hulls.md §9.1).
* **`DamageLog.Kind.RESTORE`** makes a restore a recorded command: deterministic, networked.
* **Rim first:** `restorable` lists lost bricks nearest a still-standing brick first, so a hole
  closes from its edge. For a collapse we want the opposite order -- **bottom storey first** --
  a sort by height then rim.
* **Storey units** (storey-units, Structures.md): a building is cut into storeys and 3D tiles;
  a storey is the rebuild's step, a tile under sheeting the unit that pops in.
* **Open:** bricks that left on falling pieces come back as new bricks; the rubble must be cleared
  (trucks haul it, or it fades while the fence is up).

### 5.3 Two kinds of rebuild

| Kind | Who pays | Speed | Player's part |
|---|---|---|---|
| **City repair** (any damage) | The city | Slow, in the background | None; it just happens. Gang hideouts the player wrecked come back too, unless the district flipped. |
| **Community project** (§2 step 5) | The player's loot | A few minutes, on screen | Funds it, watches it, defends it, gets the district standing. |

A flipped district's hideout does **not** come back as a hideout: it is rebuilt as something for
the community, chosen by the player from a short list. This is the visible proof the player is
changing the city.

---

## 6. Mission types

Short, replayable, every one ends in destruction or a chase. Fast & Furious: hit, smash, chase.

| Mission | Shape | Theft or crime, framed for T |
|---|---|---|
| **Hideout raid** | Clear a gang building, break to the safe, carry loot out, escape. | Stealing from criminals. |
| **Jewel run** | A gang's stash moves by armoured car; ram it, crack it, run. | Taking back stolen goods. |
| **Car snatch** | Steal a gang boss's tuned car or prototype from a guarded garage, outrun the gang. | Car theft from a villain; Fast & Furious's whole first act. |
| **Repo** | Take back a vehicle the gang stole from a neighbour: a truck, a mech, a bus. | Returning property. |
| **Defend the build** | A rebuild is up; the gang attacks in waves (cars, drones, a mech). Keep the crew working; a lost crane or storey sets it back. | No crime. |
| **Demolition contract** | The city pays you to flatten a condemned block in a time limit. Saints Row's Mayhem, legally. | No crime. Shows off the destruction. |
| **Bounty** | Track a crook through the city, ram their car, bring them in. | Helping the law. |
| **Getaway** | A crewmate needs pulling out of a hot spot; you drive. | Escaping, not robbing. |

### 6.1 Activities (open-world, 2-5 minutes)

* **Mayhem:** score by damage done in a district, in a time limit.
* **Stunt jumps and races** through damaged streets (a rebuild in progress changes the route).
* **Ragdoll run** (Saints Row's Insurance Fraud, but harmless): throw your brick figure in front of
  traffic for points; figures pop apart and click back together.
* **Arena fights:** mech or crew fights in a gang's yard.
* **Delivery rush:** carry building supplies to a site across a district while the gang tries to
  stop you; arriving speeds the rebuild.

### 6.2 Progression (from Saints Row)

Perks bought with cash and standing that **remove chores**: no fall damage, longer sprint, more ammo,
faster loot carry, a faster crew, cheaper rebuilds, shorter heat. By the end the player is nearly
a superhero; the game gets more fun as it goes.

---

## 7. Staying teen-rated

Ratings judge **what is shown**: blood, how realistic the people and their hurt look, language,
drugs, sex. Being *able* to shoot police does not by itself make a game M; shooting realistic
people with blood does. The Simpsons: Hit & Run (police chases, you can fight back) and Mercenaries
(open-world shooting and blown-up buildings) were both T. LEGO games with brawling and blasters are
E10+.

### 7.1 Rules

* **No blood, no gore.** A hit figure breaks into bricks and is out of the fight; out of combat it
  can click back together. Nothing lies around hurt.
* **Toy look stays.** Brick figures, bright colours. Realistic police uniforms, real-world gun
  models and realistic ragdolls are the risk that would push it to M. The look is what keeps T.
* **Enemies are mostly gang members in gear, drones, robots, mechs.** Robots and mechs can be
  blown up freely.
* **Civilians are never targets.** They panic and run. Hurting one costs heat, cash and standing
  and gives nothing.
* **Police are non-lethal and a force of nature** (§4).
* **Theft is always from villains** or taking back what they took (§6).
* **Language:** mild only. **Humour:** crude is fine, sexual is not. **No drugs or alcohol**
  as content or jokes.

### 7.2 How a rating would be got

Digital-only stores (Steam does not require one; console and other stores use **IARC**, a
questionnaire that gives ESRB, PEGI and the rest at once). The answers that matter: violence
against human-like characters (yes, cartoon, no blood), against police (possible, not rewarded),
civilians (possible, punished), theft (yes, from criminals). Expect **ESRB T, PEGI 12**; PEGI 16
if the figures read as realistic people.

---

## 8. What we have, what we need

| Have (built) | Need |
|---|---|
| Brick city, handmade buildings, destruction, storey units | District/gang ownership of buildings; hideout markup (safe, loot spots) |
| Restore core: revive, RESTORE command, rim-first (Hulls.md §9) | Storey-first rebuild order; scaffolding and sheeting; fence-off |
| AI squads, tactics casebook, vehicles (AI.md, AIVehicles.md) | Gang squads, repair crews, police responders; a heat manager |
| Weapons, arcade feel, inventory, carried items | Loot items (cash, jewellery), drop on knock-down; police non-lethal gear |
| Brick cars, mechs, tanks | City driving tuned arcade; car swap and garage |
| Model-to-brick converter, asset workshop | Content: gangs, cars, hideouts, community buildings |
| First-person arms | Third-person camera (if decided) |

### 8.1 Suggested first stages

1. **Heat** (§4) on the city scene: witnesses, escalation, responders, busted, losing heat.
2. **Fence and rebuild** (§5): a damaged building fenced, restored storey by storey under sheeting.
3. **One hideout raid** end to end: gang, loot, heat, escape, banked.
4. **One community project** with "defend the build".
5. Then the district map, standing, perks, activities.

---

## 9. Open questions (the user decides)

* First person only, or a third-person option on foot? Third person for driving?
* Single player first, or co-op crew from the start (Multiplayer.md)?
* One city or several districts across a planet (Planets.md)?
* Does the player's crew have named characters (Fast & Furious family), or is it generic?
* Can a player rebuild *their own* designs on a community plot (workshop builds)?

---

## Sources (research, 2026-11-22)

* [GameSpot user review](https://www.gamespot.com/saints-row-the-third/user-reviews/2200-584794/)
* [Giant Bomb: Over the Top](https://giantbomb.com/saints-row-the-third/3030-25725/user-reviews/2200-22690/)
* [Felix Online: Side by side with the Saints](https://felixonline.co.uk/articles/2011-11-17-side-by-side-with-the-saints/)
* [WhatCulture: Why Saints Row is better than GTA](https://whatculture.com/gaming/why-saints-row-is-better-than-gta?page=2)
* [Sportskeeda: GTA vs Saints Row](https://sportskeeda.com/gta/gta-vs-saints-row-5-things-made-gta-franchise-successful)
* [GamesRadar: Brick Rigs](https://gamesradar.com/after-8-years-this-bizarre-lego-meets-gta-rp-destruction-sandbox-is-now-technically-one-of-2023s-highest-rated-releases)
* [Kotaku: LEGO City Undercover is basically GTA](https://kotaku.com/lego-city-undercover-is-basically-grand-theft-auto-with-5916564)
* [GamesBeat: LEGO City Undercover is GTA for kids](https://gamesbeat.com/lego-city-undercover-review)
* [Game Informer: sandbox games don't have to be gritty](https://gameinformer.com/games/lego_city_undercover/b/wii_u/archive/2013/03/14/proof-that-sandbox-games-dont-have-to-be-gritty)
* [Teardown on Steam](https://store.steampowered.com/app/1167630/Teardown/)
* Ratings of The Simpsons: Hit & Run, Mercenaries and the LEGO games: from memory, check on
  esrb.org before relying on them.
