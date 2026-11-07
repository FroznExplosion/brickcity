#ifndef BRICK_STRENGTH_TREE_H
#define BRICK_STRENGTH_TREE_H

// Where a brick build comes apart: its bricks clustered by joint strength into
// a tree (Docs/DestructionFirstPrinciples.md A5, B6). The C++ form of the
// prototype scripts/strength_tree.gd, which tools/strength_tree_probe.gd holds
// it to.
//
// Bake: every brick starts as its own cluster; the two joined clusters with the
// most studs between them PER PAIR OF BRICKS ACROSS (average linkage) merge,
// again and again. Each merge is a node; its `studs` is the joints between its
// two children -- what it takes to pull them apart. Merges happen only across
// joints, so every node is one connected set of bricks. Per pair, not per brick
// of the smaller side: that lets one cluster swallow single bricks first and the
// top of the tree peels ends off (measured, B6).
//
// Split: a hit of energy E (in studs) at a point walks a node from the top. A
// cut that the energy reaching it (E x falloff by distance) beats is made, its
// cost taken off, and what is left is SHARED between the two children by size --
// spent, not copied, so a hit makes a few parts rather than cascading.
//
// Pure: integers in, integers out, no Godot types but Vector3. Deterministic:
// scores compare by cross-multiplication in int64, ties by node id.

#include <godot_cpp/variant/vector3.hpp>

#include <cstdint>
#include <vector>

namespace brick {

struct StrengthJoint {
    int32_t a;          ///< leaf index
    int32_t b;          ///< leaf index
    int32_t studs;
    godot::Vector3 at;  ///< centre of the contact, in the caller's space
};

struct StrengthTree {
    // Leaves are 0..n-1; internal nodes follow in merge order.
    std::vector<int32_t> left;    ///< -1 for a leaf
    std::vector<int32_t> right;
    std::vector<int32_t> size;
    std::vector<int64_t> studs;
    std::vector<godot::Vector3> cut_sum;   ///< stud-weighted sum of cut joints' centres
    std::vector<int32_t> roots;            ///< one per connected part

    /// `joints` may list a pair more than once (several contact runs): summed.
    void bake(int32_t leaves, const std::vector<StrengthJoint> &joints);

    int32_t node_count() const { return (int32_t)left.size(); }
    bool is_leaf(int32_t n) const { return left[(size_t)n] < 0; }
    godot::Vector3 cut_centre(int32_t n) const;

    /// Pieces a hit makes of `node`, appended to `out` as node ids. `at` and the
    /// joints' `at` share a space; `falloff` is the distance at which half the
    /// energy still reaches a cut.
    void split(int32_t node, double energy, const godot::Vector3 &at, double falloff,
            std::vector<int32_t> &out) const;

    /// Leaf indices under `node`, appended to `out`.
    void leaves_of(int32_t node, std::vector<int32_t> &out) const;
};

} // namespace brick

#endif // BRICK_STRENGTH_TREE_H
