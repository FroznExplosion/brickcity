# Wiring, pistons and traps in the mine world -- theory

Written 2026-11-25. Design only: nothing here is built.

**Decided 2026-11-25 (the user): the mix of section 3.3** -- visible cable
tiles, conductive bricks, a view tool, wireless bricks by antenna colour.
**Hydraulics** (water pressure through pipes) is part of the same system:
section 11. Defaults for the open questions: section 9.
Scene: `scenes/terrain_test.tscn` (the mine world, Docs/MineWorld.md).

## 0. What the user asked

- Look at the mine world's brick ground, research Minecraft's redstone and
  other games with wiring, and work out what wiring would be on this ground.
- What traps it would make, and its machines: pistons, dispensers and so on.
- **Visible wires laid in the world (redstone dust) or invisible wires made
  with a tool (Hytale is said to be working on one)?** The pros and cons of each.
- **Can the ground today have a brick pushed by a piston?** And a brick
  pushed sideways off a studded brick would look wrong: what to do about it.

## 1. What the ground is (the facts the design must fit)

| Fact | Where | What it means for wiring |
|---|---|---|
| The ground is **plate cells** on a stud x plate x stud grid (0.35 x 0.14 x 0.35 m), a material byte each, the generator plus sparse edits | MineWorld.md 2, 9 | a wire or a device has a grid to sit on, finer than Minecraft's 1 m block |
| A **brick** in the ground is the bond's rectangle (`bond_rect`, 2x4 in rock, 2x2/1x1 elsewhere); a block the player places is **one brick** (`mark_placed`) | TerrainBond.md 1 | "the brick a piston pushes" already has an answer: the same brick a shot breaks |
| An edit is `fill_box` / `clear_runs` + a tile rebake on a worker: **37 ms** from edit to drawn for one brick, 58 ms for three | MineWorld.md 9 | the field can move a brick, but it moves by a jump with a short delay, not a slide |
| Every edit is **surveyed**: what loses its support falls as pieces, sand falls as columns | TerrainCollapse.md | a pushed or pulled brick that leaves something hanging brings it down for free |
| **Stud joints** hold bricks together (the buildings' `solve_structure`, `BrickStrength.tension()`) | TerrainCollapse.md 1 | joints are what the push rule (section 6) has to respect |
| **Water and lava** are a layer of their own (`BrickFluid`), same lattice, own sparse store, own mesher, a 10 Hz tick on a worker, only changed cells awake | MineWater.md 1, 6 | the pattern a wire layer copies |
| **Chests** are nodes on the block lattice, not terrain material (`MineChests`): placed on a face, held from under, broken by what holds them going (`check` on `terrain_edited`), saved by key | Inventory.md stage 5 | the pattern every device (lever, piston, dispenser) copies |
| Flat plates are laid as smooth **tiles** 22% of the time; a piece can carry an overlay course (a tile or a studded plate) | `TILE_CHANCE`, `Piece.overlay` in brick_terrain.h | the ground already draws studless tiles: a wire can be one |
| The generator already places **`MAT_REDSTONE`** ore | brick_terrain.h | an ore to make wire from (name it something else in game, section 9) |
| Grenades break bricks, guns shoot whole bricks out, AI garrisons exist, the day turns | Inventory.md, MineWorld.md 10 | traps can use all of it |

## 2. What the other games do (research)

| Game | Wire | Signal | Lessons |
|---|---|---|---|
| **Minecraft (redstone)** | dust laid on top of blocks, one block per cell | 0-15, loses 1 a block; repeaters restore it; components update neighbours up to 2 away | Visible and tactile, everyone can read a circuit. Its oddities -- quasi-connectivity (pistons powered as if one block higher), block update detectors, update order that changes with location -- began as bugs and became features players depend on. The wiki and the bug tracker list them. Do not copy them. |
| **Minecraft mods: Create, Vintage Story's mechanical power** | axles, gears, belts: power you can SEE turn | speed and load (stress) | Moving parts read as machines. Rotation suits LEGO Technic better than electricity does. |
| **Terraria** | four colours of wire, laid with a wrench through any tile, cut with a cutter; shown only while a wiring tool is held | a toggle, not a level | Wires run through walls (hidden for free) yet can be shown; colours let nets cross. Actuators switch a block solid or passable: the cheapest trap door there is. Its logic is limited (toggles only). |
| **Brickadia** (a brick game, the closest to ours) | wires between bricks' ports, drawn as lines in the editor; hidden "microchips" hold whole circuits | many data types; "Wires V2" orders every gate in one dependency graph a step; exec wires; custom events received anywhere | Wires as an explicit graph make the update order deterministic and cheap. Very powerful, but it is a programming tool, not a survival-game material. |
| **Scrap Mechanic, Starbound, Garry's Mod Wiremod** | invisible links, made by clicking an output then an input with a connect tool | on/off (Scrap), values (Wiremod) | Clean builds, any distance. Scrap Mechanic's players asked for mod tools (parallel connect, connect by colour) because linking dozens of gates one click at a time is slow. |
| **Hytale** | no official wiring found (2026-11). There is no official roadmap; a fan site lists "logic, automation, conveyors" as possible. Mods (Logica: copper wire with Minecraft-like decay, gold wire without, pistons, observers) | -- | The "tool-wired" Hytale idea is not confirmed. |
| **LEGO itself** | Power Functions and Powered Up: real cables between battery box, motors and lights | -- | In LEGO the wire is a PART you can see. That matters for section 3. |

## 3. Visible wires or invisible wires

### 3.1 Placeable wire (redstone dust)

| Pros | Cons |
|---|---|
| **You can read a circuit by looking at it**; you learn by copying what you see | Spaghetti: wires take room and look messy |
| **It is physical, so it can be destroyed.** This is a destruction game: a shot, a grenade or a collapse cuts a wire. "Shoot the wire to stop the trap" is gameplay the invisible kind cannot have without inventing rules | Hiding a trap means burying the wire, which is work |
| In multiplayer an alert player can **spot and counter** a trap | Routing up walls and crossing two wires need special pieces |
| Fits the grid and a sparse layer like water's; the sim is cheap | Accidental connections: dust joins whatever is next to it |
| Familiar to anyone who played Minecraft | Distance decay and repeaters are busywork (and on our grid a stud is 0.35 m: 15 cells would only be 5 m) |

### 3.2 Invisible links made with a tool (Scrap Mechanic, Starbound, Brickadia's editor)

| Pros | Cons |
|---|---|
| Clean builds; any distance; hidden traps are trivial | **You cannot see what is wired**: debugging needs a tool view |
| Explicit output-to-input: nothing joins by accident | Not physical: no shot can cut it, so it does not belong to the destruction game. Explosions need an invented rule ("a link breaks when an end breaks") |
| A graph: deterministic order, cheap to sim, easy to save and to send over the network | In multiplayer, traps nobody can see or counter feel unfair |
| Logic gates become simple bricks with ports | Many links, one click each, is slow (the Scrap Mechanic complaint) |
| | "Action at a distance" fights the look of the game: everything else here is a brick you can see and break |

### 3.3 Recommendation: physical wire as real LEGO-style parts, plus a tool to see it and a few wireless parts

1. **Wire is a part, not dust:** a 1x1 **cable tile**: smooth, one plate tall,
   with a cable printed or moulded on top. It sits on studs the way a real tile
   does (the ground already draws tiles). Laid by the stud, it joins its four
   neighbours in a straight line or a bend, like dust, but you see a cable.
   1x2 and 1x4 lengths are the same cells, packed for looks.
2. **Conductive brick:** a brick material variant with a copper stripe. A wall or
   floor of them carries the signal through itself. This is Terraria's "wire
   through the wall": **traps are hidden by building the wire INTO the wall**,
   and a shot that breaks that brick still cuts the circuit. Vertical runs need
   no riser piece.
3. **A tool shows it all:** holding any wiring item (or a meter) draws every net
   within ~16 m through walls, powered nets lit, a net's devices outlined
   (Terraria shows wires only while a wiring tool is held). That covers the
   invisible system's one real strength, a clean view.
4. **Wireless only as parts:** a transmitter and a receiver brick, **the channel
   is the colour of the 1x1 round antenna on top** (LEGO's colours; Terraria's
   four wire colours). Long distance and hidden links exist, but each end is a
   brick you can find and shoot.

This keeps "everything is a brick you can see and break" and still gives tidy,
hideable circuits.

## 4. How the signal works

Do not copy redstone's rules (section 2). Brickadia's graph is the better model:

- **Nets.** Cable tiles and conductive bricks that touch form a **net**. A
  net's value is the highest of its drivers (on/off at first; a level 0-15
  later for sensors that measure). The whole net changes at once: **no decay,
  no repeaters.**
- **Devices** (levers, gates, pistons) read the nets beside their input faces
  and drive the nets beside their output faces. A gate is **one brick** (AND,
  OR, NOT, latch, delay, pulse), not a torch-and-dust puzzle. The puzzle is the
  machine, not the wiring syntax.
- **A tick at 10 Hz**, with the water (MineWater.md 6), in a fixed order
  (devices by id). Every device takes one tick; a delay brick takes 1-10.
  The same inputs give the same result anywhere, which multiplayer needs (MineWater.md 11.5).
- **Only what changed runs.** A net whose drivers changed wakes the devices
  on it; a quiet circuit costs nothing (the water's rule).
- **Nets are rebuilt when a wire changes** (placed, broken, shot, fallen): a
  flood fill over the touched cells on a worker, never a wait on the main
  thread (CLAUDE.md, WhereWorkRuns.md).
- **Past the sim ring a circuit is frozen** with its pending wakes, and resumes
  when someone comes back. A clock does not run where nobody is.
- **Store:** cable tiles as a sparse layer by region (like water sections and
  the edit regions); devices as keyed records with their state (like chests).
- **Drawing:** a lit net must not rebake ground tiles. Cable tiles are their
  own instanced mesh (one MultiMesh per tile of ground); powered is an instance
  colour set from the CPU's own record (no renderer read-backs). Conductive
  bricks show a stripe that glows the same way.

## 5. Devices

| Device | Does | Leans on |
|---|---|---|
| Lever, button, pressure tile | inputs | chest-style nodes |
| **Trip string** between two hook bricks | on when something crosses it | a LEGO string piece, a ray each tick |
| Sensors: motion (pawns and AI in a box), daylight, water/lava (`BrickFluid` query), **observer** (a brick in front changed) | inputs | `terrain_edited` already reports every change |
| Gates: AND, OR, NOT, XOR, latch, delay, pulse, counter | logic | -- |
| Lamp (a clear brick that lights) | output | the lighting rig's Glow and Lamp lights |
| Door, trapdoor, **gate tile** (a tile that turns passable when powered: Terraria's actuator) | output | device nodes |
| **Piston / lifter**, sticky piston | moves bricks | section 6 |
| **Dispenser** | fires the item in it: arrows, grenades, a gun's round, a bucket's water or lava | the weapons, grenades, buckets that exist |
| Dropper | drops items | `DroppedItems` |
| **Valve** | opens or shuts a water/lava source | `BrickFluid` sources |
| **Release brick** | lets go of the stud joints of the bricks touching it | the collapse survey (section 7) |
| Alarm | calls the nearest AI garrison | per-world AI, town garrisons |
| Speaker / note brick | sound | -- |
| Transmitter / receiver | wireless by colour | section 3.3 |

## 6. Pistons on this ground

### 6.1 Does the ground support it today?

**The data does; the motion does not yet.**

- Moving a brick in the field is possible now: read its cells, `clear_runs`,
  `fill_box` at the new place, `mark_placed` so it stays one brick. Falling sand
  does exactly this (cleared, drawn moving, written back where it lands).
- What is missing:
  1. **Motion.** The edit lands 37 ms later as a jump. A piston needs a stand-in
     brick drawn sliding (~0.15-0.25 s), with the cells written at the start and
     the stand-in hidden when the new tile swaps in (`TerrainStreamer._swaps`
     already swaps a finished tile in one frame).
  2. **Pushing the player.** The moving brick needs a short-lived kinematic
     body so it carries or shoves whoever stands there.
  3. **What moves with it** (6.3) and **what may not move**: bedrock, and
     ground too large to move (the push limit).
  4. **Cost.** Each push is a terrain edit and a tile rebake (9-14 ms on a
     worker). A few pistons are free; a fast clock driving forty is not. Limit
     pushes per tick, or keep a brick that keeps moving as a node until it stops.
- Chests and other devices are nodes: pushing them moves the node.
- After a push the collapse survey runs as for any edit, so a pulled support
  brings down what it held: that is free, and it is the best trap in section 8.

### 6.2 The studs: sliding a brick across studs looks wrong (it would)

In real LEGO a brick on studs cannot slide: its underside grips the studs. It
comes **off upward** (you pull it up), and a brick resting on **smooth tiles**
slides freely. So the rule falls out of LEGO itself:

| Push | What happens | Looks |
|---|---|---|
| **Up** | the brick lets go of the studs under it and rises: LEGO's natural way apart | right |
| **Down** | onto studs: it presses on and clicks | right |
| **Sideways, on smooth tiles** (or hanging free) | slides | right: tiles are a slide |
| **Sideways, on studs** | **hop**: lift one plate (off the studs), slide, set down and press, in ~0.2 s | right: what a hand does |

```
   side view, a sideways push over studs (the hop)

   1. rest          2. lift 1 plate     3. slide            4. press down
       ___              ___                     ___                 ___
   ]==|___|         ]==|___|           ]======|___|        ]======|___|
   n n n n n        n n n n n          n n n n n           n n n n n
```

Options considered:

- **Hop (recommended).** Works on any surface, reads as "popped off and
  re-seated", and the piston head (a 2x2 plate with anti-studs) can show the
  lift with a small tilt.
- **Slide only on tiles; stall on studs.** The most physical. Tile runs become
  "tracks" a builder lays, which is a nice idea, but most of the generated
  ground is studded (78% of flat plates), so pistons in the wild would mostly
  fail. Could be the rule for the **sticky** piston's pull only.
- **Ram (a second kind of piston).** Pushes hard enough to break the joints:
  the brick is knocked off as a falling piece (`PlanetPieces`), tumbles and
  breaks where it lands. Very good for traps; not a building block.

### 6.3 Clutch is slime

Minecraft needs slime blocks so a piston moves a group. In LEGO, **stud joints
already are the slime**: a brick pushed up takes everything clutched on top of
it. The group is the collapse's own joint graph (`find_detached_groups` with
the piston's brick cut loose). Rules:

- Push **up**: the brick and everything clutched above it rise; its joints
  below let go. Limit: **N bricks** (Minecraft's limit is 12; here 12 bricks,
  or about 96 studs of footprint), or the piston stalls.
- Push **sideways**: the brick and what is clutched above it hop together;
  what holds it at the sides (bonded neighbours) stalls the push, unless it
  is a ram.
- **Ground bonded into the hillside** is one huge group: a piston cannot move
  it. **Placed blocks, loose sand and gravel, and fallen pieces** move. This is
  Minecraft's "obsidian does not move", and it comes from the brick rule, not a list.
- **Sticky piston:** the head has studs; it clutches the brick in front and
  pulls it back (with the same group and limit).

### 6.4 Step size

A builder block is 2x2 studs by a brick, so a piston moves **2 studs**
sideways or **1 brick** up. The grid allows 1 stud and 1 plate, so a "fine
piston" is possible later (plate-high lifts, a door that moves 1 stud).

## 7. The release brick (the trap only this game can have)

When powered it **lets go of the stud joints** of the bricks it touches (in
the survey's terms: those joints are cut). The collapse survey then decides
what falls. A bridge built on release bricks drops as real pieces; a ceiling
of rock held by them comes down as rubble; a floor turns into a pit. No
special animation: it is the destruction system the game already has, started
by a wire.

## 8. Traps

| Trap | Built from | Countered by |
|---|---|---|
| **Collapsing floor / bridge** | pressure tile -> release bricks under the floor | spotting the stripe of conductive brick, shooting the wire, jumping |
| **Cave-in** | trip string -> release bricks in a cave roof; the collapse drops real rock | seeing the string; shooting it from a distance |
| **Sand drop** | trip -> piston pulls a support from under a sand store (sand falls as columns) | -- |
| **Arrow / gun wall** | trip or motion sensor -> dispensers loaded with arrows or a gun's rounds | breaking the dispenser; the wire is in the wall: shoot through |
| **Grenade chute** | pressure tile -> dropper of primed grenades (they break bricks) | outrun it |
| **Spike pit** | pressure tile -> pistons push spike bricks (LEGO cones and horns) up out of the floor | -- |
| **Crusher** | timer -> sticky pistons in a corridor ceiling, push down and pull back | timing |
| **Flood room** | door shuts (gate tiles) -> valve opens a water or lava source | breaking the valve or a wall: water flows out (BrickFluid) |
| **Trapdoor drop** | gate tiles go passable over a shaft | -- |
| **Ram wall** | rams knock wall bricks out at the player as falling pieces | cover |
| **Alarm** | observer sees a broken brick (the player digging in) -> alarm -> AI garrison comes | breaking the observer first |
| **Hidden door** | lever behind a painting brick -> pistons lift a wall section (the clutch moves it as one) | -- |
| **Lamp lure** | daylight sensor -> lamps on at night over a pressure-tile path | -- |

The theme: **traps use the game's own systems** (collapse, sand, water, lava,
grenades, guns, AI), and **the player's own weapons disarm them** because
the wire is a brick.

## 9. Open questions for the user

**Defaults taken until the user says otherwise (2026-11-25):** the wire is
the section 3.3 mix (decided); nets carry a **level 0-15** (hydraulic
pressure needs one, section 11); pistons **hop** over studs, slide on tiles;
an electric piston pushes **12 bricks**, a hydraulic one by its pressure;
names still open; rotation later.

1. **Wire: visible part (section 3.3) or invisible links?** The recommendation
   is visible cable tiles + conductive bricks + a view tool + coloured
   wireless bricks.
2. **On/off only, or levels 0-15** (needed only for measuring sensors and comparators)?
3. **Sideways push over studs: hop, tiles only, or both** (hop for pistons,
   tiles-only for sticky pull)?
4. **Push limit:** 12 bricks like Minecraft, or by weight (studs of footprint)?
5. **Names.** "Redstone", "repeater", "observer" are Minecraft's words (see
   Docs/printed-brick-city-legal-brief.md for the project's line on look-alikes).
   `MAT_REDSTONE` can stay in code; the ore and items want their own names
   (e.g. copper wire, signal ore, cable tile).
6. Rotation (Technic axles, gears) as a second power later, for windmills
   and conveyors? It suits LEGO and Vintage Story/Create show it plays well.

## 10. Build order (decided; hydraulics added as stage 6b)

Small stages, each with a probe and a gate, each merged:

1. Cable tile layer (store, nets on a worker, own mesh, saved) + lever + lamp.
   **Built 2026-11-25** (section 13).
2. Button, pressure tile, trip string; gates, delay, pulse; the view tool
   (also the wrench: look, turn, take; section 12); first Ponder-style dioramas.
3. Door, trapdoor, gate tile; observer (from `terrain_edited`); sequencer
   brick; number tile.
4. Piston: up first (unclutch + group + limit), then sideways with the hop,
   the stand-in slide, the kinematic shove; sticky piston. Moving groups are
   contraptions (section 12): one body, riders carried by contact.
4b. Turntable brick and winch (the same contraption mover).
5. Dispenser and dropper (items, arrows, grenades, gun rounds, buckets).
5b. Placer and breaker bricks.
6. Release brick (collapse), alarm (AI).
6b. Hydraulics (section 11), finite water only: pipes as a second medium of
   the same nets, hydraulic budget (12), hose reel,
   intake, pump, valve, outlet, pressure sensor, hydraulic piston.
7. Transmitter/receiver, channel = two antenna colours; conductive brick variants.
8. Later: traps the world generates (dungeons, towers stamped into the field).

## 11. Hydraulics: water pressure as part of the wiring

### 11.1 What the water system gives today

- `BrickFluid` (MineWater.md) is cells of 1 stud x 1 brick with a level in
  half tiles, kinds source / flowing / falling / still. **Still water is a
  conserved volume** (whole units, never made or lost except by drying);
  sources are infinite (the sea, lakes, rivers, springs).
- It has **no pressure**: water does not rise up the far side of a U-bend
  (MineWater.md 4.5, "STA's compression term could add it later").
- From outside it offers what a hydraulic part needs, all CPU side and
  thread-safe: `cell_info(cell)` (fluid, kind, amount, capacity),
  `surface_at(p)`, `fluid_at(p)`, `place(cell, fluid, kind, amount)`,
  `remove(cell, amount)`, and `terrain_changed` when bricks move. Commands
  are applied with the next tick; queries read the last applied state.

So hydraulics do **not** need pressure inside the water sim. They need it in
the pipes, and the pipes are a wiring net.

### 11.2 The idea: a pipe is a wire whose level is pressure

- **Pipe parts** are a second medium in the same sparse layer and the same
  net code as cable tiles: a 1x1 hose tile laid on studs, a pipe brick that
  carries through a wall (as a conductive brick does), bends and T's. LEGO's
  own Technic pneumatics (pump, switch valve, cylinder, hose) are the look:
  real parts, seen and shot. A pipe never joins a cable: they are two nets.
- A pipe net's level is its **pressure, 0-15**, the same number a wire net
  carries, so every device that reads a level reads either.
- **Pressure comes from head**, read from the water, not simulated in the
  pipe: an **intake** brick under water reads its cell and the surface above
  it; pressure = the water's depth over the intake in bricks (0.42 m), capped
  at 15 (6.3 m).
- **Only finite water has pressure** (the user, 2026-11-25). An intake counts
  only STILL water (MineWater.md 4.2: a conserved volume). Sources -- the sea,
  lakes, rivers, springs, a source bucket's water -- give **0**: an intake
  dropped in the ocean does nothing. Pressure is something the player
  gathers: buckets carried up a hill, rain caught in a cistern (rain lands as
  still water, MineWater.md R10), a pond dug and filled. It falls as the
  water is used, and a pond's intake falls as the pond drains. A net with several intakes takes the
  highest. A reservoir built up a hill is a **battery you can see**: the dam
  is the charge, and a shot that breaches it empties it (the water runs out
  by its own rules).
- **A pump** is the bridge from the electric side: powered by a wire, it
  gives full pressure from any STILL water touching it, whatever the head
  (it moves a finite volume; next to a source it does nothing).
- **A valve** (a gate brick on a pipe, opened by a wire) joins or cuts two
  pipe nets. A **pressure sensor** turns pressure into a wire signal of the
  same level (hydraulic to electric).
- **Closed parts use no water.** A hydraulic piston or ram only reads the
  pressure (Technic cylinders are a closed system). Its push limit is its
  pressure: 1 brick per level (a 6 m head pushes 15 bricks, a puddle pushes
  none). Hydraulic pistons are the strong ones; electric ones push 12.
- **Open parts move real water.** An **outlet** brick on a pressured net
  `place`s water in front of it and the net `remove`s the same amount from
  an intake's cell, so still water is conserved: draining a pond into a room
  floods it by exactly the pond's volume. There is no infinite outlet: a
  pipe never carries source water. A **jet** is an outlet with force: it pushes
  bodies along its line (fountains, a trap that blows the player off a ledge).
- **A broken pipe leaks.** When a shot, a grenade or a collapse breaks a
  pipe cell of a pressured net, the break becomes an outlet: water sprays
  out until the net is valved off or the source is dry. Shooting a pipe is
  how you stop (or start) a hydraulic machine.
- **Lava pipes:** same rules, lava's tick (2 Hz). Lava burns wooden pipes
  (`material_burns`).

### 11.3 Why not real pressure in the water sim

Water rising through a U-bend, communicating vessels and pressure pushing
through gaps would need a pressure term in every cell (STA's compression),
woken over whole bodies. That is a change to the water's core rules, its
cost (a lake would never sleep) and its saves, for an effect players mostly
meet inside pipes. Pipes as nets read the water's state once a tick at
their intakes and cost nothing while still. If one day the water gets real
pressure, the intake reads it instead of the head; nothing else changes.

### 11.4 How it runs

- In the wiring tick (10 Hz): each pipe net whose intakes' cells changed is
  read again (`cell_info` at the intake, the water's last applied state);
  its pressure changes the devices on it as any level does.
- Outlets and leaks hand `place` / `remove` commands to the water for its
  next tick, at most a few units an outlet a tick (so a burst pipe gushes but
  cannot empty a lake in a frame), conserving still water.
- A pipe placed or broken rebuilds its net like a wire.
- Saved with the wire layer; the water saves its own cells as now.

### 11.5 Traps and machines it adds

| | Built from |
|---|---|
| Flood room | pressure plate -> valve -> outlets from a cistern's intake (the room fills by the cistern's volume) |
| Lava chute | trip string -> valve on a lava pipe -> outlet over a corridor |
| Water jet | motion sensor -> pump -> jet: blows the player off a bridge |
| Hydraulic crusher / gate | a reservoir's pressure drives rams that push 15 bricks; drain the reservoir (shoot the dam) to stop them |
| Drain trap | a valve opens a pipe under a pool: the water runs out and what floated sinks |
| Fountain, irrigation | outlets on a cistern net, refilled by rain (farming: Docs/MineFarming.md) |
| Leak sabotage | shoot an enemy base's pipe: it sprays and its machines lose pressure |

## 12. What Create (the Minecraft mod) teaches this plan (2026-11-25)

The user asked what in Create would help. Create's power is rotation
(axles, cogs) measured in stress units; its big idea is the **contraption**.
What carries over, what changes, what does not:

| Create | What it is there | Here | Stage |
|---|---|---|---|
| **Contraptions** | a mover (piston, bearing, rope pulley, gantry) turns a group of blocks into ONE moving entity, places them back as blocks when it stops; size has a limit | exactly section 6.1's stand-in, made general: the moving group is laid into a chunk (as the collapse's pieces are) and drawn and collided as one body, then written back into the field. One mover type gives pistons, lifts, gantries and turntables | 4 |
| **Super glue, chassis** | say which blocks move together | not needed: **stud clutch picks the group** (6.3). The inverse is the builder's tool: **a smooth tile does not clutch**, so a course of tiles is where a moving part ends (a door on a tile sill comes away from the frame) | 4 |
| **Mechanical bearing** | rotates a contraption: windmills, doors, drawbridges | a **turntable brick** (LEGO has turntables and hinges) turning a group in 90-degree steps on the stud grid, animated between. Drawbridge trap, rotating wall, revolving secret door | 4b |
| **Rope pulley, elevator** | lifts a group on a rope | a **winch**: a lift, a dropping cage, a portcullis | 4b |
| **Riding contraptions** | players stand on moving ones | the project's carried-by-contact rule (Hulls.md 7b.3): touching a moving group makes you its passenger | 4 |
| **Stress units, overstress** | sources give capacity, machines use it; over the limit the WHOLE network stops; one number to read | the **hydraulic budget**: a pipe net's pressure is its capacity, each ram moving takes its load (bricks pushed); over it, every ram on the net stalls until load falls or pressure rises. Simple, readable, and it makes the cistern's height matter | 6b |
| **Engineer's goggles** | look at a part: speed, stress, overstressed | the **view tool** (3.3) shows a net's level, pressure, load / capacity. Lesson from Create's add-ons (Stethoscope, Kinetic Lens): show the **whole net's** sum, not one part | 2 |
| **Wrench** | turn a part's facing, pick it up without breaking it | the same tool as the view tool: one hand for "look, turn, take" | 2 |
| **Redstone Link** | wireless, the channel is a PAIR of items in two slots | the antenna channel is **two colours** (two 1x1 rounds on top): many channels, hard to guess, each end still a brick | 7 |
| **Sequenced gearshift** | a small program: turn 90, wait, turn back | a **sequencer brick**: steps of "extend n / wait t / retract" set in a small panel. Crushers, airlocks, staged doors without a clock circuit | 3 |
| **Deployer, drill, saw** | a part that uses an item, breaks blocks, rides a contraption | a **placer** (lays a block from its slots) and a **breaker** (breaks the brick in front, as a pickaxe). On a piston: a wall that seals behind you, a tunnel bore | 5 |
| **Hose pulley** | lowers a hose to drain or fill a fluid body | a **hose reel**: an intake on a hose lowered into a pond or cistern; reads and draws STILL water only (11.2) | 6b |
| **Fluid tank** | stores fluid, multi-block | not a block: a cistern of bricks with real water in it is the tank (seen, shot, leaked). A compact tank brick only if play asks for it | -- |
| **Ponder** | hold a key over an item: a little animated scene shows how it works | **worth copying**: wiring is the hardest thing in the game to learn. A tiny diorama per part (lever -> cable -> lamp; piston hop; cistern -> ram) played in the inventory | 2+ |
| **Display link, nixie tubes** | show numbers from machines | a **number tile** (printed 1x2 tile) shows a net's level: counters, pressure gauges | 3 |
| Belts, funnels, chutes, trains, schematicannon | item logistics, transport, printing builds | out of scope for wiring; belts and funnels later with the inventory | -- |
| Rotation as the power itself | axles, cogs, RPM | **hydraulics take that role** (gathered finite water, a budget, sources you can see and break). Rotation stays a "maybe later" (9.6) | -- |

Create's warnings worth keeping: contraptions are entities and each costs,
so cap how many move at once (as PlanetPieces caps pieces); and its size
limit is a config number, as our push limit is.

## 13. Stage 1, built (2026-11-25)

`scripts/wiring/mine_wiring.gd` (`MineWiring`, a child of the mine world,
terrain frame, like the chests), items in `content/base/data/items/wiring.json`.

- **Cable tile** (`cable`, kind `wire`): RMB on the ground's top lays one in
  the plate cell over it (air, ground under). Drawn as a dark smooth tile
  with a cable on top, arms toward its linked neighbours; a powered net's
  cable glows orange, an unpowered one is dull copper. Two MultiMeshes for
  every cable, one small shader (instance colour, its alpha the glow);
  rebuilt whole when anything changes (fine at stage 1's counts; per terrain
  tile when big builds need it). No collider.
- **Links**: four sides, up or down a step of up to 3 plates (a brick), so a
  run climbs a placed block. Devices never join nets.
- **Lever** (`lever`, kind `device`): 1 stud x 1 brick, stands on ground;
  RMB turns it (whatever is in the hand); on, it drives 15. **Lamp**: lit
  while a net beside it is above 0 or a lever touches it; a clear brick that
  glows, an OmniLight (4.5 m, no shadow) while lit, a collider on WORLD.
- **The tick**: 10 Hz in `_process`, and only does work when something
  changed: changed cables re-flood only the nets they touched
  (`last_flooded`), then levels, then the drawing. Main thread for now: the
  flood is small; a worker when a large build shows a cost.
- **Breaking**: LMB on a cable (the builder aims at a cable lying on the top
  it looks at, and LMB takes it, not the ground) or a device; a shot at a
  cable's spot cuts it (`MineWorld._mine` asks the wiring after the chests); a
  grenade's blast clears its radius; `terrain_edited` runs `check` over the
  edit's box (a cell filled, or the ground under it gone). Survival drops
  the item. A block is not placed into a device; placed over a cable, the
  cable breaks.
- **Saved** in the world file beside the chests: `"wiring": {"cables": [x, y,
  z, ...], "devices": {"x,y,z": {"item", "on"}}}`.
- **The kit**: not added automatically (the kit's storage must start empty
  for `--gate=inventory`); in creative take them from the catalog (E,
  Storage).
- **Not yet**: the view tool, conductive bricks, sky light on the cables and
  devices in caves (they are lit as outdoors), lamps' lights are one
  OmniLight each (fine for tens, not hundreds).

Tests: `tools/probes/wiring_probe.gd` (headless, its own ground: nets,
climbing, devices not conducting, power, a cut, support, shots, blasts, the
partial re-flood, save round trip, items) -- 39 ok. `-- --gate=wiring`
(`scripts/wiring/wiring_gate.gd`): laid with the builder's RMB, aimed and
taken with LMB, the lever lights both lamps (one up a climb), a real shot
cuts a run (its lamp dark, the other branch lit), dug-out ground breaks a
cable, generated again: all back. Pictures `user://dev/wiring_on.png`,
`wiring_cut.png`.

## Sources

- Minecraft quasi-connectivity: <https://techmcdocs.github.io/pages/GameMechanics/QuasiConnectivity>,
  block updates: <https://techmcdocs.github.io/pages/GameMechanics/BlockUpdates>,
  a location-dependent QC report: <https://bugs-legacy.mojang.com/browse/MC-179787>
- Terraria wiring: <https://terraria.wiki.gg/wiki/Guide:Wiring>, <https://terraria.wiki.gg/wiki/Wires>,
  The Grand Design: <https://terraria.wiki.gg/wiki/The_Grand_Design>
- Brickadia: EA3 changelog <https://brickadia.com/blog/ea3-release/>, devlog 8 (Wires V2)
  <https://brickadia.com/blog/devlog-8/>, EA3 patch 1 <https://brickadia.com/blog/early-access-3-patch-1/>
- Hytale: launch post <https://hytale.com/news/2026/1/hytale-is-finally-here>, no official roadmap
  <https://hytalesl.io/wiki/hytale-roadmap/>, fan list <https://www.hyguilds.com/hytale-future-roadmap>,
  Logica mod <https://www.curseforge.com/hytale/mods/logica>
- Create: contraptions <https://mintlify.wiki/Creators-of-Create/Create/concepts/contraptions>,
  moving contraptions <https://git.grimmauld.de/mirrors/Create/wiki/Moving-Contraptions>,
  stress <https://create.fandom.com/wiki/Kinetic_Stress>,
  <https://mintlify.wiki/Creators-of-Create/Create/concepts/stress-system>,
  Stethoscope add-on <https://www.curseforge.com/minecraft/mc-mods/create-stethoscope>
- LEGO Technic pneumatics (pump, switch valve, cylinder, hose) are the
  look for pipes; no source needed.
- Vintage Story mechanical power: <https://wiki.vintagestory.at/Special:MyLanguage/Mechanical_Power>
- Scrap Mechanic logic: <https://www.gamewatcher.com/scrap-mechanic-logic-gates-what-are-how>,
  connect tools mod <https://steamcommunity.com/sharedfiles/filedetails/changelog/2289714402>
