# Modular parts: guns, mechs, figures, animals

One part system for everything that is built from swappable pieces: a gun's barrel, a mech's
left leg, a figure's torso, a shoulder pod. Every part is saved on its own, carries what it
mounts with and what it takes, and is found in one catalogue that filters and sorts the same way
for all of them. A gun or a mech is then an **assembly**: a list of part ids, made by hand or
rolled from a seed.

Status: design, 2026-10-23. Nothing here is built. Section 11 is the order it is built in.

Builds on: [Parts/joints.md](Parts/joints.md) (joints, the one pin, hands),
[Parts/standards.json](Parts/standards.json) (`gun_interfaces`, `gun_platforms`, `gun_adapters`,
`part_roles`), [AssetWorkshop.md](AssetWorkshop.md) (where parts are made),
[Weapons/MANUFACTURER_SPEC.md](Weapons/MANUFACTURER_SPEC.md) (brands, effects, compat is data),
[AIRoster.md](AIRoster.md) R6 (mech classes), [Creatures/README.md](Creatures/README.md).

---

## 1. Where it starts from

| Piece | Today |
|---|---|
| Asset workshop, Make a mech | `ASSET_KINDS` in `asset_workshop.gd` only picks the save folder; the part toolbars are the gun's (`GUN_PARTS`) |
| Gun compatibility | `standards.json` already names interfaces (`mag.narrow`, `stock.tube` ...), platforms (a body's set of sockets) and adapters. The workshop's J tool places a mount or a socket with one. But `GunAssembler` joins by **slot name only** and never checks the interface |
| Workshop guns in the game | one folder per gun (`AssetGuns`), its parts fenced to it with `exclusive_to`: not parts anyone else can use |
| Mech in the game | `mech.gd`: boxes, no skeleton, no animation. Nothing to break |
| Figures | `view_arms.gd` (first-person arms); figure joints in joints.md section 4 |
| Animals | `scripts/creatures/`: procedural meshes from DNA, not brick parts |

---

## 2. The part record

One record shape for every family. One folder per part:

    res://parts/<family>/<id>/part.json      official, shipped
    user://parts/custom/<id>/part.json       made by a player, or downloaded (section 7)

```
id            "korr_arm_heavy_01"        unique; a custom part's is "<creator>.<name>.<hash8>"
rev           3                          bumped on every save that changes it
family        gun | mech | figure | creature | pod
slot          arm | leg | hand | chassis | head | pod | barrel | magazine | ...
side          L | R | any                + mirrorable: a right twin may be made by mirroring
manufacturer  "korr"                     custom parts keep theirs, or "workshop"
class         light | normal | heavy     only where it means something (section 4)
source        official | custom
creator       {name, steam_id}           custom only; shown on the card
tags          ["armored", "scoped"]      flavour and filtering; NEVER compatibility
mount         {interface: "mech.shoulder", params: {length: 2}}
sockets       [{name, interface, accepts: [...], frame, envelope}]
motion        motion set it asks for (section 8), or none
effect_id, effect_params, stats         as GunPartDef has now; limbs have none (section 4)
bricks        the part's bricks (the recipe), studs, mass
mesh          the built mesh, as data (section 7: never a scene with code)
```

`GunPartDef` keeps working: a gun part record makes a `GunPartDef` as `AssetGuns.parts` does
today, so the generator, cards and saves change as little as possible.

---

## 3. Fitting: three layers

1. **Interface (hard).** A part fits a socket when its `mount.interface` is in the socket's
   `accepts`. A magazine mounting on `mag.narrow` fits every receiver whose magazine socket
   accepts `mag.narrow`. Interfaces are a fixed list in `standards.json`, picked from a menu,
   never typed: a typo cannot quietly break a fit. Names are ours and describe the shape
   (`mag.narrow`, not a real gun's name); the gun names the player sees come from the naming
   system, not from interfaces.
2. **Assembly rules (hard, the whole build).** Both legs the same `length`; every required slot
   filled; `exclusive_to`; at most one adapter between two parts (no chains).
3. **Weights (soft, the generator only).** Manufacturer, class, rarity, as guns roll now.

An **adapter** is a part whose mount is one interface and whose socket another
(`adapter_mag_wide_narrow`), as `gun_adapters` has them. A socket that takes two kinds lists both
in `accepts`.

**The workshop ignores all three** (section 9): anything goes on any slot of its kind there, and
what does not fit is marked, not refused.

---

## 4. Mechs

### Slots

| Slot | How many | Mounts with | Carries |
|---|---|---|---|
| chassis | 1 | root | the cockpit, hatch, power cell door; the mech's **class** and all its stats |
| head | 1 | `mech.neck` | looks |
| arm | L, R | `mech.shoulder` | looks. Socket `mech.wrist` |
| hand | L, R | `mech.wrist` | looks; holds the gun. Hands may be mismatched |
| leg | L, R | `mech.hip`, `length` 1/2/3 | looks. Two different legs are fine; their lengths must match |
| pod | 2 | `mech.pod` | the mech's specials (below) |

- **Class is the chassis's.** Light, normal or heavy comes from the chassis alone, with its
  shield, armour, speed and hatch side (front on normal and heavy, back on light: AIRoster R6).
  Arms, hands, legs and head are **cosmetic**: no stats, any class on any chassis. A light
  chassis with heavy arms is a light mech that looks heavy.
- **Arms hold guns, never are guns.** Every mech has hands; the wrist takes a hand, the hand
  holds a mech gun from the gun system.
- **The chassis says where, the interface says what.** A heavy chassis puts its shoulder sockets
  further out than a light one; every one of them still takes `mech.shoulder`. The joints are
  joints.md section 5's, the one 3.2 mm pin.
- **Leg length.** `length` is hip to ground in three steps for players' mechs. The engine takes
  any value: a boss can have legs shorter or taller than the three, with no change to the code.
  The cockpit eye, the camera, rodeo points and the hatch all ride on the chassis, so their height
  is hip height plus the chassis's own: **nothing may assume `COCKPIT_Y` is fixed** once legs vary.
- **Envelopes.** Every socket has a box its part must fit in, plus the space the joint sweeps
  (joints.md's clearance volume). That is what stops a heavy arm clipping into a light chassis or
  a leg as it swings, and a pod covering the hatch, the cell door or the arm's path.

### Pods

Two pod slots on every chassis, `pod_L` and `pod_R`, on top of it, apart from the arms. The pods
are the mech's special weapons and buffs, and what the player picks for them is their play.

| Kind | Moves | Examples |
|---|---|---|
| active, animated | its own small rig and motion set (section 8) | extra arm over the shoulder: heavy melee strike, grenade throw |
| active, fixed | aims with the torso, no rig | missile launcher, laser shot |
| passive | nothing | shield booster, directional shield |

- Pods are **rolled like guns**: kind, manufacturer, rarity and effects from a seed (a
  `PodGenerator` beside `GunGenerator`), with the same effect list so stacking and merges are
  one rule (MANUFACTURER_SPEC section 8).
- Players fit them in their **inventory screen**, not the workshop (the workshop makes pod
  bodies; the game rolls pods onto them).
- Two pods of one kind: allowed; their effects stack by the one rule.

### Studs: dressing

Outside the workshop a player can put bricks on a part's studs: the `dressing` role of
`part_roles`. Dressing is stored on the **part as the player owns it** (the instance), keyed by
stud, and goes with the part when it is swapped to another mech. It may not cross a joint (one
bone, one rigid assembly), may not enter a sweep, adds mass, and breaks off as debris.

---

## 5. Guns

- Slots stay as `GunPartDef.Slot`. A receiver's sockets are its **platform** (`gun_platforms`).
- `GunAssembler` checks the interface as well as the slot (layer 1).
- The weapon-class filter (section 6) is worked out, not tagged: a receiver is its class; any
  other part is in every class whose receivers it fits.
- A gun made whole in the workshop is exported **as its parts plus an assembly**: each part
  joins the catalogue, the assembly is the design. `exclusive_to` stays for a design's signature
  parts (legendaries, or a gun whose maker wants it kept whole).

---

## 6. The catalogue: filter and sort

Every part has **facets**: family, source (official / custom), manufacturer, slot, side, class
(mech, figure), weapon class (gun), pod kind, rarity, creator, tags.

- **OR inside a facet, AND across facets.** "Light" alone shows every light part of any brand;
  "legs" alone every leg; "Korr + Vex, arms, heavy" what it says; "custom, by <name>" a creator's
  parts.
- **Manufacturer, then part** is only the default **grouping** of the list, not an order the
  filters must be used in.
- **Fits** toggle: only what passes layer 1 and 2 against the build being looked at.
- **Sort**: name, manufacturer, class, rarity, mass, newest, creator. Ties break on id, so the
  order is always the same.
- Custom parts sit in the same list as official ones, marked custom and with their creator.

---

## 7. Custom parts, sharing and multiplayer

### Saving and the package

A player's part is saved by name in `user://parts/custom/`, apart from the official ones. Export
writes one file, a **part package** (`.bcpart`, a zip):

| In it | Why |
|---|---|
| `part.json` | the record: everything in section 2, creator included |
| the bricks | so it can be rebuilt, edited, printed |
| the mesh, as arrays | so it shows without rebuilding |
| the interfaces it uses, with their `standards.json` version | so an older game can say what it is missing |
| a thumbnail | the catalogue card |
| a content hash | its identity across machines |

**A package holds data only: no scenes, no scripts.** A `.scn`/`.tscn` can carry a script, and a
part from another player must never run code here. The game builds the part's node from the
arrays. A package that fails its hash, its size limit or the schema is refused.

Downloaded, it lands in `user://parts/custom/` like the player's own, with everything it came with.

### In a match

The host's lobby lists what the match needs: each part's id and hash. A client checks its cache;
for each missing part:

1. it has a **Steam Workshop** item id: subscribe and download (GodotSteam UGC), and keep it;
2. else **from the host**, in chunks over the game's own connection, to a size cap, into the
   cache (a match-only part can be dropped after, or kept).

Joining waits for the download, with a bar. A part that cannot come shows as a placeholder of its
slot and its mech still plays.

- A part's id never changes; an edit is a new `rev` and a new hash, so a match always has the
  exact version the host used.
- Saves and assemblies name `id` + `rev`; a missing one loads as a placeholder, and loads properly
  once the part is back.
- New parts join the library **at the end** (as `AssetGuns.add_to` already does), so no existing
  seed rolls differently.

---

## 8. Motion sets: one animation library for everything

Guns, mechs, figures, animals and pods all pick their animation from one library of **motion
sets**, by what the build is, not by hand per model.

- A motion set is either **clips** (Mixamo-named bones, as `view_arms.gd` uses: a figure's walk,
  a receiver's reload) or a **procedural** mover (IK legs for any length, an n-legged gait, an
  aim chain).
- Each set says what it needs: a **body plan** and the bones or chains it drives. A build asks
  by tags (`biped`, `quad`, `hexapod`, `reload.mag`, `pod.arm`) and gets the best set its
  skeleton satisfies; a user picks another from the ones that satisfy it.
- **Lengths come from the parts.** Procedural sets read leg and arm length from the assembly, so
  one mech walk serves all three leg lengths and the bosses'.
- **Animals with 1 to 10 legs**: the creatures' DNA already makes a gait from the morphology
  (`GaitController`). That becomes the procedural motion set for animal body plans; clip sets can
  be added beside it.

---

## 9. The workshop: anything on anything

In the asset workshop every slot takes **any part of its kind**, fitting or not. Pick a barrel
from the catalogue: it spawns and snaps to the barrel socket, wherever that receiver's socket is.
That is how parts are seen together, tried and fixed.

- What does not fit is drawn with a **mark** and the reason ("mounts `mag.wide`, socket takes
  `mag.narrow`"; "legs 2 and 3 long"; "pod covers the hatch").
- A part with no socket for it (a mech leg on a gun) cannot be picked: same kind only.
- With no interface match the part snaps mount frame to socket frame anyway; where neither has
  a frame, origin to socket.

Mech mode in the workshop:

- pick the **slot, side and class**: the build area shows a **reference mech** with the standard
  joints and the chassis's sockets, so the part is built round its mount, and the mount and
  sockets for that slot are laid ready (J moves them).
- **test fit**: load any catalogue part onto any joint beside the one being built.

---

## 10. Figures and animals

The same record and code, with a **body plan** per family: the skeleton template and its
interfaces.

| Body plan | Interfaces |
|---|---|
| `mech` | `mech.neck`, `mech.shoulder`, `mech.wrist`, `mech.hip`, `mech.pod` |
| `figure` (humanoid, 8 nano bricks) | `fig.neck`, `fig.waist`, `fig.shoulder`, `fig.wrist`, `fig.hip` |
| animals, later: `quad`, `hexapod` ... `n_leg` | per plan |

- Every figure torso has the same neck, shoulder and hip sockets, so any figure's head, arms and
  legs go on any other's: an action figure. Figures are one size, so their legs are one length
  until a big or small figure wants a step.
- **Animals are their own catalogue** for now, their body plans apart from the figure's. A part
  meant to cross (an animal head on a figure) mounts with the other plan's interface.

---

## 11. The order it is built in

| # | Stage | Where |
|---|---|---|
| 1 | The part record, the catalogue (facets, filter, sort), the fit check (layers 1-2), `mech_interfaces` / `figure_interfaces` / `body_plans` in `standards.json`; a headless probe | new `scripts/parts/` |
| 2 | Guns on it: `GunAssembler` checks interfaces; the workshop exports each part on its own plus an assembly; `guns/` moved over | `scripts/guns/`, `asset_workshop.gd` |
| 3 | The catalogue panel: filters, sort, custom and creator, the Fits toggle | UI, shared by workshop and inventory |
| 4 | The workshop's anything-on-anything swap, with fit marks (section 9) | `asset_workshop.gd` |
| 5 | The workshop's mech mode: slot, side, class, reference mech, ready mounts, test fit | `asset_workshop.gd` |
| 6 | Mechs in the game from parts: a mech assembler on a skeleton, IK legs and arms by length, class from the chassis; replaces the boxes in `mech.gd` | `scripts/mech/` |
| 7 | Pods: slots, `PodGenerator`, the three kinds, the inventory screen | `scripts/mech/`, loot |
| 8 | Motion sets library (section 8) | |
| 9 | Part packages: export, import, hash, data-only loading | `scripts/parts/` |
| 10 | Multiplayer: lobby part list, host download, Steam Workshop | with the netcode |
| 11 | Dressing on studs outside the workshop | |
| 12 | The figure body plan; animals later | |

---

## 12. Open

- **Forced fits outside the workshop.** The workshop lets anything go on anything. Can a design
  saved with a mark (an unfit barrel) be used in the game, or does it have to fit there?
  Proposed: official designs may ship forced (made by us, on purpose); a player's forced design
  is workshop-only until it fits, so a downloaded part never makes an impossible gun in a match.
- **Pod names and the naming system.** Guns name themselves from parts' `name_fragment`s and
  grades; pods will want the same.
- **Mech gun sizes.** A mech's hand holds a mech-scale gun: whether those are their own receivers
  or player guns at nano full size (joints.md section 5: no held scale on a mech).
