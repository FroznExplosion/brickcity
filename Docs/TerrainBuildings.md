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

1. **Colours.** A cell holds a material, not a colour; each building colour
   goes to the nearest terrain material, so walls come out in stripes of
   stone, sandstone, clay and terracotta, nothing like the city's palette.
2. **Strength.** The ground holds at 4x a building brick's tension
   (ground_collapse TERRAIN_TIMES): a tower with half its footprint dug away
   lost 6 bricks and hung over the hole.
3. **Tall things are not surveyed whole.** ground_collapse's survey box is
   at most 32 x 96 x 32 plates (MAX_BOX); a 6-floor tower is 122 plates. Dug
   out from under all of it, 2,706 bricks let go and the top of the tower
   still stood in the air.
4. **Brick shapes.** The terrain draws its own bond (staggered bricks by
   course), not the building's bricks; a placed-brick rect exists for player
   builds (`q_placed`), not yet for stamped ones.
5. **No glass, doors, furniture, lamps, rooms** (room light boxes, room
   streaming): none of the city's interior is in the field.
6. **Far view.** The coarse tier draws a tower as a solid block; windows and
   setbacks are lost past the near tiles. Fine at 120 m; a skyline of towers
   will want the city's far view from bricks (Docs/Structures.md).

## 3. Stages

2. **Building materials.** Append terrain materials for the building
   palette's colours (or a colour byte per edited cell, if the edit table can
   carry one): walls the city's colours. Each material its own strength
   (building bricks at x1, ground at x4), read by the survey per cell.
   Gate: --gate=buildings pictures against the city's tower; half dug -> it
   tips or tears as a city building does.
3. **Tall surveys.** The collapse survey grows its box upward until it is
   past the top of what is connected (or a building stamp registers its box
   so a dig under it surveys the whole of it). Gate: --dig-all leaves
   nothing standing over the hole.
4. **Placed bricks keep their shapes.** Stamped bricks recorded as placed
   rects, so the mesher draws the building's own bricks, and the overlay's
   boxes are its bricks.
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
