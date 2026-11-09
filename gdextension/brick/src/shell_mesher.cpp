#include "shell_mesher.h"

#include "brick_world.h"

#include <godot_cpp/classes/mesh.hpp>
#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/variant/color.hpp>
#include <godot_cpp/variant/packed_color_array.hpp>
#include <godot_cpp/variant/packed_vector2_array.hpp>
#include <godot_cpp/variant/packed_vector3_array.hpp>
#include <godot_cpp/variant/vector2.hpp>
#include <godot_cpp/variant/vector3.hpp>

#include <algorithm>
#include <cmath>
#include <vector>

// The constants of scripts/building_shell.gd, and its arithmetic: GDScript
// works in doubles and rounds to float where a value goes into a Vector, so
// this does the same, and the arrays come out as the script's did.
namespace {

constexpr double STUD = 0.35;
constexpr double PLATE = 0.14;
constexpr int SEGMENTS = 32;
constexpr int ALL_STANDING = -1;
const Vector2 SEAM_UNIT(2.0 * STUD, 3.0 * PLATE);
const Vector2 SEAM_UNIT_FLAT(2.0 * STUD, 2.0 * STUD);

enum Side { FRONT = 0, BACK = 1, LEFT = 2, RIGHT = 3 };
enum Kind { BASE = 0, COURSE = 1, SLAB = 2, CORNICE = 3 };

struct Out {
    PackedVector3Array verts, normals;
    PackedColorArray colours;
    PackedVector2Array uvs, uv2s;
    PackedInt32Array indices;
};

// A run of standing wall, its two ends as the script's Vector2 held them.
struct Run {
    float lo, hi;
};

Vector2 fit_unit(const Vector2 &unit, const Vector2 &size) {
    return Vector2(
            (double)size.x / std::max(std::round((double)size.x / (double)unit.x), 1.0),
            (double)size.y / std::max(std::round((double)size.y / (double)unit.y), 1.0));
}

// Corners a, b, c, d with triangles (a,b,c) and (b,d,c), as the brick mesher.
void quad(Out &o, const Color &col, const Vector3 &a, const Vector3 &b, const Vector3 &c,
        const Vector3 &d, const Vector3 &n, const Vector2 &size, const Vector2 &unit) {
    const Vector2 seam = fit_unit(unit, size);
    const int v0 = (int)o.verts.size();
    const Vector3 corners[4] = { a, b, c, d };
    for (const Vector3 &p : corners) {
        o.verts.push_back(p);
        o.normals.push_back(n);
        o.colours.push_back(col);
        o.uv2s.push_back(seam);
    }
    o.uvs.push_back(Vector2(0, 0));
    o.uvs.push_back(Vector2(size.x, 0));
    o.uvs.push_back(Vector2(0, size.y));
    o.uvs.push_back(Vector2(size.x, size.y));
    static const int tri[6] = { 0, 1, 2, 1, 3, 2 };
    for (int i : tri) {
        o.indices.push_back(v0 + i);
    }
}

void runs(int32_t mask, double span, std::vector<Run> &out) {
    out.clear();
    if (mask == ALL_STANDING) {
        out.push_back({ 0.0f, (float)span });
        return;
    }
    if (mask == 0) {
        return;
    }
    const uint32_t bits = (uint32_t)mask;
    const double step = span / (double)SEGMENTS;
    int i = 0;
    while (i < SEGMENTS) {
        if (((bits >> i) & 1u) == 0) {
            i += 1;
            continue;
        }
        int j = i;
        while (j + 1 < SEGMENTS && ((bits >> (j + 1)) & 1u) == 1) {
            j += 1;
        }
        out.push_back({ (float)(i * step), (float)((j + 1) * step) });
        i = j + 1;
    }
}

double lo(double v, double tw) {
    return std::max(v, tw);
}

double hi(double v, double span, double tw) {
    return std::min(v, span - tw);
}

void band(Out &o, const Color &col, double y0, double y1, double w, double d, double tw,
        bool hollow, const int32_t *m) {
    const double h = y1 - y0;
    // No mask: every side standing.
    const int32_t mf = m ? m[FRONT] : ALL_STANDING;
    const int32_t mb = m ? m[BACK] : ALL_STANDING;
    const int32_t ml = m ? m[LEFT] : ALL_STANDING;
    const int32_t mr = m ? m[RIGHT] : ALL_STANDING;
    std::vector<Run> rf, rb, rl, rr;
    runs(mf, w, rf);
    runs(mb, w, rb);
    runs(ml, d, rl);
    runs(mr, d, rr);

    for (const Run &r : rf) {
        quad(o, col, Vector3(r.lo, y0, 0), Vector3(r.hi, y0, 0), Vector3(r.lo, y1, 0),
                Vector3(r.hi, y1, 0), Vector3(0, 0, -1),
                Vector2((double)r.hi - (double)r.lo, h), SEAM_UNIT);
    }
    for (const Run &r : rb) {
        quad(o, col, Vector3(r.hi, y0, d), Vector3(r.lo, y0, d), Vector3(r.hi, y1, d),
                Vector3(r.lo, y1, d), Vector3(0, 0, 1),
                Vector2((double)r.hi - (double)r.lo, h), SEAM_UNIT);
    }
    for (const Run &r : rl) {
        quad(o, col, Vector3(0, y0, r.hi), Vector3(0, y0, r.lo), Vector3(0, y1, r.hi),
                Vector3(0, y1, r.lo), Vector3(-1, 0, 0),
                Vector2((double)r.hi - (double)r.lo, h), SEAM_UNIT);
    }
    for (const Run &r : rr) {
        quad(o, col, Vector3(w, y0, r.lo), Vector3(w, y0, r.hi), Vector3(w, y1, r.lo),
                Vector3(w, y1, r.hi), Vector3(1, 0, 0),
                Vector2((double)r.hi - (double)r.lo, h), SEAM_UNIT);
    }
    if (!hollow) {
        return;
    }
    // Inner faces take the outer face's mask: a hole goes through the wall.
    for (const Run &r : rf) {
        quad(o, col, Vector3(hi(r.hi, w, tw), y0, tw), Vector3(lo(r.lo, tw), y0, tw),
                Vector3(hi(r.hi, w, tw), y1, tw), Vector3(lo(r.lo, tw), y1, tw),
                Vector3(0, 0, 1), Vector2((double)r.hi - (double)r.lo, h), SEAM_UNIT);
    }
    for (const Run &r : rb) {
        quad(o, col, Vector3(lo(r.lo, tw), y0, d - tw), Vector3(hi(r.hi, w, tw), y0, d - tw),
                Vector3(lo(r.lo, tw), y1, d - tw), Vector3(hi(r.hi, w, tw), y1, d - tw),
                Vector3(0, 0, -1), Vector2((double)r.hi - (double)r.lo, h), SEAM_UNIT);
    }
    for (const Run &r : rl) {
        quad(o, col, Vector3(tw, y0, lo(r.lo, tw)), Vector3(tw, y0, hi(r.hi, d, tw)),
                Vector3(tw, y1, lo(r.lo, tw)), Vector3(tw, y1, hi(r.hi, d, tw)),
                Vector3(1, 0, 0), Vector2((double)r.hi - (double)r.lo, h), SEAM_UNIT);
    }
    for (const Run &r : rr) {
        quad(o, col, Vector3(w - tw, y0, hi(r.hi, d, tw)), Vector3(w - tw, y0, lo(r.lo, tw)),
                Vector3(w - tw, y1, hi(r.hi, d, tw)), Vector3(w - tw, y1, lo(r.lo, tw)),
                Vector3(-1, 0, 0), Vector2((double)r.hi - (double)r.lo, h), SEAM_UNIT);
    }
}

// A horizontal slab face; winding as BuildingShell._cap.
void cap(Out &o, const Color &col, double y, double w, double d, bool upward) {
    if (upward) {
        quad(o, col, Vector3(0, y, 0), Vector3(w, y, 0), Vector3(0, y, d), Vector3(w, y, d),
                Vector3(0, 1, 0), Vector2(w, d), SEAM_UNIT_FLAT);
    } else {
        quad(o, col, Vector3(0, y, 0), Vector3(0, y, d), Vector3(w, y, 0), Vector3(w, y, d),
                Vector3(0, -1, 0), Vector2(w, d), SEAM_UNIT_FLAT);
    }
}

void ring_cap(Out &o, const Color &col, double y, double w, double d, double tw) {
    const Vector3 n(0, 1, 0);
    quad(o, col, Vector3(0, y, 0), Vector3(w, y, 0), Vector3(0, y, tw), Vector3(w, y, tw),
            n, Vector2(w, tw), SEAM_UNIT_FLAT);
    quad(o, col, Vector3(0, y, d - tw), Vector3(w, y, d - tw), Vector3(0, y, d), Vector3(w, y, d),
            n, Vector2(w, tw), SEAM_UNIT_FLAT);
    quad(o, col, Vector3(0, y, tw), Vector3(tw, y, tw), Vector3(0, y, d - tw), Vector3(tw, y, d - tw),
            n, Vector2(tw, d - tw * 2.0), SEAM_UNIT_FLAT);
    quad(o, col, Vector3(w - tw, y, tw), Vector3(w, y, tw), Vector3(w - tw, y, d - tw),
            Vector3(w, y, d - tw), n, Vector2(tw, d - tw * 2.0), SEAM_UNIT_FLAT);
}

} // namespace

Array ShellMesher::build_arrays(int footprint_x, int footprint_z, int wall_thick,
        const PackedInt32Array &bands, const PackedInt32Array &masks) {
    Out o;
    const double w = footprint_x * STUD;
    const double d = footprint_z * STUD;
    const double tw = wall_thick * STUD;
    const int count = (int)bands.size() / 4;
    const bool have_masks = masks.size() >= (int64_t)count * 5;
    const int32_t *bp = bands.ptr();
    const int32_t *mp = have_masks ? masks.ptr() : nullptr;

    double top = 0.0;
    Color top_colour = BrickWorld::get_filament_colour(2); // TowerRecipe.SLAB_COLOUR
    bool top_hollow = false;
    for (int k = 0; k < count; k++) {
        const int kind = bp[k * 4 + 0];
        const int y = bp[k * 4 + 1];
        const int plates = bp[k * 4 + 2];
        const Color col = BrickWorld::get_filament_colour(bp[k * 4 + 3]);
        const int32_t *m = (mp && mp[k * 5] != 0) ? mp + k * 5 + 1 : nullptr;

        // Every side shot away: no walls and no floor.
        if (m && m[0] == 0 && m[1] == 0 && m[2] == 0 && m[3] == 0) {
            top_hollow = false;
            continue;
        }
        const double y0 = y * PLATE;
        const double h = plates * PLATE;
        const double y1 = y0 + h;

        if (kind == BASE || kind == SLAB) {
            band(o, col, y0, y1, w, d, 0.0, false, m);
            cap(o, col, y1, w, d, true);
            if (kind != BASE) {
                cap(o, col, y0, w, d, false);
            }
            top = y1;
            top_colour = col;
            top_hollow = false;
            continue;
        }
        if (kind == CORNICE) {
            // A run along the front only (BuildingShell.build_arrays says why).
            const int32_t front = m ? m[FRONT] : ALL_STANDING;
            if (front != 0) {
                const int32_t only_front[4] = { front, 0, 0, 0 };
                band(o, col, y0, y1, w, d, 0.0, false, only_front);
            }
            continue;
        }
        band(o, col, y0, y1, w, d, tw, true, m);
        top = y1;
        top_colour = col;
        top_hollow = true;
    }
    if (top_hollow) {
        ring_cap(o, top_colour, top, w, d, tw);
    }

    Array arrays;
    arrays.resize(Mesh::ARRAY_MAX);
    arrays[Mesh::ARRAY_VERTEX] = o.verts;
    arrays[Mesh::ARRAY_NORMAL] = o.normals;
    arrays[Mesh::ARRAY_COLOR] = o.colours;
    arrays[Mesh::ARRAY_TEX_UV] = o.uvs;
    arrays[Mesh::ARRAY_TEX_UV2] = o.uv2s;
    arrays[Mesh::ARRAY_INDEX] = o.indices;
    return arrays;
}

void ShellMesher::_bind_methods() {
    ClassDB::bind_static_method("ShellMesher",
            D_METHOD("build_arrays", "footprint_x", "footprint_z", "wall_thick", "bands", "masks"),
            &ShellMesher::build_arrays);
}
