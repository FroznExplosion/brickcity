# Printed-Plastic Look: Layer Lines & Bevels

Oct 15, 2026 · @Lukas Baune

## Summary

Use analytic bead tracing for layer lines and shader-only fake bevels, not texture-based parallax occlusion mapping (POM). Because a layer stack is a simple periodic shape along a known axis, the shader solves the ray hit exactly with 1–6 circle tests, with no steps, textures or UVs.

The shader `printed_plastic.gdshader` (Godot 4.6) does five things:

- Traces the view ray against the bead stack for real occlusion close up.
- Self-shadows each bead from its neighbours, per light, with a soft penumbra.
- Bends normals toward brick and stud edges to fake bevels, faded out with camera distance.
- Adds diagonal top-skin lines on upward faces and a smoother bed side on downward faces.
- Steps down through three LOD tiers by on-screen layer size so far walls don't shimmer.

It compiles and renders in Godot 4.6 (tested on the Compatibility renderer). A companion script, `printed_brick_test.gd`, builds a test brick that carries the per-brick data the shader expects.

&#91;image: Test render: a brick corner up close, layer lines wrapping around the fake bevel\]

&#91;image: Test render: top face with diagonal top-skin lines and bevelled stud rims\]

Test renders from Godot 4.6 (Compatibility renderer, no AA): the corner bevel with layers wrapping it, and the top-skin lines with rounded stud rims.

## Scale and why plain POM falls short

At minifig scale the layer lines are big on screen, so depth effects matter, but generic POM handles them poorly.

| Quantity | Value |
| --- | --- |
| Brick height incl. stud | \~11.3 mm (9.6 body + 1.7 stud) |
| Layers per brick side | 57 |
| Layer height | \~0.198 mm |
| Player height | \~4 bricks, \~230 layers |
| Groove depth | \~0.35–0.5 of layer height (rounded beads, sharp cusps) |
| On screen, player filling 1/3 of 1080p | \~1.5 px per layer at player distance; several px beside the camera; sub-pixel across the street |

The deep grooves make occlusion and self-shadowing visible, especially at grazing angles, which city streets produce constantly. Plain texture POM struggles with this:

- Grazing views of 57 tight ridges need high step counts, or they band and stair-step.
- It needs UVs, tangents and a heightmap on every procedural part.
- It never changes silhouettes.

## Analytic bead tracing

The profile only varies along the print axis, so the 3D problem collapses to a 2D slice through the surface normal and the print axis. In that slice every layer is a circle, and the hit is solved exactly.

1. Normalise the slice: depth x runs 0–1 across two groove depths, height y counts layers. Each bead becomes a circle of radius 0.5 centred at (0.5, k + 0.5); this also turns squashed (elliptical) beads into circles.
2. Project the view ray into the slice. Its slope is M = 2 × groove\_depth\_ratio × (view along layers) / (view into the wall).
3. Starting at the bead under the pixel, test beads in the ray's direction. Bead k is hit at the smaller root of the quadratic below, with Y = y0 − (k + 0.5). The first root in 0–0.5 is the visible surface.
4. The normal is the ellipse gradient at the hit point, rebuilt in view space from the base normal and the up-the-layers tangent.

```latex
(1 + M^2)\,x^2 + (2YM - 1)\,x + Y^2 = 0
```

The ray must hit by depth 0.5, so at most |0.5 M| + 1 beads are tested, capped by `max_trace_beads` (default 6).

**Micro self-shadow.** In `light()`, the light direction is projected into the same slice. From the hit point, the ray toward the light is tested against the next three beads on its way out. Distance to each bead's centre below 0.5 means shadow; `micro_shadow_softness` sets the penumbra width.

**Cavity darkening.** Hit depth also darkens ambient light in the grooves via AO. In the mid tier, where there's no micro-shadow, AO also partly darkens direct light.

## Fake bevels

Bevels are shading only: the normal bends toward the nearest brick edge inside a band of `bevel_width`, so edges catch a soft highlight with no extra geometry.

- **Box bricks.** Each vertex carries its brick's centre and half extents. The offset from the inner box (shrunk by the bevel width) gives the bent normal: face normal mid-face, 45° at an edge, the corner diagonal at a corner. It's continuous across faces, so there's no seam.
- **Studs.** A cylinder mode rounds the top rim only. The base is a concave joint and gets no bevel.
- **Eased start.** The bend ramps in with a smoothstep, so there's no visible crease where the bevel begins.
- **Layers wrap the corner.** Layer tracing runs on the bevelled normal, so lines flow around rounded vertical corners.
- **Brick seams for free.** Rounding each brick separately makes the seam between stacked bricks show.
- **Safety check.** If the stored brick data doesn't describe the surface, the shader falls back to the mesh normal.

**Close-only fading.** Bevels fade out between `bevel_fade_start` (6) and `bevel_fade_end` (12) world units of camera distance. They also drop out before going sub-pixel to avoid aliasing. Setting `bevel_min_pixels` above 0 switches to the alternative: a thin highlight kept at every distance, which helps mid-distance buildings read as bricks.

Limits: silhouettes stay sharp, and only convex edges are bevelled.

## LOD tiers

The tier is picked per pixel from layers per pixel (`fwidth` of the layer coordinate), not camera distance, so it adapts to resolution, FOV and viewing angle. Tiers blend smoothly.

| Tier | Layers per pixel (default) | What runs |
| --- | --- | --- |
| Trace | below 0.12, fading out by 0.25 | Bead tracing, micro self-shadow, cavity AO |
| Bump | up to 0.3, fading out by 0.6 | Bead normal at the pixel (no occlusion), cavity AO on ambient and partly direct light |
| Far | above 0.6 | Flat surface with anisotropic GGX: smooth along the layers, rougher across them (`far_roughness_across`) |

The far tier keeps the streaky sheen real prints show at a distance without drawing a single line, which is what prevents moiré. Per-layer colour variation and cavity AO fade with the bump tier for the same reason.

With the defaults, full tracing shows on walls within a few bricks of the camera. Walls at the player's distance sit in the bump tier. Loosen `trace_lod_end` if you want tracing further out.

## Print details

A few surface cues separate a printed part from a molded one; the shader covers the first three.

- **Top skin (done).** Upward faces show diagonal extrusion lines at about 0.45 mm spacing (`top_line_width`), as a gentle normal ripple that fades when sub-pixel.
- **Bed side (done).** Downward faces were printed against the bed, so they're smoother: roughness is scaled by `bed_side_roughness_scale`.
- **Layer colour variation (done).** Each layer gets a tiny brightness wobble from its index (`layer_color_variation`), like real filament.
- **Slopes (not yet).** Layers on sloped and curved parts become visible stair-steps, the most recognisable printed look. They need a tilted staircase profile; right now layer lines fade out as a surface tilts toward horizontal.
- **Z-seam (not yet).** A faint vertical stripe of small blobs where each layer starts. It would be a cheap per-part detail placed at a stored seam angle.
- **Elephant's foot (not yet).** A slight chamfer on the bottom edge matches the compensation people print with.

## Using the shader

To try it, add `printed_brick_test.gd` to a MeshInstance3D, give it a ShaderMaterial using `printed_plastic.gdshader`, and tick `use_vertex_brick_data`. For a plain BoxMesh, leave it unticked and set the fallback box uniforms instead.

**Units.** Defaults assume 1 model unit = 1 stud pitch (8 mm), so `layer_height` = 0.02478. If your units differ, set it to brick height with stud ÷ 57.

**Data contract for merged chunk meshes.**

| Channel | Box brick | Stud |
| --- | --- | --- |
| CUSTOM0.xyz | Brick centre, model space | Stud centre (mid-height) |
| CUSTOM0.w | 1 | 2 (0 = no bevel) |
| CUSTOM1 | Half extents xyz | Radius, half height |
| COLOR | Per-brick tint | Per-brick tint |

Bricks in a chunk only rotate in 90° steps about Y, so store the already-rotated, axis-aligned extents. In GDExtension, use ArrayMesh with the CUSTOM0/1 channels in RGBA\_FLOAT format. Debris bricks that break loose keep working, since their own model space is the brick space.

**Key parameters.**

| Parameter | Default | Effect |
| --- | --- | --- |
| `print_axis` | (0, 1, 0) | Build direction in model space; match the STL export orientation |
| `groove_depth_ratio` | 0.35 | Groove depth ÷ layer height; 0.5 = round beads |
| `micro_shadow_softness` | 0.08 | Penumbra width of bead shadows |
| `cavity_strength` | 0.35 | Groove darkening |
| `bevel_width` | 0.05 | Bevel band on each face, model units |
| `bevel_fade_start` / `bevel_fade_end` | 6 / 12 | Camera distance where bevels fade out |
| `trace_lod_end` / `bump_lod_end` | 0.25 / 0.6 | Layers per pixel where each tier ends |
| `far_roughness_across` | 0.6 | Far-tier roughness across the layers |

**Debug views** (`debug_view`): 1 = LOD tiers (red trace, green bump, blue far), 2 = normals, 3 = bevel mask. All are unlit.

## Limits and next steps

The shader is tested on Godot 4.6's Compatibility (OpenGL) renderer only; Forward+ is the first thing to confirm.

- **Forward+ check.** Nothing in it is Compatibility-specific, but verify the `light()` output and fragment-to-light varyings match.
- **Antialiasing.** Test renders had no MSAA or TAA, so the bump-to-far handoff shows light moiré. Tune the LOD thresholds with your real AA on.
- **Silhouettes.** Godot 4 has no tessellation, so brick edges against the sky stay square. Real layered geometry for the nearest bricks could share the per-brick path used on impact.
- **Custom light model.** Defining `light()` replaces Godot's built-in direct lighting with Lambert plus anisotropic GGX (F0 0.04). Ambient and reflections still come from Godot.
- **Odd-shaped parts.** Guns, characters and curved pieces need baked edge data or bevel mode 0; the box and stud modes only cover standard bricks.
- **Next to build.** The sloped staircase profile, then Z-seam and elephant's foot.

Performance is unprofiled. Close up the cost is a few circle tests per pixel, cheaper than 16-step POM; profile on a full chunk before committing.
