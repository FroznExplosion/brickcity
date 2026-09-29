shader_type spatial;
render_mode cull_back, diffuse_burley, specular_schlick_ggx;

// L in heightfield_test: tint every piece of ground by its LOD level. 0 is
// the detailed tiles; a coarse block says its own level per instance.
uniform bool lod_debug = false;
instance uniform float lod_level = 0.0;
// SMOOTH FAR GROUND DRAWN AS COURSES (Terrain.md 19.19): a smooth coarse block
// has no bricks in it, so the shader draws what a brick hillside would show
// at that distance -- a darker line at every course (0.42 m) and each course
// a touch lighter at its top than its foot -- and the far ground reads as
// terraced rather than as a rubber sheet. Only on smooth far ground.
uniform bool far_courses = true;
uniform float far_course_m = 0.42;
uniform float far_course_line : hint_range(0.0, 1.0) = 0.35;
uniform float far_course_shade : hint_range(0.0, 0.5) = 0.10;

// Brick ground. brick.gdshader's seam, plus the two things terrain adds:
// painted studs and their faked contact shadow.
//
// The contract from the mesher is the same one brick.gdshader already defines:
//
//   UV   = position within the PIECE's face rectangle, in metres
//   UV2  = that rectangle's size, in metres
//
// so a 2x4 plate carries UV2 = (0.70, 1.40) and gets ONE outline around the
// whole 2x4 — not a grid of eight 1x1s. That is the difference between a floor
// that reads as laid brick and one that reads as a moulded baseplate, and it
// is why the mesher packs (Docs/Terrain.md section 6.2) instead of greedy-
// merging.
//
//   COLOR.rgb = the piece's filament colour, jittered per piece
//   COLOR.a   = 1 where the piece takes studs, 0 where it does not
//
// A piece never spans the plate/non-plate boundary, because the packer forces
// a cut there, so one flag per piece is exact.

group_uniforms seams;
uniform bool seams_enabled = true;
uniform float seam_width : hint_range(0.0, 0.05) = 0.010;
uniform float seam_darken : hint_range(0.0, 1.0) = 0.55;
uniform float seam_fade_begin = 30.0;
uniform float seam_fade_end = 90.0;

group_uniforms chamfer;
// Ported from brick.gdshader, which had it and this did not -- so terrain
// pieces read flatter than city bricks for no reason anyone chose. Same
// figure, same fade: a moulded brick chamfers about 0.3 mm on an 8 mm stud,
// which is 13 mm at 0.35 m studs, and a sub-pixel highlight shimmers so it
// goes away by 55 m.
//
// SHADED, not built. The argument for not building it is in brick.gdshader:
// a chamfer on every edge of every block is five times the triangles for a
// bevel that is two pixels past eight metres, and it would mean rebuilding a
// baked vertex buffer on a distance test. Real bevels go on shared instanced
// meshes instead -- PieceMeshes.chamfered_box and the stud's rim.
uniform bool chamfer_enabled = true;
uniform float chamfer_width : hint_range(0.0, 0.05) = 0.013;
uniform float chamfer_fade_begin = 18.0;
uniform float chamfer_fade_end = 55.0;
uniform float chamfer_gloss : hint_range(0.0, 1.0) = 0.45;

group_uniforms studs;
// Docs/Terrain.md section 7.2 tier 1: the cheapest stud there is. A dome
// normal inside each stud cell, in a fragment shader the ground is already
// paying for. No geometry, no memory, ~15 ALU.
uniform bool studs_enabled = true;
uniform float stud_pitch = 0.35;     // one stud
uniform float stud_radius = 0.105;   // 4.8 mm contact diameter at 1:43.75
uniform float stud_height = 0.074;
uniform float stud_dome : hint_range(0.0, 1.0) = 0.75;
// The painted dome fades IN across the same band the geometry tier fades
// OUT over (TerrainTile.STUD_RANGE = 18 m, margin 6 m), so the two tiers hand
// over instead of both drawing. Before this the geometry simply occluded the
// paint underneath it -- right to look at, but paid for twice.
uniform float stud_near_begin = 18.0;
uniform float stud_near_end = 24.0;
uniform float stud_fade_begin = 45.0;
uniform float stud_fade_end = 70.0;

group_uniforms stud_shadow;
// Section 7.4. Studs never cast: 8.3k instances through two cascades is ~365k
// depth-only triangles a frame, to draw a shadow 0.07 m long. The SURFACE
// draws it instead, analytically, from the same cell maths the dome uses --
// which also means it is still there under tier 1, where no stud geometry
// exists at all.
uniform bool stud_shadows_enabled = true;
uniform vec3 sun_dir = vec3(0.55, 0.72, 0.42);  // surface -> light, world space
uniform float contact_darken : hint_range(0.0, 1.0) = 0.72;

group_uniforms print;
// Layer lines and nozzle paths. Spec section 2 asks for these procedurally
// and never as a texture, and the reasons are worth restating because they
// decide it outright: a texture would need unwrapping per part at a density
// that changes with part size, and it would SWIM on debris as it tumbles.
// Evaluated in world space it tumbles correctly for nothing.
//
// A printer lays ~0.2 mm layers and a brick is 9.6 mm tall, so a brick is
// 48 layers. At 0.42 m that is 8.75 mm a layer -- visible close, gone by
// about fifteen metres, and it has to fade or it aliases into a moire.
uniform bool print_lines_enabled = true;
// 0.46 mm layers through a 0.55 mm nozzle, at 1:43.75 -- twenty-one layers
// a course. 0.2 mm is the commoner real setting and was tried first;
// at this scale it is 8.75 mm, which is one screen pixel at two metres,
// so the resolve filter below discarded the entire pattern and the
// print read as switched off.
uniform float layer_height = 0.020;
uniform float layer_darken : hint_range(0.0, 1.0) = 0.86;
// How much each bead stands proud of its neighbour. A drawn line is a line;
// a ridge catches the light and reads as a stacked bead, which is the whole
// difference between "lines on the surface" and "printed".
uniform float layer_relief : hint_range(0.0, 1.0) = 0.28;
// A slicer walks the part's outline two or three times before it infills,
// and on a top face those loops are the thing you actually see: they follow
// the PERIMETER of the piece, not a grid.
uniform int perimeters : hint_range(0, 4) = 3;
// Walk the outline all the way to the middle instead of infilling. True: a
// brick top is a small part and a slicer fills one with loops.
uniform bool top_concentric = false;
uniform float print_fade_begin = 7.0;
uniform float print_fade_end = 22.0;
// Nozzle path spacing on a top surface: the width of one extruded bead.
uniform float bead_width = 0.024;
// Half-width of the shadow between two beads, as a fraction of one bead.
uniform float bead_groove : hint_range(0.0, 0.5) = 0.17;
// Where the pattern starts and finishes dissolving, in beads a pixel.
// Below ~0.3 a bead is several pixels wide and is worth drawing; past
// ~0.75 it is under a pixel and drawing it only makes it crawl.
uniform float resolve_begin : hint_range(0.05, 1.0) = 0.30;
uniform float resolve_end : hint_range(0.1, 2.0) = 0.75;

group_uniforms surface;
// PLASTIC, not card. 0.9 was matte paper; ABS is glossy, and the tight
// highlight that moves across a bevel as you walk is most of what says
// "hard shiny object". The rim term is thin plastic glowing at its edges.
//
// Later this becomes a per-block material id into a table -- ABS, wood-fill,
// metal-fill, TPU -- which is one byte beside the filament colour and one
// branch here. See Docs/Terrain.md section 18.3.
uniform float surface_roughness : hint_range(0.0, 1.0) = 0.42;
uniform float surface_specular : hint_range(0.0, 1.0) = 0.55;
uniform float surface_rim : hint_range(0.0, 1.0) = 0.35;

group_uniforms materials;
// THE MATERIAL TABLE. Docs/Terrain.md 18.3.
//
// Colour says which filament; this says what it is MADE of. Two spools the
// same grey behave nothing alike — filled plastics are rough and dead,
// polished ABS is glossy, TPU is soft and slightly waxy — and none of that
// is in the albedo.
//
// The mesher writes the terrain material per vertex into CUSTOM0.r, so
// stone reads as stone next to grass without a second draw call or a second
// material. Indexed the same way the generator numbers them: 0 air (never
// drawn), 1 grass, 2 dirt, 3 sand, 4 stone, 5 dark stone, 6 road.
//
// Each entry is (roughness multiplier, specular multiplier, rim multiplier).
uniform bool materials_enabled = true;
const vec3 MATERIAL_TABLE[7] = {
    vec3(1.0, 1.0, 1.0),    // air, never drawn
    vec3(1.35, 0.55, 0.8),  // grass: matte, almost no highlight
    vec3(1.45, 0.40, 0.6),  // dirt: the deadest thing in the world
    vec3(1.15, 0.75, 0.9),  // sand: fine and slightly bright
    vec3(1.05, 0.95, 1.0),  // stone: close to plain plastic
    vec3(0.95, 1.10, 1.1),  // dark stone: denser, a harder highlight
    vec3(0.70, 1.35, 1.0)   // road: smoothed over, the glossiest ground
};

varying vec2 v_uv;
varying vec2 v_face;
varying vec3 v_world;
varying float v_studded;
varying vec3 v_flat_normal;
// FLAT, and read in the vertex stage: CUSTOM0 does not exist in a fragment
// shader, and a material index has no business being interpolated across a
// triangle anyway — half-stone is not a material.
varying flat float v_material;
varying float v_smooth_far;

void vertex() {
    v_uv = UV;
    v_face = UV2;
    v_world = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
    v_studded = COLOR.a;
    v_flat_normal = normalize(NORMAL);
    v_material = CUSTOM0.r;
    v_smooth_far = CUSTOM0.g;
}

const float TAU_F = 6.28318530718;

float hash21(vec2 p) {
    return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453);
}

/// Distance from p to the boundary of a regular n-gon of the given radius,
/// with a vertex on +X -- the orientation PieceMeshes.stud() builds, so the
/// painted stud and the geometry stud print the same shape.
float ngon_depth(vec2 p, int n, float radius) {
    float apothem = radius * cos(3.14159265 / float(n));
    float worst = 0.0;
    for (int i = 0; i < n; i++) {
        float a = TAU_F * (float(i) + 0.5) / float(n);
        worst = max(worst, dot(p, vec2(cos(a), sin(a))));
    }
    return apothem - worst;
}

// Distance from p to the segment a..b. The stud's shadow is its disc swept
// along the light's horizontal offset, which is a stadium, and a stadium is
// one segment distance and one radius compare.
float seg_dist(vec2 p, vec2 a, vec2 b) {
    vec2 ab = b - a;
    float len2 = max(dot(ab, ab), 1e-8);
    float t = clamp(dot(p - a, ab) / len2, 0.0, 1.0);
    return length(p - (a + ab * t));
}

// The LOD debug palette: 0 red, 1 orange, 2 yellow, 3 green, 4 cyan, 5 blue,
// 6 purple, 7+ magenta.
vec3 lod_colour(float lod) {
    int i = clamp(int(floor(lod + 0.5)), 0, 7);
    vec3 c[8] = vec3[8](vec3(0.95, 0.15, 0.12), vec3(1.0, 0.55, 0.1), vec3(0.95, 0.9, 0.15),
        vec3(0.2, 0.85, 0.25), vec3(0.15, 0.85, 0.9), vec3(0.2, 0.35, 1.0),
        vec3(0.6, 0.25, 0.95), vec3(0.95, 0.2, 0.8));
    return c[i];
}

void fragment() {
    vec3 albedo = COLOR.rgb;
    float dist = length(VERTEX);
    float surface_gloss = 1.0;

    // UV2 ZERO means CURVED GROUND: not a piece, so it has no outline to
    // draw a seam around and no perimeter for the nozzle to walk. Without
    // this test `mod(v_uv, 0)` is a divide by zero and the whole surface
    // goes to NaN.
    bool no_piece = v_face.x <= 0.0 || v_face.y <= 0.0;
    vec2 cell = no_piece ? v_uv : mod(v_uv, v_face);
    vec2 to_edge = no_piece ? vec2(1e6) : min(cell, v_face - cell);

    // --- a tangent frame, in the SAME SPACE as NORMAL ----------------------
    //
    // `NORMAL` in a Godot fragment shader is in VIEW space. The first version
    // of the chamfer below built its tilt as a world-space, Y-up vector and
    // assigned it straight into NORMAL, so it bent the normal in an arbitrary
    // direction relative to the camera and did nothing recognisable -- which
    // is why the bevel was visible on the studs, which are real geometry, and
    // invisible on the bricks, which are shaded.
    //
    // Screen-space derivatives give a frame wherever the face actually is:
    // no TANGENT is written by the mesher, faces point six ways, and a
    // falling chunk can be at any angle. This is brick.gdshader's frame,
    // which terrain should have been using from the start.
    vec3 dp_x = dFdx(VERTEX);
    vec3 dp_y = dFdy(VERTEX);
    vec2 duv_x = dFdx(v_uv);
    vec2 duv_y = dFdy(v_uv);
    float det = duv_x.x * duv_y.y - duv_y.x * duv_x.y;
    bool has_frame = abs(det) > 1e-12;
    vec3 tangent = vec3(0.0);
    vec3 binormal = vec3(0.0);
    if (has_frame) {
        tangent = normalize((dp_x * duv_y.y - dp_y * duv_x.y) / det);
        binormal = normalize((dp_y * duv_x.x - dp_x * duv_y.x) / det);
    }

    if (seams_enabled && !no_piece) {
        // UV is wrapped by UV2 first. For a real piece UV never leaves
        // [0, UV2), so this changes nothing -- but it lets a coarse LOD hand
        // over a merged quad with a piece-sized UV2 and still get outlines.
        float d = min(to_edge.x, to_edge.y);
        float aa = max(fwidth(d), 1e-5);
        // ANALYTIC COVERAGE: how much of THIS PIXEL the seam band covers.
        //
        // The seam is the band d < seam_width, and a pixel spans `aa` in d,
        // so the fraction of it inside the band is one clamp. As the seam
        // goes sub-pixel the coverage falls off by itself and the line just
        // gets fainter.
        //
        // What was here before widened the line to a minimum of one pixel
        // and kept it at full contrast. At a grazing angle `d` changes fast
        // along the edge, so which pixels the widened line landed in shifted
        // with every small camera move: the seam broke into DASHES that
        // crawled, and that -- not the layer lines -- was most of what read
        // as z-fighting on the ground. Turning the seams off and leaving the
        // print on is what proved it.
        float seam = clamp((seam_width - d) / aa + 0.5, 0.0, 1.0);
        float fade = 1.0 - smoothstep(seam_fade_begin, seam_fade_end, dist);
        albedo *= mix(1.0, seam_darken, seam * fade);
    }

    if (chamfer_enabled && chamfer_width > 0.0 && has_frame) {
        // A chamfer is a FLAT facet, so the tilt switches on across the band
        // rather than ramping with depth -- with one pixel of smoothing so
        // the switch does not crawl.
        vec2 aa2 = max(fwidth(to_edge), vec2(1e-5));
        vec2 band = vec2(chamfer_width);
        vec2 inside = smoothstep(band, band + aa2, to_edge);
        vec2 side = vec2(cell.x * 2.0 < v_face.x ? -1.0 : 1.0,
                         cell.y * 2.0 < v_face.y ? -1.0 : 1.0);

        // 45 degrees is equal parts face normal and edge direction.
        vec3 bevel = NORMAL
                + tangent * side.x * (1.0 - inside.x)
                + binormal * side.y * (1.0 - inside.y);
        float fade = 1.0 - smoothstep(chamfer_fade_begin, chamfer_fade_end, dist);
        NORMAL = normalize(mix(NORMAL, normalize(bevel), fade));
        float on_bevel = max(1.0 - inside.x, 1.0 - inside.y) * fade;
        surface_gloss = mix(1.0, chamfer_gloss, on_bevel);
    }

    // Studs only exist on up-facing surfaces. A skirt and a ramp are not
    // plates, and the mesher has already said so through COLOR.a -- but the
    // normal test costs nothing and catches the skirt of a studded piece.
    float up = clamp(v_flat_normal.y, 0.0, 1.0);
    float has_stud = v_studded * step(0.95, up);
    // Read by the print pass: two dark patterns multiplied over each other
    // at a grazing angle is noise, not detail.
    float stud_shade = 0.0;

    if (has_stud > 0.5) {
        // The stud cell this fragment is in, in world XZ, so studs line up
        // across piece boundaries and across tile boundaries -- they are on
        // the global lattice, like everything else (D5).
        vec2 c = (floor(v_world.xz / stud_pitch) + 0.5) * stud_pitch;
        vec2 rel = v_world.xz - c;
        float r = length(rel);

        if (stud_shadows_enabled) {
            // Where the top of the stud's shadow lands. Clamped to one cell so
            // a low sun never needs more than the two taps below; the error at
            // sunset hides inside the building shadows that dominate anyway.
            vec2 off = -sun_dir.xz / max(sun_dir.y, 0.2) * stud_height;
            float m = length(off);
            if (m > stud_pitch) {
                off *= stud_pitch / m;
            }
            // This cell, and the one the shadow could be reaching in from.
            vec2 c2 = (floor((v_world.xz - off) / stud_pitch) + 0.5) * stud_pitch;
            float t1 = seg_dist(v_world.xz, c, c + off);
            float t2 = seg_dist(v_world.xz, c2, c2 + off);
            float t = min(t1, t2);
            float aa = max(fwidth(t), 1e-5);
            float shade = 1.0 - smoothstep(stud_radius, stud_radius + aa + 0.01, t);
            stud_shade = shade;
            albedo *= mix(1.0, contact_darken, shade);
        }

        if (studs_enabled && has_frame) {
            float aa = max(fwidth(r), 1e-5);
            float disc = 1.0 - smoothstep(stud_radius - aa, stud_radius, r);
            // Fade out where the geometry tier has taken over, and again at
            // range where a stud is under a pixel and the pattern would
            // shimmer -- the same reason spec section 2 gives for layer lines.
            float fade = smoothstep(stud_near_begin, stud_near_end, dist)
                    * (1.0 - smoothstep(stud_fade_begin, stud_fade_end, dist));
            float k = disc * fade * stud_dome;
            // A dome: tilt the normal radially outward, strongest at the rim.
            // Through the tangent frame, for the same reason the chamfer is --
            // `rel` is a world-space offset and NORMAL is not.
            float rn = clamp(r / max(stud_radius, 1e-4), 0.0, 1.0);
            vec3 dome = normalize(NORMAL
                    + (tangent * rel.x + binormal * rel.y) * (rn / max(stud_radius, 1e-4)));
            NORMAL = normalize(mix(NORMAL, dome, k));
            // A touch of rim darkening so the disc reads even head-on, where
            // a normal perturbation alone does almost nothing.
            albedo *= mix(1.0, 0.94, k * smoothstep(0.55, 1.0, rn));
        }
    }

    // --- printed surface -------------------------------------------------
    float print_rough = 0.0;
    if (print_lines_enabled) {
        float fade = 1.0 - smoothstep(print_fade_begin, print_fade_end, dist);
        if (fade > 0.0) {
            // `t` counts beads or layers, and it stays CONTINUOUS: the
            // ridge normal below comes from its screen-space gradient, and
            // fract() would put a cliff in that gradient once a bead.
            float t;
            if (abs(v_flat_normal.y) > 0.7) {
                // A TOP face shows the nozzle's PATH, not layers, and a
                // nozzle does not raster a part edge to edge: it walks the
                // outline two or three times first, then infills what is
                // left. Concentric rings inside a stud disc were the first
                // attempt and were wrong twice over -- the loops follow the
                // whole PIECE, and a stud is an octagon, not a circle.
                vec2 c2 = (floor(v_world.xz / stud_pitch) + 0.5) * stud_pitch;
                vec2 rel2 = v_world.xz - c2;
                float sd = ngon_depth(rel2, 8, stud_radius);
                // Only when the painted stud is the one being drawn. Inside
                // the geometry tier the stud is a real mesh with its own
                // paths, and drawing a second set on the ground underneath
                // it put two patterns in the same pixels.
                bool painted_stud = has_stud > 0.5 && sd > 0.0
                        && dist > stud_near_begin;
                if (painted_stud) {
                    // On a stud: loops around the stud's own outline.
                    t = sd / bead_width;
                } else if (no_piece) {
                    // Curved ground is not a moulded part and has no
                    // outline, so the head rasters it -- in WORLD space,
                    // because the curve is continuous across cells and a
                    // per-cell pattern would put a grid back on it.
                    t = dot(v_world.xz, vec2(0.7071, 0.7071)) / bead_width;
                } else {
                    // UV is the position inside the PIECE's face rectangle
                    // and UV2 is that rectangle, so the distance to the
                    // piece's outline is four subtractions -- the mesher
                    // already hands over everything this needs.
                    // A BORDER AND AN INFILL, which is what a slicer does
                    // and what a printed top looks like: two or three loops
                    // round the outline, then diagonal passes across the
                    // middle.
                    //
                    // Loops all the way in was the first attempt. Nested
                    // rectangles are four sets of parallel lines with a
                    // mitre seam running out of every corner, and that is
                    // exactly what it looked like -- the mitres read as
                    // creases, not as a path.
                    float d = min(min(v_uv.x, v_face.x - v_uv.x),
                                  min(v_uv.y, v_face.y - v_uv.y));
                    float wall = float(perimeters) * bead_width;
                    if (top_concentric || d < wall) {
                        t = d / bead_width;
                    } else {
                        // Which diagonal this piece was printed along.
                        // Hashed off the piece's own corner -- UV is the
                        // offset inside the piece, so world minus UV is
                        // that corner, the same for every fragment of it.
                        vec2 origin = v_world.xz - v_uv;
                        float flip = hash21(floor(origin / 0.35 + 0.5)) < 0.5
                                ? -1.0 : 1.0;
                        t = dot(v_uv, vec2(0.7071, flip * 0.7071)) / bead_width;
                    }
                }
            } else {
                // A side face shows LAYERS, stacked along the print axis --
                // world up, because terrain bricks are printed upright.
                t = v_world.y / layer_height;
            }

            float ph = fract(t);
            float aa = max(fwidth(t), 1e-5);
            // A CURVE's pattern gives up earlier than a piece's.
            //
            // A piece resets its nozzle path every 0.35-1.4 m, so the
            // near-Nyquist band -- where a bead is about a pixel and the
            // contrast is still full -- is broken into short stretches and
            // reads as texture. Curved ground has no piece to reset on: one
            // raster runs unbroken across the whole field, and that same
            // band becomes a single sheet of moire that swims with the
            // camera. Turning curves off "fixed the z-fighting" for exactly
            // this reason, which is how it was found.
            //
            // So a curve is treated as less resolvable than it is, and its
            // lines are drawn fainter. The ground still looks printed; it
            // just stops shimmering half a field at a time.
            bool curve_top = no_piece && abs(v_flat_normal.y) > 0.7;
            if (curve_top) {
                aa *= 1.7;
            }
            // ANALYTIC FILTERING, and this is what the shimmer was.
            //
            // A bead is 8.75 mm. Seen edge-on, or past a few metres, more
            // than one of them falls in a pixel -- and a pattern sampled
            // below its own frequency does not fade, it CRAWLS: every small
            // camera move re-picks which beads land on which pixels, and
            // the surface looks like it is fighting with itself. Distance
            // fade did not help because a grazing angle compresses the
            // beads at any distance.
            //
            // So the pattern dissolves toward its own average as soon as a
            // bead approaches a pixel, which is the only honest thing to
            // draw when the detail is no longer resolvable.
            float resolved = 1.0 - smoothstep(resolve_begin, resolve_end, aa);
            float groove = max(aa * 1.4, bead_groove);
            float ink = (1.0 - smoothstep(0.0, groove, abs(ph - 0.5))) * resolved;
            // Not on top of the stud's contact shadow: two dark patterns
            // multiplied in the same pixels is noise.
            ink *= 1.0 - 0.7 * stud_shade;
            if (curve_top) {
                ink *= 0.7;
            }
            albedo *= mix(1.0, layer_darken, ink * fade);

            // The bead itself, as relief: a round bead turns through its own
            // width, so the normal leans along the direction `t` grows in
            // and back again. Faded as a bead approaches a pixel, or the
            // ridges alias into a moire -- the same reason the lines fade.
            vec3 dpx = dFdx(VERTEX);
            vec3 dpy = dFdy(VERTEX);
            vec3 grad = dpx * dFdx(t) + dpy * dFdy(t);
            float glen = length(grad);
            if (glen > 1e-8 && resolved > 0.0) {
                // SQUARED, and this is the crawl that survived the first
                // fix. Banding in albedo stops aliasing as soon as it is
                // filtered; a normal does not, because a half-resolved ridge
                // still swings the SPECULAR highlight a long way for a small
                // camera move, and a bright moving speckle reads as
                // z-fighting. Normals have to give up earlier than colour.
                float relief_k = resolved * resolved;
                NORMAL = normalize(NORMAL
                        + (grad / glen) * sin(ph * TAU_F)
                          * layer_relief * fade * relief_k);
                // ...and the roughness takes over what the normal drops.
                // A bead that is no longer resolved has not gone away: it is
                // sub-pixel roughness now, and saying so is what stops the
                // highlight from sparkling where the ridges used to be.
                print_rough = (1.0 - relief_k) * fade * layer_relief * 0.8;
            }
        }
    }

    vec3 mtl = vec3(1.0);
    if (materials_enabled) {
        // CUSTOM0.r is a unit float of the byte the mesher wrote.
        int mi = int(round(v_material * 255.0));
        mtl = MATERIAL_TABLE[clamp(mi, 0, 6)];
    }

    if (far_courses && v_smooth_far > 0.5) {
        float c = v_world.y / far_course_m;
        float fw = max(fwidth(c), 1e-4);
        float f = fract(c);
        // The course's foot: an anti-aliased line, as wide as a pixel allows.
        float line = 1.0 - smoothstep(0.0, 1.5 * fw, min(f, 1.0 - f));
        // Gone where a course is under ~2 px: past that it is moire.
        line *= 1.0 - smoothstep(0.25, 0.5, fw);
        albedo *= 1.0 - line * far_course_line;
        albedo *= 1.0 - far_course_shade + 2.0 * far_course_shade * f;
    }
    if (lod_debug) {
        albedo = mix(albedo, lod_colour(lod_level), 0.65);
    }
    ALBEDO = albedo;
    ROUGHNESS = clamp(surface_roughness * surface_gloss * mtl.x + print_rough,
            0.0, 1.0);
    SPECULAR = surface_specular * mtl.y;
    RIM = surface_rim * mtl.z;
    RIM_TINT = 0.4;
}
