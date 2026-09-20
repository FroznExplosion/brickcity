shader_type spatial;
render_mode cull_back, diffuse_burley, specular_schlick_ggx;

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

group_uniforms surface;
uniform float surface_roughness : hint_range(0.0, 1.0) = 0.85;

varying vec2 v_uv;
varying vec2 v_face;

void vertex() {
    v_uv = UV;
    v_face = UV2;
}

void fragment() {
    vec3 albedo = COLOR.rgb;
    float roughness = surface_roughness;

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
        float w = max(seam_width, aa);

        float seam = 1.0 - smoothstep(w, w + aa, d);
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

    ALBEDO = albedo;
    ROUGHNESS = roughness;
}
