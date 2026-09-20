shader_type spatial;
render_mode cull_back, diffuse_burley, specular_schlick_ggx;

// Brick water, tier 0. Docs/Water.md sections 3.0, 3.4, 3.5.
//
// Every instance is one cell of a camera-following stud lattice. In the vertex
// shader it works out whether it is the ORIGIN of a piece; if it is, it scales
// the unit plate to that piece's run and depth, and if it is not, it collapses
// to a point. So the sea is laid out of 1x2s, 2x2s, 2x4s and their neighbours,
// the same language the ground is laid in -- not a carpet of 1x1 rounds.
//
// It is done here and not on the CPU because of section 3.4's arithmetic: a
// 20 m disc crossing a 0.42 m brick step at 1.44 m/s is 1,180 block
// create/destroy events per 30 Hz tick, and 7,340 at 50 m. M2c's measured
// cascade STEP -- a one-off -- is 22 ms. So the instance buffer is written
// once at startup and never touched again, and everything that READS as a
// piece appearing or vanishing is a scale to zero:
//
//   * a piece below its neighbours hides behind their columns
//   * dry land and the shore collapse against the seabed texture
//   * a cell that is not a piece origin collapses
//   * the snap to a brick step makes a piece JUMP 0.42 m in one frame rather
//     than slide, which is the brick-film read, and a per-instance hold
//     staggers those jumps -- spec section 2's stop-motion "on twos"
//
// The packing rule is the SAME SHAPE as the ground's (Terrain.md section 6.3):
// a hashed cut lattice, so it is a pure function of the world cell and needs
// no state, no CPU pass, and no agreement between frames.
//
// The wave constants are NOT here. They arrive as `waves`, packed by
// BrickWave.uniform_array(), so the shader and the buoyancy solver cannot
// disagree about where the surface is (section 1).

group_uniforms wave;
uniform vec4 waves[8];
uniform int wave_count = 2;
uniform float wave_time = 0.0;
uniform float sea_level = 1.1;
uniform float step_m = 0.42;

group_uniforms grid;
uniform vec2 snapped_origin = vec2(0.0, 0.0);
uniform float stud = 0.35;
uniform int grid_side = 115;
uniform float fade_radius = 20.0;
uniform int seed = 20260919;

group_uniforms seabed;
// Section 5. Ground height in metres over a known world rectangle. Two jobs:
// a piece whose seabed is above the surface is dry land and collapses, and
// `surface - seabed` is the absorption depth, which is how the water gets its
// colour with no alpha, no depth prepass, and nothing for Godot's per-object
// transparency sort to get wrong.
uniform sampler2D seabed_tex : hint_default_black, filter_nearest;
uniform vec2 seabed_origin = vec2(0.0, 0.0);
uniform vec2 seabed_extent = vec2(1.0, 1.0);
uniform float open_sea_depth = 8.0;

group_uniforms look;
uniform vec4 shallow_colour : source_color = vec4(0.30, 0.62, 0.68, 1.0);
uniform vec4 deep_colour : source_color = vec4(0.06, 0.20, 0.34, 1.0);
uniform float absorb_depth = 6.0;
uniform float water_roughness : hint_range(0.0, 1.0) = 0.18;

group_uniforms studs;
uniform bool studs_enabled = true;
uniform float stud_radius = 0.105;
uniform float stud_dome : hint_range(0.0, 1.0) = 0.8;

group_uniforms seams;
uniform bool seams_enabled = true;
uniform float seam_width : hint_range(0.0, 0.05) = 0.008;
uniform float seam_darken : hint_range(0.0, 1.0) = 0.62;

group_uniforms stop_motion;
uniform float hold_seconds : hint_range(0.0, 0.25) = 0.08;

varying vec3 v_world;
varying float v_depth;
varying vec2 v_local;   // metres within the piece
varying vec2 v_face;    // the piece's size, in metres
varying float v_up;

// --- the same hash the ground uses ----------------------------------------
uint mix32(uint h) {
    h ^= h >> 16u;
    h *= 0x7feb352du;
    h ^= h >> 15u;
    h *= 0x846ca68bu;
    h ^= h >> 16u;
    return h;
}

uint hash3i(int a, int b, int c) {
    return mix32(uint(a) * 73856093u ^ uint(b) * 19349663u ^ uint(c) * 83492791u);
}

float hashf3(int a, int b, int c) {
    return float(hash3i(a, b, c)) * (1.0 / 4294967296.0);
}

int floor_div(int a, int b) {
    int q = a / b;
    return (a % b != 0 && ((a < 0) != (b < 0))) ? q - 1 : q;
}

// --- the cut lattice -------------------------------------------------------
//
// Partitions of PERIOD, each packed as nibbles low-to-high and terminated by a
// zero. Shorter than the ground's table on purpose: section 2 measures the
// terrace at 2.1 studs, so a piece longer than four almost never survives the
// "all one step" test and asking for one just wastes the walk.
const int PERIOD = 8;
const int MAX_RUN = 4;
const int PART_COUNT = 8;
const int PARTS[8] = { 0x44, 0x44, 0x242, 0x224, 0x422, 0x143, 0x332, 0x233 };

int row_offset(int row) {
    return int(hash3i(row, 11, seed ^ 0x51ED) % uint(PERIOD));
}

bool cut_before(int u, int row) {
    int t = u - row_offset(row);
    int pi = floor_div(t, PERIOD);
    int local = t - pi * PERIOD;
    int part = PARTS[int(hash3i(pi, row * 31, seed ^ 0xB105) % uint(PART_COUNT))];
    int acc = 0;
    for (int k = 0; k < 4; k++) {
        int seg = (part >> (k * 4)) & 15;
        if (seg == 0) {
            break;
        }
        if (local == acc) {
            return true;
        }
        acc += seg;
    }
    return false;
}

float wave_height(vec2 p, float t) {
    float h = sea_level;
    for (int i = 0; i < wave_count; i++) {
        vec4 a = waves[i * 2];
        vec4 b = waves[i * 2 + 1];
        h += a.x * sin(dot(vec2(a.z, a.w), p) * a.y - b.x * t + b.y);
    }
    return h;
}

/// The brick step a cell's surface sits on. Integer, so "same step" is an
/// equality and the packer needs no tolerance.
int step_at(int cx, int cz, float t) {
    vec2 p = (vec2(float(cx), float(cz)) + 0.5) * stud;
    return int(floor(wave_height(p, t) / step_m));
}

void vertex() {
    int id = INSTANCE_ID;
    int gx = id % grid_side;
    int gz = id / grid_side;
    float half_side = float(grid_side) * 0.5;
    vec2 corner = snapped_origin + (vec2(float(gx), float(gz)) - half_side) * stud;

    int cx = int(floor(corner.x / stud + 0.5));
    int cz = int(floor(corner.y / stud + 0.5));

    // --- one lattice and one clock for the whole piece --------------------
    //
    // Both of the gap bugs were the same mistake: a cell decided whether it
    // was covered by a NEIGHBOUR using numbers only it had.
    //
    //   * the per-CELL stop-motion jitter gave neighbouring cells different
    //     quantised times, so they sampled the wave at different instants,
    //     disagreed about the step, and each assumed the other would draw.
    //     The hold is now per ROW.
    //   * the two rows of a bonded pair had different cut lattices, because
    //     row_offset is hashed per row. The odd row collapsed expecting the
    //     even row to cover it, and the even row was not an origin there. A
    //     bonded pair now shares the EVEN row's lattice, its clock and its
    //     step, so the odd row is always covered by construction.
    //
    // The cost of the second one is that a bonded pair renders at the even
    // row's step, so a terrace is two studs deep in Z. That reads as more
    // brick-like, not less, and it removed every remaining agreement check.
    int pair = floor_div(cz, 2);
    bool pair_even = (cz - pair * 2) == 0;
    bool bonded = hashf3(pair, 3, seed ^ 0x2B0D) < 0.75;
    int row_key = bonded ? pair * 2 : cz;
    int depth = bonded ? 2 : 1;

    float jitter = hashf3(0, row_key, 0x570F) * hold_seconds;
    float t = hold_seconds > 0.0
        ? floor((wave_time + jitter) / hold_seconds) * hold_seconds
        : wave_time;

    int my_step = step_at(cx, row_key, t);

    // Am I the origin of a piece? Walk back while there is no cut and the
    // step has not changed. If the walk moves at all, a cell to my left owns
    // me and I am not drawn.
    int o = cx;
    for (int k = 0; k < MAX_RUN - 1; k++) {
        if (cut_before(o, row_key)) {
            break;
        }
        if (step_at(o - 1, row_key, t) != my_step) {
            break;
        }
        o -= 1;
    }
    bool is_origin = (o == cx) && !(bonded && !pair_even);

    int run = 1;
    for (int k = 1; k < MAX_RUN; k++) {
        if (cut_before(cx + k, row_key)) {
            break;
        }
        if (step_at(cx + k, row_key, t) != my_step) {
            break;
        }
        run += 1;
    }

    float top = float(my_step) * step_m;

    // Column depth: down to the lowest neighbouring step, so a step edge is a
    // solid wall from the side and from below (spec section 4), and a flat
    // patch costs a flat plate.
    int lowest = my_step;
    lowest = min(lowest, step_at(cx - 1, row_key, t));
    lowest = min(lowest, step_at(cx + run, row_key, t));
    lowest = min(lowest, step_at(cx, row_key - 1, t));
    lowest = min(lowest, step_at(cx, row_key + depth, t));
    float column = max(float(my_step - lowest), 1.0) * step_m;

    // How far the seabed is below. Outside the mapped rectangle we are in
    // open water and assume it is deep.
    vec2 uv = (corner - seabed_origin) / seabed_extent;
    float ground = -open_sea_depth;
    if (uv.x > 0.0 && uv.x < 1.0 && uv.y > 0.0 && uv.y < 1.0) {
        ground = textureLod(seabed_tex, uv, 0.0).r;
    }

    float r = length(corner - snapped_origin);
    // Three ways to not be drawn, all of them a scale to zero rather than a
    // discard: I am not a piece origin, I am past the disc, or I am over dry
    // land. Godot's shader language has no early return in vertex(), so this
    // is one branch rather than a guard clause.
    bool alive = is_origin && r < fade_radius && top > ground;
    if (alive) {
        // The unit plate has its origin at the min corner and a footprint of
        // [0,1] x [0,1], so scaling places it exactly.
        vec2 size = vec2(float(run), float(depth)) * stud;
        v_local = VERTEX.xz * size;
        v_face = size;
        v_up = step(0.5, NORMAL.y);

        VERTEX.x *= size.x;
        VERTEX.z *= size.y;
        VERTEX.y *= column;
        // A bonded piece is anchored to its EVEN row, not to the instance
        // that happens to be drawing it.
        VERTEX.xz += vec2(float(cx), float(row_key)) * stud - vec2(0.5, 0.5) * stud;
        VERTEX.y += top;

        v_world = VERTEX;
        v_depth = max(top - ground, 0.0);
    } else {
        VERTEX = vec3(0.0);
        v_world = vec3(0.0);
        v_local = vec2(0.0);
        v_face = vec2(1.0);
        v_depth = 0.0;
        v_up = 0.0;
    }
}

void fragment() {
    // Opaque, with depth carried by colour rather than alpha (section 5). The
    // whole surface is ONE object, so there is nothing for the per-object
    // transparency sort to get wrong.
    float k = clamp(v_depth / absorb_depth, 0.0, 1.0);
    vec3 albedo = mix(shallow_colour.rgb, deep_colour.rgb, k);

    // The piece outline, on the same UV/UV2 contract the ground uses. Without
    // it a 2x4 of water is a flat rectangle and only the studs say it is a
    // brick at all.
    if (seams_enabled) {
        vec2 to_edge = min(v_local, v_face - v_local);
        float d = min(to_edge.x, to_edge.y);
        float aa = max(fwidth(d), 1e-5);
        float w = max(seam_width, aa);
        albedo *= mix(1.0, seam_darken, 1.0 - smoothstep(w, w + aa, d));
    }

    if (studs_enabled && v_up > 0.5) {
        vec2 c = (floor(v_world.xz / stud) + 0.5) * stud;
        vec2 rel = v_world.xz - c;
        float r = length(rel);
        float aa = max(fwidth(r), 1e-5);
        float disc = 1.0 - smoothstep(stud_radius - aa, stud_radius, r);
        float rn = clamp(r / max(stud_radius, 1e-4), 0.0, 1.0);
        vec3 dome = normalize(vec3(rel.x, stud_radius * (1.0 - rn * rn) + 0.02, rel.y));
        NORMAL = normalize(mix(NORMAL, dome, disc * stud_dome));
    }
    // No faked contact shadow here, unlike terrain (section 4): on a moving,
    // specular, terraced surface it reads as noise, and it is two taps saved.

    ALBEDO = albedo;
    ROUGHNESS = water_roughness;
    METALLIC = 0.0;
    SPECULAR = 0.6;
}
