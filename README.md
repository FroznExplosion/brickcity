# Printed Brick City

A city of brick-built buildings that come apart the way brick-built things do. Every wall is
individual bricks on a grid; weight flows down through the joints; overloaded joints crush, the
collapse cascades, and what breaks off keeps breaking. Godot 4.6, Jolt, and a C++ GDExtension that
owns the grid.

The two things that make it possible at city scale:

* **An undamaged building holds no bricks at all.** It is a recipe, a shell mesh and five collision
  boxes. Shoot it and it materialises. 5000 registered buildings cost 0.0 MB of brick data.
* **Everything expensive is budgeted in milliseconds** — damage, promotion, splitting, meshing, the
  structural solve. A tick is allowed to run out of time and finish the work next tick.

Measured on a quiet machine: a 22-building collapse holds **16.7 ms mean, 2 of 742 frames over
budget**; 200 buildings damaged and 8 toppled holds 16.7 ms and 145 MB after trimming.

## Running it

```bash
godot --path . --resolution 1280x720
```

`LMB` fires, the mouse wheel sets how wide, `WASD` flies, `SPACE SPACE` swaps flying for walking
(the figure is just under three bricks tall), `F1` shows the stats. Build mode is its own scene:

```bash
godot --path . --resolution 1280x720 res://scenes/workshop.tscn
```

## What is in here

| | |
|---|---|
| [`Docs/Status.md`](Docs/Status.md) | **Start here.** What runs today, what it measures, and every limitation, written down rather than discovered |
| [`Docs/Plan.md`](Docs/Plan.md) | The architecture and the milestones |
| [`Docs/BuildMode.md`](Docs/BuildMode.md) | Connecting bricks: frames, welds, orientations, fixtures |
| [`Docs/BrickFailure.md`](Docs/BrickFailure.md) | Why joints fail in tension and never in compression, with the numbers |
| [`Docs/Interiors.md`](Docs/Interiors.md) | Rooms, contents and visibility |
| [`Docs/Multiplayer.md`](Docs/Multiplayer.md) | What the determinism substrate buys, and what is missing |
| [`Docs/AI.md`](Docs/AI.md) | Enemy, squad and commander AI — the design, nothing built |
| [`Docs/AIPlan.md`](Docs/AIPlan.md) | That design reviewed against the code, and the phased order to build it |
| `gdextension/brick/src` | The grid, the solver, the face bake — C++ |
| `tools/*_probe.gd` | Acceptance probes. Headless, no rendering, no physics |

## The gates

Nothing here is believed without a probe. Headless:

```bash
godot --headless --path . --script tools/m0_probe.gd        # grid
godot --headless --path . --script tools/m2_probe.gd        # stress and collapse
godot --headless --path . --script tools/build_probe.gd     # build mode, recipes, placement
godot --headless --path . --script tools/fixture_probe.gd   # fixtures
godot --headless --path . --script tools/interior_probe.gd  # rooms and contents
godot --headless --path . --script tools/dormant_probe.gd   # wreckage given back
```

And the ones that need a scene — add `--fixed-fps 60` if the window loses focus:

```bash
godot --path . -- --shot        # scripted collapse, writes shots/ and a frame-time report
godot --path . -- --stress --buildings=200
godot --path . -- --walk        # player collision
godot --path . -- --rooms       # interiors, including the portal test
godot --path . -- --chamfer     # the shaded bevel, differenced on and off
```

## Building the extension

The prebuilt Windows debug binary is committed, so the project runs on clone. To build it yourself:

```bash
git submodule update --init --recursive
cd gdextension/brick
scons platform=windows target=template_debug
```

`godot-cpp` is pinned as a submodule at the commit this was built against.

## Licence, and what is not licensed

The **code** is [GPL-3.0](LICENSE): use it, change it, redistribute it — and if you distribute a
changed version, publish your changes too.

Everything else is not. `Docs/` is all rights reserved, assets will be all rights reserved when
there are any, and the project's name is reserved. [NOTICE.md](NOTICE.md) sets that out, along with
the trademark disclaimer: **LEGO® is a trademark of the LEGO Group, which has no connection with
this project**, and no compatibility with any commercial brick system is claimed or intended.

## State

M0–M4 are in and probed; build mode's staged order is complete through fixtures; interiors have
their first pass. Everything measured here is a `template_debug` build on Windows — there is no
release build and no Linux binary yet. `Docs/Status.md` keeps the honest list.
