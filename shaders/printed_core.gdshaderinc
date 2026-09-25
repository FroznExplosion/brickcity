// Printed plastic, shared body. Included by printed.gdshader (cull_back,
// for solid pieces) and printed_double.gdshader (cull_disabled, for the
// two-sided grass blades). `render_mode` belongs to the shader and not to
// the material, so one file cannot serve both -- hence the include.

// Materials ride in the instance colour's alpha, as on the bricks: a stud
// on a steel brick is steel. Everything else instanced here (pebbles,
// tufts) writes alpha 1.0, which is PLA.
#include "res://shaders/brick_materials.gdshaderinc"

group_uniforms print;
uniform bool print_lines_enabled = true;
// 0.46 mm layers, 0.4 mm bead, at 1:43.75 — see terrain.gdshader for
// why not the 0.2 mm this started at.
uniform float layer_height = 0.020;
uniform float bead_width = 0.024;
// Half-width of the shadow between two beads, as a fraction of one bead.
uniform float bead_groove : hint_range(0.0, 0.5) = 0.17;
// Where the pattern starts and finishes dissolving, in beads a pixel.
// Below ~0.3 a bead is several pixels wide and is worth drawing; past
// ~0.75 it is under a pixel and drawing it only makes it crawl.
uniform float resolve_begin : hint_range(0.05, 1.0) = 0.30;
uniform float resolve_end : hint_range(0.1, 2.0) = 0.75;
uniform float layer_darken : hint_range(0.0, 1.0) = 0.86;
// How much each bead stands proud. This is what turns a drawn line into a
// ridge that catches the light, and it is the difference between "lines on
// the surface" and "the surface is made of stacked beads".
uniform float layer_relief : hint_range(0.0, 1.0) = 0.28;
uniform float print_fade_begin = 6.0;
uniform float print_fade_end = 18.0;

group_uniforms top_paths;
// 0: a 45-degree raster, what a slicer does on a flat top by default.
// 1: concentric loops following an N-sided outline — for a stud, whose top
//    is an octagon and not a circle, so circular rings would be visibly the
//    wrong shape on the one part there are thousands of.
uniform int top_mode : hint_range(0, 1) = 0;
uniform int contour_sides : hint_range(3, 16) = 8;
uniform float contour_radius = 0.0685;
// A real slicer walks the outline two or three times and then infills.
uniform int perimeters : hint_range(0, 4) = 2;

group_uniforms surface;
// Multiplied onto the vertex colour. A MultiMesh writes its instance colour
// into COLOR and leaves this at white; a single mesh with no vertex colours
// gets white in COLOR and sets this instead. One shader serves both.
uniform vec4 tint : source_color = vec4(1.0, 1.0, 1.0, 1.0);
uniform float surface_roughness : hint_range(0.0, 1.0) = 0.42;
uniform float surface_specular : hint_range(0.0, 1.0) = 0.55;
uniform float surface_rim : hint_range(0.0, 1.0) = 0.35;

varying vec3 v_local;
varying vec3 v_colour;
varying vec3 v_flat_normal;
varying flat int v_mat;

void vertex() {
    v_local = VERTEX;
    v_colour = COLOR.rgb * tint.rgb;
    v_flat_normal = normalize(NORMAL);
    v_mat = brick_material_id(COLOR.a);
}

const float TAU_F = 6.28318530718;

/// Distance from p to the boundary of a regular n-gon of the given radius,
/// with a vertex on +X — the orientation PieceMeshes.stud() builds.
float ngon_depth(vec2 p, int n, float radius) {
    float apothem = radius * cos(3.14159265 / float(n));
    float worst = 0.0;
    for (int i = 0; i < n; i++) {
        float a = TAU_F * (float(i) + 0.5) / float(n);
        worst = max(worst, dot(p, vec2(cos(a), sin(a))));
    }
    return apothem - worst;
}

void fragment() {
    vec3 albedo = v_colour;
    float dist = length(VERTEX);

    int mat = v_mat;
    float lh = layer_height * MAT_LAYER[mat];
    float bw = bead_width * MAT_LAYER[mat];
    float print_rough = 0.0;
    if (print_lines_enabled && MAT_PRINTED[mat] > 0.5) {
        float fade = 1.0 - smoothstep(print_fade_begin, print_fade_end, dist);
        if (fade > 0.0) {
            // `t` counts beads, and it must stay CONTINUOUS: the ridge normal
            // comes from its screen-space gradient, and fract() would put a
            // cliff in that gradient once a bead.
            float t;
            if (abs(v_flat_normal.y) > 0.7) {
                if (top_mode == 1) {
                    t = ngon_depth(v_local.xz, contour_sides, contour_radius) / bw;
                } else {
                    t = dot(v_local.xz, vec2(0.7071, 0.7071)) / bw;
                }
            } else {
                // Sides are LAYERS, stacked along the part's own print axis.
                t = v_local.y / lh;
            }

            float ph = fract(t);
            float aa = max(fwidth(t), 1e-5);
            // Dissolve the pattern toward its average as a bead approaches
            // a pixel. Below its own sampling rate a bead pattern does not
            // fade, it CRAWLS as the camera moves -- see terrain.gdshader
            // for the long version.
            float resolved = 1.0 - smoothstep(resolve_begin, resolve_end, aa);
            float groove = max(aa * 1.4, bead_groove * MAT_GROOVE[mat]);
            float ink = (1.0 - smoothstep(0.0, groove, abs(ph - 0.5))) * resolved;
            albedo *= mix(1.0, layer_darken, ink * fade * MAT_GROOVE[mat]);

            // The bead itself, as relief. A round bead's surface turns
            // through the width of the bead, so the normal leans along the
            // direction `t` grows in and back again.
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

    // The material's own surface, as brick.gdshader draws it. A stud is one
    // shared mesh, so its coordinates are the stud's own: tops by x/z, sides
    // wrapped around by x+z against height.
    float roughness = MAT_ROUGH[mat] + (surface_roughness - MAT_ROUGH[0]);
    int tex = MAT_TEX[mat];
    vec3 emission = vec3(0.0);
    if (tex != 0) {
        vec2 p = abs(v_flat_normal.y) > 0.7 ? v_local.xz : vec2(v_local.x + v_local.z, v_local.y);
        float tfade = 1.0 - smoothstep(print_fade_begin, print_fade_end * 2.0, dist);
        if (tex == 1) {
            albedo = bm_wood(albedo, p, 0.0, tfade, roughness);
        } else if (tex == 2) {
            albedo = bm_metal(albedo, p, 0.0, tfade, roughness);
        } else if (tex == 3) {
            albedo = bm_stone(albedo, p, 0.0, tfade, roughness);
        } else if (tex == 4) {
            albedo = bm_carbon(albedo, p, tfade);
        } else if (tex == 5) {
            emission = albedo * 0.85;
        } else if (tex == 6) {
            float fres = pow(1.0 - clamp(dot(NORMAL, VIEW), 0.0, 1.0), 2.5);
            albedo = mix(albedo, min(albedo * 1.7 + 0.08, vec3(1.0)), fres * 0.65);
        } else if (tex == 7) {
            albedo = bm_nylon(albedo, p, tfade);
        } else if (tex == 8) {
            albedo = bm_wood_fill(albedo, p, v_local.y / lh, 0.0, tfade);
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
