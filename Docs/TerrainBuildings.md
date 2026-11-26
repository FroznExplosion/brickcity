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

**Stage 4b done 2026-11-25 (tipping):** MineBuildings keeps a registry of
stamped buildings (box, base, weight by column). After any edit reaching a
building's base (`after_edit`, from terrain_edited), its weight's middle is
tested against the convex hull of the columns whose bottom brick still
stands on solid ground (at least a quarter stud inside). Off it, the whole
building is let go as ONE piece (ground_collapse._let_group_go): resting on
what is left of its support, it leans over the edge and falls. Gate: dug
past its middle (11 of 20 columns), it tips -- one piece, 8,492 bricks, lying
on its side (mine_building_fallen.png). Damage to the building itself does
not move its middle yet (the weights are the stamp's).

**Stages 4b-8 done 2026-11-25 (one round, the user: "do all next items"):**

- **4b, weights follow damage.** An edit into a building recounts the
  columns it reached (MineBuildings._column_weight: its building cells,
  base to top), and a changed weight asks the balance again, as an edit
  under its base does.
- **4b, breaks as it lands.** A toppled building goes in ITS OWN bricks:
  each stamped brick still whole, a course at a time, tiled into the
  falling parts (2x4 .. 1x1, _tile_course), bonded across courses as it was
  laid; what damage cut goes as 1x1s. Its joints at a city brick's strength
  (ground_collapse._let_group_go `times` 1.0, not the ground's x4), so
  PlanetPieces' landing rule shears it where it hits.
  Four things kept it from tipping at all, each fixed: let go from rest on
  the edge of what held it, it fell asleep (a constant force does not wake
  a body) and settled frozen -- so it starts turning its way (TIP_SPIN) and
  may not settle for 5 s (ground_collapse._keep_tipping); the 100-piece
  cap put it away as a record, in sight (pieces over KEEP_LAID_BRICKS are
  no longer put away for the cap); cells of it that fill no whole course
  (glass runs, furniture plates, stair steps) stayed in the ground and held
  it from inside (cleared when it topples); and frozen rubble on or in it (a
  shot brick on its roof) is immovable -- such pieces are woken.
- **4c, items.** "Plastic bricks" (ItemCatalog): one material family whose
  colours are every building material (MAT_FIL_BASE + each filament). A
  mined building brick is one of its colour, and lays that colour again.
  Glass is its own block item ("glass").
- **5, glass.** The city's towers have no glass bricks (it paints its
  panes, PiecePanes): MineBuildings._glaze fills each outer-wall opening
  above the ground storey with glass cells (the ground storey's are its
  doors). MAT_GLASS, a new ground material (appended, 41, after farming's two): solid to
  edits, collapse and collision; light passes it (the sky and block light
  fills read it as open); the overlay lays no brick of it; the terrain
  shader draws it as a 4x4 screen-door (55% of its pixels discarded, fixed,
  shadows too) and never sinks it; the near mesher stamps the glass material byte on its
  faces (it wrote none on block faces before -- only glass gets one, so no
  other face's look changes). A translucent brick of a stamped building
  or build is glass. Not a real transparent pass: one opaque draw kept.
- **6, interiors.** The tower's rooms are furnished as the city's
  (TowerBlockout._furnish: RoomManifest's furniture as plain bricks), so
  furniture is building bricks too: mined, shot, falling with it. Not yet:
  doors as moving parts, lamps that light (a lamp brick is a coloured brick:
  block light comes from lava only), room streaming.
- **6b, fittings (2026-11-25, later).** A stamped tower is fitted with the
  mine world's wiring devices (Docs/MineWiring.md), not new ones
  (MineBuildings.fit_out): every interior doorway (TowerRecipe.doorways, 4
  studs) gets a double door -- two 2-stud doors hinged at its ends, opened
  by RMB or power -- and every room (RoomManifest.rooms_for) a lamp near its
  middle with a lever beside it. Lamps start dark (each lit lamp is an
  OmniLight: fine for tens, not a town's hundreds); the lever lights it. 6
  floors: 22 doors, 24 lamps. Saved, broken and dropped by the wiring as
  its own devices. Not the outer entrances yet.
- **7, far view.** Partly: windows are glass cells now, not air, so the
  coarse tier keeps them as sky-blue cells on the block. The far view from
  bricks (Docs/Structures.md) is still the city's alone.
- **8, placing.** `MineBuildings.stamp_build(host, corner, path)`: any
  workshop build (BuildRecipe; its towers and catalogue furniture expanded as
  the city placer does) stamped the same way (a brick placed where it fills
  whole ground courses). TOWNS: a world with "towns" on (World settings,
  "Towns (city buildings)"; off for worlds from before) has a town in 40% of
  768-stud regions, 1..3 x 3 plots of 2..10-floor towers from the seed
  (`town_at`), stamped one a half second as the player comes within 260
  studs, on level dry plots only. The registry (balance records) and the
  towns laid are saved in the world file ("buildings", "towns").

Gate `--gate=buildings` (now digs 13 of 20 columns, 30 plates under the
ground, so the tip is not a balance on the edge) checks all of it: glass cells, items, the cottage
build, towns from the seed, weights recounted after the shot, the tip, the
landing breaking it; pictures inside (mine_building_inside.png) and of the
cottage. 6 runs in a row passed after the fixes, and --dig-all. Headless:
`tools/probes/mine_buildings_probe.gd` (glass, furniture, the cottage, towns,
the save, the items).

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
4b. **Tipping.** (done, above) Next: weights that follow damage, and a
   building that breaks as it lands rather than lying whole.
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
