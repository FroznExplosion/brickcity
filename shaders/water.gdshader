shader_type spatial;
render_mode cull_disabled, diffuse_burley, specular_schlick_ggx;
//
// CULL_DISABLED because the piece mesh has no bottom face: it is a top and
// four sides, so from underneath the only thing a back-face cull leaves is
// the sides. Drawing the top from below costs the back faces of a thin
// sheet and is what lets the sides go away entirely down there.

// Brick water. Docs/Water.md section 3, rewritten — see Terrain.md 18.2.
//
// One 1x1 flat-topped brick per stud cell of a camera-following grid. The
// instance count is fixed at startup and NOTHING is ever created or
// destroyed: a piece that should not be seen scales to zero, and a piece
// below its neighbours is hidden behind their columns.
//
// This replaces a version that packed varied piece sizes in the vertex
// shader — walking a cut lattice, finding piece origins, bonding row pairs.
// All of that existed to make 2x4s out of water, and fixed 1x1 pieces delete
// every line of it.
//
// A WAVE IS COLOUR, NOT SHAPE, between the brick steps. The surface moves in
// 0.42 m jumps and tints continuously, so a swell reads as a travelling band
// of pale bricks with white tops. That is the brick-film look, it costs one
// mix, and it still reads at distances where a 0.42 m step is under a pixel.
//
// The wave constants are NOT here. They arrive as `waves`, packed by
// BrickWave.uniform_array(), so the shader and the buoyancy solver cannot
// disagree about where the surface is (Water section 1).

group_uniforms wave;
uniform vec4 waves[8];
uniform int wave_count = 2;
// Wave GROUPS and the SHORE BAND (Water.md §8): BrickWave.group_uniform_array()
// and shore_band_uniform(), the same numbers BrickWave::height_at uses.
uniform vec4 groups[4];
uniform int group_count = 0;
uniform vec4 shore_band = vec4(0.0);
uniform float wave_time = 0.0;
uniform float sea_level = 1.1;
uniform float step_m = 0.42;
// Snap each piece to a brick course, the way the terrain is built.
//
// OFF. The bricks bob SMOOTHLY -- each 1x1 keeps its flat top and level
// attitude and simply rides the wave, which is what a brick sea looks like
// when the bricks are floating rather than stacked. A quantised surface
// makes the sea a staircase, and it is the one place in this project where
// the grid should not win: nothing is stacked ON the water, so nothing needs
// it to land on a course. Left here as a flag because the stepped version is
// worth being able to look at.
uniform bool brick_steps = false;
// How thick the sheet is where it is level, in metres.
//
// It was a full brick, which is what a stacked brick is -- and from below
// that is a wall of brick sides in every direction, because a 0.42 m skirt
// hanging off every piece is 0.42 m of side face with nothing behind it.
// One plate instead: the piece still reaches its lowest neighbour wherever
// the surface slopes, so the sheet is sealed, but where the sea is level it
// is a plate thick and there is nothing to see edge-on. Floating bricks are
// not stacked ones; only the part under water has to be there.
uniform float sheet_thickness = 0.14;
// The submerged seal: what a piece drops BELOW its lowest neighbour's top.
// Not zero, because the drop is computed from a float wave and the two
// pieces either side of a seam do not agree to the last bit; 5 mm is under
// a pixel at any distance you would see it from and closes that.
uniform float seam_seal = 0.005;
// There is NO amplitude knob here. Tall waves are wanted and the brick step
// is what makes them affordable -- a 3 m swell is seven steps, not a ramp
// needing more vertices -- but the gain is applied to the amplitudes inside
// BrickWave::uniform_array(), so the drawn surface and the one the swimmer
// reads cannot come apart. A `wave_gain` uniform here was 2.2x off the
// buoyancy solver for exactly as long as it existed.

group_uniforms grid;
uniform vec2 snapped_origin = vec2(0.0, 0.0);
uniform float stud = 0.35;
uniform int grid_side = 115;
uniform float fade_radius = 20.0;
// TIER 1 (Water 3.1). The same shader, the same wave, coarser pieces:
// `stud` becomes the coarse pitch, the piece is scaled to match, and
// everything inside `inner_radius` is dropped because tier 0's real 1x1
// bricks are already drawn there.
//
// One sheet that stops at 20 m is a disc of water with a cliff round it, in
// every wide shot. A second ring costs one more MultiMesh and no new code.
uniform float inner_radius = 0.0;
// TIER 2 (Water 3.2). The mesh is already a sheet in world space, so there
// is no instance to place and no brick to build: the vertex is moved
// straight onto the continuous wave. Past 80 m a 0.42 m step is under a
// pixel, and a smooth sheet cannot crack against the tier inside it.
uniform bool sheet_mode = false;
// The sheet FOLLOWS the camera now; inside this circle round the studded
// tier's centre it draws nothing, because the studded tier is there.
uniform vec2 hole_centre = vec2(0.0);
uniform float hole_radius = 0.0;

group_uniforms seabed;
uniform sampler2D seabed_tex : hint_default_black, filter_nearest;
uniform vec2 seabed_origin = vec2(0.0, 0.0);
uniform vec2 seabed_extent = vec2(1.0, 1.0);
uniform float open_sea_depth = 8.0;
// Is there sea beyond the seabed texture?
//
// For a streaming world the texture is a window onto an infinite field and
// the answer is yes. For a BOUNDED one -- every test scene -- it is no, and
// saying yes drew water hovering over the void past the last tile, with the
// sky's ground colour under it. Default no: a field with edges is the case
// that renders wrong.
uniform bool water_outside_field = false;
// Waves die as the water shallows. Without this a 3 m swell drives bricks
// straight through the beach; with it the surf flattens as it runs in, which
// is both correct and the reason tall waves are safe to allow at all.
uniform float shore_taper_depth = 2.5;

group_uniforms underwater;
// Colour only. The geometry does not change when the camera goes under --
// see the column comment in vertex() for what happened when it did. The rest
// of the submerged look is Environment fog (scripts/underwater.gd), because
// the tell is the crisp sky, not the water.
uniform bool camera_submerged = false;
uniform vec4 deep_tint : source_color = vec4(0.10, 0.28, 0.40, 1.0);
/// Depth at which absorption is at its strongest, in metres.
uniform float absorption_depth = 6.0;

group_uniforms look;
uniform vec4 trough_colour : source_color = vec4(0.09, 0.26, 0.40, 1.0);
uniform vec4 crest_colour : source_color = vec4(0.42, 0.72, 0.78, 1.0);
uniform vec4 foam_colour : source_color = vec4(0.92, 0.95, 0.96, 1.0);
uniform float foam_at : hint_range(0.0, 1.0) = 0.80;
uniform float water_roughness : hint_range(0.0, 1.0) = 0.22;

group_uniforms print;
// The water is printed plastic like everything else here: nozzle paths
// across the top of a piece, layer lines down its sides. Same numbers as
// terrain.gdshader and the same analytic filter -- a bead that cannot be
// resolved is dissolved rather than drawn, or it crawls.
//
// ALBEDO ONLY, no bead relief: a ridged normal on a surface this specular
// is a field of moving highlights, which is the one thing water does not
// need more of.
uniform bool print_lines_enabled = true;
uniform float layer_height = 0.020;
uniform float bead_width = 0.024;
uniform float bead_groove : hint_range(0.0, 0.5) = 0.17;
uniform float layer_darken : hint_range(0.0, 1.0) = 0.92;
uniform float resolve_begin : hint_range(0.05, 1.0) = 0.30;
uniform float resolve_end : hint_range(0.1, 2.0) = 0.75;
uniform float print_fade_begin = 7.0;
uniform float print_fade_end = 22.0;

group_uniforms studs;
// OFF. A flat-topped water brick is what this wants to be: studs on water
// say "you could build on this", and the surface they were drawn on is a
// wave. Kept as a uniform because the lattice they run on is still the
// thing that proves the pieces are aligned.
uniform bool studs_enabled = false;
uniform float stud_radius = 0.105;
uniform float stud_dome : hint_range(0.0, 1.0) = 0.8;

group_uniforms stop_motion;
// OFF with smooth motion. A continuous height sampled at 12 Hz does not read
// as stop-motion, it reads as a stutter -- the brick-film look comes from
// the pieces being bricks, not from the clock. It belongs with `brick_steps`
// and the two are toggled together.
uniform float hold_seconds : hint_range(0.0, 0.25) = 0.0;

varying vec3 v_world;
varying float v_height01;   // 0 at the trough, 1 at the crest
varying float v_up;
varying float v_depth;   // still-water depth under this piece, in metres
varying float v_wave;    // local wave height here, in metres, after the taper
varying vec2 v_cell;     // position within this piece, in metres
varying float v_top;     // this piece's own top, in metres

float hash21(vec2 p) {
    return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453);
}

// The swell. `cell_m` is the spacing of the vertices drawing it: a wave under
// ~4 samples a wavelength lands between vertices and the surface boils, so on
// the coarse rings of the sheet the short waves fade out (MvsC's
// max_wave_number). The studded tier passes 0 and keeps everything.
float wave_raw_lod(vec2 p, float t, float cell_m) {
    float h = 0.0;
    for (int i = 0; i < wave_count; i++) {
        vec4 a = waves[i * 2];
        vec4 b = waves[i * 2 + 1];
        float len = 6.2831853 / max(a.y, 1e-4);
        float keep = cell_m > 0.0 ? smoothstep(4.0 * cell_m, 6.0 * cell_m, len) : 1.0;
        h += keep * a.x * sin(dot(vec2(a.z, a.w), p) * a.y - b.x * t + b.y);
    }
    return h;
}

float wave_raw(vec2 p, float t) {
    return wave_raw_lod(p, t, 0.0);
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

float total_amplitude() {
    float a = 0.0;
    for (int i = 0; i < wave_count; i++) {
        a += waves[i * 2].x;
    }
    return max(a, 1e-4);
}

float seabed_at(vec2 cell) {
    vec2 uv = (cell - seabed_origin) / seabed_extent;
    if (uv.x > 0.0 && uv.x < 1.0 && uv.y > 0.0 && uv.y < 1.0) {
        return textureLod(seabed_tex, uv, 0.0).r;
    }
    // Dry land, absurdly high, so `top > ground` fails and the piece scales
    // to zero -- the same path the shoreline already takes.
    return water_outside_field ? -open_sea_depth : 1.0e6;
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

/// The shore band: phased on DEPTH, so crests are lines of equal depth and
/// they roll in toward the shore. BrickWave::band_at, restated.
float shore_wave(vec2 p, float t) {
    if (shore_band.x <= 0.0) {
        return 0.0;
    }
    float depth = sea_level - lattice_ground(p);
    if (depth <= 0.0) {
        return 0.0;
    }
    float w = smoothstep(0.3, 1.5, depth) * (1.0 - smoothstep(4.0, 9.0, depth));
    float drift = 1.2 * sin(0.013 * p.x + 0.7) + 1.2 * sin(0.011 * p.y + 2.1);
    return shore_band.x * w * sin(shore_band.y * depth + shore_band.z * t + drift);
}

/// The whole surface above still water: swell shaped by the groups and dying
/// in the shallows, plus the band. BrickWave::height_at minus sea_level.
float surface_offset(vec2 p, float t, float taper, float cell_m) {
    float band = shore_wave(p, t);
    // The band is short in distance; only the finest rings can draw it.
    if (cell_m > 0.0) {
        band *= 1.0 - smoothstep(2.0, 6.0, cell_m);
    }
    return wave_raw_lod(p, t, cell_m) * taper * group_factor(p, t) + band;
}

/// Where this cell's brick sits, in metres.
///
/// SMOOTH by default: the piece rides the wave continuously and only its
/// NEIGHBOURS' heights differ, so the sea is a field of flat-topped 1x1
/// bricks at slightly different levels rather than a staircase locked to
/// 0.42 m. `brick_steps` puts the quantiser back for comparison.
float surface_top(vec2 cell, float t) {
    float taper = clamp((sea_level - seabed_at(cell)) / shore_taper_depth, 0.0, 1.0);
    float h = sea_level + surface_offset(cell, t, taper, 0.0);
    return brick_steps ? floor(h / step_m) * step_m : h;
}

void vertex() {
    if (sheet_mode) {
        // World position: the sheet node follows the camera in X and Z.
        vec2 cell = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xz;
        float ground = seabed_at(cell);
        float taper = clamp((sea_level - ground) / shore_taper_depth, 0.0, 1.0);
        // UV2.x carries this ring's vertex spacing (WaterSheet._ring_mesh).
        float raw = surface_offset(cell, wave_time, taper, UV2.x);
        VERTEX.y = sea_level + raw;
        v_world = vec3(cell.x, VERTEX.y, cell.y);
        v_height01 = clamp(raw / (total_amplitude() * max(taper, 1e-3))
                * 0.5 + 0.5, 0.0, 1.0);
        v_depth = sea_level - ground;
        v_wave = total_amplitude() * taper;
        v_up = 1.0;
        v_cell = vec2(0.0);
        v_top = VERTEX.y;
        // Dry land gets no sheet, the same test the brick tiers use.
        if (sea_level <= ground) {
            VERTEX = vec3(0.0);
        }
    } else {
    int id = INSTANCE_ID;
    int gx = id % grid_side;
    int gz = id / grid_side;
    // FLOORED, so the grid lands on whole cells.
    //
    // `grid_side` is odd (WaterSurface makes it so), so half of it ends in
    // .5 and every piece sat half a cell off the world lattice. The painted
    // studs are on that lattice -- `floor(xz / stud)` -- so each stud
    // straddled the corner of four pieces, which is exactly what it looked
    // like. The studs were right and the pieces were off.
    float half_side = floor(float(grid_side) * 0.5);
    vec2 cell = snapped_origin + (vec2(float(gx), float(gz)) - half_side) * stud;

    // The stop-motion hold is per ROW, never per cell: per-cell jitter made
    // neighbours sample the wave at different instants, disagree about their
    // step, and each assume the other would draw. Water section 3.4b.
    int row = int(floor(cell.y / stud + 0.5));
    float jitter = hash21(vec2(float(row), 3.0)) * hold_seconds;
    float t = hold_seconds > 0.0
        ? floor((wave_time + jitter) / hold_seconds) * hold_seconds
        : wave_time;

    float ground = seabed_at(cell);
    float taper = clamp((sea_level - ground) / shore_taper_depth, 0.0, 1.0);
    float raw = surface_offset(cell, t, taper, 0.0);
    float top = sea_level + raw;
    if (brick_steps) {
        top = floor(top / step_m) * step_m;
    }

    // How far each SIDE hangs below the top, decided PER FACE.
    //
    // One depth for the whole piece was the first version, and it is wrong
    // in an obvious way once you look at it: the piece drops to its LOWEST
    // neighbour on every side, so three sides hang lower than anything
    // asked them to. Each face only has to reach the neighbour it faces.
    //
    // History, since each step here was a fix taken too far:
    //
    //   a brick      a wall of brick sides in every direction from below
    //   a plate      still an edge on every piece, read as a stripe
    //   zero         no sides at all, and a GAP at every height change
    //   one seal     closed, but all four faces to the deepest neighbour
    //   per face     this
    //
    // The four axis neighbours, sampled once and shared by the four faces.
    float hxm = surface_top(cell - vec2(stud, 0.0), t);
    float hxp = surface_top(cell + vec2(stud, 0.0), t);
    float hzm = surface_top(cell - vec2(0.0, stud), t);
    float hzp = surface_top(cell + vec2(0.0, stud), t);

    float r = length(cell - snapped_origin);
    bool alive = r < fade_radius && r >= inner_radius && top > ground;
    if (alive) {
        // A side is a RECTANGLE: both bottom corners of a face go to the
        // same depth, the drop to the neighbour that face looks at.
        //
        // Giving each bottom CORNER its own depth closed the diagonal
        // exactly and slanted the bottom edge of every side, so from below
        // the sheet was a mesh of wedges. A brick has no sloped bottom.
        //
        // The diagonal is not a hole in practice: four pieces meet at a
        // corner POINT, each wall beside it drops to its own neighbour, and
        // what is left open is a slit of zero width. A wedge you can see
        // beats a slit you cannot.
        float depth = 0.0;
        if (VERTEX.y < -0.5) {
            float hf = abs(NORMAL.x) > 0.5
                    ? (NORMAL.x > 0.0 ? hxp : hxm)
                    : (NORMAL.z > 0.0 ? hzp : hzm);
            // Submerged: the seal and nothing more. Above: a plate, so the
            // sea still reads as bricks from a boat.
            float least = camera_submerged ? seam_seal : sheet_thickness;
            depth = max(top - min(hf, top), least);
        }
        // THE PIECE IS ONE CELL ACROSS, and it was not.
        //
        // `PieceMeshes.unit_plate()` is a UNIT plate: one METRE on a side,
        // because it is a mesh and not a brick. The grid it sits on is one
        // stud, 0.35 m. So every piece of water has been 2.9x oversized
        // since this shader was written, overlapping its neighbours three
        // deep in each direction -- which is where the "risers" that needed
        // shading down came from, and most of what made the underside a
        // thicket of sides. The painted studs are in world space and never
        // gave it away.
        //
        // `stud` is this tier's pitch in metres, so it is also exactly the
        // size a piece should be.
        vec2 local = VERTEX.xz * stud;
        VERTEX.y = -depth;
        VERTEX.xz = cell + local;
        VERTEX.y += top;
        v_cell = local;
        v_world = VERTEX;
        // Normalised against the LOCAL wave height, not the open-sea one.
        // Against the open-sea amplitude a tapered shore wave never left the
        // middle of the range, so inshore water had no crest tint and no
        // foam at all -- and the surf is exactly where foam belongs.
        v_height01 = clamp(raw / (total_amplitude() * max(taper, 1e-3))
                * 0.5 + 0.5, 0.0, 1.0);
        v_depth = sea_level - ground;
        v_wave = total_amplitude() * taper;
        v_top = top;
        v_up = step(0.5, NORMAL.y);
    } else {
        VERTEX = vec3(0.0);
        v_world = vec3(0.0);
        v_height01 = 0.0;
        v_up = 0.0;
        v_depth = 0.0;
        v_wave = 0.0;
        v_cell = vec2(0.0);
        v_top = 0.0;
    }
    }
}

void fragment() {
    if (sheet_mode && hole_radius > 0.0 && distance(v_world.xz, hole_centre) < hole_radius) {
        discard;
    }
    // Seen from below -- which is now a thing that happens, see the cull
    // mode -- the top face's normal points away from the viewer.
    if (!FRONT_FACING) {
        NORMAL = -NORMAL;
    }
    // The wave, as colour. Between two brick steps the surface cannot move,
    // so this is what carries the swell.
    vec3 albedo = mix(trough_colour.rgb, crest_colour.rgb, v_height01);
    // Foam on the RISERS too, at a little less. It was a top-face effect at
    // first, which made the stripe problem below a colour problem as well as
    // a lighting one: a white crest with mid-blue risers is a hard edge no
    // amount of normal shading can hide.
    if (v_height01 > foam_at) {
        // White tops at the crest, which is also the cheapest foam there is.
        //
        // Gated on the ABSOLUTE wave height, not the normalised one. The
        // crest tint is normalised so a shore wave still bands (§3.6b), but
        // applying that to foam whitened every millpond in the world: a
        // 5 cm ripple reached "1.0 of its own height" and went white. No
        // whitecaps under half a brick of swell.
        float whitecaps = clamp((v_wave - step_m * 0.5) / step_m, 0.0, 1.0);
        albedo = mix(albedo, foam_colour.rgb,
                smoothstep(foam_at, 1.0, v_height01) * whitecaps
                * (v_up > 0.5 ? 1.0 : 0.75));
    }
    // Absorption: the seabed texture's second job (Water section 5). Shallow
    // water shows the sand through it and deep water does not, and without
    // this a bay and an ocean are the same flat blue -- which is most of what
    // makes a brick sea read as a painted floor.
    albedo = mix(albedo, deep_tint.rgb, clamp(v_depth / absorption_depth, 0.0, 0.75));
    if (camera_submerged) {
        albedo = mix(albedo, deep_tint.rgb, 0.55);
    }

    // FRONT_FACING: the underside of a brick has no studs on it, and from
    // under water the top face is what you are looking at from behind.
    if (studs_enabled && v_up > 0.5 && FRONT_FACING) {
        vec2 c = (floor(v_world.xz / stud) + 0.5) * stud;
        vec2 rel = v_world.xz - c;
        float r = length(rel);
        float aa = max(fwidth(r), 1e-5);
        float disc = 1.0 - smoothstep(stud_radius - aa, stud_radius, r);
        float rn = clamp(r / max(stud_radius, 1e-4), 0.0, 1.0);
        // Through a screen-space tangent frame: NORMAL is in VIEW space, and
        // a world-space Y-up dome written into it bends somewhere arbitrary.
        vec3 dp_x = dFdx(VERTEX);
        vec3 dp_y = dFdy(VERTEX);
        vec2 duv_x = dFdx(v_world.xz);
        vec2 duv_y = dFdy(v_world.xz);
        float det = duv_x.x * duv_y.y - duv_y.x * duv_x.y;
        if (abs(det) > 1e-12) {
            vec3 T = normalize((dp_x * duv_y.y - dp_y * duv_x.y) / det);
            vec3 B = normalize((dp_y * duv_x.x - dp_x * duv_y.x) / det);
            vec3 dome = normalize(NORMAL
                    + (T * rel.x + B * rel.y) * (rn / max(stud_radius, 1e-4)));
            NORMAL = normalize(mix(NORMAL, dome, disc * stud_dome));
        }
    }

    // The risers.
    //
    // A smooth surface cut into 1x1 cells shows a riser wherever it slopes
    // away from the eye, and the riser is only as tall as the height change
    // across one stud -- about 3 cm at this sea state, measured. From a
    // metre above the water that is nothing in world terms and everything on
    // screen: at grazing incidence a 3 cm face covers 20-odd pixels and
    // hides the rows behind it, so the sea reads as hard dark stripes.
    // Shadows were the first suspect and are not involved; the same stripes
    // appear with the sun's shadow map off.
    //
    // The geometry is correct and the LIGHTING is what makes it look wrong,
    // so a side face is shaded most of the way toward the surface it belongs
    // to. The sea stays one surface and the bricks stay bricks. Tilting each
    // piece to the local gradient would remove the risers outright, at the
    // cost of pieces that no longer sit level -- not taken, because a brick
    // that tilts stops reading as a brick.
    if (v_up < 0.5) {
        vec3 up_view = normalize((VIEW_MATRIX * vec4(0.0, 1.0, 0.0, 0.0)).xyz);
        NORMAL = normalize(mix(NORMAL, up_view, 0.85));
    }

    if (print_lines_enabled) {
        float pfade = 1.0 - smoothstep(print_fade_begin, print_fade_end,
                length(VERTEX));
        if (pfade > 0.0) {
            float pt = v_up > 0.5
                    // The top: the nozzle walking the piece's outline. On a
                    // part one stud across that is loops all the way in --
                    // there is no room for infill.
                    ? (min(min(v_cell.x, stud - v_cell.x),
                           min(v_cell.y, stud - v_cell.y)) / bead_width)
                    // The sides: layers measured DOWN FROM THIS PIECE'S OWN
                    // TOP, so they ride with it instead of swimming through
                    // it as it bobs.
                    : ((v_top - v_world.y) / layer_height);
            float pph = fract(pt);
            float paa = max(fwidth(pt), 1e-5);
            float pres = 1.0 - smoothstep(resolve_begin, resolve_end, paa);
            float pgroove = max(paa * 1.4, bead_groove);
            float pink = (1.0 - smoothstep(0.0, pgroove, abs(pph - 0.5))) * pres;
            albedo *= mix(1.0, layer_darken, pink * pfade);
        }
    }

    ALBEDO = albedo;
    ROUGHNESS = water_roughness;
    METALLIC = 0.0;
    SPECULAR = 0.7;
}
