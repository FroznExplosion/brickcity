# Custom parts, dressing and modules

How a gun or a mech is put together, and how its parts are made. Decided 2026-10-14, replacing
"turn the whole model into bricks": a gun made only of bricks reads as a wall of them, one stud
thick ([brickify](../../tools/brickify/brickify.py) stage 1 showed it). The shape comes from custom
parts; the bricks go **on** them.

Nothing here is built yet. Numbers are in [standards.json](standards.json).

## 1. Three roles

| Role | What it is | In the game |
|---|---|---|
| **bare** | a custom part: one piece, its shape cut from a 3D model, with studs and sockets where bricks or other parts go | never breaks off. A mech's limbs stay on, short of a takedown |
| **dressing** | ordinary nano bricks ([nano.md](nano.md)) pressed onto a bare part's studs | style, and what a fight takes away: armour breaks off a mech brick by brick and leaves it barer |
| **module** | a part on a connector that play takes off and puts back | a magazine, a battery that pops off the side when it is spent, a barrel pulled after an overheat |

A bare part with nothing on it is a whole, working gun or mech. Dressing is where the variety is
cheap: the same bare parts with different bricks, colours and amounts on them are different guns.

## 2. What is bare

**Guns:** one bare part per slot of the gun system (`GunPartDef.Slot`): body, barrel, stock, grip,
magazine, sight, muzzle, underbarrel. A handguard is a barrel's or an underbarrel's.

**Mechs:** the chassis (hips and torso), each arm and leg segment, the hatch, the head. One per
bone ([joints.md](joints.md) section 5), joined by its joints.

**Figures** are bare all through.

## 3. One lattice per part

Every bare part carries a lattice: the nano grid, 4 mm by 4 mm by 1.6 mm, fixed to the part.
**Every stud, socket and connector on the part sits on it.** That is the whole rule, and it is what
lets bricks on two faces of one part, or on two parts joined together, line up and bridge.

| Feature | Where | Rule |
|---|---|---|
| stud patch, top | flat or flattened tops: a rail along a body, the top of a handguard | studs on lattice points, a nano stud each |
| stud patch, side | the flanks of a stock, a body, a limb | the same studs turned on their side, placed as a bracket's side studs are ([README](README.md) section 3): bricks stuck on them still land on the lattice |
| socket patch, underside | under a stock, a handguard, a forearm | the underside of a brick, so the bottom reads as built and takes a brick from below |
| connector | where the next part joins | the part's `mount`, or a `socket_<slot>`, on a lattice point |

A patch goes only where it makes sense: where a brick would sit flat, where a hand does not go,
where a module does not slide. The surface under a patch is made flat to the lattice plane; the
shape between patches is free.

## 4. Guns are assembled by slot

The game already assembles a gun from parts (`scripts/guns/gun_assembler.gd`): a receiving part has
empties named `socket_<slot>`, an attaching part has one named `mount`, and the two are made to
coincide. Bare gun parts are those parts, so a rolled gun needs no new code:

- **Every part of a slot puts its `mount` and its sockets in the same place for that slot**, on the
  lattice. Any stock goes on any body; that is what a procedural gun needs from its parts.
- The physical connector at a `mount` is the slot's own (spec section 7): a keyed dovetail for a
  barrel or a stock, pin-and-clip for a grip or a magazine, studs for a sight.
- **The grip has a round core**, 4.8 mm across (a full stud's size) and at least 14.4 mm long,
  eight-sided like a stud. The styled grip is built round it, but where the hand closes it is that
  core, so a C hand fits every grip ([joints.md](joints.md) section 7).
- A module is a part whose connector the game lets go of: `module: reload` or `module: overheat`
  on the part, and an animation that takes the hand to it.

## 5. How parts are made: rules in code, AI at the controls

Neither "let an AI model it in Blender" nor "convert it automatically" alone. Three layers:

| Layer | What | Who decides |
|---|---|---|
| **standards** | every size: studs, pins, the grip core, lattice, clearances ([standards.json](standards.json)) | the user. Never the AI, never a script |
| **the kit** | Blender functions that make each standard feature exactly: cut a part from a model, flatten a face to the lattice, add a stud patch, a socket patch, a `mount`, a grip core, a joint; and a **checker** that measures the result against the standards | code. A stud is made by the function or not at all |
| **the build sheet** | one small file per asset: which model, which grid, what parts to cut it into and where, which faces get patches, which are modules | an AI, looking at pictures of the model, within the parameters the user sets. The user approves the pictures |

The AI never models a stud, so it cannot get one wrong; it chooses *where*, and the kit and the
checker hold every dimension. The build sheet is saved, so an asset is rebuilt from it with no AI
at all -- which is what happens to every asset the day a standard changes.

The parameters the user sets for a job: the grid (nano or full), the parts to split into (the gun
slots, a mech's bones, or a list), which parts are bare and which are bricks, and how much dressing.

**What brickify is for now:** dressing (filling a volume on a bare part with bricks), anything
that should be all bricks (world props, buildings), and an all-brick variant of a part when one is
wanted.
