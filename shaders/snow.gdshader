shader_type spatial;
render_mode cull_disabled, diffuse_burley, specular_schlick_ggx;

// Snow cover (Docs/Disasters.md 21): smooth tiles laid on every top open to
// the sky (BrickWorld.build_snow_cover / build_snow_cover_tops). The mesh is
// built at full thickness; this grows it with `weather_snow` (0 none .. 1
// deep): tiles appear one stud cell at a time, then thicken. COLOR.r is 1 on
// the top of the snow and 0 at its foot. Melting runs it backwards.

#include "res://shaders/weather.gdshaderinc"

uniform float thickness = 0.12;
uniform float stud = 0.32;

varying vec3 v_world;
varying float v_top;

float snow_hash(vec2 p) {
    return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453);
}

void vertex() {
    // Thin at first, full when deep.
    float depth = clamp((weather_snow - 0.25) / 0.6, 0.2, 1.0);
    VERTEX.y -= (1.0 - depth) * thickness * COLOR.r;
    VERTEX = weather_sway_vertex(VERTEX, MODEL_MATRIX, TIME);
    v_world = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
    v_top = COLOR.r;
}

void fragment() {
    // One stud cell at a time: each fills when the snow passes its own share.
    vec2 cell = floor(v_world.xz / stud + 0.001);
    if (snow_hash(cell) > weather_snow * 1.6 - 0.05) {
        discard;
    }
    vec3 col = weather_snow_colour;
    vec3 nw = (INV_VIEW_MATRIX * vec4(NORMAL, 0.0)).xyz;
    float up = clamp(abs(nw.y), 0.0, 1.0);
    // Smooth tiles, two studs a side: a faint groove between them, on top.
    vec2 f = fract(v_world.xz / (stud * 2.0));
    float edge = min(min(f.x, 1.0 - f.x), min(f.y, 1.0 - f.y)) * stud * 2.0;
    float groove = (1.0 - smoothstep(0.0, 0.012, edge)) * up;
    col *= 1.0 - 0.12 * groove;
    // The sides of the tiles a touch darker; a glint here and there.
    col *= mix(0.9, 1.0, up);
    float glint = step(0.985, snow_hash(floor(v_world.xz * 40.0))) * up;
    ALBEDO = col;
    ROUGHNESS = 0.6 - 0.4 * glint;
    SPECULAR = 0.35 + 0.5 * glint;
    RIM = 0.25;
    RIM_TINT = 0.6;
}
