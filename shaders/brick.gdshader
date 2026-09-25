shader_type spatial;
render_mode cull_back, diffuse_burley, specular_schlick_ggx;

// Materials: PLA, TPU, wood, metal ... in the vertex colour's alpha.
#include "res://shaders/brick_materials.gdshaderinc"

// Brick surface. Flat filament colour from vertex colour (spec section 2: no
// textures, so colour costs nothing but a byte per block), plus a dark seam
// drawn at every BLOCK boundary and a 45-degree CHAMFER shaded along the same
// boundary.
//
// The seam is the whole reason this is a shader and not a StandardMaterial3D.
// Face culling removes the geometry between two touching blocks, so a run of
// same-coloured bricks would otherwise mesh into one flat rectangle and read as
// a single slab. The mesher writes, per vertex:
//
//   UV  = position within the block's face rectangle, in METRES
//   UV2 = that rectangle's size, in metres
//
// so distance-to-block-edge is min(UV, UV2 - UV) and the line has a constant
// real-world width whatever the block size. Cell boundaries inside one block
// carry no seam, which is what makes a 2x4 read as one brick rather than eight.
//
// Width is floored at one pixel via fwidth and the whole effect fades out with
// distance, for the reason spec section 2 gives for layer lines: a sub-pixel
// line pattern shimmers. This is the same machinery those layer lines will
// need, evaluated along print_axis instead of the face plane.

group_uniforms seams;
uniform bool seams_enabled = true;
uniform float seam_width : hint_range(0.0, 0.05) = 0.010;   // metres, per side
uniform float seam_darken : hint_range(0.0, 1.0) = 0.55;    // 1.0 = invisible
uniform float seam_fade_begin = 30.0;                        // metres from camera
uniform float seam_fade_end = 75.0;

// A real brick has a small 45-degree chamfer on every edge, and it is what
// makes one read as a moulded object rather than as a box: the bevel catches a
// highlight along the top edges and goes dark along the bottom ones, so an
// unlit corner still separates from the face beside it.
//
// It is SHADED, not built. A chamfer on every edge of every block would be a
// ring of four quads per face -- five times the triangles for a bevel that is
// 13 mm wide at game scale and is sub-pixel past about twenty metres. What the
// eye actually reads at that size is the LIGHTING, so the normal is bent to
// 45 degrees inside a band along each block edge and the geometry is left flat.
// It costs two texture-space derivatives and no vertices.
//
// 13 mm is the real thing to scale: a moulded brick chamfers about 0.3 mm on an
// 8 mm stud, and a stud here is 0.35 m (Docs/Status.md, "the part palette").
//
// The bevel is NOT the same effect as the seam, and both are wanted. The seam
// is the shadowed crevice between two bricks that meet; the chamfer is the lit
// facet on either side of it. The seam survives to 75 m because a dark line
// stays legible; the chamfer fades by 60 m because a sub-pixel highlight
// shimmers.
//
// --- why not real geometry near the camera, and a line far away? ----------
//
// Asked, and the answer is no, for two reasons of different weight.
//
// The triangle count is the small one. A chamfered quad is a centre quad plus
// four edge strips plus four mitred corners: 14 triangles where there was 2.
// Against the measured figures -- M0's 824 blocks at 36,256 triangles after
// 82.9% face culling, a 150 m tower at 685k, a 25-tile terrain field at 76k --
// that is 254k, 4.8M and 532k. The tower alone ends it.
//
// The real reason is M2c. Faces are baked ONCE and damage flips index slots,
// because re-uploading a chunk's vertex buffer measured 175 ms at 16.5k
// blocks. A geometry tier that switches with distance has to rebuild and
// re-upload that buffer every time the camera crosses the threshold -- which
// is the exact cost M2c was written to remove, re-introduced and now driven
// by camera movement rather than by damage. Hysteresis bounds how often, not
// how much.
//
// So: shaded bevel in the chunk mesh, always. Where a real chamfer is wanted
// it goes on geometry that ALREADY exists and is already instanced and few --
// studs, scatter, and loose debris. A single brick tumbling past the camera is
// the one place a flat silhouette genuinely reads wrong, and those are
// separate meshes with their own budget.
//
// BUILT: `PieceMeshes.chamfered_box`, used by IslandManager's debris MultiMesh
// and by terrain carve debris. 44 triangles -- 6 inset faces, 12 bevel strips,
// 8 corner triangles -- cached per size, so the bevel is paid ONCE for the
// whole debris field rather than once per brick. Compare
// `shots/debris_chamfer_ab.png`: chamfered in red, plain box in blue, at the
// 2.4 m a brick coming off a wall actually passes you.
//
// The corollary, for anyone tempted to switch the seam off and rely on
// geometry: there is no geometry to rely on. Two touching coplanar block faces
// are meshed as touching coplanar quads, so without the seam a run of same-
// coloured bricks is one flat slab. The seam is not decorating a division that
// exists -- it IS the division.
group_uniforms chamfer;
uniform bool chamfer_enabled = true;
uniform float chamfer_width : hint_range(0.0, 0.05) = 0.013;  // metres, per side
uniform float chamfer_fade_begin = 18.0;
uniform float chamfer_fade_end = 55.0;
// A moulded brick is glossier on its chamfer than on its face -- the bevel is
// the part the mould polished. Dropping roughness inside the band puts a
// specular line along every edge, which is most of what says "plastic" rather
// than "painted box".
uniform float chamfer_gloss : hint_range(0.0, 1.0) = 0.45;

group_uniforms print;
// The same printed surface the ground and the scatter have
// (terrain.gdshader, printed.gdshader). City bricks were the last thing in
// the world still coming out of the mould smooth.
//
// In OBJECT space, unlike the ground's: a chunk of wall that has been blasted
// off tumbles, and world-space layers would swim through it as it fell. The
// ground never moves, so it uses world space to keep layers continuous across
// a seam; a brick belongs to itself.
uniform bool print_lines_enabled = true;
// 0.46 mm layers on a 9.6 mm brick, at 1:43.75 -- twenty-one a course.
//
// It was 0.00875, a 0.2 mm layer, which is physically the commonest
// setting there is and was ALSO about one screen pixel at two metres:
// the filter threw the whole pattern away and the print read as
// switched off. A 0.32 mm layer through a 0.55 mm nozzle is just as
// real a print and is actually visible.
uniform float layer_height = 0.020;
// One 0.55 mm nozzle width, same scale.
uniform float bead_width = 0.024;
uniform float bead_groove : hint_range(0.0, 0.5) = 0.17;
uniform float layer_darken : hint_range(0.0, 1.0) = 0.86;
uniform float layer_relief : hint_range(0.0, 1.0) = 0.28;
// Beads a pixel. Past resolve_end a bead is under a pixel and drawing it
// only makes it crawl -- see terrain.gdshader for the long version.
uniform float resolve_begin : hint_range(0.05, 1.0) = 0.30;
uniform float resolve_end : hint_range(0.1, 2.0) = 0.75;
uniform int perimeters : hint_range(0, 4) = 3;
uniform float print_fade_begin = 7.0;
uniform float print_fade_end = 22.0;

group_uniforms surface;
// PLASTIC. See terrain.gdshader's note: 0.85 read as matte card, and ABS is
// glossy with a tight highlight that moves across a bevel as you walk.
uniform float surface_roughness : hint_range(0.0, 1.0) = 0.42;
uniform float surface_specular : hint_range(0.0, 1.0) = 0.55;
uniform float surface_rim : hint_range(0.0, 1.0) = 0.35;

// Set by BrickMaterials.add_glass, which also gives this material its
// second pass (brick_glass.gdshader) for see-through bricks.
uniform bool glass_pass = false;

varying vec2 v_uv;
varying vec2 v_face;
varying vec3 v_local;
varying vec3 v_local_normal;

void vertex() {
    v_uv = UV;
    v_face = UV2;
    v_local = VERTEX;
    v_local_normal = normalize(NORMAL);
    // A see-through brick is drawn by the glass pass, not here: collapsed to
    // a point, its faces cost nothing and rasterise nothing.
    if (glass_pass && MAT_TRANSLUCENT[brick_material_id(COLOR.a)] > 0.5) {
        VERTEX = vec3(0.0);
    }
}

const float TAU_F = 6.28318530718;

float hash21(vec2 p) {
    return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453);
}

void fragment() {
    vec3 albedo = COLOR.rgb;
    int mat = brick_material_id(COLOR.a);
    // The uniforms tune PLA (material 0); every material moves with them.
    float roughness = MAT_ROUGH[mat] + (surface_roughness - MAT_ROUGH[0]);

    // Distance to the nearest edge of this block's face, in metres.
    //
    // UV is wrapped by UV2 first. For real brick geometry UV never leaves
    // [0, UV2) so this changes nothing -- but it lets a cheap LOD shell hand
    // over a whole wall with a BRICK-sized UV2 and get a grid of brick outlines
    // out of it, with no extra geometry. Without that, an undamaged building
    // had one outline around each entire wall and only grew brick edges when it
    // materialised.
    vec2 cell = mod(v_uv, v_face);
    vec2 to_edge = min(cell, v_face - cell);
    float d = min(to_edge.x, to_edge.y);
    float dist = length(VERTEX);

    if (seams_enabled) {
        // One screen pixel, measured in the same metres. Keeps the seam
        // visible at range instead of aliasing into a dotted mess.
        float aa = max(fwidth(d), 1e-5);
        // Analytic coverage of the seam band by this pixel; see
        // terrain.gdshader for what the widened-to-one-pixel version did.
        float seam = clamp((seam_width - d) / aa + 0.5, 0.0, 1.0);
        float fade = 1.0 - smoothstep(seam_fade_begin, seam_fade_end, dist);

        albedo *= mix(1.0, seam_darken, seam * fade);
    }

    if (chamfer_enabled && chamfer_width > 0.0) {
        // A tangent frame from the UV mapping rather than from the vertex data:
        // the mesher writes no TANGENT, and every face here is axis-aligned in
        // its own chunk but the chunk can be at any angle once it is falling.
        // Derivatives give the frame wherever the face ended up.
        vec3 dp_x = dFdx(VERTEX);
        vec3 dp_y = dFdy(VERTEX);
        vec2 duv_x = dFdx(v_uv);
        vec2 duv_y = dFdy(v_uv);
        float det = duv_x.x * duv_y.y - duv_y.x * duv_x.y;
        if (abs(det) > 1e-12) {
            vec3 tangent = (dp_x * duv_y.y - dp_y * duv_x.y) / det;
            vec3 binormal = (dp_y * duv_x.x - dp_x * duv_y.x) / det;
            tangent = normalize(tangent);
            binormal = normalize(binormal);

            // Which edge of the cell each axis is near, and how far into the
            // band. A chamfer is a FLAT facet, so the tilt does not ramp with
            // depth -- it switches on across the band, with one pixel of
            // smoothing so the switch does not crawl.
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
            roughness = mix(roughness, roughness * chamfer_gloss, on_bevel);
        }
    }

    // --- printed surface -------------------------------------------------
    // Only a printed material has beads. Wood, metal and stone are what they
    // say, not a print of them.
    float print_rough = 0.0;
    float lh = layer_height * MAT_LAYER[mat];
    float bw = bead_width * MAT_LAYER[mat];
    float layer_t = v_uv.y / lh;
    if (print_lines_enabled && MAT_PRINTED[mat] > 0.5) {
        float fade = 1.0 - smoothstep(print_fade_begin, print_fade_end, dist);
        if (fade > 0.0 && v_face.x > 0.0 && v_face.y > 0.0) {
            // Continuous, because the relief below differentiates it.
            float t;
            if (abs(v_local_normal.y) > 0.7) {
                // A top face: the outline walked two or three times, then a
                // diagonal raster across what is left. The raster is in
                // PIECE space and its direction is hashed off the piece, so
                // two bricks side by side read as two printed parts.
                float d2 = min(min(v_uv.x, v_face.x - v_uv.x),
                               min(v_uv.y, v_face.y - v_uv.y));
                float wall = float(perimeters) * bw;
                if (d2 < wall) {
                    t = d2 / bw;
                } else {
                    // The block's own corner, in the same world metres the
                    // mesher wrote, so every fragment of a block agrees.
                    vec2 origin = v_local.xz - v_uv;
                    float flip = hash21(floor(origin / 0.35 + 0.5)) < 0.5 ? -1.0 : 1.0;
                    t = dot(v_uv, vec2(0.7071, flip * 0.7071)) / bw;
                }
            } else {
                // UV.y is the height WITHIN THIS BLOCK's face, in metres, so
                // the layers restart at each brick's own base -- which is
                // what a printed brick does, being printed by itself.
                //
                // It was `v_local.y` first, and that drew nothing at all:
                // the chunk mesher emits vertices in WORLD metres, not
                // object-local ones, so on a tower a hundred metres from
                // the origin `t` ran into the thousands and fwidth of it
                // came back larger than a bead. The pattern filtered itself
                // away completely and looked like the block was disabled.
                t = layer_t;
            }

            float ph = fract(t);
            float aa3 = max(fwidth(t), 1e-5);
            float resolved = 1.0 - smoothstep(resolve_begin, resolve_end, aa3);
            float groove = max(aa3 * 1.4, bead_groove * MAT_GROOVE[mat]);
            float ink = (1.0 - smoothstep(0.0, groove, abs(ph - 0.5))) * resolved;
            albedo *= mix(1.0, layer_darken, ink * fade * MAT_GROOVE[mat]);

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
                          * layer_relief * MAT_RELIEF[mat] * fade * relief_k);
                // ...and the roughness takes over what the normal drops.
                // A bead that is no longer resolved has not gone away: it is
                // sub-pixel roughness now, and saying so is what stops the
                // highlight from sparkling where the ridges used to be.
                print_rough = (1.0 - relief_k) * fade * layer_relief * 0.8;
            }
        }
    }

    // --- the material's own surface ---------------------------------------
    int tex = MAT_TEX[mat];
    vec3 emission = vec3(0.0);
    if (tex != 0 && v_face.x > 0.0 && v_face.y > 0.0) {
        // Along the grain = along this face's longer side, which on a brick
        // is its length: a 1x6 of oak is a board, not end grain.
        vec2 p = v_face.x >= v_face.y ? v_uv : v_uv.yx;
        // This face's own corner, in the chunk's metres: v_local less the UV
        // walked back along the face's own axes. One seed a face.
        vec3 dlx = dFdx(v_local);
        vec3 dly = dFdy(v_local);
        vec2 dux = dFdx(v_uv);
        vec2 duy = dFdy(v_uv);
        float det = dux.x * duy.y - duy.x * dux.y;
        float seed = 0.0;
        if (abs(det) > 1e-12) {
            vec3 tu = (dlx * duy.y - dly * dux.y) / det;
            vec3 tv = (dly * dux.x - dlx * duy.x) / det;
            vec3 corner = v_local - tu * v_uv.x - tv * v_uv.y;
            seed = bm_hash3(floor(corner / 0.07 + 0.5));
        }
        float tfade = 1.0 - smoothstep(print_fade_begin, print_fade_end * 2.0, dist);
        if (tex == 1) {
            albedo = bm_wood(albedo, p, seed, tfade, roughness);
        } else if (tex == 2) {
            albedo = bm_metal(albedo, p, seed, tfade, roughness);
        } else if (tex == 3) {
            albedo = bm_stone(albedo, p, seed, tfade, roughness);
        } else if (tex == 4) {
            albedo = bm_carbon(albedo, p, tfade);
        } else if (tex == 5) {
            emission = albedo * 0.85;
        } else if (tex == 6) {
            // Silk: a sheen that swings with the view, brightest at a grazing
            // angle, the way silk filament shimmers.
            float fres = pow(1.0 - clamp(dot(NORMAL, VIEW), 0.0, 1.0), 2.5);
            albedo = mix(albedo, min(albedo * 1.7 + 0.08, vec3(1.0)), fres * 0.65);
        } else if (tex == 7) {
            albedo = bm_nylon(albedo, p, tfade);
        } else if (tex == 8) {
            albedo = bm_wood_fill(albedo, p, layer_t, seed, tfade);
        }
    }

    ALBEDO = albedo;
    ROUGHNESS = clamp(roughness + print_rough, 0.0, 1.0);
    SPECULAR = clamp(MAT_SPEC[mat] + (surface_specular - MAT_SPEC[0]), 0.0, 1.0);
    METALLIC = MAT_METAL[mat];
    EMISSION = emission;
    RIM = surface_rim * (1.0 - MAT_METAL[mat]);
    RIM_TINT = 0.4;
}
