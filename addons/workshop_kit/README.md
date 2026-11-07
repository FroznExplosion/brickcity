# workshop_kit — the parts of an in-game editor, for any Godot 4 project

The tools a block or grid editor needs, written once: undo, and (as it grows) a tool
interface, the editor camera, a mirror plane, a grid, a ghost, the editor frame. Printed Brick
City's two workshops (the building workshop and the asset workshop) are built on it; its plan
is in that game's `Docs/BuildTools.md` section 20.

**No game class inside.** Nothing in this folder names a class, scene or resource outside it.
What an editor's cells *are* (bricks, voxels, tiles) stays in the editor that uses the kit.

Version: see `VERSION`. Raise it with every change to this folder.

---

## 1. What is in the box

| File | Role |
|---|---|
| `core/wk_command.gd` | `WkCommand` — one edit: `undo()`, `do()`, `can_redo()`, `merge(next)`, `kind`, `data`. `WkCommand.make(kind, data, undo_fn, do_fn)` for an editor that keeps the logic itself. |
| `core/wk_group.gd` | `WkGroup` — commands that undo as one; `tail` commands (snapshots) run after the edits both ways. |
| `core/wk_undo_stack.gd` | `WkUndoStack` — the one history: `push`, `undo`, `redo`, `begin_group` / `end_group`, `group_last(n)`, `forget_where`, `busy`. |
| `core/wk_context.gd` | `WkContext` — **the seam**: everything a kit tool asks the editor, each a method with a neutral default. An editor extends it. |
| `core/wk_tool.gd` | `WkTool` — a tool: `activate(ctx)`, `deactivate()`, `input(e) -> bool`, `process(dt)`, `options_ui()`, `hint()`. |
| `core/wk_toolbox.gd` | `WkToolbox` — the tools and which one is in hand: `add`, `use(id)`, `input`, `process`. |
| `services/wk_sketch_pen.gd` | `WkSketchPen` — a stroke on a plane: freehand, brush, rectangle, ellipse, polygon; its outline, brush entry, cells, preview lines. |
| `services/wk_shapes.gd` | `WkShapes` — shapes on a grid as cells: rectangle, hollow, circle, ring, triangle, line, arch, stairs, wall lines, outlines, plans; the three lies (flat, wall_x, wall_z). Static. |
| `services/wk_camera.gd` | `WkCamera` — the editor camera: orbit (MMB orbit, Shift pan, wheel to the cursor), FPS (the editor's own fly), flat orthographic views zoomed at the cursor. |
| `services/wk_mirror.gd` | `WkMirror` — the mirror plane: on, across X or Z, where; a cell's and a direction's mirror image. |
| `tools/wk_sketch_tool.gd` | `WkSketchTool` — Sketch: draws with the pen, asks the context where (`sketch_begin`, `sketch_point`) and hands the stroke over (`sketch_commit`). |
| `tools/wk_paint_tool.gd` | `WkPaintTool` — Paint: a stroke as one undo, an eyedropper, the brush's reach; asks `paint_begin`, `paint_at`, `paint_end`, `paint_hover`, `paint_pick`, `paint_step`. |
| `tests/wk_smoke.gd` | Everything above, headless, on a pretend document and a pretend context. |

Coming, in this order (Docs/BuildTools.md §20): the rest of the shared
tools one file each, `WkGrid`, `WkGhost`, `WkFrame`.

## 1b. A tool in an editor

```gdscript
class_name MyContext
extends WkContext
func sketch_begin(_remove): return "top"            # the plane a stroke lies on (null: refuse)
func sketch_point(_plane): return cursor_on_plane()  # Vector2 in plane cells, or null
func sketch_commit(_plane, pen): fill(pen.entry("top", 1, false))

var box := WkToolbox.new()
box.ctx = MyContext.new()
box.ctx.undo_stack = undo
box.add(WkSketchTool.new())
box.use(&"sketch")
# in _unhandled_input:  if box.input(event): return
```

## 2. Undo in five lines

```gdscript
var undo := WkUndoStack.new()

func paint(cell, colour):
    var was = colours[cell]
    colours[cell] = colour
    undo.push(WkCommand.make(&"paint", [cell, was, colour],
        func(c): colours[c.data[0]] = c.data[1]; return true,     # undo
        func(c): colours[c.data[0]] = c.data[2]; return true))    # redo
```

* **Push after the edit.** The editor does the work, then records how to take it back.
* **No redo function = can't be redone.** Undoing such a command forgets the redo list, so
  redo never jumps over it.
* **`busy`.** While a command is undone or done again, `push` is ignored: the edit functions it
  calls to put things back do not record themselves twice. Call `forget_redo()` from any edit
  that records nothing of its own (it is ignored while busy too).
* **Groups.** `begin_group()` … `end_group()` around a gesture, or `group_last(n)` after the
  fact (a click and the run it began). `end_group(true)` flattens groups made inside it.
  `tail`: a snapshot command that must run after the group's edits both ways.
* **Strictly last in, first out.** An editor whose records are numbered in the order they were
  made can rely on undo never reaching past a newer edit. If something is removed from the
  middle by other means, `forget_where(pred)` drops the commands that made it -- or give the
  command an `alive_fn` (fifth argument of `make`): undo skips a command that is no longer alive,
  so Z never does nothing, and one whose thing comes back (an undo laid it back) is alive again.
* **A command keeps its place while it runs**: during its `undo`/`do`, `leaves()` still lists it,
  so an editor renumbering what the history holds reaches the commands of a group not undone yet.
* **`on_empty`.** Undo with nothing left calls it, if set, to take back one more thing that has
  no command of its own -- the records of a document as it was opened, one per Z, without
  creating thousands of commands on open. It returns a command that redoes it, or null.

## 3. Porting it into another project

1. Copy `addons/workshop_kit/` into the project (or bring it in with `git subtree`, below).
2. Run the project once (or `godot --headless --path . --import`) so the `Wk…` class names are
   registered.
3. Check it: `godot --headless --path . --script res://addons/workshop_kit/tests/wk_smoke.gd`
   (exit 0, "0 failed").

There is no autoload, no project setting and no plugin to enable: the classes are used from
code. It is under `addons/` because that is where drop-in folders go, not because it is an
editor plugin.

## 4. Keeping it in sync between projects

One copy of the kit is the master, in its own git repository; every project carries the kit
as ordinary committed files under `addons/workshop_kit/` and trades changes with the master
through **`git subtree`**:

```
# once, in the project
git remote add kit <url of the kit repository>

# take the kit's changes
git subtree pull --prefix addons/workshop_kit kit main --squash

# send this project's changes to the kit back
git subtree push --prefix addons/workshop_kit kit main
```

Why subtree and not a submodule: the files are plain files in each project, so a clone, a
worktree or an export needs no extra step, and Godot sees them as it sees any other script. A
submodule needs `git submodule update` in every clone and worktree, and breaks in worktrees
reached through a junction (Printed Brick City's godot-cpp did).

**Splitting the master out** (the first time a second project wants it), from the project
that has it:

```
git subtree split --prefix addons/workshop_kit -b workshop-kit
git push <url of a new empty repository> workshop-kit:main
```

Rules that keep two projects from drifting:

* Change kit files only in a commit of their own (no game files in it), so `subtree push` sends
  clean history.
* Raise `VERSION` in that commit: patch for a fix, minor for something added, major for a
  change that makes an editor using the kit change too.
* Nothing game-specific goes in. If the kit needs to ask the game something, it asks through
  the context object (`WkContext`, coming in stage 2) with a neutral default.
