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
// Every look but wood's is PROCEDURAL, from the face's own coordinates in
// metres. Each face hashes its own corner into a seed, so two stone bricks
// side by side are two pieces of stone, not one texture stamped twice. Wood
// is a texture set read as a solid block (bm_wood_pbr, at the end; Docs/
// PbrWood.md) -- the first of the looks to go that way.
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
//                             along the piece's grain axis (bm_wood_pbr)
//   11  Metal        no       metallic, brushed along the long side
//   12  Stone        no       mottled, with veins
//   13  Leaf         no       vegetation: flat, soft, matte

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
// 7 nylon fibre, 8 wood-fill banding.
const int MAT_TEX[14]       = int[](0, 0, 6, 0, 0, 0, 7, 5, 4, 8, 1, 2, 3, 0);
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

// --- solid wood, PBR (Docs/PbrWood.md) ---------------------------------------
//
// Wood is a SOLID, not a wallpaper: a point's colour comes from where it is in
// a block of wood, not from which face it lies on. Every face of a brick -- top,
// sides, bottom, its bevels, a slope's or a round's surface -- is a cut
// through the same block, so the grain runs on round an edge; and the block is
// the chunk's (plus `grain_origin`, the chunk's place on the grid), so two
// bricks stacked or laid end to end with their grain the same way continue
// one another, as if cut from one plank.
//
// The texture set (ambientCG Wood049, CC0; textures/wood/) is a photograph of
// side grain: along its x the fibres run, along its y the growth rings
// stripe across. The field maps a point to (along the grain, ring), so a side
// samples the photo as it is, a top a wider cut through the same rings, and
// an end -- where "along" stands still -- a column of the photo swept across
// the end as its rings.
//
// Colour: the photo divided by its own mean, onto the brick's colour, so oak,
// walnut and cherry (the variants' RGB) are three woods from one set.

global uniform sampler2D wood_albedo_rough : filter_linear_mipmap_anisotropic, repeat_enable;// RGB colour (sRGB), A roughness
global uniform sampler2D wood_normal : filter_linear_mipmap_anisotropic, repeat_enable;// normal map, OpenGL green

const vec3 WOOD_MEAN = vec3(0.2019, 0.1272, 0.0773);   // the colour's mean, linear
const float WOOD_ROUGH_MEAN = 0.504;
// The roughness map is subtle (spread 0.08); scaled up so the grain shows as
// a sheen that moves with the light and the eye, which is most of what says
// "lit wood" rather than "a photo of wood" (Docs/PbrWood.md 2).
const float WOOD_ROUGH_GAIN = 2.5;
// Metres one repeat of the texture covers: along the grain, and across it in
// ring units. The field repeats every 6 m on every axis with these (2 along,
// 3 and 1 across), so a chunk's grid origin can be passed modulo
// WOOD_PERIOD and stay exact (BrickMaterials.grain_origin). Change them and
// keep WOOD_PERIOD a multiple of 2 * WOOD_TILE.x and 3 * WOOD_TILE.y.
const vec2 WOOD_TILE = vec2(2.0, 1.0);
const float WOOD_PERIOD = 96.0;

/// Where `p` (chunk metres) lies in the block of wood, in texture repeats:
/// x along the grain, y across the rings.
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

/// The texture set at `t` (bm_wood_coords), onto albedo and roughness; and
/// with `bump` above 0 the normal map, bent into `normal` through a tangent
/// frame from the screen derivatives (any face, at any angle, as it falls).
/// `dtx`/`dty` are t's screen derivatives and `dpx`/`dpy` the position's
/// (view space), taken by the caller.
void bm_wood_pbr(vec2 t, vec2 dtx, vec2 dty, vec3 dpx, vec3 dpy, float colour_w,
        float bump, inout vec3 albedo, inout float rough, inout vec3 normal) {
    // fract and explicit gradients: a global sampler's wrap is not ours to
    // set, and the gradients of the unwrapped t keep the mip steady across
    // the wrap.
    vec2 f = fract(t);
    vec4 ar = textureGrad(wood_albedo_rough, f, dtx, dty);
    vec3 c = pow(ar.rgb, vec3(2.2));
    albedo = mix(albedo, clamp(albedo * c / WOOD_MEAN, 0.0, 1.0), colour_w);
    rough = clamp(rough + (ar.a - WOOD_ROUGH_MEAN) * WOOD_ROUGH_GAIN * colour_w, 0.04, 1.0);
    if (bump > 0.0) {
        vec2 nxy = textureGrad(wood_normal, f, dtx, dty).xy * 2.0 - 1.0;
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
