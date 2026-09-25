// LaneGraph — authored ghost routes for the Dungeon-Defenders-style defense layer.
// Spec: res://Docs/Ghosts/DEFENSE_LANES_SPEC.md
//
// A graph of nodes (spawn doorways, waypoints, junctions, objectives) joined by edges.
// Each edge carries a Curve3D smoothed through the markers placed along it, so a chain of
// hand-dropped points reads as a flowing line instead of a dogleg polyline.
//
// Split and merge are the SAME structure and need no special case:
//   merge — two edges ending at one node        (DOOR_A, DOOR_B -> JUNCT -> RIG)
//   split — one node with two outgoing edges    (SPLIT -> ANCHOR_1, SPLIT -> ANCHOR_2)
//
// Only the MARKERS are serialised. Curves are derived on load, so smoothing can be retuned
// without re-authoring a level, and moving a shared junction node reshapes every edge that
// touches it — which is the whole reason nodes are shared rather than duplicated per curve.
//
// This is a Resource, not a Node: SwarmCore reads it in C++ for the horde and BaseGhost
// reads the same object from GDScript for possessed props. Two SwarmCore instances in one
// tree segfault, so lane data cannot live inside the core.
#ifndef LANE_GRAPH_H
#define LANE_GRAPH_H

#include <godot_cpp/classes/curve3d.hpp>
#include <godot_cpp/classes/resource.hpp>
#include <godot_cpp/variant/dictionary.hpp>
#include <godot_cpp/variant/packed_float32_array.hpp>
#include <godot_cpp/variant/packed_int32_array.hpp>
#include <godot_cpp/variant/packed_string_array.hpp>
#include <godot_cpp/variant/packed_vector3_array.hpp>

#include <vector>

namespace godot {

class LaneGraph : public Resource {
	GDCLASS(LaneGraph, Resource)

public:
	enum NodeKind {
		NODE_DOOR = 0,    // ghosts spawn here
		NODE_WAY,         // plain waypoint
		NODE_JUNCTION,    // split or merge — any node with >1 edge on either side
		NODE_OBJECTIVE,   // Ecto-Rig or Sub-Anchor; ghosts stop and attack
	};

private:
	// ---- serialised (markers only; curves are derived) -----------------------------
	PackedVector3Array _node_pos;
	PackedInt32Array _node_kind;
	PackedStringArray _node_id;     // "rig_main", "anchor_2"; empty for plain waypoints

	PackedInt32Array _edge_from;
	PackedInt32Array _edge_to;
	PackedFloat32Array _edge_width;   // half-width the crowd spreads across
	PackedFloat32Array _edge_weight;  // junction pick weight
	Array _edge_points;               // per edge: PackedVector3Array of INTERIOR markers

	float _smoothing = 1.0f;   // 0 = straight polyline, 1 = Catmull-Rom, >1 loops out
	float _bake_interval = 0.25f;

	// ---- derived --------------------------------------------------------------------
	mutable std::vector<Ref<Curve3D>> _curves;
	mutable std::vector<float> _length;
	mutable std::vector<PackedInt32Array> _out;   // per node: outgoing edge indices
	mutable std::vector<PackedInt32Array> _in;    // per node: incoming edge indices
	mutable bool _dirty = true;

	void _rebuild() const;
	void _ensure() const {
		if (_dirty) {
			_rebuild();
		}
	}
	// Full ordered point list of an edge: from-node, interior markers, to-node.
	PackedVector3Array _edge_polyline(int e) const;
	bool _valid_edge(int e) const { return e >= 0 && e < _edge_from.size(); }
	bool _valid_node(int n) const { return n >= 0 && n < _node_pos.size(); }

	// storage accessors — .tres round trip goes through these, and every setter dirties
	void _set_node_pos(const PackedVector3Array &v);
	PackedVector3Array _get_node_pos() const { return _node_pos; }
	void _set_node_kind(const PackedInt32Array &v);
	PackedInt32Array _get_node_kind() const { return _node_kind; }
	void _set_node_id(const PackedStringArray &v);
	PackedStringArray _get_node_id() const { return _node_id; }
	void _set_edge_from(const PackedInt32Array &v);
	PackedInt32Array _get_edge_from() const { return _edge_from; }
	void _set_edge_to(const PackedInt32Array &v);
	PackedInt32Array _get_edge_to() const { return _edge_to; }
	void _set_edge_width(const PackedFloat32Array &v);
	PackedFloat32Array _get_edge_width() const { return _edge_width; }
	void _set_edge_weight(const PackedFloat32Array &v);
	PackedFloat32Array _get_edge_weight() const { return _edge_weight; }
	void _set_edge_points(const Array &v);
	Array _get_edge_points() const { return _edge_points; }

protected:
	static void _bind_methods();

public:
	LaneGraph();

	// ---- authoring ------------------------------------------------------------------
	int add_node(const Vector3 &pos, int kind, const String &id);
	int add_edge(int from, int to);
	void set_node_position(int n, const Vector3 &pos);
	void set_node_kind(int n, int kind);
	void set_node_id(int n, const String &id);
	void set_edge_marker_list(int e, const PackedVector3Array &interior);
	void append_edge_marker(int e, const Vector3 &p);
	void pop_edge_marker(int e);
	void set_edge_width(int e, float w);
	void set_edge_weight(int e, float w);
	void remove_edge(int e);
	// Removes the node and every edge touching it, renumbering the survivors.
	void remove_node(int n);
	void clear();

	void set_smoothing(float s);
	float get_smoothing() const { return _smoothing; }
	void set_bake_interval(float s);
	float get_bake_interval() const { return _bake_interval; }

	// ---- topology -------------------------------------------------------------------
	int node_count() const { return _node_pos.size(); }
	int edge_count() const { return _edge_from.size(); }
	Vector3 node_position(int n) const;
	int node_kind(int n) const;
	String node_id(int n) const;
	int edge_from(int e) const;
	int edge_to(int e) const;
	float edge_width(int e) const;
	float edge_weight(int e) const;
	PackedVector3Array edge_markers(int e) const;
	PackedInt32Array outgoing(int n) const;
	PackedInt32Array incoming(int n) const;
	PackedInt32Array doors() const;
	PackedInt32Array objectives() const;
	int find_node_by_id(const String &id) const;

	// ---- queries (the follow rule lives on these) ------------------------------------
	float edge_length(int e) const;
	Vector3 sample(int e, float t) const;             // t normalised 0..1
	Vector3 sample_dist(int e, float d) const;        // metres along, clamped
	Vector3 tangent_dist(int e, float d) const;       // unit forward
	Vector3 right_dist(int e, float d) const;         // unit horizontal right, for lateral spread
	// {edge, t, dist_along, distance, point} — how a yanked ghost rejoins its lane.
	Dictionary nearest(const Vector3 &p) const;
	// How far along ONE edge a body actually is. This, not integrated velocity, is what
	// drives lane progress: soft steering cuts corners, so a walker's travelled distance is
	// always shorter than the curve it is following and integrating it stalls short of the
	// end. Projection asks where the body IS instead of how far it has walked.
	float edge_offset_of(int e, const Vector3 &p) const;
	Vector3 edge_closest_point(int e, const Vector3 &p) const;
	// Weight-picked outgoing edge. `roll` is the caller's RNG in 0..1 so the horde stays
	// deterministic; -1 when the node is a dead end.
	int next_edge(int n, float roll) const;
	// Tessellated polyline for debug ribbons and for the authoring tool's live preview.
	PackedVector3Array tessellate(int e) const;
	// Cheap authoring sanity pass: unreachable doors, dead ends, objectives with no route.
	Dictionary validate() const;
};

} // namespace godot

VARIANT_ENUM_CAST(LaneGraph::NodeKind);

#endif // LANE_GRAPH_H
