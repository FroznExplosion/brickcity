# Farming in the mine world -- plan

Planned 2026-11-25; stages 1 and 2 BUILT the same day (section 15), stage 3
on 2026-11-26 (section 16), stage 4 the same day (section 17), stage 5 too (section 18). The
scene is `scenes/terrain_test.tscn` (Docs/MineWorld.md). The user's answers
to the questions are in section 14.

## 0. What is asked

- Farming like Minecraft's, but deeper and less of a chore.
- Plants keep growing while the player is away and their ground is unloaded:
  each plant carries its time, its state is saved when the ground unloads, and
  when it loads again the plant jumps to where it would be by now.
- Growth rate set by a few things: the soil, water, the plant, and items that
  speed it up or raise the yield.
- Some randomness, so no two plants grow at exactly the same rate.
- Plants can die if not harvested.
- Random trouble: a farm that is not closed in properly gets eaten or trampled
  by animals.

## 1. What zylanntest had

Almost nothing on farming. Three ideas worth keeping:

- `Random junk for zylannvoxel.txt`: a 16-bit voxel with 6 "variant" bits, the
  example being a crop's growth stage.
- `Docs/voxel_planet_game_design.md` 2: blocks with state (chests, signs,
  redstone) live in a **sidecar map keyed by cell**, saved apart from the voxel
  data. The voxel grid stays dumb.
- Same doc, 12: each saved column holds a **last-saved tick**.

The mine world already works this way: chests and stations are records keyed
by cell (MineChests), not terrain materials, and water is its own grid
(BrickFluid). Farming does the same: a farm store beside the terrain.

## 2. What other games do

| Game | What it does | Take / leave |
|---|---|---|
| Minecraft | Random ticks; farmland wet within 4 blocks of water; light 9+; bonemeal; jumping tramples farmland; **nothing grows in unloaded chunks** | Take: water by distance, light. Leave: growth only near the player, player trampling, one-by-one replanting |
| Stardew Valley | Grows a stage a day if watered that day; sprinklers; fertiliser (quality, speed); crows eat crops unless a scarecrow covers them; crops die when the season ends; giant crops from 3x3 of one crop | Take: scarecrow radius, quality from care, giant crops, sprinklers. Leave: watering by hand every day |
| Vintage Story | Farmland holds three nutrients (N, P, K); each crop drains one; fallow ground refills slowly; fertilisers refill; crop rotation in four fields ([wiki](https://wiki.vintagestory.at/Farming/en)) | Take: soil that remembers, rotation. Simplify: one fertility number plus crop families |
| Don't Starve Together | Each plant collects **stress points** (too little water, too few nutrients, crowding, not tended, wrong season); 0-1 stress grows a giant crop ([wiki](https://dontstarve.wiki.gg/wiki/Farming)) | Take: stress decides yield and quality, the player can see why. Leave: talking to every plant |
| Valheim | Crops need cultivated ground and open sky; sources disagree whether they grow while their zone is unloaded ([Steam thread](https://steamcommunity.com/app/892970/discussions/0/3409803709040667486), [guide](https://timesaver.gg/blog/valheim-farming-guide-crops-cultivation)) | Take: open sky. Do better: catch up properly |
| RimWorld | Growth % a day from soil fertility, light and temperature; random blight; animals graze fields | Take: one rate made of factors; blight that punishes monoculture |
| Oxygen Not Included | A plant grows wild (slow, free) or domesticated (fast, needs water and fertiliser); bad conditions stop growth (it wilts), they don't kill | Take: wilt before death, so a mistake can be fixed |
| Animal Crossing | Real-world clock; flowers cross-breed into new colours from neighbours | Take: breeding by adjacency |
| AgriCraft (Minecraft mod) | Seeds carry stats (growth, gain, strength); crossbreeding on crop sticks improves them | Take: seed stats, bred over generations |
| Hytale | Hoe tills, watered soil grows about 2.5x faster, dry soil still grows ([guide](https://allthings.how/hytale-farming-basics-how-crops-tools-and-livestock-systems-fit-together)) | Take: dry is slow, not dead |
| Farming Simulator, Medieval Dynasty | Fields lose fertility with the same crop each year; lime, manure; weeds | Same lesson as Vintage Story, more chores |
| Factorio (Gleba) | Agricultural towers plant and harvest; produce spoils | Take: automation late; spoiling as a reason to harvest |

## 3. Deeper, but less of a chore

Tedium in farming games is mostly **repeated single clicks**: till one block,
plant one seed, water one tile, harvest one crop, replant it. Depth is
**decisions**: where, what, next to what, with what soil and water. So:

**Cut the clicks**
- Area tools. Hoe: hold and drag a rectangle (like the builder's shapes).
  Seed bag: plants every free plot in the rectangle. Scythe: harvests a
  rectangle and **replants from the harvest** (a toggle).
- Harvest goes straight into the inventory, spill to the nearest chest, then
  the ground.
- Water from the world: irrigation channels (real BrickFluid water) wet the
  ground round them. Watering by hand is an early, temporary boost, never a
  daily duty. Sprinklers later.
- No player trampling. Animals trample; the player does not.
- Look at a plant: its stage, % to the next, time to ripe, and **what holds it
  back** ("dry", "dark", "poor soil", "open to animals"). DST's lesson: the
  player can always see why.

**Add decisions**
- Soil fertility that drops with use and recovers fallow, with legumes or
  compost (section 6).
- Crop families and rotation: a different family than last time grows better.
- Companions: some pairs side by side help (beans next to corn).
- Stress -> quality: a well kept plant yields more and better (1-3 stars).
- Giant crops: a 2x2 or 3x3 of one crop, all at low stress, may merge into one
  giant brick-built crop (a giant pumpkin build).
- Breeding: two varieties with a free plot between can seed a cross into it;
  seeds carry stats (growth, yield, hardiness) that improve over generations.
- Biome crops: each world's biomes favour some crops, so farms differ by
  planet.
- Enclosure: fences, walls, or a scarecrow decide what wild animals reach.

## 4. The world clock

The mine world has no saved clock today: `_time` (the day fraction,
`DAY_SECONDS` = 1200) restarts at 0.30 every load.

- New: `world_time`, seconds of game time since the world was made (float64),
  saved in the world file (`.inv`, key `time`). `_time` becomes
  `fposmod(world_time / DAY_SECONDS, 1)`. A side effect: the sky keeps its hour
  across loads.
- `world_time` runs while the game runs, in this world, whatever is loaded.
- While the game is CLOSED it stands still, unless the user wants real time to
  count (section 14, question 1). If so: on load, add the real seconds since
  the save, capped (say 3 in-game days), and log it.
- Gates hold the clock as they hold `_time` today.

## 5. The key idea: one function, called whenever

Plants are **not ticked**. Each plant record keeps when it was last brought up
to date (`settled_at`). One function,

    settle(plant, now) -> plant brought up to `now`

works out what happened between `settled_at` and `now` and moves the plant on.
The same function runs for a plant in view and for one whose ground loaded
after an hour away. There is no separate "offline" formula, so a farm the
player watches and one they left behave the same.

**Exact whatever the gaps.** `settle(p, t2)` must give the same plant as
`settle(settle(p, t1), t2)`. That is what makes watching and leaving the same,
and it lets peers agree (multiplayer, MineWater.md 11.5). It holds because:

- Growth is plain arithmetic: progress += rate x daylight seconds, and stage
  boundaries are found by solving for the time, not by stepping.
- Daylight is a closed-form integral of the sun curve (section 5.1), so no
  per-hour loop.
- Random things are drawn as **event times**, not per-tick dice: the time of a
  plant's next event is drawn once, from a random number keyed by (plant seed,
  event count), stored in the record, and when `now` passes it the event
  happens and the next one is drawn. However often settle is called, the same
  events happen at the same times.
- What can change a plant's conditions (water put down, a fence built, a
  fertiliser) happens only while its ground is loaded, and settle runs on the
  plant first, then the change applies. While unloaded nothing changes, so
  conditions are constant and the catch-up is a few steps per stage and per
  event, **independent of how long it was away**.

**Cost.** An unloaded plant costs nothing. A region loading settles its plants
once (a few microseconds each; 10k plants on a worker, a few ms). A loaded
plant is settled round-robin a few hundred a frame, when looked at, and when
touched.

### 5.1 Time pieces in a settle

Between `settled_at` and `now`, settle walks these boundaries in order:

1. The next stage boundary (from progress, rate and daylight).
2. The next random event (`next_event_at`).
3. Water running out (a hand watering lasts one in-game day).
4. Ripe -> overripe -> dead (section 7).
5. `now`.

Daylight: the sun height is `sin((t / DAY - 0.25) * TAU)`; light for growth is
`clamp(height * 2.5 + 0.4, 0, 1)` like `_day_night`. Its integral over a whole
day is a constant; over a part day it is a short closed form (or a 64-entry
table of the integral over one day, read and interpolated). Plants under a
roof use the cell's own light (section 8), not the sun.

## 6. How fast it grows

    rate = base(species)
         x soil      fertility 0-100 -> 0.5 .. 1.2, rotation bonus
         x water     dry 0.4, wet 1.0, too wet (in water) 0 for most
         x light     sky or lamp light in the cell (MineWorld.md 18)
         x biome     the crop's liking for this biome / height: 0.6 .. 1.3
         x boosts    fertiliser, compost, companion neighbours
         x jitter    0.85 .. 1.15, drawn per plant per stage

- `base` is per species: seconds of full daylight per stage. Wheat ~1.5
  in-game days to ripe; berries regrow in ~1 day; pumpkins ~3 days.
- **Jitter** is drawn from (plant seed, stage), so a row planted together
  ripens over a spread, and the same plant always gets the same draw.
- **Fertility** belongs to the plot, not the plant: each harvest takes the
  species' drain; fallow plots recover a little per day; legumes give some
  back; compost adds a lot. A plot also remembers the last crop's family
  (grain, root, leaf, legume, gourd): a different family gets +15%.
- **Stress** counts what went wrong over the plant's life (stages spent dry,
  dark, on poor soil, crowded, nibbled). It sets yield and quality:
  0-1 stress 3 stars and a chance of a giant crop, 2-3 two stars, more one
  star.

## 7. Stages and states

    seed -> sprout -> growing (2-4 stages by species) -> RIPE -> overripe -> dead
                         |                                 ^
                         +-- wilted (too long dry/dark) ---+ recovers when fixed

- **Ripe** for a window per species (wheat ~2 in-game days), then
  **overripe** (yield halves, seeds still drop) for another window, then
  **dead**: a brown husk. Breaking it gives compost and sometimes a seed.
  Hardy crops (pumpkins, gourds) never rot; berry bushes drop their berries
  and start again.
- **Wilted**: a plant dry or dark for a whole stage stops growing and wilts
  (ONI). Fixed within a day it recovers with a stress point; left, it dies.
- **Perennials** (berry bushes, fruit trees later) go back a stage after
  harvest instead of being replanted.
- **Saplings**: a sapling grows into a real tree (a TerrainTrees row; felled
  ones already save), so the player can replant forests.

## 8. Water, light, soil: read from the world, cached on the plot

settle must not ask BrickFluid or the sky light about an unloaded place, so
each plot keeps what it needs, worked out when its ground is loaded:

- `wet`: water (BrickFluid `cell_info`) within 4 studs on the plot's course or
  one below, or a sprinkler in range, or a hand watering not yet run out
  (`wet_until`). Worked out when the plot is made, when its tile loads, and
  when the water or the terrain changes within 4 studs (MineWater already
  dirties tiles; listen for those).
- `light`: open sky above the plot (follow the sun) or the cell's light level
  from lamps (MineWorld.md 18: lamp light needs no sun). Cached the same way.
- `enclosed`: section 9.

Wet and lit stay what they were while unloaded, which is right: nothing there
can change while nobody is there (water past the sim ring is frozen,
MineWater.md 6).

## 9. Animals and other trouble

The mine world has no animals yet (Docs/Creatures has the procgen creature
plans). So trouble comes in two forms, both as random events (section 5):

- **Unloaded or no animals near**: an abstract **pressure** per farm: the
  biome's wildlife density x how open the farm is. An event picks a plant:
  eaten (gone, or back to sprout), or its plot trampled (back to plain dirt,
  the plant lost).
- **Loaded, with real animals** (later, when creatures come to the mine world):
  real animals path to crops they like and eat them; the abstract pressure
  stops for loaded farms. Planned in Docs/MineCreatures.md 5.3: per-animal
  open/closed (deer jump two bricks), eating and trampling by real herds.

**Open or closed.** A farm is a connected group of plots (a field). It is
**enclosed** when a walk over the ground from its plots cannot get more than
24 studs away: a flood fill over walkable cells (the pawn's step height, one
brick), stopping at walls, fences, water two bricks deep, or drops it cannot
climb. Gaps under 1 stud do not count (a door shut counts as a wall). Cached
per field, worked out again when terrain edits land within 24 studs. Not
enclosed -> full pressure; enclosed -> none; a scarecrow in range halves
birds. The HUD on a plant says "open to animals" and shows the gap, so the
player is not left guessing.

**Other events** (each its own rate, all optional by setting):
- **Birds**: open sky plots, ripe grain only; scarecrow covers a radius.
- **Weeds**: on a plot left untouched for days; a weed takes fertility.
  Mulch (a leaves item!) stops them. Rare, so weeding is never a chore.
- **Blight**: a field of more than ~64 plots of ONE species may roll blight,
  spreading plot to plot; mixed fields and gaps stop it. The reason to plant
  variety.
- **Fire**: crops burn (lava already lights `material_burns`).
- **Frost**: high or snowy biomes, for crops that dislike cold.

## 10. How it looks, in bricks

- A **plot** is one builder block, 2 x 2 studs on the stud lattice (the
  chests' `block`). The hoe lowers the top plate by one (a terrain edit, grass
  to dirt) and lays a furrowed tile on it, drawn as an instance. Wet plots draw
  a darker tile. No new terrain material for stage 1 (section 14, question 4).
- A **crop** is a small brick build per stage (1-3 bricks tall, plants and
  flowers from the parts catalogue), drawn as MultiMesh instances per terrain
  tile, pooled like the tiles' tufts and pebbles (MineWorld.md 9). No node per
  plant. The far tier draws a coloured patch per field.
- A giant crop is a hand-made brick build (content/base/builds/), placed as a
  chest-like record.
- Harvest bursts into the crop's bricks (the existing crumbs), then the items.

## 11. Data and saving

**Plot record** (binary, ~28 bytes):

| Field | Size | |
|---|---|---|
| block (x, y, z) | 3 x int32 | key; the chest key form |
| species | u16 | catalogue id; 0 = bare tilled plot |
| stage, flags | u8, u8 | flags: wilted, dead, replant, giant part |
| progress | u16 | 0..65535 of the stage |
| settled_at | f64 | world_time of the last settle |
| next_event_at | f32 | offset from settled_at |
| seed, event count | u32, u8 | the plant's own randomness |
| fertility, last family, stress | u8, u8, u8 | |
| wet_until / cached wet, light, field id | packed | |

- Kept by 256 x 256-stud region like the terrain's edits:
  `<save>.regions/r_<rx>_<rz>.farm` (zstd, header `BCMF`, format 1), only
  regions changed since the last save, written on the worker with the edits.
  A settle that moved a plant marks its region changed.
- Fields (enclosure results) are not saved; worked out on load.
- `world_time` in the world file.
- A world without a farm writes no farm files.

**Code** (new folder `scripts/farming/`): `FarmStore` (records by region,
save/load), `FarmPlant` (settle, rates, events: pure functions, no nodes, so a
probe runs them headless), `FarmCrops` (species data from
`content/base/data/farming/crops.json`, through ContentPacks so mods add
crops), `FarmDraw` (instances per tile), `FarmFields` (enclosure). Items
(seeds, hoe, scythe, watering can, fertiliser, produce) in the item catalogue;
recipes in the recipe book. The mine world calls it the way it calls
MineChests.

## 12. Stages

Each stage merged on its own, with its probe.

1. **Clock and one crop.** `world_time` saved; hoe (single plot), wheat seeds,
   plant, grow, harvest, replant by hand; settle on tile load and round-robin;
   region save; the look HUD. `farm_probe` (headless): one long settle equals
   many short ones (exact), save/load round trip, unload -> wait -> reload
   gives the right stage, ripe -> overripe -> dead.
2. **The factors.** Water by distance, light (sky and lamps), fertility and
   rotation, jitter, stress and stars, wilting. HUD says what holds it back.
3. **No more chores.** Area hoe and seed bag, scythe with replant, harvest to
   inventory/chest, hand watering as a boost.
4. **More plants.** 6-8 crops over the families, berry bushes, saplings that
   become trees, compost bin (leaves and dead crops in, compost out),
   fertilisers. What the crops are FOR (section 14, question 2).
5. **Trouble.** Fields and enclosure, abstract animal pressure, scarecrow,
   birds, weeds and mulch, blight, fire. Each with a setting.
6. **Depth.** Companions, breeding and seed stats, giant crops, biome crops
   per planet.
7. **Automation.** Sprinklers, a collector that empties ripe plots in range
   into a chest, later a farmhand.

## 13. Risks

- **Many plots in view.** Instances per tile keep the draw cheap; the
  round-robin settle is capped per frame. A 10k-plot farm is the gate's case.
- **Region load spikes.** Settling a big farm on load goes to a worker, the
  results applied next tick (no waiting, CLAUDE.md).
- **Exactness drifts.** Float sums over long gaps: progress is solved per
  stage from the stage's start time, not accumulated, and times are float64.
  The probe compares one settle with many.
- **Terrain area.** Farming touches mine_world.gd and the builder (Terrain and
  inventory owners); the farm code itself stays in `scripts/farming/`.

## 14. The user's answers (2026-11-25)

1. **Closed game: no.** Crops grow only while the player is in the world --
   anywhere in it, loaded or not -- never while the game is closed.
2. **What crops are for:** later selling, health, maybe hunger and crafting.
   For now only the growing is built.
3. **Trampling:** the player tramples a plot only by LANDING on it from more
   than a standard jump: a fall of 3 bricks or more. Walking and jumping on a
   field are fine.
4. **Tilled soil:** the brick itself becomes a tilled brick with a smooth top
   -- a real terrain material (farmland), not a drawn tile.
5. **Death:** only some crops could die, and maybe none will: deferred. Ripe
   crops wait.

Also asked: a farming guide in the game, for every crop: how farming works
and what each crop wants (built: the inventory's Farming tab, section 15).

## 15. Built (2026-11-25): stages 1 and 2

**Controls.** Hoe: RMB on the top of grass, dirt or podzol. Seeds: RMB on
tilled soil. RMB on a ripe crop harvests (whatever is in the hand) and
replants from the seeds carried. LMB on a crop: harvest if ripe, else pull it
(seed back). LMB on bare tilled soil breaks it (soil back). Looking at a plot
shows a line over the hotbar: crop, stars, stage, time to ripe, what holds it
back, the soil. E -> Farming: the guide. Creative kits get a hoe and every
seed; survival finds seeds breaking grass and the like by hand (each crop's
`found`).

**Tilled soil** (C++, append-only): `MAT_FARMLAND` 39 and `MAT_WET_FARMLAND`
40 in brick_terrain.h -- unstudded like road (`material_studded`), bonded
like soil, no tufts or curved bricks on them, dirt's filament. The terrain
shader (`TERRAIN_FARMLAND`) furrows their tops, two ridges a stud along X,
and darkens the wet one. The hoe fills the 2x2 block's whole 3-plate course
with farmland and marks it placed (`mark_placed` marks whole courses only),
so it is ONE brick; a ground top part way up a course is dug down to the
course under it. Water within 4 studs (the course of the soil or the one
over it) turns it wet farmland, and back when the water goes. Breaking it
gives soil (`ItemCatalog.FARMLAND_GIVES`); farmland is no item.

**The clock.** `world_time` (mine_world.gd), seconds played in the world,
saved in the world file (`time`); the sky's hour is its day part, so the sky
keeps its hour across loads too. T moves it an hour (the crops get it). An
autosave marks the world file out of date when the clock has moved 5 s.

**Code.** `scripts/farming/`: `FarmCrops` (content/<pack>/data/farming,
ContentPacks), `FarmPlant` (the plot as data, `settle`, rates, harvest,
stars; the daylight integral is a 480-sample Simpson table of the sky's own
curve, growth at night 15% of noon), `FarmStore` (plots by 256-stud region,
`<save>.regions/r_x_z.farm`, `BCMF` format 1, written on the save worker),
`FarmDraw` (crop models of brick parts per stage, MultiMesh instances within
96 m), `MineFarming` (the mine world's: till, plant, harvest, trample,
refresh of water/light/soil, the look line), `FarmGuide` (the guide page,
written from the crop table and the growth rules), `farm_gate.gd`.
Crops: wheat, carrot, potato, beans (give fertility back), pumpkin (thirsty,
slow), berry bush (regrows); items in content/base/data/items/farming.json.

**Not yet** (later stages): real animals (abstract for now), breeding, giant crops, automation, death.

**Tests.** `farm_probe` (headless, 55 checks): the materials and shader
numbers, the crops and their items, one settle == many == saved half way for
every crop over 0.3, 1.7 and 5 days, daylight, every factor, the spread,
harvests and stars, fertility, region save. `--gate=farm` (windowed): till
(through the builder, a raised top dug down, stone and side faces refused),
plant, a dug channel wetting the near plots only, two days of growth (wet
wheat ripe, dry not), the field drawn, RMB harvest + replant, LMB pull, a
plot out of reach untouched while the clock runs and caught up exactly on
return, a real fall trampling (a hop not), the world generated again with
the farm and the clock intact; pictures `user://dev/farm_field.png`,
`farm_guide.png`.

## 16. Built (2026-11-26): stage 3, no more chores

**Whole fields.** Hold RMB with a hoe, seeds, a scythe or a watering can,
move, let go: the rectangle between (MineFarming.area, up to AREA_MAX = 9
plots a side, from where the drag began) is tilled, planted, harvested and
replanted, or watered. An outline shows the rectangle while held
(MineBuilder.farm_drag_begin / farm_drag_end; a release on the plot it began
on is the tool's plain click). Seeds stop when the stack does, the can when it
is empty. Each column's top is found near the plate the drag began on
(`_top_near`), so a field on a slope or in a cave works, never the surface far
over a cave.

**Scythe.** RMB: every ripe crop 3 x 3 round the plot, each replanted from
the seeds carried; a drag: the rectangle.

**Watering can.** LMB on water fills it (16 plots; a sip takes no water
away). RMB on tilled soil: wet for a day (FarmPlant.CAN_LASTS), the soil dark
at once. A plot's `wet_until` is a time like a stage's end: `settle` cuts the
interval there (wet before, the plot's own water after), so the catch-up is
still exact; saved as a plot row's 18th field (old 17-field rows load as
never watered).

**Chests.** What a harvest gives that will not fit the inventory goes into
the nearest chest or put-down backpack within 8 m (merged into its stacks,
then empty slots), then the ground.

**Recipes** (data/recipes/farming.json): hoe 12 wood + 12 stone at a
workbench, scythe 12 wood + 2 iron ingots at a workbench, watering can 2 iron
ingots at a workbench (ingots since the furnace smelts, Inventory.md 15). Creative kits get all three. Icons for the scythe and can.
The guide's how-to says all of it.

**Tests.** farm_probe +8 (63): exact across a can's water running out
(once == often == saved across it, wheat and pumpkin), watered beats dry,
old rows load, the recipes, the area cap. --gate=farm +7: a hoe drag tills
4 x 2, a carrot drag plants them, LMB fills the can from the channel, a can
drag waters exactly the dry ones (all dark after), four days on (the can's water lasts one) a scythe drag
harvests and replants all 8, a scythe click takes the ripe 3 x 3, a harvest
too big for the inventory lands in a chest by the field.

## 17. Built (2026-11-26): stage 4, more plants

**New crops** (crops.json): corn (grain, tall, thirsty and hungry, planted
from a cob), cabbage (the leaf family: quickest, shade-happy, light on the
soil), melon (gourd, the thirstiest). Nine crops over six families now.
Models: `corn` (two stalks, cobs), `head` (stacked round plates), and the
gourd shape in melon green.

**Saplings -> real trees.** Oak, dark oak, birch and acacia saplings (one
per tree variant, `tree` in their crop) are planted with RMB on the top of
plain grass or dirt -- no hoe (`ground: "soil"`: a plot on plain soil,
`MineFarming._soil_plot`, its four tops within a brick). They grow like any
crop (drawn as a `sapling`: trunk and leaf block); when ripe the plot goes and
`TerrainTrees.plant_tree` stands a real tree there: drawn, collided, felled
and yielding like the seed's own. Grown trees are a `planted` list (trunk
cell -> [plate, variant]) streamed in with their cell (even where a felled
tree stood) and saved in the world file (`planted`). Felling any tree in
survival gives its sapling half the time. A drag plants saplings 3 plots
apart. Seeds of crops are refused on plain soil.

**Compost and grow mix** (kind `fertiliser`, fields `fertility`,
`boost_days`). A compost bin (24 wood at a workbench) is a station: within
4 m of it, 48 leaves or 6 of any crop (tag `crop`, on every produce) make 4
compost. Compost on a plot: +30 fertility. Grow mix (4 compost + 2 coal ore
at a workbench): +10 fertility and x1.5 growth for 2 days (`boost_until`, a
cut in `settle` like a can's water, so still exact). Both by click or drag.
Plot rows now have 20 fields (boost_until, ground); older rows load.

**Tests.** farm_probe 100: exact across a grow mix's end (corn, cabbage),
boosted ripens sooner, rows keep ground and boost, a sapling per tree kind on
plain soil, a sapling grows up, the recipes, every produce composts.
--gate=farm adds: a sapling on plain grass (seeds refused there), corn,
cabbage and melon planted, compost crafted at a bin, compost raises a plot's
fertility, a grow mix drag boosts 8 plots, the sapling grows into a planted
tree and is felled; picture user://dev/farm_stage4.png.

## 18. Built (2026-11-26): stage 5, trouble

**Events, still exact.** Each planted plot has a hazard: the sum of its
trouble rates, which hold still between changes. It keeps `haz_acc` (hazard
so far) and `haz_next` (an exponential drawn from its seed and its event
count); an event happens when the one reaches the other. `settle` now walks
in steps to the next of: a can's water or grow mix running out, the stage's
end, the next event, or now -- so an event lands at the same moment however
often the plot is settled (farm_probe: 12 plots with every trouble on, once ==
often == saved half way). `FarmPlant.trouble` off: no events (the world menu's Farm trouble switch,
section 19; the gate's other checks run with it off).

| Trouble | Rate a plot a day | Needs | Does | Stops it |
|---|---|---|---|---|
| animals | 0.25 | an open field | 3 in 4 eat it back 2 stages (a stress point); 1 in 4 trample it: crop lost, the tilled brick dirt again | close the field in |
| birds | 0.6 | ripe grain or beans, open sky | peck it back from ripe to half a stage before | a scarecrow within 8 m (x0.2) |
| weeds | 0.12 | a crop, no mulch | x0.6 growth, a stress point a stage, till pulled (LMB) | mulch (12 leaves -> 6, by hand) |
| blight | 0.06 | a field of one crop (24+ plots, 90%) | the crop lost | mixed fields |

**Fields** (FarmFields): plots touching 8 ways, within a brick of each
other's height. Open or closed by a flood over stud columns from the field's
plots: a step is allowed to a column whose top is within one brick (3
plates) up or down with two plates of room over it; reaching 24 studs past
the field means open. So a wall two bricks high, a two-brick drop, or a dug
moat all round closes it. The flood runs on a WorkerThreadPool job, one
field at a time, taken when done (never a wait); fields are worked out again
when plots come or go or any terrain edit lands (MineWorld.terrain_edited ->
`terrain_changed`), at most every 1.5 s, for fields within 96 m. The flags
(open, mono) are set on the plots after settling them, and saved with them:
while far away a field stays as it was.

**In the world.** An animals' trample (`packed`) is applied when the plot is
next settled in reach: the tilled brick turns to dirt and the plot goes. LMB
on a weedy plot pulls the weeds first (the crop stays). The look line shows
"open to animals", "one-crop field: blight", weeds, "mulched", "scarecrow
near", and the last event with how long ago. Items: scarecrow (12 wood + 6
wheat at a workbench, a placed station with its own model), mulch. Plot rows
now have 31 fields; older rows load with no trouble.

**Tests.** farm_probe 109 (+9): exact with every trouble on; animals only in
open fields; mulch keeps weeds off; a scarecrow cuts bird visits; weeds slow
growth; trouble off means no events; fields group and spot a one-crop field;
old rows load. --gate=farm: the field open, a stone ring closes it, a gap
opens it (real floods), a scarecrow marks plots, LMB pulls weeds and keeps
the crop, mulch goes on, an animals' trample turns a plot to dirt, and three
days with trouble on bring events.

## 19. Farm trouble switch; what a plot's look costs (2026-11-26)

**The switch.** M (world generation) > Game mode > **Farm trouble**, under
Survival: on by default, this world's, at once, saved in the world file
(`farm_trouble`). `MineWorld.set_farm_trouble` settles every plot first, so
the time already passed keeps the rule it had; then `FarmPlant.trouble`
changes. A gate keeps its own setting (the world file is not read for it).

**The plot look's cost** (`MineFarming.refresh`, one plot a frame within 64
m: water, light, scarecrow, the tilled brick's wet/dry swap). Each part is
timed (`MineFarming.prof`, printed by --gate=farm). Before, 933 refreshes in
the gate (6 other test processes running and RAM nearly full, so the worst
numbers are high):

| Part | Mean | Worst |
|---|---|---|
| water (~200 BrickFluid.cell_info calls, a Dictionary each) | 198 us | 1705 us |
| sky light (BrickTerrain.sky_light_at, a fill) | 34 us | 863 us |
| scarecrow (every chest walked) | 14 us | 202 us |
| soil swap (only when wet/dry changed: a fill_box + re-bake) | 12 us | 286 us |
| block light | 5 us | 30 us |
| settle | 1 us | 24 us |

Changes:
- **Water**: `BrickFluid.any_fluid(lo, hi, fluid)` (C++): is any cell of the
  box wet with that fluid, under one lock -- one call instead of ~200.
  And not asked at all when no water changed anywhere (BrickFluid's
  `change_count`) and no terrain edit landed since the plot was last asked.
- **Light**: asked again only when a terrain edit landed since the plot was
  last asked (`_terrain_ver`, bumped by `terrain_changed`) or after 30 s;
  kept on the plot, not saved. The sky's light in a cell only changes with
  the ground; the day is the sun's integral, not this.
- **Scarecrows**: gathered once a second (and whenever the number of placed
  chests and stations changes), not walked per plot.
After (the same gate; 2-4 other test processes, RAM again near empty):

| Part | Before mean / worst | After mean / worst |
|---|---|---|
| water | 198 / 1705 us | 33-42 / 714-1039 us |
| sky light | 34 / 863 us | 7 / 113 us (one run: a 323 ms call while RAM was at 1 MB free -- paging, not the game) |
| scarecrow | 14 / 202 us | 7-9 / 65-303 us |

A refresh is ~60-70 us on average now (it was ~265). Water is still the
biggest part: the box is 200 cells and cells not yet simulated are generated
on the spot; the change-count skip seldom hits while rain and the sea keep
the water changing. The worst frames in these runs are paging. Next if a big
farm hitches: look at fewer plots a frame when the frame is already long, or
a field-wide water map shared by its plots.

## 20. Built (2026-11-26): stage 6, depth

**Seed traits.** Every plant has Growth, Yield and Hardiness, 0-10 (plot
`tg`, `ty`, `th`), from the seed it was planted from (an ItemStack's data
`{g, y, h}`; plain seeds have no data, so they stack with each other and a
seed's label reads "Wheat seeds (G5 Y2 H0)"). Growth: x(1 + 0.04 a point).
Yield: +8% of a harvest a point. Hardiness: dry soil 6% a point nearer full
speed, and at 5+ a dry stage is no stress. A harvest's seeds (and a crop
planted as it is, its produce) carry the plant's traits; at 3 stars 30% of
the time one trait gains a point (2 stars 10%), never a loss -- rolled from
the plant's seed. The harvest replants with its own seeds first. So a crop
kept well gets better generation by generation.

**Breeding.** A bare tilled plot between two ripe plants of one crop, in a
line (E-W or N-S), may sprout a CROSS: each trait the better parent's, half
the time one point more. About once in half an in-game day of both ripe --
but only while in reach (it needs both parents in view, checked in the plot
refresh; it is not in `settle`, so it is not part of the exact catch-up).

**Companions** (crop `companions`): x1.15 when one grows in the 8 plots
round it -- beans by corn or wheat, corn by beans, pumpkin or melon, carrot
by cabbage and back, potato by beans, pumpkin and melon by corn. Cached on
the plot (`companion`) by the refresh, after settling, like wet.

**Giants** (crop `giant`: pumpkin, melon). A 2x2 of one, all ripe at 3
stars, may merge (40%, rolled once per 2x2 from its four plants' seeds, so a
miss stays a miss until replanted): the corner plot `giant` 1, the other
three 2 (`gdx`, `gdz` to the corner). Drawn as ONE round brick 4 x 4 studs
and three bricks tall, studded, with a stem and leaves (`FarmDraw.giant_mesh`).
No trouble reaches it. Picked (any of its plots) it gives twice what its four
plots would (the gate: 14 pumpkins), and each plot is replanted. A giant that
loses a plot falls apart into ripe plots.

**Biome crops** (crop `only`): cactus fruit (desert, badlands, savanna; needs
no water at all), frostberry bush (where it snows; regrows), pineapple
(jungle). Planting elsewhere is refused (`MineFarming.grows_here`). New model:
`cactus`. 12 crops and 4 saplings now.

**Kit.** The creative kit's farm part is now the hoe, scythe, watering can,
wheat seeds and compost; the rest is in the Creative tab. With every seed in
the kit a fresh character's bags were full and harvests fell on the ground.

**Tests.** farm_probe 136: growth/yield/hardiness effects, seeds carry traits
and gain (never lose) points, trait-less seeds have no data, companion speed,
exact with traits and a companion, biome-only crops, giant flags and no
trouble on giants, 38-field rows, older rows load. --gate=farm 70: a seed's
traits into its plant and back through its harvest's replant, the label,
corn by beans, a cross between two ripe wheat plants (G1 Y3 from G1 and Y2),
cactus fruit refused outside its biomes, four 3-star pumpkins merging into a
giant (chance set to 1 for the gate), drawn as one, picked for 14 pumpkins
(user://dev/farm_giant.png). The "away" check now waits until the farm has
noticed the player left (its in-reach list is rebuilt once a second).

## 21. Built (2026-11-27): stage 7, automation

**Sprinkler** (3 iron ingots at a workbench; a placed station, its own
model): every plot within 3 plots of it (a 7 x 7 square, within 6 plates up
or down) counts as wet -- no water source. Joined to the plot's own water
in the refresh (`_sprinkled`; the cached water look stays separate, so a
sprinkler put down counts at once). The look line says "wet (sprinkler)".

**Collector** (a chest, 4 iron ingots and 1 gold ingot at a workbench; a
placed chest of 27 slots with its own model, opened like a chest): when a
plot within 4 plots of it (9 x 9) is refreshed ripe, the collector harvests
it into its own slots and replants it from a seed it holds (the harvest's own
traits first, else any). It leaves giants and saplings, and does nothing
while it has no empty slot (the crop waits ripe). It works in reach only, as
the plot refresh does; a field left alone simply waits ripe (nothing rots),
and is collected when the player comes back. Sprinklers, collectors and
scarecrows are gathered together once a second, and again whenever the
number of placed things changes.

**Not built**: a farmhand that walks the rounds needs a creature to walk
(the creature work); the collector does its job for now.

**Tests.** farm_probe 140 (+4): the items and their kinds (the collector is
a container), the recipes, the collector's slot filling and seed finding.
--gate=farm 73 (+3): a sprinkler turns a dry plot wet and dark; a collector
given wheat seeds, corn and beans harvests the ripe plots in reach (5: wheat,
pumpkins, a melon and their seeds) and replants from what it holds; it is
then broken so the 'away' check sees plain growth.

**All stages of section 12 are built.** Set aside, by the user's choice:
what crops are for (selling, health, hunger, crafting), real animals, crops
dying, and a farmhand.
