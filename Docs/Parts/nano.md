# Nano bricks

The second grid. The **world** (buildings, terrain, large structures) is built on the full grid of
[README](README.md) section 1. Every **entity** -- figures, mechs, guns, gear, small props -- is
built of nano bricks: the same system at exactly half size.

Status: defined 2026-10-13. **Nothing here has been printed or built in the game yet.** Print
dimensions are nominal; a resin fit plate decides the final stud and socket sizes, as the FDM fit
plates did for the full grid. Machine-readable copy: [standards.json](standards.json).

## 1. The ruler

A nano brick is a brick at x0.5 on every axis. Its unit is the **nano tick**, 0.8 mm: half a tick.

| | Nano ticks | Print (mm) | Game (m), x43.75 | On the full grid |
|---|---|---|---|---|
| nano tick | 1 | 0.8 | 0.035 | half a tick |
| nano plate | 2 | 1.6 | 0.07 | half a plate |
| nano stud pitch | 5 | 4.0 | 0.175 | half a stud |
| nano brick (3 nano plates) | 6 | 4.8 | 0.21 | half a brick |
| figure | 48 | 38.4 | 1.68 | 4 bricks = 8 nano bricks |
| mech | 168 | 134.4 (5.29 in) | 5.88 | 14 bricks = 28 nano bricks |

So one full-grid cell (a stud square, a plate tall) is exactly 2 x 2 x 2 nano cells, and a nano
build whose origin is on a whole tick lines up with the bricks it stands on. The game factor is the
same 0.04375 m per mm; a nano build is the same chunk code drawn at half scale.

**The mech is 14 bricks tall** (decided 2026-10-13): 28 nano bricks, 5.88 m in the game, 134.4 mm
printed. `Mech.HEIGHT` in `scripts/mech/mech.gd` is 16 courses today and has to follow.

## 2. Anatomy of a nano brick (print, nominal)

Half of [README](README.md) section 2, so a nano part is the full part scaled, not a new design.

| Feature | mm | Half of |
|---|---|---|
| stud pitch | 4.0 | 8.0 |
| stud diameter | 2.4 | 4.8 |
| stud height | 0.85 | 1.7 |
| stud centre from part edge | 1.95 | 3.9 |
| clearance | 0.05 per side | 0.1 |
| nano plate / nano brick height | 1.6 / 4.8 | 3.2 / 9.6 |
| outer wall | 0.6 | 1.2 |
| top (ceiling) | 0.5 | 1.0 |
| underside tube | Ø3.25 outer, Ø2.4 inner | Ø6.51 / Ø4.8 |

The stud is **2.4 mm, not 2.0**: exact half, so every size on the full grid has a nano size and the
two grids share one set of numbers. The house style carries over: eight-sided studs tapering to 86%.

**Process: resin.** At this size an FDM nozzle (0.4 mm) cannot draw a 0.6 mm wall or a 2.4 mm
stud cleanly. Two things do not scale down with the geometry and are set by the process instead:

- **Clutch.** The full grid's underside leaf springs (`brickcity-print/gen_bricks.py`) are FDM
  features. Resin is stiff and brittle; a nano brick holds by a rigid friction fit, tuned with
  the stud diameter and socket width. A `fit_nano` plate comes before any nano part is trusted.
- **Clearance.** 0.05 per side is the nominal half; the exporter applies the process's own value.
  Model nominal sizes, never bake clearance into a mesh (the rule in `brick-part-ai-prompt.md`).

## 3. The part list

Every part in [parts.json](parts.json) exists as a nano part with the same shape, studs, tubes and
profile at x0.5. The name takes an `n_` prefix:

| Full | Nano | Nano size (mm) |
|---|---|---|
| `plate_1x1` | `n_plate_1x1` | 4.0 x 1.6 x 4.0 |
| `brick_2x4` | `n_brick_2x4` | 8.0 x 4.8 x 16.0 |
| `slope_...`, `curve_...`, `round_...`, `arch_...`, `bracket_...`, `tile_...`, `column_...` | `n_` + the same name | half |

There is no second table to keep: a nano part's numbers are the full part's, halved. Nano parts
are **not** mixed into a full-grid chunk; a nano build is its own frame (section 5).

## 4. Meeting the full grid

| Where | How |
|---|---|
| A nano build standing on full bricks | **Adapter**, `adapter_1x1`: one full stud socket underneath, 2 x 2 nano studs on top. One plate (3.2 mm) tall. `adapter_2x2` likewise, 4 x 4 nano studs. |
| Full bricks on a nano build | **Adapter**, `adapter_up_1x1`: 2 x 2 nano sockets underneath, one full stud on top. |
| Joints | The joint size ladder ([joints.md](joints.md) section 2) uses diameters both grids already have: 2.4 (nano stud), 3.2 (bar), 4.8 (full stud). A D6 joint pin fits a full stud socket. |
| Real LEGO bricks | The full grid stays compatible both ways (README sections 2 and 3). Nano parts are our own size; they meet real bricks only through an adapter. |
| Commercial nano blocks | Not a target. They share the 4 mm pitch but are 5 mm tall with a ridged underside, so they do not stack true with ours. |

A 2 x 2 nano part does **not** grip a full stud on its own: its cavity is 6.7 mm across and a full
stud is 4.8. That is what the adapters are for.

## 5. What is a nano build

| Class | Grid | Game | Print |
|---|---|---|---|
| world | full | x43.75 | FDM, 1:1 |
| entity: figure, mech, prop | nano | x43.75 (a frame at half scale) | resin, 1:1 |
| held: gun, gear | nano | entity size x `HELD_SCALE` ([joints.md](joints.md) section 7) | resin, 1:1 -- the full nano size |

In the game a nano build is a frame (Docs/BuildMode.md section 2) with one more fact: its scale is
one half. Not built yet. What it needs:

- a scale of 1 or 1/2 on a frame, in `BuildRecipe` and where a frame's transform is made;
- frame origins in nano ticks, or held to whole ticks;
- the recipe kinds `mech`, `gun`, `vehicle` and `aircraft`, which wait on links (BuildMode section 6);
- `scale_probe` reading [standards.json](standards.json), so the half stays exact.
