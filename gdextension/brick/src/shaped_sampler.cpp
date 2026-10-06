#include "shaped_sampler.h"

#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/variant/packed_byte_array.hpp>
#include <godot_cpp/variant/packed_vector2_array.hpp>
#include <godot_cpp/variant/string.hpp>
#include <godot_cpp/variant/vector2.hpp>
#include <godot_cpp/variant/vector3.hpp>

#include <vector>

namespace {

struct Prism {
    std::vector<Vector2> poly;
    int plane = 2;   // 0 "zy", 1 "xy", 2 "xz"
    double lo = 0.0, hi = 0.0;
    double sgn = 1.0;
};

/// ShapedParts._from3: a point in the part -> profile point, extrusion.
inline void from3(int plane, const Vector3 &v, Vector2 &p, real_t &e) {
    switch (plane) {
        case 0: p = Vector2(v.z, v.y); e = v.x; break;
        case 1: p = Vector2(v.x, v.y); e = v.z; break;
        default: p = Vector2(v.x, v.z); e = v.y; break;
    }
}

/// ShapedParts._prism_has, with _inside: on the inner side of every edge.
bool has(const Prism &pr, const Vector3 &v) {
    Vector2 f;
    real_t e;
    from3(pr.plane, v, f, e);
    if ((double)e < pr.lo - 1e-6 || (double)e > pr.hi + 1e-6) {
        return false;
    }
    const size_t n = pr.poly.size();
    for (size_t i = 0; i < n; ++i) {
        const Vector2 a = pr.poly[i];
        const Vector2 ed = pr.poly[(i + 1) % n] - a;
        if ((double)ed.cross(f - a) * pr.sgn < -1e-9) {
            return false;
        }
    }
    return true;
}

bool any(const std::vector<Prism> &pieces, const Vector3 &v) {
    for (const Prism &pr : pieces) {
        if (has(pr, v)) {
            return true;
        }
    }
    return false;
}

} // namespace

Dictionary ShapedSampler::mask(const Array &pieces_in, const Vector3i &size, double S, double P, int samples) {
    std::vector<Prism> pieces;
    for (int64_t k = 0; k < pieces_in.size(); ++k) {
        const Dictionary d = pieces_in[k];
        Prism pr;
        const PackedVector2Array poly = d["poly"];
        for (int64_t i = 0; i < poly.size(); ++i) {
            pr.poly.push_back(poly[i]);
        }
        const String plane = d["plane"];
        pr.plane = plane == "zy" ? 0 : (plane == "xy" ? 1 : 2);
        pr.lo = (double)d["lo"];
        pr.hi = (double)d["hi"];
        // ShapedParts._signed_area: accumulated in a float64 from float crosses.
        double a = 0.0;
        for (size_t i = 0; i < pr.poly.size(); ++i) {
            a += (double)pr.poly[i].cross(pr.poly[(i + 1) % pr.poly.size()]);
        }
        a *= 0.5;
        pr.sgn = a > 0.0 ? 1.0 : (a < 0.0 ? -1.0 : 0.0);
        pieces.push_back(pr);
    }

    const int sx_n = size.x, sy_n = size.y, sz_n = size.z;
    PackedByteArray cells;
    cells.resize((int64_t)sx_n * sy_n * sz_n);
    uint8_t *cw = cells.ptrw();
    int solid = 0;
    const int total = samples * samples * samples;
    for (int z = 0; z < sz_n; ++z) {
        for (int y = 0; y < sy_n; ++y) {
            for (int x = 0; x < sx_n; ++x) {
                int hit = 0;
                for (int sy = 0; sy < samples; ++sy) {
                    for (int sz = 0; sz < samples; ++sz) {
                        for (int sx = 0; sx < samples; ++sx) {
                            const Vector3 v((real_t)((x + (sx + 0.5) / samples) * S),
                                    (real_t)((y + (sy + 0.5) / samples) * P),
                                    (real_t)((z + (sz + 0.5) / samples) * S));
                            if (any(pieces, v)) {
                                ++hit;
                            }
                        }
                    }
                }
                const bool on = hit * 2 >= total;
                cw[x + sx_n * (y + sy_n * z)] = on ? 1 : 0;
                solid += on ? 1 : 0;
            }
        }
    }

    PackedByteArray studs, sockets;
    studs.resize((int64_t)sx_n * sz_n);
    sockets.resize((int64_t)sx_n * sz_n);
    uint8_t *st = studs.ptrw();
    uint8_t *so = sockets.ptrw();
    static const double D[3] = { -0.2, 0.0, 0.2 };
    for (int z = 0; z < sz_n; ++z) {
        for (int x = 0; x < sx_n; ++x) {
            st[x + sx_n * z] = 0;
            so[x + sx_n * z] = 0;
            int top = -1;
            for (int y = 0; y < sy_n; ++y) {
                if (cw[x + sx_n * (y + sy_n * z)] != 0) {
                    top = y;
                }
            }
            if (top >= 0) {
                // ShapedParts._covered: the stud's inner footprint, nine points.
                const double yy = (top + 1) * P - 1e-4;
                bool covered = true;
                for (int i = 0; i < 3 && covered; ++i) {
                    for (int j = 0; j < 3 && covered; ++j) {
                        const Vector3 v((real_t)((x + 0.5 + D[i]) * S), (real_t)yy, (real_t)((z + 0.5 + D[j]) * S));
                        covered = any(pieces, v);
                    }
                }
                if (covered) {
                    st[x + sx_n * z] = 1;
                }
            }
            if (cw[x + sx_n * (sy_n * z)] != 0) {
                so[x + sx_n * z] = 1;
            }
        }
    }
    Dictionary out;
    out["cells"] = cells;
    out["studs"] = studs;
    out["sockets"] = sockets;
    out["solid"] = solid;
    return out;
}

void ShapedSampler::_bind_methods() {
    ClassDB::bind_static_method("ShapedSampler",
            D_METHOD("mask", "pieces", "size", "stud_m", "plate_m", "samples"), &ShapedSampler::mask);
}
