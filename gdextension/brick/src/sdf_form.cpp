#include "sdf_form.h"

#include <godot_cpp/classes/mesh.hpp>
#include <godot_cpp/core/class_db.hpp>

#include <algorithm>
#include <cmath>
#include <cstring>
#include <vector>

using namespace godot;

namespace {

constexpr int64_t OFF = int64_t(1) << 20;

inline int fdiv(int a, int b) { return a >= 0 ? a / b : -((-a + b - 1) / b); }
inline int fmod_pos(int a, int b) { const int m = a % b; return m < 0 ? m + b : m; }

inline float clampb(float v) { return std::clamp(v, -SdfForm::BAND, SdfForm::BAND); }

// Inigo Quilez's polynomial smooth minimum: min(a, b) rounded over `k`.
inline float smin(float a, float b, float k) {
    const float h = std::clamp(0.5f + 0.5f * (b - a) / k, 0.0f, 1.0f);
    return b + (a - b) * h - k * h * (1.0f - h);
}

inline float capsule_sdf(const Vector3 &p, const Vector3 &a, const Vector3 &b, float r) {
    const Vector3 pa = p - a, ba = b - a;
    const float l2 = ba.length_squared();
    const float h = l2 > 0.0f ? std::clamp(pa.dot(ba) / l2, 0.0f, 1.0f) : 0.0f;
    return (pa - ba * h).length() - r;
}

inline float box_sdf(const Vector3 &p, const Vector3 &c, const Vector3 &h) {
    const Vector3 q = (p - c).abs() - h;
    const Vector3 m(std::max(q.x, 0.0f), std::max(q.y, 0.0f), std::max(q.z, 0.0f));
    return m.length() + std::min(std::max(q.x, std::max(q.y, q.z)), 0.0f);
}

// Closest point on triangle abc to p (Ericson, Real-Time Collision Detection 5.1.5).
Vector3 closest_on_tri(const Vector3 &p, const Vector3 &a, const Vector3 &b, const Vector3 &c) {
    const Vector3 ab = b - a, ac = c - a, ap = p - a;
    const float d1 = ab.dot(ap), d2 = ac.dot(ap);
    if (d1 <= 0.0f && d2 <= 0.0f) return a;
    const Vector3 bp = p - b;
    const float d3 = ab.dot(bp), d4 = ac.dot(bp);
    if (d3 >= 0.0f && d4 <= d3) return b;
    const float vc = d1 * d4 - d3 * d2;
    if (vc <= 0.0f && d1 >= 0.0f && d3 <= 0.0f) return a + ab * (d1 / (d1 - d3));
    const Vector3 cp = p - c;
    const float d5 = ab.dot(cp), d6 = ac.dot(cp);
    if (d6 >= 0.0f && d5 <= d6) return c;
    const float vb = d5 * d2 - d1 * d6;
    if (vb <= 0.0f && d2 >= 0.0f && d6 <= 0.0f) return a + ac * (d2 / (d2 - d6));
    const float va = d3 * d6 - d5 * d4;
    if (va <= 0.0f && (d4 - d3) >= 0.0f && (d5 - d6) >= 0.0f)
        return b + (c - b) * ((d4 - d3) / ((d4 - d3) + (d5 - d6)));
    const float den = 1.0f / (va + vb + vc);
    return a + ab * (vb * den) + ac * (vc * den);
}

inline int sidx(int x, int y, int z) { return x + SdfForm::B * (y + SdfForm::B * z); }

void new_block(SdfForm::Block &b) {
    std::fill(std::begin(b.d), std::end(b.d), SdfForm::BAND);
    std::memset(b.part, 0, sizeof(b.part));
    std::memset(b.flag, 0, sizeof(b.flag));
}

template <typename T>
void bput(PackedByteArray &out, const T &v) {
    const int64_t at = out.size();
    out.resize(at + (int64_t)sizeof(T));
    std::memcpy(out.ptrw() + at, &v, sizeof(T));
}

template <typename T>
bool bget(const PackedByteArray &in, int64_t &at, T &v) {
    if (at + (int64_t)sizeof(T) > in.size()) return false;
    std::memcpy(&v, in.ptr() + at, sizeof(T));
    at += (int64_t)sizeof(T);
    return true;
}

} // namespace

void SdfForm::_bind_methods() {
    ClassDB::bind_method(D_METHOD("stroke", "op", "a", "b", "radius", "blend", "part"), &SdfForm::stroke);
    ClassDB::bind_method(D_METHOD("box", "op", "center", "half", "blend", "part"), &SdfForm::box);
    ClassDB::bind_method(D_METHOD("shape", "op", "kind", "xform", "size", "blend", "part"), &SdfForm::shape);
    ClassDB::bind_method(D_METHOD("flatten", "center", "radius", "normal", "point", "strength", "part"),
            &SdfForm::flatten);
    ClassDB::bind_method(D_METHOD("stamp_mesh", "op", "verts", "index", "part"), &SdfForm::stamp_mesh);
    ClassDB::bind_method(D_METHOD("scale", "factor", "pivot"), &SdfForm::scale);
    ClassDB::bind_method(D_METHOD("blur", "passes"), &SdfForm::blur);
    ClassDB::bind_method(D_METHOD("clear"), &SdfForm::clear);
    ClassDB::bind_method(D_METHOD("cells"), &SdfForm::cells);
    ClassDB::bind_method(D_METHOD("sync_cells", "before", "after"), &SdfForm::sync_cells);
    ClassDB::bind_method(D_METHOD("begin_edit"), &SdfForm::begin_edit);
    ClassDB::bind_method(D_METHOD("end_edit"), &SdfForm::end_edit);
    ClassDB::bind_method(D_METHOD("swap_blocks", "record"), &SdfForm::swap_blocks);
    ClassDB::bind_method(D_METHOD("take_dirty"), &SdfForm::take_dirty);
    ClassDB::bind_method(D_METHOD("block_keys"), &SdfForm::block_keys);
    ClassDB::bind_method(D_METHOD("mesh_block", "b", "palette"), &SdfForm::mesh_block);
    ClassDB::bind_method(D_METHOD("raycast", "from", "dir", "max_dist"), &SdfForm::raycast);
    ClassDB::bind_method(D_METHOD("sample", "p"), &SdfForm::sample);
    ClassDB::bind_method(D_METHOD("part_near", "p"), &SdfForm::part_near);
    ClassDB::bind_method(D_METHOD("bounds"), &SdfForm::bounds);
    ClassDB::bind_method(D_METHOD("block_count"), &SdfForm::block_count);
    ClassDB::bind_method(D_METHOD("part_field", "part", "lo", "dims", "smooth_only"), &SdfForm::part_field, DEFVAL(false));
    ClassDB::bind_method(D_METHOD("to_bytes"), &SdfForm::to_bytes);
    ClassDB::bind_method(D_METHOD("from_bytes", "bytes"), &SdfForm::from_bytes);
    BIND_CONSTANT(ADD);
    BIND_CONSTANT(REMOVE);
    BIND_CONSTANT(SMOOTH);
    BIND_CONSTANT(PAINT);
    BIND_CONSTANT(MARK);
    BIND_CONSTANT(UNMARK);
    BIND_CONSTANT(GROW);
    BIND_CONSTANT(SHAPE_BOX);
    BIND_CONSTANT(SHAPE_CONE);
}

int64_t SdfForm::key(int bx, int by, int bz) {
    return ((int64_t)bx + OFF) | (((int64_t)by + OFF) << 21) | (((int64_t)bz + OFF) << 42);
}

Vector3i SdfForm::unkey(int64_t k) {
    const int64_t m = (int64_t(1) << 21) - 1;
    return Vector3i((int)((k & m) - OFF), (int)(((k >> 21) & m) - OFF), (int)(((k >> 42) & m) - OFF));
}

SdfForm::Block *SdfForm::find(int64_t k) const {
    auto it = blocks.find(k);
    return it == blocks.end() ? nullptr : it->second.get();
}

SdfForm::Block *SdfForm::touch(int64_t k, bool create) {
    Block *b = find(k);
    if (!b && !create) {
        return nullptr;
    }
    if (recording && undo.find(k) == undo.end()) {
        if (b) {
            auto copy = std::make_unique<Block>();
            std::memcpy(copy.get(), b, sizeof(Block));
            undo[k] = std::move(copy);
        } else {
            undo[k] = nullptr;
        }
    }
    dirty[k] = true;
    if (!b) {
        auto nb = std::make_unique<Block>();
        new_block(*nb);
        b = nb.get();
        blocks[k] = std::move(nb);
    }
    return b;
}

float SdfForm::d_at(int i, int j, int k) const {
    const Block *b = find(key(fdiv(i, B), fdiv(j, B), fdiv(k, B)));
    return b ? b->d[sidx(fmod_pos(i, B), fmod_pos(j, B), fmod_pos(k, B))] : BAND;
}

uint8_t SdfForm::part_at(int i, int j, int k) const {
    const Block *b = find(key(fdiv(i, B), fdiv(j, B), fdiv(k, B)));
    return b ? b->part[sidx(fmod_pos(i, B), fmod_pos(j, B), fmod_pos(k, B))] : 0;
}

uint8_t SdfForm::flag_at(int i, int j, int k) const {
    const Block *b = find(key(fdiv(i, B), fdiv(j, B), fdiv(k, B)));
    return b ? b->flag[sidx(fmod_pos(i, B), fmod_pos(j, B), fmod_pos(k, B))] : 0;
}

float SdfForm::trilinear(const Vector3 &p) const {
    const Vector3 q = p - Vector3(0.5f, 0.5f, 0.5f);
    const int x = (int)std::floor(q.x), y = (int)std::floor(q.y), z = (int)std::floor(q.z);
    const float fx = q.x - x, fy = q.y - y, fz = q.z - z;
    float c[2][2][2];
    for (int dz = 0; dz < 2; ++dz)
        for (int dy = 0; dy < 2; ++dy)
            for (int dx = 0; dx < 2; ++dx) c[dz][dy][dx] = d_at(x + dx, y + dy, z + dz);
    auto lx = [&](int dy, int dz) { return c[dz][dy][0] + (c[dz][dy][1] - c[dz][dy][0]) * fx; };
    const float a = lx(0, 0) + (lx(1, 0) - lx(0, 0)) * fy;
    const float b = lx(0, 1) + (lx(1, 1) - lx(0, 1)) * fy;
    return a + (b - a) * fz;
}

template <typename F>
void SdfForm::each(const Vector3i &lo, const Vector3i &hi, bool create, F fn) {
    for (int bz = fdiv(lo.z, B); bz <= fdiv(hi.z, B); ++bz) {
        for (int by = fdiv(lo.y, B); by <= fdiv(hi.y, B); ++by) {
            for (int bx = fdiv(lo.x, B); bx <= fdiv(hi.x, B); ++bx) {
                Block *blk = touch(key(bx, by, bz), create);
                if (!blk) {
                    continue;
                }
                const int x0 = std::max(lo.x, bx * B), x1 = std::min(hi.x, bx * B + B - 1);
                const int y0 = std::max(lo.y, by * B), y1 = std::min(hi.y, by * B + B - 1);
                const int z0 = std::max(lo.z, bz * B), z1 = std::min(hi.z, bz * B + B - 1);
                for (int z = z0; z <= z1; ++z)
                    for (int y = y0; y <= y1; ++y)
                        for (int x = x0; x <= x1; ++x)
                            fn(blk, sidx(x - bx * B, y - by * B, z - bz * B), Vector3i(x, y, z));
            }
        }
    }
}

void SdfForm::apply_shape(int op, const Vector3i &lo, const Vector3i &hi, float blend, int part,
        float (*sdf)(const Vector3 &, const void *), const void *ctx) {
    const uint8_t label = (uint8_t)std::clamp(part, 0, 255);
    auto at = [&](const Vector3i &s) { return sdf(Vector3(s.x + 0.5f, s.y + 0.5f, s.z + 0.5f), ctx); };
    switch (op) {
        case ADD:
            each(lo, hi, true, [&](Block *b, int i, const Vector3i &s) {
                const float v = at(s), old = b->d[i];
                const float nd = blend > 0.0f ? smin(old, v, blend) : std::min(old, v);
                if (v < old) {
                    b->part[i] = label;
                }
                b->d[i] = clampb(nd);
            });
            break;
        case REMOVE:
            each(lo, hi, false, [&](Block *b, int i, const Vector3i &s) {
                const float v = at(s), old = b->d[i];
                b->d[i] = clampb(blend > 0.0f ? -smin(-old, v, blend) : std::max(old, -v));
            });
            break;
        case SMOOTH: {
            // Blurred within the shape (Zylann's do_smooth_sphere): every sample toward the
            // mean of its 27, by `blend` where the shape is a sample or more deep.
            std::vector<std::pair<Vector3i, float>> next;
            const float k = std::clamp(blend, 0.0f, 1.0f);
            each(lo, hi, false, [&](Block *b, int i, const Vector3i &s) {
                const float w = k * std::clamp(-at(s), 0.0f, 1.0f);
                if (w <= 0.0f) return;
                float sum = 0.0f;
                for (int dz = -1; dz <= 1; ++dz)
                    for (int dy = -1; dy <= 1; ++dy)
                        for (int dx = -1; dx <= 1; ++dx) sum += d_at(s.x + dx, s.y + dy, s.z + dz);
                next.push_back({s, b->d[i] + (sum / 27.0f - b->d[i]) * w});
            });
            for (const auto &n : next) {
                Block *b = touch(key(fdiv(n.first.x, B), fdiv(n.first.y, B), fdiv(n.first.z, B)), false);
                b->d[sidx(fmod_pos(n.first.x, B), fmod_pos(n.first.y, B), fmod_pos(n.first.z, B))] = clampb(n.second);
            }
            break;
        }
        case PAINT:
        case MARK:
        case UNMARK:
            each(lo, hi, false, [&](Block *b, int i, const Vector3i &s) {
                if (at(s) >= 0.0f) return;
                if (op == PAINT) b->part[i] = label;
                else b->flag[i] = op == MARK ? 1 : 0;
            });
            break;
        default:
            break;
    }
}

namespace {
struct Capsule { Vector3 a, b; float r; };
float capsule_fn(const Vector3 &p, const void *c) {
    const Capsule *k = (const Capsule *)c;
    return capsule_sdf(p, k->a, k->b, k->r);
}
struct Box { Vector3 c, h; };
float box_fn(const Vector3 &p, const void *c) {
    const Box *k = (const Box *)c;
    return box_sdf(p, k->c, k->h);
}
// Inigo Quilez's capped cone: r1 at y = -h, r2 at y = +h.
float capped_cone_sdf(const Vector3 &p, float h, float r1, float r2) {
    const Vector2 q(Vector2(p.x, p.z).length(), p.y);
    const Vector2 k1(r2, h);
    const Vector2 k2(r2 - r1, 2.0f * h);
    const Vector2 ca(q.x - std::min(q.x, q.y < 0.0f ? r1 : r2), std::abs(q.y) - h);
    const Vector2 cb = q - k1 + k2 * std::clamp((k1 - q).dot(k2) / k2.dot(k2), 0.0f, 1.0f);
    const float s = (cb.x < 0.0f && ca.y < 0.0f) ? -1.0f : 1.0f;
    return s * std::sqrt(std::min(ca.dot(ca), cb.dot(cb)));
}
struct Placed { Transform3D inv; int kind; Vector3 size; };
float placed_fn(const Vector3 &p, const void *c) {
    const Placed *k = (const Placed *)c;
    const Vector3 l = k->inv.xform(p);
    if (k->kind == SdfForm::SHAPE_BOX) return box_sdf(l, Vector3(), k->size);
    return capped_cone_sdf(l, k->size.y, k->size.x, k->size.z);
}
Vector3i floor3(const Vector3 &v) {
    return Vector3i((int)std::floor(v.x), (int)std::floor(v.y), (int)std::floor(v.z));
}
Vector3i ceil3(const Vector3 &v) {
    return Vector3i((int)std::ceil(v.x), (int)std::ceil(v.y), (int)std::ceil(v.z));
}
} // namespace

void SdfForm::stroke(int op, const Vector3 &a, const Vector3 &b, float radius, float blend, int part) {
    if (op == GROW) {
        grow(a, b, radius, blend, part);
        return;
    }
    const Capsule c{a, b, std::max(radius, 0.01f)};
    const float reach = c.r + BAND + std::max(blend, 0.0f) + 1.0f;
    const Vector3 r(reach, reach, reach);
    apply_shape(op, floor3(a.min(b) - r), ceil3(a.max(b) + r), blend, part, capsule_fn, &c);
}

void SdfForm::box(int op, const Vector3 &center, const Vector3 &half, float blend, int part) {
    const Box k{center, half.abs()};
    const float reach = BAND + std::max(blend, 0.0f) + 1.0f;
    const Vector3 r = k.h + Vector3(reach, reach, reach);
    apply_shape(op, floor3(center - r), ceil3(center + r), blend, part, box_fn, &k);
}

void SdfForm::shape(int op, int kind, const Transform3D &xform, const Vector3 &size, float blend, int part) {
    if (op == SMOOTH || op == GROW) return;
    const Vector3 s = size.abs();
    const Placed k{xform.affine_inverse(), kind, s};
    const Vector3 ext = kind == SHAPE_BOX ? s : Vector3(std::max(s.x, s.z), s.y, std::max(s.x, s.z));
    const float reach = BAND + std::max(blend, 0.0f) + 1.0f;
    Vector3 mn(1e30f, 1e30f, 1e30f), mx(-1e30f, -1e30f, -1e30f);
    for (int c = 0; c < 8; ++c) {
        const Vector3 p = xform.xform(Vector3(c & 1 ? ext.x : -ext.x, c & 2 ? ext.y : -ext.y, c & 4 ? ext.z : -ext.z));
        mn = mn.min(p);
        mx = mx.max(p);
    }
    const Vector3 r(reach, reach, reach);
    apply_shape(op, floor3(mn - r), ceil3(mx + r), blend, part, placed_fn, &k);
}

void SdfForm::grow(const Vector3 &a, const Vector3 &b, float radius, float amount, int part) {
    const float r = std::max(radius, 0.5f);
    const uint8_t label = (uint8_t)std::clamp(part, 0, 255);
    const Vector3 e(r + 1.0f, r + 1.0f, r + 1.0f);
    each(floor3(a.min(b) - e), ceil3(a.max(b) + e), amount > 0.0f, [&](Block *blk, int i, const Vector3i &s) {
        const float v = capsule_sdf(Vector3(s.x + 0.5f, s.y + 0.5f, s.z + 0.5f), a, b, r);
        const float w = std::clamp(-v / r, 0.0f, 1.0f);
        if (w <= 0.0f) return;
        const float old = blk->d[i];
        const float nd = clampb(old - amount * w);
        if (nd < 0.0f && old >= 0.0f) blk->part[i] = label;
        blk->d[i] = nd;
    });
}

void SdfForm::flatten(const Vector3 &center, float radius, const Vector3 &normal, const Vector3 &point,
        float strength, int part) {
    const float r = std::max(radius, 0.5f);
    const Vector3 n = normal.length_squared() > 0.0f ? normal.normalized() : Vector3(0, 1, 0);
    const float k = std::clamp(strength, 0.0f, 1.0f);
    const uint8_t label = (uint8_t)std::clamp(part, 0, 255);
    const Vector3 e(r + 1.0f, r + 1.0f, r + 1.0f);
    each(floor3(center - e), ceil3(center + e), true, [&](Block *blk, int i, const Vector3i &s) {
        const Vector3 p(s.x + 0.5f, s.y + 0.5f, s.z + 0.5f);
        const float w = k * std::clamp((r - p.distance_to(center)) / (0.5f * r), 0.0f, 1.0f);
        if (w <= 0.0f) return;
        const float old = blk->d[i];
        const float nd = clampb(old + (n.dot(p - point) - old) * w);
        if (nd < 0.0f && old >= 0.0f) blk->part[i] = label;
        blk->d[i] = nd;
    });
}

void SdfForm::cell_box(const Vector3i &c, int op, int part) {
    const Vector3 lo((float)(c.x * STUD), (float)(c.y * PLATE), (float)(c.z * STUD));
    const Vector3 half(STUD * 0.5f, PLATE * 0.5f, STUD * 0.5f);
    box(op, lo + half, half, 0.0f, part);
}

void SdfForm::stamp_mesh(int op, const PackedVector3Array &verts, const PackedInt32Array &index, int part) {
    const int64_t nt = index.size() / 3;
    if (nt == 0 || verts.is_empty()) {
        return;
    }
    Vector3 mn = verts[0], mx = verts[0];
    for (int64_t i = 0; i < verts.size(); ++i) {
        mn = mn.min(verts[i]);
        mx = mx.max(verts[i]);
    }
    const Vector3 r(BAND + 1.0f, BAND + 1.0f, BAND + 1.0f);
    const Vector3i lo = floor3(mn - r), hi = ceil3(mx + r);
    const Vector3i D = hi - lo + Vector3i(1, 1, 1);
    const int64_t n = (int64_t)D.x * D.y * D.z;
    if (n > 400000000) {
        return; // over 1.6 GB of distances: refuse rather than stall
    }
    auto didx = [&](int x, int y, int z) { return (int64_t)x + (int64_t)D.x * ((int64_t)y + (int64_t)D.y * z); };
    std::vector<float> ud((size_t)n, BAND);
    std::vector<std::vector<float>> rows((size_t)D.y * D.z);
    const Vector3 *v = verts.ptr();
    const int32_t *ix = index.ptr();
    for (int64_t t = 0; t < nt; ++t) {
        const int32_t i0 = ix[t * 3], i1 = ix[t * 3 + 1], i2 = ix[t * 3 + 2];
        if (i0 < 0 || i1 < 0 || i2 < 0 || i0 >= verts.size() || i1 >= verts.size() || i2 >= verts.size()) {
            continue;
        }
        const Vector3 a = v[i0], b = v[i1], c = v[i2];
        // Distance: every sample within BAND of the triangle's box.
        const Vector3i tlo = floor3(a.min(b).min(c) - r) - lo, thi = ceil3(a.max(b).max(c) + r) - lo;
        for (int z = std::max(0, tlo.z); z <= std::min(D.z - 1, thi.z); ++z)
            for (int y = std::max(0, tlo.y); y <= std::min(D.y - 1, thi.y); ++y)
                for (int x = std::max(0, tlo.x); x <= std::min(D.x - 1, thi.x); ++x) {
                    const Vector3 p((float)(x + lo.x) + 0.5f, (float)(y + lo.y) + 0.5f, (float)(z + lo.z) + 0.5f);
                    const float d = (p - closest_on_tri(p, a, b, c)).length();
                    float &u = ud[(size_t)didx(x, y, z)];
                    u = std::min(u, d);
                }
        // Inside: where a row of samples along x crosses the triangle (nudged off
        // sample centres so a row never runs exactly through an edge).
        const float ylo = std::min(a.y, std::min(b.y, c.y)), yhi = std::max(a.y, std::max(b.y, c.y));
        const float zlo = std::min(a.z, std::min(b.z, c.z)), zhi = std::max(a.z, std::max(b.z, c.z));
        for (int z = std::max(0, (int)std::floor(zlo) - lo.z - 1); z <= std::min(D.z - 1, (int)std::ceil(zhi) - lo.z); ++z) {
            const float pz = (float)(z + lo.z) + 0.5f + 1.3e-4f;
            for (int y = std::max(0, (int)std::floor(ylo) - lo.y - 1); y <= std::min(D.y - 1, (int)std::ceil(yhi) - lo.y); ++y) {
                const float py = (float)(y + lo.y) + 0.5f + 0.7e-4f;
                // Barycentric of (py, pz) in the triangle projected on y-z.
                const float d = (b.y - a.y) * (c.z - a.z) - (c.y - a.y) * (b.z - a.z);
                if (std::abs(d) < 1e-12f) continue;
                const float l1 = ((py - a.y) * (c.z - a.z) - (c.y - a.y) * (pz - a.z)) / d;
                const float l2 = ((b.y - a.y) * (pz - a.z) - (py - a.y) * (b.z - a.z)) / d;
                if (l1 < 0.0f || l2 < 0.0f || l1 + l2 > 1.0f) continue;
                rows[(size_t)y + (size_t)D.y * z].push_back(a.x + l1 * (b.x - a.x) + l2 * (c.x - a.x));
            }
        }
    }
    std::vector<float> sd((size_t)n);
    for (int z = 0; z < D.z; ++z)
        for (int y = 0; y < D.y; ++y) {
            std::vector<float> &row = rows[(size_t)y + (size_t)D.y * z];
            std::sort(row.begin(), row.end());
            size_t at = 0;
            for (int x = 0; x < D.x; ++x) {
                const float px = (float)(x + lo.x) + 0.5f;
                while (at < row.size() && row[at] < px) ++at;
                const int64_t i = didx(x, y, z);
                sd[(size_t)i] = (at & 1) ? -ud[(size_t)i] : ud[(size_t)i];
            }
        }
    struct Ctx { const std::vector<float> *sd; Vector3i lo, D; };
    const Ctx ctx{&sd, lo, D};
    auto fn = [](const Vector3 &p, const void *c) -> float {
        const Ctx *k = (const Ctx *)c;
        const int x = (int)std::floor(p.x) - k->lo.x, y = (int)std::floor(p.y) - k->lo.y, z = (int)std::floor(p.z) - k->lo.z;
        if (x < 0 || y < 0 || z < 0 || x >= k->D.x || y >= k->D.y || z >= k->D.z) return SdfForm::BAND;
        return (*k->sd)[(size_t)x + (size_t)k->D.x * ((size_t)y + (size_t)k->D.y * z)];
    };
    apply_shape(op, lo, hi, 0.0f, part, fn, &ctx);
}

void SdfForm::scale(float factor, const Vector3 &pivot) {
    if (factor <= 0.0f || blocks.empty()) {
        return;
    }
    // Only the blocks a stored block lands on (not the whole box round them: a stroke
    // far off made that box hundreds of thousands of blocks, minutes of work), and a
    // sample is kept near only where its source is within the band -- empty space has
    // no block, and scaled down it must stay empty, not become BAND * factor.
    std::unordered_map<int64_t, bool> want;
    for (const auto &kv : blocks) {
        const Vector3 o = Vector3(unkey(kv.first)) * (float)B;
        const Vector3i lo = floor3(pivot + (o - pivot) * factor) - Vector3i(1, 1, 1);
        const Vector3i hi = ceil3(pivot + (o + Vector3(B, B, B) - pivot) * factor) + Vector3i(1, 1, 1);
        for (int bz = fdiv(lo.z, B); bz <= fdiv(hi.z, B); ++bz)
            for (int by = fdiv(lo.y, B); by <= fdiv(hi.y, B); ++by)
                for (int bx = fdiv(lo.x, B); bx <= fdiv(hi.x, B); ++bx)
                    want[key(bx, by, bz)] = true;
    }
    std::unordered_map<int64_t, std::unique_ptr<Block>> out;
    for (const auto &w : want) {
        const Vector3i bc = unkey(w.first);
        auto nb = std::make_unique<Block>();
        bool near = false;
        for (int z = 0; z < B; ++z)
            for (int y = 0; y < B; ++y)
                for (int x = 0; x < B; ++x) {
                    const Vector3 p((float)(bc.x * B + x) + 0.5f, (float)(bc.y * B + y) + 0.5f, (float)(bc.z * B + z) + 0.5f);
                    const Vector3 src = pivot + (p - pivot) / factor;
                    const float ds = trilinear(src);
                    const float d = ds < BAND ? clampb(ds * factor) : BAND;
                    const Vector3i s = floor3(src);
                    const int i = sidx(x, y, z);
                    nb->d[i] = d;
                    nb->part[i] = part_at(s.x, s.y, s.z);
                    nb->flag[i] = flag_at(s.x, s.y, s.z);
                    near = near || d < BAND;
                }
        if (near) out[w.first] = std::move(nb);
    }
    for (const auto &kv : blocks) touch(kv.first, false);
    for (const auto &kv : out) {
        if (recording && undo.find(kv.first) == undo.end()) {
            Block *old = find(kv.first);
            if (old) {
                auto copy = std::make_unique<Block>();
                std::memcpy(copy.get(), old, sizeof(Block));
                undo[kv.first] = std::move(copy);
            } else {
                undo[kv.first] = nullptr;
            }
        }
        dirty[kv.first] = true;
    }
    blocks.swap(out);
}

void SdfForm::blur(int passes) {
    for (int it = 0; it < passes; ++it) {
        std::vector<std::pair<int64_t, std::vector<float>>> next;
        for (const auto &kv : blocks) {
            const Vector3i o = unkey(kv.first) * B;
            std::vector<float> d(B3);
            for (int z = 0; z < B; ++z)
                for (int y = 0; y < B; ++y)
                    for (int x = 0; x < B; ++x) {
                        float sum = 0.0f;
                        for (int dz = -1; dz <= 1; ++dz)
                            for (int dy = -1; dy <= 1; ++dy)
                                for (int dx = -1; dx <= 1; ++dx) sum += d_at(o.x + x + dx, o.y + y + dy, o.z + z + dz);
                        d[sidx(x, y, z)] = clampb(sum / 27.0f);
                    }
            next.push_back({kv.first, std::move(d)});
        }
        for (auto &n : next) {
            Block *b = touch(n.first, false);
            std::copy(n.second.begin(), n.second.end(), b->d);
        }
    }
}

void SdfForm::clear() {
    for (const auto &kv : blocks) touch(kv.first, false);
    blocks.clear();
}

PackedInt32Array SdfForm::cells() const {
    struct C { int x, y, z, part, flag; };
    std::vector<C> out;
    for (const auto &kv : blocks) {
        const Vector3i o = unkey(kv.first) * B;
        const Block *b = kv.second.get();
        for (int z = 0; z < B; ++z) {
            if (fmod_pos(o.z + z, STUD) != 2) continue;
            for (int y = 0; y < B; y += 2) { // a plate's two samples are both in this block
                for (int x = 0; x < B; ++x) {
                    if (fmod_pos(o.x + x, STUD) != 2) continue;
                    const int i = sidx(x, y, z);
                    if (b->d[i] + b->d[sidx(x, y + 1, z)] >= 0.0f) continue;
                    out.push_back({fdiv(o.x + x, STUD), fdiv(o.y + y, PLATE), fdiv(o.z + z, STUD), b->part[i], b->flag[i]});
                }
            }
        }
    }
    std::sort(out.begin(), out.end(), [](const C &a, const C &b) {
        if (a.y != b.y) return a.y < b.y;
        if (a.z != b.z) return a.z < b.z;
        return a.x < b.x;
    });
    PackedInt32Array r;
    r.resize((int64_t)out.size() * 5);
    int32_t *w = r.ptrw();
    for (size_t i = 0; i < out.size(); ++i) {
        w[i * 5] = out[i].x;
        w[i * 5 + 1] = out[i].y;
        w[i * 5 + 2] = out[i].z;
        w[i * 5 + 3] = out[i].part;
        w[i * 5 + 4] = out[i].flag;
    }
    return r;
}

void SdfForm::sync_cells(const PackedInt32Array &before, const PackedInt32Array &after) {
    auto ck = [](int x, int y, int z) { return key(x, y, z); }; // cells fit the same packing
    std::unordered_map<int64_t, int> a, b;
    for (int64_t i = 0; i + 4 < before.size(); i += 5)
        a[ck(before[i], before[i + 1], before[i + 2])] = before[i + 3];
    for (int64_t i = 0; i + 4 < after.size(); i += 5)
        b[ck(after[i], after[i + 1], after[i + 2])] = after[i + 3];
    for (const auto &kv : a) {
        if (b.find(kv.first) == b.end()) cell_box(unkey(kv.first), REMOVE, 0);
    }
    for (const auto &kv : b) {
        auto it = a.find(kv.first);
        if (it == a.end()) {
            cell_box(unkey(kv.first), ADD, kv.second);
        } else if (it->second != kv.second) {
            const Vector3i c = unkey(kv.first);
            const Vector3i lo(c.x * STUD, c.y * PLATE, c.z * STUD);
            const uint8_t label = (uint8_t)std::clamp(kv.second, 0, 255);
            each(lo, lo + Vector3i(STUD - 1, PLATE - 1, STUD - 1), false,
                    [&](Block *blk, int i, const Vector3i &) { blk->part[i] = label; });
        }
    }
}

void SdfForm::begin_edit() {
    recording = true;
    undo.clear();
}

PackedByteArray SdfForm::end_edit() {
    PackedByteArray out;
    bput<int32_t>(out, (int32_t)undo.size());
    for (const auto &kv : undo) {
        bput<int64_t>(out, kv.first);
        bput<uint8_t>(out, kv.second ? 1 : 0);
        if (kv.second) {
            const int64_t at = out.size();
            out.resize(at + (int64_t)sizeof(Block));
            std::memcpy(out.ptrw() + at, kv.second.get(), sizeof(Block));
        }
    }
    undo.clear();
    recording = false;
    return out;
}

PackedByteArray SdfForm::swap_blocks(const PackedByteArray &record) {
    PackedByteArray out;
    int64_t at = 0;
    int32_t n = 0;
    if (!bget(record, at, n)) return out;
    bput<int32_t>(out, n);
    for (int32_t e = 0; e < n; ++e) {
        int64_t k = 0;
        uint8_t present = 0;
        if (!bget(record, at, k) || !bget(record, at, present)) break;
        Block *cur = find(k);
        bput<int64_t>(out, k);
        bput<uint8_t>(out, cur ? 1 : 0);
        if (cur) {
            const int64_t o = out.size();
            out.resize(o + (int64_t)sizeof(Block));
            std::memcpy(out.ptrw() + o, cur, sizeof(Block));
        }
        dirty[k] = true;
        if (present) {
            if (at + (int64_t)sizeof(Block) > record.size()) break;
            if (!cur) {
                blocks[k] = std::make_unique<Block>();
                cur = blocks[k].get();
            }
            std::memcpy(cur, record.ptr() + at, sizeof(Block));
            at += (int64_t)sizeof(Block);
        } else {
            blocks.erase(k);
        }
    }
    return out;
}

Array SdfForm::take_dirty() {
    // A block's surface reads one sample past it each way: a change also re-meshes the
    // blocks round it.
    std::unordered_map<int64_t, bool> all;
    for (const auto &kv : dirty) {
        const Vector3i c = unkey(kv.first);
        all[kv.first] = true;
        for (int dz = -1; dz <= 1; ++dz)
            for (int dy = -1; dy <= 1; ++dy)
                for (int dx = -1; dx <= 1; ++dx) {
                    const int64_t k = key(c.x + dx, c.y + dy, c.z + dz);
                    if (find(k)) all[k] = true;
                }
    }
    dirty.clear();
    Array out;
    for (const auto &kv : all) out.push_back(unkey(kv.first));
    return out;
}

Array SdfForm::block_keys() const {
    Array out;
    for (const auto &kv : blocks) out.push_back(unkey(kv.first));
    return out;
}

Array SdfForm::mesh_block(const Vector3i &bc, const PackedColorArray &palette) const {
    // Samples [-1, B] of the block each way; cubes [0, B] of those (cube c has samples
    // c and c + 1); a quad across every edge whose lower sample is the block's own --
    // so each edge is meshed by exactly one block and the blocks meet without a crack.
    constexpr int S = B + 2;
    constexpr int C = B + 1;
    const Vector3i o = bc * B - Vector3i(1, 1, 1);
    std::vector<float> d((size_t)S * S * S);
    bool any_in = false, any_out = false;
    auto li = [&](int x, int y, int z) { return (size_t)x + (size_t)S * ((size_t)y + (size_t)S * z); };
    for (int z = 0; z < S; ++z)
        for (int y = 0; y < S; ++y)
            for (int x = 0; x < S; ++x) {
                const float v = d_at(o.x + x, o.y + y, o.z + z);
                d[li(x, y, z)] = v;
                any_in = any_in || v < 0.0f;
                any_out = any_out || v >= 0.0f;
            }
    if (!any_in || !any_out) return Array();

    static const int CORNER[8][3] = {
        {0, 0, 0}, {1, 0, 0}, {0, 1, 0}, {1, 1, 0}, {0, 0, 1}, {1, 0, 1}, {0, 1, 1}, {1, 1, 1}};
    static const int EDGE[12][2] = {
        {0, 1}, {2, 3}, {4, 5}, {6, 7}, {0, 2}, {1, 3}, {4, 6}, {5, 7}, {0, 4}, {1, 5}, {2, 6}, {3, 7}};
    auto ci = [&](int x, int y, int z) { return (size_t)x + (size_t)C * ((size_t)y + (size_t)C * z); };
    std::vector<int32_t> vert_of((size_t)C * C * C, -1);
    PackedVector3Array verts;
    for (int z = 0; z < C; ++z)
        for (int y = 0; y < C; ++y)
            for (int x = 0; x < C; ++x) {
                float v[8];
                int in = 0;
                for (int k = 0; k < 8; ++k) {
                    v[k] = d[li(x + CORNER[k][0], y + CORNER[k][1], z + CORNER[k][2])];
                    in += v[k] < 0.0f ? 1 : 0;
                }
                if (in == 0 || in == 8) continue;
                Vector3 sum;
                int n = 0;
                for (const auto &e : EDGE) {
                    const float a = v[e[0]], b = v[e[1]];
                    if ((a < 0.0f) == (b < 0.0f)) continue;
                    const float t = a / (a - b);
                    sum += Vector3(CORNER[e[0]][0] + t * (CORNER[e[1]][0] - CORNER[e[0]][0]),
                            CORNER[e[0]][1] + t * (CORNER[e[1]][1] - CORNER[e[0]][1]),
                            CORNER[e[0]][2] + t * (CORNER[e[1]][2] - CORNER[e[0]][2]));
                    ++n;
                }
                vert_of[ci(x, y, z)] = (int32_t)verts.size();
                verts.push_back(Vector3((float)(o.x + x), (float)(o.y + y), (float)(o.z + z)) + sum / (float)n +
                        Vector3(0.5f, 0.5f, 0.5f));
            }
    PackedInt32Array index;
    for (int axis = 0; axis < 3; ++axis) {
        const int u = (axis + 1) % 3, w = (axis + 2) % 3;
        for (int z = 1; z <= B; ++z)
            for (int y = 1; y <= B; ++y)
                for (int x = 1; x <= B; ++x) {
                    int p[3] = {x, y, z};
                    int q[3] = {x, y, z};
                    q[axis] += 1;
                    const bool a = d[li(p[0], p[1], p[2])] < 0.0f;
                    const bool b = d[li(q[0], q[1], q[2])] < 0.0f;
                    if (a == b) continue;
                    static const int RING[4][2] = {{0, 0}, {1, 0}, {1, 1}, {0, 1}};
                    int32_t quad[4];
                    bool ok = true;
                    for (int k = 0; k < 4 && ok; ++k) {
                        int c[3] = {p[0], p[1], p[2]};
                        c[u] -= 1 - RING[k][0];
                        c[w] -= 1 - RING[k][1];
                        quad[k] = vert_of[ci(c[0], c[1], c[2])];
                        ok = quad[k] >= 0;
                    }
                    if (!ok) continue;
                    // As FormMesher: counter-clockwise seen from +axis, reversed when the
                    // solid is at p (Godot's front faces are clockwise).
                    if (a) std::swap(quad[1], quad[3]);
                    const float d02 = (verts[quad[0]] - verts[quad[2]]).length_squared();
                    const float d13 = (verts[quad[1]] - verts[quad[3]]).length_squared();
                    if (d02 <= d13) {
                        for (int32_t t : {quad[0], quad[1], quad[2], quad[0], quad[2], quad[3]}) index.push_back(t);
                    } else {
                        for (int32_t t : {quad[0], quad[1], quad[3], quad[1], quad[2], quad[3]}) index.push_back(t);
                    }
                }
    }
    if (index.is_empty()) return Array();
    PackedVector3Array normals;
    PackedColorArray colors;
    normals.resize(verts.size());
    colors.resize(verts.size());
    for (int64_t i = 0; i < verts.size(); ++i) {
        const Vector3 p = verts[i];
        const float e = 0.5f;
        const Vector3 g(trilinear(p + Vector3(e, 0, 0)) - trilinear(p - Vector3(e, 0, 0)),
                trilinear(p + Vector3(0, e, 0)) - trilinear(p - Vector3(0, e, 0)),
                trilinear(p + Vector3(0, 0, e)) - trilinear(p - Vector3(0, 0, e)));
        normals.set(i, g.length_squared() > 0.0f ? g.normalized() : Vector3(0, 1, 0));
        const Vector3i s = floor3(p);
        const int part = part_at(s.x, s.y, s.z);
        Color col = part < palette.size() ? palette[part] : Color(1, 1, 1);
        // Marked smooth: lighter, so the areas that will be custom pieces stand out.
        if (flag_at(s.x, s.y, s.z)) col = col.lerp(Color(1, 1, 1), 0.45f);
        colors.set(i, col);
    }
    Array out;
    out.resize(Mesh::ARRAY_MAX);
    out[Mesh::ARRAY_VERTEX] = verts;
    out[Mesh::ARRAY_NORMAL] = normals;
    out[Mesh::ARRAY_COLOR] = colors;
    out[Mesh::ARRAY_INDEX] = index;
    return out;
}

Variant SdfForm::raycast(const Vector3 &from, const Vector3 &dir, float max_dist) const {
    if (dir.length_squared() == 0.0f) return Variant();
    const Vector3 n = dir.normalized();
    float t = 0.0f, prev = 0.0f;
    if (trilinear(from) < 0.0f) return from;
    while (t <= max_dist) {
        const float v = trilinear(from + n * t);
        if (v < 0.0f) {
            float a = prev, b = t;
            for (int i = 0; i < 16; ++i) {
                const float m = (a + b) * 0.5f;
                (trilinear(from + n * m) < 0.0f ? b : a) = m;
            }
            return from + n * b;
        }
        prev = t;
        t += std::max(v * 0.8f, 0.2f);
    }
    return Variant();
}

float SdfForm::sample(const Vector3 &p) const { return trilinear(p); }

int SdfForm::part_near(const Vector3 &p) const {
    const Vector3i s = floor3(p);
    return part_at(s.x, s.y, s.z);
}

AABB SdfForm::bounds() const {
    Vector3i mn(INT32_MAX, INT32_MAX, INT32_MAX), mx(INT32_MIN, INT32_MIN, INT32_MIN);
    bool any = false;
    for (const auto &kv : blocks) {
        const Vector3i o = unkey(kv.first) * B;
        for (int z = 0; z < B; ++z)
            for (int y = 0; y < B; ++y)
                for (int x = 0; x < B; ++x) {
                    if (kv.second->d[sidx(x, y, z)] >= 0.0f) continue;
                    const Vector3i s = o + Vector3i(x, y, z);
                    mn = mn.min(s);
                    mx = mx.max(s);
                    any = true;
                }
    }
    return any ? AABB(Vector3(mn), Vector3(mx - mn + Vector3i(1, 1, 1))) : AABB();
}

int SdfForm::block_count() const { return (int)blocks.size(); }

PackedFloat32Array SdfForm::part_field(int part, const Vector3i &lo, const Vector3i &dims, bool smooth_only) const {
    PackedFloat32Array out;
    if (dims.x <= 0 || dims.y <= 0 || dims.z <= 0) return out;
    out.resize((int64_t)dims.x * dims.y * dims.z);
    float *w = out.ptrw();
    int64_t i = 0;
    for (int z = 0; z < dims.z; ++z)
        for (int y = 0; y < dims.y; ++y)
            for (int x = 0; x < dims.x; ++x, ++i) {
                float d = d_at(lo.x + x, lo.y + y, lo.z + z);
                if ((part != 0 && part_at(lo.x + x, lo.y + y, lo.z + z) != part) ||
                        (smooth_only && !flag_at(lo.x + x, lo.y + y, lo.z + z))) {
                    d = std::max(d, 0.5f);
                }
                w[i] = d;
            }
    return out;
}

PackedByteArray SdfForm::to_bytes() const {
    PackedByteArray out;
    bput<uint32_t>(out, 0x31464453u); // "SDF1"
    bput<int32_t>(out, (int32_t)blocks.size());
    for (const auto &kv : blocks) {
        bput<int64_t>(out, kv.first);
        const int64_t at = out.size();
        out.resize(at + (int64_t)sizeof(Block));
        std::memcpy(out.ptrw() + at, kv.second.get(), sizeof(Block));
    }
    return out;
}

bool SdfForm::from_bytes(const PackedByteArray &bytes) {
    int64_t at = 0;
    uint32_t magic = 0;
    int32_t n = 0;
    if (!bget(bytes, at, magic) || magic != 0x31464453u || !bget(bytes, at, n) || n < 0) return false;
    std::unordered_map<int64_t, std::unique_ptr<Block>> in;
    for (int32_t e = 0; e < n; ++e) {
        int64_t k = 0;
        if (!bget(bytes, at, k) || at + (int64_t)sizeof(Block) > bytes.size()) return false;
        auto b = std::make_unique<Block>();
        std::memcpy(b.get(), bytes.ptr() + at, sizeof(Block));
        at += (int64_t)sizeof(Block);
        in[k] = std::move(b);
    }
    clear();
    for (auto &kv : in) {
        touch(kv.first, false);
        dirty[kv.first] = true;
        if (recording && undo.find(kv.first) == undo.end()) undo[kv.first] = nullptr;
        blocks[kv.first] = std::move(kv.second);
    }
    return true;
}
