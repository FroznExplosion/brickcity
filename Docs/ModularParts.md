# Modular parts: guns, mechs, figures, animals

One part system for everything that is built from swappable pieces: a gun's barrel, a mech's
left leg, a figure's torso, a shoulder pod. Every part is saved on its own, carries what it
mounts with and what it takes, and is found in one catalogue that filters and sorts the same way
for all of them. A gun or a mech in the game is an **assembly** the generator puts together from
parts that fit, from a seed and a design (section 7).

Status (2026-10-24): **stages 1 to 9, 11 and 12 built, and stage 10's offline half** (its network half waits on the netcode). The part record, the fit check and the
catalogue (`scripts/parts/`, `tools/parts_probe.gd`, 65 checks); guns on them: the workshop's
Save writes every part on its own, the generator and the assembler only put together parts
that fit (`tools/part_save_probe.gd`); the catalogue panel, F7 in the workshop
(`tools/part_panel_probe.gd`, 38 checks); trying any part on in the workshop, with fit marks
(`part_save_probe`, now 61 checks); mech mode in the workshop (`tools/mech_workshop_probe.gd`, 56
checks); mechs in the game from parts (`tools/mech_parts_probe.gd`, 70 checks); pods and mech guns
(`tools/pods_probe.gd`, 28; `mech_workshop_probe` now 62); the motion sets (`tools/motion_probe.gd`,
29); part packages (`tools/package_probe.gd`, 26); the match's parts offline (`tools/lobby_probe.gd`, 24); dressing (`tools/dressing_probe.gd`, 20); figures (`tools/figure_probe.gd`, 32). Section 11 is the order the rest is built in;
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
| 4 | **Done.** The workshop's anything-on-anything swap, with fit marks (section 9): pick in F7 to try a part on | `asset_workshop.gd` |
| 5 | **Done.** The workshop's mech mode: slot, side, class, reference mech, ready mounts, test fit; `tools/mech_workshop_probe.gd` | `asset_workshop.gd` |
| 6 | **Done.** Mechs in the game from parts: designs (fixed and rolled slots), `PartBuilder`, `MechAssembler`, class from the chassis, hips from the legs' length; the boxes in `mech.gd` give way to parts; `tools/mech_parts_probe.gd` | `scripts/mech/` |
| 7 | **Done.** Pods: slots, `PodGenerator`, the three kinds, pod names, the inventory screen; mech guns (scale `mech`) rolled for the hands; `tools/pods_probe.gd` | `scripts/mech/`, `scripts/guns/`, loot |
| 8 | **Done.** Motion sets library (section 8): `MotionSets`, the mech walk by leg length, the pods' arms; `tools/motion_probe.gd` | `scripts/parts/` |
| 9 | **Done.** Part packages: export, import, hash, data-only loading; `tools/package_probe.gd` | `scripts/parts/` |
| 10 | **Half done** (all but the network): lobby part list, what is missing, host download in checked chunks, placeholders, a Steam Workshop wrapper; `tools/lobby_probe.gd`. The messages themselves wait on the netcode | `scripts/parts/`, then the netcode |
| 11 | **Done.** Dressing on studs outside the workshop: `PartDressing`, Ctrl B by your mech; `tools/dressing_probe.gd` | `scripts/parts/` |
| 12 | **Done.** The figure body plan: the workshop's figure mode, `Figure` in the game with swappable limbs and a walk; `tools/figure_probe.gd`. Animals stay the creatures' own | `scripts/parts/` |

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

### Stage 4 as built

- **Try a part on**: double click a part in the catalogue (F7). Any held gun part goes on its
  own slot, fitting or not (`AssetWorkshop.try_part`). A mech, figure or pod part cannot be
  tried on a gun: same kind only.
- It is drawn from its **saved game scene**, its mount where this build's socket for it is:
  where the build's own part of that slot mounts, else the host's J socket point for it, else
  (a muzzle) the tip. The build's own part of that slot is hidden meanwhile.
- A **tried body** (or barrel) brings its sockets: the build's own parts that hang on it are
  drawn on its `socket_<slot>` nodes, as the game's assembler would put them, and are edited
  there (the mouse follows them, as in the exploded view).
- **Marks**: every part is checked against what it hangs from by the game's own rule (both say
  their interfaces: PartFit layer 1; neither does: by slot). A part that does not fit gets a
  red mark with the reason ("magazine does not fit: mounts on mag.wide, socket takes
  mag.narrow"); a tried part that fits, a green one. The status line lists them.
- **Never saved.** A tried part is already saved on its own; Save writes only this build's own
  parts, unchanged by what is tried on. A part from another build is not brought into this
  one's design: putting a fixed part of another build in a design is the design files'
  job (stage 6).
- Off: try the build's own saved part of that slot, or menu Photos > Take off the tried parts.
  A new or opened build takes them all off.
- The catalogue's Fits follows: with a body tried on, it lists what fits that body.

### Stage 5 as built

- **Asset > Make a mech** turns the build into a mech's ten parts: `chassis`, `head`, `arm_L`,
  `arm_R`, `hand_L`, `hand_R`, `leg_L`, `leg_R`, `pod_L`, `pod_R` (`MechReference.PARTS`). Each
  is its part's slot and side (the build part *is* the slot and side: Y picks it). Switching
  renames the parts in place (a gun's body becomes the chassis), so no brick changes part. Make
  a gun turns them back.
- **Class and leg length**: menu Mech > Class light / normal / heavy, Legs 1 / 2 / 3. Saved with
  the build. Every part saved from it is filed under that class; only the chassis's counts in
  the game (section 4), the limbs' is their look.
- **The reference mech** (`scripts/parts/mech_reference.gd`, menu Mech > Reference mech): its
  joints as labelled balls, the bones between them and its footprint, drawn through the bricks.
  It faces -X; its left is +Z, so the mirror (across Z) makes a right part of a left one.
  Numbers, in nano bricks from the ground:

  | | light | normal | heavy |
  |---|---|---|---|
  | hip, legs 1 / 2 / 3 | 12 / 16 / 20 | same | same |
  | hips apart (studs, each side) | 4 | 5 | 6 |
  | shoulder | hip + 2 | hip + 2 | hip + 2 |
  | shoulders apart (studs, each side) | 9 | 11 | 13 |
  | neck | hip + 5 | hip + 6 | hip + 7 |
  | wrist | shoulder - 8, 2 studs ahead | same | same |
  | pods | at the neck, 3 studs behind, 4 in from the shoulders | same | same |

  Legs 2 long puts the hip at joints.md's 16. These are first numbers, to change when the first
  mechs are built round them.
- **Ready joints**: every part's mount and, on the part it hangs from, a socket taking it, laid
  on the reference's joints with the right interface (`mech.neck`, `mech.shoulder`,
  `mech.wrist`, `mech.hip`, `mech.pod`). Another class or length moves them; points put by hand
  stay. J on a joint takes away the current part's point there first, so a mount can be moved
  and the socket left. Mech > Lay the joints ready again. The J panel offers the mech's sockets.
- **Save** writes every part on its own, as a gun's are: family `mech` (`pod` for a pod's body),
  slot, side, class, mount, a leg's `length` in its mount params, what each socket takes. Scenes
  are nano size in the game (a nano stud 0.175 m), facing -Z, with `mount` and `socket_<name>`
  nodes where the points are. Saved apart, they make a whole mech by the body plan (PartFit
  layer 2).
- **Try on** works for mech parts: a part goes on its slot and side (one for either side goes on
  the part being built if it is of that slot, else the left). The legs' rule is checked too:
  legs of two lengths are both marked "legs 3 and 2 long". The catalogue's Fits aims at the
  part's socket on the mech plan (`arm_R/hand` for the right hand).
- **Not yet**: the game does not build mechs from these parts -- that is stage 6, which replaces
  `mech.gd`'s boxes. Pod bodies are saved; the pods rolled onto them are stage 7.

### Stage 6 as built

- **Designs** (`PartDesign`, `scripts/parts/part_design.gd`): a file per design in
  `res://parts/designs/` (shipped) or `user://parts/designs/` (the player's), naming parts slot
  by slot: `{"fixed": id}`, `{"pool": query}` or `{"empty": true}`; a slot not named is rolled
  from everything that fits. A design names parts, it never holds them. A joined pair is two
  fixed slots; John is a figure design with his torso and head fixed and `neck/hat` a pool of
  hats. The workshop's saved mech builds are designs too, every slot fixed
  (`MechAssembler.designs`).
- **Rolling** (`PartBuilder.generate(plan, design, seed, catalog, opts)`): any body plan (mech,
  figure, gun). The root first (of a class if asked), then each socket from the root out, each
  from the parts that fit what it hangs from (layer 1) and the plan's `same` rule (layer 2): the
  legs' length is rolled once, from the lengths both sides have a leg for. Candidates in id
  order, one seeded RNG: the same seed, design and catalogue roll the same build. Pools are
  official parts only unless asked (`custom`), so a seed rolls one mech on every machine; a
  design's fixed parts may be anyone's. A fixed part that does not fit, or a required socket
  nothing fits, is a problem, and a build with problems is never made.
- **Assembling** (`MechAssembler.assemble`): each part's saved scene on a joint node where its
  host's `socket_<name>` is, one level deeper for the hand on the arm. The chassis's scene is at
  the hips (the workshop now exports it there). The hips stand `hip_height` above the feet:
  the legs' `length` in nano bricks (12 / 16 / 20; a boss's any other length on the same line).
- **In the mech** (`Mech.set_parts`, via `MechAssembler.dress`): the boxes go. The legs' joints
  go on the legs (they turn with the legs; stage 8's motion set walks them); the right arm and hand on the gun arm, posed so shoulder-to-wrist points along
  the aim, the muzzle ahead of the wrist; chassis, head, left arm and pods on the torso. The gun
  arm's shoulder (`Mech.shoulder`) and the pilot's eye (`Mech.cockpit_y`, 0.84 m over the hips)
  come from the parts. The chassis's class is the mech's layers (AIRoster 4.1: light's hatch at
  the back). The capsule and the rodeo points are as they were.
- **In the city**: every mech spawned is dressed if a whole one can be rolled -- a roster mech
  with a chassis of its class -- and keeps its boxes otherwise. No mech parts ship yet, so today
  every rolled mech keeps its boxes. **Ctrl Y** spawns an enemy mech of each mech saved in the
  workshop in turn, with its chassis's class. Seeded from where it stands, so no combat roll
  moves.
- **Not yet**: the arms and legs are rigid parts on joints (no knee or elbow inside a part);
  the mech's gun is still the placeholder LMG, hidden, at the wrist (stage 7: mech guns).

### Stage 7 as built

- **`PodGenerator`** (`scripts/parts/pod_generator.gd`), beside `GunGenerator` and
  `ShieldGenerator`: a kind, a maker, a rarity (rolled as a gun's) and a tier from a seed; one
  power roll scaled by rarity x tier, traded against the cooldown at a constant product; a grade
  word as a gun's; a score on the guns' 100-a-tier scale. Saved by `{seed, rarity, tier, kind,
  body}` and rolled back the same.

  | Kind | Sort | Does |
  |---|---|---|
  | `missiles` (Missile Pod) | active, fixed | a burst of 4 rockets (a `rocket_launcher` of its own) where the mech aims |
  | `laser` (Laser) | active, fixed | one heavy shot (a `sniper`) |
  | `grenade_arm` (Grenade Arm) | active, animated | lobs 2 grenades (a `grenade_launcher`) |
  | `melee_arm` (Strike Arm) | active, animated | the nearest enemy mech within 7 m takes ~450 |
  | `shield_boost` (Shield Booster) | passive | the shield layer ~30 % bigger |
  | `directional_shield` (Brace Plate) | passive | the armour layer ~22 % bigger (see below) |

- **Names** from the pods' own lists -- grade word (shared with guns: one grade scale), an
  adjective, a noun of the kind ("Shouldered Hive", "Pylon Lance") or the pod body's
  `name_fragment`. `pods_probe` checks no gun noun is in them (it caught "Bulwark", a heavy gun's
  noun). A pod body's `pod_kind` (active_animated / active_fixed / passive) limits what is
  rolled onto it; a body that says none carries any.
- **`MechPods`** (`scripts/parts/mech_pods.gd`) on a mech: `pod_L` and `pod_R`. Passives resize
  the layers while fitted (as full as they were) and hold when the layers are made again (a
  chassis's class). Actives are used, then cool down; a weapon pod is a `GunController` of its
  own on the mech's aim, its damage the pod's power. Two of one kind stack.
- **In the mech**: 1 and 2 (the gun slot keys) use the left and right pod.
- **Fitting: the backpack's mech page** (`MechLoadoutScreen`): swap weapon steps backpack ->
  skills -> mech -> backpack when the player has a mech. Up / Down pick a pod, 1 / 2 fit it
  left / right (what was there goes back), Shift 1 / 2 take one off. The player starts with one
  pod of each kind, a missile pod and a shield booster fitted (not in a scripted pass, whose
  mech must fight as it always has).
- **Mech guns**: Gun > "Mech gun" in the workshop builds a gun at the mechs' nano scale, with
  the `mgun.*` joints only, saved as `scale: mech`. `AssetGuns` takes a scale (fenced apart:
  `asset_mech_<id>`), so a mech gun never joins a player's guns. `MechAssembler.roll_gun` rolls
  one of them (stats and modifiers from the seed, as any gun) and `arm_gun` puts it, seen, in the
  mech's right hand, the muzzle moved to its own. The player's mech carries one when any is
  saved (not in a scripted pass); Ctrl Y's workshop mechs do too. With none, the hidden
  placeholder LMG stays.
- **Not yet**: the Brace Plate is armour all round until hits say which way they came from; enemy mechs carry
  no pods (their brain would need to use them: the AI's); pods do not drop as loot yet.

### Stage 8 as built

- **`MotionSets`** (`scripts/parts/motion_sets.gd`): every set says its body plans, the tags it
  answers to, the paths it needs (`leg_L`, `magazine`) and, for creatures, a leg count. A build
  asks with an action and what it would like (`["walk", "heavy"]`, `["pod.arm", "melee_arm"]`,
  `["reload", "reload.mag"]`) and gets the set it satisfies that does the action with the most
  of them; ties on id. A pick (a player's, a design's `motion: {"walk": id}`) wins when the
  build satisfies it, else it is passed over. `satisfying()` lists what a user may pick from.

  | Set | For | Run by |
  |---|---|---|
  | `mech.walk.stride` | mechs, light and normal | `MechStride` |
  | `mech.walk.stomp` | mechs, heavy: a shorter swing | `MechStride` |
  | `pod.arm.strike`, `pod.arm.throw` | the Strike Arm and Grenade Arm pods | `PodArmMotion` |
  | `gun.reload.mag`, `gun.reload.fixed` | guns, by whether the magazine comes off | `PlayerView` (as before) |
  | `creature.gait`, `creature.gait.far` | animals of 1 to 10 legs, near and far | `GaitController`, `CannedGait` (as before) |
  | `figure.walk.clips` | figures, Mixamo-named clips | stage 12 |

- **The mech walk** (`MechStride`): the legs swing at the hips, left against right. The swing
  grows with speed (widest at 9 m/s); a step is `2 x hip height x sin(swing)` long and the
  cadence is whatever makes steps x length the speed, so **the feet keep pace with the ground at
  every leg length** -- legs 1, 2, 3 and a boss's -- and longer legs step slower. The length is
  read from the build (`MechAssembler.hip_height`). Moved out of `mech.gd`, which only puts the
  parts on now.
- **Pod arms** (`PodArmMotion`): a Strike Arm winds back and hammers down and forward, a Grenade
  Arm winds further back and flings, then each settles. What swings is the pod part on the
  chassis (`Joint_pod_L` / `_R`), or, on a mech with no pod part there, a **stand-in box** on the
  torso that `MechPods` puts up for every fitted pod and takes away with it.
- **Not yet**: the animals' DNA makes legs in pairs (2, 4, 6 ...); the library takes 1 to 10, so
  odd counts wait on the creatures' DNA (the animals stage). The pod arm is a swing of the pod
  body, not an arm of joints. Knees and elbows inside a part need parts with more than one bone.

### Stage 9 as built

- **`PartPackage`** (`scripts/parts/part_package.gd`). A `.bcpart` is a zip of `part.json`
  (the record, creator and bricks in it), `mesh.json` (the part's nodes as data: Node3D,
  MeshInstance3D and MultiMeshInstance3D only, their places, their meshes as base64 packed arrays,
  their materials by role -- `brick`, `stud` -- or as a plain colour), `interfaces.json` (the
  interfaces it uses and standards.json's `version`), `thumb.png` when the part has one, and
  `manifest.json` (format, id, rev, each file's sha256, and the **content hash**: the sha256 of
  the content files' hashes, the part's identity across machines).
- **Export**: Asset > "Export this build's parts to share" writes each saved part of the build to
  `user://parts/export/<id>.bcpart`.
- **Import**: Asset > "Import a part package..." (`PartPackage.import_file`). Refused: a package
  over 8 MB or a file in it over 16 MB; any file but the five (a `.scn`, `.tscn`, `.gd` ...);
  a file that does not match its hash; a record that breaks the schema (`PartRecord.problems`);
  an id a folder cannot have; a shipped part's id; a mesh with a node of another type, a parent
  out of order, a bad place or name, an array of the wrong kind or length, bones or weights, an
  index out of range, more than 512 nodes or 2 million vertices, a multimesh buffer not whole.
- What passes goes in `user://parts/custom/<id>/`: `part.json` (always `custom`, whatever it says;
  the creator kept), a `part.scn` **built here from the arrays** by our own code, `package.json`
  (the manifest, so its hash is known: `PartPackage.hash_of`) and the thumbnail. The same
  package again changes nothing; a newer rev replaces the part; an older one is refused.
- Round trip: an exported and imported part has the same nodes, meshes and materials (normals and
  tangents to the engine's packing), the catalogue reads it and the game makes the gun of it.
- **Not yet**: the zip reader cannot ask a file's size before unpacking it, so the 8 MB file cap is the
  guard against a file that unpacks huge. Steam Workshop and the lobby are stage 10.

### Stage 10, the offline half, as built

The game has no netcode yet. Everything a match needs of the parts is built so that the
netcode only has to carry dictionaries and byte chunks:

- **`PartLobby.list(ids, catalogue)`** (host): each part's id, rev, content hash
  (`PartPackage.hash_for`: an imported part's from its manifest, a part made here worked out
  from its package), its source, its Steam item when it has one, and its record without the
  bricks (its shape: enough to stand in for it).
- **`PartLobby.missing(list, catalogue)`** (client): what it lacks, or has another version of
  (another hash). Shipped parts are never missing. `source_for(entry)`: Steam if the part has an
  item and Steam is there, else the host.
- **`PartTransfer`**: `make_offer(dir)` packs the part (`PartPackage.pack`, in memory) into 32 KB
  chunks with an offer {id, rev, hash, size, count}. The client's `PartTransfer.new(offer,
  lobby_hash)` refuses an offer over 8 MB, with a chunk count that does not match its size, or
  of another hash than the lobby named; `take(i, bytes)` takes chunks in any order, again is
  harmless, the wrong size or out of range refused; `progress()` for the join bar, `wanted()`
  for what to ask again for; `finish()` checks the whole is the hash offered, then imports it as
  any package (data only).
- **`PartLobby.placeholder(entry)`**: a missing part's stand-in -- its record as the lobby gave
  it, so it fits where the real one would, tagged `placeholder`, drawn as a plain block. A mech
  goes together with one.
- **`SteamParts`**: subscribe, the installed folder, an item id kept beside its part
  (`steam.json`), through GodotSteam's UGC calls when the game runs with it. GodotSteam is not
  in the project, so today it says it is not there and everything comes from the host.
- **Waiting on the netcode**: the lobby message, asking for and sending the chunks, the join
  screen's bar, swapping a placeholder for the real part when it lands, publishing to Steam.

### Stage 11 as built

- **`PartDressing`** (`scripts/parts/part_dressing.gd`): a part's studs are read from its stud
  multimeshes -- their place, which way is up, the pitch between them -- and a stud is keyed by
  its place in the part (to the millimetre), so dressing survives saves of the same part.
- **The rules**: a 1x1 brick or plate, one a stud, only on a stud the part has; not within
  1.6 stud pitches of the part's mount or any socket (it would cross where the next part turns);
  not more than 2 pitches out past the part's own bounds (the space it swings through). Each
  brick adds 0.9 kg, a plate 0.3 (`mass()`).
- **Owned**: kept in `user://parts/dressing.json` by owner and part id, so it goes with the part
  to whatever mech it is put on and is never another player's. A newer rev of a part that moved
  a stud leaves that brick off, and says which (`apply` returns them).
- **In the city**: on foot by your own mech of parts, **Ctrl B** puts a brick on the stud
  nearest the crosshair line (within half a metre, 30 m off), **Ctrl Shift B** takes it off,
  **Ctrl Alt B** the next colour; saved at once. Your mech is dressed when it is made
  (`MechAssembler.dress(..., owner)`), and when its armour breaks, three bricks a part fly off
  as falling debris for eight seconds -- off this mech, not out of your things. Not in a
  scripted pass.
- **Studs kept on the node**: the renderer holds a multimesh's buffer, so headless a part's
  studs read back empty. The workshop now keeps each stud multimesh's buffer as `buffer` meta,
  packages carry it and rebuild it, and dressing reads it first. (Before this, a package made
  headless had lost its studs' places; `package_probe` now checks they come through.)
- **Not yet**: one layer of bricks (no brick on a dressing brick), 1x1 only; no dressing on
  guns or figures in the game yet (the same code takes any part with studs).

### Stage 12 as built

- **`FigureReference`** (`scripts/parts/figure_reference.gd`), with the same calls as
  `MechReference`: nine parts -- `torso`, `head`, `arm_L`, `arm_R`, `hand_L`, `hand_R`,
  `leg_L`, `leg_R`, `hat` -- on the figure body plan's joints (`fig.neck`, `fig.shoulder`,
  `fig.wrist`, `fig.hip`, `fig.hat`). One size, 8 nano bricks (1.68 m): hips 12 nano plates up,
  shoulders 20, neck 21, the hat's studs 27; shoulders 2 studs out, hips 1. No class, no leg
  length: every part fits every figure.
- **The workshop's body mode serves mechs and figures.** Asset > "Make a figure": its parts, its
  reference drawn (each part's bone to what it hangs from, legs to the ground), every joint's
  mount and socket laid ready, the J panel offering its sockets, Save writing nine `figure`
  parts. Try on (F7) takes figure parts. `figure` is a recipe and asset kind
  (`user://figures/`).
- **Paths by socket names**: a part's plan path runs by the sockets from the root -- the hat
  on the head is `neck/hat` (`path_of` had made it `head/hat`; the figure probe caught it).
- **`Figure`** (`scripts/parts/figure.gd`) in the game: `Figure.make(build)` from
  `PartBuilder.generate("figure", design, seed, catalogue)` -- nothing if the build has
  problems -- every part on its joint (`MechAssembler.assemble`), standing on its hips.
  **`swap(path, part)`** changes a limb where it stands: refused, with nothing changed, if the
  part does not fit there or the figure would not be whole; what hangs on it stays on, on the new
  part's socket. It walks by `figure.walk.stride` (the mechs' stride, from its leg length; the
  Mixamo clip set is there to pick when a figure has those bones). `Figure.designs()`: the
  workshop's figures and figure design files (John is one: torso and head fixed, hat rolled).
- **In the city**: **Ctrl T** puts the workshop's figures down in turn ahead of the camera,
  walking a circle; **Ctrl Shift T** swaps a limb of the last one for another figure part that
  fits.
- **Animals stay the creatures'** (`ProcCreature`, their DNA and gaits), their own catalogue, as
  decided; MotionSets already picks their gait for 1 to 10 legs.
- **Not yet**: figures are models that walk, not characters with a brain (an NPC's AI is the AI
  area's); a character-builder screen beyond the workshop and Ctrl Shift T; Mixamo clips on
  figure parts (one rigid bone a part today).

### Joints inside a part (knees, elbows), as built

- A part can **bend**: a third kind of J point, `bend`, named `knee` or `elbow`. Body mode lays
  them ready half way down each leg (hip to ground) and each arm (shoulder to wrist), with the
  other ready points (`MechReference` / `FigureReference.BENDS`, `bend_at`).
- **Export**: the part's bricks below the bend go under a pivot `Bend_<name>` at the bend (in
  `Lower`), the rest stay in `Model`; a socket below the bend goes under the pivot too, so the
  hand goes with the forearm. The record lists them (`extra.bends`).
- **Assembly**: a socket inside a part (under a bend) is found where it is, and the part hung on
  it goes under the pivot -- the hand rides the elbow. `Mech.set_parts` leaves such joints
  inside their part; the gun arm's wrist is worked out through them.
- **Motion**: `MechStride` folds each knee back while its leg swings through (the half of the
  cycle it moves forward), straight when standing; figures swing their arms against their legs
  with the elbows a little bent. A mech's gun arm still aims straight.
- Probed in `figure_probe` (joints: 7 checks) and `mech_workshop_probe` (the ready bends, the
  wrist under the elbow).
- **Several bends a part**: a leg bends at its knee (half way down) and its ankle (0.85 of the
  way down), an arm at its elbow (`BENDS` is a list a part, `BEND_DOWN` how far down each).
  Each piece between two bends hangs under the pivot of the bend above it
  (`Bend_knee/Bend_ankle`), and a socket goes under the deepest bend above it. The walk keeps
  the foot level: the ankle turns against the hip and the knee together. A figure's stride is
  widest at its own run, 3.5 m/s (a mech's is 9).
- **Looked at** (`tools/figure_look.gd`, windowed: the workshop's side, front and 3D views and
  the figure standing, mid-stride, at full reach and with an elbow bent, into
  `user://figure_look/`). What the pictures showed, and what changed:
  - mid-stride the swinging leg's knee folds back, its foot level; at full reach the legs
    scissor with both feet flat; the elbow folds the forearm and hand forward;
  - a figure's walk had used the mech's 9 m/s scale, so at walking pace its knees barely moved:
    its own run now;
  - in mech and figure mode the gun's size marks (the class ruler, "butt", the grip box) were
    still drawn: a gun's only now; the status line said "in the game 0.03 m long" (a gun's
    length): a body's says how tall it is in the game;
  - a figure was a speck in the flat views (framed for 80 studs) and far off in 3D: its flat
    views are framed to 26 studs, above the readouts, and 3D starts by its height;
  - a mount and its socket at one spot drew two labels over each other, and the reference its
    own label too: one label a spot now ("arm_L on torso  (fig.shoulder)", "leg_L knee"),
    smaller in a figure's view.
- **Not yet**: a wrist turn; the shell of a smooth part stays with the upper piece; the ready
  elbow sits where it falls, not on a brick seam (a brick across it turns with the upper arm).

### Characters, as built

- **What a figure does** (`Figure.mode`): `idle` stands; `wander` walks a circle round where it
  was put; `follow` walks after its `target`, turning to face it, and stops 2 m short;
  `patrol` walks its `route` round and round. A character's simple brain -- fighting stays the
  AI area's.
- **The character builder** (`CharacterBuilder`, **Ctrl Alt T** in the city): the figure turning
  in a preview and its slots; Up / Down picks a slot, Left / Right steps through the parts that
  fit there -- only those (a mech's arm never; a head with nowhere for the hat not while a hat
  is on) -- R rolls a whole new one (custom parts too: it is the player's), S saves it as a
  design of fixed slots in `user://parts/designs/`, Enter puts it in the world (following you on
  foot, else walking its circle). Saved characters come back with Ctrl T as any figure design.
- Probed in `tools/character_probe.gd` (16).

### Thumbnails, as built

- **`PartThumbnail`** (`scripts/parts/part_thumbnail.gd`): a part drawn in a viewport of its own,
  from three quarters above, framed to its meshes, on a clear background, 256 across, kept beside
  it as `thumb.png`. It needs a window: headless it makes none (and nothing breaks).
- **The workshop's Save** makes one for every part it writes, one after another, when it has a
  window; Asset > "Make pictures of this build's saved parts" makes them again.
- **The catalogue** shows a part's picture as its icon in the list (40 px). Packages carry it and
  an import keeps it (stage 9 already took a `thumb.png`).
- Probed by `tools/thumb_probe.gd` (windowed: 7 checks -- the part in the middle in its colour,
  clear round it, framed, the icon, the package; headless: 2). Its one windowed run peaked at
  68 C, not held back.

## 12. Decided

Decided 2026-10-23: every part saves on its own (section 7); joined pairs and fixed characters
are designs (section 7, Designs); pods name like guns from their own word lists (section 4);
mech guns are their own guns at mech scale (section 5); the workshop saves only parts, so
nothing unfit is ever saved, and the game only assembles parts that fit (section 7).
