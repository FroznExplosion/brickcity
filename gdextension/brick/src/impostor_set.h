#pragma once

#include <godot_cpp/classes/ref_counted.hpp>
#include <godot_cpp/variant/aabb.hpp>
#include <godot_cpp/variant/array.hpp>
#include <godot_cpp/variant/transform3d.hpp>
#include <godot_cpp/variant/vector2i.hpp>
#include <godot_cpp/variant/vector3.hpp>

#include <cstdint>
#include <unordered_map>
#include <vector>

using namespace godot;

/// The bookkeeping half of an ImpostorLod (scripts/impostor_lod.gd,
/// Docs/Impostors.md 3.3, 8): every copy's transform, whether its owner wants
/// it drawn, which tier it is in, and which CHUNK-metre square holds it.
///
/// `update` sorts the copies into tiers by distance and, for each square
/// where any copy changed tier, packs the near and far MultiMesh buffers.
/// That loop -- a distance a copy in every square a range edge crosses, and
/// a twelve-float row a drawn copy on a repack -- was GDScript, 3.8 ms for
/// the 6,000 trees of the heightfield scene. The script keeps everything that
/// is a node, a mesh or a material.
class ImpostorSet : public RefCounted {
    GDCLASS(ImpostorSet, RefCounted)

protected:
    static void _bind_methods();

public:
    void set_chunk(double metres);

    int add(const Transform3D &xf, bool wanted);
    /// Returns true when the copy changed square (the script may need the
    /// new square's nodes).
    bool move(int handle, const Transform3D &xf);
    void remove(int handle);
    int count() const;
    int chunk_count() const;
    void set_wanted(int handle, bool on);
    int tier_of(int handle) const;
    Vector2i key_of(int handle) const;

    /// Every square repacks on the next update (the far tier's mesh changed).
    void mark_all_dirty();
    /// Every copy in tier `from` goes to `to` (a node source's cards landed).
    void retier(int from, int to);

    /// Sort into tiers from `here` and repack the squares where anything
    /// changed. `blend`: a mesh copy crossing the band is drawn as both
    /// (tier 3); `no_card`: nothing can be drawn far yet, so far is near.
    /// Returns one Dictionary a repacked square: key, near, far (row-major
    /// 3x4 transforms, the MultiMesh TRANSFORM_3D layout), n_near, n_far,
    /// far_box (AABB of the far copies' origins), has_far.
    Array update(const Vector3 &here, double near_range, double cull_range, double hysteresis,
            bool blend, bool no_card);
    int get_near_count() const { return near_count; }
    int get_far_count() const { return far_count; }

private:
    struct Chunk {
        std::vector<int> members;
        bool dirty = true;
    };
    static int64_t pack(const Vector2i &k) { return ((int64_t)k.x << 32) ^ (int64_t)(uint32_t)k.y; }
    Vector2i key(const Vector3 &p) const;
    Chunk &chunk(const Vector2i &k);

    double chunk_m = 128.0;
    std::vector<Transform3D> xf;
    std::vector<uint8_t> want;
    std::vector<uint8_t> tier;     ///< 0 hidden, 1 near, 2 far, 3 both (the band)
    std::vector<Vector2i> chunk_of;
    std::vector<uint8_t> is_free;
    std::vector<int> free_list;
    std::unordered_map<int64_t, Chunk> chunks;
    std::unordered_map<int64_t, Vector2i> chunk_keys;
    int near_count = 0;
    int far_count = 0;
};
