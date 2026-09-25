# Printed Brick City — working here

Several Claude chats work on this project at once. These rules exist so they do
not step on each other.

## One chat, one worktree

- Each chat works in **its own git worktree** on its own branch, never in another
  chat's folder. The main folder (`C:\Users\lbaun\Documents\brickcity`, branch
  `main`) is where the user runs Godot; work reaches it by merging.
- **Before each task:** bring your branch up to date — `git merge main` (or
  `git rebase main` if the branch is private and unpushed).
- **When something works:** merge it into `main` promptly, small and often — a
  feature or a fix, not a week of work. From the main folder:
  `git merge --no-ff <branch>` then `git push origin main`.
- **Uncommitted work in the main folder is allowed** (some areas keep work
  there). Git refuses a merge that would change a file with uncommitted edits;
  if that happens, do not force it or stash someone else's work — tell the user
  which file, and wait for that area to commit.
- Stage only your own files. Never commit another area's half-finished work.
- Temporary worktrees for experiments go in your scratchpad and are removed
  when done (`git worktree remove`).
- **Remove the godot-cpp junction FIRST** (see Building):
  `cmd /c rmdir <worktree>\gdextension\brick\godot-cpp`, check it is gone,
  then `git worktree remove`. A forced `git worktree remove` (or any recursive
  delete) follows the junction and empties the MAIN folder's godot-cpp --
  sources and built library -- which breaks every worktree's build. It
  happened once (2026-09-25); the fix was `git submodule update --init
  gdextension/brick/godot-cpp` and a full rebuild in the main folder.

## Areas

Advisory, to keep merges clean. Anyone may make a small change anywhere; a large
change in another area is that area's job.

| Area | Owns |
|---|---|
| Build mode | `scripts/workshop*.gd`, `city_placer.gd`, `brick_palette.gd`, `shaped_parts.gd`, `build_recipe.gd`, `build_shell.gd`, `staircase_recipe.gd`, materials (`brick_materials.gd`, `shaders/brick*.gdshader*`, the material tables in `brick_grid.h`), `Docs/Parts/`, `builds/` |
| Terrain and water | `brick_terrain.*`, `terrain_*.gd`, `water_*.gd`, `underwater.gd`, `heightfield_*`, `shaders/terrain*`, `shaders/water*` |
| Weapons and effects | `weapons/`, `fx/`, `autoload/`, `loot/` |
| City and buildings (shared) | `city_scene.gd`, `building_registry.gd`, `tower_recipe.gd`, `room*.gd`, `island_manager.gd` — small changes by anyone, merged soon |

## Building

The engine library is **not committed**; each worktree builds its own.

- A new worktree has an empty `gdextension/brick/godot-cpp` (a submodule).
  Link the main folder's already-built copy instead of cloning and building it:
  `cmd /c mklink /J gdextension\brick\godot-cpp C:\Users\lbaun\Documents\brickcity\gdextension\brick\godot-cpp`
  (remove the empty directory first).
- Build: `python -m SCons` from `gdextension/brick` (`scons` is not on PATH).
  The Godot editor locks the DLL of the folder it has open — that is only ever
  the main folder, so worktree builds are never blocked.
- Before running scripts, refresh Godot's caches once:
  `Godot_v4.6.2-stable_win64_console.exe --headless --path . --import`.

## Testing

- Console Godot: `C:\Users\lbaun\Downloads\godot_bin_tmp\Godot_v4.6.2-stable_win64_console.exe`.
- Probes: `--headless --path . --script res://tools/<name>_probe.gd` (build mode:
  `place_probe`, `city_place_probe`, `palette_probe`, `shaped_probe`, `scale_probe`;
  the workshop gate: `--path . res://scenes/workshop.tscn -- --gate`).
- Run the probes your change could affect before merging.
