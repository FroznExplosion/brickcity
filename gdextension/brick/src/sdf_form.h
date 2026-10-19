#pragma once

#include <godot_cpp/classes/ref_counted.hpp>
#include <godot_cpp/variant/aabb.hpp>
#include <godot_cpp/variant/array.hpp>
#include <godot_cpp/variant/packed_byte_array.hpp>
#include <godot_cpp/variant/packed_color_array.hpp>
#include <godot_cpp/variant/packed_float32_array.hpp>
#include <godot_cpp/variant/packed_int32_array.hpp>
#include <godot_cpp/variant/packed_vector3_array.hpp>
#include <godot_cpp/variant/transform3d.hpp>
#include <godot_cpp/variant/vector2.hpp>
#include <godot_cpp/variant/vector3.hpp>
#include <godot_cpp/variant/vector3i.hpp>

#include <cstdint>
#include <memory>
#include <unordered_map>

using namespace godot;

/// The asset workshop's block-out: one signed distance field for the whole asset,
/// sculpted in 3D, with a part label and a smooth flag on every sample
/// (Docs/AssetWorkshop.md, "The SDF block-out").
///
/// Units: one sample a TICK (a stud is 5, a plate 2; 0.07 m), so the field lines up
/// with the brick grid. Sample (i, j, k) is at ((i, j, k) + 0.5) ticks from the
/// grid's corner; brick cell (x, y, z) covers ticks [5x, 5x + 5) x [2y, 2y + 2) x
/// [5z, 5z + 5), and its middle is sample 5x + 2 across, between samples 2y and
/// 2y + 1 up, sample 5z + 2 deep. Negative is inside. Distances are kept within
/// +-BAND samples (a narrow band, as Zylann's voxel tools store theirs), and only
/// the 16^3 blocks a stroke came near are stored: a 1000-stud area costs what is
/// drawn in it.
///
/// Brushes follow Zylann's VoxelTool: add is a union (min), remove a subtraction
/// (max with the negated shape), both optionally smooth (Inigo Quilez's polynomial
/// smooth min), smooth blurs within the brush. A part label goes to every sample an
/// add changed; paint relabels without changing the shape.
///
/// Bricks and the field: `cells` reads which brick cells are solid (the middle of
/// the cell inside) and which part and smooth flag each has; `sync_cells` writes back only
/// the cells that changed -- a brick added is a box unioned, a brick taken a box
/// carved -- so the smooth surface stays smooth wherever the bricks were not
/// touched, and `cells` gives back exactly the bricks that were synced.
class SdfForm : public RefCounted {
    GDCLASS(SdfForm, RefCounted)

public:
    static constexpr int B = 16;            // block edge, samples
    static constexpr int B3 = B * B * B;
    static constexpr float BAND = 6.0f;     // samples
    static constexpr int STUD = 5;          // samples a stud
    static constexpr int PLATE = 2;         // samples a plate

    enum Op { ADD = 0, REMOVE = 1, SMOOTH = 2, PAINT = 3, MARK = 4, UNMARK = 5, GROW = 6 };
    enum Shape { SHAPE_BOX = 0, SHAPE_CONE = 1 };

    struct Block {
        float d[B3];
        uint8_t part[B3];
        uint8_t flag[B3];
    };

protected:
    static void _bind_methods();

private:
    std::unordered_map<int64_t, std::unique_ptr<Block>> blocks;
    // While an edit records: each block as it was when the edit first touched it
    // (null: it did not exist).
    bool recording = false;
    std::unordered_map<int64_t, std::unique_ptr<Block>> undo;
    std::unordered_map<int64_t, bool> dirty;

    static int64_t key(int bx, int by, int bz);
    static Vector3i unkey(int64_t k);
    Block *find(int64_t k) const;
    Block *touch(int64_t k, bool create);
    float d_at(int i, int j, int k) const;
    uint8_t part_at(int i, int j, int k) const;
    uint8_t flag_at(int i, int j, int k) const;
    float trilinear(const Vector3 &p) const;

    // Calls fn(block, index, sample) for every sample in [lo, hi], creating blocks
    // when `create`.
    template <typename F>
    void each(const Vector3i &lo, const Vector3i &hi, bool create, F fn);

    void apply_shape(int op, const Vector3i &lo, const Vector3i &hi, float blend, int part,
            float (*sdf)(const Vector3 &, const void *), const void *ctx);
    void cell_box(const Vector3i &c, int op, int part);
    void grow(const Vector3 &a, const Vector3 &b, float radius, float amount, int part);

public:
    /// A capsule from `a` to `b` (samples), `radius` round it: a sphere when a == b.
    /// GROW (Zylann's grow_sphere): every sample's distance down by `blend` samples in
    /// the middle, fading to the edge (negative: shrinks).
    /// `op`: ADD, REMOVE, SMOOTH (blur, `blend` its strength 0-1), PAINT (label
    /// `part`), MARK / UNMARK (smooth: a custom piece on Convert; unmarked is bricks). `blend`: for ADD and REMOVE, how far
    /// (samples) the shape blends into what is there.
    void stroke(int op, const Vector3 &a, const Vector3 &b, float radius, float blend, int part);
    /// A box, `center` and `half` its half size (samples).
    void box(int op, const Vector3 &center, const Vector3 &half, float blend, int part);
    /// A shape in its own frame, placed by the rigid `xform` (local to samples): SHAPE_BOX
    /// (`size` its half extents) or SHAPE_CONE, a capped cone along local y (`size.x` the
    /// radius at y = -size.y, `size.z` at y = +size.y; equal: a cylinder). Ops as `stroke`
    /// but SMOOTH and GROW.
    void shape(int op, int kind, const Transform3D &xform, const Vector3 &size, float blend, int part);
    /// Flatten (Substance Modeler, Blender): within the ball every sample moves toward
    /// its distance from the plane through `point` square to `normal` (outward), by
    /// `strength` (0-1) in the middle, fading to the edge. Fills below it with `part`.
    void flatten(const Vector3 &center, float radius, const Vector3 &normal, const Vector3 &point,
            float strength, int part);
    /// A closed mesh (triangles `index` into `verts`, samples) as a solid: inside by
    /// ray parity along x, distance to its nearest triangle.
    void stamp_mesh(int op, const PackedVector3Array &verts, const PackedInt32Array &index, int part);

    /// The whole form scaled by `factor` about `pivot` (samples).
    void scale(float factor, const Vector3 &pivot);
    /// The whole form blurred `passes` times (each sample to the mean of its 27).
    void blur(int passes);
    void clear();

    /// The solid brick cells: x, y, z, part, flag for each.
    PackedInt32Array cells() const;
    /// Writes back the cells that differ between `before` and `after` (both as
    /// `cells` gives them; flags ignored).
    void sync_cells(const PackedInt32Array &before, const PackedInt32Array &after);

    /// Undo: start recording; end gives the blocks as they were before, and
    /// `swap_blocks` puts such a record back and gives the record of what it replaced.
    void begin_edit();
    PackedByteArray end_edit();
    PackedByteArray swap_blocks(const PackedByteArray &record);

    /// Blocks changed since the last call (block coordinates).
    Array take_dirty();
    Array block_keys() const;
    /// The surface in block `b` (surface nets, normals from the field), in samples
    /// from the grid's corner: ArrayMesh arrays with COLOR from `palette[part]` (lighter
    /// where marked smooth), or empty.
    Array mesh_block(const Vector3i &b, const PackedColorArray &palette) const;

    /// The first surface point along a ray (samples), or null.
    Variant raycast(const Vector3 &from, const Vector3 &dir, float max_dist) const;
    float sample(const Vector3 &p) const;
    int part_near(const Vector3 &p) const;
    /// The box round every stored sample that is inside, in samples (empty: size 0).
    AABB bounds() const;
    int block_count() const;

    /// Dense distances of part `part` (0: every part) over `dims` samples from `lo`:
    /// another part's solid counts as just outside, so each part ends where its label
    /// does. `smooth_only`: unmarked (brick) samples count as just outside too, so a
    /// custom part ends where its bricks begin. For shells.
    PackedFloat32Array part_field(int part, const Vector3i &lo, const Vector3i &dims, bool smooth_only = false) const;

    PackedByteArray to_bytes() const;
    bool from_bytes(const PackedByteArray &bytes);
};
