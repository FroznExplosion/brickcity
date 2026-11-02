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

E4 is only done if E1 and the measurements show band rebuilds still matter. The full Brickadia
answer (one custom collision shape with an index inside) needs a Jolt shape Godot does not
expose -- out of scope unless E4's cheap steps are not enough.

---

## 12. Build order

Each step lands on `main` on its own, with its gate.

1. **E1 debug views.** Helps every step after.
2. **E2 measure, then batch** loose pieces' drawing if the numbers say so (editor closed).
3. **Air grid, compartments, breaches** (§2-§3) on the generated spaceship, headless.
   Gate: `hull_air_probe`.
4. **Venting** in space (§4): pressure, the pull toward the hole, a HUD warning.
5. **Repair core + restore tool** (§9 B). Gate: `repair_probe`. Breaches seal.
6. **A boat**, floating by buoyancy (§7) with no flooding yet. Gate: floats level.
7. **The sea cut out of the hull** (§6), with the terrain and water area. Gate: the shot.
8. **Flooding** (§5) + water drawn inside (§8) + listing and sinking (§7).
   Gates: `hull_flood_probe`, the boat lists and sinks.
9. **Brick-by-brick patching** (§9 A) on the same core.
10. **E3, E4, E5** as measurements call for them.
11. **Respawn** (§10) when the user decides.

## 13. Open questions

- Repair front end: A, B or both (§9)? What does a repair cost?
- Respawn rule (§10)?
- Low pressure: warn, hurt, or need a suit?
- Pumps and bailing: a module, a tool, or nothing?
- Do buildings get the air grid too (flooded basements, sealed bunkers)?
- Ships bigger than ~60 m: sparse grid blocks from the start, or when needed?
- Sink My Bricks' dev shorts ("Voxel Ocean", "Ghost ships", "This tool has saved me dozens of
  hours", "Trees in video games") -- transcripts not read yet; their ocean approach may change §5-§6.
