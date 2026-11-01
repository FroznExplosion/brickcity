// What a brick is made of, and how that looks. Shared by brick.gdshader (the
// bricks) and printed_core.gdshaderinc (their studs), so a steel brick has
// steel studs.
//
// The material rides in the vertex colour's ALPHA (brick_grid.h, block_rgba):
// alpha 1.0 is material 0, PLA, so every mesh made before materials existed --
// and the terrain, which never sets one -- is plain PLA without a change.
// RGB is already the resolved colour: a filament's, or the material's own
// variant (oak, brass, slate). This file only decides how the SURFACE reads.
//
// The natural materials -- wood, metal, stone, leaves -- are texture sets
// read as SOLIDS (bm_pbr, at the end; Docs/PbrWood.md): a point's look comes
// from where it is in the block, not from which face it lies on. The
// printed filaments' looks are still PROCEDURAL, from the face's own
// coordinates in metres, each face hashing its corner into a seed.
//
// The order of the tables below is brick_grid.h's BRICK_MATERIALS order, and
// both are append-only.
//
//   id  material     printed  look
//    0  PLA          yes      the house style: satin, layer lines
//    1  PLA matte    yes      flat, soft highlight
//    2  PLA silk     yes      glossy, metallic sheen that follows the view
//    3  ABS          yes      a touch glossier, finer layers
//    4  PETG         yes      clear: brick_glass.gdshader, blended
//    5  TPU          yes      rubbery matte, wide soft beads
//    6  Nylon        yes      matte with a fine fibrous grain
//    7  Glow PLA     yes      lit from inside
//    8  Carbon PLA   yes      dark, with a fine twill of fibre
//    9  Wood PLA     yes      layers, plus the streaky banding of wood fill
//   10  Wood         no       solid PBR wood: a texture set, cut as a block
//                             along the piece's grain axis (bm_pbr)
//   11  Metal        no       PBR brushed steel, streaks along the long side
//   12  Stone        no       PBR polished veined stone
//   13  Leaf         no       PBR leaves, for a tree's crown

const int MAT_COUNT = 14;
const float MAT_PRINTED[14] = float[](1.0, 1.0, 1.0, 1.0, 1.0, 1.0, 1.0, 1.0, 1.0, 1.0, 0.0, 0.0, 0.0, 0.0);
const float MAT_ROUGH[14]   = float[](0.42, 0.80, 0.22, 0.30, 0.16, 0.86, 0.70, 0.50, 0.58, 0.62, 0.42, 0.30, 0.72, 0.78);
const float MAT_SPEC[14]    = float[](0.55, 0.28, 0.80, 0.60, 0.72, 0.18, 0.32, 0.50, 0.40, 0.35, 0.40, 0.50, 0.32, 0.22);
// Metal at 0.8, not 1.0: a fully metallic surface is exactly as bright as
// what it reflects, and brass and copper came out dull brown wherever the
// surroundings were plain. A fifth of diffuse keeps the metal's own colour.
const float MAT_METAL[14]   = float[](0.0, 0.0, 0.35, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.8, 0.0, 0.0);
// Multipliers on the bead: layer height and width, how proud a bead stands,
// and how dark the groove between two reads.
const float MAT_LAYER[14]   = float[](1.0, 1.0, 1.0, 0.8, 1.0, 1.6, 1.0, 1.0, 1.0, 1.2, 1.0, 1.0, 1.0, 1.0);
const float MAT_RELIEF[14]  = float[](1.0, 1.1, 0.6, 0.8, 0.45, 0.7, 0.9, 1.0, 1.0, 1.0, 1.0, 1.0, 1.0, 1.0);
const float MAT_GROOVE[14]  = float[](1.0, 0.8, 0.6, 1.0, 0.5, 0.7, 0.9, 1.0, 1.0, 1.0, 1.0, 1.0, 1.0, 1.0);
// Walls: how many loops a slicer walks round the outline before it fills the
// inside, seen on a top or bottom face (print_surface.gdshaderinc). Two is
// the ordinary print -- what a real brick's top shows under its studs -- and
// three on the tough engineering filaments (nylon, carbon), which are the
// ones printed thick. Not printed: 0.
const int MAT_WALLS[14]     = int[](2, 2, 2, 2, 2, 2, 3, 2, 3, 2, 0, 0, 0, 0);
// 0 none, 1 wood, 2 brushed metal, 3 stone, 4 carbon twill, 5 glow, 6 silk,
// 7 nylon fibre, 8 wood-fill banding, 9 leaves. 1, 2, 3 and 9 are texture
// sets (bm_pbr, at the end); the rest procedural.
const int MAT_TEX[14]       = int[](0, 0, 6, 0, 0, 0, 7, 5, 4, 8, 1, 2, 3, 9);
// Light passes through (brick_grid.h `translucent`). With a glass pass on the
// material these are drawn there instead; without one -- a material nobody
// gave a second pass -- they draw here, glossy and solid.
const float MAT_TRANSLUCENT[14] = float[](0.0, 0.0, 0.0, 0.0, 1.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0);

// The alpha byte's low five bits are the material; the two above them the
// brick's grain axis (brick_grid.h grain_axis; Docs/PbrWood.md).
int brick_material_id(float alpha) {
    return clamp(int(round((1.0 - alpha) * 255.0)) & 31, 0, MAT_COUNT - 1);
}

// Which way a brick was cut: 0 along X, 1 along Z, 2 up Y.
int brick_grain_axis(float alpha) {
    return (int(round((1.0 - alpha) * 255.0)) >> 5) & 3;
}

// --- noise ----------------------------------------------------------------

float bm_hash(vec2 p) {
    return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453);
}

float bm_hash3(vec3 p) {
    return fract(sin(dot(p, vec3(127.1, 311.7, 74.7))) * 43758.5453);
}

float bm_noise(vec2 p) {
    vec2 i = floor(p);
    vec2 f = fract(p);
    vec2 u = f * f * (3.0 - 2.0 * f);
    return mix(mix(bm_hash(i), bm_hash(i + vec2(1.0, 0.0)), u.x),
               mix(bm_hash(i + vec2(0.0, 1.0)), bm_hash(i + vec2(1.0, 1.0)), u.x), u.y);
}

float bm_fbm(vec2 p) {
    float v = 0.0;
    float a = 0.5;
    for (int i = 0; i < 4; i++) {
        v += a * bm_noise(p);
        p = p * 2.03 + vec2(17.1, 9.2);
        a *= 0.5;
    }
    return v;
}

// --- the looks --------------------------------------------------------------
//
// `p` is the surface position in metres with x ALONG the grain (the piece's
// long side) and y across it; `seed` is 0..1 per face; `fade` goes to 0 with
// distance, where fine detail would only shimmer. Each returns the albedo and
// nudges roughness.

vec3 bm_wood(vec3 base, vec2 p, float seed, float fade, inout float rough) {
    vec2 q = p + vec2(seed * 13.0, seed * 7.0);
    // Growth rings cut at a shallow angle read as long stretched bands along
    // the board, warped by the grain. A few per stud.
    float warp = bm_fbm(vec2(q.x * 1.3, q.y * 5.0)) * 1.4;
    float ring = fract(q.y * 16.0 + warp + q.x * 0.35);
    float band = smoothstep(0.0, 0.25, ring) * smoothstep(1.0, 0.6, ring);
    vec3 col = base * mix(0.74, 1.06, band);
    // Fine fibre streaks along the grain.
    float fibre = bm_noise(vec2(q.x * 3.0, q.y * 160.0));
    col *= mix(1.0, 0.9 + 0.18 * fibre, fade);
    rough += (1.0 - band) * 0.08;
    return col;
}

vec3 bm_metal(vec3 base, vec2 p, float seed, float fade, inout float rough) {
    vec2 q = p + vec2(seed * 11.0, seed * 5.0);
    // Brushing: long thin streaks along the piece, fading out at range.
    float streak = bm_noise(vec2(q.x * 4.0, q.y * 420.0));
    float mottle = bm_fbm(q * 6.0);
    vec3 col = base * (0.92 + 0.12 * mottle);
    col *= mix(1.0, 0.9 + 0.16 * streak, fade);
    rough = clamp(rough + (streak - 0.5) * 0.12 * fade + (mottle - 0.5) * 0.1, 0.05, 1.0);
    return col;
}

vec3 bm_stone(vec3 base, vec2 p, float seed, float fade, inout float rough) {
    vec2 q = p * 3.0 + vec2(seed * 19.0, seed * 3.0);
    float mottle = bm_fbm(q * 2.0);
    vec3 col = base * (0.84 + 0.3 * mottle);
    // Veins: where a warped sine crosses zero. Darker on a light stone,
    // lighter on a dark one.
    float v = abs(sin((q.x + q.y * 0.6) * 2.2 + bm_fbm(q * 1.5) * 5.0));
    float vein = (1.0 - smoothstep(0.0, 0.07, v)) * fade;
    float light = dot(base, vec3(0.333));
    vec3 vein_col = light > 0.5 ? base * 0.55 : base + vec3(0.35);
    col = mix(col, vein_col, vein * 0.7);
    // Speckle, as granite has.
    col *= mix(1.0, 0.92 + 0.16 * bm_hash(floor(q * 90.0)), fade * 0.6);
    rough += (mottle - 0.5) * 0.1;
    return col;
}

vec3 bm_carbon(vec3 base, vec2 p, float fade) {
    // Carbon-filled filament is its colour dulled and darkened, with a fine
    // twill of fibre catching the light.
    vec3 col = base * 0.45 + vec3(0.03);
    float a = step(0.5, fract((p.x + p.y) * 30.0));
    float b = step(0.5, fract((p.x - p.y) * 30.0));
    float twill = abs(a - b);
    return col * mix(1.0, 0.85 + 0.3 * twill, fade);
}

vec3 bm_nylon(vec3 base, vec2 p, float fade) {
    float fuzz = bm_noise(p * 900.0);
    return base * mix(1.0, 0.94 + 0.1 * fuzz, fade);
}

// `layer_t` is height in 20 mm steps (what a layer was before they were 57 a
// brick), so the bands kept their size when the layers got finer.
vec3 bm_wood_fill(vec3 base, vec2 p, float layer_t, float seed, float fade) {
    // Wood-filled PLA prints with streaky light and dark bands where the
    // nozzle ran hotter or cooler -- along the LAYERS, not a grain.
    float band = bm_noise(vec2(layer_t * 0.35 + seed * 40.0, p.x * 2.0));
    float fleck = bm_hash(floor(p * 350.0));
    vec3 col = base * (0.82 + 0.3 * band);
    return col * mix(1.0, 0.95 + 0.08 * fleck, fade);
}

// --- PBR texture sets (Docs/PbrWood.md) -------------------------------------
//
// A natural material is a SOLID, not a wallpaper: a point's look comes from
// where it is in a block of the stuff, not from which face it lies on. The
// block is the chunk's (plus `grain_origin`, the chunk's place on the grid), so
// bricks side by side are cut from one block, and a piece broken off keeps
// its pattern.
//
// Each set is ambientCG (CC0; textures/<material>/): colour with roughness in
// alpha, and an OpenGL normal map, bound as global uniforms so every brick
// material has them. Colour is the photo over its own mean, times the brick's
// colour: the variants (oak, walnut; steel, brass; marble, slate; the greens)
// are many looks from one set, and a brick's average colour is its own.
//
//   wood    Wood049, a solid field: rings round an axis along the grain
//           (bm_wood_coords), so the grain runs on round every edge
//   metal   Metal009, brushed: each face the plane it faces (bm_box_coords),
//           its streaks along the piece's long side
//   stone   Marble012, polished: as metal, no grain. Polished stone has no
//           relief to speak of (its map is flat), so no normal read
//   leaf    ScatteredLeaves008, three quarters greyed so the brick's green
//           is the colour: as stone, with relief

global uniform sampler2D wood_albedo_rough : filter_linear_mipmap_anisotropic, repeat_enable;
global uniform sampler2D wood_normal : filter_linear_mipmap_anisotropic, repeat_enable;
global uniform sampler2D metal_albedo_rough : filter_linear_mipmap_anisotropic, repeat_enable;
global uniform sampler2D metal_normal : filter_linear_mipmap_anisotropic, repeat_enable;
global uniform sampler2D stone_albedo_rough : filter_linear_mipmap_anisotropic, repeat_enable;
global uniform sampler2D leaf_albedo_rough : filter_linear_mipmap_anisotropic, repeat_enable;
global uniform sampler2D leaf_normal : filter_linear_mipmap_anisotropic, repeat_enable;

// Per set, by MAT_TEX (1 wood, 2 metal, 3 stone, 9 leaf): the colour's
// linear mean and the roughness map's mean (tools: pack_sets in the doc);
// how far the roughness map is spread (the maps are subtle -- wood's spread is
// 0.08 -- and the spread is what shows as a sheen moving with the light); and
// the normal map's strength (times the material's pbr_bump).
bool bm_is_pbr(int tex) {
    return tex == 1 || tex == 2 || tex == 3 || tex == 9;
}

const vec3 WOOD_MEAN = vec3(0.2019, 0.1272, 0.0773);
const vec3 METAL_MEAN = vec3(0.2886, 0.2994, 0.3105);
const vec3 STONE_MEAN = vec3(0.4210, 0.4271, 0.4753);
const vec3 LEAF_MEAN = vec3(0.2526, 0.2267, 0.1295);
const vec4 PBR_ROUGH_MEAN = vec4(0.504, 0.469, 0.066, 0.523);   // wood, metal, stone, leaf
const vec4 PBR_ROUGH_GAIN = vec4(2.5, 2.0, 2.0, 1.5);
const vec4 PBR_BUMP = vec4(2.0, 1.5, 0.0, 1.5);
// Metres one repeat covers (metal, stone, leaf; wood's is WOOD_TILE). Every
// one divides PBR_PERIOD, so a chunk's grid origin can be passed modulo it and
// stay exact (BrickMaterials.set_grain_origin).
const vec3 PBR_TILE = vec3(1.0, 2.0, 1.5);
// Metres along the grain, and across it in ring units. Wood's field repeats
// every 6 m on every axis with these (2 along, 3 and 1 across). Change them
// and keep PBR_PERIOD a multiple of 2 * WOOD_TILE.x and 3 * WOOD_TILE.y.
const vec2 WOOD_TILE = vec2(2.0, 1.0);
const float PBR_PERIOD = 96.0;

/// Where `p` (chunk metres) lies in the block of wood, in texture repeats:
/// x along the grain, y across the rings.
///
/// The photo is side grain: fibres along its x, rings striping down its y. A
/// side samples it as it is, a top a wider cut through the same rings, and an
/// end -- where "along" stands still -- a column of it swept across the end.
vec2 bm_wood_coords(vec3 p, int axis) {
    // q.x along the grain; q.y and q.z across it, q.z the one a horizontal
    // board's sides stand in.
    vec3 q = axis == 0 ? p.xzy : (axis == 1 ? p.zxy : p.yxz);
    // Rings cut at a slant: a third as fast across the board's width as up
    // its edge, so a top shows the wide figure of a flat-sawn plank and a
    // side the narrow lines. The sine bends them as rings bend, and repeats
    // with the field.
    float ph = q.z / WOOD_TILE.y + 2.0 * q.y / (3.0 * WOOD_TILE.y) + q.x / WOOD_TILE.x;
    float s = q.y / 3.0 + q.z + 0.06 * sin(6.28318530718 * ph);
    return vec2(q.x / WOOD_TILE.x, s / WOOD_TILE.y);
}

float bm_comp(vec3 v, int i) {
    return i == 0 ? v.x : (i == 1 ? v.y : v.z);
}

/// A face's own plane of the block, metres: the projection square to the axis
/// its normal is nearest (`n`, chunk space). Along the grain first where the
/// grain lies in that plane, so brushing runs the piece's length; an end face
/// takes its other two axes. One projection, not a blend of three: a brick's
/// faces are square to an axis, and a bevel's seam is a millimetre wide.
vec2 bm_box_coords(vec3 p, vec3 n, int axis) {
    // A 45-degree slope or bevel picks the same plane every pixel: Y first,
    // then X, never a coin toss on rounding.
    vec3 a = abs(n) + vec3(0.01, 0.02, 0.0);
    int k = a.x >= a.y && a.x >= a.z ? 0 : (a.y >= a.z ? 1 : 2);
    int g = axis == 0 ? 0 : (axis == 1 ? 2 : 1);
    if (k == g) {
        return vec2(bm_comp(p, k == 0 ? 2 : 0), bm_comp(p, k == 1 ? 2 : 1));
    }
    return vec2(bm_comp(p, g), bm_comp(p, 3 - k - g));
}

/// The set `tex` at chunk point `p` (normal `n`, grain `axis`) onto albedo
/// and roughness; and with `bump` above 0 its normal map, bent into `normal`
/// through a tangent frame from the screen derivatives (any face, at any
/// angle, as it falls). `dpx`/`dpy`: the view-space position's derivatives.
void bm_pbr(int tex, vec3 p, vec3 n, int axis, vec3 dpx, vec3 dpy, float colour_w,
        float bump, inout vec3 albedo, inout float rough, inout vec3 normal) {
    int k = tex == 1 ? 0 : (tex == 2 ? 1 : (tex == 3 ? 2 : 3));
    vec2 t = tex == 1 ? bm_wood_coords(p, axis)
            : bm_box_coords(p, n, axis) / (tex == 2 ? PBR_TILE.x : (tex == 3 ? PBR_TILE.y : PBR_TILE.z));
    // fract and explicit gradients: the gradients of the unwrapped t keep the
    // mip steady across the wrap.
    vec2 dtx = dFdx(t);
    vec2 dty = dFdy(t);
    vec2 f = fract(t);
    vec4 ar;
    vec3 mean;
    if (k == 0) {
        ar = textureGrad(wood_albedo_rough, f, dtx, dty);
        mean = WOOD_MEAN;
    } else if (k == 1) {
        ar = textureGrad(metal_albedo_rough, f, dtx, dty);
        mean = METAL_MEAN;
    } else if (k == 2) {
        ar = textureGrad(stone_albedo_rough, f, dtx, dty);
        mean = STONE_MEAN;
    } else {
        ar = textureGrad(leaf_albedo_rough, f, dtx, dty);
        mean = LEAF_MEAN;
    }
    vec3 c = pow(ar.rgb, vec3(2.2));
    albedo = mix(albedo, clamp(albedo * c / mean, 0.0, 1.0), colour_w);
    rough = clamp(rough + (ar.a - PBR_ROUGH_MEAN[k]) * PBR_ROUGH_GAIN[k] * colour_w, 0.04, 1.0);
    bump *= PBR_BUMP[k];
    if (bump > 0.0) {
        vec2 nxy;
        if (k == 0) {
            nxy = textureGrad(wood_normal, f, dtx, dty).xy;
        } else if (k == 1) {
            nxy = textureGrad(metal_normal, f, dtx, dty).xy;
        } else {
            nxy = textureGrad(leaf_normal, f, dtx, dty).xy;
        }
        nxy = nxy * 2.0 - 1.0;
        nxy.y = -nxy.y;   // OpenGL green is up the image; t.y runs down it
        // Cotangent frame (Schueler): the directions t.x and t.y grow in,
        // across this surface.
        vec3 dp2perp = cross(dpy, normal);
        vec3 dp1perp = cross(normal, dpx);
        vec3 tg = dp2perp * dtx.x + dp1perp * dty.x;
        vec3 bt = dp2perp * dtx.y + dp1perp * dty.y;
        float m = max(dot(tg, tg), dot(bt, bt));
        if (m > 1e-24) {
            float inv = inversesqrt(m);
            normal = normalize(normal + (tg * nxy.x + bt * nxy.y) * inv * bump);
        }
    }
}
