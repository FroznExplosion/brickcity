#include "ai_scheduler.h"

#include <godot_cpp/core/class_db.hpp>

#include <algorithm>
#include <chrono>

using namespace godot;

namespace {

uint64_t now_usec() {
    return (uint64_t)std::chrono::duration_cast<std::chrono::microseconds>(
            std::chrono::steady_clock::now().time_since_epoch())
            .count();
}

// Budget at each level of the ladder, as a fraction of the base.
constexpr float LEVEL_BUDGET[AIScheduler::LEVEL_MAX + 1] = { 1.0f, 0.8f, 0.6f, 0.45f, 0.3f };

} // namespace

void AIScheduler::_bind_methods() {
    ClassDB::bind_method(D_METHOD("submit", "subsystem", "priority", "job", "must_run"),
            &AIScheduler::submit, DEFVAL(false));
    ClassDB::bind_method(D_METHOD("queued"), &AIScheduler::queued);
    ClassDB::bind_method(D_METHOD("queued_in", "subsystem"), &AIScheduler::queued_in);
    ClassDB::bind_method(D_METHOD("clear"), &AIScheduler::clear);
    ClassDB::bind_method(D_METHOD("run"), &AIScheduler::run);
    ClassDB::bind_method(D_METHOD("run_for", "budget_usec"), &AIScheduler::run_for);
    ClassDB::bind_method(D_METHOD("set_base_budget_ms", "ms"), &AIScheduler::set_base_budget_ms);
    ClassDB::bind_method(D_METHOD("get_base_budget_ms"), &AIScheduler::get_base_budget_ms);
    ClassDB::bind_method(D_METHOD("report_destruction_ms", "ms"), &AIScheduler::report_destruction_ms);
    ClassDB::bind_method(D_METHOD("set_thresholds", "heavy_ms", "quiet_ms"), &AIScheduler::set_thresholds);
    ClassDB::bind_method(D_METHOD("set_hysteresis", "frames_down", "frames_up"),
            &AIScheduler::set_hysteresis);
    ClassDB::bind_method(D_METHOD("get_level"), &AIScheduler::get_level);
    ClassDB::bind_method(D_METHOD("get_max_level_seen"), &AIScheduler::get_max_level_seen);
    ClassDB::bind_method(D_METHOD("get_budget_ms"), &AIScheduler::get_budget_ms);
    ClassDB::bind_method(D_METHOD("get_baseline_ms"), &AIScheduler::get_baseline_ms);
    ClassDB::bind_method(D_METHOD("rate_scale", "subsystem"), &AIScheduler::rate_scale);
    ClassDB::bind_method(D_METHOD("get_stats"), &AIScheduler::get_stats);
    ClassDB::bind_method(D_METHOD("get_last_run_usec"), &AIScheduler::get_last_run_usec);
    ClassDB::bind_method(D_METHOD("get_last_overrun_usec"), &AIScheduler::get_last_overrun_usec);

    BIND_ENUM_CONSTANT(PERCEPTION);
    BIND_ENUM_CONSTANT(NAV);
    BIND_ENUM_CONSTANT(TACTICAL);
    BIND_ENUM_CONSTANT(TREES);
    BIND_ENUM_CONSTANT(ONNX);
    BIND_ENUM_CONSTANT(COMMANDER);
    BIND_ENUM_CONSTANT(SUBSYSTEM_COUNT);
    BIND_CONSTANT(LEVEL_MAX);
}

// A job's place in line: its priority, plus what it has earned by waiting.
// Every waiting job gains `aging` a frame, so relative to each other only the
// frame it was born in matters, and the key never changes after it is queued --
// which is what lets this be a plain heap.
float AIScheduler::_score(const Job &j) const {
    return j.priority - aging * (float)j.born_frame;
}

bool AIScheduler::_before(const Job &a, const Job &b) const {
    // std heap is a max-heap on "less": b outranks a.
    const float sa = _score(a);
    const float sb = _score(b);
    if (sa != sb) {
        return sa < sb;
    }
    return a.id > b.id;   // equal: first in, first out
}

int AIScheduler::submit(int subsystem, float priority, const Callable &job, bool must_run) {
    Job j;
    j.id = next_id++;
    j.subsystem = std::clamp(subsystem, 0, SUBSYSTEM_COUNT - 1);
    j.priority = priority;
    j.born_frame = frame;
    j.must_run = must_run;
    j.call = job;
    heap.push_back(j);
    std::push_heap(heap.begin(), heap.end(),
            [this](const Job &a, const Job &b) { return _before(a, b); });
    return j.id;
}

int AIScheduler::queued_in(int subsystem) const {
    int n = 0;
    for (const Job &j : heap) {
        if (j.subsystem == subsystem) {
            n++;
        }
    }
    return n;
}

void AIScheduler::clear() {
    heap.clear();
}

float AIScheduler::get_budget_ms() const {
    return base_budget_ms * LEVEL_BUDGET[std::clamp(level, 0, LEVEL_MAX)];
}

int AIScheduler::run() {
    return run_for((int)(get_budget_ms() * 1000.0f));
}

int AIScheduler::run_for(int budget_usec) {
    frame++;
    for (int s = 0; s < SUBSYSTEM_COUNT; ++s) {
        sub_usec[s] = 0;
        sub_ran[s] = 0;
        sub_deferred[s] = 0;
    }
    const uint64_t start = now_usec();
    auto less = [this](const Job &a, const Job &b) { return _before(a, b); };
    int ran = 0;

    // Must-run first, whatever they cost: evade and firing are never deferred.
    for (size_t i = 0; i < heap.size();) {
        if (!heap[i].must_run) {
            ++i;
            continue;
        }
        Job j = heap[i];
        heap[i] = heap.back();
        heap.pop_back();
        std::make_heap(heap.begin(), heap.end(), less);
        const uint64_t t0 = now_usec();
        if (j.call.is_valid()) {
            j.call.call();
        }
        sub_usec[j.subsystem] += now_usec() - t0;
        sub_ran[j.subsystem]++;
        ran++;
        i = 0;
    }

    // Then best-first until the budget is spent. The check is BEFORE each job,
    // so the overrun is at most one job -- which is why jobs must be small.
    while (!heap.empty() && (int64_t)(now_usec() - start) < (int64_t)budget_usec) {
        std::pop_heap(heap.begin(), heap.end(), less);
        Job j = heap.back();
        heap.pop_back();
        const uint64_t t0 = now_usec();
        if (j.call.is_valid()) {
            j.call.call();
        }
        sub_usec[j.subsystem] += now_usec() - t0;
        sub_ran[j.subsystem]++;
        ran++;
    }
    for (const Job &j : heap) {
        sub_deferred[j.subsystem]++;
    }
    last_run_usec = now_usec() - start;
    last_overrun_usec = last_run_usec > (uint64_t)std::max(budget_usec, 0)
            ? last_run_usec - (uint64_t)std::max(budget_usec, 0)
            : 0;
    last_ran = ran;
    return ran;
}

void AIScheduler::set_thresholds(float p_heavy_ms, float p_quiet_ms) {
    heavy_ms = p_heavy_ms;
    quiet_ms = std::min(p_quiet_ms, p_heavy_ms);
    baseline_ms = quiet_ms;
}

void AIScheduler::set_hysteresis(int p_frames_down, int p_frames_up) {
    frames_down = std::max(1, p_frames_down);
    frames_up = std::max(1, p_frames_up);
}

void AIScheduler::report_destruction_ms(float ms) {
    const float margin = std::max(heavy_ms - quiet_ms, 0.5f);
    const bool heavy = ms > heavy_ms && ms > baseline_ms + margin;
    const bool quiet = ms < quiet_ms || ms < baseline_ms + margin * 0.5f;
    // The city's normal: down quickly, up slowly -- a collapse lasting a few
    // seconds stays heavy, a load that lasts half a minute becomes normal.
    baseline_ms += (ms - baseline_ms) * (ms < baseline_ms ? 0.2f : 0.005f);
    if (heavy) {
        // Only a STREAK of heavy frames is a collapse. One spike is not -- the
        // city does periodic work (streaming, trimming) that costs a tick in
        // thirty, and a quiet run that every one of those reset never finished.
        if (++heavy_run >= frames_down) {
            heavy_run = 0;
            quiet_run = 0;
            level = std::min(level + 1, LEVEL_MAX);
            max_level_seen = std::max(max_level_seen, level);
        }
    } else if (quiet) {
        heavy_run = 0;
        if (++quiet_run >= frames_up) {
            quiet_run = 0;
            level = std::max(level - 1, 0);
        }
    } else {
        // In between: hold where we are. It breaks a run of heavy frames but not
        // a run of quiet ones -- a big city at rest jitters about its normal,
        // and a quiet run that any jitter reset would never finish.
        heavy_run = 0;
    }
}

float AIScheduler::rate_scale(int subsystem) const {
    float s = 1.0f;
    // AI.md 10.3 rule 7, in order: the directed tier's rate, perception rays,
    // fewer smart agents, the commander's rate.
    if (subsystem == TREES && level >= 1) {
        s *= 0.5f;
    }
    if (subsystem == PERCEPTION && level >= 2) {
        s *= 0.5f;
    }
    if (subsystem == TREES && level >= 3) {
        s *= 0.5f;
    }
    if (subsystem == COMMANDER && level >= 4) {
        s *= 0.5f;
    }
    return s;
}

Dictionary AIScheduler::get_stats() const {
    static const char *NAMES[SUBSYSTEM_COUNT] = { "perception", "nav", "tactical", "trees", "onnx",
        "commander" };
    Dictionary d;
    for (int s = 0; s < SUBSYSTEM_COUNT; ++s) {
        Dictionary sub;
        sub["ms"] = (double)sub_usec[s] / 1000.0;
        sub["ran"] = sub_ran[s];
        sub["deferred"] = sub_deferred[s];
        d[NAMES[s]] = sub;
    }
    d["ran"] = last_ran;
    d["queued"] = (int)heap.size();
    d["run_ms"] = (double)last_run_usec / 1000.0;
    d["overrun_ms"] = (double)last_overrun_usec / 1000.0;
    d["budget_ms"] = get_budget_ms();
    d["level"] = level;
    d["max_level_seen"] = max_level_seen;
    d["baseline_ms"] = baseline_ms;
    return d;
}
