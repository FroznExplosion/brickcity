# Modular parts: guns, mechs, figures, animals

One part system for everything that is built from swappable pieces: a gun's barrel, a mech's
left leg, a figure's torso, a shoulder pod. Every part is saved on its own, carries what it
mounts with and what it takes, and is found in one catalogue that filters and sorts the same way
for all of them. A gun or a mech in the game is an **assembly** the generator puts together from
parts that fit, from a seed and a design (section 7).

Status (2026-10-24): **stages 1 to 3 built.** The part record, the fit check and the
catalogue (`scripts/parts/`, `tools/parts_probe.gd`, 65 checks); guns on them: the workshop's
Save writes every part on its own, the generator and the assembler only put together parts
that fit (`tools/part_save_probe.gd`, 40 checks); the catalogue panel, F7 in the workshop
(`tools/part_panel_probe.gd`, 38 checks). Section 11 is the order the rest is built in;
"Stage 1 as built" and "Stage 2 as built" below say what differs from the plan.

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
scale         held | mech                guns only: a player's gun, or a mech's (section 5)
slot          arm | leg | hand | chassis | head | pod | barrel | magazine | hat | ...
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
- Pods are **named like guns** -- grade word, element word, a noun from the pod body's
  `name_fragment` -- but from **their own word lists**, so a pod's name never reads as a gun's.
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
- A gun made whole in the workshop is saved **as its parts** (section 7): each joins the
  catalogue, and the generator makes guns of them.
- **Mech guns are guns at mech scale** (`scale: mech`): their own receivers, barrels and the
  rest, built in the workshop and rolled by the same generator, on the nano grid the mechs are
  built on (joints.md section 5: no held scale on a mech). The two scales never mix: a mech
  part fits only a mech receiver, and a mech's hand holds only a mech gun. Their interfaces are
  their own (`mgun.*` beside `gun_interfaces`), and `scale` is a catalogue facet.

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

### Saving: every part on its own

**Save writes every part as its own file**, however many are in the workshop at once. A gun
with eight parts open is eight part files and nothing else: **parts are the only thing the
workshop saves**. A part unchanged since its last save is not written again (its `rev` stays).

So a build never saves a wrong part: what is put together in the workshop, fitting or not, is
a view to look at and try things in, never a gun. **Every gun, mech and pod in the game is put
together by the generator, and the generator only ever puts together parts that fit** (section
3, layers 1 and 2). Which parts were open is kept only as the workshop's own session (its
autosave), which the game never reads.

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

### Designs: fixed slots and rolled slots

What the generator rolls from is a **design**: for each slot, either a **fixed** part or a
**pool** to roll from. The ordinary design is all pools and needs no file. The special cases
below are design files, written on purpose (not by the workshop's Save), and **checked to fit
when they load**: a design whose fixed parts do not fit is refused, with the reason.

| Case | Design |
|---|---|
| a rolled gun | every slot a pool (the generator's candidates, as now) |
| a legendary: barrel and receiver joined | `receiver` and `barrel` fixed, as a **joined pair**: they always roll together; the rest pools |
| a special character, always the same | every slot fixed |
| John: same limbs and torso, different hats | torso, arms, legs, head fixed; `hat` a pool (hats tagged `john` or any hat) |

- A **joined pair** (or group) is several fixed parts that are only ever placed together: still
  separate part files, kept together by the design. Their parts carry `exclusive_to` the design,
  so nothing else rolls them, as legendaries' do today.
- A pool is a filter (section 6) plus weights: "any light chassis", "hats tagged john".
- The seed rolls only the pool slots; fixed slots take no roll, so a fixed part never moves
  another slot's roll.

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
| 1 | **Done.** The part record, the catalogue (facets, filter, sort), the fit check (layers 1-2), `mech_interfaces` / `figure_interfaces` / `mgun_interfaces` / `body_plans` in `standards.json`; `tools/parts_probe.gd` | `scripts/parts/` |
| 2 | **Done.** Guns on it: `GunAssembler` and the generator check interfaces; Save writes each part on its own; the game reads those parts (old `guns/` folders still load). Design files with fixed and pool slots moved to stage 6, where the generator first needs them | `scripts/guns/`, `asset_workshop.gd` |
| 3 | **Done.** The catalogue panel: filters, sort, custom and creator, the Fits toggle; F7 in the workshop; `tools/part_panel_probe.gd` | UI, shared by workshop and inventory |
| 4 | The workshop's anything-on-anything swap, with fit marks (section 9) | `asset_workshop.gd` |
| 5 | The workshop's mech mode: slot, side, class, reference mech, ready mounts, test fit | `asset_workshop.gd` |
| 6 | Mechs in the game from parts: a mech assembler on a skeleton, IK legs and arms by length, class from the chassis; replaces the boxes in `mech.gd` | `scripts/mech/` |
| 7 | Pods: slots, `PodGenerator`, the three kinds, pod names, the inventory screen; mech guns (scale `mech`) rolled for the hands | `scripts/mech/`, `scripts/guns/`, loot |
| 8 | Motion sets library (section 8) | |
| 9 | Part packages: export, import, hash, data-only loading | `scripts/parts/` |
| 10 | Multiplayer: lobby part list, host download, Steam Workshop | with the netcode |
| 11 | Dressing on studs outside the workshop | |
| 12 | The figure body plan; animals later | |

---

### Stage 1 as built

- A build is checked against a **body plan** (`standards.json` `body_plans`: `mech`, `figure`,
  `gun`; a mech gun is a `gun` plan with `mgun.*` interfaces and `scale: mech`). A plan names its
  root slot and every socket **path** -- the host's path, `/`, the socket's name: `arm_L`,
  `arm_L/hand`, `neck/hat` -- with the slot and side it takes and whether it must be filled;
  `same` lists paths whose parts share a mount param (the legs' `length`).
- Every check gives a **reason** ("mounts on mag.wide, socket takes mag.narrow"), so the
  workshop's marks (section 9) and the generator's refusals read the same.
- A part's own problems (`PartRecord.problems`) keep it out of the catalogue: an interface not in
  `standards.json`, a custom part with no creator, a hip with no length.
- **The folder decides official or custom**, never the file: a downloaded part cannot make itself
  official. The first folder read wins an id; a second with the same id is left out.
- JSON has no ints: mount params that are whole numbers are read back as ints.
- Not yet: a seed-stable order for the generator (new parts at the end, section 7) is stage 2's;
  the catalogue's lists are in id order.

### Stage 2 as built

- **Save** (Ctrl S, Save As) writes the build -- the workshop's own file, for opening it here
  again; the game never reads it -- and then **every part on its own**:
  `<parts dir>/<id>/part.json` + `part.scn`. The parts dir is `user://parts/custom/` for the
  player's builds and `res://parts/gun/` for a shipped one (written only from the editor).
  `AssetWorkshop.save_parts`.
- A part's **id** is made on its first save and kept in the build (`meta.asset.part_ids`):
  `<creator>.<build>_<part>.<8 hex>` for a custom part, `<build>_<part>` for a shipped one. The
  creator is `player` until Steam names one (stage 10). Save As under another name, or a new
  build, makes new ids; the old parts stay as they were.
- A part **unchanged** since its last save is not written again. Unchanged means its record and
  what its scene holds (nodes, places, mesh vertices, colours: `scene_signature`) -- not the
  scene file, which is different bytes every save. A changed part's `rev` goes up by one.
- A record holds: family `gun`, scale `held`, slot, maker, `custom` and its creator, the body's
  weapon class (the workshop's Size), its mount interface and what each socket takes (from its J
  points), `from` (the build it was last saved from), and its own bricks as a recipe.
- **Fit in the game** (`GunPartDef.mount_interface`, `socket_accepts`, `takes`, `fits_recipe`):
  parts that both say their interfaces join only on a shared one; parts from before interfaces
  (every placeholder part, and a workshop part with no J points) join each other by slot as
  always, and **never** a part that says its interfaces. The generator leaves an unfit part out
  of every pool (`_pool_at`); the assembler leaves an unfit part off with a warning. 600 rolls
  over six classes are the same, part for part, before and after.
- **The game reads the parts** (`AssetGuns.designs`): parts saved from one build, by its name,
  are that build's gun (T in the city), fenced to it as before, and made only if they fit
  (`AssetGuns.why_not`). A build that half-says its interfaces (a body whose sockets take
  `mag.narrow`, a magazine with no mount point) makes no gun, with the part that does not fit.
- **Not in the random pools yet.** Workshop parts stay fenced to their own design. In the pools
  they would change what every seed rolls on each machine by what is saved there; they join when
  official parts ship (the same on every machine) and the lobby carries custom ones (stage 10).
- **Old guns:** an exported `guns/<name>/` folder still loads. Open it in the workshop and Save,
  and its parts are written; the parts win over the folder of the same name.

### Stage 3 as built

- **`PartCatalogPanel`** (`scripts/parts/part_catalog_panel.gd`), one panel for every screen: a
  search line, a row of buttons per facet, the list, a detail line, and Sort, reversed, by maker
  and Fits. A screen gives it a catalogue and, for the inventory, the parts the player has
  (`set_catalog(cat, parts)`); what a pick does is the screen's (`part_picked`).
- **Any one button alone filters**; OR inside a facet, AND across (section 6). Each button's
  number is how many parts ticking it would show, counted with every OTHER facet's ticks, so
  ticking `light` keeps `heavy` and its count. A facet every listed part shares has no row.
- **Search**: every word must be in the name, id, maker or creator.
- **Grouped by maker** by default (a heading per maker, makers A-Z), sorted inside by the Sort;
  off, one flat list. Ties on id.
- Custom parts in the same list, `custom, by <creator>` beside them; `custom` and the creator are
  buttons like any other.
- **Fits** is greyed until the screen points it at a socket (`set_fit_target(host, path,
  plan)`); then only what passes layers 1-2 there. The detail line says why a part does not fit
  ("mounts on mag.wide, socket takes mag.narrow") whether Fits is on or not.
- **In the workshop: F7** (menu: Photos > Parts catalogue). It reads the part folders each time
  it opens. Its Fits points at the socket of the part being built (Y), on the saved part it hangs
  from: the body's magazine well for the magazine, the barrel's for a muzzle. Picking a part only
  names it for now; putting it on is stage 4.

## 12. Decided

Decided 2026-10-23: every part saves on its own (section 7); joined pairs and fixed characters
are designs (section 7, Designs); pods name like guns from their own word lists (section 4);
mech guns are their own guns at mech scale (section 5); the workshop saves only parts, so
nothing unfit is ever saved, and the game only assembles parts that fit (section 7).
