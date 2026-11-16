# Handoff: one UI for both workshops

For the chat that takes this over. Written 2026-11-14. The plan is **Docs/BuildTools.md
section 21** -- read it first; this file is what the plan does not say: where things are, what
was found, how to test without harming the user's files, and what to do next.

## State

- Asked by the user 2026-11-13: the workshop (`scenes/workshop.tscn`) and the asset workshop
  (`scenes/asset_workshop.tscn`) should share most features; clean the UI up and make it the same
  in both. Analysis first, then a plan, then building in stages.
- Done: the analysis, the plan (section 21, the user's five answers in it), a tool that
  photographs both UIs (then, 2026-11-13, no game code changed).
- Stages 0 and 1 (1a the asset's bar and pop-out, 1b the building's outliner and Selected,
  1c the status line) and stage 2 (2a every key a button and one key map, agreed with the
  user; 2b one camera) merged 2026-11-14, stage 3 (the six menus) 2026-11-15 (section 21, "As
  built"), stage 4 (4a the building's stage tabs, Finish keeps the last layer; 4b the Generate
  tool, the generators out of Rooms), stage 5 (one library on Tab) and stage 6a (one Draw on
  the asset's Bricks stage, the base then the height) and 6b (one Draw on Block out: the brush
  and the stamps; box, round, cone pulled) 2026-11-15. Next: **stage 7**, a model into clay and
  bricks in the building workshop -- needs the junction and SCons (C++, `sdf_form.cpp`), and the
  Build mode area owns it. Measured 2026-11-15 (section 21, "A model into a building",
  `model_scale_probe`): tick clay takes 20-40 s and 0.5-0.9 GB for an 80-100 stud model, Make
  bricks was the slow part; 7a (2026-11-15) made it 3x faster (section 21, "Stage 7a"); 7b
  (2026-11-15, C++) made fit slopes ~1.6x faster, the same bricks. 7c (C++)
  `SdfForm.mesh_cells`, a model straight to brick cells, no clay (400 studs in 0.12 s). 7d
  (2026-11-15) Generate > Model in the building workshop: open a model, size, wall, the budget
  first, laid over frames with a bar and Cancel, one undo (400 studs: 35k bricks in 4.6 s).
  Stage 7 is done; the cell clay is put off (section 21 says why). Stage 8 (plan in
  section 21, "Colours from a model"): 8a OBJ colours and 8b the model's colours in Generate > Model (C++
  `mesh_cell_colours`) done 2026-11-16; next 8c, the colour table on import (both workshops). Never run the probe at 200+ studs on this machine (memory).


## Where to work

- Worktree `C:/Users/lbaun/bc-ui`, branch `workshop-ui`. Since stage 7b it has the godot-cpp
  junction and builds its own DLL (`python -m SCons -j6` from `gdextension/brick`), and
  `override.cfg` (the test window). `git merge main` before each task; after merging C++ from
  main, build, then `--headless --path . --import`. Remove the junction FIRST if the worktree is
  ever removed (CLAUDE.md).
- CLAUDE.md's rules apply: one windowed run at a time, heat log after each
  (`python tools/heat_sum.py --last <minutes>`), launch from Bash, no `--resolution`.

## The pictures

```
cd C:/Users/lbaun/bc-ui
<console godot> --path . --script res://tools/shots/workshop_ui_shots.gd [-- --only=building|asset]
```

About 25 s, windowed. Writes 62 pictures to `user://dev/ui_shots/`
(`%APPDATA%/Godot/app_userdata/Brickcity/dev/ui_shots/`): `b..` the building workshop, `a..` the
asset workshop, one per tool, menu and panel. Run it before and after every UI change and look at
the pictures -- that is how the problems below were found.

**It must stay safe.** A windowed asset-workshop run without `--shot` or `--gate` restores the
user's autosave and then autosaves over it. The script sets `ws._no_autosave = true`,
`ws.bench._hotbar.save_path` and `ws.toolbars_save` to `user://dev/` right after `add_child`.
Any new script that instantiates a workshop must do the same. Never pass `--gate` just to get
this: it runs the bench's gate.

## Where the UI is

Since stage 1 also: `scripts/workshop/workshop_bar.gd` (the bar's list), `workshop_outliner.gd`
(the building's right side), `BrickBench.show_status` / `status_line` / `stats_on` / `bar_act`.

| What | File |
|---|---|
| Shared bricks, HUD readout, hotbar, paint palette, keys panel, menus' actions | `scripts/workshop/brick_bench.gd` (`_build_hud`, `_update_hud`, `KEY_ROWS`, `_on_menu`) |
| Menu bar's menus and the open / save dialogs | `scripts/workshop/workshop_menu.gd` (`asset_mode` hides the building's for the asset workshop) |
| Building: rail rows, the 20-button bar, the pop-out and every tool's options | `scripts/workshop/workshop_tools.gd` (`TOOLS`, `ACTIONS`, `setup`, `_build_options`, `process`) |
| Asset: stage tabs, per-stage tool rows, outliner, toast | `scripts/workshop/asset_workshop_ui.gd` |
| Asset: its own menu rows (File, View, Insert, one a kind, Help) | `scripts/workshop/asset_workshop.gd` `_build_menus`; the shared six and the bar's rows: `WorkshopMenu` (`add_bar`) |
| Asset: the old rail, now the options under the tools | `asset_workshop.gd` `_build_rail`, `_rail_process` (~6876-7217) |
| Asset: floating panels | `asset_workshop.gd` `_build_panel` (photos), `_build_point_panel`, `_build_help`, `toggle_catalog`; `asset_catalog_panel.gd` |
| Hotbar and the brick browser | `scripts/workshop/workshop_hotbar.gd` |
| Furniture catalogue (F6) | `scripts/workshop/furnish_tool.gd` |
| The kit's frame, rail, menu bar | `addons/workshop_kit/ui/` (`WkFrame`, `WkRail`, `WkMenuBar`); names no game class, raise `VERSION` on a change |

How the two share code: section 0 of BuildTools.md. New shared brick features go in the bench
(or the kit if they name no game class); an asset-only variation is a hook, not an override.

## Stage 0: what the pictures show broken

Small fixes, no design choice left. One merge, or two.

1. **The pop-out covers the readout** (building; `b01`, `b04`). `WorkshopTools.process` puts
   `ws._hud` at the rail's right edge and the pop-out on top of it. Until stage 1's status line,
   move the readout right of the pop-out while it shows (`_rail_right()` is already there).
2. **The toast overlaps the readout** (asset; `a2_*`). `AssetWorkshopUI.process` places `_toast`
   at `top + 44`, on the bench's `_hud`. And its text still says "Edit as SDF" where the button
   says "Bricks to clay": grep `asset_workshop.gd` for "Edit as SDF" in user-facing strings.
3. **Floating panels without a backdrop**, on top of the outliner and the readout (`a5_*`): the
   photos panel, the guides panel, the parts catalogue, the connection point panel. Give each the
   look the rail has (`bench.wk_ctx.panel_box()`), and place them clear of the rail and the
   outliner (`AssetWorkshopUI.frame` knows both).
4. **The asset rail's width jumps** from ~208 to ~330 px when a tool has options (`a02` against
   `a1_blockout_draw`): the old rail inside it is wider than `RAIL_W`. Keep one width.
5. **Redo is missing from the building's Edit menu** (`workshop_menu.gd` `_build_bar`; the asset
   workshop adds its own).
6. **F6, the furniture catalogue, has no button**: add it to the building's bar or under the
   tools, as Bricks is (the user's rule: every action a button).
7. **The asset help page** (`HELP_TEXT`, shown at start) is a wall of text and describes an older
   layout. Shorten it to what is true now; stage 1 replaces it.

Checks: `build_tools_probe`, `workshop_probe`, `asset_workshop_probe`, `asset_ui_probe`,
`furnish_probe`, `wk_smoke` if the kit changed; compare the COUNTS with main, not just the fails.
Then the pictures again.

## What was decided (do not ask again)

Section 21, "Decided with the user": one frame; the building's orbit camera in both; one Draw
gesture, base then height (this replaces the 2026-11-08 choice to keep the asset's one-drag); stage
tabs in the building workshop (Structure, Interior, Detail, Finish); one library browser. Also
wanted: a model into clay and bricks in the building workshop, kept small (coarser clay, skin
only, in sections, a budget said first -- measure a 400-stud model before building it), and a
colour table for a model's colours (the matching itself is built: Docs/AssetWorkshop.md, "Colour
from model to bricks").

## The user's standing rules for this work

- Every action is a button, not a key to remember; keys still work. **On the screen**, where
  it makes sense (bar, rail, under the tools, outliner) -- a menu entry alone is not enough
  (asked again 2026-11-14). `asset_ui_probe` checks the asset's keys against their buttons.
- One flow (press, drag the base, pull the height, click) over options and number boxes.
- A plan is written in Docs before it is built; "As built" goes under it after.
- The asset workshop's stages stay, in order. The 2D Sketch is wanted; in stage 6 it becomes
  Draw's pen outlines, not removed.
- A pass or probe never saves settings or writes the user's files.
- They budget chats by weekly usage: land small, merge often, offer a handoff when a chat is long.

## Open, to raise when its stage comes

- Stage 2: the keys -- settled 2026-11-14 (section 21, stage 2a).
- Stage 4: settled 2026-11-15 -- on Finish, Hand lays in the last layer used.
- Stage 5: settled 2026-11-15 -- inserted builds stay copies, furniture a reference.
- Stage 7: cell-sized clay is a second resolution of `SdfForm` (C++, `gdextension/brick/src/
  sdf_form.cpp`): that stage needs the junction and SCons, and the Build mode area owns it.
