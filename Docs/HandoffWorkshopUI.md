# Handoff: one UI for both workshops

For the chat that takes this over. Written 2026-11-14. The plan is **Docs/BuildTools.md
section 21** -- read it first; this file is what the plan does not say: where things are, what
was found, how to test without harming the user's files, and what to do next.

## State

- Asked by the user 2026-11-13: the workshop (`scenes/workshop.tscn`) and the asset workshop
  (`scenes/asset_workshop.tscn`) should share most features; clean the UI up and make it the same
  in both. Analysis first, then a plan, then building in stages.
- Done: the analysis, the plan (section 21, the user's five answers in it), a tool that
  photographs both UIs. **No game code has changed.** Main `7ee39400`.
- Next: **stage 0** (below). Then stages 1-8 in section 21's order, each merged on its own.

## Where to work

- Worktree `C:/Users/lbaun/bc-ui`, branch `workshop-ui`. It has the built DLL copied from main
  (no junction, no SCons needed while no C++ changes) and `override.cfg` (the test window).
  `git merge main` before each task; if main gained C++ since 2026-11-12 20:22, copy main's DLL
  again and run `--headless --path . --import`.
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

| What | File |
|---|---|
| Shared bricks, HUD readout, hotbar, paint palette, keys panel, menus' actions | `scripts/workshop/brick_bench.gd` (`_build_hud`, `_update_hud`, `KEY_ROWS`, `_on_menu`) |
| Menu bar's menus and the open / save dialogs | `scripts/workshop/workshop_menu.gd` (`asset_mode` hides the building's for the asset workshop) |
| Building: rail rows, the 20-button bar, the pop-out and every tool's options | `scripts/workshop/workshop_tools.gd` (`TOOLS`, `ACTIONS`, `setup`, `_build_options`, `process`) |
| Asset: stage tabs, per-stage tool rows, outliner, toast | `scripts/workshop/asset_workshop_ui.gd` |
| Asset: its eleven menus | `scripts/workshop/asset_workshop.gd` `_build_menus` (~line 10560) |
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

- Every action is a button, not a key to remember; keys still work.
- One flow (press, drag the base, pull the height, click) over options and number boxes.
- A plan is written in Docs before it is built; "As built" goes under it after.
- The asset workshop's stages stay, in order. The 2D Sketch is wanted; in stage 6 it becomes
  Draw's pen outlines, not removed.
- A pass or probe never saves settings or writes the user's files.
- They budget chats by weekly usage: land small, merge often, offer a handoff when a chat is long.

## Open, to raise when its stage comes

- Stage 2: the asset workshop's keys N, J, O, P, Y lose their jobs to buttons. Say which keys
  change before merging; the user has muscle memory there.
- Stage 4: a brick's layer comes from the tab. What Hand does on the Finish tab (probably: the
  last layer used).
- Stage 5: inserted builds are copies, furniture is a reference. "Edit in the asset workshop" is
  only for furniture unless the user wants builds as references too.
- Stage 7: cell-sized clay is a second resolution of `SdfForm` (C++, `gdextension/brick/src/
  sdf_form.cpp`): that stage needs the junction and SCons, and the Build mode area owns it.
