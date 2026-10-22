# Space: asteroids, ships, stations, and bricks only where it broke

Status (2026-10-21): **design; §5's storey units built for generated towers (§5.3b).** Written at the user's request with
[Planets.md](Planets.md) (real sphere planets). It answers four questions: how small a smooth
asteroid can be; whether ships and stations the size of the city's buildings can be destructible;
whether a section can stay whole until it breaks and only then become bricks without a hitch; and
whether only the storeys or rooms that were hit can become bricks while the rest stays intact.

Numbers marked *measured* come from this repo's docs (where cited); the rest are **estimates**
scaled from them, to be replaced by a gate on a quiet machine.

Prior art read for it: STA (`C:\Users\lbaun\Documents\sta`) and zylanntest
(`C:\Users\lbaun\Documents\zylanntest`) -- §6.

---

## 1. Asteroids: how small can smooth ground be?

**No lower limit.** The ~8-10 km in Planets.md §10a is not a limit on smooth ground; it is the
size above which the game can run its fights in a **flat bubble** (gravity straight down, `AINav`'s
flat columns, every `Vector3.UP` as it is) and nobody notices the curve. Below it the ground works
exactly the same; what changes is that the code walking on it must know it is on a ball:

| body | what the player walks with | AI on foot | buildings on it |
|---|---|---|---|
| **≥ 8-10 km radius** | today's controllers in a flat bubble (Planets §10a) | today's `AINav` in the bubble | rigid, on pads |
| **~300 m - 8 km** | STA's radial gravity controller (STA doc 05: rebuild the whole basis from radial up each frame; `up_direction` set every frame) | needs per-chunk charts (Planets §7) or no ground AI | rigid with a gravity zone (Planets §4.1) |
| **~20-300 m** (a moon-let, a big rock) | radial controller; the curve is strong (walk 30 m on a 200 m radius: 8.6° of turn) | flyers, turrets, crawlers that stick to the surface -- not `AINav` | small ones, each with its own gravity zone |
| **under ~20 m** | not walked on as a world: a brick build or a rigid prop | -- | -- |

How the smooth ground is made, by size:

| | indestructible | carvable |
|---|---|---|
| **large, near-round** | cubed-sphere heightmap chunks, baked (Planets §3.2) | the same with scorch decals; no digging |
| **potato / any shape** | a mesh baked once from a distance field (our `SdfForm` meshes surfaces already; STA doc 25: potatoes and ovals cost nothing extra) | Zylann's voxel terrain as STA uses it (its most expensive system: re-meshing, edit storage) |

Gravity is a game choice, not physics: a real 200 m rock has almost none. Pick per body.

### 1.1 Bricks or smooth, by size (estimates)

A solid sphere of bricks grows with volume (a 2x4 brick is ~0.41 m³); a hollow shell two bricks
thick grows with surface:

| diameter | solid bricks | shell of bricks | verdict |
|---|---|---|---|
| 5 m | ~160 | -- | bricks: a shootable rock, cover |
| 10 m | ~1,300 | -- | bricks (a small building's worth) |
| 20 m | ~10,000 | ~2,500 | bricks only as a shell; or smooth |
| 30 m | ~34,000 | ~10,000 | smooth, with brick patches |
| 100 m | ~1.3 M | ~100,000 | smooth only |

**Recommendation:** under ~15-20 m, all bricks (made in the asset workshop: sculpt the SDF,
Convert); 20-80 m, smooth with **brick patches** -- ore veins, wrecks, outposts on their own little
grids, as Planets §3.1 puts patches on planets; landable rocks and moons, smooth ground. Rings and
belts use STA's three tiers (STA doc 15 §3.2): a shader disc far, instanced rocks approaching,
only the nearest few dozen promoted to real bodies inside.

---

## 2. What a building costs now -- the starting point

*Measured* (sources in brackets):

| a building that is ... | costs | |
|---|---|---|
| registered, out of sight | no `BrickWorld` memory; 5000 registered in 19 ms | Status.md |
| far, 260 m - 3 km | one instance of one MultiMesh, ~12 triangles; the whole far city one draw call | Impostors.md stage 1 |
| 110-260 m | a box (~10 triangles) + 5 collision boxes | Impostors.md |
| under 110 m, intact or hit | banded shell: ~3.7k triangles, 2 draw calls | Impostors.md §7.1 |
| **in bricks** | 756 blocks: 4.8 ms to build, ~4 MB; a 16,600-block tower: 10 MB of blocks, 111 MB of baked mesh | Status.md |
| dormant wreckage | 17 bytes a block (3,461 blocks: 7.7 MB -> 57.5 KB) | Status.md |

Two figures say where the money goes once bricks exist (CollapseNext.md, DestructionLod §5.4): a
merged collision rebuild of a 15,099-brick piece took 22.5 ms; one landing's re-solve of 12,315
bricks 38.4 ms; 200 buildings under fire peaked at 457.5 MB with 183 resident.

**So intact really is cheap -- by three to four orders of magnitude.** The cost is bricks, and
today the unit that becomes bricks is the **whole building**: the first hit runs
`BuildingRegistry.materialise`, which lays every brick of it and replays its damage record
(drawing and collision are already per band; the bricks are not). That is Next.md 2.5, "sections,
not buildings, as the unit of materialisation", not built.

---

## 3. Ships and stations

### 3.1 Size against bricks (estimates)

Hulls are hollow with decks, like buildings, so bricks grow with surface. From the 150 m tower
(16,600 blocks) and ~6 µs a brick to build, ~7 KB of baked mesh a brick:

| thing | size | bricks | all of it in bricks at once |
|---|---|---|---|
| fighter | 15-40 m | 1-5k | 5-30 ms, 5-35 MB: fine |
| station, building-sized | 30-150 m | 3-25k | as today's buildings |
| frigate | 60-100 m | 5-15k | 40-100 ms, 35-100 MB |
| capital ship | 300-500 m | 70-200k | 0.4-1.2 s, 0.5-1.3 GB: **never all at once** |
| huge station | 1 km+ | 700k+ | a district of building-sized sections |

### 3.2 A ship is sections; a section is whole until it breaks

The user's model (2026-10-21): a large ship or station is **a few sections**, each about the size
of an ordinary city building (not the big-city towers) -- ~5-15k bricks. Nothing is brick by
brick until the **final break** of a section; then that section becomes bricks and fractures.

| state of a section | drawn by | collision | cost |
|---|---|---|---|
| **whole** (hit or not) | its shell; hits show as scorch and holes in the shell (`damage_profile`, as recipe buildings show band damage) | a few boxes on the ship's one rigid body | a building's shell |
| **broken off** (its joints to the ship are gone) | the same shell, now its own rigid body, drifting with the ship's momentum | its boxes | the same |
| **final break** (its hit points gone, or it struck something hard) | bricks, near the player; big rigid shell pieces far away | merged boxes per band | bricks, under the budget of §5 |

- **Hit points** per section and per **joint** (the spars and frames between sections). A joint
  at zero lets its section go: the section leaves as a rigid shell body -- no bricks. This is the
  Fortnite-style cascade STA doc 17 §5 describes: a ship's support anchors to its **root set**
  (the bridge, a core module), and what is cut off from the root leaves.
- **Space makes the bricks cheaper than on the ground.** With no gravity there is no weight: no
  stress solve, no landing breaks, no settling. A brick falls only when nothing connects it (the
  attachment rule, unchanged) -- connectivity only. Inside a ship with artificial gravity the
  solve runs as on the ground, within that ship's gravity zone.
- **Fighters** are one unit: their baked shell (from the converter, as the guns are) and hit
  points until they die; then bricks, or straight to the fragment caps of §4 far away.
- **Moving** is new work buildings never needed: the ship is one rigid body carrying its sections'
  boxes (zylanntest `game/ship`: a `RigidBody3D` with per-chunk shapes; Jolt takes the compound
  body); the player inside rides the ship's frame (STA doc 17 §4, doc 12's frame handoff); bricks
  of a ship live in the ship's own frame, as a building's live in `b.xform`.

### 3.3 The final break without a hitch

The risk is the moment a whole section turns into bricks: built in one tick, 10k bricks is
~60 ms -- a visible stall. Four things make it free to the eye, three of which exist:

1. **Templates** (exist: `BrickWorld.save_template` / `load_template`): a section's blocks copied
   in, ids and joints and all, instead of laid one by one ("building the biggest block by block
   was 26 ms of every promotion"). Per section kind, saved once.
2. **The shell keeps drawing until the bands are baked** (exists: a promotion keeps the far box or
   shell as a placeholder and `_bands_done` frees it). Bands bake on a worker (`bake_chunk_async`).
3. **Pre-warm** (new): when a section's hit points fall under ~30%, lay its bricks hidden, a band
   or two a tick; at the break it is a swap of what is shown.
4. **Do not make the whole section bricks at all** (new, and the better one): the final break
   splits the shell along its **storeys and rooms** (§5) into a handful of big rigid shell chunks.
   Only the chunks in the near ring, or hit again, become bricks. Far away, the chunks never do.

The flash, the dust and the debris of the explosion cover a frame or two either way.

---

## 4. Fragments: caps by size

The rule the city already runs (Scale.md §4.8, CollapseTier): small pieces are texture and are
deleted, large ones are landmarks and are kept as records. In space:

| piece | near (< 60 m) | mid (60-150 m) | far |
|---|---|---|---|
| a crumb, a single brick | particles, deleted quickly (as in a collapse today) | deleted where it comes loose | never made |
| small (under ~200 bricks) | flies, deleted after a few seconds or when the cap is full, oldest first | deleted | never made |
| large (a room, a deck, a section) | flies, collides, can be shot again | rigid, never fractures on contact | **a drift record** (below) |

**A drifting piece in space is analytic.** With nothing near and no gravity, where it is is
`p0 + v t` and how it is turned is `q0` spun by `ω t`. So a large piece far from everyone is the
dormant record the city already has (17 bytes a block) plus six numbers -- no body, no physics --
and comes back as a body when someone comes near, or is deleted when it leaves the play space. The
debris cap's eviction (small deleted first, large slept) needs no change; "slept" becomes "drift".

---

## 5. Bricks only where it was hit: storeys and rooms

The user (2026-10-21): cap the buildings in real bricks by a **budget**, not by distance alone,
and make the unit **rooms or floors**, not whole buildings: a damaged building or ship turns the
storeys or rooms that were hit into bricks; everywhere else stays intact.

**Yes, and most of it is parts that already exist.**

### 5.1 The unit: a storey band, then a room

- **Storey** first: the horizontal band between two floor slabs. The slabs are known -- the
  generator lays them (`TowerRecipe._lay_slab`), the floor finder finds them in a build
  (Structures §2.4). A storey is six brick courses and a slab (`TowerRecipe.STOREY_PLATES`), so
  the 22k-brick 80 x 60 tower (204 courses) has ~32 storeys of ~700 bricks; the 200 x 80 wide
  building ~2.2k a storey. On a ship, a storey is a **deck**.
- **Room** second, for wide buildings and long decks: the room record (`StructureSpaces`) gives
  each room's footprint. DestructionLod §5.4 found every tower room against an outer wall, which
  made rooms useless as a unit of *drawing interiors*; as a unit of *bricks* that does not matter.
- A hit makes bricks of the units its blast reaches -- usually one storey, the one above if a
  slab is cut. Everything else stays the shell.

### 5.2 How a part of a building stands as bricks while the rest is whole

| boundary | how the solver sees it | exists? |
|---|---|---|
| intact storeys **below** | the ground: cells at or below the band's bottom anchor it | `BrickWorld.set_foundation_level` -- yes |
| intact storeys **above** | their weight, resting on the band's top bricks (columns, walls) | `BrickWorld.set_load` -- yes (it carries settled wreckage today) |
| an intact **room beside** | an anchor: the wall cells it shares | new: anchor cells by list (a foundation by cells, not a level) |

The bricks of the band are laid from the recipe **for that band only**, with block ids that stay
the same whichever bands are laid (the damage record keys on them). The shell stops drawing that
band (shells are already drawn by band) and the band's bricks draw it instead.

When the band gives way -- the attachment rule: nothing connects what is above to what is below
-- the intact part **above** becomes **one rigid piece drawn by its own shell bands**, with its
boxes: a section breaking off, no bricks. It falls (or drifts). When it lands hard, or is hit
again, *its* lowest storey becomes bricks the same way, and fractures by the same rules. So a
tower comes down a storey of bricks at a time, and the parts nobody is near never become bricks.

What is new, in order:

1. **Recipes laid by band** with ids stable per band (`TowerRecipe` lays storeys already; a
   `BuildRecipe` is sliced by the floor finder's slabs).
2. **A shell piece**: a rigid body drawn by a run of a building's shell bands (today a piece is
   always bricks).
3. **Anchor cells** beside a materialised room (only for rooms; storeys need nothing new).
4. **Templates per band**, so a band is copied, not built.

### 5.3 The budget

Replace "materialised while near, given back after quiet" with **a budget of bricks in play**
(a setting, as Teardown ships its debris cap), counted in units:

- A unit becomes bricks when hit (or pre-warmed, §3.3). Over budget, the **quietest units
  furthest from every player** are given back first: their bricks dropped, their damage kept as
  the record (exists: `_demesh`, the damage record replays on the next materialise). A unit a
  player stands in, or that is moving, is never given back.
- Starting figure to measure against: the 200-building pass peaked at 457.5 MB with 183
  buildings resident. A budget of **~150k bricks** -- some 100-200 storeys -- is the first
  guess; the gate sets it.
- The city's distance rings (DestructionLod §2) stay as they are for *what pieces do*; the budget
  decides *how many bricks exist*.

### 5.3a Build plan (2026-10-21) -- storey units in the flat game

Taken up from §7 item 1 and Next.md 2.5. What the code does today, and what changes:

**Ids.** A block id is its index in the chunk's block list (`BrickWorld::place_block` appends),
and the damage record (`dead`, `gone`, `worn`, `scorched`) is lists of ids. So a storey cannot be
laid on its own by running the recipe for it: every id after it would move. Instead the **whole
building's template** (`BuildingRegistry._templates`, built for every shape at city layout) is the
id space, and a storey is laid *from the template*:

- `BrickWorld.create_band_chunk(template)` makes a chunk with the template's origin and dims and
  its full block list -- every block **absent**: in the list (so ids hold) but owning no cells,
  never drawn, solved, hit or counted. An absent block is marked `removed` (which every hot loop
  already skips) plus a per-chunk byte that says it is absent, not edited away.
- `BrickWorld.lay_band(chunk, template, y_lo, y_hi)` makes present every absent block whose cell
  y is in `[y_lo, y_hi)` -- copied from the template, cells written -- and returns how many. A
  storey is `[20 s, 20 s + 20)` plates (`TowerRecipe.STOREY_PLATES`: its slab, then six courses).
- **The record rides absent blocks.** `kill_blocks`, `set_worn_blocks`, `set_scorched_blocks`
  on an absent id write its record bits; `get_dead_blocks`, `get_detached_blocks`,
  `get_worn_blocks`, `get_scorched_blocks` report them. So the record round-trips through a
  partly laid building unchanged, and a storey laid later comes in with its damage (`lay_band`
  applies its bits as it makes it present).
- **Occupancy only where laid.** A chunk's dims stay the building's (so its sections -- the bands
  drawing and collision are cut into -- number as before), but its occupancy grid holds a
  **y-window**: the plates of what is laid. A cell outside it reads empty. The window grows when a
  storey outside it is laid (the grid is rebuilt from the present blocks; a storey is ~1 ms).

**Boundaries for the solver.**
- Below: each run of laid storeys is anchored at its bottom plate. `foundation_level` keeps the
  lowest; `BrickWorld.set_anchor_levels(chunk, ys)` adds the others (two storeys laid apart).
- Above: the weight of everything over a run's top (template mass, `get_template_mass`) rests on
  the run's top bricks (`get_blocks_topping(chunk, y)`: alive structure whose top face is at y)
  through `set_load` with owner `BuildingRegistry.ABOVE_OWNER - run` (wreckage loads use piece
  ids, which are >= 0).

**Registry.** `materialise(id, storeys := [])`: empty lays the whole building as today (every
probe and gate that promotes by hand keeps its meaning); a list lays those storeys from the
template. `lay_storeys(id, storeys)` lays more into a building already partly laid. `damage()`
lays the storeys a blast reaches first. `storeys_in(id, point, radius)` says which. A building
knows `storeys_laid` (empty = all). The damage profile of a partly laid building is the bricks'
for laid storeys and the kept profile for the rest (`live_damage_profile`, `dematerialise`).

**City.** A hit (`_apply_blast`), an aim (`_aim_promote`), a falling piece's path
(`_path_promote`) and a walk-up (`_stream_residency`) promote the storeys they reach, not the
building; a hit on storeys not yet laid lays them (`_lay_more`: lay, bake again, bands rebuilt --
the old ones drawn meanwhile -- and collision reshaped for the new sections). The storeys still
whole are drawn by the building's **rest shell** (`_rest_shells`): the recipe shell with laid
storeys' bands marked gone, with its collision boxes and AI proxies. It exists while the building
is partly laid, its bricks are drawn (`_brick_nodes`) and no stand-in shell is up (`_shells`);
`_rest_sync` keeps that true. `--whole` turns storey units off (the gate's "today").

**A storey gives way** when no brick of it is left under the storey above
(`get_blocks_topping` empty after the solve) -- or when what is left still carries it but off to
one side: the template's centre of mass over the run stands outside the plan (convex hull) of the
bricks topping it. The stress solve never fails that (what is left takes it in compression); laid
whole the building would have tipped (`check_stability`). Then everything above leaves as a **shell piece**
(`ShellPiece`): one rigid body drawn by the shell bands of those storeys, with their boxes, no
bricks. The building keeps `cut_storey`: those storeys are never laid in it again (their blocks
stay absent), its profile marks their bands gone and their rooms are written off. Laid storeys
above the gap leave as ordinary brick pieces. A tipping top leaves resting on the stump and goes
over its edge. When the shell piece lands hard -- a brick piece's own rule: speed lost over
`IslandManager.IMPACT_DELTA` after a fall -- where somebody could see it break (its box within
`FRACTURE_RANGE`, as a brick piece's landing), ALL of it is laid from the template into one brick
piece with every joint it had (`heal_joints`, as a collapse chunk), and the landing breaks it where
it touched (`fracture_on_impact`). Far from everyone it lands whole and stays a shell. Shot, it does
the same and the blast lands on the bricks. Undamaged storeys stay as stiff as LEGO: nothing comes
away a floor at a time. (The first build split off its lowest storey at every landing as a body of
its own, and a falling top came apart floor by floor -- user, 2026-10-21.)

**Templates per band** come free: `lay_band` copies blocks out of the template, so a storey is
never built.

**Builds** (`BuildRecipe`, one frame) are sliced at the floors the floor finder finds
(`floor_lines`, Structures §2.4): a template a recipe (`_build_template_of`: the build, then its
fixtures, as materialise lays them), and their rest shell and shell pieces drawn by `BuildShell`
with every block of the other storeys left out (`build_hidden`). A build of several frames is laid
whole.

**The brick budget** (§5.3) is `CityScene.brick_budget` (150k, `--brick-budget=`): over it, the
quietest storey furthest from everybody goes back to its rest shell, one a pass
(`_trim_budget`, `BrickWorld.unlay_band`: present blocks absent again, damage in the record bits,
the profile the shell draws taken first); a building laid whole goes back whole. Never a storey
within 20 m of somebody, or one laid or hit in the last 3 s. The distance trim (`_trim_quiet`)
runs as before; the budget is a ceiling over it.

**The log.** Which storeys are laid changes how a building's solves come out, so it is a command:
`LAY` (storeys laid), `UNLAY` (storeys given back, or none named: all), `GIVE_WAY` (a storey gave
way: the cut), `SHELL_BRICKS` (a shell piece became one brick piece at a transform, its id its seq).
`StructureReplayer` applies them through the caller's registry (`CityScene._storey_hooks`) -- the
twins of `_check_log_replays`, and a checkpoint load (`AreaSnapshot.restore`'s hooks).

Gate: `city.tscn -- --storeys --big` (new): the biggest tower shot at mid-height, first-hit time,
bricks laid and chunk memory, `--whole` against storey units; the part above falls as one shell
piece; the building given back and laid again replays its record (`storey_unit_probe` headless checks
ids and the record round trip).

### 5.3b What was built, and what it measured (2026-10-21)

Branch `claude/great-rhodes-077356`. All of §5.3a for generated towers; not builds, not rooms as
units, not the budget (§5.3).

`--storeys --big`, the 80 x 60 tower of 204 courses (24,522 bricks, 35 storeys) shot once at
mid-height, then the same with `--whole` (today). One run each, the editor closed, no other Godot
running, display awake; heat under 80 C throughout:

| first hit | `--whole` | storey units |
|---|---|---|
| promotion (laying, collision, bake start) | 30.4 ms; 9.7 ms after main's cheaper promotions (1b717e6) | 5.7 ms; 2.0 ms after |
| bricks laid | 24,522 | 1,443 (storeys 16-17) |
| occupancy grid | 12.6 MB | 0.77 MB |
| BrickWorld memory | +93 MB | +8.4 MB |
| process static memory | +103 MB | +11 MB |
| video memory | +35 MB | +4.3 MB |
| the shot shown (bands drawn) at tick | 28-29 | 7-9; 4 after |

Before main's cheaper promotions both had one 0.5-0.76 s frame some ticks after the shot, all of
it in `_process`, none in the physics tick, with `--whole` as with storey units. After merging them
(one palette snapshot shared by bakes) it is gone: the worst frame of the 90 ticks after the shot
is 37 ms in both modes, and not the shot's tick.

Then (storey units) storey 17 blown out with blasts all through it: the storeys over the last
laid one leave as **one shell piece** (storeys 20-34) at tick 67; the building is 5 laid storeys
(3,623 bricks -- the blasts and the wreckage landing reached 15-19); the piece lands hard and is
(since the rule above) becomes one brick piece where it lands; given back and laid again, the
record replays exactly (template ids; a room's piece laid as bricks is not laid again, as before).
The same pass, 2026-10-21 later: another tower's ground storey blown out under its west three
fifths tips over as one shell piece (90 degrees); a watchtower build laid a storey at a time, its
first floor blown out, the top leaving as a shell piece; four towers shot over a tight budget, the
far storeys given back and the one stood by kept; and the whole log replayed into twins -- some
2,700 commands, 0 missed, the same structure.

Found on the way and fixed: `lay_band` changed a chunk a worker was baking (barrage probe
crashed); bands rebuilt for storeys just laid drew what the building had shed (held now, as a
promotion is behind its shell); a landing on a building's shell (`_shear_building`) laid the
whole building; falling-path promotion laid every storey under wreckage falling *inside* its own
building; the collapse director took a banded building's template count for its size.

Not done: rooms as units, anchor cells by list (§5.2); a shell piece is not in a checkpoint's
pieces (one loaded mid-fall is gone; the building is cut as it was); a live co-op client would
lay storeys of its own on a look or a walk-up as the host does, and only the host's LAYs are in the
log -- the city has no live client yet, so that is unchecked; the budget's figure is the doc's
first guess, not a measured one.

### 5.4 What it should buy (estimates)

| | today | storey units |
|---|---|---|
| first hit on a 22k-brick tower | the whole tower laid (~140 ms raw, templates help) | one or two storeys, ~700-1,400 bricks (~5-9 ms raw; less from a template) |
| memory, one hit tower | ~120 MB+ | ~5-10 MB |
| a 500 m ship hit amidships | impossible | one deck of one section |

---

## 6. What to take from STA and zylanntest

| need | where | what it is |
|---|---|---|
| walking round a small body | STA doc 05 | radial gravity controller: full basis rebuilt from radial up every frame (the strafe-drift fix), `up_direction` every frame |
| a ship as a frame you stand in | STA doc 17 §4, doc 12 | space -> planet -> ship frames; boarding is a frame handoff that carries velocity |
| ship damage anchored to a root | STA doc 17 §5 | what is cut off from the bridge / core leaves as debris |
| tiny floating ground deleted | STA doc 09 | islands under ~2 m³ break off, fall, are deleted on impact |
| belts and rings | STA doc 15 §3 | far disc, near instanced band, inside: nearest N promoted |
| odd-shaped bodies | STA doc 25 | potatoes and ovals cost nothing extra; more polyhedron sides is worse |
| flying a ship | zylanntest `game/ship/scripts/ship_controller.gd` | 6DOF pilot and maneuver modes; speed cap falls near a planet (~2000 -> 300 m/s) |
| a ship's gravity | zylanntest `ship_controller.gd` (`is_gravity_field`), `game/ship/docs/plan.md` | gravity-generator blocks pull players toward ship-down inside the ship's box |
| a ship as a sparse grid | zylanntest `ship_voxel_grid.gd` | 16³ chunks in a dictionary, each its own mesh and column boxes on one body; an edit rebuilds one chunk |
| floating origin, orbits | zylanntest `systems/core/solar_system_manager.gd` (also STA) | rebase the universe past a distance; orbits on rails, time only in free space |
| space <-> ground | zylanntest `planet_transition_manager.gd`, `Docs/voxel_planet_game_design.md` §6 | approach, reframe, enter the surface, exit; four phases with clouds hiding the swap |
| a city seen from orbit | zylanntest design doc §6 | the planet's far texture re-baked where it changed (dirty cells, throttled): big builds show from space |

---

## 7. If it is taken up: order

1. **Storey units in the flat game** (§5, Next.md 2.5): worth doing now -- it is the first-hit
   lag the user has reported (CollapseNext.md), and every ship and station needs it.
2. **The brick budget** (§5.3) replacing distance-only trimming.
3. **Shell pieces** (§5.2): a broken-off upper part as a rigid shell.
4. Sections, joints and hit points for ships and stations (§3.2); pre-warm (§3.3).
5. Space: zero-g pieces, drift records (§4), a ship frame, flight (zylanntest), a belt (STA).
6. Small bodies: STA's radial controller on one smooth asteroid (§1).

Gate for 1-3: a 22k-brick tower shot at mid-height -- first-hit time, memory, and the upper part
falling as one shell piece -- on a quiet machine (editor closed), against today.
