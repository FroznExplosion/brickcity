#include "ai_world.h"

#include "../brick_grid.h"

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
    ClassDB::bind_method(D_METHOD("trace", "from", "to"), &AIWorld::trace);
    ClassDB::bind_method(D_METHOD("bricks_between", "from", "to"), &AIWorld::bricks_between);
    ClassDB::bind_method(D_METHOD("line_clear", "from", "to"), &AIWorld::line_clear);
    ClassDB::bind_method(D_METHOD("cover_seconds", "from", "to", "hp_per_hit", "hits_per_second"),
            &AIWorld::cover_seconds);
    ClassDB::bind_method(D_METHOD("cover_seconds_batch", "from", "to", "hp_per_hit",
                                 "hits_per_second"),
            &AIWorld::cover_seconds_batch);
    ClassDB::bind_method(D_METHOD("set_proxy", "id", "xform", "size", "bricks_per_metre"),
            &AIWorld::set_proxy);
    ClassDB::bind_method(D_METHOD("remove_proxy", "id"), &AIWorld::remove_proxy);
    ClassDB::bind_method(D_METHOD("clear_proxies"), &AIWorld::clear_proxies);
    ClassDB::bind_method(D_METHOD("get_proxy_count"), &AIWorld::get_proxy_count);
    ClassDB::bind_method(D_METHOD("set_smoke", "id", "centre", "radius"), &AIWorld::set_smoke);
    ClassDB::bind_method(D_METHOD("remove_smoke", "id"), &AIWorld::remove_smoke);
    ClassDB::bind_method(D_METHOD("clear_smoke"), &AIWorld::clear_smoke);
    ClassDB::bind_method(D_METHOD("smoke_blocks", "from", "to"), &AIWorld::smoke_blocks);
    ClassDB::bind_method(D_METHOD("set_danger", "id", "box"), &AIWorld::set_danger);
    ClassDB::bind_method(D_METHOD("remove_danger", "id"), &AIWorld::remove_danger);
    ClassDB::bind_method(D_METHOD("clear_danger"), &AIWorld::clear_danger);
    ClassDB::bind_method(D_METHOD("in_danger", "point"), &AIWorld::in_danger);
    ClassDB::bind_method(D_METHOD("danger_distance", "point"), &AIWorld::danger_distance);
    ClassDB::bind_method(D_METHOD("get_stats"), &AIWorld::get_stats);
    ClassDB::bind_method(D_METHOD("reset_stats"), &AIWorld::reset_stats);
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
        e.inv = c.xform.affine_inverse();
        const AABB local(Vector3(), Vector3(c.dims.x * cs.x, c.dims.y * cs.y, c.dims.z * cs.z));
        e.box = c.xform.xform(local);
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
    Dictionary out;
    out["bricks"] = acc.bricks;
    out["hp"] = acc.hp;
    out["solid_m"] = acc.solid_m;
    out["proxy_bricks"] = acc.proxy_bricks;
    const bool hit = acc.first_t <= 1.0f;
    out["hit"] = hit;
    out["point"] = hit ? from + (to - from) * acc.first_t : to;
    out["chunk"] = acc.first_chunk;
    out["smoke"] = smoke_blocks(from, to);
    return out;
}

int AIWorld::bricks_between(const Vector3 &from, const Vector3 &to) {
    Accum acc;
    _walk(from, to, 0, acc);
    return acc.bricks + (int)std::ceil(acc.proxy_bricks - 1e-3f);
}

bool AIWorld::line_clear(const Vector3 &from, const Vector3 &to) {
    if (smoke_blocks(from, to)) {
        return false;
    }
    Accum acc;
    _walk(from, to, 0, acc);
    return acc.bricks == 0 && acc.proxy_bricks <= 1e-3f;
}

float AIWorld::cover_seconds(const Vector3 &from, const Vector3 &to, int hp_per_hit,
        float hits_per_second) {
    if (hits_per_second <= 0.0f || hp_per_hit <= 0) {
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
