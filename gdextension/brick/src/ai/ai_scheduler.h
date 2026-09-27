#pragma once

// AIScheduler -- one budget for all AI work, and the arbiter that shares the
// frame with destruction (Docs/AI.md section 10.1, AIPlan P2 and R14).
//
// Everything the AI does is a JOB: a perception ray batch, a path request, a
// cover search, a tree tick, an ONNX batch. A job has a subsystem and a priority
// (the agent's importance), and the scheduler serves the queue best-first inside
// a per-frame millisecond budget. What does not fit waits for the next frame and
// ages while it waits, so nothing starves. Only jobs marked `must_run` -- evade
// and firing -- run whatever the budget says.
//
// The ARBITER: destruction reports what it spent this frame. When a collapse is
// eating the frame the AI steps DOWN its ladder -- a smaller budget, and a level
// the brains read to thin themselves out in a fixed order (AI.md 10.3 rule 7) --
// and steps back up once the frame is quiet again, with hysteresis both ways so
// it does not flap.

#include <godot_cpp/classes/ref_counted.hpp>
#include <godot_cpp/variant/callable.hpp>
#include <godot_cpp/variant/dictionary.hpp>

#include <cstdint>
#include <vector>

// The global namespace, as BrickWorld is (brick_world.h), so its `friend` finds us.
using namespace godot;

class AIScheduler : public RefCounted {
    GDCLASS(AIScheduler, RefCounted);

protected:
    static void _bind_methods();

public:
    enum Subsystem {
        PERCEPTION = 0,
        NAV,
        TACTICAL,
        TREES,
        ONNX,
        COMMANDER,
        SUBSYSTEM_COUNT,
    };

    /// Degradation levels, in the order AI.md 10.3 rule 7 gives: first the
    /// directed tier's rate, then perception rays, then fewer smart agents,
    /// then the commander's rate. Evade and firing are never on it.
    static constexpr int LEVEL_MAX = 4;

    /// Queue a job. Returns its id. `must_run` jobs run this frame whatever the
    /// budget -- evade and firing only.
    int submit(int subsystem, float priority, const Callable &job, bool must_run = false);
    int queued() const { return (int)heap.size(); }
    int queued_in(int subsystem) const;
    void clear();

    /// Serve the queue for up to the current budget. Returns how many ran.
    int run();
    /// Serve it for an explicit budget instead of the arbiter's, in microseconds.
    int run_for(int budget_usec);

    // --- the arbiter ---------------------------------------------------------

    /// The AI's budget with nothing else on: AI.md 10.1's 2.5 ms.
    void set_base_budget_ms(float ms) { base_budget_ms = ms; }
    float get_base_budget_ms() const { return base_budget_ms; }
    /// Destruction's spend this frame, in ms. Once a frame, before run().
    void report_destruction_ms(float ms);
    /// Heavy and quiet, relative to the city's own normal. A frame is HEAVY when
    /// destruction spends `heavy_ms - quiet_ms` more than its baseline and at
    /// least `heavy_ms`; QUIET when it is within half that of the baseline, or
    /// under `quiet_ms` outright. The baseline falls fast and rises slowly, so a
    /// collapse reads as heavy and a big city at rest reads as quiet -- a fixed
    /// threshold did neither for two hundred buildings, which tick at 6 ms
    /// doing nothing.
    void set_thresholds(float heavy_ms, float quiet_ms);
    float get_baseline_ms() const { return baseline_ms; }
    /// Frames of heavy load before stepping down one level, and of quiet
    /// before stepping back up.
    void set_hysteresis(int frames_down, int frames_up);
    int get_level() const { return level; }
    int get_max_level_seen() const { return max_level_seen; }
    /// The budget at the current level, ms.
    float get_budget_ms() const;
    /// 1.0 at level 0, lower as the ladder steps down: what a brain multiplies
    /// its own rate by. Directed trees read it from level 1, perception from 2.
    float rate_scale(int subsystem) const;

    // --- measuring -------------------------------------------------------------

    /// Per subsystem: {ms, ran, deferred, queued}, plus the frame's totals, the
    /// level and the budget. Counts are for the last run().
    Dictionary get_stats() const;
    /// Microseconds the last run() spent, and by how much it went over budget.
    int get_last_run_usec() const { return (int)last_run_usec; }
    int get_last_overrun_usec() const { return (int)last_overrun_usec; }

private:
    struct Job {
        int id = 0;
        int subsystem = 0;
        float priority = 0.0f;
        int64_t born_frame = 0;
        bool must_run = false;
        Callable call;
    };

    std::vector<Job> heap;
    int next_id = 1;
    int64_t frame = 0;
    // How much priority a frame of waiting is worth. A job that has waited long
    // enough overtakes fresher, more important work -- nothing starves.
    float aging = 0.5f;

    float base_budget_ms = 2.5f;
    float heavy_ms = 8.0f;
    float quiet_ms = 4.0f;
    int frames_down = 3;
    int frames_up = 30;
    int level = 0;
    int max_level_seen = 0;
    float baseline_ms = 4.0f;
    int heavy_run = 0;
    int quiet_run = 0;

    uint64_t sub_usec[SUBSYSTEM_COUNT] = {};
    int sub_ran[SUBSYSTEM_COUNT] = {};
    int sub_deferred[SUBSYSTEM_COUNT] = {};
    uint64_t last_run_usec = 0;
    uint64_t last_overrun_usec = 0;
    int last_ran = 0;

    float _score(const Job &j) const;
    bool _before(const Job &a, const Job &b) const;
};


VARIANT_ENUM_CAST(AIScheduler::Subsystem);
