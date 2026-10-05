# Reference — zylanntest (voxel planets on Zylann's Voxel Tools)

Source: `C:\Users\lbaun\Documents\zylanntest`. Godot 4.6, Zylann's Voxel Tools (a custom fork).
A Minecraft-like multiplayer voxel game with TOROIDAL planets (the world wraps in X and Z), a
seamless space-to-ground transition, and several planets a solar system
(`Docs/voxel_planet_game_design.md`).

## What is worth taking

* **The curvature shader** — `shaders/blocky_terrain.gdshader` (from `triplanar_blocks.gdshader`):
  each vertex drops by its horizontal distance from the player squared over `2 * u_planet_radius`,
  blended by the player's altitude (`u_curve_low_altitude` .. `u_curve_high_altitude`,
  `u_curve_low_amount`), scaled by `u_curvature_strength` (0 in the structure builder —
  `systems/core/blocky_terrain_setup.gd`). A flat world that looks like a planet.
* **World wrapping** — `Docs/spike_01_world_wrapping.md`: one canonical coordinate space modulo
  the world size, shortest toroidal deltas, noise sampled on wrapped coordinates. Walking round is
  real travel, no teleport.
* **Size tiers and the curve rule** — `voxel_planet_game_design.md` §3: curve radius about a fifth
  of the world's size, baked at world creation (changing it later moves every structure's look).

Used by: `Docs/Planets.md` §2.
