#include "brick_pools.h"

#include "brick_terrain.h"

#include <godot_cpp/classes/mesh.hpp>
#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/variant/packed_byte_array.hpp>
#include <godot_cpp/variant/packed_color_array.hpp>
#include <godot_cpp/variant/packed_int32_array.hpp>
#include <godot_cpp/variant/packed_vector2_array.hpp>
#include <godot_cpp/variant/packed_vector3_array.hpp>
#include <godot_cpp/variant/vector2i.hpp>

#include <algorithm>
#include <cmath>
#include <limits>
#include <memory>
#include <unordered_map>
#include <unordered_set>
#include <utility>
#include <vector>

using namespace brick;

namespace {

constexpr int T = TILE;
constexpr int N = T * T;
/// Sub-step. The pipe model is stable while a wave crosses less than a stud
/// per step: sqrt(g * 3 m) is 5.4 m/s against 0.35 m * 60 = 21 m/s.
constexpr double STEP = 1.0 / 60.0;
constexpr int MAX_STEPS_PER_TICK = 4;
constexpr float G = 9.8f;
/// Flux kept per step. 0.95 at 60 Hz halves a flow left running in a quarter
/// second (0.98 took nine seconds to still a pool that met the sea):
/// a pool settles rather than rings.
constexpr float DAMP = 0.95f;
/// A column whose depth moves less than this per step, with every flux out of
/// it under EPS_F, is calm; CALM_STEPS calm steps and it stops being ticked.
constexpr float EPS_D = 2.0e-5f;
// 1 cm/s: below it the pipes leave a head of (1 - DAMP) * EPS_F / k, a few
// millimetres, and the approach to it is an exponential tail of minutes.
constexpr float EPS_F = 1.0e-2f;
constexpr int CALM_STEPS = 30;
/// Water shallower than this is not drawn and does not count as a surface.
constexpr float SHOW_MIN = 0.02f;
/// Seeping stops this far under the sea. Without it a pool open to the sea
/// never settles: seeping tops up the columns a few millimetres under sea
/// level, the sea takes the excess at the breach, and the loop flows forever.
constexpr float SEEP_SLACK = 0.03f;
/// How fast water moves, as a fraction of gravity's pull in the pipes. Full
/// strength filled a crater from a breach in about a second -- correct, and
/// too quick to see it come in. 0.3 takes several seconds.
float g_flow = 0.3f;

/// Tiles made per tick when flow reaches a tile that is not held yet.
constexpr int MAKE_PER_TICK = 2;

enum : uint8_t { K_LAND = 0, K_OCEAN = 1 };
// Directions: +x, -x, +z, -z.
constexpr int DX[4] = { 1, -1, 0, 0 };
constexpr int DZ[4] = { 0, 0, 1, -1 };
constexpr int OPP[4] = { 1, 0, 3, 2 };

struct PoolTile {
    int tx = 0, tz = 0;
    /// Where water rests, metres (BrickTerrain::water_floor_tile).
    float floor[N];
    /// Water over the floor, metres. Sea columns hold sea level - floor and
    /// are never changed: the sea is infinite.
    float depth[N];
    /// Flux out to each neighbour, metres of depth per second.
    float flux[N][4];
    uint8_t kind[N];
    /// Within reach of the sea through the ground (a beach): fills toward
    /// sea level even with no channel.
    uint8_t seep[N];
    uint8_t active[N];
    uint16_t calm[N];
    /// The level last drawn, so a tile is re-meshed only when a column's
    /// drawn level changes.
    float shown[N];
};

std::unordered_map<int64_t, std::unique_ptr<PoolTile>> g_tiles;
std::vector<std::pair<PoolTile *, int>> g_active;
std::unordered_set<int64_t> g_dirty;
std::unordered_set<int64_t> g_want;
double g_accum = 0.0;
int g_seep_studs = 10;
float g_seep_rate = 0.08f;

inline int64_t key(int tx, int tz) { return ((int64_t)tx << 32) ^ (int64_t)(uint32_t)tz; }

inline int fdiv(int a, int b) {
    const int q = a / b;
    return (a % b != 0 && ((a < 0) != (b < 0))) ? q - 1 : q;
}

inline float sea() { return (float)BrickWave::get_sea_level(); }

PoolTile *tile_at(int tx, int tz) {
    auto it = g_tiles.find(key(tx, tz));
    return it == g_tiles.end() ? nullptr : it->second.get();
}

/// The tile and index of a world column, or nullptr.
PoolTile *column(int x, int z, int &i) {
    const int tx = fdiv(x, T), tz = fdiv(z, T);
    PoolTile *t = tile_at(tx, tz);
    if (t != nullptr) {
        i = (z - tz * T) * T + (x - tx * T);
    }
    return t;
}

inline float level(const PoolTile *t, int i) {
    return t->kind[i] == K_OCEAN ? sea() : t->floor[i] + t->depth[i];
}

/// The level a column is DRAWN at, or -INF when there is nothing to draw.
/// Continuous: a pool is seen rising from the floor of the hole. (It was
/// stepped a plate at a time, and a hole that filled in two seconds read as
/// water that appeared rather than water that came in.)
float shown_level(const PoolTile *t, int i) {
    if (t->kind[i] == K_OCEAN || t->depth[i] < SHOW_MIN) {
        return -std::numeric_limits<float>::infinity();
    }
    return t->floor[i] + t->depth[i];
}

/// Has a column's drawn water moved enough since it was meshed to mesh again?
inline bool needs_redraw(const PoolTile *t, int i) {
    const float now = shown_level(t, i);
    const float was = t->shown[i];
    if (std::isfinite(now) != std::isfinite(was)) {
        return true;
    }
    return std::isfinite(now) && std::fabs(now - was) > 0.004f;
}

void activate(PoolTile *t, int i) {
    t->calm[i] = 0;
    if (!t->active[i]) {
        t->active[i] = 1;
        g_active.emplace_back(t, i);
    }
}

void mark_dirty(PoolTile *t, int i) {
    g_dirty.insert(key(t->tx, t->tz));
    // A column on the edge draws a side its neighbour tile owns.
    const int lx = i % T, lz = i / T;
    if (lx == 0) g_dirty.insert(key(t->tx - 1, t->tz));
    if (lx == T - 1) g_dirty.insert(key(t->tx + 1, t->tz));
    if (lz == 0) g_dirty.insert(key(t->tx, t->tz - 1));
    if (lz == T - 1) g_dirty.insert(key(t->tx, t->tz + 1));
}

/// Read the ground under a tile: floor, sea or land, seeping or not. Keeps
/// the water LEVEL of land columns that hold some, so ground raised under a
/// pool pushes the water up and out rather than deleting it.
void read_ground(PoolTile *t) {
    const PackedFloat32Array fl = BrickTerrain::water_floor_tile(t->tx, t->tz);
    const float *f = fl.ptr();
    const float s = sea();
    const int gx0 = t->tx * T, gz0 = t->tz * T;
    bool any_dug = false;
    std::vector<uint8_t> dug((size_t)N, 0);
    for (int i = 0; i < N; ++i) {
        const float old_level = t->floor[i] + t->depth[i];
        const bool had = t->kind[i] == K_LAND && t->depth[i] > 0.0f;
        t->floor[i] = f[i];
        bool ocean = false;
        if (f[i] < s) {
            // The floor is below the sea. Sea if the world as generated was;
            // DUG if its top is below the sea now and was not then. A slope
            // whose face dips under the sea on a natural beach is neither:
            // it is land the sea tiers already leave dry.
            const int gx = gx0 + i % T, gz = gz0 + i / T;
            const bool bare_wet = (float)(BrickTerrain::generated_plate(gx, gz) + 1) * PLATE_M < s;
            ocean = bare_wet;
            dug[(size_t)i] = !bare_wet
                    && (float)(BrickTerrain::surface_plate(gx, gz) + 1) * PLATE_M < s;
            any_dug = any_dug || dug[(size_t)i];
        }
        t->kind[i] = ocean ? K_OCEAN : K_LAND;
        if (ocean) {
            t->depth[i] = std::max(0.0f, s - f[i]);
        } else {
            t->depth[i] = had ? std::max(0.0f, old_level - f[i]) : 0.0f;
        }
        t->seep[i] = 0;
    }
    if (any_dug && g_seep_studs > 0) {
        // Sea in a window round the tile, then grown by the seep reach.
        const int r = g_seep_studs;
        const int w = T + 2 * r;
        std::vector<uint8_t> sea_at((size_t)w * w, 0), grown((size_t)w * w, 0);
        for (int z = 0; z < w; ++z) {
            for (int x = 0; x < w; ++x) {
                const int gx = gx0 - r + x, gz = gz0 - r + z;
                sea_at[(size_t)z * w + x] =
                        (float)(BrickTerrain::generated_plate(gx, gz) + 1) * PLATE_M < s;
            }
        }
        // Separable Chebyshev dilation: rows, then columns.
        std::vector<uint8_t> rows((size_t)w * w, 0);
        for (int z = 0; z < w; ++z) {
            int last = -1000000;
            for (int x = 0; x < w; ++x) {
                if (sea_at[(size_t)z * w + x]) last = x;
                rows[(size_t)z * w + x] = x - last <= r;
            }
            last = 1000000;
            for (int x = w - 1; x >= 0; --x) {
                if (sea_at[(size_t)z * w + x]) last = x;
                rows[(size_t)z * w + x] |= last - x <= r;
            }
        }
        for (int x = 0; x < w; ++x) {
            int last = -1000000;
            for (int z = 0; z < w; ++z) {
                if (rows[(size_t)z * w + x]) last = z;
                grown[(size_t)z * w + x] = z - last <= r;
            }
            last = 1000000;
            for (int z = w - 1; z >= 0; --z) {
                if (rows[(size_t)z * w + x]) last = z;
                grown[(size_t)z * w + x] |= last - z <= r;
            }
        }
        for (int i = 0; i < N; ++i) {
            const int lx = i % T, lz = i / T;
            t->seep[i] = dug[(size_t)i] && grown[(size_t)(lz + r) * w + (lx + r)];
        }
    }
    for (int i = 0; i < N; ++i) {
        for (int d = 0; d < 4; ++d) {
            t->flux[i][d] = 0.0f;
        }
        activate(t, i);
        mark_dirty(t, i);
    }
}

PoolTile *make_tile(int tx, int tz) {
    PoolTile *have = tile_at(tx, tz);
    if (have != nullptr) {
        return have;
    }
    auto t = std::make_unique<PoolTile>();
    t->tx = tx;
    t->tz = tz;
    for (int i = 0; i < N; ++i) {
        t->floor[i] = 0.0f;
        t->depth[i] = 0.0f;
        t->kind[i] = K_LAND;
        t->active[i] = 0;
        t->calm[i] = 0;
        t->shown[i] = -std::numeric_limits<float>::infinity();
    }
    PoolTile *p = t.get();
    g_tiles.emplace(key(tx, tz), std::move(t));
    g_want.erase(key(tx, tz));
    read_ground(p);
    return p;
}

/// Is any column of this tile, inside `studs`, dug below the sea where the
/// world as generated was dry?
bool dug_below_sea(int tx, int tz, const Rect2i &studs) {
    const float s = sea();
    const int x0 = std::max(tx * T, studs.position.x), x1 = std::min(tx * T + T, studs.position.x + studs.size.x);
    const int z0 = std::max(tz * T, studs.position.y), z1 = std::min(tz * T + T, studs.position.y + studs.size.y);
    for (int z = z0; z < z1; ++z) {
        for (int x = x0; x < x1; ++x) {
            if ((float)(BrickTerrain::surface_plate(x, z) + 1) * PLATE_M < s
                    && (float)(BrickTerrain::generated_plate(x, z) + 1) * PLATE_M >= s) {
                return true;
            }
        }
    }
    return false;
}

void step() {
    const float s = sea();
    const float k = (float)STEP * G * g_flow / STUD_M;
    const size_t n0 = g_active.size();

    // Pass 1: the flux out of every ticked column to each neighbour.
    for (size_t a = 0; a < n0; ++a) {
        PoolTile *t = g_active[a].first;
        const int i = g_active[a].second;
        const int gx = t->tx * T + i % T, gz = t->tz * T + i / T;
        const bool ocean = t->kind[i] == K_OCEAN;
        const float l = ocean ? s : t->floor[i] + t->depth[i];
        float out = 0.0f;
        for (int d = 0; d < 4; ++d) {
            int j = 0;
            PoolTile *nt = column(gx + DX[d], gz + DZ[d], j);
            float &f = t->flux[i][d];
            if (nt == nullptr) {
                // Not held: a wall for now. Water at the edge asks for it.
                f = 0.0f;
                if (!ocean && t->depth[i] > SHOW_MIN) {
                    g_want.insert(key(fdiv(gx + DX[d], T), fdiv(gz + DZ[d], T)));
                }
                continue;
            }
            if (ocean && nt->kind[j] == K_OCEAN) {
                f = 0.0f;   // sea to sea: both infinite, nothing to move
                continue;
            }
            const float ln = level(nt, j);
            f = std::max(0.0f, DAMP * f + k * (l - ln));
            out += f;
        }
        if (!ocean && out > 0.0f) {
            // Never send more than the column holds.
            const float avail = t->depth[i] / (float)STEP;
            if (out > avail) {
                const float scale = avail / out;
                for (int d = 0; d < 4; ++d) {
                    t->flux[i][d] *= scale;
                }
            }
        }
        for (int d = 0; d < 4; ++d) {
            // ANY flow wakes the neighbour: pass 2 only adds water to ticked
            // columns, and a trickle under EPS_F sent to a still one was lost
            // (and the sea, an infinite source, kept topping it up).
            // A trickle wakes it without resetting its calm count, or two
            // columns trading microns keep each other awake for ever.
            if (t->flux[i][d] > 0.0f) {
                int j = 0;
                PoolTile *nt = column(gx + DX[d], gz + DZ[d], j);
                if (nt == nullptr) {
                    continue;
                }
                if (t->flux[i][d] > EPS_F) {
                    activate(nt, j);
                } else if (!nt->active[j]) {
                    nt->active[j] = 1;
                    g_active.emplace_back(nt, j);
                }
            }
        }
    }

    // Pass 2: every ticked column's depth, from what flowed in and out.
    // Includes columns woken in pass 1, so water sent to a still column
    // arrives.
    const size_t n1 = g_active.size();
    for (size_t a = 0; a < n1; ++a) {
        PoolTile *t = g_active[a].first;
        const int i = g_active[a].second;
        const int gx = t->tx * T + i % T, gz = t->tz * T + i / T;
        float fin = 0.0f, fout = 0.0f, fmax = 0.0f;
        for (int d = 0; d < 4; ++d) {
            fout += t->flux[i][d];
            fmax = std::max(fmax, t->flux[i][d]);
            int j = 0;
            PoolTile *nt = column(gx + DX[d], gz + DZ[d], j);
            if (nt != nullptr) {
                fin += nt->flux[j][OPP[d]];
            }
        }
        float dd = 0.0f;
        if (t->kind[i] == K_LAND) {
            dd = (float)STEP * (fin - fout);
            if (t->seep[i]) {
                const float room = s - SEEP_SLACK - (t->floor[i] + t->depth[i] + dd);
                if (room > 0.0f) {
                    dd += std::min(g_seep_rate * (float)STEP, room);
                }
            }
            t->depth[i] = std::max(0.0f, t->depth[i] + dd);
            if (needs_redraw(t, i)) {
                mark_dirty(t, i);
            }
        }
        if (std::fabs(dd) > EPS_D || fmax > EPS_F) {
            t->calm[i] = 0;
        } else if (t->calm[i] < 0xFFFF) {
            ++t->calm[i];
        }
    }

    // Pass 3: drop the columns that have been calm long enough.
    size_t w = 0;
    for (size_t a = 0; a < g_active.size(); ++a) {
        PoolTile *t = g_active[a].first;
        const int i = g_active[a].second;
        if (t->calm[i] > CALM_STEPS) {
            t->active[i] = 0;
            for (int d = 0; d < 4; ++d) {
                t->flux[i][d] = 0.0f;
            }
        } else {
            g_active[w++] = g_active[a];
        }
    }
    g_active.resize(w);
}

void make_wanted(int budget) {
    while (!g_want.empty() && budget-- > 0) {
        const int64_t k = *g_want.begin();
        g_want.erase(g_want.begin());
        const int tx = (int)(k >> 32);
        const int tz = (int)(int32_t)(uint32_t)(k & 0xFFFFFFFF);
        make_tile(tx, tz);
    }
}

} // namespace

void BrickPools::clear() {
    g_tiles.clear();
    g_active.clear();
    g_dirty.clear();
    g_want.clear();
    g_accum = 0.0;
}

int BrickPools::ground_changed(const Rect2i &studs) {
    // One stud out: a column's neighbours decide where its water goes.
    const Rect2i r(studs.position - Vector2i(1, 1), studs.size + Vector2i(2, 2));
    const int tx0 = fdiv(r.position.x, T), tx1 = fdiv(r.position.x + r.size.x - 1, T);
    const int tz0 = fdiv(r.position.y, T), tz1 = fdiv(r.position.y + r.size.y - 1, T);
    int touched = 0;
    for (int tz = tz0; tz <= tz1; ++tz) {
        for (int tx = tx0; tx <= tx1; ++tx) {
            PoolTile *t = tile_at(tx, tz);
            if (t != nullptr) {
                read_ground(t);
                ++touched;
            } else if (dug_below_sea(tx, tz, r)) {
                make_tile(tx, tz);
                ++touched;
            }
        }
    }
    // A dug tile's neighbours are where its water comes from.
    std::vector<std::pair<int, int>> made;
    for (int tz = tz0; tz <= tz1; ++tz) {
        for (int tx = tx0; tx <= tx1; ++tx) {
            if (tile_at(tx, tz) != nullptr) {
                made.emplace_back(tx, tz);
            }
        }
    }
    for (const auto &m : made) {
        for (int d = 0; d < 4; ++d) {
            if (tile_at(m.first + DX[d], m.second + DZ[d]) == nullptr) {
                make_tile(m.first + DX[d], m.second + DZ[d]);
            }
        }
    }
    return touched;
}

int BrickPools::scan_sculpt() {
    const Array tiles = BrickTerrain::sculpt_tiles();
    int touched = 0;
    for (int64_t k = 0; k < tiles.size(); ++k) {
        const Vector2i t = tiles[k];
        touched += ground_changed(Rect2i(t.x * T, t.y * T, T, T));
    }
    return touched;
}

int BrickPools::tick(double delta) {
    g_accum += std::max(0.0, delta);
    int steps = (int)std::floor(g_accum / STEP);
    if (steps > MAX_STEPS_PER_TICK) {
        steps = MAX_STEPS_PER_TICK;
        g_accum = 0.0;   // behind: slow the water, not the frame
    } else {
        g_accum -= steps * STEP;
    }
    int ticked = 0;
    for (int k = 0; k < steps; ++k) {
        ticked += (int)g_active.size();
        step();
    }
    make_wanted(MAKE_PER_TICK);
    return ticked;
}

void BrickPools::settle(int ticks) {
    for (int k = 0; k < ticks; ++k) {
        if (g_active.empty() && g_want.empty()) {
            break;
        }
        step();
        make_wanted(1 << 20);
    }
}

double BrickPools::level_at(double x, double z) {
    int i = 0;
    const PoolTile *t = column((int)std::floor(x / STUD_M), (int)std::floor(z / STUD_M), i);
    if (t == nullptr || t->kind[i] == K_OCEAN) {
        return std::numeric_limits<double>::quiet_NaN();
    }
    if (t->depth[i] < SHOW_MIN) {
        return -std::numeric_limits<double>::infinity();
    }
    return (double)(t->floor[i] + t->depth[i]);
}

double BrickPools::depth_at(int x, int z) {
    int i = 0;
    const PoolTile *t = column(x, z, i);
    return (t == nullptr || t->kind[i] == K_OCEAN) ? 0.0 : (double)t->depth[i];
}

void BrickPools::add_water(int x, int z, double metres) {
    int i = 0;
    PoolTile *t = column(x, z, i);
    if (t == nullptr) {
        t = make_tile(fdiv(x, T), fdiv(z, T));
        column(x, z, i);
    }
    if (t->kind[i] == K_OCEAN) {
        return;
    }
    t->depth[i] = std::max(0.0f, t->depth[i] + (float)metres);
    activate(t, i);
    mark_dirty(t, i);
}

double BrickPools::total_volume() {
    double v = 0.0;
    for (const auto &kv : g_tiles) {
        const PoolTile *t = kv.second.get();
        for (int i = 0; i < N; ++i) {
            if (t->kind[i] == K_LAND) {
                v += (double)t->depth[i];
            }
        }
    }
    return v * (double)STUD_M * (double)STUD_M;
}

int BrickPools::active_count() { return (int)g_active.size(); }

Array BrickPools::active_columns(int limit) {
    Array out;
    for (const auto &a : g_active) {
        if (out.size() >= limit) {
            break;
        }
        const PoolTile *t = a.first;
        const int i = a.second;
        Dictionary d;
        d["x"] = t->tx * T + i % T;
        d["z"] = t->tz * T + i / T;
        d["sea"] = t->kind[i] == K_OCEAN;
        d["floor"] = t->floor[i];
        d["depth"] = t->depth[i];
        d["flux"] = PackedFloat32Array({ t->flux[i][0], t->flux[i][1], t->flux[i][2], t->flux[i][3] });
        d["calm"] = t->calm[i];
        out.append(d);
    }
    return out;
}
int BrickPools::tile_count() { return (int)g_tiles.size(); }

Array BrickPools::take_dirty_tiles() {
    Array out;
    for (int64_t k : g_dirty) {
        if (g_tiles.count(k) != 0) {
            out.append(Vector2i((int)(k >> 32), (int)(int32_t)(uint32_t)(k & 0xFFFFFFFF)));
        }
    }
    g_dirty.clear();
    return out;
}

Dictionary BrickPools::build_mesh(int tx, int tz) {
    Dictionary result;
    result["mesh"] = Array();
    result["triangle_count"] = 0;
    PoolTile *t = tile_at(tx, tz);
    if (t == nullptr) {
        return result;
    }
    PackedVector3Array verts, normals;
    PackedColorArray colours;
    PackedVector2Array uvs;
    PackedInt32Array indices;
    auto quad = [&](Vector3 a, Vector3 b, Vector3 c, Vector3 d, Vector3 nrm, Color col) {
        const int base = (int)verts.size();
        for (const Vector3 &v : { a, b, c, d }) {
            verts.push_back(v);
            normals.push_back(nrm);
            colours.push_back(col);
            uvs.push_back(Vector2(v.x, v.z));
        }
        indices.push_back(base);
        indices.push_back(base + 1);
        indices.push_back(base + 2);
        indices.push_back(base);
        indices.push_back(base + 2);
        indices.push_back(base + 3);
    };
    // A corner's height: the mean of the water round it -- wet pool columns
    // at their level, sea columns at the sea's. Where water comes in from the
    // sea the surface slopes down from it into the hole, and a stream runs
    // downhill, instead of every column being a flat step (STA's blocky
    // water, section 3).
    auto corner = [&](int cx, int cz, float own) {
        float sum = 0.0f;
        int n = 0;
        for (int dz = -1; dz <= 0; ++dz) {
            for (int dx = -1; dx <= 0; ++dx) {
                int j = 0;
                const PoolTile *nt = column(cx + dx, cz + dz, j);
                if (nt == nullptr) {
                    continue;
                }
                const float l = nt->kind[j] == K_OCEAN ? sea() : shown_level(nt, j);
                if (std::isfinite(l)) {
                    sum += l;
                    ++n;
                }
            }
        }
        return n > 0 ? sum / (float)n : own;
    };
    for (int i = 0; i < N; ++i) {
        const float top = shown_level(t, i);
        t->shown[i] = top;
        if (!std::isfinite(top)) {
            continue;
        }
        const int gx = tx * T + i % T, gz = tz * T + i / T;
        const float x0 = (float)gx * STUD_M, x1 = x0 + STUD_M;
        const float z0 = (float)gz * STUD_M, z1 = z0 + STUD_M;
        float speed = 0.0f;
        for (int d = 0; d < 4; ++d) {
            speed += t->flux[i][d];
        }
        // Net flow out of the column, for the direction foam runs in.
        const float fx = t->flux[i][0] - t->flux[i][1];
        const float fz = t->flux[i][2] - t->flux[i][3];
        // R: how fast it is flowing (foam), G: how deep (colour), B and A:
        // which way it flows, 0.5 still.
        const Color col(std::min(speed / 2.0f, 1.0f), std::min(t->depth[i] / 3.0f, 1.0f),
                0.5f + 0.5f * std::clamp(fx, -1.0f, 1.0f), 0.5f + 0.5f * std::clamp(fz, -1.0f, 1.0f));
        const float h00 = corner(gx, gz, top), h10 = corner(gx + 1, gz, top);
        const float h11 = corner(gx + 1, gz + 1, top), h01 = corner(gx, gz + 1, top);
        quad(Vector3(x0, h00, z0), Vector3(x1, h10, z0), Vector3(x1, h11, z1), Vector3(x0, h01, z1),
                Vector3(0, 1, 0), col);
        for (int d = 0; d < 4; ++d) {
            const int nx = gx + DX[d], nz = gz + DZ[d];
            int j = 0;
            const PoolTile *nt = column(nx, nz, j);
            float bottom = t->floor[i];
            if (nt == nullptr) {
                bottom = std::max(bottom, (float)(BrickTerrain::surface_plate(nx, nz) + 1) * PLATE_M);
            } else if (nt->kind[j] == K_OCEAN || std::isfinite(shown_level(nt, j))) {
                continue;   // the sea, or water: the tops meet at the corners
            } else {
                bottom = std::max(bottom, nt->floor[j]);
            }
            float ax, az, bx, bz, ha, hb;
            switch (d) {
                case 0: ax = x1; az = z0; bx = x1; bz = z1; ha = h10; hb = h11; break;
                case 1: ax = x0; az = z1; bx = x0; bz = z0; ha = h01; hb = h00; break;
                case 2: ax = x1; az = z1; bx = x0; bz = z1; ha = h11; hb = h01; break;
                default: ax = x0; az = z0; bx = x1; bz = z0; ha = h00; hb = h10; break;
            }
            if (bottom >= std::max(ha, hb) - 0.005f) {
                continue;
            }
            const Vector3 nrm((float)DX[d], 0, (float)DZ[d]);
            quad(Vector3(ax, ha, az), Vector3(bx, hb, bz), Vector3(bx, std::min(bottom, hb), bz),
                    Vector3(ax, std::min(bottom, ha), az), nrm, col);
        }
    }
    if (verts.is_empty()) {
        return result;
    }
    Array mesh;
    mesh.resize(Mesh::ARRAY_MAX);
    mesh[Mesh::ARRAY_VERTEX] = verts;
    mesh[Mesh::ARRAY_NORMAL] = normals;
    mesh[Mesh::ARRAY_COLOR] = colours;
    mesh[Mesh::ARRAY_TEX_UV] = uvs;
    mesh[Mesh::ARRAY_INDEX] = indices;
    result["mesh"] = mesh;
    result["triangle_count"] = (int)(indices.size() / 3);
    return result;
}

PackedByteArray BrickPools::sea_mask(int x0, int z0, int size) {
    PackedByteArray out;
    size = std::max(size, 1);
    const size_t n = (size_t)size * size;
    out.resize((int64_t)n * 2);
    uint8_t *w = out.ptrw();
    // R: 255 on every pool column that is not sea (the sea discards there).
    // G: how much of its wave the sea keeps, 0 against water in a pool and
    // full POOL_CALM_STUDS away -- so where the sea meets a pool it is at
    // its still level, the pool's level, and no crest stands over the pool.
    constexpr float POOL_CALM_STUDS = 14.0f;
    const float INF = 1.0e9f;
    std::vector<float> dist(n, INF);
    for (size_t k = 0; k < n; ++k) {
        w[k * 2] = 0;
    }
    const int tx0 = fdiv(x0, T), tx1 = fdiv(x0 + size - 1, T);
    const int tz0 = fdiv(z0, T), tz1 = fdiv(z0 + size - 1, T);
    bool any_wet = false;
    for (int tz = tz0; tz <= tz1; ++tz) {
        for (int tx = tx0; tx <= tx1; ++tx) {
            const PoolTile *t = tile_at(tx, tz);
            if (t == nullptr) {
                continue;
            }
            for (int i = 0; i < N; ++i) {
                if (t->kind[i] != K_LAND) {
                    continue;
                }
                const int x = tx * T + i % T - x0, z = tz * T + i / T - z0;
                if (x >= 0 && z >= 0 && x < size && z < size) {
                    const size_t k = (size_t)z * size + x;
                    w[k * 2] = 255;
                    if (t->depth[i] >= SHOW_MIN) {
                        dist[k] = 0.0f;
                        any_wet = true;
                    }
                }
            }
        }
    }
    if (any_wet) {
        // Two-pass chamfer, as the shore field does (BrickWave).
        const float D1 = 1.0f, D2 = 1.41421356f;
        for (int z = 0; z < size; ++z) {
            for (int x = 0; x < size; ++x) {
                float &v = dist[(size_t)z * size + x];
                if (x > 0) v = std::min(v, dist[(size_t)z * size + x - 1] + D1);
                if (z > 0) {
                    v = std::min(v, dist[(size_t)(z - 1) * size + x] + D1);
                    if (x > 0) v = std::min(v, dist[(size_t)(z - 1) * size + x - 1] + D2);
                    if (x + 1 < size) v = std::min(v, dist[(size_t)(z - 1) * size + x + 1] + D2);
                }
            }
        }
        for (int z = size - 1; z >= 0; --z) {
            for (int x = size - 1; x >= 0; --x) {
                float &v = dist[(size_t)z * size + x];
                if (x + 1 < size) v = std::min(v, dist[(size_t)z * size + x + 1] + D1);
                if (z + 1 < size) {
                    v = std::min(v, dist[(size_t)(z + 1) * size + x] + D1);
                    if (x + 1 < size) v = std::min(v, dist[(size_t)(z + 1) * size + x + 1] + D2);
                    if (x > 0) v = std::min(v, dist[(size_t)(z + 1) * size + x - 1] + D2);
                }
            }
        }
    }
    for (size_t k = 0; k < n; ++k) {
        const float u = std::clamp(dist[k] / POOL_CALM_STUDS, 0.0f, 1.0f);
        w[k * 2 + 1] = (uint8_t)std::lround(255.0f * u * u * (3.0f - 2.0f * u));
    }
    return out;
}

void BrickPools::set_flow_speed(double fraction) { g_flow = (float)std::clamp(fraction, 0.01, 1.0); }

void BrickPools::set_seep(int studs, double metres_per_second) {
    g_seep_studs = std::max(0, studs);
    g_seep_rate = (float)std::max(0.0, metres_per_second);
}

void BrickPools::_bind_methods() {
    ClassDB::bind_static_method("BrickPools", D_METHOD("clear"), &BrickPools::clear);
    ClassDB::bind_static_method("BrickPools", D_METHOD("ground_changed", "studs"),
        &BrickPools::ground_changed);
    ClassDB::bind_static_method("BrickPools", D_METHOD("scan_sculpt"), &BrickPools::scan_sculpt);
    ClassDB::bind_static_method("BrickPools", D_METHOD("tick", "delta"), &BrickPools::tick);
    ClassDB::bind_static_method("BrickPools", D_METHOD("settle", "ticks"), &BrickPools::settle);
    ClassDB::bind_static_method("BrickPools", D_METHOD("level_at", "x", "z"), &BrickPools::level_at);
    ClassDB::bind_static_method("BrickPools", D_METHOD("depth_at", "x", "z"), &BrickPools::depth_at);
    ClassDB::bind_static_method("BrickPools", D_METHOD("add_water", "x", "z", "metres"),
        &BrickPools::add_water);
    ClassDB::bind_static_method("BrickPools", D_METHOD("total_volume"), &BrickPools::total_volume);
    ClassDB::bind_static_method("BrickPools", D_METHOD("active_count"), &BrickPools::active_count);
    ClassDB::bind_static_method("BrickPools", D_METHOD("tile_count"), &BrickPools::tile_count);
    ClassDB::bind_static_method("BrickPools", D_METHOD("active_columns", "limit"),
        &BrickPools::active_columns);
    ClassDB::bind_static_method("BrickPools", D_METHOD("take_dirty_tiles"),
        &BrickPools::take_dirty_tiles);
    ClassDB::bind_static_method("BrickPools", D_METHOD("build_mesh", "tx", "tz"),
        &BrickPools::build_mesh);
    ClassDB::bind_static_method("BrickPools", D_METHOD("sea_mask", "x0", "z0", "size"),
        &BrickPools::sea_mask);
    ClassDB::bind_static_method("BrickPools", D_METHOD("set_flow_speed", "fraction"),
        &BrickPools::set_flow_speed);
    ClassDB::bind_static_method("BrickPools", D_METHOD("set_seep", "studs", "metres_per_second"),
        &BrickPools::set_seep);
}
