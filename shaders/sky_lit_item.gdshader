shader_type spatial;
render_mode cull_back, diffuse_burley, specular_schlick_ggx;

// ItemIcons' models as the mine world draws them lying about (dropped items,
// chests) and the boxes of sand that landed on a collapse piece: the
// StandardMaterial3D they were made with (colour, roughness, alpha, glow),
// lit by their own cell's sky light (Docs/MineWorld.md 19). Only the mine
// world uses this (MineSkyLit.item_material); the alpha copy has
// `#define ITEM_ALPHA` in front.

#define SKY_LIT
#include "res://shaders/sky_lit.gdshaderinc"

uniform vec4 albedo : source_color = vec4(1.0);
uniform float roughness : hint_range(0.0, 1.0) = 0.4;
uniform vec4 emission : source_color = vec4(0.0, 0.0, 0.0, 1.0);
uniform float emission_energy = 0.0;

void fragment() {
    ALBEDO = albedo.rgb;
#ifdef ITEM_ALPHA
    ALPHA = albedo.a;
#endif
    ROUGHNESS = roughness;
    EMISSION = emission.rgb * emission_energy;
    // StandardMaterial3D's SPECULAR is 0.5, its METALLIC 0, no rim.
    float b = sky_lit_raw(sky_level);
    AO = mix(sky_light_floor, 1.0, b);
    SPECULAR = 0.5 * sqrt(AO);
    sl_sun = pow(b, sky_sun_power);
    sl_spec = 0.5;
    sl_rim = 0.0;
    sl_metal = 0.0;
}
