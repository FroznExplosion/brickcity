#include "flow_grid.h"

#include <godot_cpp/core/class_db.hpp>

#include <cmath>
#include <limits>

using namespace godot;

void FlowGrid::_bind_methods() {
	ClassDB::bind_method(
			D_METHOD("solve", "cols", "rows", "cell", "solid", "extra", "goals"),
			&FlowGrid::solve);
}

PackedFloat32Array FlowGrid::solve(int cols, int rows, float cell, const PackedByteArray &solid,
		const PackedFloat32Array &extra, const PackedInt32Array &goals) {
	const int n = cols * rows;
	PackedFloat32Array out;
	if (cols <= 0 || rows <= 0 || solid.size() < n || extra.size() < n) {
		return out;
	}
	const float INFF = std::numeric_limits<float>::infinity();
	out.resize(n);

	_cost.assign(n, INFF);
	_heap_cost.clear();
	_heap_idx.clear();
	_heap_cost.reserve(n);
	_heap_idx.reserve(n);

	const uint8_t *sol = solid.ptr();
	const float *ext = extra.ptr();
	float *cost = _cost.data();

	auto push = [&](float c, int i) {
		_heap_cost.push_back(c);
		_heap_idx.push_back(i);
		int k = (int)_heap_idx.size() - 1;
		while (k > 0) {
			int parent = (k - 1) >> 1;
			if (_heap_cost[parent] <= _heap_cost[k]) break;
			std::swap(_heap_cost[parent], _heap_cost[k]);
			std::swap(_heap_idx[parent], _heap_idx[k]);
			k = parent;
		}
	};

	for (int g = 0; g < goals.size(); g++) {
		int i = goals[g];
		if (i < 0 || i >= n || sol[i] != 0 || cost[i] == 0.0f) continue;
		cost[i] = 0.0f;
		push(0.0f, i);
	}

	static const int NX[8] = { 1, -1, 0, 0, 1, 1, -1, -1 };
	static const int NZ[8] = { 0, 0, 1, -1, 1, -1, 1, -1 };
	const float diag = cell * 1.41421356f;

	while (!_heap_idx.empty()) {
		const float c = _heap_cost[0];
		const int here = _heap_idx[0];
		// pop
		_heap_cost[0] = _heap_cost.back();
		_heap_idx[0] = _heap_idx.back();
		_heap_cost.pop_back();
		_heap_idx.pop_back();
		const int count = (int)_heap_idx.size();
		int k = 0;
		while (true) {
			int l = k * 2 + 1;
			if (l >= count) break;
			int small = l;
			int r = l + 1;
			if (r < count && _heap_cost[r] < _heap_cost[l]) small = r;
			if (_heap_cost[small] >= _heap_cost[k]) break;
			std::swap(_heap_cost[small], _heap_cost[k]);
			std::swap(_heap_idx[small], _heap_idx[k]);
			k = small;
		}

		if (c > cost[here]) continue;   // stale entry, already improved
		const int cz = here / cols;
		const int cx = here - cz * cols;
		const int row = cz * cols;
		for (int d = 0; d < 8; d++) {
			const int ax = cx + NX[d];
			const int az = cz + NZ[d];
			if (ax < 0 || az < 0 || ax >= cols || az >= rows) continue;
			const int ni = az * cols + ax;
			if (sol[ni] != 0) continue;
			float step = cell;
			if (d >= 4) {
				// No cutting the corner between two solids — see the header.
				if (sol[row + ax] != 0 || sol[az * cols + cx] != 0) continue;
				step = diag;
			}
			const float nc = c + step + ext[ni];
			if (nc < cost[ni]) {
				cost[ni] = nc;
				push(nc, ni);
			}
		}
	}

	float *dst = out.ptrw();
	for (int i = 0; i < n; i++) dst[i] = cost[i];
	return out;
}
