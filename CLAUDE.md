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
  happened once (2026-09-25). To restore it, CLONE it standalone
  (`git clone https://github.com/godotengine/godot-cpp.git` into that folder,
  then check out the commit `git submodule status` names) and run a full
  `python -m SCons` in the main folder. Not `git submodule update --init`: that
  leaves a `.git` FILE with a relative path, which breaks `git status` in every
  worktree that reaches it through a junction.

## Areas

Advisory, to keep merges clean. Anyone may make a small change anywhere; a large
change in another area is that area's job.

| Area | Owns |
|---|---|
| Build mode | `scripts/workshop*.gd`, `city_placer.gd`, `brick_palette.gd`, `shaped_parts.gd`, `build_recipe.gd`, `build_shell.gd`, `staircase_recipe.gd`, materials (`brick_materials.gd`, `shaders/brick*.gdshader*`, the material tables in `brick_grid.h`), `Docs/Parts/`, `builds/` |
| Terrain and water | `brick_terrain.*`, `terrain_*.gd`, `water_*.gd`, `underwater.gd`, `heightfield_*`, `shaders/terrain*`, `shaders/water*` |
| Weapons and effects | `weapons/`, `fx/`, `autoload/`, `loot/` |
| Disasters | `scripts/disasters/`, `shaders/disaster_*`, `tools/disaster_probe.gd`, `Docs/Disasters.md` |
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
- The brick mesher or its near tier (`bake_faces_into`, `chamfer_faces_into`,
  `brick_near.gd`, `brick.gdshader`): `brick_bevel_probe`, `brick_bevel_gap_probe`
  (not headless) and `--path . res://scenes/city.tscn -- --chamfer`
  (Docs/BrickBevel.md).
- Run the probes your change could affect before merging.

### Test windows stay out of the user's way

The user works on this machine while tests run. A run that opens a window --
any scene pass (`-- --something`), any probe marked `## Not headless` -- must
not take their keyboard, their mouse, or the middle of their screen. It used
to do all three, and Escape (their way out) paused the pass.

- **Once per worktree:** `cp tools/test_window.cfg override.cfg` (beside
  `project.godot`; untracked and gitignored). **Never in the main folder** --
  the game window there could not be clicked into.
- With it, every window that worktree opens: never takes the keyboard, never
  captures the mouse, opens as a title bar in the bottom right corner and is
  off the screen about three seconds later (`scripts/test_window.gd`), and
  draws at 1280x720. It is still drawn there; screenshots are as before.
- **Do not pass `--resolution`.** It makes the window full size while the
  engine starts, in the corner but large. The test window sizes itself.
- **Launch from Bash**, as the passes always have been. PowerShell's
  `Start-Process` gives the new window the keyboard whatever the setting says.
- Do not add `borderless` or a minimised start to `override.cfg`: either one
  takes the keyboard (measured 2026-10-06).
- Without the file a scripted pass still never captures the mouse and cannot
  be paused (`CityScene._scripted`), but its window opens mid-screen with the
  keyboard. Copy the file.
- New code that captures the mouse must not do it when `DebugCamera.hands_off`
  is set (today `DebugCamera._set_captured` is the only place that captures).
- A test window, and any scripted city pass, runs on the settings menu's
  **defaults**, in memory (`TestWindow.use_default_settings`): what the user
  has saved in Options no longer changes a gate's pictures or numbers. So a
  pass must **never save settings** -- `MenuSettings.set_value(id, v, false)`,
  never the saving form, never `reset_tab`/`reset_all`/`rebind`: it would write
  the defaults over the user's own `settings.cfg`.

### Know what a test measures, and prune what no longer matters

- Before running a probe or pass (or trusting its result), read what each
  check is FOR -- its comment and the doc section it cites -- not just its name.
- If a check measures something the game no longer has or needs (a removed
  feature, a replaced approach, a number nobody uses), remove that check (or
  that part of the pass) in the same change that made it obsolete, and say in
  the commit message why it went.
- Pruning is not a way to make a failing test pass: a check that fails on
  something still wanted is a bug to fix, not a check to delete.
- Stay in your area: prune checks in the files your area owns (Areas table);
  for another area's tests, tell the user which check looks obsolete and why.

### Performance measurements need the editor closed

Frame times, `--bench`, `--stress`, `--lod` and any other timing pass are only
trustworthy with the user's Godot EDITOR closed (an open editor inflates frame
times several-fold). Correctness probes and gates are fine with it open.

- Before a timing run, check for the editor: a Godot process whose command
  line has `--editor` (PowerShell:
  `Get-CimInstance Win32_Process -Filter "name like 'Godot%'" | Select CommandLine`).
- If it is open and there is other work left, **skip the timing run and carry
  on** with the next task; come back to it later.
- If the timing run is the LAST thing left, wait **30 minutes** (a background
  wait, not a sleep loop) and check once more. Still open: stop, do not keep
  retrying, and say in chat that the measurement was not taken because the
  editor was open.
- Never close the user's editor yourself.
- Report numbers taken with other test runs going (other chats' Godot
  processes) as unreliable, and say so.
