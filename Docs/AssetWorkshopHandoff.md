# Asset workshop block-out: handoff (2026-10-20)

For the next chat picking up the asset workshop's SDF block-out (the gun workshop's
Sculpt tool). The full record is `Docs/AssetWorkshop.md`, sections from "The SDF block-out"
(2026-10-18) to "Models as objects, pieces as parts, spawning at the grid" (2026-10-20).
Read those before changing anything.

## Where things are

- **Worktree** `C:/Users/lbaun/bc-sdf`, branch `sdf-sculpt`. Everything is merged into
  `main` and pushed (last merge 44019a6). Main's DLL was rebuilt after the last C++ change.
- **Rule from the user:** write the plan into `Docs/AssetWorkshop.md` BEFORE implementing.
  Never remove the 2D Sketch tool. Gun sizes stay as they are (an SMG 53 studs) for now.

## What the block-out is

A 3D signed distance field (C++ `SdfForm`, `gdextension/brick/src/sdf_form.*`) sculpted in
the workshop; **Convert** turns it into bricks (default) plus custom smooth pieces where
marked smooth; **Edit as SDF** goes back 1:1. One sample a tick: a stud is 5, a plate 2.

| File | What |
|---|---|
| `scripts/asset_workshop.gd` | the workshop (huge). Sculpt input `_sculpt_input`, `sculpt_convert`, models, size marks, game view: search "Round 4" and "Models as objects" |
| `scripts/asset_sculpt.gd` | `AssetSculpt`: a field drawn (block meshes, cursor, ghosts). The block-out is one; each model object is another |
| `scripts/model_mesh.gd` | `ModelMesh`: reads glTF/GLB/FBX (skinned meshes posed by hand), OBJ, STL; `read_pieces` |
| `scripts/model_gizmo.gd` | `ModelGizmo`: arrows move, rings turn, cube resizes (2x per 200 px) |
| `scripts/fit_kit.gd` | `FitKit`: slopes/wedges/curves sampled for `SdfForm.fit_pieces`; `mirror_name` |
| `tools/asset_workshop_probe.gd` | 288 checks; `tools/sdf_form_probe.gd` 38 |

## Built, newest first

- **Models as objects** (2026-10-20): each imported model keeps its own field; sculpt mode
  "models: pick and move" or the models list selects one (gizmo back); pieces get a part
  picker each; Convert joins models in (`SdfForm.combine`) and takes them out after; "bake
  into SDF"; every model change one undo; saved in `meta.asset.models` (file path + xf).
  Spawn fix: `build_centre` counts field + models while sculpting.
- **Symmetric Convert** with the mirror on (Alt S, plane across z): near half mirrored,
  2-stud bricks bridge the middle, plane kept on a stud line; "centre on mirror".
- **Nudges** half / one stud each way, **snap to studs**, `SdfForm.move`.
- **Gun size marks**: ruler from the butt (SMG 53.25 studs = 852 mm real, 213 mm print),
  the shared grip box from `Docs/Parts/standards.json` `held_grip`; class picker.
- **Game view** Alt C: camera as `PlayerView` frames a held gun (class VIEW_LENGTH, HIP,
  RMB = ADS).
- Earlier: Sculpt (3D, Alt V) / Sketch (2D, Alt D) split; fitted pieces; wedges; lathe.

## Known gaps / next ideas

- Brush strokes act on the block-out only; to carve a model, bake it. Bricks deleted inside
  an unbaked model come back at the next Convert.
- (Fixed 2026-10-20: a second model spawns beside the others on +z, two studs clear; undo
  keeps the selected model picked.)
- Mirror plane is across z only (a model symmetric left-right seen from the front must be
  turned a quarter first).
- Corner slopes impossible until shapes other than prisms (ShapedSampler, print profiles).
- Planned next in the doc: move/grab of sculpted parts, selecting a piece; maybe the gizmo
  on F3 guides.
- Building-sized models: not built; what it would take is in the doc (C++ chunked Convert,
  chunked stamping, distance levels).
- The 2x-studs cost table is in the doc ("Symmetric Convert, and what a bigger gun costs");
  the user decided to keep sizes for now.

## Working notes

- Write patches as Python files with `patchlib.py`-style exact replacements; files are CRLF.
- After `git merge main`: rebuild the worktree DLL (`python -m SCons` in
  `gdextension/brick`) and run `--headless --path . --import` before probes; a parse error
  makes a run hang, so grep the import output first.
- Main's DLL must be rebuilt after a C++ merge, editor closed. Another chat may be building
  godot-cpp through the junction: if `godot-cpp/bin` is empty, wait for its `cl.exe` to stop.
- Windowed passes: `-- --shot --sculpt [--stamps|--convert]`, `-- --shot --model [--gameview]`.
  Check the heat log after (`python tools/heat_sum.py --last 6`); the last run hit 100 C with
  other chats' probes going -- don't start another windowed run above 80 C.
- Headless test helpers that use the workshop scene must set `_no_autosave = true` and the
  probe's hotbar/toolbar paths so they never write the user's files.
