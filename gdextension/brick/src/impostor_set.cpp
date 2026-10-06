#include "impostor_set.h"

#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/variant/dictionary.hpp>
#include <godot_cpp/variant/packed_float32_array.hpp>

#include <algorithm>
#include <cmath>

void ImpostorSet::set_chunk(double metres) { chunk_m = std::max(metres, 1.0); }

Vector2i ImpostorSet::key(const Vector3 &p) const {
    return Vector2i((int)std::floor(p.x / chunk_m), (int)std::floor(p.z / chunk_m));
}

ImpostorSet::Chunk &ImpostorSet::chunk(const Vector2i &k) {
    const int64_t pk = pack(k);
    auto it = chunks.find(pk);
    if (it == chunks.end()) {
        chunk_keys[pk] = k;
        it = chunks.emplace(pk, Chunk()).first;
    }
    return it->second;
}

int ImpostorSet::add(const Transform3D &t, bool wanted) {
    int h;
    if (!free_list.empty()) {
        h = free_list.back();
        free_list.pop_back();
        xf[h] = t;
        want[h] = wanted ? 1 : 0;
        tier[h] = 0;
        is_free[h] = 0;
        chunk_of[h] = key(t.origin);
    } else {
        h = (int)xf.size();
        xf.push_back(t);
        want.push_back(wanted ? 1 : 0);
        tier.push_back(0);
        is_free.push_back(0);
        chunk_of.push_back(key(t.origin));
    }
    Chunk &c = chunk(chunk_of[h]);
    c.members.push_back(h);
    c.dirty = true;
    return h;
}

bool ImpostorSet::move(int h, const Transform3D &t) {
    if (h < 0 || h >= (int)xf.size() || is_free[h]) {
        return false;
    }
    xf[h] = t;
    const Vector2i k = key(t.origin);
    if (k != chunk_of[h]) {
        Chunk &old = chunk(chunk_of[h]);
        old.members.erase(std::remove(old.members.begin(), old.members.end(), h), old.members.end());
        old.dirty = true;
        chunk_of[h] = k;
        Chunk &c = chunk(k);
        c.members.push_back(h);
        c.dirty = true;
        return true;
    }
    if (tier[h] != 0) {
        chunk(k).dirty = true;
    }
    return false;
}

void ImpostorSet::remove(int h) {
    if (h < 0 || h >= (int)xf.size() || is_free[h]) {
        return;
    }
    want[h] = 0;
    Chunk &c = chunk(chunk_of[h]);
    c.members.erase(std::remove(c.members.begin(), c.members.end(), h), c.members.end());
    c.dirty = true;
    tier[h] = 0;
    is_free[h] = 1;
    free_list.push_back(h);
}

int ImpostorSet::count() const { return (int)xf.size() - (int)free_list.size(); }
int ImpostorSet::chunk_count() const { return (int)chunks.size(); }

void ImpostorSet::set_wanted(int h, bool on) {
    if (h < 0 || h >= (int)want.size()) {
        return;
    }
    const uint8_t v = on ? 1 : 0;
    if (want[h] != v) {
        want[h] = v;
        chunk(chunk_of[h]).dirty = true;
    }
}

int ImpostorSet::tier_of(int h) const { return (h >= 0 && h < (int)tier.size()) ? tier[h] : 0; }

Vector2i ImpostorSet::key_of(int h) const {
    return (h >= 0 && h < (int)chunk_of.size()) ? chunk_of[h] : Vector2i();
}

void ImpostorSet::mark_all_dirty() {
    for (auto &kv : chunks) {
        kv.second.dirty = true;
    }
}

void ImpostorSet::retier(int from, int to) {
    for (size_t i = 0; i < tier.size(); ++i) {
        if (tier[i] == from) {
            tier[i] = (uint8_t)to;
        }
    }
}

Array ImpostorSet::update(const Vector3 &here, double near_range, double cull_range, double hysteresis,
        bool blend, bool no_card) {
    Array out;
    near_count = 0;
    far_count = 0;
    const double hx = here.x, hz = here.z;
    for (auto &kv : chunks) {
        Chunk &c = kv.second;
        const Vector2i k = chunk_keys[kv.first];
        // The square's nearest and furthest points, flat: a whole square on
        // one side of a range edge is decided without looking inside it.
        const double lx = k.x * chunk_m, lz = k.y * chunk_m;
        const double cx = std::clamp(hx, lx, lx + chunk_m), cz = std::clamp(hz, lz, lz + chunk_m);
        const double nearest = std::hypot(cx - hx, cz - hz);
        double furthest = 0.0;
        for (int corner = 0; corner < 4; ++corner) {
            const double px = lx + ((corner & 1) ? chunk_m : 0.0), pz = lz + ((corner & 2) ? chunk_m : 0.0);
            furthest = std::max(furthest, std::hypot(px - hx, pz - hz));
        }
        int whole = -1;
        if (nearest > cull_range + chunk_m) {
            whole = 0;
        } else if (nearest > near_range + hysteresis + chunk_m * 0.1 && furthest < cull_range) {
            whole = 2;
        }
        bool changed = c.dirty;
        c.dirty = false;
        for (int h : c.members) {
            int t = 0;
            if (want[h] != 0) {
                if (whole >= 0) {
                    t = whole;
                } else {
                    const double d = (double)xf[h].origin.distance_to(here);
                    if (d > cull_range) {
                        t = 0;
                    } else if (blend) {
                        // The band is the fade itself: no hysteresis needed.
                        t = d < near_range - hysteresis ? 1 : (d > near_range + hysteresis ? 2 : 3);
                    } else if (tier[h] == 1) {
                        t = d < near_range + hysteresis ? 1 : 2;
                    } else {
                        t = d < near_range - hysteresis ? 1 : 2;
                    }
                }
                if (t == 2 && no_card) {
                    t = 1;
                }
            }
            if (t != tier[h]) {
                tier[h] = (uint8_t)t;
                changed = true;
            }
            if (tier[h] == 1 || tier[h] == 3) {
                ++near_count;
            }
            if (tier[h] == 2 || tier[h] == 3) {
                ++far_count;
            }
        }
        if (!changed) {
            continue;
        }
        PackedFloat32Array nb, fb;
        int n_near = 0, n_far = 0;
        for (int h : c.members) {
            n_near += (tier[h] == 1 || tier[h] == 3);
            n_far += (tier[h] == 2 || tier[h] == 3);
        }
        nb.resize((int64_t)n_near * 12);
        fb.resize((int64_t)n_far * 12);
        float *np = nb.ptrw();
        float *fp = fb.ptrw();
        AABB box;
        bool first = true;
        for (int h : c.members) {
            const uint8_t t = tier[h];
            if (t == 0) {
                continue;
            }
            const Transform3D &x = xf[h];
            const float row[12] = {
                (float)x.basis.rows[0][0], (float)x.basis.rows[0][1], (float)x.basis.rows[0][2], (float)x.origin.x,
                (float)x.basis.rows[1][0], (float)x.basis.rows[1][1], (float)x.basis.rows[1][2], (float)x.origin.y,
                (float)x.basis.rows[2][0], (float)x.basis.rows[2][1], (float)x.basis.rows[2][2], (float)x.origin.z,
            };
            if (t == 1 || t == 3) {
                std::copy(row, row + 12, np);
                np += 12;
            }
            if (t == 2 || t == 3) {
                std::copy(row, row + 12, fp);
                fp += 12;
                if (first) {
                    box = AABB(x.origin, Vector3());
                    first = false;
                } else {
                    box.expand_to(x.origin);
                }
            }
        }
        Dictionary d;
        d["key"] = k;
        d["near"] = nb;
        d["far"] = fb;
        d["n_near"] = n_near;
        d["n_far"] = n_far;
        d["far_box"] = box;
        d["has_far"] = !first;
        out.append(d);
    }
    return out;
}

void ImpostorSet::_bind_methods() {
    ClassDB::bind_method(D_METHOD("set_chunk", "metres"), &ImpostorSet::set_chunk);
    ClassDB::bind_method(D_METHOD("add", "xf", "wanted"), &ImpostorSet::add);
    ClassDB::bind_method(D_METHOD("move", "handle", "xf"), &ImpostorSet::move);
    ClassDB::bind_method(D_METHOD("remove", "handle"), &ImpostorSet::remove);
    ClassDB::bind_method(D_METHOD("count"), &ImpostorSet::count);
    ClassDB::bind_method(D_METHOD("chunk_count"), &ImpostorSet::chunk_count);
    ClassDB::bind_method(D_METHOD("set_wanted", "handle", "on"), &ImpostorSet::set_wanted);
    ClassDB::bind_method(D_METHOD("tier_of", "handle"), &ImpostorSet::tier_of);
    ClassDB::bind_method(D_METHOD("key_of", "handle"), &ImpostorSet::key_of);
    ClassDB::bind_method(D_METHOD("mark_all_dirty"), &ImpostorSet::mark_all_dirty);
    ClassDB::bind_method(D_METHOD("retier", "from", "to"), &ImpostorSet::retier);
    ClassDB::bind_method(D_METHOD("update", "here", "near_range", "cull_range", "hysteresis", "blend", "no_card"),
            &ImpostorSet::update);
    ClassDB::bind_method(D_METHOD("get_near_count"), &ImpostorSet::get_near_count);
    ClassDB::bind_method(D_METHOD("get_far_count"), &ImpostorSet::get_far_count);
}
