#pragma once

#include <godot_cpp/classes/ref_counted.hpp>
#include <godot_cpp/variant/aabb.hpp>
#include <godot_cpp/variant/color.hpp>
#include <godot_cpp/variant/array.hpp>
#include <godot_cpp/variant/packed_byte_array.hpp>
#include <godot_cpp/variant/packed_color_array.hpp>
#include <godot_cpp/variant/packed_float32_array.hpp>
#include <godot_cpp/variant/packed_int32_array.hpp>
#include <godot_cpp/variant/packed_vector2_array.hpp>
#include <godot_cpp/variant/packed_vector3_array.hpp>
#include <godot_cpp/variant/transform3d.hpp>
#include <godot_cpp/variant/vector2.hpp>
#include <godot_cpp/variant/vector3.hpp>
#include <godot_cpp/variant/vector3i.hpp>

#include <cstdint>
#include <memory>
#include <unordered_map>
#include <vector>

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
///
/// Colour (Docs/AssetWorkshop.md, "Colour from model to bricks"): every sample also
/// keeps a colour, none until something gives it one. A model stamped with its
/// vertex colours gives each sample the colour of the model's surface nearest it;
/// a brush gives `set_colour`'s (none by default); COLOUR repaints. The surface is
/// drawn in it; `cell_colours` votes each brick cell's colour from a palette (in
/// Oklab, as the eye sees colour), and `sync_cells` gives bricks' colours back.
class SdfForm : public RefCounted {
    GDCLASS(SdfForm, RefCounted)

public:
    static constexpr int B = 16;            // block edge, samples
    static constexpr int B3 = B * B * B;
    static constexpr float BAND = 6.0f;     // samples
    static constexpr int STUD = 5;          // samples a stud
    static constexpr int PLATE = 2;         // samples a plate

    enum Op { ADD = 0, REMOVE = 1, SMOOTH = 2, PAINT = 3, MARK = 4, UNMARK = 5, GROW = 6, COLOUR = 7 };
    enum Shape { SHAPE_BOX = 0, SHAPE_CONE = 1 };

    struct Block {
        float d[B3];
        uint8_t part[B3];
        uint8_t flag[B3];
        // RGBA8 (r in the high byte); 0: no colour of its own (drawn in its part's).
        // Last, so an older save's blocks (without it) read as the leading bytes.
        uint32_t col[B3];
    };
    /// A block's size before colours (the "SDF1" saves).
    static constexpr int64_t BLOCK_V1 = (int64_t)B3 * (sizeof(float) + 2);

protected:
    static void _bind_methods();

private:
    std::unordered_map<int64_t, std::unique_ptr<Block>> blocks;
    // While an edit records: each block as it was when the edit first touched it
    // (null: it did not exist).
    bool recording = false;
    std::unordered_map<int64_t, std::unique_ptr<Block>> undo;
    std::unordered_map<int64_t, bool> dirty;
    // What ADD, GROW, flatten and COLOUR give a sample (0: none).
    uint32_t brush_col = 0;
    // While a stamp_mesh with colours runs: each dense sample's colour.
    struct StampCol { const std::vector<uint32_t> *col; Vector3i lo, D; };
    const StampCol *stamp_col = nullptr;
    uint32_t add_col(const Vector3i &s) const;

    static int64_t key(int bx, int by, int bz);
    static Vector3i unkey(int64_t k);
    Block *find(int64_t k) const;
    Block *touch(int64_t k, bool create);
    float d_at(int i, int j, int k) const;
    uint8_t part_at(int i, int j, int k) const;
    uint8_t flag_at(int i, int j, int k) const;
    uint32_t col_at(int i, int j, int k) const;
    // The colour of the inside sample nearest `p` among the eight round it (0: none).
    uint32_t col_near(const Vector3 &p) const;
    struct Cell { int x, y, z, part, flag; };
    std::vector<Cell> cell_list() const;
    float trilinear(const Vector3 &p) const;

    // Calls fn(block, index, sample) for every sample in [lo, hi], creating blocks
    // when `create`.
    template <typename F>
    void each(const Vector3i &lo, const Vector3i &hi, bool create, F fn);

    void apply_shape(int op, const Vector3i &lo, const Vector3i &hi, float blend, int part,
            float (*sdf)(const Vector3 &, const void *), const void *ctx);
    void cell_box(const Vector3i &c, int op, int part);
    void grow(const Vector3 &a, const Vector3 &b, float radius, float amount, int part);
    // Every sample from where it came through `xf` (samples to samples, affine): distances
    // scaled by its size, labels and flags from the nearest sample.
    void remap(const Transform3D &xf);

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
    /// ray parity along x, distance to its nearest triangle. `colours` (one a vertex,
    /// optional): with ADD each sample takes the colour of the surface nearest it,
    /// blended across its triangle.
    void stamp_mesh(int op, const PackedVector3Array &verts, const PackedInt32Array &index, int part,
            const PackedColorArray &colours = PackedColorArray());
    /// A lathe: `profile` (out from the axis, along it; samples) closed down to the axis
    /// at both ends and turned about the local y axis, placed by `xform`.
    void lathe(int op, const Transform3D &xform, const PackedVector2Array &profile, float blend, int part);

    /// Catalogue pieces fitted to the field (Docs/AssetWorkshop.md, "SDF tools, round 3").
    /// `cells`: x, y, z of the brick cells a piece may take. `pieces`: [{grid:
    /// PackedByteArray (1 solid, x fastest, a byte a sample: 5 x 2 x 5 a cell), size:
    /// Vector3i cells, normal: Vector3 (its open side)}]. A piece is tried where its box
    /// covers a surface cell, its open side within 45 degrees of the field's, its box only
    /// `cells` or empty; it goes in when it matches the field's samples better than the
    /// box's cells as bricks by `min_gain` of its samples, the biggest gain first, none
    /// overlapping. Returns piece, x, y, z for each.
    PackedInt32Array fit_pieces(const PackedInt32Array &cells, const Array &pieces, float min_gain) const;

    /// The whole form scaled by `factor` about `pivot` (samples).
    void scale(float factor, const Vector3 &pivot);
    /// The whole form moved `by` samples: exact for whole samples, resampled (trilinear,
    /// labels from the nearest) for a part of one -- half a stud is 2.5.
    void move(const Vector3 &by);
    /// The whole form resampled through `xform` (samples to samples; a turn, a size and a
    /// move): a lifted part let go (Docs/AssetWorkshop.md, "Pick and move").
    void transform(const Transform3D &xform);
    /// Part `label` taken out into a form of its own (same grid): there its samples as
    /// they are, every other part's solid just outside; here its solid just outside. So
    /// `combine(ADD)` of the two gives the part back.
    Ref<SdfForm> take_part(int label);
    /// Another form joined into this one, sample for sample (both on the same grid): ADD a
    /// union -- where it is inside, its label through `labels` (labels[its label], kept
    /// when out of range) and its flag -- or REMOVE a carve. A model object into the
    /// block-out (Docs/AssetWorkshop.md, "Models as objects").
    void combine(const Ref<SdfForm> &other, int op, const PackedInt32Array &labels);
    /// The whole form blurred `passes` times (each sample to the mean of its 27).
    void blur(int passes);
    void clear();

    /// The solid brick cells: x, y, z, part, flag for each.
    PackedInt32Array cells() const;
    /// Writes back the cells that differ between `before` and `after` (both as
    /// `cells` gives them; flags ignored). `colours` (optional, one a cell of `after`;
    /// alpha 0: none): the colour each cell added or relabelled takes.
    void sync_cells(const PackedInt32Array &before, const PackedInt32Array &after,
            const PackedColorArray &colours = PackedColorArray());

    /// The colour new clay takes from ADD, GROW and flatten, and COLOUR paints (alpha
    /// 0: none, drawn in its part's colour). None by default.
    void set_colour(const Color &c);
    Color get_colour() const;
    /// The colour at sample `p` (the inside sample nearest it; alpha 0: none).
    Color colour_at(const Vector3 &p) const;
    /// Each cell's colour, one for each cell in `cells`' order: the index into
    /// `palette` that most of the cell's coloured samples are nearest to (in Oklab,
    /// samples near the surface counting most -- the colour that is seen), -1 when no
    /// sample has one. A cell with none takes the nearest coloured cell's, through the
    /// solid, so the inside of a model is its surface's colour, not its part's.
    PackedInt32Array cell_colours(const PackedColorArray &palette) const;

    /// Undo: start recording; end gives the blocks as they were before, and
    /// `swap_blocks` puts such a record back and gives the record of what it replaced.
    void begin_edit();
    PackedByteArray end_edit();
    PackedByteArray swap_blocks(const PackedByteArray &record);

    /// Blocks changed since the last call (block coordinates).
    Array take_dirty();
    Array block_keys() const;
    /// The surface in block `b` (surface nets, normals from the field), in samples
    /// from the grid's corner: ArrayMesh arrays with COLOR from the samples' own colour
    /// (with `own_colours`) else `palette[part]` (lighter where marked smooth), or empty.
    Array mesh_block(const Vector3i &b, const PackedColorArray &palette, bool own_colours = true) const;

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
