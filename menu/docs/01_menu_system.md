# menu/ — main menu, pause menu, options

A drop-in front end for a Godot 4 game: main menu, pause menu, a full options system with input
rebinding, and a layout contract that keeps all of it on screen at any window size.

Copy the `menu/` folder into another project, add two autoloads, point one project setting at a
host script, and it works. It has no dependency on anything outside itself — no game classes, no
`.tres`, no fonts, no textures.

---

## 1. What is in the box

| File | Role |
|---|---|
| `core/MenuHost.gd` | **The seam.** Every game-specific thing the menus need, as overridable no-ops. |
| `core/MenuSettings.gd` | Autoload. The settings **model**: one table, persistence, apply, signals. |
| `core/MenuManager.gd` | Autoload. Owns pausing — the trigger, the tree freeze, the mouse mode. |
| `core/MenuScreen.gd` | Base `Control` every screen extends. Builds the fit-safe scaffold. |
| `core/MenuFit.gd` | The overflow auditor + the layout helpers that make it pass. |
| `core/MenuTheme.gd` | The whole look, in code. Re-skin = edit the palette block. |
| `ui/MainMenu.gd/.tscn` | Front end. Buttons above Options come from the host. |
| `ui/PauseMenu.gd/.tscn` | In-run panel + three quick settings. |
| `ui/OptionsMenu.gd/.tscn` | Renders `MenuSettings`. Knows no settings of its own. |
| `ui/OptionRow.gd` | One settings row, built from one table entry. |
| `ui/KeybindRow.gd` | One rebindable action: two slots, capture, conflict resolution. |
| `ui/MenuModal.gd` | Confirmations and prompts — as a `MenuScreen`, never an OS popup. |
| `tests/menu_smoke.gd` | Model, persistence, rebinding, host seam, pause lifecycle. |
| `tests/menu_fit_smoke.gd` | The no-overflow proof across a resolution matrix. |

---

## 2. Porting it into another game

**1. Copy `menu/`.**

**2. Register two autoloads** (Project Settings → Autoload), in this order relative to any audio
system you have — `MenuSettings` creates the `Music`/`SFX`/`UI`/`Voice` buses if the project
ships no bus layout, so it should come before anything that looks them up:

```
MenuSettings   res://menu/core/MenuSettings.gd
MenuManager    res://menu/core/MenuManager.gd
```

**3. Set the main scene** to `res://menu/ui/MainMenu.tscn`.

**4. Add a `pause` input action.** Escape, plus gamepad Start. If you skip this, `MenuManager`
falls back to `ui_cancel` — which also means Back inside menus, so one Escape does two things.
A dedicated action is the supported configuration.

**5. Write a host** and point `menu/host_script` at it:

```gdscript
# res://game/MyMenuHost.gd
class_name MyMenuHost
extends MenuHost

func _game_title() -> String:
    return "MY GAME"

func _main_menu_entries() -> Array:
    return [{
        "label": "New Game", "primary": true,
        "action": func() -> void: get_tree().change_scene_to_file("res://game/Level1.tscn"),
    }]

func _apply_setting(id: StringName, value: Variant) -> void:
    if id == &"fov":
        # push it at your camera
        pass
```

Everything in `MenuHost` has a working default, so a project that stops at step 4 still gets a
main menu with Options and Quit, a working pause menu, and the entire engine-level settings set.

**6. Stretch settings.** For the interface scale slider to mean anything, the project needs
`display/window/stretch/mode = "canvas_items"` and `aspect = "expand"` with a base viewport size
(1920×1080 is a good default). Without it the UI is pixel-fixed and a 4K screen renders it tiny.

That base cuts both ways, and the module handles the other edge itself. On a screen *smaller*
than the base, `canvas_items` shrinks the UI by the same rule that grows it on a larger one — a
1280×720 window against a 1920×1080 base draws everything at 0.667×, so a 17px font lands on 11
device pixels and a 1px border on two thirds of one, and the whole interface reads as tiny and
soft. `MenuSettings._ui_scale_floor()` cancels exactly that shortfall through
`Window.content_scale_factor`, so the net scale never falls below 1.0 and small screens get
native-pixel UI in a smaller logical space instead of a shrunken one. It is inert at or above
the base resolution, and the interface-scale slider multiplies on top of it either way. The
smaller logical space is what §3's layout contract exists to absorb, and §3.4's matrix already
covers it down to 640×480.

**Removing settings you do not want** is deleting rows from `MenuSettings.DEFS`. The options
screen shrinks to match; nothing else needs touching. **Adding one** is a row in the table plus a
branch in your host's `_apply_setting`.

---

## 3. The layout contract — why nothing is cut off

Three mechanisms, and a test that proves they hold.

### 3.1 The scaffold

`MenuScreen` builds the same frame for every screen:

```
MenuScreen        full rect = exactly the viewport
└ Backdrop        flat fill, or a dim over the paused game
└ SafeMargin      page padding + safe-area inset, recomputed on every resize
  └ Frame         header · separator · body · footer
    └ Body        ScrollContainer, follow_focus = true      <- the escape valve
      └ content   whatever the screen builds
```

* **The body is always a `ScrollContainer`.** Content that does not fit becomes scrollable rather
  than clipped. No combination of text scale, interface scale, translated strings and window size
  can put a control out of reach.
* **`follow_focus` is on**, so moving focus with a gamepad or Tab scrolls the target into view.
* **Margins are recomputed from the live viewport**, not baked at build time — on resize, on
  interface-scale change, and on safe-area change.
* **Page padding scales with the smaller viewport dimension** (`MenuFit.page_padding`), clamped
  to 10–48px, so a 4K screen does not get 12px gutters and a 480p one does not lose a third of
  its width to them.

### 3.2 Rows that shrink

Nothing is allowed to force a container wider than the screen:

* `MenuFit.fit_label()` — shrinkable without going invisible. Godot drops a `Label`'s minimum
  WIDTH to 1 when `clip_text` is on or the overrun behaviour trims, which is the shrinking we
  want; but with autowrap *also* on it drops the minimum HEIGHT to 1 as well, and `Label`
  defaults to `SIZE_SHRINK_CENTER` vertically — so the container hands it one pixel and it
  renders nothing. The two modes therefore take different flags: a wrapping label gets autowrap
  alone (autowrap by itself already pins the minimum width at 1), a non-wrapping one gets the
  ellipsis alone.
* `MenuFit.fit_button()` — the same idea, same trap: `clip_text` takes a Button's minimum width
  down to its stylebox padding, and a Button in a BoxContainer defaults to `SIZE_FILL` without
  expand, so that is exactly what it gets — an empty rounded box. The floor goes back on as a
  `custom_minimum_size.x` of the text's natural width, capped at a share of the window so a row
  of buttons still cannot outgrow a small screen. `MenuScreen` re-runs `MenuFit.refit_buttons()`
  on each relayout, because that cap moves with the window.
* `OptionRow` gives the **editor** a small minimum (110px) and lets the **label** absorb the rest.
* Below `MenuFit.NARROW_WIDTH` (900px) rows **stack** — label above, editor below, full width —
  and the options tab bar becomes a dropdown.
* Fixed-width panels are capped by `MenuScreen.available_width()`, which subtracts padding, the
  safe-area inset and the **measured** scrollbar width. Sizing against the raw viewport width is
  how a 640px window with a 15% safe area on both edges ends up 200px short.
* **`header` and `footer` are `HFlowContainer`s, not `HBox`es.** Buttons carry a minimum width
  derived from their own text, and a row of them whose minimums exceed the screen has nowhere to
  go in a box container — it grows past the viewport and drags the entire scaffold with it. A
  flow container wraps to a second line instead.

### 3.3 The safe area

The game's `UISafeArea` autoload (if it has one) insets UI by transforming **CanvasLayers**. A
`Control` main scene has no CanvasLayer above it and is therefore missed entirely — so
`MenuScreen` applies the inset itself, but only when it is *not* already under a layer that got
the transform. Both halves matter: without the first, menus ignore the safe area; without the
second, a pause menu inside a CanvasLayer gets inset twice.

The four Interface-tab sliders drive `UISafeArea.set_insets()` when the autoload exists, and are
still honoured by the menus when it does not.

### 3.4 The proof

`MenuFit.audit(root)` walks the tree and reports every visible `Control` that lies outside its
nearest **clipping** ancestor — with one exemption: overflowing a `ScrollContainer` along an axis
that container can actually scroll is fine, because the player can reach it. Overflowing a
`clip_contents` panel, or a scroll container with that axis disabled, is not.

`tests/menu_fit_smoke.gd` builds every screen — and every options tab — inside a `SubViewport` at
each of nine sizes:

```
640x480   800x600   1024x768   1280x720   1366x768
1920x1080   2560x1080 (21:9)   3840x2160 (4K)   1080x1920 (portrait)
```

each at two settings profiles: defaults, and the punishing one (1.6× text scale with a 15%
safe-area inset on all four edges). For each it asserts:

1. `audit()` is empty — nothing unreachable,
2. `needs_horizontal_scroll()` is false — the layout fit the **width** without falling back to
   the horizontal escape valve. Sideways-scrolling menus are a failure to shrink, not a shrug.
3. `audit_collapsed()` is empty — every control carrying text is at least one line tall and
   wider than a sliver.

The third one exists because the first two are satisfied by a menu that renders **nothing**. A
label squashed to one pixel of height sits inside its container perfectly and passes every
overflow check ever written — and that is not hypothetical: `fit_label` once set autowrap,
`clip_text` and a trimming overrun together, which pins `Label.get_minimum_size()` at (1, 1), and
every wrapping label in the module drew nothing while the matrix stayed green. Fitting and being
visible are two claims, so they are two assertions.

```
godot --headless --path . res://menu/tests/menu_fit_smoke.tscn
godot --headless --path . res://menu/tests/menu_smoke.tscn
```

Both must print `0 failed`.

---

## 4. Settings

One table (`MenuSettings.DEFS`) drives persistence, the options UI, and the apply dispatch.
Values live in `user://settings.cfg`, section = tab id.

**Video** — display mode (windowed / borderless / exclusive), resolution, monitor, V-Sync,
frame-rate limit, field of view, render scale, upscaler (Bilinear / FSR 1.0 / FSR 2.2), MSAA,
FXAA, temporal AA, shadow quality, brightness.

**Audio** — Master / Music / SFX / Interface / Voice, mute all, mute when unfocused, output
device.

**Controls** — mouse sensitivity, aim sensitivity, invert Y, gamepad sensitivity X/Y, stick
deadzone, vibration, toggle-vs-hold for sprint / aim / crouch, and **full rebinding** of every
non-`ui_*` action.

**Gameplay** — default difficulty, language, subtitles + size, tutorial hints, pause when
unfocused.

**Accessibility** — interface scale, text size, colour filter (protanopia / deuteranopia /
tritanopia / monochrome) with strength, screen shake, reduce motion, reduce flashing, high
contrast UI.

**Interface** — safe-area inset per edge, HUD opacity, FPS counter, frame-time readout, menu
animations.

Rows marked `needs_rd` (render scale, upscaler, TAA) are **hidden** on the Compatibility renderer
rather than shown as controls that silently do nothing.

### Reading a setting from game code

```gdscript
var sens: float = MenuSettings.get_value(&"mouse_sensitivity")
var invert: bool = MenuSettings.get_bool(&"invert_y")     # NOT bool(get_value(...))
MenuSettings.changed.connect(func(id, value): ...)
```

`get_bool()` exists because GDScript's `bool()` has constructors for bool/int/float **only** —
call it on a String or a null and it does not return false, it raises and aborts the calling
function. A hand-edited `settings.cfg` containing `show_fps="true"` would otherwise take the
whole settings load down with it. `MenuSettings.truthy()` does the same job for a raw Variant.

### Rebinding

Keys are stored by **physical** keycode, so a binding made on AZERTY stays under the same finger
on QWERTY. Two slots per action (primary + alternate, which in practice is keyboard + gamepad).
Click a slot and press anything; right-click clears it. A key already used elsewhere raises a
conflict prompt that offers to clear the other binding. Only actions that differ from the
project's own defaults are written to disk, so changing a default binding in a later patch still
reaches players who never rebound that key.

---

## 5. Pausing

`MenuManager` owns it. `open_pause()` refuses when:

* there is no current scene,
* the current scene **is** a `MenuScreen`, or
* `MenuHost.pause_allowed()` says no — a level editor with its own Escape panel, a cutscene, a
  results screen that already paused the tree.

On open it records the mouse mode and the previous `paused` state; on close it puts both back.
`dismiss()` tears the menu down *without* restoring either, for when the thing behind it is going
away anyway (quit to menu, level reload).

Auto-pause on focus loss is on by default and controlled by the `pause_on_focus_loss` setting.

---

## 6. Deliberate choices worth knowing

* **Modals are `MenuScreen`s, not `AcceptDialog`/`Window`.** An OS popup is positioned in desktop
  coordinates: it ignores the safe area, ignores the interface scale, and on a small display can
  open partly off-screen — the exact failure this module exists to prevent.
* **Options is one screen with one behaviour**, opened as a scene from the main menu and as a
  child overlay from the pause menu. Two options screens are how "the sliders don't apply while
  paused" bugs happen.
* **The theme is code, not a `.tres`.** A copied folder cannot arrive with broken resource paths,
  and re-skinning is the palette block at the top of `MenuTheme.gd`.
* **The scrollbar is 10px and its width is measured, not assumed.** `MenuTheme._bar_box` exists
  because building scrollbars from the general-purpose `_box()` gave them its 12px content
  margins as *width* — a 24px bar that ate a chunk of every narrow screen.
* **`set_anchors_and_offsets_preset`, never `set_anchors_preset`.** The latter preserves the
  control's current size, so a Control created with `.new()` (size 0×0) stays 0×0 forever.
