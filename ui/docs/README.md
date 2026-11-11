# ui/ — the in-game UI kit

One look for every HUD and in-game screen, the same as the menus', and the player's
**text scale** and **high contrast** (Options > Accessibility) applied to all of them.
Built on `menu/`'s `MenuTheme` (its palette and Theme); nothing of the game's inside.

| File | Role |
|---|---|
| `core/GameUI.gd` | `GameUI`: drawing helpers for HUDs, styling helpers for built screens, the HUD colours. Static. |

## Porting it into another project

1. Copy `menu/` and `ui/` (the kit needs `MenuTheme`; `menu/docs/01_menu_system.md` says how to
   set `menu/` up — the two autoloads, the host).
2. Nothing else: `GameUI` is a `class_name`, found by the editor.
3. Re-skin by setting `MenuTheme`'s palette (`MenuTheme.accent = ...`) and `GameUI`'s HUD
   colours (`GameUI.hud_warn = ...`) before the first screen draws.

Keeping two projects in step: give `menu/` and `ui/` their own repository and add it to each
project as a git submodule (or `git subtree`). A fix made in one project is pushed there and
pulled in the other; nothing in these folders may name a class of either game.

## Using it

**A drawn screen** (a Control's `_draw`: crosshair, bars, numbers over the world):

```gdscript
func _draw() -> void:
	GameUI.draw_text(self, "R  RELOAD", Vector2(size.x - 32, size.y - 18), 16, GameUI.hud_warn,
			HORIZONTAL_ALIGNMENT_RIGHT)
	GameUI.draw_bar(self, Rect2(32, size.y - 44, 260, 12), health_frac, Color.WHITE)
```

Sizes are **designed pixel sizes**: `draw_text` and `px()` scale them by the player's text
scale. Measure with `GameUI.text_width(text, size)`, never with the font directly, or a scaled
line will not fit where it was measured.

**A built screen** (Controls: a card, a menu, a catalogue):

```gdscript
var panel := PanelContainer.new()
panel.add_theme_stylebox_override(&"panel", GameUI.panel_box())
GameUI.style(panel)            # the menus' Theme, put on again when text scale changes
panel.add_child(GameUI.label("Loadout", 18))
```

## What stays the game's

What a colour **means** — a rarity (`Rarity.colour`), a team, a damage type, a defence
layer — belongs to the game's data, not to the kit. The kit gives the chrome: text, dim
text, the plate behind a bar, warning, ready, panels.

## Converting a screen (the recipe)

1. Replace `ThemeDB.fallback_font` + `font.get_string_size(..., px)` with
   `GameUI.text_width(text, px)`; replace `draw_string_outline` + `draw_string` pairs with
   `GameUI.draw_text`.
2. Replace a dark `draw_rect` behind a filled `draw_rect` with `GameUI.draw_bar` (the plate
   is the bar's rect grown by 2, as the HUDs drew it).
3. Replace chrome colours: white text → `GameUI.hud_text` / `hud_dim`, black plates →
   `hud_back`, red "low/empty" → `hud_warn`; in Controls, `MenuTheme.text` / `text_dim`.
4. Replace `add_theme_font_size_override(&"font_size", N)` with `GameUI.px(N)`, and a
   hand-made panel `StyleBoxFlat` with `GameUI.panel_box()`; call `GameUI.style(root)`.
5. Leave meaning colours alone (step "What stays the game's").

## Converted

| Screen | State |
|---|---|
| `scripts/pawn/player_hud.gd` (drawn) | on the kit |
| `scripts/guns/gun_card.gd` (built) | on the kit |
| `scripts/pawn/player_arsenal.gd`, `scripts/progression/skill_screen.gd`, `scripts/space/galaxy_map.gd`, `scripts/space/universe_panel.gd`, `scripts/space/space_markers.gd`, `scripts/ai/aggro_meter.gd` (drawn) | text scale: font and every size through the kit (steps 1, 4 of the recipe). Their own colours and plates are still hand-written: steps 2-3 when each is next touched |
| `scripts/loot/loot_builder_menu.gd`, `scripts/terrain/terrain_dev_menu.gd`, the disaster menu in `scripts/disasters/disaster_director.gd` (built) | on the kit: panel, theme, sizes (the disaster menu keeps its amber border) |
| `scripts/ai/callout_hud.gd`, `scripts/parts/character_builder.gd`, `scripts/parts/mech_loadout_screen.gd` (built) | sizes through the kit |
| `scripts/combat/combat_feedback.gd` | its damage numbers are `Label3D`s in the world, sized in metres: not screen text, left as they are |
| `scripts/parts/part_catalog_panel.gd` | no style of its own: it wears the asset workshop's |

`tools/probes/game_ui_probe.gd` checks the kit itself. A new screen starts on the kit.
