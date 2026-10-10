# AI vehicles and mechs — plan

**Status: 2026-10-10. Step 1 is built in its smallest form, and step 3's tank in its first
part (AIRoster.md RO10: crewed seats, a cannon that opens walls, armour, the player can drive
it, infantry screen it, it crushes low walls). The vehicle map (§3) is built for wheels and
tracks, riding on and boarding vehicles (§4.1, after Halo) and seats for the truck and the
tank, and both have brick bodies in damage zones (§4.2); the rest is planned.**
The commander can name, cost and weigh every vehicle below (`UnitCatalog`), so the budget, the
doctrine and the save format know them before each one drives; only the truck and the tank
have `built = true` -- the tank a commander buys as support (AIRoster.md RO11), and the arena
(`--tank`) and the city (Z) field one free.

**What step 1 is today** (`scripts/ai/vehicles/transport_truck.gd`): a kinematic body with health
that asks for one path and drives it (9 m/s, 1.6 rad/s turns, slower through a sharp one). What it
carries is **cargo** -- the unit kinds the commander bought -- not bodies in seats (its open bed
takes riders, §4.1, but the commander's squads still ride as cargo): at the drop
(within 22 m of where it was sent, the end of its path, or stuck 3 s) the host puts the squad
down at the tailgate, on the side away from the threat. Shot to pieces on the way, its squad is
lost with it. The commander buys "a squad by truck" as often as its doctrine's `truck_share`
says (0.4; more against a sniper, less against a demolisher). It drives the vehicle map (§3),
and the arena picks its start from where that map has a road to the fight. The player can
drive one, ride in its bed, and hijack an enemy's (§4.1). Its body is bricks in damage zones
(§4.2): its engine shot out, it stops and lets its squad out there. Not yet: moving cover. Read [AI.md](AI.md) first
(§3.6 navigation per way of moving, §6.4 mechs, §9 the commander) and [AIPlan.md](AIPlan.md) P7.

Prior art: Red Dawn (`C:\Users\lbaun\Documents\reddawn`) has six vehicle types and a
`VehicleSquadCoordinator` that links one vehicle to one infantry squad. Its structure is the one
to copy; its failure modes (below) are the ones to avoid.

---

## 1. What Red Dawn had, and what to keep

| Red Dawn | Keep | Change |
|---|---|---|
| `VehicleRole` TRANSPORT, APC, HEAVY_ARMOR, IFV, AIR_SUPPORT, AIR_TRANSPORT | The roles, as `UnitCatalog.role` | Add WATER_TRANSPORT, FIRE_SUPPORT (gunboat), AIR_STRIKE (plane), MECH |
| `VehicleSquadCoordinator`: one vehicle ↔ one squad; dismount, screen, moving cover, morale cascade on the vehicle's loss | All of it, as a **mounted squad**: the vehicle is a member of the squad with a role, not a coordinator beside it | Orders and Reports (SquadMsg), not signals and node references |
| Vehicle AI: patrol a `Path3D`, chase inside a detection radius, stop and deploy troops | Deploy as a squad play (`dismount`) | No `Path3D`: routes come from the vehicle map (§3); no detection sphere: the side's knowledge (AI.md 4.2) |
| Tanks/IFV/helis as `CharacterBody3D` with differential tracks; jeep/APC as `VehicleBody3D` | Two motors: **wheeled** (`VehicleBody3D`) and **tracked/legged** (kinematic) | Every vehicle is **built of bricks** on the grid, like a mech (P7) — it breaks like everything else |
| Damage zones by colour (engine red, fuel yellow, tracks cyan, explosive orange); trophy/APS; engine → ammo → turret chains | Zones as **brick groups** in the vehicle's chunk, each with a function; losing the group loses the function | The chain is the bricks: an ammo rack that is shot through detonates, an engine block that is gone stops the wheels |
| Commander points: jeep 3, APC 12, IFV 15, tank 20, attack heli 18, transport heli 10 | These numbers (`UnitCatalog`) | Add truck 4, patrol boat 6, gunboat 10, strike plane 16, mech 25 |
| Win flags: all armour destroyed | — | Our encounters end on objectives; armour is what the commander spends, not a checklist |

Why Red Dawn's vehicles never fully joined the fight (from the code): the coordinator held node
references and polled; infantry cover positions round a vehicle were raycast every update;
vehicle AI and squad AI were separate trees that talked through signals nobody answered. Here a
vehicle is a squad member, its cover is AIWorld's (a vehicle's bricks are bricks), and its
orders are the squad's.

---

## 2. Units

| Unit | Mobility | Role | Seats | What it does in a fight |
|---|---|---|---|---|
| Jeep, truck | wheeled | transport | 4 / 8 | Brings a squad fast; not cover. Dismount at a distance, drive off |
| APC | wheeled | apc | 8 | Brings a squad under armour; parks as **moving cover**, infantry advance in its lee |
| IFV | tracked | ifv | 6 | APC plus a cannon: suppresses while its squad bounds |
| Tank | tracked | heavy_armor | — | Fire support; **infantry screens it** from rocket-carriers; its gun opens walls (a breach for its squad — AI.md 3.8) |
| Transport helicopter | air | air_transport | 8 | Inserts a squad on a roof or a street; door gunner |
| Attack helicopter | air | air_support | — | Gun runs on what the side has in sight; the commander's answer to a player on a roof |
| Strike plane | air | air_strike | — | One pass on a marked point; a building brought down on a player who will not move |
| Patrol boat, gunboat | water | transport / fire support | 6 / 2 | The sea's side of the city (Docs/Water.md): landings, and fire from the water |
| Mech (enemy) | mech | heavy_armor | — | AI.md 6.4: takes the building away when infantry hide in it |

---

## 3. Navigation: one map per way of moving (AI.md 3.6)

| Mobility | Map | From |
|---|---|---|
| foot | `AINav` columns (today) | the bricks |
| wheeled | **vehicle map**: the same column read, with clearance (width, height), a max step of one plate and no stairs; roads cheap, rubble dear, anything over its ground clearance impassable | the bricks and the terrain field |
| tracked | as wheeled, but rubble and low walls are passable at a cost — **it crushes them** (the crush is a command through the authority, so co-op agrees) | same |
| mech | mech map with clearance and breach links (P7) | same |
| air | flyer **height field**: the top of everything per column, plus a margin; routes are 2D over it | AIWorld's `top_at` |
| water | the sea's surface where it is deeper than draught; shores and quays as landing points | `TerrainWorld.sea_level`, the field |

Shared as AI.md 4.3 says: **the vehicle paths, its squad rides** — a mounted squad asks for no
paths at all. Flow fields for many vehicles to one place, later.

**Built (wheeled and tracked, 2026-10-10): `VehicleNav`.** Not a new map but the walking map's
machinery told a vehicle's numbers, as the mech map is (`AINav.set_agent`): the footprint is
the vehicle's width plus a hand each side (`MARGIN`), square -- a truck 8 studs (2.8 m), a tank
10 (3.5 m) -- the air it needs its height (a truck 18 plates, a tank 21), the step a kerb for a
truck (2 plates) and a brick course for a tank (3), the drop a kerb's worth. So a path only goes
where the whole vehicle fits between walls and under roofs, a staircase is no road for a truck,
and a hole blown in a wall is a road the moment it is wide enough -- nothing is baked; the
walking map's `nav_changed` invalidates it. One per kind, made on first use by
`AIServices.vehicle_nav(kind)` and served in its tick with the other sizes' maps.
`VehicleNav.reach_point` is the nearest place to a goal a vehicle fits (a goal down an alley:
beside it or at its mouth). `TankBrain` and `TransportTruck` path on it to that point, and fall
back to the walking map when it has no road (`road` says which). The arena chooses a truck's
start with one flow field outward from the fight on the truck's map, in place of a foot path per
candidate checked for width (the checks it replaced, `route_wide` and its kin, are gone). The
city's narrowest street is 9 studs (3.15 m): a truck fits, a tank does not, and goes round.
**Crushing (built, 2026-10-10).** The tank's map is told to crush (`AINav.set_crush`, in C++):
a run of bricks standing on the ground over its step and no higher than `Tank.CRUSH_PLATES` (9,
three courses, 1.26 m) -- a garden wall, a barricade, a heap of rubble -- is a floor at its foot,
a way through for 4 m more than the road beside it, so a tank goes through a low wall where a
truck goes round (and round a five-course one, like the truck). The tank does it as it drives
(`Tank._crush`): bricks or rubble in the slab across its nose up to that height, and nothing
over it up to its own, are worn off a row at a time, edge to edge, every 0.25 s -- a PLA brick
at a pass, stone in three, metal in four -- as a gun's hit is, through the city's structure hit
(`chip`, through the authority), so co-op agrees. Not yet: rubble dearer than road for wheels;
the mech, air and water maps of the table. Probes: `vehicle_nav_probe` (15),
`vehicle_bricks_probe` (G, H).

---

## 4. The mounted squad (the coordinator, as a squad)

A vehicle is a `Squad` member with a role (`driver`), and the squad's plays learn about it:

- **Mount / ride / dismount** — Task `MOUNT` (walk to a seat, board), `RIDE` (nothing: the body is
  carried), `DISMOUNT` (out, to a place in a ring round the vehicle's lee side). Dismount where
  the doctrine says: at a distance from the contact (transport), at contact behind the armour
  (APC), under fire (IFV suppresses first).
- **Moving cover** — the lee of an APC/IFV/tank is cover AIWorld already rates (its bricks are
  between the threat and the spot); `BTPlayAdvance` bounds into it as it moves.
- **Screen** — around a tank, members hold points on its flanks facing where rocket fire would
  come from; the aggro table (AI.md 8) says who draws the player's attention.
- **Loss cascade** — the vehicle destroyed costs the squad morale as a leader's death does.
- **Air insertion** — the transport helicopter hovers over a roof or street the survey (the
  arena's `SpawnSurvey`) has passed: it reads what the spot stands on the same way, so it never
  drops a squad onto a roof that has fallen in.

### 4.1 Driving, riding and boarding (built, after Halo)

Halo's vehicles are what this follows: anybody drives one, more ride on it and shoot their own
guns, and the other side takes it from you by jumping on. Built for the two vehicles there are
(2026-10-10); the mech's own rodeo is AIRoster.md 4.5.

| | Tank | Truck |
|---|---|---|
| **Drive** (M at it) | an empty one of any side, or ours with a seat free: the driver's if it is free -- W/S, A/D turn on the spot, and LMB cannon, RMB machine gun while no gunner of ours is in -- else the gunner's; Q switches (with one of ours in the other, they swap) | an empty one, from beside the cab: W/S throttle and brake, A/D steer, only while it rolls |
| **Camera** | behind and above, looking where the mouse looks, pulled in by walls (Halo's); C: the cupola | the same; C: the cab |
| **Ride** (M at one somebody else drives; jump or M gets off) | four on the track covers | six in the open bed |
| **Board an enemy's** (E beside it) | onto its back deck; E held 2 s pries the hatch: its crew is dragged out (20 hurt) and the player is put at the wheel. Noticed after 1 s, or at once if its side sees it: an aggro spike, as a mech's rider | its cab at once: the squad in the back is put out at the tailgate there and then, and it is the player's |

- **Riders** (`VehicleDeck`, a vehicle's `rodeo`) are carried every tick on their spot, a
  collision exception of the vehicle; they shoot their own guns at what they see -- no walking,
  no tactics -- and are put down beside the hull when they get off or it is wrecked.
- **Halo's marines:** while the player drives a vehicle of theirs and it stands still, soldiers
  of the player's side within 15 m walk to it and get on, as many as it has room for
  (`Soldier.ride_on`) -- the nearest into a tank's empty gunner's seat first, at the hatch. The
  riders get down when the player gets out: they have a fight to get back to; a gunner stays.
- **Seats** (`Tank.player_seat`): at the wheel with a gunner of theirs in, the player drives and
  the gunner shoots on its own (`TankBrain`, each seat the brain's only while a crewman is in
  it); in the gunner's seat with one of theirs at the wheel, the driver takes them to the side's
  best contact and holds off it, as a crewed tank does.
- **The enemy boards too:** a soldier with the rodeo mod (the roster's "boarder") goes for a
  hostile tank with somebody in it as it does a mech, climbs onto the deck and pries the hatch:
  a player inside is thrown out hurt, and the soldier takes the gun -- the tank turns on its old
  side. The tank's crew cannot turn the gun on its own deck; the player gets out and shoots it
  off, or their side does.
- The player at the wheel has no body: the tank's target pawn (and a truck's, made when a
  player first drives it) is what the other side senses and shoots. Wrecked, the player climbs
  out hurt (25).
- **Splatter** (`Splatter`): a driven vehicle going faster than 4 m/s hits each body of another
  side in the box just ahead of its nose for 30 a m/s over that, plus 30 -- a truck at speed
  (9 m/s, 180) kills a soldier, a tank at its top (6 m/s, 90) nearly does -- once a second per
  body. Its own side, riders, boarders and anybody inside a vehicle are spared.
- The city: CTRL+Z an empty truck of ours, CTRL+SHIFT+Z an enemy's with four soldiers in the
  back coming for the player. Gates: `vehicle_seats_probe` (16), the city's `--vehicles` pass.
- Not yet: a passenger seat in the cab; the enemy boarding a truck.

### 4.2 Brick bodies and damage zones (built)

Red Dawn's zones by colour (§1), as groups of bricks (`VehicleBricks`): every vehicle's body is
bricks a real brick's size, laid in running bond in boxes by zone, chamfered, studs on whatever
top is open, each with hit points of its own. A hit lands on the brick nearest where it struck
and what is left of it goes on to the next nearest within its reach -- in the same part first
(a rocket on the turret goes into the turret, not the deck) -- and bricks knocked off fly. A
splash with no point lands on a brick of the outside. A zone is **lost** when fewer than its
share of bricks are left; the vehicle's health is as before (the bricks are where it shows).

| Vehicle | Zone (bricks' hp, kept to) | Lost |
|---|---|---|
| Tank | tracks, each (70, 60%) | thrown: it does not drive; on one it still pivots, slowly |
| | engine, the back deck (80, 50%) | it neither drives nor turns; the turret turns by hand (40%); smoke |
| | turret (130, 40%) | jammed: it does not traverse |
| | gun: mantlet and barrel (70, 50%) | the cannon is gone; the machine gun fires |
| | ammo rack, behind a stud of turret wall in its back (200, 60%) | **cooks off**: wrecked there and then, the turret thrown, its crew out with 60 hurt, 150 to everybody within 7 m (less with distance), a 3 m blast in the bricks -- five rockets to the turret's back |
| | hull (110) | -- |
| Truck | engine, under the hood (45, 50%) | it does not drive: a squad on its way is let out where it stops; smoke -- about 30 rifle rounds |
| | wheels (50, 60%) | half speed |
| | cab, bed (60) | -- |

Drawn as one MultiMesh per part and brick size, and one of studs per part: a brick knocked off
is a zero-scale instance and its part's studs laid again. Not yet: the bricks in the world's
grid -- cover AIWorld knows, weight -- (AIPlan P7); the APC's zones. Probe:
`vehicle_bricks_probe` (26).

---

## 5. The commander's side

Already built: `UnitCatalog` (points, mobility, role, `built`), `Doctrine.draw` only fields
built units, the budget is points. Still to come, with the first vehicle:

- **Roster by answer** — against a player on roofs: helicopters; against a mech: rocket
  infantry and tanks; against a demolisher: flyers and vehicles, which destruction does not stop
  (AI.md 9's table).
- **Transport as a purchase** — a reinforcement is a squad *and how it arrives*: on foot, by
  truck, by APC, by helicopter, by boat. Arrival changes where it can come from (a road, the sea,
  the sky) and how long it takes: Red Dawn's travel time, distance / speed clamped 15–90 s,
  with the player told (radio chatter, a compass marker).
- **Off-screen fights by points** — Red Dawn's ratio table (≥2.0 decisive, ≥1.3 win, ≥0.8
  stalemate ...), for fronts no player is near; the player's presence switches a front to
  real time.

---

## 6. Order of work

1. **One wheeled transport** (truck): brick-built, `VehicleBody3D`, vehicle map, mount / ride /
   dismount. The commander buys "a squad by truck". Gate: a squad arrives by truck, dismounts
   in the truck's lee, and fights; nobody is left inside. *(Built: the truck, the vehicle map,
   riders and the player's driving and hijacking. Not yet: brick-built, VehicleBody3D, its
   squad as riders rather than cargo.)*
2. **APC** as moving cover; **damage zones as brick groups** (engine, wheels, ammo). *(Built for
   the truck and the tank, §4.2. Not yet: the APC.)*
3. **Tank** (tracked motor, crushing, a gun that breaches), screened by infantry. *(Built.)*
4. **Transport helicopter** on the height field; roof insertion through the survey.
5. **Attack helicopter**, **strike plane** — fire support the commander calls on a point.
6. **Boats** once the sea's surface is a map (Water.md).
7. **Enemy mech** — AIPlan P7, on the same seat and squad machinery.

Each step is a unit with `built = true` in `UnitCatalog` and a gate in the arena.
