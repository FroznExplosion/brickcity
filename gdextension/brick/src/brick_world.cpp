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
#include <queue>
#include <chrono>
#if defined(_MSC_VER)
#include <intrin.h>
#endif
#include <climits>
#include <limits>
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
    palette_changed();
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
    palette_changed();
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
    palette_changed();
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

    // An authored surface turns with the part. Positions go through the linear
    // map and are then shifted back into the part's box, which the map may
    // have flipped to negative; normals take the linear map alone.
    if (!base.mesh.empty() || !base.hulls.empty()) {
        const Vector3 csz = cell_size();
        const Vector3 box((float)base.size.x * csz.x, (float)base.size.y * csz.y,
                (float)base.size.z * csz.z);
        auto lin = [&o](const Vector3 &v) {
            // The same map as Orient::direction, for float vectors.
            float ax = v.x, az = v.z, ay = v.y;
            switch (o.yaw) {
                case 1: ax = -v.z; az = v.x;  break;
                case 2: ax = -v.x; az = -v.z; break;
                case 3: ax = v.z;  az = -v.x; break;
                default: break;
            }
            if (o.flip) {
                ay = -ay;
                az = -az;
            }
            return Vector3(ax, ay, az);
        };
        const Vector3 far = lin(box);
        const Vector3 shift(std::max(0.0f, -far.x), std::max(0.0f, -far.y),
                std::max(0.0f, -far.z));
        for (const Archetype::MeshTri &t : base.mesh) {
            Archetype::MeshTri r;
            for (int k = 0; k < 3; ++k) {
                r.p[k] = lin(t.p[k]) + shift;
                r.n[k] = lin(t.n[k]);
            }
            r.feature = t.feature; // edge k is still opposite vertex k
            r.edges = t.edges;
            for (int k = 0; k < t.edges; ++k) {
                r.edge_a[k] = lin(t.edge_a[k]) + shift;
                r.edge_b[k] = lin(t.edge_b[k]) + shift;
            }
            a.mesh.push_back(r);
        }
        for (const PackedVector3Array &h : base.hulls) {
            PackedVector3Array r;
            r.resize(h.size());
            for (int k = 0; k < h.size(); ++k) {
                r.set(k, lin(h[k]) + shift);
            }
            a.hulls.push_back(r);
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
    palette_changed();
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
    c.occ_y0 = 0;
    c.occ_dy = dims.y;
    c.occupancy.reset(c.cell_count());
    c.xform = Transform3D(Basis(), brick::grid_to_world(origin));
    c.anchored = true;
    chunks.push_back(std::move(c));
    chunk_live.push_back(1);
    joint_cache.push_back(brick::JointCache());
    conn_watch.push_back(ConnWatch());
    stats.push_back(MeshStats());
    solve_stats.push_back(SolveStats());
    stress.push_back(StressState());
    foundation_level.push_back(origin.y); // the chunk's own floor anchors it
    anchor_levels.push_back(std::vector<int>());
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
                // index_of is -1 outside a band chunk's occupancy window:
                // nothing can be put where nothing is laid.
                if (!c.in_bounds(l) || c.index_of(l) < 0 || c.occupancy[c.index_of(l)] >= 0) {
                    return -1;
                }
            }
        }
    }

    const int32_t id = (int32_t)c.blocks.size();
    Block b;
    b.cell = cell;
    b.archetype = archetype_id;
    // Up to 255, not the palette size: for a variant material (wood, metal)
    // the byte picks one of ITS list, which block_rgba resolves.
    b.colour = (uint8_t)std::clamp(colour, 0, 255);
    b.decorative = decorative;
    c.blocks.push_back(b);
    if (!c.absent.empty()) {
        c.absent.push_back(0); // placed, so present
    }

    for (int x = 0; x < a.size.x; ++x) {
        for (int y = 0; y < a.size.y; ++y) {
            for (int z = 0; z < a.size.z; ++z) {
                if (!a.solid_at(x, y, z)) {
                    continue;
                }
                const Vector3i l(base.x + x, base.y + y, base.z + z);
                c.occupancy.set(c.index_of(l), id);
            }
        }
    }
    conn_touch(chunk_id, id);
    if (joint_cache[chunk_id].valid) {
        std::vector<int32_t> touching;
        blocks_touching(c, id, touching);
        joints_changed(chunk_id, id, touching, true);
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
    // ...and a stand-in's worker is reading the block list this is about to grow.
    if (!coarse_jobs.empty()) {
        settle_coarse_job(chunk_id);
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
    // What its joints reached, asked while its cells are still its own.
    std::vector<int32_t> touching;
    const bool keep_joints = joint_cache[chunk_id].valid;
    if (keep_joints) {
        blocks_touching(c, block_id, touching);
    }
    // A chunk known to be in one piece is told what this touched
    // (get_components_near): a removed block has no joints left to ask.
    if (conn_watch[(size_t)chunk_id].whole) {
        std::vector<int32_t> near;
        if (keep_joints) {
            near = touching;
        } else {
            blocks_touching(c, block_id, near);
        }
        conn_touch(chunk_id, block_id);
        for (const int32_t o : near) {
            conn_touch(chunk_id, o);
        }
    }

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
                    c.occupancy.set(c.index_of(l), -1);
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
    if (keep_joints) {
        joints_changed(chunk_id, block_id, touching, false);
    }

    // Geometry changed, so the bake is stale and a bake in flight is reading
    // the arrays this call just wrote. Same contract as place_block -- and the
    // same exception, for the same reason.
    if (!b.decorative) {
        c.bake.valid = false;
        if (bake_pending(chunk_id)) {
            settle_bake_job(chunk_id, false);
        }
        if (!coarse_jobs.empty()) {
            settle_coarse_job(chunk_id);
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
                if (!c.in_bounds(l) || c.index_of(l) < 0 || c.occupancy[c.index_of(l)] >= 0) {
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
    conn_touch(chunk_id, id);
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
        if (c.is_absent(bid)) {
            // Not laid: the record says it is dead, and it comes in dead.
            c.absent[(size_t)bid] &= (uint8_t)~Chunk::ABSENT_ALIVE;
            c.blocks[bid].hp = 0;
            continue;
        }
        c.blocks[bid].alive = false;
        conn_touch(chunk_id, bid);
        c.blocks[bid].hp = 0;
    }
}

PackedFloat32Array BrickWorld::get_chunk_studs(int chunk_id) const {
    return chunk_studs(chunk_id, -1, true);
}

PackedFloat32Array BrickWorld::get_chunk_studs_section(int chunk_id, int section) const {
    return chunk_studs(chunk_id, section, false);
}

PackedByteArray BrickWorld::get_chunk_studs_open(int chunk_id, int section) const {
    std::vector<uint8_t> open;
    chunk_studs(chunk_id, section, false, &open);
    PackedByteArray out;
    out.resize((int64_t)open.size());
    if (!open.empty()) {
        std::memcpy(out.ptrw(), open.data(), open.size());
    }
    return out;
}

Array BrickWorld::get_chunk_studs_and_open(int chunk_id, int section) const {
    std::vector<uint8_t> open;
    const PackedFloat32Array buffer = chunk_studs(chunk_id, section, false, &open);
    PackedByteArray flags;
    flags.resize((int64_t)open.size());
    if (!open.empty()) {
        std::memcpy(flags.ptrw(), open.data(), open.size());
    }
    Array out;
    out.push_back(buffer);
    out.push_back(flags);
    return out;
}

Array BrickWorld::split_studs(const PackedFloat32Array &buffer, Vector3 eye,
        const PackedFloat32Array &rings, const PackedByteArray &open, int closed_rings) {
    Array out;
    const int ring_n = (int)rings.size();
    std::vector<std::vector<float>> parts((size_t)ring_n);
    const float *r = buffer.ptr();
    const int64_t n = buffer.size() / 16;
    const uint8_t *o = open.size() == n ? open.ptr() : nullptr;
    for (int64_t i = 0; i < n; ++i) {
        // Sixteen floats: three rows of the basis with the origin in each
        // row's fourth, then the colour (chunk_studs).
        const float *at = r + i * 16;
        const float dx = at[3] - (float)eye.x;
        const float dy = at[7] - (float)eye.y;
        const float dz = at[11] - (float)eye.z;
        const float d2 = dx * dx + dy * dy + dz * dz;
        const int last = (o != nullptr && o[i] == 0) ? std::min(ring_n, closed_rings) : ring_n;
        for (int k = 0; k < last; ++k) {
            if (d2 < rings[k] * rings[k]) {
                parts[(size_t)k].insert(parts[(size_t)k].end(), at, at + 16);
                break;
            }
        }
    }
    for (int k = 0; k < ring_n; ++k) {
        PackedFloat32Array part;
        part.resize((int64_t)parts[(size_t)k].size());
        if (!parts[(size_t)k].empty()) {
            std::memcpy(part.ptrw(), parts[(size_t)k].data(),
                    parts[(size_t)k].size() * sizeof(float));
        }
        out.push_back(part);
    }
    return out;
}

// Which way a part's top was printed, in the chunk's frame: every copy of a
// part comes off the printer with its top lines the same way round in its
// own frame, so a part turned a quarter is a part whose lines are turned.
// Long along X -- the way it was printed -- or along Z, turned. A square part
// says nothing about how it was turned, so its corner cell's hash does.
// brick.gdshader / print_surface.gdshaderinc (ps_top_turned) works the same
// out of a face's own size and corner, and must agree: the hash is the same
// integer one.
bool BrickWorld::stud_turn(const Vector3i &size, const Vector3i &corner) {
    if (size.x != size.z) {
        return size.z > size.x;
    }
    const uint32_t h = ((uint32_t)corner.x * 73856093u) ^ ((uint32_t)corner.z * 19349663u);
    return ((h >> 4) & 1u) != 0;
}

PackedFloat32Array BrickWorld::chunk_studs(int chunk_id, int section, bool furniture,
        std::vector<uint8_t> *open) const {
    PackedFloat32Array out;
    if (!valid_chunk(chunk_id)) {
        return out;
    }
    const Chunk &c = chunks[chunk_id];

    // Sixteen floats: three rows of four (basis columns interleaved with the
    // origin, as MultiMesh.set_buffer wants), then rgba.
    auto push = [&out](float px, float py, float pz, bool down, bool turn, const Color &col) {
        // A downward stud is the same mesh turned 180 degrees about X -- a
        // proper rotation, so the winding stays right. A negative Y scale would
        // mirror it and the stud would render inside out.
        const float sy = down ? -1.0f : 1.0f;
        // A TURNED stud is the same mesh a quarter turn about Y first. Its
        // shape does not change -- an octagon, or a square post, goes onto
        // itself -- but its own frame does, and the printed surface reads the
        // top's toolpath in that frame (printed_core.gdshaderinc): it lies the
        // way its brick's top does (stud_turn).
        // Rows of the basis: Rx(down) * Ry(turn).
        const float t = turn ? 1.0f : 0.0f, u = turn ? 0.0f : 1.0f;
        out.push_back(u);       out.push_back(0.0f); out.push_back(t);       out.push_back(px);
        out.push_back(0.0f);    out.push_back(sy);   out.push_back(0.0f);    out.push_back(py);
        out.push_back(-t * sy); out.push_back(0.0f); out.push_back(u * sy);  out.push_back(pz);
        // Alpha is the material (block_rgba), so a stud is shaded as what its
        // brick is made of: a steel brick has steel studs.
        out.push_back(col.r); out.push_back(col.g); out.push_back(col.b); out.push_back(col.a);
    };

    for (size_t bi = 0; bi < c.blocks.size(); ++bi) {
        const Block &b = c.blocks[bi];
        if (b.removed || !b.alive) {
            continue;
        }
        // A block is drawn by the band its lowest cell is in (FaceBake) -- and
        // furniture by none of them: it is not in the bake (FurnitureMesh).
        if ((b.decorative && !furniture)
                || (section >= 0 && c.section_of(b.cell) != section)) {
            continue;
        }
        const Archetype &a = archetypes[b.archetype];
        const Vector3i base = b.cell - c.origin;
        const Color col = block_rgba(b.material, b.colour);
        const bool turn = stud_turn(a.size, base);

        for (const Archetype::SurfaceCell &sc : a.top_cells) {
            if (a.up_at(sc.x, sc.z) != FACE_STUD) {
                continue;
            }
            const Vector3i cell(base.x + sc.x, base.y + sc.y, base.z + sc.z);
            if (c.solid_at(cell + Vector3i(0, 1, 0))) {
                continue; // covered: inside the brick above
            }
            push(((float)cell.x + 0.5f) * STUD_M, (float)(cell.y + 1) * PLATE_M,
                    ((float)cell.z + 0.5f) * STUD_M, false, turn, col);
            if (open != nullptr) {
                // Up the column to the first brick: on a storey's floor that
                // is the slab over it, a storey up, so this stops soon.
                uint8_t clear = 1;
                for (int y = cell.y + 2; y < c.dims.y; ++y) {
                    if (c.solid_at(Vector3i(cell.x, y, cell.z))) {
                        clear = 0;
                        break;
                    }
                }
                open->push_back(clear);
            }
        }
        for (const Archetype::SurfaceCell &sc : a.bottom_cells) {
            if (a.down_at(sc.x, sc.z) != FACE_STUD) {
                continue;
            }
            const Vector3i cell(base.x + sc.x, base.y + sc.y, base.z + sc.z);
            if (c.solid_at(cell - Vector3i(0, 1, 0))) {
                continue;
            }
            push(((float)cell.x + 0.5f) * STUD_M, (float)cell.y * PLATE_M,
                    ((float)cell.z + 0.5f) * STUD_M, true, turn, col);
            if (open != nullptr) {
                uint8_t clear = 1;
                for (int y = cell.y - 2; y >= 0; --y) {
                    if (c.solid_at(Vector3i(cell.x, y, cell.z))) {
                        clear = 0;
                        break;
                    }
                }
                open->push_back(clear);
            }
        }
    }
    return out;
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
        } else if (c.is_absent((int32_t)i)
                && (c.absent[i] & (Chunk::ABSENT_ALIVE | Chunk::ABSENT_DETACHED)) == 0) {
            ++n; // not laid, and dead in its record
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
        } else if (c.is_absent((int32_t)i)
                && (c.absent[i] & (Chunk::ABSENT_ALIVE | Chunk::ABSENT_DETACHED)) == 0) {
            out.push_back((int32_t)i); // not laid: its record (Chunk::absent)
        }
    }
    return out;
}

PackedInt32Array BrickWorld::get_detached_blocks(int chunk_id) const {
    PackedInt32Array out;
    if (!valid_chunk(chunk_id)) {
        return out;
    }
    const Chunk &c = chunks[chunk_id];
    for (size_t i = 0; i < c.blocks.size(); ++i) {
        if (c.blocks[i].detached && !c.blocks[i].removed) {
            out.push_back((int32_t)i);
        } else if (c.is_absent((int32_t)i) && (c.absent[i] & Chunk::ABSENT_DETACHED) != 0) {
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

bool BrickWorld::set_block_colour(int chunk_id, int block_id, int colour) {
    if (!valid_chunk(chunk_id)) {
        return false;
    }
    Chunk &c = chunks[chunk_id];
    if (block_id < 0 || block_id >= (int)c.blocks.size() || c.blocks[block_id].removed) {
        return false;
    }
    const uint8_t v = (uint8_t)std::clamp(colour, 0, 255);
    if (c.blocks[block_id].colour == v) {
        return true;
    }
    c.blocks[block_id].colour = v;
    // The bake caches each face's colour; a stale bake would draw the old one.
    if (c.bake.valid || bake_pending(chunk_id)) {
        drop_chunk_bake(chunk_id);
    }
    return true;
}

bool BrickWorld::is_solid(int chunk_id, Vector3i cell) const {
    if (!valid_chunk(chunk_id)) {
        return false;
    }
    const Chunk &c = chunks[chunk_id];
    return c.solid_at(cell - c.origin);
}

PackedByteArray BrickWorld::get_solid_cells(int chunk_id) const {
    PackedByteArray out;
    if (!valid_chunk(chunk_id)) {
        return out;
    }
    const Chunk &c = chunks[chunk_id];
    const Vector3i d = c.dims;
    out.resize((int64_t)d.x * d.y * d.z);
    uint8_t *w = out.ptrw();
    memset(w, 0, (size_t)out.size());
    // Alive per block first: a Block is big, and reading it per cell was most
    // of the cost (5.7 ms for a tower; PerfCaps.md 4).
    std::vector<uint8_t> alive(c.blocks.size());
    for (size_t i = 0; i < c.blocks.size(); ++i) {
        alive[i] = c.blocks[i].alive ? 1 : 0;
    }
    for (int z = 0; z < d.z; ++z) {
        for (int y = 0; y < d.y; ++y) {
            const int64_t row = c.index_of(Vector3i(0, y, z));
            if (row < 0) {
                continue; // outside a band chunk's window: nothing there
            }
            uint8_t *o = w + (int64_t)d.x * ((int64_t)y + (int64_t)d.y * z);
            for (int x = 0; x < d.x; ++x) {
                const int32_t blk = c.occupancy[row + x];
                o[x] = (blk >= 0 && alive[(size_t)blk]) ? 1 : 0;
            }
        }
    }
    return out;
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

    // Blocks bucketed by section, so the faces come out grouped. See
    // FaceBake::section_first -- a section's faces, and therefore its vertices,
    // have to be ONE contiguous range or a section mesh is a gather rather than
    // a slice.
    const int section_n = c.sections();
    std::vector<std::vector<int32_t>> by_section((size_t)section_n);
    for (size_t i = 0; i < c.blocks.size(); ++i) {
        const Block &b = c.blocks[i];
        if (b.removed || b.decorative) {
            continue;
        }
        by_section[(size_t)c.section_of(b.cell)].push_back((int32_t)i);
    }
    fb.section_first.assign((size_t)section_n, 0);
    fb.section_faces.assign((size_t)section_n, 0);

    for (int sec = 0; sec < section_n; ++sec) {
    fb.section_first[(size_t)sec] = (int32_t)fb.owner.size();
    for (int32_t bi : by_section[(size_t)sec]) {
        const Block &b = c.blocks[bi];
        if (b.removed) {
            continue; // edited away: owns no cells, so it has no faces
        }
        if (b.decorative) {
            continue; // bucketed out above; see FurnitureMesh
        }
        const Archetype &a = parts[b.archetype];
        const Vector3i base = b.cell - c.origin;
        const Color col = block_rgba(b.material, b.colour);
        const Vector3 block_origin(base.x * cs.x, base.y * cs.y, base.z * cs.z);
        const int asize[3] = { a.size.x, a.size.y, a.size.z };

        // An authored surface replaces the voxel faces outright. Each triangle
        // is stored as a quad whose fourth corner repeats the second: the
        // second triangle of the pair, (1, 3, 2), collapses to zero area, and
        // every other part of the pipeline -- four vertices a face, the index
        // partition, damage by degenerate triangles, sections -- is unchanged.
        if (!a.mesh.empty()) {
            for (const Archetype::MeshTri &t : a.mesh) {
                Vector3 n = t.n[0] + t.n[1] + t.n[2];
                if (n.length_squared() < 1e-12f) {
                    n = -(t.p[1] - t.p[0]).cross(t.p[2] - t.p[0]);
                }
                n = n.normalized();

                // Culling. Only a triangle lying flat on a cell boundary can be
                // hidden by a neighbour, and only by an ordinary VOXEL block:
                // two authored surfaces meeting (one stair's newel on the
                // next's) do not fill their cells, so letting one hide the
                // other would open holes where the mask is square and the
                // drawing is not. Both are kept; they face each other inside
                // solid and cost a few triangles.
                int32_t other = -1;
                int axis = -1;
                if (std::abs(n.x) > 0.999f) {
                    axis = 0;
                } else if (std::abs(n.y) > 0.999f) {
                    axis = 1;
                } else if (std::abs(n.z) > 0.999f) {
                    axis = 2;
                }
                if (axis >= 0) {
                    const Vector3 g = (t.p[0] + t.p[1] + t.p[2]) / 3.0f;
                    const float q = g[axis] / cs[axis];
                    if (std::abs(q - std::round(q)) < 1e-3f) {
                        const Vector3 probe = g + n * (cs[axis] * 0.5f);
                        const Vector3i nc(
                            base.x + (int)std::floor(probe.x / cs.x),
                            base.y + (int)std::floor(probe.y / cs.y),
                            base.z + (int)std::floor(probe.z / cs.z));
                        const int32_t nb = c.block_at(nc);
                        if (nb >= 0 && nb != (int32_t)bi && !c.blocks[nb].decorative
                                && parts[c.blocks[nb].archetype].mesh.empty()
                                && brick_material_hides(b.material, c.blocks[nb].material)) {
                            other = nb;
                        }
                    }
                }

                // Godot draws CLOCKWISE as the front, so (b-a) x (c-a) has to
                // point AWAY from the side the face is seen from.
                Vector3 p0 = t.p[0], p1 = t.p[1], p2 = t.p[2];
                Vector3 n0 = t.n[0], n1 = t.n[1], n2 = t.n[2];
                if ((p1 - p0).cross(p2 - p0).dot(n) > 0.0f) {
                    std::swap(p1, p2);
                    std::swap(n1, n2);
                }
                const Vector3 vs[4] = { p0, p1, p2, p1 };
                const Vector3 ns[4] = { n0, n1, n2, n1 };
                // How far each corner is from each of the triangle's REAL
                // edges (MeshTri::feature): its height over the edge opposite
                // it, nothing to the other two. Linear across the triangle,
                // so what the shader gets at a point is exactly its distance
                // to that edge -- what a box's face rectangle gives it. An
                // edge that is not a real one is far off at every corner. UV
                // carries the first two, UV2.x the third (+ AUTHORED_UV2),
                // UV2.y says authored, and whether the part lies turned
                // (stud_turn: its top's lines, as a box's).
                // ...to the real edges nearest it on its face (MeshTri::
                // edge_a), as lines: linear across the triangle all the same.
                const Vector3 pp[3] = { p0, p1, p2 };
                float dist[3][3];
                for (int j = 0; j < 3; ++j) {
                    for (int i = 0; i < 3; ++i) {
                        if (j >= t.edges) {
                            dist[i][j] = BrickWorld::AUTHORED_FAR;
                            continue;
                        }
                        const Vector3 ea = t.edge_a[j], eb = t.edge_b[j];
                        const Vector3 dir = (eb - ea).normalized();
                        const Vector3 off = pp[i] - ea;
                        dist[i][j] = (off - dir * off.dot(dir)).length();
                    }
                }
                const float turned = BrickWorld::stud_turn(a.size, base) ? BrickWorld::AUTHORED_TURNED : BrickWorld::AUTHORED_UV2Y;
                const int corner_of[4] = { 0, 1, 2, 1 };
                for (int k = 0; k < 4; ++k) {
                    const float *dv = dist[corner_of[k]];
                    fb.verts.push_back(block_origin + vs[k]);
                    fb.normals.push_back(ns[k]);
                    fb.colours.push_back(col);
                    fb.uvs.push_back(Vector2(dv[0], dv[1]));
                    fb.uv2s.push_back(Vector2(BrickWorld::AUTHORED_UV2 + dv[2], turned));
                }
                fb.owner.push_back((int32_t)bi);
                fb.other.push_back(other);
                fb.edge.push_back(brick::EDGE_RAW);
                fb.corner.push_back(0);
            }
            continue;
        }

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
                        // So does a neighbour with an authored surface. Its
                        // cell is solid in the mask but its SHAPE need not fill
                        // it -- a round brick leaves the corners of its cells
                        // open -- and hiding this face behind it opens a
                        // square hole round the curve. Drawn, the face is
                        // buried wherever the shape does cover it and costs a
                        // quad there.
                        if (other >= 0 && !parts[c.blocks[other].archetype].mesh.empty()) {
                            other = -1;
                        }
                        // And a see-through one, to an opaque face: that face
                        // is what is seen through it (brick_material_hides).
                        if (other >= 0 && !brick_material_hides(b.material, c.blocks[other].material)) {
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

                        // What each side of the rectangle is (brick::EDGE_*),
                        // for the chamfered mesh. Across a side lies either
                        // nothing of this part -- a free edge -- or more of
                        // this same face.
                        const int32_t this_face = (int32_t)fb.owner.size() - 1;
                        uint32_t edge_grooves = 0; // brick::EDGE_GROOVE_SHIFT
                        uint32_t edge_inner = 0;   // brick::EDGE_INNER_SHIFT
                        const auto local_of = [&](int aa, int bb) -> Vector3i {
                            int lc[3] = { 0, 0, 0 };
                            lc[sa] = si;
                            lc[pa] = aa;
                            lc[pb] = bb;
                            return Vector3i(base.x + lc[0], base.y + lc[1], base.z + lc[2]);
                        };
                        // A block that can back an inside corner: a plain
                        // brick for good, that hides this face. Not furniture,
                        // which reads as open air; not an authored shape,
                        // which need not fill its cells; not a see-through
                        // one.
                        const auto backs = [&](int32_t blk) -> bool {
                            return blk >= 0 && blk != (int32_t)bi && !c.blocks[blk].decorative
                                    && parts[c.blocks[blk].archetype].mesh.empty()
                                    && brick_material_hides(b.material, c.blocks[blk].material);
                        };
                        // A brick SITTING ON BRICKS has a flat bottom: its
                        // bottom edges are square where they rest on the
                        // brick below, the two meeting like printed parts
                        // stacked. Anywhere else -- an overhang, a ledge, a
                        // part over air -- the bottom keeps its bevel. So:
                        //   * a side face's bottom side is FLUSH (straight
                        //     down to the bottom's plane) when every cell
                        //     along the brick's bottom row on that side has
                        //     a plain brick under it (row_supported: the
                        //     whole row, so every rectangle of the face
                        //     agrees, and so does the brick below, which
                        //     floors the half-groove under it);
                        //   * a bottom face resting on a brick (`other`) has
                        //     its bevels laid flat in its own plane
                        //     (chamfer_faces_into, EDGE_DIR_FLAT_BOTTOM): it
                        //     reaches out to its edges, only its corners cut
                        //     where an upright edge is bevelled. Hidden while
                        //     that brick stands; flat when it is shot away.
                        const bool side_face = f != 2 && f != 3;
                        const auto row_supported = [&](int32_t blk, const Vector3i &dir) -> bool {
                            if (blk < 0 || c.blocks[blk].decorative) {
                                return false;
                            }
                            const Archetype &pa_ = parts[c.blocks[blk].archetype];
                            if (!pa_.mesh.empty() || !pa_.is_full_box()) {
                                return false;
                            }
                            const Vector3i p0 = c.blocks[blk].cell - c.origin;
                            const Vector3i sz = pa_.size;
                            const int ax = dir.x != 0 ? 0 : 2;     // across the face
                            const int run = ax == 0 ? 2 : 0;       // along it
                            Vector3i at = p0;
                            at[ax] = (dir[ax] > 0) ? p0[ax] + sz[ax] - 1 : p0[ax];
                            for (int k = 0; k < sz[run]; ++k) {
                                Vector3i cell = at;
                                cell[run] = p0[run] + k;
                                const int32_t under = c.block_at(cell - Vector3i(0, 1, 0));
                                if (under < 0 || under == blk || c.blocks[under].decorative
                                        || !parts[c.blocks[under].archetype].mesh.empty()
                                        || !brick_material_hides(c.blocks[blk].material,
                                                c.blocks[under].material)) {
                                    return false;
                                }
                            }
                            return true;
                        };
                        const bool flat_bottom = f == 3 && a.is_full_box() && other >= 0;
                        const auto side_raw = [&](int which, int a_from, int a_to, int b_from,
                                int b_to, int da, int db) -> uint32_t {
                            // Which way this side faces out, and whether it is
                            // a side face's top: there, a brick standing on
                            // this one flush has a flat bottom, and the groove
                            // between them is this brick's bevel alone -- open
                            // above, under that brick's bottom, which is
                            // hidden. So it gets a floor (below).
                            const int out_axis = da != 0 ? pa : pb;
                            const bool top_edge = side_face && out_axis == 1 && da + db > 0;
                            const bool bottom_edge = side_face && out_axis == 1 && da + db < 0
                                    && row_supported((int32_t)bi, FACE_DIR[f]);
                            const int along_axis = da != 0 ? pb : pa;
                            Vector3i along_dir;
                            along_dir[along_axis] = 1;
                            uint8_t run_trim = 0;
                            Vector3i run_last, run_last_own;
                            bool run_last_flat = false;
                            bool free_edge = false, more_face = false, open = true;
                            bool walled = true;
                            // brick::EDGE_INNER_SHIFT: every cell along the
                            // side is an inside corner.
                            bool inner = a.is_full_box();
                            // ...or would be one for the face ROUND the edge,
                            // where that one is open: it does not draw the
                            // facet this side would leave to it (QUIET).
                            bool inner_beyond = false;
                            // The facet floors (FaceBake::floors): runs of
                            // cells along this side with a block against the
                            // face round the edge AND one diagonally across.
                            const size_t floors_before = fb.floors.size();
                            int at = 0, run_from = -1;
                            // Whether the brick above, flat-bottomed over a
                            // floor, has an open upright corner past `at`:
                            // nothing beside it there. A plain part only: an
                            // authored one has no bevel to meet.
                            const auto corner_open = [&](const Vector3i &beyond, const Vector3i &step) -> bool {
                                const int32_t up = c.block_at(beyond);
                                return up >= 0 && parts[c.blocks[up].archetype].mesh.empty()
                                        && c.block_at(beyond + step) < 0;
                            };
                            const auto close_run = [&]() {
                                if (run_from >= 0) {
                                    if (run_last_flat && corner_open(run_last, along_dir)) {
                                        run_trim |= 2u;
                                    }
                                    // A side face's bottom keeps its floors
                                    // (the third brick's), square to the
                                    // face; where this brick's own upright
                                    // edge is bevelled, the floor stops short.
                                    if (bottom_edge && c.block_at(run_last_own + along_dir) < 0) {
                                        run_trim |= 2u;
                                    }
                                    fb.floors.push_back({ this_face, (uint16_t)run_from,
                                            (uint16_t)at, (uint8_t)which, run_trim });
                                    run_from = -1;
                                    run_trim = 0;
                                }
                            };
                            for (int aa = a_from; aa <= a_to; ++aa) {
                                for (int bb = b_from; bb <= b_to; ++bb, ++at) {
                                    int lc[3] = { 0, 0, 0 };
                                    lc[sa] = si;
                                    lc[pa] = aa + da;
                                    lc[pb] = bb + db;
                                    const bool off = lc[pa] < 0 || lc[pa] >= an
                                            || lc[pb] < 0 || lc[pb] >= bn;
                                    if (!off && a.solid_at(lc[0], lc[1], lc[2])) {
                                        more_face = true;
                                        close_run();
                                        continue;
                                    }
                                    free_edge = true;
                                    // The face round the corner: open to the
                                    // air for good only where no block of any
                                    // kind owns the cell beyond it.
                                    const Vector3i beyond(base.x + lc[0], base.y + lc[1],
                                            base.z + lc[2]);
                                    const int32_t against = c.block_at(beyond);
                                    const int32_t across = c.block_at(beyond + FACE_DIR[f]);
                                    if (against >= 0) {
                                        open = false;
                                        if (!backs(against) || !backs(across)) {
                                            inner = false;
                                        }
                                        // Not beside a part with an authored
                                        // shape either (a cheese slope, a round
                                        // brick): it does not fill its cells,
                                        // and what closes a square corner
                                        // against one is not worked out. The
                                        // bevel stays there.
                                        for (int n = 0; inner && n < 27; ++n) {
                                            const Vector3i d(n % 3 - 1, (n / 3) % 3 - 1, n / 9 - 1);
                                            const int32_t nb = c.block_at(beyond + d);
                                            if (nb >= 0 && !parts[c.blocks[nb].archetype].mesh.empty()) {
                                                inner = false;
                                            }
                                        }
                                        // A third brick, not more of the one
                                        // this stands against: that one's
                                        // face goes on past the edge and is
                                        // pushed out under this (EXTEND).
                                        // Or, on a side face's top, a brick
                                        // standing on this flush: its flat
                                        // bottom over this one's bevel.
                                        const bool flat_above = top_edge && across < 0
                                                && row_supported(against, FACE_DIR[f]);
                                        if ((across < 0 && !flat_above) || across == against) {
                                            close_run();
                                        } else {
                                            const Vector3i own = local_of(aa, bb);
                                            if (run_from < 0) {
                                                run_from = at;
                                                if (flat_above && corner_open(beyond, -along_dir)) {
                                                    run_trim |= 1u;
                                                }
                                                if (bottom_edge && c.block_at(own - along_dir) < 0) {
                                                    run_trim |= 1u;
                                                }
                                            }
                                            run_last = beyond;
                                            run_last_own = own;
                                            run_last_flat = flat_above;
                                        }
                                    } else {
                                        walled = false;
                                        inner = false;
                                        // The face round the edge, seen from
                                        // there: the block this face stands
                                        // against, and one past it beyond.
                                        if (a.is_full_box()
                                                && backs(c.block_at(local_of(aa, bb) + FACE_DIR[f]))
                                                && backs(across)) {
                                            inner_beyond = true;
                                        }
                                        close_run();
                                    }
                                }
                            }
                            close_run();
                            if (free_edge && more_face) {
                                fb.floors.resize(floors_before);
                                return brick::EDGE_FLUSH;
                            }
                            if (!free_edge) {
                                return brick::EDGE_EXTEND;
                            }
                            // An inside corner: square, and pushed out under
                            // the brick round it, which backs it -- no facet,
                            // so no facet floors either.
                            if (inner) {
                                fb.floors.resize(floors_before);
                                edge_inner |= 1u << which;
                                return brick::EDGE_EXTEND;
                            }
                            // The face round the edge is square there and
                            // draws no facet, so this one does -- shaded as
                            // the groove that one's would have been, so the
                            // two never differ where both are drawn.
                            if (inner_beyond) {
                                edge_grooves |= 1u << which;
                                return brick::EDGE_CONVEX;
                            }
                            // One facet for the two faces that share it, where
                            // the one round the corner is open to the air for
                            // good, and so always draws it: an ordinary brick's
                            // only (a shaped part's other face may be FLUSH
                            // there and draw none). If this face is as open as
                            // that one, the lower axis has it. If this one
                            // stands against a brick, that one has it -- and
                            // keeps it when the brick is shot away and this
                            // face appears: its facet is shaded as a groove's
                            // (EDGE_GROOVE_SHIFT), a copy drawn here would not
                            // be, and the two would flicker over each other.
                            const int perp = da != 0 ? pa : pb;
                            if (open && a.is_full_box() && (other >= 0 || sa > perp)) {
                                return brick::EDGE_CONVEX_QUIET;
                            }
                            if (walled) {
                                edge_grooves |= 1u << which;
                            }
                            return brick::EDGE_CONVEX;
                        };
                        const auto side = [&](int which, int a_from, int a_to, int b_from,
                                int b_to, int da, int db) -> uint32_t {
                            const size_t floors_before = fb.floors.size();
                            const uint32_t code = side_raw(which, a_from, a_to, b_from, b_to, da, db);
                            if (code != brick::EDGE_CONVEX && code != brick::EDGE_CONVEX_QUIET) {
                                return code;
                            }
                            const int out_axis = da != 0 ? pa : pb;
                            if (side_face && out_axis == 1 && da + db < 0
                                    && row_supported((int32_t)bi, FACE_DIR[f])) {
                                // A side face's bottom, resting on bricks:
                                // square, straight down.
                                // Its floors stay: where a third brick is
                                // diagonally across, the brick under this one
                                // may have a bevel nobody else closes.
                                edge_grooves &= ~(1u << which);
                                return brick::EDGE_FLUSH;
                            }
                            if (flat_bottom) {
                                // A bottom face resting on a brick: it draws
                                // its own flat strip out to the edge, always
                                // (the side face round the edge may have no
                                // facet to draw for it), and needs no floor.
                                fb.floors.resize(floors_before);
                                return brick::EDGE_CONVEX;
                            }
                            return code;
                        };
                        uint32_t edge = (uint32_t)(
                                (side(0, ai, ai, bj, b1, -1, 0) << brick::EDGE_A_LO)
                                | (side(1, a1, a1, bj, b1, 1, 0) << brick::EDGE_A_HI)
                                | (side(2, ai, a1, bj, bj, 0, -1) << brick::EDGE_B_LO)
                                | (side(3, ai, a1, b1, b1, 0, 1) << brick::EDGE_B_HI)
                                | ((flat_bottom ? brick::EDGE_DIR_FLAT_BOTTOM : f) << brick::EDGE_DIR_SHIFT));
                        // The plugs (brick::EDGE_PLUG_SHIFT): a corner whose
                        // other two faces both have a block against them.
                        const auto taken_at = [&](int aa, int bb) -> bool {
                            int lc[3] = { 0, 0, 0 };
                            lc[sa] = si;
                            lc[pa] = aa;
                            lc[pb] = bb;
                            return c.block_at(Vector3i(base.x + lc[0], base.y + lc[1],
                                    base.z + lc[2])) >= 0;
                        };
                        // Or whose third edge -- the one between those two
                        // faces -- is an INSIDE corner (brick::EDGE_INNER_SHIFT):
                        // square, so the two bevels either side of it meet in
                        // a mitre there too, the wall's end and its foot.
                        // Corner k's cell, and its two outward steps in the
                        // plane.
                        Vector3i corner_cell[4], out_a[4], out_b[4];
                        for (int k = 0; k < 4; ++k) {
                            const Vector3i o = FACE_CORNERS[f][k];
                            const int oc[3] = { o.x, o.y, o.z };
                            const int ca = oc[pa] ? a1 : ai;
                            const int cb = oc[pb] ? b1 : bj;
                            corner_cell[k] = local_of(ca, cb);
                            out_a[k] = Vector3i();
                            out_b[k] = Vector3i();
                            out_a[k][pa] = oc[pa] ? 1 : -1;
                            out_b[k][pb] = oc[pb] ? 1 : -1;
                            const Vector3i &cc = corner_cell[k];
                            const bool third_inner = a.is_full_box()
                                    && ((backs(c.block_at(cc + out_a[k]))
                                                && backs(c.block_at(cc + out_a[k] + out_b[k])))
                                            || (backs(c.block_at(cc + out_b[k]))
                                                && backs(c.block_at(cc + out_b[k] + out_a[k]))));
                            if ((taken_at(ca + (oc[pa] ? 1 : -1), cb)
                                    && taken_at(ca, cb + (oc[pb] ? 1 : -1))) || third_inner) {
                                edge |= 1u << (brick::EDGE_PLUG_SHIFT + k);
                            }
                        }
                        // The caps (brick::EDGE_CAP_SHIFT). A cell of this
                        // slice just past the rectangle, along a free edge:
                        // a face of this block too, standing against another
                        // block (`mask` is still this slice's), with one
                        // against the face round the edge as well.
                        const auto tunnel_at = [&](int aa, int bb, int da, int db) -> bool {
                            if (aa < 0 || aa >= an || bb < 0 || bb >= bn) {
                                return false;
                            }
                            const int32_t beyond = mask[(size_t)aa * bn + bb];
                            return beyond != NO_FACE && beyond >= 0 && taken_at(aa + da, bb + db);
                        };
                        const auto code_of = [&](int shift) -> uint32_t {
                            return (edge >> shift) & 3u;
                        };
                        const bool a_lo_on = code_of(brick::EDGE_A_LO) == brick::EDGE_EXTEND;
                        const bool a_hi_on = code_of(brick::EDGE_A_HI) == brick::EDGE_EXTEND;
                        const bool b_lo_on = code_of(brick::EDGE_B_LO) == brick::EDGE_EXTEND;
                        const bool b_hi_on = code_of(brick::EDGE_B_HI) == brick::EDGE_EXTEND;
                        uint32_t caps = 0;
                        if (code_of(brick::EDGE_A_LO) == brick::EDGE_CONVEX) {
                            caps |= (b_lo_on && tunnel_at(ai, bj - 1, -1, 0)) ? 1u << 0 : 0u;
                            caps |= (b_hi_on && tunnel_at(ai, b1 + 1, -1, 0)) ? 1u << 1 : 0u;
                        }
                        if (code_of(brick::EDGE_A_HI) == brick::EDGE_CONVEX) {
                            caps |= (b_lo_on && tunnel_at(a1, bj - 1, 1, 0)) ? 1u << 2 : 0u;
                            caps |= (b_hi_on && tunnel_at(a1, b1 + 1, 1, 0)) ? 1u << 3 : 0u;
                        }
                        if (code_of(brick::EDGE_B_LO) == brick::EDGE_CONVEX) {
                            caps |= (a_lo_on && tunnel_at(ai - 1, bj, 0, -1)) ? 1u << 4 : 0u;
                            caps |= (a_hi_on && tunnel_at(a1 + 1, bj, 0, -1)) ? 1u << 5 : 0u;
                        }
                        if (code_of(brick::EDGE_B_HI) == brick::EDGE_CONVEX) {
                            caps |= (a_lo_on && tunnel_at(ai - 1, b1, 0, 1)) ? 1u << 6 : 0u;
                            caps |= (a_hi_on && tunnel_at(a1 + 1, b1, 0, 1)) ? 1u << 7 : 0u;
                        }
                        edge |= caps << brick::EDGE_CAP_SHIFT;
                        // A bevelled side running into an INSIDE corner at
                        // one end (brick::EDGE_INNER_SHIFT). Its facet stops
                        // at the brick's corner there, and either:
                        //   * the face round the edge is square at that end
                        //     too (a brick diagonally below it), or the facet
                        //     is a groove: the facet is CAPPED across its end
                        //     (the cap bit of that end) -- unless the floor
                        //     the corner stands on is pushed out under it and
                        //     shows there already, when a cap would fight it;
                        //   * or that face is bevelled along the corner's
                        //     edge: the two bevels meet in a MITRE (the plug
                        //     bit of the corner), as at a plug.
                        const Vector3i fd = FACE_DIR[f];
                        uint8_t corners = 0;
                        for (int k = 0; k < 4; ++k) {
                            const Vector3i o = FACE_CORNERS[f][k];
                            const int ia = o[pa] ? 1 : 0;           // the A side at k
                            const int ib = 2 + (o[pb] ? 1 : 0);     // the B side at k
                            const bool inner_a = (edge_inner >> ia) & 1u;
                            const bool inner_b = (edge_inner >> ib) & 1u;
                            if (inner_a == inner_b) {
                                continue;
                            }
                            edge &= ~(1u << (brick::EDGE_PLUG_SHIFT + k));
                            const int s_side = inner_a ? ib : ia;
                            if (code_of(s_side * 2) != brick::EDGE_CONVEX) {
                                continue;
                            }
                            const Vector3i g1 = inner_a ? out_a[k] : out_b[k];
                            const Vector3i g2 = inner_a ? out_b[k] : out_a[k];
                            const Vector3i &cc = corner_cell[k];
                            // A groove's other wall: a plain brick there. An
                            // authored shape or a see-through one is drawn
                            // against as open air, and is that here too.
                            const int32_t pb_blk = backs(c.block_at(cc + g2)) ? c.block_at(cc + g2) : -1;
                            const int32_t d_blk = c.block_at(cc + g1 + g2);
                            // The bevel a mitre would meet runs along a
                            // bottom edge that rests on bricks -- the inside
                            // corner is a side face's foot and the face round
                            // the corner is FLUSH there, or this is a flat
                            // bottom -- and has none (side() above). The facet
                            // just stops at the corner: under it is the bevel
                            // of the brick this stands on.
                            const bool bottom_corner = flat_bottom
                                    || (side_face && (inner_a ? pa : pb) == 1
                                            && !((inner_a ? o[pa] : o[pb]) != 0)
                                            && row_supported((int32_t)bi, g2));
                            uint8_t state;
                            if (pb_blk < 0 && !backs(d_blk)) {
                                state = bottom_corner ? brick::CORNER_COVERED : brick::CORNER_MITRE;
                            } else {
                                const int32_t e_blk = c.block_at(cc + g1 + g2 + fd);
                                const int32_t y_blk = c.block_at(cc + g1 + fd);
                                const bool e_inner = backs(e_blk) && backs(c.block_at(cc + g2 + fd));
                                const bool covered = (e_blk >= 0 && e_blk == y_blk) || e_inner
                                        || (pb_blk < 0 && e_blk >= 0 && e_blk == d_blk);
                                state = covered ? brick::CORNER_COVERED : brick::CORNER_CAP;
                            }
                            corners |= (uint8_t)(state << (k * 2));
                        }
                        edge |= edge_grooves << brick::EDGE_GROOVE_SHIFT;
                        edge |= edge_inner << brick::EDGE_INNER_SHIFT;
                        fb.edge.push_back(edge);
                        fb.corner.push_back(corners);
                    }
                }
            }
        }
    }
    fb.section_faces[(size_t)sec] = (int32_t)fb.owner.size() - fb.section_first[(size_t)sec];
    }

    static std::atomic<uint32_t> bakes_made{0};
    fb.serial = bakes_made.fetch_add(1, std::memory_order_relaxed) + 1;
    fb.valid = true;
    fb.bake_ms = std::chrono::duration<double, std::milli>(
            std::chrono::steady_clock::now() - t0).count();
}

void BrickWorld::bake_chunk_faces(Chunk &c) {
    bake_faces_into(c, archetypes, c.bake);
    // A new bake numbers its faces afresh: the patch baseline described the
    // old one (update_index_regions).
    c.live_indices = PackedInt32Array();
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
            chunks[chunk_id].live_indices = PackedInt32Array();
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

std::shared_ptr<const std::vector<Archetype>> BrickWorld::palette_snapshot() {
    if (!parts_snapshot) {
        parts_snapshot = std::make_shared<const std::vector<Archetype>>(archetypes);
    }
    return parts_snapshot;
}

void BrickWorld::bake_chunk_async(int chunk_id) {
    if (!valid_chunk(chunk_id) || chunks[chunk_id].bake.valid || bake_pending(chunk_id)) {
        return;
    }
    auto job = std::make_unique<BakeJob>();
    job->chunk_id = chunk_id;
    // The palette is copied rather than shared: baking a new archetype on the
    // main thread would otherwise reallocate underneath the worker.
    job->parts = palette_snapshot();
    BakeJob *raw = job.get();
    const Chunk *cp = &chunks[chunk_id]; // stable: chunks is a deque
    raw->worker = std::thread([raw, cp]() {
        bake_faces_into(*cp, *raw->parts, raw->bake);
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
Dictionary BrickWorld::add_merged_shapes(RID body, int chunk_id, Vector3 offset, int section,
        bool skip_decorative) {
    Dictionary out;
    const Chunk &c = chunks[chunk_id];
    std::vector<const Block *> blocks;
    blocks.reserve(c.blocks.size());
    for (const Block &b : c.blocks) {
        if (b.alive && !(skip_decorative && b.decorative)
                && (section < 0 || c.section_of(b.cell) == section)) {
            blocks.push_back(&b);
        }
    }
    out["map"] = Dictionary();
    out["count"] = merge_blocks_into(body, c, offset, blocks);
    out["merged"] = true;
    return out;
}

PackedInt32Array BrickWorld::add_band_shapes(const Array &bodies, int chunk_id, Vector3 offset,
        const PackedInt32Array &sections, bool skip_decorative) {
    PackedInt32Array counts;
    counts.resize(sections.size());
    for (int64_t i = 0; i < sections.size(); ++i) {
        counts.set(i, 0);
    }
    if (!valid_chunk(chunk_id) || bodies.size() != sections.size()) {
        return counts;
    }
    const Chunk &c = chunks[chunk_id];
    // Which slot of the request each band is, and the blocks of each, in one
    // walk over the chunk.
    std::vector<int> slot((size_t)std::max(c.sections(), 1), -1);
    for (int64_t i = 0; i < sections.size(); ++i) {
        const int s = sections[i];
        if (s >= 0 && s < (int)slot.size()) {
            slot[(size_t)s] = (int)i;
        }
    }
    std::vector<std::vector<const Block *>> lists((size_t)sections.size());
    for (const Block &b : c.blocks) {
        if (!b.alive || (skip_decorative && b.decorative)) {
            continue;
        }
        const int k = slot[(size_t)c.section_of(b.cell)];
        if (k >= 0) {
            lists[(size_t)k].push_back(&b);
        }
    }
    for (int64_t i = 0; i < sections.size(); ++i) {
        counts.set(i, merge_blocks_into((RID)bodies[i], c, offset, lists[(size_t)i]));
    }
    return counts;
}

namespace {

// A merge's cells are bits, a row of them to a run of 64-bit words
// (BrickWorld::merge_blocks_into). These are the runs of a row, [x0, x1].
inline int ctz64(uint64_t v) {
#if defined(_MSC_VER)
    unsigned long i;
    _BitScanForward64(&i, v);
    return (int)i;
#else
    return __builtin_ctzll(v);
#endif
}

// The bits of word `w` that are in [x0, x1].
inline uint64_t run_mask(int w, int x0, int x1) {
    const int lo = x0 > (w << 6) ? x0 - (w << 6) : 0;
    const int hi = x1 < (w << 6) + 63 ? x1 - (w << 6) : 63;
    const uint64_t up = hi == 63 ? ~0ull : ((1ull << (hi + 1)) - 1);
    return up & (~0ull << lo);
}

inline void bit_run_set(uint64_t *r, int x0, int x1) {
    for (int w = x0 >> 6; w <= (x1 >> 6); ++w) {
        r[w] |= run_mask(w, x0, x1);
    }
}

inline void bit_run_clear(uint64_t *r, int x0, int x1) {
    for (int w = x0 >> 6; w <= (x1 >> 6); ++w) {
        r[w] &= ~run_mask(w, x0, x1);
    }
}

inline bool bit_run_full(const uint64_t *r, int x0, int x1) {
    for (int w = x0 >> 6; w <= (x1 >> 6); ++w) {
        const uint64_t m = run_mask(w, x0, x1);
        if ((r[w] & m) != m) {
            return false;
        }
    }
    return true;
}

// The first set bit at or after x, or n if there is none before n.
inline int bit_next_set(const uint64_t *r, int x, int n) {
    while (x < n) {
        const int w = x >> 6;
        const uint64_t v = r[w] & (~0ull << (x & 63));
        if (v != 0) {
            const int f = (w << 6) + ctz64(v);
            return f < n ? f : n;
        }
        x = (w + 1) << 6;
    }
    return n;
}

// The first clear bit at or after x, or n.
inline int bit_next_clear(const uint64_t *r, int x, int n) {
    while (x < n) {
        const int w = x >> 6;
        const uint64_t v = ~r[w] & (~0ull << (x & 63));
        if (v != 0) {
            const int f = (w << 6) + ctz64(v);
            return f < n ? f : n;
        }
        x = (w + 1) << 6;
    }
    return n;
}

} // namespace

int BrickWorld::merge_blocks_into(RID body, const Chunk &c, Vector3 offset,
        const std::vector<const Block *> &blocks) {
    PhysicsServer3D *ps = PhysicsServer3D::get_singleton();
    const Vector3i d = c.dims;
    const Vector3 cs = cell_size();
    const int64_t n = (int64_t)d.x * d.y * d.z;
    if (n <= 0) {
        return 0;
    }

    // The grid is only as tall as what is being merged: one band of a tall
    // chunk is a few dozen of its hundreds of rows, and allocating and scanning
    // the whole chunk's grid for every band was most of a band's rebuild.
    int w_lo = d.y, w_hi = -1;
    for (const Block *b : blocks) {
        const int y0 = b->cell.y - c.origin.y;
        const int y1 = y0 + archetypes[b->archetype].size.y - 1;
        w_lo = y0 < w_lo ? y0 : w_lo;
        w_hi = y1 > w_hi ? y1 : w_hi;
    }
    w_lo = w_lo < 0 ? 0 : w_lo;
    w_hi = w_hi >= d.y ? d.y - 1 : w_hi;
    const int wy = w_hi >= w_lo ? w_hi - w_lo + 1 : 0;
    // The cells as bits, a row of them (x) to a run of 64-bit words. Most of a
    // building's box is air -- its rooms -- and at a byte a cell a 22,000-brick
    // tower was 3.1 million of them: 2-4 ms to fill and 3-4 more to walk, most
    // of the tick it toppled in (2026-10-15). In words the air goes by 64 cells
    // at a time and a brick is marked a row at a stroke. The walk is the one it
    // was -- z, then y, then x, each box as long in x, then as tall, then as
    // deep as it goes -- so the boxes are the same ones, in the same order.
    const int words = (d.x + 63) >> 6;
    thread_local std::vector<uint64_t> bits;
    bits.assign((size_t)words * (size_t)wy * (size_t)d.z, 0);
    auto row = [&](int y, int z) -> uint64_t * {
        return bits.data() + (size_t)words * ((size_t)(y - w_lo) + (size_t)wy * (size_t)z);
    };
    // Parts with authored hulls are kept out of the merge -- their cells are not
    // what they collide as -- and get their own shapes after it.
    std::vector<const Block *> hulled;
    // The rows anything was marked in.
    int y_lo = d.y, y_hi = -1;
    for (const Block *bp : blocks) {
        const Block &b = *bp;
        const Archetype &a = archetypes[b.archetype];
        if (!a.hulls.empty()) {
            hulled.push_back(&b);
            continue;
        }
        const Vector3i base = b.cell - c.origin;
        if (a.is_full_box()) {
            const int x0 = base.x < 0 ? 0 : base.x;
            const int x1 = (base.x + a.size.x < d.x ? base.x + a.size.x : d.x) - 1;
            const int y0 = base.y < w_lo ? w_lo : base.y;
            const int y1 = base.y + a.size.y - 1 > w_hi ? w_hi : base.y + a.size.y - 1;
            const int z0 = base.z < 0 ? 0 : base.z;
            const int z1 = (base.z + a.size.z < d.z ? base.z + a.size.z : d.z) - 1;
            if (x0 > x1 || y0 > y1 || z0 > z1) {
                continue;
            }
            for (int z = z0; z <= z1; ++z) {
                for (int y = y0; y <= y1; ++y) {
                    bit_run_set(row(y, z), x0, x1);
                }
            }
            y_lo = y0 < y_lo ? y0 : y_lo;
            y_hi = y1 > y_hi ? y1 : y_hi;
            continue;
        }
        for (int lx = 0; lx < a.size.x; ++lx) {
            for (int ly = 0; ly < a.size.y; ++ly) {
                for (int lz = 0; lz < a.size.z; ++lz) {
                    if (!a.solid_at(lx, ly, lz)) {
                        continue;
                    }
                    const int x = base.x + lx, y = base.y + ly, z = base.z + lz;
                    if (x < 0 || y < w_lo || z < 0 || x >= d.x || y > w_hi || z >= d.z) {
                        continue;
                    }
                    row(y, z)[x >> 6] |= 1ull << (x & 63);
                    y_lo = y < y_lo ? y : y_lo;
                    y_hi = y > y_hi ? y : y_hi;
                }
            }
        }
    }

    int count = 0;
    for (int z = 0; z < d.z; ++z) {
        for (int y = y_lo; y <= y_hi; ++y) {
            uint64_t *r = row(y, z);
            for (int x = bit_next_set(r, 0, d.x); x < d.x;) {
                const int x1 = bit_next_clear(r, x, d.x) - 1;
                int y1 = y;
                while (y1 + 1 <= y_hi && bit_run_full(row(y1 + 1, z), x, x1)) {
                    ++y1;
                }
                int z1 = z;
                while (z1 + 1 < d.z) {
                    bool plane = true;
                    for (int yy = y; yy <= y1 && plane; ++yy) {
                        plane = bit_run_full(row(yy, z1 + 1), x, x1);
                    }
                    if (!plane) {
                        break;
                    }
                    ++z1;
                }
                for (int zz = z; zz <= z1; ++zz) {
                    for (int yy = y; yy <= y1; ++yy) {
                        bit_run_clear(row(yy, zz), x, x1);
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
                x = bit_next_set(r, x1 + 1, d.x);
            }
        }
    }

    for (const Block *b : hulled) {
        const Archetype &a = archetypes[b->archetype];
        const Vector3i base = b->cell - c.origin;
        const Vector3 origin(base.x * cs.x, base.y * cs.y, base.z * cs.z);
        for (int h = 0; h < (int)a.hulls.size(); ++h) {
            ps->body_add_shape(body, hull_shape_for(b->archetype, h),
                    Transform3D(Basis(), origin - offset));
            ++count;
        }
    }

    return count;
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
        bool merge, int section, bool skip_decorative) {
    Dictionary out;
    if (!valid_chunk(chunk_id)) {
        return out;
    }
    PhysicsServer3D *ps = PhysicsServer3D::get_singleton();
    const Chunk &c = chunks[chunk_id];

    if (merge) {
        return add_merged_shapes(body, chunk_id, offset, section, skip_decorative);
    }

    Dictionary map;
    int next = 0;
    for (size_t bi = 0; bi < c.blocks.size(); ++bi) {
        const Block &b = c.blocks[bi];
        if (b.removed || (skip_dead && !b.alive)) {
            continue;
        }
        if (section >= 0 && c.section_of(b.cell) != section) {
            continue;
        }
        if (skip_decorative && b.decorative) {
            continue;
        }
        const Archetype &a = archetypes[b.archetype];
        PackedInt32Array mine;
        if (!a.hulls.empty()) {
            // Authored hulls: the part collides as what it draws. One shared
            // shape per hull, placed at the block's origin.
            const Vector3 cs = cell_size();
            const Vector3i base = b.cell - c.origin;
            const Vector3 origin(base.x * cs.x, base.y * cs.y, base.z * cs.z);
            for (int h = 0; h < (int)a.hulls.size(); ++h) {
                ps->body_add_shape(body, hull_shape_for(b.archetype, h),
                        Transform3D(Basis(), origin - offset));
                mine.push_back(next);
                if (!b.alive) {
                    ps->body_set_shape_disabled(body, next, true);
                }
                ++next;
            }
        } else if (a.is_full_box()) {
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

PackedInt32Array BrickWorld::get_block_sections(int chunk_id,
        const PackedInt32Array &block_ids, bool skip_decorative) const {
    PackedInt32Array out;
    out.resize(block_ids.size());
    for (int64_t i = 0; i < block_ids.size(); ++i) {
        out.set(i, -1);
    }
    if (!valid_chunk(chunk_id)) {
        return out;
    }
    const Chunk &c = chunks[chunk_id];
    for (int64_t i = 0; i < block_ids.size(); ++i) {
        const int32_t bid = block_ids[i];
        if (bid >= 0 && bid < (int32_t)c.blocks.size()
                && !(skip_decorative && c.blocks[(size_t)bid].decorative)) {
            out.set(i, c.section_of(c.blocks[(size_t)bid].cell));
        }
    }
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
    for (auto &j : coarse_jobs) {
        if (j->worker.joinable()) {
            j->worker.join();
        }
    }
    for (auto &j : chamfer_jobs) {
        if (j->worker.joinable()) {
            j->worker.join();
        }
    }
    PhysicsServer3D *ps = PhysicsServer3D::get_singleton();
    if (ps != nullptr) {
        for (auto &kv : box_shapes) {
            ps->free_rid(kv.second);
        }
        for (auto &kv : hull_shapes) {
            ps->free_rid(kv.second);
        }
    }
    box_shapes.clear();
    hull_shapes.clear();
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

void BrickWorld::track_indices(Chunk &c, int emitted) {
    const FaceBake &fb = c.bake;
    const int faces = fb.face_count();
    const size_t nb = c.blocks.size();
    c.idx_alive.resize(nb);
    for (size_t i = 0; i < nb; ++i) {
        c.idx_alive[i] = c.blocks[i].alive ? 1 : 0;
    }
    c.idx_own_first.assign(nb, 0);
    c.idx_own_n.assign(nb, 0);
    c.idx_rev_at.assign(nb + 1, 0);
    for (int f = 0; f < faces; ++f) {
        const int32_t o = fb.owner[f];
        if (c.idx_own_n[(size_t)o] == 0) {
            c.idx_own_first[(size_t)o] = f;
        }
        ++c.idx_own_n[(size_t)o];
        const int32_t other = fb.other[f];
        if (other >= 0) {
            ++c.idx_rev_at[(size_t)other + 1];
        }
    }
    for (size_t i = 0; i < nb; ++i) {
        c.idx_rev_at[i + 1] += c.idx_rev_at[i];
    }
    c.idx_rev.resize((size_t)c.idx_rev_at[nb]);
    std::vector<int32_t> at(c.idx_rev_at.begin(), c.idx_rev_at.end() - 1);
    for (int f = 0; f < faces; ++f) {
        const int32_t other = fb.other[f];
        if (other >= 0) {
            c.idx_rev[(size_t)at[(size_t)other]++] = f;
        }
    }
    c.idx_serial = fb.serial;
    c.idx_emitted = emitted;
    ++index_stats[1];
}

bool BrickWorld::refill_changed(Chunk &c, std::vector<int32_t> &changed) {
    const FaceBake &fb = c.bake;
    const int faces = fb.face_count();
    const size_t nb = c.blocks.size();
    if (!fb.valid || c.idx_serial != fb.serial || c.idx_alive.size() != nb
            || c.idx_own_n.size() != nb || c.live_indices.size() != (int64_t)faces * 6) {
        return false;
    }
    // Which blocks changed: a byte a block, against a walk of every face.
    std::vector<int32_t> dirty;
    for (size_t i = 0; i < nb; ++i) {
        if ((c.blocks[i].alive ? 1 : 0) != c.idx_alive[i]) {
            dirty.push_back((int32_t)i);
        }
    }
    // Most of it changed: the full fill is the cheaper walk.
    if (dirty.size() > nb / 4 + 64) {
        return false;
    }
    int32_t *w = c.live_indices.ptrw();
    auto redo = [&](int f) {
        const int32_t owner = fb.owner[f];
        const int32_t other = fb.other[f];
        const bool drawn = c.blocks[owner].alive && (other < 0 || !c.blocks[other].alive);
        const int base = f * 6;
        // Slot 1 is v0 + 1 when drawn and 0 when not (slot 0 is 0 both ways
        // for the first face).
        if (drawn == (w[base + 1] != 0)) {
            return;
        }
        if (drawn) {
            const int v0 = f * 4;
            w[base + 0] = v0 + 0;
            w[base + 1] = v0 + 1;
            w[base + 2] = v0 + 2;
            w[base + 3] = v0 + 1;
            w[base + 4] = v0 + 3;
            w[base + 5] = v0 + 2;
            ++c.idx_emitted;
        } else {
            for (int k = 0; k < 6; ++k) {
                w[base + k] = 0;
            }
            --c.idx_emitted;
        }
        changed.push_back(f);
    };
    for (int32_t x : dirty) {
        const int32_t f0 = c.idx_own_first[(size_t)x];
        const int32_t n = c.idx_own_n[(size_t)x];
        for (int32_t f = f0; f < f0 + n; ++f) {
            redo(f);
        }
        for (int32_t k = c.idx_rev_at[(size_t)x]; k < c.idx_rev_at[(size_t)x + 1]; ++k) {
            redo(c.idx_rev[(size_t)k]);
        }
        c.idx_alive[(size_t)x] = c.blocks[(size_t)x].alive ? 1 : 0;
    }
    ++index_stats[0];
    index_stats[2] += (int64_t)changed.size();
    if (index_check) {
        index_verify(c);
    }
    return true;
}

void BrickWorld::index_verify(Chunk &c) {
    MeshStats scratch;
    PackedInt32Array full;
    fill_indices(c, scratch, full);
    if (full.size() != c.live_indices.size()
            || memcmp(full.ptr(), c.live_indices.ptr(), (size_t)full.size() * 4) != 0) {
        ++index_stats[3];
    }
}

Dictionary BrickWorld::get_memory_report() const {
    Dictionary d;
    int64_t occupancy = 0, blocks = 0, bake_verts = 0, bake_topology = 0, indices = 0, joints = 0;
    int64_t joint_overlay = 0;
    int live = 0, baked = 0, total_blocks = 0, total_faces = 0;

    for (size_t i = 0; i < chunks.size(); ++i) {
        if (!chunk_live[i]) {
            continue;
        }
        ++live;
        const Chunk &c = chunks[i];
        occupancy += c.occupancy.bytes();
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
        if (i < joint_cache.size()) {
            const brick::JointCache &jc = joint_cache[i];
            const int64_t over = (int64_t)jc.over_runs.capacity() * sizeof(brick::JointRun)
                    + (int64_t)(jc.over_at.capacity() + jc.over_n.capacity()) * sizeof(int32_t);
            joints += (int64_t)jc.runs.capacity() * sizeof(brick::JointRun)
                    + (int64_t)jc.at.capacity() * sizeof(int32_t) + over;
            joint_overlay += over;
        }
    }

    const int64_t total = occupancy + blocks + bake_verts + bake_topology + indices + joints;
    d["chunks"] = live;
    d["chunks_baked"] = baked;
    d["blocks"] = total_blocks;
    d["baked_faces"] = total_faces;
    d["occupancy_bytes"] = occupancy;
    d["block_bytes"] = blocks;
    d["bake_vertex_bytes"] = bake_verts;
    d["bake_topology_bytes"] = bake_topology;
    d["index_bytes"] = indices;
    d["joint_bytes"] = joints;
    // Of which, the runs redone in place since each cache was last built whole
    // (JointCache::over_runs).
    d["joint_overlay_bytes"] = joint_overlay;
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

    int first = -1;
    int last = -1;
    int n = 0;
    const int32_t *b = nullptr;
    std::vector<int32_t> changed;
    // Only what changed, when it can: a 24,000-brick piece under fire walked
    // all of its faces for every hit, 2-9 ms each (2026-10-20).
    if (refill_changed(c, changed)) {
        n = c.live_indices.size();
        b = c.live_indices.ptr();
        st.faces_emitted = c.idx_emitted;
        for (int32_t f : changed) {
            first = (first < 0 || f * 6 < first) ? f * 6 : first;
            last = (f * 6 + 5 > last) ? f * 6 + 5 : last;
        }
    } else {
        PackedInt32Array next;
        fill_indices(c, st, next);
        n = next.size();
        const int32_t *a = c.live_indices.ptr();
        const int32_t *nb = next.ptr();
        for (int i = 0; i < n; ++i) {
            if (a[i] != nb[i]) {
                if (first < 0) {
                    first = i;
                }
                last = i;
            }
        }
        c.live_indices = next;
        track_indices(c, st.faces_emitted);
        b = c.live_indices.ptr();
    }

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

void BrickWorld::set_chunk_section_plates(int chunk_id, int plates) {
    if (!valid_chunk(chunk_id)) {
        return;
    }
    Chunk &c = chunks[chunk_id];
    const int want = plates > 0 ? plates : 0;
    if (c.section_plates == want) {
        return;
    }
    c.section_plates = want;
    // The face ORDER depends on this, so anything already baked is now baked
    // in the wrong order.
    c.bake.valid = false;
    if (bake_pending(chunk_id)) {
        settle_bake_job(chunk_id, false);
    }
}

void BrickWorld::set_chunk_section_studs(int chunk_id, int studs) {
    if (!valid_chunk(chunk_id)) {
        return;
    }
    Chunk &c = chunks[chunk_id];
    const int want = studs > 0 ? studs : 0;
    if (c.section_studs == want) {
        return;
    }
    c.section_studs = want;
    // As set_chunk_section_plates: the face order follows the sections.
    c.bake.valid = false;
    if (bake_pending(chunk_id)) {
        settle_bake_job(chunk_id, false);
    }
}

int BrickWorld::get_chunk_sections(int chunk_id) const {
    return valid_chunk(chunk_id) ? chunks[chunk_id].sections() : 0;
}

bool BrickWorld::has_bake(int chunk_id) const {
    return valid_chunk(chunk_id) && chunks[chunk_id].bake.valid;
}

Array BrickWorld::build_chunk_mesh_section(int chunk_id, int section) {
    if (!valid_chunk(chunk_id)) {
        return Array();
    }
    Chunk &c = chunks[chunk_id];
    MeshStats &st = stats[chunk_id];
    if (!c.bake.valid) {
        bake_chunk_faces(c);
        st.bake_ms = c.bake.bake_ms;
    }
    if (section < 0 || section >= c.bake.section_count()) {
        return Array();
    }
    // The whole-chunk buffer is the BASELINE the next patch diffs against
    // (update_index_regions), and it has to be what the bands DRAW. It was set
    // the first time a patch was asked for -- after the hit the patch was for,
    // so that hit was in the baseline, diffed as no change and never drawn:
    // killed bricks went on being drawn, floating, until the building was
    // rebuilt (--ghost, 2026-10-02). Filling it whole here made the first band
    // after a bake pay for every face in the chunk (57 ms against 5.5), so each
    // band writes its own range of it instead, as it computes it below: what is
    // in the baseline is exactly what each band was built with. A band not
    // built yet since the bake is all degenerate there.
    const int first = c.bake.section_first[(size_t)section];
    const int faces = c.bake.section_faces[(size_t)section];
    if (faces <= 0) {
        return Array();
    }
    const int v0 = first * 4;
    const int vn = faces * 4;

    Array arrays;
    arrays.resize(Mesh::ARRAY_MAX);
    arrays[Mesh::ARRAY_VERTEX] = c.bake.verts.slice(v0, v0 + vn);
    arrays[Mesh::ARRAY_NORMAL] = c.bake.normals.slice(v0, v0 + vn);
    arrays[Mesh::ARRAY_COLOR] = c.bake.colours.slice(v0, v0 + vn);
    arrays[Mesh::ARRAY_TEX_UV] = c.bake.uvs.slice(v0, v0 + vn);
    arrays[Mesh::ARRAY_TEX_UV2] = c.bake.uv2s.slice(v0, v0 + vn);

    // Local indices: the same six per face the whole-chunk path writes, with
    // the band's vertex base taken off.
    // Computed from the faces themselves rather than read out of the chunk
    // buffer, so this band does not depend on that buffer being current.
    PackedInt32Array idx;
    idx.resize((int64_t)faces * 6);
    int32_t *w = idx.ptrw();
    const int64_t total = (int64_t)c.bake.face_count() * 6;
    if (c.live_indices.size() != total) {
        c.live_indices.resize(total);
        std::fill(c.live_indices.ptrw(), c.live_indices.ptrw() + total, 0);
    }
    int32_t *live = c.live_indices.ptrw();
    for (int f = 0; f < faces; ++f) {
        const int face = first + f;
        const int32_t owner = c.bake.owner[(size_t)face];
        const int32_t other = c.bake.other[(size_t)face];
        const bool drawn = c.blocks[owner].alive
                && (other < 0 || !c.blocks[other].alive);
        const int to = f * 6;
        int32_t *at = live + (size_t)face * 6;
        if (!drawn) {
            // A culled face stays a degenerate triangle, or the band's buffer
            // changes length when something breaks and it can never be patched
            // again.
            for (int k = 0; k < 6; ++k) {
                w[to + k] = 0;
                at[k] = 0;
            }
            continue;
        }
        const int32_t base = face * 4 - v0;
        w[to + 0] = base + 0;
        w[to + 1] = base + 1;
        w[to + 2] = base + 2;
        w[to + 3] = base + 1;
        w[to + 4] = base + 3;
        w[to + 5] = base + 2;
        // In the chunk's numbering, as fill_indices writes it.
        const int32_t g = face * 4;
        at[0] = g + 0;
        at[1] = g + 1;
        at[2] = g + 2;
        at[3] = g + 1;
        at[4] = g + 3;
        at[5] = g + 2;
    }
    arrays[Mesh::ARRAY_INDEX] = idx;
    return arrays;
}

Array BrickWorld::update_index_regions(int chunk_id, int index_bytes) {
    Array out;
    if (!valid_chunk(chunk_id)) {
        return out;
    }
    Chunk &c = chunks[chunk_id];
    // Nothing to patch FROM -- no bake (a block placed or removed since: a room
    // laid or cleared), or no baseline for it (a fresh bake no band has been
    // built from). It used to answer with no regions, which a caller reads as
    // "patched, nothing moved" -- and the change this patch was for was never
    // drawn. Section -1 says: build again (CityScene._remesh,
    // IslandManager._patch_bands).
    Dictionary cannot;
    cannot["section"] = -1;
    if (!c.bake.valid) {
        out.push_back(cannot);
        return out;
    }
    const auto t0 = std::chrono::steady_clock::now();
    MeshStats &st = stats[chunk_id];
    st.faces_emitted = 0;
    st.faces_culled = 0;

    PackedInt32Array next;
    fill_indices(c, st, next);

    if (c.live_indices.size() != next.size()) {
        c.live_indices = next;
        st.indices = next.size();
        st.compact_ms = std::chrono::duration<double, std::milli>(
                std::chrono::steady_clock::now() - t0).count();
        out.push_back(cannot);
        return out;
    }
    const int32_t *a = c.live_indices.ptr();
    const int32_t *b = next.ptr();

    for (int sec = 0; sec < c.bake.section_count(); ++sec) {
        const int first = c.bake.section_first[(size_t)sec];
        const int faces = c.bake.section_faces[(size_t)sec];
        if (faces <= 0) {
            continue;
        }
        const int lo = first * 6;
        const int hi = lo + faces * 6;
        const int v0 = first * 4;
        int changed_lo = -1;
        int changed_hi = -1;
        for (int i = lo; i < hi; ++i) {
            if (a[i] != b[i]) {
                if (changed_lo < 0) {
                    changed_lo = i;
                }
                changed_hi = i;
            }
        }
        if (changed_lo < 0) {
            continue;
        }
        // Whole indices, and in the band's own numbering.
        const int n = changed_hi - changed_lo + 1;
        PackedByteArray data;
        data.resize((int64_t)n * index_bytes);
        uint8_t *w = data.ptrw();
        for (int i = 0; i < n; ++i) {
            const int32_t val = b[changed_lo + i] == 0 ? 0 : b[changed_lo + i] - v0;
            if (index_bytes == 2) {
                const uint16_t v = (uint16_t)val;
                std::memcpy(w + (size_t)i * 2, &v, 2);
            } else {
                std::memcpy(w + (size_t)i * 4, &val, 4);
            }
        }
        Dictionary d;
        d["section"] = sec;
        d["offset"] = (changed_lo - lo) * index_bytes;
        d["data"] = data;
        d["changed_bytes"] = data.size();
        out.push_back(d);
    }

    c.live_indices = next;
    st.indices = next.size();
    st.compact_ms = std::chrono::duration<double, std::milli>(
            std::chrono::steady_clock::now() - t0).count();
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
    track_indices(c, st.faces_emitted);
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

// --- the chamfered near mesh -------------------------------------------------
//
// Every baked face again, with the free edges of its brick cut off at 45
// degrees (Docs/BrickBevel.md). It is the face bake's faces in the face bake's
// order, each one now a few quads instead of one, so everything the flat mesh
// does with a face still holds: a face is drawn or it is not, by the same rule,
// and damage is zeros written over its indices.
//
// Nothing here asks what the brick next door is doing, and that is the design
// (Terrain.md 22.13: backing, not agreement). A face only knows its own four
// sides, as the bake found them (brick::EDGE_*):
//
//   * a free edge of the brick is drawn IN by the bevel and gets a facet down
//     to where the face round the corner starts. Both faces of an edge draw
//     that facet -- either may be hidden behind a neighbour while the other is
//     seen -- and the two copies are the same quad shaded the same way.
//   * a side that is not an edge of the brick is pushed OUT by the bevel,
//     under whatever stands there. A brick on a slab shows a sliver of the
//     slab's top under its own bevelled bottom edge, and that sliver is
//     otherwise a face nobody draws: a slit into the wall.
//   * where three bricks meet on a line, a corner or an end, what would show
//     between their bevels is drawn by the face whose facet stops there: a
//     floor (FaceBake::floors), a plug (EDGE_PLUG_SHIFT), a cap
//     (EDGE_CAP_SHIFT).
//
// A facet carries a NEGATIVE UV2 (brick.gdshader: no print, no seam of its
// own), so the two copies of one cannot differ. Its UV is free, then, and
// says what the shader cannot work out: x is how deep into the cut the vertex
// is (0 at the face, 1 a bevel behind it) and y whether the cut is one wall
// of a groove between two bricks (brick::EDGE_GROOVE_SHIFT).
void BrickWorld::chamfer_faces_into(const ChamferIn &in, ChamferOut &out) {
    const auto t0 = std::chrono::steady_clock::now();
    // As bake_faces_into: the two axes of each face's plane, and which UV
    // component the bake wrote along each.
    static const int PLANE_A[6] = { 1, 1, 0, 0, 0, 0 };
    static const int PLANE_B[6] = { 2, 2, 2, 2, 1, 1 };
    static const int UV_A[6] = { 1, 1, 0, 0, 0, 0 };
    static const int UV_B[6] = { 0, 0, 1, 1, 1, 1 };

    const float c = in.bevel;
    const Vector3 cs = cell_size();
    out.quad_first.assign((size_t)in.faces + 1, 0);
    int floor_at = 0;
    const size_t guess = (size_t)in.faces * 4 * (c > 0.0f ? 4 : 1);
    out.vv.reserve(guess);
    out.nn.reserve(guess);
    out.cc.reserve(guess);
    out.uu.reserve(guess);
    out.u2.reserve(guess);

    Vector3 n;
    Color col;
    Vector2 u2;
    const auto push = [&](const Vector3 &p, const Vector2 &uv) {
        out.vv.push_back(p);
        out.nn.push_back(n);
        out.cc.push_back(col);
        out.uu.push_back(uv);
        out.u2.push_back(u2);
    };
    // A quad given round its edge, stored as a baked face is -- a, b, d, c, for
    // triangles (0, 1, 2) and (1, 3, 2) -- and turned to face `n` if it came
    // the other way round (the rule PieceMeshes._tri_n keeps).
    const auto quad = [&](const Vector3 &a, const Vector3 &b, const Vector3 &cc, const Vector3 &d,
            const Vector2 &ua, const Vector2 &ub, const Vector2 &uc, const Vector2 &ud) {
        if ((b - a).cross(d - a).dot(n) > 0.0f) {
            push(a, ua); push(d, ud); push(b, ub); push(cc, uc);
        } else {
            push(a, ua); push(b, ub); push(d, ud); push(cc, uc);
        }
    };

    out.carrier.assign((size_t)in.faces, 0);
    int32_t quads = 0;

    // A PLAIN BOX is drawn whole, as the brick it is: its six faces, each
    // drawn in by the bevel, the twelve 45-degree facets between them and the
    // eight corner triangles -- every edge and every corner of it cut, the
    // same whatever stands next to it (Docs/BrickBevel.md 2.5). Two bricks
    // side by side are two boxes, and the groove between them is their two
    // facets meeting where they touch; nothing is pushed out under a
    // neighbour, plugged or capped. Every box is closed, so no seam between
    // two can be seen through. Its hidden faces are drawn too (the depth
    // prepass buries them): a brick shot away uncovers a whole brick behind
    // it, with no rebuild. (The rules this replaced -- extended faces, plugs,
    // caps, floors -- kept the bevels clear of each other, and left square
    // corners standing over the upright bevels at every seam.)
    const auto emit_box = [&](int i0, int i1) {
        Vector3 lo = in.verts[(size_t)i0 * 4], hi = lo;
        float covered[6] = { 0, 0, 0, 0, 0, 0 };
        float area[6] = { 0, 0, 0, 0, 0, 0 };
        for (int j = i0; j < i1; ++j) {
            for (int k = 0; k < 4; ++k) {
                const Vector3 &p = in.verts[(size_t)j * 4 + k];
                lo = Vector3(std::min(lo.x, p.x), std::min(lo.y, p.y), std::min(lo.z, p.z));
                hi = Vector3(std::max(hi.x, p.x), std::max(hi.y, p.y), std::max(hi.z, p.z));
            }
            const Vector3 &fn = in.normals[(size_t)j * 4];
            const int d = fn.x > 0.5f ? 0 : fn.x < -0.5f ? 1 : fn.y > 0.5f ? 2
                    : fn.y < -0.5f ? 3 : fn.z > 0.5f ? 4 : 5;
            const Vector3 e1 = in.verts[(size_t)j * 4 + 1] - in.verts[(size_t)j * 4];
            const Vector3 e2 = in.verts[(size_t)j * 4 + 2] - in.verts[(size_t)j * 4];
            const float a = e1.cross(e2).length();
            area[d] += a;
            if (in.other != nullptr && in.other[j] >= 0) {
                covered[d] += a;
            }
        }
        const Vector3 size = hi - lo;
        const float cb = std::min(c, 0.45f * std::min(size.x, std::min(size.y, size.z)));
        bool against[6];
        for (int d = 0; d < 6; ++d) {
            against[d] = area[d] > 0.0f && covered[d] > 0.5f * area[d];
        }
        // The face of direction d: its axis, its sign, its plane.
        const auto axis_of = [](int d) { return d / 2; };
        const auto sign_of = [](int d) { return (d & 1) ? -1.0f : 1.0f; };
        const auto face_uv = [&](int d, const Vector3 &p) -> Vector2 {
            const Vector3 r = p - lo;
            switch (d) {
                case 0: case 1: return Vector2(r.z, r.y);
                case 2: case 3: return Vector2(r.x, r.z);
                default:        return Vector2(r.x, r.y);
            }
        };
        const auto face_size = [&](int d) -> Vector2 {
            switch (d) {
                case 0: case 1: return Vector2(size.z, size.y);
                case 2: case 3: return Vector2(size.x, size.z);
                default:        return Vector2(size.x, size.y);
            }
        };
        // A point of the box: on each axis -1 the low side, +1 the high,
        // 0 inset from the low side by the bevel, 2 inset from the high.
        const auto at = [&](int ix, int iy, int iz) -> Vector3 {
            const int idx[3] = { ix, iy, iz };
            Vector3 p;
            for (int ax = 0; ax < 3; ++ax) {
                switch (idx[ax]) {
                    case -1: p[ax] = lo[ax]; break;
                    case 1:  p[ax] = hi[ax]; break;
                    case 0:  p[ax] = lo[ax] + cb; break;
                    default: p[ax] = hi[ax] - cb; break;
                }
            }
            return p;
        };
        // The six faces.
        for (int d = 0; d < 6; ++d) {
            const int ax = axis_of(d);
            const int side = (d & 1) ? -1 : 1;
            const int u = (ax + 1) % 3, w = (ax + 2) % 3;
            int ia[3], ib[3], ic[3], id[3];
            ia[ax] = ib[ax] = ic[ax] = id[ax] = side;
            ia[u] = 0; ia[w] = 0;
            ib[u] = 2; ib[w] = 0;
            ic[u] = 2; ic[w] = 2;
            id[u] = 0; id[w] = 2;
            const Vector3 pa = at(ia[0], ia[1], ia[2]);
            const Vector3 pb = at(ib[0], ib[1], ib[2]);
            const Vector3 pc = at(ic[0], ic[1], ic[2]);
            const Vector3 pd = at(id[0], id[1], id[2]);
            n = FACE_NORMAL[d];
            u2 = face_size(d);
            quad(pa, pb, pc, pd, face_uv(d, pa), face_uv(d, pb), face_uv(d, pc), face_uv(d, pd));
            ++quads;
        }
        // The twelve facets: one an edge, between faces d1 (axis a1) and d2
        // (axis a2), along the third axis.
        for (int a1 = 0; a1 < 3; ++a1) {
            for (int a2 = a1 + 1; a2 < 3; ++a2) {
                const int along = 3 - a1 - a2;
                for (int s1 = 0; s1 < 2; ++s1) {
                    for (int s2 = 0; s2 < 2; ++s2) {
                        const int d1 = a1 * 2 + s1, d2 = a2 * 2 + s2;
                        const int e1 = s1 ? -1 : 1, e2 = s2 ? -1 : 1;
                        const int in1 = s1 ? 0 : 2, in2 = s2 ? 0 : 2;
                        int p[4][3];
                        // On face d1: its plane on a1, inset on a2.
                        p[0][a1] = e1; p[0][a2] = in2; p[0][along] = 0;
                        p[1][a1] = e1; p[1][a2] = in2; p[1][along] = 2;
                        // On face d2.
                        p[2][a1] = in1; p[2][a2] = e2; p[2][along] = 2;
                        p[3][a1] = in1; p[3][a2] = e2; p[3][along] = 0;
                        const float groove = (against[d1] || against[d2]) ? 1.0f : 0.0f;
                        const Vector2 fu(0.5f, groove);
                        n = (FACE_NORMAL[d1] + FACE_NORMAL[d2]).normalized();
                        u2 = -face_size(d1);
                        quad(at(p[0][0], p[0][1], p[0][2]), at(p[1][0], p[1][1], p[1][2]),
                                at(p[2][0], p[2][1], p[2][2]), at(p[3][0], p[3][1], p[3][2]),
                                fu, fu, fu, fu);
                        ++quads;
                    }
                }
            }
        }
        // The eight corners.
        for (int sx = 0; sx < 2; ++sx) {
            for (int sy = 0; sy < 2; ++sy) {
                for (int sz = 0; sz < 2; ++sz) {
                    const int ex = sx ? -1 : 1, ey = sy ? -1 : 1, ez = sz ? -1 : 1;
                    const int ix = sx ? 0 : 2, iy = sy ? 0 : 2, iz = sz ? 0 : 2;
                    const Vector3 px = at(ex, iy, iz);
                    const Vector3 py = at(ix, ey, iz);
                    const Vector3 pz = at(ix, iy, ez);
                    const bool g = against[sx] || against[2 + sy] || against[4 + sz];
                    const Vector2 fu(0.5f, g ? 1.0f : 0.0f);
                    n = Vector3(sign_of(sx), sign_of(2 + sy), sign_of(4 + sz)).normalized();
                    u2 = -face_size(2 + sy);
                    quad(px, py, pz, pz, fu, fu, fu, fu);
                    ++quads;
                }
            }
        }
    };

    // CORNER POSTS (Docs/BrickBevel.md 2.6). Where four bricks' corners
    // meet along an edge, or two meet across a diagonal, their bevels leave a
    // diamond channel with nothing in it: daylight straight through a wall
    // wherever a vertical seam lines up with a course's groove, and between
    // two bricks that touch only at a corner. A post fills it: a square bar
    // turned 45 degrees, a little inside the bevels so it never fights them,
    // shaded as the bottom of a groove. It stops a bevel short of each end,
    // where the corner triangles close the pit in front of it.
    const auto emit_posts = [&](int p0, int p1) {
        const Color base = col;
        col = Color(base.r * 0.7f, base.g * 0.7f, base.b * 0.7f, base.a);
        const Vector2 fu(0.5f, 1.0f);
        for (int k = p0; k < p1; ++k) {
            const float *q = in.posts + (size_t)k * POST_FLOATS;
            const int ax = (int)q[0];
            const int au = (ax + 1) % 3, av = (ax + 2) % 3;
            const float a0 = q[1], a1 = q[2], eu = q[3], ev = q[4];
            // r < 0: a channel closed all round by the four bricks' facets,
            // so its two end caps are enough to stop the light.
            const bool caps_only = q[5] < 0.0f;
            const float r = std::fabs(q[5]);
            const auto pt = [&](float a, float du, float dv) {
                Vector3 p;
                p[ax] = a;
                p[au] = eu + du;
                p[av] = ev + dv;
                return p;
            };
            const float DU[4] = { r, 0.0f, -r, 0.0f };
            const float DV[4] = { 0.0f, r, 0.0f, -r };
            u2 = -Vector2(a1 - a0, r);
            for (int s2 = 0; s2 < (caps_only ? 0 : 4); ++s2) {
                const int t = (s2 + 1) % 4;
                Vector3 nn;
                nn[ax] = 0.0f;
                nn[au] = DU[s2] + DU[t];
                nn[av] = DV[s2] + DV[t];
                n = nn.normalized();
                quad(pt(a0, DU[s2], DV[s2]), pt(a1, DU[s2], DV[s2]),
                        pt(a1, DU[t], DV[t]), pt(a0, DU[t], DV[t]), fu, fu, fu, fu);
                ++quads;
            }
            for (int e = 0; e < 2; ++e) {
                const float a = e ? a1 : a0;
                Vector3 nn;
                nn[ax] = e ? 1.0f : -1.0f;
                n = nn;
                quad(pt(a, DU[0], DV[0]), pt(a, DU[1], DV[1]),
                        pt(a, DU[2], DV[2]), pt(a, DU[3], DV[3]), fu, fu, fu, fu);
                ++quads;
            }
        }
        col = base;
    };

    for (int i = 0; i < in.faces; ++i) {
        out.quad_first[(size_t)i] = quads;
        if (in.box != nullptr && in.box[i] != 0 && c > 0.0f) {
            // Its block's first face carries the box; the rest draw nothing.
            if (i == 0 || in.owner[i - 1] != in.owner[i]) {
                out.carrier[(size_t)i] = 1;
                if (in.drawn == nullptr || in.drawn[i] != 0) {
                    int i1 = i + 1;
                    while (i1 < in.faces && in.owner[i1] == in.owner[i]) {
                        ++i1;
                    }
                    col = in.colours[(size_t)i * 4];
                    emit_box(i, i1);
                    if (in.posts != nullptr) {
                        emit_posts(in.post_at[i], in.post_at[i + 1]);
                    }
                }
            }
            continue;
        }
        // This face's facet floors, whether or not it is drawn.
        while (floor_at < in.floor_count && in.floors[floor_at].face - in.face_base < i) {
            ++floor_at;
        }
        int floor_end = floor_at;
        while (floor_end < in.floor_count && in.floors[floor_end].face - in.face_base == i) {
            ++floor_end;
        }
        if (in.drawn != nullptr && in.drawn[i] == 0) {
            continue;
        }
        const int v = i * 4;
        const uint32_t e = in.edge[i];
        const Vector3 face_n = in.normals[v];
        col = in.colours[v];
        const Vector2 face_u2 = in.uv2s[v];

        if ((e & brick::EDGE_RAW) != 0 || c <= 0.0f) {
            for (int k = 0; k < 4; ++k) {
                n = in.normals[v + k];
                u2 = in.uv2s[v + k];
                push(in.verts[v + k], in.uvs[v + k]);
            }
            ++quads;
            continue;
        }

        int f = (e >> brick::EDGE_DIR_SHIFT) & 7;
        // A bottom face resting on a brick (bake_faces_into) lays its bevels
        // flat; it is the -Y face all the same.
        const bool flat = f == brick::EDGE_DIR_FLAT_BOTTOM;
        if (flat) {
            f = 3;
        }
        Vector3 A, B;
        A[PLANE_A[f]] = 1.0f;
        B[PLANE_B[f]] = 1.0f;
        Vector2 UA, UB;
        UA[UV_A[f]] = 1.0f;
        UB[UV_B[f]] = 1.0f;
        const int code_a[2] = { (e >> brick::EDGE_A_LO) & 3, (e >> brick::EDGE_A_HI) & 3 };
        const int code_b[2] = { (e >> brick::EDGE_B_LO) & 3, (e >> brick::EDGE_B_HI) & 3 };
        // How far a corner moves along the OUTWARD direction of a side.
        const auto shift = [c](int code) -> float {
            return code == brick::EDGE_FLUSH ? 0.0f : (code == brick::EDGE_EXTEND ? c : -c);
        };

        Vector3 q[4];
        Vector2 qu[4];
        int hi_a[4], hi_b[4];
        for (int k = 0; k < 4; ++k) {
            const Vector3i o = FACE_CORNERS[f][k];
            hi_a[k] = o[PLANE_A[f]];
            hi_b[k] = o[PLANE_B[f]];
            const float da = shift(code_a[hi_a[k]]) * (hi_a[k] ? 1.0f : -1.0f);
            const float db = shift(code_b[hi_b[k]]) * (hi_b[k] ? 1.0f : -1.0f);
            q[k] = in.verts[v + k] + A * da + B * db;
            qu[k] = in.uvs[v + k] + UA * da + UB * db;
        }

        // The face itself, in the bake's own corner order.
        n = face_n;
        u2 = face_u2;
        for (int k = 0; k < 4; ++k) {
            push(q[k], qu[k]);
        }
        ++quads;

        // A BOTTOM face's bevels are laid flat (bake_faces_into: a printed
        // part's bottom is flat): its facets are strips of its own plane, out
        // to the edge, part of the face -- its normal, its UV, no facet mark
        // -- and its corner triangles cut the corner where an upright edge is
        // bevelled. Caps close a bevel's end, and a flat one has none.
        const Vector3 uv_o = in.verts[v];
        const Vector2 uv_at = in.uvs[v];
        const auto uv_of = [&](const Vector3 &p) -> Vector2 {
            const Vector3 r = p - uv_o;
            return uv_at + UA * r[PLANE_A[f]] + UB * r[PLANE_B[f]];
        };
        const auto fquad = [&](const Vector3 &a, const Vector3 &b, const Vector3 &cc, const Vector3 &d,
                const Vector2 &ua, const Vector2 &ub, const Vector2 &uc, const Vector2 &ud) {
            if (flat) {
                quad(a, b, cc, d, uv_of(a), uv_of(b), uv_of(cc), uv_of(d));
            } else {
                quad(a, b, cc, d, ua, ub, uc, ud);
            }
        };

        // The facets. `u2` negative marks them (see above).
        u2 = flat ? face_u2 : Vector2(-face_u2.x, -face_u2.y);
        for (int s = 0; s < 4; ++s) {
            const bool on_a = s < 2;
            const int hi = s & 1;
            if ((on_a ? code_a[hi] : code_b[hi]) != brick::EDGE_CONVEX) {
                continue;
            }
            int k1 = -1, k2 = -1;
            for (int k = 0; k < 4; ++k) {
                if ((on_a ? hi_a[k] : hi_b[k]) == hi) {
                    (k1 < 0 ? k1 : k2) = k;
                }
            }
            const float sgn = hi ? 1.0f : -1.0f;
            const Vector3 o = (on_a ? A : B) * sgn;
            const float groove = (e & (1u << (brick::EDGE_GROOVE_SHIFT + s))) != 0 ? 1.0f : 0.0f;
            const Vector2 shallow(0.0f, groove), deep(1.0f, groove);
            // From this face's drawn-in edge to the one round the corner's.
            const Vector3 step = flat ? o * c : (o - face_n) * c;
            // At a PLUGGED corner (brick::EDGE_PLUG_SHIFT) the facet does not
            // stop a bevel short for a corner triangle: its far edge runs on
            // to the brick's corner, and the facet of the other side meets it
            // there along the mitre. Two facets close the corner between them.
            // Where it runs into an INSIDE corner (brick::EDGE_INNER_SHIFT)
            // it stops at the brick's own corner, not pushed out with the face:
            // past it is the other brick's bevel, and the facet would stand
            // in it. Then (bake_faces_into decides) either its far edge stops
            // a bevel short, where the face round the edge is bevelled along
            // the corner -- the two meet in a mitre (the plug bit) -- or it
            // runs on square and is capped across its end (the cap bit): what
            // is past the end of a groove that runs into a square corner is
            // the inside of the brick behind, which draws nothing there. (A
            // wall's seam coming down to the floor, a floor's seam running up
            // to a wall.) With neither, the floor pushed out under the corner
            // shows there.
            Vector3 near1 = q[k1], near2 = q[k2];
            Vector3 far1 = near1 + step, far2 = near2 + step;
            for (int end = 0; end < 2; ++end) {
                const int k = end == 0 ? k1 : k2;
                const int other_hi = on_a ? hi_b[k] : hi_a[k];
                const int other_side = on_a ? 2 + other_hi : other_hi;
                if ((e & (1u << (brick::EDGE_INNER_SHIFT + other_side))) == 0) {
                    continue;
                }
                const int state = (in.corner[i] >> (k * 2)) & 3;
                const bool mitre = state == brick::CORNER_MITRE;
                const bool cap = state == brick::CORNER_CAP;
                const Vector3 axis = on_a ? B : A;
                const Vector3 in_step = axis * (other_hi ? -c : c);
                Vector3 &at = end == 0 ? near1 : near2;
                Vector3 &far = end == 0 ? far1 : far2;
                at += in_step;
                far = at + step;
                if (mitre) {
                    far += in_step;
                } else if (cap && !flat) {
                    n = axis * (other_hi ? -1.0f : 1.0f);
                    quad(at, at + step, at + o * c, at + o * c, shallow, deep, deep, deep);
                    ++quads;
                }
            }
            for (int end = 0; end < 2; ++end) {
                const int k = end == 0 ? k1 : k2;
                const int other_code = on_a ? code_b[hi_b[k]] : code_a[hi_a[k]];
                // QUIET too: a corner mitred because the edge between the two
                // faces round it is an inside corner may have one side whose
                // facet the face round the edge draws -- mitred there.
                if ((other_code != brick::EDGE_CONVEX && other_code != brick::EDGE_CONVEX_QUIET)
                        || (e & (1u << (brick::EDGE_PLUG_SHIFT + k))) == 0) {
                    continue;
                }
                const Vector3 run_out = on_a ? B * (hi_b[k] ? c : -c) : A * (hi_a[k] ? c : -c);
                (end == 0 ? far1 : far2) += run_out;
            }
            n = flat ? face_n : (face_n + o).normalized();
            fquad(near1, near2, far2, far1, shallow, shallow, deep, deep);
            ++quads;
            // The caps (brick::EDGE_CAP_SHIFT): the facet's own cross-section,
            // across the end it stops at, facing back along it.
            for (int end = 0; end < 2; ++end) {
                if (flat || (e & (1u << (brick::EDGE_CAP_SHIFT + s * 2 + end))) == 0) {
                    continue;
                }
                // An inside corner's cap is drawn above.
                if ((e & (1u << (brick::EDGE_INNER_SHIFT + (on_a ? 2 + end : end)))) != 0) {
                    continue;
                }
                const int k = ((on_a ? hi_b[k1] : hi_a[k1]) == end) ? k1 : k2;
                n = (on_a ? B : A) * (end ? -1.0f : 1.0f);
                quad(q[k], q[k] + step, q[k] + o * c, q[k] + o * c,
                        shallow, deep, deep, deep);
                ++quads;
                // And a floor under the bevel of facet that reaches past the
                // face to that cap: the brick this stands on is not drawn
                // there either.
                const Vector3 edge_at = in.verts[v + k] ;
                const Vector3 edge_to = q[k] + o * c;
                const Vector3 back = face_n * -c;
                n = -o;
                quad(edge_at, edge_to, edge_to + back, edge_at + back, deep, deep, deep, deep);
                ++quads;
            }
        }

        // The corners, where three facets leave a triangle open. One that has
        // a QUIET side is drawn by the face that side belongs to, and a
        // plugged one is closed by its two facets (above).
        for (int k = 0; k < 4; ++k) {
            const int ca = code_a[hi_a[k]];
            const int cb = code_b[hi_b[k]];
            if (ca != brick::EDGE_CONVEX || cb != brick::EDGE_CONVEX
                    || (e & (1u << (brick::EDGE_PLUG_SHIFT + k))) != 0) {
                continue;
            }
            const Vector3 oa = A * (hi_a[k] ? 1.0f : -1.0f);
            const Vector3 ob = B * (hi_b[k] ? 1.0f : -1.0f);
            const Vector3 p1 = q[k] + (flat ? oa : oa - face_n) * c;
            const Vector3 p2 = q[k] + (flat ? ob : ob - face_n) * c;
            n = flat ? face_n : (face_n + oa + ob).normalized();
            const int sa_bit = brick::EDGE_GROOVE_SHIFT + hi_a[k];
            const int sb_bit = brick::EDGE_GROOVE_SHIFT + 2 + hi_b[k];
            const float groove = ((e >> sa_bit) & (e >> sb_bit) & 1u) != 0 ? 1.0f : 0.0f;
            const Vector2 shallow(0.0f, groove), deep(1.0f, groove);
            fquad(q[k], p1, p2, p2, shallow, deep, deep, deep);
            ++quads;
        }
        u2 = Vector2(-face_u2.x, -face_u2.y);

        // The facet floors (FaceBake::floors): in the plane of the face round
        // the edge, from where the facet ends out to the edge, facing back
        // into the cut.
        for (int li = floor_at; li < floor_end; ++li) {
            const brick::FaceBake::Floor &fl = in.floors[li];
            const bool on_a = fl.side < 2;
            const int hi = fl.side & 1;
            // The side's corner at the low end of the way along it.
            int k0 = 0;
            for (int k = 0; k < 4; ++k) {
                if ((on_a ? hi_a[k] : hi_b[k]) == hi && (on_a ? hi_b[k] : hi_a[k]) == 0) {
                    k0 = k;
                }
            }
            const int run_axis = on_a ? PLANE_B[f] : PLANE_A[f];
            const Vector3 along = (on_a ? B : A) * cs[run_axis];
            const Vector3 from = in.verts[v + k0] + along * (float)fl.from;
            const Vector3 to = in.verts[v + k0] + along * (float)fl.to;
            const Vector3 back = face_n * -c;
            const Vector2 uv(1.0f, 1.0f); // the floor of a groove
            n = (on_a ? A : B) * (hi ? -1.0f : 1.0f);
            // Under a flat bottom whose upright edge is bevelled at an end,
            // the floor's outer edge stops a bevel short there (Floor::trim).
            const Vector3 unit = along.normalized() * c;
            const Vector3 from_o = from + ((fl.trim & 1u) ? unit : Vector3());
            const Vector3 to_o = to - ((fl.trim & 2u) ? unit : Vector3());
            quad(from_o, to_o, to + back, from + back, uv, uv, uv, uv);
            ++quads;
        }
    }
    out.quad_first[(size_t)in.faces] = quads;
    out.ms = std::chrono::duration<double, std::milli>(
            std::chrono::steady_clock::now() - t0).count();
}

Array BrickWorld::chamfer_arrays(const ChamferOut &o) {
    Array arrays;
    if (o.vv.empty()) {
        return arrays;
    }
    PackedVector3Array verts;
    PackedVector3Array normals;
    PackedColorArray colours;
    PackedVector2Array uvs;
    PackedVector2Array uv2s;
    verts.resize((int64_t)o.vv.size());
    normals.resize((int64_t)o.nn.size());
    colours.resize((int64_t)o.cc.size());
    uvs.resize((int64_t)o.uu.size());
    uv2s.resize((int64_t)o.u2.size());
    std::memcpy(verts.ptrw(), o.vv.data(), o.vv.size() * sizeof(Vector3));
    std::memcpy(normals.ptrw(), o.nn.data(), o.nn.size() * sizeof(Vector3));
    std::memcpy(colours.ptrw(), o.cc.data(), o.cc.size() * sizeof(Color));
    std::memcpy(uvs.ptrw(), o.uu.data(), o.uu.size() * sizeof(Vector2));
    std::memcpy(uv2s.ptrw(), o.u2.data(), o.u2.size() * sizeof(Vector2));
    arrays.resize(Mesh::ARRAY_MAX);
    arrays[Mesh::ARRAY_VERTEX] = verts;
    arrays[Mesh::ARRAY_NORMAL] = normals;
    arrays[Mesh::ARRAY_COLOR] = colours;
    arrays[Mesh::ARRAY_TEX_UV] = uvs;
    arrays[Mesh::ARRAY_TEX_UV2] = uv2s;
    return arrays;
}

void BrickWorld::chamfer_box_flags(const Chunk &c, int first, int faces,
        std::vector<uint8_t> &out) const {
    out.assign((size_t)faces, 0);
    for (int f = 0; f < faces; ++f) {
        const int32_t owner = c.bake.owner[(size_t)(first + f)];
        const Block &b = c.blocks[owner];
        out[(size_t)f] = (uint8_t)(valid_archetype(b.archetype)
                && archetypes[b.archetype].is_full_box()
                && (c.bake.edge[(size_t)(first + f)] & brick::EDGE_RAW) == 0);
    }
}

void BrickWorld::chamfer_posts(const Chunk &c, int first, int faces, float bevel,
        const std::vector<uint8_t> &box, std::vector<float> &posts,
        std::vector<int32_t> &post_at) const {
    posts.clear();
    post_at.assign((size_t)faces + 1, 0);
    if (bevel <= 0.0f) {
        return;
    }
    const Vector3 cs = cell_size();
    // The block standing in a cell, or -1: only what meshes as matter. As
    // BUILT, whatever has been shot since: a band is patched after a hit, not
    // rebuilt, and a post must not depend on what a patch cannot change. (A
    // post beside a brick shot away is a bevel's sliver of groove; one whose
    // own brick is shot away goes with it.)
    const auto solid = [&](const Vector3i &l) -> int32_t {
        if (!c.in_bounds(l)) {
            return -1;
        }
        const int32_t id = c.occupancy[c.index_of(l)];
        if (id < 0) {
            return -1;
        }
        const Block &b = c.blocks[(size_t)id];
        if (b.removed || b.decorative) {
            return -1;
        }
        return id;
    };
    const auto is_box = [&](int32_t id) {
        const Block &b = c.blocks[(size_t)id];
        return valid_archetype(b.archetype) && archetypes[b.archetype].is_full_box();
    };
    const float r = 0.9f * bevel;
    // Round the edge line along `ax` at (bu, bv), cell `a` along it: the four
    // blocks in its quadrants (bit 0 high on u, bit 1 high on v), and what the
    // bevels leave there -- 0 nothing, 1 a closed channel (four PLAIN BOXES,
    // at least one with a corner on the line), 2 anything else open: a gap
    // across a diagonal, or a channel with a shaped part round it, whose
    // faces are not closed boxes (it is drawn by the old rules).
    // `closed` is four blocks and no corner: their faces close a channel's end.
    struct Round {
        int32_t q[4];
        int kind;
        int corner_k;   // the first plain box with a corner here, or -1
        bool closed;
    };
    const auto round_at = [&](int ax, int bu, int bv, int a) {
        const int au = (ax + 1) % 3, av = (ax + 2) % 3;
        Round o;
        for (int k = 0; k < 4; ++k) {
            Vector3i l;
            l[ax] = a;
            l[au] = (k & 1) ? bu : bu - 1;
            l[av] = (k & 2) ? bv : bv - 1;
            o.q[k] = solid(l);
        }
        const int32_t *q = o.q;
        const bool all = q[0] >= 0 && q[1] >= 0 && q[2] >= 0 && q[3] >= 0;
        const bool diag = (q[0] >= 0 && q[3] >= 0 && q[1] < 0 && q[2] < 0)
                || (q[1] >= 0 && q[2] >= 0 && q[0] < 0 && q[3] < 0);
        bool corner = false;
        o.corner_k = -1;
        for (int k = 0; k < 4; ++k) {
            // A CORNER on the line: its neighbours round it on both axes are
            // other blocks. (At a T, a seam over a brick's middle, the brick
            // below fills two quadrants and has no edge.)
            if (q[k] >= 0 && q[k ^ 1] != q[k] && q[k ^ 2] != q[k]) {
                corner = true;
                if (o.corner_k < 0 && is_box(q[k])) {
                    o.corner_k = k;
                }
            }
        }
        const bool boxes = all && is_box(q[0]) && is_box(q[1]) && is_box(q[2]) && is_box(q[3]);
        o.kind = diag ? 2 : (all && corner ? (boxes ? 1 : 2) : 0);
        o.closed = all && !corner;
        return o;
    };
    for (int f = 0; f < faces; ++f) {
        post_at[(size_t)f] = (int32_t)(posts.size() / POST_FLOATS);
        const int32_t owner = c.bake.owner[(size_t)(first + f)];
        if (box[(size_t)f] == 0 || (f > 0 && c.bake.owner[(size_t)(first + f - 1)] == owner)) {
            continue;   // not its block's carrier
        }
        const Block &b = c.blocks[(size_t)owner];
        const Vector3i lo = b.cell - c.origin;
        const Vector3i hi = lo + archetypes[b.archetype].size;
        // The box's twelve edges: along axis ax, at one side of it on each of
        // the other two axes.
        for (int ax = 0; ax < 3; ++ax) {
            const int au = (ax + 1) % 3, av = (ax + 2) % 3;
            const int len = ax == 0 ? c.dims.x : (ax == 1 ? c.dims.y : c.dims.z);
            for (int su = 0; su < 2; ++su) {
                for (int sv = 0; sv < 2; ++sv) {
                    const int bu = su ? hi[au] : lo[au];
                    const int bv = sv ? hi[av] : lo[av];
                    // This box's quadrant round the line (it is high where
                    // the edge is its LOW side).
                    const int mine = (su ? 0 : 1) | (sv ? 0 : 2);
                    int run_from = -1, run_kind = 0;
                    for (int a = lo[ax]; a <= hi[ax]; ++a) {
                        int kind = 0;
                        if (a < hi[ax]) {
                            const Round o = round_at(ax, bu, bv, a);
                            // Drawn once, by the first plain box with a corner.
                            if (o.kind != 0 && o.corner_k == mine) {
                                kind = o.kind;
                            }
                        }
                        if (run_from >= 0 && kind != run_kind) {
                            // A closed channel needs a post only if it is open
                            // at BOTH ends -- seen through. Deep in a thick
                            // wall its ends are faces, and nothing shows.
                            bool through = true;
                            if (run_kind == 1) {
                                for (int dir = -1; dir <= 1 && through; dir += 2) {
                                    int e = dir < 0 ? run_from - 1 : a;
                                    while (e >= 0 && e < len && round_at(ax, bu, bv, e).kind == 1) {
                                        e += dir;
                                    }
                                    if (e >= 0 && e < len && round_at(ax, bu, bv, e).closed) {
                                        through = false;
                                    }
                                }
                            }
                            const float a0 = (float)run_from * cs[ax] + bevel;
                            const float a1 = (float)a * cs[ax] - bevel;
                            if (through && a1 > a0) {
                                posts.push_back((float)ax);
                                posts.push_back(a0);
                                posts.push_back(a1);
                                posts.push_back((float)bu * cs[au]);
                                posts.push_back((float)bv * cs[av]);
                                // Negative: a closed channel, which its two
                                // end caps alone stop every sight line through.
                                posts.push_back(run_kind == 1 ? -r : r);
                            }
                            run_from = -1;
                        }
                        if (kind != 0 && run_from < 0) {
                            run_from = a;
                            run_kind = kind;
                        }
                    }
                }
            }
        }
    }
    post_at[(size_t)faces] = (int32_t)(posts.size() / POST_FLOATS);
}

void BrickWorld::chamfer_indices(const Chunk &c, int section,
        const std::vector<int32_t> &quad_first, PackedInt32Array &out,
        const std::vector<uint8_t> &carrier) {
    // A section, or with section < 0 the chunk.
    const int first = section < 0 ? 0 : c.bake.section_first[(size_t)section];
    const int faces = section < 0 ? c.bake.face_count() : c.bake.section_faces[(size_t)section];
    out.resize((int64_t)quad_first[(size_t)faces] * 6);
    int32_t *w = out.ptrw();
    for (int f = 0; f < faces; ++f) {
        const int32_t owner = c.bake.owner[(size_t)(first + f)];
        const int32_t other = c.bake.other[(size_t)(first + f)];
        const bool box = (size_t)f < carrier.size() && carrier[(size_t)f] != 0;
        const bool drawn = c.blocks[owner].alive
                && (box || other < 0 || !c.blocks[other].alive);
        for (int32_t qi = quad_first[(size_t)f]; qi < quad_first[(size_t)f + 1]; ++qi) {
            int32_t *at = w + (size_t)qi * 6;
            if (!drawn) {
                std::fill(at, at + 6, 0);
                continue;
            }
            const int32_t b = qi * 4;
            at[0] = b + 0;
            at[1] = b + 1;
            at[2] = b + 2;
            at[3] = b + 1;
            at[4] = b + 3;
            at[5] = b + 2;
        }
    }
}

Array BrickWorld::build_chunk_chamfer_mesh(int chunk_id, double bevel) {
    if (!valid_chunk(chunk_id)) {
        return Array();
    }
    Chunk &c = chunks[chunk_id];
    if (!c.bake.valid) {
        bake_chunk_faces(c);
        stats[chunk_id].bake_ms = c.bake.bake_ms;
    }
    const int faces = c.bake.face_count();
    if (faces == 0) {
        return Array();
    }
    // With no bevel there is nothing to build boxes for: the flat faces.
    std::vector<uint8_t> box;
    chamfer_box_flags(c, 0, bevel > 0.0 ? faces : 0, box);
    box.resize((size_t)faces, 0);
    std::vector<uint8_t> drawn((size_t)faces, 0);
    for (int f = 0; f < faces; ++f) {
        const int32_t owner = c.bake.owner[(size_t)f];
        const int32_t other = c.bake.other[(size_t)f];
        drawn[(size_t)f] = c.blocks[owner].alive
                && (box[(size_t)f] != 0 || other < 0 || !c.blocks[other].alive);
    }
    std::vector<float> posts;
    std::vector<int32_t> post_at;
    chamfer_posts(c, 0, faces, (float)std::max(0.0, bevel), box, posts, post_at);
    ChamferIn in;
    in.owner = c.bake.owner.data();
    in.other = c.bake.other.data();
    in.box = box.data();
    in.posts = posts.data();
    in.post_at = post_at.data();
    in.verts = c.bake.verts.ptr();
    in.normals = c.bake.normals.ptr();
    in.colours = c.bake.colours.ptr();
    in.uvs = c.bake.uvs.ptr();
    in.uv2s = c.bake.uv2s.ptr();
    in.edge = c.bake.edge.data();
    in.corner = c.bake.corner.data();
    in.drawn = drawn.data();
    in.floors = c.bake.floors.data();
    in.floor_count = (int)c.bake.floors.size();
    in.faces = faces;
    in.bevel = (float)std::max(0.0, bevel);
    ChamferOut out;
    chamfer_faces_into(in, out);
    Array arrays = chamfer_arrays(out);
    if (arrays.is_empty()) {
        return arrays;
    }
    // Every quad here is drawn: the faces that are not were left out.
    const int32_t quads = out.quad_first[(size_t)faces];
    PackedInt32Array idx;
    idx.resize((int64_t)quads * 6);
    int32_t *w = idx.ptrw();
    for (int32_t qi = 0; qi < quads; ++qi) {
        const int32_t b = qi * 4;
        int32_t *at = w + (size_t)qi * 6;
        at[0] = b + 0;
        at[1] = b + 1;
        at[2] = b + 2;
        at[3] = b + 1;
        at[4] = b + 3;
        at[5] = b + 2;
    }
    arrays[Mesh::ARRAY_INDEX] = idx;
    last_chamfer_tris = quads * 2;
    last_chamfer_ms = out.ms;
    return arrays;
}

bool BrickWorld::chamfer_pending(int chunk_id, int section) const {
    for (const auto &j : chamfer_jobs) {
        if (j->chunk_id == chunk_id && j->section == section) {
            return true;
        }
    }
    return false;
}

bool BrickWorld::chamfer_ready(int chunk_id, int section) const {
    for (const auto &j : chamfer_jobs) {
        if (j->chunk_id == chunk_id && j->section == section) {
            return j->done.load(std::memory_order_acquire);
        }
    }
    return false;
}

void BrickWorld::chamfer_section_async(int chunk_id, int section, double bevel) {
    if (!valid_chunk(chunk_id) || chamfer_pending(chunk_id, section)) {
        return;
    }
    const Chunk &c = chunks[chunk_id];
    if (!c.bake.valid || section >= c.bake.section_count()) {
        return;
    }
    const int first = section < 0 ? 0 : c.bake.section_first[(size_t)section];
    const int faces = section < 0 ? c.bake.face_count() : c.bake.section_faces[(size_t)section];
    if (faces <= 0) {
        return;
    }
    auto job = std::make_unique<ChamferJob>();
    job->chunk_id = chunk_id;
    job->section = section;
    job->serial = c.bake.serial;
    job->verts = c.bake.verts;
    job->normals = c.bake.normals;
    job->colours = c.bake.colours;
    job->uvs = c.bake.uvs;
    job->uv2s = c.bake.uv2s;
    job->edge.assign(c.bake.edge.begin() + first, c.bake.edge.begin() + first + faces);
    job->corner.assign(c.bake.corner.begin() + first, c.bake.corner.begin() + first + faces);
    job->in.verts = job->verts.ptr() + (size_t)first * 4;
    job->in.normals = job->normals.ptr() + (size_t)first * 4;
    job->in.colours = job->colours.ptr() + (size_t)first * 4;
    job->in.uvs = job->uvs.ptr() + (size_t)first * 4;
    job->in.uv2s = job->uv2s.ptr() + (size_t)first * 4;
    job->in.edge = job->edge.data();
    job->in.corner = job->corner.data();
    job->owner.assign(c.bake.owner.begin() + first, c.bake.owner.begin() + first + faces);
    job->other.assign(c.bake.other.begin() + first, c.bake.other.begin() + first + faces);
    chamfer_box_flags(c, first, faces, job->box);
    job->in.owner = job->owner.data();
    job->in.other = job->other.data();
    job->in.box = job->box.data();
    chamfer_posts(c, first, faces, (float)std::max(0.0, bevel), job->box, job->posts,
            job->post_at);
    job->in.posts = job->posts.data();
    job->in.post_at = job->post_at.data();
    {
        const auto before = [](const brick::FaceBake::Floor &l, int face) {
            return l.face < face;
        };
        const auto lo = std::lower_bound(c.bake.floors.begin(), c.bake.floors.end(), first,
                before);
        const auto hi = std::lower_bound(lo, c.bake.floors.end(), first + faces, before);
        job->floors.assign(lo, hi);
    }
    job->in.floors = job->floors.data();
    job->in.floor_count = (int)job->floors.size();
    job->in.face_base = first;
    job->in.faces = faces;
    job->in.bevel = (float)std::max(0.0, bevel);
    ChamferJob *raw = job.get();
    raw->worker = std::thread([raw]() {
        chamfer_faces_into(raw->in, raw->out);
        raw->done.store(true, std::memory_order_release);
    });
    chamfer_jobs.push_back(std::move(job));
}

Array BrickWorld::take_chamfer_section(int chunk_id, int section) {
    for (size_t i = 0; i < chamfer_jobs.size(); ++i) {
        ChamferJob *job = chamfer_jobs[i].get();
        if (job->chunk_id != chunk_id || job->section != section) {
            continue;
        }
        if (job->worker.joinable()) {
            job->worker.join();
        }
        Array arrays;
        // Only against the bake it was built from: another one numbers its
        // faces afresh, and these quads would be drawn by the wrong bricks.
        if (valid_chunk(chunk_id) && chunks[chunk_id].bake.valid
                && chunks[chunk_id].bake.serial == job->serial) {
            arrays = chamfer_arrays(job->out);
        }
        if (!arrays.is_empty()) {
            ChamferBand &band = chamfer_bands[std::make_pair(chunk_id, section)];
            band.serial = job->serial;
            band.quad_first = std::move(job->out.quad_first);
            band.carrier = std::move(job->out.carrier);
            chamfer_indices(chunks[chunk_id], section, band.quad_first, band.live, band.carrier);
            arrays[Mesh::ARRAY_INDEX] = band.live;
            last_chamfer_tris = (int)(band.live.size() / 3);
            last_chamfer_ms = job->out.ms;
        }
        chamfer_jobs.erase(chamfer_jobs.begin() + (long)i);
        return arrays;
    }
    return Array();
}

Array BrickWorld::update_chamfer_regions(int chunk_id, const PackedInt32Array &sections) {
    Array out;
    if (!valid_chunk(chunk_id)) {
        return out;
    }
    const Chunk &c = chunks[chunk_id];
    auto it = chamfer_bands.lower_bound(std::make_pair(chunk_id, INT32_MIN));
    for (; it != chamfer_bands.end() && it->first.first == chunk_id; ++it) {
        ChamferBand &band = it->second;
        const int section = it->first.second;
        // The chunk as one band (section < 0) is every section.
        if (!sections.is_empty() && section >= 0 && !sections.has(section)) {
            continue;
        }
        Dictionary d;
        d["section"] = section;
        if (!c.bake.valid || c.bake.serial != band.serial
                || section >= c.bake.section_count()) {
            d["stale"] = true;
            out.push_back(d);
            continue;
        }
        PackedInt32Array next;
        // The bake is the one the band was built from, so its faces are still
        // the band's; a band of fewer would read past its quads.
        const int band_faces = section < 0 ? c.bake.face_count()
                : c.bake.section_faces[(size_t)section];
        if ((int)band.quad_first.size() != band_faces + 1) {
            d["stale"] = true;
            out.push_back(d);
            continue;
        }
        chamfer_indices(c, section, band.quad_first, next, band.carrier);
        const int n = (int)next.size();
        if (n != band.live.size()) {
            d["stale"] = true;
            out.push_back(d);
            continue;
        }
        const int32_t *a = band.live.ptr();
        const int32_t *b = next.ptr();
        int lo = -1, hi = -1;
        for (int i = 0; i < n; ++i) {
            if (a[i] != b[i]) {
                if (lo < 0) {
                    lo = i;
                }
                hi = i;
            }
        }
        if (lo < 0) {
            continue;
        }
        const int count = hi - lo + 1;
        // Four vertices a quad, six indices: the mesh's vertex count, and so
        // its index width (IslandManager.INDEX16_MAX_VERTS).
        const int index_bytes = (n / 6) * 4 <= 65536 ? 2 : 4;
        PackedByteArray data;
        data.resize((int64_t)count * index_bytes);
        uint8_t *w = data.ptrw();
        for (int i = 0; i < count; ++i) {
            const int32_t val = b[lo + i];
            if (index_bytes == 2) {
                const uint16_t v16 = (uint16_t)val;
                std::memcpy(w + (size_t)i * 2, &v16, 2);
            } else {
                std::memcpy(w + (size_t)i * 4, &val, 4);
            }
        }
        d["offset"] = lo * index_bytes;
        d["data"] = data;
        d["changed_bytes"] = data.size();
        out.push_back(d);
        band.live = next;
    }
    return out;
}

int BrickWorld::get_chamfer_expected_triangles(int chunk_id, int section) const {
    const auto it = chamfer_bands.find(std::make_pair(chunk_id, section));
    if (!valid_chunk(chunk_id) || it == chamfer_bands.end()) {
        return -1;
    }
    const Chunk &c = chunks[chunk_id];
    const ChamferBand &band = it->second;
    if (!c.bake.valid || c.bake.serial != band.serial) {
        return -1;
    }
    PackedInt32Array idx;
    chamfer_indices(c, section, band.quad_first, idx, band.carrier);
    int tris = 0;
    const int32_t *r = idx.ptr();
    for (int64_t i = 0; i + 2 < idx.size(); i += 3) {
        if (r[i] != r[i + 1] || r[i + 1] != r[i + 2]) {
            ++tris;
        }
    }
    return tris;
}

void BrickWorld::drop_chamfer(int chunk_id, int section, bool all) {
    for (size_t i = chamfer_jobs.size(); i-- > 0;) {
        ChamferJob *job = chamfer_jobs[i].get();
        if (job->chunk_id != chunk_id || (!all && job->section != section)) {
            continue;
        }
        if (job->worker.joinable()) {
            job->worker.join();
        }
        chamfer_jobs.erase(chamfer_jobs.begin() + (long)i);
    }
    if (!all) {
        chamfer_bands.erase(std::make_pair(chunk_id, section));
        return;
    }
    auto it = chamfer_bands.lower_bound(std::make_pair(chunk_id, INT32_MIN));
    while (it != chamfer_bands.end() && it->first.first == chunk_id) {
        it = chamfer_bands.erase(it);
    }
}

// A far piece's stand-in. The bake merges faces WITHIN a brick and no further,
// so a wall of 2x4s is a quad per brick face, and a settled piece of 5,000
// bricks is 40,000-odd vertices whether it is 5 m away or 300. Here the merge
// runs across bricks, over the occupancy grid itself: every cell of a live
// brick keyed by its colour, and one rectangle for each run of one colour on
// each exposed plane -- the greedy mesh the bake does per brick, done per
// chunk. No bake is read or made: a piece that goes coarse gives its bake back.
//
// UV is the vertex's own position in the face plane (chunk metres) and UV2 a
// brick-sized rectangle, so the seam shader tiles brick outlines over each
// merged face (brick.gdshader; BuildingShell.SEAM_UNIT) -- a course tall and
// two studs wide: not where the real seams are, but where seams would be.
// Authored parts (round bricks, spiral steps) are drawn as the cells they fill.
void BrickWorld::coarse_faces_into(const Chunk &c, const std::vector<Archetype> &archetypes,
        CoarseOut &out) {
    const auto t0 = std::chrono::steady_clock::now();

    // Only the box the live bricks are in. A piece cut out of a building keeps
    // the building's grid -- 42x627x60, 1.58 million cells, round 6,500 bricks
    // -- and walking all of it was 10-16 ms a build, in a queue that was
    // building one or three a tick for pieces falling far off.
    Vector3i lo(INT_MAX, INT_MAX, INT_MAX);
    Vector3i hi(INT_MIN, INT_MIN, INT_MIN);
    for (const Block &b : c.blocks) {
        if (b.removed || !b.alive || b.decorative) {
            continue;
        }
        const Vector3i base = b.cell - c.origin;
        const Vector3i end = base + archetypes[b.archetype].size;
        lo = Vector3i(std::min(lo.x, base.x), std::min(lo.y, base.y), std::min(lo.z, base.z));
        hi = Vector3i(std::max(hi.x, end.x), std::max(hi.y, end.y), std::max(hi.z, end.z));
    }
    if (lo.x > hi.x) {
        out.ms = std::chrono::duration<double, std::milli>(
                std::chrono::steady_clock::now() - t0).count();
        return;
    }
    lo = Vector3i(std::max(lo.x, 0), std::max(lo.y, 0), std::max(lo.z, 0));
    hi = Vector3i(std::min(hi.x, c.dims.x), std::min(hi.y, c.dims.y), std::min(hi.z, c.dims.z));
    // From here on the grid is that box: cell (x, y, z) of it is the chunk's
    // lo + (x, y, z), and a neighbour outside it holds nothing drawn.
    const int dim[3] = { hi.x - lo.x, hi.y - lo.y, hi.z - lo.z };
    const int stride[3] = { 1, dim[0], dim[0] * dim[1] }; // as Chunk::index_of
    const int cells = dim[0] * dim[1] * dim[2];

    // Per cell: 0 = nothing drawn there, else 1 + the colour's index; and its
    // material, for what hides what (brick_material_hides). The cells that
    // hold anything are listed as they go: a building is mostly the air inside
    // it, and everything after this walks the list, not the grid. (Walking the
    // grid six times over, a face direction at a time, was 5 ms for a
    // 40x30-stud tower of 60 courses.)
    std::vector<int32_t> key((size_t)cells, 0);
    std::vector<uint8_t> mat((size_t)cells, 0);
    std::vector<int32_t> filled;
    std::vector<Color> cols;
    std::vector<int32_t> block_key(c.blocks.size(), 0);
    for (int i = 0; i < cells; ++i) {
        const int32_t bid = c.occupancy[(size_t)c.index_of(Vector3i(
                lo.x + i % dim[0], lo.y + (i / dim[0]) % dim[1], lo.z + i / stride[2]))];
        if (bid < 0) {
            continue;
        }
        const Block &b = c.blocks[(size_t)bid];
        if (!b.alive || b.decorative) {
            continue; // dead bricks still hold their cells; furniture is FurnitureMesh's
        }
        int32_t &k = block_key[(size_t)bid];
        if (k == 0) {
            const Color col = block_rgba(b.material, b.colour);
            for (size_t j = 0; j < cols.size(); ++j) {
                if (cols[j] == col) {
                    k = (int32_t)j + 1;
                    break;
                }
            }
            if (k == 0) {
                cols.push_back(col);
                k = (int32_t)cols.size();
            }
        }
        key[(size_t)i] = k;
        mat[(size_t)i] = b.material;
        filled.push_back(i);
    }

    // As bake_faces_into: which axis each face is sliced along, and which two
    // span its plane. FACE_DIR steps + along it for an even face, - for odd.
    static const int SLICE_AXIS[6] = { 0, 0, 1, 1, 2, 2 };
    static const int PLANE_A[6]    = { 1, 1, 0, 0, 0, 0 };
    static const int PLANE_B[6]    = { 2, 2, 2, 2, 1, 1 };

    // Every exposed face, by the way it faces, as its place in a raster of
    // slices: (slice * A + a) * B + b, A and B being its plane's two axes.
    std::vector<int32_t> faces[6];
    for (const int i : filled) {
        const int at[3] = { i % dim[0], (i / dim[0]) % dim[1], i / stride[2] };
        for (int f = 0; f < 6; ++f) {
            const int ax = SLICE_AXIS[f];
            const int step = (f & 1) ? -1 : 1;
            const int n = at[ax] + step;
            if (n >= 0 && n < dim[ax]) {
                const size_t j = (size_t)(i + step * stride[ax]);
                if (key[j] != 0 && brick_material_hides(mat[(size_t)i], mat[j])) {
                    continue; // buried
                }
            }
            faces[f].push_back((at[ax] * dim[PLANE_A[f]] + at[PLANE_A[f]]) * dim[PLANE_B[f]]
                    + at[PLANE_B[f]]);
        }
    }

    const Vector3 cs = cell_size();
    const Vector2 seam_side(2.0f * STUD_M, 3.0f * PLATE_M);
    const Vector2 seam_flat(2.0f * STUD_M, 2.0f * STUD_M);
    std::vector<Vector3> &vv = out.vv;
    std::vector<Vector3> &nn = out.nn;
    std::vector<Color> &cc = out.cc;
    std::vector<Vector2> &uu = out.uu;
    std::vector<Vector2> &u2 = out.u2;
    std::vector<int32_t> &ii = out.ii;
    std::vector<int32_t> mask; // one slice's plane; all zero between slices
    std::vector<int32_t> slice_at;
    std::vector<int32_t> by_slice;

    for (int f = 0; f < 6; ++f) {
        std::vector<int32_t> &list = faces[f];
        if (list.empty()) {
            continue;
        }
        const int sa = SLICE_AXIS[f];
        const int pa = PLANE_A[f];
        const int pb = PLANE_B[f];
        const int an = dim[pa];
        const int bn = dim[pb];
        const int plane = an * bn;
        const Vector2 seam = (f == 2 || f == 3) ? seam_flat : seam_side;
        mask.assign((size_t)plane, 0);
        // Grouped by slice, keeping the grid's order within one: a counting
        // sort (a comparison sort of the whole list was most of the build).
        // In a slice that order is B-major -- B is always the slower of the
        // two in the grid -- so each face comes after every face lower along
        // B, and after those level with it and lower along A: the least
        // untaken face first, which is all the greedy merge asks of an order.
        slice_at.assign((size_t)dim[sa] + 1, 0);
        for (const int32_t v : list) {
            ++slice_at[(size_t)(v / plane) + 1];
        }
        for (int q = 0; q < dim[sa]; ++q) {
            slice_at[(size_t)q + 1] += slice_at[(size_t)q];
        }
        by_slice.resize(list.size());
        for (const int32_t v : list) {
            by_slice[(size_t)slice_at[(size_t)(v / plane)]++] = v;
        }
        list.swap(by_slice);
        size_t s0 = 0;
        while (s0 < list.size()) {
            const int si = list[s0] / plane;
            size_t s1 = s0;
            for (; s1 < list.size() && list[s1] / plane == si; ++s1) {
                const int r = list[s1] % plane;
                int at[3];
                at[sa] = si;
                at[pa] = r / bn;
                at[pb] = r % bn;
                mask[(size_t)r] = key[(size_t)(at[0] + at[1] * stride[1] + at[2] * stride[2])];
            }

            // Greedy rectangles of one colour, started from each listed face
            // in scan order. A face is spent by zeroing it, and every one is,
            // so the plane is clean again for the next slice.
            for (size_t s = s0; s < s1; ++s) {
                const int r = list[s] % plane;
                const int32_t k = mask[(size_t)r];
                if (k == 0) {
                    continue;
                }
                const int ai = r / bn;
                const int bj = r % bn;
                int b1 = bj;
                while (b1 + 1 < bn && mask[(size_t)ai * bn + b1 + 1] == k) {
                    ++b1;
                }
                int a1 = ai;
                while (a1 + 1 < an) {
                    bool row_ok = true;
                    for (int bb = bj; bb <= b1; ++bb) {
                        if (mask[(size_t)(a1 + 1) * bn + bb] != k) {
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
                        mask[(size_t)aa * bn + bb] = 0;
                    }
                }

                const Color col = cols[(size_t)k - 1];
                const int v0 = (int)vv.size();
                for (int q = 0; q < 4; ++q) {
                    const Vector3i o = FACE_CORNERS[f][q];
                    const int oc[3] = { o.x, o.y, o.z };
                    int cell[3];
                    cell[sa] = si + oc[sa];
                    cell[pa] = (oc[pa] == 0) ? ai : (a1 + 1);
                    cell[pb] = (oc[pb] == 0) ? bj : (b1 + 1);
                    const Vector3 vp((lo.x + cell[0]) * cs.x, (lo.y + cell[1]) * cs.y,
                            (lo.z + cell[2]) * cs.z);
                    switch (f) {
                        case 0: case 1: uu.push_back(Vector2(vp.z, vp.y)); break;
                        case 2: case 3: uu.push_back(Vector2(vp.x, vp.z)); break;
                        default:        uu.push_back(Vector2(vp.x, vp.y)); break;
                    }
                    vv.push_back(vp);
                    nn.push_back(FACE_NORMAL[f]);
                    cc.push_back(col);
                    u2.push_back(seam);
                }
                ii.push_back(v0 + 0);
                ii.push_back(v0 + 1);
                ii.push_back(v0 + 2);
                ii.push_back(v0 + 1);
                ii.push_back(v0 + 3);
                ii.push_back(v0 + 2);
            }
            s0 = s1;
        }
    }

    out.ms = std::chrono::duration<double, std::milli>(
            std::chrono::steady_clock::now() - t0).count();
}

Array BrickWorld::coarse_arrays(const CoarseOut &o) {
    Array arrays;
    if (o.vv.empty()) {
        return arrays;
    }
    PackedVector3Array verts;
    PackedVector3Array normals;
    PackedColorArray colours;
    PackedVector2Array uvs;
    PackedVector2Array uv2s;
    PackedInt32Array indices;
    verts.resize((int64_t)o.vv.size());
    normals.resize((int64_t)o.nn.size());
    colours.resize((int64_t)o.cc.size());
    uvs.resize((int64_t)o.uu.size());
    uv2s.resize((int64_t)o.u2.size());
    indices.resize((int64_t)o.ii.size());
    std::memcpy(verts.ptrw(), o.vv.data(), o.vv.size() * sizeof(Vector3));
    std::memcpy(normals.ptrw(), o.nn.data(), o.nn.size() * sizeof(Vector3));
    std::memcpy(colours.ptrw(), o.cc.data(), o.cc.size() * sizeof(Color));
    std::memcpy(uvs.ptrw(), o.uu.data(), o.uu.size() * sizeof(Vector2));
    std::memcpy(uv2s.ptrw(), o.u2.data(), o.u2.size() * sizeof(Vector2));
    std::memcpy(indices.ptrw(), o.ii.data(), o.ii.size() * sizeof(int32_t));
    arrays.resize(Mesh::ARRAY_MAX);
    arrays[Mesh::ARRAY_VERTEX] = verts;
    arrays[Mesh::ARRAY_NORMAL] = normals;
    arrays[Mesh::ARRAY_COLOR] = colours;
    arrays[Mesh::ARRAY_TEX_UV] = uvs;
    arrays[Mesh::ARRAY_TEX_UV2] = uv2s;
    arrays[Mesh::ARRAY_INDEX] = indices;
    return arrays;
}

Array BrickWorld::build_chunk_coarse_mesh(int chunk_id) {
    if (!valid_chunk(chunk_id)) {
        return Array();
    }
    CoarseOut out;
    coarse_faces_into(chunks[chunk_id], archetypes, out);
    last_coarse_ms = out.ms;
    return coarse_arrays(out);
}

bool BrickWorld::coarse_pending(int chunk_id) const {
    for (const auto &j : coarse_jobs) {
        if (j->chunk_id == chunk_id) {
            return true;
        }
    }
    return false;
}

void BrickWorld::coarse_chunk_async(int chunk_id) {
    if (!valid_chunk(chunk_id) || coarse_pending(chunk_id)) {
        return;
    }
    auto job = std::make_unique<CoarseJob>();
    job->chunk_id = chunk_id;
    job->parts = palette_snapshot(); // as a bake's: the palette can grow under a worker
    CoarseJob *raw = job.get();
    const Chunk *cp = &chunks[chunk_id]; // stable: chunks is a deque
    raw->worker = std::thread([raw, cp]() {
        coarse_faces_into(*cp, *raw->parts, raw->out);
        raw->done.store(true, std::memory_order_release);
    });
    coarse_jobs.push_back(std::move(job));
}

bool BrickWorld::coarse_ready(int chunk_id) const {
    for (const auto &j : coarse_jobs) {
        if (j->chunk_id == chunk_id) {
            return j->done.load(std::memory_order_acquire);
        }
    }
    return false;
}

Array BrickWorld::take_coarse_mesh(int chunk_id) {
    for (size_t i = 0; i < coarse_jobs.size(); ++i) {
        if (coarse_jobs[i]->chunk_id != chunk_id) {
            continue;
        }
        CoarseJob *job = coarse_jobs[i].get();
        if (job->worker.joinable()) {
            job->worker.join();
        }
        last_coarse_ms = job->out.ms;
        const Array arrays = coarse_arrays(job->out);
        coarse_jobs.erase(coarse_jobs.begin() + (long)i);
        return arrays;
    }
    return Array();
}

void BrickWorld::settle_coarse_job(int chunk_id) {
    for (size_t i = 0; i < coarse_jobs.size(); ++i) {
        if (coarse_jobs[i]->chunk_id != chunk_id) {
            continue;
        }
        if (coarse_jobs[i]->worker.joinable()) {
            coarse_jobs[i]->worker.join();
        }
        coarse_jobs.erase(coarse_jobs.begin() + (long)i);
        return;
    }
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
    auto occludes = [&](const Vector3i &l, int owner_material) -> bool {
        const int32_t nb = c.block_at(l);
        if (nb < 0 || !c.blocks[nb].alive) {
            return false;
        }
        if (!brick_material_hides(owner_material, c.blocks[nb].material)) {
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
        const Color col = block_rgba(b.material, b.colour);

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
                        if (occludes(local + FACE_DIR[f], b.material)) {
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

/// Every joint for_each_neighbour would find, before the tests that change as a
/// building comes apart. See brick::JointCache.
const brick::JointCache &BrickWorld::joints_of(int chunk_id) {
    brick::JointCache &jc = joint_cache[chunk_id];
    const Chunk &c = chunks[chunk_id];
    const size_t n = c.blocks.size();
    if (jc.valid && jc.at.size() == n + 1) {
        return jc;
    }
    jc.at.clear();
    jc.runs.clear();
    jc.over_at.clear();
    jc.over_n.clear();
    jc.over_runs.clear();
    jc.at.reserve(n + 1);
    for (size_t i = 0; i < n; ++i) {
        jc.at.push_back((int32_t)jc.runs.size());
        block_runs(c, (int32_t)i, jc.runs);
    }
    jc.at.push_back((int32_t)jc.runs.size());
    jc.valid = true;
    return jc;
}

void BrickWorld::block_runs(const Chunk &c, int32_t bid, std::vector<brick::JointRun> &out) const {
    const Block &b = c.blocks[(size_t)bid];
    if (b.removed) {
        return; // its cells are someone else's, or nobody's
    }
    const Vector3i base = b.cell - c.origin;
    const Archetype &a = archetypes[b.archetype];
    const size_t from = out.size();
    auto add = [&](int32_t nb, uint8_t up) {
        if (out.size() > from && out.back().nb == nb && out.back().up == up
                && out.back().count < 0xFFFF) {
            ++out.back().count;
        } else {
            out.push_back(brick::JointRun{ nb, 1, up, 0 });
        }
    };
    for (const Archetype::SurfaceCell &sc : a.top_cells) {
        const int32_t upb = c.block_at(Vector3i(base.x + sc.x, base.y + sc.y + 1, base.z + sc.z));
        if (upb >= 0 && upb != bid
                && joint_exists(c, archetypes, bid, upb, b.cell.x + sc.x, b.cell.z + sc.z)) {
            add(upb, 1);
        }
    }
    for (const Archetype::SurfaceCell &sc : a.bottom_cells) {
        const int32_t down = c.block_at(Vector3i(base.x + sc.x, base.y + sc.y - 1, base.z + sc.z));
        if (down >= 0 && down != bid
                && joint_exists(c, archetypes, down, bid, b.cell.x + sc.x, b.cell.z + sc.z)) {
            add(down, 0);
        }
    }
}

void BrickWorld::blocks_touching(const Chunk &c, int32_t bid, std::vector<int32_t> &out) const {
    const Block &b = c.blocks[(size_t)bid];
    const Archetype &a = archetypes[b.archetype];
    const Vector3i base = b.cell - c.origin;
    for (int x = 0; x < a.size.x; ++x) {
        for (int y = 0; y < a.size.y; ++y) {
            for (int z = 0; z < a.size.z; ++z) {
                if (!a.solid_at(x, y, z)) {
                    continue;
                }
                for (int dy = -1; dy <= 1; dy += 2) {
                    const int32_t o = c.block_at(Vector3i(base.x + x, base.y + y + dy, base.z + z));
                    if (o >= 0 && o != bid
                            && std::find(out.begin(), out.end(), o) == out.end()) {
                        out.push_back(o);
                    }
                }
            }
        }
    }
}

// A room laying its furniture, or taking it back, used to throw the whole
// cache away -- and the next solve of the building built it again: 2-3 ms of a
// 50,000-brick tower's solve, every time a room opened or shut near somebody.
// Only the block and what touches it can have changed, so only their runs are
// redone. The overlay is folded back into a whole build once it is a quarter
// the size of the cache itself.
void BrickWorld::joints_changed(int chunk_id, int32_t bid, const std::vector<int32_t> &touching,
        bool placed) {
    brick::JointCache &jc = joint_cache[chunk_id];
    if (!jc.valid) {
        return;
    }
    const Chunk &c = chunks[chunk_id];
    const size_t n = c.blocks.size();
    if (placed) {
        // A new id, one past the end: its base range is empty.
        if (jc.at.size() != n) {
            jc.valid = false;
            return;
        }
        jc.at.push_back(jc.at.back());
    } else if (jc.at.size() != n + 1) {
        jc.valid = false;
        return;
    }
    if (jc.over_at.size() < n) {
        jc.over_at.resize(n, -1);
        jc.over_n.resize(n, 0);
    }
    auto redo = [&](int32_t b) {
        jc.over_at[(size_t)b] = (int32_t)jc.over_runs.size();
        block_runs(c, b, jc.over_runs);
        jc.over_n[(size_t)b] = (int32_t)jc.over_runs.size() - jc.over_at[(size_t)b];
    };
    redo(bid);
    for (int32_t o : touching) {
        redo(o);
    }
    if (jc.over_runs.size() > jc.runs.size() / 4 + 4096) {
        jc.valid = false;
    }
}

/// for_each_neighbour, from the cache: the same neighbours in the same order,
/// once per RUN with its cell count rather than once per cell. The tests that
/// change as a building comes apart are applied here, as for_each_neighbour
/// applied them: a dead neighbour is no joint, a block cut from what is below
/// (bottom_broken) has no joints downward, and one above it that is cut from
/// what is below has none to it.
template <typename F>
static inline void for_each_joint(const Chunk &c, const brick::JointCache &jc,
        int32_t bid, F &&fn) {
    const Block &b = c.blocks[bid];
    const brick::JointRun *r;
    const brick::JointRun *end;
    if (!jc.over_at.empty() && jc.over_at[bid] >= 0) {
        r = jc.over_runs.data() + jc.over_at[bid];
        end = r + jc.over_n[bid];
    } else {
        r = jc.runs.data() + jc.at[bid];
        end = jc.runs.data() + jc.at[bid + 1];
    }
    for (; r != end; ++r) {
        const Block &o = c.blocks[r->nb];
        if (r->up) {
            if (!o.alive || o.bottom_broken) {
                continue;
            }
        } else {
            if (b.bottom_broken) {
                return; // the downward runs are all after the upward ones
            }
            if (!o.alive) {
                continue;
            }
        }
        fn(r->nb, (int)r->count);
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
    SolveScratch &scratch = solve_scratch();
    std::vector<int32_t> &scratch_depth = scratch.depth;
    std::vector<int32_t> &scratch_queue = scratch.queue;
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
    const Vector3i up = -chunk_down[chunk_id];
    for (size_t i = 0; i < n; ++i) {
        const Block &b = c.blocks[i];
        if (b.alive && !b.support_broken && grounded_at(chunk_id, height_along(b.cell, up))) {
            mark[i] = 1;
            scratch_depth[i] = 0;
            scratch_queue.push_back((int32_t)i);
        }
    }

    // Once per run rather than once per cell: the first call marks the block
    // or rejects it for a reason the next call to it would give again, so the
    // queue comes out in the same order.
    const brick::JointCache &jc = joints_of(chunk_id);
    for (size_t head = 0; head < scratch_queue.size(); ++head) {
        const int32_t bid = scratch_queue[head];
        ++ss.blocks_visited;
        const int32_t next_depth = scratch_depth[bid] + 1;
        const bool from_held = c.blocks[bid].held;
        for_each_joint(c, jc, bid, [&](int32_t nb, int) {
            if (mark[nb] != 0 || c.blocks[nb].support_broken) {
                return;
            }
            // A held brick hangs on its own studs: nothing is held up THROUGH
            // it, except another of its own group (Block::held).
            if (from_held && !c.blocks[nb].held) {
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
    if (!valid_chunk(chunk_id)) {
        return Array();
    }
    const PackedByteArray grounded = solve_grounded(chunk_id);
    return detached_groups_of(chunk_id, grounded.ptr());
}

Array BrickWorld::detached_groups_of(int chunk_id, const uint8_t *grounded) {
    SolveScratch &scratch = solve_scratch();
    std::vector<uint8_t> &scratch_mark = scratch.mark;
    std::vector<int32_t> &scratch_queue = scratch.queue;
    Array out;
    const brick::JointCache &jc = joints_of(chunk_id);
    Chunk &c = chunks[chunk_id];
    SolveStats &ss = solve_stats[chunk_id];

    const size_t n = c.blocks.size();
    scratch_mark.assign(n, 0);

    std::vector<PackedInt32Array> groups;
    for (size_t i = 0; i < n; ++i) {
        if (!c.blocks[i].alive || grounded[i] || scratch_mark[i]) {
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
            for_each_joint(c, jc, bid, [&](int32_t nb, int) {
                if (scratch_mark[nb] || grounded[nb]) {
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

void BrickWorld::set_anchor_levels(int chunk_id, const PackedInt32Array &grid_ys) {
    if (!valid_chunk(chunk_id)) {
        return;
    }
    std::vector<int> &a = anchor_levels[(size_t)chunk_id];
    a.clear();
    for (int64_t i = 0; i < grid_ys.size(); ++i) {
        a.push_back(grid_ys[i]);
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

void BrickWorld::set_load(int chunk_id, int owner, const PackedInt32Array &block_ids, float mass_each) {
    if (!valid_chunk(chunk_id)) {
        return;
    }
    std::vector<std::pair<int32_t, int64_t>> v;
    const int64_t units = brick::to_mass_units(std::max(mass_each, 0.0f));
    for (int i = 0; i < block_ids.size(); ++i) {
        v.push_back({ block_ids[i], units });
    }
    StressState &sx = stress[chunk_id];
    if (v.empty()) {
        sx.loads.erase(owner);
    } else {
        sx.loads[owner] = std::move(v);
    }
}

void BrickWorld::clear_load(int chunk_id, int owner) {
    if (valid_chunk(chunk_id)) {
        stress[chunk_id].loads.erase(owner);
    }
}

float BrickWorld::get_external_load(int chunk_id, int block_id) const {
    if (!valid_chunk(chunk_id)) {
        return 0.0f;
    }
    int64_t sum = 0;
    for (const auto &owner : stress[chunk_id].loads) {
        for (const auto &l : owner.second) {
            if (l.first == block_id) {
                sum += l.second;
            }
        }
    }
    return (float)((double)sum / (double)brick::to_mass_units(1.0f));
}

float BrickWorld::get_headroom(int chunk_id, int block_id) const {
    if (!valid_chunk(chunk_id)) {
        return -1.0f;
    }
    const std::vector<int64_t> &h = stress[chunk_id].headroom;
    if (block_id < 0 || block_id >= (int)h.size()) {
        return -1.0f;
    }
    if (h[block_id] == std::numeric_limits<int64_t>::max()) {
        return std::numeric_limits<float>::infinity();
    }
    return (float)((double)h[block_id] / (double)brick::MASS_FIXED);
}

PackedInt32Array BrickWorld::get_load_owners(int chunk_id) const {
    PackedInt32Array out;
    if (valid_chunk(chunk_id)) {
        for (const auto &owner : stress[chunk_id].loads) {
            out.push_back(owner.first);
        }
    }
    return out;
}

Dictionary BrickWorld::solve_stress(int chunk_id) {
    SolveScratch &scratch = solve_scratch();
    std::vector<int32_t> &scratch_depth = scratch.depth;
    std::vector<int32_t> &scratch_queue = scratch.queue;
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
    // And what is resting on it from outside: wreckage (set_load).
    for (const auto &owner : sx.loads) {
        for (const auto &l : owner.second) {
            if (l.first >= 0 && l.first < (int32_t)n && c.blocks[l.first].alive) {
                c.blocks[l.first].load += l.second;
            }
        }
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
    // by contact area. The calls come from the joint cache as runs of calls to
    // one neighbour (for_each_joint): the same calls in the same order, so the
    // same sums and the same remainder handed to the same neighbours.
    const brick::JointCache &jc = joints_of(chunk_id);
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
        // A held brick is nobody's supporter but its own group's (Block::held).
        const bool i_am_held = b.held;
        for_each_joint(c, jc, bid, [&](int32_t nb, int count) {
            const int32_t nd = scratch_depth[nb];
            if (nd < 0 || nd >= depth || (c.blocks[nb].held && !i_am_held)) {
                return;
            }
            contact += count;
            if (height_along(c.blocks[nb].cell, up) > my_height) {
                contact_tension += count;
            }
        });
        if (contact == 0) {
            continue; // reached only through equal-depth peers; nothing to load
        }

        // A held brick is asked what holding it asked (reattach_held_groups):
        // its own weight against ALL its studs into grounded structure, not
        // only those the walk reached it through -- or it was held one solve
        // and failed the next on a stricter test than the one that held it.
        int test_contact = contact;
        int test_tension = contact_tension;
        if (i_am_held) {
            test_contact = 0;
            test_tension = 0;
            for_each_joint(c, jc, bid, [&](int32_t nb, int count) {
                if (scratch_depth[nb] < 0) {
                    return;
                }
                test_contact += count;
                if (height_along(c.blocks[nb].cell, up) > my_height) {
                    test_tension += count;
                }
            });
        }

        if (test_tension > 0) {
            // Only the share carried by the upward joints is a pull. Both sides
            // are integers and the comparison is exact: no division, so no
            // rounding decides whether a joint fails.
            const int64_t pull = b.load * (int64_t)test_tension;
            const int64_t capacity = (int64_t)test_tension * capacity_per_stud
                    * (int64_t)test_contact;
            // Reported only, never decided on.
            sx.max_ratio = std::max(sx.max_ratio,
                    (float)((double)pull / (double)std::max((int64_t)1, capacity)));

            if (pull > capacity && !b.support_broken) {
                b.support_broken = true;
                conn_forget(chunk_id);
                b.strained = true;
                separated.push_back(bid);
                ++sx.failures;
            }
        }

        // Share the load by contact area, and hand the remainder out one unit
        // at a time in neighbour order. Integer division alone would quietly
        // destroy load -- a tall building would get lighter the further down it
        // went -- and the remainder has to go somewhere fixed, not anywhere.
        //
        // A run of k calls to one neighbour is k shares, and one unit of the
        // remainder for each of those calls while any is left.
        const int64_t share = b.load / (int64_t)contact;
        int64_t remainder = b.load - share * (int64_t)contact;
        for_each_joint(c, jc, bid, [&](int32_t nb, int count) {
            const int32_t nd = scratch_depth[nb];
            if (nd >= 0 && nd < depth && !(c.blocks[nb].held && !i_am_held)) {
                const int64_t extra = std::min(remainder, (int64_t)count);
                remainder -= extra;
                c.blocks[nb].load += share * (int64_t)count + extra;
            }
        });
    }

    // Headroom, walking the same order FORWARD: a block's supporters are
    // shallower, so theirs is known by the time it is reached. A joint fails
    // when load * tension_contact > tension_contact * capacity * contact, that
    // is when the block's load passes capacity * contact -- so what it can
    // still take is the difference. Mass added to a block reaches the joints
    // under it too; the least over every supporter takes it all to each of
    // them (R7's worst case), where the solve would share it.
    {
        constexpr int64_t INF_ROOM = std::numeric_limits<int64_t>::max();
        sx.headroom.assign(n, 0);
        for (size_t qi = 0; qi < scratch_queue.size(); ++qi) {
            const int32_t bid = scratch_queue[qi];
            const Block &b = c.blocks[bid];
            const int32_t depth = scratch_depth[bid];
            if (depth <= 0) {
                sx.headroom[bid] = INF_ROOM;
                continue;
            }
            if (b.support_broken) {
                continue;   // already let go: no room at all
            }
            int contact = 0;
            int contact_tension = 0;
            int64_t below = INF_ROOM;
            const int my_height = height_along(b.cell, up);
            const bool i_am_held = b.held;
            for_each_joint(c, jc, bid, [&](int32_t nb, int count) {
                const int32_t nd = scratch_depth[nb];
                if (nd < 0 || nd >= depth || (c.blocks[nb].held && !i_am_held)) {
                    return;
                }
                contact += count;
                if (height_along(c.blocks[nb].cell, up) > my_height) {
                    contact_tension += count;
                }
                below = std::min(below, sx.headroom[nb]);
            });
            int64_t room = below;
            if (contact_tension > 0) {
                room = std::min(room, std::max((int64_t)0,
                        capacity_per_stud * (int64_t)contact - b.load));
            }
            sx.headroom[bid] = room;
        }
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

Dictionary BrickWorld::lateral_check(int chunk_id, float accel_g, Vector3 world_dir) {
    Dictionary out;
    out["ratio"] = 0.0;
    if (!valid_chunk(chunk_id)) {
        return out;
    }
    Chunk &c = chunks[chunk_id];
    const Vector3i up = -chunk_down[chunk_id];
    if (up != Vector3i(0, 1, 0)) {
        return out; // a toppled chunk is a piece: physics has it, not this
    }
    // Which grid axis, and which way along it, the load pushes.
    const Vector3 local_dir = c.xform.basis.inverse().xform(world_dir);
    const bool along_x = std::abs(local_dir.x) >= std::abs(local_dir.z);
    const float sgn = (along_x ? local_dir.x : local_dir.z) >= 0.0f ? 1.0f : -1.0f;
    const Vector3 cs = cell_size();
    const double hcell = along_x ? cs.x : cs.z;
    const double vcell = cs.y;
    const double cap = (double)std::max((int64_t)1,
            brick::to_mass_units(stress[chunk_id].tension_per_stud));
    constexpr double SOLID_STUDS = 4.0;

    // Heights span [lo, hi) over the living structural blocks.
    int lo = INT32_MAX;
    int hi = INT32_MIN;
    int x0 = INT32_MAX, x1 = INT32_MIN, z0 = INT32_MAX, z1 = INT32_MIN;
    const size_t n = c.blocks.size();
    for (size_t i = 0; i < n; ++i) {
        const Block &b = c.blocks[i];
        if (!b.alive || b.decorative) {
            continue;
        }
        const Vector3i bs = archetypes[b.archetype].size;
        lo = std::min(lo, b.cell.y);
        hi = std::max(hi, b.cell.y + bs.y);
        x0 = std::min(x0, b.cell.x);
        x1 = std::max(x1, b.cell.x + bs.x);
        z0 = std::min(z0, b.cell.z);
        z1 = std::max(z1, b.cell.z + bs.z);
    }
    if (lo >= hi) {
        return out;
    }
    const int layers = hi - lo + 1;
    // Per boundary h (index h - lo): mass whose bottom is at h, its moments;
    // stud contact meeting at h; solid cells running through h; the toe.
    std::vector<double> m(layers, 0.0), mx(layers, 0.0), my(layers, 0.0);
    std::vector<double> j(layers, 0.0), jx(layers, 0.0);
    std::vector<double> toe(layers, -1e30);
    // Along the push, in metres, signed so that "further" is always larger.
    auto along = [&](double cells) { return sgn * cells * hcell; };
    const brick::JointCache &jc = joints_of(chunk_id);
    for (size_t i = 0; i < n; ++i) {
        const Block &b = c.blocks[i];
        if (!b.alive || b.decorative) {
            continue;
        }
        const Vector3i sz = archetypes[b.archetype].size;
        const double a0 = along_x ? b.cell.x : b.cell.z;
        const double a1 = a0 + (along_x ? sz.x : sz.z);
        const double lo_m = std::min(along(a0), along(a1));
        const double hi_m = std::max(along(a0), along(a1));
        const double mid = (lo_m + hi_m) * 0.5;
        const double mass = (double)std::max((int64_t)1,
                brick::to_mass_units(archetypes[b.archetype].mass));
        const int bot = b.cell.y;
        const int top = b.cell.y + sz.y;
        m[bot - lo] += mass;
        mx[bot - lo] += mass * mid;
        my[bot - lo] += mass * (bot + top) * 0.5 * vcell;
        // Solid through every boundary strictly inside it.
        const double cells = (double)sz.x * (double)sz.z;
        for (int h = bot + 1; h < top; ++h) {
            j[h - lo] += cells * SOLID_STUDS;
            jx[h - lo] += cells * SOLID_STUDS * mid;
            toe[h - lo] = std::max(toe[h - lo], hi_m);
        }
        if (b.support_broken || b.bottom_broken) {
            continue;
        }
        // Joints meeting at its bottom: to the blocks it stands on.
        const int32_t bid = (int32_t)i;
        for_each_joint(c, jc, bid, [&](int32_t nb, int count) {
            const Block &o = c.blocks[nb];
            if (o.decorative || o.cell.y + archetypes[o.archetype].size.y != bot) {
                return;
            }
            const Vector3i osz = archetypes[o.archetype].size;
            const double b0 = along_x ? o.cell.x : o.cell.z;
            const double b1 = b0 + (along_x ? osz.x : osz.z);
            const double olo = std::max(lo_m, std::min(along(b0), along(b1)));
            const double ohi = std::min(hi_m, std::max(along(b0), along(b1)));
            j[bot - lo] += count;
            jx[bot - lo] += count * (olo + ohi) * 0.5;
            toe[bot - lo] = std::max(toe[bot - lo], ohi);
        });
    }

    // Top down: what is above boundary h is every block whose bottom is >= h.
    const int floor_y = foundation_level[chunk_id];
    double W = 0.0, WX = 0.0, WY = 0.0;
    double best = 0.0;
    int best_h = -1;
    double best_w = 0.0;
    int boundaries = 0;
    for (int h = hi; h > lo; --h) {
        const int k = h - lo;
        W += m[k];
        WX += mx[k];
        WY += my[k];
        if (extra_anchor(chunk_id, h)) {
            // Held here (set_anchor_levels): what is above weighs on this
            // anchor, not on anything under it.
            W = WX = WY = 0.0;
            continue;
        }
        if (h <= floor_y || W <= 0.0 || j[k] <= 0.0) {
            continue; // the foundation, or nothing meets here
        }
        ++boundaries;
        const double xc = WX / W;
        const double yc = WY / W;
        const double T = toe[k];
        const double hm = h * vcell;
        const double demand = (double)accel_g * W * std::max(0.0, yc - hm);
        const double hold = W * (T - xc) + cap * (j[k] * T - jx[k]);
        const double ratio = hold > 0.0 ? demand / hold : (demand > 0.0 ? 1e9 : 0.0);
        if (ratio > best) {
            best = ratio;
            best_h = h;
            best_w = W;
        }
    }
    out["ratio"] = best;
    out["boundaries"] = boundaries;
    if (best_h >= 0) {
        // The boundary's plane, at the middle of the chunk's footprint.
        const Vector3 local((x0 + x1) * 0.5f * cs.x, best_h * vcell, (z0 + z1) * 0.5f * cs.z);
        out["level"] = c.xform.xform(local);
        out["level_cell"] = best_h;
        out["mass_above"] = best_w / (double)brick::MASS_FIXED;
    }
    return out;
}

Dictionary BrickWorld::gravity_check(int chunk_id, float crush_per_stud) {
    Dictionary out;
    out["ratio"] = 0.0;
    if (!valid_chunk(chunk_id)) {
        return out;
    }
    Chunk &c = chunks[chunk_id];
    const Vector3i up = -chunk_down[chunk_id];
    if (up != Vector3i(0, 1, 0)) {
        return out; // a toppled chunk is a piece: physics has it, not this
    }
    // What is grounded now: only that is weighed, and only that holds.
    solve_grounded(chunk_id);
    const std::vector<int32_t> &depth = solve_scratch().depth;
    const Vector3 cs = cell_size();
    const double cap = (double)std::max((int64_t)1,
            brick::to_mass_units(stress[chunk_id].tension_per_stud));
    const double crush_cap = cap * std::max(crush_per_stud, 0.0001f);
    constexpr double SOLID_STUDS = 4.0;

    int lo = INT32_MAX;
    int hi = INT32_MIN;
    int x0 = INT32_MAX, x1 = INT32_MIN, z0 = INT32_MAX, z1 = INT32_MIN;
    const size_t n = c.blocks.size();
    auto counts = [&](size_t i) {
        const Block &b = c.blocks[i];
        return b.alive && !b.decorative && i < depth.size() && depth[i] >= 0;
    };
    for (size_t i = 0; i < n; ++i) {
        if (!counts(i)) {
            continue;
        }
        const Block &b = c.blocks[i];
        const Vector3i bs = archetypes[b.archetype].size;
        lo = std::min(lo, b.cell.y);
        hi = std::max(hi, b.cell.y + bs.y);
        x0 = std::min(x0, b.cell.x);
        x1 = std::max(x1, b.cell.x + bs.x);
        z0 = std::min(z0, b.cell.z);
        z1 = std::max(z1, b.cell.z + bs.z);
    }
    if (lo >= hi) {
        return out;
    }
    const int layers = hi - lo + 1;
    // Per boundary h (index h - lo): mass whose bottom is at h and its
    // moments; stud contact at h, its moments, and how far it reaches.
    std::vector<double> m(layers, 0.0), mx(layers, 0.0), mz(layers, 0.0);
    // And the same mass and contact by REGION: the footprint cut into columns
    // of GRAVITY_REGION studs, each weighed on its own (Structures.md 2.3). A
    // sum over the whole boundary hardly moves when one part of a wide
    // building loses what holds it up.
    const int rnx = std::max(1, (x1 - x0 + GRAVITY_REGION - 1) / GRAVITY_REGION);
    const int rnz = std::max(1, (z1 - z0 + GRAVITY_REGION - 1) / GRAVITY_REGION);
    const int regions = rnx * rnz;
    std::vector<double> rm((size_t)layers * regions, 0.0), rj((size_t)layers * regions, 0.0);
    auto region_of = [&](double cx, double cz) {
        const int rx = std::clamp((int)std::floor((cx - x0) / GRAVITY_REGION), 0, rnx - 1);
        const int rz = std::clamp((int)std::floor((cz - z0) / GRAVITY_REGION), 0, rnz - 1);
        return rz * rnx + rx;
    };
    std::vector<double> j(layers, 0.0), jx(layers, 0.0), jz(layers, 0.0);
    std::vector<double> ex0(layers, 1e30), ex1(layers, -1e30), ez0(layers, 1e30), ez1(layers, -1e30);
    auto touch = [&](int k, double a0, double a1, double b0, double b1, double studs) {
        const double cx = (a0 + a1) * 0.5;
        const double cz = (b0 + b1) * 0.5;
        j[k] += studs;
        jx[k] += studs * cx;
        jz[k] += studs * cz;
        rj[(size_t)k * regions + region_of(cx / cs.x, cz / cs.z)] += studs;
        ex0[k] = std::min(ex0[k], a0);
        ex1[k] = std::max(ex1[k], a1);
        ez0[k] = std::min(ez0[k], b0);
        ez1[k] = std::max(ez1[k], b1);
    };
    const brick::JointCache &jc = joints_of(chunk_id);
    for (size_t i = 0; i < n; ++i) {
        if (!counts(i)) {
            continue;
        }
        const Block &b = c.blocks[i];
        const Vector3i sz = archetypes[b.archetype].size;
        const double ax0 = b.cell.x * cs.x, ax1 = (b.cell.x + sz.x) * cs.x;
        const double az0 = b.cell.z * cs.z, az1 = (b.cell.z + sz.z) * cs.z;
        const double mass = (double)std::max((int64_t)1,
                brick::to_mass_units(archetypes[b.archetype].mass));
        const int bot = b.cell.y;
        const int top = b.cell.y + sz.y;
        m[bot - lo] += mass;
        mx[bot - lo] += mass * (ax0 + ax1) * 0.5;
        mz[bot - lo] += mass * (az0 + az1) * 0.5;
        rm[(size_t)(bot - lo) * regions + region_of(b.cell.x + sz.x * 0.5, b.cell.z + sz.z * 0.5)] += mass;
        // Solid plastic through every boundary strictly inside it.
        for (int h = bot + 1; h < top; ++h) {
            touch(h - lo, ax0, ax1, az0, az1, (double)sz.x * (double)sz.z * SOLID_STUDS);
        }
        if (b.support_broken || b.bottom_broken) {
            continue;
        }
        // Studs meeting at its bottom, from the grounded blocks it stands on.
        const int32_t bid = (int32_t)i;
        for_each_joint(c, jc, bid, [&](int32_t nb, int count) {
            if (!counts((size_t)nb)) {
                return;
            }
            const Block &o = c.blocks[nb];
            const Vector3i osz = archetypes[o.archetype].size;
            if (o.cell.y + osz.y != bot) {
                return;
            }
            const double ox0 = std::max(ax0, (double)o.cell.x * cs.x);
            const double ox1 = std::min(ax1, (double)(o.cell.x + osz.x) * cs.x);
            const double oz0 = std::max(az0, (double)o.cell.z * cs.z);
            const double oz1 = std::min(az1, (double)(o.cell.z + osz.z) * cs.z);
            touch(bot - lo, std::min(ox0, ox1), std::max(ox0, ox1),
                    std::min(oz0, oz1), std::max(oz0, oz1), (double)count);
        });
    }

    // Top down: what is above boundary h is every block whose bottom is >= h.
    const int floor_y = foundation_level[chunk_id];
    double W = 0.0, WX = 0.0, WZ = 0.0;
    double best = 0.0;
    int best_h = -1;
    double best_w = 0.0;
    bool best_crush = false;
    int boundaries = 0;
    std::vector<double> rW((size_t)regions, 0.0);
    double rbest = 0.0;
    int rbest_h = -1;
    int rbest_r = -1;
    double rbest_w = 0.0;
    for (int h = hi; h > lo; --h) {
        const int k = h - lo;
        W += m[k];
        WX += mx[k];
        WZ += mz[k];
        for (int r = 0; r < regions; ++r) {
            rW[(size_t)r] += rm[(size_t)k * regions + r];
            const double studs = rj[(size_t)k * regions + r];
            if (h <= floor_y || extra_anchor(chunk_id, h) || rW[(size_t)r] <= 0.0 || studs <= 0.0) {
                continue; // nothing meets here: what is above is the span rule's
            }
            const double rc = rW[(size_t)r] / (studs * crush_cap);
            if (rc > rbest) {
                rbest = rc;
                rbest_h = h;
                rbest_r = r;
                rbest_w = rW[(size_t)r];
            }
        }
        if (extra_anchor(chunk_id, h)) {
            // As the lateral check: held here, so nothing under it carries it.
            W = WX = WZ = 0.0;
            std::fill(rW.begin(), rW.end(), 0.0);
            continue;
        }
        if (h <= floor_y || W <= 0.0 || j[k] <= 0.0) {
            continue;
        }
        ++boundaries;
        const double xc = WX / W;
        const double zc = WZ / W;
        // TIP, about whichever edge the centre of mass is beyond.
        double tip = 0.0;
        auto over = [&](double past, double hold) {
            if (past <= 0.0) {
                return;
            }
            const double r = hold > 0.0 ? W * past / hold : 1e9;
            tip = std::max(tip, r);
        };
        over(xc - ex1[k], cap * (j[k] * ex1[k] - jx[k]));
        over(ex0[k] - xc, cap * (jx[k] - j[k] * ex0[k]));
        over(zc - ez1[k], cap * (j[k] * ez1[k] - jz[k]));
        over(ez0[k] - zc, cap * (jz[k] - j[k] * ez0[k]));
        // CRUSH.
        const double crush = W / (j[k] * crush_cap);
        const double r = std::max(tip, crush);
        if (r > best) {
            best = r;
            best_h = h;
            best_w = W;
            best_crush = crush > tip;
        }
    }
    out["ratio"] = best;
    out["boundaries"] = boundaries;
    if (best_h >= 0) {
        const Vector3 local((x0 + x1) * 0.5f * cs.x, best_h * cs.y, (z0 + z1) * 0.5f * cs.z);
        out["level"] = c.xform.xform(local);
        out["level_cell"] = best_h;
        out["mass_above"] = best_w / (double)brick::MASS_FIXED;
        out["kind"] = best_crush ? "crush" : "tip";
    }
    out["region_ratio"] = rbest;
    if (rbest_h >= 0) {
        const int rx = rbest_r % rnx;
        const int rz = rbest_r / rnx;
        const int ax = x0 + rx * GRAVITY_REGION;
        const int az = z0 + rz * GRAVITY_REGION;
        out["region"] = Rect2i(ax, az, std::min(GRAVITY_REGION, x1 - ax), std::min(GRAVITY_REGION, z1 - az));
        out["region_level_cell"] = rbest_h;
        out["region_mass_above"] = rbest_w / (double)brick::MASS_FIXED;
    }
    return out;
}

// --- snow cover --------------------------------------------------------------

namespace {

constexpr int32_t SNOW_NONE = INT32_MIN;

// Merge equal tops into rectangles and emit a low box for each.
Array snow_boxes(const std::vector<int32_t> &top, int w, int d, float cell_x, float cell_z,
        float plate, float thickness, Vector3 offset) {
    PackedVector3Array verts;
    PackedVector3Array normals;
    PackedColorArray colours;
    PackedInt32Array indices;
    std::vector<uint8_t> used((size_t)w * (size_t)d, 0);
    auto quad = [&](Vector3 a, Vector3 b, Vector3 c, Vector3 e, Vector3 n, float ra, float rb,
            float rc, float re) {
        const int32_t base = (int32_t)verts.size();
        verts.push_back(a);
        verts.push_back(b);
        verts.push_back(c);
        verts.push_back(e);
        for (int i = 0; i < 4; ++i) {
            normals.push_back(n);
        }
        colours.push_back(Color(ra, 0, 0, 1));
        colours.push_back(Color(rb, 0, 0, 1));
        colours.push_back(Color(rc, 0, 0, 1));
        colours.push_back(Color(re, 0, 0, 1));
        indices.push_back(base);
        indices.push_back(base + 1);
        indices.push_back(base + 2);
        indices.push_back(base);
        indices.push_back(base + 2);
        indices.push_back(base + 3);
    };
    for (int z = 0; z < d; ++z) {
        for (int x = 0; x < w; ++x) {
            const size_t i0 = (size_t)x + (size_t)w * (size_t)z;
            const int32_t t = top[i0];
            if (t == SNOW_NONE || used[i0]) {
                continue;
            }
            int x1 = x + 1;
            while (x1 < w && !used[(size_t)x1 + (size_t)w * z] && top[(size_t)x1 + (size_t)w * z] == t) {
                ++x1;
            }
            int z1 = z + 1;
            while (z1 < d) {
                bool row = true;
                for (int xx = x; xx < x1; ++xx) {
                    const size_t ii = (size_t)xx + (size_t)w * (size_t)z1;
                    if (used[ii] || top[ii] != t) {
                        row = false;
                        break;
                    }
                }
                if (!row) {
                    break;
                }
                ++z1;
            }
            for (int zz = z; zz < z1; ++zz) {
                for (int xx = x; xx < x1; ++xx) {
                    used[(size_t)xx + (size_t)w * (size_t)zz] = 1;
                }
            }
            const float X0 = offset.x + x * cell_x;
            const float X1 = offset.x + x1 * cell_x;
            const float Z0 = offset.z + z * cell_z;
            const float Z1 = offset.z + z1 * cell_z;
            const float Y0 = offset.y + t * plate;
            const float Y1 = Y0 + thickness;
            // Top, then the four sides (the shader draws both faces).
            quad(Vector3(X0, Y1, Z0), Vector3(X1, Y1, Z0), Vector3(X1, Y1, Z1), Vector3(X0, Y1, Z1),
                    Vector3(0, 1, 0), 1, 1, 1, 1);
            quad(Vector3(X0, Y0, Z0), Vector3(X1, Y0, Z0), Vector3(X1, Y1, Z0), Vector3(X0, Y1, Z0),
                    Vector3(0, 0, -1), 0, 0, 1, 1);
            quad(Vector3(X1, Y0, Z1), Vector3(X0, Y0, Z1), Vector3(X0, Y1, Z1), Vector3(X1, Y1, Z1),
                    Vector3(0, 0, 1), 0, 0, 1, 1);
            quad(Vector3(X0, Y0, Z1), Vector3(X0, Y0, Z0), Vector3(X0, Y1, Z0), Vector3(X0, Y1, Z1),
                    Vector3(-1, 0, 0), 0, 0, 1, 1);
            quad(Vector3(X1, Y0, Z0), Vector3(X1, Y0, Z1), Vector3(X1, Y1, Z1), Vector3(X1, Y1, Z0),
                    Vector3(1, 0, 0), 0, 0, 1, 1);
        }
    }
    Array arrays;
    if (verts.is_empty()) {
        return arrays;
    }
    arrays.resize(Mesh::ARRAY_MAX);
    arrays[Mesh::ARRAY_VERTEX] = verts;
    arrays[Mesh::ARRAY_NORMAL] = normals;
    arrays[Mesh::ARRAY_COLOR] = colours;
    arrays[Mesh::ARRAY_INDEX] = indices;
    return arrays;
}

} // namespace

Array BrickWorld::build_snow_cover(int chunk_id, float thickness) {
    if (!valid_chunk(chunk_id)) {
        return Array();
    }
    const Chunk &c = chunks[chunk_id];
    const Vector3i dm = c.dims;
    const Vector3 cs = cell_size();
    std::vector<int32_t> top((size_t)dm.x * (size_t)dm.z, SNOW_NONE);
    for (int z = 0; z < dm.z; ++z) {
        for (int x = 0; x < dm.x; ++x) {
            for (int y = dm.y - 1; y >= 0; --y) {
                const int32_t bid = c.block_at(Vector3i(x, y, z));
                if (bid < 0) {
                    continue;
                }
                const Block &b = c.blocks[bid];
                // Furniture neither carries snow nor keeps it off: it is
                // inside, under a roof, or it is on a roof under the snow.
                if (!b.alive || b.detached || b.removed || b.decorative) {
                    continue;
                }
                top[(size_t)x + (size_t)dm.x * (size_t)z] = y + 1;
                break;
            }
        }
    }
    return snow_boxes(top, dm.x, dm.z, cs.x, cs.z, cs.y, thickness, Vector3());
}

Array BrickWorld::build_snow_cover_tops(const PackedInt32Array &tops, int w, int d, float cell,
        float plate, float thickness, Vector2 origin) {
    if (w <= 0 || d <= 0 || tops.size() < (int64_t)w * d) {
        return Array();
    }
    std::vector<int32_t> top((size_t)w * (size_t)d);
    for (int64_t i = 0; i < (int64_t)w * d; ++i) {
        const int32_t t = tops[i];
        top[(size_t)i] = t < -1000000 ? SNOW_NONE : t;
    }
    return snow_boxes(top, w, d, cell, cell, plate, thickness, Vector3(origin.x, 0.0f, origin.y));
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
    const SolveScratch &scratch = solve_scratch();
    const std::vector<int32_t> &scratch_depth = scratch.depth;
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

int BrickWorld::get_block_joints(int chunk_id, int block_id) const {
    if (!valid_chunk(chunk_id)) {
        return 0;
    }
    const Chunk &c = chunks[chunk_id];
    if (block_id < 0 || block_id >= (int)c.blocks.size()) {
        return 0;
    }
    const Block &b = c.blocks[block_id];
    return (b.support_broken ? JOINT_SUPPORT_BROKEN : 0)
            | (b.bottom_broken ? JOINT_BOTTOM_BROKEN : 0)
            | (b.strained ? JOINT_STRAINED : 0)
            | (b.held ? JOINT_HELD : 0);
}

void BrickWorld::set_block_joints(int chunk_id, int block_id, int joints) {
    if (!valid_chunk(chunk_id)) {
        return;
    }
    Chunk &c = chunks[chunk_id];
    if (block_id < 0 || block_id >= (int)c.blocks.size()) {
        return;
    }
    Block &b = c.blocks[block_id];
    b.support_broken = (joints & JOINT_SUPPORT_BROKEN) != 0;
    b.bottom_broken = (joints & JOINT_BOTTOM_BROKEN) != 0;
    conn_touch(chunk_id, block_id);
    b.strained = (joints & JOINT_STRAINED) != 0;
    b.held = (joints & JOINT_HELD) != 0;
}

int BrickWorld::heal_joints(int chunk_id) {
    if (!valid_chunk(chunk_id)) {
        return 0;
    }
    int healed = 0;
    for (Block &b : chunks[chunk_id].blocks) {
        if (b.support_broken || b.bottom_broken || b.strained || b.held) {
            b.support_broken = false;
            b.bottom_broken = false;
            b.strained = false;
            b.held = false;
            ++healed;
        }
    }
    // No cache to drop: the joint cache applies bottom_broken as it reads, and
    // support_broken is not in it at all.
    return healed;
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
    if (!valid_chunk(chunk_id)) {
        return Dictionary();
    }
    // The grounding pass tells us what is still standing and what it rests on.
    solve_grounded(chunk_id);
    return stability_of_grounding(chunk_id);
}

Dictionary BrickWorld::solve_structure(int chunk_id, int max_rounds, double budget_ms) {
    SolveScratch &scratch = solve_scratch();
    std::vector<int32_t> &scratch_depth = scratch.depth;
    std::vector<uint8_t> &scratch_grounded = scratch.grounded;
    Dictionary out;
    if (!valid_chunk(chunk_id)) {
        return out;
    }
    // Round after round while the cascade runs (see the header). Each stress
    // solve begins with its own grounding walk, so a round sees what the last
    // one failed; what can no longer reach the ground is not walked, so it
    // weighs nothing -- as if it had already been cut out, which is what
    // happened between two ticks' solves.
    const auto t0 = std::chrono::steady_clock::now();
    Dictionary stress_out;
    int rounds = 0;
    int failed_rounds = 0;
    int failures = 0;
    int last = 0;
    PackedInt32Array separated;
    while (true) {
        stress_out = solve_stress(chunk_id);
        ++rounds;
        last = (int)stress_out.get("failures", 0);
        if (last <= 0) {
            break;
        }
        ++failed_rounds;
        failures += last;
        separated.append_array(PackedInt32Array(stress_out.get("separated", PackedInt32Array())));
        if (rounds >= std::max(1, max_rounds)) {
            break;
        }
        if (budget_ms > 0.0 && std::chrono::duration<double, std::milli>(
                std::chrono::steady_clock::now() - t0).count() >= budget_ms) {
            break;
        }
    }
    stress_out["failures"] = failures;
    stress_out["separated"] = separated;
    stress_out["rounds"] = failed_rounds;
    // The stress solve changes support_broken on the joints it fails and on
    // nothing else, and a block in the walk was never support_broken to begin
    // with (the walk does not enter one) -- so no failures means the grounding
    // it walked is still the grounding. A failure means a fresh walk.
    if (last > 0) {
        solve_grounded(chunk_id);
    }
    Dictionary stability = stability_of_grounding(chunk_id);

    // solve_grounded's bytes, from the walk: reached, and alive.
    const size_t n = chunks[chunk_id].blocks.size();
    auto grounded_from_walk = [&]() {
        const Chunk &cc = chunks[chunk_id];
        scratch_grounded.assign(n, 0);
        for (size_t i = 0; i < n; ++i) {
            scratch_grounded[i] = (scratch_depth[i] >= 0 && cc.blocks[i].alive) ? 1 : 0;
        }
    };
    grounded_from_walk();
    Array groups = detached_groups_of(chunk_id, scratch_grounded.data());
    // What came loose only because load from elsewhere went through it, and
    // whose own studs hold it, is put back (Block::held) -- and the answers
    // asked again of the building it is part of once more.
    const int reattached = reattach_held_groups(chunk_id, groups, scratch_grounded.data());
    stress_out["reattached"] = reattached;
    if (reattached > 0) {
        solve_grounded(chunk_id);
        stability = stability_of_grounding(chunk_id);
        grounded_from_walk();
        groups = detached_groups_of(chunk_id, scratch_grounded.data());
    }

    out["stress"] = stress_out;
    out["stability"] = stability;
    out["groups"] = groups;
    return out;
}

int BrickWorld::reattach_held_groups(int chunk_id, const Array &groups, const uint8_t *grounded) {
    if (!valid_chunk(chunk_id) || groups.is_empty()) {
        return 0;
    }
    Chunk &c = chunks[chunk_id];
    const brick::JointCache &jc = joints_of(chunk_id);
    const Vector3i up = -chunk_down[chunk_id];
    const int64_t cap = std::max((int64_t)1, brick::to_mass_units(stress[chunk_id].tension_per_stud));
    std::vector<uint8_t> &in_group = solve_scratch().mark;
    in_group.assign(c.blocks.size(), 0);
    int reattached = 0;
    for (int gi = 0; gi < groups.size(); ++gi) {
        const PackedInt32Array g = groups[gi];
        if (g.size() == 0 || g.size() > REATTACH_MAX_BLOCKS) {
            continue;
        }
        // Only what the stress solve failed, and never held twice: a brick
        // broken by force -- sheared, torn -- or one its own weight already
        // pulled off a hold, stays where it fell.
        bool strained = false;
        bool eligible = true;
        int64_t mass = 0;
        for (int k = 0; k < g.size(); ++k) {
            const Block &b = c.blocks[g[k]];
            if (b.support_broken) {
                if (!b.strained || b.held) {
                    eligible = false;
                    break;
                }
                strained = true;
            }
            if (!b.decorative) {
                mass += std::max((int64_t)1, brick::to_mass_units(archetypes[b.archetype].mass));
            }
        }
        if (!eligible || !strained) {
            continue;
        }
        for (int k = 0; k < g.size(); ++k) {
            in_group[g[k]] = 1;
        }
        // Its studs into grounded structure: above it (it hangs from them) and
        // below it (it rests on them), as the stress solve counts contact.
        int64_t above = 0;
        int64_t below = 0;
        for (int k = 0; k < g.size(); ++k) {
            const int32_t bid = g[k];
            const Block &b = c.blocks[bid];
            if (b.decorative) {
                continue;
            }
            const int my_height = height_along(b.cell, up);
            for_each_joint(c, jc, bid, [&](int32_t nb, int count) {
                const Block &o = c.blocks[nb];
                if (in_group[nb] || !grounded[nb] || o.decorative || o.held) {
                    return;
                }
                if (height_along(o.cell, up) > my_height) {
                    above += count;
                } else {
                    below += count;
                }
            });
        }
        for (int k = 0; k < g.size(); ++k) {
            in_group[g[k]] = 0;
        }
        // The stress solve's own test, on its own weight: no pull at all when
        // nothing above holds it and something below does; otherwise the load
        // against the capacity of all its contact.
        const bool holds = (above == 0 && below > 0) || (above + below > 0 && mass <= cap * (above + below));
        if (!holds) {
            continue;
        }
        for (int k = 0; k < g.size(); ++k) {
            Block &b = c.blocks[g[k]];
            b.support_broken = false;
            b.strained = false;
            b.held = true;
        }
        ++reattached;
    }
    return reattached;
}

Dictionary BrickWorld::solve_rounds(int chunk_id, int rounds) {
    Dictionary out;
    if (!valid_chunk(chunk_id)) {
        return out;
    }
    int failures = 0;
    for (int r = 0; r < rounds; ++r) {
        failures += (int)solve_stress(chunk_id).get("failures", 0);
    }
    const PackedByteArray grounded = solve_grounded(chunk_id);
    const Array groups = detached_groups_of(chunk_id, grounded.ptr());
    out["failures"] = failures;
    out["reattached"] = reattach_held_groups(chunk_id, groups, grounded.ptr());
    return out;
}

Array BrickWorld::solve_structures(const PackedInt32Array &chunk_ids, int max_rounds,
        double budget_ms) {
    const int n = (int)chunk_ids.size();
    std::vector<Dictionary> results((size_t)n);
    // The first on this thread, in slot 0 like any other solve here; each of
    // the rest on a thread of its own with a slot of its own. More than there
    // are slots are solved here afterwards, in turn.
    const int par = std::min(n, (int)SOLVE_SLOTS);
    std::vector<std::thread> workers;
    for (int i = 1; i < par; ++i) {
        const int chunk = chunk_ids[i];
        workers.emplace_back([this, &results, i, chunk, max_rounds, budget_ms]() {
            scratch_slot = i;
            results[(size_t)i] = solve_structure(chunk, max_rounds, budget_ms);
        });
    }
    if (n > 0) {
        results[0] = solve_structure(chunk_ids[0], max_rounds, budget_ms);
    }
    for (std::thread &t : workers) {
        t.join();
    }
    for (int i = par; i < n; ++i) {
        results[(size_t)i] = solve_structure(chunk_ids[i], max_rounds, budget_ms);
    }
    Array out;
    for (const Dictionary &d : results) {
        out.push_back(d);
    }
    return out;
}

PackedInt32Array BrickWorld::place_blocks(int chunk_id, Vector3i origin,
        const PackedInt32Array &cells, const PackedInt32Array &archetype_ids,
        const PackedByteArray &colours) {
    PackedInt32Array out;
    const int64_t n = archetype_ids.size();
    if (!valid_chunk(chunk_id) || cells.size() < n * 3 || colours.size() < n) {
        return out;
    }
    out.resize(n);
    int32_t *ids = out.ptrw();
    for (int64_t i = 0; i < n; ++i) {
        ids[i] = place_block(chunk_id,
                origin + Vector3i(cells[i * 3], cells[i * 3 + 1], cells[i * 3 + 2]),
                archetype_ids[i], colours[i], false);
    }
    return out;
}

int BrickWorld::save_template(int chunk_id) {
    if (!valid_chunk(chunk_id)) {
        return -1;
    }
    ChunkTemplate t;
    const Chunk &c = chunks[chunk_id];
    t.origin = c.origin;
    t.dims = c.dims;
    t.blocks = c.blocks;
    // Worked out now if it was not already: the chunk that loads this is solved
    // the moment it is dressed, and the cache is the first thing that solve
    // would have built.
    t.joints = joints_of(chunk_id);
    templates.push_back(std::move(t));
    return (int)templates.size() - 1;
}

bool BrickWorld::load_template(int template_id, int chunk_id) {
    if (template_id < 0 || template_id >= (int)templates.size() || !valid_chunk(chunk_id)) {
        return false;
    }
    const ChunkTemplate &t = templates[template_id];
    Chunk &c = chunks[chunk_id];
    if (c.dims != t.dims || c.origin != t.origin || !c.blocks.empty()) {
        return false;
    }
    // The blocks as they were, and the cells each one claims -- what
    // place_block writes, for every block at once. A removed block claims
    // nothing, as it claimed nothing when the template was saved.
    c.blocks = t.blocks;
    conn_forget(chunk_id);
    for (size_t i = 0; i < c.blocks.size(); ++i) {
        const Block &b = c.blocks[i];
        if (b.removed) {
            continue;
        }
        const Archetype &a = archetypes[b.archetype];
        const Vector3i base = b.cell - c.origin;
        for (int x = 0; x < a.size.x; ++x) {
            for (int y = 0; y < a.size.y; ++y) {
                for (int z = 0; z < a.size.z; ++z) {
                    if (a.solid_at(x, y, z)) {
                        c.occupancy.set(c.index_of(Vector3i(base.x + x, base.y + y, base.z + z)),
                                (int32_t)i);
                    }
                }
            }
        }
    }
    joint_cache[chunk_id] = t.joints;
    c.bake.valid = false;
    if (!bake_jobs.empty() && bake_pending(chunk_id)) {
        settle_bake_job(chunk_id, false);
    }
    if (!coarse_jobs.empty()) {
        settle_coarse_job(chunk_id);
    }
    return true;
}

int BrickWorld::get_template_count() const {
    return (int)templates.size();
}

// --- a building a storey at a time (Docs/Space.md 5.3a) ---------------------
//
// A building's block ids are its template's: the recipe laid whole, once, when
// the city was laid out. A band chunk holds that whole list from the start, so
// an id means the same brick whichever storeys are laid, which is what the
// damage record rides on. What is not laid is ABSENT: `removed` (owning no
// cells, so every bake, solve, hit and count already passes it by) and marked
// in Chunk::absent, whose bits plus the block's own hp / scorched / colour are
// its damage record until it is laid.

int BrickWorld::create_band_chunk(int template_id) {
    if (template_id < 0 || template_id >= (int)templates.size()) {
        return -1;
    }
    const ChunkTemplate &t = templates[template_id];
    // Made as any chunk is, one cell tall, then given the template's dims with
    // an EMPTY occupancy window: the building's sections number as they would
    // with every brick in it, and the grid costs nothing until a storey is laid.
    const int id = create_chunk(t.origin, Vector3i(t.dims.x, 1, t.dims.z));
    if (id < 0) {
        return -1;
    }
    Chunk &c = chunks[id];
    c.dims = t.dims;
    c.occ_y0 = 0;
    c.occ_dy = 0;
    c.occupancy.reset(0);
    c.blocks = t.blocks;
    c.absent.assign(c.blocks.size(), 0);
    for (size_t i = 0; i < c.blocks.size(); ++i) {
        Block &b = c.blocks[i];
        if (b.removed) {
            continue; // removed in the recipe itself: stays a tombstone
        }
        c.absent[i] = Chunk::ABSENT | (b.alive ? Chunk::ABSENT_ALIVE : 0)
                | (b.detached ? Chunk::ABSENT_DETACHED : 0);
        b.removed = true;
        b.alive = false;
    }
    joint_cache[id] = brick::JointCache();
    conn_forget(id);
    return id;
}

void BrickWorld::set_occupancy_window(Chunk &c, int y0, int y1) {
    y0 = std::max(y0, 0);
    y1 = std::min(y1, c.dims.y);
    c.occ_y0 = y0;
    c.occ_dy = std::max(y1 - y0, 0);
    c.occupancy.reset((int64_t)c.dims.x * c.occ_dy * c.dims.z);
    for (size_t i = 0; i < c.blocks.size(); ++i) {
        const Block &b = c.blocks[i];
        if (b.removed) {
            continue;
        }
        const Archetype &a = archetypes[b.archetype];
        const Vector3i base = b.cell - c.origin;
        for (int x = 0; x < a.size.x; ++x) {
            for (int y = 0; y < a.size.y; ++y) {
                for (int z = 0; z < a.size.z; ++z) {
                    if (a.solid_at(x, y, z)) {
                        c.occupancy.set(c.index_of(Vector3i(base.x + x, base.y + y, base.z + z)),
                                (int32_t)i);
                    }
                }
            }
        }
    }
}

int BrickWorld::lay_band(int chunk_id, int template_id, int y_lo, int y_hi) {
    if (!valid_chunk(chunk_id) || template_id < 0 || template_id >= (int)templates.size()) {
        return 0;
    }
    Chunk &c = chunks[chunk_id];
    const ChunkTemplate &t = templates[template_id];
    if (c.absent.size() != c.blocks.size() || c.blocks.size() < t.blocks.size()) {
        return 0; // not a band chunk of this template
    }
    // Which absent blocks come in, and the window that has to hold them and
    // everything already laid.
    std::vector<int32_t> in;
    int lo = c.occ_dy > 0 ? c.occ_y0 : INT_MAX;
    int hi = c.occ_dy > 0 ? c.occ_y0 + c.occ_dy : INT_MIN;
    for (size_t i = 0; i < t.blocks.size(); ++i) {
        if ((c.absent[i] & Chunk::ABSENT) == 0) {
            continue;
        }
        const Block &b = c.blocks[i];
        if (b.cell.y < y_lo || b.cell.y >= y_hi) {
            continue;
        }
        in.push_back((int32_t)i);
        const int by = b.cell.y - c.origin.y;
        lo = std::min(lo, by);
        hi = std::max(hi, by + archetypes[b.archetype].size.y);
    }
    if (in.empty()) {
        return 0;
    }
    // A worker may be reading this chunk -- a bake, a coarse mesh, a chamfered
    // band. The blocks and the grid are about to change under it (the grid
    // reallocated), so every job on it is settled first, as release_chunk does.
    settle_bake_job(chunk_id, false);
    settle_coarse_job(chunk_id);
    drop_chamfer(chunk_id, -1, true);
    // Present, with the record it carried while absent.
    for (const int32_t i : in) {
        Block &b = c.blocks[(size_t)i];
        const uint8_t a = c.absent[(size_t)i];
        b.removed = false;
        b.detached = (a & Chunk::ABSENT_DETACHED) != 0;
        b.alive = (a & Chunk::ABSENT_ALIVE) != 0 && !b.detached;
        if (!b.alive) {
            b.hp = 0;
        }
        c.absent[(size_t)i] = 0;
    }
    // A dead or detached block still owns its cells (place_block's note), so
    // every block that came in is written -- by rebuilding the grid for the
    // window that holds them all. A storey is ~100k cells.
    if (c.occ_dy <= 0 || lo < c.occ_y0 || hi > c.occ_y0 + c.occ_dy) {
        set_occupancy_window(c, lo, hi);
    } else {
        for (const int32_t i : in) {
            const Block &b = c.blocks[(size_t)i];
            const Archetype &ar = archetypes[b.archetype];
            const Vector3i base = b.cell - c.origin;
            for (int x = 0; x < ar.size.x; ++x) {
                for (int y = 0; y < ar.size.y; ++y) {
                    for (int z = 0; z < ar.size.z; ++z) {
                        if (ar.solid_at(x, y, z)) {
                            c.occupancy.set(c.index_of(Vector3i(base.x + x, base.y + y, base.z + z)),
                                    i);
                        }
                    }
                }
            }
        }
    }
    // Everything derived from the cells is stale: the joints (rebuilt from the
    // grid on the next ask), the components and the bake.
    joint_cache[chunk_id] = brick::JointCache();
    conn_forget(chunk_id);
    c.bake.valid = false;
    return (int)in.size();
}

int BrickWorld::unlay_band(int chunk_id, int y_lo, int y_hi, int template_blocks) {
    if (!valid_chunk(chunk_id)) {
        return 0;
    }
    Chunk &c = chunks[chunk_id];
    if (c.absent.size() != c.blocks.size()) {
        return 0; // not a band chunk
    }
    const size_t n = std::min(c.blocks.size(), (size_t)std::max(template_blocks, 0));
    std::vector<int32_t> out;
    for (size_t i = 0; i < n; ++i) {
        const Block &b = c.blocks[i];
        if (b.removed || (c.absent[i] & Chunk::ABSENT) != 0) {
            continue;
        }
        if (b.cell.y >= y_lo && b.cell.y < y_hi) {
            out.push_back((int32_t)i);
        }
    }
    if (out.empty()) {
        return 0;
    }
    // As lay_band: a worker may be reading this chunk.
    settle_bake_job(chunk_id, false);
    settle_coarse_job(chunk_id);
    drop_chamfer(chunk_id, -1, true);
    for (const int32_t i : out) {
        Block &b = c.blocks[(size_t)i];
        // Its cells, then its record: alive or not, left as a piece or not.
        const Archetype &a = archetypes[b.archetype];
        const Vector3i base = b.cell - c.origin;
        for (int x = 0; x < a.size.x; ++x) {
            for (int y = 0; y < a.size.y; ++y) {
                for (int z = 0; z < a.size.z; ++z) {
                    if (!a.solid_at(x, y, z)) {
                        continue;
                    }
                    const int64_t k = c.index_of(Vector3i(base.x + x, base.y + y, base.z + z));
                    if (c.occupancy[k] == i) {
                        c.occupancy.set(k, -1);
                    }
                }
            }
        }
        c.absent[(size_t)i] = Chunk::ABSENT | (b.alive ? Chunk::ABSENT_ALIVE : 0)
                | (b.detached ? Chunk::ABSENT_DETACHED : 0);
        b.removed = true;
        b.alive = false;
        b.support_broken = false;
        b.strained = false;
        b.held = false;
        b.bottom_broken = false;
    }
    joint_cache[chunk_id] = brick::JointCache();
    conn_forget(chunk_id);
    c.bake.valid = false;
    return (int)out.size();
}

int BrickWorld::get_absent_count(int chunk_id) const {
    if (!valid_chunk(chunk_id)) {
        return 0;
    }
    int n = 0;
    for (const uint8_t a : chunks[chunk_id].absent) {
        if ((a & Chunk::ABSENT) != 0) {
            ++n;
        }
    }
    return n;
}

bool BrickWorld::is_block_absent(int chunk_id, int block_id) const {
    if (!valid_chunk(chunk_id)) {
        return false;
    }
    const Chunk &c = chunks[chunk_id];
    return block_id >= 0 && block_id < (int)c.blocks.size() && c.is_absent(block_id);
}

float BrickWorld::get_template_mass(int template_id, int y_lo, int y_hi) const {
    if (template_id < 0 || template_id >= (int)templates.size()) {
        return 0.0f;
    }
    float total = 0.0f;
    for (const Block &b : templates[template_id].blocks) {
        if (b.removed || !b.alive || b.decorative || b.cell.y < y_lo || b.cell.y >= y_hi) {
            continue;
        }
        total += std::max(archetypes[b.archetype].mass, 0.0001f);
    }
    return total;
}

PackedInt32Array BrickWorld::get_blocks_topping(int chunk_id, int y) const {
    PackedInt32Array out;
    if (!valid_chunk(chunk_id)) {
        return out;
    }
    const Chunk &c = chunks[chunk_id];
    for (size_t i = 0; i < c.blocks.size(); ++i) {
        const Block &b = c.blocks[i];
        if (!b.alive || b.removed || b.decorative) {
            continue;
        }
        if (b.cell.y + archetypes[b.archetype].size.y == y) {
            out.push_back((int32_t)i);
        }
    }
    return out;
}

PackedInt32Array BrickWorld::get_blocks_in_band(int chunk_id, int y_lo, int y_hi) const {
    PackedInt32Array out;
    if (!valid_chunk(chunk_id)) {
        return out;
    }
    const Chunk &c = chunks[chunk_id];
    for (size_t i = 0; i < c.blocks.size(); ++i) {
        const Block &b = c.blocks[i];
        if (b.alive && !b.removed && b.cell.y >= y_lo && b.cell.y < y_hi) {
            out.push_back((int32_t)i);
        }
    }
    return out;
}

Vector3 BrickWorld::get_template_com(int template_id, int y_lo, int y_hi) const {
    if (template_id < 0 || template_id >= (int)templates.size()) {
        return Vector3();
    }
    double m = 0.0, x = 0.0, y = 0.0, z = 0.0;
    for (const Block &b : templates[template_id].blocks) {
        if (b.removed || !b.alive || b.decorative || b.cell.y < y_lo || b.cell.y >= y_hi) {
            continue;
        }
        const Archetype &a = archetypes[b.archetype];
        const double w = std::max(a.mass, 0.0001f);
        m += w;
        x += w * (b.cell.x + a.size.x * 0.5);
        y += w * (b.cell.y + a.size.y * 0.5);
        z += w * (b.cell.z + a.size.z * 0.5);
    }
    return m > 0.0 ? Vector3((float)(x / m), (float)(y / m), (float)(z / m)) : Vector3();
}

PackedVector2Array BrickWorld::get_blocks_footprint(int chunk_id, const PackedInt32Array &ids) const {
    PackedVector2Array out;
    if (!valid_chunk(chunk_id)) {
        return out;
    }
    const Chunk &c = chunks[chunk_id];
    for (int64_t i = 0; i < ids.size(); ++i) {
        const int32_t id = ids[i];
        if (id < 0 || id >= (int32_t)c.blocks.size()) {
            continue;
        }
        const Block &b = c.blocks[id];
        const Vector3i sz = archetypes[b.archetype].size;
        const float x0 = (float)b.cell.x, z0 = (float)b.cell.z;
        const float x1 = x0 + sz.x, z1 = z0 + sz.z;
        out.push_back(Vector2(x0, z0));
        out.push_back(Vector2(x1, z0));
        out.push_back(Vector2(x1, z1));
        out.push_back(Vector2(x0, z1));
    }
    return out;
}

int64_t BrickWorld::get_occupancy_bytes(int chunk_id) const {
    return valid_chunk(chunk_id) ? chunks[chunk_id].occupancy.bytes() : 0;
}

Dictionary BrickWorld::stability_of_grounding(int chunk_id) {
    SolveScratch &scratch = solve_scratch();
    std::vector<int32_t> &scratch_depth = scratch.depth;
    Dictionary out;
    Chunk &c = chunks[chunk_id];
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
        if (grounded_at(chunk_id, b.cell.y)) {
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

    // Each block is hit ONCE, at the distance of its nearest cell: a block
    // covers many cells, and charging it per cell would make a 2x4 eight
    // times weaker than a 1x1.
    std::vector<std::pair<int32_t, float>> nearest;
    for (int x = lo.x; x <= hi.x; ++x) {
        for (int y = lo.y; y <= hi.y; ++y) {
            for (int z = lo.z; z <= hi.z; ++z) {
                const Vector3i l(x, y, z);
                const int32_t bid = c.block_at(l);
                if (bid < 0 || !c.blocks[bid].alive) {
                    continue;
                }
                const Vector3 cell_centre((x + 0.5f) * cs.x, (y + 0.5f) * cs.y, (z + 0.5f) * cs.z);
                const float d2 = cell_centre.distance_squared_to(centre_local);
                if (d2 > r2) {
                    continue;
                }
                nearest.push_back({bid, d2});
            }
        }
    }
    std::sort(nearest.begin(), nearest.end());   // by id, then distance: nearest first

    // Damage falls off from twice a PLA block's life at the centre to once
    // at the rim. A block's life is its hp (a fraction of full, 0..255) times
    // its material's toughness, so PLA -- toughness 1 -- dies anywhere in the
    // blast, which is what every block did before materials; a tougher one
    // may survive with less hp, and the next hit finds it weaker. Integer and
    // order-fixed, so a replayed hit lands the same (Docs/AIPlan.md P0).
    for (size_t i = 0; i < nearest.size(); ++i) {
        if (i > 0 && nearest[i].first == nearest[i - 1].first) {
            continue;   // this block's nearest cell has already been charged
        }
        Block &b = c.blocks[nearest[i].first];
        const float d = std::sqrt(nearest[i].second) / radius_m;
        const float damage = 255.0f * (2.0f - std::min(d, 1.0f));
        const float toughness = std::max(brick_material_toughness(b.material), 0.05f);
        const float left = (float)b.hp * toughness - damage;
        if (left > 0.0f) {
            // Rounded DOWN (and never to 0 while alive): rounding up handed
            // back a sliver each hit, and a hit that should have finished a
            // brick left it two points of life.
            b.hp = (uint8_t)std::clamp((int)std::floor(left / toughness), 1, 255);
            continue;
        }
        b.alive = false;
        conn_touch(chunk_id, nearest[i].first);
        b.hp = 0;
        killed.push_back(nearest[i].first);
    }
    return killed;
}

PackedInt32Array BrickWorld::chip_hit(int chunk_id, Vector3 world_point, float radius_m, int damage) {
    PackedInt32Array killed;
    if (!valid_chunk(chunk_id) || damage <= 0) {
        return killed;
    }
    Chunk &c = chunks[chunk_id];
    const Vector3 cs = cell_size();
    const Vector3 centre_local = c.xform.affine_inverse().xform(world_point);
    const float r = std::max(radius_m, 0.0f);
    const Vector3 r3(r, r, r);
    const Vector3i lo = brick::world_to_grid(centre_local - r3);
    const Vector3i hi = brick::world_to_grid(centre_local + r3);
    const Vector3i own = brick::world_to_grid(centre_local);
    const float r2 = r * r;
    const uint8_t dmg = (uint8_t)std::min(damage, 255);

    // Which blocks, each once: one block covers many cells, and wearing it once
    // per cell would make a big brick softer than a small one.
    std::vector<int32_t> hit;
    for (int x = lo.x; x <= hi.x; ++x) {
        for (int y = lo.y; y <= hi.y; ++y) {
            for (int z = lo.z; z <= hi.z; ++z) {
                const Vector3i l(x, y, z);
                const int32_t bid = c.block_at(l);
                if (bid < 0 || !c.blocks[bid].alive) {
                    continue;
                }
                const Vector3 cell_centre((x + 0.5f) * cs.x, (y + 0.5f) * cs.y, (z + 0.5f) * cs.z);
                if (l != own && cell_centre.distance_squared_to(centre_local) > r2) {
                    continue;
                }
                hit.push_back(bid);
            }
        }
    }
    std::sort(hit.begin(), hit.end());
    hit.erase(std::unique(hit.begin(), hit.end()), hit.end());
    for (int32_t bid : hit) {
        Block &b = c.blocks[bid];
        // A tougher material wears slower: the damage divided by its
        // toughness, in tenths so it stays integer (metal 4.0 -> a quarter).
        const int t10 = std::max(1, (int)std::lround(brick_material_toughness(b.material) * 10.0f));
        const uint8_t wear = (uint8_t)std::max(1, ((int)dmg * 10 + t10 / 2) / t10);
        b.hp = b.hp > wear ? (uint8_t)(b.hp - wear) : (uint8_t)0;
        if (b.hp == 0) {
            b.alive = false;
            conn_touch(chunk_id, bid);
            killed.push_back(bid);
        }
    }
    return killed;
}

AABB BrickWorld::get_blocks_box(int chunk_id, const PackedInt32Array &block_ids) const {
    if (!valid_chunk(chunk_id)) {
        return AABB();
    }
    const Chunk &c = chunks[chunk_id];
    const Vector3 cs = cell_size();
    bool any = false;
    Vector3 lo, hi;
    for (int64_t i = 0; i < block_ids.size(); ++i) {
        const int32_t bid = block_ids[i];
        if (bid < 0 || bid >= (int32_t)c.blocks.size() || c.blocks[(size_t)bid].removed) {
            continue;
        }
        const Block &b = c.blocks[(size_t)bid];
        const Vector3i base = b.cell - c.origin;
        const Vector3i sz = archetypes[b.archetype].size;
        const Vector3 a(base.x * cs.x, base.y * cs.y, base.z * cs.z);
        const Vector3 z((base.x + sz.x) * cs.x, (base.y + sz.y) * cs.y, (base.z + sz.z) * cs.z);
        if (!any) {
            lo = a;
            hi = z;
            any = true;
        } else {
            lo = Vector3(std::min(lo.x, a.x), std::min(lo.y, a.y), std::min(lo.z, a.z));
            hi = Vector3(std::max(hi.x, z.x), std::max(hi.y, z.y), std::max(hi.z, z.z));
        }
    }
    return any ? AABB(lo, hi - lo) : AABB();
}

int BrickWorld::get_chunk_authored_tris(int chunk_id) const {
    if (!valid_chunk(chunk_id)) {
        return 0;
    }
    int n = 0;
    for (const Block &b : chunks[chunk_id].blocks) {
        if (b.alive) {
            n += (int)archetypes[b.archetype].mesh.size();
        }
    }
    return n;
}

PackedInt32Array BrickWorld::get_worn_blocks(int chunk_id) const {
    PackedInt32Array out;
    if (!valid_chunk(chunk_id)) {
        return out;
    }
    const Chunk &c = chunks[chunk_id];
    for (size_t i = 0; i < c.blocks.size(); ++i) {
        const Block &b = c.blocks[i];
        const bool live = c.is_absent((int32_t)i)
                ? (c.absent[i] & Chunk::ABSENT_ALIVE) != 0
                : (b.alive && !b.removed);
        if (live && b.hp < 255) {
            out.push_back((int32_t)i);
            out.push_back((int32_t)b.hp);
        }
    }
    return out;
}

void BrickWorld::set_worn_blocks(int chunk_id, const PackedInt32Array &worn) {
    if (!valid_chunk(chunk_id)) {
        return;
    }
    Chunk &c = chunks[chunk_id];
    for (int i = 0; i + 1 < worn.size(); i += 2) {
        const int32_t id = worn[i];
        if (id < 0 || id >= (int32_t)c.blocks.size()) {
            continue;
        }
        Block &b = c.blocks[id];
        const bool live = c.is_absent(id) ? (c.absent[(size_t)id] & Chunk::ABSENT_ALIVE) != 0
                : (b.alive && !b.removed);
        if (!live) {
            continue;
        }
        b.hp = (uint8_t)std::clamp((int)worn[i + 1], 1, 255);
    }
}

PackedInt32Array BrickWorld::scorch_hit(int chunk_id, Vector3 world_point, float radius_m) {
    PackedInt32Array out;
    if (!valid_chunk(chunk_id)) {
        return out;
    }
    Chunk &c = chunks[chunk_id];
    const Vector3 cs = cell_size();
    const Vector3 centre_local = c.xform.affine_inverse().xform(world_point);
    const float r = std::max(radius_m, 0.0f);
    const Vector3 r3(r, r, r);
    const Vector3i lo = brick::world_to_grid(centre_local - r3);
    const Vector3i hi = brick::world_to_grid(centre_local + r3);
    const Vector3i own = brick::world_to_grid(centre_local);
    const float r2 = r * r;
    std::vector<int32_t> hit;
    for (int x = lo.x; x <= hi.x; ++x) {
        for (int y = lo.y; y <= hi.y; ++y) {
            for (int z = lo.z; z <= hi.z; ++z) {
                const Vector3i l(x, y, z);
                const int32_t bid = c.block_at(l);
                if (bid < 0 || !c.blocks[bid].alive || c.blocks[bid].scorched) {
                    continue;
                }
                const Vector3 cell_centre((x + 0.5f) * cs.x, (y + 0.5f) * cs.y, (z + 0.5f) * cs.z);
                if (l != own && cell_centre.distance_squared_to(centre_local) > r2) {
                    continue;
                }
                hit.push_back(bid);
            }
        }
    }
    std::sort(hit.begin(), hit.end());
    hit.erase(std::unique(hit.begin(), hit.end()), hit.end());
    for (int32_t bid : hit) {
        Block &b = c.blocks[bid];
        b.scorched = true;
        b.colour = (uint8_t)brick_material_darkest(b.material);
        out.push_back(bid);
    }
    // The bake caches each face's colour (set_block_colour).
    if (!hit.empty() && (c.bake.valid || bake_pending(chunk_id))) {
        drop_chunk_bake(chunk_id);
    }
    return out;
}

PackedInt32Array BrickWorld::get_scorched_blocks(int chunk_id) const {
    PackedInt32Array out;
    if (!valid_chunk(chunk_id)) {
        return out;
    }
    const Chunk &c = chunks[chunk_id];
    for (size_t i = 0; i < c.blocks.size(); ++i) {
        const Block &b = c.blocks[i];
        const bool live = c.is_absent((int32_t)i)
                ? (c.absent[i] & Chunk::ABSENT_ALIVE) != 0
                : (b.alive && !b.removed);
        if (live && b.scorched) {
            out.push_back((int32_t)i);
        }
    }
    return out;
}

void BrickWorld::set_scorched_blocks(int chunk_id, const PackedInt32Array &ids) {
    if (!valid_chunk(chunk_id)) {
        return;
    }
    Chunk &c = chunks[chunk_id];
    bool any = false;
    for (int64_t i = 0; i < ids.size(); ++i) {
        const int32_t id = ids[i];
        if (id < 0 || id >= (int32_t)c.blocks.size()) {
            continue;
        }
        Block &b = c.blocks[id];
        if (c.is_absent(id)) {
            // Its record: it comes in charred (lay_band keeps the colour).
            if ((c.absent[(size_t)id] & Chunk::ABSENT_ALIVE) != 0) {
                b.scorched = true;
                b.colour = (uint8_t)brick_material_darkest(b.material);
            }
            continue;
        }
        if (!b.alive || b.removed) {
            continue;
        }
        b.scorched = true;
        b.colour = (uint8_t)brick_material_darkest(b.material);
        any = true;
    }
    if (any && (c.bake.valid || bake_pending(chunk_id))) {
        drop_chunk_bake(chunk_id);
    }
}

// --- fire, brick by brick ---------------------------------------------------
//
// Per material, in BRICK_MATERIALS' order (append-only, as that table is):
//   TAKE   how readily it takes heat -- leaves at once, nylon grudgingly. Metal
//          and stone take a little (they char) and never burn.
//   BURN   seconds a 12-cell block (a 2x2 brick) burns. Plastic slumps and goes
//          in a few seconds; a wooden trunk smoulders for half a minute;
//          leaves flash.
//   FLAME  how hard it heats what is round it while it burns.
// PLA, PLA matte, PLA silk, ABS, PETG, TPU, Nylon, Glow PLA, Carbon PLA,
// Wood PLA, Wood, Metal, Stone, Leaf.
namespace {
constexpr float FIRE_TAKE[] = {0.55f, 0.55f, 0.55f, 0.5f, 0.45f, 0.4f, 0.35f, 0.55f, 0.45f,
        0.8f, 1.0f, 0.25f, 0.2f, 1.6f};
constexpr float FIRE_BURN[] = {7.0f, 7.0f, 7.0f, 8.0f, 8.0f, 10.0f, 10.0f, 7.0f, 8.0f,
        9.0f, 26.0f, 0.0f, 0.0f, 3.0f};
constexpr float FIRE_FLAME[] = {0.7f, 0.7f, 0.7f, 0.8f, 0.6f, 0.6f, 0.6f, 0.7f, 0.7f,
        0.8f, 1.0f, 0.0f, 0.0f, 0.9f};
constexpr int FIRE_TABLE = (int)(sizeof(FIRE_TAKE) / sizeof(FIRE_TAKE[0]));

float fire_take(int m) { return (m >= 0 && m < FIRE_TABLE) ? FIRE_TAKE[m] : FIRE_TAKE[0]; }
float fire_flame(int m) { return (m >= 0 && m < FIRE_TABLE) ? FIRE_FLAME[m] : FIRE_FLAME[0]; }

// Heat a burning neighbour gives, per second, per unit of contact: tuned so a
// leaf over a burning leaf catches in about a second and a length of trunk over
// a burning one in about one and a half.
constexpr float FIRE_HEAT_K = 0.12f;
// More contact than this heats no faster: a big block over a big fire is not
// set alight in an instant.
constexpr float FIRE_GAIN_CAP = 8.0f;
// What a block loses to the air, per second, as a share of its heat. A block
// beside a fire it cannot catch from settles below 1 and never does.
constexpr float FIRE_COOL = 0.12f;
// Heat at which a block chars (its material's darkest colour, for good).
constexpr float FIRE_CHAR = 0.6f;
constexpr float FIRE_MAX_HEAT = 1.5f;
// Flames climb: what is above a burning block is heated three times what is
// beside it, and what is below a fraction. Reach is how many cells of air the
// heat crosses that way -- up four (0.56 m), sideways one, more downwind.
constexpr float FIRE_UP = 3.0f;
constexpr float FIRE_SIDE = 1.0f;
constexpr float FIRE_DOWN = 0.3f;
constexpr int FIRE_REACH_UP = 4;
// Wind at this speed (m/s) is full strength: downwind heated 3.5x, upwind a
// fifth, and the heat carried three cells further downwind.
constexpr float FIRE_WIND_FULL = 15.0f;

const Vector3i FIRE_DIRS[6] = {Vector3i(0, 1, 0), Vector3i(0, -1, 0), Vector3i(1, 0, 0),
        Vector3i(-1, 0, 0), Vector3i(0, 0, 1), Vector3i(0, 0, -1)};

bool fire_air(const brick::Chunk &c, const Vector3i &l, int32_t self) {
    if (!c.in_bounds(l)) {
        return true;
    }
    const int32_t nb = c.occupancy[c.index_of(l)];
    if (nb == self) {
        return false;
    }
    if (nb < 0) {
        return true;
    }
    const brick::Block &o = c.blocks[nb];
    return !o.alive || o.detached || o.removed;
}
} // namespace

float BrickWorld::fire_burn_seconds(int material, int cells) {
    if (material < 0 || material >= FIRE_TABLE || FIRE_BURN[material] <= 0.0f) {
        return material >= FIRE_TABLE ? FIRE_BURN[0] : 0.0f;
    }
    const float size = std::cbrt(std::max(cells, 1) / 12.0f);
    return FIRE_BURN[material] * std::clamp(size, 0.5f, 3.0f);
}

std::map<int32_t, BrickWorld::FireBlock> *BrickWorld::fire_of(int chunk_id) {
    if (!valid_chunk(chunk_id)) {
        return nullptr;
    }
    if ((int)fire_state.size() <= chunk_id) {
        fire_state.resize((size_t)chunk_id + 1);
    }
    return &fire_state[(size_t)chunk_id];
}

int BrickWorld::fire_heat(int chunk_id, Vector3 world_point, float radius_m, float heat,
        bool by_material) {
    std::map<int32_t, FireBlock> *fs = fire_of(chunk_id);
    if (fs == nullptr || heat <= 0.0f) {
        return 0;
    }
    Chunk &c = chunks[chunk_id];
    const Vector3 cs = cell_size();
    const Vector3 centre_local = c.xform.affine_inverse().xform(world_point);
    const float r = std::max(radius_m, 0.0f);
    const Vector3 r3(r, r, r);
    const Vector3i lo = brick::world_to_grid(centre_local - r3);
    const Vector3i hi = brick::world_to_grid(centre_local + r3);
    const Vector3i own = brick::world_to_grid(centre_local);
    const float r2 = r * r;
    std::vector<int32_t> hit;
    for (int x = lo.x; x <= hi.x; ++x) {
        for (int y = lo.y; y <= hi.y; ++y) {
            for (int z = lo.z; z <= hi.z; ++z) {
                const Vector3i l(x, y, z);
                const int32_t bid = c.block_at(l);
                if (bid < 0 || !c.blocks[bid].alive || c.blocks[bid].detached) {
                    continue;
                }
                const Vector3 cell_centre((x + 0.5f) * cs.x, (y + 0.5f) * cs.y, (z + 0.5f) * cs.z);
                if (l != own && cell_centre.distance_squared_to(centre_local) > r2) {
                    continue;
                }
                hit.push_back(bid);
            }
        }
    }
    std::sort(hit.begin(), hit.end());
    hit.erase(std::unique(hit.begin(), hit.end()), hit.end());
    int burnable = 0;
    for (int32_t bid : hit) {
        const int m = c.blocks[bid].material;
        const bool burns = fire_burn_seconds(m, 1) > 0.0f;
        FireBlock &fb = (*fs)[bid];
        // A flame put to it: what burns takes the heat whole, what does not
        // takes its share (and only chars).
        fb.heat = std::min(FIRE_MAX_HEAT,
                fb.heat + ((burns && !by_material) ? heat : heat * fire_take(m)));
        burnable += burns ? 1 : 0;
    }
    return burnable;
}

Dictionary BrickWorld::fire_step(int chunk_id, float dt, Vector3 wind, float damp, int max_burning) {
    Dictionary out;
    PackedInt32Array killed;
    PackedInt32Array charred;
    PackedVector3Array points;
    PackedFloat32Array power;
    PackedVector3Array loose;
    int caught = 0;
    int burning = 0;
    std::map<int32_t, FireBlock> *fs = fire_of(chunk_id);
    if (fs != nullptr && !fs->empty()) {
        Chunk &c = chunks[chunk_id];
        const Vector3 cs = cell_size();
        const Vector3 wl = c.xform.basis.xform_inv(wind);
        const float ws = std::clamp(wl.length() / FIRE_WIND_FULL, 0.0f, 1.5f);
        const Vector3 wd = ws > 0.0f ? wl.normalized() : Vector3();
        float weight[6];
        int reach[6];
        for (int d = 0; d < 6; ++d) {
            const Vector3i dv = FIRE_DIRS[d];
            const float along = wd.dot(Vector3(dv.x, dv.y, dv.z));
            const float base = dv.y > 0 ? FIRE_UP : (dv.y < 0 ? FIRE_DOWN : FIRE_SIDE);
            weight[d] = base * std::max(0.2f, 1.0f + 2.5f * ws * along);
            reach[d] = dv.y > 0 ? FIRE_REACH_UP
                    : (dv.y < 0 ? 1 : 1 + (int)std::lround(3.0f * ws * std::max(0.0f, along)));
        }
        // 1. What every burning block gives what is round it.
        std::map<int32_t, float> gain;
        for (auto &kv : *fs) {
            FireBlock &fb = kv.second;
            if (!fb.burning) {
                continue;
            }
            const int32_t id = kv.first;
            const Block &b = c.blocks[id];
            if (!b.alive || b.detached || b.removed) {
                continue;
            }
            burning += 1;
            // Flames build for a second, and die down as the fuel runs out.
            const float p = fire_flame(b.material) * std::min(1.0f, 0.5f + fb.age * 0.5f)
                    * std::min(1.0f, 0.3f + fb.fuel / std::max(0.01f, 0.3f * fb.fuel0));
            const Vector3i base = b.cell - c.origin;
            const Vector3i sz = archetypes[b.archetype].size;
            for (int x = 0; x < sz.x; ++x) {
                for (int y = 0; y < sz.y; ++y) {
                    for (int z = 0; z < sz.z; ++z) {
                        const Vector3i l = base + Vector3i(x, y, z);
                        if (c.block_at(l) != id) {
                            continue;
                        }
                        for (int d = 0; d < 6; ++d) {
                            for (int k = 1; k <= reach[d]; ++k) {
                                const Vector3i n = l + FIRE_DIRS[d] * k;
                                if (!c.in_bounds(n)) {
                                    break;
                                }
                                const int32_t nb = c.occupancy[c.index_of(n)];
                                if (nb == id) {
                                    break;
                                }
                                if (nb >= 0 && c.blocks[nb].alive && !c.blocks[nb].detached) {
                                    gain[nb] += p * weight[d] / (float)k;
                                    break;
                                }
                            }
                        }
                    }
                }
            }
        }
        for (auto &kv : gain) {
            if (fs->find(kv.first) == fs->end()) {
                (*fs)[kv.first] = FireBlock();
            }
        }
        // 2. Every block with heat: burn, heat, cool, char, catch.
        bool rebake = false;
        for (auto it = fs->begin(); it != fs->end();) {
            const int32_t id = it->first;
            FireBlock &fb = it->second;
            Block &b = c.blocks[id];
            const Vector3i base = b.cell - c.origin;
            const Vector3i sz = archetypes[b.archetype].size;
            if (!b.alive || b.detached || b.removed) {
                // Burning, and carried off on a piece: where, so the fire can go
                // with it (BurningDebris).
                if (fb.burning && b.detached && !b.removed) {
                    loose.push_back(c.xform.xform(Vector3((base.x + sz.x * 0.5f) * cs.x,
                            (base.y + sz.y * 0.5f) * cs.y, (base.z + sz.z * 0.5f) * cs.z)));
                }
                it = fs->erase(it);
                continue;
            }
            if (fb.burning) {
                fb.age += dt;
                fb.fuel -= dt;
                if (fb.fuel <= 0.0f) {
                    b.alive = false;
                    conn_touch(chunk_id, id);
                    b.hp = 0;
                    killed.push_back(id);
                    it = fs->erase(it);
                    continue;
                }
                const Vector3 mid((base.x + sz.x * 0.5f) * cs.x, (base.y + sz.y * 0.5f) * cs.y,
                        (base.z + sz.z * 0.5f) * cs.z);
                points.push_back(c.xform.xform(mid));
                power.push_back(std::min(1.0f, 0.5f + fb.age * 0.5f)
                        * std::min(1.0f, 0.3f + fb.fuel / std::max(0.01f, 0.3f * fb.fuel0)));
                ++it;
                continue;
            }
            auto g = gain.find(id);
            const float in = g != gain.end() ? std::min(g->second, FIRE_GAIN_CAP) : 0.0f;
            fb.heat += dt * (FIRE_HEAT_K * fire_take(b.material) * in * damp - FIRE_COOL * fb.heat);
            fb.heat = std::min(fb.heat, FIRE_MAX_HEAT);
            if (!b.scorched && fb.heat >= FIRE_CHAR) {
                b.scorched = true;
                b.colour = (uint8_t)brick_material_darkest(b.material);
                charred.push_back(id);
                rebake = true;
            }
            if (fb.heat >= 1.0f && burning < max_burning) {
                int cells = 0;
                bool air = false;
                for (int x = 0; x < sz.x; ++x) {
                    for (int y = 0; y < sz.y; ++y) {
                        for (int z = 0; z < sz.z; ++z) {
                            const Vector3i l = base + Vector3i(x, y, z);
                            if (c.block_at(l) != id) {
                                continue;
                            }
                            cells += 1;
                            for (int d = 0; d < 6 && !air; ++d) {
                                air = fire_air(c, l + FIRE_DIRS[d], id);
                            }
                        }
                    }
                }
                const float secs = fire_burn_seconds(b.material, cells);
                if (air && secs > 0.0f) {
                    fb.burning = true;
                    fb.fuel = fb.fuel0 = secs;
                    fb.age = 0.0f;
                    caught += 1;
                    burning += 1;
                }
            }
            if (!fb.burning && fb.heat < 0.02f) {
                it = fs->erase(it);
                continue;
            }
            ++it;
        }
        if (rebake && (c.bake.valid || bake_pending(chunk_id))) {
            drop_chunk_bake(chunk_id);
        }
        out["active"] = !fs->empty();
    } else {
        out["active"] = false;
    }
    out["killed"] = killed;
    out["charred"] = charred;
    out["points"] = points;
    out["power"] = power;
    out["loose"] = loose;
    out["caught"] = caught;
    out["burning"] = (int)points.size();
    return out;
}

void BrickWorld::fire_clear(int chunk_id) {
    if (chunk_id >= 0 && chunk_id < (int)fire_state.size()) {
        fire_state[(size_t)chunk_id].clear();
    }
}

PackedFloat32Array BrickWorld::fire_get(int chunk_id, int block_id) const {
    PackedFloat32Array out;
    out.resize(4);
    out.fill(0.0f);
    if (chunk_id < 0 || chunk_id >= (int)fire_state.size()) {
        return out;
    }
    const auto &fs = fire_state[(size_t)chunk_id];
    const auto it = fs.find(block_id);
    if (it != fs.end()) {
        out.set(0, it->second.heat);
        out.set(1, it->second.burning ? 1.0f : 0.0f);
        out.set(2, it->second.fuel);
        out.set(3, it->second.age);
    }
    return out;
}

int BrickWorld::fire_burning(int chunk_id) const {
    if (chunk_id < 0 || chunk_id >= (int)fire_state.size()) {
        return 0;
    }
    int n = 0;
    for (const auto &kv : fire_state[(size_t)chunk_id]) {
        n += kv.second.burning ? 1 : 0;
    }
    return n;
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
            conn_touch(chunk_id, cand.bid);
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
        conn_touch(chunk_id, bid);
        loosened.push_back(bid);
    }
    loosened.sort();
    return loosened;
}


PackedInt32Array BrickWorld::sever_seams(int chunk_id, PackedVector3Array world_points,
        Vector3 world_normal, bool through) {
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
            conn_touch(chunk_id, (int32_t)bi);
            cut.push_back((int32_t)bi);
            continue;
        }
        // A block that runs THROUGH a seam -- a column a storey tall, in a
        // wall snapped along a row of windows -- would hold the two sides
        // together by itself. In a brick model it pulls off its studs at one
        // end and goes with the other side: here, off its foot. Not
        // furniture, which stands on a floor and holds nothing.
        if (!through || b.decorative) {
            continue;
        }
        const int32_t top_y = base_y + archetypes[b.archetype].size.y;
        for (const int32_t k : planes) {
            if (k > base_y && k < top_y) {
                b.bottom_broken = true;
                conn_touch(chunk_id, (int32_t)bi);
                cut.push_back((int32_t)bi);
                break;
            }
        }
    }
    return cut;
}

PackedInt32Array BrickWorld::seam_studs(int chunk_id, int from_k, int to_k) {
    PackedInt32Array out;
    if (!valid_chunk(chunk_id) || to_k < from_k) {
        return out;
    }
    const Chunk &c = chunks[chunk_id];
    const int layers = to_k - from_k + 1;
    out.resize(layers * 3);
    out.fill(0);
    int32_t *at = out.ptrw();
    const brick::JointCache &jc = joints_of(chunk_id);
    const size_t n = c.blocks.size();
    for (size_t i = 0; i < n; ++i) {
        const Block &b = c.blocks[i];
        // Furniture holds nothing together: it stands on a floor and nothing
        // stands on it.
        if (!b.alive || b.decorative) {
            continue;
        }
        const int bot = b.cell.y - c.origin.y;
        const int top = bot + archetypes[b.archetype].size.y;
        if (top <= from_k || bot > to_k) {
            continue;
        }
        // The studs at its foot: its joints to the blocks it stands on. The
        // cache leaves out a joint its upper block has let go (bottom_broken).
        int foot = 0;
        if (!b.support_broken) {
            for_each_joint(c, jc, (int32_t)i, [&](int32_t nb, int count) {
                const Block &o = c.blocks[nb];
                if (o.decorative || o.support_broken
                        || o.cell.y - c.origin.y + archetypes[o.archetype].size.y != bot) {
                    return;
                }
                foot += count;
            });
        }
        if (bot >= from_k) {
            at[(bot - from_k) * 3] += foot;
        }
        // And it runs through every boundary strictly inside it.
        for (int k = std::max(bot + 1, from_k); k < top && k <= to_k; ++k) {
            at[(k - from_k) * 3 + 1] += 1;
            at[(k - from_k) * 3 + 2] += foot;
        }
    }
    return out;
}

// --- detachment ------------------------------------------------------------

PackedInt32Array BrickWorld::rest_contacts(int piece_chunk, const Transform3D &piece_xform,
        int building_chunk) const {
    PackedInt32Array out;
    if (!valid_chunk(piece_chunk) || !valid_chunk(building_chunk)) {
        return out;
    }
    const Chunk &c = chunks[piece_chunk];
    const Chunk &bc = chunks[building_chunk];
    const Transform3D inv = bc.xform.affine_inverse();
    const Vector3 cs = cell_size();
    const Basis &bs = piece_xform.basis;
    // The same arithmetic the script did, in the same types, so a point on a
    // cell boundary lands in the same cell: Vector3 sums in real_t, scalars in
    // double (a GDScript float), the half-extent added in the script's order.
    const double ax = std::abs((double)bs.rows[1][0]);
    const double ay = std::abs((double)bs.rows[1][1]);
    const double az = std::abs((double)bs.rows[1][2]);
    std::vector<Vector3i> found;
    auto test = [&](const Vector3 &pos, const Vector3 &size) {
        const Vector3 centre = piece_xform.xform(pos);
        const double hy = ax * (double)size.x * 0.5 + ay * (double)size.y * 0.5
                + az * (double)size.z * 0.5;
        const Vector3 under = centre - Vector3(0, 1, 0) * (real_t)(hy + 0.05);
        const Vector3 local = inv.xform(under);
        const Vector3i rel((int)std::floor((double)local.x / (double)cs.x),
                (int)std::floor((double)local.y / (double)cs.y),
                (int)std::floor((double)local.z / (double)cs.z));
        if (!bc.in_bounds(rel) || !bc.solid_at(rel) || bc.occupancy[(size_t)bc.index_of(rel)] < 0) {
            return;
        }
        const Vector3i at = bc.origin + rel;
        if (std::find(found.begin(), found.end(), at) == found.end()) {
            found.push_back(at);
        }
    };
    for (size_t i = 0; i < c.blocks.size(); ++i) {
        const Block &b = c.blocks[i];
        if (b.removed || !b.alive) {
            continue;
        }
        const Archetype &a = archetypes[b.archetype];
        if (a.is_full_box()) {
            Vector3 centre, size;
            block_extent(c, b, centre, size);
            test(centre, size);
            continue;
        }
        const Vector3i base = b.cell - c.origin;
        for (int x = 0; x < a.size.x; ++x) {
            for (int y = 0; y < a.size.y; ++y) {
                for (int z = 0; z < a.size.z; ++z) {
                    if (a.solid_at(x, y, z)) {
                        test(Vector3((base.x + x + 0.5f) * cs.x, (base.y + y + 0.5f) * cs.y,
                                (base.z + z + 0.5f) * cs.z), cs);
                    }
                }
            }
        }
    }
    out.resize((int64_t)found.size() * 3);
    for (size_t k = 0; k < found.size(); ++k) {
        out.set((int64_t)k * 3, found[k].x);
        out.set((int64_t)k * 3 + 1, found[k].y);
        out.set((int64_t)k * 3 + 2, found[k].z);
    }
    return out;
}

bool BrickWorld::any_block_centre_in(int chunk_id, const AABB &box,
        const PackedInt32Array &exclude) const {
    if (!valid_chunk(chunk_id)) {
        return false;
    }
    const Chunk &c = chunks[chunk_id];
    std::vector<uint8_t> skip(c.blocks.size(), 0);
    for (int64_t k = 0; k < exclude.size(); ++k) {
        const int32_t id = exclude[k];
        if (id >= 0 && id < (int32_t)c.blocks.size()) {
            skip[(size_t)id] = 1;
        }
    }
    const Vector3 cs = cell_size();
    for (size_t i = 0; i < c.blocks.size(); ++i) {
        const Block &b = c.blocks[i];
        if (b.removed || !b.alive || skip[i]) {
            continue;
        }
        const Archetype &a = archetypes[b.archetype];
        if (a.is_full_box()) {
            Vector3 centre, size;
            block_extent(c, b, centre, size);
            if (box.has_point(centre)) {
                return true;
            }
            continue;
        }
        const Vector3i base = b.cell - c.origin;
        for (int x = 0; x < a.size.x; ++x) {
            for (int y = 0; y < a.size.y; ++y) {
                for (int z = 0; z < a.size.z; ++z) {
                    if (a.solid_at(x, y, z) && box.has_point(Vector3((base.x + x + 0.5f) * cs.x,
                            (base.y + y + 0.5f) * cs.y, (base.z + z + 0.5f) * cs.z))) {
                        return true;
                    }
                }
            }
        }
    }
    return false;
}

PackedByteArray BrickWorld::block_centre_levels(int chunk_id, const AABB &box,
        float level_height, const PackedInt32Array &exclude) const {
    PackedByteArray out;
    if (!valid_chunk(chunk_id) || level_height <= 0.0f) {
        return out;
    }
    const int levels = std::max(1, (int)std::ceil(box.size.y / level_height));
    out.resize(levels);
    out.fill(0);
    const Chunk &c = chunks[chunk_id];
    std::vector<uint8_t> skip(c.blocks.size(), 0);
    for (int64_t k = 0; k < exclude.size(); ++k) {
        const int32_t id = exclude[k];
        if (id >= 0 && id < (int32_t)c.blocks.size()) {
            skip[(size_t)id] = 1;
        }
    }
    auto mark = [&](const Vector3 &p) {
        if (!box.has_point(p)) {
            return;
        }
        const int l = std::min(levels - 1, std::max(0,
                (int)std::floor((p.y - box.position.y) / level_height)));
        out.set(l, 1);
    };
    const Vector3 cs = cell_size();
    for (size_t i = 0; i < c.blocks.size(); ++i) {
        const Block &b = c.blocks[i];
        if (b.removed || !b.alive || skip[i]) {
            continue;
        }
        const Archetype &a = archetypes[b.archetype];
        if (a.is_full_box()) {
            Vector3 centre, size;
            block_extent(c, b, centre, size);
            mark(centre);
            continue;
        }
        const Vector3i base = b.cell - c.origin;
        for (int x = 0; x < a.size.x; ++x) {
            for (int y = 0; y < a.size.y; ++y) {
                for (int z = 0; z < a.size.z; ++z) {
                    if (a.solid_at(x, y, z)) {
                        mark(Vector3((base.x + x + 0.5f) * cs.x, (base.y + y + 0.5f) * cs.y,
                                (base.z + z + 0.5f) * cs.z));
                    }
                }
            }
        }
    }
    return out;
}

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
            conn_touch(chunk_id, (int32_t)i);
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
    Vector3 com;
    float total_mass = 0.0f;
    body_mass(chunk_id, com, total_mass);

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

void BrickWorld::body_mass(int chunk_id, Vector3 &com, float &mass) const {
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
    com = total_mass > 0.0f ? weighted / total_mass : Vector3();
    mass = total_mass;
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
                conn_touch(chunk_id, (int32_t)bi);
                loosened.push_back((int32_t)bi);
                break;
            }
        }
    }
    return loosened;
}

PackedInt32Array BrickWorld::separate_plane(int chunk_id, Vector3 world_point,
        Vector3 world_normal, float thickness, Rect2 within) {
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
        if (within.has_area() && !within.has_point(Vector2(centre.x, centre.z))) {
            continue;
        }
        // Loose, not gone.
        b.support_broken = true;
        conn_touch(chunk_id, (int32_t)bi);
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
    settle_coarse_job(chunk_id);
    drop_chamfer(chunk_id, -1, true);
    chunks[chunk_id] = Chunk();
    chunk_live[chunk_id] = 0;
    fire_clear(chunk_id);
    joint_cache[chunk_id] = brick::JointCache();
    conn_watch[(size_t)chunk_id] = ConnWatch();
    anchor_levels[(size_t)chunk_id].clear();
}

// --- islands ---------------------------------------------------------------

thread_local int BrickWorld::scratch_slot = 0;

Array BrickWorld::get_components(int chunk_id) {
    Array out = components_all(chunk_id);
    if (valid_chunk(chunk_id)) {
        // In one piece, or about to be cut until it is (mark_chunk_whole).
        ConnWatch &w = conn_watch[(size_t)chunk_id];
        w.whole = out.size() <= 1;
        w.touched.clear();
    }
    return out;
}

Array BrickWorld::components_all(int chunk_id) {
    SolveScratch &scratch = solve_scratch();
    std::vector<uint8_t> &scratch_mark = scratch.mark;
    std::vector<int32_t> &scratch_queue = scratch.queue;
    Array out;
    if (!valid_chunk(chunk_id)) {
        return out;
    }
    const brick::JointCache &jc = joints_of(chunk_id);
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
            for_each_joint(c, jc, bid, [&](int32_t nb, int) {
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

// A block's runs as the cache holds them, with nothing applied: every block
// its faces meet through a stud, whatever has died or been cut since. Where a
// change can have parted something, these are what it parted.
template <typename F>
static inline void for_each_run_raw(const brick::JointCache &jc, int32_t bid, F &&fn) {
    const brick::JointRun *r;
    const brick::JointRun *end;
    if (!jc.over_at.empty() && jc.over_at[bid] >= 0) {
        r = jc.over_runs.data() + jc.over_at[bid];
        end = r + jc.over_n[bid];
    } else {
        r = jc.runs.data() + jc.at[bid];
        end = jc.runs.data() + jc.at[bid + 1];
    }
    for (; r != end; ++r) {
        fn(r->nb);
    }
}

PackedInt32Array BrickWorld::cut_spans(int chunk_id, float reach_studs, bool apply) {
    if (!valid_chunk(chunk_id) || chunk_down[chunk_id] != Vector3i(0, -1, 0)) {
        return PackedInt32Array();
    }
    return spans_from(chunk_id, reach_studs, nullptr, apply);
}

PackedInt32Array BrickWorld::cut_spans_resting(int piece_chunk, const Transform3D &piece_xform,
        const PackedInt32Array &building_chunks, float ground_y, float reach_studs, bool apply) {
    if (!valid_chunk(piece_chunk)) {
        return PackedInt32Array();
    }
    // Lying level: its own up near the world's.
    const Vector3 up = piece_xform.basis.get_column(1).normalized();
    if (up.y < 0.9f) {
        return PackedInt32Array();
    }
    const Chunk &c = chunks[piece_chunk];
    std::vector<uint8_t> seeds(c.blocks.size(), 0);
    const Basis &bs = piece_xform.basis;
    const double ax = std::abs((double)bs.rows[1][0]);
    const double ay = std::abs((double)bs.rows[1][1]);
    const double az = std::abs((double)bs.rows[1][2]);
    const Vector3 cs = cell_size();
    bool any = false;
    for (size_t i = 0; i < c.blocks.size(); ++i) {
        const Block &b = c.blocks[i];
        if (b.removed || !b.alive || b.support_broken) {
            continue;
        }
        // The point just under it, as rest_contacts finds it.
        Vector3 centre, size;
        block_extent(c, b, centre, size);
        const Vector3 at = piece_xform.xform(centre);
        const double hy = ax * (double)size.x * 0.5 + ay * (double)size.y * 0.5 + az * (double)size.z * 0.5;
        const Vector3 under = at - Vector3(0, 1, 0) * (real_t)(hy + 0.05);
        bool rests = under.y <= ground_y;
        for (int64_t k = 0; k < building_chunks.size() && !rests; ++k) {
            const int bcid = building_chunks[k];
            if (!valid_chunk(bcid)) {
                continue;
            }
            const Chunk &bc = chunks[bcid];
            const Vector3 local = bc.xform.affine_inverse().xform(under);
            const Vector3i rel((int)std::floor((double)local.x / (double)cs.x),
                    (int)std::floor((double)local.y / (double)cs.y),
                    (int)std::floor((double)local.z / (double)cs.z));
            rests = bc.in_bounds(rel) && bc.solid_at(rel);
        }
        if (rests) {
            seeds[i] = 1;
            any = true;
        }
    }
    if (!any) {
        return PackedInt32Array();
    }
    return spans_from(piece_chunk, reach_studs, &seeds, apply);
}

PackedInt32Array BrickWorld::spans_from(int chunk_id, float reach_studs, const std::vector<uint8_t> *seeds,
        bool apply) {
    PackedInt32Array out;
    if (!valid_chunk(chunk_id) || reach_studs <= 0.0f) {
        return out;
    }
    const brick::JointCache &jc = joints_of(chunk_id);
    Chunk &c = chunks[chunk_id];
    const int32_t n = (int32_t)c.blocks.size();
    auto usable = [&](int32_t i) {
        const Block &b = c.blocks[(size_t)i];
        return b.alive && !b.removed && !b.support_broken;
    };

    // 1. Held from below, lowest first: a block's neighbours below it start
    // lower than it does.
    std::vector<int32_t> order;
    order.reserve((size_t)n);
    for (int32_t i = 0; i < n; ++i) {
        if (usable(i)) {
            order.push_back(i);
        }
    }
    std::sort(order.begin(), order.end(), [&](int32_t a, int32_t b) {
        const int ya = c.blocks[(size_t)a].cell.y;
        const int yb = c.blocks[(size_t)b].cell.y;
        return ya != yb ? ya < yb : a < b;
    });
    // Held by stud COLUMN: a column of a block's footprint is held when the
    // block under it in that column is held in that column and joined to it,
    // or the block stands on the foundation. A block is held when any column
    // of it is. Not by block: a brick resting half on a held one would then be
    // held, and in a wall laid in a bond every brick does -- "held" crept half
    // a brick out over a gap a course, 36 studs over a three-storey building
    // (span_probe, 2026-10-16). Not by the block under its middle either: a
    // floor panel lies on walls at its edges.
    std::vector<int64_t> at((size_t)n + 1, 0);
    for (int32_t i = 0; i < n; ++i) {
        const Vector3i sz = archetypes[c.blocks[(size_t)i].archetype].size;
        at[(size_t)i + 1] = at[(size_t)i] + (int64_t)sz.x * sz.z;
    }
    std::vector<uint8_t> col((size_t)at[(size_t)n], 0);
    std::vector<uint8_t> held((size_t)n, 0);
    auto joined_below = [&](int32_t bid, int32_t nb) {
        const brick::JointRun *r;
        const brick::JointRun *end;
        if (!jc.over_at.empty() && jc.over_at[(size_t)bid] >= 0) {
            r = jc.over_runs.data() + jc.over_at[(size_t)bid];
            end = r + jc.over_n[(size_t)bid];
        } else {
            r = jc.runs.data() + jc.at[(size_t)bid];
            end = jc.runs.data() + jc.at[(size_t)bid + 1];
        }
        for (; r != end; ++r) {
            if (r->up == 0 && r->nb == nb) {
                return true;
            }
        }
        return false;
    };
    for (const int32_t bid : order) {
        const Block &b = c.blocks[(size_t)bid];
        const Vector3i sz = archetypes[b.archetype].size;
        const bool ground = seeds != nullptr ? (*seeds)[(size_t)bid] != 0
                : grounded_at(chunk_id, b.cell.y);
        if (!ground && b.bottom_broken) {
            continue;
        }
        int32_t last = -1;
        bool last_joined = false;
        for (int dx = 0; dx < sz.x; ++dx) {
            for (int dz = 0; dz < sz.z; ++dz) {
                bool ok = ground;
                if (!ok) {
                    const Vector3i cell(b.cell.x + dx, b.cell.y - 1, b.cell.z + dz);
                    const int32_t u = c.block_at(cell - c.origin);
                    if (u >= 0 && u != bid && usable(u) && held[(size_t)u]) {
                        if (u != last) {
                            last = u;
                            last_joined = joined_below(bid, u);
                        }
                        if (last_joined) {
                            const Block &ub = c.blocks[(size_t)u];
                            const Vector3i usz = archetypes[ub.archetype].size;
                            const int ux = cell.x - ub.cell.x;
                            const int uz = cell.z - ub.cell.z;
                            ok = ux >= 0 && uz >= 0 && ux < usz.x && uz < usz.z
                                    && col[(size_t)(at[(size_t)u] + (int64_t)ux * usz.z + uz)];
                        }
                    }
                }
                if (ok) {
                    col[(size_t)(at[(size_t)bid] + (int64_t)dx * sz.z + dz)] = 1;
                    held[(size_t)bid] = 1;
                }
            }
        }
    }

    // 2. Reach: nearest first from every block held from below, through the
    // joints, a step costing how far apart the two blocks' middles are on plan.
    auto middle = [&](int32_t i) {
        const Block &b = c.blocks[(size_t)i];
        const Vector3i sz = archetypes[b.archetype].size;
        return Vector2(b.cell.x + sz.x * 0.5f, b.cell.z + sz.z * 0.5f);
    };
    // A held block's reach is nothing; the walk starts from the held blocks
    // next to unheld ones and goes on through unheld ones only -- in a
    // standing building a few hundred blocks, not all of it.
    std::vector<float> reach((size_t)n, std::numeric_limits<float>::infinity());
    using Item = std::pair<float, int32_t>;
    std::priority_queue<Item, std::vector<Item>, std::greater<Item>> q;
    for (const int32_t bid : order) {
        if (!held[(size_t)bid]) {
            continue;
        }
        reach[(size_t)bid] = 0.0f;
        bool edge = false;
        for_each_joint(c, jc, bid, [&](int32_t nb, int) {
            if (!edge && usable(nb) && !held[(size_t)nb]) {
                edge = true;
            }
        });
        if (edge) {
            q.push({ 0.0f, bid });
        }
    }
    // Nothing reaches further than the toughest material lets it.
    const float most = reach_studs * 4.0f;
    while (!q.empty()) {
        const Item top = q.top();
        q.pop();
        const int32_t u = top.second;
        if (top.first > reach[(size_t)u] || top.first > most) {
            continue;
        }
        const Vector2 mu = middle(u);
        for_each_joint(c, jc, u, [&](int32_t nb, int) {
            if (!usable(nb) || held[(size_t)nb]) {
                return;
            }
            const float d = top.first + (middle(nb) - mu).length();
            if (d < reach[(size_t)nb]) {
                reach[(size_t)nb] = d;
                q.push({ d, nb });
            }
        });
    }

    // 3. Past its reach: nothing near enough under it. (Out of reach of every
    // block held from below is not this: that is loose, and the solve's.)
    std::vector<uint8_t> past((size_t)n, 0);
    bool any = false;
    for (const int32_t bid : order) {
        const float r = reach[(size_t)bid];
        if (!held[(size_t)bid] && r < std::numeric_limits<float>::infinity()
                && r > reach_studs * brick_material_toughness(c.blocks[(size_t)bid].material)) {
            past[(size_t)bid] = 1;
            any = true;
        }
    }
    if (!any) {
        return out;
    }
    // 4. The rim: what has nothing, where it is joined to what has.
    for (const int32_t bid : order) {
        if (!past[(size_t)bid]) {
            continue;
        }
        bool rim = false;
        for_each_joint(c, jc, bid, [&](int32_t nb, int) {
            if (!rim && usable(nb) && !past[(size_t)nb]) {
                rim = true;
            }
        });
        if (rim) {
            out.push_back(bid);
        }
    }
    out.sort();
    if (apply) {
        for (int64_t i = 0; i < out.size(); ++i) {
            c.blocks[(size_t)out[i]].support_broken = true;
            conn_touch(chunk_id, out[i]);
        }
    }
    return out;
}

Array BrickWorld::get_components_near(int chunk_id) {
    if (!valid_chunk(chunk_id)) {
        return Array();
    }
    near_stats[0]++;
    ConnWatch &w = conn_watch[(size_t)chunk_id];
    if (!w.whole) {
        near_stats[4]++;
        return get_components(chunk_id);
    }
    Array out;
    if (w.touched.empty()) {
        near_stats[1]++;
        out.push_back(PackedInt32Array());
    } else {
        near_stats[2]++;
        const brick::JointCache &jc = joints_of(chunk_id);
        const Chunk &c = chunks[chunk_id];
        const int32_t n = (int32_t)c.blocks.size();

        // Which walk each block was reached by, stamped so that a walk of a
        // few hundred blocks does not clear an array of twenty thousand.
        thread_local std::vector<uint32_t> stamp;
        thread_local std::vector<int32_t> walk_of;
        thread_local uint32_t gen = 0;
        if (stamp.size() < (size_t)n) {
            stamp.resize((size_t)n, 0);
            walk_of.resize((size_t)n, -1);
        }
        if (++gen == 0) {
            std::fill(stamp.begin(), stamp.end(), 0);
            gen = 1;
        }
        auto reached = [&](int32_t b) { return stamp[(size_t)b] == gen; };

        // One walk from each live block a change touched, and from each live
        // block its faces met -- all of them in ONE queue, breadth first, so a
        // block costs what it costs a whole walk. `open` is how many blocks of
        // a union of walks are queued and not yet looked at.
        thread_local std::vector<int32_t> queue;
        queue.clear();
        auto seed = [&](int32_t b) {
            if (b < 0 || b >= n || reached(b)) {
                return;
            }
            const Block &bb = c.blocks[(size_t)b];
            if (!bb.alive || bb.removed) {
                return;
            }
            stamp[(size_t)b] = gen;
            walk_of[(size_t)b] = (int32_t)queue.size();
            queue.push_back(b);
        };
        for (const int32_t t : w.touched) {
            if (t < 0 || t >= n) {
                continue;
            }
            seed(t);
            if (!c.blocks[(size_t)t].removed) {
                for_each_run_raw(jc, t, [&](int32_t nb) { seed(nb); });
            }
        }
        w.touched.clear();

        // Walks that meet are one: a union of them. `left` is how many unions
        // still have blocks queued.
        const int32_t m = (int32_t)queue.size();
        std::vector<int32_t> parent((size_t)m);
        std::vector<int64_t> open((size_t)m, 1), size((size_t)m, 1);
        for (int32_t i = 0; i < m; ++i) {
            parent[(size_t)i] = i;
        }
        auto find = [&](int32_t a) {
            while (parent[(size_t)a] != a) {
                parent[(size_t)a] = parent[(size_t)parent[(size_t)a]];
                a = parent[(size_t)a];
            }
            return a;
        };
        int32_t left = m;
        int64_t alive_n = -1;
        auto count_alive = [&]() {
            if (alive_n < 0) {
                alive_n = 0;
                for (const Block &b : c.blocks) {
                    alive_n += b.alive ? 1 : 0;
                }
            }
        };
        bool all_of_it = false;
        size_t head = 0;
        for (;;) {
            if (left <= 1 && !all_of_it) {
                if (left == 0) {
                    break;
                }
                // One still going: the rest -- unless a group that came off is
                // bigger than it, when the rest is walked too, to be cut off
                // in its turn (the biggest stays the piece).
                count_alive();
                int64_t off = 0, biggest = 0;
                for (int32_t i = 0; i < m; ++i) {
                    if (find(i) == i && open[(size_t)i] == 0) {
                        off += size[(size_t)i];
                        biggest = std::max(biggest, size[(size_t)i]);
                    }
                }
                if (biggest <= alive_n - off) {
                    break;
                }
                all_of_it = true;
            }
            if (head >= queue.size()) {
                break;
            }
            const int32_t v = queue[head++];
            const int32_t L = walk_of[(size_t)v];
            // A sheared block is joined to nothing (get_components).
            if (!c.blocks[(size_t)v].support_broken) {
                for_each_joint(c, jc, v, [&](int32_t nb, int) {
                    if (c.blocks[(size_t)nb].support_broken) {
                        return;
                    }
                    if (!reached(nb)) {
                        stamp[(size_t)nb] = gen;
                        walk_of[(size_t)nb] = L;
                        queue.push_back(nb);
                        const int32_t R = find(L);
                        open[(size_t)R]++;
                        size[(size_t)R]++;
                        return;
                    }
                    int32_t A = find(L);
                    int32_t B = find(walk_of[(size_t)nb]);
                    if (A == B) {
                        return;
                    }
                    if (size[(size_t)A] < size[(size_t)B]) {
                        std::swap(A, B);
                    }
                    if (open[(size_t)A] > 0 && open[(size_t)B] > 0) {
                        --left;
                    }
                    parent[(size_t)B] = A;
                    open[(size_t)A] += open[(size_t)B];
                    size[(size_t)A] += size[(size_t)B];
                });
            }
            const int32_t R = find(L);
            if (--open[(size_t)R] == 0) {
                --left;
            }
        }
        near_stats[3] += (int64_t)head;

        // The unions that ran out are the groups; every block reached is in the
        // queue, with the walk that reached it.
        std::vector<int32_t> slot((size_t)m, -1);
        std::vector<PackedInt32Array> groups;
        bool going = false;
        for (int32_t i = 0; i < m; ++i) {
            if (find(i) == i) {
                if (open[(size_t)i] == 0) {
                    slot[(size_t)i] = (int32_t)groups.size();
                    groups.push_back(PackedInt32Array());
                } else {
                    going = true;
                }
            }
        }
        for (const int32_t b : queue) {
            const int32_t at = slot[(size_t)find(walk_of[(size_t)b])];
            if (at >= 0) {
                groups[(size_t)at].push_back(b);
            }
        }
        for (PackedInt32Array &g : groups) {
            g.sort();
        }
        std::stable_sort(groups.begin(), groups.end(),
                [](const PackedInt32Array &a, const PackedInt32Array &b) {
                    return a.size() > b.size();
                });
        if (going || m == 0) {
            // m == 0: what changed had no live block on it or beside it, so
            // nothing live can have been parted by it.
            out.push_back(PackedInt32Array());
            for (const PackedInt32Array &g : groups) {
                out.push_back(g);
            }
        } else {
            // Everything walked. It is all of the chunk only if the chunk was
            // in one piece when it was said to be: if a live block was reached
            // by no walk, something changed it without saying so -- walked
            // whole, and counted.
            count_alive();
            if ((int64_t)queue.size() != alive_n) {
                near_stats[6]++;
                return get_components(chunk_id);
            }
            for (const PackedInt32Array &g : groups) {
                out.push_back(g);
            }
        }
        // Still one piece, or about to be cut until it is (mark_chunk_whole).
        w.whole = out.size() <= 1;
    }

    if (components_check) {
        // The same question, walked whole, without touching the watch.
        const Array all = components_all(chunk_id);
        bool same = all.size() == out.size();
        if (same && out.size() > 1) {
            const Chunk &c = chunks[chunk_id];
            std::vector<int32_t> comp(c.blocks.size(), -1);
            for (int64_t k = 0; k < all.size(); ++k) {
                const PackedInt32Array g = all[k];
                for (int64_t i = 0; i < g.size(); ++i) {
                    comp[(size_t)g[i]] = (int32_t)k;
                }
            }
            const int64_t biggest = ((PackedInt32Array)all[0]).size();
            for (int64_t k = 1; k < out.size() && same; ++k) {
                const PackedInt32Array g = out[k];
                const int32_t at = g.is_empty() ? -1 : comp[(size_t)g[0]];
                same = at >= 0 && ((PackedInt32Array)all[at]).size() == g.size()
                        && (at > 0 || g.size() == biggest);
                for (int64_t i = 1; i < g.size() && same; ++i) {
                    same = comp[(size_t)g[i]] == at;
                }
            }
        }
        if (!same) {
            near_stats[5]++;
            UtilityFunctions::push_warning("BrickWorld: get_components_near on chunk ", chunk_id,
                    " found ", out.size(), " group(s), walked whole ", all.size());
        }
    }
    return out;
}

void BrickWorld::mark_chunk_whole(int chunk_id) {
    if (!valid_chunk(chunk_id)) {
        return;
    }
    ConnWatch &w = conn_watch[(size_t)chunk_id];
    w.whole = true;
    w.touched.clear();
}

void BrickWorld::set_components_check(bool on) {
    components_check = on;
}

PackedInt64Array BrickWorld::get_components_near_stats() const {
    PackedInt64Array out;
    for (int i = 0; i < 7; ++i) {
        out.push_back(near_stats[i]);
    }
    return out;
}

PackedInt32Array BrickWorld::crack_studs(int chunk_id, int axis, int from_k, int to_k) {
    PackedInt32Array out;
    if (!valid_chunk(chunk_id) || to_k < from_k || (axis != 0 && axis != 2)) {
        return out;
    }
    const brick::JointCache &jc = joints_of(chunk_id);
    const Chunk &c = chunks[chunk_id];
    const int layers = to_k - from_k + 1;
    // Added over a range of boundaries at once, summed at the end.
    std::vector<int64_t> diff((size_t)layers + 1, 0);
    // Twice a block's middle along the axis, in cells: whole numbers.
    auto mid2 = [&](const Block &b) -> int {
        const int at = (axis == 0 ? b.cell.x - c.origin.x : b.cell.z - c.origin.z);
        const Vector3i sz = archetypes[b.archetype].size;
        return 2 * at + (axis == 0 ? sz.x : sz.z);
    };
    // ceil(v / 2), for either sign.
    auto ceil_half = [](int v) -> int { return v >= 0 ? (v + 1) / 2 : -((-v) / 2); };
    const size_t n = c.blocks.size();
    for (size_t i = 0; i < n; ++i) {
        const Block &b = c.blocks[i];
        if (!b.alive || b.support_broken) {
            continue;
        }
        const int mi = mid2(b);
        for_each_joint(c, jc, (int32_t)i, [&](int32_t nb, int count) {
            // Each pair once.
            if (nb <= (int32_t)i) {
                return;
            }
            const Block &o = c.blocks[nb];
            if (!o.alive || o.support_broken) {
                return;
            }
            const int mo = mid2(o);
            const int lo2 = std::min(mi, mo);
            const int hi2 = std::max(mi, mo);
            // A brick is on the near side of plane k when 2 * middle <= 2k, so
            // the two are apart for lo2 <= 2k < hi2.
            const int k0 = std::max(ceil_half(lo2), from_k);
            const int k1 = std::min(ceil_half(hi2) - 1, to_k);
            if (k0 > k1) {
                return;
            }
            diff[(size_t)(k0 - from_k)] += count;
            diff[(size_t)(k1 - from_k + 1)] -= count;
        });
    }
    out.resize(layers);
    int64_t run = 0;
    for (int k = 0; k < layers; ++k) {
        run += diff[(size_t)k];
        out.set(k, (int32_t)run);
    }
    return out;
}

Array BrickWorld::crack_components(int chunk_id, const PackedInt32Array &planes_x,
        const PackedInt32Array &planes_z) {
    Array out;
    if (!valid_chunk(chunk_id)) {
        return out;
    }
    // Cut along cracks next, whole or not: not known to be in one piece.
    conn_forget(chunk_id);
    const brick::JointCache &jc = joints_of(chunk_id);
    const Chunk &c = chunks[chunk_id];
    const size_t n = c.blocks.size();
    std::vector<int> px(planes_x.ptr(), planes_x.ptr() + planes_x.size());
    std::vector<int> pz(planes_z.ptr(), planes_z.ptr() + planes_z.size());
    // Which side of every plane each brick's middle is on, as one number.
    std::vector<int32_t> side(n, 0);
    for (size_t i = 0; i < n; ++i) {
        const Block &b = c.blocks[i];
        const Vector3i sz = archetypes[b.archetype].size;
        const int mx = 2 * (b.cell.x - c.origin.x) + sz.x;
        const int mz = 2 * (b.cell.z - c.origin.z) + sz.z;
        int sx = 0;
        for (const int k : px) {
            sx += (mx > 2 * k) ? 1 : 0;
        }
        int szi = 0;
        for (const int k : pz) {
            szi += (mz > 2 * k) ? 1 : 0;
        }
        side[i] = sx * 64 + szi;
    }
    std::vector<uint8_t> mark(n, 0);
    std::vector<int32_t> queue;
    std::vector<PackedInt32Array> groups;
    for (size_t i = 0; i < n; ++i) {
        if (!c.blocks[i].alive || mark[i]) {
            continue;
        }
        PackedInt32Array group;
        queue.clear();
        queue.push_back((int32_t)i);
        mark[i] = 1;
        for (size_t head = 0; head < queue.size(); ++head) {
            const int32_t bid = queue[head];
            group.push_back(bid);
            for_each_joint(c, jc, bid, [&](int32_t nb, int) {
                if (mark[nb]) {
                    return;
                }
                // As get_components: a sheared block is joined to nothing.
                if (c.blocks[bid].support_broken || c.blocks[nb].support_broken) {
                    return;
                }
                // Across a crack: let go.
                if (side[bid] != side[nb]) {
                    return;
                }
                mark[nb] = 1;
                queue.push_back(nb);
            });
        }
        group.sort();
        groups.push_back(group);
    }
    // A handful the crack cut off from its own side but not from the brick
    // it is clicked to across the crack stays with that brick: the crack
    // lets go of one side of a brick's joints, and a plate held only by the
    // brick across it goes with that brick, not off on its own. Merged in,
    // smallest first, and only into a group of more than a handful: a side
    // that is nothing but a handful is still a side, and parts.
    constexpr int ORPHAN_MAX = 8;
    std::vector<int32_t> comp(n, -1);
    for (size_t g = 0; g < groups.size(); ++g) {
        for (int k = 0; k < groups[g].size(); ++k) {
            comp[groups[g][k]] = (int32_t)g;
        }
    }
    std::vector<int32_t> owner(groups.size());
    for (size_t g = 0; g < groups.size(); ++g) {
        owner[g] = (int32_t)g;
    }
    auto find = [&](int32_t g) {
        while (owner[g] != g) {
            g = owner[g] = owner[owner[g]];
        }
        return g;
    };
    std::vector<size_t> order(groups.size());
    for (size_t g = 0; g < groups.size(); ++g) {
        order[g] = g;
    }
    std::stable_sort(order.begin(), order.end(),
            [&](size_t a, size_t b) { return groups[a].size() < groups[b].size(); });
    std::vector<int64_t> size_of(groups.size());
    for (size_t g = 0; g < groups.size(); ++g) {
        size_of[g] = groups[g].size();
    }
    for (const size_t g : order) {
        if (groups[g].size() > ORPHAN_MAX || find((int32_t)g) != (int32_t)g) {
            continue;
        }
        // The group across the crack it holds most studs of.
        std::vector<std::pair<int32_t, int>> held;   // group -> studs into it
        for (int k = 0; k < groups[g].size(); ++k) {
            const int32_t bid = groups[g][k];
            if (c.blocks[bid].support_broken) {
                continue;
            }
            for_each_joint(c, jc, bid, [&](int32_t nb, int count) {
                if (c.blocks[nb].support_broken || comp[nb] < 0) {
                    return;
                }
                const int32_t o = find(comp[nb]);
                if (o == (int32_t)g) {
                    return;
                }
                for (auto &h : held) {
                    if (h.first == o) {
                        h.second += count;
                        return;
                    }
                }
                held.push_back({o, count});
            });
        }
        int32_t to = -1;
        int most = 0;
        for (const auto &kv : held) {
            if (size_of[kv.first] <= ORPHAN_MAX) {
                continue;
            }
            if (kv.second > most || (kv.second == most && kv.first < to)) {
                most = kv.second;
                to = kv.first;
            }
        }
        if (to >= 0) {
            owner[g] = to;
            size_of[to] += size_of[g];
        }
    }
    std::vector<PackedInt32Array> merged;
    std::vector<int32_t> slot(groups.size(), -1);
    for (size_t g = 0; g < groups.size(); ++g) {
        const int32_t r = find((int32_t)g);
        if (slot[r] < 0) {
            slot[r] = (int32_t)merged.size();
            merged.push_back(PackedInt32Array());
        }
        merged[slot[r]].append_array(groups[g]);
    }
    for (PackedInt32Array &m : merged) {
        m.sort();
    }
    std::stable_sort(merged.begin(), merged.end(),
            [](const PackedInt32Array &a, const PackedInt32Array &b) {
                return a.size() > b.size();
            });
    for (const PackedInt32Array &g : merged) {
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
        const Block &src_block = chunks[chunk_id].blocks[bid];
        // Everything a block IS goes with it, not only its shape. Laying it
        // fresh used to reset three things, each a bug of its own: furniture
        // came out as structure (bearing load, counted by every solve), a joint
        // a landing had severed was whole again (so a sheared clump healed the
        // moment it became a piece), and a damaged brick was new. Found by the
        // city's log-replay check, Docs/AIPlan.md P0.
        //
        // And straight into the new chunk, without place_block's questions: it
        // is empty and has no bake, and cells that were one block's in the
        // source are nobody else's in a copy of the same layout. place_block
        // checked every cell twice and looked for a bake in flight once a
        // block -- 4.2 ms for a 7,000-brick piece cut out of another piece.
        Chunk &isl = chunks[island_id];
        const Archetype &a = archetypes[src_block.archetype];
        const int32_t nid = (int32_t)isl.blocks.size();
        Block nb;
        nb.cell = src_block.cell;
        nb.archetype = src_block.archetype;
        nb.colour = src_block.colour;
        nb.decorative = src_block.decorative;
        nb.support_broken = src_block.support_broken;
        nb.bottom_broken = src_block.bottom_broken;
        nb.strained = src_block.strained;
        nb.held = src_block.held;
        nb.hp = src_block.hp;
        nb.material = src_block.material;   // a steel beam falls as steel
        nb.scorched = src_block.scorched;
        isl.blocks.push_back(nb);
        const Vector3i base = nb.cell - isl.origin;
        for (int x = 0; x < a.size.x; ++x) {
            for (int y = 0; y < a.size.y; ++y) {
                for (int z = 0; z < a.size.z; ++z) {
                    if (a.solid_at(x, y, z)) {
                        isl.occupancy.set(isl.index_of(Vector3i(base.x + x, base.y + y, base.z + z)),
                                nid);
                    }
                }
            }
        }
        chunks[chunk_id].blocks[bid].alive = false;
        conn_touch(chunk_id, bid);
        chunks[chunk_id].blocks[bid].detached = true;
        taken.push_back(bid);
    }
    joint_cache[island_id].valid = false;
    chunks[island_id].bake.valid = false;

    // The mass and where its centre is -- NOT get_body_boxes, which also builds
    // a Dictionary for every box and was thrown away here. A shaped part is a
    // box per occupied CELL, so a staircase coming away whole (363 steps, a
    // 10 x 726 x 10 grid) was 37 ms of dictionaries in one split.
    Vector3 com;
    float mass = 0.0f;
    body_mass(island_id, com, mass);
    out["chunk"] = island_id;
    out["local_com"] = com;
    out["com"] = chunks[island_id].xform.xform(com);
    out["mass"] = mass;
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
    return FILAMENT_PALETTE_SIZE;
}

int BrickWorld::get_material_count() {
    return BRICK_MATERIAL_COUNT;
}

String BrickWorld::get_material_name(int material) {
    return (material >= 0 && material < BRICK_MATERIAL_COUNT) ? String(BRICK_MATERIALS[material].name) : String();
}

bool BrickWorld::is_filament_material(int material) {
    return material >= 0 && material < BRICK_MATERIAL_COUNT && BRICK_MATERIALS[material].variants == nullptr;
}

float BrickWorld::get_material_toughness(int material) {
    return brick_material_toughness(material);
}

bool BrickWorld::is_material_translucent(int material) {
    return brick_material_translucent(material);
}

int BrickWorld::get_block_hp(int chunk_id, int block_id) const {
    if (!valid_chunk(chunk_id)) {
        return 0;
    }
    const Chunk &c = chunks[chunk_id];
    return (block_id >= 0 && block_id < (int)c.blocks.size()) ? (int)c.blocks[block_id].hp : 0;
}

int BrickWorld::get_material_colour_count(int material) {
    return brick_material_colour_count(material);
}

Color BrickWorld::get_material_colour(int material, int colour) {
    return block_rgba(material, colour);
}

String BrickWorld::get_material_colour_name(int material, int colour) {
    return String(brick_material_colour_entry(material, colour).name);
}

int BrickWorld::get_block_material(int chunk_id, int block_id) const {
    if (!valid_chunk(chunk_id)) {
        return 0;
    }
    const Chunk &c = chunks[chunk_id];
    return (block_id >= 0 && block_id < (int)c.blocks.size()) ? (int)c.blocks[block_id].material : 0;
}

bool BrickWorld::set_block_material(int chunk_id, int block_id, int material) {
    if (!valid_chunk(chunk_id) || material < 0 || material >= BRICK_MATERIAL_COUNT) {
        return false;
    }
    Chunk &c = chunks[chunk_id];
    if (block_id < 0 || block_id >= (int)c.blocks.size() || c.blocks[block_id].removed) {
        return false;
    }
    if (c.blocks[block_id].material == (uint8_t)material) {
        return true;
    }
    c.blocks[block_id].material = (uint8_t)material;
    // Same reason as set_block_colour: the bake holds each face's colour, and
    // the material rides in that colour's alpha.
    if (c.bake.valid || bake_pending(chunk_id)) {
        drop_chunk_bake(chunk_id);
    }
    return true;
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

RID BrickWorld::hull_shape_for(int archetype_id, int hull) {
    const std::pair<int, int> key(archetype_id, hull);
    auto it = hull_shapes.find(key);
    if (it != hull_shapes.end()) {
        return it->second;
    }
    PhysicsServer3D *ps = PhysicsServer3D::get_singleton();
    const RID rid = ps->convex_polygon_shape_create();
    ps->shape_set_data(rid, archetypes[archetype_id].hulls[hull]);
    hull_shapes[key] = rid;
    return rid;
}

void BrickWorld::free_hull_shapes(int archetype_id) {
    PhysicsServer3D *ps = PhysicsServer3D::get_singleton();
    for (auto it = hull_shapes.begin(); it != hull_shapes.end();) {
        if (it->first.first == archetype_id) {
            if (ps != nullptr) {
                ps->free_rid(it->second);
            }
            it = hull_shapes.erase(it);
        } else {
            ++it;
        }
    }
}

void BrickWorld::set_archetype_hulls(int archetype_id, const Array &hulls) {
    palette_changed();
    if (!valid_archetype(archetype_id)) {
        return;
    }
    std::vector<PackedVector3Array> next;
    for (int i = 0; i < hulls.size(); ++i) {
        const PackedVector3Array h = hulls[i];
        if (h.size() < 4) {
            UtilityFunctions::push_error("BrickWorld: a hull needs at least four points");
            return;
        }
        next.push_back(h);
    }
    // Any shape built from the old hulls is now wrong.
    free_hull_shapes(archetype_id);
    archetypes[archetype_id].hulls = next;
}

int BrickWorld::get_archetype_hull_count(int archetype_id) const {
    return valid_archetype(archetype_id) ? (int)archetypes[archetype_id].hulls.size() : 0;
}

void BrickWorld::set_archetype_mesh(int archetype_id, const PackedVector3Array &positions,
        const PackedVector3Array &normals) {
    if (!valid_archetype(archetype_id)) {
        return;
    }
    if (positions.size() % 3 != 0 || normals.size() != positions.size()) {
        UtilityFunctions::push_error("BrickWorld: a mesh needs three positions and three normals a triangle");
        return;
    }
    palette_changed();
    Archetype &a = archetypes[archetype_id];
    a.mesh.clear();
    for (int i = 0; i < positions.size(); i += 3) {
        Archetype::MeshTri t;
        for (int k = 0; k < 3; ++k) {
            t.p[k] = positions[i + k];
            t.n[k] = normals[i + k].normalized();
        }
        a.mesh.push_back(t);
    }
    mark_feature_edges(a.mesh);
}

// Which triangle edges are the part's real edges (Archetype::MeshTri::feature):
// an edge no other triangle shares, or shares turning by more than a crease.
// Positions are matched to a tenth of a millimetre. Round a curve, flat across
// a face, the triangulation's own edges are not.
void BrickWorld::mark_feature_edges(std::vector<Archetype::MeshTri> &mesh) {
    // First, no T-junctions. Where a vertex of one triangle lies along the
    // edge of another -- an arch's beam over the tops of its pillars -- that
    // edge is split there, so every edge is shared exactly or not at all.
    // Otherwise the beam's long underside edge, real over the opening and
    // not over the pillars, could only be one or the other.
    {
        std::vector<Vector3> verts;
        for (const Archetype::MeshTri &t : mesh) {
            for (int k = 0; k < 3; ++k) {
                bool seen = false;
                for (const Vector3 &v : verts) {
                    if ((v - t.p[k]).length_squared() < 1e-10f) {
                        seen = true;
                        break;
                    }
                }
                if (!seen) {
                    verts.push_back(t.p[k]);
                }
            }
        }
        for (int pass = 0; pass < 8; ++pass) {
            bool split = false;
            std::vector<Archetype::MeshTri> out;
            out.reserve(mesh.size());
            for (const Archetype::MeshTri &t : mesh) {
                int at_k = -1;
                float at_s = 0.0f;
                Vector3 at_v;
                for (int k = 0; k < 3 && at_k < 0; ++k) {
                    const Vector3 a = t.p[(k + 1) % 3], b = t.p[(k + 2) % 3];
                    const Vector3 ab = b - a;
                    const float l2 = ab.length_squared();
                    if (l2 < 1e-10f) {
                        continue;
                    }
                    for (const Vector3 &v : verts) {
                        const float sv = (v - a).dot(ab) / l2;
                        if (sv > 1e-3f && sv < 1.0f - 1e-3f && (a + ab * sv - v).length() < 1e-4f) {
                            at_k = k;
                            at_s = sv;
                            at_v = v;
                            break;
                        }
                    }
                }
                if (at_k < 0) {
                    out.push_back(t);
                    continue;
                }
                split = true;
                const int k0 = at_k, k1 = (at_k + 1) % 3, k2 = (at_k + 2) % 3;
                const Vector3 nv = t.n[k1].lerp(t.n[k2], at_s).normalized();
                Archetype::MeshTri x = t, y = t;
                // (p0, a, b) cut at v on a-b: (p0, a, v) and (p0, v, b),
                // wound as the original.
                x.p[k0] = t.p[k0]; x.p[k1] = t.p[k1]; x.p[k2] = at_v;
                x.n[k0] = t.n[k0]; x.n[k1] = t.n[k1]; x.n[k2] = nv;
                y.p[k0] = t.p[k0]; y.p[k1] = at_v; y.p[k2] = t.p[k2];
                y.n[k0] = t.n[k0]; y.n[k1] = nv; y.n[k2] = t.n[k2];
                out.push_back(x);
                out.push_back(y);
            }
            mesh.swap(out);
            if (!split) {
                break;
            }
        }
    }
    const float crease = std::cos(30.0f * 3.14159265f / 180.0f);
    struct Key {
        int64_t a[3], b[3];
        bool operator<(const Key &o) const {
            for (int i = 0; i < 3; ++i) {
                if (a[i] != o.a[i]) return a[i] < o.a[i];
            }
            for (int i = 0; i < 3; ++i) {
                if (b[i] != o.b[i]) return b[i] < o.b[i];
            }
            return false;
        }
    };
    const auto q = [](const Vector3 &v, int64_t out[3]) {
        out[0] = (int64_t)std::llround(v.x * 10000.0f);
        out[1] = (int64_t)std::llround(v.y * 10000.0f);
        out[2] = (int64_t)std::llround(v.z * 10000.0f);
    };
    std::map<Key, std::vector<std::pair<int, int>>> edges;
    std::vector<Vector3> fn(mesh.size());
    for (size_t i = 0; i < mesh.size(); ++i) {
        const Archetype::MeshTri &t = mesh[i];
        Vector3 n = (t.p[1] - t.p[0]).cross(t.p[2] - t.p[0]);
        fn[i] = n.length_squared() > 1e-16f ? n.normalized() : Vector3();
        for (int k = 0; k < 3; ++k) {
            int64_t a[3], b[3];
            q(t.p[(k + 1) % 3], a);
            q(t.p[(k + 2) % 3], b);
            Key key;
            const bool swap = std::lexicographical_compare(b, b + 3, a, a + 3);
            for (int j = 0; j < 3; ++j) {
                key.a[j] = swap ? b[j] : a[j];
                key.b[j] = swap ? a[j] : b[j];
            }
            edges[key].push_back({ (int)i, k });
        }
    }
    for (Archetype::MeshTri &t : mesh) {
        t.feature = 0;
    }
    for (const auto &e : edges) {
        const std::vector<std::pair<int, int>> &users = e.second;
        bool feature = users.size() != 2;
        if (!feature) {
            // Winding may differ (a mirrored variant), so compare as lines.
            feature = std::abs(fn[(size_t)users[0].first].dot(fn[(size_t)users[1].first])) < crease;
        }
        if (feature) {
            for (const auto &u : users) {
                mesh[(size_t)u.first].feature |= (uint8_t)(1u << u.second);
            }
        }
    }

    // Each triangle's nearest real edges on its flat face (MeshTri::edge_a).
    // A face: the triangles in one plane. A curved surface's triangles each
    // have a plane of their own, and keep their own edges.
    const auto face_normal = [&](size_t i) -> Vector3 {
        const Archetype::MeshTri &t = mesh[i];
        const Vector3 n = (t.p[1] - t.p[0]).cross(t.p[2] - t.p[0]);
        return n.length_squared() > 1e-16f ? n.normalized() : Vector3();
    };
    const auto same_plane = [&](size_t i, size_t j) -> bool {
        const Vector3 a = face_normal(i), b = face_normal(j);
        return std::abs(a.dot(b)) > 0.9995f && std::abs(a.dot(mesh[j].p[0] - mesh[i].p[0])) < 1e-4f;
    };
    const auto face_of = [&](size_t i) -> std::vector<size_t> {
        std::vector<size_t> f;
        for (size_t j = 0; j < mesh.size(); ++j) {
            if (j == i || same_plane(i, j)) {
                f.push_back(j);
            }
        }
        return f;
    };
    // Whether the face lies all on one side of the line a-b: a convex face's
    // every edge. A face with a notch in it (an arch's front, round its
    // opening) has edges whose lines run on across it.
    const auto supports = [&](const std::vector<size_t> &face, const Vector3 &n,
            const Vector3 &a, const Vector3 &b) -> bool {
        const Vector3 side = n.cross(b - a);
        float lo = 0.0f, hi = 0.0f;
        for (size_t j : face) {
            for (int k = 0; k < 3; ++k) {
                const float sd = side.dot(mesh[j].p[k] - a);
                lo = std::min(lo, sd);
                hi = std::max(hi, sd);
            }
        }
        const float tol = 1e-5f * std::max(side.length(), 1e-6f);
        return lo > -tol || hi < tol;
    };

    // Such an edge's line is its distance only beside it -- between the
    // perpendiculars through its ends. So the face is cut along those
    // perpendiculars first: every piece then lies wholly beside the edge or
    // wholly past its end, and takes the line or does not.
    {
        struct Cut {
            Vector3 o, m;   // the points with (p - o).m == 0
        };
        std::vector<Cut> cuts;
        std::vector<bool> done(mesh.size(), false);
        for (size_t i = 0; i < mesh.size(); ++i) {
            if (done[i]) {
                continue;
            }
            const std::vector<size_t> face = face_of(i);
            const Vector3 n = face_normal(i);
            for (size_t j : face) {
                done[j] = true;
                const Archetype::MeshTri &t = mesh[j];
                for (int k = 0; k < 3; ++k) {
                    if (((t.feature >> k) & 1u) == 0) {
                        continue;
                    }
                    const Vector3 a = t.p[(k + 1) % 3], b = t.p[(k + 2) % 3];
                    if (face.size() < 2 || supports(face, n, a, b)) {
                        continue;
                    }
                    const Vector3 m = (b - a).normalized();
                    cuts.push_back({ a, m });
                    cuts.push_back({ b, m });
                }
            }
        }
        for (const Cut &cut : cuts) {
            std::vector<Archetype::MeshTri> out;
            out.reserve(mesh.size());
            for (const Archetype::MeshTri &t : mesh) {
                // Only a triangle of a face the cut lies in: one whose plane
                // holds the cut's line.
                const Vector3 tn = (t.p[1] - t.p[0]).cross(t.p[2] - t.p[0]);
                const bool in_plane = tn.length_squared() > 1e-16f
                        && std::abs(tn.normalized().dot(cut.m)) < 1e-4f
                        && std::abs(tn.normalized().dot(cut.o - t.p[0])) < 1e-4f;
                float f[3];
                int neg = 0, pos = 0;
                for (int k = 0; k < 3; ++k) {
                    f[k] = (t.p[k] - cut.o).dot(cut.m);
                    neg += f[k] < -1e-5f ? 1 : 0;
                    pos += f[k] > 1e-5f ? 1 : 0;
                }
                if (!in_plane || neg == 0 || pos == 0) {
                    out.push_back(t);
                    continue;
                }
                // The vertex alone on its side (a vertex on the line itself
                // counts with neither: then the triangle is cut in two).
                int lone = -1;
                for (int k = 0; k < 3; ++k) {
                    const int sk = f[k] < -1e-5f ? -1 : (f[k] > 1e-5f ? 1 : 0);
                    const int s1 = f[(k + 1) % 3] < -1e-5f ? -1 : (f[(k + 1) % 3] > 1e-5f ? 1 : 0);
                    const int s2 = f[(k + 2) % 3] < -1e-5f ? -1 : (f[(k + 2) % 3] > 1e-5f ? 1 : 0);
                    if (sk != 0 && s1 != sk && s2 != sk && (s1 == -sk || s2 == -sk)) {
                        lone = k;
                        break;
                    }
                }
                if (lone < 0) {
                    out.push_back(t);
                    continue;
                }
                const int i0 = lone, i1 = (lone + 1) % 3, i2 = (lone + 2) % 3;
                const uint8_t fi = (t.feature >> i0) & 1u, fj = (t.feature >> i1) & 1u,
                              fk = (t.feature >> i2) & 1u;
                const auto at = [&](int x, int y, Vector3 &pp, Vector3 &nn) {
                    const float u = f[x] / (f[x] - f[y]);
                    pp = t.p[x].lerp(t.p[y], u);
                    nn = t.n[x].lerp(t.n[y], u).normalized();
                };
                Vector3 pa, na, pb, nb;
                at(i0, i1, pa, na);   // on i0-i1, the edge opposite i2
                at(i0, i2, pb, nb);   // on i2-i0, the edge opposite i1
                const bool j_on = std::abs(f[i1]) <= 1e-5f;
                const bool k_on = std::abs(f[i2]) <= 1e-5f;
                Archetype::MeshTri x = t, y = t, z = t;
                if (j_on || k_on) {
                    // The line runs through a corner: two pieces.
                    // Through i1: cut i2-i0 at pb -> (i0, i1, pb), (pb, i1, i2).
                    // Through i2: cut i0-i1 at pa -> (i0, pa, i2), (pa, i1, i2).
                    if (j_on) {
                        x.p[0] = t.p[i0]; x.p[1] = t.p[i1]; x.p[2] = pb;
                        x.n[0] = t.n[i0]; x.n[1] = t.n[i1]; x.n[2] = nb;
                        x.feature = (uint8_t)(0u | (fj << 1) | (fk << 2));
                        y.p[0] = pb; y.p[1] = t.p[i1]; y.p[2] = t.p[i2];
                        y.n[0] = nb; y.n[1] = t.n[i1]; y.n[2] = t.n[i2];
                        y.feature = (uint8_t)(fi | (fj << 1) | 0u);
                    } else {
                        x.p[0] = t.p[i0]; x.p[1] = pa; x.p[2] = t.p[i2];
                        x.n[0] = t.n[i0]; x.n[1] = na; x.n[2] = t.n[i2];
                        x.feature = (uint8_t)(0u | (fj << 1) | (fk << 2));
                        y.p[0] = pa; y.p[1] = t.p[i1]; y.p[2] = t.p[i2];
                        y.n[0] = na; y.n[1] = t.n[i1]; y.n[2] = t.n[i2];
                        y.feature = (uint8_t)(fi | 0u | (fk << 2));
                    }
                    out.push_back(x);
                    out.push_back(y);
                    continue;
                }
                // (i0, pa, pb); (pa, i1, i2); (pa, i2, pb).
                x.p[0] = t.p[i0]; x.p[1] = pa; x.p[2] = pb;
                x.n[0] = t.n[i0]; x.n[1] = na; x.n[2] = nb;
                x.feature = (uint8_t)(0u | (fj << 1) | (fk << 2));
                y.p[0] = pa; y.p[1] = t.p[i1]; y.p[2] = t.p[i2];
                y.n[0] = na; y.n[1] = t.n[i1]; y.n[2] = t.n[i2];
                y.feature = (uint8_t)(fi | 0u | (fk << 2));
                z.p[0] = pa; z.p[1] = t.p[i2]; z.p[2] = pb;
                z.n[0] = na; z.n[1] = t.n[i2]; z.n[2] = nb;
                z.feature = (uint8_t)(fj | 0u | 0u);
                out.push_back(x);
                out.push_back(y);
                out.push_back(z);
            }
            mesh.swap(out);
        }
    }

    const auto seg_dist = [](const Vector3 &a, const Vector3 &b, const Vector3 &p) -> float {
        const Vector3 ab = b - a;
        const float l2 = ab.length_squared();
        const float s = l2 > 1e-12f ? std::clamp((p - a).dot(ab) / l2, 0.0f, 1.0f) : 0.0f;
        return (a + ab * s - p).length();
    };
    for (size_t i = 0; i < mesh.size(); ++i) {
        Archetype::MeshTri &t = mesh[i];
        const Vector3 c = (t.p[0] + t.p[1] + t.p[2]) / 3.0f;
        const std::vector<size_t> face = face_of(i);
        const Vector3 n = face_normal(i);
        // Beside the edge: every corner of this triangle between the
        // perpendiculars through its ends (the cuts above made it one or the
        // other).
        const auto beside = [&](const Vector3 &a, const Vector3 &b) -> bool {
            const Vector3 ab = b - a;
            const float l2 = ab.length_squared();
            for (int k = 0; k < 3; ++k) {
                const float sk = l2 > 1e-12f ? (t.p[k] - a).dot(ab) / l2 : 0.0f;
                if (sk < -1e-3f || sk > 1.0f + 1e-3f) {
                    return false;
                }
            }
            return true;
        };
        struct Cand {
            Vector3 a, b;
            float d;
        };
        std::vector<Cand> cands;
        for (size_t j : face) {
            const Archetype::MeshTri &o = mesh[j];
            for (int k = 0; k < 3; ++k) {
                if (((o.feature >> k) & 1u) == 0) {
                    continue;
                }
                const Vector3 a = o.p[(k + 1) % 3], b = o.p[(k + 2) % 3];
                if (face.size() > 1 && !supports(face, n, a, b) && !beside(a, b)) {
                    continue;
                }
                cands.push_back({ a, b, seg_dist(a, b, c) });
            }
        }
        std::sort(cands.begin(), cands.end(), [](const Cand &x, const Cand &y) { return x.d < y.d; });
        t.edges = 0;
        for (const Cand &cd : cands) {
            if (t.edges >= 3) {
                break;
            }
            // One line once: a long edge split in two is one line.
            bool dup = false;
            const Vector3 dir = (cd.b - cd.a).normalized();
            for (int k = 0; k < t.edges; ++k) {
                const Vector3 od = (t.edge_b[k] - t.edge_a[k]).normalized();
                const Vector3 off = cd.a - t.edge_a[k];
                if (std::abs(dir.dot(od)) > 0.9999f
                        && (off - od * off.dot(od)).length() < 1e-4f) {
                    dup = true;
                    break;
                }
            }
            if (!dup) {
                t.edge_a[t.edges] = cd.a;
                t.edge_b[t.edges] = cd.b;
                ++t.edges;
            }
        }
    }
}

int BrickWorld::get_archetype_mesh_triangles(int archetype_id) const {
    return valid_archetype(archetype_id) ? (int)archetypes[archetype_id].mesh.size() : 0;
}

void BrickWorld::set_side_studs(int archetype_id, const PackedInt32Array &studs) {
    palette_changed();
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

int64_t BrickWorld::paged_chunk_cells() { return Occupancy::PAGED_ABOVE; }

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

Dictionary BrickWorld::capture_blocks(int chunk_id, int from, int count) const {
    Dictionary out;
    PackedInt32Array cells, archs, decorative, joints, worn;
    PackedByteArray colours;
    Vector3 lo(INFINITY, INFINITY, INFINITY), hi(-INFINITY, -INFINITY, -INFINITY);
    int n = 0;
    if (valid_chunk(chunk_id)) {
        const Chunk &c = chunks[chunk_id];
        const int total = (int)c.blocks.size();
        const int start = std::max(from, 0);
        const int end = std::min(total, start + std::max(count, 0));
        const real_t metres = get_cell_size().x / (real_t)TICKS_STUD;
        for (int id = start; id < end; ++id) {
            const Block &b = c.blocks[(size_t)id];
            if (b.removed || b.detached || !b.alive) {
                continue;
            }
            Vector3i llo, lhi, wlo, whi;
            local_ticks(b.cell - c.origin, archetypes[b.archetype].size, llo, lhi);
            world_ticks(c.frame_rotation, c.frame_ticks, llo, lhi, wlo, whi);
            cells.push_back(wlo.x / TICKS_STUD);
            cells.push_back(wlo.y / TICKS_PLATE);
            cells.push_back(wlo.z / TICKS_STUD);
            if (b.decorative) {
                decorative.push_back(n);
            }
            const int cut = (b.support_broken ? JOINT_SUPPORT_BROKEN : 0)
                    | (b.bottom_broken ? JOINT_BOTTOM_BROKEN : 0)
                    | (b.strained ? JOINT_STRAINED : 0)
                    | (b.held ? JOINT_HELD : 0);
            if (cut != 0) {
                joints.push_back(n);
                joints.push_back(cut);
            }
            if (b.hp < 255) {
                worn.push_back(n);
                worn.push_back((int32_t)b.hp);
            }
            archs.push_back(b.archetype);
            colours.push_back(b.colour);
            const Vector3 a = Vector3(wlo) * metres;
            const Vector3 z = Vector3(whi) * metres;
            lo = Vector3(std::min(lo.x, a.x), std::min(lo.y, a.y), std::min(lo.z, a.z));
            hi = Vector3(std::max(hi.x, z.x), std::max(hi.y, z.y), std::max(hi.z, z.z));
            ++n;
        }
    }
    out["cells"] = cells;
    out["archetypes"] = archs;
    out["colours"] = colours;
    out["decorative"] = decorative;
    out["joints"] = joints;
    out["worn"] = worn;
    out["count"] = n;
    out["lo"] = lo;
    out["hi"] = hi;
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
    SolveScratch &scratch = solve_scratch();
    std::vector<int32_t> &scratch_depth = scratch.depth;
    std::vector<int32_t> &scratch_queue = scratch.queue;
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
    const brick::JointCache &jc = joints_of(chunk_id);

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
        const bool from_held = c.blocks[bid].held;
        for_each_joint(c, jc, bid, [&](int32_t nb, int) {
            if (mark[nb] != 0 || c.blocks[nb].support_broken) {
                return;
            }
            if (from_held && !c.blocks[nb].held) {
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
    ClassDB::bind_method(D_METHOD("get_components_near", "chunk_id"), &BrickWorld::get_components_near);
    ClassDB::bind_method(D_METHOD("cut_spans", "chunk_id", "reach_studs", "apply"), &BrickWorld::cut_spans);
    ClassDB::bind_method(D_METHOD("cut_spans_resting", "piece_chunk", "piece_xform", "building_chunks",
            "ground_y", "reach_studs", "apply"), &BrickWorld::cut_spans_resting);
    ClassDB::bind_method(D_METHOD("mark_chunk_whole", "chunk_id"), &BrickWorld::mark_chunk_whole);
    ClassDB::bind_method(D_METHOD("set_components_check", "on"), &BrickWorld::set_components_check);
    ClassDB::bind_method(D_METHOD("set_index_check", "on"), &BrickWorld::set_index_check);
    ClassDB::bind_method(D_METHOD("get_index_patch_stats"), &BrickWorld::get_index_patch_stats);
    ClassDB::bind_method(D_METHOD("get_components_near_stats"), &BrickWorld::get_components_near_stats);
    ClassDB::bind_method(D_METHOD("crack_studs", "chunk_id", "axis", "from_k", "to_k"),
            &BrickWorld::crack_studs);
    ClassDB::bind_method(D_METHOD("crack_components", "chunk_id", "planes_x", "planes_z"),
            &BrickWorld::crack_components);
    ClassDB::bind_method(D_METHOD("release_chunk", "chunk_id"), &BrickWorld::release_chunk);
    ClassDB::bind_method(D_METHOD("is_chunk_alive", "chunk_id"), &BrickWorld::is_chunk_alive);
    ClassDB::bind_method(D_METHOD("is_chunk_anchored", "chunk_id"), &BrickWorld::is_chunk_anchored);
    ClassDB::bind_method(D_METHOD("set_chunk_anchored", "chunk_id", "anchored"),
            &BrickWorld::set_chunk_anchored);
    ClassDB::bind_method(D_METHOD("get_chunk_com", "chunk_id"), &BrickWorld::get_chunk_com);
    ClassDB::bind_method(D_METHOD("separate_plane", "chunk_id", "world_point", "world_normal", "thickness",
            "within"), &BrickWorld::separate_plane, DEFVAL(Rect2()));
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
    ClassDB::bind_method(D_METHOD("set_archetype_hulls", "archetype_id", "hulls"),
            &BrickWorld::set_archetype_hulls);
    ClassDB::bind_method(D_METHOD("get_archetype_hull_count", "archetype_id"),
            &BrickWorld::get_archetype_hull_count);
    ClassDB::bind_method(D_METHOD("set_archetype_mesh", "archetype_id", "positions", "normals"),
            &BrickWorld::set_archetype_mesh);
    ClassDB::bind_method(D_METHOD("get_archetype_mesh_triangles", "archetype_id"),
            &BrickWorld::get_archetype_mesh_triangles);
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
    ClassDB::bind_method(D_METHOD("get_chunk_studs", "chunk_id"), &BrickWorld::get_chunk_studs);
    ClassDB::bind_method(D_METHOD("get_chunk_studs_section", "chunk_id", "section"),
            &BrickWorld::get_chunk_studs_section);
    ClassDB::bind_method(D_METHOD("get_chunk_studs_open", "chunk_id", "section"),
            &BrickWorld::get_chunk_studs_open);
    ClassDB::bind_method(D_METHOD("get_chunk_studs_and_open", "chunk_id", "section"),
            &BrickWorld::get_chunk_studs_and_open);
    ClassDB::bind_static_method("BrickWorld", D_METHOD("split_studs", "buffer", "eye", "rings",
            "open", "closed_rings"), &BrickWorld::split_studs, DEFVAL(PackedByteArray()), DEFVAL(0));
    ClassDB::bind_method(D_METHOD("build_chunk_chamfer_mesh", "chunk_id", "bevel"),
            &BrickWorld::build_chunk_chamfer_mesh);
    ClassDB::bind_method(D_METHOD("chamfer_section_async", "chunk_id", "section", "bevel"),
            &BrickWorld::chamfer_section_async);
    ClassDB::bind_method(D_METHOD("chamfer_pending", "chunk_id", "section"),
            &BrickWorld::chamfer_pending);
    ClassDB::bind_method(D_METHOD("chamfer_ready", "chunk_id", "section"),
            &BrickWorld::chamfer_ready);
    ClassDB::bind_method(D_METHOD("take_chamfer_section", "chunk_id", "section"),
            &BrickWorld::take_chamfer_section);
    ClassDB::bind_method(D_METHOD("update_chamfer_regions", "chunk_id", "sections"),
            &BrickWorld::update_chamfer_regions, DEFVAL(PackedInt32Array()));
    ClassDB::bind_method(D_METHOD("drop_chamfer", "chunk_id", "section", "all"),
            &BrickWorld::drop_chamfer, DEFVAL(false));
    ClassDB::bind_method(D_METHOD("get_chamfer_expected_triangles", "chunk_id", "section"),
            &BrickWorld::get_chamfer_expected_triangles);
    ClassDB::bind_method(D_METHOD("get_last_chamfer_triangles"),
            &BrickWorld::get_last_chamfer_triangles);
    ClassDB::bind_method(D_METHOD("get_last_chamfer_ms"), &BrickWorld::get_last_chamfer_ms);
    ClassDB::bind_method(D_METHOD("get_column_mask", "chunk_id", "y0", "y1"),
            &BrickWorld::get_column_mask);
    ClassDB::bind_method(D_METHOD("build_damage_profile", "chunk_id", "fx", "fz", "thick",
                    "segments", "bands"),
            &BrickWorld::build_damage_profile);
    ClassDB::bind_method(D_METHOD("get_dead_blocks", "chunk_id"), &BrickWorld::get_dead_blocks);
    ClassDB::bind_method(D_METHOD("get_detached_blocks", "chunk_id"),
            &BrickWorld::get_detached_blocks);
    ClassDB::bind_method(D_METHOD("get_dead_block_count", "chunk_id"),
            &BrickWorld::get_dead_block_count);
    ClassDB::bind_method(D_METHOD("get_block_archetype", "chunk_id", "block_id"),
            &BrickWorld::get_block_archetype);
    ClassDB::bind_method(D_METHOD("get_block_colour", "chunk_id", "block_id"),
            &BrickWorld::get_block_colour);
    ClassDB::bind_method(D_METHOD("set_block_colour", "chunk_id", "block_id", "colour"),
            &BrickWorld::set_block_colour);
    ClassDB::bind_method(D_METHOD("get_block_material", "chunk_id", "block_id"),
            &BrickWorld::get_block_material);
    ClassDB::bind_method(D_METHOD("set_block_material", "chunk_id", "block_id", "material"),
            &BrickWorld::set_block_material);
    ClassDB::bind_static_method("BrickWorld", D_METHOD("get_material_count"), &BrickWorld::get_material_count);
    ClassDB::bind_static_method("BrickWorld", D_METHOD("get_material_name", "material"), &BrickWorld::get_material_name);
    ClassDB::bind_static_method("BrickWorld", D_METHOD("is_filament_material", "material"), &BrickWorld::is_filament_material);
    ClassDB::bind_static_method("BrickWorld", D_METHOD("get_material_colour_count", "material"), &BrickWorld::get_material_colour_count);
    ClassDB::bind_static_method("BrickWorld", D_METHOD("get_material_toughness", "material"), &BrickWorld::get_material_toughness);
    ClassDB::bind_static_method("BrickWorld", D_METHOD("is_material_translucent", "material"), &BrickWorld::is_material_translucent);
    ClassDB::bind_method(D_METHOD("get_block_hp", "chunk_id", "block_id"), &BrickWorld::get_block_hp);
    ClassDB::bind_static_method("BrickWorld", D_METHOD("get_material_colour", "material", "colour"), &BrickWorld::get_material_colour);
    ClassDB::bind_static_method("BrickWorld", D_METHOD("get_material_colour_name", "material", "colour"), &BrickWorld::get_material_colour_name);
    ClassDB::bind_method(D_METHOD("is_solid", "chunk_id", "cell"), &BrickWorld::is_solid);
    ClassDB::bind_method(D_METHOD("block_at", "chunk_id", "cell"), &BrickWorld::block_at);
    ClassDB::bind_method(D_METHOD("get_block_count", "chunk_id"), &BrickWorld::get_block_count);
    ClassDB::bind_method(D_METHOD("get_alive_block_count", "chunk_id"), &BrickWorld::get_alive_block_count);
    ClassDB::bind_method(D_METHOD("get_block_index_range", "chunk_id", "block_id"),
            &BrickWorld::get_block_index_range);

    ClassDB::bind_method(D_METHOD("build_chunk_mesh", "chunk_id"), &BrickWorld::build_chunk_mesh);
    ClassDB::bind_method(D_METHOD("rest_contacts", "piece_chunk", "piece_xform", "building_chunk"),
            &BrickWorld::rest_contacts);
    ClassDB::bind_method(D_METHOD("any_block_centre_in", "chunk_id", "box", "exclude"),
            &BrickWorld::any_block_centre_in);
    ClassDB::bind_method(D_METHOD("block_centre_levels", "chunk_id", "box", "level_height", "exclude"),
            &BrickWorld::block_centre_levels);
    ClassDB::bind_method(D_METHOD("build_chunk_coarse_mesh", "chunk_id"),
            &BrickWorld::build_chunk_coarse_mesh);
    ClassDB::bind_method(D_METHOD("get_last_coarse_ms"), &BrickWorld::get_last_coarse_ms);
    ClassDB::bind_method(D_METHOD("coarse_chunk_async", "chunk_id"), &BrickWorld::coarse_chunk_async);
    ClassDB::bind_method(D_METHOD("coarse_pending", "chunk_id"), &BrickWorld::coarse_pending);
    ClassDB::bind_method(D_METHOD("coarse_ready", "chunk_id"), &BrickWorld::coarse_ready);
    ClassDB::bind_method(D_METHOD("take_coarse_mesh", "chunk_id"), &BrickWorld::take_coarse_mesh);
    ClassDB::bind_method(D_METHOD("get_mesh_stats", "chunk_id"), &BrickWorld::get_mesh_stats);
    ClassDB::bind_method(D_METHOD("set_chunk_section_plates", "chunk_id", "plates"),
            &BrickWorld::set_chunk_section_plates);
    ClassDB::bind_method(D_METHOD("set_chunk_section_studs", "chunk_id", "studs"),
            &BrickWorld::set_chunk_section_studs);
    ClassDB::bind_method(D_METHOD("get_chunk_sections", "chunk_id"),
            &BrickWorld::get_chunk_sections);
    ClassDB::bind_method(D_METHOD("has_bake", "chunk_id"), &BrickWorld::has_bake);
    ClassDB::bind_method(D_METHOD("build_chunk_mesh_section", "chunk_id", "section"),
            &BrickWorld::build_chunk_mesh_section);
    ClassDB::bind_method(D_METHOD("update_index_regions", "chunk_id", "index_bytes"),
            &BrickWorld::update_index_regions);
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
    ClassDB::bind_method(D_METHOD("add_chunk_shapes", "body", "chunk_id", "offset", "skip_dead", "merge",
            "section", "skip_decorative"), &BrickWorld::add_chunk_shapes, DEFVAL(false), DEFVAL(-1),
            DEFVAL(false));
    ClassDB::bind_method(D_METHOD("get_chunk_authored_tris", "chunk_id"),
            &BrickWorld::get_chunk_authored_tris);
    ClassDB::bind_method(D_METHOD("get_blocks_box", "chunk_id", "block_ids"),
            &BrickWorld::get_blocks_box);
    ClassDB::bind_method(D_METHOD("solve_structures", "chunk_ids", "max_rounds", "budget_ms"),
            &BrickWorld::solve_structures, DEFVAL(1), DEFVAL(0.0));
    ClassDB::bind_method(D_METHOD("solve_rounds", "chunk_id", "rounds"), &BrickWorld::solve_rounds);
    ClassDB::bind_method(D_METHOD("get_block_sections", "chunk_id", "block_ids", "skip_decorative"),
            &BrickWorld::get_block_sections, DEFVAL(false));
    ClassDB::bind_method(D_METHOD("add_band_shapes", "bodies", "chunk_id", "offset", "sections",
            "skip_decorative"), &BrickWorld::add_band_shapes, DEFVAL(false));
    ClassDB::bind_method(D_METHOD("capture_blocks", "chunk_id", "from", "count"),
            &BrickWorld::capture_blocks);
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
    ClassDB::bind_method(D_METHOD("lateral_check", "chunk_id", "accel_g", "world_dir"),
            &BrickWorld::lateral_check);
    ClassDB::bind_method(D_METHOD("build_snow_cover", "chunk_id", "thickness"),
            &BrickWorld::build_snow_cover);
    ClassDB::bind_static_method("BrickWorld", D_METHOD("build_snow_cover_tops", "tops", "w", "d",
            "cell", "plate", "thickness", "origin"), &BrickWorld::build_snow_cover_tops);
    ClassDB::bind_method(D_METHOD("check_stability", "chunk_id"), &BrickWorld::check_stability);
    ClassDB::bind_method(D_METHOD("gravity_check", "chunk_id", "crush_per_stud"),
            &BrickWorld::gravity_check);
    ClassDB::bind_method(D_METHOD("solve_structure", "chunk_id", "max_rounds", "budget_ms"),
            &BrickWorld::solve_structure, DEFVAL(1), DEFVAL(0.0));
    ClassDB::bind_method(D_METHOD("heal_joints", "chunk_id"), &BrickWorld::heal_joints);
    ClassDB::bind_method(D_METHOD("save_template", "chunk_id"), &BrickWorld::save_template);
    ClassDB::bind_method(D_METHOD("place_blocks", "chunk_id", "origin", "cells", "archetype_ids", "colours"),
            &BrickWorld::place_blocks);
    ClassDB::bind_method(D_METHOD("load_template", "template_id", "chunk_id"), &BrickWorld::load_template);
    ClassDB::bind_method(D_METHOD("create_band_chunk", "template_id"), &BrickWorld::create_band_chunk);
    ClassDB::bind_method(D_METHOD("lay_band", "chunk_id", "template_id", "y_lo", "y_hi"),
            &BrickWorld::lay_band);
    ClassDB::bind_method(D_METHOD("get_absent_count", "chunk_id"), &BrickWorld::get_absent_count);
    ClassDB::bind_method(D_METHOD("unlay_band", "chunk_id", "y_lo", "y_hi", "template_blocks"),
            &BrickWorld::unlay_band);
    ClassDB::bind_method(D_METHOD("is_block_absent", "chunk_id", "block_id"),
            &BrickWorld::is_block_absent);
    ClassDB::bind_method(D_METHOD("get_template_mass", "template_id", "y_lo", "y_hi"),
            &BrickWorld::get_template_mass);
    ClassDB::bind_method(D_METHOD("get_blocks_topping", "chunk_id", "y"),
            &BrickWorld::get_blocks_topping);
    ClassDB::bind_method(D_METHOD("get_blocks_in_band", "chunk_id", "y_lo", "y_hi"),
            &BrickWorld::get_blocks_in_band);
    ClassDB::bind_method(D_METHOD("get_template_com", "template_id", "y_lo", "y_hi"),
            &BrickWorld::get_template_com);
    ClassDB::bind_method(D_METHOD("get_blocks_footprint", "chunk_id", "ids"),
            &BrickWorld::get_blocks_footprint);
    ClassDB::bind_method(D_METHOD("get_occupancy_bytes", "chunk_id"),
            &BrickWorld::get_occupancy_bytes);
    ClassDB::bind_method(D_METHOD("get_solid_cells", "chunk_id"), &BrickWorld::get_solid_cells);
    ClassDB::bind_method(D_METHOD("set_anchor_levels", "chunk_id", "grid_ys"),
            &BrickWorld::set_anchor_levels);
    ClassDB::bind_method(D_METHOD("get_template_count"), &BrickWorld::get_template_count);
    ClassDB::bind_method(D_METHOD("set_tension_per_stud", "chunk_id", "capacity"),
            &BrickWorld::set_tension_per_stud);
    ClassDB::bind_method(D_METHOD("get_tension_per_stud", "chunk_id"), &BrickWorld::get_tension_per_stud);
    ClassDB::bind_method(D_METHOD("get_max_stress_ratio", "chunk_id"), &BrickWorld::get_max_stress_ratio);
    ClassDB::bind_method(D_METHOD("get_block_load", "chunk_id", "block_id"), &BrickWorld::get_block_load);
    ClassDB::bind_method(D_METHOD("get_block_capacity", "chunk_id", "block_id"),
            &BrickWorld::get_block_capacity);
    ClassDB::bind_method(D_METHOD("is_support_broken", "chunk_id", "block_id"),
            &BrickWorld::is_support_broken);
    ClassDB::bind_method(D_METHOD("get_block_joints", "chunk_id", "block_id"),
            &BrickWorld::get_block_joints);
    ClassDB::bind_method(D_METHOD("set_block_joints", "chunk_id", "block_id", "joints"),
            &BrickWorld::set_block_joints);
    BIND_CONSTANT(JOINT_SUPPORT_BROKEN);
    BIND_CONSTANT(JOINT_BOTTOM_BROKEN);

    ClassDB::bind_method(D_METHOD("set_load", "chunk_id", "owner", "block_ids", "mass_each"),
            &BrickWorld::set_load);
    ClassDB::bind_method(D_METHOD("clear_load", "chunk_id", "owner"), &BrickWorld::clear_load);
    ClassDB::bind_method(D_METHOD("get_external_load", "chunk_id", "block_id"),
            &BrickWorld::get_external_load);
    ClassDB::bind_method(D_METHOD("get_load_owners", "chunk_id"), &BrickWorld::get_load_owners);
    ClassDB::bind_method(D_METHOD("get_headroom", "chunk_id", "block_id"), &BrickWorld::get_headroom);
    ClassDB::bind_method(D_METHOD("chip_hit", "chunk_id", "world_point", "radius_m", "damage"),
            &BrickWorld::chip_hit);
    ClassDB::bind_method(D_METHOD("get_worn_blocks", "chunk_id"), &BrickWorld::get_worn_blocks);
    ClassDB::bind_method(D_METHOD("scorch_hit", "chunk_id", "world_point", "radius_m"),
            &BrickWorld::scorch_hit);
    ClassDB::bind_method(D_METHOD("get_scorched_blocks", "chunk_id"), &BrickWorld::get_scorched_blocks);
    ClassDB::bind_method(D_METHOD("set_scorched_blocks", "chunk_id", "ids"),
            &BrickWorld::set_scorched_blocks);
    ClassDB::bind_method(D_METHOD("fire_heat", "chunk_id", "world_point", "radius_m", "heat",
                    "by_material"),
            &BrickWorld::fire_heat, DEFVAL(false));
    ClassDB::bind_method(D_METHOD("fire_step", "chunk_id", "dt", "wind", "damp", "max_burning"),
            &BrickWorld::fire_step);
    ClassDB::bind_method(D_METHOD("fire_clear", "chunk_id"), &BrickWorld::fire_clear);
    ClassDB::bind_method(D_METHOD("fire_burning", "chunk_id"), &BrickWorld::fire_burning);
    ClassDB::bind_method(D_METHOD("fire_get", "chunk_id", "block_id"), &BrickWorld::fire_get);
    ClassDB::bind_static_method("BrickWorld", D_METHOD("fire_burn_seconds", "material", "cells"),
            &BrickWorld::fire_burn_seconds);
    ClassDB::bind_method(D_METHOD("set_worn_blocks", "chunk_id", "worn"),
            &BrickWorld::set_worn_blocks);
    ClassDB::bind_method(D_METHOD("apply_hit", "chunk_id", "world_point", "radius_m"),
            &BrickWorld::apply_hit);
    ClassDB::bind_method(D_METHOD("separate_near", "chunk_id", "world_point", "radius_m",
                    "max_blocks", "peel"),
            &BrickWorld::separate_near, DEFVAL(0), DEFVAL(false));
    ClassDB::bind_method(D_METHOD("sever_seams", "chunk_id", "world_points", "world_normal", "through"),
            &BrickWorld::sever_seams, DEFVAL(false));
    ClassDB::bind_method(D_METHOD("seam_studs", "chunk_id", "from_k", "to_k"),
            &BrickWorld::seam_studs);
    ClassDB::bind_method(D_METHOD("detach_group", "chunk_id", "block_ids"), &BrickWorld::detach_group);
    ClassDB::bind_method(D_METHOD("get_block_boxes", "chunk_id"), &BrickWorld::get_block_boxes);

    ClassDB::bind_static_method("BrickWorld", D_METHOD("ticks_per_stud"),
            &BrickWorld::ticks_per_stud);
    ClassDB::bind_static_method("BrickWorld", D_METHOD("ticks_per_plate"),
            &BrickWorld::ticks_per_plate);
    ClassDB::bind_static_method("BrickWorld", D_METHOD("rotation_count"),
            &BrickWorld::rotation_count);
    ClassDB::bind_static_method("BrickWorld", D_METHOD("paged_chunk_cells"),
            &BrickWorld::paged_chunk_cells);
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
