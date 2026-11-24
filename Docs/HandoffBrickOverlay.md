# Handoff: brick overlay (real chamfers as instances), mine world

Written 2026-11-23 for the next chat. Read `Docs/BrickOverlay.md` first (the
plan, 7 stages, and its Status), then `Docs/MineWorld.md` section 19 (how we
got here).

## Where things are

- Worktree `C:\Users\lbaun\bc-skylit2`, branch `skylit-followups`, merged into
  main up to 0f1a01d0. godot-cpp is a junction to the main folder's (remove it
  with `cmd /c rmdir` BEFORE any `git worktree remove`). `override.cfg` is in
  place. Its DLL is built from the branch.
- Main's DLL was rebuilt 17:07 on 2026-11-23 (after the last C++ merge).

## Done in this chat (all in main)

- Sky light on things (pieces, drops, chests), lava BLOCK light on them
  (`BrickTerrain.block_light_at`), falling sand (per-instance levels), crumbs
  (`PlanetCrumbs.shade`), water (per-vertex sky level in COLOR.b,
  `brick::sky_levels_into`, water_fluid.gdshader includes sky_lit.gdshaderinc).
- Knocked-off bricks are pieces in the mine world (`debris_max` 0).
- Seam fixes in `mask_faces` (brick_terrain.cpp): edge flags remapped per face
  winding; skirts past covered edges; a backing quad behind chamfered faces;
  1 mm overlap of flat faces (`FLAT_OVERLAP`); chamfered faces square at the
  tile's sides and floor (`bound`).
- Caves: `TerrainDeep.radius` from the world setting **Cave view distance**
  (`cave_tiles`), up/down = half of it; a black depth fade underground
  (`_cave_fog` in mine_world.gd) ending at the nearer of the two reaches.
- World setting **Chamfered brick edges** (`chamfer`,
  `TerrainTile.bevel_enabled`). Off = no slits at all (the user confirmed).
- Brick overlay **stage 1**: `build_tile` / `build_section` return
  `overlay_bricks` (10 floats a brick); `tools/probes/terrain_bricks_probe.gd`.

## Next: stage 2 (Docs/BrickOverlay.md 3-4)

1. `scripts/terrain/terrain_bricks.gd` (TerrainBricks), a child of the mine
   world: keep each drawn tile's and section's `overlay_bricks` (TerrainTile
   gets the bake's dictionary -- hand the list on where the streamer/deep tier
   land a bake); dedupe bricks across tiles by corner + course; each frame
   pick those within `range_m` (~12 m) of the eye and in a widened view cone,
   nearest first, up to `max_bricks`; one MultiMesh (unit bevelled box,
   `BrickNear.bevel_box_mesh`) with transform = the brick's box, colour, custom
   data (material, sky, block). CPU arrays only, no read-back.
2. `TERRAIN_BOX` copy of `shaders/terrain.gdshader` (as MineSkyLit makes
   defined copies): material from INSTANCE_CUSTOM, UV/UV2 from the scale
   (`shaders/brick_boxed.gdshaderinc`: `brick_box_size`, `brick_box_inset`,
   `brick_box_uv`), sky/block light from custom data.
3. Gate `-- --gate=bricks` (mine_world.gd, next to `--gate=seams`): the stone
   room with the overlay on; pictures, instance count, fill ms.
Then stage 3 (the 13 mm recess in terrain.gdshader's vertex, only on faces
under bricks -- mark them in the bake, e.g. CUSTOM0.b, since slopes/ramps get
no instance) and the gates in the doc.

## Open items (not done)

- With chamfers ON: `--gate=seams --deep --at-top` leaves 88 px (one short
  slit where a course seam meets a tile seam); `--gate=seams` showed 2 px at
  a wall/roof join in 1 run of 3. The overlay is meant to retire this code.
- GPU timing never taken cleanly (`--gate=gpu`, editor closed, nothing else
  running, start under ~62 C; compare section 17/18: 5.48 / 3.89 ms).
- The cave fade has not been checked in a picture; deep tier at radius 8 with
  up/down 4 is up to 17x17x9 sections, not timed.
- Water gets sky light only (lava's block light needs the fluid lock that
  mesh_tile holds).
- `terrain_probe` fails 2 checks on main too (packer cells, one top surface);
  its "tile builds under a frame" timing failed once with the editor open.

## Gotchas

- The Bash tool halves `\\`, even in quoted heredocs: write Python patch
  scripts with Write, and in Python use raw strings for Windows paths.
- Patch scripts: `open(..., newline='')`, keep CRLF.
- After merging main: stale DLL means parse errors; rebuild (`python -m SCons`
  in gdextension/brick) then `--import`.
- Parse-check mine_world.gd before a windowed run (load its source with
  `MenuManager.` swapped out); a parse error hangs a windowed pass.
- Gates that move the camera: make their own Camera3D (the walker's is posed
  every frame). Count magenta with a loose test (r, b > 0.45, g < 0.6 x min):
  tonemapping shifts pure magenta.
- `heat_sum.py` cannot read a window across midnight; read the CSV. The heat
  logger dies in standby: restart it as memory `heat-logger-dies-in-standby`
  says. One windowed run at a time, wait under 80 C.
- Never run terrain_test.tscn without a `--gate` flag (it saves the world).
