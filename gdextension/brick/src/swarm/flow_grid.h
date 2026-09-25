// FlowGrid — the Dijkstra integration pass for TDFlowField, in C++.
//
// This is one function pretending to be a class, and the reason it exists is measurement rather
// than taste. The GDScript version of this loop cost ~20 ms per zone on a 1,800-cell grid, and
// it runs several times per barricade the player puts down — which is a visible freeze while
// building, the one thing a build phase cannot have.
//
// Everything ELSE stays in GDScript: rasterising the obstacles is a handful of boxes, tracing a
// route is a few hundred steps, and neither shows up in a profile. Only the relaxation moves, so
// `scripts/td/td_flow_field.gd` remains the single source of truth for what the grid MEANS and
// this file never learns what a barricade is.
//
// The module keeps working without this extension: TDFlowField falls back to its own
// implementation when the class is absent (see `_solve_native`), which is the same contract
// TDHordeBridge has with SwarmCore.
#ifndef FLOW_GRID_H
#define FLOW_GRID_H

#include <godot_cpp/classes/ref_counted.hpp>
#include <godot_cpp/variant/packed_byte_array.hpp>
#include <godot_cpp/variant/packed_float32_array.hpp>
#include <godot_cpp/variant/packed_int32_array.hpp>

#include <vector>

namespace godot {

class FlowGrid : public RefCounted {
	GDCLASS(FlowGrid, RefCounted)

private:
	// Scratch, kept between calls so a re-plan does not reallocate. One instance is used for
	// every zone in a level, so these grow to the largest grid and stay there.
	std::vector<float> _cost;
	std::vector<float> _heap_cost;
	std::vector<int32_t> _heap_idx;

protected:
	static void _bind_methods();

public:
	// Multi-source Dijkstra out from every goal cell at once.
	//
	// `solid` is one byte per cell, non-zero = never crossed. `extra` is metres-equivalent
	// charged for entering a cell — the player's barricades, which are PASSABLE at a price so
	// that sealing a zone produces a route through the cheapest wall rather than no route at
	// all. `goals` are cell indices.
	//
	// Returns metres-to-the-nearest-goal per cell, INF where there is no way through.
	//
	// Eight-connected, diagonals at cell*sqrt(2), and a diagonal is refused when either
	// orthogonal neighbour is solid: otherwise a route slips through the seam where two walls
	// touch at their corners, which the player believed they had closed.
	PackedFloat32Array solve(int cols, int rows, float cell, const PackedByteArray &solid,
			const PackedFloat32Array &extra, const PackedInt32Array &goals);
};

} // namespace godot

#endif // FLOW_GRID_H
