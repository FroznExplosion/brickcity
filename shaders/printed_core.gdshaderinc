// Printed plastic, shared body. Included by printed.gdshader (cull_back,
// for solid pieces) and printed_double.gdshader (cull_disabled, for the
// two-sided grass blades). `render_mode` belongs to the shader and not to
// the material, so one file cannot serve both -- hence the include.

// Materials ride in the instance colour's alpha, as on the bricks: a stud
// on a steel brick is steel. Everything else instanced here (pebbles,
// tufts) writes alpha 1.0, which is PLA.
#include "res://shaders/brick_materials.gdshaderinc"
#include "res://shaders/weather.gdshaderinc"
// Layer lines, toolpaths, the finish of each face: the same printer as the
// bricks (see there; its uniforms are this material's).
#include "res://shaders/print_surface.gdshaderinc"

group_uniforms top_paths;
// 0: a 45-degree raster, what a slicer does on a flat top by default.
// 1: a STUD. Its top is one path spiralling in to the centre, and its sides
//    are shaded round although the mesh is an octagon.
//
//    The top was concentric loops following the octagon, and that drew the
//    octagon's corners as eight creases on every stud. A real stud is round
//    and so is its toolpath; the mesh is eight-sided only to be cheap, and
//    the shading is now what says round -- normals bent radially (vertex())
//    and a circular spiral. The silhouette is still eight-sided, at 0.2 m.
uniform int top_mode : hint_range(0, 1) = 0;
uniform int contour_sides : hint_range(3, 16) = 8;   // unused since the spiral; kept for callers
uniform float contour_radius = 0.0685;   // where the spiral starts, its outer bead
// A real stud is 1.8 mm, nine 0.2 mm layers: with the brick's 48, 57.
uniform int stud_layers : hint_range(1, 32) = 9;
uniform float stud_height = 0.074;   // PieceMeshes.STUD_H

group_uniforms surface;
// Multiplied onto the vertex colour. A MultiMesh writes its instance colour
// into COLOR and leaves this at white; a single mesh with no vertex colours
// gets white in COLOR and sets this instead. One shader serves both.
uniform vec4 tint : source_color = vec4(1.0, 1.0, 1.0, 1.0);
uniform float surface_roughness : hint_range(0.0, 1.0) = 0.42;
uniform float surface_specular : hint_range(0.0, 1.0) = 0.55;
uniform float surface_rim : hint_range(0.0, 1.0) = 0.35;
// Set by BrickMaterials.add_glass, with printed_glass.gdshader as the second
// pass that draws see-through studs.
uniform bool glass_pass = false;

varying vec3 v_local;
varying vec3 v_colour;
varying vec3 v_flat_normal;
varying flat int v_mat;

void vertex() {
    v_local = VERTEX;
    v_colour = COLOR.rgb * tint.rgb;
    v_flat_normal = normalize(NORMAL);
    v_mat = brick_material_id(COLOR.a);
    // A stud is shaded round: each vertex's normal points out from the axis,
    // so across a flat face the interpolated normal turns the way a cylinder's
    // does and the octagon's corners stop showing. The 45-degree rim keeps
    // its lean. v_flat_normal above keeps the true face, for the toolpaths.
    if (top_mode == 1 && abs(NORMAL.y) < 0.95) {
        float rl = length(VERTEX.xz);
        if (rl > 1e-5) {
            float h = length(NORMAL.xz);
            NORMAL = normalize(vec3(VERTEX.x / rl * h, NORMAL.y, VERTEX.z / rl * h));
        }
    }
    // Grass in the wind (weather.gdshaderinc): only what has a sway height --
    // the tufts -- and after v_local, so the print lines ride along.
    VERTEX = weather_sway_vertex(VERTEX, MODEL_MATRIX, TIME);
    // A see-through brick is drawn by the glass pass, not here: collapsed to
    // a point, its faces cost nothing and rasterise nothing.
    if (glass_pass && MAT_TRANSLUCENT[brick_material_id(COLOR.a)] > 0.5) {
        VERTEX = vec3(0.0);
    }
}

void fragment() {
    vec3 albedo = v_colour;
    float dist = length(VERTEX);

    int mat = v_mat;
    int face = ps_face(v_flat_normal);
    float roughness = ps_roughness(face, mat, MAT_ROUGH[mat] + (surface_roughness - MAT_ROUGH[0]));
    float print_rough = 0.0;
    vec3 aniso_dir = vec3(0.0);
    float aniso = 0.0;
    if (print_lines_enabled && ps_printed(mat)) {
        float t;
        float t_d;
        if (face != 0) {
            float bw = ps_bead(face, mat);
            if (top_mode == 1) {
                // One bead a turn, in to the centre. `t` steps by exactly
                // one where the angle wraps, which fract() never sees; the
                // derivatives take the unwrapped radial count instead.
                float r = length(v_local.xz);
                float turn = atan(v_local.z, v_local.x) / PS_TAU + 0.5;
                // A finer line than a brick's skin: a real stud top is
                // 4.8 mm across and takes five or six turns of 0.4 mm.
                bw *= 0.7;
                t_d = (contour_radius - r) / bw;
                t = t_d + turn;
            } else {
                t = dot(v_local.xz, vec2(0.7071, face == 2 ? -0.7071 : 0.7071)) / bw;
                t_d = t;
            }
        } else if (top_mode == 1) {
            // A stud's own layers, on top of the brick's: nine.
            t = v_local.y / (stud_height / float(max(stud_layers, 1)));
            t_d = t;
        } else {
            // Sides are LAYERS, stacked along the part's own print axis, the
            // same height as the brick's.
            t = v_local.y / ps_layer(mat);
            t_d = t;
        }
        // A stud is one shared mesh: one seed for all of them.
        ps_beads(t, t_d, face, mat, dist, VERTEX, 0.0, 0.0, 0.0,
                albedo, NORMAL, print_rough, aniso_dir, aniso);
        if (face == 2) {
            vec3 ax_u = normalize(mat3(VIEW_MATRIX) * MODEL_MATRIX[0].xyz);
            vec3 ax_v = normalize(mat3(VIEW_MATRIX) * MODEL_MATRIX[2].xyz);
            ps_bed_grain(v_local.xz, ax_u, ax_v, albedo, NORMAL, print_rough);
        }
    }

    // The material's own surface, as brick.gdshader draws it. A stud is one
    // shared mesh, so its coordinates are the stud's own: tops by x/z, sides
    // wrapped around by x+z against height.
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
            // By height in 20 mm steps, as on the bricks.
            albedo = bm_wood_fill(albedo, p, v_local.y / 0.020, 0.0, tfade);
        }
    }

    float out_rough = clamp(roughness + print_rough, 0.0, 1.0);
    float out_spec = clamp(MAT_SPEC[mat] + (surface_specular - MAT_SPEC[0]), 0.0, 1.0);
    // Rain (weather.gdshaderinc), as on bricks.
    vec3 wet_normal = NORMAL;
    weather_wet_surface(albedo, out_rough, out_spec, wet_normal, VERTEX, INV_VIEW_MATRIX,
            VIEW_MATRIX, 0.14 * (1.0 - MAT_METAL[mat]), 1.0, TIME);
    NORMAL = wet_normal;
    weather_snow_surface(albedo, out_rough, out_spec, NORMAL, INV_VIEW_MATRIX, 1.0);
    vec3 burn_glow = weather_burn_surface(albedo, out_rough,
            (INV_VIEW_MATRIX * vec4(VERTEX, 1.0)).xyz, TIME);
    emission += burn_glow;
    ALBEDO = albedo;
    ROUGHNESS = out_rough;
    SPECULAR = out_spec;
    METALLIC = MAT_METAL[mat];
    ps_tangent_frame(NORMAL, aniso_dir, TANGENT, BINORMAL);
    ANISOTROPY = aniso;
    EMISSION = emission;
    RIM = surface_rim * (1.0 - MAT_METAL[mat]);
    RIM_TINT = 0.4;
}
