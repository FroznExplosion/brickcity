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
// Every look is PROCEDURAL, from the face's own coordinates in metres: no
// textures, the same rule as the rest of the palette (spec section 2). Each
// face hashes its own corner into a seed, so two oak bricks side by side are
// two pieces of oak, not one texture stamped twice.
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
//   10  Wood         no       rings and grain along the piece's long side
//   11  Metal        no       metallic, brushed along the long side
//   12  Stone        no       mottled, with veins

const int MAT_COUNT = 13;
const float MAT_PRINTED[13] = float[](1.0, 1.0, 1.0, 1.0, 1.0, 1.0, 1.0, 1.0, 1.0, 1.0, 0.0, 0.0, 0.0);
const float MAT_ROUGH[13]   = float[](0.42, 0.80, 0.22, 0.30, 0.16, 0.86, 0.70, 0.50, 0.58, 0.62, 0.55, 0.30, 0.72);
const float MAT_SPEC[13]    = float[](0.55, 0.28, 0.80, 0.60, 0.72, 0.18, 0.32, 0.50, 0.40, 0.35, 0.40, 0.50, 0.32);
// Metal at 0.8, not 1.0: a fully metallic surface is exactly as bright as
// what it reflects, and brass and copper came out dull brown wherever the
// surroundings were plain. A fifth of diffuse keeps the metal's own colour.
const float MAT_METAL[13]   = float[](0.0, 0.0, 0.35, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.8, 0.0);
// Multipliers on the bead: layer height and width, how proud a bead stands,
// and how dark the groove between two reads.
const float MAT_LAYER[13]   = float[](1.0, 1.0, 1.0, 0.8, 1.0, 1.6, 1.0, 1.0, 1.0, 1.2, 1.0, 1.0, 1.0);
const float MAT_RELIEF[13]  = float[](1.0, 1.1, 0.6, 0.8, 0.45, 0.7, 0.9, 1.0, 1.0, 1.0, 1.0, 1.0, 1.0);
const float MAT_GROOVE[13]  = float[](1.0, 0.8, 0.6, 1.0, 0.5, 0.7, 0.9, 1.0, 1.0, 1.0, 1.0, 1.0, 1.0);
// 0 none, 1 wood, 2 brushed metal, 3 stone, 4 carbon twill, 5 glow, 6 silk,
// 7 nylon fibre, 8 wood-fill banding.
const int MAT_TEX[13]       = int[](0, 0, 6, 0, 0, 0, 7, 5, 4, 8, 1, 2, 3);
// Light passes through (brick_grid.h `translucent`). With a glass pass on the
// material these are drawn there instead; without one -- a material nobody
// gave a second pass -- they draw here, glossy and solid.
const float MAT_TRANSLUCENT[13] = float[](0.0, 0.0, 0.0, 0.0, 1.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0);

int brick_material_id(float alpha) {
    return clamp(int(round((1.0 - alpha) * 255.0)), 0, MAT_COUNT - 1);
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

vec3 bm_wood_fill(vec3 base, vec2 p, float layer_t, float seed, float fade) {
    // Wood-filled PLA prints with streaky light and dark bands where the
    // nozzle ran hotter or cooler -- along the LAYERS, not a grain.
    float band = bm_noise(vec2(layer_t * 0.35 + seed * 40.0, p.x * 2.0));
    float fleck = bm_hash(floor(p * 350.0));
    vec3 col = base * (0.82 + 0.3 * band);
    return col * mix(1.0, 0.95 + 0.08 * fleck, fade);
}
