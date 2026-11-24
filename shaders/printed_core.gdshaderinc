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
#ifdef GRID_LIGHT
// The brick grid's light (grid_light.gdshaderinc) on the near tier's studs
// (printed_grid.gdshader). A stud's VERTEX is its own; the grid is the
// chunk's: world to chunk is the band's inverse, by rows (BrickGridLight).
#include "res://shaders/grid_light.gdshaderinc"
instance uniform vec4 grid_from_world_x = vec4(1.0, 0.0, 0.0, 0.0);
instance uniform vec4 grid_from_world_y = vec4(0.0, 1.0, 0.0, 0.0);
instance uniform vec4 grid_from_world_z = vec4(0.0, 0.0, 1.0, 0.0);
varying vec3 v_grid_p;
varying vec3 v_grid_n;
#endif

group_uniforms top_paths;
// 0: a 45-degree raster, what a slicer does on a flat top by default.
// 1: a STUD. Its top is what the sliced G-code shows on every stud: the
//    outline walked twice (the walls, MAT_WALLS), following the stud's own
//    N-sided shape -- the slicer walks the shape it is given, and this stud
//    is an octagon (PieceMeshes.stud) -- and inside them a few short lines at
//    45 degrees, the SAME way as its brick's top. It was a spiral in to the
//    centre, which no slicer prints. The stud's own frame is turned with its
//    brick (BrickWorld::stud_turn), so the lines here are one fixed diagonal.
//
//    The walls' corners are ROUNDED, by a fifth of a bead. Concentric loops
//    with sharp corners drew eight hard creases on every stud: the ridge
//    normal swings straight across the corner's bisector. A real nozzle
//    cannot turn on a point either, so the path rounds every corner a little,
//    and so does this.
uniform int top_mode : hint_range(0, 1) = 0;
uniform int contour_sides : hint_range(3, 16) = 8;
uniform float contour_radius = 0.0685;   // the outline's corner radius: where the spiral starts
// How far a stud's facets are shaded toward round: 0 eight flat faces, 1 a
// cylinder. Between, an octagon with softened corners, which is what a
// printed polygon is.
uniform float stud_round : hint_range(0.0, 1.0) = 0.5;
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
// PBR texture sets, as brick.gdshader's uniforms of the same names.
uniform float pbr_range = 14.0;
uniform float pbr_far_range = 60.0;
uniform float pbr_bump : hint_range(0.0, 3.0) = 1.0;

global uniform float lod_zoom;
#ifdef NEAR_STUD_RANGE
// BrickNear's stud_radius (BrickNear._push_radii); scaled through a scope.
global uniform float near_stud_radius;
#endif
#ifdef INSTANCE_SKY
// THE GROUND'S STUDS IN THE MINE WORLD (Docs/MineWorld.md 20): each stud's
// sky and block light, from the bake (BrickTerrain sky_light_pass), in its
// MultiMesh custom data (r sky, g block, 0..1 for levels 0..15) -- the
// terrain shader's curve and its light() below, so a stud in a cave is as
// dark as the floor it stands on (TerrainTile.sky_stud_material).
uniform float sky_light_floor : hint_range(0.0, 0.2) = 0.015;
uniform float sky_light_curve : hint_range(0.5, 0.95) = 0.8;
// A brick the overlay hid the frame it was shot (TerrainBricks.hide_at,
// Docs/BrickOverlay.md stage 6): its studs go with it till its tile is rebuilt.
uniform int overlay_holes = 0;
uniform vec3 overlay_hole_lo[8];
uniform vec3 overlay_hole_hi[8];
uniform float sky_sun_power : hint_range(1.0, 4.0) = 2.0;
uniform vec3 block_light_colour : source_color = vec3(1.0, 0.52, 0.22);
uniform float block_light_energy : hint_range(0.0, 4.0) = 1.0;
uniform float block_light_ao : hint_range(0.0, 1.0) = 0.5;
varying float v_sky;
varying float v_block;
varying float l_sun;
varying float l_spec;
varying float l_rim;
#endif
varying vec3 v_local;
varying vec3 v_colour;
varying vec3 v_flat_normal;
varying flat int v_mat;
varying flat int v_grain;
varying flat int v_set;

void vertex() {
#ifdef NEAR_STUD_RANGE
    // A stud past the geometry's reach is a card (stud_card.gdshader), or
    // nothing: collapsed to its origin, it rasterises nothing, and nothing
    // below is worked out for it. By the STUD's own distance, so the band's
    // buffer is written when its bricks change and never because the camera
    // moved (Docs/BrickBevel.md 3).
    if (length(MODEL_MATRIX[3].xyz - CAMERA_POSITION_WORLD) * lod_zoom >= near_stud_radius) {
        VERTEX = vec3(0.0);
    } else {
#endif
    v_local = VERTEX;
#ifdef GRID_LIGHT
    if (grid_light.x >= 0.0) {
        mat4 to_chunk = transpose(mat4(grid_from_world_x, grid_from_world_y,
                grid_from_world_z, vec4(0.0, 0.0, 0.0, 1.0))) * MODEL_MATRIX;
        v_grid_p = (to_chunk * vec4(VERTEX, 1.0)).xyz;
        v_grid_n = normalize(mat3(to_chunk) * NORMAL);
    }
#endif
    v_colour = COLOR.rgb * tint.rgb;
    v_flat_normal = normalize(NORMAL);
    v_mat = brick_material_id(COLOR.a);
    v_grain = brick_grain_axis(COLOR.a);
    v_set = bm_pbr_set(MAT_TEX[v_mat], v_colour);
#ifdef INSTANCE_SKY
    v_sky = INSTANCE_CUSTOM.r;
    v_block = INSTANCE_CUSTOM.g;
    if (overlay_holes > 0) {
        // The stud's foot, a centimetre down into the brick it stands on.
        vec3 foot = MODEL_MATRIX[3].xyz - vec3(0.0, 0.01, 0.0);
        for (int i = 0; i < 8; i++) {
            if (i >= overlay_holes) {
                break;
            }
            if (all(greaterThan(foot, overlay_hole_lo[i])) && all(lessThan(foot, overlay_hole_hi[i]))) {
                VERTEX = vec3(0.0);
            }
        }
    }
#endif
    // A stud's corners are softened in the shading (stud_round): each
    // vertex's normal leans out from the axis, so across a flat face the
    // interpolated normal turns a little the way a cylinder's does. The
    // 45-degree rim keeps its lean. v_flat_normal above keeps the true face,
    // for the toolpaths.
    if (top_mode == 1 && abs(NORMAL.y) < 0.95) {
        float rl = length(VERTEX.xz);
        if (rl > 1e-5) {
            float h = length(NORMAL.xz);
            vec3 round_n = vec3(VERTEX.x / rl * h, NORMAL.y, VERTEX.z / rl * h);
            NORMAL = normalize(mix(NORMAL, round_n, stud_round));
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
#ifdef NEAR_STUD_RANGE
    }
#endif
}

/// How far p is inside a regular n-gon of the given corner radius (vertex on
/// +X, the orientation PieceMeshes.stud builds), with the corners rounded:
/// a soft maximum over the edges, `soft` metres of it. Its level sets are
/// the outline shrunk inward with round corners -- a toolpath's loops.
float ngon_depth_round(vec2 p, int n, float radius, float soft) {
    float apothem = radius * cos(3.14159265 / float(n));
    float d[16];
    float worst = -1e9;
    for (int i = 0; i < n; i++) {
        float a = PS_TAU * (float(i) + 0.5) / float(n);
        d[i] = dot(p, vec2(cos(a), sin(a)));
        worst = max(worst, d[i]);
    }
    float sum = 0.0;
    for (int i = 0; i < n; i++) {
        sum += exp((d[i] - worst) / soft);
    }
    return apothem - (worst + soft * log(sum));
}

void fragment() {
    vec3 albedo = v_colour;
    float dist = length(VERTEX) * lod_zoom;   // scaled through a scope (brick.gdshader)

    int mat = v_mat;
    int face = ps_face(v_flat_normal);
    float roughness = ps_roughness(face, mat, MAT_ROUGH[mat] + (surface_roughness - MAT_ROUGH[0]));
    float print_rough = 0.0;
    vec3 aniso_dir = vec3(0.0);
    float aniso = 0.0;
    if (print_lines_enabled && ps_printed(mat)) {
        float t;
        float t_d;
        // Metres along the beads (ps_bead_tex): x + z round a loop and up a
        // side -- on the two side facets that face along x - z it stands
        // still, and their layers show no wander along them, still each
        // layer its own -- and across a top's diagonals their own way.
        float u = v_local.x + v_local.z;
        float junction = 0.0;
        if (face != 0) {
            float bw = ps_bead(face, mat);
            if (top_mode == 1 && face == 1) {
                // The walls round the outline, then the diagonals. A real
                // stud top is 4.8 mm across: two 0.45 mm loops and about
                // seven lines inside them.
                float depth = ngon_depth_round(v_local.xz, contour_sides, contour_radius,
                        bw * 0.2);
                float wall = float(ps_walls(mat)) * bw;
                if (depth < wall) {
                    t = depth / bw;
                } else {
                    t = dot(v_local.xz, vec2(0.7071, 0.7071)) / bw;
                    u = dot(v_local.xz, vec2(-0.7071, 0.7071));
                }
                t_d = t;
                // Where the lines meet the inner wall, the fine dark line
                // the brick's top has too.
                if (wall > 0.0) {
                    float jw = 0.18 * bw + fwidth(depth);
                    junction = (1.0 - smoothstep(0.0, jw, abs(depth - wall))) * 0.6;
                }
            } else {
                t = dot(v_local.xz, vec2(0.7071, face == 2 ? -0.7071 : 0.7071)) / bw;
                t_d = t;
                u = dot(v_local.xz, vec2(face == 2 ? 0.7071 : -0.7071, 0.7071));
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
        ps_beads(t, t_d, u, face, mat, dist, VERTEX, 0.0, junction, 0.0,
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
    if (v_set >= 0) {
        // The same set as its brick, cut the same way -- in the stud's own
        // frame (a stud is one shared mesh, and does not know where it stands
        // in the brick), so the grain runs the brick's way but does not
        // continue its figure.
        roughness = clamp(roughness + PBR_ROUGH_SHIFT[v_set], 0.04, 1.0);
        if (dist < pbr_far_range) {
            float colour_w = 1.0 - smoothstep(pbr_far_range * 0.75, pbr_far_range, dist);
            float bump = pbr_bump * (1.0 - smoothstep(pbr_range * 0.7, pbr_range, dist));
            bm_pbr(v_set, v_local, v_flat_normal, v_grain, dFdx(VERTEX), dFdy(VERTEX), colour_w, bump,
                    albedo, roughness, NORMAL);
        }
    } else if (tex != 0) {
        vec2 p = abs(v_flat_normal.y) > 0.7 ? v_local.xz : vec2(v_local.x + v_local.z, v_local.y);
        float tfade = 1.0 - smoothstep(print_fade_begin, print_fade_end * 2.0, dist);
        if (tex == 4) {
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
    if (tex == 10) {
        emission = bm_lamp(albedo);
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
#ifdef GRID_LIGHT
    AO = grid_light_shade(v_grid_p, v_grid_n, albedo, emission);
#endif
    // Under a cloud, less sun (clouds.gdshaderinc; Docs/Lighting.md 2b).
    albedo *= cloud_shade((INV_VIEW_MATRIX * vec4(VERTEX, 1.0)).xyz);
    ALBEDO = albedo;
    ROUGHNESS = out_rough;
    SPECULAR = out_spec;
    float metal = MAT_METAL[mat] * (v_set >= 0 ? PBR_METAL[v_set] : 1.0);
    METALLIC = metal;
    ps_tangent_frame(NORMAL, aniso_dir, TANGENT, BINORMAL);
    ANISOTROPY = aniso;
    EMISSION = emission;
#ifdef INSTANCE_SKY
    float sky_k0 = pow(sky_light_curve, 15.0);
    float sky_b = clamp((pow(sky_light_curve, 15.0 - 15.0 * clamp(v_sky, 0.0, 1.0)) - sky_k0)
            / (1.0 - sky_k0), 0.0, 1.0);
    float blk_b = clamp((pow(sky_light_curve, 15.0 - 15.0 * clamp(v_block, 0.0, 1.0)) - sky_k0)
            / (1.0 - sky_k0), 0.0, 1.0);
    AO = mix(sky_light_floor, 1.0, max(sky_b, blk_b * block_light_ao));
    EMISSION += block_light_colour * albedo * (blk_b * block_light_energy);
    l_spec = SPECULAR;
    SPECULAR = SPECULAR * sqrt(AO);
    l_sun = pow(sky_b, sky_sun_power);
    l_rim = RIM;
#endif
    RIM = surface_rim * (1.0 - metal);
    RIM_TINT = 0.4;
}

#ifdef INSTANCE_SKY
float sky_schlick(float u) {
    float m = 1.0 - u;
    float m2 = m * m;
    return m2 * m2 * m;
}

// The terrain shader's light() (SKY_LIGHT): the engine's own lighting, the
// sun scaled by the sky light; any other light as the engine draws it.
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
