// THE SEA'S WAVES, shared by the wave tiers (water.gdshader) and the fluid
// mesher's real sea band (water_fluid.gdshader, Docs/MineWater.md 11.9), so
// where they meet they are the same height. The numbers come from BrickWave
// (WaterSea pushes them to the tiers; MineWater copies them to the fluid).

uniform vec4 waves[8];
uniform int wave_count = 2;
uniform vec4 groups[4];
uniform int group_count = 0;
uniform vec4 shore_band = vec4(0.0);
uniform vec4 swell_blend = vec4(250.0, 400.0, 1.0, 0.0);
uniform vec2 shore_calm = vec2(0.25, 150.0);
uniform float wave_time = 0.0;
uniform float sea_level = 1.1;
uniform sampler2D pool_calm : hint_default_white, filter_linear;
uniform vec2 pool_mask_origin = vec2(0.0);
uniform float pool_mask_size = 0.0;
uniform sampler2D seabed_tex : hint_default_black, filter_nearest;
uniform vec2 seabed_origin = vec2(0.0, 0.0);
uniform vec2 seabed_extent = vec2(1.0, 1.0);
uniform float open_sea_depth = 8.0;
uniform bool water_outside_field = false;
uniform float swash_delay = 1.4;   // seconds of delay per metre above still water
uniform float swash_loss = 0.5;    // metres of the wave lost per metre climbed
// The swell. `cell_m` is the spacing of the vertices drawing it: a wave under
// ~4 samples a wavelength lands between vertices and the surface boils, so on
// the coarse rings of the sheet the short waves fade out (MvsC's
// max_wave_number). The studded tier passes 0 and keeps everything.
float wave_raw_lod(vec2 p, float t, float cell_m, float dist) {
    // 0 near land (rolling toward the shore), 1 in open ocean (directional).
    float open = smoothstep(swell_blend.x, swell_blend.y, dist);
    float h = 0.0;
    for (int i = 0; i < wave_count; i++) {
        vec4 a = waves[i * 2];
        vec4 b = waves[i * 2 + 1];
        float len = 6.2831853 / max(a.y, 1e-4);
        float keep = cell_m > 0.0 ? smoothstep(4.0 * cell_m, 6.0 * cell_m, len) : 1.0;
        float directional = sin(dot(vec2(a.z, a.w), p) * a.y - b.x * t + b.y);
        float drift = swell_blend.z * (sin(0.017 * p.x + 1.3 * float(i)) + sin(0.014 * p.y + 0.7 * float(i)));
        float steered = sin(a.y * min(dist, swell_blend.y) + b.x * t + b.y + drift);
        h += keep * a.x * (steered * (1.0 - open) + directional * open);
    }
    return h;
}

float group_factor(vec2 p, float t) {
    float f = 1.0;
    for (int j = 0; j < group_count; j++) {
        vec4 a = groups[j * 2];
        vec4 b = groups[j * 2 + 1];
        f += a.x * sin(dot(vec2(a.z, a.w), p) * a.y - b.x * t + b.y);
    }
    return f;
}

/// The ground BILINEAR over the seabed lattice: the same corners the texture
/// holds and BrickWave::band_depth reads, so the band's crests are where the
/// CPU says they are. Nearest (seabed_at) is fine for a cull mask; a crest
/// phased on it would come out in 2.8 m blocks.
float lattice_ground(vec2 p) {
    vec2 size = vec2(textureSize(seabed_tex, 0));
    vec2 q = (p - seabed_origin) / seabed_extent * size;
    ivec2 i0 = ivec2(floor(q));
    vec2 f = q - vec2(i0);
    if (i0.x < 0 || i0.y < 0 || i0.x + 1 >= int(size.x) || i0.y + 1 >= int(size.y)) {
        return water_outside_field ? -open_sea_depth : 1.0e6;
    }
    float a = texelFetch(seabed_tex, i0, 0).r;
    float b = texelFetch(seabed_tex, i0 + ivec2(1, 0), 0).r;
    float c = texelFetch(seabed_tex, i0 + ivec2(0, 1), 0).r;
    float d = texelFetch(seabed_tex, i0 + ivec2(1, 1), 0).r;
    return mix(mix(a, b, f.x), mix(c, d, f.x), f.y);
}

/// Metres to the nearest dry ground: the seabed texture's G channel
/// (BrickWave.build_shore_field), bilinear like the ground.
float lattice_distance(vec2 p) {
    vec2 size = vec2(textureSize(seabed_tex, 0));
    vec2 q = (p - seabed_origin) / seabed_extent * size;
    ivec2 i0 = ivec2(floor(q));
    vec2 f = q - vec2(i0);
    if (i0.x < 0 || i0.y < 0 || i0.x + 1 >= int(size.x) || i0.y + 1 >= int(size.y)) {
        return 1.0e4;
    }
    float a = texelFetch(seabed_tex, i0, 0).g;
    float b = texelFetch(seabed_tex, i0 + ivec2(1, 0), 0).g;
    float c = texelFetch(seabed_tex, i0 + ivec2(0, 1), 0).g;
    float d = texelFetch(seabed_tex, i0 + ivec2(1, 1), 0).g;
    return mix(mix(a, b, f.x), mix(c, d, f.x), f.y);
}

/// The shore band: phased on DISTANCE TO THE SHORE, so crests run along
/// every coast and roll in toward it. BrickWave::band_at, restated.
/// shore_band = (amplitude, radians per metre, omega, reach).
float shore_wave(vec2 p, float t, float dist) {
    if (shore_band.x <= 0.0) {
        return 0.0;
    }
    float depth = sea_level - lattice_ground(p);
    if (depth <= 0.0) {
        return 0.0;
    }
    float reach = shore_band.w;
    float w = (0.35 + 0.65 * smoothstep(0.0, 20.0, dist)) * (1.0 - smoothstep(0.6 * reach, reach, dist))
            * smoothstep(0.2, 1.0, depth);
    float drift = 1.2 * sin(0.013 * p.x + 0.7) + 1.2 * sin(0.011 * p.y + 2.1);
    return shore_band.x * w * sin(shore_band.y * dist + shore_band.z * t + drift);
}

/// The whole surface above still water: swell shaped by the groups and dying
/// in the shallows, plus the band. BrickWave::height_at minus sea_level.
float pool_calm_at(vec2 p) {
    if (pool_mask_size <= 0.0) {
        return 1.0;
    }
    vec2 q = (p - pool_mask_origin) / pool_mask_size;
    if (q.x < 0.0 || q.y < 0.0 || q.x > 1.0 || q.y > 1.0) {
        return 1.0;
    }
    return textureLod(pool_calm, q, 0.0).g;
}

float surface_offset(vec2 p, float t, float taper, float cell_m) {
    float above = lattice_ground(p) - sea_level;
    if (above > 0.0) {
        t -= above * swash_delay;
    }
    float dist = lattice_distance(p);
    float band = shore_wave(p, t, dist);
    // The band's crests are 15 m apart; rings too coarse to carry 4 samples
    // of it leave it out.
    if (cell_m > 0.0) {
        band *= 1.0 - smoothstep(3.0, 5.0, cell_m);
    }
    // The wave strength by distance to the shore only: full out in the
    // water, a quarter at the beach (BrickWave swell_near_shore). No depth
    // clamp -- `taper` is 1.
    float calm = shore_calm.x + (1.0 - shore_calm.x) * smoothstep(0.0, shore_calm.y, dist);
    return (wave_raw_lod(p, t, cell_m, dist) * taper * group_factor(p, t) * calm + band)
            * pool_calm_at(p) - max(above, 0.0) * swash_loss;
}
