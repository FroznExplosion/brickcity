# Farming in the mine world -- handoff

Written 2026-11-27 for the next chat that works on farming. The full design
and build log is Docs/MineFarming.md (sections 0-23); this note is the short
way in: what is there, how it works, how to test it, what the user decided,
what was researched, and the next round (fruit trees, more bushes, an auto
farmer) designed but NOT built -- the user asked for this note first.

## 1. State

All seven planned stages, the trouble switch, the gap fixes and "real animals
only" are merged into main (last farming merge be834d76, 2026-11-27).
Worktree: `.claude/worktrees/farming` (branch `farming`) -- it has a godot-cpp
JUNCTION: `cmd /c rmdir .claude\worktrees\farming\gdextension\brick\godot-cpp`
before any `git worktree remove` (CLAUDE.md, Building).

| What | Where in MineFarming.md |
|---|---|
| tilled soil (terrain materials 39/40), hoe, crops, catch-up growth, saves, guide | 15 |
| drag tools, scythe, watering can, chest spill | 16 |
| corn/cabbage/melon, saplings -> real trees, compost, grow mix | 17 |
| trouble: birds, weeds, blight (animals now real, 23) | 18, 23 |
| Farm trouble switch; plot look cost (BrickFluid.any_fluid) | 19 |
| seed traits, breeding, companions, giants, biome crops | 20 |
| sprinkler, collector | 21 |
| far fields, crops lit like caves, refusal messages | 22 |
| real animals only: no animal events, no fence flood | 23 |

16 crops (incl. 4 saplings), 12 produce items, tools hoe/scythe/watering
can, compost/grow mix/mulch, compost bin, scarecrow, sprinkler, collector.

## 2. The user's decisions (keep them)

- Crops grow only while the player is in the world (anywhere in it, loaded
  or not), never while the game is closed.
- The player tramples a plot only by LANDING on it from 3+ bricks.
- Tilled soil is a real terrain material (smooth, furrowed by the shader).
- Crop death: deferred (maybe never). Ripe crops wait.
- Crops will be for selling, health, hunger, crafting -- later; growing only
  for now.
- Real animals only (creatures chat's pigs/zombies eat and trample crops);
  farming rolls no animal events (23).
- Farm trouble is a per-world switch (M > Game mode).

## 3. How it works (the one idea to keep)

**Nothing is ticked.** A plot keeps the world time it was last settled to
(`t`). `FarmPlant.settle(plot, now)` walks from `t` to `now` in steps -- to
the next of: a can's water running out (`wet_until`), a grow mix's boost
running out (`boost_until`), the stage's end (solved by bisection on the
closed-form daylight integral), the next random event (accumulated hazard vs
an exponential draw from the plot's seed), or now. Conditions (wet, sky,
lamp, scared, mono, companion, traits) are CACHED on the plot by
`MineFarming.refresh` while it is in reach and are constant while it is out
of reach, so the catch-up is exact: once == often == saved half way (the
probe checks it with every feature on). A plot out of reach is never
touched; it catches up when the player comes back.

Rule for anything new: if it changes how a plot grows, either make it part
of `settle` (pure, from plot data and its seed) or a cached flag set after
settling the plot first. Anything that needs other plots or chests at that
moment (crossing, giants, the collector) is near-only and says so.

## 4. Files

| File | What |
|---|---|
| `scripts/farming/farm_plant.gd` | FarmPlant: plot data, settle, rates, events, harvest, rows (38 fields) |
| `scripts/farming/farm_crops.gd` | FarmCrops: crop table from `content/<pack>/data/farming/*.json` |
| `scripts/farming/farm_store.gd` | FarmStore: plots by 256-stud region, `.farm` files, `version` |
| `scripts/farming/farm_fields.gd` | FarmFields: plots grouped into fields, one-crop (blight) |
| `scripts/farming/farm_draw.gd` | FarmDraw: crop models, giants, far patches, sky-lit material |
| `scripts/farming/mine_farming.gd` | MineFarming: the mine world's -- till, plant, harvest, areas, refresh, sprinklers, collectors, look line |
| `scripts/farming/farm_guide.gd` | the inventory's Farming tab |
| `scripts/farming/farm_gate.gd` | `--gate=farm` (preloaded by mine_world.gd) |
| `tools/probes/farm_probe.gd` | headless probe |
| `content/base/data/farming/crops.json`, `data/items/farming.json`, `data/recipes/farming.json` | data |
| hooks elsewhere | mine_world.gd (`world_time`, save/load, farm label, trouble switch), mine_builder.gd (RMB/LMB, drags), item_catalog/icons, terrain_trees.gd (`plant_tree`, `planted`), brick_terrain.h (MAT_FARMLAND 39/40), terrain.gdshader (furrows), brick_fluid (`any_fluid`) |

Other chats call into farming: creatures (`animal_eat`, `creature_landed`,
`crops_near`); inventory changed the tool recipes to iron ingots (smelting).

## 5. Testing, and what bit us

- `--headless --path . --script res://tools/probes/farm_probe.gd` (140).
- `--path . scenes/terrain_test.tscn -- --gate=farm` (73, windowed; copy
  `tools/test_window.cfg` to `override.cfg` in the worktree; launch from Bash;
  wait until the heat log says < 85 C; say the peak after).
- Parse-check mine_world.gd through a copy with MenuManager stubbed (it does
  not load headless otherwise).
- The gate's earlier sections run with trouble OFF so they are certain.
- Kit: a fresh creative kit with every seed filled the bags and harvests fell
  on the ground -- the kit has only hoe/scythe/can/wheat seeds/compost; the
  gate takes the rest with `_hold` (picks from Creative).
- Gate variable names are one function scope: new sections must not reuse
  names (`tb`, `c0`, `kinds`, `replanted` clashed).
- The "away" check must wait until `_near` drops the plot (rebuilt once a
  second) before moving the clock.
- Placed things (scarecrows, sprinklers, collectors) are gathered once a
  frame AND on a count change -- count-only missed a swap.
- Timings in gates are only indicative: other chats' runs and low RAM
  (paging) make 10-300 ms spikes that are not the game's.
- Bash heredocs halve backslashes: write Python patch files with Write;
  keep CRLF (`newline=""`).

## 6. Research

### Minecraft (vanilla)
- Crops grow by random ticks, only in loaded chunks; farmland wet within 4
  blocks of water; bone meal; trampling by jumping. (Farming here does
  better: exact catch-up anywhere in the world.)
- Farmer villagers claim a composter, harvest ripe crops near it and replant
  -- but only if they carry something to replant; a full inventory stalls
  them; they fill the composter and bone-meal crops. Mods (Villager Farm,
  Smarter Farmers) make them replant the same crop at once.
  ([Villager Farm](https://modrinth.com/mod/villagerfarm),
  [Smarter Farmers](https://www.curseforge.com/minecraft/mc-mods/smarter-farmers-farmers-replant),
  [Mojang bug MC-146429](https://bugs.mojang.com/browse/MC-146429))
- Apples drop from oak leaves as they decay; cocoa grows on jungle logs;
  sweet berry bushes regrow.

### Minecraft mods
- **Pam's HarvestCraft 2 - Trees**: fruit and nuts grow on the trees and are
  picked right from the leaves
  ([wiki-mine](https://www.wiki-mine.com/mods/pams-harvestcraft-2-trees-new-types-of-trees),
  [CurseForge](https://www.curseforge.com/minecraft/mc-mods/pams-harvestcraft-2-trees/files/3281234)).
- **Dynamic Trees (+ Pam's)**: a tree needs a thick enough trunk before it
  fruits; fruit blocks appear over time, right-click a ripe one to collect,
  it grows back; bone meal does not make fruit
  ([CurseForge](https://www.curseforge.com/minecraft/mc-mods/dtphc)).
- **Actually Harvest / right-click harvest** mods: harvest and replant in one
  click ([CurseForge](https://www.curseforge.com/minecraft/mc-mods/actually-harvest)).
- Known without a source this round: AgriCraft (seed stats, crossbreeding --
  farming has this), Farmer's Delight (rich soil, crops on ropes), Create
  (mechanical harvesters on contraptions), MineColonies (a farmer citizen
  works fields, keeps the harvest in his hut), Serene Seasons.

### Other games
- **Stardew Valley Junimo Hut**: harvests crops in a 17 x 17 area round its
  door into the hut; skips forage crops, garden pots and trees; not in rain or
  winter. Replanting from seeds and a chest beside it are MODS (Greenhouse
  Gatherers' Harvest Statue replants if it holds matching seeds; Better
  Junimos plants and fertilises)
  ([wiki](https://stardewvalleywiki.com:443/Junimo_Hut),
  [Greenhouse Gatherers](https://www.curseforge.com/stardewvalley/mods/greenhouse-gatherers)).
  Stardew fruit trees: take weeks to mature, then fruit daily in season.
- **Animal Crossing**: shake a fruit tree, the fruit drops; it regrows in
  about 2-3 days (native fruit), 3-6 days for foreign fruit; shaking does no
  harm ([Gamepur](https://gamepur.com/guides/when-does-fruit-respawn-animal-crossing-new-horizons)).
- **Terraria**: shaking a tree drops fruit by chance (per-tree tables)
  ([wiki](https://terraria.wiki.gg/wiki/Trees/Shaking)).
- From the first research round (MineFarming.md 2): Vintage Story
  (nutrients, rotation), Don't Starve Together (stress, giants), Valheim,
  RimWorld (growing zones, blight), Oxygen Not Included (wilt), Factorio
  Gleba (agricultural towers plant and harvest in a radius, output to
  inserters), Hytale.

### What to take
- Fruit on the tree, picked by hitting it; it regrows (Pam's, Animal
  Crossing); a tree fruits only once grown (Dynamic Trees).
- An auto farmer works an AREA, replants from seeds, stores in a chest
  beside it, and stops when the chest is full (Junimo Hut + its mods,
  villager farmers).
- Do better than all of them: the auto farmer's harvest and replant are part
  of the exact catch-up, so a fenced farm keeps working while its ground is
  unloaded.

## 7. Next round, designed (not built)

### 7.1 Fruit trees
- New crops (crops.json): apple tree, cherry tree, orange tree, lemon tree
  (more later: plum, peach, coconut, nuts), each tied to a tree variant for
  its canopy look (`tree`), planted from a sapling on plain soil like the
  saplings (`ground: "soil"`). New field `fruit_at`: the stage where the
  real tree stands (e.g. 0-3 sapling, 4 bare tree, 5 fruit growing, 6 ripe),
  `regrow_to` = `fruit_at` (perennial: picked, the tree stays and fruits
  again, about a day a cycle).
- Unlike the timber saplings (17) the plot is KEPT when the tree stands:
  `MineFarming` calls `host.plant_tree` once the stage reaches `fruit_at`
  (near-only, like saplings) and sets `plot.ground = "tree"`; `settle`
  keeps growing the fruit cycle exactly while away.
- Fruit is drawn in the leaves: FarmDraw puts small round fruit bricks on the
  canopy boxes (`Trees.boxes(variant)` + `Trees.placement`), seeded points,
  green and small while growing, the fruit's colour when ripe.
- Hitting the trunk or the leaves (LMB; the tree ray already covers both)
  with ripe fruit SHAKES it: `FarmPlant.harvest`, the fruit falls as dropped
  items round the canopy, the tree stays (hook in MineBuilder `_fell` before
  felling). With no ripe fruit LMB fells it as today: the plot goes, wood and
  leaves as any tree, and its sapling.
- Getting saplings: Creative; in survival a small chance when felling an
  ordinary tree of that variant, and always one when felling a fruit tree.
- Traits apply (yield trait = more fruit); the collector and auto farmer may
  pick fruit trees (allow `fruit_at` crops in their "not a tree" checks).

### 7.2 More bushes
- Blueberry bush (blue), grape vine (purple; later on a trellis), raspberry
  -- regrowing bushes like the berry bush (shape `bush`), produce planted as
  it is. Hitting a ripe bush already harvests it.

### 7.3 The auto farmer
- An item (station, its own model, e.g. a small brick robot or a farmer
  figure), placed in a field. It tends the plots in ITS FENCED AREA: a flood
  over walkable stud columns from its block (a step allowed within one brick
  up or down with room over it -- the stage 5 flood, in git history before
  be834d76: `FarmFields.flood_open` / `top_from`), stopped by fences, walls
  and drops, capped at a reach (about 12 plots each way). Plots whose columns
  the flood reaches are tended: `plot.auto = true`, `plot.auto_by = <its key>`
  -- cached flags, set after settling the plot, worked out again (on a
  WorkerThreadPool job, never waited on) when the farmer is placed or
  removed, plots come or go, or the ground near it changes.
- **While away, inside `settle`:** when an auto plot's crop becomes ripe at
  time t, settle harvests it AT t (pure: the same rolls as `harvest`), adds
  what it gives to the plot's own output list (`auto_out`: [[item, count,
  data], ...] merged by item and data), keeps one seed back from that harvest
  (its own seeds, or one produce for crops planted as they are) and replants
  at t with that seed's traits, then carries on growing -- several cycles if
  the player was gone long. Perennials (bushes, fruit trees) just go back to
  their regrow stage. Weeds never come up on auto plots (the farmer pulls
  them: weeds hazard 0). Still exact: once == often == saved half way, so it
  goes in the probe's exactness checks.
- **In reach:** `auto_out` is moved into the chests within ~8 m of the farmer
  (`MineFarming._put_in`); what does not fit stays on the plot (nothing is
  lost; a full chest just holds it back -- like a full Junimo hut or villager).
  Bare tilled plots in its area are planted from seeds in those chests; plots
  under 40 fertility get compost from them.
- Rows grow by `auto`, `auto_by`, `auto_out` (old rows load without).
- Collector (21) stays: simpler, near-only, no fence needed.
- Tests: probe -- exact with auto harvest (several cycles), auto_out carries
  traits, seeds kept back, perennial, no weeds on auto plots. Gate -- a
  farmer inside a stone ring tends the plots inside and not those outside; a
  chest beside it; the player flies away, three days pass, nothing is
  settled while away; back again the plots have harvested and replanted
  (exact against one settle), the chest holds the harvest; a full chest
  leaves the rest on the plots.

### 7.4 Still set aside
Crop uses (selling, health, hunger, crafting), crop death, a walking
farmhand (needs creatures), frost and fire, per-trouble switches, seasons,
multiplayer sync.
