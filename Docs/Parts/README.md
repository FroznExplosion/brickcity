# Parts — measurements for modelling

Everything a modeller needs to build a part so it matches the game grid exactly and prints at real
brick size. The per-part sheets are **generated** from the same code the game bakes its parts from:

| File | What |
|---|---|
| [INDEX.md](INDEX.md) | every family, with links |
| `plates.md`, `bricks.md`, `tiles.md`, `columns.md`, `brackets.md`, `slopes.md`, `curves.md`, `rounds.md`, `archs.md` | one sheet per family: sizes, stud and tube positions, profiles |
| `profiles/*.svg` | the cross-section of every shaped part, on a stud/plate grid, corners labelled in mm |
| `parts.json` | the same numbers for a Blender or build script to read |

Regenerate after changing any part:

```bash
godot --headless --path . --script tools/part_sheets.gd
```

`tools/scale_probe.gd` checks that the city, terrain, workshop, meshes and walking figure all use
one grid, and that the grid is a real brick's grid.

---

## 1. One ruler, three sizes

The whole project is built on a **1.6 mm unit** (a "tick" in the code): a stud is 5 of them, a
plate 2, a brick 6. Every part is a whole number of studs across and plates tall.

| | Units | Print / Blender (mm) | Game (m), x43.75 |
|---|---|---|---|
| unit (tick) | 1 | 1.6 | 0.07 |
| plate | 2 | 3.2 | 0.14 |
| stud pitch | 5 | 8.0 | 0.35 |
| brick (3 plates) | 6 | 9.6 | 0.42 |
| figure (4 bricks) | 24 | 38.4 | 1.68 |
| storey = column (6 bricks) | 36 | 57.6 | 2.52 |

The same factor on every axis: 0.35 / 8.0 = 0.14 / 3.2 = 0.04375 m per mm. Nothing is squashed.
The extension owns these (`gdextension/brick/src/brick_grid.h`); `BrickPalette` and a few scripts
keep copies, and `scale_probe` fails if any copy disagrees.

**Model at print scale, in millimetres.** That is the size a printed part has to be, and the game
size is the same model x43.75.

## 2. Anatomy of a real brick

Measured values for a 2x4 brick (3001), from Bartneck's calipered drawing (2019) and the LEGO brand
manual (2013). Section 3 says what the game does differently and why.

| Feature | mm | Notes |
|---|---|---|
| stud pitch | 8.0 | centre to centre |
| stud diameter | 4.8 | |
| stud height | 1.7 | measured 1.7–1.8; nominally 1 unit (1.6), varying by era |
| stud centre from part edge | 3.9 | 4.0 on the grid, minus the 0.1 clearance |
| clearance | 0.1 per side | a 1x1 is 7.8 across, a 2x4 is 15.8 x 31.8; the gap between neighbours is 0.2 |
| plate / brick height | 3.2 / 9.6 | height has **no** clearance |
| outer wall | 1.2 | the unit system says 1 unit (1.6); measured parts are thinner |
| top (ceiling) | 1.0 | the unit system says 1 unit (1.6); measured parts are thinner |
| underside tube | Ø6.51 outer, Ø4.8 inner | where four studs' corners meet: centres at (8i, 8j) |
| rib inside the wall | 0.8 wide (0.6 on the 2x4's end) | holds the stud from the side |
| one-wide underside pin | *measure before relying on it* | commonly quoted ~3.2 mm; no calipered source found |

The sheets give **grid** sizes (what the game uses: 8 x 8 per stud) and **real** sizes (0.1 in on
every side: model this for printing).

## 3. What the game does differently, on purpose

| Game | Real | Why |
|---|---|---|
| parts fill the whole grid cell | 0.1 mm clearance per side | the mesher merges faces across neighbours; a 4 mm gap at game scale would show everywhere |
| solid inside | walls, tubes, ribs | nobody sees the underside at game scale; a print needs them |
| studs taper to 86% at the top, 8 sides | straight cylinder | the house style (spec §2); a print can keep a straight stud |
| round parts and curves are octagons (45° facets) | round | low poly on purpose, matching the octagonal studs |
| slope falls 2 plates over 1 stud: 38.7° | same angle | real "45°" slopes are not 45° either |
| bracket side studs **5.6 mm** up (half a stud below the top) | 5.6 mm: centred in the top 5 of the brick's 6 units, like a Technic hole or a headlight stud | **Not a difference.** A part on the stud sits flush with the bracket's top and one unit (1.6 mm, half a plate) above its base: the real SNOT offset, exactly on the grid. |

## 4. Blender setup

- **Units:** Scene Properties → Units → Metric, **Unit Scale 0.001**, Length **Millimeters**.
  One Blender unit is then 1 mm and every number in the sheets can be typed straight in.
- **Grid:** snap increment 1.6 mm (one unit), or 8 mm for studs / 3.2 mm for plates.
- **Origin:** the part's minimum corner: bottom, at grid (0, 0, 0). The game places a part by its
  min cell, so a model with its origin anywhere else lands offset.
- **Axes.** The sheets use the game's axes: X = width W, **Y = up**, Z = length L. Blender is Z-up,
  and its glTF exporter (+Y Up) maps Blender (x, y, z) → game (x, z, −y). So in Blender:
  - width W along **+X**,
  - height along **+Z**,
  - length L along **−Y**.
  
  A profile listed in the "ZY plane" is drawn in Blender's YZ plane with Y negated.
- **Canonical orientation.** Model each part once, in the orientation the sheet describes: long
  side along L, a slope's low front at L = 0, a bracket's side studs on +X. The game makes every
  other orientation itself (`BrickWorld.bake_variant`); do not model turned copies.
- **Export:** glTF 2.0, +Y Up, apply modifiers. For the game, scale x0.04375 on import
  (mm → game metres); for printing, export STL at scale 1 in mm.

## 5. Figure-sized clearances (size only)

The legal brief rules out the minifigure's **shape** (a registered 3D trademark: no C hands, no
stud-topped cylinder head, no minifig hip/leg/torso silhouette). Its **size** is just a size, and
it is the size real brick buildings are designed around. So a building here should fit a figure
of these outer dimensions, and our own figure can be any shape inside them:

| | mm | bricks / studs | game m |
|---|---|---|---|
| height, without anything on the head | 38.4 | 4 bricks | 1.68 |
| height with a 1.8 mm top | ~40 | | 1.75 |
| width at the hips | 15.4 | just under 2 studs | 0.67 |
| depth | 7.8 | 1 stud, less clearance | 0.34 |
| footprint | | 2 x 1 studs | |

As a rule of thumb (common builder practice, not a measured source): a doorway for a figure this
size is 4 studs wide and at least 5 bricks of clear opening, and a storey is 6 or more bricks plus
the floor. Section 6 compares the game to these.

## 6. What the game commits to

Settled (Sep 2026), and enforced by `tools/scale_probe.gd` part 3:

| | Game | Print |
|---|---|---|
| figure height | 4 bricks, 1.68 m | 38.4 mm |
| figure width | 1.5 studs, 0.525 m: slimmer than figure-sized | 12 mm |
| head | 1.25 bricks, 0.53 m: bigger than the trademarked figure's | 12 mm |
| eyes | mid-head, 1.42 m | |
| storey | 6 courses + 1 plate slab, 2.52 m under the slab | 57.6 mm |
| doorway | 4 studs wide, 5 bricks clear (the 6th is the lintel) | 32 x 48 mm |
| window | 3 courses: sill 2 bricks up, head 5 up | |
| column | one storey, 18 plates | 57.6 mm |

Our figure's **shape** is our own: big head, slim body, low-poly, no C hands, no stud-topped
cylinder head, no minifig hip/leg/torso outline. Only its outer size follows section 5, so it
fits anything built for a figure that size.

When the storey went from 4 courses to 6, **no building got taller**. Every city shape kept its
height (or lost up to one storey of it) and got fewer floors: 11 floors became 7. Floors are three
quarters of a building's bricks (Docs/Scale.md), so fewer floors pays for the taller walls.

## Sources

- [Bartneck, LEGO Brick Dimensions and Measurements (2019)](https://www.bartneck.de/2019/04/21/lego-brick-dimensions-and-measurements/): calipered 2x4 drawing.
- [LEGO brand manual, minifigure measurements (2013)](https://tongal.s3.amazonaws.com/custom-files/2020/08/13/MinifigureProportions.pdf).
- [Brick Architect, figures in scale models](https://brickarchitect.com/scale/): a figure is 4 bricks without the head stud, 40 mm with it.
- [Zoe Blade, Lego brick dimensions](https://notebook.zoeblade.com/Lego_brick_dimensions.html): the 1.6 mm unit, and Technic holes and headlight studs centred in a brick's top 5 units.
