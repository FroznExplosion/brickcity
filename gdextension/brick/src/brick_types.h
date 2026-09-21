#ifndef BRICK_TYPES_H
#define BRICK_TYPES_H

#include <godot_cpp/variant/color.hpp>
#include <godot_cpp/variant/packed_color_array.hpp>
#include <godot_cpp/variant/packed_int32_array.hpp>
#include <godot_cpp/variant/packed_vector2_array.hpp>
#include <godot_cpp/variant/packed_vector3_array.hpp>
#include <godot_cpp/variant/string.hpp>
#include <godot_cpp/variant/transform3d.hpp>
#include <godot_cpp/variant/vector3i.hpp>

#include <cmath>
#include <cstdint>
#include <vector>

using namespace godot;

namespace brick {

// ---------------------------------------------------------------------------
// Archetype -- a part type. The flyweight. Plan.md section 2.
//
// One archetype serves every block of that type in the world: one shared
// collision shape, one baked vertex buffer with per-face index ranges, one set
// of stud positions and connector metadata. Tens of these exist, not millions.
//
// M0 carries only what meshing and placement need. The shared BoxShape3D RID,
// the baked index partition, stud positions, print_axis and connector keys
// arrive with M1, M5 and the export pipeline respectively.
// ---------------------------------------------------------------------------

/// What a part offers on a horizontal face, per column.
///
/// Two bits rather than the two independent one-bit masks this started with,
/// because a FLIPPED part has studs on its bottom and sockets on its top and
/// "has_stud / has_socket" cannot say that. The two-bit form also makes a tile
/// (NONE on top) and a double-sided plate (STUD on both) expressible in the
/// same vocabulary. Docs/BuildMode.md section 3.1.
enum Face : uint8_t {
    FACE_NONE = 0,   ///< smooth. nothing clips here.
    FACE_STUD = 1,   ///< offers a stud.
    FACE_SOCKET = 2, ///< accepts a stud.
};

struct Archetype {
    String name;
    Vector3i size = Vector3i(1, 1, 1); // BOUNDING BOX in studs, plates, studs
    float mass = 1.0f;                 // grams at print scale, arbitrary units for now

    // --- shape ------------------------------------------------------------
    //
    // A part is not required to fill its bounding box. `cells` is an occupancy
    // mask over the box; an EMPTY vector means "a full box", which is the
    // common case and costs nothing. Slopes, arches, L-pieces, brackets and
    // anything else that spec section 2 calls a curve or an organic form are
    // expressed by masking cells out.
    //
    // `studs` and `sockets` are per-column over the XZ footprint: which columns
    // carry studs on top, and which accept a stud underneath. Empty means "all
    // of them". A tile has no studs, so nothing clips to its top; that is a
    // real structural property, not decoration, and the connectivity graph has
    // to see it.
    //
    // What is NOT here yet, with a seam left for it: a baked custom mesh and
    // custom convex colliders. Today a masked part meshes and collides as its
    // occupied cells, which is a voxel approximation -- right for the graph and
    // the physics, visibly stepped for a true curve. See Docs/Status.md.
    // --- side studs -------------------------------------------------------
    //
    // A stud on a LATERAL face -- a bracket, a headlight brick. Stored as a
    // LIST rather than as four more masks, because a bracket has two or three
    // of them and what placement wants is "where can I attach", not "is there
    // one at (u,v)".
    //
    // They are what makes sideways building reachable: a rotated frame steps
    // its build plane by one PLATE (2 ticks) while upright brick faces sit at
    // stud boundaries (multiples of 5), so a frame at a fixed origin can only
    // meet every second stud. A side stud names the exact plane to put a frame
    // on, and the parity problem disappears.
    struct SideStud {
        int8_t x, y, z;    // cell within the part
        int8_t dx, dy, dz; // outward face normal, one axis, +-1
    };
    std::vector<SideStud> side_studs;

    std::vector<uint8_t> cells;     // size.x * size.y * size.z, 1 = solid
    std::vector<uint8_t> up_face;   // size.x * size.z, Face. empty = all STUD
    std::vector<uint8_t> down_face; // size.x * size.z, Face. empty = all SOCKET

    int box_cell_count() const { return size.x * size.y * size.z; }

    bool is_full_box() const { return cells.empty(); }

    bool solid_at(int x, int y, int z) const {
        if (cells.empty()) {
            return true;
        }
        return cells[(size_t)x + (size_t)size.x * ((size_t)y + (size_t)size.y * (size_t)z)] != 0;
    }

    /// An empty mask is the ordinary brick: studs up, sockets down.
    uint8_t up_at(int x, int z) const {
        if (up_face.empty()) {
            return FACE_STUD;
        }
        return up_face[(size_t)x + (size_t)size.x * (size_t)z];
    }

    uint8_t down_at(int x, int z) const {
        if (down_face.empty()) {
            return FACE_SOCKET;
        }
        return down_face[(size_t)x + (size_t)size.x * (size_t)z];
    }

    bool has_stud(int x, int z) const { return up_at(x, z) == FACE_STUD; }
    bool has_socket(int x, int z) const { return down_at(x, z) == FACE_SOCKET; }

    /// Do these two faces mate? A stud meets a socket, either way round -- which
    /// is what lets a flipped part join a normal one.
    static bool faces_mate(uint8_t upper_down, uint8_t lower_up) {
        return (lower_up == FACE_STUD && upper_down == FACE_SOCKET)
            || (lower_up == FACE_SOCKET && upper_down == FACE_STUD);
    }

    /// Same part, geometrically? Used to dedupe orientation variants: a 2x2
    /// brick yawed 90 degrees is the brick it already was, and baking it twice
    /// would put two ids on one shape.
    bool same_shape_as(const Archetype &o) const {
        // Side studs are part of the shape. Without this a bracket dedupes onto
        // the plain brick of the same size -- it looks identical to every other
        // test -- and the studs that make sideways building possible silently
        // vanish.
        if (side_studs.size() != o.side_studs.size()) {
            return false;
        }
        for (size_t i = 0; i < side_studs.size(); ++i) {
            const SideStud &p = side_studs[i];
            const SideStud &q = o.side_studs[i];
            if (p.x != q.x || p.y != q.y || p.z != q.z
                    || p.dx != q.dx || p.dy != q.dy || p.dz != q.dz) {
                return false;
            }
        }
        return size == o.size && cells == o.cells
            && up_face == o.up_face && down_face == o.down_face
            && std::abs(mass - o.mass) < 0.0001f;
    }

    // --- surface cells ----------------------------------------------------
    //
    // A stud joint can only happen where a part's surface faces up or down, so
    // connectivity has no business looking at the cells in between. These are
    // precomputed once per archetype: every cell whose neighbour ABOVE it
    // inside the part is empty, and every cell whose neighbour BELOW it is.
    //
    // For a full box that is one cell per column at each end -- exactly the
    // footprint scan connectivity used before masks existed. Walking all cells
    // instead cost 3x the lookups and, called four times per cascade step,
    // measured over 200 ms at 16.5k blocks.
    struct SurfaceCell {
        int16_t x, y, z;
    };
    std::vector<SurfaceCell> top_cells;
    std::vector<SurfaceCell> bottom_cells;

    void build_surface_cells() {
        top_cells.clear();
        bottom_cells.clear();
        for (int x = 0; x < size.x; ++x) {
            for (int z = 0; z < size.z; ++z) {
                for (int y = 0; y < size.y; ++y) {
                    if (!solid_at(x, y, z)) {
                        continue;
                    }
                    if (y + 1 >= size.y || !solid_at(x, y + 1, z)) {
                        top_cells.push_back({(int16_t)x, (int16_t)y, (int16_t)z});
                    }
                    if (y - 1 < 0 || !solid_at(x, y - 1, z)) {
                        bottom_cells.push_back({(int16_t)x, (int16_t)y, (int16_t)z});
                    }
                }
            }
        }
    }

    /// Solid cells, for mass and collision. Cheap for the full-box case.
    int solid_cell_count() const {
        if (cells.empty()) {
            return box_cell_count();
        }
        int n = 0;
        for (uint8_t v : cells) {
            if (v) {
                ++n;
            }
        }
        return n;
    }
};

// ---------------------------------------------------------------------------
// Block -- one placed part.
//
// 16 bytes is the budget (Plan.md section 2 memory table). Blocks only exist
// inside a materialised chunk; an intact building is a recipe and has none.
// ---------------------------------------------------------------------------

struct Block {
    Vector3i cell;            // min corner, grid coords absolute
    int32_t archetype = -1;
    uint8_t colour = 0;
    uint8_t hp = 255;         // quantised, the determinism substrate
    bool alive = true;

    // Left the chunk as part of a falling cluster rather than being destroyed.
    // Both states mesh and collide as nothing; they differ in what they mean,
    // and a detached block's matter still exists somewhere in the world.
    bool detached = false;

    // Taken out by an EDIT rather than by damage: remove_block gave its cells
    // back, so the space is reusable and this record owns nothing. Distinct
    // from `alive` because a dead block still occupies its cells (you cannot
    // rebuild into a crater) and a removed one does not, and distinct from
    // `detached` because its matter does not exist anywhere in the world.
    //
    // The record survives so block ids stay stable -- the damage record, the
    // index partition and the block -> shape map all key on them. `archetype`
    // stays valid too: several hot loops walk every block and dereference it
    // without checking anything first.
    bool removed = false;

    // Fixed TO the structure rather than BEING structure: furniture, fittings,
    // a staircase flight. Docs/BuildMode.md section 9.2 named this role for a
    // FRAME and then found frames were the wrong unit -- a separate chunk with
    // a body of its own produced a building that landed on its own staircase,
    // and then, once the layers were fixed, a staircase left standing in the
    // rubble. The unit is the BLOCK, in the host's own grid.
    //
    // What the role changes is deliberately small, and it is the whole of what
    // "not structure" means here:
    //
    //   * it weighs nothing in solve_stress, so a room full of furniture cannot
    //     break the floor it stands on and a tower does not get heavier for
    //     being furnished;
    //   * it is left out of the centre of mass and the support footprint in
    //     check_stability, so what a building is balanced on is what it is
    //     BUILT of.
    //
    // What the role does NOT change is as important. A decorative block is in
    // the same chunk, the same occupancy grid, the same bake, the same
    // collision and the same damage record as everything else. It is connected:
    // grounding reaches it through whatever it rests on, so it holds still while
    // its floor exists and comes away with that floor when it does not. It rides
    // the island (Docs/Interiors.md section 4.2) because it is IN the island.
    bool decorative = false;

    // Crushed loose: the joints carrying this block's weight gave way. Damage,
    // so it stays set. Grounding will not reach a broken block at all, so it
    // and everything resting on it fall together -- which is the cascade.
    bool support_broken = false;

    // The joints on this block's UNDERSIDE gave way, and nothing else did.
    //
    // This is what a brick model does that concrete does not. `support_broken`
    // means "joined to nothing", so marking a slab of blocks with it turns that
    // slab into a spray of individual bricks -- which is how rubble behaves and
    // is not how a snapped LEGO wall behaves. A brick wall separates at a SEAM:
    // the studs along one course let go, the two halves each stay a solid
    // object, and nothing crumbles in between.
    //
    // Connectivity is vertical, so severing the downward joints of one course
    // is exactly that seam. `for_each_neighbour` skips the link in BOTH
    // directions -- a block does not see the neighbour below it, and that
    // neighbour does not see it -- so the cut is the same whichever side the
    // component walk arrives from.
    bool bottom_broken = false;

    // Transient, rebuilt by every stress solve. Weight of this block plus
    // everything resting on it, in FIXED-POINT mass units (brick::MASS_FIXED
    // per unit of archetype mass).
    //
    // Integer, not float, and that is a networking decision rather than a
    // performance one. The structural outcome -- which joints fail, which
    // pieces come away -- has to be identical on every machine in a multiplayer
    // game, and float accumulation is not: FMA contraction or a different
    // compiler's reassociation moves the last bit, and a comparison sitting on
    // the failure threshold flips. One flipped joint cascades into a different
    // collapse. See Docs/Multiplayer.md section 3.
    int64_t load = 0;

    // Index range this block owns in the chunk's last built mesh. This is the
    // partition that makes damage an index-exclusion rather than a remesh
    // (Plan.md section 3). Rebuilt by build_mesh().
    int32_t index_start = 0;
    int32_t index_count = 0;
};

// ---------------------------------------------------------------------------
// Chunk -- a dense region of the grid.
//
// occupancy holds a block index per CELL, -1 for empty, so face culling is a
// neighbour lookup and connectivity is integer adjacency. A block larger than
// one cell writes its index into every cell it covers.
// ---------------------------------------------------------------------------

// ---------------------------------------------------------------------------
// Baked faces.
//
// Every face that could EVER be visible is generated once, when the chunk is
// built. A face qualifies if the cell beyond it is empty or belongs to a
// different block; faces buried inside one block can never be seen and are
// never baked.
//
// Damage then never regenerates geometry. It only changes which faces are
// INDEXED:
//
//     draw face  iff  alive[owner] && (other < 0 || !alive[other])
//
// The `other < 0` case is a face already open to the air. The `!alive[other]`
// case is the one that makes a hole visible: when a block dies, the faces its
// neighbours had pressed against it come into the index buffer, so the inside
// of the wall appears without a single vertex being computed.
//
// Vertices are four per face, so face f owns [4f, 4f+4).
struct FaceBake {
    PackedVector3Array verts;
    PackedVector3Array normals;
    PackedColorArray colours;
    PackedVector2Array uvs;   // position within the owner's face rect, metres
    PackedVector2Array uv2s;  // that rect's size
    std::vector<int32_t> owner;
    std::vector<int32_t> other; // block on the far side, -1 = open air
    bool valid = false;
    double bake_ms = 0.0;

    int face_count() const { return (int)owner.size(); }

    void clear() {
        verts = PackedVector3Array();
        normals = PackedVector3Array();
        colours = PackedColorArray();
        uvs = PackedVector2Array();
        uv2s = PackedVector2Array();
        owner.clear();
        other.clear();
        valid = false;
    }
};

struct Chunk {
    Vector3i origin;               // grid coords of the min corner
    Vector3i dims;                 // size in cells
    std::vector<int32_t> occupancy; // dims.x * dims.y * dims.z, -1 = empty
    std::vector<Block> blocks;
    FaceBake bake;

    // The index buffer currently on the GPU. FIXED length -- six entries per
    // baked face, always -- with hidden faces written as degenerate triangles
    // (0,0,0). A constant length is what lets the surface be created once and
    // then patched in place: uploading a fresh ArrayMesh re-sends the whole
    // vertex buffer, which measured 175 ms per cascade step at 16.5k blocks.
    PackedInt32Array live_indices;

    // --- where this chunk is in the world ---------------------------------
    //
    // A building sits on the grid and never moves, so its transform is just
    // grid_to_world(origin). A detached ISLAND is the same structure with the
    // same grid, carried around by a rigid body -- so it needs a full
    // transform, and every query that takes a world point has to come through
    // it first.
    //
    // Making an island a chunk rather than a bag of boxes is what lets it be
    // shot at, re-solved for connectivity and split in two: everything that
    // works on a building works on a piece of one, unchanged.
    Transform3D xform;

    // --- frame ------------------------------------------------------------
    //
    // The chunk as one of the 24 axis-aligned rotations at an exact integer
    // TICK offset (0.07 m: a stud is 5, a plate is 2). `xform` is DERIVED from
    // these -- they are the truth, because only they are exact, and cross-frame
    // alignment has to be integer or two frames cannot be guaranteed to touch.
    int frame_rotation = 0;
    Vector3i frame_ticks;

    // Anchored chunks are held up by the ground and get a grounding solve.
    // Islands are in free fall or resting; connectivity still matters (it is
    // what splits them), but "reaches the foundation" does not.
    bool anchored = true;

    int cell_count() const { return dims.x * dims.y * dims.z; }

    bool in_bounds(const Vector3i &local) const {
        return local.x >= 0 && local.y >= 0 && local.z >= 0 &&
               local.x < dims.x && local.y < dims.y && local.z < dims.z;
    }

    int index_of(const Vector3i &local) const {
        return local.x + dims.x * (local.y + dims.y * local.z);
    }

    // -1 when empty or out of bounds.
    int32_t block_at(const Vector3i &local) const {
        if (!in_bounds(local)) {
            return -1;
        }
        return occupancy[index_of(local)];
    }

    // A cell is solid only if it holds a block that is still alive.
    bool solid_at(const Vector3i &local) const {
        const int32_t b = block_at(local);
        return b >= 0 && blocks[b].alive;
    }
};

} // namespace brick

#endif // BRICK_TYPES_H
