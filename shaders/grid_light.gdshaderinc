// The light on the brick grid (Docs/Lighting.md 6.1; BrickGridLight): per
// building, how open each cell is to the sky (R) and the lamps' light
// reaching it (GBA: its colour times how much), a layer of grid_light_tex
// each, its y layers as tiles.
// `grid_light`: the layer, and the grid's cells in x, y, z (margin included);
// a layer under 0 is no grid -- drawn as before.
//
// Shared by brick.gdshader (the bands, positions chunk-local already) and
// printed_grid.gdshader (the near tier's studs, brought to the chunk by
// grid_from_world, printed_core.gdshaderinc).
instance uniform vec4 grid_light = vec4(-1.0, 0.0, 0.0, 0.0);
uniform sampler2DArray grid_light_tex : filter_linear, repeat_disable;
uniform float grid_light_size = 512.0;
uniform vec3 grid_cell = vec3(0.35, 0.42, 0.35);
// A cell shut off from the sky keeps this much of the ambient light.
uniform float grid_sky_floor : hint_range(0.0, 1.0) = 0.1;
// The lamps' light on what is near them, tinted by this (each lamp's own
// colour is in the grid).
uniform vec3 grid_lamp_colour : source_color = vec3(1.0, 1.0, 1.0);
uniform float grid_lamp_energy = 0.6;

// The grid's light (sky; lamp r, g, b) at chunk-local `p`: bilinear in a y
// layer, mixed between two.
vec4 grid_light_at(vec3 p) {
    vec3 n = grid_light.yzw;
    vec3 c = p / grid_cell + 1.0;
    vec2 xz = clamp(c.xz, vec2(0.5), n.xz - 0.5);
    float ly = clamp(c.y - 0.5, 0.0, n.y - 1.0);
    float l0 = floor(ly);
    float l1 = min(l0 + 1.0, n.y - 1.0);
    float per_row = floor(grid_light_size / n.x);
    vec2 t0 = vec2(mod(l0, per_row) * n.x, floor(l0 / per_row) * n.z);
    vec2 t1 = vec2(mod(l1, per_row) * n.x, floor(l1 / per_row) * n.z);
    vec4 a = texture(grid_light_tex, vec3((t0 + xz) / grid_light_size, grid_light.x));
    vec4 b = texture(grid_light_tex, vec3((t1 + xz) / grid_light_size, grid_light.x));
    return mix(a, b, ly - l0);
}

// The grid on a face at chunk-local `p`, its normal `n`: what the ambient
// keeps (multiply into AO) and the lamps' light added to `emission`.
float grid_light_shade(vec3 p, vec3 n, vec3 albedo, inout vec3 emission) {
    if (grid_light.x < 0.0) {
        return 1.0;
    }
    // Half a cell out from the face: the air it looks into, not the block it
    // is on.
    vec4 gl = grid_light_at(p + n * grid_cell * 0.5);
    // Squared, as before: how much reaches (the brightest channel) times the
    // light itself.
    vec3 lamp = gl.gba * max(max(gl.g, gl.b), gl.a);
    emission += albedo * grid_lamp_colour * grid_lamp_energy * lamp;
    // What a shut room loses is sky: the ambient light and reflections.
    return mix(grid_sky_floor, 1.0, gl.r);
}
