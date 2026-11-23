shader_type spatial;
render_mode cull_back, diffuse_burley, specular_schlick_ggx;

// ItemIcons' models as the mine world draws them lying about (dropped items,
// chests) and the boxes of sand that landed on a collapse piece: the
// StandardMaterial3D they were made with (colour, roughness, alpha, glow),
// lit by their own cell's sky light (Docs/MineWorld.md 19). Only the mine
// world uses this (MineSkyLit.item_material); the alpha copy has
// `#define ITEM_ALPHA` in front. The falling sand's copy (MineSkyLit.
// sand_material) has `#define SKY_LIT_SAND`: one MultiMesh for every falling
// column, so its levels are per instance -- INSTANCE_CUSTOM.r the sky level,
// .g the block level, as 0..1 -- and its colour is the instance's.

#define SKY_LIT
#include "res://shaders/sky_lit.gdshaderinc"

uniform vec4 albedo : source_color = vec4(1.0);
uniform float roughness : hint_range(0.0, 1.0) = 0.4;
uniform vec4 emission : source_color = vec4(0.0, 0.0, 0.0, 1.0);
uniform float emission_energy = 0.0;

#ifdef SKY_LIT_SAND
varying flat float sand_sky;
varying flat float sand_block;

void vertex() {
    sand_sky = INSTANCE_CUSTOM.r * 15.0;
    sand_block = INSTANCE_CUSTOM.g * 15.0;
}
#endif

void fragment() {
    ALBEDO = albedo.rgb;
#ifdef SKY_LIT_SAND
    ALBEDO *= COLOR.rgb;
    float lv_sky = sand_sky;
    float lv_block = sand_block;
#else
    float lv_sky = sky_level;
    float lv_block = block_level;
#endif
#ifdef ITEM_ALPHA
    ALPHA = albedo.a;
#endif
    ROUGHNESS = roughness;
    EMISSION = emission.rgb * emission_energy;
    // StandardMaterial3D's SPECULAR is 0.5, its METALLIC 0, no rim.
    float b = sky_lit_raw(lv_sky);
    AO = sky_lit_ao_at(lv_sky, lv_block);
    EMISSION += sky_lit_glow_at(ALBEDO, lv_block);
    SPECULAR = 0.5 * sqrt(AO);
    sl_sun = pow(b, sky_sun_power);
    sl_spec = 0.5;
    sl_rim = 0.0;
    sl_metal = 0.0;
}
