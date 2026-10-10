# AI vehicles and mechs — plan

**Status: 2026-10-09. Step 1 is built in its smallest form, and step 3's tank in its first
part (AIRoster.md RO10: crewed seats, a cannon that opens walls, armour, the player can drive
it, infantry screen it -- no crushing, no brick body, no vehicle map yet); the rest is planned.**
The commander can name, cost and weigh every vehicle below (`UnitCatalog`), so the budget, the
doctrine and the save format know them before each one drives; only the truck has `built =
true` -- the tank is fielded by the arena (`--tank`) and the city (Z), not yet bought.

**What step 1 is today** (`scripts/ai/vehicles/transport_truck.gd`): a kinematic body with health
that asks for one path and drives it (9 m/s, 1.6 rad/s turns, slower through a sharp one). What it
carries is **cargo** -- the unit kinds the commander bought -- not bodies in seats: at the drop
(within 22 m of where it was sent, the end of its path, or stuck 3 s) the host puts the squad
down at the tailgate, on the side away from the threat. Shot to pieces on the way, its squad is
lost with it. The commander buys "a squad by truck" as often as its doctrine's `truck_share`
says (0.4; more against a sniper, less against a demolisher). Not yet: a brick-built body,
seats, moving cover, a vehicle map with clearance -- it drives the foot map, and stops where
that is too narrow for it. Read [AI.md](AI.md) first
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
   in the truck's lee, and fights; nobody is left inside.
2. **APC** as moving cover; **damage zones as brick groups** (engine, wheels, ammo).
3. **Tank** (tracked motor, crushing, a gun that breaches), screened by infantry.
4. **Transport helicopter** on the height field; roof insertion through the survey.
5. **Attack helicopter**, **strike plane** — fire support the commander calls on a point.
6. **Boats** once the sea's surface is a map (Water.md).
7. **Enemy mech** — AIPlan P7, on the same seat and squad machinery.

Each step is a unit with `built = true` in `UnitCatalog` and a gate in the arena.
