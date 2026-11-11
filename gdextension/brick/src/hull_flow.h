#pragma once

#include <godot_cpp/classes/ref_counted.hpp>
#include <godot_cpp/variant/packed_byte_array.hpp>
#include <godot_cpp/variant/packed_float32_array.hpp>
#include <godot_cpp/variant/packed_int32_array.hpp>
#include <godot_cpp/variant/vector3i.hpp>

#include <vector>

using namespace godot;

/// Water inside a hull, the automaton's flow (Docs/Hulls.md 5; scripts/hulls/hull_water.gd
/// keeps the holes, the pumps and the bookkeeping and calls this for the flow).
///
/// A fill a cell on the hull's air grid; water stands only in passable cells
/// (inside air, open doorways). A step runs `passes` passes over the cells whose
/// water moved last time, and what they touched: down the ship's down first (to
/// full), then aside (a share of the difference, weighted toward the low side),
/// then up where a cell is over full. A transfer under `still` is no move, so a
/// pool at rest drops out of the moving set and costs nothing until something
/// touches it (water added, the ship tipped: `wake_all`).
///
/// Was GDScript (hull_water.gd's _flow): a flooded boat's 2,700 wet cells,
/// rolling, cost more than the frame.
class HullFlow : public RefCounted {
    GDCLASS(HullFlow, RefCounted)

protected:
    static void _bind_methods();

public:
    void setup(Vector3i dims);
    /// Which cells water may stand in: HullAir's states (INSIDE passes) and the
    /// cells of doors that are open now.
    void set_passable(const PackedByteArray &state, int inside_state, const PackedInt32Array &open_door_cells);

    float get(int i) const;
    /// Capped at full: what is drawn and what weighs.
    float level(int i) const;
    void set_fill(int i, float v);
    /// `v` added to cell `i` (taken if negative, never below 0); it moves next step.
    float add(int i, float v);
    bool is_passable(int i) const;

    /// `passes` passes. `lateral` four grid steps aside, `weights` theirs.
    /// Returns whether any water moved.
    bool flow(int down_step, const PackedInt32Array &lateral, const PackedFloat32Array &weights,
            int passes, float side, float up, float dry, float still);
    void wake_all();

    PackedInt32Array wet() const;
    int wet_count() const;
    int moving_count() const;
    double total() const;
    /// Thin film under `dry` taken away by the flow, all told.
    double get_dried() const { return dried; }

private:
    Vector3i dims;
    std::vector<float> fill;
    std::vector<uint8_t> pass;
    std::vector<uint8_t> in_wet;
    std::vector<int32_t> wet_list;
    std::vector<uint8_t> in_moving;
    std::vector<int32_t> moving;
    double dried = 0.0;

    int move(int i, int step) const;
    void mark_wet(int i);
    void mark_moving(int i, std::vector<int32_t> &into, std::vector<uint8_t> &flag);
    void compact_wet();
};
