// The printed surface: layer lines up the sides, toolpaths across the tops and
// bottoms, and how shiny each of those faces is. Shared by brick.gdshader (the
// chunk meshes) and printed_core.gdshaderinc (studs, scatter, debris), so a
// stud and the brick under it came off the same printer.
//
// Needs brick_materials.gdshaderinc included first (the MAT_ tables).
//
// A real FDM part has three different surfaces, and reading as printed is
// mostly getting the difference between them right:
//
//   sides    stacked layers. Dull: every layer is a little cylinder, so the
//            face is a washboard that scatters light ACROSS the layers and
//            keeps a tight highlight ALONG them -- an anisotropic highlight,
//            stretched across the lines.
//   top      the last layer, ironed flat by the nozzle: wide squashed lines
//            in a 45-degree raster inside a few loops of wall. Satin.
//   bottom   whatever the bed was. Glass leaves a mirror; smooth PEI a satin;
//            textured PEI a matte powder-coat grain. The first layer is
//            squashed flattest of all, so its lines barely show.
//
// The lighting is already physically based (GGX, Schlick Fresnel at plastic's
// 4 %): this decides the inputs -- roughness per face, the bead relief, and
// ANISOTROPY with its direction, which is the one part a flat material cannot
// fake and the one that still reads when the lines themselves are too fine to
// draw.

#include "res://shaders/print_finish.gdshaderinc"

group_uniforms print;
uniform bool print_lines_enabled = true;
// 57 layers on a 2x4's side: a real printed brick, 9.6 mm at 0.168 mm a
// layer. So 19 a plate, and at 1:43.75 that is 7.4 mm.
//
// It was 0.020 (21 a brick), raised from 0.00875 because a layer that thin
// is about a pixel at two metres and the resolve filter below dissolves it.
// That is still true: at 57 a brick the lines are drawn within a few metres
// and dissolve past that. What carries the print further now is not the line
// but the anisotropy -- the highlight smeared across the layers, which is how
// a real print looks from across a room too.
//
// Snapped to a whole number a plate (ps_layer), so a material with coarser
// or finer layers (MAT_LAYER) still finishes each brick on a whole layer.
uniform float layer_height = 0.0073684;
// Top and bottom lines. Wider than a side layer is tall: the nozzle squashes
// a skin line flat, and the first layer is squashed flatter still into the bed.
uniform float top_bead_width = 0.028;
uniform float bottom_bead_width = 0.032;
// Half-width of the shadow between two beads, as a fraction of one bead.
uniform float bead_groove : hint_range(0.0, 0.5) = 0.17;
uniform float layer_darken : hint_range(0.0, 1.0) = 0.86;
// How proud each bead stands: what turns a drawn line into a ridge.
uniform float layer_relief : hint_range(0.0, 1.0) = 0.28;
// No printer lays two identical layers -- a little more plastic, a degree
// hotter. A per-layer shade wobble on the sides.
uniform float layer_wobble : hint_range(0.0, 0.3) = 0.06;
// Where the pattern starts and finishes dissolving, in beads a pixel. Below
// ~0.3 a bead is several pixels and worth drawing; past ~0.75 it is under a
// pixel and drawing it only makes it crawl (terrain.gdshader, the long version).
uniform float resolve_begin : hint_range(0.05, 1.0) = 0.30;
uniform float resolve_end : hint_range(0.1, 2.0) = 0.75;
// Added to every material's wall count (MAT_WALLS): the "strong print"
// setting a slicer has. Shows as more loops round the top and bottom.
uniform int wall_bonus : hint_range(-3, 4) = 0;
uniform float print_fade_begin = 6.0;
uniform float print_fade_end = 20.0;
// How far the layers stretch the highlight across themselves. Not faded with
// distance: sub-pixel lines are exactly what anisotropy stands in for.
uniform float print_anisotropy : hint_range(0.0, 0.9) = 0.55;

group_uniforms finish;
// Added to the material's roughness on a printed side, taken off on a top.
uniform float side_dullness : hint_range(0.0, 0.5) = 0.08;
uniform float top_gloss : hint_range(0.0, 0.5) = 0.06;
// Roughness multiplier for an injection-moulded part (PRINT_FINISH 1): a
// polished mould gives every face the same glossy skin.
uniform float molded_gloss : hint_range(0.1, 1.0) = 0.5;

const float PS_PLATE = 0.14;   // brick_grid.h PLATE_M
const float PS_TAU = 6.28318530718;

// 0 side, 1 top, 2 bottom, from a normal in the part's own space.
int ps_face(vec3 n) {
    return n.y > 0.7 ? 1 : (n.y < -0.7 ? 2 : 0);
}

// Printed at all: the finish is printed and the material is a filament.
bool ps_printed(int mat) {
    return PRINT_FINISH == 0 && MAT_PRINTED[mat] > 0.5;
}

float ps_layer(int mat) {
    float n = max(round(PS_PLATE / (layer_height * MAT_LAYER[mat])), 1.0);
    return PS_PLATE / n;
}

float ps_bead(int face, int mat) {
    return (face == 2 ? bottom_bead_width : top_bead_width) * MAT_LAYER[mat];
}

int ps_walls(int mat) {
    return max(MAT_WALLS[mat] + wall_bonus, 0);
}

// `base` is the material's own roughness; this is what the face makes of it.
float ps_roughness(int face, int mat, float base) {
    if (MAT_PRINTED[mat] < 0.5) {
        return base;
    }
    if (PRINT_FINISH == 1) {
        return base * molded_gloss;
    }
    if (face == 0) {
        return base + side_dullness;
    }
    if (face == 1) {
        return base - top_gloss;
    }
    if (PRINT_BED == 0) {
        // Glass: a mirror whatever went on it -- matte PLA a little less so.
        return mix(0.05, base, 0.15);
    }
    if (PRINT_BED == 1) {
        return base * 0.6;
    }
    return min(base + 0.2, 1.0);
}

// How much of the bead shows on this face: (groove shade, relief).
vec2 ps_face_k(int face) {
    if (face == 0) {
        // 0.17 mm layers are a fine sheen of lines, not corrugation.
        return vec2(0.6, 0.6);
    }
    if (face == 1) {
        return vec2(0.9, 0.7);
    }
    if (PRINT_BED == 0) {
        return vec2(0.2, 0.1);
    }
    if (PRINT_BED == 1) {
        return vec2(0.35, 0.25);
    }
    return vec2(0.05, 0.05);
}

// The beads. `t` counts them and must be CONTINUOUS -- the ridge normal comes
// from its screen-space gradient, and fract() would put a cliff in that once
// a bead. `vertex` is view-space VERTEX; `seed` is 0..1 per face, for the
// layer wobble; `junction` 0..1 darkens where the infill meets the walls.
// Writes the anisotropy direction (view space, across the beads) and amount.
void ps_beads(float t, int face, int mat, float dist, vec3 vertex, float seed, float junction,
        inout vec3 albedo, inout vec3 normal, inout float rough,
        inout vec3 aniso_dir, inout float aniso) {
    vec2 fk = ps_face_k(face);
    vec3 dpx = dFdx(vertex);
    vec3 dpy = dFdy(vertex);
    vec3 grad = dpx * dFdx(t) + dpy * dFdy(t);
    float glen = length(grad);
    if (glen > 1e-8) {
        aniso_dir = grad / glen;
        aniso = print_anisotropy * min(fk.y * MAT_RELIEF[mat], 1.0);
    }

    float fade = 1.0 - smoothstep(print_fade_begin, print_fade_end, dist);
    if (fade <= 0.0) {
        return;
    }
    float ph = fract(t);
    float aa = max(fwidth(t), 1e-5);
    // Dissolve toward the average as a bead approaches a pixel: below its own
    // sampling rate a bead pattern does not fade, it CRAWLS.
    float resolved = 1.0 - smoothstep(resolve_begin, resolve_end, aa);
    float groove = max(aa * 1.4, bead_groove * MAT_GROOVE[mat]);
    float ink = (1.0 - smoothstep(0.0, groove, abs(ph - 0.5))) * resolved;
    ink = max(ink, junction * resolved);
    albedo *= mix(1.0, layer_darken, ink * fade * MAT_GROOVE[mat] * fk.x);
    if (face == 0) {
        float w = bm_hash(vec2(floor(t), seed * 97.0)) - 0.5;
        albedo *= 1.0 + w * layer_wobble * resolved * fade;
    }

    if (glen > 1e-8 && resolved > 0.0) {
        // SQUARED: a half-resolved ridge still swings the specular highlight
        // a long way for a small camera move, and a moving speckle reads as
        // z-fighting. Normals have to give up earlier than colour.
        float relief_k = resolved * resolved;
        normal = normalize(normal + aniso_dir * sin(ph * PS_TAU)
                * layer_relief * MAT_RELIEF[mat] * fk.y * fade * relief_k);
        // ...and roughness takes over what the normal drops: an unresolved
        // bead is sub-pixel roughness now, not gone.
        rough += (1.0 - relief_k) * fade * layer_relief * 0.5 * fk.y;
    }
}

// Textured PEI's powder-coat grain on a bottom face. `p` is the face in
// metres, `ax_u`/`ax_v` its two axes in view space. Nothing on other beds.
void ps_bed_grain(vec2 p, vec3 ax_u, vec3 ax_v, inout vec3 albedo, inout vec3 normal,
        inout float rough) {
    if (PRINT_BED != 2) {
        return;
    }
    // ~0.2 mm grains at 1:43.75.
    vec2 q = p * 110.0;
    float aa = max(fwidth(q.x) + fwidth(q.y), 1e-5);
    float resolved = 1.0 - smoothstep(0.35, 0.9, aa);
    float n0 = bm_noise(q);
    float nx = bm_noise(q + vec2(0.25, 0.0));
    float ny = bm_noise(q + vec2(0.0, 0.25));
    vec2 slope = vec2(nx - n0, ny - n0) * 4.0;
    normal = normalize(normal - (ax_u * slope.x + ax_v * slope.y) * 0.18 * resolved);
    albedo *= 1.0 + (n0 - 0.5) * 0.06 * resolved;
    rough += (1.0 - resolved) * 0.06;
}

// Hand the anisotropy to the lighting. TANGENT is the rough direction --
// across the beads -- so the highlight smears across the layers and stays
// tight along them. Godot only bends its frame for ANISOTROPY above 0.01.
void ps_tangent_frame(vec3 normal, vec3 aniso_dir, inout vec3 tangent, inout vec3 binormal) {
    vec3 tg = aniso_dir - normal * dot(normal, aniso_dir);
    float l = length(tg);
    if (l > 1e-5) {
        tangent = tg / l;
        binormal = cross(normal, tangent);
    }
}
