shader_type spatial;
render_mode cull_back, diffuse_burley, specular_schlick_ggx;

// The mine world's wire tiles, wires and trip strings (MineWiring, Docs/
// MineWiring.md 13): one MultiMesh each, the instance's COLOR its colour and
// its alpha the glow of a powered wire.
//
// With `#define SKY_LIT` in front (MineWiring, when the mine world has sky
// light on, MineSkyLit) the instances take the sky light of their own cell,
// so a wire in a dark cave is as dark as the walls round it (Docs/
// MineWiring.md 19): INSTANCE_CUSTOM.r the sky level, .g the lava's block
// level, as 0..1 -- the falling sand's way (sky_lit_item.gdshader). The glow
// of a powered wire stays: it is light of its own.

#ifdef SKY_LIT
#include "res://shaders/sky_lit.gdshaderinc"
varying flat float w_sky;
varying flat float w_block;
#endif

varying vec4 tint;

void vertex() {
    tint = COLOR;
#ifdef SKY_LIT
    w_sky = INSTANCE_CUSTOM.r * 15.0;
    w_block = INSTANCE_CUSTOM.g * 15.0;
#endif
}

void fragment() {
    ALBEDO = tint.rgb;
    ROUGHNESS = 0.45;
    EMISSION = tint.rgb * tint.a * 1.6;
#ifdef SKY_LIT
    float b = sky_lit_raw(w_sky);
    AO = sky_lit_ao_at(w_sky, w_block);
    EMISSION += sky_lit_glow_at(ALBEDO, w_block);
    SPECULAR = 0.5 * sqrt(AO);
    sl_sun = pow(b, sky_sun_power);
    sl_spec = 0.5;
    sl_rim = 0.0;
    sl_metal = 0.0;
#endif
}
