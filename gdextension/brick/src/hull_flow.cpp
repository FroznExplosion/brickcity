#include "hull_flow.h"

#include <godot_cpp/core/class_db.hpp>

#include <algorithm>
#include <cmath>

void HullFlow::setup(Vector3i p_dims) {
    dims = p_dims;
    const size_t n = (size_t)std::max(0, dims.x * dims.y * dims.z);
    fill.assign(n, 0.0f);
    pass.assign(n, 0);
    in_wet.assign(n, 0);
    in_moving.assign(n, 0);
    wet_list.clear();
    moving.clear();
    dried = 0.0;
}

void HullFlow::set_passable(const PackedByteArray &state, int inside_state, const PackedInt32Array &open_door_cells) {
    const size_t n = fill.size();
    if ((size_t)state.size() != n) {
        return;
    }
    const uint8_t *s = state.ptr();
    for (size_t i = 0; i < n; ++i) {
        pass[i] = s[i] == (uint8_t)inside_state ? 1 : 0;
    }
    for (int k = 0; k < open_door_cells.size(); ++k) {
        const int i = open_door_cells[k];
        if (i >= 0 && (size_t)i < n) {
            pass[i] = 1;
        }
    }
}

float HullFlow::get(int i) const {
    return (i >= 0 && (size_t)i < fill.size()) ? fill[i] : 0.0f;
}

float HullFlow::level(int i) const {
    return std::min(get(i), 1.0f);
}

bool HullFlow::is_passable(int i) const {
    return i >= 0 && (size_t)i < pass.size() && pass[i] != 0;
}

void HullFlow::mark_wet(int i) {
    if (!in_wet[i]) {
        in_wet[i] = 1;
        wet_list.push_back(i);
    }
}

void HullFlow::mark_moving(int i, std::vector<int32_t> &into, std::vector<uint8_t> &flag) {
    if (!flag[i]) {
        flag[i] = 1;
        into.push_back(i);
    }
}

void HullFlow::set_fill(int i, float v) {
    if (i < 0 || (size_t)i >= fill.size()) {
        return;
    }
    fill[i] = std::max(v, 0.0f);
    if (fill[i] > 0.0f) {
        mark_wet(i);
    }
    mark_moving(i, moving, in_moving);
}

float HullFlow::add(int i, float v) {
    if (i < 0 || (size_t)i >= fill.size()) {
        return 0.0f;
    }
    const float before = fill[i];
    fill[i] = std::max(before + v, 0.0f);
    if (fill[i] > 0.0f) {
        mark_wet(i);
    }
    mark_moving(i, moving, in_moving);
    return fill[i] - before;
}

int HullFlow::move(int i, int step) const {
    const int j = i + step;
    if (j < 0 || (size_t)j >= fill.size()) {
        return -1;
    }
    const int sy = dims.x;
    const int sz = dims.x * dims.y;
    if (std::abs(step) == 1 && i / sy != j / sy) {
        return -1;
    }
    if (std::abs(step) == sy && i / sz != j / sz) {
        return -1;
    }
    return j;
}

void HullFlow::wake_all() {
    for (int32_t i : wet_list) {
        mark_moving(i, moving, in_moving);
    }
}

bool HullFlow::flow(int down_step, const PackedInt32Array &lateral, const PackedFloat32Array &weights,
        int passes, float side, float up, float dry, float still) {
    bool any = false;
    const int nl = std::min((int)lateral.size(), (int)weights.size());
    std::vector<int32_t> next;
    std::vector<uint8_t> in_next(fill.size(), 0);
    for (int p = 0; p < passes && !moving.empty(); ++p) {
        next.clear();
        for (int32_t i : moving) {
            in_moving[i] = 0;
        }
        for (int32_t i : moving) {
            float w = fill[i];
            if (w <= dry) {
                if (w > 0.0f) {
                    dried += w;
                    fill[i] = 0.0f;
                }
                continue;
            }
            bool moved = false;
            const int j = move(i, down_step);
            if (j >= 0 && pass[j] && fill[j] < 1.0f) {
                const float m = std::min(w, 1.0f - fill[j]);
                if (m > still) {
                    fill[i] -= m;
                    fill[j] += m;
                    mark_wet(j);
                    mark_moving(j, next, in_next);
                    moved = true;
                    w = fill[i];
                }
            }
            for (int k = 0; k < nl && w > dry; ++k) {
                const int n = move(i, lateral[k]);
                if (n < 0 || !pass[n] || fill[n] >= w) {
                    continue;
                }
                const float m = (w - fill[n]) * side * weights[k];
                if (m <= still) {
                    continue;
                }
                fill[i] -= m;
                fill[n] += m;
                mark_wet(n);
                mark_moving(n, next, in_next);
                moved = true;
                w = fill[i];
            }
            if (w > 1.0f) {
                const int u = move(i, -down_step);
                if (u >= 0 && pass[u]) {
                    const float m = (w - 1.0f) * up;
                    if (m > still) {
                        fill[i] -= m;
                        fill[u] += m;
                        mark_wet(u);
                        mark_moving(u, next, in_next);
                        moved = true;
                    }
                }
            }
            if (fill[i] <= dry) {
                dried += fill[i];
                fill[i] = 0.0f;
            } else if (moved) {
                mark_moving(i, next, in_next);
            }
            any = any || moved;
        }
        for (int32_t i : next) {
            in_next[i] = 0;
        }
        moving.swap(next);
        for (int32_t i : moving) {
            in_moving[i] = 1;
        }
    }
    compact_wet();
    return any;
}

void HullFlow::compact_wet() {
    size_t k = 0;
    for (size_t r = 0; r < wet_list.size(); ++r) {
        const int32_t i = wet_list[r];
        if (fill[i] > 0.0f) {
            wet_list[k++] = i;
        } else {
            in_wet[i] = 0;
        }
    }
    wet_list.resize(k);
}

PackedInt32Array HullFlow::wet() const {
    PackedInt32Array out;
    out.resize((int64_t)wet_list.size());
    int32_t *w = out.ptrw();
    for (size_t k = 0; k < wet_list.size(); ++k) {
        w[k] = wet_list[k];
    }
    return out;
}

int HullFlow::wet_count() const {
    return (int)wet_list.size();
}

int HullFlow::moving_count() const {
    return (int)moving.size();
}

double HullFlow::total() const {
    double t = 0.0;
    for (int32_t i : wet_list) {
        t += fill[i];
    }
    return t;
}

void HullFlow::_bind_methods() {
    ClassDB::bind_method(D_METHOD("setup", "dims"), &HullFlow::setup);
    ClassDB::bind_method(D_METHOD("set_passable", "state", "inside_state", "open_door_cells"), &HullFlow::set_passable);
    ClassDB::bind_method(D_METHOD("get", "i"), &HullFlow::get);
    ClassDB::bind_method(D_METHOD("level", "i"), &HullFlow::level);
    ClassDB::bind_method(D_METHOD("set_fill", "i", "v"), &HullFlow::set_fill);
    ClassDB::bind_method(D_METHOD("add", "i", "v"), &HullFlow::add);
    ClassDB::bind_method(D_METHOD("is_passable", "i"), &HullFlow::is_passable);
    ClassDB::bind_method(D_METHOD("flow", "down_step", "lateral", "weights", "passes", "side", "up", "dry", "still"),
            &HullFlow::flow);
    ClassDB::bind_method(D_METHOD("wake_all"), &HullFlow::wake_all);
    ClassDB::bind_method(D_METHOD("wet"), &HullFlow::wet);
    ClassDB::bind_method(D_METHOD("wet_count"), &HullFlow::wet_count);
    ClassDB::bind_method(D_METHOD("moving_count"), &HullFlow::moving_count);
    ClassDB::bind_method(D_METHOD("total"), &HullFlow::total);
    ClassDB::bind_method(D_METHOD("get_dried"), &HullFlow::get_dried);
}
