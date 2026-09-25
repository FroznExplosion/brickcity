# Procedural Gun System — Borderlands-Style Part Assembly (Godot 4.6)

Spec status: implementation-ready. Companion scripts live in `scripts/`.

## 1. Research summary: the frictionless pipeline

The lowest-friction path from "existing 3D models" to "parts snapping together at runtime" is **named socket empties authored in Blender, exported via glTF, matched by string convention in Godot**. No custom importers, no plugins, no per-part scene editing in Godot.

Why this wins over alternatives:

- **Blender Empties → Godot Node3D.** Godot's glTF importer converts every Blender Empty into a plain `Node3D`, preserving its full transform (position *and* rotation — a commonly reported "rotation not imported" issue turned out to be users viewing gizmos in world space; the data imports correctly). This means attachment points are authored where the art is authored, once, and travel with the model forever.
- **Zero Godot-side setup per part.** Because sockets are found by name (`socket_*`) at runtime, adding a new barrel to the game is: model it, drop two empties, export GLB, register one Resource. You never open the imported scene.
- **Alternatives rejected:**
  - *Manually adding Marker3D nodes in Godot per part* — works, but it's per-part editor labor and desyncs the moment art is re-exported.
  - *Origin-at-connection-point convention (no markers)* — least data, but breaks down when a part has multiple connection points (a body has 4–6 sockets) and fights Blender's origin workflows. We keep it as a fallback only.
  - *Bone-based attachment* — the right tool for hands/holsters on animated rigs, overkill and more fragile for rigid gun parts.

## 2. Authoring convention (Blender)

1. **Model every part in its assembled pose.** Load a reference body, model the barrel where it would sit on that body, then move the barrel mesh to its own file/collection *without rotating it*. Because everything shares one "assembled" orientation, all empties can keep **identity rotation**, and alignment becomes trivial. (Rotated empties are fully supported — you only need them for radial mounts like side-rails.)
2. **On receiving parts (the body, mostly):** add one Empty per slot, named `socket_<slot>`:
   `socket_barrel`, `socket_stock`, `socket_grip`, `socket_magazine`, `socket_sight`, and on barrels: `socket_muzzle`, `socket_underbarrel`. Sockets can live on *any* part — assembly is recursive.
3. **On attaching parts:** add one Empty named `mount`, placed at the point that must coincide with the socket, as a direct child of the part's root object. If a part has no `mount`, the assembler falls back to treating the part's origin as the mount point.
4. **Export:** glTF 2.0 / GLB, +Y up (default). Apply scale (`Ctrl+A`) before export. Avoid `.` in object names (Godot sanitizes them).
5. One GLB per part. Filename = part id, e.g. `barrel_jakobs_long.glb`.

### Animated sockets (reload convention)

Reload clips live in the **receiver's** Blender file, and they animate the receiver's **socket empties**, not the attached parts:

- **Magazine drop/insert:** keyframe `socket_magazine` itself (translate down/out, back in). At runtime the attached mag is a child of that socket, so *any* generated magazine rides the motion for free — zero per-mag animation work.
- The same applies to any socket: keyframe `socket_barrel` for a break-action tilt, `socket_sight` for a flip-up, etc. Receiver-local motion (bolt, charging handle) is animated on the receiver's own meshes as normal.
- Empty/object animations export via glTF into the receiver scene's `AnimationPlayer`; track paths resolve to the imported socket `Node3D`s, so no runtime rewiring is needed.
- **Rest-pose rule:** every clip that touches a socket must start *and* end on the socket's rest transform (first/last keyframes identical), and the export should include a RESET action if you use one in Blender. A socket left off-rest after a clip permanently misaligns everything attached to it — this is the one way to break the snapping guarantee.
- Interrupted reloads: because misalignment is only a socket-transform issue, the weapon controller can cancel safely by calling the `AnimationPlayer`'s RESET animation (or `play_receiver_animation(&"reset")`) rather than snapping node transforms manually.

`tools/add_socket_empties.py` is a Blender helper: select an object, run it, and it adds correctly named empties at the 3D cursor.

## 3. Runtime architecture

```
GunPartDef (Resource)      one per part: slot, PackedScene, rarity, stat mods, manufacturer, tags
GunPartLibrary (Resource)  the catalog; query parts by slot/rarity/manufacturer
GunGenerator (static)      seed → recipe (slot → GunPartDef) + rolled rarity + name
GunAssembler (static)      recipe → assembled Node3D via recursive socket matching
GunStats (static)          base stats + part add/mult modifiers → final stat dict
GunInstance (Node3D)       the assembled gun in the world; owns seed, stats, muzzle lookup
```

Determinism: a gun is fully defined by `(library, seed)`. Recipes serialize to a small dict of part ids — this is what you sync over multiplayer or write to saves; never sync node trees.

### Assembly algorithm

1. Instantiate the BODY part scene; push it on a work queue.
2. Pop a part; `find_children("socket_*", "Node3D")` on it.
3. For each socket, parse the slot from the name suffix. If the recipe has a part for that slot and it isn't placed yet, instantiate it, `socket.add_child(part)`, then set `part.transform = mount.transform.affine_inverse()` (or IDENTITY if no mount). This makes the part's mount frame coincide exactly with the socket frame — no other math.
4. Push the new part on the queue (so barrels can receive muzzles, etc.). Empty sockets are simply left empty.

### Quality, naming and score

`GunGenerator`'s rarity/naming behaviour is specified in
[GUN_QUALITY_NAMING_SPEC.md](../GUN_QUALITY_NAMING_SPEC.md): parts roll a per-slot rarity
offset around the gun's tier, the resulting quality grade becomes the name's optional
first word, and the name schema is `[Grade] [Element] [Barrel] [Receiver]` — every word
derived, none random. Two authoring rules land on the part GLBs and their defs:
**BODY `name_fragment` must be a noun, BARREL `name_fragment` must be an adjective**, and
both are required (a `.tres` validator asserts this).

### Stat model (placeholder)

`GunStats.gd` is a stub combiner — the real stat/rarity model lives in its own spec. This system only guarantees the carrier: every `GunPartDef` has `stat_add` / `stat_mult` `Dictionary[StringName, float]` payloads, and the generator hands the full recipe + rarity to whatever combiner replaces `GunStats.compute()`.

### Behavior payloads (who owns what)

Presentation is owned by parts via typed def subclasses; game code only ever calls `GunInstance` hooks:

- **Receiver (`GunReceiverDef`, always Slot.BODY):** owns reload. The receiver GLB carries an `AnimationPlayer` (Blender actions export into it); the def names the reload clip plus optional logical extras (equip, inspect). Runtime: `GunInstance.play_reload() -> float` (returns clip length for ammo-refill timing) and `play_receiver_animation(&"equip")`.
- **Barrel (`GunBarrelDef`, always Slot.BARREL):** owns shot presentation — `shoot_sound` (AudioStream, per-shot pitch randomization), `muzzle_flash_scene`, `bullet_trail_scene`. Runtime: `GunInstance.play_shot_effects(hit_point)` plays sound at the muzzle, spawns the flash at the deepest muzzle socket, and spawns the trail in world space (`setup(from, to)` convention). Ballistics/damage stay in the weapon controller; this is presentation only.

Untyped `GunPartDef` remains valid for slots with no behavior (grips, stocks, mags, sights).

### GDExtension decision

**None of this system goes to C++.** Assembly is a few node instantiations and one inverse transform per part; generation is a handful of RNG rolls. GDExtension is reserved for per-frame bulk-data loops (voxel meshing, fluids). Future gun-adjacent candidates only if profiling demands: mass projectile/tracer simulation, mesh-merging large loot piles — and both should try MultiMesh/RenderingServer from GDScript first.

## 4. File manifest

| File | Purpose |
|---|---|
| `scripts/gun_part_def.gd` | Part metadata resource (base) |
| `scripts/gun_receiver_def.gd` | BODY def: reload / logical animation clips |
| `scripts/gun_barrel_def.gd` | BARREL def: shot sound, muzzle flash, trail |
| `scripts/gun_part_library.gd` | Catalog + weighted queries |
| `scripts/gun_assembler.gd` | Socket-based recursive assembly |
| `scripts/gun_generator.gd` | Seeded recipe generation, rarity, naming |
| `scripts/gun_stats.gd` | Stat combination |
| `scripts/gun_instance.gd` | Runtime gun node |
| `scripts/gun_forge_test.gd` | Debug scene: press R to reroll a gun |
| `tools/add_socket_empties.py` | Blender authoring helper |

## 5. Setup checklist (Godot side)

1. Copy `scripts/` into the project; class names auto-register.
2. Import part GLBs anywhere under `res://parts/`.
3. For each part, create a `GunPartDef` resource: assign slot, the GLB `PackedScene`, weight, rarity band, stat mods.
4. Create one `GunPartLibrary` resource; drag all defs into `parts`.
5. Drop `gun_forge_test.gd` on a Node3D in a test scene, assign the library, run, press **R**.

## 6. Deferred / out of scope for v1

- Per-part material/tint swapping by manufacturer (trivial extension: iterate MeshInstance3D and override materials post-assembly).
- Merging assembled parts into a single mesh for render perf (only needed if hundreds of world-dropped guns are visible; `MeshInstance3D` count per gun is ~5–8, fine as-is).
- Legendary fixed-recipe parts, elemental system integration (plugs into `stat_add`/`tags`).
