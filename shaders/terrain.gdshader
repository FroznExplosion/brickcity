shader_type spatial;
render_mode cull_back, diffuse_burley, specular_schlick_ggx;
#include "res://shaders/weather.gdshaderinc"
#include "res://shaders/print_underside.gdshaderinc"
#ifdef TERRAIN_BOX
#include "res://shaders/brick_boxed.gdshaderinc"
#endif

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
// How dark a ramp between two shelves is against a shelf's top.
uniform float far_ramp_shade : hint_range(0.3, 1.0) = 0.72;

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
// On the brick overlay's real bricks (TERRAIN_BOX) the drawn seam and the
// shaded chamfer fade IN with distance: none inside outline_blend_begin,
// where the geometry is the edge; both together out to outline_blend_end;
// the outline alone past it, where a 13 mm bevel is a pixel or two anyway.
uniform float outline_blend_begin = 3.0;
uniform float outline_blend_end = 9.0;
uniform float chamfer_width : hint_range(0.0, 0.05) = 0.013;
uniform float chamfer_fade_begin = 18.0;
uniform float chamfer_fade_end = 55.0;
uniform float chamfer_gloss : hint_range(0.0, 1.0) = 0.45;

group_uniforms overlay;
// THE BRICK OVERLAY's recess (Docs/BrickOverlay.md 2, stage 3). Within
// `overlay_reach` of the eye (TerrainBricks sets it each pick: how far its
// real bricks reach; 0 = no overlay) every flat face with a brick laid over
// it (CUSTOM0.b = 64, the bake's BOXED_FACE) sinks 13 mm along its normal:
// under the brick's box, so it neither z-fights the box's faces nor fills
// its chamfers -- between two bricks the groove's floor is this sunken face.
// It fades out over `overlay_fade` before the reach's edge. The boxes
// (TERRAIN_BOX) are drawn 2 mm toward the eye, so where the recess fades
// they still win the depth test against the face they lie on.
uniform float overlay_reach = 0.0;
uniform float overlay_fade = 1.5;
// BROKEN BRICKS, AT ONCE (stage 6): a shot hides its brick's box the same
// frame (TerrainBricks.hide_at); the flat faces of that brick fold to a point
// here till the rebuilt tile is drawn. World space; `overlay_holes` of them.
uniform int overlay_holes = 0;
uniform vec3 overlay_hole_lo[8];
uniform vec3 overlay_hole_hi[8];
const float OVERLAY_RECESS = 0.013;
const float OVERLAY_PULL = 0.002;

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
// Curved ground (UV2 zero) drawn PLAIN: no layer lines or nozzle paths. On a
// slope the layer lines are contours a course apart, and they read as the
// terraces the curve replaced (Terrain.md 18.7). Studs on its flat spots keep
// theirs.
uniform bool plain_curves = true;
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
// GLASS (Docs/TerrainBuildings.md 5): brick_terrain.h MAT_GLASS, a solid
// cell drawn see-through. The terrain is one opaque pass, so glass is a
// screen-door: a fixed 4x4 pattern of its pixels discarded (shadows too),
// the rest tinted and glossy. No overlay brick is laid over it, so it is
// never sunk (the recess is for faces under a real brick).
const int TERRAIN_GLASS = 39;
const float GLASS_OPEN = 0.55;
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
// CUSTOM0.b: a real bevel facet of the near mesh (MeshBuf::facet).
varying flat float v_facet;

#ifdef SKY_LIGHT
// SKY LIGHT IN THE CELLS (Docs/MineWorld.md 18). Only the mine world's copy
// of this shader has `#define SKY_LIGHT` (TerrainTile.ground_material); every
// other scene compiles none of this.
//
// CUSTOM0.a is the vertex's sky light, levels 0..15 as 0..1, spread through
// the cells by the bake (BrickTerrain sky_light_pass). Minecraft's curve,
// 0.8^(15 - level), run from `sky_light_floor` up to 1, scales the ambient
// (AO) and the SUN (light() below), per pixel: an enclosed cave is dark, its
// open mouth and the world outside are not. The environment itself is the
// open air's; only the exposure follows the eye.
uniform float sky_light_floor : hint_range(0.0, 0.2) = 0.015;
uniform float sky_light_curve : hint_range(0.5, 0.95) = 0.8;
// The sun falls off faster than the sky's light: it comes from one way.
uniform float sky_sun_power : hint_range(1.0, 4.0) = 2.0;
// BLOCK LIGHT from lava (Docs/MineWorld.md 18): CUSTOM0.g on the near tiles
// and deep sections, levels 0..15 as bytes 0..60 -- under the far meshes'
// 128 and 255 (smooth far ground), which read as none here. The same curve
// as the sky's; drawn as a warm glow x albedo (EMISSION), and it lifts the
// AO too (by `block_light_ao`), so a lava-lit cave wall takes some ambient.
uniform vec3 block_light_colour : source_color = vec3(1.0, 0.52, 0.22);
uniform float block_light_energy : hint_range(0.0, 4.0) = 1.0;
uniform float block_light_ao : hint_range(0.0, 1.0) = 0.5;
// `-- --sky-debug=N` in the mine world: 1 the vertex's sky light, 2 the AO,
// 3 the block light, drawn flat (emission only).
uniform int sky_debug = 0;
varying float v_sky;
varying float v_block;
// Fragment to light(): the sun's share here, and the surface's specular and
// rim (light() cannot read the fragment's SPECULAR or RIM).
varying float l_sun;
varying float l_spec;
varying float l_rim;
#endif

#ifdef TERRAIN_BOX
// THE BRICK OVERLAY (Docs/BrickOverlay.md): this copy draws the real bricks
// laid over the flat ground near the camera (TerrainBricks), one instanced
// bevelled box a brick (BrickNear.bevel_box_mesh), scaled to the brick. What
// the flat mesh's vertices carry comes from the instance instead:
//   transform     the brick's box (scale its size, origin its middle)
//   COLOR         whole numbers: r its colour (8 bits a channel, red at bit
//                 0), g its faces' block light (face f at bit 4 f), a
//                 material * 2 + 1 if its top has studs
//   CUSTOM        its faces' sky light, 4 bits a face's corner: face f's
//                 corner c is level 4 f + c, six to a word
// Faces: +x 0, -x 1, +y 2, -y 3, +z 4, -z 5; a face's corner: bit 0 its u
// max, bit 1 its v max (x faces u z, v y; y faces u x, v z; z faces u x, v
// y). A bevel's facet takes the light of the face its normal leans to most.
// UV and UV2 are the box face's (brick_box_uv): one brick a face, so the seam
// and the print are the brick's own.
// The words are whole numbers, exact in a float: read as they are (`+ 0.5`
// rounds 2^24 - 1 up to 2^24 in a float, and a lit word read as 0).
int tb_nibble(float word, int n) {
    return (int(word) >> (4 * n)) & 15;
}
#endif

void vertex() {
#ifdef TERRAIN_BOX
    vec3 box_size = brick_box_size(MODEL_MATRIX);
    vec3 box_safe = max(box_size, vec3(1e-6));
    // Metres from the brick's middle, the 13 mm bevel taken off.
    vec3 box_at = VERTEX * box_size - sign(VERTEX) * brick_box_inset(UV.x, box_size);
    vec4 box_uv = brick_box_uv(box_size, box_at, NORMAL);
    v_uv = box_uv.xy;
    v_face = box_uv.zw;
    v_facet = 0.0;
    if (UV.y > 0.5) {
        // A bevel's facet: no piece (no seam, no shaded chamfer), plain on a
        // top's bevel. Its normal is 45 degrees in metres; the instance's
        // scale would lean it towards the brick's long side.
        v_uv = vec2(0.5, 1.0);
        v_face = vec2(-1.0);
        v_facet = 1.0;
        NORMAL = NORMAL / box_safe;
    }
    // Its face (by the mesh's own normal, a facet's to y first) and its
    // corner in that face.
    vec3 box_n = abs(UV.y > 0.5 ? NORMAL * box_safe : NORMAL);
    int box_face;
    int box_c;
    if (box_n.y >= box_n.x - 1e-4 && box_n.y >= box_n.z - 1e-4) {
        box_face = (UV.y > 0.5 ? (NORMAL * box_safe).y : NORMAL.y) > 0.0 ? 2 : 3;
        box_c = (VERTEX.x > 0.0 ? 1 : 0) | (VERTEX.z > 0.0 ? 2 : 0);
    } else if (box_n.x >= box_n.z) {
        box_face = (UV.y > 0.5 ? (NORMAL * box_safe).x : NORMAL.x) > 0.0 ? 0 : 1;
        box_c = (VERTEX.z > 0.0 ? 1 : 0) | (VERTEX.y > 0.0 ? 2 : 0);
    } else {
        box_face = (UV.y > 0.5 ? (NORMAL * box_safe).z : NORMAL.z) > 0.0 ? 4 : 5;
        box_c = (VERTEX.x > 0.0 ? 1 : 0) | (VERTEX.y > 0.0 ? 2 : 0);
    }
    VERTEX = box_at / box_safe;
    int box_code = int(COLOR.a + 0.5);
    v_studded = float(box_code & 1);
    v_material = float(box_code >> 1) / 255.0;
    v_smooth_far = 0.0;
    v_flat_normal = normalize(mat3(MODEL_MATRIX) * NORMAL);
#ifdef SKY_LIGHT
    int box_l = box_face * 4 + box_c;
    v_sky = float(tb_nibble(INSTANCE_CUSTOM[box_l / 6], box_l % 6)) / 15.0;
    v_block = float(tb_nibble(COLOR.g, box_face)) / 15.0;
#endif
    int box_rgb = int(COLOR.r);
    COLOR = vec4(float(box_rgb & 255), float((box_rgb >> 8) & 255), float((box_rgb >> 16) & 255),
            255.0 * float(box_code & 1)) / 255.0;
    v_world = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
#ifdef TERRAIN_CAVITY
    // A broken brick's hole, seen from inside (TerrainBricks: the stand-in
    // walls till its tile is rebuilt): its faces turned in.
    NORMAL = -NORMAL;
    v_flat_normal = -v_flat_normal;
#endif
    vec4 box_view = MODELVIEW_MATRIX * vec4(VERTEX, 1.0);
    box_view.xyz -= normalize(box_view.xyz) * OVERLAY_PULL;
    POSITION = PROJECTION_MATRIX * box_view;
#else
    v_uv = UV;
    v_face = UV2;
    v_world = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
    v_studded = COLOR.a;
    v_flat_normal = normalize(NORMAL);
    v_material = CUSTOM0.r;
    v_smooth_far = CUSTOM0.g;
    v_facet = CUSTOM0.b;
#ifdef SKY_LIGHT
    v_sky = CUSTOM0.a;
    v_block = CUSTOM0.g < 0.25 ? CUSTOM0.g * (255.0 / 60.0) : 0.0;
#endif
    float push = 0.0;
    // BEHIND faces (CUSTOM0.b = 96, Docs/BrickOverlay.md 6b): the solid behind
    // the overlay's bricks, there for a shot brick's hole. Only inside the
    // reach, where a brick can be shot out; collapsed past it (and with no
    // overlay), sunk like a boxed face inside it.
    bool behind = abs(CUSTOM0.b * 255.0 - 96.0) < 0.5;
    bool glass = int(round(CUSTOM0.r * 255.0)) == TERRAIN_GLASS;
    if (glass) {
        // Never under a brick: as it lies.
    } else if (behind && (overlay_reach <= 0.0
            || distance(v_world, INV_VIEW_MATRIX[3].xyz) >= overlay_reach)) {
        VERTEX = vec3(0.0);
    } else if ((overlay_reach > 0.0 || (overlay_holes > 0 && !behind))
            && (behind || abs(CUSTOM0.b * 255.0 - 64.0) < 0.5)) {
        // Covered faces fold where a hidden brick is at ANY range (a far shot
        // has no box, TerrainBricks._hide_far); they sink only in the reach.
        float od = distance(v_world, INV_VIEW_MATRIX[3].xyz);
        float ok = overlay_reach > 0.0
                ? 1.0 - smoothstep(overlay_reach - overlay_fade, overlay_reach, od) : 0.0;
        // Where the face would lie sunk along its normal: the hole test's
        // place in its brick (below) is measured from there.
        vec3 sunk = VERTEX - normalize(NORMAL) * (OVERLAY_RECESS * ok);
        bool folded = false;
        if (!behind && overlay_holes > 0 && UV2.x > 0.0 && UV2.y > 0.0) {
            // The middle of this face's BRICK face (UV is the place in it,
            // UV2 its size; the mesher's axes: x faces u along z (+ on +x),
            // z faces u along x (+ on -z), tops and bottoms u x and v z, a
            // side's v up), a centimetre into the brick.
            vec3 n = normalize(NORMAL);
            vec2 d = 0.5 * UV2 - UV;
            vec3 off;
            if (abs(n.x) > 0.5) {
                off = vec3(0.0, d.y, d.x * sign(n.x));
            } else if (abs(n.z) > 0.5) {
                off = vec3(-d.x * sign(n.z), d.y, 0.0);
            } else {
                off = vec3(d.x, 0.0, d.y);
            }
            vec3 mid = (MODEL_MATRIX * vec4(sunk + off - n * 0.01, 1.0)).xyz;
            for (int i = 0; i < 8; i++) {
                if (i >= overlay_holes) {
                    break;
                }
                if (all(greaterThan(mid, overlay_hole_lo[i])) && all(lessThan(mid, overlay_hole_hi[i]))) {
                    VERTEX = vec3(0.0);
                    folded = true;
                }
            }
        }
        // THE RECESS ALONG THE EYE'S RAY, not the face's normal (the user,
        // 2026-11-24: see-through slits at the grid; --gate=slits). Sunk
        // along its own normal each face moved apart from the next: a top
        // and the side under it, a sunk face and an unsunk filler strip, a
        // tile's edge. A vertex moved along its own ray from the eye stays
        // on the same pixel, so the ground covers exactly what it covered
        // and no slit can open; it goes back far enough to lie 13 mm under
        // the face along its normal (more at a grazing view), behind the
        // brick's box and its bevels as before.
        if (!folded && ok > 0.0) {
            vec3 ray = normalize((MODELVIEW_MATRIX * vec4(VERTEX, 1.0)).xyz);
            vec3 nv = normalize(mat3(MODELVIEW_MATRIX) * NORMAL);
            push = OVERLAY_RECESS * ok / max(abs(dot(nv, ray)), 0.25);
        }
    }
    // POSITION on every path: a shader that writes it anywhere uses it for
    // every vertex.
    vec4 vv = MODELVIEW_MATRIX * vec4(VERTEX, 1.0);
    vv.xyz += normalize(vv.xyz) * push;
    POSITION = PROJECTION_MATRIX * vv;
#endif
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
    if (int(round(v_material * 255.0)) == TERRAIN_GLASS) {
        // 4x4 ordered dither: the same pixels every frame, so it does not crawl.
        ivec2 q = ivec2(FRAGCOORD.xy) & ivec2(3);
        int bayer[16] = int[](0, 8, 2, 10, 12, 4, 14, 6, 3, 11, 1, 9, 15, 7, 13, 5);
        if ((float(bayer[q.y * 4 + q.x]) + 0.5) / 16.0 < GLASS_OPEN) {
            discard;
        }
    }
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

#ifdef TERRAIN_BOX
    // Real bevels: the drawn seam and shaded chamfer only fade in with range.
    float outline_w = smoothstep(outline_blend_begin, outline_blend_end, dist);
    // The model's axes without the instance's scale (the underside's walk).
    mat3 model3 = mat3(normalize(MODEL_MATRIX[0].xyz), normalize(MODEL_MATRIX[1].xyz),
            normalize(MODEL_MATRIX[2].xyz));
#else
    float outline_w = 1.0;
    mat3 model3 = mat3(MODEL_MATRIX);
#endif
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
        float fade = (1.0 - smoothstep(seam_fade_begin, seam_fade_end, dist)) * outline_w;
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
        float fade = (1.0 - smoothstep(chamfer_fade_begin, chamfer_fade_end, dist)) * outline_w;
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

    // --- the underside (Docs/MineWorld.md 20) -----------------------------
    //
    // A brick's bottom is OPEN: its rim, the ribs that stand in for tubes and
    // the hollow between them (print_surface's ps_underside), as a falling
    // brick draws it (brick.gdshader). A cave roof or an overhang is the
    // bottoms of the bricks over it, and drew as flat plastic. UV is the
    // place in the brick's bottom and UV2 that bottom (the mesher's), so the
    // pattern is the brick's own, across tile edges too.
    const float UNDER_BEAD = 0.020;  // print_surface bottom_bead_width
    float under_solid = 1.0;
    float under_occ = 1.0;
    if (underside_hollow && !no_piece && v_flat_normal.y < -0.95) {
        vec2 fsize = v_face;
        float usd = ps_under_sd(cell, fsize);
        under_solid = clamp(0.5 - usd / max(fwidth(usd), 1e-5), 0.0, 1.0);
        if (under_solid < 0.99) {
            float shade = mix(under_wall, under_cavity, 0.5);
            if (dist < under_depth_range) {
                const float SD_STEP = 0.003;
                // The view ray walked up into the hollow by the distance to
                // the nearest rim or rib (brick.gdshader's sphere trace), so
                // the rim and ribs hide what is behind them as the eye moves.
                vec2 hp = cell;
                float hs = under_depth;
                bool on_wall = false;
                float pfade = 1.0 - smoothstep(under_parallax_range * 0.6, under_parallax_range, dist);
                if (pfade > 0.0) {
                    vec3 dv = transpose(model3) * (mat3(INV_VIEW_MATRIX) * normalize(VERTEX));
                    if (dv.y > 0.02) {
                        vec2 run = dv.xz / dv.y * pfade;
                        float rl = max(length(run), 1e-4);
                        hs = 0.0;
                        for (int i = 0; i < 16; i++) {
                            float sd = ps_under_sd(hp, fsize);
                            if (sd < 0.001) {
                                on_wall = true;
                                break;
                            }
                            float st = sd / rl;
                            if (hs + st >= under_depth) {
                                hp += run * (under_depth - hs);
                                hs = under_depth;
                                break;
                            }
                            hs += st;
                            hp += run * st;
                        }
                        if (!on_wall && hs < under_depth) {
                            hs = under_depth;
                        }
                    }
                }
                float near = 1.0 - smoothstep(under_depth_range * 0.6, under_depth_range, dist);
                float upk = hs / under_depth;
                vec3 ax_u = normalize(mat3(VIEW_MATRIX) * MODEL_MATRIX[0].xyz);
                vec3 ax_v = normalize(mat3(VIEW_MATRIX) * MODEL_MATRIX[2].xyz);
                if (on_wall) {
                    float s0 = ps_under_sd(hp, fsize);
                    vec2 g = vec2(ps_under_sd(hp + vec2(SD_STEP, 0.0), fsize) - s0,
                                  ps_under_sd(hp + vec2(0.0, SD_STEP), fsize) - s0);
                    float gl = length(g);
                    if (gl > 1e-7) {
                        vec2 dir = g / gl;
                        vec3 wall_n = normalize(ax_u * dir.x * 0.25 + ax_v * dir.y * 0.25 + NORMAL);
                        NORMAL = normalize(mix(NORMAL, wall_n, near));
                    }
                }
                // The walls' lines a layer apart up them, the roof's a bead
                // apart across it.
                float lt = on_wall ? hs / layer_height : hp.x / UNDER_BEAD;
                float laa = max(fwidth(lt), 1e-5);
                float lres = 1.0 - smoothstep(resolve_begin, resolve_end, laa);
                float ink = (1.0 - smoothstep(0.0, max(laa * 1.4, 0.18), abs(fract(lt) - 0.5)))
                        * lres * near;
                shade = mix(under_wall, under_cavity, near * (on_wall ? upk : 1.0) + (1.0 - near) * 0.5);
                if (on_wall) {
                    shade *= mix(1.0, 0.8, upk * near);
                }
                albedo *= mix(1.0, 0.82, ink * (1.0 - under_solid));
            }
            // What the hollow loses is sky (AO, below), and a little of its
            // own light, so it reads as going up into the brick.
            under_occ = mix(shade, 1.0, under_solid);
            albedo *= mix(mix(1.0, shade, 0.6), 1.0, under_solid);
        }
    }

    // --- printed surface -------------------------------------------------
    float print_rough = 0.0;
    if (print_lines_enabled) {
        float fade = 1.0 - smoothstep(print_fade_begin, print_fade_end, dist);
        // A top's bevel facet is plain: the nozzle's paths stop at the edge
        // of the top rather than running on down the bevel (they carry the
        // top's UV, so they would). An upright facet keeps its layers, which
        // do wrap round a printed corner.
        if (v_facet > 0.5 && v_flat_normal.y > 0.3) {
            fade = 0.0;
        }
        if (no_piece && plain_curves && has_stud < 0.5) {
            fade = 0.0;
        }
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
            // multiplied in the same pixels is noise. Nor in an underside's
            // hollow, which has its own lines.
            ink *= 1.0 - 0.7 * stud_shade;
            ink *= under_solid;
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

    // FAR GROUND, blocky (G 0.5) or smooth (G 1.0), lit by ONE rule (19.20,
    // 19.21): flat per triangle, a top at full brightness and anything
    // steeper -- a smooth ramp or a blocky step -- darkened alike. The border
    // between the two then differs in shape only.
    if (v_smooth_far > 0.25) {
        vec3 fn = normalize(cross(dFdy(VERTEX), dFdx(VERTEX)));
        if (dot(fn, NORMAL) < 0.0) {
            fn = -fn;
        }
        NORMAL = fn;
        float up = (INV_VIEW_MATRIX * vec4(fn, 0.0)).y;
        albedo *= mix(far_ramp_shade, 1.0, smoothstep(0.75, 0.97, up));
    }
    if (far_courses && v_smooth_far > 0.75) {
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
    float out_rough = clamp(surface_roughness * surface_gloss * mtl.x + print_rough
            + (1.0 - under_solid) * 0.25, 0.0, 1.0);
    float out_spec = surface_specular * mtl.y;
    // Rain (weather.gdshaderinc): the ground darkens more than a wall does.
    vec3 wet_normal = NORMAL;
    weather_wet_surface(albedo, out_rough, out_spec, wet_normal, VERTEX, INV_VIEW_MATRIX,
            VIEW_MATRIX, 0.22, 1.0, TIME);
    NORMAL = wet_normal;
    weather_snow_surface(albedo, out_rough, out_spec, NORMAL, INV_VIEW_MATRIX, 1.0);
    vec3 burn_glow = weather_burn_surface(albedo, out_rough, v_world, TIME);
    EMISSION += burn_glow;
    // Under a cloud, less sun (clouds.gdshaderinc; Docs/Lighting.md 2b).
    albedo *= cloud_shade(v_world);
    ALBEDO = albedo;
    ROUGHNESS = out_rough;
    SPECULAR = out_spec;
    RIM = surface_rim * mtl.z;
    RIM_TINT = 0.4;
    AO = under_occ;
#ifdef SKY_LIGHT
    float sky_k0 = pow(sky_light_curve, 15.0);
    // Clamped: at level 0 the difference rounds a hair under zero, and pow()
    // of a negative number is NaN -- every level-0 face drew black.
    float sky_b = clamp((pow(sky_light_curve, 15.0 - 15.0 * clamp(v_sky, 0.0, 1.0)) - sky_k0)
            / (1.0 - sky_k0), 0.0, 1.0);
    float blk_b = clamp((pow(sky_light_curve, 15.0 - 15.0 * clamp(v_block, 0.0, 1.0)) - sky_k0)
            / (1.0 - sky_k0), 0.0, 1.0);
    AO = mix(sky_light_floor, 1.0, max(sky_b, blk_b * block_light_ao)) * under_occ;
    EMISSION += block_light_colour * albedo * (blk_b * block_light_energy);
    // The sky's REFLECTIONS ignore AO (--gate=deep --light-sweep: a level-0
    // cave 0.033 without them, 0.079 with). They scale with f0 = 0.16 x
    // SPECULAR^2, and their grazing part with clamp(50 f0): SPECULAR x
    // sqrt(AO) takes them down about as AO takes the ambient. light() keeps
    // the surface's own specular for lamps, lava and the flashlight.
    SPECULAR = out_spec * sqrt(AO);
    l_sun = pow(sky_b, sky_sun_power);
    l_spec = out_spec;
    l_rim = surface_rim * mtl.z;
    if (sky_debug > 0) {
        vec3 dbg = sky_debug == 1 ? vec3(clamp(v_sky, 0.0, 1.0))
                : sky_debug == 3 ? vec3(clamp(v_block, 0.0, 1.0)) : vec3(AO);
        ALBEDO = vec3(0.0);
        AO = 0.0;
        EMISSION = dbg;
        l_sun = 0.0;
    }
#endif
}

#ifdef SKY_LIGHT
float sky_schlick(float u) {
    float m = 1.0 - u;
    float m2 = m * m;
    return m2 * m2 * m;
}

// The engine's own lighting for this render_mode (Burley diffuse, Schlick-GGX
// specular, the rim), written out so the sun can be scaled by the sky light;
// any other light (a lamp, lava, the flashlight) is as the engine draws it.
void light() {
    float k = LIGHT_IS_DIRECTIONAL ? l_sun : 1.0;
    float cNdotL = max(dot(NORMAL, LIGHT), 0.0);
    float cNdotV = max(dot(NORMAL, VIEW), 1e-4);
    vec3 H = normalize(VIEW + LIGHT);
    float cLdotH = clamp(dot(LIGHT, H), 0.0, 1.0);
    float cNdotH = clamp(dot(NORMAL, H), 0.0, 1.0);
    float rough = ROUGHNESS;
    float fd90 = 2.0 * cLdotH * cLdotH * rough - 0.5;
    float fdv = 1.0 + fd90 * sky_schlick(cNdotV);
    float fdl = 1.0 + fd90 * sky_schlick(cNdotL);
    DIFFUSE_LIGHT += LIGHT_COLOR * ((1.0 / PI) * fdv * fdl * cNdotL) * ATTENUATION * k;
    float rim_light = pow(max(1e-4, 1.0 - cNdotV), max(0.0, (1.0 - rough) * 16.0));
    DIFFUSE_LIGHT += rim_light * l_rim * mix(vec3(1.0), ALBEDO, 0.4) * LIGHT_COLOR * k;
    if (rough > 0.0) {
        float a = rough * rough;
        float dh = cNdotH * a;
        float dk = a / (1.0 - cNdotH * cNdotH + dh * dh);
        float d = dk * dk * (1.0 / PI);
        float g = 0.5 / mix(2.0 * cNdotL * cNdotV, cNdotL + cNdotV, a);
        float f0 = 0.16 * l_spec * l_spec;
        float f90 = clamp(f0 * 49.5, 0.0, 1.0);
        float f = f0 + (f90 - f0) * sky_schlick(cLdotH);
        SPECULAR_LIGHT += (cNdotL * d * f * g) * LIGHT_COLOR * ATTENUATION * SPECULAR_AMOUNT * k;
    }
}
#endif
