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
//   14  Lamp         yes      a diffuser lit from behind: its colour, bright

const int MAT_COUNT = 15;
const float MAT_PRINTED[15] = float[](1.0, 1.0, 1.0, 1.0, 1.0, 1.0, 1.0, 1.0, 1.0, 1.0, 0.0, 0.0, 0.0, 0.0, 1.0);
const float MAT_ROUGH[15]   = float[](0.42, 0.80, 0.22, 0.30, 0.16, 0.86, 0.70, 0.50, 0.58, 0.62, 0.42, 0.30, 0.72, 0.78, 0.55);
const float MAT_SPEC[15]    = float[](0.55, 0.28, 0.80, 0.60, 0.72, 0.18, 0.32, 0.50, 0.40, 0.35, 0.40, 0.50, 0.32, 0.22, 0.40);
// Metal at 0.8, not 1.0: a fully metallic surface is exactly as bright as
// what it reflects, and brass and copper came out dull brown wherever the
// surroundings were plain. A fifth of diffuse keeps the metal's own colour.
const float MAT_METAL[15]   = float[](0.0, 0.0, 0.35, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.8, 0.0, 0.0, 0.0);
// Multipliers on the bead: layer height and width, how proud a bead stands,
// and how dark the groove between two reads.
const float MAT_LAYER[15]   = float[](1.0, 1.0, 1.0, 0.8, 1.0, 1.6, 1.0, 1.0, 1.0, 1.2, 1.0, 1.0, 1.0, 1.0, 1.0);
const float MAT_RELIEF[15]  = float[](1.0, 1.1, 0.6, 0.8, 0.45, 0.7, 0.9, 1.0, 1.0, 1.0, 1.0, 1.0, 1.0, 1.0, 0.4);
const float MAT_GROOVE[15]  = float[](1.0, 0.8, 0.6, 1.0, 0.5, 0.7, 0.9, 1.0, 1.0, 1.0, 1.0, 1.0, 1.0, 1.0, 0.5);
// Walls: how many loops a slicer walks round the outline before it fills the
// inside, seen on a top or bottom face (print_surface.gdshaderinc). Two is
// the ordinary print -- what a real brick's top shows under its studs -- and
// three on the tough engineering filaments (nylon, carbon), which are the
// ones printed thick. Not printed: 0.
const int MAT_WALLS[15]     = int[](2, 2, 2, 2, 2, 2, 3, 2, 3, 2, 0, 0, 0, 0, 2);
// 0 none, 1 wood, 2 brushed metal, 3 stone, 4 carbon twill, 5 glow, 6 silk,
// 7 nylon fibre, 8 wood-fill banding, 9 leaves, 10 lamp. 1, 2, 3 and 9 are
// texture sets (bm_pbr, at the end); the rest procedural.
const int MAT_TEX[15]       = int[](0, 0, 6, 0, 0, 0, 7, 5, 4, 8, 1, 2, 3, 9, 10);
// Light passes through (brick_grid.h `translucent`). With a glass pass on the
// material these are drawn there instead; without one -- a material nobody
// gave a second pass -- they draw here, glossy and solid.
const float MAT_TRANSLUCENT[15] = float[](0.0, 0.0, 0.0, 0.0, 1.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0);

// A Lamp (MAT_TEX 10): a diffuser lit from behind shines its colour at full
// strength, whatever the light round it (Docs/Lighting.md 6.3).
const float LAMP_GLOW = 2.4;
vec3 bm_lamp(vec3 albedo) {
    return albedo / max(max(albedo.r, albedo.g), max(albedo.b, 0.05)) * LAMP_GLOW;
}

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
// Each material has a texture ARRAY, one slice per set (ambientCG, CC0;
// textures/pbr/): colour with roughness in alpha, and a second array of
// OpenGL normal maps for the sets that have relief. Each variant picks a set
// (the tables below): walnut is a walnut photo, slate a rock, verdigris a
// patina. Colour is still the photo over its own mean, times the variant's
// colour, so a brick's average colour is its swatch's, and two variants on
// one set (oak and ash; copper and brass) differ by it.
//
//   wood    a solid field: rings round an axis along the grain
//           (bm_wood_coords), so the grain runs on round every edge
//   metal   each face the plane it faces (bm_box_coords), brushing along the
//           piece's long side
//   stone   as metal. Polished stone has no relief (its map is flat), so
//           only the rough ones have a normal slice
//   leaf    ScatteredLeaves008, three quarters greyed so the brick's green
//           is the colour; one set for every filament colour

global uniform sampler2DArray wood_albedo_rough : filter_linear_mipmap_anisotropic, repeat_enable;
global uniform sampler2DArray wood_normal : filter_linear_mipmap_anisotropic, repeat_enable;
global uniform sampler2DArray metal_albedo_rough : filter_linear_mipmap_anisotropic, repeat_enable;
global uniform sampler2DArray metal_normal : filter_linear_mipmap_anisotropic, repeat_enable;
global uniform sampler2DArray stone_albedo_rough : filter_linear_mipmap_anisotropic, repeat_enable;
global uniform sampler2DArray stone_normal : filter_linear_mipmap_anisotropic, repeat_enable;
global uniform sampler2DArray leaf_albedo_rough : filter_linear_mipmap_anisotropic, repeat_enable;
global uniform sampler2DArray leaf_normal : filter_linear_mipmap_anisotropic, repeat_enable;

bool bm_is_pbr(int tex) {
    return tex == 1 || tex == 2 || tex == 3 || tex == 9;
}

// The sets, all materials in one numbering. Per set: its material (0 wood,
// 1 metal, 2 stone, 3 leaf) and slice in that material's arrays (-1: none --
// polished metal is its colour, mirror-smooth; a flat-relief set has no
// normal slice); the colour's linear mean and the roughness map's mean (the
// packing script prints both, Docs/PbrWood.md); how far the roughness map is
// spread (the spread is what shows as a sheen moving with the light); the
// normal map's strength (times the material's pbr_bump); the metres one
// repeat covers (box-mapped sets; wood's is WOOD_TILE), each dividing
// PBR_PERIOD; how much rougher than the material's own MAT_ROUGH the stuff is
// (concrete is not marble); how metallic, of the material's MAT_METAL (rust
// and patina are not bare metal); and how much of the photo's own hue to keep
// (PBR_HUE).
//
//    0 Wood049   oak, teak, ash, cedar      11 polished  chrome, gold, silver
//    1 Wood051   walnut, ebony              12 Marble012 white marble
//    2 Wood066   cherry, mahogany           13 Marble016 black, green marble
//    3 Wood095   birch, maple, bamboo       14 Granite002A grey, pink granite
//    4 Wood096   pine (knots)               15 Rock058   slate, basalt
//    5 Wood062   weathered, driftwood       16 Travertine009 limestone, travertine
//    6 Metal009  steel, stainless, alu, Ti  17 Travertine004 sandstone
//    7 Metal055A iron, gunmetal             18 Concrete030 concrete
//    8 Metal053B rusted iron                19 Clay005   terracotta
//    9 Metal047A copper, brass, bronze      20 ScatteredLeaves008 every leaf
//   10 Metal058C verdigris
const int PBR_KIND[21]   = int[](0, 0, 0, 0, 0, 0,  1, 1, 1, 1, 1, 1,  2, 2, 2, 2, 2, 2, 2, 2,  3);
const int PBR_LAYER[21]  = int[](0, 1, 2, 3, 4, 5,  0, 1, 2, 3, 4, -1,  0, 1, 2, 3, 4, 5, 6, 7,  0);
const int PBR_NLAYER[21] = int[](0, 1, 2, 3, 4, 5,  0, -1, -1, -1, -1, -1,  -1, -1, -1, 0, -1, -1, 1, 2,  0);
const vec3 PBR_MEAN[21] = vec3[](
    vec3(0.2023, 0.1275, 0.0775), vec3(0.0550, 0.0352, 0.0282), vec3(0.1113, 0.0380, 0.0078),
    vec3(0.6105, 0.3352, 0.1589), vec3(0.4571, 0.3417, 0.2363), vec3(0.1299, 0.0918, 0.0729),
    vec3(0.2886, 0.2994, 0.3105), vec3(0.5169, 0.5160, 0.5158), vec3(0.4955, 0.4785, 0.4615),
    vec3(0.5954, 0.2315, 0.1082), vec3(0.2840, 0.4786, 0.4074), vec3(1.0000, 1.0000, 1.0000),
    vec3(0.4210, 0.4271, 0.4753), vec3(0.0539, 0.0585, 0.0558), vec3(0.4927, 0.4703, 0.4466),
    vec3(0.0807, 0.0918, 0.1052), vec3(0.7411, 0.6012, 0.4154), vec3(0.3728, 0.3063, 0.2410),
    vec3(0.1263, 0.1172, 0.1089), vec3(0.3447, 0.1882, 0.1076), vec3(0.2526, 0.2267, 0.1295));
const float PBR_ROUGH_MEAN[21] = float[](
        0.504, 0.543, 0.329, 0.567, 0.670, 0.677, 0.469, 0.274, 0.291, 0.263, 0.453, 0.000,
        0.066, 0.114, 0.023, 0.650, 0.037, 0.033, 0.728, 0.490, 0.523);
const float PBR_ROUGH_GAIN[21] = float[](2.5, 2.5, 2.5, 2.5, 2.5, 2.0,  2.0, 2.0, 1.0, 2.5, 2.0, 0.0,
        2.0, 2.0, 2.0, 1.0, 2.0, 2.0, 2.0, 2.0,  1.5);
const float PBR_BUMP[21] = float[](2.0, 2.0, 3.0, 2.0, 2.5, 1.0,  1.5, 0.0, 0.0, 0.0, 0.0, 0.0,
        0.0, 0.0, 0.0, 1.0, 0.0, 0.0, 1.2, 1.0,  1.5);
const float PBR_TILE[21] = float[](0.0, 0.0, 0.0, 0.0, 0.0, 0.0,  1.0, 1.5, 2.0, 1.0, 2.0, 1.0,
        2.0, 2.0, 1.0, 3.0, 2.0, 2.0, 2.0, 1.5,  1.5);
const float PBR_ROUGH_SHIFT[21] = float[](0.0, 0.0, -0.08, 0.0, 0.15, 0.3,  0.0, 0.1, 0.3, -0.05, 0.35, -0.22,
        -0.45, -0.45, -0.4, 0.0, -0.3, 0.1, 0.1, 0.05,  0.0);
const float PBR_METAL[21] = float[](1.0, 1.0, 1.0, 1.0, 1.0, 1.0,  1.0, 1.0, 0.35, 1.0, 0.2, 1.0,
        1.0, 1.0, 1.0, 1.0, 1.0, 1.0, 1.0, 1.0,  1.0);
// Colour is the photo over its mean channel by channel at 1 -- rust's orange
// and patina's green stay where they are on any variant -- and by brightness
// alone at 0. A strongly coloured photo wants less: cherry's blue mean is
// 0.008, and blue over it is noise, not figure.
const float PBR_HUE[21] = float[](1.0, 0.5, 0.3, 0.5, 0.6, 0.6,  1.0, 1.0, 1.0, 0.3, 1.0, 1.0,
        1.0, 1.0, 1.0, 1.0, 0.5, 0.6, 1.0, 0.4,  1.0);
const int PBR_LEAF_SET = 20;

// Which set a variant is. The colours are brick_grid.h's WOOD_VARIANTS,
// METAL_VARIANTS and STONE_VARIANTS in order -- the vertex colour IS the
// variant, so the nearest of its material's list says which one (eight bits
// a channel cannot blur two of them: wood_probe checks every variant comes
// back as itself, and that these lists match the engine's).
const vec3 WOOD_RGB[14] = vec3[](
    vec3(0.72, 0.54, 0.33), vec3(0.36, 0.24, 0.16), vec3(0.62, 0.33, 0.21), vec3(0.86, 0.70, 0.47),
    vec3(0.90, 0.81, 0.64), vec3(0.45, 0.20, 0.13), vec3(0.88, 0.74, 0.54), vec3(0.60, 0.42, 0.24),
    vec3(0.13, 0.10, 0.09), vec3(0.80, 0.72, 0.58), vec3(0.70, 0.42, 0.28), vec3(0.86, 0.76, 0.50),
    vec3(0.58, 0.56, 0.52), vec3(0.72, 0.68, 0.60));
// oak walnut cherry pine birch mahogany maple teak ebony ash cedar bamboo weathered driftwood
const int WOOD_SET[14] = int[](0, 1, 2, 4, 3, 2, 3, 0, 1, 0, 0, 3, 5, 5);
const vec3 METAL_RGB[14] = vec3[](
    vec3(0.62, 0.63, 0.65), vec3(0.76, 0.77, 0.78), vec3(0.85, 0.86, 0.88), vec3(0.93, 0.94, 0.96),
    vec3(0.36, 0.35, 0.34), vec3(0.48, 0.26, 0.14), vec3(0.86, 0.50, 0.34), vec3(0.88, 0.73, 0.38),
    vec3(0.72, 0.50, 0.26), vec3(1.00, 0.80, 0.36), vec3(0.92, 0.92, 0.93), vec3(0.55, 0.56, 0.60),
    vec3(0.25, 0.27, 0.30), vec3(0.36, 0.62, 0.52));
// steel stainless aluminium chrome iron rusted copper brass bronze gold silver titanium gunmetal verdigris
const int METAL_SET[14] = int[](6, 6, 6, 11, 7, 8, 9, 9, 9, 11, 11, 6, 7, 10);
const vec3 STONE_RGB[12] = vec3[](
    vec3(0.92, 0.91, 0.88), vec3(0.12, 0.12, 0.13), vec3(0.52, 0.52, 0.53), vec3(0.72, 0.55, 0.52),
    vec3(0.28, 0.31, 0.34), vec3(0.82, 0.68, 0.48), vec3(0.84, 0.81, 0.72), vec3(0.20, 0.20, 0.21),
    vec3(0.72, 0.38, 0.25), vec3(0.62, 0.61, 0.58), vec3(0.24, 0.40, 0.32), vec3(0.86, 0.78, 0.64));
// white marble, black marble, grey granite, pink granite, slate, sandstone,
// limestone, basalt, terracotta, concrete, green marble, travertine
const int STONE_SET[12] = int[](12, 13, 14, 14, 15, 17, 16, 15, 19, 18, 13, 16);

/// The set a vertex of material look `tex` and colour `c` takes; -1 not a
/// texture set. Per vertex (flat), so the search is nothing per pixel.
int bm_pbr_set(int tex, vec3 c) {
    if (tex == 9) {
        return PBR_LEAF_SET;
    }
    int best = -1;
    float bd = 1e9;
    if (tex == 1) {
        for (int i = 0; i < 14; i++) {
            vec3 d = c - WOOD_RGB[i];
            if (dot(d, d) < bd) { bd = dot(d, d); best = WOOD_SET[i]; }
        }
    } else if (tex == 2) {
        for (int i = 0; i < 14; i++) {
            vec3 d = c - METAL_RGB[i];
            if (dot(d, d) < bd) { bd = dot(d, d); best = METAL_SET[i]; }
        }
    } else if (tex == 3) {
        for (int i = 0; i < 12; i++) {
            vec3 d = c - STONE_RGB[i];
            if (dot(d, d) < bd) { bd = dot(d, d); best = STONE_SET[i]; }
        }
    }
    return best;
}

// Metres along the grain, and across it in ring units. Wood's field repeats
// every 6 m on every axis with these (2 along, 3 and 1 across). Change them
// and keep PBR_PERIOD a multiple of 2 * WOOD_TILE.x and 3 * WOOD_TILE.y (and
// of every PBR_TILE), so a chunk's grid origin can be passed modulo it and
// stay exact (BrickMaterials.set_grain_origin).
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

/// Set `s` (bm_pbr_set) at chunk point `p` (normal `n`, grain `axis`) onto
/// albedo and roughness; and with `bump` above 0 its normal map, bent into
/// `normal` through a tangent frame from the screen derivatives (any face, at
/// any angle, as it falls). `dpx`/`dpy`: the view-space position's
/// derivatives. The set's roughness shift and metalness are the caller's
/// (they hold at any distance; this is only the near detail).
void bm_pbr(int s, vec3 p, vec3 n, int axis, vec3 dpx, vec3 dpy, float colour_w,
        float bump, inout vec3 albedo, inout float rough, inout vec3 normal) {
    int k = PBR_KIND[s];
    int layer = PBR_LAYER[s];
    if (layer < 0) {
        return;
    }
    vec2 t = k == 0 ? bm_wood_coords(p, axis) : bm_box_coords(p, n, axis) / PBR_TILE[s];
    // fract and explicit gradients: the gradients of the unwrapped t keep the
    // mip steady across the wrap.
    vec2 dtx = dFdx(t);
    vec2 dty = dFdy(t);
    vec3 f = vec3(fract(t), float(layer));
    vec4 ar;
    if (k == 0) {
        ar = textureGrad(wood_albedo_rough, f, dtx, dty);
    } else if (k == 1) {
        ar = textureGrad(metal_albedo_rough, f, dtx, dty);
    } else if (k == 2) {
        ar = textureGrad(stone_albedo_rough, f, dtx, dty);
    } else {
        ar = textureGrad(leaf_albedo_rough, f, dtx, dty);
    }
    vec3 c = pow(ar.rgb, vec3(2.2));
    const vec3 LUM = vec3(0.2126, 0.7152, 0.0722);
    vec3 ratio = mix(vec3(dot(c, LUM) / dot(PBR_MEAN[s], LUM)), c / PBR_MEAN[s], PBR_HUE[s]);
    albedo = mix(albedo, clamp(albedo * min(ratio, vec3(4.0)), 0.0, 1.0), colour_w);
    rough = clamp(rough + (ar.a - PBR_ROUGH_MEAN[s]) * PBR_ROUGH_GAIN[s] * colour_w, 0.04, 1.0);
    bump *= PBR_BUMP[s];
    int nl = PBR_NLAYER[s];
    if (bump > 0.0 && nl >= 0) {
        vec3 fn = vec3(f.xy, float(nl));
        vec2 nxy;
        if (k == 0) {
            nxy = textureGrad(wood_normal, fn, dtx, dty).xy;
        } else if (k == 1) {
            nxy = textureGrad(metal_normal, fn, dtx, dty).xy;
        } else if (k == 2) {
            nxy = textureGrad(stone_normal, fn, dtx, dty).xy;
        } else {
            nxy = textureGrad(leaf_normal, fn, dtx, dty).xy;
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
