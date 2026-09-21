#include "brick_world.h"
#include "brick_grid.h"

#include <godot_cpp/classes/mesh.hpp>
#include <godot_cpp/classes/physics_server3d.hpp>
#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/variant/packed_color_array.hpp>
#include <godot_cpp/variant/packed_int32_array.hpp>
#include <godot_cpp/variant/packed_vector2_array.hpp>
#include <godot_cpp/variant/packed_vector3_array.hpp>
#include <godot_cpp/variant/utility_functions.hpp>

#include <algorithm>
#include <chrono>
#include <climits>
#include <cstring>

using namespace godot;
using namespace brick;

// ---------------------------------------------------------------------------
// Face tables.
//
// Order is fixed -- +X, -X, +Y, -Y, +Z, -Z -- and so is the corner order inside
// each face. Meshing walks blocks in id order, cells in (x, y, z) order and
// faces in this order, which is what makes a rebuilt mesh byte-identical for
// identical state (gate G6).
//
// Corners are unit offsets (0 or 1 per axis) laid out a, b, c, d. Triangles are
// (a, b, c) and (b, d, c). Godot derives a face's plane as
// (p1 - p3) cross (p1 - p2), and every entry below was checked against that so
// the winding faces outward. Explicit normals are emitted as well, so shading
// stays correct even if a future engine change flips the culling convention.
// ---------------------------------------------------------------------------

namespace {

const Vector3i FACE_DIR[6] = {
    Vector3i(1, 0, 0),  // +X
    Vector3i(-1, 0, 0), // -X
    Vector3i(0, 1, 0),  // +Y
    Vector3i(0, -1, 0), // -Y
    Vector3i(0, 0, 1),  // +Z
    Vector3i(0, 0, -1), // -Z
};

/// How far along "up" a cell sits, in cells. With the default up of (0,1,0)
/// this is just cell.y, which is what every chunk that has not toppled uses.
static inline int height_along(const Vector3i &cell, const Vector3i &up) {
    return cell.x * up.x + cell.y * up.y + cell.z * up.z;
}


const Vector3 FACE_NORMAL[6] = {
    Vector3(1, 0, 0),
    Vector3(-1, 0, 0),
    Vector3(0, 1, 0),
    Vector3(0, -1, 0),
    Vector3(0, 0, 1),
    Vector3(0, 0, -1),
};

const Vector3i FACE_CORNERS[6][4] = {
    // +X
    { Vector3i(1, 0, 0), Vector3i(1, 0, 1), Vector3i(1, 1, 0), Vector3i(1, 1, 1) },
    // -X
    { Vector3i(0, 0, 0), Vector3i(0, 1, 0), Vector3i(0, 0, 1), Vector3i(0, 1, 1) },
    // +Y
    { Vector3i(0, 1, 0), Vector3i(1, 1, 0), Vector3i(0, 1, 1), Vector3i(1, 1, 1) },
    // -Y
    { Vector3i(0, 0, 0), Vector3i(0, 0, 1), Vector3i(1, 0, 0), Vector3i(1, 0, 1) },
    // +Z
    { Vector3i(0, 0, 1), Vector3i(0, 1, 1), Vector3i(1, 0, 1), Vector3i(1, 1, 1) },
    // -Z
    { Vector3i(0, 0, 0), Vector3i(1, 0, 0), Vector3i(0, 1, 0), Vector3i(1, 1, 0) },
};

} // namespace

// ---------------------------------------------------------------------------

BrickWorld::BrickWorld() {
    set_seed(0);
}


bool BrickWorld::valid_chunk(int chunk_id) const {
    return chunk_id >= 0 && chunk_id < (int)chunks.size() && chunk_live[chunk_id] != 0;
}

bool BrickWorld::valid_archetype(int archetype_id) const {
    return archetype_id >= 0 && archetype_id < (int)archetypes.size();
}

// --- archetype library -----------------------------------------------------

int BrickWorld::bake_archetype(const String &name, Vector3i size, float mass) {
    if (size.x < 1 || size.y < 1 || size.z < 1) {
        UtilityFunctions::push_error("BrickWorld: archetype '", name, "' has a non-positive size");
        return -1;
    }
    Archetype a;
    a.name = name;
    a.size = size;
    a.mass = mass;
    a.build_surface_cells();
    archetypes.push_back(a);
    return (int)archetypes.size() - 1;
}

int BrickWorld::bake_shaped_archetype(const String &name, Vector3i size, float mass,
        const PackedByteArray &cells, const PackedByteArray &studs,
        const PackedByteArray &sockets) {
    const int id = bake_archetype(name, size, mass);
    if (id < 0) {
        return -1;
    }
    Archetype &a = archetypes[id];

    const int64_t box = (int64_t)size.x * size.y * size.z;
    const int64_t cols = (int64_t)size.x * size.z;

    if (!cells.is_empty()) {
        if (cells.size() != box) {
            UtilityFunctions::push_error("BrickWorld: '", name, "' cell mask is ", cells.size(),
                    ", expected ", box);
            return -1;
        }
        a.cells.assign(cells.ptr(), cells.ptr() + cells.size());
        if (a.solid_cell_count() == 0) {
            UtilityFunctions::push_error("BrickWorld: '", name, "' has no solid cells");
            return -1;
        }
    }
    if (!studs.is_empty()) {
        if (studs.size() != cols) {
            UtilityFunctions::push_error("BrickWorld: '", name, "' stud mask is ", studs.size(),
                    ", expected ", cols);
            return -1;
        }
        // One-bit in, two-bit stored: a column with no stud is smooth, not a
        // socket. Every existing caller means exactly this.
        a.up_face.resize(cols);
        for (int64_t i = 0; i < cols; ++i) {
            a.up_face[(size_t)i] = studs[i] ? FACE_STUD : FACE_NONE;
        }
    }
    if (!sockets.is_empty()) {
        if (sockets.size() != cols) {
            UtilityFunctions::push_error("BrickWorld: '", name, "' socket mask is ", sockets.size(),
                    ", expected ", cols);
            return -1;
        }
        a.down_face.resize(cols);
        for (int64_t i = 0; i < cols; ++i) {
            a.down_face[(size_t)i] = sockets[i] ? FACE_SOCKET : FACE_NONE;
        }
    }
    a.build_surface_cells(); // the cell mask changed, so the surfaces did too
    return id;
}

bool BrickWorld::is_archetype_full_box(int archetype_id) const {
    return valid_archetype(archetype_id) && archetypes[archetype_id].is_full_box();
}

int BrickWorld::get_archetype_solid_cells(int archetype_id) const {
    return valid_archetype(archetype_id) ? archetypes[archetype_id].solid_cell_count() : 0;
}

// ---------------------------------------------------------------------------
// Orientation variants. Docs/BuildMode.md section 3.
// ---------------------------------------------------------------------------

namespace {

/// Map a cell of a part through `yaw` quarter turns about +Y, then a flip of
/// 180 degrees about X. Writes the new coordinate and reports the new size.
///
/// Yaw swaps two STUD axes, so it is exact. Flip reverses Y and Z and leaves
/// every extent alone. The one rotation that is NOT here is 90 degrees about X
/// or Z, which would swap a stud axis with the plate axis and land on 1.2
/// studs -- section 2.1, and the reason sideways building is a frame rather
/// than a rotation.
struct Orient {
    Vector3i size;
    int yaw;
    bool flip;

    Vector3i out_size() const {
        if (yaw & 1) {
            return Vector3i(size.z, size.y, size.x);
        }
        return size; // flip leaves extents unchanged
    }

    void cell(int x, int y, int z, int &ox, int &oy, int &oz) const {
        int ax = x, az = z;
        switch (yaw) {
            case 1: ax = size.z - 1 - z; az = x; break;
            case 2: ax = size.x - 1 - x; az = size.z - 1 - z; break;
            case 3: ax = z;              az = size.x - 1 - x; break;
            default: break;
        }
        const Vector3i os = out_size();
        ox = ax;
        oy = y;
        oz = az;
        if (flip) {
            oy = os.y - 1 - oy;
            oz = os.z - 1 - oz;
        }
    }

    /// Columns move the same way cells do, minus the Y term.
    void column(int x, int z, int &ox, int &oz) const {
        int dummy;
        cell(x, 0, z, ox, dummy, oz);
    }

    /// The LINEAR part only, for a direction. `cell` folds in size-dependent
    /// reflections, which are right for a position and wrong for a normal.
    void direction(int dx, int dy, int dz, int &ox, int &oy, int &oz) const {
        int ax = dx, az = dz;
        switch (yaw) {
            case 1: ax = -dz; az = dx;  break;
            case 2: ax = -dx; az = -dz; break;
            case 3: ax = dz;  az = -dx; break;
            default: break;
        }
        ox = ax;
        oy = dy;
        oz = az;
        if (flip) {
            oy = -oy;
            oz = -oz;
        }
    }
};

} // namespace

int BrickWorld::bake_variant(int base_archetype, const String &name, int yaw, bool flip) {
    if (!valid_archetype(base_archetype)) {
        return -1;
    }
    // By value: archetypes may reallocate when the new one is pushed.
    const Archetype base = archetypes[base_archetype];
    Orient o{base.size, ((yaw % 4) + 4) % 4, flip};

    Archetype a;
    a.name = name;
    a.size = o.out_size();
    a.mass = base.mass;

    const int64_t box = (int64_t)a.size.x * a.size.y * a.size.z;
    const int64_t cols = (int64_t)a.size.x * a.size.z;

    if (!base.cells.empty()) {
        a.cells.assign((size_t)box, 0);
        for (int x = 0; x < base.size.x; ++x) {
            for (int y = 0; y < base.size.y; ++y) {
                for (int z = 0; z < base.size.z; ++z) {
                    if (!base.solid_at(x, y, z)) {
                        continue;
                    }
                    int ox, oy, oz;
                    o.cell(x, y, z, ox, oy, oz);
                    const size_t i = (size_t)ox
                            + (size_t)a.size.x * ((size_t)oy + (size_t)a.size.y * (size_t)oz);
                    a.cells[i] = 1;
                }
            }
        }
    }

    // A flip turns the top face into the bottom one. That is the whole reason
    // the masks are two-bit: "studs up, sockets down" cannot describe the
    // result, and an inverted part is an ordinary block on the ordinary grid.
    const bool defaulted = base.up_face.empty() && base.down_face.empty();
    if (!defaulted || flip) {
        a.up_face.assign((size_t)cols, FACE_NONE);
        a.down_face.assign((size_t)cols, FACE_NONE);
        for (int x = 0; x < base.size.x; ++x) {
            for (int z = 0; z < base.size.z; ++z) {
                int ox, oz;
                o.column(x, z, ox, oz);
                const size_t dst = (size_t)ox + (size_t)a.size.x * (size_t)oz;
                const uint8_t up = base.up_at(x, z);
                const uint8_t down = base.down_at(x, z);
                a.up_face[dst] = flip ? down : up;
                a.down_face[dst] = flip ? up : down;
            }
        }
    }

    // Side studs move with the part: the cell they sit on rotates like a
    // position, the face they point along rotates like a normal.
    for (const Archetype::SideStud &ss : base.side_studs) {
        int cx, cy, cz, dx, dy, dz;
        o.cell(ss.x, ss.y, ss.z, cx, cy, cz);
        o.direction(ss.dx, ss.dy, ss.dz, dx, dy, dz);
        a.side_studs.push_back({(int8_t)cx, (int8_t)cy, (int8_t)cz,
                (int8_t)dx, (int8_t)dy, (int8_t)dz});
    }

    a.build_surface_cells();

    // Dedupe. A 2x2 brick yawed 90 degrees is the brick it already was, and two
    // ids on one shape would let a recipe name the same part two ways.
    for (size_t i = 0; i < archetypes.size(); ++i) {
        if (archetypes[i].same_shape_as(a)) {
            return (int)i;
        }
    }
    archetypes.push_back(a);
    return (int)archetypes.size() - 1;
}

int BrickWorld::bake_faced_archetype(const String &name, Vector3i size, float mass,
        const PackedByteArray &cells, const PackedByteArray &up_face,
        const PackedByteArray &down_face) {
    const int id = bake_archetype(name, size, mass);
    if (id < 0) {
        return -1;
    }
    Archetype &a = archetypes[id];
    const int64_t box = (int64_t)size.x * size.y * size.z;
    const int64_t cols = (int64_t)size.x * size.z;

    if (!cells.is_empty()) {
        if (cells.size() != box) {
            UtilityFunctions::push_error("BrickWorld: cell mask wrong size for ", name);
            return -1;
        }
        a.cells.assign(cells.ptr(), cells.ptr() + cells.size());
        if (a.solid_cell_count() == 0) {
            UtilityFunctions::push_error("BrickWorld: no solid cells in ", name);
            return -1;
        }
    }
    if (!up_face.is_empty()) {
        if (up_face.size() != cols) {
            UtilityFunctions::push_error("BrickWorld: up_face wrong size for ", name);
            return -1;
        }
        a.up_face.assign(up_face.ptr(), up_face.ptr() + up_face.size());
    }
    if (!down_face.is_empty()) {
        if (down_face.size() != cols) {
            UtilityFunctions::push_error("BrickWorld: down_face wrong size for ", name);
            return -1;
        }
        a.down_face.assign(down_face.ptr(), down_face.ptr() + down_face.size());
    }
    a.build_surface_cells();
    return id;
}

PackedByteArray BrickWorld::get_archetype_up_face(int archetype_id) const {
    PackedByteArray out;
    if (!valid_archetype(archetype_id)) {
        return out;
    }
    const Archetype &a = archetypes[archetype_id];
    out.resize((int64_t)a.size.x * a.size.z);
    for (int z = 0; z < a.size.z; ++z) {
        for (int x = 0; x < a.size.x; ++x) {
            out.set(x + a.size.x * z, a.up_at(x, z));
        }
    }
    return out;
}

PackedByteArray BrickWorld::get_archetype_down_face(int archetype_id) const {
    PackedByteArray out;
    if (!valid_archetype(archetype_id)) {
        return out;
    }
    const Archetype &a = archetypes[archetype_id];
    out.resize((int64_t)a.size.x * a.size.z);
    for (int z = 0; z < a.size.z; ++z) {
        for (int x = 0; x < a.size.x; ++x) {
            out.set(x + a.size.x * z, a.down_at(x, z));
        }
    }
    return out;
}

int BrickWorld::get_archetype_count() const {
    return (int)archetypes.size();
}

Vector3i BrickWorld::get_archetype_size(int archetype_id) const {
    if (!valid_archetype(archetype_id)) {
        return Vector3i(0, 0, 0);
    }
    return archetypes[archetype_id].size;
}

String BrickWorld::get_archetype_name(int archetype_id) const {
    if (!valid_archetype(archetype_id)) {
        return String();
    }
    return archetypes[archetype_id].name;
}

// --- chunks ----------------------------------------------------------------

int BrickWorld::create_chunk(Vector3i origin, Vector3i dims) {
    if (dims.x < 1 || dims.y < 1 || dims.z < 1) {
        UtilityFunctions::push_error("BrickWorld: chunk dims must be positive");
        return -1;
    }
    Chunk c;
    c.origin = origin;
    c.dims = dims;
    c.occupancy.assign((size_t)c.cell_count(), -1);
    c.xform = Transform3D(Basis(), brick::grid_to_world(origin));
    c.anchored = true;
    chunks.push_back(std::move(c));
    chunk_live.push_back(1);
    stats.push_back(MeshStats());
    solve_stats.push_back(SolveStats());
    stress.push_back(StressState());
    foundation_level.push_back(origin.y); // the chunk's own floor anchors it
    chunk_down.push_back(Vector3i(0, -1, 0));
    return (int)chunks.size() - 1;
}

int BrickWorld::get_chunk_count() const {
    return (int)chunks.size();
}

Vector3i BrickWorld::get_chunk_origin(int chunk_id) const {
    return valid_chunk(chunk_id) ? chunks[chunk_id].origin : Vector3i();
}

Vector3i BrickWorld::get_chunk_dims(int chunk_id) const {
    return valid_chunk(chunk_id) ? chunks[chunk_id].dims : Vector3i();
}

int BrickWorld::place_block(int chunk_id, Vector3i cell, int archetype_id, int colour,
        bool decorative) {
    if (!valid_chunk(chunk_id) || !valid_archetype(archetype_id)) {
        return -1;
    }
    Chunk &c = chunks[chunk_id];
    const Archetype &a = archetypes[archetype_id];
    const Vector3i base = cell - c.origin;

    // Only the cells the part actually occupies are claimed, so an L-piece can
    // sit in the notch of another. Check the whole shape before writing
    // anything, so a rejected placement leaves the chunk untouched. A dead
    // block still owns its cells: its bricks are gone but the space is not
    // reusable yet.
    for (int x = 0; x < a.size.x; ++x) {
        for (int y = 0; y < a.size.y; ++y) {
            for (int z = 0; z < a.size.z; ++z) {
                if (!a.solid_at(x, y, z)) {
                    continue;
                }
                const Vector3i l(base.x + x, base.y + y, base.z + z);
                if (!c.in_bounds(l) || c.occupancy[c.index_of(l)] >= 0) {
                    return -1;
                }
            }
        }
    }

    const int32_t id = (int32_t)c.blocks.size();
    Block b;
    b.cell = cell;
    b.archetype = archetype_id;
    b.colour = (uint8_t)std::clamp(colour, 0, FILAMENT_COUNT - 1);
    b.decorative = decorative;
    c.blocks.push_back(b);

    for (int x = 0; x < a.size.x; ++x) {
        for (int y = 0; y < a.size.y; ++y) {
            for (int z = 0; z < a.size.z; ++z) {
                if (!a.solid_at(x, y, z)) {
                    continue;
                }
                const Vector3i l(base.x + x, base.y + y, base.z + z);
                c.occupancy[c.index_of(l)] = id;
            }
        }
    }
    // Geometry changed, so the bake has to be redone. Damage never gets here:
    // killing a block only changes which baked faces are indexed.
    //
    // A DECORATIVE block is the exception, and it is the point of the flag
    // being passed in here rather than set afterwards: it is not in the bake,
    // and its cells read as air to everything that is, so the bake this chunk
    // already holds is still exactly right.
    if (decorative) {
        return id;
    }
    c.bake.valid = false;
    // A bake running against the old geometry is now worthless, and it is
    // reading the very arrays this call just wrote. Join it and drop it.
    // `place_block` is called once per block when an island is cut out of a
    // building, so this check is on the hottest path there is. Scanning the job
    // list is only worth it when there is a job.
    if (!bake_jobs.empty() && bake_pending(chunk_id)) {
        settle_bake_job(chunk_id, false);
    }
    return id;
}

// ---------------------------------------------------------------------------
// Editing. Distinct from damage on purpose -- see the header.
// ---------------------------------------------------------------------------

bool BrickWorld::remove_block(int chunk_id, int block_id) {
    if (!valid_chunk(chunk_id)) {
        return false;
    }
    Chunk &c = chunks[chunk_id];
    if (block_id < 0 || block_id >= (int)c.blocks.size()) {
        return false;
    }
    Block &b = c.blocks[block_id];
    if (b.removed) {
        return false; // already a tombstone
    }
    const Archetype &a = archetypes[b.archetype];
    const Vector3i base = b.cell - c.origin;

    // Release only the cells this block actually owns. A masked part left its
    // notch free for somebody else, and that somebody is still there.
    for (int x = 0; x < a.size.x; ++x) {
        for (int y = 0; y < a.size.y; ++y) {
            for (int z = 0; z < a.size.z; ++z) {
                if (!a.solid_at(x, y, z)) {
                    continue;
                }
                const Vector3i l(base.x + x, base.y + y, base.z + z);
                if (c.in_bounds(l) && c.occupancy[c.index_of(l)] == block_id) {
                    c.occupancy[c.index_of(l)] = -1;
                }
            }
        }
    }

    // The record stays, owning nothing. Compacting would renumber every block
    // after this one, and block ids are what the damage record, the index
    // partition and the block -> shape map all key on. `archetype` stays valid
    // because the face bake and get_block_boxes walk every block and index it
    // without a guard; `removed` is what those loops skip on.
    b.alive = false;
    b.removed = true;
    b.index_count = 0;
    b.load = 0;

    // Geometry changed, so the bake is stale and a bake in flight is reading
    // the arrays this call just wrote. Same contract as place_block -- and the
    // same exception, for the same reason.
    if (!b.decorative) {
        c.bake.valid = false;
        if (bake_pending(chunk_id)) {
            settle_bake_job(chunk_id, false);
        }
    }
    return true;
}

bool BrickWorld::can_place(int chunk_id, Vector3i cell, int archetype_id) const {
    if (!valid_chunk(chunk_id) || !valid_archetype(archetype_id)) {
        return false;
    }
    const Chunk &c = chunks[chunk_id];
    const Archetype &a = archetypes[archetype_id];
    const Vector3i base = cell - c.origin;
    for (int x = 0; x < a.size.x; ++x) {
        for (int y = 0; y < a.size.y; ++y) {
            for (int z = 0; z < a.size.z; ++z) {
                if (!a.solid_at(x, y, z)) {
                    continue;
                }
                const Vector3i l(base.x + x, base.y + y, base.z + z);
                if (!c.in_bounds(l) || c.occupancy[c.index_of(l)] >= 0) {
                    return false;
                }
            }
        }
    }
    return true;
}

int BrickWorld::would_connect(int chunk_id, Vector3i cell, int archetype_id) const {
    if (!can_place(chunk_id, cell, archetype_id)) {
        return -1;
    }
    const Chunk &c = chunks[chunk_id];
    const Archetype &a = archetypes[archetype_id];
    const Vector3i base = cell - c.origin;
    int joints = 0;

    // Same test for_each_neighbour runs, with the hypothetical part standing in
    // for one side of the joint. Only surfaces can carry a stud, so only the
    // precomputed surface cells are walked -- the cells in between cannot join
    // anything by definition.
    for (const Archetype::SurfaceCell &sc : a.bottom_cells) {
        const Vector3i l(base.x + sc.x, base.y + sc.y - 1, base.z + sc.z);
        const int32_t below = c.block_at(l);
        if (below < 0 || !c.blocks[below].alive) {
            continue;
        }
        const Block &lb = c.blocks[below];
        const Archetype &la = archetypes[lb.archetype];
        const int wx = cell.x + sc.x;
        const int wz = cell.z + sc.z;
        if (Archetype::faces_mate(a.down_at(sc.x, sc.z),
                la.up_at(wx - lb.cell.x, wz - lb.cell.z))) {
            ++joints;
        }
    }
    for (const Archetype::SurfaceCell &sc : a.top_cells) {
        const Vector3i l(base.x + sc.x, base.y + sc.y + 1, base.z + sc.z);
        const int32_t above = c.block_at(l);
        if (above < 0 || !c.blocks[above].alive) {
            continue;
        }
        const Block &ub = c.blocks[above];
        const Archetype &ua = archetypes[ub.archetype];
        const int wx = cell.x + sc.x;
        const int wz = cell.z + sc.z;
        if (Archetype::faces_mate(ua.down_at(wx - ub.cell.x, wz - ub.cell.z),
                a.up_at(sc.x, sc.z))) {
            ++joints;
        }
    }
    return joints;
}

int BrickWorld::kill_block(int chunk_id, Vector3i cell) {
    if (!valid_chunk(chunk_id)) {
        return -1;
    }
    Chunk &c = chunks[chunk_id];
    const int32_t id = c.block_at(cell - c.origin);
    if (id < 0 || !c.blocks[id].alive) {
        return -1;
    }
    c.blocks[id].alive = false;
    c.blocks[id].hp = 0;
    return id;
}

void BrickWorld::kill_blocks(int chunk_id, const PackedInt32Array &ids) {
    if (!valid_chunk(chunk_id)) {
        return;
    }
    Chunk &c = chunks[chunk_id];
    for (int i = 0; i < ids.size(); ++i) {
        const int32_t bid = ids[i];
        if (bid < 0 || bid >= (int32_t)c.blocks.size()) {
            continue;
        }
        c.blocks[bid].alive = false;
        c.blocks[bid].hp = 0;
    }
}

PackedByteArray BrickWorld::get_column_mask(int chunk_id, int y0, int y1) const {
    PackedByteArray out;
    if (!valid_chunk(chunk_id)) {
        return out;
    }
    const Chunk &c = chunks[chunk_id];
    out.resize((int64_t)c.dims.x * c.dims.z);
    uint8_t *w = out.ptrw();
    std::memset(w, 0, (size_t)c.dims.x * c.dims.z);

    // Clamp to the chunk rather than refusing: a caller walking a recipe's
    // bands does not know where the chunk ends, and a band past the top is
    // legitimately all-empty rather than an error.
    const int lo = std::max(0, y0 - c.origin.y);
    const int hi = std::min(c.dims.y, y1 - c.origin.y);
    for (int y = lo; y < hi; ++y) {
        for (int z = 0; z < c.dims.z; ++z) {
            for (int x = 0; x < c.dims.x; ++x) {
                const size_t col = (size_t)x + (size_t)c.dims.x * (size_t)z;
                if (w[col]) {
                    continue; // this column already answered yes
                }
                if (c.solid_at(Vector3i(x, y, z))) {
                    w[col] = 1;
                }
            }
        }
    }
    return out;
}

Dictionary BrickWorld::build_damage_profile(int chunk_id, int fx, int fz, int thick,
        int segments, PackedInt32Array bands) const {
    Dictionary out;
    if (!valid_chunk(chunk_id) || fx <= 0 || fz <= 0 || segments <= 0 || thick <= 0) {
        return out;
    }
    const Chunk &c = chunks[chunk_id];
    const int all_standing = -1; // every bit set, matching BuildingShell.ALL_STANDING

    // One column mask per band, then 4 x `segments` rectangle tests over it.
    // This lived in GDScript and cost 3.4 ms a building -- 128 nested-loop
    // rectangle scans per band, times ~34 bands -- which was two thirds of what
    // de-materialising a building cost and therefore what held the trim budget
    // down to one building a run. It is a pure walk over occupancy, so it
    // belongs here.
    std::vector<uint8_t> col((size_t)c.dims.x * (size_t)c.dims.z);

    const int band_count = bands.size() / 2;
    for (int bi = 0; bi < band_count; ++bi) {
        const int y0 = bands[bi * 2];
        const int y1 = y0 + bands[bi * 2 + 1];

        std::fill(col.begin(), col.end(), (uint8_t)0);
        const int lo = std::max(0, y0 - c.origin.y);
        const int hi = std::min(c.dims.y, y1 - c.origin.y);
        for (int y = lo; y < hi; ++y) {
            for (int z = 0; z < c.dims.z; ++z) {
                for (int x = 0; x < c.dims.x; ++x) {
                    const size_t k = (size_t)x + (size_t)c.dims.x * (size_t)z;
                    if (!col[k] && c.solid_at(Vector3i(x, y, z))) {
                        col[k] = 1;
                    }
                }
            }
        }
        if ((int)col.size() < fx * fz) {
            continue;
        }

        // Is any column alive in this XZ rectangle?
        auto any = [&](int x0, int x1, int z0, int z1) -> bool {
            for (int z = std::max(z0, 0); z < z1; ++z) {
                for (int x = std::max(x0, 0); x < x1; ++x) {
                    const int i = x + fx * z;
                    if (i >= 0 && i < (int)col.size() && col[i] != 0) {
                        return true;
                    }
                }
            }
            return false;
        };

        int masks[4] = {0, 0, 0, 0};
        for (int seg = 0; seg < segments; ++seg) {
            // Segment -> cell range along the run. Ceil the end so a wall whose
            // stud count does not divide by `segments` still covers every cell.
            const int ax = (seg * fx) / segments;
            const int bx = std::max(ax + 1, ((seg + 1) * fx) / segments);
            const int az = (seg * fz) / segments;
            const int bz = std::max(az + 1, ((seg + 1) * fz) / segments);
            const int bit = 1 << seg;
            if (any(ax, bx, 0, thick))            { masks[0] |= bit; } // FRONT
            if (any(ax, bx, fz - thick, fz))      { masks[1] |= bit; } // BACK
            if (any(0, thick, az, bz))            { masks[2] |= bit; } // LEFT
            if (any(fx - thick, fx, az, bz))      { masks[3] |= bit; } // RIGHT
        }

        // An untouched band carries no entry at all, so an intact building has
        // an empty profile and the shell takes its original path.
        if (masks[0] != all_standing || masks[1] != all_standing
                || masks[2] != all_standing || masks[3] != all_standing) {
            PackedInt32Array m;
            m.push_back(masks[0]);
            m.push_back(masks[1]);
            m.push_back(masks[2]);
            m.push_back(masks[3]);
            out[bi] = m;
        }
    }
    return out;
}

int BrickWorld::get_dead_block_count(int chunk_id) const {
    if (!valid_chunk(chunk_id)) {
        return 0;
    }
    const Chunk &c = chunks[chunk_id];
    int n = 0;
    // Same test as get_dead_blocks, and it has to stay the same test: callers
    // compare this count against a previous one to decide whether the holes
    // have moved.
    for (size_t i = 0; i < c.blocks.size(); ++i) {
        const Block &b = c.blocks[i];
        if (!b.alive && !b.detached && !b.removed) {
            ++n;
        }
    }
    return n;
}

PackedInt32Array BrickWorld::get_dead_blocks(int chunk_id) const {
    PackedInt32Array out;
    if (!valid_chunk(chunk_id)) {
        return out;
    }
    const Chunk &c = chunks[chunk_id];
    for (size_t i = 0; i < c.blocks.size(); ++i) {
        // Detached blocks left as part of an island; they are not destroyed and
        // must not come back as holes when the building is rebuilt. Removed
        // blocks were edited away, which is not damage either.
        if (!c.blocks[i].alive && !c.blocks[i].detached && !c.blocks[i].removed) {
            out.push_back((int32_t)i);
        }
    }
    return out;
}

int BrickWorld::get_block_archetype(int chunk_id, int block_id) const {
    if (!valid_chunk(chunk_id)) {
        return -1;
    }
    const Chunk &c = chunks[chunk_id];
    return (block_id >= 0 && block_id < (int)c.blocks.size()) ? c.blocks[block_id].archetype : -1;
}

int BrickWorld::get_block_colour(int chunk_id, int block_id) const {
    if (!valid_chunk(chunk_id)) {
        return 0;
    }
    const Chunk &c = chunks[chunk_id];
    return (block_id >= 0 && block_id < (int)c.blocks.size()) ? (int)c.blocks[block_id].colour : 0;
}

bool BrickWorld::is_solid(int chunk_id, Vector3i cell) const {
    if (!valid_chunk(chunk_id)) {
        return false;
    }
    const Chunk &c = chunks[chunk_id];
    return c.solid_at(cell - c.origin);
}

int BrickWorld::block_at(int chunk_id, Vector3i cell) const {
    if (!valid_chunk(chunk_id)) {
        return -1;
    }
    const Chunk &c = chunks[chunk_id];
    return c.block_at(cell - c.origin);
}

int BrickWorld::get_block_count(int chunk_id) const {
    return valid_chunk(chunk_id) ? (int)chunks[chunk_id].blocks.size() : 0;
}

int BrickWorld::get_alive_block_count(int chunk_id) const {
    if (!valid_chunk(chunk_id)) {
        return 0;
    }
    int n = 0;
    for (const Block &b : chunks[chunk_id].blocks) {
        if (b.alive) {
            ++n;
        }
    }
    return n;
}

Vector2i BrickWorld::get_block_index_range(int chunk_id, int block_id) const {
    if (!valid_chunk(chunk_id)) {
        return Vector2i(0, 0);
    }
    const Chunk &c = chunks[chunk_id];
    if (block_id < 0 || block_id >= (int)c.blocks.size()) {
        return Vector2i(0, 0);
    }
    return Vector2i(c.blocks[block_id].index_start, c.blocks[block_id].index_count);
}

// --- meshing ---------------------------------------------------------------

// The bake, as a free function, so a worker thread can run it without touching
// BrickWorld. It reads a chunk's GEOMETRY only -- cells, archetypes, colours,
// occupancy -- and never `alive`, `load`, `index_start` or anything else damage
// writes. That is what makes it safe to run while the game plays.
// The bake, as a free function, so a worker thread can run it without touching
// BrickWorld. It reads a chunk's GEOMETRY only -- cells, archetypes, colours,
// occupancy -- and never `alive`, `load`, `index_start` or anything else damage
// writes. That is what makes it safe to run while the game plays.
//
// Faces are GREEDY-MERGED within each block. The naive version emitted one quad
// per cell face, which measured 43.9 baked faces per block on the 150 m tower
// where a 2x4 brick needs six -- and the bake is 98% of this system's memory.
// Cells on the same face plane merge when they agree about what is on the other
// side of them, because that is exactly the condition under which they are
// drawn or culled together (see fill_indices).
//
// Nothing about the seam shader changes: UV is still position within the
// BLOCK's face rectangle and UV2 is still that rectangle's size, so a merged
// quad covering four cells still carries one brick outline, not four.
static void bake_faces_into(const Chunk &c, const std::vector<Archetype> &parts,
        FaceBake &fb) {
    const auto t0 = std::chrono::steady_clock::now();
    fb.clear();

    const Vector3 cs = cell_size();
    // Which axes span each face plane, and which one it is sliced along.
    // 0 = x, 1 = y, 2 = z.
    static const int SLICE_AXIS[6] = { 0, 0, 1, 1, 2, 2 };
    static const int PLANE_A[6]    = { 1, 1, 0, 0, 0, 0 };
    static const int PLANE_B[6]    = { 2, 2, 2, 2, 1, 1 };

    constexpr int32_t NO_FACE = INT32_MIN;
    std::vector<int32_t> mask;   // what is on the far side of each cell face
    std::vector<uint8_t> taken;

    for (size_t bi = 0; bi < c.blocks.size(); ++bi) {
        const Block &b = c.blocks[bi];
        if (b.removed) {
            continue; // edited away: owns no cells, so it has no faces
        }
        if (b.decorative) {
            // Interiors are not in the building's bake AT ALL. They are drawn
            // separately, per chunk, from the blocks themselves -- because a
            // bake is whole-chunk and a room is not, and re-baking 50,000
            // bricks to add a chair is the single most expensive thing
            // interiors ever did.
            continue;
        }
        const Archetype &a = parts[b.archetype];
        const Vector3i base = b.cell - c.origin;
        const Color col = filament_colour(b.colour);
        const Vector3 block_origin(base.x * cs.x, base.y * cs.y, base.z * cs.z);
        const int asize[3] = { a.size.x, a.size.y, a.size.z };

        for (int f = 0; f < 6; ++f) {
            const int sa = SLICE_AXIS[f];
            const int pa = PLANE_A[f];
            const int pb = PLANE_B[f];
            const int an = asize[pa];
            const int bn = asize[pb];
            const int sn = asize[sa];

            Vector2 face_size;
            switch (f) {
                case 0: case 1: face_size = Vector2(a.size.z * cs.z, a.size.y * cs.y); break;
                case 2: case 3: face_size = Vector2(a.size.x * cs.x, a.size.z * cs.z); break;
                default:        face_size = Vector2(a.size.x * cs.x, a.size.y * cs.y); break;
            }

            mask.assign((size_t)an * bn, NO_FACE);
            taken.assign((size_t)an * bn, 0);

            for (int si = 0; si < sn; ++si) {
                // Fill the slice's mask.
                bool any = false;
                for (int ai = 0; ai < an; ++ai) {
                    for (int bj = 0; bj < bn; ++bj) {
                        int lc[3] = { 0, 0, 0 };
                        lc[sa] = si;
                        lc[pa] = ai;
                        lc[pb] = bj;
                        const size_t m = (size_t)ai * bn + bj;
                        mask[m] = NO_FACE;
                        taken[m] = 0;
                        if (!a.solid_at(lc[0], lc[1], lc[2])) {
                            continue;
                        }
                        const Vector3i local(base.x + lc[0], base.y + lc[1], base.z + lc[2]);
                        int32_t other = c.block_at(local + FACE_DIR[f]);
                        if (other == (int32_t)bi) {
                            continue; // buried inside this block; never visible
                        }
                        // A decorative neighbour reads as OPEN AIR here, and it
                        // has to. It owns its cells, so without this the floor
                        // under a chair bakes with `other` = the chair, and the
                        // draw rule (other < 0 || !alive[other]) then hides that
                        // floor for as long as the chair is alive -- a chair
                        // shaped hole in the floor it is standing on.
                        if (other >= 0 && c.blocks[other].decorative) {
                            other = -1;
                        }
                        mask[m] = other;
                        any = true;
                    }
                }
                if (!any) {
                    continue;
                }

                // Greedy rectangles over cells that agree about `other`.
                for (int ai = 0; ai < an; ++ai) {
                    for (int bj = 0; bj < bn; ++bj) {
                        const size_t m0 = (size_t)ai * bn + bj;
                        if (taken[m0] || mask[m0] == NO_FACE) {
                            continue;
                        }
                        const int32_t other = mask[m0];

                        int b1 = bj;
                        while (b1 + 1 < bn) {
                            const size_t m = (size_t)ai * bn + (b1 + 1);
                            if (taken[m] || mask[m] != other) {
                                break;
                            }
                            ++b1;
                        }
                        int a1 = ai;
                        while (a1 + 1 < an) {
                            bool row_ok = true;
                            for (int bb = bj; bb <= b1; ++bb) {
                                const size_t m = (size_t)(a1 + 1) * bn + bb;
                                if (taken[m] || mask[m] != other) {
                                    row_ok = false;
                                    break;
                                }
                            }
                            if (!row_ok) {
                                break;
                            }
                            ++a1;
                        }
                        for (int aa = ai; aa <= a1; ++aa) {
                            for (int bb = bj; bb <= b1; ++bb) {
                                taken[(size_t)aa * bn + bb] = 1;
                            }
                        }

                        // One quad for the whole rectangle. A corner offset of 0
                        // on an in-plane axis takes the rectangle's low edge and
                        // 1 takes its high edge, which is the same rule the
                        // single-cell version used with a1 == ai.
                        for (int k = 0; k < 4; ++k) {
                            const Vector3i o = FACE_CORNERS[f][k];
                            const int oc[3] = { o.x, o.y, o.z };
                            int cell[3];
                            cell[sa] = si + oc[sa];
                            cell[pa] = (oc[pa] == 0) ? ai : (a1 + 1);
                            cell[pb] = (oc[pb] == 0) ? bj : (b1 + 1);
                            const Vector3 vp(
                                (base.x + cell[0]) * cs.x,
                                (base.y + cell[1]) * cs.y,
                                (base.z + cell[2]) * cs.z);
                            const Vector3 rel = vp - block_origin;

                            Vector2 uv;
                            switch (f) {
                                case 0: case 1: uv = Vector2(rel.z, rel.y); break;
                                case 2: case 3: uv = Vector2(rel.x, rel.z); break;
                                default:        uv = Vector2(rel.x, rel.y); break;
                            }

                            fb.verts.push_back(vp);
                            fb.normals.push_back(FACE_NORMAL[f]);
                            fb.colours.push_back(col);
                            fb.uvs.push_back(uv);
                            fb.uv2s.push_back(face_size);
                        }
                        fb.owner.push_back((int32_t)bi);
                        fb.other.push_back(other);
                    }
                }
            }
        }
    }

    fb.valid = true;
    fb.bake_ms = std::chrono::duration<double, std::milli>(
            std::chrono::steady_clock::now() - t0).count();
}

void BrickWorld::bake_chunk_faces(Chunk &c) {
    bake_faces_into(c, archetypes, c.bake);
}

BrickWorld::BakeJob *BrickWorld::find_bake_job(int chunk_id) {
    for (auto &j : bake_jobs) {
        if (j->chunk_id == chunk_id) {
            return j.get();
        }
    }
    return nullptr;
}

bool BrickWorld::bake_pending(int chunk_id) const {
    for (const auto &j : bake_jobs) {
        if (j->chunk_id == chunk_id) {
            return true;
        }
    }
    return false;
}

int BrickWorld::bakes_in_flight() const {
    return (int)bake_jobs.size();
}

void BrickWorld::settle_bake_job(int chunk_id, bool adopt) {
    for (size_t i = 0; i < bake_jobs.size(); ++i) {
        if (bake_jobs[i]->chunk_id != chunk_id) {
            continue;
        }
        BakeJob *job = bake_jobs[i].get();
        if (job->worker.joinable()) {
            job->worker.join();
        }
        if (adopt && valid_chunk(chunk_id)) {
            chunks[chunk_id].bake = std::move(job->bake);
            stats[chunk_id].bake_ms = chunks[chunk_id].bake.bake_ms;
            stats[chunk_id].baked_faces = chunks[chunk_id].bake.face_count();
        }
        bake_jobs.erase(bake_jobs.begin() + (long)i);
        return;
    }
}

void BrickWorld::drop_chunk_bake(int chunk_id) {
    if (!valid_chunk(chunk_id)) {
        return;
    }
    settle_bake_job(chunk_id, false);
    chunks[chunk_id].bake = FaceBake();
    chunks[chunk_id].live_indices = PackedInt32Array();
    stats[chunk_id].baked_faces = 0;
}

void BrickWorld::bake_chunk_async(int chunk_id) {
    if (!valid_chunk(chunk_id) || chunks[chunk_id].bake.valid || bake_pending(chunk_id)) {
        return;
    }
    auto job = std::make_unique<BakeJob>();
    job->chunk_id = chunk_id;
    // The palette is copied rather than shared: baking a new archetype on the
    // main thread would otherwise reallocate underneath the worker.
    job->parts = archetypes;
    BakeJob *raw = job.get();
    const Chunk *cp = &chunks[chunk_id]; // stable: chunks is a deque
    raw->worker = std::thread([raw, cp]() {
        bake_faces_into(*cp, raw->parts, raw->bake);
        raw->done.store(true, std::memory_order_release);
    });
    bake_jobs.push_back(std::move(job));
}

bool BrickWorld::bake_ready(int chunk_id) {
    if (!valid_chunk(chunk_id)) {
        return false;
    }
    if (chunks[chunk_id].bake.valid) {
        return true;
    }
    BakeJob *job = find_bake_job(chunk_id);
    if (job == nullptr) {
        return false;
    }
    if (!job->done.load(std::memory_order_acquire)) {
        return false;
    }
    settle_bake_job(chunk_id, true);
    return true;
}

void BrickWorld::set_chunk_gravity(int chunk_id, Vector3i down) {
    if (!valid_chunk(chunk_id)) {
        return;
    }
    // Snap to the dominant axis: a grid has six downs, not infinitely many.
    Vector3i axis(0, -1, 0);
    const int ax = std::abs(down.x);
    const int ay = std::abs(down.y);
    const int az = std::abs(down.z);
    if (ax >= ay && ax >= az && ax > 0) {
        axis = Vector3i(down.x > 0 ? 1 : -1, 0, 0);
    } else if (az >= ay && az > 0) {
        axis = Vector3i(0, 0, down.z > 0 ? 1 : -1);
    } else if (ay > 0) {
        axis = Vector3i(0, down.y > 0 ? 1 : -1, 0);
    }
    chunk_down[chunk_id] = axis;

    // The foundation is whatever is lowest along the new down. Without this the
    // chunk would still be anchored to the face it stood on before it fell.
    const Vector3i up = -axis;
    const Chunk &c = chunks[chunk_id];
    bool any = false;
    int lowest = 0;
    for (const Block &b : c.blocks) {
        if (!b.alive) {
            continue;
        }
        const int hh = height_along(b.cell, up);
        if (!any || hh < lowest) {
            lowest = hh;
            any = true;
        }
    }
    foundation_level[chunk_id] = any ? lowest : 0;
}

Vector3i BrickWorld::get_chunk_gravity(int chunk_id) const {
    return valid_chunk(chunk_id) ? chunk_down[chunk_id] : Vector3i(0, -1, 0);
}

/// Every solid cell of every living block, greedily merged into as few boxes as
/// possible. Block identity is deliberately ignored: this is for pieces that
/// have stopped moving and will not be damaged until something hits them, at
/// which point the caller rebuilds per block.
Dictionary BrickWorld::add_merged_shapes(RID body, int chunk_id, Vector3 offset) {
    Dictionary out;
    PhysicsServer3D *ps = PhysicsServer3D::get_singleton();
    const Chunk &c = chunks[chunk_id];
    const Vector3i d = c.dims;
    const Vector3 cs = cell_size();
    const int64_t n = (int64_t)d.x * d.y * d.z;
    if (n <= 0) {
        out["map"] = Dictionary();
        out["count"] = 0;
        out["merged"] = true;
        return out;
    }

    std::vector<uint8_t> solid((size_t)n, 0);
    for (const Block &b : c.blocks) {
        if (!b.alive) {
            continue;
        }
        const Archetype &a = archetypes[b.archetype];
        const Vector3i base = b.cell - c.origin;
        for (int lx = 0; lx < a.size.x; ++lx) {
            for (int ly = 0; ly < a.size.y; ++ly) {
                for (int lz = 0; lz < a.size.z; ++lz) {
                    if (!a.solid_at(lx, ly, lz)) {
                        continue;
                    }
                    const int x = base.x + lx, y = base.y + ly, z = base.z + lz;
                    if (x < 0 || y < 0 || z < 0 || x >= d.x || y >= d.y || z >= d.z) {
                        continue;
                    }
                    solid[(size_t)((int64_t)x + (int64_t)d.x * ((int64_t)y + (int64_t)d.y * z))] = 1;
                }
            }
        }
    }

    auto at = [&](int x, int y, int z) -> uint8_t & {
        return solid[(size_t)((int64_t)x + (int64_t)d.x * ((int64_t)y + (int64_t)d.y * z))];
    };

    int count = 0;
    for (int z = 0; z < d.z; ++z) {
        for (int y = 0; y < d.y; ++y) {
            for (int x = 0; x < d.x; ++x) {
                if (!at(x, y, z)) {
                    continue;
                }
                int x1 = x;
                while (x1 + 1 < d.x && at(x1 + 1, y, z)) {
                    ++x1;
                }
                int y1 = y;
                while (y1 + 1 < d.y) {
                    bool row = true;
                    for (int xx = x; xx <= x1 && row; ++xx) {
                        row = at(xx, y1 + 1, z) != 0;
                    }
                    if (!row) {
                        break;
                    }
                    ++y1;
                }
                int z1 = z;
                while (z1 + 1 < d.z) {
                    bool plane = true;
                    for (int yy = y; yy <= y1 && plane; ++yy) {
                        for (int xx = x; xx <= x1 && plane; ++xx) {
                            plane = at(xx, yy, z1 + 1) != 0;
                        }
                    }
                    if (!plane) {
                        break;
                    }
                    ++z1;
                }
                for (int zz = z; zz <= z1; ++zz) {
                    for (int yy = y; yy <= y1; ++yy) {
                        for (int xx = x; xx <= x1; ++xx) {
                            at(xx, yy, zz) = 0;
                        }
                    }
                }

                const Vector3 size((x1 - x + 1) * cs.x, (y1 - y + 1) * cs.y, (z1 - z + 1) * cs.z);
                const Vector3 centre(
                        (x + (x1 - x + 1) * 0.5f) * cs.x,
                        (y + (y1 - y + 1) * 0.5f) * cs.y,
                        (z + (z1 - z + 1) * 0.5f) * cs.z);
                ps->body_add_shape(body, box_shape_for(size),
                        Transform3D(Basis(), centre - offset));
                ++count;
            }
        }
    }

    out["map"] = Dictionary();
    out["count"] = count;
    out["merged"] = true;
    return out;
}

RID BrickWorld::box_shape_for(const Vector3 &size) {
    const Vector3i key(
            (int)llround(size.x * 10000.0),
            (int)llround(size.y * 10000.0),
            (int)llround(size.z * 10000.0));
    auto it = box_shapes.find(key);
    if (it != box_shapes.end()) {
        return it->second;
    }
    PhysicsServer3D *ps = PhysicsServer3D::get_singleton();
    const RID rid = ps->box_shape_create();
    ps->shape_set_data(rid, size * 0.5f);
    box_shapes[key] = rid;
    return rid;
}

Dictionary BrickWorld::add_chunk_shapes(RID body, int chunk_id, Vector3 offset, bool skip_dead,
        bool merge) {
    Dictionary out;
    if (!valid_chunk(chunk_id)) {
        return out;
    }
    PhysicsServer3D *ps = PhysicsServer3D::get_singleton();
    const Chunk &c = chunks[chunk_id];

    if (merge) {
        return add_merged_shapes(body, chunk_id, offset);
    }

    Dictionary map;
    int next = 0;
    for (size_t bi = 0; bi < c.blocks.size(); ++bi) {
        const Block &b = c.blocks[bi];
        if (b.removed || (skip_dead && !b.alive)) {
            continue;
        }
        const Archetype &a = archetypes[b.archetype];
        PackedInt32Array mine;
        if (a.is_full_box()) {
            Vector3 centre, size;
            block_extent(c, b, centre, size);
            ps->body_add_shape(body, box_shape_for(size),
                    Transform3D(Basis(), centre - offset));
            mine.push_back(next);
            if (!b.alive) {
                ps->body_set_shape_disabled(body, next, true);
            }
            ++next;
        } else {
            // A masked part collides as one box per solid cell.
            const Vector3 cs = cell_size();
            const Vector3i base = b.cell - c.origin;
            for (int lx = 0; lx < a.size.x; ++lx) {
                for (int ly = 0; ly < a.size.y; ++ly) {
                    for (int lz = 0; lz < a.size.z; ++lz) {
                        if (!a.solid_at(lx, ly, lz)) {
                            continue;
                        }
                        const Vector3 centre(
                                (base.x + lx + 0.5f) * cs.x,
                                (base.y + ly + 0.5f) * cs.y,
                                (base.z + lz + 0.5f) * cs.z);
                        ps->body_add_shape(body, box_shape_for(cs),
                                Transform3D(Basis(), centre - offset));
                        mine.push_back(next);
                        if (!b.alive) {
                            ps->body_set_shape_disabled(body, next, true);
                        }
                        ++next;
                    }
                }
            }
        }
        if (mine.size() > 0) {
            map[(int)bi] = mine;
        }
    }
    out["map"] = map;
    out["count"] = next;
    return out;
}

int64_t BrickWorld::get_chunk_content_hash(int chunk_id) const {
    if (!valid_chunk(chunk_id)) {
        return 0;
    }
    const Chunk &c = chunks[chunk_id];
    // Sort by cell so the hash does not depend on the order blocks were added.
    std::vector<std::pair<Vector3i, int32_t>> parts;
    parts.reserve(c.blocks.size());
    for (const Block &b : c.blocks) {
        if (b.alive) {
            parts.push_back({b.cell, b.archetype});
        }
    }
    std::sort(parts.begin(), parts.end(),
            [](const std::pair<Vector3i, int32_t> &a, const std::pair<Vector3i, int32_t> &b) {
                if (a.first.x != b.first.x) return a.first.x < b.first.x;
                if (a.first.y != b.first.y) return a.first.y < b.first.y;
                if (a.first.z != b.first.z) return a.first.z < b.first.z;
                return a.second < b.second;
            });

    // FNV-1a over the sorted integers. Integer in, integer out: no float ever
    // touches this, so it is identical on every machine.
    uint64_t h = 1469598103934665603ULL;
    auto mix = [&h](int32_t v) {
        for (int i = 0; i < 4; ++i) {
            h ^= (uint64_t)((v >> (i * 8)) & 0xFF);
            h *= 1099511628211ULL;
        }
    };
    for (const auto &p : parts) {
        mix(p.first.x);
        mix(p.first.y);
        mix(p.first.z);
        mix(p.second);
    }
    return (int64_t)(h & 0x7FFFFFFFFFFFFFFFULL);
}

float BrickWorld::get_chunk_mass(int chunk_id) const {
    if (!valid_chunk(chunk_id)) {
        return 0.0f;
    }
    float total = 0.0f;
    for (const Block &b : chunks[chunk_id].blocks) {
        if (b.alive) {
            total += std::max(archetypes[b.archetype].mass, 0.0001f);
        }
    }
    return total;
}

BrickWorld::~BrickWorld() {
    for (auto &j : bake_jobs) {
        if (j->worker.joinable()) {
            j->worker.join();
        }
    }
    PhysicsServer3D *ps = PhysicsServer3D::get_singleton();
    if (ps != nullptr) {
        for (auto &kv : box_shapes) {
            ps->free_rid(kv.second);
        }
    }
    box_shapes.clear();
}

void BrickWorld::fill_indices(Chunk &c, MeshStats &st, PackedInt32Array &out) {
    const FaceBake &fb = c.bake;
    const int faces = fb.face_count();
    out.resize((int64_t)faces * 6);
    int32_t *w = out.ptrw();

    // Faces were baked block by block, so a block's faces are contiguous here,
    // which keeps the per-block index range meaningful.
    int32_t current = -1;
    for (int f = 0; f < faces; ++f) {
        const int32_t owner = fb.owner[f];
        if (owner != current) {
            if (current >= 0) {
                c.blocks[current].index_count = f * 6 - c.blocks[current].index_start;
            }
            current = owner;
            c.blocks[current].index_start = f * 6;
        }

        const int32_t other = fb.other[f];
        const bool drawn = c.blocks[owner].alive
                && (other < 0 || !c.blocks[other].alive);

        const int base = f * 6;
        if (drawn) {
            ++st.faces_emitted;
            const int v0 = f * 4;
            w[base + 0] = v0 + 0;
            w[base + 1] = v0 + 1;
            w[base + 2] = v0 + 2;
            w[base + 3] = v0 + 1;
            w[base + 4] = v0 + 3;
            w[base + 5] = v0 + 2;
        } else {
            ++st.faces_culled;
            // Degenerate: zero area, discarded by the rasteriser. Keeping the
            // slot means the buffer length never changes, which is the whole
            // reason the surface can be patched instead of rebuilt.
            for (int k = 0; k < 6; ++k) {
                w[base + k] = 0;
            }
        }
    }
    if (current >= 0) {
        c.blocks[current].index_count = faces * 6 - c.blocks[current].index_start;
    }
}

Dictionary BrickWorld::get_memory_report() const {
    Dictionary d;
    int64_t occupancy = 0, blocks = 0, bake_verts = 0, bake_topology = 0, indices = 0;
    int live = 0, baked = 0, total_blocks = 0, total_faces = 0;

    for (size_t i = 0; i < chunks.size(); ++i) {
        if (!chunk_live[i]) {
            continue;
        }
        ++live;
        const Chunk &c = chunks[i];
        occupancy += (int64_t)c.occupancy.size() * sizeof(int32_t);
        blocks += (int64_t)c.blocks.size() * sizeof(Block);
        total_blocks += (int)c.blocks.size();

        if (c.bake.valid) {
            ++baked;
            const int64_t faces = c.bake.face_count();
            total_faces += (int)faces;
            // 4 verts per face: position, normal, colour, uv, uv2
            bake_verts += faces * 4 * (int64_t)(sizeof(Vector3) * 2 + sizeof(Color)
                    + sizeof(Vector2) * 2);
            bake_topology += faces * 2 * (int64_t)sizeof(int32_t);
        }
        indices += (int64_t)c.live_indices.size() * sizeof(int32_t);
    }

    const int64_t total = occupancy + blocks + bake_verts + bake_topology + indices;
    d["chunks"] = live;
    d["chunks_baked"] = baked;
    d["blocks"] = total_blocks;
    d["baked_faces"] = total_faces;
    d["occupancy_bytes"] = occupancy;
    d["block_bytes"] = blocks;
    d["bake_vertex_bytes"] = bake_verts;
    d["bake_topology_bytes"] = bake_topology;
    d["index_bytes"] = indices;
    d["total_bytes"] = total;
    d["bytes_per_block"] = total_blocks > 0 ? (double)total / total_blocks : 0.0;
    return d;
}

Dictionary BrickWorld::update_index_region(int chunk_id, int index_bytes) {
    Dictionary out;
    if (!valid_chunk(chunk_id)) {
        return out;
    }
    Chunk &c = chunks[chunk_id];
    if (!c.bake.valid || c.live_indices.is_empty()) {
        return out; // nothing has been built yet; caller must build first
    }

    const auto t0 = std::chrono::steady_clock::now();
    MeshStats &st = stats[chunk_id];
    st.faces_emitted = 0;
    st.faces_culled = 0;

    PackedInt32Array next;
    fill_indices(c, st, next);

    const int n = next.size();
    const int32_t *a = c.live_indices.ptr();
    const int32_t *b = next.ptr();

    int first = -1;
    int last = -1;
    for (int i = 0; i < n; ++i) {
        if (a[i] != b[i]) {
            if (first < 0) {
                first = i;
            }
            last = i;
        }
    }
    c.live_indices = next;

    st.indices = n;
    st.compact_ms = std::chrono::duration<double, std::milli>(
            std::chrono::steady_clock::now() - t0).count();

    if (first < 0) {
        out["changed_bytes"] = 0;
        out["drawn_faces"] = st.faces_emitted;
        out["update_ms"] = st.compact_ms;
        return out; // nothing moved; no upload needed at all
    }

    // Only the span that actually changed crosses to the renderer. Crushing a
    // handful of blocks touches a narrow band of faces, so this is usually a
    // few kilobytes against a vertex buffer of tens of megabytes.
    const int count = last - first + 1;
    const int width = (index_bytes == 2) ? 2 : 4;
    PackedByteArray data;
    data.resize((int64_t)count * width);
    if (width == 4) {
        memcpy(data.ptrw(), b + first, (size_t)count * 4);
    } else {
        // A 16-bit surface only exists when every index fits in 16 bits, so
        // this narrowing is lossless by construction.
        uint16_t *w16 = reinterpret_cast<uint16_t *>(data.ptrw());
        for (int i = 0; i < count; ++i) {
            w16[i] = (uint16_t)b[first + i];
        }
    }

    out["offset"] = first * width;
    out["data"] = data;
    out["changed_bytes"] = count * width;
    out["drawn_faces"] = st.faces_emitted;
    out["update_ms"] = st.compact_ms;
    return out;
}

Array BrickWorld::build_chunk_mesh(int chunk_id) {
    if (!valid_chunk(chunk_id)) {
        return Array();
    }
    Chunk &c = chunks[chunk_id];
    MeshStats &st = stats[chunk_id];
    st = MeshStats();

    if (!c.bake.valid) {
        bake_chunk_faces(c);
    }
    st.bake_ms = c.bake.bake_ms;
    st.baked_faces = c.bake.face_count();

    fill_indices(c, st, c.live_indices);
    st.vertices = c.bake.verts.size();
    st.indices = c.live_indices.size();
    for (const Block &b : c.blocks) {
        if (b.alive) {
            ++st.blocks_meshed;
        }
    }

    if (c.live_indices.is_empty()) {
        return Array();
    }

    Array arrays;
    arrays.resize(Mesh::ARRAY_MAX);
    arrays[Mesh::ARRAY_VERTEX] = c.bake.verts;
    arrays[Mesh::ARRAY_NORMAL] = c.bake.normals;
    arrays[Mesh::ARRAY_COLOR] = c.bake.colours;
    arrays[Mesh::ARRAY_TEX_UV] = c.bake.uvs;
    arrays[Mesh::ARRAY_TEX_UV2] = c.bake.uv2s;
    arrays[Mesh::ARRAY_INDEX] = c.live_indices;
    return arrays;
}

Array BrickWorld::build_mesh_internal(Chunk &c, MeshStats &st,
        const std::vector<uint8_t> *mask, const Vector3 &offset, bool write_ranges) {
    Array arrays;

    PackedVector3Array verts;
    PackedVector3Array normals;
    PackedColorArray colours;
    PackedVector2Array uvs;  // metres from the block's face origin
    PackedVector2Array uv2s; // the block's face size in metres
    PackedInt32Array indices;

    const Vector3 cs = cell_size();

    // A cell blocks a face only if it holds a live block that is also part of
    // whatever we are meshing. Inside a detached group that means the break
    // surface gets faces, because the blocks it tore away from are outside the
    // mask.
    auto occludes = [&](const Vector3i &l) -> bool {
        const int32_t nb = c.block_at(l);
        if (nb < 0 || !c.blocks[nb].alive) {
            return false;
        }
        return mask == nullptr || (*mask)[nb] != 0;
    };

    for (size_t bi = 0; bi < c.blocks.size(); ++bi) {
        Block &b = c.blocks[bi];
        if (write_ranges) {
            b.index_start = (int32_t)indices.size();
            b.index_count = 0;
        }
        if (!b.alive || (mask != nullptr && (*mask)[bi] == 0)) {
            continue;
        }
        ++st.blocks_meshed;

        const Vector3i asize = archetypes[b.archetype].size;
        const Vector3i base = b.cell - c.origin;
        const Color col = filament_colour(b.colour);

        // Where this block starts, in chunk-local metres. Every face vertex is
        // written relative to it so the shader can find the BLOCK's outline --
        // not the cell's. Without that, a run of same-coloured blocks culls its
        // seams away and reads as one flat slab.
        const Vector3 block_origin(base.x * cs.x, base.y * cs.y, base.z * cs.z);

        const Archetype &arch = archetypes[b.archetype];
        for (int lx = 0; lx < asize.x; ++lx) {
            for (int ly = 0; ly < asize.y; ++ly) {
                for (int lz = 0; lz < asize.z; ++lz) {
                    if (!arch.solid_at(lx, ly, lz)) {
                        continue; // a masked-out cell of a shaped part
                    }
                    const Vector3i local(base.x + lx, base.y + ly, base.z + lz);

                    for (int f = 0; f < 6; ++f) {
                        // Interior faces go away: a face exists only where the
                        // neighbouring cell is empty or dead. That covers both
                        // a block's own interior and the seam between two
                        // touching blocks (spec section 6).
                        if (occludes(local + FACE_DIR[f])) {
                            ++st.faces_culled;
                            continue;
                        }
                        ++st.faces_emitted;

                        // Which two axes lie in this face's plane, and how big
                        // the whole block is across them.
                        Vector2 face_size;
                        switch (f) {
                            case 0: case 1: face_size = Vector2(asize.z * cs.z, asize.y * cs.y); break;
                            case 2: case 3: face_size = Vector2(asize.x * cs.x, asize.z * cs.z); break;
                            default:        face_size = Vector2(asize.x * cs.x, asize.y * cs.y); break;
                        }

                        const int v0 = (int)verts.size();
                        for (int k = 0; k < 4; ++k) {
                            const Vector3i o = FACE_CORNERS[f][k];
                            const Vector3 vp(
                                (local.x + o.x) * cs.x,
                                (local.y + o.y) * cs.y,
                                (local.z + o.z) * cs.z);
                            const Vector3 rel = vp - block_origin;

                            Vector2 uv;
                            switch (f) {
                                case 0: case 1: uv = Vector2(rel.z, rel.y); break;
                                case 2: case 3: uv = Vector2(rel.x, rel.z); break;
                                default:        uv = Vector2(rel.x, rel.y); break;
                            }

                            verts.push_back(vp - offset);
                            normals.push_back(FACE_NORMAL[f]);
                            colours.push_back(col);
                            uvs.push_back(uv);
                            uv2s.push_back(face_size);
                        }

                        indices.push_back(v0 + 0);
                        indices.push_back(v0 + 1);
                        indices.push_back(v0 + 2);
                        indices.push_back(v0 + 1);
                        indices.push_back(v0 + 3);
                        indices.push_back(v0 + 2);
                        if (write_ranges) {
                            b.index_count += 6;
                        }
                    }
                }
            }
        }
    }

    st.vertices = (int)verts.size();
    st.indices = (int)indices.size();

    if (verts.is_empty()) {
        return arrays; // nothing visible; caller skips the surface
    }

    arrays.resize(Mesh::ARRAY_MAX);
    arrays[Mesh::ARRAY_VERTEX] = verts;
    arrays[Mesh::ARRAY_NORMAL] = normals;
    arrays[Mesh::ARRAY_COLOR] = colours;
    arrays[Mesh::ARRAY_TEX_UV] = uvs;
    arrays[Mesh::ARRAY_TEX_UV2] = uv2s;
    arrays[Mesh::ARRAY_INDEX] = c.live_indices;
    return arrays;
}

Dictionary BrickWorld::get_mesh_stats(int chunk_id) const {
    Dictionary d;
    if (!valid_chunk(chunk_id)) {
        return d;
    }
    const MeshStats &st = stats[chunk_id];
    const int total = st.faces_emitted + st.faces_culled;
    d["faces_emitted"] = st.faces_emitted;
    d["faces_culled"] = st.faces_culled;
    d["faces_total"] = total;
    d["cull_ratio"] = total > 0 ? (double)st.faces_culled / (double)total : 0.0;
    d["vertices"] = st.vertices;
    d["indices"] = st.indices;
    // DRAWN triangles. The index buffer is a fixed length with hidden faces
    // written as degenerates, so its size is not a triangle count.
    d["triangles"] = st.faces_emitted * 2;
    d["index_slots"] = st.indices;
    d["degenerate_triangles"] = st.faces_culled * 2;
    d["blocks_meshed"] = st.blocks_meshed;
    d["baked_faces"] = st.baked_faces;
    d["bake_ms"] = st.bake_ms;
    d["compact_ms"] = st.compact_ms;
    return d;
}

// --- connectivity ----------------------------------------------------------
//
// Spec section 5: bricks are nodes, STUD connections are edges. Two blocks are
// joined when their footprints overlap in XZ and one sits directly on the
// other. Two blocks side by side in the same course are NOT joined, which is
// exactly why a running bond holds a wall together and a stack of loose bricks
// does not.
//
// The edge list is never stored. The occupancy grid already answers the
// question in a handful of integer lookups, and a derived graph cannot go stale
// when a block dies.

/// Is there a stud joint in world column (wx, wz) between the block below and
/// the block above? The lower part has to offer a stud there and the upper part
/// has to accept one. A tile offers none, so nothing clips to its top -- which
/// is a structural fact, not a decorative one.
static bool joint_exists(const Chunk &c, const std::vector<Archetype> &archetypes,
        int32_t lower, int32_t upper, int wx, int wz) {
    const Block &lb = c.blocks[lower];
    const Block &ub = c.blocks[upper];
    const Archetype &la = archetypes[lb.archetype];
    const Archetype &ua = archetypes[ub.archetype];
    return Archetype::faces_mate(
            ua.down_at(wx - ub.cell.x, wz - ub.cell.z),
            la.up_at(wx - lb.cell.x, wz - lb.cell.z));
}

/// Every stud joint this block has, fired once PER SHARED CELL -- so counting
/// the calls gives the contact area, and sharing load equally per call shares
/// it by area.
///
/// Walks the block's own solid cells rather than the top and bottom faces of
/// its bounding box, because a masked part has neither. An interior cell's
/// neighbour is the block itself and is skipped, so only real boundaries fire.
template <typename F>
static void for_each_neighbour(const Chunk &c, const std::vector<Archetype> &archetypes,
        int32_t bid, F &&fn) {
    const Block &b = c.blocks[bid];
    const Vector3i base = b.cell - c.origin;
    const Archetype &a = archetypes[b.archetype];

    for (const Archetype::SurfaceCell &sc : a.top_cells) {
        const int32_t up = c.block_at(Vector3i(base.x + sc.x, base.y + sc.y + 1, base.z + sc.z));
        // The block above owns the joint between them, so its bottom_broken
        // cuts this link too -- otherwise the walk would cross the seam going
        // up and not going down, and a cut would depend on where it started.
        if (up >= 0 && up != bid && c.blocks[up].alive && !c.blocks[up].bottom_broken
                && joint_exists(c, archetypes, bid, up, b.cell.x + sc.x, b.cell.z + sc.z)) {
            fn(up);
        }
    }
    if (b.bottom_broken) {
        return;
    }
    for (const Archetype::SurfaceCell &sc : a.bottom_cells) {
        const int32_t down = c.block_at(Vector3i(base.x + sc.x, base.y + sc.y - 1, base.z + sc.z));
        if (down >= 0 && down != bid && c.blocks[down].alive
                && joint_exists(c, archetypes, down, bid, b.cell.x + sc.x, b.cell.z + sc.z)) {
            fn(down);
        }
    }
}

PackedInt32Array BrickWorld::get_block_neighbours(int chunk_id, int block_id) const {
    PackedInt32Array out;
    if (!valid_chunk(chunk_id)) {
        return out;
    }
    const Chunk &c = chunks[chunk_id];
    if (block_id < 0 || block_id >= (int)c.blocks.size() || !c.blocks[block_id].alive) {
        return out;
    }
    // A wide block can meet the same neighbour over several cells, so dedupe.
    for_each_neighbour(c, archetypes, block_id, [&](int32_t n) {
        if (!out.has(n)) {
            out.push_back(n);
        }
    });
    return out;
}

// Can grounding travel from `from` to `to`?
//
// Two rules, and both are about interiors (Block::decorative). Grounding is
// reachability from the foundation, so it is DIRECTED, and the direction is
// what these say.
//
//   * Grounding never leaves an interior for structure. A chair is held up by
//     the floor it stands on; a wall is not held up by the chair. Without this
//     a room's furniture is a load path, and a section that should have fallen
//     hangs off the table in it -- which is exactly what it did.
//   * An interior block is grounded only from BELOW. Structure is not: undercut
//     a wall and its weight travels sideways to the corners that still stand,
//     which is the whole reason the support tree is a BFS rather than a
//     downward walk. Furniture has no such story. A chair whose floor has been
//     blown out from under it is falling, even if it is still touching a wall.
static inline bool grounding_flows(const Chunk &c, const std::vector<Archetype> &parts,
        int32_t from, int32_t to, const Vector3i &up) {
    const Block &a = c.blocks[from];
    const Block &b = c.blocks[to];
    // The overwhelming case, and this is the hottest loop in the solve: two
    // structural blocks, nothing to decide. Two bools before any arithmetic.
    if (!a.decorative && !b.decorative) {
        return true;
    }
    if (a.decorative && !b.decorative) {
        return false;
    }
    if (b.decorative && height_along(b.cell, up) <= height_along(a.cell, up)) {
        return false;
    }
    (void)parts;
    return true;
}

PackedByteArray BrickWorld::solve_grounded(int chunk_id) {
    PackedByteArray out;
    if (!valid_chunk(chunk_id)) {
        return out;
    }
    const auto t0 = std::chrono::steady_clock::now();

    Chunk &c = chunks[chunk_id];
    SolveStats &ss = solve_stats[chunk_id];
    ss = SolveStats();

    const size_t n = c.blocks.size();
    out.resize((int64_t)n);
    uint8_t *mark = out.ptrw();
    for (size_t i = 0; i < n; ++i) {
        mark[i] = 0;
    }

    scratch_queue.clear();
    scratch_queue.reserve(n);
    scratch_depth.assign(n, -1);

    // Seed from every live block resting on the foundation level. A block that
    // has been crushed loose is never a seed and is never reached.
    const int floor_y = foundation_level[chunk_id];
    const Vector3i up = -chunk_down[chunk_id];
    for (size_t i = 0; i < n; ++i) {
        const Block &b = c.blocks[i];
        if (b.alive && !b.support_broken && height_along(b.cell, up) <= floor_y) {
            mark[i] = 1;
            scratch_depth[i] = 0;
            scratch_queue.push_back((int32_t)i);
        }
    }

    for (size_t head = 0; head < scratch_queue.size(); ++head) {
        const int32_t bid = scratch_queue[head];
        ++ss.blocks_visited;
        const int32_t next_depth = scratch_depth[bid] + 1;
        for_each_neighbour(c, archetypes, bid, [&](int32_t nb) {
            if (mark[nb] != 0 || c.blocks[nb].support_broken) {
                return;
            }
            if (!grounding_flows(c, archetypes, bid, nb, up)) {
                return;
            }
            mark[nb] = 1;
            scratch_depth[nb] = next_depth;
            scratch_queue.push_back(nb);
        });
    }

    for (size_t i = 0; i < n; ++i) {
        if (!c.blocks[i].alive) {
            mark[i] = 0;
            continue;
        }
        if (mark[i]) {
            ++ss.grounded;
        } else {
            ++ss.ungrounded;
        }
    }

    ss.solve_ms = std::chrono::duration<double, std::milli>(
            std::chrono::steady_clock::now() - t0).count();
    return out;
}

Array BrickWorld::find_detached_groups(int chunk_id) {
    Array out;
    if (!valid_chunk(chunk_id)) {
        return out;
    }

    const PackedByteArray grounded = solve_grounded(chunk_id);
    Chunk &c = chunks[chunk_id];
    SolveStats &ss = solve_stats[chunk_id];

    const size_t n = c.blocks.size();
    scratch_mark.assign(n, 0);

    std::vector<PackedInt32Array> groups;
    for (size_t i = 0; i < n; ++i) {
        if (!c.blocks[i].alive || grounded[(int64_t)i] || scratch_mark[i]) {
            continue;
        }
        // Second fill, this time confined to the ungrounded set, so each island
        // of loose brick comes back as its own cluster.
        PackedInt32Array group;
        scratch_queue.clear();
        scratch_queue.push_back((int32_t)i);
        scratch_mark[i] = 1;
        for (size_t head = 0; head < scratch_queue.size(); ++head) {
            const int32_t bid = scratch_queue[head];
            group.push_back(bid);
            // No joint test here: an island is what falls together, and a
            // crushed block falls with whatever was resting on it.
            for_each_neighbour(c, archetypes, bid, [&](int32_t nb) {
                if (scratch_mark[nb] || grounded[(int64_t)nb]) {
                    return;
                }
                scratch_mark[nb] = 1;
                scratch_queue.push_back(nb);
            });
        }
        group.sort();
        groups.push_back(group);
    }

    // Largest first: a budgeted collapse should spend on the piece that matters.
    std::stable_sort(groups.begin(), groups.end(),
            [](const PackedInt32Array &a, const PackedInt32Array &b) {
                return a.size() > b.size();
            });

    for (const PackedInt32Array &g : groups) {
        out.push_back(g);
    }
    ss.groups = (int)groups.size();
    return out;
}

void BrickWorld::set_foundation_level(int chunk_id, int grid_y) {
    if (valid_chunk(chunk_id)) {
        foundation_level[chunk_id] = grid_y;
    }
}

Dictionary BrickWorld::get_solve_stats(int chunk_id) const {
    Dictionary d;
    if (!valid_chunk(chunk_id)) {
        return d;
    }
    const SolveStats &ss = solve_stats[chunk_id];
    d["blocks_visited"] = ss.blocks_visited;
    d["grounded"] = ss.grounded;
    d["ungrounded"] = ss.ungrounded;
    d["groups"] = ss.groups;
    d["solve_ms"] = ss.solve_ms;
    return d;
}

// --- stress ----------------------------------------------------------------
//
// Spec section 5 wants big chunks to hold together and then give way. This is
// the "give way" half: weight flows down the structure, a joint's strength
// comes from how much stud contact it has, and a joint asked to carry more than
// that breaks.
//
// The one subtlety worth stating: blocks are processed in descending grid Y.
// Load only ever moves downward, so by the time a block is reached every
// contribution to it has already been made and a single pass is exact. Ordering
// by BFS depth from the ground instead would be wrong -- a block can rest on
// two supporters at different depths, and the deeper one would be visited
// before it received anything.

Dictionary BrickWorld::solve_stress(int chunk_id) {
    Dictionary out;
    if (!valid_chunk(chunk_id)) {
        return out;
    }
    const auto t0 = std::chrono::steady_clock::now();

    // The support tree first. Load has to follow whatever is actually holding a
    // block up, which is not always what is underneath it: undercut a wall and
    // its weight travels sideways to the corners that still stand. An earlier
    // version flowed load strictly downward, so a wall hanging over a hole
    // transmitted nothing at all and the tower levitated.
    solve_grounded(chunk_id);
    const Vector3i up = -chunk_down[chunk_id];

    Chunk &c = chunks[chunk_id];
    StressState &sx = stress[chunk_id];
    const size_t n = c.blocks.size();

    for (size_t i = 0; i < n; ++i) {
        Block &b = c.blocks[i];
        // A decorative block weighs nothing HERE and only here. It still has
        // mass everywhere it matters -- the island it becomes is thrown by it --
        // but a chair is not a load case for the floor it stands on, and a
        // furnished tower must not be closer to collapse than an empty one.
        b.load = (b.alive && !b.decorative)
                ? std::max((int64_t)1, brick::to_mass_units(archetypes[b.archetype].mass))
                : (int64_t)0;
    }

    sx.max_ratio = 0.0f;
    sx.failures = 0;
    int64_t peak_load = 0;
    const int64_t capacity_per_stud = std::max(
            (int64_t)1, brick::to_mass_units(sx.tension_per_stud));
    PackedInt32Array separated;

    // Walk the BFS order backwards. BFS visits in nondecreasing depth, so in
    // reverse a block is reached only after everything deeper than it, and
    // since load moves strictly toward the ground one pass is exact.
    //
    // for_each_neighbour fires once per shared cell, so counting its calls
    // gives the stud contact -- and sharing the load equally per call shares it
    // by contact area.
    for (int i = (int)scratch_queue.size() - 1; i >= 0; --i) {
        const int32_t bid = scratch_queue[i];
        Block &b = c.blocks[bid];
        peak_load = std::max(peak_load, b.load);

        const int32_t depth = scratch_depth[bid];
        if (depth <= 0) {
            continue; // resting on the foundation, carried by the ground
        }

        // Split the supporting contact by which way the joint is loaded. A
        // supporter ABOVE this block is holding it up against gravity, which
        // is the only case that can fail: tension. A supporter below is in
        // compression, and compression is effectively unbreakable here.
        int contact = 0;
        int contact_tension = 0;
        const int my_height = height_along(b.cell, up);
        for_each_neighbour(c, archetypes, bid, [&](int32_t nb) {
            const int32_t nd = scratch_depth[nb];
            if (nd < 0 || nd >= depth) {
                return;
            }
            ++contact;
            if (height_along(c.blocks[nb].cell, up) > my_height) {
                ++contact_tension;
            }
        });
        if (contact == 0) {
            continue; // reached only through equal-depth peers; nothing to load
        }

        if (contact_tension > 0) {
            // Only the share carried by the upward joints is a pull. Both sides
            // are integers and the comparison is exact: no division, so no
            // rounding decides whether a joint fails.
            const int64_t pull = b.load * (int64_t)contact_tension;
            const int64_t capacity = (int64_t)contact_tension * capacity_per_stud
                    * (int64_t)contact;
            // Reported only, never decided on.
            sx.max_ratio = std::max(sx.max_ratio,
                    (float)((double)pull / (double)std::max((int64_t)1, capacity)));

            if (pull > capacity && !b.support_broken) {
                b.support_broken = true;
                separated.push_back(bid);
                ++sx.failures;
            }
        }

        // Share the load by contact area, and hand the remainder out one unit
        // at a time in neighbour order. Integer division alone would quietly
        // destroy load -- a tall building would get lighter the further down it
        // went -- and the remainder has to go somewhere fixed, not anywhere.
        const int64_t share = b.load / (int64_t)contact;
        int64_t remainder = b.load - share * (int64_t)contact;
        for_each_neighbour(c, archetypes, bid, [&](int32_t nb) {
            const int32_t nd = scratch_depth[nb];
            if (nd >= 0 && nd < depth) {
                int64_t give = share;
                if (remainder > 0) {
                    ++give;
                    --remainder;
                }
                c.blocks[nb].load += give;
            }
        });
    }

    // Nothing is destroyed. A released joint leaves both bricks whole -- the
    // piece simply stops being attached, and connectivity turns it into an
    // island on the next pass. See Docs/BrickFailure.md section 5.
    out["failures"] = sx.failures;
    out["separated"] = separated;
    out["max_ratio"] = sx.max_ratio;
    out["blocks_loaded"] = (int)scratch_queue.size();
    out["peak_load"] = (double)peak_load / (double)brick::MASS_FIXED;
    out["solve_ms"] = std::chrono::duration<double, std::milli>(
            std::chrono::steady_clock::now() - t0).count();
    return out;
}

int BrickWorld::set_blocks_decorative(int chunk_id, const PackedInt32Array &block_ids, bool on) {
    if (!valid_chunk(chunk_id)) {
        return 0;
    }
    Chunk &c = chunks[chunk_id];
    int changed = 0;
    for (int i = 0; i < block_ids.size(); ++i) {
        const int32_t bid = block_ids[i];
        if (bid < 0 || bid >= (int32_t)c.blocks.size()) {
            continue;
        }
        if (c.blocks[bid].decorative == on) {
            continue;
        }
        c.blocks[bid].decorative = on;
        ++changed;
    }
    // No bake invalidation: the role changes nothing about the geometry, the
    // faces or the colours. It is read by the solve and by nothing else.
    return changed;
}

bool BrickWorld::is_block_decorative(int chunk_id, int block_id) const {
    if (!valid_chunk(chunk_id)) {
        return false;
    }
    const Chunk &c = chunks[chunk_id];
    if (block_id < 0 || block_id >= (int)c.blocks.size()) {
        return false;
    }
    return c.blocks[block_id].decorative;
}

PackedInt32Array BrickWorld::get_decorative_blocks(int chunk_id) const {
    PackedInt32Array out;
    if (!valid_chunk(chunk_id)) {
        return out;
    }
    const Chunk &c = chunks[chunk_id];
    for (size_t i = 0; i < c.blocks.size(); ++i) {
        if (c.blocks[i].decorative && c.blocks[i].alive) {
            out.push_back((int32_t)i);
        }
    }
    return out;
}

void BrickWorld::set_tension_per_stud(int chunk_id, float capacity) {
    if (valid_chunk(chunk_id)) {
        stress[chunk_id].tension_per_stud = std::max(capacity, 0.0001f);
    }
}

float BrickWorld::get_tension_per_stud(int chunk_id) const {
    return valid_chunk(chunk_id) ? stress[chunk_id].tension_per_stud : 0.0f;
}

float BrickWorld::get_max_stress_ratio(int chunk_id) const {
    return valid_chunk(chunk_id) ? stress[chunk_id].max_ratio : 0.0f;
}

float BrickWorld::get_block_load(int chunk_id, int block_id) const {
    if (!valid_chunk(chunk_id)) {
        return 0.0f;
    }
    const Chunk &c = chunks[chunk_id];
    if (block_id < 0 || block_id >= (int)c.blocks.size()) {
        return 0.0f;
    }
    return (double)c.blocks[block_id].load / (double)brick::MASS_FIXED;
}

float BrickWorld::get_block_capacity(int chunk_id, int block_id) const {
    if (!valid_chunk(chunk_id)) {
        return 0.0f;
    }
    const Chunk &c = chunks[chunk_id];
    if (block_id < 0 || block_id >= (int)c.blocks.size()) {
        return 0.0f;
    }
    // Strength of everything that carried it in the last solve.
    if (block_id >= (int)scratch_depth.size() || scratch_depth[block_id] <= 0) {
        return 0.0f; // foundation, or never reached
    }
    const int32_t depth = scratch_depth[block_id];
    int contact_tension = 0;
    for_each_neighbour(c, archetypes, block_id, [&](int32_t nb) {
        const int32_t nd = scratch_depth[nb];
        const Vector3i up2 = -chunk_down[chunk_id];
        if (nd >= 0 && nd < depth
                && height_along(c.blocks[nb].cell, up2)
                        > height_along(c.blocks[block_id].cell, up2)) {
            ++contact_tension;
        }
    });
    return contact_tension * stress[chunk_id].tension_per_stud;
}

bool BrickWorld::is_support_broken(int chunk_id, int block_id) const {
    if (!valid_chunk(chunk_id)) {
        return false;
    }
    const Chunk &c = chunks[chunk_id];
    if (block_id < 0 || block_id >= (int)c.blocks.size()) {
        return false;
    }
    return c.blocks[block_id].support_broken;
}

// The convex hull of a set of points in the ground plane, anticlockwise.
//
// Monotone chain: sort, sweep the lower side, sweep the upper side. `pts` is
// consumed. Degenerate inputs come back as they are -- a single point stays a
// point and a straight line stays two ends -- which is what the caller wants,
// because a building standing on one foot is balanced on a point and a building
// standing on two is balanced on a line.
static std::vector<Vector2> ground_hull(std::vector<Vector2> &pts) {
    std::sort(pts.begin(), pts.end(), [](const Vector2 &a, const Vector2 &b) {
        return a.x != b.x ? a.x < b.x : a.y < b.y;
    });
    pts.erase(std::unique(pts.begin(), pts.end(), [](const Vector2 &a, const Vector2 &b) {
        return a.is_equal_approx(b);
    }), pts.end());
    const size_t n = pts.size();
    if (n < 3) {
        return pts;
    }
    auto cross = [](const Vector2 &o, const Vector2 &a, const Vector2 &b) -> float {
        return (a.x - o.x) * (b.y - o.y) - (a.y - o.y) * (b.x - o.x);
    };
    std::vector<Vector2> hull(2 * n);
    size_t k = 0;
    for (size_t i = 0; i < n; ++i) {
        while (k >= 2 && cross(hull[k - 2], hull[k - 1], pts[i]) <= 0.0f) {
            --k;
        }
        hull[k++] = pts[i];
    }
    for (size_t i = n - 1, t = k + 1; i > 0; --i) {
        while (k >= t && cross(hull[k - 2], hull[k - 1], pts[i - 1]) <= 0.0f) {
            --k;
        }
        hull[k++] = pts[i - 1];
    }
    hull.resize(k > 0 ? k - 1 : 0);
    return hull;
}

// How far outside the support polygon a point is, in metres. Negative inside.
//
// For a proper polygon this is the largest signed distance to any edge line,
// which for a convex anticlockwise hull is exactly "outside" when positive. A
// hull that came back as a segment or a point has no interior at all, so the
// answer is the plain distance to it -- and that is the case that matters for
// anything standing on legs.
static float hull_overhang(const std::vector<Vector2> &hull, const Vector2 &p) {
    if (hull.empty()) {
        return 1e9f;
    }
    if (hull.size() == 1) {
        return hull[0].distance_to(p);
    }
    if (hull.size() == 2) {
        const Vector2 ab = hull[1] - hull[0];
        const float len2 = ab.length_squared();
        if (len2 <= 0.0f) {
            return hull[0].distance_to(p);
        }
        const float t = std::clamp((p - hull[0]).dot(ab) / len2, 0.0f, 1.0f);
        return (hull[0] + ab * t).distance_to(p);
    }
    float worst = -1e9f;
    for (size_t i = 0; i < hull.size(); ++i) {
        const Vector2 a = hull[i];
        const Vector2 b = hull[(i + 1) % hull.size()];
        const Vector2 edge = b - a;
        const float len = edge.length();
        if (len <= 0.0f) {
            continue;
        }
        // Anticlockwise hull, so the interior is to the LEFT of every edge.
        const float side = ((p.x - a.x) * edge.y - (p.y - a.y) * edge.x) / len;
        worst = std::max(worst, side);
    }
    return worst;
}

Dictionary BrickWorld::check_stability(int chunk_id) {
    Dictionary out;
    if (!valid_chunk(chunk_id)) {
        return out;
    }
    // The grounding pass tells us what is still standing and what it rests on.
    solve_grounded(chunk_id);

    Chunk &c = chunks[chunk_id];
    const int floor_y = foundation_level[chunk_id];
    const Vector3 cs = cell_size();

    float total_mass = 0.0f;
    Vector3 weighted;
    PackedInt32Array standing;

    bool have_support = false;
    Vector2 support_min(0, 0);
    Vector2 support_max(0, 0);
    std::vector<Vector2> feet;

    for (size_t i = 0; i < c.blocks.size(); ++i) {
        const Block &b = c.blocks[i];
        if (!b.alive || scratch_depth[i] < 0) {
            continue; // gone, or already not connected to the ground
        }
        // In `standing` whatever its role: this list is what gets handed to
        // split_island, and furniture has to leave with the building it is
        // standing in (Docs/Interiors.md section 4.2).
        standing.push_back((int32_t)i);
        if (b.decorative) {
            continue; // not what the building is balanced on, nor balanced BY
        }

        Vector3 centre, size;
        block_extent(c, b, centre, size);
        const float m = std::max(archetypes[b.archetype].mass, 0.0001f);
        weighted += centre * m;
        total_mass += m;

        // What the building actually stands on: the blocks in contact with the
        // foundation. Every foot contributes the four corners of its footprint
        // and the support polygon is their convex hull.
        //
        // It was the bounding RECTANGLE of those corners, which is the same
        // thing for a building standing on its own outline and too generous for
        // one standing on legs: the rectangle claims every corner, including
        // the ones no leg is under.
        //
        // Measured on a four-legged deck, as overhang in metres -- negative is
        // standing, and tighter is the hull being stricter:
        //
        //     four legs              rect -2.02   hull -2.02
        //     one leg gone           rect -1.58   hull -1.23
        //     two gone, same side    rect +0.17   hull +0.17   (falls, both)
        //     two gone, diagonal     rect -1.97   hull -0.49
        //
        // So it is a tightening of up to a metre and a half rather than a
        // different verdict in any of those, and the verdicts it agrees with
        // are the right ones -- a deck on three legs with its mass in the
        // middle really is standing. What the hull buys is the case those are
        // one load away from: put weight over a corner no leg is under and the
        // rectangle still says it is supported.
        if (b.cell.y <= floor_y) {
            const Vector3i base = b.cell - c.origin;
            const Vector3i sz = archetypes[b.archetype].size;
            const Vector2 lo(base.x * cs.x, base.z * cs.z);
            const Vector2 hi((base.x + sz.x) * cs.x, (base.z + sz.z) * cs.z);
            feet.push_back(lo);
            feet.push_back(Vector2(hi.x, lo.y));
            feet.push_back(hi);
            feet.push_back(Vector2(lo.x, hi.y));
            if (!have_support) {
                support_min = lo;
                support_max = hi;
                have_support = true;
            } else {
                support_min = Vector2(std::min(support_min.x, lo.x), std::min(support_min.y, lo.y));
                support_max = Vector2(std::max(support_max.x, hi.x), std::max(support_max.y, hi.y));
            }
        }
    }

    if (total_mass <= 0.0f || standing.is_empty()) {
        out["stable"] = true;
        return out;
    }

    const Vector3 com = weighted / total_mass;
    bool stable = true;
    float overhang = 0.0f;

    std::vector<Vector2> hull;
    if (!have_support) {
        stable = false; // nothing touching the ground at all
        overhang = 1e9f;
    } else {
        hull = ground_hull(feet);
        overhang = hull_overhang(hull, Vector2(com.x, com.z));
        stable = overhang <= 0.0f;
    }

    out["stable"] = stable;
    out["com"] = com;
    out["support_min"] = support_min;
    out["support_max"] = support_max;
    // The polygon itself, for an overlay to draw and a probe to measure. The
    // rectangle above is kept because plenty of callers only want a rough box.
    PackedVector2Array poly;
    for (const Vector2 &v : hull) {
        poly.push_back(v);
    }
    out["support_hull"] = poly;
    out["overhang"] = overhang;
    out["blocks"] = standing;
    return out;
}

// --- damage ----------------------------------------------------------------

PackedInt32Array BrickWorld::apply_hit(int chunk_id, Vector3 world_point, float radius_m) {
    PackedInt32Array killed;
    if (!valid_chunk(chunk_id) || radius_m <= 0.0f) {
        return killed;
    }
    Chunk &c = chunks[chunk_id];
    const Vector3 cs = cell_size();

    // Walk the cells inside the blast's grid-space bounding box and test each
    // cell centre against the sphere. The radius is in metres, so the bite is
    // round in the world even though a cell is not a cube.
    // Through the chunk's own transform, so a tumbling island can be shot in
    // its own frame without anything upstream knowing it moved.
    const Vector3 centre_local = c.xform.affine_inverse().xform(world_point);
    const Vector3 r3(radius_m, radius_m, radius_m);
    const Vector3i lo = brick::world_to_grid(centre_local - r3);
    const Vector3i hi = brick::world_to_grid(centre_local + r3);
    const float r2 = radius_m * radius_m;

    for (int x = lo.x; x <= hi.x; ++x) {
        for (int y = lo.y; y <= hi.y; ++y) {
            for (int z = lo.z; z <= hi.z; ++z) {
                const Vector3i l(x, y, z);
                const int32_t bid = c.block_at(l);
                if (bid < 0 || !c.blocks[bid].alive) {
                    continue;
                }
                const Vector3 cell_centre((x + 0.5f) * cs.x, (y + 0.5f) * cs.y, (z + 0.5f) * cs.z);
                if (cell_centre.distance_squared_to(centre_local) > r2) {
                    continue;
                }
                c.blocks[bid].alive = false;
                c.blocks[bid].hp = 0;
                killed.push_back(bid);
            }
        }
    }

    // One block covers many cells, so the same id can land here repeatedly.
    killed.sort();
    int write = 0;
    for (int i = 0; i < killed.size(); ++i) {
        if (i == 0 || killed[i] != killed[i - 1]) {
            killed.set(write++, killed[i]);
        }
    }
    killed.resize(write);
    return killed;
}

PackedInt32Array BrickWorld::separate_near(int chunk_id, Vector3 world_point, float radius_m,
        int max_blocks, bool peel) {
    PackedInt32Array loosened;
    if (!valid_chunk(chunk_id) || radius_m <= 0.0f) {
        return loosened;
    }
    Chunk &c = chunks[chunk_id];
    const Vector3 cs = cell_size();

    struct Candidate {
        float d2;
        int32_t bid;
    };
    std::vector<Candidate> candidates;

    const Vector3 centre_local = c.xform.affine_inverse().xform(world_point);
    const Vector3 r3(radius_m, radius_m, radius_m);
    const Vector3i lo = brick::world_to_grid(centre_local - r3);
    const Vector3i hi = brick::world_to_grid(centre_local + r3);
    const float r2 = radius_m * radius_m;

    for (int x = lo.x; x <= hi.x; ++x) {
        for (int y = lo.y; y <= hi.y; ++y) {
            for (int z = lo.z; z <= hi.z; ++z) {
                const Vector3i l(x, y, z);
                const int32_t bid = c.block_at(l);
                if (bid < 0 || !c.blocks[bid].alive || c.blocks[bid].support_broken) {
                    continue;
                }
                const Vector3 cell_centre((x + 0.5f) * cs.x, (y + 0.5f) * cs.y, (z + 0.5f) * cs.z);
                if (cell_centre.distance_squared_to(centre_local) > r2) {
                    continue;
                }
                // Nearest-first, so a cap keeps what the impact actually
                // reached rather than whatever the sweep happened to visit
                // first. Marked below, once the set is final.
                candidates.push_back({cell_centre.distance_squared_to(centre_local), bid});
            }
        }
    }

    std::sort(candidates.begin(), candidates.end(),
            [](const Candidate &a, const Candidate &b) { return a.d2 < b.d2; });

    if (!peel) {
        int taken = 0;
        for (const Candidate &cand : candidates) {
            if (c.blocks[cand.bid].support_broken) {
                continue; // a block can appear once per cell it owns
            }
            if (max_blocks > 0 && taken >= max_blocks) {
                break;
            }
            // Loose, not gone.
            c.blocks[cand.bid].support_broken = true;
            loosened.push_back(cand.bid);
            ++taken;
        }
        loosened.sort();
        return loosened;
    }

    // PEEL: take the same set of blocks, then cut only along its UNDERSIDE.
    //
    // Marking every block in the ball support_broken isolates each one, and a
    // struck wall sprays individual bricks -- concrete, not a brick model. Here
    // the struck region keeps its own joints and is severed from what is under
    // it, so it comes away as one clump. What holds the clump together is the
    // running bond: a brick spanning several cells links the columns it covers,
    // exactly as it does in the real toy.
    //
    // A region cut free from below but still capped by intact wall above does
    // not fly off at all -- it hangs, the stress solve finds it unsupported,
    // and the cascade decides what falls. That is the intended outcome and the
    // reason this produces so much less debris than the old behaviour.
    std::vector<int32_t> chosen;
    chosen.reserve(candidates.size());
    for (const Candidate &cand : candidates) {
        if (max_blocks > 0 && (int)chosen.size() >= max_blocks) {
            break;
        }
        if (std::find(chosen.begin(), chosen.end(), cand.bid) != chosen.end()) {
            continue; // a block can appear once per cell it owns
        }
        chosen.push_back(cand.bid);
    }

    for (const int32_t bid : chosen) {
        Block &b = c.blocks[bid];
        if (b.bottom_broken) {
            continue;
        }
        // Is anything directly under this block also part of the clump? If so
        // the joint between them is internal and must survive.
        const Vector3i base = b.cell - c.origin;
        const Archetype &a = archetypes[b.archetype];
        bool rests_on_clump = false;
        for (const Archetype::SurfaceCell &sc : a.bottom_cells) {
            const int32_t down =
                    c.block_at(Vector3i(base.x + sc.x, base.y + sc.y - 1, base.z + sc.z));
            if (down >= 0 && down != bid && c.blocks[down].alive
                    && std::find(chosen.begin(), chosen.end(), down) != chosen.end()) {
                rests_on_clump = true;
                break;
            }
        }
        if (rests_on_clump) {
            continue;
        }
        b.bottom_broken = true;
        loosened.push_back(bid);
    }
    loosened.sort();
    return loosened;
}


PackedInt32Array BrickWorld::sever_seams(int chunk_id, PackedVector3Array world_points,
        Vector3 world_normal) {
    PackedInt32Array cut;
    if (!valid_chunk(chunk_id) || world_points.size() == 0) {
        return cut;
    }
    Chunk &c = chunks[chunk_id];
    const Transform3D inv = c.xform.affine_inverse();
    Vector3 n = inv.basis.xform(world_normal);
    if (n.length_squared() < 1e-8f) {
        return cut;
    }
    n.normalize();

    // Joints only exist vertically, so the only direction a clean seam can run
    // is across the chunk's own Y. For a toppled tower lying on its side that
    // is a horizontal world axis -- which is the whole point, because the break
    // wanted there is across the tower's length, and the tower's length IS its
    // local Y. A cut asked for along local X or Z has no joints to sever and is
    // refused here rather than faked; the caller falls back to a band.
    if (std::abs(n.y) < 0.8f) {
        return cut;
    }

    const float cy = cell_size().y;
    if (cy <= 0.0f) {
        return cut;
    }

    // Snap each cut to the nearest course boundary. A seam is between two
    // courses, never through one -- that is what makes it read as bricks coming
    // apart rather than bricks being cut in half.
    std::vector<int32_t> planes;
    for (int i = 0; i < world_points.size(); ++i) {
        const Vector3 local = inv.xform(world_points[i]);
        const int32_t k = (int32_t)llround((double)local.y / (double)cy);
        if (std::find(planes.begin(), planes.end(), k) == planes.end()) {
            planes.push_back(k);
        }
    }
    if (planes.empty()) {
        return cut;
    }

    for (size_t bi = 0; bi < c.blocks.size(); ++bi) {
        Block &b = c.blocks[bi];
        if (!b.alive || b.support_broken || b.bottom_broken) {
            continue;
        }
        const int32_t base_y = b.cell.y - c.origin.y;
        if (std::find(planes.begin(), planes.end(), base_y) != planes.end()) {
            b.bottom_broken = true;
            cut.push_back((int32_t)bi);
        }
    }
    return cut;
}

// --- detachment ------------------------------------------------------------

void BrickWorld::block_extent(const Chunk &c, const Block &b,
        Vector3 &out_centre, Vector3 &out_size) const {
    const Vector3 cs = cell_size();
    const Vector3i base = b.cell - c.origin;
    const Vector3i sz = archetypes[b.archetype].size;
    out_size = Vector3(sz.x * cs.x, sz.y * cs.y, sz.z * cs.z);
    out_centre = Vector3(base.x * cs.x, base.y * cs.y, base.z * cs.z) + out_size * 0.5f;
}

Dictionary BrickWorld::detach_group(int chunk_id, const PackedInt32Array &block_ids) {
    Dictionary out;
    if (!valid_chunk(chunk_id) || block_ids.is_empty()) {
        return out;
    }
    Chunk &c = chunks[chunk_id];
    const size_t n = c.blocks.size();

    std::vector<uint8_t> mask(n, 0);
    float total_mass = 0.0f;
    Vector3 weighted;
    int counted = 0;

    for (int i = 0; i < block_ids.size(); ++i) {
        const int32_t bid = block_ids[i];
        if (bid < 0 || bid >= (int32_t)n || !c.blocks[bid].alive) {
            continue;
        }
        mask[bid] = 1;
        Vector3 centre, size;
        block_extent(c, c.blocks[bid], centre, size);
        const float m = std::max(archetypes[c.blocks[bid].archetype].mass, 0.0001f);
        weighted += centre * m;
        total_mass += m;
        ++counted;
    }
    if (counted == 0) {
        return out;
    }

    const Vector3 com_local = weighted / total_mass;

    // Mesh first: once the blocks are marked detached they stop meshing, and
    // the group needs its geometry built while it is still part of the chunk.
    MeshStats group_stats;
    Array mesh = build_mesh_internal(c, group_stats, &mask, com_local, false);

    Array boxes;
    for (size_t i = 0; i < n; ++i) {
        if (!mask[i]) {
            continue;
        }
        Vector3 centre, size;
        block_extent(c, c.blocks[i], centre, size);
        Dictionary box;
        box["pos"] = centre - com_local;
        box["size"] = size;
        boxes.push_back(box);
    }

    PackedInt32Array taken;
    for (size_t i = 0; i < n; ++i) {
        if (mask[i]) {
            c.blocks[i].alive = false;
            c.blocks[i].detached = true;
            taken.push_back((int32_t)i);
        }
    }

    out["mesh"] = mesh;
    out["boxes"] = boxes;
    out["com"] = c.xform.xform(com_local);
    out["mass"] = total_mass;
    out["block_count"] = counted;
    out["block_ids"] = taken;
    out["faces"] = group_stats.faces_emitted;
    out["triangles"] = group_stats.indices / 3;
    return out;
}

// --- collision authoring ---------------------------------------------------

Array BrickWorld::get_block_boxes(int chunk_id) const {
    Array out;
    if (!valid_chunk(chunk_id)) {
        return out;
    }
    const Chunk &c = chunks[chunk_id];
    const Vector3 cs = cell_size();

    for (size_t i = 0; i < c.blocks.size(); ++i) {
        const Block &b = c.blocks[i];
        if (b.removed) {
            continue;
        }
        const Archetype &a = archetypes[b.archetype];
        const Vector3i base = b.cell - c.origin;

        if (a.is_full_box()) {
            Vector3 centre, size;
            block_extent(c, b, centre, size);
            Dictionary box;
            box["block"] = (int)i;
            box["pos"] = centre;
            box["size"] = size;
            box["alive"] = b.alive;
            out.push_back(box);
            continue;
        }

        // A shaped part collides as its occupied cells. One box per cell is
        // blunt but exact, and these parts are small; merging runs into larger
        // boxes is an optimisation, not a correctness matter.
        for (int x = 0; x < a.size.x; ++x) {
            for (int y = 0; y < a.size.y; ++y) {
                for (int z = 0; z < a.size.z; ++z) {
                    if (!a.solid_at(x, y, z)) {
                        continue;
                    }
                    Dictionary box;
                    box["block"] = (int)i;
                    box["pos"] = Vector3((base.x + x + 0.5f) * cs.x,
                            (base.y + y + 0.5f) * cs.y, (base.z + z + 0.5f) * cs.z);
                    box["size"] = cs;
                    box["alive"] = b.alive;
                    out.push_back(box);
                }
            }
        }
    }
    return out;
}

Dictionary BrickWorld::get_body_boxes(int chunk_id) const {
    Dictionary out;
    if (!valid_chunk(chunk_id)) {
        return out;
    }
    const Chunk &c = chunks[chunk_id];

    float total_mass = 0.0f;
    Vector3 weighted;
    for (const Block &b : c.blocks) {
        if (!b.alive) {
            continue;
        }
        Vector3 centre, size;
        block_extent(c, b, centre, size);
        const float m = std::max(archetypes[b.archetype].mass, 0.0001f);
        weighted += centre * m;
        total_mass += m;
    }
    const Vector3 com = total_mass > 0.0f ? weighted / total_mass : Vector3();

    Array boxes;
    const Array all = get_block_boxes(chunk_id);
    for (int i = 0; i < all.size(); ++i) {
        Dictionary src = all[i];
        if (!(bool)src["alive"]) {
            continue;
        }
        Dictionary box;
        box["block"] = src["block"];
        box["pos"] = (Vector3)src["pos"] - com;
        box["size"] = src["size"];
        boxes.push_back(box);
    }

    out["boxes"] = boxes;
    out["com"] = com;
    out["mass"] = total_mass;
    return out;
}

// --- chunks as movable things ----------------------------------------------

void BrickWorld::set_chunk_transform(int chunk_id, Transform3D xform) {
    if (valid_chunk(chunk_id)) {
        chunks[chunk_id].xform = xform;
    }
}

Transform3D BrickWorld::get_chunk_transform(int chunk_id) const {
    return valid_chunk(chunk_id) ? chunks[chunk_id].xform : Transform3D();
}

bool BrickWorld::is_chunk_alive(int chunk_id) const {
    return valid_chunk(chunk_id);
}

bool BrickWorld::is_chunk_anchored(int chunk_id) const {
    return valid_chunk(chunk_id) && chunks[chunk_id].anchored;
}

void BrickWorld::set_chunk_anchored(int chunk_id, bool anchored) {
    if (valid_chunk(chunk_id)) {
        chunks[chunk_id].anchored = anchored;
    }
}

Vector3 BrickWorld::get_chunk_com(int chunk_id) const {
    if (!valid_chunk(chunk_id)) {
        return Vector3();
    }
    const Chunk &c = chunks[chunk_id];
    float total = 0.0f;
    Vector3 weighted;
    for (const Block &b : c.blocks) {
        if (!b.alive) {
            continue;
        }
        Vector3 centre, size;
        block_extent(c, b, centre, size);
        const float m = std::max(archetypes[b.archetype].mass, 0.0001f);
        weighted += centre * m;
        total += m;
    }
    return total > 0.0f ? weighted / total : Vector3();
}

PackedInt32Array BrickWorld::separate_planes(int chunk_id, PackedVector3Array world_points,
        Vector3 world_normal, float thickness) {
    PackedInt32Array loosened;
    if (!valid_chunk(chunk_id) || thickness <= 0.0f || world_points.size() == 0) {
        return loosened;
    }
    Chunk &c = chunks[chunk_id];
    const Transform3D inv = c.xform.affine_inverse();
    Vector3 n = inv.basis.xform(world_normal);
    if (n.length_squared() < 1e-8f) {
        return loosened;
    }
    n.normalize();

    // Each plane is just an offset along the shared normal.
    std::vector<float> offsets;
    offsets.reserve((size_t)world_points.size());
    for (int i = 0; i < world_points.size(); ++i) {
        offsets.push_back(inv.xform(world_points[i]).dot(n));
    }

    const float half = thickness * 0.5f;
    for (size_t bi = 0; bi < c.blocks.size(); ++bi) {
        Block &b = c.blocks[bi];
        if (!b.alive || b.support_broken) {
            continue;
        }
        Vector3 centre, size;
        block_extent(c, b, centre, size);
        const float d = centre.dot(n);
        for (float o : offsets) {
            if (std::abs(d - o) <= half) {
                // Torn across, not gone.
                b.support_broken = true;
                loosened.push_back((int32_t)bi);
                break;
            }
        }
    }
    return loosened;
}

PackedInt32Array BrickWorld::separate_plane(int chunk_id, Vector3 world_point,
        Vector3 world_normal, float thickness) {
    PackedInt32Array loosened;
    if (!valid_chunk(chunk_id) || thickness <= 0.0f) {
        return loosened;
    }
    Chunk &c = chunks[chunk_id];
    const Transform3D inv = c.xform.affine_inverse();
    const Vector3 p = inv.xform(world_point);
    // A normal is a direction, so it takes the basis and not the translation.
    Vector3 n = inv.basis.xform(world_normal);
    if (n.length_squared() < 1e-8f) {
        return loosened;
    }
    n.normalize();

    const float half = thickness * 0.5f;
    for (size_t bi = 0; bi < c.blocks.size(); ++bi) {
        Block &b = c.blocks[bi];
        if (!b.alive || b.support_broken) {
            continue;
        }
        Vector3 centre, size;
        block_extent(c, b, centre, size);
        if (std::abs((centre - p).dot(n)) > half) {
            continue;
        }
        // Loose, not gone.
        b.support_broken = true;
        loosened.push_back((int32_t)bi);
    }
    return loosened;
}

void BrickWorld::release_chunk(int chunk_id) {
    if (!valid_chunk(chunk_id)) {
        return;
    }
    // Never free a chunk a worker is still reading.
    settle_bake_job(chunk_id, false);
    chunks[chunk_id] = Chunk();
    chunk_live[chunk_id] = 0;
}

// --- islands ---------------------------------------------------------------

Array BrickWorld::get_components(int chunk_id) {
    Array out;
    if (!valid_chunk(chunk_id)) {
        return out;
    }
    Chunk &c = chunks[chunk_id];
    const size_t n = c.blocks.size();
    scratch_mark.assign(n, 0);

    std::vector<PackedInt32Array> groups;
    for (size_t i = 0; i < n; ++i) {
        if (!c.blocks[i].alive || scratch_mark[i]) {
            continue;
        }
        PackedInt32Array group;
        scratch_queue.clear();
        scratch_queue.push_back((int32_t)i);
        scratch_mark[i] = 1;
        for (size_t head = 0; head < scratch_queue.size(); ++head) {
            const int32_t bid = scratch_queue[head];
            group.push_back(bid);
            for_each_neighbour(c, archetypes, bid, [&](int32_t nb) {
                if (scratch_mark[nb]) {
                    return;
                }
                // A sheared block is joined to nothing, so it comes away as a
                // loose brick and takes nothing with it.
                if (c.blocks[bid].support_broken || c.blocks[nb].support_broken) {
                    return;
                }
                scratch_mark[nb] = 1;
                scratch_queue.push_back(nb);
            });
        }
        group.sort();
        groups.push_back(group);
    }

    std::stable_sort(groups.begin(), groups.end(),
            [](const PackedInt32Array &a, const PackedInt32Array &b) {
                return a.size() > b.size();
            });
    for (const PackedInt32Array &g : groups) {
        out.push_back(g);
    }
    return out;
}

Dictionary BrickWorld::split_island(int chunk_id, const PackedInt32Array &block_ids) {
    Dictionary out;
    if (!valid_chunk(chunk_id) || block_ids.is_empty()) {
        return out;
    }

    // Bounding box of the group, in the source chunk's grid.
    Vector3i lo(INT32_MAX, INT32_MAX, INT32_MAX);
    Vector3i hi(INT32_MIN, INT32_MIN, INT32_MIN);
    int counted = 0;
    {
        const Chunk &src = chunks[chunk_id];
        for (int i = 0; i < block_ids.size(); ++i) {
            const int32_t bid = block_ids[i];
            if (bid < 0 || bid >= (int32_t)src.blocks.size() || !src.blocks[bid].alive) {
                continue;
            }
            const Block &b = src.blocks[bid];
            const Vector3i sz = archetypes[b.archetype].size;
            lo.x = std::min(lo.x, b.cell.x);
            lo.y = std::min(lo.y, b.cell.y);
            lo.z = std::min(lo.z, b.cell.z);
            hi.x = std::max(hi.x, b.cell.x + sz.x);
            hi.y = std::max(hi.y, b.cell.y + sz.y);
            hi.z = std::max(hi.z, b.cell.z + sz.z);
            ++counted;
        }
    }
    if (counted == 0) {
        return out;
    }

    const Transform3D src_xform = chunks[chunk_id].xform;
    const Vector3i src_origin = chunks[chunk_id].origin;

    // create_chunk may reallocate `chunks`, so nothing above may be held as a
    // reference across it.
    const int island_id = create_chunk(lo, hi - lo);
    if (island_id < 0) {
        return out;
    }

    // The island starts exactly where the group stood: the source's transform,
    // shifted by where the group sat inside the source grid.
    chunks[island_id].anchored = false;
    // An island is made of the same plastic as what it broke off. Without this
    // it would get the default capacity and be effectively unbreakable.
    stress[island_id].tension_per_stud = stress[chunk_id].tension_per_stud;
    chunks[island_id].xform = src_xform
            * Transform3D(Basis(), brick::grid_to_world(lo - src_origin));

    PackedInt32Array taken;
    for (int i = 0; i < block_ids.size(); ++i) {
        const int32_t bid = block_ids[i];
        if (bid < 0 || bid >= (int32_t)chunks[chunk_id].blocks.size()
                || !chunks[chunk_id].blocks[bid].alive) {
            continue;
        }
        const Block src_block = chunks[chunk_id].blocks[bid];
        place_block(island_id, src_block.cell, src_block.archetype, src_block.colour);
        chunks[chunk_id].blocks[bid].alive = false;
        chunks[chunk_id].blocks[bid].detached = true;
        taken.push_back(bid);
    }

    const Dictionary body = get_body_boxes(island_id);
    out["chunk"] = island_id;
    out["local_com"] = body.get("com", Vector3());
    out["com"] = chunks[island_id].xform.xform((Vector3)body.get("com", Vector3()));
    out["mass"] = body.get("mass", 0.0);
    out["block_count"] = counted;
    out["source_blocks"] = taken;
    return out;
}

// --- grid ------------------------------------------------------------------

Vector3 BrickWorld::grid_to_world(Vector3i cell) {
    return brick::grid_to_world(cell);
}

Vector3i BrickWorld::world_to_grid(Vector3 pos) {
    return brick::world_to_grid(pos);
}

Vector3 BrickWorld::get_cell_size() {
    return cell_size();
}

float BrickWorld::get_stud_metres() {
    return STUD_M;
}

float BrickWorld::get_plate_metres() {
    return PLATE_M;
}

Color BrickWorld::get_filament_colour(int index) {
    return filament_colour(index);
}

int BrickWorld::get_filament_count() {
    return FILAMENT_COUNT;
}

// --- determinism -----------------------------------------------------------

// ---------------------------------------------------------------------------
// Frames, ticks and welds. Docs/BuildMode.md section 2.
// ---------------------------------------------------------------------------

namespace {

constexpr int TICKS_STUD = 5;
constexpr int TICKS_PLATE = 2;

/// One of the 24 axis-aligned rotations, as a signed permutation of the axes.
/// `axis[i]` is which input axis feeds output axis i; `sign[i]` is its sign.
struct Rot {
    int8_t axis[3];
    int8_t sign[3];
};

/// The 24 rotations: every signed permutation with determinant +1. Built once,
/// in a fixed order, so a rotation index means the same thing in a save file as
/// it does in memory.
const std::vector<Rot> &rotations() {
    static std::vector<Rot> table = [] {
        std::vector<Rot> out;
        const int perms[6][3] = {{0,1,2},{0,2,1},{1,0,2},{1,2,0},{2,0,1},{2,1,0}};
        for (int p = 0; p < 6; ++p) {
            for (int s = 0; s < 8; ++s) {
                Rot r;
                for (int i = 0; i < 3; ++i) {
                    r.axis[i] = (int8_t)perms[p][i];
                    r.sign[i] = (s >> i) & 1 ? -1 : 1;
                }
                // Determinant of a signed permutation: the permutation's parity
                // times the product of the signs. Keep only proper rotations --
                // a mirrored part is a different part, not a turned one.
                int parity = 1;
                for (int i = 0; i < 3; ++i) {
                    for (int j = i + 1; j < 3; ++j) {
                        if (perms[p][i] > perms[p][j]) {
                            parity = -parity;
                        }
                    }
                }
                const int det = parity * r.sign[0] * r.sign[1] * r.sign[2];
                if (det == 1) {
                    out.push_back(r);
                }
            }
        }
        return out;
    }();
    return table;
}

Vector3i rotate_ticks(int rotation, const Vector3i &v) {
    const Rot &r = rotations()[rotation];
    const int in[3] = {v.x, v.y, v.z};
    return Vector3i(
        r.sign[0] * in[r.axis[0]],
        r.sign[1] * in[r.axis[1]],
        r.sign[2] * in[r.axis[2]]);
}

Basis rotation_basis(int rotation) {
    Basis b;
    b.set_column(0, Vector3(rotate_ticks(rotation, Vector3i(1, 0, 0))));
    b.set_column(1, Vector3(rotate_ticks(rotation, Vector3i(0, 1, 0))));
    b.set_column(2, Vector3(rotate_ticks(rotation, Vector3i(0, 0, 1))));
    return b;
}

/// A cell range in chunk-local ticks.
void local_ticks(const Vector3i &cell, const Vector3i &size, Vector3i &lo, Vector3i &hi) {
    lo = Vector3i(cell.x * TICKS_STUD, cell.y * TICKS_PLATE, cell.z * TICKS_STUD);
    hi = Vector3i((cell.x + size.x) * TICKS_STUD,
                  (cell.y + size.y) * TICKS_PLATE,
                  (cell.z + size.z) * TICKS_STUD);
}

/// Rotate a tick-space box and offset it. A signed permutation maps a box to a
/// box exactly, so this stays integer -- there is no bounding-box slop.
void world_ticks(int rotation, const Vector3i &offset,
        const Vector3i &lo, const Vector3i &hi, Vector3i &out_lo, Vector3i &out_hi) {
    const Vector3i a = rotate_ticks(rotation, lo) + offset;
    const Vector3i b = rotate_ticks(rotation, hi) + offset;
    out_lo = Vector3i(std::min(a.x, b.x), std::min(a.y, b.y), std::min(a.z, b.z));
    out_hi = Vector3i(std::max(a.x, b.x), std::max(a.y, b.y), std::max(a.z, b.z));
}

bool boxes_overlap(const Vector3i &alo, const Vector3i &ahi,
        const Vector3i &blo, const Vector3i &bhi) {
    return alo.x < bhi.x && blo.x < ahi.x
        && alo.y < bhi.y && blo.y < ahi.y
        && alo.z < bhi.z && blo.z < ahi.z;
}

} // namespace

int BrickWorld::ticks_per_stud() { return TICKS_STUD; }

void BrickWorld::set_side_studs(int archetype_id, const PackedInt32Array &studs) {
    if (!valid_archetype(archetype_id)) {
        return;
    }
    if (studs.size() % 6 != 0) {
        UtilityFunctions::push_error("BrickWorld: side studs need 6 ints each");
        return;
    }
    Archetype &a = archetypes[archetype_id];
    a.side_studs.clear();
    for (int i = 0; i < studs.size(); i += 6) {
        a.side_studs.push_back({
            (int8_t)studs[i], (int8_t)studs[i + 1], (int8_t)studs[i + 2],
            (int8_t)studs[i + 3], (int8_t)studs[i + 4], (int8_t)studs[i + 5]});
    }
}

PackedInt32Array BrickWorld::get_archetype_side_studs(int archetype_id) const {
    PackedInt32Array out;
    if (!valid_archetype(archetype_id)) {
        return out;
    }
    for (const Archetype::SideStud &s : archetypes[archetype_id].side_studs) {
        out.push_back(s.x);
        out.push_back(s.y);
        out.push_back(s.z);
        out.push_back(s.dx);
        out.push_back(s.dy);
        out.push_back(s.dz);
    }
    return out;
}

Array BrickWorld::get_side_studs(int chunk_id, int block_id) const {
    Array out;
    if (!valid_chunk(chunk_id)) {
        return out;
    }
    const Chunk &c = chunks[chunk_id];
    if (block_id < 0 || block_id >= (int)c.blocks.size()) {
        return out;
    }
    const Block &b = c.blocks[block_id];
    if (b.removed || !b.alive) {
        return out;
    }
    const Archetype &a = archetypes[b.archetype];
    const Vector3i base = b.cell - c.origin;

    for (const Archetype::SideStud &ss : a.side_studs) {
        const Vector3i local(base.x + ss.x, base.y + ss.y, base.z + ss.z);
        const Vector3i dir(ss.dx, ss.dy, ss.dz);
        // Buried studs are not attachment points.
        if (c.solid_at(local + dir)) {
            continue;
        }
        Vector3i lo, hi, wlo, whi;
        local_ticks(local, Vector3i(1, 1, 1), lo, hi);
        world_ticks(c.frame_rotation, c.frame_ticks, lo, hi, wlo, whi);

        Dictionary d;
        d["lo"] = wlo;
        d["hi"] = whi;
        d["dir"] = rotate_ticks(c.frame_rotation, dir);
        d["block"] = block_id;
        out.push_back(d);
    }
    return out;
}

int BrickWorld::ticks_per_plate() { return TICKS_PLATE; }
int BrickWorld::rotation_count() { return (int)rotations().size(); }

void BrickWorld::set_chunk_frame(int chunk_id, int rotation, Vector3i origin_ticks) {
    if (!valid_chunk(chunk_id)) {
        return;
    }
    if (rotation < 0 || rotation >= (int)rotations().size()) {
        UtilityFunctions::push_error("BrickWorld: rotation out of range");
        return;
    }
    Chunk &c = chunks[chunk_id];
    c.frame_rotation = rotation;
    c.frame_ticks = origin_ticks;
    // The transform is DERIVED. Ticks are the truth, because only they are
    // exact; the float transform is for the renderer and the solver.
    const float tick_m = STUD_M / (float)TICKS_STUD;
    c.xform = Transform3D(rotation_basis(rotation), Vector3(origin_ticks) * tick_m);
}

int BrickWorld::get_chunk_rotation(int chunk_id) const {
    return valid_chunk(chunk_id) ? chunks[chunk_id].frame_rotation : 0;
}

Vector3i BrickWorld::get_chunk_origin_ticks(int chunk_id) const {
    return valid_chunk(chunk_id) ? chunks[chunk_id].frame_ticks : Vector3i();
}

Array BrickWorld::get_block_ticks(int chunk_id, int block_id) const {
    Array out;
    if (!valid_chunk(chunk_id)) {
        return out;
    }
    const Chunk &c = chunks[chunk_id];
    if (block_id < 0 || block_id >= (int)c.blocks.size()) {
        return out;
    }
    const Block &b = c.blocks[block_id];
    if (b.removed) {
        return out;
    }
    Vector3i lo, hi;
    local_ticks(b.cell - c.origin, archetypes[b.archetype].size, lo, hi);
    Vector3i wlo, whi;
    world_ticks(c.frame_rotation, c.frame_ticks, lo, hi, wlo, whi);
    out.push_back(wlo);
    out.push_back(whi - wlo);
    return out;
}

PackedInt32Array BrickWorld::get_frame_overlaps(int chunk_id, int block_id,
        int other_chunk) const {
    PackedInt32Array out;
    if (!valid_chunk(chunk_id) || !valid_chunk(other_chunk) || chunk_id == other_chunk) {
        return out;
    }
    const Chunk &c = chunks[chunk_id];
    if (block_id < 0 || block_id >= (int)c.blocks.size() || c.blocks[block_id].removed) {
        return out;
    }
    const Block &b = c.blocks[block_id];
    Vector3i lo, hi, alo, ahi;
    local_ticks(b.cell - c.origin, archetypes[b.archetype].size, lo, hi);
    world_ticks(c.frame_rotation, c.frame_ticks, lo, hi, alo, ahi);

    const Chunk &o = chunks[other_chunk];
    for (size_t i = 0; i < o.blocks.size(); ++i) {
        const Block &ob = o.blocks[i];
        if (ob.removed || !ob.alive) {
            continue;
        }
        Vector3i olo, ohi, blo, bhi;
        local_ticks(ob.cell - o.origin, archetypes[ob.archetype].size, olo, ohi);
        world_ticks(o.frame_rotation, o.frame_ticks, olo, ohi, blo, bhi);
        if (boxes_overlap(alo, ahi, blo, bhi)) {
            out.push_back((int32_t)i);
        }
    }
    return out;
}

bool BrickWorld::overlaps_frame(int chunk_id, Vector3i cell, int archetype_id,
        int other_chunk) const {
    if (!valid_chunk(chunk_id) || !valid_archetype(archetype_id)
            || !valid_chunk(other_chunk) || chunk_id == other_chunk) {
        return false;
    }
    const Chunk &c = chunks[chunk_id];
    Vector3i lo, hi, alo, ahi;
    local_ticks(cell - c.origin, archetypes[archetype_id].size, lo, hi);
    world_ticks(c.frame_rotation, c.frame_ticks, lo, hi, alo, ahi);

    const Chunk &o = chunks[other_chunk];
    for (size_t i = 0; i < o.blocks.size(); ++i) {
        const Block &ob = o.blocks[i];
        if (ob.removed || !ob.alive) {
            continue;
        }
        Vector3i olo, ohi, blo, bhi;
        local_ticks(ob.cell - o.origin, archetypes[ob.archetype].size, olo, ohi);
        world_ticks(o.frame_rotation, o.frame_ticks, olo, ohi, blo, bhi);
        if (boxes_overlap(alo, ahi, blo, bhi)) {
            return true;
        }
    }
    return false;
}

// --- welds -----------------------------------------------------------------

int BrickWorld::add_weld(int chunk_a, int block_a, int chunk_b, int block_b) {
    if (!valid_chunk(chunk_a) || !valid_chunk(chunk_b)) {
        return -1;
    }
    if (block_a < 0 || block_a >= (int)chunks[chunk_a].blocks.size()
            || block_b < 0 || block_b >= (int)chunks[chunk_b].blocks.size()) {
        return -1;
    }
    Weld w;
    w.chunk_a = chunk_a;
    w.block_a = block_a;
    w.chunk_b = chunk_b;
    w.block_b = block_b;
    w.present = true;
    welds.push_back(w);
    return (int)welds.size() - 1;
}

int BrickWorld::get_weld_count() const {
    return (int)welds.size();
}

bool BrickWorld::is_weld_alive(int weld_id) const {
    if (weld_id < 0 || weld_id >= (int)welds.size()) {
        return false;
    }
    const Weld &w = welds[weld_id];
    if (!w.present || !valid_chunk(w.chunk_a) || !valid_chunk(w.chunk_b)) {
        return false;
    }
    const Chunk &a = chunks[w.chunk_a];
    const Chunk &b = chunks[w.chunk_b];
    if (w.block_a >= (int)a.blocks.size() || w.block_b >= (int)b.blocks.size()) {
        return false;
    }
    // Derived, never cached. This is what stops the one stored graph in the
    // system from going stale when a block dies.
    return a.blocks[w.block_a].alive && b.blocks[w.block_b].alive;
}

Dictionary BrickWorld::get_weld(int weld_id) const {
    Dictionary d;
    if (weld_id < 0 || weld_id >= (int)welds.size()) {
        return d;
    }
    const Weld &w = welds[weld_id];
    d["chunk_a"] = w.chunk_a;
    d["block_a"] = w.block_a;
    d["chunk_b"] = w.chunk_b;
    d["block_b"] = w.block_b;
    d["alive"] = is_weld_alive(weld_id);
    return d;
}

PackedInt32Array BrickWorld::get_live_welds() const {
    PackedInt32Array out;
    for (size_t i = 0; i < welds.size(); ++i) {
        if (is_weld_alive((int)i)) {
            out.push_back((int32_t)i);
        }
    }
    return out;
}

bool BrickWorld::remove_weld(int weld_id) {
    if (weld_id < 0 || weld_id >= (int)welds.size() || !welds[weld_id].present) {
        return false;
    }
    welds[weld_id].present = false;
    return true;
}

// --- grounding from a seed set ---------------------------------------------

PackedByteArray BrickWorld::solve_grounded_from(int chunk_id, const PackedInt32Array &seeds) {
    PackedByteArray out;
    if (!valid_chunk(chunk_id)) {
        return out;
    }
    Chunk &c = chunks[chunk_id];
    SolveStats &ss = solve_stats[chunk_id];
    ss = SolveStats();

    const size_t n = c.blocks.size();
    out.resize((int64_t)n);
    uint8_t *mark = out.ptrw();
    for (size_t i = 0; i < n; ++i) {
        mark[i] = 0;
    }

    scratch_queue.clear();
    scratch_queue.reserve(n);
    scratch_depth.assign(n, -1);
    const Vector3i up = -chunk_down[chunk_id];

    for (int i = 0; i < seeds.size(); ++i) {
        const int32_t bid = seeds[i];
        if (bid < 0 || bid >= (int32_t)n) {
            continue;
        }
        const Block &b = c.blocks[bid];
        if (!b.alive || b.support_broken || mark[bid]) {
            continue;
        }
        mark[bid] = 1;
        scratch_depth[bid] = 0;
        scratch_queue.push_back(bid);
    }

    for (size_t head = 0; head < scratch_queue.size(); ++head) {
        const int32_t bid = scratch_queue[head];
        ++ss.blocks_visited;
        const int32_t next_depth = scratch_depth[bid] + 1;
        for_each_neighbour(c, archetypes, bid, [&](int32_t nb) {
            if (mark[nb] != 0 || c.blocks[nb].support_broken) {
                return;
            }
            if (!grounding_flows(c, archetypes, bid, nb, up)) {
                return;
            }
            mark[nb] = 1;
            scratch_depth[nb] = next_depth;
            scratch_queue.push_back(nb);
        });
    }

    for (size_t i = 0; i < n; ++i) {
        if (!c.blocks[i].alive) {
            mark[i] = 0;
            continue;
        }
        if (mark[i]) {
            ++ss.grounded;
        } else {
            ++ss.ungrounded;
        }
    }
    return out;
}

void BrickWorld::set_seed(int64_t seed) {
    rng_seed = seed;
    // splitmix-style avalanche so seed 0 is not a degenerate state
    rng_state = (uint64_t)seed * 0x9E3779B97F4A7C15ULL + 0x6A09E667F3BCC909ULL;
    if (rng_state == 0) {
        rng_state = 0x9E3779B97F4A7C15ULL;
    }
}

int64_t BrickWorld::get_seed() const {
    return rng_seed;
}

// --- bindings --------------------------------------------------------------

void BrickWorld::_bind_methods() {
    ClassDB::bind_method(D_METHOD("bake_archetype", "name", "size", "mass"),
            &BrickWorld::bake_archetype, DEFVAL(1.0));
    ClassDB::bind_method(D_METHOD("bake_shaped_archetype", "name", "size", "mass",
            "cells", "studs", "sockets"), &BrickWorld::bake_shaped_archetype,
            DEFVAL(PackedByteArray()), DEFVAL(PackedByteArray()));
    ClassDB::bind_method(D_METHOD("is_archetype_full_box", "archetype_id"),
            &BrickWorld::is_archetype_full_box);
    ClassDB::bind_method(D_METHOD("get_archetype_solid_cells", "archetype_id"),
            &BrickWorld::get_archetype_solid_cells);

    ClassDB::bind_method(D_METHOD("split_island", "chunk_id", "block_ids"), &BrickWorld::split_island);
    ClassDB::bind_method(D_METHOD("get_components", "chunk_id"), &BrickWorld::get_components);
    ClassDB::bind_method(D_METHOD("release_chunk", "chunk_id"), &BrickWorld::release_chunk);
    ClassDB::bind_method(D_METHOD("is_chunk_alive", "chunk_id"), &BrickWorld::is_chunk_alive);
    ClassDB::bind_method(D_METHOD("is_chunk_anchored", "chunk_id"), &BrickWorld::is_chunk_anchored);
    ClassDB::bind_method(D_METHOD("set_chunk_anchored", "chunk_id", "anchored"),
            &BrickWorld::set_chunk_anchored);
    ClassDB::bind_method(D_METHOD("get_chunk_com", "chunk_id"), &BrickWorld::get_chunk_com);
    ClassDB::bind_method(D_METHOD("separate_plane", "chunk_id", "world_point", "world_normal", "thickness"),
            &BrickWorld::separate_plane);
    ClassDB::bind_method(D_METHOD("separate_planes", "chunk_id", "world_points", "world_normal", "thickness"),
            &BrickWorld::separate_planes);
    ClassDB::bind_method(D_METHOD("set_chunk_transform", "chunk_id", "xform"),
            &BrickWorld::set_chunk_transform);
    ClassDB::bind_method(D_METHOD("get_chunk_transform", "chunk_id"), &BrickWorld::get_chunk_transform);
    ClassDB::bind_method(D_METHOD("get_body_boxes", "chunk_id"), &BrickWorld::get_body_boxes);
    ClassDB::bind_method(D_METHOD("bake_variant", "base_archetype", "name", "yaw", "flip"),
            &BrickWorld::bake_variant);
    ClassDB::bind_method(D_METHOD("bake_faced_archetype", "name", "size", "mass", "cells",
            "up_face", "down_face"), &BrickWorld::bake_faced_archetype);
    ClassDB::bind_method(D_METHOD("set_side_studs", "archetype_id", "studs"),
            &BrickWorld::set_side_studs);
    ClassDB::bind_method(D_METHOD("get_archetype_side_studs", "archetype_id"),
            &BrickWorld::get_archetype_side_studs);
    ClassDB::bind_method(D_METHOD("get_side_studs", "chunk_id", "block_id"),
            &BrickWorld::get_side_studs);
    ClassDB::bind_method(D_METHOD("get_archetype_up_face", "archetype_id"),
            &BrickWorld::get_archetype_up_face);
    ClassDB::bind_method(D_METHOD("get_archetype_down_face", "archetype_id"),
            &BrickWorld::get_archetype_down_face);
    ClassDB::bind_method(D_METHOD("get_archetype_count"), &BrickWorld::get_archetype_count);
    ClassDB::bind_method(D_METHOD("get_archetype_size", "archetype_id"), &BrickWorld::get_archetype_size);
    ClassDB::bind_method(D_METHOD("get_archetype_name", "archetype_id"), &BrickWorld::get_archetype_name);

    ClassDB::bind_method(D_METHOD("create_chunk", "origin", "dims"), &BrickWorld::create_chunk);
    ClassDB::bind_method(D_METHOD("get_chunk_count"), &BrickWorld::get_chunk_count);
    ClassDB::bind_method(D_METHOD("get_chunk_origin", "chunk_id"), &BrickWorld::get_chunk_origin);
    ClassDB::bind_method(D_METHOD("get_chunk_dims", "chunk_id"), &BrickWorld::get_chunk_dims);

    ClassDB::bind_method(D_METHOD("place_block", "chunk_id", "cell", "archetype_id", "colour",
                    "decorative"),
            &BrickWorld::place_block, DEFVAL(false));
    ClassDB::bind_method(D_METHOD("remove_block", "chunk_id", "block_id"),
            &BrickWorld::remove_block);
    ClassDB::bind_method(D_METHOD("can_place", "chunk_id", "cell", "archetype_id"),
            &BrickWorld::can_place);
    ClassDB::bind_method(D_METHOD("would_connect", "chunk_id", "cell", "archetype_id"),
            &BrickWorld::would_connect);
    ClassDB::bind_method(D_METHOD("kill_block", "chunk_id", "cell"), &BrickWorld::kill_block);
    ClassDB::bind_method(D_METHOD("kill_blocks", "chunk_id", "ids"), &BrickWorld::kill_blocks);
    ClassDB::bind_method(D_METHOD("get_column_mask", "chunk_id", "y0", "y1"),
            &BrickWorld::get_column_mask);
    ClassDB::bind_method(D_METHOD("build_damage_profile", "chunk_id", "fx", "fz", "thick",
                    "segments", "bands"),
            &BrickWorld::build_damage_profile);
    ClassDB::bind_method(D_METHOD("get_dead_blocks", "chunk_id"), &BrickWorld::get_dead_blocks);
    ClassDB::bind_method(D_METHOD("get_dead_block_count", "chunk_id"),
            &BrickWorld::get_dead_block_count);
    ClassDB::bind_method(D_METHOD("get_block_archetype", "chunk_id", "block_id"),
            &BrickWorld::get_block_archetype);
    ClassDB::bind_method(D_METHOD("get_block_colour", "chunk_id", "block_id"),
            &BrickWorld::get_block_colour);
    ClassDB::bind_method(D_METHOD("is_solid", "chunk_id", "cell"), &BrickWorld::is_solid);
    ClassDB::bind_method(D_METHOD("block_at", "chunk_id", "cell"), &BrickWorld::block_at);
    ClassDB::bind_method(D_METHOD("get_block_count", "chunk_id"), &BrickWorld::get_block_count);
    ClassDB::bind_method(D_METHOD("get_alive_block_count", "chunk_id"), &BrickWorld::get_alive_block_count);
    ClassDB::bind_method(D_METHOD("get_block_index_range", "chunk_id", "block_id"),
            &BrickWorld::get_block_index_range);

    ClassDB::bind_method(D_METHOD("build_chunk_mesh", "chunk_id"), &BrickWorld::build_chunk_mesh);
    ClassDB::bind_method(D_METHOD("get_mesh_stats", "chunk_id"), &BrickWorld::get_mesh_stats);
    ClassDB::bind_method(D_METHOD("update_index_region", "chunk_id", "index_bytes"),
            &BrickWorld::update_index_region, DEFVAL(4));
    ClassDB::bind_method(D_METHOD("get_memory_report"), &BrickWorld::get_memory_report);
    ClassDB::bind_method(D_METHOD("bake_chunk_async", "chunk_id"), &BrickWorld::bake_chunk_async);
    ClassDB::bind_method(D_METHOD("bake_ready", "chunk_id"), &BrickWorld::bake_ready);
    ClassDB::bind_method(D_METHOD("bake_pending", "chunk_id"), &BrickWorld::bake_pending);
    ClassDB::bind_method(D_METHOD("drop_chunk_bake", "chunk_id"), &BrickWorld::drop_chunk_bake);
    ClassDB::bind_method(D_METHOD("bakes_in_flight"), &BrickWorld::bakes_in_flight);
    ClassDB::bind_method(D_METHOD("get_chunk_mass", "chunk_id"), &BrickWorld::get_chunk_mass);
    ClassDB::bind_method(D_METHOD("get_chunk_content_hash", "chunk_id"),
            &BrickWorld::get_chunk_content_hash);
    ClassDB::bind_method(D_METHOD("add_chunk_shapes", "body", "chunk_id", "offset", "skip_dead", "merge"),
            &BrickWorld::add_chunk_shapes, DEFVAL(false));
    ClassDB::bind_method(D_METHOD("set_chunk_gravity", "chunk_id", "down"), &BrickWorld::set_chunk_gravity);
    ClassDB::bind_method(D_METHOD("get_chunk_gravity", "chunk_id"), &BrickWorld::get_chunk_gravity);

    ClassDB::bind_method(D_METHOD("get_block_neighbours", "chunk_id", "block_id"),
            &BrickWorld::get_block_neighbours);
    ClassDB::bind_method(D_METHOD("set_blocks_decorative", "chunk_id", "block_ids", "on"),
            &BrickWorld::set_blocks_decorative);
    ClassDB::bind_method(D_METHOD("is_block_decorative", "chunk_id", "block_id"),
            &BrickWorld::is_block_decorative);
    ClassDB::bind_method(D_METHOD("get_decorative_blocks", "chunk_id"),
            &BrickWorld::get_decorative_blocks);
    ClassDB::bind_method(D_METHOD("solve_grounded", "chunk_id"), &BrickWorld::solve_grounded);
    ClassDB::bind_method(D_METHOD("find_detached_groups", "chunk_id"), &BrickWorld::find_detached_groups);
    ClassDB::bind_method(D_METHOD("set_foundation_level", "chunk_id", "grid_y"),
            &BrickWorld::set_foundation_level);
    ClassDB::bind_method(D_METHOD("get_solve_stats", "chunk_id"), &BrickWorld::get_solve_stats);

    ClassDB::bind_method(D_METHOD("solve_stress", "chunk_id"), &BrickWorld::solve_stress);
    ClassDB::bind_method(D_METHOD("check_stability", "chunk_id"), &BrickWorld::check_stability);
    ClassDB::bind_method(D_METHOD("set_tension_per_stud", "chunk_id", "capacity"),
            &BrickWorld::set_tension_per_stud);
    ClassDB::bind_method(D_METHOD("get_tension_per_stud", "chunk_id"), &BrickWorld::get_tension_per_stud);
    ClassDB::bind_method(D_METHOD("get_max_stress_ratio", "chunk_id"), &BrickWorld::get_max_stress_ratio);
    ClassDB::bind_method(D_METHOD("get_block_load", "chunk_id", "block_id"), &BrickWorld::get_block_load);
    ClassDB::bind_method(D_METHOD("get_block_capacity", "chunk_id", "block_id"),
            &BrickWorld::get_block_capacity);
    ClassDB::bind_method(D_METHOD("is_support_broken", "chunk_id", "block_id"),
            &BrickWorld::is_support_broken);

    ClassDB::bind_method(D_METHOD("apply_hit", "chunk_id", "world_point", "radius_m"),
            &BrickWorld::apply_hit);
    ClassDB::bind_method(D_METHOD("separate_near", "chunk_id", "world_point", "radius_m",
                    "max_blocks", "peel"),
            &BrickWorld::separate_near, DEFVAL(0), DEFVAL(false));
    ClassDB::bind_method(D_METHOD("sever_seams", "chunk_id", "world_points", "world_normal"),
            &BrickWorld::sever_seams);
    ClassDB::bind_method(D_METHOD("detach_group", "chunk_id", "block_ids"), &BrickWorld::detach_group);
    ClassDB::bind_method(D_METHOD("get_block_boxes", "chunk_id"), &BrickWorld::get_block_boxes);

    ClassDB::bind_static_method("BrickWorld", D_METHOD("ticks_per_stud"),
            &BrickWorld::ticks_per_stud);
    ClassDB::bind_static_method("BrickWorld", D_METHOD("ticks_per_plate"),
            &BrickWorld::ticks_per_plate);
    ClassDB::bind_static_method("BrickWorld", D_METHOD("rotation_count"),
            &BrickWorld::rotation_count);
    ClassDB::bind_method(D_METHOD("set_chunk_frame", "chunk_id", "rotation", "origin_ticks"),
            &BrickWorld::set_chunk_frame);
    ClassDB::bind_method(D_METHOD("get_chunk_rotation", "chunk_id"),
            &BrickWorld::get_chunk_rotation);
    ClassDB::bind_method(D_METHOD("get_chunk_origin_ticks", "chunk_id"),
            &BrickWorld::get_chunk_origin_ticks);
    ClassDB::bind_method(D_METHOD("get_block_ticks", "chunk_id", "block_id"),
            &BrickWorld::get_block_ticks);
    ClassDB::bind_method(D_METHOD("overlaps_frame", "chunk_id", "cell", "archetype_id",
            "other_chunk"), &BrickWorld::overlaps_frame);
    ClassDB::bind_method(D_METHOD("get_frame_overlaps", "chunk_id", "block_id", "other_chunk"),
            &BrickWorld::get_frame_overlaps);
    ClassDB::bind_method(D_METHOD("add_weld", "chunk_a", "block_a", "chunk_b", "block_b"),
            &BrickWorld::add_weld);
    ClassDB::bind_method(D_METHOD("get_weld_count"), &BrickWorld::get_weld_count);
    ClassDB::bind_method(D_METHOD("is_weld_alive", "weld_id"), &BrickWorld::is_weld_alive);
    ClassDB::bind_method(D_METHOD("get_weld", "weld_id"), &BrickWorld::get_weld);
    ClassDB::bind_method(D_METHOD("get_live_welds"), &BrickWorld::get_live_welds);
    ClassDB::bind_method(D_METHOD("remove_weld", "weld_id"), &BrickWorld::remove_weld);
    ClassDB::bind_method(D_METHOD("solve_grounded_from", "chunk_id", "seeds"),
            &BrickWorld::solve_grounded_from);
    ClassDB::bind_method(D_METHOD("set_seed", "seed"), &BrickWorld::set_seed);
    ClassDB::bind_method(D_METHOD("get_seed"), &BrickWorld::get_seed);

    ClassDB::bind_static_method("BrickWorld", D_METHOD("grid_to_world", "cell"), &BrickWorld::grid_to_world);
    ClassDB::bind_static_method("BrickWorld", D_METHOD("world_to_grid", "pos"), &BrickWorld::world_to_grid);
    ClassDB::bind_static_method("BrickWorld", D_METHOD("get_cell_size"), &BrickWorld::get_cell_size);
    ClassDB::bind_static_method("BrickWorld", D_METHOD("get_stud_metres"), &BrickWorld::get_stud_metres);
    ClassDB::bind_static_method("BrickWorld", D_METHOD("get_plate_metres"), &BrickWorld::get_plate_metres);
    ClassDB::bind_static_method("BrickWorld", D_METHOD("get_filament_colour", "index"), &BrickWorld::get_filament_colour);
    ClassDB::bind_static_method("BrickWorld", D_METHOD("get_filament_count"), &BrickWorld::get_filament_count);
}
