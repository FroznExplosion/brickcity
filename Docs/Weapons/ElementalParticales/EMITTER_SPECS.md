# Emitter Specs — pooled VFX scenes

Run `fx/emitter_factory.gd` (open in Script Editor → File → Run) to generate all
scenes below into `res://fx/emitters/`, then register them in `VfxPool.emitter_scenes`:

```gdscript
@export var emitter_scenes: Dictionary = {
    "fire_body":    preload("res://fx/emitters/fire_body.tscn"),
    "fire_smoke":   preload("res://fx/emitters/fire_smoke.tscn"),
    "acid_sizzle":  preload("res://fx/emitters/acid_sizzle.tscn"),
    "shock_sparks": preload("res://fx/emitters/shock_sparks.tscn"),
    "rad_smoke":    preload("res://fx/emitters/rad_smoke.tscn"),
    "ice_mist":     preload("res://fx/emitters/ice_mist.tscn"),
    "corr_drips":   preload("res://fx/emitters/corr_drips.tscn"),
    "shatter_puff": preload("res://fx/emitters/shatter_puff.tscn"),
}
# Also: arc_ribbon_scene = preload("res://fx/emitters/arc_ribbon.tscn")
```

First edit the `TEX` table at the top of the factory to point at your Synty
textures, and check each flipbook's grid (open the PNG — count columns × rows,
usually 4×4 or 8×8) so `h`/`v` match.

## Per-emitter tuning (what the factory bakes in, and why)

| Key | Count | Life | Quad | Blend | Motion | Notes |
|---|---|---|---|---|---|---|
| `fire_body` | 12 | 0.7s | 0.5m | Add | up 0.4–0.9 m/s, +1.5 buoyancy | Flame flipbook plays once per particle. **Local coords** so flames stick to a running enemy. Scale curve pops in fast, shrinks to embers. |
| `fire_smoke` | 6 | 1.4s | 0.7m | Mix | up 0.6–1.1, slight spin | **Global coords** — smoke trails behind movement, sells speed. Expands ×1.6 over life, alpha peaks at 0.55 so it never blocks the flames. |
| `acid_sizzle` | 16 | 0.55s | 0.12m | Add | up 0.2–0.7, wide sphere | Soft glow dots popping off the dissolve front. Tiny quads = negligible fill. |
| `shock_sparks` | 20 | 0.35s | 0.08m | Add | 2–4 m/s all directions, full gravity + damping | Classic spark shower. Short life + heavy damping keeps them tight around the body. Arc ribbons do the "electricity" read; these add energy. |
| `rad_smoke` | 10 | 1.6s | 0.6m | **Add @ low alpha** | slow rise + **turbulence** | The "smokier shock" look: additive green haze that curls (turbulence strength 0.6). Also reused as the death-spread burst. |
| `ice_mist` | 8 | 1.2s | 0.5m | Mix | drifts **down** 0.1–0.3 | Cold air sinks — mist rolling off the popsicle downward reads instantly as "frozen", not "steaming". Local coords. |
| `corr_drips` | 10 | 0.8s | 0.1m | Mix | free-fall, full gravity | Droplets shed from the coat and land where the puddle is. Global coords so drips fall straight even if the enemy staggers. |
| `shatter_puff` | 24 | 0.9s | 0.4m | Mix | radial 2–4.5 m/s, damped | **One-shot**, explosiveness 1.0. Fired by `VfxPool.spawn_shatter()` beneath the shard burst — hides the mesh-swap frame. |
| `arc_ribbon` | — | — | 1.2×0.8m ×2 | Add (shader) | orbits via `arc_ribbon.gd` | Two crossed quads with `electric_arc.gdshader`. Not billboarded: crossed planes read as volume from every angle for 4 triangles. |

Total worst case per enemy (fire = heaviest): 18 particles + 1 overlay pass.
Twenty burning enemies ≈ 360 small quads — trivial. The budget killer would have
been big overlapping smoke quads; that's why smoke is capped at 6 per enemy.

## Which Synty texture goes where

- **flame**: the fire flipbook atlas (orange tongues on black). If the pack has
  both "fire" and "fire_torch" variants, the torch one usually loops cleaner.
- **smoke**: any soft smoke puff flipbook — used by fire_smoke, rad_smoke,
  ice_mist, and shatter_puff (the color ramp retints it per element, which is
  why one atlas serves four effects).
- **spark**: a small streak/star sprite. If Synty only has round glows, use the
  glow — the velocity stretch sells it anyway.
- **glow**: soft radial white dot (every pack has one).
- **droplet**: teardrop or splash sprite; a round glow at Mix blend also works.

If a texture path in `TEX` doesn't exist the factory still builds the scene with
a white placeholder, so you can generate first and assign textures after.

## Scenes the factory does NOT build (one-time hand setup)

**Radiation arc variant.** The pooled `arc_ribbon.tscn` ships tuned for shock.
For radiation's lazier arcs the scripts already lower `intensity` per instance;
if you want the full smoky look, duplicate `arc_ribbon.tscn`, and on its
material set `arc_color` green, `scroll_speed 1.5`, `softness 0.25`, then point
a second pool export at it.

**Oil slick Fx** (child `Fx` of `surface_oil.tscn`): one GPUParticles3D with
`emission_shape = BOX` and `emission_box_extents` matching the slick mesh
(e.g. 2×0.1×2 for a 4×4 m slick). Flame flipbook, Add blend, amount ≈
`8 × area_in_m²` capped at 60, lifetime 0.8, quad 0.6 m, velocity up 0.5–1.0.
One stretched emitter for the whole slick — never per-tile emitters. Start with
`emitting = false`; `SurfaceOil.ignite()` flips it on.

**Water zap Fx** (child `Fx` of `surface_water.tscn`): 4 quads (1.5×0.5 m) with
the electric arc material, laid flat 5 cm above the water plane at random yaw,
plus optionally one `shock_sparks`-style emitter with box emission across the
surface. Also add `instance uniform float zap = 0.0;` to your water shader and
multiply it into EMISSION with a caustics/voronoi texture — the script already
sets `zap` on electrify.

**Puddle decals.** `VfxPool` uses `Decal` nodes: author one 256² albedo — radial
alpha falloff with a blotchy voronoi edge — assign it to the pooled decals'
`texture_albedo` in `VfxPool._ready()` (one line: `d.texture_albedo = preload(...)`).
`modulate` retints it green (corrosive) so one texture serves all puddle colors.
On flat Synty ground you can swap to quads with `puddle_decal.gdshader` instead —
cheaper, and the shader's bubbling interior is better than a static decal.

**Noise textures** (shared by all shaders): create two `NoiseTexture2D` resources
and save as `.tres` — `noise_rgb.tres` (FastNoiseLite, Perlin, frequency 0.05,
seamless ✓) and `noise_voronoi.tres` (Cellular, frequency 0.08, seamless ✓,
used as `crack_tex`/caustics). Assign both on `elemental_overlay`'s material and
`noise_tex` wherever the shaders ask.

## Sanity checklist after generating

1. Open `fire_body.tscn`, press the emitting checkbox — flames should pop in,
   shrink, and the flipbook should complete exactly once per particle. If the
   flipbook strobes, the `h`/`v` grid in `TEX` doesn't match the atlas.
2. Drop an enemy in a test scene, run
   `ElementalManager.apply($Enemy/ElementalTarget, ElementalManager.Element.FIRE, 25.0)`
   from a debug key — you should see overlay embers + both emitters, and the
   emitters must return to the pool (check the VfxPool node in Remote tree)
   5s later.
3. Kill it while frozen (`ICE` then `deal_damage 999`) — shard burst + puff,
   no orphaned mist emitter.
