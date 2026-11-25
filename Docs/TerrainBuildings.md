# Buildings as ground (the mine world)

The user's direction (2026-11-24): the terrain field is the ONE place bricks
live. A building is bricks in the ground, not an object on it -- so anything
a player builds digs, collapses, lights, saves, streams and gets real bevels
(the brick overlay) without being declared a building. The city's building
features come to the terrain, not the other way round. Heights for now: the
city's, at most 10 floors.

## 1. Stage 1 -- done 2026-11-24: stamp a city tower into the field

- `scripts/terrain/mine_buildings.gd` (MineBuildings): the city's own
  generator (TowerRecipe, the stairwell as TowerBlockout lays it) is built
  into a scratch BrickWorld chunk and read back brick by brick; each brick's
  box becomes plate cells (`fill_box`) in the terrain material whose filament
  is nearest its colour. Glass (PETG) is left out: open windows. The plot is
  cleared above the base and stone laid under it to the footprint's lowest
  ground, so it stands on the ground and is joined to it.
- Gate `res://scenes/terrain_test.tscn -- --gate=buildings` (`--floors=N`,
  1-10, default 6; `--dig-all`): stamps a 20 x 20 stud tower beside the
  player, pictures it near / from 40 m / from 120 m
  (user://dev/mine_building_*.png), shoots its wall, digs out the ground
  under half its footprint (or all of it) and counts what falls.
- Measured (6 floors): 1014 bricks -> 22,856 cells, 17.1 m tall, stamped in
  ~110 ms. Shot: hidden the frame it is hit, the field has the hole. Real
  bevels up close (the overlay), a plain block far off (the coarse tier).

## 2. What looks or works wrong (what stage 1 showed)

1. **Colours** (fixed in stage 2). A cell holds a material, not a colour;
   each building colour went to the nearest terrain material, so walls came
   out in stripes of stone, sandstone, clay and terracotta.
2. **Strength** (fixed in stage 2). The ground holds at 4x a building
   brick's tension (ground_collapse TERRAIN_TIMES): a tower with half its
   footprint dug away lost 6 bricks and hung over the hole.
3. **Tall things fall whole** -- not a problem after all: dug out from under
   all of it, the tower (122 plates) dropped into the hole as pieces and
   landed (the survey grows upward, TerrainCollapse GROW_UP; a first look at
   the picture misread it as standing).
3b. **No tipping.** The solve is tension, not balance: half its footprint
   gone, a tower holds on the other half's studs. The city's buildings tip
   (Docs/StoreyUnits, the storey-unit landings); the ground's survey does not.
4. **Brick shapes.** The terrain draws its own bond (staggered bricks by
   course), not the building's bricks; a placed-brick rect exists for player
   builds (`q_placed`), not yet for stamped ones.
5. **No glass, doors, furniture, lamps, rooms** (room light boxes, room
   streaming): none of the city's interior is in the field.
6. **Far view.** The coarse tier draws a tower as a solid block; windows and
   setbacks are lost past the near tiles. Fine at 120 m; a skyline of towers
   will want the city's far view from bricks (Docs/Structures.md).

## 3. Stages

**Stage 2 done 2026-11-24:** building materials MAT_FIL_BASE (64) + the
filament index (brick_terrain.h: is_building_material, clamp_material,
material_filament): the city's colours, studded, strong-bonded. The survey
takes `building_times` (ground_collapse passes TERRAIN_TIMES): a building
brick weighs 4x its cells there, so at the ground's 4x tension it holds as a
city brick does. Each stamped brick is BrickTerrain.mark_placed -- one brick,
kept whole -- but only where it fills whole terrain courses: a storey is 20
plates (6 courses + a 2-plate slab), so most floors sit off the ground's
course lines and stay bond cells (3,204 of 22,856 cells placed). Half dug:
166 bricks let go (6 before); it still stands on the other half (3b).
Mined, a building brick drops no item (ItemCatalog has none for them).

**Stage 4 done 2026-11-24 (the building's own bricks):** instead of placed
bricks at plate offsets, the building is laid ON the ground's courses:
MineBuildings.course_map makes each 2-plate slab (and the base) one 3-plate
course, so a storey is 21 plates, 7 courses, and every course of bricks
lines up (the floors a plate thicker). Every brick that fills its courses is
mark_placed (a slab's lower layer laid, not placed): 8,552 of 25,656 cells
kept as whole bricks (3,204 before), the walls drawn as the building's own
bricks. 6 floors: 18.1 m. Half dug, nothing lets go now -- whole bricks
bridge the gap (no tipping, 3b); dug out from under all of it, the tower
falls as ONE piece of 964 bricks (--gate=buildings --dig-all).

2. **Building materials.** (done, above) Append terrain materials for the building
   palette's colours (or a colour byte per edited cell, if the edit table can
   carry one): walls the city's colours. Each material its own strength
   (building bricks at x1, ground at x4), read by the survey per cell.
   Gate: --gate=buildings pictures against the city's tower; half dug -> it
   tips or tears as a city building does.
3. **Tall surveys.** The collapse survey grows its box upward until it is
   past the top of what is connected (or a building stamp registers its box
   so a dig under it surveys the whole of it). Gate: --dig-all leaves
   nothing standing over the hole.
4. **Placed bricks keep their shapes.** (done by course alignment, above) Stamped bricks recorded as placed
   rects, so the mesher draws the building's own bricks, and the overlay's
   boxes are its bricks. Needs placed bricks at PLATE offsets, not only on
   the ground's courses (a storey is 20 plates, the ground's course 3).
4b. **Tipping.** A building whose support is cut on one side leans and falls
   over (balance about its remaining support), as the city's storey units do.
4c. **Items.** A mined building brick gives a block item of its colour.
5. **Glass.** A translucent terrain material (the brick shader's glass
   pass); windows glazed again.
6. **Interiors.** Doors and furniture as placed assets on cells (the asset
   placer stores {asset, cell}); rooms found from enclosed air (the spaces
   tool, Docs/Structures.md) for light boxes and room streaming.
7. **Far view.** Tall regions in the coarse tier drawn from their bricks
   (Docs/Structures.md, "far view from bricks").
8. **Placing them.** Buildings from a world's generator (towns), and from
   the workshop's builds (BuildRecipe) the same way, 10 floors at most for
   now.
