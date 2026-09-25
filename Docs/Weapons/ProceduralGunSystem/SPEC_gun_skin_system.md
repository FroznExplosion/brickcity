# Gun Skin System — Seamless Cross-Part Skins (Godot 4.6)

Companion to `SPEC_procedural_gun_system.md`. Adds cosmetics that flow across
any combination of parts without ever touching part assets.

## 1. Core idea

Skins never sample the parts' UVs for the pattern. Instead the pattern is
**triplanar-projected in gun-local space**: every vertex is transformed by its
part's *rest* transform relative to the gun root (captured once at assembly),
and that gun-space position drives the pattern lookup. Consequences:

- The pattern flows across part seams as if the assembled gun were dipped in it.
- Any skin works on any gun — past, future, mixed-manufacturer — because skins are pure data.
- Animated parts don't "swim": the rest transform is frozen per mesh at apply
  time (passed as instance uniforms), so the pattern is effectively painted on
  at assembly and sticks to the mag while it drops.
- Part UVs are still used for what they're good at: each part's baked **normal
  map** is carried over as a detail layer under the gun-level pattern.

The **manufacturer tint pass** is just the degenerate case: a `GunSkinDef` with
no pattern texture renders solid `palette_primary` (pattern defaults to black =
mask 0 everywhere), palette driven by the body's manufacturer. One system, two
use cases.

## 2. Data model

`GunSkinDef` (Resource) — one per skin:
- `pattern` (Texture2D, tileable): RGB = three mask layers, A = emission mask.
- `palette_primary/secondary/tertiary/accent` (Color): primary is the base;
  R/G/B channels of the pattern blend in secondary/tertiary/accent (CS:GO-style
  recoloring — one grayscale-ish mask texture, infinite colorways).
- `pattern_scale` (tiles per meter of gun), `blend_sharpness` (triplanar edge).
- `roughness`, `metallic`, `emission_color`, `emission_strength` (emission is
  gated by the pattern's alpha channel).

`GunSkinLibrary` (Resource): all skins + `manufacturer_defaults`
(`Dictionary[StringName, GunSkinDef]`) for the tint pass.

`GunSkinApplier` (static): walks every `MeshInstance3D` under the gun model
root, computes its rest transform relative to the root (works pre-`add_child`,
no tree needed), writes it as three `vec4` instance uniforms (basis columns,
origin packed in `.w` — Godot instance uniforms don't support `mat4`), and
assigns a `ShaderMaterial` per source material (cached, so surfaces sharing a
source share the override). If the source is a `BaseMaterial3D` with a normal
map, it's forwarded to the skin shader as the detail layer.

`GunInstance.apply_skin(skin)` is the runtime entry point; `create()` /
`from_result()` accept an optional `GunSkinLibrary` and auto-apply the body
manufacturer's default tint.

## 3. Shader contract (`gun_skin.gdshader`)

Install at `res://shaders/gun_skin.gdshader` (path constant in
`GunSkinApplier.SHADER_PATH` — change both if you relocate it).

- `vertex()`: reconstructs the part→gun transform from the three instance
  uniforms; outputs gun-space position + normal.
- `fragment()`: triplanar weights from the gun-space normal
  (`pow(abs(n), sharpness)`, normalized); samples the pattern on the three
  gun-space planes; palette blend `primary → secondary(R) → tertiary(G) →
  accent(B)`; `EMISSION = emission_color * strength * pattern.a`; detail
  normal via `NORMAL_MAP` with strength 0 when no map was forwarded.

Perf: one shader, ≤ a handful of materials per gun (one per distinct source
material), three texture fetches for the pattern + one detail normal. Not a
GDExtension candidate by any stretch.

## 4. Pattern texture authoring

- Tileable, 512–1024px. Author masks with hard-ish edges; triplanar blending
  softens them slightly.
- Channels: R = secondary-color regions, G = tertiary, B = accent, A = emissive
  regions (black alpha = none). Overlapping channels blend in R→G→B order.
- `pattern_scale` is in tiles-per-meter; rifles are ~0.8–1.2 m in gun space, so
  a scale of 2–4 reads well for camo, 8+ for fine patterns.
- Solid-color skins / manufacturer tints: leave `pattern` empty.
- sRGB import is fine for the pattern (it's sampled as `source_color`).

## 5. Runtime flow

```
result   = GunGenerator.generate(library, seed)
gun      = GunInstance.from_result(result, skin_library)  # auto manufacturer tint
gun.apply_skin(dropped_skin)                              # cosmetic swap, any time
```

Reapplication is idempotent — overrides are simply replaced. Skins serialize as
an id next to the gun's recipe dict.

## 6. File manifest

| File | Purpose |
|---|---|
| `shaders/gun_skin.gdshader` | Triplanar gun-space skin shader |
| `scripts/gun_skin_def.gd` | Skin resource (pattern + palette + surface params) |
| `scripts/gun_skin_library.gd` | Skin catalog + manufacturer defaults |
| `scripts/gun_skin_applier.gd` | Applies a skin to an assembled gun model |
| `scripts/gun_instance.gd` | Updated: `apply_skin()`, optional auto-tint |

## 7. Deferred

- Wear/float values (edge-wear mask lerp — add a curvature/AO bake per part later).
- Pattern seed offset per gun (randomize pattern placement: add a gun-space
  offset uniform, trivially).
- Stickers/decals (separate decal projector pass).
