shader_type spatial;
render_mode cull_disabled, diffuse_burley, specular_schlick_ggx;

// POOLS: water that flowed into dug ground (BrickPools, Docs/Water.md 12).
//
// One flat top per stud column at a plate-stepped level, and sides where the
// water stands above its neighbour. Calm: no wave function -- a pool is still
// water, and the waves stop where the sea does. Coloured like the sea's
// trough deepening with depth, with foam where it is flowing fast.
//
// CULL_DISABLED for the same reason as water.gdshader: from under the surface
// the top's back face is the water you look up at.

uniform vec4 shallow_colour : source_color = vec4(0.30, 0.58, 0.66, 1.0);
uniform vec4 deep_colour : source_color = vec4(0.09, 0.26, 0.40, 1.0);
uniform vec4 foam_colour : source_color = vec4(0.92, 0.95, 0.96, 1.0);
uniform float water_roughness : hint_range(0.0, 1.0) = 0.22;
uniform float stud = 0.35;
// Thin lines on the stud grid, as on the sea, so a pool reads as bricks.
uniform float grid_line_darken : hint_range(0.0, 1.0) = 0.12;
uniform float grid_line_width = 0.012;

varying float v_up;
varying vec3 v_world;

void vertex() {
    v_up = NORMAL.y;
    v_world = VERTEX;
}

void fragment() {
    float depth = COLOR.g;
    float flow = COLOR.r;
    vec3 albedo = mix(shallow_colour.rgb, deep_colour.rgb, smoothstep(0.0, 0.6, depth));
    // Foam streaks where it runs: broken up along the stud grid so it reads
    // as moving water rather than a flat white patch.
    float streak = 0.5 + 0.5 * sin((v_world.x + v_world.z) * 9.0 - TIME * 6.0);
    albedo = mix(albedo, foam_colour.rgb, clamp(flow * 1.5, 0.0, 0.8) * streak);
    if (v_up > 0.5) {
        vec2 cell = mod(v_world.xz, stud);
        float edge = min(min(cell.x, stud - cell.x), min(cell.y, stud - cell.y));
        float aa = max(fwidth(edge), 1e-5);
        float line = 1.0 - smoothstep(grid_line_width, grid_line_width + aa, edge);
        albedo *= 1.0 - line * grid_line_darken;
    } else {
        // Sides lit most of the way toward the surface they belong to, as
        // the sea's risers are (water.gdshader).
        vec3 up_view = normalize((VIEW_MATRIX * vec4(0.0, 1.0, 0.0, 0.0)).xyz);
        NORMAL = normalize(mix(NORMAL, up_view, 0.85));
    }
    ALBEDO = albedo;
    ROUGHNESS = water_roughness;
    METALLIC = 0.0;
    SPECULAR = 0.7;
}
