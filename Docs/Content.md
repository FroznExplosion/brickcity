# Content packs: the game, DLC and mods

Where content lives, and how a mod or a DLC adds to it without touching the
game's folders. Code: `scripts/core/content_packs.gd` (`ContentPacks`). Probe:
`tools/content_packs_probe.gd`.

## 1. The rule

**A pack is one folder that holds everything it adds.** The game itself is a
pack. A DLC is a pack. A mod is a pack. All three have the same sub-folders, and
every library in the game reads the same sub-folder of every pack, so content
in a pack shows up wherever the game's own does: the workshop's Open list, the
item catalogue, the part catalogue, the brick palette, the world list.

Nothing is copied out of a pack and nothing is registered anywhere else. Delete
the folder and the content is gone.

| Kind | Where | Who |
|---|---|---|
| `base` | `res://content/base/` | the game |
| `dlc` | `res://content/<id>/` (in the project, or a `.pck` shipped beside the game) | us |
| `mod` | `user://mods/<id>/` (a folder), or `user://mods/<id>.zip` / `.pck` | anyone |
| the player's own work | `user://builds/`, `user://items/` ... | the player |

Read in that order. `user://` is
`%APPDATA%\Godot\app_userdata\Brickcity\` on Windows.

## 2. Inside a pack

```
<id>/
  pack.json        what it is (below)
  builds/          buildings                       *.json, sub-folders allowed
  rooms/           rooms, in a sub-folder a room kind
  items/           furniture and items (mugs, books, chairs)
  guns/            guns: a build (*.json) or an exported folder (<id>/gun.json)
  mechs/           mechs
  figures/         characters
  parts/           gun and mech parts: <family>/<part id>/part.json + part.scn + thumb.png
  bricks/          brick definitions, *.json (section 4)
  worlds/          terrain worlds, *.json
  data/            tables: asset_tags.json, ai/roster.json, ai/tactics_book.json
  planets/ characters/ audio/ textures/      reserved (section 6)
```

`pack.json`:

```json
{
	"format": 1,
	"id": "my_mod",
	"name": "My Mod",
	"version": "1.0",
	"author": "Someone",
	"description": "Girders and a coffee mug.",
	"requires": ["base"]
}
```

- `id` must be the folder's name: lower-case letters, digits and `_`.
- `requires` lists pack ids. A pack whose needs are not installed is left out
  (and so is anything that needed it).
- `format` is the pack format (`ContentPacks.FORMAT`). A pack made for a newer
  format is left out rather than half read.
- A pack that is left out says why: `ContentPacks.rejected()`.

A player switches a mod off without deleting it: `ContentPacks.set_enabled(id,
false)`, kept in `user://mods/packs.cfg`. `ContentPacks.mods()` lists every mod
found, on or off, for a mods screen (not built yet).

## 3. Names that meet

- **A file** of the same name in two packs: the later pack's is the one used
  (`ContentPacks.resolve("worlds/city.json")`), exactly as a player's build with
  a shipped build's name has always replaced it.
- **A table** (tags, and later any registry): every pack's copy is read and
  merged (`ContentPacks.every("data/asset_tags.json")`). A mod's
  `data/asset_tags.json` adds values to a level the game has (a new planet) or
  adds a level.
- **A part or a brick** the game already has is never replaced by a mod. Builds
  name their bricks; a build must mean the same bricks with or without a mod.
- **Ours and theirs**: a DLC's gun and mech parts are `official`; a mod's are
  `custom` whatever its files say (and so need a `creator.name`).

## 4. Bricks from a pack

`bricks/*.json` adds parts to the brick palette (`BrickPalette`), so they are in
the workshop's brick menu with the game's:

```json
{
	"parts": {
		"girder_1x5": {"size": [1, 3, 5]},
		"tile_3x3":   {"size": [3, 1, 3]},
		"slope_2x6":  {"size": [2, 3, 6], "shape": {"kind": "slope", "axis": "x"}}
	},
	"categories": [["Girders", ["girder"]]]
}
```

- A name is `<family>_<W>x<L>`, W <= L. `size` is `[W studs, H plates, L studs]`
  (H 1 is a plate, 3 a brick). The name must end with the size it states.
- The family decides studs and sockets as it does for the game's parts: a
  `tile_` has no studs, an `undertile_` no sockets, a `bracket_` side studs.
- `shape.kind` is one `ShapedParts` makes: `slope`, `curve` (with `axis` x or
  z), `wedge`, `slope_corner`, `round`, `arch`.
- `categories` adds a browsing group, or adds families to one the game has. A
  family in no category is listed under "Other", never hidden.
- Pack bricks are baked after the game's, so no archetype of the game's is
  renumbered by installing a mod (the probe checks this).

Items (mugs, books, furniture) are not bricks: they are builds in `items/`,
tagged in the asset workshop, and already appear in the item catalogue.

A brick with a new *shape* (its own mesh) is not possible from a pack yet: that
is the custom pieces work in `Docs/Parts/custom.md`.

## 5. What reads packs today

| Content | Read by | Pack folder |
|---|---|---|
| buildings, rooms, items, guns, mechs, figures (builds) | `BuildRecipe.library(kind)` -> workshop Open, city placer, `RoomTemplates`, `RoomModules`, `AssetCatalog` | `builds/ rooms/ items/ guns/ mechs/ figures/` |
| gun and mech parts | `PartCatalog.load_all()` | `parts/` |
| exported gun folders | `AssetGuns.all()` | `guns/<id>/gun.json` |
| bricks | `BrickPalette` | `bricks/` |
| terrain worlds | `TerrainWorld.world_path`, `list_worlds` | `worlds/` |
| asset tags (planet, type, room) | `AssetTags` | `data/asset_tags.json` |

Base only for now (the path is under `content/base/`, no merge yet):
`data/ai/roster.json`, `data/ai/tactics_book.json`.

## 6. Not built yet

Each of these is code today, not data, so a pack cannot add one until its
registry reads packs. The folder names are reserved so packs made now stay valid.

| Content | Today | To open it to packs |
|---|---|---|
| Planets, star systems | generated in `scripts/planet/`, `scripts/space/` | `planets/*.json`: biome and system definitions read by `PlanetData` / `StarSystem` |
| Gun classes, receivers, barrels, legendaries, skins | tables in `scripts/guns/`, `scripts/loot/` | `data/guns/*.json` merged into `GunPartLibrary`, `LegendaryTable` |
| Enemy types and tactics | one exported roster and book | merge every pack's `data/ai/*.json` by type id |
| Characters | `figures/` builds are read; the lobby and `character.json` name none from packs | a character manifest in `characters/` |
| Audio | none: every sound is synthesised in code, there is not one audio file | `audio/` plus a sound table by event name |
| Materials, textures | `textures/pbr/` and fixed shader lists (`Docs/PbrWood.md`) | `textures/` plus a material table; needs shader work |
| Disasters, creatures | scripts | data tables |
| A mods screen | `ContentPacks.mods()`, `set_enabled`, `rejected()` exist | a menu page |

## 7. Safety

- A **folder** mod is data: JSON, and part scenes. A part scene (`part.scn`) can
  carry a script, and so can a `.pck`. Before mods are downloaded from
  strangers (a workshop, a server sending parts), part scenes from packs need
  the same check downloaded parts get, and `.pck` mods should be off unless the
  player allows them.
- A `.zip` or `.pck` is mounted without replacing any file the game has, and
  only under `content/<its id>/`. An archive named like a pack the game ships
  is refused.

## 8. Shipping a DLC

Author it in the project as `content/<id>/`, then either leave it in the main
export or export that folder alone as `<id>.pck` and load it at start (the same
mount a mod archive gets, from the game's folder instead of `user://mods/`:
not wired yet, one line when the first DLC exists).

When export presets are made: JSON is not a Godot resource, so the preset must
include `content/*` as non-resource files (and `Docs/Parts/standards.json`,
below), or the exported game has no content.

## 9. The audit (2026-11-11)

What was found when the project's folders were gone through, and what was done.

**Loose models, audio, textures.** There are none to speak of. No `.glb`,
`.fbx`, `.obj`, `.blend`, `.wav`, `.ogg` or `.mp3` is in the project. Textures:
nine PBR maps in `textures/pbr/` (in use), fifteen part thumbnails beside their
parts, reference photos in `Docs/Planets/` (kept from Godot by a `.gdignore`).
Models and print files are in `Documents\brickcity-print`, outside the project.

**Moved** (into the base pack):

| Was | Now |
|---|---|
| `builds/`, `guns/`, `mechs/`, `parts/`, `worlds/` | `content/base/<same>/` |
| `data/asset_tags.json`, `data/ai/` | `content/base/data/` |
| `Docs/please rename/` (a reference shader and script Godot was importing) | `Docs/Reference/printed-plastic/`, with a `.gdignore` |
| `tools/brickify/__pycache__/*.pyc` (tracked by mistake) | removed, ignored |

**Found, left alone, worth doing** (each is its own change; the first two touch
every chat's branch, so they want a quiet moment):

1. **`user://` is flat.** Settings, the character, eight libraries, workshop
   layouts, tallies, shots and about forty probe leftovers (`_probe_*`,
   `_t.obj`, `zz_*.png`) share one folder, 171 MB. Proposed:
   `user://library/` holding the player's own work *as a pack* (same folders, so
   sharing your builds is zipping it), `user://profile/` (character),
   `user://workshop/` (layouts, autosave, quick save), `user://exports/`,
   `user://dev/` (probe files, shots, test saves). Needs one path table
   (`UserPaths`) and a one-time move of existing files.
2. **`scripts/` has 121 files at its top and `tools/` 255.** The top of
   `scripts/` is mostly four groups that already have a name: build/workshop,
   terrain and water, rooms and interiors, rendering. `tools/` mixes probes,
   generators (`make_*`), the brickify Python and look tools. Scripts find each
   other by `class_name`, so moving them is safe for code; it is the forty open
   worktrees that make it costly.
3. **`Docs/Parts/standards.json` is game data in the docs folder.** The game
   reads it at run time (`PartStandards`), and so do the Python print tools, so
   it stayed. It belongs in `content/base/data/`.
4. **Three homes for tests**: `tools/*_probe.gd`, `test/` (weapons), and
   `menu/tests/`. And three for effects code: `fx/`, `autoload/`,
   `scripts/effects/`, `scripts/elements/`.
5. **`shots/` (86 MB, untracked) has no `.gdignore`**, so Godot imports every
   screenshot in it. It cannot be committed (the folder is git-ignored): add
   the file by hand in each checkout, or have the shot code write it.
6. **`addons/zylann.voxel` (13 MB)** is used only by the planet graph
   (`scripts/planet/planet_body.gd`, `planet_graph.gd`, `planet_walker.gd`).
   Fine while that is so; worth knowing it is the whole reason it is here.
7. `scripts/upload_ledger.gd.uid` and `tools/flashlight_probe.gd.uid` are
   untracked in the main folder: their scripts were committed without them.
