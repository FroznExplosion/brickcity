# Mine world creatures: animals, enemies, pathfinding (plan)

A plan, written 2026-11-26. Nothing here is built yet. The scene is
`scenes/terrain_test.tscn` (Docs/MineWorld.md); farming is Docs/MineFarming.md.

## 0. What is asked

- Animals, enemies and pathfinding in the mine world.
- **To start: a zombie that pathfinds to the player.** A zombie is 2 studs
  across and 4 bricks tall.
- Pathfinding only needs to look at cells big enough for the body to fit
  through.
- Enemies and animals **trample crops**; animals **eat crops** when a farm is
  not properly closed in (fences are not in the game yet).
- Animals should feel like **hunting**, not like Minecraft: in Minecraft an
  animal does nothing until you hit it. Here animals live **in packs and
  herds** that notice you, watch you and run off together.

## 1. What already exists

| Part | Where | Use for the mine world |
|---|---|---|
| `Pawn`: 2x2 studs (0.525 m), `BODY_HEIGHT` 4 bricks = 12 plates, steps up one brick, health, intents, gravity | `scripts/pawn/pawn.gd` | **The zombie's body is exactly a Pawn.** Spawn one, drive its `intents` |
| `AINav`: A* over stud columns and plate floors, 2x2 footprint, 12 plates of headroom (9 crouched), step up 3 plates, a flow field (`request_field`, `field_dir`), request queue with a budget, HPA | `gdextension/brick/src/ai/ai_nav.*` | The design to copy. **It cannot read the mine world as it stands** (see below) |
| `AIWorld` with `set_terrain_ground(true)` | `ai_world.*` | Sees terrain as a **heightfield**: everything under the top is solid, columns count plates up from y = 0. The mine world has caves, overhangs, player builds inside the field (buildings are ground, Docs/TerrainBuildings.md) and goes down to -126 m. Every cave is a wall to it |
| `Animal`, `AnimalPack`: GRAZE / FLEE (on noise) / HUNT (encircle, then close in and bite) | `scripts/ai/animal*.gd` | Behaviour to port: the pack decides, the members take their places |
| `AIServices`: scheduler, tiers (`AgentTier`), noise and contacts (`FactionKnowledge`) | `scripts/ai/` | The mine world already makes one (`mine_world.gd` ~708) for grenades |
| `ProcCreature`, `CreatureDNA`, gait, LOD | `scripts/creatures/` | Animal looks: legs that walk with the body's speed |
| `FarmFields.top_from` / `flood_open`: a walk over `BrickTerrain.solid_at` (step 3 plates, 2 plates of room) | `scripts/farming/farm_fields.gd` | Same walk rule as the nav; it should become the nav's question later (section 6.3) |
| Animal trouble as an abstract rate (0.25 a plot a day, eat back 2 stages / trample) | `FarmPlant`, MineFarming.md 18 | Stays for farms far away; real animals take over near the player |
| `MineFarming.trample(plot)`, `landed()` | `scripts/farming/mine_farming.gd` | The hook a creature's feet call |
| `MineWorld.terrain_edited(res)` | `mine_world.gd` ~1045 | Where the nav is told which box changed |
| `BrickTerrain.sky_light_at`, `block_light_at` | `brick_terrain.h` | Dark enough to spawn |

Missing: the player cannot die in the mine world (no death or respawn), there
are no creatures there at all, and no fences.

## 2. Pathfinding: `TerrainNav`

### 2.1 Why a new class

AINav's columns start at plate 0 and read AIWorld, which treats the ground as
solid all the way down. Teaching AINav a second source would change the city's
and the planets' navigation (another area's code, and their gates). The mine
world needs something smaller: the terrain field only, read volumetrically.
So: a new C++ class `TerrainNav` next to AINav (`gdextension/brick/src/ai/`),
copying its ideas (stud columns, plate floors, A* in C++, the request queue,
the flow field) and reading `g_field.solid_at(x, yp, z)` directly, with plate
y anywhere (negative too).

C++ because the reads are many: a column is checked plate by plate, and a few
dozen creatures plus a flow field is hundreds of thousands of reads. The farm
flood does this in GDScript on a worker and gets away with it only because it
runs once per field every 1.5 s.

### 2.2 Only cells a body fits in (the user's idea)

Per stud column, the nav keeps a short list of **floors**: a plate with solid
under it and air over it. For each floor it stores two small numbers:

- **headroom**: plates of air over it (capped at 16);
- **width**: the biggest square of columns, with this one at a corner, whose
  floors are all within a step of this one and all have that headroom
  (capped at 4 studs). A distance-transform pass, like a clearance map.

A body of W studs and H plates only ever looks at floors where
`width >= W and headroom >= H`. Everything else is not in its graph at all.
So one map serves every body: a zombie (2 x 12), a wolf (2 x 6), a deer
(2 x 11), a rabbit (1 x 3), a cow or a boar (3 x 9). A 1-stud gap or a
tunnel 11 plates high simply does not exist for a zombie.

Floors are worked out **lazily, by blocks of 16 x 16 columns**, on first ask,
and kept. A terrain edit forgets only the blocks its box touches (plus one
column round for the width pass).

### 2.3 Moves

Eight neighbours; a diagonal only when both straight neighbours are open
(no cutting corners through a 1-stud crack). Per body:

| Move | Zombie | Notes |
|---|---|---|
| step up | 3 plates (one brick) | the Pawn's `STEP_HEIGHT` |
| jump up | 0 | **a wall two bricks high keeps zombies out**, as in Minecraft, and gives building a point. Deer will jump far more (section 5) |
| drop down | 9 plates free, up to 19 with a cost | a fall past `SAFE_FALL` hurts |
| water | allowed, 3x cost | `BrickFluid`; a swimmer crosses, a zombie wades |
| lava | never | |
| closed door | a wall | wiring doors (MineWiring.md) |

### 2.4 One path or one field

- **A path** (A*, bounded node count) for one creature going somewhere: an
  animal to its grazing spot, a deer to its escape point.
- **A flow field** for everything chasing the player: one Dijkstra out from the
  player's floor to ~48 m, per body class in use. Every zombie in it reads the
  direction at its own floor: the cost is one per player, not one per zombie.
  Built again when the player has moved 2 studs to a new floor or an edit
  lands inside it, at most a few times a second.
- Both run on a worker. Asking returns at once; the result is taken when it is
  done (`is_task_completed`, never a wait: CLAUDE.md, Docs/WhereWorkRuns.md).
- **No way to the player** (sealed in a base): the zombie goes to the
  reachable floor closest to the player and stays there, which is the
  Minecraft "zombies at the wall at night" picture. Breaking blocks is later
  (stage 11).
- Steering on top: keep apart from other creatures (a little push from
  neighbours), jump when stuck against a 1-brick step, ask again when stuck
  2 s.

### 2.5 Near, far, asleep

The terrain has colliders only where the detail tier is. So:

- **Near** (within the detail tier, ~40 m): a Pawn with physics, walking.
- **Far** (out to the sim ring): no body; the creature slides along its path
  or field from floor to floor at its speed, on the CPU, no physics. Becomes a
  Pawn again when it comes near. `AgentTier` already does this split for
  soldiers.
- **Asleep** (unloaded): animals' herds are saved (where, how many, what);
  hostile monsters are not, they go (as in Minecraft).

Positions move with the origin shift (MineWorld.md 15).

## 3. The zombie (the first thing built)

- **Body**: a Pawn, team "monsters". Look: a brick figure built 2 x 2 studs x
  4 bricks (green head, torn shirt), arms forward; a few seeds for variety.
  First a greybox capsule so the AI can be tested before the look is done.
- **Senses**: sees the player within 24 m (a ray over the field, not through
  ground), hears shots, blasts and breaking within 32 m (AIServices noise),
  and smells the player within 8 m round corners (cheap, makes them feel like
  they know). Lost the player: goes to where it was last known, then wanders.
- **Moves**: walk 2.6 m/s wandering, 3.6 m/s chasing (the player sprints
  faster). Groups follow the same field, so they come as a crowd.
- **Hits**: melee at 1.4 m, 4 damage every 1 s, a small knock back (the
  `Animal` bite, slower).
- **Dies**: health 40; shots break into it the way a shot breaks ground;
  falls apart in bricks.
- **Crops**: walking over a planted plot tramples it 1 time in 4
  (`MineFarming.trample`), the same rule as the abstract trample.
- **Spawns** (stage 4): in the dark (sky light and block light both low),
  on a floor a zombie fits, 24-64 m from the player, out of sight, capped
  (say 12 near). Goes at day in the open (burns, or just walks off and
  despawns: a question, section 8).

## 4. Enemies later

The same body and nav serve more: a spider (wide, short, climbs walls: a
"climb" move), a skeleton-like archer (keeps distance, needs line of sight),
something that digs. Each one a row in a table, not new code.

## 5. Animals: herds and packs that feel like hunting

### 5.1 The herd notices you

Every herd has an **alert** level, one for the whole herd, with each member's
own look on top:

| Level | What you see | Goes up when | Goes down when |
|---|---|---|---|
| CALM | grazing, heads down, wandering slowly | | nothing seen for 20 s |
| WARY | heads up, ears turned, all freeze and **look at you**; one may step away | you are noticed (below) | you stay still or out of sight |
| ALARM | a call, tails up, they bunch and start to move off | you come closer while noticed, or move fast | |
| FLEE | the herd bolts **together**, the leader picks the way (away from you, toward cover or downhill), then slows and settles far off | a shot, a hit, you sprint at them, a herd member dies | after 30-60 s, far away |

**Noticed** is a score that fills over time, not a yes/no:

- distance (it fills faster close by);
- seen: in the herd's view and not behind ground or leaves; crouching cuts it,
  standing still cuts it a lot, sprinting doubles it;
- light: at night or in shade they see less;
- **scent**: a world wind (one direction that turns slowly); upwind of a herd
  it smells you from far further. Come at them from downwind;
- noise: footsteps when sprinting, breaking blocks, shots (a shot within
  60 m: straight to FLEE).

A **lookout**: one member at a time stands with its head up while the others
graze, and it notices better. Shoot the lookout and the herd is blind for a
moment; miss and they all go.

So hunting is: find a herd, work round downwind, crouch, close the distance
while they are not looking, and get one shot. The deer that is hit and not
killed runs with the herd and can be followed.

### 5.2 Species to start with

| Animal | Group | Body (W x H) | Does | Gives |
|---|---|---|---|---|
| deer | herd 3-8 | 2 x 11 | the hunting animal above; jumps 2 bricks | meat, hide |
| rabbit | 1-3 | 1 x 3 | zigzags off, hides in holes a zombie cannot follow | small meat |
| boar | 2-5 | 3 x 8 | flees, but **turns and charges** when hurt or cornered | meat |
| wolf | pack 3-6 | 2 x 7 | the predator: hunts deer herds and, at night or when you are hurt, you | hide |

Wolves are `AnimalPack.HUNT` ported: they stalk a target, spread round it,
close in together. A pack that loses half its members breaks and runs.
Wolves hunting deer near you is something you can watch, and steal from.

Looks: procedural creatures (`ProcCreature`, a DNA per species with a little
variety), in brick colours.

### 5.3 Farms

- A herbivore herd that is CALM has a **graze target**: grass, or better, a
  crop it likes within ~40 m (deer: carrots, beans; boar: potatoes; rabbits:
  everything). A crop is the strongest pull.
- If the nav finds a way to the plot for that animal's body and moves, they go
  and **eat**: back 2 stages a bite, as the abstract event does. Walking over
  plots **tramples** them 1 in 4. Wolves and zombies only trample.
- **Closed in** therefore means "no path for that animal", and the same
  question answers both: a two-brick wall keeps out boars, rabbits and
  zombies but **not deer** (they jump 2 bricks). Fences (stage 10) are made
  to be just too high for a deer.
- `FarmFields`' open/closed flood is per animal then: it becomes the
  TerrainNav's question (is there a way in from 24 studs out, for this body)
  and the plot's HUD can say *"open to deer"*.
- Near the player (within the sim ring) real animals replace the abstract
  animal trouble for that field; far away the abstract rate stays, scaled by
  how many herds live in that biome. Same as MineFarming.md 9 planned.

### 5.4 Later: livestock

Taming, breeding, pens, feeding animals from the farm, milk and wool: the
farming side's next part, once fences exist. Not planned in detail here.

## 6. Shared pieces

### 6.1 Player health and death in the mine world

Zombies need it. Survival only: health (the Pawn's) shown on the HUD,
regenerates slowly when fed later, on death a respawn at the world spawn or
a bed. What is dropped on death is a question (section 8). Creative: no
damage.

### 6.2 Spawning and the population

A `MineCreatures` node in the mine world owns every creature: spawn rules per
species (biome, light, time of day, distance), caps near and far, herds placed
when terrain sections first generate (from the world seed, so the same herds
are in the same place), saved herds per region, despawning. The F3 readout
shows the counts and the nav's numbers.

### 6.3 One walk rule

`FarmFields.top_from` (step 3 plates, room 2 plates) and the nav's moves should
end as one rule, so a field the HUD calls closed is closed to the animals that
then try. Done in stage 9, not before.

## 7. Stages

| # | Stage | Ends with |
|---|---|---|
| 1 | **TerrainNav**: floors by 16x16 blocks, headroom and width, A*, flow field, worker jobs, edit invalidation | `terrain_nav_probe` (headless): a 2-stud gap passes a zombie, a 1-stud gap does not; an 11-plate tunnel is shut to it, a 12 is open; a way through a cave below the surface; a wall one brick high is stepped, two is not; an edit opens and closes a way; a field points every floor at the goal |
| 2 | **Zombie v1**: greybox Pawn, a dev key to spawn one, chases the player on the flow field, melee hit, dies to shots | `--gate=zombie`: spawned 30 m off behind a hill it reaches the player; it goes round a 2-brick wall through the gap; sealed in, it waits at the nearest floor; tramples a plot |
| 3 | **Player health, death, respawn** (survival) | gate: a zombie's hits take health; death respawns |
| 4 | **Night spawns**, caps, despawn, day rule; the brick zombie look | gate: night in the open spawns them, a lit room does not |
| 5 | **Far tier**: creatures beyond the colliders ride the nav; tiers swap; origin shift | gate: a crowd 60 m off arrives through the tier swap with no jumps; frame cost of 30 zombies measured |
| 6 | **Deer herd** with alert levels, lookout, scent and wind, flee together; hunting drops | `--gate=herd`: crouched downwind gets closer than standing upwind; a shot sends the herd off together; they settle far away |
| 7 | **Rabbits and boar** (holes, charging) | gate |
| 8 | **Wolves**: pack hunts deer and the player | gate: a pack takes a deer; the pack breaks at half |
| 9 | **Animals and farms**: graze targets, eating, trampling, per-animal open/closed, abstract trouble only far | farm gate: a deer herd eats an open field; a 2-brick wall stops boar not deer |
| 10 | **Fences and gates** (build mode block: posts that join, rails; too high to jump, see-through) | gate: a fenced field is closed to every animal |
| 11 | Later: zombies that break blocks or pile up, more enemies, livestock | |

Stages 1-2 are the start the user asked for. Each stage is merged when its
probe or gate passes.

## 8. Questions for the user

1. **Daylight**: do zombies burn in the sun (Minecraft), hide in shade, or just
   go?
2. **Death**: what does the player lose on death in survival (everything
   dropped where you died, nothing, or only the hotbar)?
3. **Zombie walls**: is "two bricks high keeps them out" right for now, or
   should they climb over each other or break blocks early?
4. **Scent and wind**: worth it (it needs a world wind that the HUD can show,
   e.g. drifting leaves or a small arrow)?
5. **Looks**: brick figures for zombies and procedural creatures for animals,
   or brick-built animals too (build them in the asset workshop)?
6. **Fence height**: just too high for a deer (more than 2 bricks), or should
   deer jump them and only walls stop deer?
