#ifndef BRICK_TERRAIN_H
#define BRICK_TERRAIN_H

#include <godot_cpp/classes/ref_counted.hpp>
#include <godot_cpp/variant/array.hpp>
#include <godot_cpp/variant/color.hpp>
#include <godot_cpp/variant/dictionary.hpp>
#include <godot_cpp/variant/packed_float32_array.hpp>
#include <godot_cpp/variant/packed_int32_array.hpp>
#include <godot_cpp/variant/packed_vector4_array.hpp>
#include <godot_cpp/variant/vector2.hpp>

#include "brick_grid.h"

#include <cstdint>
#include <vector>

using namespace godot;

namespace brick {

// ---------------------------------------------------------------------------
// Terrain, as pure maths. Docs/Terrain.md.
//
// Everything here is a function of (global cell, world seed) and nothing else.
// That is section 6.3's requirement and it is not a style preference: a tile
// approached from the other side has to lay the same bricks, and a tile that
// streams in late has to agree with one that streamed in early. A scanline
// packer that accumulates state cannot promise either.
//
// Nothing in this namespace touches a Node, a Ref, or the engine's noise
// classes, so the whole of it is safe to run on a worker thread -- which is
// what Plan.md section 3 asks of generation and baking.
// ---------------------------------------------------------------------------

/// A terrain voxel is one stud x one BRICK x one stud. Not a plate: a
/// plate-tall voxel is three times the data for a step nobody reads at ground
/// scale. The 0.42 m step that choice creates is made walkable by the ramp
/// layer, not by shrinking the voxel (Terrain section 4).
constexpr float BRICK_M = PLATE_M * PLATES_PER_BRICK;

constexpr int TILE = 32;      ///< studs a side. 11.2 m -- a chunk's XZ footprint.
constexpr int MARGIN = 2;     ///< is_plate and ramp_dir both read one cell out.
constexpr int SPAN = TILE + 2 * MARGIN;

/// The packer's lattice. Cut positions repeat every PERIOD studs, offset per
/// row, and the split within a period comes from the partition table.
///
/// A memoryless per-cell cut probability would give a GEOMETRIC length
/// distribution -- mostly short pieces -- which is the opposite of a laid
/// floor. A partition table gives exact control over the mix instead, and the
/// mix asked for is "mostly 2x4".
constexpr int PERIOD = 12;
constexpr int MAX_LEN = 6;

/// Chance a row-pair bonds into 2-deep pieces rather than staying two 1-deep
/// rows. High, because 2xN is the point.
constexpr float BOND_CHANCE = 0.86f;

/// How many PLATES of real voxels are kept below the lowest surface in a
/// section. Deep enough for a crater and a cave mouth; everything below is
/// uniform rock and is not in the mask at all (section 17.4).
constexpr int SECTION_BELOW = 54;

/// Plates per brick, spelled out because the terrain mask is indexed in
/// PLATES and the packer still thinks in bricks (section 17.3).
constexpr int PLATES_PER_CELL = PLATES_PER_BRICK;

/// Bumped whenever the generator's output changes. A saved damage diff is
/// meaningless against a different field, so a stale stamp must invalidate the
/// save rather than misapply it -- mvs-c's LAYOUT_VERSION lesson.
/// 2: volumetric. A heightmap delta and a voxel diff are different formats,
/// so damage saved under version 1 must be REJECTED, not misapplied.
/// Slope pieces at every single-brick terrace step.
///
/// OFF. They exist to make a 0.42 m step walkable, but a 1x1 slope is a
/// 50-degree face a third of a metre across -- twenty times a chamfer -- and
/// at close range the ground reads as melted rather than built. Walkability
/// moves to the character's step-up height, which already exists.
///
/// The cells that were ramps do not vanish: they are terrace edges, so they
/// are not flat plates, so the packer makes them TILES. Dropping slopes
/// raises the smooth-tile share on its own.
constexpr bool RAMPS_ENABLED = false;

/// Chance a flat plate piece is laid as a smooth TILE rather than a studded
/// brick. Ground that is wall-to-wall studs reads as one material; a mix of
/// tile and brick reads as a surface someone laid.
constexpr float TILE_CHANCE = 0.22f;

constexpr int FIELD_VERSION = 2;

enum Material {
    MAT_AIR = 0,
    MAT_GRASS,
    MAT_DIRT,
    MAT_SAND,
    MAT_STONE,
    MAT_DARK_STONE,
    MAT_ROAD,
    MATERIAL_COUNT
};

/// Filament index per material. Terrain does not get a colour table of its
/// own: a terrain brick and a building brick printed in the same filament have
/// to be the same colour, or the world stops reading as one set of parts.
inline int material_filament(int m) {
    switch (m) {
        case MAT_GRASS: return FIL_GREEN;
        case MAT_DIRT: return FIL_BROWN;
        case MAT_SAND: return FIL_TAN;
        case MAT_STONE: return FIL_GREY;
        case MAT_DARK_STONE: return FIL_DARK_GREY;
        case MAT_ROAD: return FIL_DARK_GREY;
        default: return FIL_GREY;
    }
}

/// Road is paved: no studs. Everything natural takes them.
inline bool material_studded(int m) {
    return m != MAT_ROAD && m != MAT_AIR;
}

// --- hashing ---------------------------------------------------------------
//
// One stateless mix, behind every random decision terrain makes: which
// partition, which row offset, which piece tint, where scatter lands.
//
// Deliberately NOT BrickWorld's seeded RNG. D9's actual requirement is
// reproducibility, and a hash gives MORE of it than a sequence does: it is
// order-independent, so the world does not depend on which tile the camera
// asked for first. It is held to the same standard -- one named function, no
// ad-hoc randomness at call sites.

inline uint32_t mix32(uint32_t h) {
    h ^= h >> 16;
    h *= 0x7feb352dU;
    h ^= h >> 15;
    h *= 0x846ca68bU;
    h ^= h >> 16;
    return h;
}

inline uint32_t hash3(int32_t a, int32_t b, int32_t c) {
    return mix32((uint32_t)a * 73856093U ^ (uint32_t)b * 19349663U ^ (uint32_t)c * 83492791U);
}

inline float hashf(int32_t a, int32_t b, int32_t c) {
    return (float)hash3(a, b, c) * (1.0f / 4294967296.0f);
}

// --- the generator ---------------------------------------------------------
//
// Value noise with a smooth fade and fractal octaves, written out rather than
// taken from FastNoiseLite. Two reasons: it is pure integer hashing plus float
// arithmetic, so it is identical on every platform and safe on any thread, and
// it keeps the field a function of the seed alone with no engine object to
// configure and forget to configure.

float value_noise(float x, float y, uint32_t seed);
float fbm(float x, float y, uint32_t seed, int octaves, float lacunarity, float gain);

float value_noise3(float x, float y, float z, uint32_t seed);

/// The field. Held by value, copied freely, never a singleton in disguise.
///
/// VOLUMETRIC as of section 17: `solid_at` is the truth and the surface is
/// derived from it, not the other way round. The 2D functions survive because
/// the generator still builds its surface from 2D noise -- a cave only ever
/// removes material, so `nominal_top` is an upper bound on the real surface
/// and scanning down from it is cheap.
struct Field {
    uint32_t seed = 1337;

    /// The same surface BEFORE it is quantised, in plates.
    ///
    /// Steepness has to be measured on this and not on `top_plate`: the
    /// quantised surface of gentle ground is a field of one-plate steps, so
    /// every slope from 0.1 to 0.9 plates a stud measures as exactly the
    /// same "one", and a steepness test on it can only ever say "1 or 0".
    float raw_plate(int x, int z) const;

    /// The topmost solid PLATE the 2D noise alone would give. An upper bound
    /// on the real surface once caves are carved out of it.
    ///
    /// Primary: the brick height is derived from it, not the other way
    /// round, so the generator can quantise to plates (0.14 m) instead of
    /// bricks (0.42 m) and get three times the vertical resolution.
    int top_plate(int x, int z) const;

    /// The same surface in BRICKS, for material banding and cave depth.
    int nominal_height(int x, int z) const;
    int material_at(int x, int z, int h) const;

    /// Is this PLATE cell solid, and of what? 0 is air.
    ///
    /// This is the truth the whole system now rests on. Everything else --
    /// the surface height, the packer's input, the heightmap water samples --
    /// is derived from it.
    int solid_at(int x, int yp, int z) const;

    /// Is this plate cell inside a carved cave?
    ///
    /// `top` is the column's nominal top plate, passed in because the caller
    /// almost always has it already and recomputing three octaves of fBm per
    /// CELL rather than per COLUMN was 85x of the sampling cost.
    bool cave_at(int x, int yp, int z) const;
    bool cave_at(int x, int yp, int z, int top) const;
};

/// Player and generator edits, sparse, keyed by packed global PLATE cell.
///
/// This is the damage record, and it is the whole of it. An untouched world
/// stores nothing; a crater stores one byte per plate it removed. Same
/// doctrine as a building's damage record (Plan section 4.2) -- the recipe is
/// a function, and only the difference from it is written down.
int64_t pack_cell(int x, int yp, int z);
int edit_at(int64_t key);          ///< -1 when there is no edit
void set_edit(int x, int yp, int z, int material);
/// Deepest edited plate anywhere in the 3x3 tile neighbourhood of (tx, tz),
/// or INT_MAX when nothing there has been touched. The mask has to reach
/// it, or digging past the section floor punches a hole the mesher cannot
/// see.
int deepest_edit_near(int tx, int tz);
void clear_edits();
size_t edit_count();
bool edits_empty();

/// One tile's field, sampled once with a margin.
///
/// Holds BOTH representations, because both are wanted and neither is
/// redundant:
///
///   `vox`  the volumetric mask, one material a PLATE cell. What caves,
///          overhangs and craters live in, and what the face mesher walks.
///   `h`    the topmost solid per column, in BRICKS, derived from `vox`.
///          What the packer, the stud rule, collision and water's seabed
///          texture read -- all of which only ever cared about the surface.
///
/// Deriving the second from the first is section 17.7's far-LOD heightmap,
/// computed here rather than stored.
struct TileSample {
    int tx = 0, tz = 0;
    int y0 = 0;        ///< plate index of the bottom of `vox`
    int ysize = 0;     ///< plates of `vox`
    std::vector<uint8_t> vox;    ///< SPAN * ysize * SPAN, material, 0 = air
    /// Air the outside world can reach, flood-filled from the sky and from
    /// the section's sides. A sealed chamber is air, but it is not OPEN air,
    /// and nothing adjacent to it is drawn.
    std::vector<uint8_t> open;

    std::vector<int16_t> h;
    /// The topmost SOLID plate of the column, exactly.
    ///
    /// `h` is that plate's brick, and for untouched ground the two always
    /// agree because the generator builds surfaces on brick boundaries. A
    /// crater does not: it can leave one or two plates of a brick standing,
    /// and drawing that column's top at the BRICK top floats a quad two
    /// plates above the rock with nothing under it.
    std::vector<int16_t> tp;
    std::vector<uint8_t> mat;
    std::vector<uint8_t> plate;
    std::vector<uint8_t> ramp;   ///< 255 = not a ramp, else 0=-X 1=+X 2=-Z 3=+Z
    /// This column is drawn as a CURVED surface rather than packed into
    /// bricks. A function of the biome field and the local steepness, so
    /// two tiles always agree about a column on their shared edge.
    std::vector<uint8_t> smooth;

    static int idx(int lx, int lz) { return (lx + MARGIN) + SPAN * (lz + MARGIN); }
    int height(int lx, int lz) const { return h[idx(lx, lz)]; }
    int material(int lx, int lz) const { return mat[idx(lx, lz)]; }
    bool is_plate(int lx, int lz) const { return plate[idx(lx, lz)] != 0; }
    bool studded(int lx, int lz) const {
        return is_plate(lx, lz) && material_studded(mat[idx(lx, lz)]);
    }

    int vidx(int lx, int yp, int lz) const {
        return (lx + MARGIN) + SPAN * ((yp - y0) + ysize * (lz + MARGIN));
    }
    bool in_y(int yp) const { return yp >= y0 && yp < y0 + ysize; }
    /// Air outside the mask ABOVE, rock outside it below: the world does not
    /// stop at the section, it just stops being interesting.
    int voxel(int lx, int yp, int lz) const {
        if (lx < -MARGIN || lz < -MARGIN || lx >= TILE + MARGIN || lz >= TILE + MARGIN) {
            return MAT_STONE;
        }
        if (yp >= y0 + ysize) {
            return MAT_AIR;
        }
        if (yp < y0) {
            return MAT_STONE;
        }
        return vox[vidx(lx, yp, lz)];
    }
    bool solid(int lx, int yp, int lz) const { return voxel(lx, yp, lz) != MAT_AIR; }
    /// Outside the mask counts as open above and sealed below, matching
    /// `voxel`: the sky is reachable, the bedrock is not.
    bool open_air(int lx, int yp, int lz) const {
        if (lx < -MARGIN || lz < -MARGIN || lx >= TILE + MARGIN || lz >= TILE + MARGIN) {
            return yp >= y0 + ysize;
        }
        if (yp >= y0 + ysize) {
            return true;
        }
        if (yp < y0) {
            return false;
        }
        return open[vidx(lx, yp, lz)] != 0;
    }
};

void sample_tile(const Field &f, int tx, int tz, TileSample &out);

/// What a surface piece IS, which decides how it is drawn and whether it takes
/// studs. Terrain.md section 6.1.
enum PieceKind {
    PIECE_BRICK = 0,  ///< flat plate, studs up
    PIECE_TILE = 1,   ///< flat, smooth top, NO studs -- a terrace edge or lip
    PIECE_RAMP = 2,   ///< 1x1, top tilted one brick toward a lower neighbour
};

/// Ints per piece in `pack_tile`'s flat return: ox, oz, sx, sz, height,
/// material, kind, ramp.
constexpr int PIECE_STRIDE = 8;

/// A packed piece, in TILE-local cells. `sx`/`sz` are its footprint, so a 2x4
/// is (2, 4) or (4, 2) depending which way it was laid -- and both occur,
/// which is the point of the orientation hash in the packer.
struct Piece {
    int16_t ox, oz, sx, sz;
    int16_t h;
    int16_t top;    ///< topmost solid PLATE; the top face is drawn at top + 1
    uint8_t mat;
    uint8_t studded;
    uint8_t kind;   ///< PieceKind
    uint8_t ramp;   ///< 255 unless kind == PIECE_RAMP; else 0=-X 1=+X 2=-Z 3=+Z
    /// A second course laid ON this piece: 0 none, 1 a smooth tile, 2 a
    /// studded plate. When set, the piece's own top face is NOT drawn -- the
    /// overlay covers it exactly, so the quad underneath is culled the same
    /// way a face between two touching blocks is.
    uint8_t overlay;
};

/// An overlay course is one PLATE proud of the brick it sits on: a real tile
/// laid on a real brick, not a decal.
constexpr float OVERLAY_M = PLATE_M;

/// How many brick pieces get one, and how many of those are smooth.
constexpr float OVERLAY_CHANCE = 0.26f;
constexpr float OVERLAY_TILE_SHARE = 0.62f;

/// Is there a piece boundary immediately BEFORE `u` on this row?
///
/// A pure function of the coordinate, which is what makes the packer O(1),
/// order-independent, and safe to re-run around a crater: a forced cut at a
/// dead cell can only disturb MAX_LEN cells either side (section 6.5).
bool cut_before(uint32_t seed, int u, int row_key, int axis);
bool pair_bonds(uint32_t seed, int pair_key, int axis);
int row_offset(uint32_t seed, int row_key, int axis);

/// Per-piece colour jitter. Per PIECE, not per cell: a brick is one moulded
/// colour, and a real print of many parts varies brick to brick. Per stud it
/// would read as surface noise instead.
inline float piece_tint(uint32_t seed, int ox, int oz) {
    return 1.0f + (hashf(ox, oz, (int32_t)(seed ^ 0x7A11U)) - 0.5f) * 0.08f;
}

/// Packs the tile's surface into pieces, LARGEST FIRST.
///
/// Passes run down a size ladder -- 2x6, then 2x4, then 2x3, 1x4, 2x2, and so
/// on to 1x1 -- and each pass places wherever it still fits. That ordering is
/// what makes the ground read as laid rather than tiled: the big bricks go
/// down first, the medium ones take the gaps they left, and the small ones
/// fill what is over.
///
/// Both orientations of every non-square size are candidates, picked per cell
/// by hash, so a floor carries courses running BOTH ways instead of one
/// direction per tile.
///
/// Flat plate cells become PIECE_BRICK. Flat cells that are not plate --
/// terrace lips, corners -- become PIECE_TILE, packed the same way but smooth
/// and studless. Ramps are 1x1 by nature and are placed first so nothing
/// swallows them.
void pack_tile(const Field &f, const TileSample &s, std::vector<Piece> &out,
        std::vector<int32_t> &owner);

} // namespace brick

// ---------------------------------------------------------------------------

/// Terrain's boundary to GDScript. Static methods only -- terrain truth is a
/// function, not an object, and the resident state that will eventually exist
/// (palettised sections, damage diffs) belongs in BrickWorld next to the
/// chunks it will become.
///
/// The calls are BULK. One `build_tile` returns the mesh arrays, the stud
/// MultiMesh buffer, the scatter buffers and the collision boxes together,
/// because the rule that matters at the boundary is one crossing per tile
/// rather than one per piece.
class BrickTerrain : public RefCounted {
    GDCLASS(BrickTerrain, RefCounted);

protected:
    static void _bind_methods();

public:
    static void configure(int64_t world_seed);
    static int get_field_version();
    static int64_t get_seed();

    static float get_brick_metres();
    static int get_tile_studs();
    static int get_max_piece_length();
    static int get_period();
    /// Real 45-degree chamfer cut off every emitted face edge, in metres.
    /// 0 disables it. Costs 7x the triangles -- see the note in the .cpp.
    static void set_face_bevel(double metres);
    static double get_face_bevel();
    static int get_piece_stride();

    static int height_at(int x, int z);
    static int solid_at(int x, int yp, int z);
    static int surface_plate(int x, int z);

    /// Remove every solid plate cell within `radius_m` of a world point.
    ///
    /// This is terrain destruction, and it is deliberately the same shape as
    /// `BrickWorld::apply_hit`: it edits the truth and returns what changed.
    /// Nothing about presentation happens here.
    ///
    /// Returns: `tiles` (tx, tz pairs whose mesh is now stale), `removed`
    /// (plate cells destroyed), and `debris` -- 8 floats a piece: world x, y,
    /// z, size x, y, z in metres, and a packed rgb -- for the caller to throw
    /// as rigid bodies.
    static Dictionary carve(Vector3 world_point, double radius_m);
    /// Heightfield mode: no caves, no edits, no destruction.
    ///
    /// The surface is exactly `nominal_height` and nothing can be below it,
    /// so a column is solid from the mask floor to its top and no further.
    /// Everything downstream -- the packer, studs, tiles, scatter, collision
    /// -- is unchanged; it just gets a field with nothing carved out of it.
    ///
    /// This is section 17's decision taken back, and deliberately as a FLAG
    /// rather than by deleting the volumetric path, because the two differ
    /// only in what `solid_at` answers.
    /// Quantise the generated surface to PLATES rather than to bricks.
    ///
    /// A brick step is 0.42 m, which against a 1.68 m player is a big stair.
    /// A plate step is 0.14 m and the terrain reads as a gentler slope built
    /// out of thinner pieces — the "half bricks to step elevation" idea,
    /// except the grid was already in plates so it costs nothing but a
    /// different multiplier in the generator.
    static void set_plate_steps(bool on);
    static bool get_plate_steps();

    /// Let some ground be a CURVE instead of a stack of bricks.
    ///
    /// Same field, same `tp`, different top face: a smooth column emits one
    /// vertex at its own height and lets the GPU interpolate, where a
    /// bricked one emits a flat quad and side walls. Studs are unchanged --
    /// `stud_at` already means "are my four neighbours at my exact height",
    /// which on a curve means "am I on a flat spot".
    ///
    /// Off by default, and off for the volumetric scene: a curve is a
    /// heightfield statement and a cave roof is not a heightfield.
    static void set_smooth_terrain(bool on);
    static bool get_smooth_terrain();

    /// Is this column drawn as a curve? Biome AND steepness — see
    /// Docs/Terrain.md 18.5.
    static bool smooth_at(int x, int z);

    static void set_flat_mode(bool on);
    static bool get_flat_mode();
    static void set_overlay_chance(double chance);
    static double get_overlay_chance();

    static void clear_terrain_edits();
    static int get_edit_count();
    static int material_at(int x, int z);
    static bool is_plate(int x, int z);
    static bool stud_at(int x, int z);
    static int ramp_dir(int x, int z);
    static int material_filament_index(int m);
    static bool material_takes_studs(int m);

    static int64_t hash3(int a, int b, int c);
    static double hashf(int a, int b, int c);
    static bool cut_before(int u, int row_key, int axis);

    /// `PIECE_STRIDE` ints a piece: ox, oz, sx, sz, height, material, kind,
    /// ramp. Tile-local cells.
    static PackedInt32Array pack_tile(int tx, int tz);

    /// Everything a tile needs, in one crossing.
    ///
    ///   mesh          Array, laid out for ArrayMesh.add_surface_from_arrays
    ///   studs         PackedFloat32Array, 16 floats an instance -- 12 of
    ///                 transform then 4 of colour, which is exactly
    ///                 MultiMesh.set_buffer's layout for TRANSFORM_3D with
    ///                 use_colors, so GDScript uploads it without a loop
    ///   tufts         same layout
    ///   pebbles       same layout
    ///   boxes         PackedFloat32Array, 6 floats a box: centre then size
    ///   piece_count, triangle_count, stud_count, scatter_count, build_ms
    static Dictionary build_tile(int tx, int tz);
};

// ---------------------------------------------------------------------------

/// The one wave function. Docs/Water.md section 1.
///
/// Spec section 4's strongest line is that ONE wave function drives
/// everything, evaluated identically on the GPU for visuals and here for
/// buoyancy, swimming, boats and knockback. That is a D9 obligation as much as
/// a rendering one, so the shader receives `uniform_array()` and has no
/// constants of its own.
///
/// VERTICAL ONLY, not true Gerstner (section 1.1). Gerstner displaces XZ as
/// well as Y, and that shears the stud grid -- a floating brick and the
/// water's own studs have to stay on the lattice the city is on (D5). It also
/// buys nothing, because quantising to brick steps destroys the crest
/// sharpness the pinch would add.
class BrickWave : public RefCounted {
    GDCLASS(BrickWave, RefCounted);

protected:
    static void _bind_methods();

public:
    static int component_count();

    /// Still water, in metres. A world knob, not a constant: the same
    /// generator with the sea 1.5 m higher is an archipelago instead of a
    /// plain, and nothing else about the water changes.
    static void set_sea_level(double m);
    static double get_sea_level();

    /// Multiply every component's amplitude. Tall waves are wanted, and the
    /// brick step is what makes them affordable -- a 3 m swell is seven steps
    /// rather than a ramp needing more vertices.
    ///
    /// It lives HERE and not in the shader. A gain the shader applied alone
    /// would put the drawn surface 2.2x away from the one the swimmer and the
    /// buoyancy solver read, which is precisely the divergence this class
    /// exists to prevent (section 1).
    static void set_wave_gain(double g);
    static double get_wave_gain();

    /// Waves die as the water shallows: the amplitude is scaled by
    /// clamp(depth / this, 0, 1). Without it a 3 m swell drives bricks
    /// straight through the beach. The shader applies the same ramp off the
    /// seabed texture, so this is what the scene pushes to it.
    static double get_shore_taper_depth();

    /// The shore ramp at a point: 1 in open water, 0 on dry land. The packed
    /// uniforms carry the amplitudes WITHOUT it -- the shader applies its own
    /// from the seabed texture -- so anything reproducing the drawn surface
    /// on the CPU needs this factor, and so does the probe that checks the
    /// two agree.
    static double shore_gain(double x, double z);

    static double get_step_metres();

    static double height_at(double x, double z, double t);
    static double stepped_at(double x, double z, double t);

    /// Batched, and the one gameplay should use: one boundary crossing a body
    /// a tick is cheap, one a sample point is not.
    static PackedFloat32Array sample_heights(const PackedVector2Array &points, double t);

    /// Two vec4 a component: (amplitude, wavenumber, dir.x, dir.z) then
    /// (omega, phase, 0, 0). Handed straight to the shader.
    static PackedVector4Array uniform_array();

    /// Terrace width in studs at the current sea state -- the number
    /// section 3.5 uses to decide whether varied piece shapes are worth
    /// packing on water. A calm sea has wide terraces and would genuinely pave
    /// itself with 1x6s; a rough one breaks down to 1x1s.
    static double terrace_studs();
};

#endif // BRICK_TERRAIN_H
