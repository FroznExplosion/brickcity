#include "ai_world.h"

#include "../brick_grid.h"
#include "../brick_terrain.h"

#include <godot_cpp/core/class_db.hpp>

#include <algorithm>
#include <chrono>
#include <cmath>
#include <limits>

using namespace godot;

namespace {

uint64_t now_usec() {
    return (uint64_t)std::chrono::duration_cast<std::chrono::microseconds>(
            std::chrono::steady_clock::now().time_since_epoch())
            .count();
}

// BrickWorld::chip_hit's wear rule, restated: a round of `dmg` takes
// dmg / toughness hp, in tenths so it stays integer, at least 1. Cover life
// has to predict what the gun will actually do, so it is the same arithmetic.
int wear_of(int dmg, int material) {
    dmg = std::clamp(dmg, 0, 255);
    if (dmg <= 0) {
        return 0;
    }
    const int t10 = std::max(1, (int)std::lround(brick::brick_material_toughness(material) * 10.0f));
    return std::max(1, (dmg * 10 + t10 / 2) / t10);
}

} // namespace

void AIWorld::_bind_methods() {
    ClassDB::bind_method(D_METHOD("set_world", "world"), &AIWorld::set_world);
    ClassDB::bind_method(D_METHOD("get_world"), &AIWorld::get_world);
    ClassDB::bind_method(D_METHOD("sync"), &AIWorld::sync);
    ClassDB::bind_method(D_METHOD("get_indexed_chunks"), &AIWorld::get_indexed_chunks);
    ClassDB::bind_method(D_METHOD("trace", "from", "to"), &AIWorld::_b_trace);
    ClassDB::bind_method(D_METHOD("bricks_between", "from", "to"), &AIWorld::_b_bricks_between);
    ClassDB::bind_method(D_METHOD("line_clear", "from", "to"), &AIWorld::_b_line_clear);
    ClassDB::bind_method(D_METHOD("cover_seconds", "from", "to", "hp_per_hit", "hits_per_second"),
            &AIWorld::_b_cover_seconds);
    ClassDB::bind_method(D_METHOD("cover_seconds_batch", "from", "to", "hp_per_hit",
                                 "hits_per_second"),
            &AIWorld::_b_cover_seconds_batch);
    ClassDB::bind_method(D_METHOD("set_proxy", "id", "xform", "size", "bricks_per_metre"),
            &AIWorld::_b_set_proxy);
    ClassDB::bind_method(D_METHOD("set_cover", "id", "xform", "size", "bricks_per_metre"),
            &AIWorld::_b_set_cover);
    ClassDB::bind_method(D_METHOD("remove_proxy", "id"), &AIWorld::remove_proxy);
    ClassDB::bind_method(D_METHOD("clear_proxies"), &AIWorld::clear_proxies);
    ClassDB::bind_method(D_METHOD("get_proxy_count"), &AIWorld::get_proxy_count);
    ClassDB::bind_method(D_METHOD("set_smoke", "id", "centre", "radius"), &AIWorld::_b_set_smoke);
    ClassDB::bind_method(D_METHOD("shift_origin", "offset"), &AIWorld::shift_origin);
    ClassDB::bind_method(D_METHOD("get_ground_shift"), &AIWorld::get_ground_shift);
    ClassDB::bind_method(D_METHOD("remove_smoke", "id"), &AIWorld::remove_smoke);
    ClassDB::bind_method(D_METHOD("clear_smoke"), &AIWorld::clear_smoke);
    ClassDB::bind_method(D_METHOD("smoke_blocks", "from", "to"), &AIWorld::_b_smoke_blocks);
    ClassDB::bind_method(D_METHOD("set_danger", "id", "box"), &AIWorld::_b_set_danger);
    ClassDB::bind_method(D_METHOD("remove_danger", "id"), &AIWorld::remove_danger);
    ClassDB::bind_method(D_METHOD("clear_danger"), &AIWorld::clear_danger);
    ClassDB::bind_method(D_METHOD("in_danger", "point"), &AIWorld::_b_in_danger);
    ClassDB::bind_method(D_METHOD("danger_distance", "point"), &AIWorld::_b_danger_distance);
    ClassDB::bind_method(D_METHOD("block_at", "point"), &AIWorld::_b_block_at);
    ClassDB::bind_method(D_METHOD("solid_at", "point"), &AIWorld::_b_solid_at);
    ClassDB::bind_method(D_METHOD("top_at", "x", "z"), &AIWorld::top_at);
    ClassDB::bind_method(D_METHOD("set_terrain_ground", "on"), &AIWorld::set_terrain_ground);
    ClassDB::bind_method(D_METHOD("get_terrain_ground"), &AIWorld::get_terrain_ground);
    ClassDB::bind_method(D_METHOD("ground_at", "x", "z"), &AIWorld::ground_at);
    ClassDB::bind_method(D_METHOD("ground_blocks", "from", "to"), &AIWorld::_b_ground_blocks);
    ClassDB::bind_method(D_METHOD("ground_under", "point"), &AIWorld::ground_under);
    ClassDB::bind_method(D_METHOD("top_over", "point"), &AIWorld::top_over);
    ClassDB::bind_method(D_METHOD("set_frame", "region_to_world"), &AIWorld::set_frame);
    ClassDB::bind_method(D_METHOD("get_frame"), &AIWorld::get_frame);
    ClassDB::bind_method(D_METHOD("is_framed"), &AIWorld::is_framed);
    ClassDB::bind_method(D_METHOD("set_ground_grid", "origin", "step", "size", "heights"),
            &AIWorld::set_ground_grid);
    ClassDB::bind_method(D_METHOD("has_ground_grid"), &AIWorld::has_ground_grid);
    ClassDB::bind_method(D_METHOD("get_stats"), &AIWorld::get_stats);
    ClassDB::bind_method(D_METHOD("reset_stats"), &AIWorld::reset_stats);
}

// --- the bound forms: world values in and out (set_frame) ---------------------
//
// Unframed, each calls straight through: the flat game takes exactly the path
// it always has.

Dictionary AIWorld::_b_trace(const Vector3 &from, const Vector3 &to) {
    if (!framed) {
        return trace(from, to);
    }
    Dictionary out = trace(frame_inv.xform(from), frame_inv.xform(to));
    out["point"] = frame.xform((Vector3)out["point"]);
    return out;
}

int AIWorld::_b_bricks_between(const Vector3 &from, const Vector3 &to) {
    if (!framed) {
        return bricks_between(from, to);
    }
    return bricks_between(frame_inv.xform(from), frame_inv.xform(to));
}

bool AIWorld::_b_line_clear(const Vector3 &from, const Vector3 &to) {
    if (!framed) {
        return line_clear(from, to);
    }
    return line_clear(frame_inv.xform(from), frame_inv.xform(to));
}

float AIWorld::_b_cover_seconds(const Vector3 &from, const Vector3 &to, int hp_per_hit,
        float hits_per_second) {
    if (!framed) {
        return cover_seconds(from, to, hp_per_hit, hits_per_second);
    }
    return cover_seconds(frame_inv.xform(from), frame_inv.xform(to), hp_per_hit, hits_per_second);
}

PackedFloat32Array AIWorld::_b_cover_seconds_batch(const Vector3 &from,
        const PackedVector3Array &to, int hp_per_hit, float hits_per_second) {
    if (!framed) {
        return cover_seconds_batch(from, to, hp_per_hit, hits_per_second);
    }
    PackedVector3Array local;
    local.resize(to.size());
    for (int i = 0; i < to.size(); ++i) {
        local.set(i, frame_inv.xform(to[i]));
    }
    return cover_seconds_batch(frame_inv.xform(from), local, hp_per_hit, hits_per_second);
}

void AIWorld::_b_set_proxy(int id, const Transform3D &xform, const Vector3 &size,
        float bricks_per_metre) {
    if (!framed) {
        set_proxy(id, xform, size, bricks_per_metre);
        return;
    }
    set_proxy(id, frame_inv * xform, size, bricks_per_metre);
}

void AIWorld::_b_set_cover(int id, const Transform3D &xform, const Vector3 &size,
        float bricks_per_metre) {
    if (!framed) {
        set_cover(id, xform, size, bricks_per_metre);
        return;
    }
    set_cover(id, frame_inv * xform, size, bricks_per_metre);
}

void AIWorld::_b_set_smoke(int id, const Vector3 &centre, float radius) {
    set_smoke(id, framed ? frame_inv.xform(centre) : centre, radius);
}

bool AIWorld::_b_smoke_blocks(const Vector3 &from, const Vector3 &to) const {
    if (!framed) {
        return smoke_blocks(from, to);
    }
    return smoke_blocks(frame_inv.xform(from), frame_inv.xform(to));
}

void AIWorld::_b_set_danger(int id, const AABB &box) {
    if (!framed) {
        set_danger(id, box);
        return;
    }
    set_danger(id, frame_inv.xform(box));
}

bool AIWorld::_b_in_danger(const Vector3 &point) const {
    return in_danger(framed ? frame_inv.xform(point) : point);
}

float AIWorld::_b_danger_distance(const Vector3 &point) const {
    return danger_distance(framed ? frame_inv.xform(point) : point);
}

bool AIWorld::_b_solid_at(const Vector3 &point) {
    return solid_at(framed ? frame_inv.xform(point) : point);
}

Vector2i AIWorld::_b_block_at(const Vector3 &point) {
    return block_at(framed ? frame_inv.xform(point) : point);
}

bool AIWorld::_b_ground_blocks(const Vector3 &from, const Vector3 &to) {
    if (!framed) {
        return ground_blocks(from, to);
    }
    return ground_blocks(frame_inv.xform(from), frame_inv.xform(to));
}

Vector3 AIWorld::ground_under(const Vector3 &point) {
    if (!framed) {
        return Vector3(point.x, ground_at(point.x, point.z), point.z);
    }
    const Vector3 l = frame_inv.xform(point);
    return frame.xform(Vector3(l.x, ground_at(l.x, l.z), l.z));
}

Vector3 AIWorld::top_over(const Vector3 &point) {
    const Vector3 l = to_region(point);
    const float top = top_at(l.x, l.z);
    if (!std::isfinite(top)) {
        return Vector3(INFINITY, INFINITY, INFINITY);
    }
    return to_world(Vector3(l.x, top, l.z));
}

void AIWorld::set_frame(const Transform3D &region_to_world) {
    frame = region_to_world;
    frame_inv = region_to_world.affine_inverse();
    framed = region_to_world != Transform3D();
    // The chunks' boxes are in the region: the next sync() puts them there.
    chunk_entries.clear();
    hash.clear();
    ground_cache.clear();
}

void AIWorld::set_ground_grid(const Vector2 &origin, float step, int size,
        const PackedFloat32Array &heights) {
    ground_cache.clear();
    if (size < 2 || step <= 0.0f || heights.size() < (int64_t)size * size) {
        grid_size = 0;
        grid_heights.clear();
        return;
    }
    grid_origin = origin;
    grid_step = step;
    grid_size = size;
    grid_heights.assign(heights.ptr(), heights.ptr() + (int64_t)size * size);
    float top = 0.0f;
    for (float h : grid_heights) {
        top = std::max(top, h);
    }
    // Outside: solid to well over anything inside, past any step or drop a
    // map allows -- a path never leaves the region.
    grid_wall = (int)std::ceil(top / brick::PLATE_M) + 256;
}

// The first plate of air over stud column (gx, gz): the grid read bilinearly
// at the stud's centre, as PlanetNavRegion.ground_at reads it.
int AIWorld::_grid_plate(int gx, int gz) const {
    const float fx = ((gx + 0.5f) * brick::STUD_M - grid_origin.x) / grid_step;
    const float fz = ((gz + 0.5f) * brick::STUD_M - grid_origin.y) / grid_step;
    const float last = (float)(grid_size - 1);
    if (!(fx >= 0.0f && fz >= 0.0f && fx <= last && fz <= last)) {
        return grid_wall;
    }
    const int i = std::min((int)fx, grid_size - 2);
    const int j = std::min((int)fz, grid_size - 2);
    const float sx = fx - (float)i;
    const float sz = fz - (float)j;
    const float *row0 = grid_heights.data() + (size_t)j * grid_size + i;
    const float *row1 = row0 + grid_size;
    const float a = row0[0] + (row0[1] - row0[0]) * sx;
    const float b = row1[0] + (row1[1] - row1[0]) * sx;
    const float h = a + (b - a) * sz;
    return std::max(0, (int)std::lround(h / brick::PLATE_M));
}

void AIWorld::set_world(const Ref<BrickWorld> &p_world) {
    world = p_world;
    chunk_entries.clear();
    hash.clear();
}

void AIWorld::sync() {
    chunk_entries.clear();
    hash.clear();
    if (world.is_null()) {
        return;
    }
    const Vector3 cs = brick::cell_size();
    BrickWorld *w = world.ptr();
    for (int id = 0; id < (int)w->chunks.size(); ++id) {
        if (!w->is_chunk_alive(id)) {
            continue;
        }
        const brick::Chunk &c = w->chunks[id];
        if (c.dims.x <= 0 || c.dims.y <= 0 || c.dims.z <= 0) {
            continue;
        }
        ChunkEntry e;
        e.chunk = id;
        e.dims = c.dims;
        const AABB local(Vector3(), Vector3(c.dims.x * cs.x, c.dims.y * cs.y, c.dims.z * cs.z));
        if (framed) {
            // Chunk -> region: the AI's whole world is the region's.
            const Transform3D xf = frame_inv * c.xform;
            e.inv = xf.affine_inverse();
            e.box = xf.xform(local);
        } else {
            e.inv = c.xform.affine_inverse();
            e.box = c.xform.xform(local);
        }
        const int index = (int)chunk_entries.size();
        chunk_entries.push_back(e);
        const int x0 = (int)std::floor(e.box.position.x / HASH_CELL);
        const int x1 = (int)std::floor((e.box.position.x + e.box.size.x) / HASH_CELL);
        const int z0 = (int)std::floor(e.box.position.z / HASH_CELL);
        const int z1 = (int)std::floor((e.box.position.z + e.box.size.z) / HASH_CELL);
        for (int x = x0; x <= x1; ++x) {
            for (int z = z0; z <= z1; ++z) {
                hash[key(x, z)].push_back(index);
            }
        }
    }
}

bool AIWorld::_segment_box(const Vector3 &a, const Vector3 &b, const AABB &box, float &t0,
        float &t1) {
    t0 = 0.0f;
    t1 = 1.0f;
    const Vector3 d = b - a;
    const Vector3 lo = box.position;
    const Vector3 hi = box.position + box.size;
    for (int axis = 0; axis < 3; ++axis) {
        const float o = a[axis];
        const float v = d[axis];
        if (std::fabs(v) < 1e-9f) {
            if (o < lo[axis] || o > hi[axis]) {
                return false;
            }
            continue;
        }
        float ta = (lo[axis] - o) / v;
        float tb = (hi[axis] - o) / v;
        if (ta > tb) {
            std::swap(ta, tb);
        }
        t0 = std::max(t0, ta);
        t1 = std::min(t1, tb);
        if (t0 > t1) {
            return false;
        }
    }
    return true;
}

void AIWorld::_walk_chunk(ChunkEntry &e, const Vector3 &from, const Vector3 &to, int hp_per_hit,
        Accum &acc) {
    const brick::Chunk &c = world->chunks[e.chunk];
    const Vector3 cs = brick::cell_size();
    // Into the chunk's frame, then into CELL units: every axis one cell per unit,
    // whatever the stud and plate pitch, so the DDA is the textbook one.
    const Vector3 la = e.inv.xform(from);
    const Vector3 lb = e.inv.xform(to);
    const Vector3 ga(la.x / cs.x, la.y / cs.y, la.z / cs.z);
    const Vector3 gb(lb.x / cs.x, lb.y / cs.y, lb.z / cs.z);
    float t0, t1;
    if (!_segment_box(ga, gb, AABB(Vector3(), Vector3(e.dims.x, e.dims.y, e.dims.z)), t0, t1)) {
        return;
    }
    chunks_walked++;
    const Vector3 d = gb - ga;
    const float world_len = from.distance_to(to);
    const float eps = 1e-5f;
    const Vector3 p = ga + d * (t0 + eps);
    Vector3i cell((int)std::floor(p.x), (int)std::floor(p.y), (int)std::floor(p.z));
    cell.x = std::clamp(cell.x, 0, e.dims.x - 1);
    cell.y = std::clamp(cell.y, 0, e.dims.y - 1);
    cell.z = std::clamp(cell.z, 0, e.dims.z - 1);

    int step[3];
    float t_max[3];
    float t_delta[3];
    for (int axis = 0; axis < 3; ++axis) {
        const float v = d[axis];
        if (v > 0.0f) {
            step[axis] = 1;
            t_max[axis] = ((float)(cell[axis] + 1) - ga[axis]) / v;
            t_delta[axis] = 1.0f / v;
        } else if (v < 0.0f) {
            step[axis] = -1;
            t_max[axis] = ((float)cell[axis] - ga[axis]) / v;
            t_delta[axis] = -1.0f / v;
        } else {
            step[axis] = 0;
            t_max[axis] = std::numeric_limits<float>::infinity();
            t_delta[axis] = std::numeric_limits<float>::infinity();
        }
    }

    seen.clear();
    float t_enter = t0;
    while (t_enter <= t1) {
        const float t_exit = std::min(std::min(t_max[0], t_max[1]), std::min(t_max[2], t1));
        cells_walked++;
        const int32_t bid = c.occupancy[c.index_of(cell)];
        if (bid >= 0) {
            const brick::Block &b = c.blocks[bid];
            if (b.alive && !b.decorative) {
                acc.solid_m += std::max(0.0f, t_exit - t_enter) * world_len;
                if (t_enter < acc.first_t) {
                    acc.first_t = t_enter;
                    acc.first_chunk = e.chunk;
                }
                if (std::find(seen.begin(), seen.end(), bid) == seen.end()) {
                    seen.push_back(bid);
                    acc.bricks++;
                    acc.hp += b.hp;
                    const int wear = wear_of(hp_per_hit, b.material);
                    if (wear > 0) {
                        acc.hits += (b.hp + wear - 1) / wear;
                    }
                }
            }
        }
        // Next cell along whichever boundary comes first.
        int axis = 0;
        if (t_max[1] < t_max[axis]) {
            axis = 1;
        }
        if (t_max[2] < t_max[axis]) {
            axis = 2;
        }
        if (t_max[axis] > t1) {
            break;
        }
        cell[axis] += step[axis];
        if (cell[axis] < 0 || cell[axis] >= e.dims[axis]) {
            break;
        }
        t_enter = t_max[axis];
        t_max[axis] += t_delta[axis];
    }
}

void AIWorld::_walk(const Vector3 &from, const Vector3 &to, int hp_per_hit, Accum &acc) {
    const uint64_t t_start = now_usec();
    queries++;
    query_stamp++;
    if (proxies_dirty) {
        _rebuild_proxies();
    }
    if (!chunk_entries.empty() || !proxy_list.empty()) {
        // The broad phase, walked along the segment's XZ shadow cell by cell (a
        // 2D DDA of its own), so a long sight line costs the cells it crosses,
        // not the area of its bounding box.
        const float ax = from.x / HASH_CELL;
        const float az = from.z / HASH_CELL;
        const float bx = to.x / HASH_CELL;
        const float bz = to.z / HASH_CELL;
        int cx = (int)std::floor(ax);
        int cz = (int)std::floor(az);
        const int ex = (int)std::floor(bx);
        const int ez = (int)std::floor(bz);
        const float dx = bx - ax;
        const float dz = bz - az;
        const int sx = dx > 0.0f ? 1 : (dx < 0.0f ? -1 : 0);
        const int sz = dz > 0.0f ? 1 : (dz < 0.0f ? -1 : 0);
        const float inf = std::numeric_limits<float>::infinity();
        float tmx = sx > 0 ? ((float)(cx + 1) - ax) / dx : (sx < 0 ? ((float)cx - ax) / dx : inf);
        float tmz = sz > 0 ? ((float)(cz + 1) - az) / dz : (sz < 0 ? ((float)cz - az) / dz : inf);
        const float tdx = sx != 0 ? std::fabs(1.0f / dx) : inf;
        const float tdz = sz != 0 ? std::fabs(1.0f / dz) : inf;
        const int max_steps = std::abs(ex - cx) + std::abs(ez - cz) + 1;
        for (int s = 0; s < max_steps; ++s) {
            auto pit = proxy_hash.find(key(cx, cz));
            if (pit != proxy_hash.end()) {
                for (int index : pit->second) {
                    if (proxy_stamp[index] == query_stamp) {
                        continue;
                    }
                    proxy_stamp[index] = query_stamp;
                    _walk_proxy(proxy_list[index], from, to, acc);
                }
            }
            auto it = world.is_valid() ? hash.find(key(cx, cz)) : hash.end();
            if (it != hash.end()) {
                for (int index : it->second) {
                    ChunkEntry &e = chunk_entries[index];
                    if (e.stamp == query_stamp) {
                        continue;
                    }
                    e.stamp = query_stamp;
                    float t0, t1;
                    if (_segment_box(from, to, e.box, t0, t1)) {
                        _walk_chunk(e, from, to, hp_per_hit, acc);
                    }
                }
            }
            if (cx == ex && cz == ez) {
                break;
            }
            if (tmx < tmz) {
                cx += sx;
                tmx += tdx;
            } else {
                cz += sz;
                tmz += tdz;
            }
        }
    }
    query_usec += now_usec() - t_start;
}

void AIWorld::_walk_proxy(Proxy &p, const Vector3 &from, const Vector3 &to, Accum &acc) {
    float t0, t1;
    if (!_segment_box(from, to, p.box, t0, t1)) {
        return;
    }
    const Vector3 la = p.inv.xform(from);
    const Vector3 lb = p.inv.xform(to);
    if (!_segment_box(la, lb, AABB(-p.half, p.half * 2.0f), t0, t1)) {
        return;
    }
    if (p.cover) {
        const auto inside = [&p](const Vector3 &l) {
            return std::fabs(l.x) <= p.half.x && std::fabs(l.y) <= p.half.y && std::fabs(l.z) <= p.half.z;
        };
        if (inside(la) || inside(lb)) {
            return;
        }
    }
    acc.proxy_bricks += (t1 - t0) * from.distance_to(to) * p.bricks_per_metre;
    if (t0 < acc.first_t) {
        acc.first_t = t0;
        acc.first_chunk = -1;
    }
}

void AIWorld::_rebuild_proxies() {
    proxies_dirty = false;
    proxy_list.clear();
    proxy_hash.clear();
    for (const auto &kv : proxies) {
        const int index = (int)proxy_list.size();
        proxy_list.push_back(kv.second);
        const AABB &box = kv.second.box;
        const int x0 = (int)std::floor(box.position.x / HASH_CELL);
        const int x1 = (int)std::floor((box.position.x + box.size.x) / HASH_CELL);
        const int z0 = (int)std::floor(box.position.z / HASH_CELL);
        const int z1 = (int)std::floor((box.position.z + box.size.z) / HASH_CELL);
        for (int x = x0; x <= x1; ++x) {
            for (int z = z0; z <= z1; ++z) {
                proxy_hash[key(x, z)].push_back(index);
            }
        }
    }
    proxy_stamp.assign(proxy_list.size(), 0);
}

Dictionary AIWorld::trace(const Vector3 &from, const Vector3 &to) {
    Accum acc;
    _walk(from, to, 0, acc);
    float t_ground = 2.0f;
    const bool ground = _terrain_hit(from, to, t_ground);
    Dictionary out;
    out["bricks"] = acc.bricks;
    out["hp"] = acc.hp;
    out["solid_m"] = acc.solid_m;
    out["proxy_bricks"] = acc.proxy_bricks;
    // The ground is a hit like a brick is, and the first of the two is THE hit.
    const float first = std::min(acc.first_t, t_ground);
    const bool hit = first <= 1.0f;
    out["hit"] = hit;
    out["point"] = hit ? from + (to - from) * first : to;
    out["chunk"] = ground && t_ground < acc.first_t ? -1 : acc.first_chunk;
    out["ground"] = ground;
    out["smoke"] = smoke_blocks(from, to);
    return out;
}

// What the ground counts as, in bricks: more than any wall, because no gun
// wears a hill away.
static constexpr int GROUND_BRICKS = 1000;

int AIWorld::bricks_between(const Vector3 &from, const Vector3 &to) {
    Accum acc;
    _walk(from, to, 0, acc);
    float t = 0.0f;
    const int ground = _terrain_hit(from, to, t) ? GROUND_BRICKS : 0;
    return acc.bricks + (int)std::ceil(acc.proxy_bricks - 1e-3f) + ground;
}

bool AIWorld::line_clear(const Vector3 &from, const Vector3 &to) {
    if (smoke_blocks(from, to)) {
        return false;
    }
    Accum acc;
    _walk(from, to, 0, acc);
    if (acc.bricks != 0 || acc.proxy_bricks > 1e-3f) {
        return false;
    }
    float t = 0.0f;
    return !_terrain_hit(from, to, t);
}

float AIWorld::cover_seconds(const Vector3 &from, const Vector3 &to, int hp_per_hit,
        float hits_per_second) {
    if (hits_per_second <= 0.0f || hp_per_hit <= 0) {
        return std::numeric_limits<float>::infinity();
    }
    float t = 0.0f;
    if (_terrain_hit(from, to, t)) {
        return std::numeric_limits<float>::infinity();
    }
    Accum acc;
    _walk(from, to, hp_per_hit, acc);
    // A proxy is bricks nobody has built: full hp, the plain material.
    const int proxy_wear = wear_of(hp_per_hit, 0);
    const float proxy_hits = acc.proxy_bricks * (float)((255 + proxy_wear - 1) / proxy_wear);
    return ((float)acc.hits + proxy_hits) / hits_per_second;
}

PackedFloat32Array AIWorld::cover_seconds_batch(const Vector3 &from, const PackedVector3Array &to,
        int hp_per_hit, float hits_per_second) {
    PackedFloat32Array out;
    out.resize(to.size());
    for (int i = 0; i < to.size(); ++i) {
        out.set(i, cover_seconds(from, to[i], hp_per_hit, hits_per_second));
    }
    return out;
}

void AIWorld::set_proxy(int id, const Transform3D &xform, const Vector3 &size,
        float bricks_per_metre) {
    Proxy p;
    p.id = id;
    p.xform = xform;
    p.inv = xform.affine_inverse();
    p.half = size * 0.5f;
    p.bricks_per_metre = bricks_per_metre;
    p.box = xform.xform(AABB(-p.half, size));
    proxies[id] = p;
    proxies_dirty = true;
}

void AIWorld::set_cover(int id, const Transform3D &xform, const Vector3 &size,
        float bricks_per_metre) {
    set_proxy(id, xform, size, bricks_per_metre);
    proxies[id].cover = true;
}

void AIWorld::remove_proxy(int id) {
    proxies.erase(id);
    proxies_dirty = true;
}

void AIWorld::clear_proxies() {
    proxies.clear();
    proxies_dirty = true;
}

void AIWorld::set_smoke(int id, const Vector3 &centre, float radius) {
    smoke[id] = Sphere{ centre, radius };
}

void AIWorld::remove_smoke(int id) {
    smoke.erase(id);
}

void AIWorld::clear_smoke() {
    smoke.clear();
}

bool AIWorld::smoke_blocks(const Vector3 &from, const Vector3 &to) const {
    const Vector3 d = to - from;
    const float len2 = d.length_squared();
    for (const auto &kv : smoke) {
        const Sphere &s = kv.second;
        float t = len2 > 0.0f ? (s.centre - from).dot(d) / len2 : 0.0f;
        t = std::clamp(t, 0.0f, 1.0f);
        if ((from + d * t).distance_squared_to(s.centre) <= s.radius * s.radius) {
            return true;
        }
    }
    return false;
}

void AIWorld::shift_origin(const Vector3 &offset) {
    if (framed) {
        // A planet's re-centre: the region moves with the scene, and inside it
        // nothing moves -- every box is the region's already.
        frame.origin += offset;
        frame_inv = frame.affine_inverse();
        chunk_entries.clear();
        hash.clear();
        return;
    }
    for (auto &kv : proxies) {
        Proxy &p = kv.second;
        p.xform.origin += offset;
        p.inv = p.xform.affine_inverse();
        p.box.position += offset;
    }
    proxies_dirty = true;
    for (auto &kv : smoke) {
        kv.second.centre += offset;
    }
    for (auto &kv : danger) {
        kv.second.position += offset;
    }
    const float sx = offset.x / brick::STUD_M;
    const float sz = offset.z / brick::STUD_M;
    const int dx = (int)std::lround(sx);
    const int dz = (int)std::lround(sz);
    if (std::abs(sx - (float)dx) > 1e-3f || std::abs(sz - (float)dz) > 1e-3f) {
        ERR_PRINT("AIWorld.shift_origin: X and Z are not whole studs; the ground will be off");
    }
    ground_dx += dx;
    ground_dz += dz;
    ground_cache.clear();
    // The chunks' entries are rebuilt from BrickWorld by the next sync().
    chunk_entries.clear();
    hash.clear();
}

void AIWorld::set_danger(int id, const AABB &box) {
    danger[id] = box;
}

void AIWorld::remove_danger(int id) {
    danger.erase(id);
}

void AIWorld::clear_danger() {
    danger.clear();
}

bool AIWorld::in_danger(const Vector3 &point) const {
    for (const auto &kv : danger) {
        if (kv.second.has_point(point)) {
            return true;
        }
    }
    return false;
}

float AIWorld::danger_distance(const Vector3 &point) const {
    float best = std::numeric_limits<float>::infinity();
    for (const auto &kv : danger) {
        const AABB &b = kv.second;
        const Vector3 lo = b.position;
        const Vector3 hi = b.position + b.size;
        const Vector3 q(std::clamp(point.x, lo.x, hi.x), std::clamp(point.y, lo.y, hi.y),
                std::clamp(point.z, lo.z, hi.z));
        best = std::min(best, q.distance_to(point));
    }
    return best;
}

Vector2i AIWorld::block_at(const Vector3 &p) {
    const int64_t k = key((int)std::floor(p.x / HASH_CELL), (int)std::floor(p.z / HASH_CELL));
    auto it = hash.find(k);
    if (it == hash.end() || !world.is_valid()) {
        return Vector2i(-1, -1);
    }
    const Vector3 cs = brick::cell_size();
    for (int index : it->second) {
        const ChunkEntry &e = chunk_entries[index];
        if (!e.box.has_point(p)) {
            continue;
        }
        const Vector3 l = e.inv.xform(p);
        const Vector3i cell((int)std::floor(l.x / cs.x), (int)std::floor(l.y / cs.y),
                (int)std::floor(l.z / cs.z));
        const brick::Chunk &c = world->chunks[e.chunk];
        if (!c.in_bounds(cell)) {
            continue;
        }
        const int32_t bid = c.occupancy[c.index_of(cell)];
        if (bid >= 0 && c.blocks[bid].alive) {
            return Vector2i(e.chunk, bid);
        }
    }
    return Vector2i(-1, -1);
}

bool AIWorld::solid_at(const Vector3 &p) {
    if (proxies_dirty) {
        _rebuild_proxies();
    }
    if (terrain_ground && p.y < ground_at(p.x, p.z)) {
        return true;
    }
    const int64_t k = key((int)std::floor(p.x / HASH_CELL), (int)std::floor(p.z / HASH_CELL));
    auto it = hash.find(k);
    if (it != hash.end() && world.is_valid()) {
        const Vector3 cs = brick::cell_size();
        for (int index : it->second) {
            const ChunkEntry &e = chunk_entries[index];
            if (!e.box.has_point(p)) {
                continue;
            }
            const Vector3 l = e.inv.xform(p);
            const Vector3i cell((int)std::floor(l.x / cs.x), (int)std::floor(l.y / cs.y),
                    (int)std::floor(l.z / cs.z));
            const brick::Chunk &c = world->chunks[e.chunk];
            if (!c.in_bounds(cell)) {
                continue;
            }
            const int32_t bid = c.occupancy[c.index_of(cell)];
            if (bid >= 0 && c.blocks[bid].alive) {
                return true;
            }
        }
    }
    auto pit = proxy_hash.find(k);
    if (pit != proxy_hash.end()) {
        for (int index : pit->second) {
            const Proxy &pr = proxy_list[index];
            if (pr.cover || !pr.box.has_point(p)) {
                continue;
            }
            const Vector3 l = pr.inv.xform(p);
            if (std::fabs(l.x) <= pr.half.x && std::fabs(l.y) <= pr.half.y
                    && std::fabs(l.z) <= pr.half.z) {
                return true;
            }
        }
    }
    return false;
}

void AIWorld::column_solid(float x, float z, std::vector<char> &out) {
    std::fill(out.begin(), out.end(), 0);
    if (out.empty()) {
        return;
    }
    if (proxies_dirty) {
        _rebuild_proxies();
    }
    const int n = (int)out.size();
    const float plate = brick::PLATE_M;
    if (terrain_ground) {
        // Under the ground is solid, whatever stands on it.
        const int g = std::min(n, _ground_plate((int)std::floor(x / brick::STUD_M),
                (int)std::floor(z / brick::STUD_M)));
        std::fill(out.begin(), out.begin() + std::max(0, g), (char)1);
    }
    const int64_t k = key((int)std::floor(x / HASH_CELL), (int)std::floor(z / HASH_CELL));
    auto it = hash.find(k);
    if (it != hash.end() && world.is_valid()) {
        const Vector3 cs = brick::cell_size();
        for (int index : it->second) {
            const ChunkEntry &e = chunk_entries[index];
            const AABB &b = e.box;
            if (x < b.position.x || x > b.position.x + b.size.x || z < b.position.z
                    || z > b.position.z + b.size.z) {
                continue;
            }
            const brick::Chunk &c = world->chunks[e.chunk];
            const int y0 = std::max(0, (int)std::floor(b.position.y / plate));
            const int y1 = std::min(n - 1, (int)std::ceil((b.position.y + b.size.y) / plate));
            const Basis &basis = e.inv.basis;
            const bool upright = basis.get_column(1).is_equal_approx(Vector3(0, 1, 0))
                    && std::fabs(basis.get_column(0).y) < 1e-5f && std::fabs(basis.get_column(2).y) < 1e-5f;
            if (upright) {
                // Y in the world is Y in the chunk: fix the cell's x and z once
                // and walk its occupancy straight up.
                const Vector3 l0 = e.inv.xform(Vector3(x, 0.0f, z));
                const int lx = (int)std::floor(l0.x / cs.x);
                const int lz = (int)std::floor(l0.z / cs.z);
                if (lx < 0 || lz < 0 || lx >= c.dims.x || lz >= c.dims.z) {
                    continue;
                }
                for (int y = y0; y <= y1; ++y) {
                    const int ly = (int)std::floor((l0.y + (y + 0.5f) * plate) / cs.y);
                    if (ly < 0 || ly >= c.dims.y) {
                        continue;
                    }
                    const int32_t bid = c.occupancy[c.index_of(Vector3i(lx, ly, lz))];
                    if (bid >= 0 && c.blocks[bid].alive) {
                        out[y] = 1;
                    }
                }
            } else {
                for (int y = y0; y <= y1; ++y) {
                    if (out[y]) {
                        continue;
                    }
                    const Vector3 l = e.inv.xform(Vector3(x, (y + 0.5f) * plate, z));
                    const Vector3i cell((int)std::floor(l.x / cs.x), (int)std::floor(l.y / cs.y),
                            (int)std::floor(l.z / cs.z));
                    if (!c.in_bounds(cell)) {
                        continue;
                    }
                    const int32_t bid = c.occupancy[c.index_of(cell)];
                    if (bid >= 0 && c.blocks[bid].alive) {
                        out[y] = 1;
                    }
                }
            }
        }
    }
    auto pit = proxy_hash.find(k);
    if (pit != proxy_hash.end()) {
        for (int index : pit->second) {
            const Proxy &pr = proxy_list[index];
            const AABB &b = pr.box;
            if (pr.cover) {
                continue;
            }
            if (x < b.position.x || x > b.position.x + b.size.x || z < b.position.z
                    || z > b.position.z + b.size.z) {
                continue;
            }
            const int y0 = std::max(0, (int)std::floor(b.position.y / plate));
            const int y1 = std::min(n - 1, (int)std::ceil((b.position.y + b.size.y) / plate));
            for (int y = y0; y <= y1; ++y) {
                const Vector3 l = pr.inv.xform(Vector3(x, (y + 0.5f) * plate, z));
                if (std::fabs(l.x) <= pr.half.x && std::fabs(l.y) <= pr.half.y
                        && std::fabs(l.z) <= pr.half.z) {
                    out[y] = 1;
                }
            }
        }
    }
}

float AIWorld::top_at(float x, float z) {
    if (proxies_dirty) {
        _rebuild_proxies();
    }
    float top = -std::numeric_limits<float>::infinity();
    const int64_t k = key((int)std::floor(x / HASH_CELL), (int)std::floor(z / HASH_CELL));
    auto it = hash.find(k);
    if (it != hash.end()) {
        for (int index : it->second) {
            const AABB &b = chunk_entries[index].box;
            if (x >= b.position.x && x <= b.position.x + b.size.x && z >= b.position.z
                    && z <= b.position.z + b.size.z) {
                top = std::max(top, b.position.y + b.size.y);
            }
        }
    }
    auto pit = proxy_hash.find(k);
    if (pit != proxy_hash.end()) {
        for (int index : pit->second) {
            const AABB &b = proxy_list[index].box;
            if (proxy_list[index].cover) {
                continue;
            }
            if (x >= b.position.x && x <= b.position.x + b.size.x && z >= b.position.z
                    && z <= b.position.z + b.size.z) {
                top = std::max(top, b.position.y + b.size.y);
            }
        }
    }
    if (terrain_ground) {
        top = std::max(top, ground_at(x, z));
    }
    return top;
}

bool AIWorld::ground_blocks(const Vector3 &from, const Vector3 &to) {
    float t = 0.0f;
    return _terrain_hit(from, to, t);
}

void AIWorld::set_terrain_ground(bool on) {
    terrain_ground = on;
    ground_cache.clear();
}

int AIWorld::_ground_plate(int gx, int gz) {
    const int64_t k = key(gx, gz);
    auto it = ground_cache.find(k);
    if (it != ground_cache.end()) {
        return it->second;
    }
    if (ground_cache.size() >= (1u << 20)) {
        ground_cache.clear();
    }
    // The first plate of AIR: `surface_plate` is the top solid one. Never below
    // plate 0 -- navigation counts plates up from there, and a seabed below
    // the city's datum is somewhere nobody walks anyway.
    const int g = grid_size > 0
            ? _grid_plate(gx, gz)
            : std::max(0, BrickTerrain::surface_plate(gx - ground_dx, gz - ground_dz) + 1);
    ground_cache.emplace(k, g);
    return g;
}

float AIWorld::ground_at(float x, float z) {
    if (!terrain_ground) {
        return 0.0f;
    }
    return (float)_ground_plate((int)std::floor(x / brick::STUD_M),
                   (int)std::floor(z / brick::STUD_M))
            * brick::PLATE_M;
}

// A march at one stud a step over the segment's ground shadow. A crest is
// wider than a stud, so nothing a figure could hide behind slips between two
// samples. Half a brick of slack, so a line that starts or ends at a figure's
// feet on a slope is not blocked by the slope it is standing on.
bool AIWorld::_terrain_hit(const Vector3 &from, const Vector3 &to, float &t) {
    if (!terrain_ground) {
        return false;
    }
    const Vector3 d = to - from;
    const float run = std::sqrt(d.x * d.x + d.z * d.z);
    const int n = std::max(1, (int)std::ceil(run / brick::STUD_M));
    const float slack = brick::PLATE_M * 1.5f;
    for (int i = 0; i <= n; ++i) {
        const float s = (float)i / (float)n;
        const Vector3 p = from + d * s;
        if (p.y < ground_at(p.x, p.z) - slack) {
            t = s;
            return true;
        }
    }
    return false;
}

Dictionary AIWorld::get_stats() const {
    Dictionary d;
    d["queries"] = (int64_t)queries;
    d["query_usec"] = (int64_t)query_usec;
    d["mean_usec"] = queries > 0 ? (double)query_usec / (double)queries : 0.0;
    d["cells_walked"] = (int64_t)cells_walked;
    d["chunks_walked"] = (int64_t)chunks_walked;
    d["indexed_chunks"] = (int)chunk_entries.size();
    d["hash_cells"] = (int)hash.size();
    d["proxies"] = (int)proxies.size();
    d["smoke"] = (int)smoke.size();
    d["danger"] = (int)danger.size();
    return d;
}

void AIWorld::reset_stats() {
    queries = 0;
    query_usec = 0;
    cells_walked = 0;
    chunks_walked = 0;
}
