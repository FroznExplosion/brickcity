// SKY LIGHT ON THINGS (Docs/MineWorld.md 19). The mine world's collapse
// pieces, dropped items and chests take the sky light of the cell they are
// in, so in a dark cave they are as dark as its walls. Included only by the
// mine world's copies (`#define SKY_LIT`, MineSkyLit): brick.gdshader's for the
// pieces, sky_lit_item.gdshader for ItemIcons' models; every other scene
// compiles none of this.
//
// `sky_level` (0..15) is set per node by MineSkyLit from
// BrickTerrain.sky_light_at, asked when a thing appears, moves a cell, or the
// ground near it is edited. The curve and the uniforms are terrain.gdshader's
// `#ifdef SKY_LIGHT` ones (MineWorld.sky_brightness):
//
//   AO        x the brightness (the ambient),
//   SPECULAR  x sqrt(brightness): the sky's reflections ignore AO,
//   the SUN   x brightness^sky_sun_power, in light() below, which writes out
//             the engine's own Burley diffuse, Schlick-GGX specular and rim;
//             every other light (a lamp, the lava's glow, the flashlight)
//             lights as the engine would.
//
// The including shader writes, in fragment(): AO, SPECULAR as above, and the
// varyings sl_sun (the sun's share), sl_spec (its own SPECULAR), sl_rim (its
// RIM), sl_metal (its METALLIC); with SKY_LIT_ANISO also sl_aniso, sl_tangent,
// sl_binormal (its ANISOTROPY, TANGENT, BINORMAL): light() cannot read those.

instance uniform float sky_level = 15.0;
uniform float sky_light_floor : hint_range(0.0, 0.2) = 0.015;
uniform float sky_light_curve : hint_range(0.5, 0.95) = 0.8;
uniform float sky_sun_power : hint_range(1.0, 4.0) = 2.0;
varying float sl_sun;
varying float sl_spec;
varying float sl_rim;
varying float sl_metal;
#ifdef SKY_LIT_ANISO
varying float sl_aniso;
varying vec3 sl_tangent;
varying vec3 sl_binormal;
#endif

// A level's brightness before the floor: 0 at level 0, 1 at 15. Clamped: at
// level 0 the difference rounds a hair under zero, and pow() of a negative
// number is NaN, which draws black.
float sky_lit_raw(float level) {
    float k0 = pow(sky_light_curve, 15.0);
    return clamp((pow(sky_light_curve, 15.0 - clamp(level, 0.0, 15.0)) - k0) / (1.0 - k0),
            0.0, 1.0);
}

float sky_lit_schlick(float u) {
    float m = 1.0 - u;
    float m2 = m * m;
    return m2 * m2 * m;
}

void light() {
    float k = LIGHT_IS_DIRECTIONAL ? sl_sun : 1.0;
    float cNdotL = max(dot(NORMAL, LIGHT), 0.0);
    float cNdotV = max(dot(NORMAL, VIEW), 1e-4);
    vec3 H = normalize(VIEW + LIGHT);
    float cLdotH = clamp(dot(LIGHT, H), 0.0, 1.0);
    float cNdotH = clamp(dot(NORMAL, H), 0.0, 1.0);
    float rough = ROUGHNESS;
    if (sl_metal < 1.0) {
        float fd90 = 2.0 * cLdotH * cLdotH * rough - 0.5;
        float fdv = 1.0 + fd90 * sky_lit_schlick(cNdotV);
        float fdl = 1.0 + fd90 * sky_lit_schlick(cNdotL);
        DIFFUSE_LIGHT += LIGHT_COLOR * ((1.0 / PI) * fdv * fdl * cNdotL) * ATTENUATION * k;
        if (sl_rim > 0.0) {
            float rim_light = pow(max(1e-4, 1.0 - cNdotV), max(0.0, (1.0 - rough) * 16.0));
            DIFFUSE_LIGHT += rim_light * sl_rim * mix(vec3(1.0), ALBEDO, 0.4) * LIGHT_COLOR * k;
        }
    }
    if (rough > 0.0) {
        float a = rough * rough;
        float d;
        float g;
#ifdef SKY_LIT_ANISO
        // The engine's anisotropic path, which it takes whenever ANISOTROPY
        // is written (at 0 it is GGX with the exact Smith term).
        vec3 t = normalize(sl_tangent);
        vec3 b = normalize(sl_binormal);
        float aspect = sqrt(1.0 - sl_aniso * 0.9);
        float ax = a / aspect;
        float ay = a * aspect;
        float a2 = ax * ay;
        vec3 v = vec3(ay * dot(t, H), ax * dot(b, H), a2 * cNdotH);
        float w2 = a2 / dot(v, v);
        d = a2 * w2 * w2 * (1.0 / PI);
        float lv = cNdotL * length(vec3(ax * dot(t, VIEW), ay * dot(b, VIEW), cNdotV));
        float ll = cNdotV * length(vec3(ax * dot(t, LIGHT), ay * dot(b, LIGHT), cNdotL));
        g = 0.5 / (lv + ll);
#else
        float dh = cNdotH * a;
        float dk = a / (1.0 - cNdotH * cNdotH + dh * dh);
        d = dk * dk * (1.0 / PI);
        g = 0.5 / mix(2.0 * cNdotL * cNdotV, cNdotL + cNdotV, a);
#endif
        vec3 f0 = mix(vec3(0.16 * sl_spec * sl_spec), ALBEDO, sl_metal);
        float f90 = clamp(dot(f0, vec3(50.0 * 0.33)), sl_metal, 1.0);
        vec3 f = f0 + (f90 - f0) * sky_lit_schlick(cLdotH);
        SPECULAR_LIGHT += (cNdotL * d * g) * f * LIGHT_COLOR * ATTENUATION * SPECULAR_AMOUNT * k;
    }
}
