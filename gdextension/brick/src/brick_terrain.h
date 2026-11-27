#ifndef BRICK_TERRAIN_H
#define BRICK_TERRAIN_H

#include <shared_mutex>
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
#include <memory>
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
/// A deep section's height (Docs/MineWorld.md 16): 32 bricks, 13.4 m.
constexpr int DEEP_SECTION_PLATES = 96;

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
    // --- the biome generator's blocks (Docs/MineWorld.md 2). APPENDED, never
    // inserted: a saved edit stores the material byte.
    MAT_SNOW,
    MAT_GRAVEL,
    MAT_SANDSTONE,
    MAT_RED_SAND,
    MAT_TERRA_ORANGE,
    MAT_TERRA_CREAM,
    MAT_TERRA_RED,
    MAT_CLAY,
    MAT_BEDROCK,
    MAT_COAL,
    MAT_IRON,
    MAT_COPPER,
    MAT_GOLD,
    MAT_REDSTONE,
    MAT_LAPIS,
    MAT_DIAMOND,
    MAT_PODZOL,
    MAT_DRY_GRASS,
    MAT_LUSH_GRASS,
    MAT_COLD_GRASS,
    MAT_DARK_GRASS,
    MAT_GRANITE,
    MAT_DIORITE,
    MAT_ICE,
    /// Lava meeting water (Docs/MineWater.md 4.6).
    MAT_OBSIDIAN,
    /// Building materials that float (Docs/MineWater.md 14.8): a piece mostly
    /// of these floats, mostly of anything else sinks. Filaments no ground
    /// uses, so a block's colour index says what it is.
    MAT_WOOD,
    MAT_LEAVES,
    /// More colours of the two (Docs/Inventory.md 13): the wood and leaves
    /// item families lay any of them. Also filaments no ground uses, and none
    /// near one (skin dark, a dark wood, was dirt's brown to 0.01).
    MAT_PALE_WOOD,
    MAT_BIRCH_WOOD,
    MAT_LIGHT_LEAVES,
    MAT_AUTUMN_LEAVES,
    MAT_RED_LEAVES,
    /// Tilled soil (Docs/MineFarming.md): a hoe turns a soil brick into one.
    /// Smooth (no studs), furrowed by the terrain shader; the wet one is the
    /// same brick with water near it, drawn darker.
    MAT_FARMLAND,
    MAT_WET_FARMLAND,
    /// GLASS (Docs/TerrainBuildings.md 5): a building's windows, and a block
    /// item. Solid to everything that edits, collapses and collides; light
    /// passes it (the sky and block light fills), the overlay lays no brick
    /// of it, and the terrain shader draws it see-through (TERRAIN_GLASS).
    MAT_GLASS,
    /// A WIRE BRICK (Docs/MineWiring.md 20): a placed brick that carries the
    /// wiring's signal through itself (the wiring keeps its nets; the copper
    /// stripe and its glow are the wiring's drawing). Solid and studded like
    /// any brick; only the wiring treats it differently.
    MAT_WIRE_BRICK,
    MATERIAL_COUNT
};

inline bool material_is_glass(int m) { return m == MAT_GLASS; }

/// Wood or leaves, any colour: what lava sets alight and water floats.
inline bool material_is_wood(int m) {
    return m == MAT_WOOD || m == MAT_PALE_WOOD || m == MAT_BIRCH_WOOD;
}
inline bool material_is_leaves(int m) {
    return m == MAT_LEAVES || m == MAT_LIGHT_LEAVES || m == MAT_AUTUMN_LEAVES || m == MAT_RED_LEAVES;
}
inline bool material_burns(int m) { return material_is_wood(m) || material_is_leaves(m); }

/// BUILDING MATERIALS (Docs/TerrainBuildings.md, stage 2): one a filament
/// colour, MAT_FIL_BASE + the filament's index, so a building stamped into
/// the ground keeps the city's colours (a cell holds a material, not a
/// colour). Plastic bricks: studded, strong-bonded, and in the collapse
/// survey as strong as the city's bricks, not the ground's x4.
constexpr int MAT_FIL_BASE = 64;
constexpr int MATERIAL_LIMIT = MAT_FIL_BASE + FILAMENT_PALETTE_SIZE;
static_assert(MATERIAL_LIMIT <= 256, "terrain materials are a byte");
static_assert(MATERIAL_COUNT <= MAT_FIL_BASE, "the ground's materials stay under the building range");

inline bool is_building_material(int m) {
    return m >= MAT_FIL_BASE && m < MATERIAL_LIMIT;
}

/// A material byte as stored: a ground material, or a building one.
inline int clamp_material(int m) {
    if (is_building_material(m)) {
        return m;
    }
    return std::min(std::max(m, 0), (int)MATERIAL_COUNT - 1);
}

/// Filament index per material. Terrain does not get a colour table of its
/// own: a terrain brick and a building brick printed in the same filament have
/// to be the same colour, or the world stops reading as one set of parts.
inline int material_filament(int m) {
    if (is_building_material(m)) {
        return m - MAT_FIL_BASE;
    }
    switch (m) {
        case MAT_GRASS: return FIL_GREEN;
        case MAT_DIRT: return FIL_BROWN;
        case MAT_SAND: return FIL_TAN;
        case MAT_STONE: return FIL_GREY;
        case MAT_DARK_STONE: return FIL_DARK_GREY;
        case MAT_ROAD: return FIL_DARK_GREY;
        // Palette indices past the Filament enum (brick_grid.h FILAMENT_PALETTE).
        case MAT_SNOW: return FIL_WHITE;
        case MAT_GRAVEL: return 15;        // warm grey
        case MAT_SANDSTONE: return 62;     // khaki
        case MAT_RED_SAND: return 24;      // dark orange
        case MAT_TERRA_ORANGE: return 60;  // terracotta
        case MAT_TERRA_CREAM: return 32;   // cream
        case MAT_TERRA_RED: return 26;     // rust
        case MAT_CLAY: return 61;          // clay
        case MAT_BEDROCK: return 14;       // charcoal
        case MAT_COAL: return FIL_BLACK;
        case MAT_IRON: return 25;          // peach
        case MAT_COPPER: return 39;        // teal
        case MAT_GOLD: return 31;          // gold yellow
        case MAT_REDSTONE: return 17;      // bright red
        case MAT_LAPIS: return 43;         // royal blue
        case MAT_DIAMOND: return 46;       // cyan
        case MAT_PODZOL: return 27;        // chocolate
        case MAT_DRY_GRASS: return 37;     // olive
        case MAT_LUSH_GRASS: return 35;    // bright green
        case MAT_COLD_GRASS: return 63;    // moss (sage read as snow in daylight)
        case MAT_DARK_GRASS: return 34;    // dark green
        case MAT_GRANITE: return 23;       // rose
        case MAT_DIORITE: return 13;       // light grey
        case MAT_ICE: return 48;           // ice
        case MAT_OBSIDIAN: return 53;      // plum
        case MAT_WOOD: return 28;          // caramel
        case MAT_LEAVES: return 41;        // forest
        case MAT_PALE_WOOD: return 57;     // skin medium
        case MAT_BIRCH_WOOD: return 29;    // sand
        case MAT_LIGHT_LEAVES: return 36;  // lime
        case MAT_AUTUMN_LEAVES: return FIL_ORANGE;
        case MAT_RED_LEAVES: return FIL_RED;
        case MAT_FARMLAND: return FIL_BROWN;      // dirt's; the shader furrows it
        case MAT_WET_FARMLAND: return FIL_BROWN;  // and darkens the wet one
        case MAT_GLASS: return 44;         // sky blue
        case MAT_WIRE_BRICK: return FIL_DARK_GREY;   // the stripe is the wiring's
        default: return FIL_GREY;
    }
}

inline bool material_is_farmland(int m) { return m == MAT_FARMLAND || m == MAT_WET_FARMLAND; }

/// Road is paved and farmland tilled: no studs. Everything natural takes them.
inline bool material_studded(int m) {
    return m != MAT_ROAD && m != MAT_AIR && !material_is_farmland(m) && m != MAT_GLASS;
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
    /// The same before the pads: noise plus sculpt. What a brush paints on.
    float base_plate(int x, int z) const;

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
/// Cell (x, course, z) BUILT by an edit: a solid edit on one of its plates
/// (filled in, a landed pile), not ground as generated. The pattern library's
/// bricks are the generated ground's; built ground takes the old pattern
/// among its own cells (Docs/HandoffBrickPatterns.md, TerrainRegions.md 13).
bool built_cell(int x, int course, int z);
/// A PLACED brick over cell (x, course, z) -- a block the player laid, which
/// keeps its own shape (Docs/TerrainBond.md 1): false when none. Its
/// rectangle in studs. Safe from any thread, like the edits.
bool placed_at(int x, int course, int z, int &rx, int &rz, int &rsx, int &rsz);
void set_edit(int x, int yp, int z, int material);
/// Deepest edited plate anywhere in the 3x3 tile neighbourhood of (tx, tz),
/// or INT_MAX when nothing there has been touched. The mask has to reach
/// it, or digging past the section floor punches a hole the mesher cannot
/// see.
int deepest_edit_near(int tx, int tz);
/// Highest edited SOLID plate in the 3x3 tile neighbourhood, or INT_MIN. A
/// block placed above the generated ground is above every column's bound,
/// so the mask and the surface scan have to reach up to it.
int highest_edit_near(int tx, int tz);
void clear_edits();
/// The edit tables' reader/writer lock (brick_terrain.cpp): readers on other
/// threads that must not race the main thread's edits take it shared.
std::shared_mutex &edit_lock();
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
    /// The plates this sample DRAWS and collides, when narrower than `vox`
    /// (unset: own_hi <= own_lo, all of it). The deep tier (Docs/MineWorld.md
    /// 16) samples one guard plate past a boundary so faces there are right,
    /// and leaves that plate to whoever owns it.
    int own_lo = 0, own_hi = 0;
    int lo_owned() const { return own_hi > own_lo ? own_lo : y0; }
    int hi_owned() const { return own_hi > own_lo ? own_hi : y0 + ysize; }
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
    /// The column's top plate AS GENERATED, edits ignored. Where an edit
    /// moved a column's top, its neighbours judge their studs against this,
    /// so a hole or a placed block does not re-lay the bricks around it
    /// (Docs/MineWorld.md 10).
    std::vector<int16_t> gtp;
    std::vector<uint8_t> mat;
    /// A painted COLOUR (filament index) for the column, 255 = its
    /// material's own. Pieces are cut where it changes, like material.
    std::vector<uint8_t> col;
    /// SLOPE COLUMNS (19.24), a pure function of the field so neighbouring
    /// tiles agree: the fall side (255 = none), the profile length, this
    /// column's distance from the front, and the fall in plates.
    std::vector<uint8_t> sl_r, sl_len, sl_d, sl_fall;
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
    /// A SLOPE along a terrace edge (Terrain.md 19.22): W studs along the
    /// contour, L (2..4) studs down the fall. L 2 is a 1x2 slope (flat back,
    /// straight face, a plate lip); L 3 and 4 are curved slopes. A one-plate
    /// fall makes the cheese version, with no lip. `ramp` is the fall side.
    PIECE_SLOPE = 3,
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
    uint8_t ramp;   ///< 255 unless kind == PIECE_RAMP/SLOPE; else 0=-X 1=+X 2=-Z 3=+Z
    uint8_t slope_len = 0;   ///< PIECE_SLOPE: studs down the fall (2..4)
    uint8_t fall = 0;        ///< PIECE_SLOPE: plates to the lower neighbour
    uint8_t slope_s0 = 0;    ///< PIECE_SLOPE: profile station at the piece's back edge
    /// A second course laid ON this piece: 0 none, 1 a smooth tile, 2 a
    /// studded plate. When set, the piece's own top face is NOT drawn -- the
    /// overlay covers it exactly, so the quad underneath is culled the same
    /// way a face between two touching blocks is.
    uint8_t overlay;
    /// Something stands on this brick (the bond's footprint it is cut from
    /// reaches under a higher column): it keeps its studs, never a tile and
    /// never a smooth overlay -- a real brick holds the one on it by them.
    uint8_t held = 0;
    /// The BRICK this piece is part of, tile-local (may reach past the tile):
    /// with the bond's top course (BrickTerrain.set_bond_top, Docs/
    /// TerrainBond.md) a brick can cross a tile edge and each tile draws its
    /// part; the outline, the tint and breaking go by the whole brick.
    /// bsx 0: the piece is the whole brick.
    int16_t bx = 0, bz = 0, bsx = 0, bsz = 0;
    int brick_x() const { return bsx > 0 ? bx : ox; }
    int brick_z() const { return bsx > 0 ? bz : oz; }
    int brick_sx() const { return bsx > 0 ? bsx : sx; }
    int brick_sz() const { return bsx > 0 ? bsz : sz; }
};

/// The top course laid on the ground's bond rather than packed (Docs/
/// TerrainBond.md). The mine world turns it on.
extern bool g_bond_top;

/// An overlay course is one PLATE proud of the brick it sits on: a real tile
/// laid on a real brick, not a decal.
constexpr float OVERLAY_M = PLATE_M;

/// How many brick pieces get one, and how many of those are smooth.
constexpr float OVERLAY_CHANCE = 0.26f;
constexpr float OVERLAY_TILE_SHARE = 0.62f;

/// Of the bricks topmost in a cave (their top faces drawn by the face mesher,
/// not packed), how many carry studs: more than the surface's 1 - TILE_CHANCE
/// (Docs/MineWorld.md 20). The rest are smooth, by the brick's corner.
constexpr float CAVE_STUD_CHANCE = 0.9f;

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

/// One column of a tile as the collapse survey needs it (Docs/TerrainBond.md):
/// its topmost solid plate and the packed piece over it, as the tile draws it
/// and a shot breaks it.
struct TopColumn {
    int top = -2000000000;      ///< topmost solid plate (TileSample::tp)
    bool piece = false;         ///< a packed piece owns its top course
    int px = 0, pz = 0;         ///< the piece's corner, absolute studs
    int psx = 0, psz = 0;       ///< and its size
};

/// Tile (tx, tz)'s columns, TILE x TILE, x fastest, from the packed-tile
/// store (packed_tops); a tile not kept is sampled and packed (~8 ms): a
/// worker's job. `packed`, when given, says which.
void top_columns(int tx, int tz, std::vector<TopColumn> &out, bool *packed = nullptr);

/// What tile (tx, tz) is made of has a version: it changes when a cell in it
/// or within a tile of it is edited or a brick placed, and for every tile when
/// the world is set up again (seed, generator, its params, the bond, edits
/// cleared). Equal versions, equal tile: what a cache of a tile's derived data
/// (the collapse's top course) checks. Lock-free; a hash slot may be shared by
/// two tiles, which only makes a cache miss more often.
uint64_t tile_version(int tx, int tz);
/// Every tile's version changes (the world set up again).
void bump_field_version();

/// The GENERATED cells (no edits) of tile (tx, tz)'s own TILE x TILE columns,
/// plates [y_lo, y_hi): vox[lx + TILE * (lz + TILE * (yp - y_lo))], material,
/// 255 under the bedrock; gtop[lx + TILE * lz] the column's generated top
/// plate. From the kept generated tiles and deep sections, made when not
/// kept. Any thread. False without the biome generator (test fields): the
/// region fit (terrain_fit.h) is then off. `field` gets the field's serial.
bool generated_cells(int tx, int tz, int y_lo, int y_hi, std::vector<uint8_t> &vox,
        std::vector<int16_t> &gtop, uint32_t *field = nullptr,
        int lx0 = 0, int lx1 = TILE, int lz0 = 0, int lz1 = TILE);
/// This thread's generated_cells make every cell (never the kept tiles):
/// region_fit_probe's check that both give the same cells.
void set_generated_made_only(bool on);
/// The field's serial: changes with the world (seed, generator, params).
uint32_t field_serial();

/// A tile's top course packed into pieces (pack_tile's output): `owner` is
/// TILE x TILE, x fastest, the piece owning each column's top course or -1.
struct TilePack {
    std::vector<Piece> pieces;
    std::vector<int32_t> owner;
    /// Each column's top solid plate (the sample's `tp`), TILE x TILE.
    std::vector<int16_t> top;
};

/// Tile (tx, tz) sampled into `s` and its top course packed -- the bricks the
/// player sees. Kept by tile version (Docs/TerrainCollapse.md 8.4): the
/// drawing packs a tile once and the pickaxe, the brick lookups and the
/// collapse's survey read the same pieces instead of packing again. Thread
/// safe; packs on a miss. Shared and immutable: never change what it returns.
std::shared_ptr<const TilePack> packed_tile(int tx, int tz, TileSample &s);
/// What is KEPT of a tile's top course (Docs/TerrainRegions.md 12.5: the
/// packs themselves are no longer kept, ~14 KB a tile): each column's top
/// plate and the brick its top course is part of, ~6 KB a tile.
struct TileTops {
    std::vector<int16_t> top;    ///< TILE x TILE, x fastest: topmost solid plate
    /// The column's top brick, from the tile's corner (a brick may cross the
    /// edge): x, z, sx, sz; sx 0 where no piece owns the column's top.
    std::vector<int8_t> rect;    ///< TILE x TILE x 4
    bool piece(int lx, int lz) const { return rect[(size_t)(lx + TILE * lz) * 4 + 2] != 0; }
};

/// The same without the sample, for a reader that needs only the column tops
/// and top bricks (the collapse's survey, rain, the pickaxe): a kept tile
/// costs a lookup; one not kept is sampled and packed (~8 ms).
std::shared_ptr<const TileTops> packed_tops(int tx, int tz, bool *packed = nullptr);

/// SKY LIGHT for a mesh drawn over the cells but not baked by the terrain
/// (the water, BrickFluid mesh_tile; Docs/MineWorld.md 19): each vertex's
/// sky level (0..15) as 0..1 into `col[i].b`, sampled as the ground's bake
/// does (half a cell out along its normal, the eight cells round that point,
/// opaque ones left out). Vertices in absolute metres. Nothing when sky light
/// is off. Any thread: it reads the field only, no lock.
void sky_levels_into(const PackedVector3Array &v, const PackedVector3Array &n, PackedColorArray &col);

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
    static int get_piece_stride();

    static int height_at(int x, int z);
    static int solid_at(int x, int yp, int z);
    static int surface_plate(int x, int z);
    /// The top plate of the field AS GENERATED: noise and pads, no sculpt.
    /// The sea is measured on this, so a hole dug in the beach is not ocean
    /// and has to fill by flowing (Water.md 12).
    static int generated_plate(int x, int z);
    /// The floor water rests on, per column of a tile, in metres: the top,
    /// or the middle of a slope's face (column_surface), so a slope holds
    /// water. TILE x TILE, row-major (z then x).
    static PackedFloat32Array water_floor_tile(int tx, int tz);
    /// Where a ray first meets the heightfield's column tops, within
    /// `max_metres`: {"position": Vector3} on the top of the column hit, or
    /// {} for a miss. Half-metre march, then bisection. (The editor's brush
    /// aimed with this in GDScript every frame: up to 800 field reads.)
    static Dictionary ray_ground(const Vector3 &from, const Vector3 &dir, double max_metres);

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
    /// Set every plate cell in [lo, hi] (stud, plate, stud; inclusive) to
    /// `material` -- 0 breaks, anything else places. `only_air` leaves solid
    /// cells as they are (placing). Bedrock never breaks. Returns
    /// {"tiles": [tx, tz, ...] to rebuild, "changed": cells}. Docs/MineWorld.md 8.
    static Dictionary fill_box(Vector3i lo, Vector3i hi, int material, bool only_air);
    /// A shot breaking WHOLE BRICKS (Docs/MineWorld.md 10): the surface
    /// piece hit, all of it, when the hit is in a column's top course; the
    /// one brick cell hit (a stud by a brick) on a wall or a cave face.
    /// Bedrock never. Returns {"tiles", "removed" (cells), "debris" (9 floats
    /// a brick: centre, size, colour)}; empty "tiles" when nothing broke.
    static Dictionary break_brick(Vector3 point, Vector3 normal);
    /// `break_brick`'s READ half, safe on a worker (it samples and packs a
    /// tile, ~10 ms): {"runs": [x, z, lo, hi] per column to clear, "debris"};
    /// empty runs when nothing would break. `clear_runs` is the write half,
    /// for the main thread: {"tiles", "removed"}.
    static Dictionary find_brick(Vector3 point, Vector3 normal);
    static Dictionary clear_runs(const PackedInt32Array &runs);
    /// Every WHOLE brick plate box [lo, hi] touches, as find_brick takes one:
    /// a surface piece in a column's top course all of it, a brick cell (a stud
    /// by a brick) under it. {runs} for clear_runs. A pickaxe's area: nothing
    /// is cut in parts, so the packer lays the ground round it as before.
    /// Samples and packs each tile it touches (~10 ms a tile): a worker's job.
    static Dictionary find_bricks(Vector3i lo, Vector3i hi);
    /// The first solid plate cell along a ray, walking the grid exactly
    /// (stud x plate x stud): {"cell": Vector3i, "normal": Vector3i (the face
    /// entered through), "material", "position"}; empty when nothing is hit.
    static Dictionary ray_cell(Vector3 from, Vector3 dir, double max_metres);
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

    /// With smooth terrain on, WHICH ground curves (Docs/Terrain.md 18.6).
    /// Off: the biome rule -- the odd curved hillside, steep ground bricked.
    /// On: the slope rule -- ground that slopes more than `curve_slope`
    /// (plates a stud, regional) curves, flat ground is laid brick, pads and
    /// cliffs are brick, and what `paint_form` painted beats all of it.
    /// Low-poly curves (Terrain.md 18.7): studs a side of one curve quad
    /// where a whole block and the ring round it are curve. 1 is a quad a
    /// stud, as before; it must divide the tile.
    /// Bricks poking out of curved ground (Terrain.md 18.7): the share of
    /// curve cells a brick starts on. 0 for none.
    /// Shelves on slopes ground (Terrain.md 18.8): every `bricks` of height
    /// the first `share` of the rise is flat. 0 bricks for none. Changes the
    /// FIELD: call before anything is built from it.
    static void set_shelves(double bricks, double share);
    static Vector2 get_shelves();
    static void set_curve_bricks(double share);
    static double get_curve_bricks();
    static void set_curve_step(int studs);
    static int get_curve_step();
    static void set_smooth_slopes(bool on);
    static bool get_smooth_slopes();
    static void set_curve_slope(double plates_per_stud);
    static double get_curve_slope();
    /// Paint brick (0) or curve (1) over a disc, or -1 to hand it back to
    /// the rule. Same tiles and undo strokes as the sculpt. Returns the stud
    /// rectangle touched.
    static Rect2i paint_form(int x, int z, double radius, int form);
    /// What a column was painted: 0 brick, 1 curve, 255 not painted.
    static int form_at(int x, int z);
    /// For the world file: TILE*TILE bytes.
    static PackedByteArray get_form_tile(int tx, int tz);
    static void set_form_tile(int tx, int tz, const PackedByteArray &bytes);

    /// BAKED SUN SHADOW. Direction TO the sun, world space.
    ///
    /// The ground is a static heightfield, so which of it the sun reaches is
    /// a property of the world and not of the frame. Marching the field once
    /// at build time and darkening the colour costs nothing to draw, works
    /// at any distance, and lets the terrain stop casting into the shadow
    /// map altogether — which at a 145 m detail radius was 290k triangles
    /// and 6.5 ms a frame (Docs/Terrain.md 19.7).
    ///
    /// Set it to zero to bake no shadow at all.
    static void set_sun_direction(Vector3 to_sun);
    static Vector3 get_sun_direction();

    /// AUTHORED BUILDING PADS.
    ///
    /// The terrain is a fixed authored size with authored buildings on it,
    /// and a building needs ground that is flat and where the author put it.
    /// A pad flattens the field to one height inside `radius` studs and
    /// eases back to the natural surface over `skirt` more.
    ///
    /// It goes in the FIELD, not in the mesher, so every consumer agrees
    /// about it without being told: the detailed tier, the coarse tier, the
    /// collider, the stud test, the seabed texture and the buoyancy solver
    /// all read the same surface.
    ///
    /// Call before anything is built. Pads are not damage; they are part of
    /// what the world IS.
    ///
    /// `radius_z` makes it a RECTANGLE: `radius` studs each way in X and
    /// `radius_z` in Z (-1: the same as `radius`). A building is rarely
    /// square, and a square pad under a 40 x 30 footprint flattens ten
    /// studs of hillside nobody asked for.
    static void add_pad(int x, int z, int radius, int skirt, double height_m,
            int radius_z = -1);
    static void clear_pads();
    static int pad_count();
    /// The pad a column belongs to, or -1.
    static int pad_at(int x, int z);

    /// Editing. Terrain editing is a LEVEL EDITING job, not a gameplay one,
    /// so these exist for the editor and the world file — not for anything
    /// the player can reach. Docs/Terrain.md 20.
    ///
    /// A pad as a Dictionary: x, z, radius, skirt, height (metres).
    static Dictionary get_pad(int index);
    static void set_pad(int index, int x, int z, int radius, int skirt, double height_m,
            int radius_z = -1);
    static void remove_pad(int index);
    /// The stud rectangle a pad affects, as (min_x, min_z, max_x, max_z).
    /// What a rebuild has to cover after an edit.
    static Rect2i pad_bounds(int index);

    /// PAINTED MATERIAL. An author saying "this bit is sand" about ground
    /// the generator called grass.
    ///
    /// Like a pad, it lives in the FIELD, so the mesh, the scatter, the
    /// studs and the coarse tier all agree without being told. Unlike a
    /// pad, its edge is DITHERED rather than blended: material is a
    /// category, and half sand is not a material — so the skirt decides per
    /// column, by a hash, and the boundary breaks up instead of drawing a
    /// circle on the ground.
    /// SCULPTING. Brush strokes that raise, lower, flatten and smooth the
    /// ground, the way a smooth-terrain editor does -- held and dragged over
    /// the ground rather than placed. Docs/Terrain.md 20.6.
    ///
    /// A stroke goes into the FIELD, like a pad: a height offset per stud
    /// column, added to the noise and under the pads (so a building's pad
    /// still wins where it stands). Stored per tile, copy-on-write, because
    /// tiles bake on worker threads while the editor paints.
    ///
    /// `mode`: 0 RAISE (`amount` metres at the middle, negative lowers),
    /// 1 FLATTEN (towards `target_m`, `amount` 0..1 of the way), 2 SMOOTH
    /// (towards the neighbours' average, `amount` 0..1). `radius` in studs,
    /// round, with a smoothstep falloff. Returns the stud rectangle touched.
    static Rect2i sculpt(int x, int z, double radius, int mode, double amount, double target_m);
    /// Undo groups: every sculpt between two begin_stroke calls is one undo.
    static void sculpt_begin_stroke();
    /// Put the last stroke back. Returns what it touched (empty: nothing).
    static Rect2i sculpt_undo();
    static int sculpt_undo_depth();
    static void clear_sculpt();
    /// The offset at a column, in metres.
    static double sculpt_at(int x, int z);
    /// For the world file: which tiles hold a sculpt, and each one's
    /// TILE x TILE offsets in metres, row-major (z then x).
    static Array sculpt_tiles();
    static PackedFloat32Array get_sculpt_tile(int tx, int tz);
    static void set_sculpt_tile(int tx, int tz, const PackedFloat32Array &metres);

    /// SURFACE PAINT: a brush that says what the ground under it is MADE of
    /// and what COLOUR it is, a stud column at a time (Docs/Terrain.md
    /// 20.7). Kept in the same copy-on-write tiles and undo strokes as the
    /// sculpt. `material` is a terrain material, `colour` a filament index;
    /// -1 leaves that half alone, -2 puts it back to what the ground was.
    /// Round, hard-edged, `radius` studs. Returns the stud rectangle touched.
    static Rect2i paint_surface(int x, int z, double radius, int material, int colour);
    /// What a column was painted: (material, colour), 255 for "not painted".
    static Vector2i surface_paint_at(int x, int z);
    /// The filament a column is drawn in: its painted colour, else its
    /// material's.
    static int colour_at(int x, int z);
    /// For the world file: TILE*TILE materials then TILE*TILE colours.
    static PackedByteArray get_surface_paint_tile(int tx, int tz);
    static void set_surface_paint_tile(int tx, int tz, const PackedByteArray &bytes);

    static void add_paint(int x, int z, int radius, int skirt, int material);
    static void clear_paints();
    static int paint_count();
    static Dictionary get_paint(int index);
    static void set_paint(int index, int x, int z, int radius, int skirt, int material);
    static void remove_paint(int index);
    static Rect2i paint_bounds(int index);
    /// The paint covering a column, or -1.
    static int paint_at(int x, int z);

    /// The generator's material names, in its own order.
    ///
    /// The editor had this list written out by hand, which is one rename
    /// away from painting stone and labelling it sand. The names live where
    /// the enum lives.
    static PackedStringArray material_names();

    /// Is this column in the sun? The same march the mesher bakes with.
    static bool sunlit(int x, int z);

    /// The surface BEFORE quantisation, in metres: what curved ground is
    /// drawn from, and the only way anything outside the mesher can predict
    /// where a curve actually is.
    static double surface_raw(int x, int z);

    /// Is this column drawn as a curve? Biome AND steepness — see
    /// Docs/Terrain.md 18.5.
    static bool smooth_at(int x, int z);

    static void set_flat_mode(bool on);
    /// Bake the faces behind the overlay's bricks (Docs/BrickOverlay.md 6b).
    static void set_behind_faces(bool on);
    static bool get_behind_faces();
    /// Behind faces only round the eye: its tile (x, z) and plate (y).
    static void set_behind_centre(Vector3i tile_plate);
    /// Would a bake now give this tile (sy = INT_MIN) or section behind faces?
    static bool behind_wanted(int tx, int sy, int tz);
    static bool get_flat_mode();
    static void set_overlay_chance(double chance);
    static double get_overlay_chance();

    static void clear_terrain_edits();
    static int get_edit_count();
    /// Every edit, 13 bytes each: int32 x, int32 yp, int32 z (stud, plate,
    /// stud; little-endian), uint8 material (0 = carved). For saving a world's
    /// changes (Docs/MineWorld.md 9); `set_edits` lays them back.
    static PackedByteArray get_edits();
    /// EDITS BY REGION (Docs/MineWorld.md 9), for a save that writes only what
    /// changed. The main thread only. A region is get_region_studs() square.
    static int get_region_studs();
    /// The packed-tile store (brick::packed_tile): hits, packs (misses),
    /// tiles kept. `reset` zeroes the counts.
    static Dictionary get_tile_pack_stats(bool reset = false);
    /// MEMORY (terrain_mem_probe, Docs/TerrainRegions.md 2): the packed-tile
    /// store's and the edit table's bytes. Probes only: it locks the store.
    static Dictionary memory_stats();
    /// One tile sampled as a bake samples it: ms, the sample's bytes, and the
    /// material runs up its columns (what a kept run store would hold).
    static Dictionary sample_stats(int tx, int tz);
    /// The same for one deep section (empty when it has nothing to sample).
    static Dictionary section_sample_stats(int tx, int sy, int tz);
    /// The regions (rx, rz pairs) edited since the last call, and forgets
    /// that they were. Call once after loading to start clean.
    static PackedInt32Array take_dirty_regions();
    /// One region's edits, get_edits' 13-byte records (set_edits loads them).
    static PackedByteArray get_region_edits(int rx, int rz);
    /// Lay edits from `get_edits`' bytes over the current ones. Returns how many.
    static int set_edits(const PackedByteArray &bytes);
    /// A placed block (Docs/TerrainBond.md 1): the plate box `lo`..`hi` just
    /// filled with `material` is ONE brick, kept whole by the bond, breaking
    /// and the collapse. Cells of the box not of that material are left out.
    static int mark_placed(Vector3i lo, Vector3i hi, int material);
    /// The placed bricks, 4 ints a cell (x, course, z, code), for a save; and
    /// back (after set_edits).
    static PackedInt32Array get_placed();
    /// The placed brick holding cell (x, course, z): Vector4i(rx, rz, sx, sz),
    /// its rectangle's low corner and size in studs; all zeros if none.
    static Vector4i placed_rect(int x, int course, int z);
    static int set_placed(const PackedInt32Array &cells);
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
    /// THE DEEP TIER (Docs/MineWorld.md 16). On: a surface tile's mask stops
    /// at a fixed plate (deep_top) and everything under it is drawn by
    /// sections, `build_section`, on an absolute grid of DEEP_SECTION_PLATES.
    static void set_deep_tier(bool on);
    static bool get_deep_tier();
    static int deep_top(int tx, int tz);
    static int get_deep_section_plates();
    static int get_bedrock_plate();
    static Dictionary build_section(int tx, int sy, int tz);
    /// THE BRICK OVERLAY's pick (Docs/BrickOverlay.md 3): from bakes'
    /// `overlay_bricks` lists (Array of PackedFloat32Array, 17 floats a
    /// brick), the bricks within `range_m` of `eye` (to their box) and inside
    /// the cone round `forward` (cos of its half angle; a brick's bounding
    /// sphere counts), deduped by corner and course (each face's light from the list that drew
    /// more of it), nearest first, up to
    /// `max_bricks`. Returns {buffer: MultiMesh TRANSFORM_3D + colours +
    /// custom data (20 floats an instance), count, far_m: the farthest picked
    /// brick's distance (range_m when none was left out), seen: bricks read}.
    /// The instance: transform = the box (scale its size, origin its middle),
    /// colour = (rgb as 24 bits, block word, 0, material * 2 + studs), custom = the faces' sky
    /// words (overlay_bricks' floats 11-14). Main thread, no renderer.
    /// `hidden`: boxes (lo, hi pairs, terrain frame) whose bricks are left out
    /// (bricks shot and hidden till their tile is rebuilt, TerrainBricks).
    static Dictionary overlay_pick(const Array &lists, Vector3 eye, Vector3 forward, double range_m,
            double cos_half, int max_bricks, const PackedVector3Array &hidden);
    /// The listed brick (overlay_bricks' 17 floats) whose box holds `point`,
    /// from any of `lists` -- at any range, not only what overlay_pick laid
    /// (a far shot). {brick: its floats, lo, hi: its box with any brick
    /// stacked on or under it on the same footprint (a piece's plate or
    /// tile), each face's light from the list that drew more of it}; empty
    /// when none holds it.
    static Dictionary overlay_find(const Array &lists, Vector3 point);
    /// FOR PROBES (Docs/MineWorld.md 20): the flat mesh and colliders of a
    /// tile (sy = INT32_MIN) or deep section, checked against the field.
    ///   exposed, undrawn   faces of owned solid cells against OPEN air, and
    ///                      those no triangle of the mesh covers (by
    ///                      direction in undrawn_dir, first few in examples)
    ///   box_air_top, box_air_cave   open-air cells inside a column-top box
    ///                      or a cave box: a collider where nothing is drawn
    ///   air_examples       first few of those cells
    static Dictionary audit_tile(int tx, int tz, int sy);
    /// SKY LIGHT IN THE CELLS (Docs/MineWorld.md 18). On: build_tile and
    /// build_section write each vertex's sky light, 0..255 for levels 0..15,
    /// into CUSTOM0.a (always 255 when off). Only the mine world turns it on.
    static void set_sky_light(bool on);
    static bool get_sky_light();
    /// The sky light level (0..15) of the cell holding `point` (terrain-local
    /// metres): what the eye's exposure follows.
    static double sky_light_at(Vector3 point);
    /// The BLOCK light level (0..15) from lava of the cell holding `point`
    /// (terrain-local metres), as the tile bakes fill it (Docs/MineWorld.md
    /// 19): lava things in a cave glow by. 0 at once with no lava within
    /// light's reach.
    static double block_light_at(Vector3 point);

    /// A COARSE block of ground, for distance. Docs/Terrain.md 19.4.
    ///
    /// Covers `span` x `span` tiles starting at tile (tx0, tz0) as ONE mesh,
    /// sampling the surface every `step` studs: no packing, no pieces, no
    /// studs, no scatter, no collider. A 4x4-tile block at step 4 is about
    /// 2k triangles and one draw call where the full build of the same
    /// ground is ~18k and sixteen.
    ///
    /// It is deliberately NOT the same mesher. Detail that is under a pixel
    /// is not detail, and everything the near tier exists for -- the seam
    /// around a 2x4, the nozzle path, the stud -- is under a pixel out here.
    ///
    /// Returns: mesh (ARRAY_MAX arrays), triangle_count, build_ms.
    static Dictionary build_coarse(int tx0, int tz0, int span, int step);
    /// Slope and curved-slope pieces along terrace edges (19.22). OFF by
    /// default (the plain-brick look was preferred); on draws them.
    static void set_slope_pieces(bool on);
    static bool get_slope_pieces();
    /// The top course laid on the ground's bond (Docs/TerrainBond.md); the
    /// mine world turns it on, every other scene keeps the packer's ladder.
    static void set_bond_top(bool on);
    static bool get_bond_top();
    /// Coarse blocks sampled this coarsely or more are built SMOOTH: one
    /// vertex a sample, no flat tops and walls (Terrain.md §19.14). At that
    /// distance a brick course is under a pixel, so the steps are paid for
    /// and never seen. 0 turns it off.
    static void set_coarse_smooth_step(int step);
    static int get_coarse_smooth_step();

    /// The generator (Docs/MineWorld.md): 0 classic, 1 biomes. Change it, or
    /// the params, only while nothing is baking -- workers read them.
    static void set_generator(int mode);
    static int get_generator();
    static void set_gen_params(Dictionary params);
    static Dictionary get_gen_params();
    static void reset_gen_params();
    static int biome_at(int x, int z);
    static PackedStringArray biome_names();
    static PackedByteArray gen_preview(int64_t seed, Dictionary params, int cx, int cz, int w, int h,
            int step, int mode);
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

    /// WAVE GROUPS (Docs/Water.md §8, after MvsC): two long envelopes that
    /// travel with the swell and scale it +/-30%, so one stretch of sea is
    /// heaped and the next is calm. Two vec4 a group: (fraction, wavenumber,
    /// dir.x, dir.z) then (omega, phase, 0, 0).
    static PackedVector4Array group_uniform_array();
    /// THE SHORE BAND: a wave phased on DISTANCE TO THE SHORE, so its crests
    /// run parallel to every coast and roll in toward it whatever the swell
    /// is doing. (amplitude, radians per metre, omega, band reach in metres).
    static Vector4 shore_band_uniform();
    /// How the swell is steered (Water.md 9.8): within `x` metres of a shore
    /// it travels TOWARD the nearest shore (phased on distance), past `y` it
    /// is the open-ocean directional swell, blended between. `z` is the drift
    /// that keeps crests off perfect contour lines. (near, far, drift, 0).
    static Vector4 swell_blend_uniform();
    /// TUNING (the dev menu, Terrain.md 20.10). Where the swell turns from
    /// shore-steered to directional, in metres from the shore.
    static void set_swell_steer(double near_m, double far_m);
    /// Wave strength at the waterline (0..1) and how far out it reaches full.
    static void set_shore_calm(double strength, double fade_m);
    /// (strength, fade) for the shader.
    static Vector2 shore_calm_uniform();
    /// RIVERS CALM (the mine world; Docs/MineWaterNext.md 11): narrow water
    /// -- no open water within RIVER_OPEN_R metres -- loses the swell (its
    /// crests ran ACROSS a river, phased on the distance to the banks) and
    /// carries a small ripple along its banks toward the wider water. Off:
    /// every other scene's sea as it was. The shader's `river_calm`.
    static void set_river_calm(bool on);
    static bool get_river_calm();
    /// Build the field the band reads: the ground and the distance to the
    /// nearest dry ground, one sample every `step` studs over +/-`half_studs`,
    /// on the SAME lattice as the water's seabed texture. Returns the samples
    /// interleaved (ground, distance) row by row -- the texture's own layout,
    /// so the water uploads it as it is.
    static PackedFloat32Array build_shore_field(int half_studs, int step);
    /// The same field round (cx, cz) studs, computed without touching the live
    /// one: safe on a worker. install_shore_field makes it the live field.
    static PackedFloat32Array compute_shore_field(int cx, int cz, int half_studs, int step);
    static void install_shore_field(int cx, int cz, int half_studs, int step, const PackedFloat32Array &field);
    /// After build_shore_field: the cells, `cell_studs` a side, holding any
    /// field sample under the sea, as Vector2i (water_sea.gd's WET map).
    static Array wet_cells(int cell_studs);
    /// Metres from a point to the nearest dry ground, bilinear over that
    /// field; very large where no field has been built.
    static double shore_distance(double x, double z);
    /// The still-water depth, bilinear over the seabed lattice.
    static double band_depth(double x, double z);
    /// The two halves of the surface, for the probe that checks the shader's
    /// copy of the formula: the group factor at a point and the band.
    static double group_at(double x, double z, double t);
    static double band_at(double x, double z, double t);

    /// Terrace width in studs at the current sea state -- the number
    /// section 3.5 uses to decide whether varied piece shapes are worth
    /// packing on water. A calm sea has wide terraces and would genuinely pave
    /// itself with 1x6s; a rough one breaks down to 1x1s.
    static double terrace_studs();
};

#endif // BRICK_TERRAIN_H
