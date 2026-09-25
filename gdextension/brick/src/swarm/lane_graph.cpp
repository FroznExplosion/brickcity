#include "lane_graph.h"

#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/variant/utility_functions.hpp>

#include <cmath>

using namespace godot;

LaneGraph::LaneGraph() {
}

// --------------------------------------------------------------------------- derivation

// Full ordered point list: the from-node, every interior marker, the to-node. The end
// points are NOT stored per edge — they are read from the shared nodes, so dragging a
// junction reshapes every curve meeting there instead of leaving orphaned duplicates.
PackedVector3Array LaneGraph::_edge_polyline(int e) const {
	PackedVector3Array out;
	if (!_valid_edge(e)) {
		return out;
	}
	const int a = _edge_from[e];
	const int b = _edge_to[e];
	if (!_valid_node(a) || !_valid_node(b)) {
		return out;
	}
	out.push_back(_node_pos[a]);
	if (e < _edge_points.size()) {
		const PackedVector3Array mid = _edge_points[e];
		for (int i = 0; i < mid.size(); i++) {
			out.push_back(mid[i]);
		}
	}
	out.push_back(_node_pos[b]);
	return out;
}

// Catmull-Rom through every marker, expressed as Curve3D Bezier handles. A Catmull-Rom
// segment equals a cubic Bezier whose handles sit at +/- (p[i+1] - p[i-1]) / 6, so the
// curve passes exactly THROUGH each marker — a designer's click is on the line, not merely
// near it. `smoothing` scales the handles: 0 gives the raw polyline back, 1 is the true
// spline, above ~1.4 it starts to loop out past tight corners.
void LaneGraph::_rebuild() const {
	_dirty = false;

	const int ec = _edge_from.size();
	const int nc = _node_pos.size();

	_curves.clear();
	_length.clear();
	_curves.resize(ec);
	_length.assign(ec, 0.0f);

	_out.clear();
	_in.clear();
	_out.resize(nc);
	_in.resize(nc);

	for (int e = 0; e < ec; e++) {
		const PackedVector3Array pts = _edge_polyline(e);
		Ref<Curve3D> c;
		c.instantiate();
		c->set_bake_interval(_bake_interval);
		const int n = pts.size();
		for (int i = 0; i < n; i++) {
			Vector3 prev = (i > 0) ? pts[i - 1] : pts[i] - (pts[(i + 1 < n) ? i + 1 : i] - pts[i]);
			Vector3 next = (i < n - 1) ? pts[i + 1] : pts[i] + (pts[i] - pts[(i > 0) ? i - 1 : i]);
			const Vector3 d = (next - prev) * (_smoothing / 6.0f);
			c->add_point(pts[i], -d, d);
		}
		_curves[e] = c;
		_length[e] = (n >= 2) ? (float)c->get_baked_length() : 0.0f;

		const int a = _edge_from[e];
		const int b = _edge_to[e];
		if (a >= 0 && a < nc) {
			_out[a].push_back(e);
		}
		if (b >= 0 && b < nc) {
			_in[b].push_back(e);
		}
	}
}

// --------------------------------------------------------------------------- authoring

int LaneGraph::add_node(const Vector3 &pos, int kind, const String &id) {
	_node_pos.push_back(pos);
	_node_kind.push_back(kind);
	_node_id.push_back(id);
	_dirty = true;
	emit_changed();
	return _node_pos.size() - 1;
}

int LaneGraph::add_edge(int from, int to) {
	if (!_valid_node(from) || !_valid_node(to) || from == to) {
		return -1;
	}
	_edge_from.push_back(from);
	_edge_to.push_back(to);
	_edge_width.push_back(1.25f);
	_edge_weight.push_back(1.0f);
	_edge_points.push_back(PackedVector3Array());
	_dirty = true;
	emit_changed();
	return _edge_from.size() - 1;
}

void LaneGraph::set_node_position(int n, const Vector3 &pos) {
	if (!_valid_node(n)) {
		return;
	}
	_node_pos[n] = pos;
	_dirty = true;
	emit_changed();
}

void LaneGraph::set_node_kind(int n, int kind) {
	if (!_valid_node(n)) {
		return;
	}
	_node_kind[n] = kind;
	emit_changed();
}

void LaneGraph::set_node_id(int n, const String &id) {
	if (!_valid_node(n)) {
		return;
	}
	_node_id[n] = id;
	emit_changed();
}

void LaneGraph::set_edge_marker_list(int e, const PackedVector3Array &interior) {
	if (!_valid_edge(e)) {
		return;
	}
	_edge_points[e] = interior;
	_dirty = true;
	emit_changed();
}

void LaneGraph::append_edge_marker(int e, const Vector3 &p) {
	if (!_valid_edge(e)) {
		return;
	}
	PackedVector3Array mid = _edge_points[e];
	mid.push_back(p);
	_edge_points[e] = mid;
	_dirty = true;
	emit_changed();
}

void LaneGraph::pop_edge_marker(int e) {
	if (!_valid_edge(e)) {
		return;
	}
	PackedVector3Array mid = _edge_points[e];
	if (mid.is_empty()) {
		return;
	}
	mid.remove_at(mid.size() - 1);
	_edge_points[e] = mid;
	_dirty = true;
	emit_changed();
}

void LaneGraph::set_edge_width(int e, float w) {
	if (!_valid_edge(e)) {
		return;
	}
	_edge_width[e] = w;
	emit_changed();
}

void LaneGraph::set_edge_weight(int e, float w) {
	if (!_valid_edge(e)) {
		return;
	}
	_edge_weight[e] = (w < 0.0f) ? 0.0f : w;
	emit_changed();
}

void LaneGraph::remove_edge(int e) {
	if (!_valid_edge(e)) {
		return;
	}
	_edge_from.remove_at(e);
	_edge_to.remove_at(e);
	_edge_width.remove_at(e);
	_edge_weight.remove_at(e);
	if (e < _edge_points.size()) {
		_edge_points.remove_at(e);
	}
	_dirty = true;
	emit_changed();
}

// Edges store node INDICES, so deleting a node has to renumber every reference above it —
// otherwise the surviving edges quietly point at the wrong nodes and the lanes reshuffle.
void LaneGraph::remove_node(int n) {
	if (!_valid_node(n)) {
		return;
	}
	for (int e = _edge_from.size() - 1; e >= 0; e--) {
		if (_edge_from[e] == n || _edge_to[e] == n) {
			remove_edge(e);
		}
	}
	for (int e = 0; e < _edge_from.size(); e++) {
		if (_edge_from[e] > n) {
			_edge_from[e] = _edge_from[e] - 1;
		}
		if (_edge_to[e] > n) {
			_edge_to[e] = _edge_to[e] - 1;
		}
	}
	_node_pos.remove_at(n);
	_node_kind.remove_at(n);
	_node_id.remove_at(n);
	_dirty = true;
	emit_changed();
}

void LaneGraph::clear() {
	_node_pos.clear();
	_node_kind.clear();
	_node_id.clear();
	_edge_from.clear();
	_edge_to.clear();
	_edge_width.clear();
	_edge_weight.clear();
	_edge_points.clear();
	_dirty = true;
	emit_changed();
}

void LaneGraph::set_smoothing(float s) {
	_smoothing = s;
	_dirty = true;
	emit_changed();
}

void LaneGraph::set_bake_interval(float s) {
	_bake_interval = (s < 0.02f) ? 0.02f : s;
	_dirty = true;
	emit_changed();
}

// --------------------------------------------------------------------------- topology

Vector3 LaneGraph::node_position(int n) const {
	return _valid_node(n) ? _node_pos[n] : Vector3();
}

int LaneGraph::node_kind(int n) const {
	return _valid_node(n) ? _node_kind[n] : (int)NODE_WAY;
}

String LaneGraph::node_id(int n) const {
	return _valid_node(n) ? _node_id[n] : String();
}

int LaneGraph::edge_from(int e) const {
	return _valid_edge(e) ? _edge_from[e] : -1;
}

int LaneGraph::edge_to(int e) const {
	return _valid_edge(e) ? _edge_to[e] : -1;
}

float LaneGraph::edge_width(int e) const {
	return _valid_edge(e) ? _edge_width[e] : 0.0f;
}

float LaneGraph::edge_weight(int e) const {
	return _valid_edge(e) ? _edge_weight[e] : 0.0f;
}

PackedVector3Array LaneGraph::edge_markers(int e) const {
	if (!_valid_edge(e) || e >= _edge_points.size()) {
		return PackedVector3Array();
	}
	return _edge_points[e];
}

PackedInt32Array LaneGraph::outgoing(int n) const {
	_ensure();
	if (n < 0 || n >= (int)_out.size()) {
		return PackedInt32Array();
	}
	return _out[n];
}

PackedInt32Array LaneGraph::incoming(int n) const {
	_ensure();
	if (n < 0 || n >= (int)_in.size()) {
		return PackedInt32Array();
	}
	return _in[n];
}

PackedInt32Array LaneGraph::doors() const {
	PackedInt32Array out;
	for (int i = 0; i < _node_kind.size(); i++) {
		if (_node_kind[i] == NODE_DOOR) {
			out.push_back(i);
		}
	}
	return out;
}

PackedInt32Array LaneGraph::objectives() const {
	PackedInt32Array out;
	for (int i = 0; i < _node_kind.size(); i++) {
		if (_node_kind[i] == NODE_OBJECTIVE) {
			out.push_back(i);
		}
	}
	return out;
}

int LaneGraph::find_node_by_id(const String &id) const {
	if (id.is_empty()) {
		return -1;
	}
	for (int i = 0; i < _node_id.size(); i++) {
		if (_node_id[i] == id) {
			return i;
		}
	}
	return -1;
}

// --------------------------------------------------------------------------- queries

float LaneGraph::edge_length(int e) const {
	_ensure();
	return _valid_edge(e) ? _length[e] : 0.0f;
}

Vector3 LaneGraph::sample(int e, float t) const {
	_ensure();
	if (!_valid_edge(e)) {
		return Vector3();
	}
	return sample_dist(e, t * _length[e]);
}

Vector3 LaneGraph::sample_dist(int e, float d) const {
	_ensure();
	if (!_valid_edge(e) || _curves[e].is_null()) {
		return Vector3();
	}
	const float len = _length[e];
	if (len <= 0.0f) {
		return node_position(_edge_from[e]);
	}
	if (d < 0.0f) {
		d = 0.0f;
	} else if (d > len) {
		d = len;
	}
	return _curves[e]->sample_baked(d, true);
}

// Central difference rather than the curve's own up-vector machinery: the tilt/up track is
// authored data we never set, and a finite difference on the baked points is what the
// follow rule actually wants.
Vector3 LaneGraph::tangent_dist(int e, float d) const {
	_ensure();
	if (!_valid_edge(e) || _length[e] <= 0.0f) {
		return Vector3(0.0f, 0.0f, -1.0f);
	}
	const float h = 0.15f;
	const Vector3 a = sample_dist(e, d - h);
	const Vector3 b = sample_dist(e, d + h);
	Vector3 t = b - a;
	if (t.length_squared() < 1e-8f) {
		return Vector3(0.0f, 0.0f, -1.0f);
	}
	return t.normalized();
}

// Horizontal right of travel. Vertical-ish tangents (a lane dropping down a stairwell)
// fall back to world +X so the lateral spread never collapses to zero width.
Vector3 LaneGraph::right_dist(int e, float d) const {
	const Vector3 t = tangent_dist(e, d);
	Vector3 r = t.cross(Vector3(0.0f, 1.0f, 0.0f));
	if (r.length_squared() < 1e-6f) {
		return Vector3(1.0f, 0.0f, 0.0f);
	}
	return r.normalized();
}

// How a ghost that got yanked off its lane by the vacuum beam finds its way back on.
Dictionary LaneGraph::nearest(const Vector3 &p) const {
	_ensure();
	Dictionary out;
	int best_e = -1;
	float best_d2 = 3.4e38f;
	Vector3 best_pt;
	float best_off = 0.0f;

	for (int e = 0; e < (int)_curves.size(); e++) {
		if (_curves[e].is_null() || _length[e] <= 0.0f) {
			continue;
		}
		const Vector3 pt = _curves[e]->get_closest_point(p);
		const float d2 = (float)pt.distance_squared_to(p);
		if (d2 < best_d2) {
			best_d2 = d2;
			best_e = e;
			best_pt = pt;
			best_off = (float)_curves[e]->get_closest_offset(p);
		}
	}

	out["edge"] = best_e;
	out["dist_along"] = best_off;
	out["t"] = (best_e >= 0 && _length[best_e] > 0.0f) ? best_off / _length[best_e] : 0.0f;
	out["distance"] = (best_e >= 0) ? std::sqrt(best_d2) : -1.0f;
	out["point"] = best_pt;
	return out;
}

float LaneGraph::edge_offset_of(int e, const Vector3 &p) const {
	_ensure();
	if (!_valid_edge(e) || _curves[e].is_null() || _length[e] <= 0.0f) {
		return 0.0f;
	}
	return (float)_curves[e]->get_closest_offset(p);
}

Vector3 LaneGraph::edge_closest_point(int e, const Vector3 &p) const {
	_ensure();
	if (!_valid_edge(e) || _curves[e].is_null()) {
		return Vector3();
	}
	if (_length[e] <= 0.0f) {
		return node_position(_edge_from[e]);
	}
	return _curves[e]->get_closest_point(p);
}

// `roll` is the CALLER's random number, not ours: the horde tick has to stay deterministic
// and reproducible from its own seed, so this class never owns an RNG.
int LaneGraph::next_edge(int n, float roll) const {
	_ensure();
	if (n < 0 || n >= (int)_out.size()) {
		return -1;
	}
	const PackedInt32Array &es = _out[n];
	if (es.is_empty()) {
		return -1;
	}
	float total = 0.0f;
	for (int i = 0; i < es.size(); i++) {
		total += _edge_weight[es[i]];
	}
	if (total <= 0.0f) {
		// Every branch weighted to zero — still take one rather than stall the ghost.
		int i = (int)(roll * (float)es.size());
		if (i < 0) {
			i = 0;
		} else if (i >= es.size()) {
			i = es.size() - 1;
		}
		return es[i];
	}
	float acc = 0.0f;
	const float pick = roll * total;
	for (int i = 0; i < es.size(); i++) {
		acc += _edge_weight[es[i]];
		if (pick <= acc) {
			return es[i];
		}
	}
	return es[es.size() - 1];
}

PackedVector3Array LaneGraph::tessellate(int e) const {
	_ensure();
	if (!_valid_edge(e) || _curves[e].is_null()) {
		return PackedVector3Array();
	}
	return _curves[e]->get_baked_points();
}

// Authoring sanity, cheap enough to run on every save. Catches the three mistakes that are
// invisible in the viewport: a doorway that leads nowhere, an objective nothing routes to,
// and a waypoint chain that just stops.
Dictionary LaneGraph::validate() const {
	_ensure();
	Dictionary out;
	PackedInt32Array dead_ends;
	PackedInt32Array isolated;
	PackedInt32Array orphan_doors;
	PackedInt32Array unreachable_objectives;

	const int nc = _node_pos.size();
	for (int i = 0; i < nc; i++) {
		const bool has_out = !_out[i].is_empty();
		const bool has_in = !_in[i].is_empty();
		if (!has_out && !has_in) {
			isolated.push_back(i);
		} else if (!has_out && _node_kind[i] != NODE_OBJECTIVE) {
			dead_ends.push_back(i);
		}
	}

	// Forward flood from every door: which nodes can a spawned ghost actually reach.
	std::vector<bool> seen(nc, false);
	PackedInt32Array stack = doors();
	for (int i = 0; i < stack.size(); i++) {
		seen[stack[i]] = true;
	}
	while (!stack.is_empty()) {
		const int n = stack[stack.size() - 1];
		stack.remove_at(stack.size() - 1);
		const PackedInt32Array &es = _out[n];
		for (int i = 0; i < es.size(); i++) {
			const int to = _edge_to[es[i]];
			if (to >= 0 && to < nc && !seen[to]) {
				seen[to] = true;
				stack.push_back(to);
			}
		}
	}
	for (int i = 0; i < nc; i++) {
		if (_node_kind[i] == NODE_OBJECTIVE && !seen[i]) {
			unreachable_objectives.push_back(i);
		}
	}

	// Backward flood from every objective: which doors lead to one.
	std::vector<bool> feeds(nc, false);
	PackedInt32Array back = objectives();
	for (int i = 0; i < back.size(); i++) {
		feeds[back[i]] = true;
	}
	while (!back.is_empty()) {
		const int n = back[back.size() - 1];
		back.remove_at(back.size() - 1);
		const PackedInt32Array &es = _in[n];
		for (int i = 0; i < es.size(); i++) {
			const int from = _edge_from[es[i]];
			if (from >= 0 && from < nc && !feeds[from]) {
				feeds[from] = true;
				back.push_back(from);
			}
		}
	}
	const PackedInt32Array ds = doors();
	for (int i = 0; i < ds.size(); i++) {
		if (!feeds[ds[i]]) {
			orphan_doors.push_back(ds[i]);
		}
	}

	out["ok"] = dead_ends.is_empty() && isolated.is_empty() && orphan_doors.is_empty() &&
			unreachable_objectives.is_empty() && !ds.is_empty() && !objectives().is_empty();
	out["dead_ends"] = dead_ends;
	out["isolated"] = isolated;
	out["orphan_doors"] = orphan_doors;
	out["unreachable_objectives"] = unreachable_objectives;
	out["door_count"] = ds.size();
	out["objective_count"] = objectives().size();
	return out;
}

// --------------------------------------------------------------------------- storage

void LaneGraph::_set_node_pos(const PackedVector3Array &v) {
	_node_pos = v;
	_dirty = true;
}
void LaneGraph::_set_node_kind(const PackedInt32Array &v) {
	_node_kind = v;
	_dirty = true;
}
void LaneGraph::_set_node_id(const PackedStringArray &v) {
	_node_id = v;
	_dirty = true;
}
void LaneGraph::_set_edge_from(const PackedInt32Array &v) {
	_edge_from = v;
	_dirty = true;
}
void LaneGraph::_set_edge_to(const PackedInt32Array &v) {
	_edge_to = v;
	_dirty = true;
}
void LaneGraph::_set_edge_width(const PackedFloat32Array &v) {
	_edge_width = v;
	_dirty = true;
}
void LaneGraph::_set_edge_weight(const PackedFloat32Array &v) {
	_edge_weight = v;
	_dirty = true;
}
void LaneGraph::_set_edge_points(const Array &v) {
	_edge_points = v;
	_dirty = true;
}

void LaneGraph::_bind_methods() {
	ClassDB::bind_method(D_METHOD("add_node", "position", "kind", "id"), &LaneGraph::add_node);
	ClassDB::bind_method(D_METHOD("add_edge", "from", "to"), &LaneGraph::add_edge);
	ClassDB::bind_method(D_METHOD("set_node_position", "node", "position"), &LaneGraph::set_node_position);
	ClassDB::bind_method(D_METHOD("set_node_kind", "node", "kind"), &LaneGraph::set_node_kind);
	ClassDB::bind_method(D_METHOD("set_node_id", "node", "id"), &LaneGraph::set_node_id);
	ClassDB::bind_method(D_METHOD("set_edge_marker_list", "edge", "interior"), &LaneGraph::set_edge_marker_list);
	ClassDB::bind_method(D_METHOD("append_edge_marker", "edge", "point"), &LaneGraph::append_edge_marker);
	ClassDB::bind_method(D_METHOD("pop_edge_marker", "edge"), &LaneGraph::pop_edge_marker);
	ClassDB::bind_method(D_METHOD("set_edge_width", "edge", "width"), &LaneGraph::set_edge_width);
	ClassDB::bind_method(D_METHOD("set_edge_weight", "edge", "weight"), &LaneGraph::set_edge_weight);
	ClassDB::bind_method(D_METHOD("remove_edge", "edge"), &LaneGraph::remove_edge);
	ClassDB::bind_method(D_METHOD("remove_node", "node"), &LaneGraph::remove_node);
	ClassDB::bind_method(D_METHOD("clear"), &LaneGraph::clear);

	ClassDB::bind_method(D_METHOD("node_count"), &LaneGraph::node_count);
	ClassDB::bind_method(D_METHOD("edge_count"), &LaneGraph::edge_count);
	ClassDB::bind_method(D_METHOD("node_position", "node"), &LaneGraph::node_position);
	ClassDB::bind_method(D_METHOD("node_kind", "node"), &LaneGraph::node_kind);
	ClassDB::bind_method(D_METHOD("node_id", "node"), &LaneGraph::node_id);
	ClassDB::bind_method(D_METHOD("edge_from", "edge"), &LaneGraph::edge_from);
	ClassDB::bind_method(D_METHOD("edge_to", "edge"), &LaneGraph::edge_to);
	ClassDB::bind_method(D_METHOD("edge_width", "edge"), &LaneGraph::edge_width);
	ClassDB::bind_method(D_METHOD("edge_weight", "edge"), &LaneGraph::edge_weight);
	ClassDB::bind_method(D_METHOD("edge_markers", "edge"), &LaneGraph::edge_markers);
	ClassDB::bind_method(D_METHOD("outgoing", "node"), &LaneGraph::outgoing);
	ClassDB::bind_method(D_METHOD("incoming", "node"), &LaneGraph::incoming);
	ClassDB::bind_method(D_METHOD("doors"), &LaneGraph::doors);
	ClassDB::bind_method(D_METHOD("objectives"), &LaneGraph::objectives);
	ClassDB::bind_method(D_METHOD("find_node_by_id", "id"), &LaneGraph::find_node_by_id);

	ClassDB::bind_method(D_METHOD("edge_length", "edge"), &LaneGraph::edge_length);
	ClassDB::bind_method(D_METHOD("sample", "edge", "t"), &LaneGraph::sample);
	ClassDB::bind_method(D_METHOD("sample_dist", "edge", "distance"), &LaneGraph::sample_dist);
	ClassDB::bind_method(D_METHOD("tangent_dist", "edge", "distance"), &LaneGraph::tangent_dist);
	ClassDB::bind_method(D_METHOD("right_dist", "edge", "distance"), &LaneGraph::right_dist);
	ClassDB::bind_method(D_METHOD("nearest", "position"), &LaneGraph::nearest);
	ClassDB::bind_method(D_METHOD("edge_offset_of", "edge", "position"), &LaneGraph::edge_offset_of);
	ClassDB::bind_method(D_METHOD("edge_closest_point", "edge", "position"),
			&LaneGraph::edge_closest_point);
	ClassDB::bind_method(D_METHOD("next_edge", "node", "roll"), &LaneGraph::next_edge);
	ClassDB::bind_method(D_METHOD("tessellate", "edge"), &LaneGraph::tessellate);
	ClassDB::bind_method(D_METHOD("validate"), &LaneGraph::validate);

	ClassDB::bind_method(D_METHOD("set_smoothing", "smoothing"), &LaneGraph::set_smoothing);
	ClassDB::bind_method(D_METHOD("get_smoothing"), &LaneGraph::get_smoothing);
	ClassDB::bind_method(D_METHOD("set_bake_interval", "interval"), &LaneGraph::set_bake_interval);
	ClassDB::bind_method(D_METHOD("get_bake_interval"), &LaneGraph::get_bake_interval);
	ADD_PROPERTY(PropertyInfo(Variant::FLOAT, "smoothing", PROPERTY_HINT_RANGE, "0.0,1.6,0.05"),
			"set_smoothing", "get_smoothing");
	ADD_PROPERTY(PropertyInfo(Variant::FLOAT, "bake_interval", PROPERTY_HINT_RANGE, "0.05,1.0,0.01"),
			"set_bake_interval", "get_bake_interval");

	// Raw storage. STORAGE-only: these round-trip through the .tres but are index soup in
	// an inspector, and hand-editing them desynchronises the graph.
	ClassDB::bind_method(D_METHOD("_set_node_pos", "v"), &LaneGraph::_set_node_pos);
	ClassDB::bind_method(D_METHOD("_get_node_pos"), &LaneGraph::_get_node_pos);
	ClassDB::bind_method(D_METHOD("_set_node_kind", "v"), &LaneGraph::_set_node_kind);
	ClassDB::bind_method(D_METHOD("_get_node_kind"), &LaneGraph::_get_node_kind);
	ClassDB::bind_method(D_METHOD("_set_node_id", "v"), &LaneGraph::_set_node_id);
	ClassDB::bind_method(D_METHOD("_get_node_id"), &LaneGraph::_get_node_id);
	ClassDB::bind_method(D_METHOD("_set_edge_from", "v"), &LaneGraph::_set_edge_from);
	ClassDB::bind_method(D_METHOD("_get_edge_from"), &LaneGraph::_get_edge_from);
	ClassDB::bind_method(D_METHOD("_set_edge_to", "v"), &LaneGraph::_set_edge_to);
	ClassDB::bind_method(D_METHOD("_get_edge_to"), &LaneGraph::_get_edge_to);
	ClassDB::bind_method(D_METHOD("_set_edge_width", "v"), &LaneGraph::_set_edge_width);
	ClassDB::bind_method(D_METHOD("_get_edge_width"), &LaneGraph::_get_edge_width);
	ClassDB::bind_method(D_METHOD("_set_edge_weight", "v"), &LaneGraph::_set_edge_weight);
	ClassDB::bind_method(D_METHOD("_get_edge_weight"), &LaneGraph::_get_edge_weight);
	ClassDB::bind_method(D_METHOD("_set_edge_points", "v"), &LaneGraph::_set_edge_points);
	ClassDB::bind_method(D_METHOD("_get_edge_points"), &LaneGraph::_get_edge_points);

	const uint32_t ST = PROPERTY_USAGE_STORAGE;
	ADD_PROPERTY(PropertyInfo(Variant::PACKED_VECTOR3_ARRAY, "node_pos", PROPERTY_HINT_NONE, "", ST),
			"_set_node_pos", "_get_node_pos");
	ADD_PROPERTY(PropertyInfo(Variant::PACKED_INT32_ARRAY, "node_kind", PROPERTY_HINT_NONE, "", ST),
			"_set_node_kind", "_get_node_kind");
	ADD_PROPERTY(PropertyInfo(Variant::PACKED_STRING_ARRAY, "node_id", PROPERTY_HINT_NONE, "", ST),
			"_set_node_id", "_get_node_id");
	ADD_PROPERTY(PropertyInfo(Variant::PACKED_INT32_ARRAY, "edge_from", PROPERTY_HINT_NONE, "", ST),
			"_set_edge_from", "_get_edge_from");
	ADD_PROPERTY(PropertyInfo(Variant::PACKED_INT32_ARRAY, "edge_to", PROPERTY_HINT_NONE, "", ST),
			"_set_edge_to", "_get_edge_to");
	ADD_PROPERTY(PropertyInfo(Variant::PACKED_FLOAT32_ARRAY, "edge_width", PROPERTY_HINT_NONE, "", ST),
			"_set_edge_width", "_get_edge_width");
	ADD_PROPERTY(PropertyInfo(Variant::PACKED_FLOAT32_ARRAY, "edge_weight", PROPERTY_HINT_NONE, "", ST),
			"_set_edge_weight", "_get_edge_weight");
	ADD_PROPERTY(PropertyInfo(Variant::ARRAY, "edge_points", PROPERTY_HINT_NONE, "", ST),
			"_set_edge_points", "_get_edge_points");

	BIND_ENUM_CONSTANT(NODE_DOOR);
	BIND_ENUM_CONSTANT(NODE_WAY);
	BIND_ENUM_CONSTANT(NODE_JUNCTION);
	BIND_ENUM_CONSTANT(NODE_OBJECTIVE);
}
