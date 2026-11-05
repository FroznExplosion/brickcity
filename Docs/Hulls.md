# Hulls: the air inside, breaches, flooding, venting, repair

Plan, 2026-11-02. Nothing here is built. It comes out of the research in
[Reference/brick-games.md](Reference/brick-games.md) and the user's direction:

> Ships use the **air bricks contained inside** space ships, boats, etc. to know when a breach
> happens, and start to **pour water in or vent air**. In water a ship takes on water **like
> Minecraft, brick by brick** from where water can enter. Near the player the sea is real pieces,
> so it should be **cut out per brick**: a floating ship has no water bricks inside it below the
> waterline. Patching: **brick by brick, or a Red Faction: Armageddon style tool** that restores
> what was there (undecided). Respawns: undecided. **A health bar, not limbs**; limbs may come off
> on death.

Part 1 (§1-§10) is the hull work. Part 2 (§11) is the engine fixes from the research. §12 is the
order to build it all in, each step with its gate.

---

## 1. What already exists to build on

| Need | Already built | Where |
|---|---|---|
| A ship's layout | generated hulls with decks, rooms, bulkheads cutting it into sections | `ShipBuild` (Docs/RoomModules.md 7.5) |
| A ship as a body | one rigid body, sections whole until a final break, the player rides its frame | `SpaceShip`, Docs/Space.md 3.2 |
| Water that flows | one depth per stud column, virtual pipes, active set only, 60 Hz sub-steps, mass conserved | `BrickPools` (`src/brick_pools.cpp`), Water.md 12.7 |
| A 3D water automaton design | mass per cell, down / side / up, `COMPRESS` for pressure, trapped-air cap | Water.md 12.1, after STA (`Reference/sta.md`) |
| Cutting the sea out of a place | `BrickPools.sea_mask`: a byte per stud, `water.gdshader` discards there | Water.md 12.7 |
| The wave height anywhere | `BrickWave.sample_heights`, batched, the same sum the shader runs | Water.md 1, 7 |
| Real water pieces near the camera | tier 0: brick-snapped round plates to 20 m | Water.md 3.0 |
| What a structure *should* be | the recipe: every building and ship is its recipe until touched | Plan.md B1 |
| Damage as a command | recordable, deterministic, ordered | Multiplayer.md |
| Mass of a piece | `get_chunk_mass` | Water.md 7 |

The new work is: an **air grid** per hull (§2), **breaches** found from it (§3), **venting** (§4),
**flooding** (§5), the **sea cut out of the hull** (§6), **floating and sinking** (§7), the
water **drawn inside** (§8), and **repair** (§9).

---

## 2. The air grid: the "air bricks" inside a hull

A hull gets a grid in its **own frame** (it moves and tilts with the ship): one cell per stud by
one brick (0.35 x 0.42 m, Water.md 12.2's cell), over the hull's bounding box. Each cell is one of

| Cell | Meaning |
|---|---|
| `SOLID` | the recipe has a brick here (whether or not it is drawn as bricks yet) |
| `OUTSIDE` | empty and reachable from outside the hull |
| `INSIDE` | empty and enclosed: the hull's **air bricks** |

plus, for `INSIDE` cells, a **compartment id** and a water mass (`u16`, STA's `MAX 4096`).

- **Built from the recipe, once, when the hull is made** (`ShipBuild.make`, or a boat's
  equivalent): a flood fill from the bounding box's faces over empty cells marks `OUTSIDE`;
  whatever empty cell it never reached is `INSIDE`. Connected `INSIDE` cells are a compartment.
- **Doors** are cells with a state. An open door joins two compartments; a closed one splits
  them. Bulkheads are already in `ShipBuild`, so a hit forward does not flood the engine room.
- **From the recipe, not the live bricks**, so a section still drawn as its shell (Space.md 3.2)
  has its air grid all the same. A cell becomes "gone" when bricks are removed there, *or* when a
  shell hole (`damage_profile`) stands for it.
- **Size.** A 60 x 20 x 10 m ship is about 170 x 57 x 24 cells = 230k cells, a byte each plus
  water only where water is: well under 1 MB. Kept sparse (16³ blocks, as zylanntest's
  `ship_voxel_grid`) if hulls get bigger.
- Also works for **buildings** later (a flooded basement, a sealed bunker) -- the same grid over a
  storey band.

## 3. Breaches

A **breach** is a gone hull cell that joins an `INSIDE` cell to an `OUTSIDE` one.

- Found **from the damage, not by scanning**: a hit already lists the cells it removed. For each,
  look at its six neighbours. If it now touches both inside and outside air, it is a breach cell
  of that compartment; the compartment is breached.
- A hit that opens a wall between two compartments **merges** them (re-label the smaller one).
  Only a hit's own cells and the compartments they touch are ever looked at.
- Each breach cell keeps where it is (ship frame), so §4 and §5 know where air leaves and water
  comes in, and how big the hole is (its cell count).
- A repair (§9) that fills a breach cell takes it off the list; when a compartment has no breach
  cells left it is sealed again.

**Gate:** `hull_air_probe` (headless) -- a generated ship has N compartments and no breaches; one
shot through the side breaches exactly that compartment; opening a bulkhead merges two; a repair
seals it. Ships of every seed checked, as `88b5bc6` did for loose bricks.

### 3.1 Built (2026-11-02): `HullAir`

`scripts/hull_air.gd`, gate `tools/hull_air_probe.gd` (headless, 8 ok).

- Baked from the laid recipe: one `get_solid_cells` call, doors from `BuildDoors.of(recipe)` as
  walls to the fill, an outside fill from the chunk's faces, then inside air labelled into
  compartments (union-find, so merges are cheap).
- **Compartments are rooms and corridor runs**, split by closed doors: seed 1 is 75,210 inside
  cells in 90 compartments for 28 placed rooms (sizes 36 cells -- voids in walls -- to 6,296).
  An open door links two (`links()`); the airlock is the one door onto the outside, and opening
  it breaches what it opens onto.
- Hits are followed from the removed blocks' cells (block id = the recipe's frame-0 order, checked
  against the block count). A shot through the hull breaches exactly its room in 0.06 ms; a wall
  between two rooms merges them; a patched hole seals, and the inner part of a patched thick wall
  goes back to inside air (`_pocket_from`, at most 4,096 cells followed).
- **Bake is 130-300 ms in GDScript** (seeds 1-8). Fine once at generation; it moves to C++ with
  the flooding (§5) or onto a worker.
- **No revive yet:** a killed block keeps its cell, so the probe patches by `remove_block` and a
  new `place_block` (`cells_added`). The repair step (§9) needs a real revive.

## 4. Venting in space

Air moves fast; it does not need to flow brick by brick. **One pressure per compartment.**

- A breached compartment loses air at a rate set by the hole's area (breach cell count) and the
  pressure difference: `dp/dt = -k * area * p / volume`. A big room with a small hole goes slowly;
  a cabin with a wall gone empties in a second.
- While air goes out, things near a breach are **pushed toward it**: loose pieces, items,
  players (a force falling with distance from the breach cells). This is the visual: debris and
  dust drawn out of the hole, then quiet.
- At low pressure: a HUD warning; whether players need a suit or take damage is a design call (§10).
- Sealing the breach stops the loss; air comes back from the ship's supply over time (or a module
  that does it).
- On a planet the outside is air, so venting does nothing; under water it is §5.

**Gate:** in `hull_air_probe`: pressure in a breached compartment falls at the expected rate,
stops when sealed, and the next compartment over (bulkhead closed) does not change.

### 4.1 Built: venting (2026-11-02)

- **HullAir keeps an amount of air per compartment** (cells x atmospheres), so pressure is
  air / cells: two rooms joined add theirs, freed cells joining a room thin it, a patched pocket
  comes in empty. `step(dt, outside)`: a breached room `p -> outside + (p - outside) e^(-k dt)`,
  `k = VENT_K * holes / cells` (VENT_K 30: a 180-cell room with a one-cell hole is at 85 % after
  a second; a big wall gone empties a cabin in about one); open doors between rooms even them out
  (no air lost); a sealed room is topped up by the ship's SUPPLY (2 % a second).
- **The rush:** `pull_at(cell, cell_m)` -- toward the room's nearest hole, up to PULL 30 m/s^2,
  falling off past 3 m, scaled by how fast the air is going and how much is left. The player's
  walker takes it as a drift (`PlanetWalker.push`): the floor takes it back off in a quarter of a
  second, the air slowly, so standing by a hole drags you to it and off your feet you go.
- **Wired into generated ships and stations** (`SpaceStation.air`): baked in `prepare` with the
  template (~265 ms for seed 1, once), every hit followed in `_after_kill` (the bricks killed and
  what the solve sends off), the doors' states each tick (`BuildDoors.open_states`: swung open,
  or the leaf gone with its lintel), stepped while bricked, flown or not.
- **Outside air:** `PlanetSystem` sets each ship's `outside_pressure` -- 1 in a world's air
  (to 4 % of its radius up), thinning to 0 at 8 % -- so a ship parked on a planet with its
  airlock open loses nothing.
- **HUD:** `PlanetSystem.air_at(p)` / `SpaceStation.air_at` (pressure, pull, breached, venting);
  the planet scene shows **HULL BREACH air N %** while the room the player is in is losing air,
  **LOW AIR N %** under 50 %.
- Gates: `hull_air_probe` 13 (the expected rate after 1 s, no other room changes, the rush toward
  the hole, sealed stops and refills, an open door evens two rooms out); `ship_vent_probe` 10
  (a real ship: baked, doors lined up, a hole of five hull bricks killed through the hit path,
  air_at, crumbs on its floor drawn out, a far room untouched, sealed, a world's air lets
  nothing out). planet `--gate=hull` 11 ok.
- **Crumbs drawn out:** `PlanetCrumbs.wind` (a ship's or station's sets it to its `air_at`):
  every crumb is pushed by the rush; one lying down is picked up (a hop) once the rush passes
  WIND_LIFT 2 m/s^2, so a room's broken bits fly out of the hole and away. A point in a brick or on
  its face (a crumb by a wall, the player's feet) takes the air of the cell next to it
  (`air_at(p, near)`).
- How strong it is: a one-brick hole in a 2000-cell room loses ~4 % a second and barely stirs
  anything (1 m/s^2 by it); five bricks out, ~25 % a second, 6-7 m/s^2: crumbs go out, the player
  is dragged.
- **Not yet:** large loose pieces (PlanetPieces rigid bodies) pushed too; dust drawn at the hole;
  what low air does to a player (suit, damage -- §10).

## 5. Flooding: water brick by brick

Inside the hull, water is the **3D cell automaton** Water.md 12.1 already designed after STA,
run on the hull's grid: mass per cell, flow down first, then sideways, then up (the `COMPRESS`
term, so a full compartment pushes water up a stairwell). Only cells with water, and their
neighbours, tick (active set). This is what makes it Minecraft-like: water runs along the deck
from the hole, pours down the stairs, and fills the lowest deck first.

- **Where water comes in:** each breach cell **below the outside water level** is a source. The
  level is `BrickWave.sample_heights` at the breach's world position (one batched call for all
  breaches), or a pool's level where a pool is (`water_sea.surface_at`). The inflow is set by how
  far below the surface the hole is (deeper = faster), so a hole at the waterline sloshes in with
  each wave and a hole low on the hull gushes.
- **Where water goes out:** a breach cell **above** the outside level drains the water against
  it, so a ship that rises or rolls the hole out of the water stops filling and can empty.
  Pumps (a module) are a later option.
- **Down is the ship's down.** The ship heels and pitches, so gravity in the grid is world down
  turned into the ship's frame. The automaton steps along the grid axis nearest that direction,
  with the sideways rule favouring the downhill side, so water runs to the low side of a listing
  ship. Past ~45 degrees the "down" axis changes. Good enough to look right; not real fluid.
- **Trapped air:** a sealed compartment that floods from below keeps its air at the top (STA's
  pocket cap), so a capsized ship can have an air pocket to swim up into.
- **Cost:** STA's budget is 100k active cells in ~3 ms on a worker. A flooding ship has a few
  thousand active cells. Run on a worker in C++, next to `BrickPools`, at the same 60 Hz.

**Gate:** `hull_flood_probe` (headless) -- one breach below the line fills its compartment and
stops at the outside level; a closed bulkhead holds; an open door lets it on; water never appears
outside the hull's inside cells; mass in = mass in the grid; a breach lifted out of the water
drains.

## 6. The sea cut out of the hull, per brick

Near the player the sea is real pieces (tier 0, Water.md 3.0); further out it is the studded tier
and then the smooth sheet. All of them must leave the **inside of a floating hull dry**.

- The hull gives the water shaders a small **3D texture of its `INSIDE` cells** (one byte per
  cell: 255 dry inside, 0 otherwise; flooded cells read 0 so the outside sea is not drawn over
  water that is already drawn inside, §8), plus the hull's world-to-ship transform.
- Each water shader (tier 0 pieces, studded tier, sheet) moves the fragment into the ship's frame,
  **snaps it to the cell grid**, and discards if that cell is dry inside. Because the test is per
  cell, the cut follows the bricks of the hull exactly: no smooth water poking through a brick
  hull, no square cut-out wider than the boat.
- This is `BrickPools.sea_mask` again, made to move: the mask was a world-fixed byte per stud; this
  is a ship-fixed byte per cell. A few ships near the camera at once (an array of masks, nearest
  first).
- **Underwater view:** the waterline split (Water.md 6) and the underwater fog must also ask "is
  the camera in a dry hull cell?" -- a player below the sea line inside a dry hold is not
  underwater.
- **Owned by the terrain and water area** (the water shaders and `water_*.gd`): the hull supplies
  the mask, the water side reads it.

**Gate:** a scene shot (windowed, one run, heat check after): a boat floating low, camera on deck
and in the hold -- no sea pieces inside, sea right up to the hull outside, the cut stepped by
bricks. And a flooded hold: inside water drawn, no doubled surface.

## 7. Floating, listing, sinking

- The ship is already one rigid body. Buoyancy adds a force at **sample points per section**
  (or per few metres of keel), each from the wave height there (one batched `sample_heights`
  call per ship per tick, Water.md 7).
- **What floats it** at a sample point: the submerged volume of its column of the hull -- bricks
  plus `INSIDE` air cells that are dry -- times water density. Flooded cells add their water's
  weight instead.
- So the ship **lists toward the flooded side**, settles lower as compartments fill, and sinks
  when the dry air left cannot hold its mass (`get_chunk_mass` for the bricks, plus water).
- A section that breaks off (Space.md 3.2) takes its own cells and compartments with it and floats
  or sinks on its own.
- **A boat is needed first.** Today's generated ship is a spaceship parked on land. A boat hull
  (open deck, keel, a hold) is a `ShipBuild` variant, or built in the workshop by hand.

**Gate:** a boat floats level at its designed waterline; flooding one side lists it that way;
flooding enough sinks it; patching and pumping out lets it rise.

## 7b. Walking inside a moving hull: the ghost hull

From Sink My Bricks' "Ghost ships" short (Reference/brick-games.md 1.1). **This changes the plan.**

**The problem we already have.** A ship that moves puts its brick collision away and keeps only a
shell box (`SpaceStation.ride`: "their collision (world-placed, it would stay behind) put
away"), and a floating-origin shift rebuilds the collision (`on_origin_shift`). So nobody can walk
the decks of a ship while it moves, and a rocking boat would have to rebuild or move thousands of
brick shapes every tick. Walking on a moving platform also jitters as small errors pile up, and an
AI walk map baked for the ship goes stale the moment it moves.

**Their answer.** Every ship has a **ghost double**: a copy of its collision that never moves. A
character who boards is moved onto the ghost, walks there on still ground, and is **drawn** on the
real ship at the same ship-local position: `real = ship.global_transform * ghost_local`. Their
characters have ghosts too. Collision and walk maps are built once and never touched; movement is
jitter-free because the ground really is still.

**Ours:**
- The ghost is the hull's `BuildingCollision` in its **own physics space**
  (`PhysicsServer3D.space_create`), at the identity transform -- not "far across the map" as they
  do it (that needs room in the world and fights our floating origin). Built once at promotion;
  never rebuilt when the ship moves or the origin shifts; edited only by damage and repair, as a
  standing building's bands are.
- A pawn aboard has its body moved into the ghost space; its node is drawn at
  `ship.global_transform * ghost_local` each frame, and the camera follows the drawn one. The
  ship's motion reaches it as a felt force only where wanted (a lurch when the ship is hit, a lean
  in a hard turn), not by moving the floor under it.
- **AI walk map baked once** in ship space (§10's crew, boarding parties).
- **The air grid (§2) and the flooding (§5) live in the same frame**, so water, air and the people
  wading through it share one still coordinate system. Water drawn inside (§8) is drawn at the
  real ship; its "down" is the real ship's tilt (§5).
- The **real** ship keeps its outside collision on its moving rigid body (shell box or a few boxes
  per section, Space.md 3.2) for everything outside: cannonballs, other ships, the sea, debris.
- **Crossing over** is the new work: boarding and getting off (move the body between spaces,
  carry velocity, as the STA frame handoff does); falling overboard through a hole; shots fired
  aboard (ray in the ghost space; a ray that leaves the hull through a gap continues in the world);
  shots from outside that enter through a hole (hit the real hull, then continue in the ghost);
  loose bricks broken off inside (they belong to the ghost until they leave the hull).
- Network: a pawn aboard sends ship-local positions -- small numbers, nothing to correct as the
  ship moves.

**Travel: planet, space, another planet.** Today every frame change rebases each top-level node
(`PlanetSystem`: `m * transform`, velocities turned) and a sleeping planet reparents what stands on
it. With the ghost only the **ship** is handed over: riders live in ship-local coordinates and are
drawn from the ship's transform, so reparenting the ship any number of times moves nothing in the
ghost. Origin shifts never touch it. Getting off is a pawn's only handoff, into whatever world the
ship is in then (ship velocity + its deck velocity turned into the world); docking with another
ship is the same handoff, ghost to ghost.
- **One shared ghost space** for all ships, each ship's ghost in its own slot ~10 km from the
  next -- not a Jolt space per ship (each reserves its own memory, and two independent spaces are
  untested, Planets.md). Per-ship spaces only if a test shows them cheap.
- **Owned by something that lasts** (the system / an autoload), never by one planet's `World3D`,
  so it survives a scene unloading.
- **Gravity aboard is per ship, ship-local:** artificial gravity in flight; parked or low over a
  planet, the planet's radial pull turned into the ship's frame each tick. Pawns apply their own
  gravity already; loose bricks in the ghost need it per body (the space's one gravity cannot be
  everyone's).
- **A ship parked on a planet that goes to sleep:** reparented as now, its ghost slot switched off,
  its crew asleep with it; woken with the planet.

**Gate:** `ghost_hull_probe` (headless): a pawn walks the deck of a rocking, turning ship for 60 s
-- no drift relative to the deck, collision built once, no rebuild on an origin shift; boarding and
getting off keep its velocity; a shot fired aboard hits the wall it was aimed at; the ship flown planet -> space -> a second planet with a pawn walking the whole way: no drift, the
ghost never rebuilt, the pawn's world velocity right when it steps off; a parked ship's crew
sleeps and wakes with its planet.

### 7b.1 Built (2026-11-04): the ghost hull, first cut

* **`GhostHulls`** (scripts/space/ghost_hulls.gd) is one physics space of its own
  (`space_create`). Each generated ship gets a slot 2 km from the next along X, near the
  space's origin so floats keep millimetres. Owned by the `PlanetSystem`: it lasts through a
  planet's sleep and is freed with the system. Jolt runs the two spaces side by side with no
  trouble.
* **A ship's ghost**: `SpaceStation.ghost`, a `BuildingCollision` of its bricks in the
  ghost space at `ghost_slot * frame`.
  * Built once, when its bricks are first in. Hits disable bricks in it and repairs enable
    them, as in its world collision.
  * Never touched by `ride`, `unride`, an origin shift or a reparent. It is freed only on
    `deactivate` or when the ship itself is deleted; `_exit_tree` no longer frees it, since a
    reparent leaves the tree.
  * `ghost_to_real()` maps ghost points to the world, `ghost_up()` is up on its decks,
    `deck_velocity(g)` is a deck point's world velocity over the last frame, and
    `ghost_holds(g)` says whether a ghost point is inside the ship's box.
* **Crossing**: `GhostHulls.board(body, ship)` and `get_off(body, ship, world_space)` move a
  character's body between the spaces. Same place on the ship; velocity is the deck's plus
  its own, turned into the right frame. Boarding marks the body `ghosted`, so
  `PlanetFrame.recentre` and `PlanetSystem._travel` leave it alone: only its ship travels.
* **The pawn aboard**:
  * `Pawn.ghost` holds its ship. Its up is the ship's deck up, held for the whole move by
    the new `Gravity.pin_up`, since no field or planet can say where down is at ghost points.
    With the ship's generator off, it floats.
  * `PawnMoves`' rays and shape tests ask the space the body is in.
  * `PlayerController` draws the camera, and its look frame, through the ship's
    `ghost_to_real`.
  * `PlanetScene._ghost_tick` boards the pawn when it stands in a riding ship. It gets off
    when the ship stops riding (at rest, its bricks' collision back), or when the pawn
    leaves the ship's box (out through a hole).
  * The terrain streaming viewer goes to the camera while aboard, so the ground streams round
    the real ship. `_anchor()` uses the real place.
* **In play**: standing up from the seat over a world no longer stops the ship dead. It
  glides to rest under you, at the unpiloted ship's own braking of about 40-50 m/s², its
  bricks drawn and riding the whole way. Its collision comes back in the world once it is
  slower than `PlanetSystem.COAST_STILL` (0.3 m/s), and you step off the ghost onto it.
* **Gates**:
  * `tools/ghost_hull_probe.gd`, 10 checks. Its ghost is built once in its own space. A body
    boards at the same place. 6 s of rocking, turning and 300 m/s flight: drift 0.0000 m,
    drawn on the real ship 0.0000 m off. It walks the distance it walked. A ray aboard meets
    a real wall. A hole and its repair show in the ghost. A reparent and an origin shift
    never rebuild the ghost. Getting off keeps the velocity.
  * The planet `--gate=hull` adds 2 checks (18 ok). Up from the seat at 66 m/s: on the
    ghost, 0.000 m along the deck while the ship went 17 m. At rest: off the ghost onto the
    solid bricks.
* **Not built yet** (the crossing list above):
  * **Shots fired aboard.** The gun's ray is the camera's, in the world, where a riding ship
    has only its shell box.
  * **Shots from outside entering through a hole.**
  * **Loose bricks inside the ghost.**
  * **AI and enemies seeing a pawn aboard.** Its body is not in the world.
  * **Repairs while riding.** Still refused.
  * **Docking, ghost to ghost.**
  * **A parked ship's crew asleep with its planet.**
  * **The 60 s and planet-to-planet runs of the gate.** The probe holds for 6 s.
  * **Boats (step 7).** They will use the same ghost.

## 8. Water drawn inside

The same drawing as pools (`water_pools.gd`, `water_pool.gdshader`), in the ship's frame and
parented to it: a top per column at its level, stepped by plate so it reads as bricks, sides only
toward dry cells, foam in the direction of flow. Re-meshed at 20 Hz, only where the level moved.
A waterfall sheet where water drops down a stairwell or through a hole in a deck.

## 9. Repair: two front ends, one core

The core is the same either way, and it is mostly free because **every structure is its recipe**:
what is missing is "the recipe minus what is there".

**Core: `restore(structure, cells)`**
- For each requested cell the recipe holds a brick for and the world does not: lay it back (the
  same `BrickWorld` add a promotion uses), re-run the attachment check and the structural solve
  for the band, and take breach cells off the list (§3).
- A restore is a **command**, like damage: deterministic, ordered, recorded, so it networks.
- What it costs (bricks carried, energy, ammo) is a design value, the same for both front ends.

**Front end A: brick by brick.** A combat quick-place from the build tools: the missing bricks of
the structure you look at show as ghosts of the original; click places one (it costs one). Slow,
precise, satisfying for a crew under fire. Needs the build tools' ghost and snapping, which exist.

**Front end B: the restore tool (Red Faction: Armageddon's Reconstructor).** Point at a damaged
area and hold: missing bricks within a radius come back, **nearest the hole's edge first** so a
breach seals quickly, a few per tick. Optionally **pulls the structure's own debris back** --
loose pieces near the hole that came from it fly back and are consumed as the bricks reappear
(pieces are named by what they hold, Multiplayer.md, so we know where they came from).

**Recommendation:** build the core and front end B first (one gun-like tool, easy to play,
useful on buildings too); front end A after, as an option on the same core. Undecided -- the user
picks.

**Gate:** `repair_probe` (headless) -- a shot hull is restored to the recipe exactly; a restored
breach seals its compartment; a restore inside a falling piece is refused; the same commands in
the same order give the same result twice.

### 9.1 Built (2026-11-04): the core and the restore tool

* **C++ `BrickWorld.revive_blocks(chunk, ids)`.** It brings a block back in its own cells:
  destroyed, or `detached` (gone on a piece). A dead block still holds its cells, so nothing
  can have been laid there. It comes back as a new brick: hp 255, and its joint damage
  (`support_broken`, `bottom_broken`, `strained`, `held`) cleared. **Ids stay**, so the
  damage record, the collision shape map and HullAir's block map all hold. Removed (edited
  away), decorative and band-chunk absent blocks are left alone. Its faces are still in the
  bake (dead blocks keep their slots), so the next index patch draws it. A chunk baked
  without its dead (§11 E2, `bake_skips_dead`) is baked again.
* **`DamageLog.Kind.RESTORE`**: `blocks` as ids, as BURN's are, because which bricks a
  restore reaches is the host's choice. `StructureReplayer` applies it like the other
  building kinds.
* **`SpaceStation.restorable(point, radius)`** lists the lost bricks within `radius`. The
  rim comes first: bricks beside one that is still there, nearest the point first. So a hole
  closes from its edge inward and a breach seals soonest.
* **`SpaceStation.restore(ids, point, radius)`** records the command and applies it. Then
  the air takes the bricks back (`HullAir.blocks_added`: the breach seals, the supply
  refills), the collision bands are rebuilt at the next flush (`BuildingCollision.enable`),
  and the bands are redrawn.
* **Refused while the ship `riding`** (flown over a world). A hit is refused then too: its
  bricks' collision is put away. Working on a hull in flight comes with the ghost hull
  (step 6).
* **`RestoreTool`** (front end B): hold `restore` (the **middle mouse button**; every letter
  key was taken, rebindable in Options > Controls) on a ship's or station's hull. The lost
  bricks within RADIUS 2.5 m of where you point (RANGE 6 m along the view) come back, RATE
  8 a second, rim first. Wired in `PlanetScene._restore_tick`.
* **Not decided, left open:**
  * **What a brick costs.** `RestoreTool.cost` is how many it may still lay; -1, no limit,
    for now.
  * **Bricks that left on a piece come back as new ones.** The drifting piece stays as
    debris. Pulling the debris back in (§9 B, optional) is not built.
  * **No HUD or effect for the tool yet**: the bricks reappearing is the only feedback.
  * Front end A (brick by brick, step 10) can use the same `restore`.
* **Gate: `tools/repair_probe.gd`, 7 checks:** the shot, the rim first, the tool's rate,
  refused while riding, every brick exactly as built (part, colour, full hp, same id), the
  breach sealed and filling, and the replay. The ship's commands replayed on a fresh ship
  give the same bricks after the shot and at the end.

## 10. Health, limbs, respawn (decisions)

- **Health: a health bar** (the user's choice). The Borderlands-style layers already exist
  (`HealthPool`: shield, armor, health).
- **Limbs on death:** when a brick figure dies it comes apart at its joints -- arms, legs, head,
  torso as loose pieces through the debris system, capped like any other. Cosmetic; no gameplay.
  For mechs, a destroyed arm drops its weapon (optional, later).
- **Respawn: undecided.** Options to choose from when it matters:
  1. at your ship / dropship / Titan while it still stands (Sink My Bricks' rule: lose it and
     respawns stop until you capture another);
  2. at fixed checkpoints;
  3. co-op revive by a teammate within a time, else respawn at 1 or 2.
- **Air in space:** whether low pressure needs a suit, hurts, or only warns (§4).

---

## 11. Engine fixes from the research

From [Reference/brick-games.md](Reference/brick-games.md) §5. Each is measured before it is done.
Timing runs need the editor closed (CLAUDE.md).

| # | Fix | Size | Measure first |
|---|---|---|---|
| E1 | **Debug views**: band bounds, collision per band, centre of mass of loose pieces, bodies that never sleep, live counts against the caps -- one toggle | small | -- |
| E2 | **Batch loose pieces' drawing**: pieces sharing a mesh draw from one `MultiMesh` written once a frame, instead of a `MeshInstance3D` each (`IslandManager`) | small-medium | render and CPU time with the caps full (80/24/96 pieces) |
| E3 | **Reserve memory before the first hit**: size a building's C++ brick arrays from its recipe when it promotes, so laying bricks never grows them | medium | the first-hit tick, before and after |
| E4 | **Band collision rebuilds less**: smaller bands near damage, or rebuild only the touched part of a band's compound | medium-large | is a band rebuild still in the worst tick of a collapse? |
| E5 | **Nearest-first ray order** in our own C++ brick ray tests | small | ray test counts |
| E6 | **Batched, threaded buoyancy** for all floating things (§7 uses it) | small | -- |

**E2 measured (2026-11-04, `city.tscn -- --piececost`, editor closed, no other runs, but
under 1 GB of RAM free -- paging may add noise):** 6 towers blasted gave 24 large pieces
(0 small: the cap was not reached). Each piece has its own mesh (24 distinct), so a
`MultiMesh` has nothing to share. Drawn vs hidden, averaged over 180 frames:

| | render CPU | GPU | draw calls |
|---|---|---|---|
| drawn | 0.870 ms | 11.20 ms | 752 |
| hidden | 0.795 ms | 6.82 ms | 615 |
| **the pieces** | **0.07 ms** | **4.36 ms** | **137** |

The cost is GPU work, not draw calls or CPU. Batching (E2 as written) would not help, so it
is not done.

**What the triangles are (same day, the pass now breaks them down per piece):**

* **91% of the 856k were dead slots.** A loose piece keeps the face bake of the building it
  came from: every face of every brick it was ever part of, the dead patched to (0,0,0) so
  a hit is an index patch and never an upload. One 398-brick piece carried a 121k-slot
  bake. Only 72k triangles were drawn, about 6 a brick.
* **Half of those 72k were 25 stair steps.** The spiral staircase's steps
  (`StaircaseRecipe.step_mesh`, archetypes 288-294) are 1,444 triangles each, against
  about 6 for a wall brick. That is the stair step's studs and curve. It belongs to the
  build-mode area: a lighter step is theirs to make.
* **Coarse stand-ins** of the same pieces: 17.7k triangles, GPU 0.7-1.1 ms against
  3.3-4.2 ms. Bringing the stand-in range (`ISLAND_MESH_RANGE`, 120 m) closer would be a
  visible change (no studs nearer than that), so it is a design call, not done.

**Done: settled pieces are baked again without their dead** (`IslandManager._compact_due`,
C++ `BrickWorld.set_chunk_bake_skips_dead`). A piece that has settled, is drawn as bricks
and has over twice as many slots as drawn triangles (and at least 6,000 slots) is baked
again on the bake thread from its live bricks only. Its old mesh draws until the new one is
up, and later hits patch it as before. In the pass, 13 of 24 pieces were baked again, and
the slots went from 856k to 129k with the same faces drawn. The GPU time barely moved
(dead slots are cheap to draw: 3.3 ms, within the noise). The gain is memory: the bake on
the CPU (224 bytes a face) and the vertex buffer in the GPU's memory, which on this machine
is the same RAM. That is about 80 MB for those 24 pieces. Gate:
`tools/compact_bake_probe.gd`. A brick brought back alive in such a chunk has no faces to
patch in. Revive (§9, step 5) must bake the chunk again.

E4 is only done if E1 and the measurements show band rebuilds still matter. The full Brickadia
answer (one custom collision shape with an index inside) needs a Jolt shape Godot does not
expose -- out of scope unless E4's cheap steps are not enough.

---

## 12. Build order

Each step lands on `main` on its own, with its gate.

1. **E1 debug views.** Helps every step after.
2. **E2 measure, then batch** loose pieces' drawing if the numbers say so (editor closed).
   Measured: GPU triangles, not draw calls -- batching skipped. Settled pieces now drop
   their dead bricks' faces (§11).
3. **Air grid, compartments, breaches** (§2-§3) on the generated spaceship, headless.
   Gate: `hull_air_probe`.
4. **Venting** in space (§4): pressure, the pull toward the hole, a HUD warning.
5. **Repair core + restore tool** (§9 B). Gate: `repair_probe`. Breaches seal.
   Built 2026-11-04 (§9.1).
6. **The ghost hull** (§7b) on the generated spaceship: walk its decks while it flies.
   Gate: `ghost_hull_probe`. First cut built 2026-11-04 (§7b.1): walking, boarding,
   getting off, damage and repair in the ghost; shots aboard and AI still to come.
7. **A boat**, floating by buoyancy (§7) with no flooding yet, crew aboard on its ghost.
   Gate: floats level.
8. **The sea cut out of the hull** (§6), with the terrain and water area. Gate: the shot.
9. **Flooding** (§5) + water drawn inside (§8) + listing and sinking (§7).
   Gates: `hull_flood_probe`, the boat lists and sinks.
10. **Brick-by-brick patching** (§9 A) on the same core.
11. **E3, E4, E5** as measurements call for them.
12. **Respawn** (§10) when the user decides.

## 13. Open questions

- Repair front end: A, B or both (§9)? B is built (§9.1). What does a repair cost? Should the
  tool pull its debris back? Which key or slot is it on?
- Respawn rule (§10)?
- Low pressure: warn, hurt, or need a suit?
- Pumps and bailing: a module, a tool, or nothing?
- Do buildings get the air grid too (flooded basements, sealed bunkers)?
- Ships bigger than ~60 m: sparse grid blocks from the start, or when needed?
- Waves: keep the vertical-only sine sum, or take Sink My Bricks' inverted-displacement trick
  for choppier crests (Reference/brick-games.md 1.1)? The water area decides. Either way §5 and §7
  read heights only through `BrickWave.sample_heights`, so this plan does not change.
- The ghost hull (§7b): a pawn's body moved to another physics space while its node stays in the
  scene -- prototype first; if Godot fights it, fall back to their way (the ghost placed far off in
  the same world).
