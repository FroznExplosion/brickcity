// Weather on surfaces (Docs/Disasters.md 19): wet in rain, and swaying in wind.
//
// Every uniform defaults to "no weather", so a shader that includes this and a
// material nobody sets draw exactly as they did. scripts/weather_fx.gd pushes
// the values into every registered material.
//
//   weather_wet    0 dry .. 1 soaked. Darker a little, far glossier, most on
//                  what faces the sky. Lingers after the rain (it dries).
//   weather_rain   0 .. 1: rain falling NOW. Ripples in the wet and water
//                  running down walls move only while it falls.
//   weather_wind   the wind's direction times its strength, 0 .. ~1.5.
//   weather_sway   PER INSTANCE (GeometryInstance3D.set_instance_shader_parameter):
//                  (height m, lean at the top per metre of height at wind 1,
//                  sway frequency Hz). 0 height: never sways -- a piece of
//                  debris, a chair. Set on trees, grass, standing buildings.
//
// Sway bends the object about its base: the lean grows with the square of the
// height, so a tree's crown moves and its trunk barely does, and a tower's top
// moves a few centimetres while its ground floor stays put. Visual only --
// collision does not sway.
//
// Wet, in weather_wet_surface: the film (darker, glossier); PUDDLES on flat
// ground -- patches of near-mirror water from a world-space noise, the last to
// dry; RIPPLES -- rings spreading where drops land, in the normal, strongest
// in the puddles; and STREAKS -- thin wet runs down walls, flowing while it
// rains and left as dark trails after.

uniform float weather_wet : hint_range(0.0, 1.0) = 0.0;
uniform float weather_rain : hint_range(0.0, 1.0) = 0.0;
uniform vec3 weather_wind = vec3(0.0);
instance uniform vec3 weather_sway = vec3(0.0);

// `local` in model space with +Y up from the base. Returns it bent.
vec3 weather_sway_vertex(vec3 wp_local, mat4 wp_model, float wp_t) {
    float wx_s2 = dot(weather_wind, weather_wind);
    if (weather_sway.x <= 0.0 || wx_s2 < 1e-6) {
        return wp_local;
    }
    float wx_s = sqrt(wx_s2);
    float wx_h = clamp(wp_local.y / weather_sway.x, 0.0, 1.5);
    // Each object on its own phase, from where it stands.
    float wx_phase = dot(wp_model[3].xz, vec2(0.173, 0.291));
    float wx_w = 6.28318530718 * weather_sway.z;
    // A steady lean downwind, a sway about it, and a faster flutter on top.
    float wx_osc = 0.7 + 0.3 * sin(wp_t * wx_w + wx_phase) + 0.1 * sin(wp_t * wx_w * 2.7 + wx_phase * 1.7);
    float wx_lean = weather_sway.y * weather_sway.x * wx_s * wx_osc * wx_h * wx_h;
    // The world wind into model space (rotation and scale both undone).
    mat3 wx_m = mat3(wp_model);
    vec3 wx_dir = weather_wind / wx_s;
    vec3 wx_d_local = vec3(dot(wx_m[0], wx_dir) / max(dot(wx_m[0], wx_m[0]), 1e-6),
            0.0, dot(wx_m[2], wx_dir) / max(dot(wx_m[2], wx_m[2]), 1e-6));
    return wp_local + wx_d_local * wx_lean;
}

float weather_hash(vec2 wp_p) {
    return fract(sin(dot(wp_p, vec2(127.1, 311.7))) * 43758.5453);
}

float weather_noise(vec2 wp_p) {
    vec2 wx_i = floor(wp_p);
    vec2 wx_f = fract(wp_p);
    wx_f = wx_f * wx_f * (3.0 - 2.0 * wx_f);
    return mix(mix(weather_hash(wx_i), weather_hash(wx_i + vec2(1.0, 0.0)), wx_f.x),
            mix(weather_hash(wx_i + vec2(0.0, 1.0)), weather_hash(wx_i + vec2(1.0, 1.0)), wx_f.x), wx_f.y);
}

// One layer of ripples: a drop per cell, at its own place and time; a ring
// spreads from it and fades. Returns the slope the ring puts in the surface,
// in world XZ.
vec2 weather_ripple_layer(vec2 wp_p, float wp_t, float wp_seed) {
    vec2 wx_cell = floor(wp_p);
    vec2 wx_f = fract(wp_p);
    float wx_r0 = weather_hash(wx_cell + wp_seed);
    float wx_r1 = weather_hash(wx_cell + wp_seed + 17.3);
    vec2 wx_centre = vec2(0.25) + vec2(wx_r0, wx_r1) * 0.5;
    float wx_age = fract(wp_t * 0.9 + wx_r0 * 7.0);
    vec2 wx_d = wx_f - wx_centre;
    float wx_dist = length(wx_d);
    float wx_radius = wx_age * 0.4;
    float wx_ring = exp(-pow((wx_dist - wx_radius) * 28.0, 2.0)) * (1.0 - wx_age);
    return wx_dist > 1e-4 ? wx_d / wx_dist * wx_ring : vec2(0.0);
}

// Wet surface. `darken` is how much this surface darkens soaked (the ground's
// dirt 0.22, plastic 0.14, metal 0); `puddles` how much standing water its
// flat parts hold (ground 1, a roof less, a far card none). `normal_view` is
// NORMAL, updated; `vertex_view` is VERTEX. Call last, after anything else
// that bends the normal, and write NORMAL back.
void weather_wet_surface(inout vec3 wp_albedo, inout float wp_roughness, inout float wp_specular,
        inout vec3 wp_normal_view, vec3 wp_vertex_view, mat4 wp_inv_view, mat4 wp_view,
        float wp_darken, float wp_puddles, float wp_t) {
    if (weather_wet <= 0.0) {
        return;
    }
    vec3 wx_nw = normalize((wp_inv_view * vec4(wp_normal_view, 0.0)).xyz);
    vec3 wx_world = (wp_inv_view * vec4(wp_vertex_view, 1.0)).xyz;
    float wx_up = clamp(wx_nw.y, 0.0, 1.0);
    float wx_w = weather_wet * (0.55 + 0.45 * wx_up);
    wp_albedo *= 1.0 - wp_darken * wx_w;
    wp_roughness = mix(wp_roughness, 0.22, wx_w * 0.85);
    wp_specular = mix(wp_specular, 0.65, wx_w);

    vec2 wx_slope = vec2(0.0);
    if (wx_up > 0.85) {
        // Puddles: where the noise is high, on the flat. They fill as it gets
        // wet and are the last of it to go.
        float wx_n = weather_noise(wx_world.xz * 0.35) * 0.65 + weather_noise(wx_world.xz * 1.3) * 0.35;
        float wx_fill = smoothstep(0.3, 1.0, weather_wet);
        float wx_pool = smoothstep(0.56 - 0.14 * wx_fill, 0.62 - 0.1 * wx_fill, wx_n) * wx_fill * wp_puddles
                * smoothstep(0.85, 0.97, wx_up);
        wp_albedo *= 1.0 - 0.5 * wx_pool;
        wp_roughness = mix(wp_roughness, 0.0, wx_pool);
        wp_specular = mix(wp_specular, 1.0, wx_pool);
        // Ripples while it rains: strongest in the puddles, faint on the film.
        if (weather_rain > 0.0) {
            float wx_k = weather_rain * (0.25 + 0.75 * wx_pool) * smoothstep(0.85, 1.0, wx_up);
            wx_slope = (weather_ripple_layer(wx_world.xz * 2.2, wp_t, 0.0)
                    + weather_ripple_layer(wx_world.xz * 3.1 + 5.7, wp_t * 1.13, 3.1)) * wx_k * 1.2;
        }
    } else if (abs(wx_nw.y) < 0.35) {
        // Streaks down a wall: thin runs, each on its own column, flowing
        // while the rain falls and left as darker trails after.
        vec2 wx_along = normalize(vec2(-wx_nw.z, wx_nw.x) + vec2(1e-5));
        float wx_u = dot(wx_world.xz, wx_along) * 4.0;
        float wx_col = floor(wx_u);
        float wx_rnd = weather_hash(vec2(wx_col, 7.1));
        float wx_line = smoothstep(0.0, 0.1, fract(wx_u)) * (1.0 - smoothstep(0.3, 0.45, fract(wx_u)));
        float wx_flow = 0.5 + 0.5 * sin(wx_world.y * 2.3 - wp_t * (2.0 + 3.0 * wx_rnd) * weather_rain + wx_rnd * 40.0);
        float wx_streak = wx_line * step(0.55, wx_rnd) * mix(0.55, wx_flow, weather_rain) * weather_wet;
        wp_albedo *= 1.0 - 0.35 * wx_streak;
        wp_roughness = mix(wp_roughness, 0.04, wx_streak);
    }
    if (wx_slope != vec2(0.0)) {
        wx_nw = normalize(wx_nw + vec3(wx_slope.x, 0.0, wx_slope.y));
        wp_normal_view = normalize((wp_view * vec4(wx_nw, 0.0)).xyz);
    }
}
