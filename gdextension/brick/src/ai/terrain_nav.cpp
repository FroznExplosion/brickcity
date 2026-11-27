#include "terrain_nav.h"

#include "../brick_grid.h"

#include <godot_cpp/core/class_db.hpp>

#include <algorithm>
#include <climits>
#include <cmath>
#include <cstring>
#include <queue>
#include <unordered_set>

// brick_terrain.cpp: one column of the field, 1 solid / 0 air.
void terrain_column_solid(int x, int z, int y0, int n, uint8_t *out);
// brick_fluid.cpp: courses of a column, 0 dry / 1 water / 2 lava.
void fluid_column(int x, int z, int b0, int nb, uint8_t *out);
// brick_fluid.cpp: the log's changed cells since a write count.
bool fluid_changes_since(int64_t since, int64_t &now, std::vector<int> &out);

namespace {

constexpr int NO_LAND = INT32_MIN;
constexpr int PLATES_PER_COURSE = 3;
const int DIRS[8][2] = { { 1, 0 }, { -1, 0 }, { 0, 1 }, { 0, -1 }, { 1, 1 }, { 1, -1 }, { -1, 1 }, { -1, -1 } };

inline int fdiv(int a, int b) {
    return (a >= 0) ? a / b : -((-a + b - 1) / b);
}

inline int unpack21(int64_t v) {
    v &= 0x1FFFFF;
    if (v & 0x100000) {
        v -= 0x200000;
    }
    return (int)v;
}

/// A body is never in solid or lava.
inline bool blocks(uint8_t c) {
    return c == TerrainNav::SOLID || c == TerrainNav::LAVA;
}

} // namespace

void TerrainNav::_bind_methods() {
    ClassDB::bind_method(D_METHOD("find_path", "from", "to", "body", "max_nodes"), &TerrainNav::find_path);
    ClassDB::bind_method(D_METHOD("build_field", "goal", "radius", "body", "max_nodes"), &TerrainNav::build_field);
    ClassDB::bind_method(D_METHOD("field_next", "id", "from"), &TerrainNav::field_next);
    ClassDB::bind_method(D_METHOD("field_cost", "id", "from"), &TerrainNav::field_cost);
    ClassDB::bind_method(D_METHOD("field_size", "id"), &TerrainNav::field_size);
    ClassDB::bind_method(D_METHOD("release_field", "id"), &TerrainNav::release_field);
    ClassDB::bind_method(D_METHOD("free_reach", "from", "body", "reach", "max_nodes"), &TerrainNav::free_reach);
    ClassDB::bind_method(D_METHOD("line_clear", "from", "to"), &TerrainNav::line_clear);
    ClassDB::bind_method(D_METHOD("stand_near", "at", "body", "radius"), &TerrainNav::stand_near);
    ClassDB::bind_method(D_METHOD("fits", "at", "body"), &TerrainNav::fits);
    ClassDB::bind_method(D_METHOD("code_at", "at"), &TerrainNav::code_at);
    ClassDB::bind_method(D_METHOD("invalidate_box", "lo", "hi"), &TerrainNav::invalidate_box);
    ClassDB::bind_method(D_METHOD("clear"), &TerrainNav::clear);
    ClassDB::bind_method(D_METHOD("set_fluid", "on"), &TerrainNav::set_fluid);
    ClassDB::bind_method(D_METHOD("set_fluid_version", "v"), &TerrainNav::set_fluid_version);
    ClassDB::bind_method(D_METHOD("update_fluid"), &TerrainNav::update_fluid);
    ClassDB::bind_method(D_METHOD("set_obstacles", "id", "lo_hi"), &TerrainNav::set_obstacles);
    ClassDB::bind_method(D_METHOD("remove_obstacles", "id"), &TerrainNav::remove_obstacles);
    ClassDB::bind_method(D_METHOD("obstacle_count"), &TerrainNav::obstacle_count);
    ClassDB::bind_method(D_METHOD("get_stats"), &TerrainNav::get_stats);
}

// --- sections ---------------------------------------------------------------

const TerrainNav::Section *TerrainNav::Reader::_at(int sx, int sy, int sz) {
    const int64_t k = _key(sx, sy, sz);
    if (k != key || sec == nullptr) {
        const int slot = (int)(((uint64_t)k * 0x9E3779B97F4A7C15ull) >> 59) & (SLOTS - 1);
        if (keys[slot] != k) {
            keys[slot] = k;
            held[slot] = nav->_section(sx, sy, sz);
        }
        key = k;
        sec = held[slot].get();
    }
    return sec;
}

uint8_t TerrainNav::Reader::code(int x, int y, int z) {
    const int sx = fdiv(x, SX), sy = fdiv(y, SY), sz = fdiv(z, SX);
    const Section *s = _at(sx, sy, sz);
    const int lx = x - sx * SX, ly = y - sy * SY, lz = z - sz * SX;
    return s->cells[(lz * SX + lx) * SY + ly];
}

void TerrainNav::Reader::column(int x, int z, int y0, int n, uint8_t *out) {
    const int sx = fdiv(x, SX), sz = fdiv(z, SX);
    const int lx = x - sx * SX, lz = z - sz * SX;
    int y = y0;
    while (n > 0) {
        const int sy = fdiv(y, SY);
        const int ly = y - sy * SY;
        const int take = std::min(n, SY - ly);
        const Section *s = _at(sx, sy, sz);
        std::memcpy(out, &s->cells[(lz * SX + lx) * SY + ly], (size_t)take);
        out += take;
        y += take;
        n -= take;
    }
}

void TerrainNav::_fill_fluid(Section &s, int sx, int sy, int sz) {
    std::memcpy(s.cells, s.solid, sizeof(s.cells));
    s.fver = fluid_ver.load();
    if (!fluid_on.load()) {
        return;
    }
    const int x0 = sx * SX, y0 = sy * SY, z0 = sz * SX;
    const int b0 = fdiv(y0, PLATES_PER_COURSE);
    const int b1 = fdiv(y0 + SY - 1, PLATES_PER_COURSE);
    const int nb = b1 - b0 + 1;
    uint8_t f[32];
    for (int lz = 0; lz < SX; ++lz) {
        for (int lx = 0; lx < SX; ++lx) {
            fluid_column(x0 + lx, z0 + lz, b0, nb, f);
            uint8_t *col = &s.cells[(lz * SX + lx) * SY];
            for (int ly = 0; ly < SY; ++ly) {
                if (col[ly] != AIR) {
                    continue;
                }
                const uint8_t w = f[fdiv(y0 + ly, PLATES_PER_COURSE) - b0];
                if (w == 1) {
                    col[ly] = WATER;
                } else if (w == 2) {
                    col[ly] = LAVA;
                }
            }
        }
    }
    fluid_refreshes.fetch_add(1, std::memory_order_relaxed);
}

std::shared_ptr<const TerrainNav::Section> TerrainNav::_section(int sx, int sy, int sz) {
    const int64_t k = _key(sx, sy, sz);
    std::shared_ptr<const Section> old;
    {
        std::lock_guard<std::mutex> lk(sec_lock);
        auto it = sections.find(k);
        if (it != sections.end()) {
            auto d = fluid_dirty.find(k);
            if (it->second->fver == fluid_ver.load() && d == fluid_dirty.end()) {
                return it->second;
            }
            if (d != fluid_dirty.end()) {
                fluid_dirty.erase(d);
            }
            old = it->second;   // its fluid is stale: read again below
        }
    }
    // Made outside the lock: two searches may make the same one, the last kept.
    auto s = std::make_shared<Section>();
    const int x0 = sx * SX, y0 = sy * SY, z0 = sz * SX;
    if (old) {
        std::memcpy(s->solid, old->solid, sizeof(s->solid));
    } else {
        for (int lz = 0; lz < SX; ++lz) {
            for (int lx = 0; lx < SX; ++lx) {
                terrain_column_solid(x0 + lx, z0 + lz, y0, SY, &s->solid[(lz * SX + lx) * SY]);
            }
        }
        // Trunks, shut doors and the like over this section.
        std::lock_guard<std::mutex> ol(ob_lock);
        auto it = ob_index.find(_key(sx, 0, sz));
        if (it != ob_index.end()) {
            for (const OBox &b : it->second) {
                for (int z = std::max(b.z0, z0); z <= std::min(b.z1, z0 + SX - 1); ++z) {
                    for (int x = std::max(b.x0, x0); x <= std::min(b.x1, x0 + SX - 1); ++x) {
                        for (int y = std::max(b.y0, y0); y <= std::min(b.y1, y0 + SY - 1); ++y) {
                            s->solid[((z - z0) * SX + (x - x0)) * SY + (y - y0)] = 1;
                        }
                    }
                }
            }
        }
        sections_made.fetch_add(1, std::memory_order_relaxed);
    }
    _fill_fluid(*s, sx, sy, sz);
    std::lock_guard<std::mutex> lk(sec_lock);
    if ((int)sections.size() >= MAX_SECTIONS) {
        sections.clear();
    }
    sections[k] = s;
    return s;
}

void TerrainNav::invalidate_box(const Vector3i &lo, const Vector3i &hi) {
    const int sx0 = fdiv(std::min(lo.x, hi.x), SX), sx1 = fdiv(std::max(lo.x, hi.x), SX);
    const int sy0 = fdiv(std::min(lo.y, hi.y), SY), sy1 = fdiv(std::max(lo.y, hi.y), SY);
    const int sz0 = fdiv(std::min(lo.z, hi.z), SX), sz1 = fdiv(std::max(lo.z, hi.z), SX);
    std::lock_guard<std::mutex> lk(sec_lock);
    if ((int64_t)(sx1 - sx0 + 1) * (sy1 - sy0 + 1) * (sz1 - sz0 + 1) > (int64_t)sections.size()) {
        for (auto it = sections.begin(); it != sections.end();) {
            int x, y, z;
            _unkey(it->first, x, y, z);
            if (x >= sx0 && x <= sx1 && y >= sy0 && y <= sy1 && z >= sz0 && z <= sz1) {
                it = sections.erase(it);
            } else {
                ++it;
            }
        }
        return;
    }
    for (int x = sx0; x <= sx1; ++x) {
        for (int y = sy0; y <= sy1; ++y) {
            for (int z = sz0; z <= sz1; ++z) {
                sections.erase(_key(x, y, z));
            }
        }
    }
}

void TerrainNav::clear() {
    std::lock_guard<std::mutex> lk(sec_lock);
    sections.clear();
}

void TerrainNav::set_fluid(bool on) {
    fluid_on.store(on);
    fluid_ver.fetch_add(1);
}

int TerrainNav::update_fluid() {
    if (!fluid_on.load()) {
        return 0;
    }
    std::vector<int> cells;
    int64_t now = 0;
    const bool ok = fluid_changes_since(fluid_seen, now, cells);
    if (fluid_seen < 0 || !ok) {
        fluid_seen = now;
        if (!ok) {
            fluid_ver.fetch_add(1);   // too far back: every section reads again
        }
        return -1;
    }
    fluid_seen = now;
    std::lock_guard<std::mutex> lk(sec_lock);
    for (size_t i = 0; i + 2 < cells.size(); i += 3) {
        const int x = cells[i], b = cells[i + 1], z = cells[i + 2];
        for (int yp = b * PLATES_PER_COURSE; yp < (b + 1) * PLATES_PER_COURSE; yp += SY) {
            const int64_t k = _key(fdiv(x, SX), fdiv(yp, SY), fdiv(z, SX));
            if (sections.count(k)) {
                fluid_dirty.insert(k);
            }
        }
        // A course can straddle two sections in y.
        const int64_t k2 = _key(fdiv(x, SX), fdiv((b + 1) * PLATES_PER_COURSE - 1, SY), fdiv(z, SX));
        if (sections.count(k2)) {
            fluid_dirty.insert(k2);
        }
    }
    return (int)(cells.size() / 3);
}

void TerrainNav::set_fluid_version(int64_t v) {
    // Kept apart from set_fluid's bumps: a version only ever goes forward.
    const int64_t want = v * 2 + 1000000;
    if (fluid_ver.load() != want) {
        fluid_ver.store(want);
    }
}

void TerrainNav::_rebuild_obstacle_index() {
    ob_index.clear();
    for (const auto &g : ob_groups) {
        for (const OBox &b : g.second) {
            for (int sz = fdiv(b.z0, SX); sz <= fdiv(b.z1, SX); ++sz) {
                for (int sx = fdiv(b.x0, SX); sx <= fdiv(b.x1, SX); ++sx) {
                    ob_index[_key(sx, 0, sz)].push_back(b);
                }
            }
        }
    }
}

void TerrainNav::_invalidate_boxes(const std::vector<OBox> &boxes) {
    for (const OBox &b : boxes) {
        invalidate_box(Vector3i(b.x0, b.y0, b.z0), Vector3i(b.x1, b.y1, b.z1));
    }
}

void TerrainNav::set_obstacles(int id, const PackedVector3Array &lo_hi) {
    std::vector<OBox> boxes;
    for (int64_t i = 0; i + 1 < lo_hi.size(); i += 2) {
        const Vector3 a = lo_hi[i], b = lo_hi[i + 1];
        boxes.push_back({ (int)std::min(a.x, b.x), (int)std::min(a.y, b.y), (int)std::min(a.z, b.z),
                (int)std::max(a.x, b.x), (int)std::max(a.y, b.y), (int)std::max(a.z, b.z) });
    }
    std::vector<OBox> old;
    {
        std::lock_guard<std::mutex> ol(ob_lock);
        auto it = ob_groups.find(id);
        if (it != ob_groups.end()) {
            old = it->second;
        }
        ob_groups[id] = boxes;
        _rebuild_obstacle_index();
    }
    _invalidate_boxes(old);
    _invalidate_boxes(boxes);
}

void TerrainNav::remove_obstacles(int id) {
    std::vector<OBox> old;
    {
        std::lock_guard<std::mutex> ol(ob_lock);
        auto it = ob_groups.find(id);
        if (it == ob_groups.end()) {
            return;
        }
        old = it->second;
        ob_groups.erase(it);
        _rebuild_obstacle_index();
    }
    _invalidate_boxes(old);
}

int TerrainNav::obstacle_count() {
    std::lock_guard<std::mutex> ol(ob_lock);
    int n = 0;
    for (const auto &g : ob_groups) {
        n += (int)g.second.size();
    }
    return n;
}

Dictionary TerrainNav::get_stats() {
    Dictionary d;
    {
        std::lock_guard<std::mutex> lk(sec_lock);
        d["sections"] = (int64_t)sections.size();
    }
    {
        std::lock_guard<std::mutex> lk(field_lock);
        d["fields"] = (int64_t)fields.size();
    }
    d["sections_made"] = (int64_t)sections_made.load();
    d["fluid_refreshes"] = (int64_t)fluid_refreshes.load();
    d["obstacles"] = obstacle_count();
    return d;
}

// --- nodes and moves --------------------------------------------------------

TerrainNav::Body TerrainNav::_body(const Vector4i &v) {
    Body b;
    b.w = std::clamp(v.x, 1, 6);
    b.h = std::clamp(v.y, 1, 40);
    b.up = std::clamp(v.z, 0, 24);
    b.drop = std::clamp(v.w, 0, 60);
    return b;
}

int64_t TerrainNav::_key(int x, int y, int z) {
    return ((int64_t)(x & 0x1FFFFF) << 42) | ((int64_t)(y & 0x1FFFFF) << 21) | (int64_t)(z & 0x1FFFFF);
}

void TerrainNav::_unkey(int64_t k, int &x, int &y, int &z) {
    x = unpack21(k >> 42);
    y = unpack21(k >> 21);
    z = unpack21(k);
}

void TerrainNav::_snap(const Vector3 &p, const Body &b, int &x, int &y, int &z) {
    x = (int)std::floor(p.x / brick::STUD_M - b.w * 0.5f + 0.5f);
    z = (int)std::floor(p.z / brick::STUD_M - b.w * 0.5f + 0.5f);
    y = (int)std::floor((p.y + 0.02f) / brick::PLATE_M) - 1;
}

Vector3 TerrainNav::_feet(int x, int y, int z, const Body &b) {
    return Vector3((x + b.w * 0.5f) * brick::STUD_M, (y + 1) * brick::PLATE_M, (z + b.w * 0.5f) * brick::STUD_M);
}

bool TerrainNav::_fit(Reader &r, int x, int y, int z, const Body &b) {
    bool support = false;
    for (int cz = z; cz < z + b.w; ++cz) {
        for (int cx = x; cx < x + b.w; ++cx) {
            for (int yy = y + 1; yy <= y + b.h; ++yy) {
                if (blocks(r.code(cx, yy, cz))) {
                    return false;
                }
            }
            if (r.code(cx, y + b.h, cz) == WATER) {
                return false;   // the head under water
            }
            if (!support && r.solid(cx, y, cz)) {
                support = true;
            }
        }
    }
    return support;
}

bool TerrainNav::_find_node(Reader &r, int &x, int &y, int &z, const Body &b, int dn, int upr) {
    static const int OFF[9][2] = { { 0, 0 }, { 1, 0 }, { -1, 0 }, { 0, 1 }, { 0, -1 }, { 1, 1 }, { -1, -1 }, { 1, -1 }, { -1, 1 } };
    for (const auto &o : OFF) {
        // Nearest height first: the plate itself, then one up, one down, ...
        for (int i = 0; i <= std::max(dn, upr) * 2; ++i) {
            const int d = (i & 1) ? (i + 1) / 2 : -(i / 2);
            if (d > upr || -d > dn) {
                continue;
            }
            if (_fit(r, x + o[0], y + d, z + o[1], b)) {
                x += o[0];
                z += o[1];
                y += d;
                return true;
            }
        }
    }
    return false;
}

int TerrainNav::_land(Reader &r, int x, int y, int z, int nx, int nz, const Body &b) {
    // One copy of each column over everything the move can touch: from the
    // deepest drop to the head over the highest step.
    const int bot = y - b.drop, top = y + b.up;
    const int n = top + b.h - bot + 1;
    uint8_t buf[6 * 6][128];
    const int nn = std::min(n, 128);
    int support = NO_LAND;
    int ci = 0;
    for (int cz = nz; cz < nz + b.w; ++cz) {
        for (int cx = nx; cx < nx + b.w; ++cx, ++ci) {
            r.column(cx, cz, bot, nn, buf[ci]);
            for (int i = top - bot; i >= 0 && bot + i > support; --i) {
                if (buf[ci][i] == SOLID) {
                    support = bot + i;
                    break;
                }
                if (buf[ci][i] == LAVA) {
                    break;   // under lava is never where it lands
                }
            }
        }
    }
    if (support == NO_LAND) {
        return NO_LAND;   // a drop deeper than it takes
    }
    // Room for the body over the landing, up to where its head was if it drops.
    const int head = std::max(y, support) + b.h;
    for (int c = 0; c < ci; ++c) {
        for (int yy = support + 1; yy <= head; ++yy) {
            const int i = yy - bot;
            const uint8_t v = i < nn ? buf[c][i] : r.code(nx + c % b.w, yy, nz + c / b.w);
            if (blocks(v)) {
                return NO_LAND;
            }
        }
        const int hi = support + b.h - bot;
        if ((hi < nn ? buf[c][hi] : r.code(nx + c % b.w, support + b.h, nz + c / b.w)) == WATER) {
            return NO_LAND;   // the head under water
        }
    }
    // Stepping up: room over where it stands for the head to rise.
    if (support > y) {
        for (int cz = z; cz < z + b.w; ++cz) {
            for (int cx = x; cx < x + b.w; ++cx) {
                for (int yy = y + b.h + 1; yy <= support + b.h; ++yy) {
                    if (blocks(r.code(cx, yy, cz))) {
                        return NO_LAND;
                    }
                }
            }
        }
    }
    return support;
}

int TerrainNav::_move(Reader &r, int x, int y, int z, int dx, int dz, const Body &b) {
    if (dx != 0 && dz != 0) {
        if (_land(r, x, y, z, x + dx, z, b) == NO_LAND || _land(r, x, y, z, x, z + dz, b) == NO_LAND) {
            return NO_LAND;
        }
    }
    return _land(r, x, y, z, x + dx, z + dz, b);
}

bool TerrainNav::_wet_feet(Reader &r, int x, int y, int z, const Body &b) {
    for (int cz = z; cz < z + b.w; ++cz) {
        for (int cx = x; cx < x + b.w; ++cx) {
            if (r.code(cx, y + 1, cz) == WATER) {
                return true;
            }
        }
    }
    return false;
}

float TerrainNav::_edge_cost(Reader &r, int x, int z, int dx, int dz, int y0, int y1, const Body &b) {
    float c = (dx != 0 && dz != 0) ? 1.41421f : 1.0f;
    const int dy = y1 - y0;
    if (dy > 0) {
        c += dy * 0.15f;
    } else if (-dy > SAFE_DROP) {
        c += HURT_COST;
    } else {
        c += -dy * 0.03f;
    }
    if (_wet_feet(r, x + dx, y1, z + dz, b)) {
        c += WADE_COST;
    }
    return c;
}

// --- queries ----------------------------------------------------------------

bool TerrainNav::fits(const Vector3 &at, const Vector4i &body) {
    const Body b = _body(body);
    Reader r(this);
    int x, y, z;
    _snap(at, b, x, y, z);
    return _fit(r, x, y, z, b);
}

int TerrainNav::code_at(const Vector3 &at) {
    Reader r(this);
    return r.code((int)std::floor(at.x / brick::STUD_M), (int)std::floor(at.y / brick::PLATE_M),
            (int)std::floor(at.z / brick::STUD_M));
}

Vector3 TerrainNav::stand_near(const Vector3 &at, const Vector4i &body, int radius) {
    const Body b = _body(body);
    Reader r(this);
    int sx, sy, sz;
    _snap(at, b, sx, sy, sz);
    for (int rr = 0; rr <= radius; ++rr) {
        for (int dz = -rr; dz <= rr; ++dz) {
            for (int dx = -rr; dx <= rr; ++dx) {
                if (std::max(std::abs(dx), std::abs(dz)) != rr) {
                    continue;
                }
                for (int i = 0; i <= 24; ++i) {
                    const int d = (i & 1) ? (i + 1) / 2 : -(i / 2);
                    if (_fit(r, sx + dx, sy + d, sz + dz, b)) {
                        return _feet(sx + dx, sy + d, sz + dz, b);
                    }
                }
            }
        }
    }
    return Vector3(INFINITY, INFINITY, INFINITY);
}

bool TerrainNav::line_clear(const Vector3 &from, const Vector3 &to) {
    Reader r(this);
    const Vector3 d = to - from;
    const float len = d.length();
    const int steps = std::max(1, (int)std::ceil(len / 0.06f));
    int64_t last = INT64_MIN;
    for (int i = 0; i <= steps; ++i) {
        const Vector3 p = from + d * ((float)i / steps);
        const int x = (int)std::floor(p.x / brick::STUD_M);
        const int y = (int)std::floor(p.y / brick::PLATE_M);
        const int z = (int)std::floor(p.z / brick::STUD_M);
        const int64_t k = _key(x, y, z);
        if (k == last) {
            continue;
        }
        last = k;
        if (r.solid(x, y, z)) {
            return false;
        }
    }
    return true;
}

bool TerrainNav::free_reach(const Vector3 &from, const Vector4i &body, int reach, int max_nodes) {
    const Body b = _body(body);
    Reader r(this);
    int sx, sy, sz;
    _snap(from, b, sx, sy, sz);
    if (!_find_node(r, sx, sy, sz, b, 6, 3)) {
        return false;   // stuck where it stands: as trapped as it gets
    }
    std::unordered_set<int64_t> seen;
    std::vector<int64_t> q;
    q.push_back(_key(sx, sy, sz));
    seen.insert(q.back());
    for (size_t head = 0; head < q.size(); ++head) {
        if ((int)seen.size() > max_nodes) {
            return true;   // that much room is not a pen
        }
        int x, y, z;
        _unkey(q[head], x, y, z);
        if (std::max(std::abs(x - sx), std::abs(z - sz)) > reach) {
            return true;
        }
        for (int i = 0; i < 4; ++i) {
            const int ny = _move(r, x, y, z, DIRS[i][0], DIRS[i][1], b);
            if (ny == NO_LAND) {
                continue;
            }
            const int64_t nk = _key(x + DIRS[i][0], ny, z + DIRS[i][1]);
            if (seen.insert(nk).second) {
                q.push_back(nk);
            }
        }
    }
    return false;
}

Dictionary TerrainNav::find_path(const Vector3 &from, const Vector3 &to, const Vector4i &body, int max_nodes) {
    const Body b = _body(body);
    Reader r(this);
    Dictionary out;
    out["path"] = PackedVector3Array();
    out["reached"] = false;
    out["expanded"] = 0;
    int sx, sy, sz;
    _snap(from, b, sx, sy, sz);
    if (!_find_node(r, sx, sy, sz, b, 6, 3)) {
        return out;
    }
    int gx, gy, gz;
    _snap(to, b, gx, gy, gz);
    _find_node(r, gx, gy, gz, b, 12, 3);   // if not a node, still where to head
    auto hfun = [&](int x, int y, int z) {
        const float ex = (float)(x - gx), ez = (float)(z - gz);
        return std::sqrt(ex * ex + ez * ez) + std::abs(y - gy) * 0.05f;
    };
    using QE = std::pair<float, int64_t>;
    std::priority_queue<QE, std::vector<QE>, std::greater<QE>> open;
    std::unordered_map<int64_t, float> g;
    std::unordered_map<int64_t, int64_t> parent;
    std::unordered_set<int64_t> closed;
    const int64_t start = _key(sx, sy, sz);
    g[start] = 0.0f;
    open.push({ hfun(sx, sy, sz), start });
    int64_t best = start;
    float best_h = hfun(sx, sy, sz);
    bool reached = false;
    int expanded = 0;
    while (!open.empty() && expanded < max_nodes) {
        const int64_t k = open.top().second;
        open.pop();
        if (!closed.insert(k).second) {
            continue;
        }
        ++expanded;
        int x, y, z;
        _unkey(k, x, y, z);
        const float hh = hfun(x, y, z);
        if (hh < best_h) {
            best_h = hh;
            best = k;
        }
        if (x == gx && z == gz && std::abs(y - gy) <= 3) {
            best = k;
            reached = true;
            break;
        }
        const float gk = g[k];
        for (const auto &d : DIRS) {
            const int ny = _move(r, x, y, z, d[0], d[1], b);
            if (ny == NO_LAND) {
                continue;
            }
            const int64_t nk = _key(x + d[0], ny, z + d[1]);
            if (closed.count(nk)) {
                continue;
            }
            const float ng = gk + _edge_cost(r, x, z, d[0], d[1], y, ny, b);
            auto it = g.find(nk);
            if (it == g.end() || ng < it->second) {
                g[nk] = ng;
                parent[nk] = k;
                open.push({ ng + hfun(x + d[0], ny, z + d[1]), nk });
            }
        }
    }
    std::vector<int64_t> chain;
    for (int64_t k = best;;) {
        chain.push_back(k);
        auto it = parent.find(k);
        if (it == parent.end()) {
            break;
        }
        k = it->second;
    }
    PackedVector3Array path;
    path.resize((int64_t)chain.size());
    for (size_t i = 0; i < chain.size(); ++i) {
        int x, y, z;
        _unkey(chain[chain.size() - 1 - i], x, y, z);
        path.set((int64_t)i, _feet(x, y, z, b));
    }
    out["path"] = path;
    out["reached"] = reached;
    out["expanded"] = expanded;
    return out;
}

int TerrainNav::build_field(const Vector3 &goal, int radius, const Vector4i &body, int max_nodes) {
    auto f = std::make_shared<Field>();
    f->body = _body(body);
    const Body &b = f->body;
    Reader r(this);
    int gx, gy, gz;
    _snap(goal, b, gx, gy, gz);
    if (!_find_node(r, gx, gy, gz, b, 12, 3)) {
        return 0;
    }
    f->gx = gx;
    f->gz = gz;
    using QE = std::pair<float, int64_t>;
    std::priority_queue<QE, std::vector<QE>, std::greater<QE>> open;
    auto &cost = f->cost;
    const int64_t g0 = _key(gx, gy, gz);
    cost[g0] = 0.0f;
    open.push({ 0.0f, g0 });
    // Backwards: who can walk INTO node B? A footprint one step back, standing
    // somewhere in [yB - up, yB + drop], whose forward move lands exactly on B.
    const int lo_off = -b.up, hi_off = b.drop;
    const int n = hi_off - lo_off + 1 + b.h;
    const int cols = b.w * b.w;
    std::vector<uint8_t> buf((size_t)cols * n);
    std::vector<int16_t> above((size_t)cols * n);
    int popped = 0;
    while (!open.empty() && popped < max_nodes) {
        const auto [c, k] = open.top();
        open.pop();
        auto ck = cost.find(k);
        if (ck == cost.end() || c > ck->second) {
            continue;
        }
        ++popped;
        int x, y, z;
        _unkey(k, x, y, z);
        for (const auto &d : DIRS) {
            const int ax = x - d[0], az = z - d[1];
            if (std::abs(ax - gx) > radius || std::abs(az - gz) > radius) {
                continue;
            }
            const int lo = y + lo_off;
            int ci = 0;
            for (int cz = az; cz < az + b.w; ++cz) {
                for (int cx = ax; cx < ax + b.w; ++cx) {
                    uint8_t *col = &buf[(size_t)ci * n];
                    r.column(cx, cz, lo, n, col);
                    // above[i]: the first plate over i a body cannot be in (n: none).
                    int16_t *ab = &above[(size_t)ci * n];
                    int16_t next = (int16_t)n;
                    for (int i = n - 1; i >= 0; --i) {
                        ab[i] = next;
                        if (blocks(col[i])) {
                            next = (int16_t)i;
                        }
                    }
                    ++ci;
                }
            }
            for (int ya = y + hi_off; ya >= lo; --ya) {
                const int i0 = ya - lo;
                bool support = false, clear = true;
                for (int cc = 0; cc < cols; ++cc) {
                    support = support || buf[(size_t)cc * n + i0] == SOLID;
                    if (above[(size_t)cc * n + i0] <= i0 + b.h) {
                        clear = false;
                        break;
                    }
                }
                if (!support || !clear) {
                    continue;
                }
                if (_move(r, ax, ya, az, d[0], d[1], b) != y) {
                    continue;
                }
                const int64_t ak = _key(ax, ya, az);
                const float nc = c + _edge_cost(r, ax, az, d[0], d[1], ya, y, b);
                auto it = cost.find(ak);
                if (it == cost.end() || nc < it->second) {
                    cost[ak] = nc;
                    open.push({ nc, ak });
                }
            }
        }
    }
    const int id = next_field.fetch_add(1);
    std::lock_guard<std::mutex> lk(field_lock);
    fields[id] = f;
    return id;
}

Vector3 TerrainNav::field_next(int id, const Vector3 &from) {
    std::shared_ptr<const Field> f;
    {
        std::lock_guard<std::mutex> lk(field_lock);
        auto it = fields.find(id);
        if (it == fields.end()) {
            return Vector3(INFINITY, INFINITY, INFINITY);
        }
        f = it->second;
    }
    const Body &b = f->body;
    Reader r(this);
    int x, y, z;
    _snap(from, b, x, y, z);
    // The node it stands on, or one beside it that is in the field.
    auto here = f->cost.end();
    {
        int fx = x, fy = y, fz = z;
        if (_find_node(r, fx, fy, fz, b, 6, 3)) {
            here = f->cost.find(_key(fx, fy, fz));
            if (here != f->cost.end()) {
                x = fx;
                y = fy;
                z = fz;
            }
        }
    }
    if (here == f->cost.end()) {
        return Vector3(INFINITY, INFINITY, INFINITY);
    }
    if (here->second <= 0.0f) {
        return _feet(x, y, z, b);
    }
    float best = here->second;
    Vector3 out = Vector3(INFINITY, INFINITY, INFINITY);
    for (const auto &d : DIRS) {
        const int ny = _move(r, x, y, z, d[0], d[1], b);
        if (ny == NO_LAND) {
            continue;
        }
        auto it = f->cost.find(_key(x + d[0], ny, z + d[1]));
        if (it != f->cost.end() && it->second < best) {
            best = it->second;
            out = _feet(x + d[0], ny, z + d[1], b);
        }
    }
    return out;
}

float TerrainNav::field_cost(int id, const Vector3 &from) {
    std::shared_ptr<const Field> f;
    {
        std::lock_guard<std::mutex> lk(field_lock);
        auto it = fields.find(id);
        if (it == fields.end()) {
            return INFINITY;
        }
        f = it->second;
    }
    Reader r(this);
    int x, y, z;
    _snap(from, f->body, x, y, z);
    if (!_find_node(r, x, y, z, f->body, 6, 3)) {
        return INFINITY;
    }
    auto it = f->cost.find(_key(x, y, z));
    return it == f->cost.end() ? INFINITY : it->second * brick::STUD_M;
}

int TerrainNav::field_size(int id) {
    std::lock_guard<std::mutex> lk(field_lock);
    auto it = fields.find(id);
    return it == fields.end() ? 0 : (int)it->second->cost.size();
}

void TerrainNav::release_field(int id) {
    std::lock_guard<std::mutex> lk(field_lock);
    fields.erase(id);
}
