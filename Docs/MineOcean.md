# Mine world: the deep ocean

The user, 2026-11-26: oceans really deep, the middle of them fake water --
beaches and the floor real, the rest drawn -- since most of the time the
player only swims in it or rides a boat on it. Later a whole underwater
world: villages, and fast water tunnels like the currents in Finding Nemo.

## 1. What is already fake (nothing to build)

The sea is already the split the user describes ([MineWater.md](MineWater.md) 5, 4.4):

| Part | Real or drawn | Cost |
|---|---|---|
| Sea floor | real terrain bricks (sand, gravel, rock) | as any ground |
| Open sea's water | **worked out from the seed** (`gen_fluid`): a column whose top is under the sea course is ocean source up to it; nothing stored | none until touched |
| Sea surface | drawn: the wave tiers (`water.gdshader`, `BrickWave`) | the same for any depth |
| Beach edge | real source bricks, 6 studs wide (the real band, MineWater.md 11.9) | one course |
| Water the player disturbs | real cells in sections (16 bricks tall), saved as a difference from the generated sea | only where touched |

So the depth of the sea costs nothing in water: 90 m of untouched ocean stores
as much as 14 m (nothing). What a deep ocean needs is the ground under it, the
look from inside it, and things to do in it.

## 2. Stages

| # | Stage | State |
|---|---|---|
| 1 | Deep sea floor: shelf, drop-off, deep plains, trenches; the underwater look by depth | built |
| 2 | Breath and depth: a breath bar, drowning, a depth readout, diving fast | built |
| 3 | Currents: fast water paths through the deep that carry swimmers | built |
| 4 | Underwater villages: dry domes, flooding when broken | open |
| 5 | Later: caustics on the floor, light shafts, sea life, boats that dive | open |

### 2.1 Stage 1 -- the deep floor

`terrain_biomes.cpp column_base`, the ocean branch. Continentalness `c` under
`ocean_threshold` is basin; `d = ocean_threshold - c` is how far out:

* **Shelf** (as before): `d` 0 .. 0.30 slopes down to `ocean_depth_m` (14 m).
  Beaches and the shallows near them are unchanged.
* **Drop-off**: `d` from `deep_ocean_from` (0.34) over 0.10 falls on to
  `deep_ocean_m` (70 m) -- a steep slope, not a cliff.
* **Deep plains** roll by 4 m (the hill noise, stronger).
* **Trenches**: where the ridge noise is high, `trench_m` (20 m) more.
* Never deeper than `bedrock_m + 24` (the floor stays over the lava line and
  the bedrock, with rock under it for caves).

`deep_ocean_m` at or under `ocean_depth_m` turns it off (the old basins). All
three are GenParams (the World menu can show them; presets may set them).
Saved worlds: the generator changes, so the open sea of an old world gets
deeper where it is far from land; edits are stored as differences and stay.

**The look by depth** (`scripts/water/mine_dive.gd`): under water the fog
(`underwater.gd`) is set each frame from the depth -- clear and green near
the top, darker and bluer going down, near black at 60 m and more (fog
colour, density, ambient light and the view's brightness). Marine snow --
small motes drifting -- round the eye. The flashlight (already in the game)
is the light of the deep.

### 2.2 Stage 2 -- breath and depth

* **Breath** 20 s under water (the eye under), back at 4 s to full in air.
  Out of breath: 2 health a second until up. Creative mode never drowns.
* **Readout**: a bubbles bar and the depth in metres, shown only while under
  water or while breath is short.
* **Diving**: holding run while swimming swims 2x (down to a 70 m floor in
  about 15 s).

### 2.3 Stage 3 -- currents

Fast water paths through the deep (`scripts/water/mine_currents.gd`,
`MineCurrents`). Worked out from the seed like the sea, stored nowhere:

* A **region** of 256 m has a chance of one current. It starts at a random
  point of the region where the sea is 30 m deep or more, heads a random way
  and turns slowly, in 6 m steps, mid-way between floor and surface (never
  higher than 8 m under it), until the sea is under 20 m deep or it is 600 m
  long.
* **Push**: within 4 m of the path, the water flows along it at up to
  9 m/s (full at its middle, falling off to its edge), added to the water's
  flow (`Pawn.water_flow`) -- swimmers are carried, and steer out of it.
* **Look**: streaks drifting along the path near the eye.
* Regions round the player (two each way) are worked out as the player moves.

### 2.4 Stage 4 -- villages (open)

The terrain field is the one brick store and water only fills above a
column's top (`gen_fluid`): a dome on the floor is dry inside with water
over it; breaking it lets the water in by the ordinary rules. To prove first.

## 3. Open questions

* How deep at most? 70 m plains and 90 m trenches now.
* Boats that dive (a submarine) -- stage 5 or never?
* What lights the deep beyond the flashlight: glowing sea life, lamps?
* Pressure (damage past a depth without gear)?

## 4. Tests

`res://scenes/terrain_test.tscn -- --gate=ocean` (mine_world.gd
`_run_ocean_gate`): finds deep water, prints the floor depth, puts the pawn
at depth (the look's brightness by depth, pictures at 5, 30, 60 m), runs
breath out (drowning in survival, none in creative), finds a current and
measures the swimmer carried along it.
