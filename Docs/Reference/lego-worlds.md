# Reference — LEGO Worlds terrain

What LEGO Worlds (TT Games, 2017) does with brick terrain, and what it suggests
for ours. Screenshots are LEGO's and are NOT committed; the ones this was
written from are the Steam store set (appid 332310,
`store.steampowered.com/api/appdetails?appids=332310`), with local copies in
`shots/reference/lego-worlds/` (git-ignored).

## What the terrain is made of

TT describe it as voxel-based, "formed using wedge bricks of all sorts and
sizes along with normal rectangular shapes". Their build palette lists 1x1
wedges and pyramids, 1x2 wedges, 1x2 slopes and inverted slopes, 1x2 roof
tiles, 1x3 curved slopes and 2x4 angle bricks. Read off the screenshots:

| Where | What it is built from |
|---|---|
| Grass hillsides (`hillside_slopes.jpg`) | Stepped rows of 1x2 and 2x2 **slopes** at every one-brick rise, studded flat tops between them; cliffs are vertical faces of 1x1/1x2 columns in mixed colours (grass over dirt), not smooth |
| Mountain faces (the user's polar-bear screenshot) | Long **wedge and cheese slopes** laid in rows along the contour, several studs long, so a steep face reads as shingles, not stairs |
| Wide flats (`snowfield_terraces.jpg`) | Mostly smooth **tiles** with sparse studs; gentle rises show as thin concentric terrace lines a plate or a brick high |
| Far mountains (`desert_far_mountains.jpg`) | Still bricks — a fine voxel staircase at distance, not a smooth surface |
| Tree canopies, roofs (`slope_rows.jpg`) | Rows of 1x2 slopes stacked in offset courses: the same trick as the hillsides |
| Ledges (`snow_ledge.jpg`) | Running-bond brick walls under a studded top: the side of a step is bricks of mixed length |

## What it suggests for us

1. **Slopes, but long ones.** We had 1x1 ramps and turned them off
   (`RAMPS_ENABLED`, brick_terrain.h): a 1x1 slope is a 50° face a third of a
   metre across and the ground read as melted. LEGO Worlds' hills do not use
   1x1s: they use 1x2 / 2x2 slopes (rise one brick over one stud, ~39°, with a
   studded back strip — our `slope_1x2`, `slope_2x2`, `slope_2x4` in
   `Docs/Parts/slopes.md`) and, on gentler ground, **curved slopes** that rise
   one brick over two to four studs (`curve_1x2`, `curve_2x2` exist; a 1x3 /
   1x4 curve would need making). Rule of thumb from the shots: a slope piece
   only where the rise is exactly one brick and the run under it is at least
   the piece's length; pick the piece by the run (1 stud → slope, 2–4 studs →
   curve), laid along the contour so a row of them reads as shingles.
2. **Corners.** A contour that turns needs inside/outside corner slopes (2x2
   corner, 1x1 pyramid) or the row breaks into sawteeth — both are in their
   palette and neither is in ours yet.
3. **Cliffs stay bricks.** Anything steeper than one brick per stud is a
   vertical face of bricks, coloured in bands (grass cap, dirt below), which is
   what our blocky walls already do; the colour banding is the part we lack.
4. **This is also what closes the blocky → smooth gap.** A hillside of 1x2 /
   curved slopes is a sloped surface made of bricks — the same silhouette our
   smooth far ground has — so the step from LOD 1 to LOD 2 becomes "slopes
   drawn as slopes" to "slopes drawn as one surface".
5. **Far ground.** They keep bricks at distance; our smooth far ground with
   course lines (Terrain.md 19.19–19.21) is the cheap stand-in for that, and
   matches it better once the near ground has slopes.

## Parts we would need

| Part | Have it? | Use |
|---|---|---|
| `slope_1x2`, `slope_2x2`, `slope_2x4` | yes (Docs/Parts) | one-brick rise over one stud, along a contour |
| `curve_1x2`, `curve_2x2` | yes | rise over two studs |
| curved slope 1x3, 1x4 (and 2x3, 2x4) | no | gentle hills: rise over three / four studs |
| corner slopes (inside/outside), 1x1 pyramid | no | where a contour turns |
| cheese slope 1x1 / 1x2 (one plate high) | no | plate-step regions (our half-brick steps) |

Sources: Wikipedia "Lego Worlds"; LEGO Worlds wiki, "Slopes"; Steam
discussions ("So is this basically the ultimate voxel game?"); Steam store
screenshots for app 332310.
