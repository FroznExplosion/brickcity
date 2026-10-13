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

## 3. Studs go on the part's own faces

Decided 2026-10-15, after two tries at more: **the model's shape is not changed. It is cut into
parts, and studs are added.** No resizing, no softened edges, no faces moved, no pad under a patch.

| Rule | |
|---|---|
| a stud stands square to its face | whichever way the face points: up, sideways, or along a slanted facet. Its foot is on the facet, its axis is the facet's normal |
| studs come in neat patches | a run of nearly flat facets is one face; a grid of the stud pitch is laid on it, along the gun, and the biggest whole rectangle that fits gets studs |
| a stud is whole | all of it on the face with a lip round it, and nothing of the gun over it |
| not everywhere | no studs underneath (sockets go there), none on the ends where parts join, none on a grip or a barrel |

**The lattice** (the nano grid fixed to the part: 4 mm by 4 mm by 1.6 mm) still places every mount
and socket. For studs it is where a face's grid starts, and the grid is then slid to where the
most studs fit; the lattice's own position wins a tie. So studs on one face are always a stud
pitch apart, but studs on two different faces line up with each other only where that cost
nothing. On the first rifle one face in ten kept the lattice. If bricks must bridge two faces or
two parts, those faces have to be told to keep it, and take fewer studs.

## 4. Guns are assembled by slot

The game already assembles a gun from parts (`scripts/guns/gun_assembler.gd`): a receiving part has
empties named `socket_<slot>`, an attaching part has one named `mount`, and the two are made to
coincide. Bare gun parts are those parts, so a rolled gun needs no new code:

- **Every part of a slot puts its `mount` and its sockets in the same place for that slot**, on the
  lattice. Any stock goes on any body; that is what a procedural gun needs from its parts.
- The physical connector at a `mount` is the slot's own (spec section 7): a keyed dovetail for a
  barrel or a stock, pin-and-clip for a grip or a magazine, studs for a sight.
- **The grip has a round core**, 3.2 mm across -- the bar a brick figure's C hand grips, the
  same size as every joint pin -- and at least 14.4 mm long, eight-sided like a stud. The styled
  grip is built round it, but where the hand closes it is that core, so a C hand fits every grip
  ([joints.md](joints.md) section 7).
- **A sight is a single piece pressed onto a rail**, as one brick is pressed onto studs. A rail
  is a row of studs: a flat top has one moulded in; a carry handle has a short row of its own
  (`sight.handle`) that takes an **adapter** (`adapter_handle_rail`) with a rail on top. Planned:
  a gooseneck adapter that reaches forward off the handle, and bodies whose sights are moulded in
  and take none.
- A module is a part whose connector the game lets go of: `module: reload` or `module: overheat`
  on the part, and an animation that takes the hand to it.

### 4.1 Interfaces, platforms and adapters

Not every stock goes on every gun, and that is wanted: guns come in families. What decides it is
the **interface** at the joint, and the rule is one line: **a mount joins a socket of the same slot
and the same interface.**

| | What | Example |
|---|---|---|
| **interface** | a named connector shape for one slot | `stock.tube`: a post out of the body's back, in line with the barrel. `stock.tang`: a flat tongue low on the body |
| **platform** | a body's set of sockets, one interface per slot. Bodies of a platform take the same parts | `A`: tube stock, narrow magazine. `B`: tang stock, wide magazine |
| **adapter** | a small part whose mount is one interface and whose socket is another | `adapter_tang_tube` lets any tube stock go on a tang body |

So the rules "per gun" are per platform, shared by every gun of it, and a part made for one
platform reaches another through an adapter. The lists are in [standards.json](standards.json)
(`gun_interfaces`, `gun_platforms`, `gun_adapters`) and are a first set, to grow.

The interfaces are our own shapes on the nano grid. None copies a real firearm's fitting or its
dimensions (spec section 7), and the data does not use real guns' names.

For the generator this is one more filter when it fills a socket: parts of that slot whose mount
is the socket's interface, or reaches it through an adapter it then adds. `GunAssembler` matches by
slot alone today; the interface has to be carried on `GunPartDef` and on the socket. Not built.

### 4.2 Dressing breaks off a brick at a time

Armour on a mech or a figure, and anything else pressed onto studs, comes off **per brick**: each
dressing brick has its own hit points and leaves on its own. Bricks may be grouped into a plate
that leaves as one where per brick costs too much; the group is a field on the dressing, not a
different kind of part. `VehicleBricks` (scripts/ai/vehicles) already does this for a tank's zones.

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

**Built so far, from bought models (stand-ins):** [partkit.py](../../tools/brickify/partkit.py)
and [rifle_a.json](../../tools/brickify/sheets/rifle_a.json): a model cut into five bare parts by
its own shells, studs square to its faces.

**Built so far, our own:** [gunsmith.py](../../tools/brickify/gunsmith.py) and
[smg_a.json](../../tools/brickify/sheets/smg_a.json), a drum-and-stick submachine gun drawn in the
sheet. A part is one of three kinds: **bricks** (an outline filled by the packer, its top tiled
but for the studs a sight sits on), **profile** (an outline with a thickness and cut-back edges:
one closed solid, with stud patches on its sides and, where asked, the underside of a brick), and
**turned** (round about the bore). First pass: 18 bricks and 7 custom parts, 46 studs, every joint
on the lattice. Still to come: slopes and curves on the brick-built parts, finer custom shapes,
the interfaces' own shapes, dressing, STLs, and a scene the game's gun system loads.
