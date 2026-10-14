# The asset workshop

A workshop scene for blocking out **assets** -- guns first, then mechs, gear and props -- fast,
against a photo or an existing model, with each part kept apart as it is built. Its output goes
to the part kit (`tools/brickify/gunsmith.py`), which turns it into nano bricks, smooth custom
pieces, studs and connections ([Docs/Parts/custom.md](Parts/custom.md)).

    godot --path . res://scenes/asset_workshop.tscn

It is the workshop ([Docs/BuildMode.md](BuildMode.md), `scripts/workshop.gd`) with tools added:
`scripts/asset_workshop.gd` extends it, and everything the workshop does -- placing, sideways
building, the hotbar, paint, undo, save and load -- works here unchanged. Tools that prove out
can move into the main workshop later; that is the build-mode area's call.

Status: all four phases are built (2026-10-14) and checked by the probe (56 checks). The panels and drag tools have been driven by the probe, not yet by hand: what feels wrong in use is the next round.

---

## 1. Units: build in bricks, think in nano

An asset is built here in ordinary bricks. On export every brick becomes its nano twin -- same
studs, half the size -- and a gun's nano model is a quarter of the real gun
([Docs/Parts/joints.md](Parts/joints.md) section 7). So one stud here stands for:

| Here | Nano | Print | The real thing |
|---|---|---|---|
| 1 stud | 1 nano stud | 4 mm | 16 mm |
| 1 plate | 1 nano plate | 1.6 mm | 6.4 mm |

A Thompson is 53 studs long and 3 studs wide here; a pistol about 13 studs.

The ruler, the measure tool and the readouts all show studs and plates **and** print mm and
real mm, so a part can be built straight from a real gun's numbers.

---

## 2. The tools

### Phase 1 -- trace a photo by hand

| Tool | Key | What it does |
|---|---|---|
| **Ruler** | always on | the cell under the cursor and the build's size, in studs/plates, print mm and real mm |
| **Reference photo** | F2 (panel) | load an image onto a plane -- side, top or front -- behind the build. Calibrate: click two points on it and type the real length between them; the photo scales itself. Move it, set its opacity, hide it, remove it. It is never built on: rays pass through it |
| **Ortho views** | F6 | perspective, side, top, front, in turn. The flat views line up with the photo planes. Home / End zoom a flat view |
| **Measure** | F7 | click two points (on bricks, a photo or the floor): the distance in all four units, drawn as a line |
| **Mirror** | F8 | every brick placed is placed again mirrored across the centre plane (a gun's long axis runs along X; the plane is Z = its middle). The plane sits on the middle of a stud, so an odd width (a 3-stud body) is centred |

### Phase 2 -- build a whole gun split by part

| Tool | Key | What it does |
|---|---|---|
| **Part toolbars** | Y cycles | several hotbars, each bound to a part (barrel, stock, grip ...). Every brick placed is tagged with the part of the toolbar it came from, so the split lines are built in. Each part keeps its own nine slots |
| **Drag place** | hold LMB, drag | the held brick laid again and again on the plane of the first one, wherever the cursor passes: a line, a wall, a floor |
| **Connection points** | J | place a mount or a socket on the lattice for the current part and pick its interface (`stock.tang` ...): the gun system's `socket_<slot>` / `mount` |

### Phase 3 -- block out fast

| Tool | Key | What it does |
|---|---|---|
| **Shape drag** | K, then drag | box, rectangle, cylinder, circle, sphere, wedge. Filled **clean** (fewest bricks, studs holding) or **random** (mixed sizes) |
| **Box select** | L, drag | a region: move, copy, delete, or re-pack it clean |
| **Guide models** | F3 (panel) | load an existing model (glTF, FBX, OBJ) on its own locked, see-through layer, and build inside it. A bought model is a guide only: it is never exported ([custom.md](Parts/custom.md) section 6) |
| **Section view** | O | hide everything past a plane, to build inside |
| **Isolate / explode** | P | show only the current part, or pull the parts apart; tint bricks by part |

### Phase 4 -- out the other end

| Tool | Key | What it does |
|---|---|---|
| **Mark smooth** | N | paint a part's role: stays bricks, or becomes a smooth custom piece (its brick outline is lofted, as the traced stock and grip were) |
| **Wand** | F4, click a photo | the patch of the photo's colour under the click, filled with bricks for the current part, so many studs across on the mirror plane; then fix it by hand |
| **Live readout** | always on | each part's bricks (~ marks smooth ones) and the asset's length in the game; after an export, the part kit's checks: loose bricks, the grip, joints meeting |
| **Export** | F12 | write the build sheet to `user://asset_exports/`, run the part kit in Blender (`BRICKCITY_BLENDER` if it is not in the usual place), and show its picture and checks here. A smooth part leaves as a loft of its brick outline -- along the gun if it is longer than tall, else up it; the rest leave as laid. The muzzle is the low-x end unless `meta.asset.muzzle` is `+x` |
| **Undo / redo** | Z / shift Z | a fill, a copy or a mirrored pair undoes at once; redo lays it back, each brick in its own part |

---

## 3. What is saved

Everything the asset workshop adds lives in the build's recipe, in `meta.asset` -- the free-form
facts a recipe carries and nothing structural reads (`BuildRecipe.meta`). The recipe's own format
does not change, so a build made here opens in the main workshop and the city as any other.

| Key | Holds |
|---|---|
| `photos` | each photo: file, plane, centre, mm per pixel, opacity, shown |
| `mirror` | on, and the plane |
| `parts` | the part names, and which part each brick is, by recipe index. A brick deleted with RMB takes its own tag; anything else that shortens the recipe (undo, deleting an inserted group) takes tags from the end |
| `points` | mounts and sockets: part, kind, slot, interface, and where: studs along, plates up, studs across |
| `guides` | guide models: file, real length, offset, turn, opacity |
| `smooth`, `muzzle` | which parts leave as smooth pieces; which end is the muzzle |

A photo is referred to by its path and is not copied: a bought or borrowed picture stays out of
the repository.

---

## 4. Checks

`tools/asset_workshop_probe.gd`, headless, drives the scene with exact rays, as the workshop's
own probes do: the units, a photo's calibration, measuring, the mirror's cells and facings, what
is saved and loaded back. Each phase adds its own cases.
