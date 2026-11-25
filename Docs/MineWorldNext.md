# Mine world -- later work

A list, not a design doc: what is known to be open in the mine world, its
terrain, the brick overlay and the lighting, with enough said about each to
pick it up cold. Written 2026-11-24. When an item is done, delete it here and
say so in the doc it belongs to.

Other lists: [CollapseNext.md](CollapseNext.md) (destruction),
[MineWaterNext.md](MineWaterNext.md) (water), [Next.md](Next.md) (the city).

## Not yet looked at in a picture

1. **The cave's black depth fade** (`MineWorld._cave_fog`, the world setting
   Cave view distance): underground the view ends in black at the nearer of
   the deep tier's reach across and up/down. Never checked in a picture.
   A gate: stand in a long cave, look along it at radius 2, 4 and 8, and save
   pictures; the fade should end before the drawn sections do, with no grey
   band and no cut-off wall.
2. **The city on terrain with the brick overlay.** Every TerrainStreamer
   makes the overlay now (`auto_overlay`, Docs/BrickOverlay.md), the city's
   too. Nobody has looked: run a city pass that stands on terrain, picture
   the ground near the camera, check the bevels and that nothing z-fights
   under buildings.

## Not yet timed

3. **The deep tier at its largest** (Cave view distance 8: radius 8, up/down
   4 = up to 17 x 17 x 9 sections). Load time, frame time and memory never
   measured. `--gate=deep` at radius 8, and `--gate=mem` underground.
4. **The overlay behind-faces' cost on the GPU** (Docs/BrickOverlay.md 6b,
   the terrain-audit chat's): 2095 behind triangles a tile, drawn near the
   eye. `--gate=gpu` with the editor closed, `-- --no-behind` for the A/B.

## Known wrong, not fixed

5. **Water takes no lava light.** Water gets the sky's light per vertex, but
   lava's block light needs the fluid lock that mesh_tile holds
   (Docs/MineWorld.md 18). A lava-lit cave's pool stays dark.
6. **terrain_probe fails two checks, on main too**: "turning it off gives the
   packer its cells back" (196 pieces bricked vs 196 mixed) and "every cell
   has exactly one top surface" (tile 1,1: 993 of 1024). Nobody has looked
   at why. Its "a tile builds in well under a frame" also fails when other
   runs are going (timing, not a bug).
7. **The planet's --gate=light: "the grid darkens the inside"** fails
   (0.550 against 0.590 with the grid off): BrickGridLight is meant to make a
   building's inside darker than without it and does not. Seen 2026-11-24,
   the same at reflection atlas 256 and 32 -- not the atlas.

## Worth measuring next

8. **The process's RAM** (~2.2 GB private in the mine world). The video
   memory was cut twice on 2026-11-24 (reflection atlas, item icons:
   Docs/TerrainRegions.md 2.1); the RAM side has had no audit. Start from
   terrain_mem_probe's "process" line and a run with no water, no trees, no
   deep tier, one at a time.
9. **The engine's own ~264 MB of video textures** for any 3D window
   (tools/probes/vram_baseline_probe.gd). Probably Godot's and the driver's
   floor; worth one look at what a Forward+ window allocates by default
   (GI buffers, VRS, decals atlas) before calling it fixed.

## The brick overlay

10. **Far bricks get no real bevel at all**: past the overlay's 12 m reach the
    shaded chamfer is all there is. Fine today; if a scope or a long view
    shows it, a cheaper far tier (bevel facets only, no boxes) is the idea.
11. **Shots at slopes, ramps and curved ground** are not in any overlay list
    and still go the old way (find_brick on a worker, the tile's own hole in
    35-70 ms). A shot at one is seen late.
