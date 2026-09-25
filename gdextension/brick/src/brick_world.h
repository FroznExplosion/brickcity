#ifndef BRICK_WORLD_H
#define BRICK_WORLD_H

#include <godot_cpp/classes/ref_counted.hpp>
#include <godot_cpp/variant/array.hpp>
#include <godot_cpp/variant/color.hpp>
#include <godot_cpp/variant/dictionary.hpp>
#include <godot_cpp/variant/packed_byte_array.hpp>
#include <godot_cpp/variant/packed_int32_array.hpp>
#include <godot_cpp/variant/string.hpp>
#include <godot_cpp/variant/vector2i.hpp>
#include <godot_cpp/variant/vector3.hpp>
#include <godot_cpp/variant/vector3i.hpp>

#include "brick_types.h"

#include <atomic>
#include <deque>
#include <map>
#include <utility>
#include <memory>
#include <thread>
#include <vector>

using namespace godot;

/// Resident destruction state. Plan.md section 3.
///
/// This class OWNS the brick world -- it is not a stateless helper the way a
/// geometry utility would be. GDScript talks to it in deltas: place a block,
/// apply a hit, ask for a mesh. Block data never crosses the boundary.
///
/// M0 scope: the archetype library, dense chunks, integer grid transforms, and
/// mesh building with face culling. Connectivity, stress, clusters and LOD land
/// in M1 through M4 on top of exactly this data layout.
///
/// Registered as RefCounted and held by one autoload. It becomes a real engine
/// singleton when more than one system needs it.
class BrickWorld : public RefCounted {
    GDCLASS(BrickWorld, RefCounted);

protected:
    static void _bind_methods();

public:
    BrickWorld();
    ~BrickWorld();

    // --- archetype library -------------------------------------------------

    /// Bake a part type that fills its bounding box. Size is (studs, plates, studs).
    int bake_archetype(const String &name, Vector3i size, float mass);

    /// Bake a part that does NOT fill its bounding box.
    ///
    ///   cells    size.x*size.y*size.z, 1 where the part is solid. Empty = full box.
    ///   studs    size.x*size.z, 1 where the top carries a stud. Empty = all.
    ///   sockets  size.x*size.z, 1 where the underside accepts one. Empty = all.
    ///
    /// This is the seam for slopes, arches, brackets and anything else spec
    /// section 2 calls a curve. Occupancy, connectivity, stress, meshing and
    /// collision all read the mask, so nothing downstream assumes a box.
    int bake_shaped_archetype(const String &name, Vector3i size, float mass,
            const PackedByteArray &cells, const PackedByteArray &studs,
            const PackedByteArray &sockets);

    /// Bake an ORIENTED copy of an existing archetype. Docs/BuildMode.md
    /// section 3: orientation is baked as separate archetypes, never stored on
    /// a block, because the alternative puts a rotation on the hot path to save
    /// memory that is not scarce.
    ///
    /// `yaw` is quarter turns about +Y, 0..3 -- both axes are studs, so this is
    /// always integer. `flip` is 180 degrees about X, which leaves every extent
    /// unchanged and swaps which face carries studs. Those eight are the only
    /// grid-legal orientations; a sideways brick is not one of them and cannot
    /// be (section 2.1).
    ///
    /// Returns the id of an EXISTING archetype when the result is identical to
    /// one -- a square brick yawed 90 degrees is the brick it already was, so
    /// callers should expect a many-to-one mapping.
    int bake_variant(int base_archetype, const String &name, int yaw, bool flip);

    /// Face masks, two bits per column: 0 none, 1 stud, 2 socket. Empty arrays
    /// keep the default -- studs up, sockets down.
    int bake_faced_archetype(const String &name, Vector3i size, float mass,
            const PackedByteArray &cells, const PackedByteArray &up_face,
            const PackedByteArray &down_face);

    /// Give a part studs on its LATERAL faces. Six ints per stud:
    /// cell x, y, z then the outward normal dx, dy, dz.
    ///
    /// These are what a sideways frame attaches to. See `get_side_studs`.
    /// Give a part an AUTHORED surface: triangles in its own local metres,
    /// three positions and three normals each. The face bake draws these in
    /// place of voxel faces; nothing else changes -- connectivity, stress and
    /// collision still read the cell mask (gap 8, Docs/BuildMode.md section 10).
    ///
    /// Winding does not matter: each triangle is turned to face along its
    /// normals. Pass empty arrays to go back to voxel faces.
    void set_archetype_mesh(int archetype_id, const PackedVector3Array &positions,
            const PackedVector3Array &normals);
    int get_archetype_mesh_triangles(int archetype_id) const;

    /// Give a part CONVEX HULLS to collide as, each a PackedVector3Array of at
    /// least four points in its own local metres. Both collision paths -- one
    /// body shape per block, and a standing building's merged boxes -- then use
    /// one shared convex shape per hull for it instead of boxes. Pass an empty
    /// array to go back to boxes.
    void set_archetype_hulls(int archetype_id, const Array &hulls);
    int get_archetype_hull_count(int archetype_id) const;

    void set_side_studs(int archetype_id, const PackedInt32Array &studs);
    PackedInt32Array get_archetype_side_studs(int archetype_id) const;

    /// Exposed side studs of a placed block, in WORLD TICKS.
    ///
    /// One dictionary per stud: `lo` and `hi` are the owning cell's tick box,
    /// `dir` is the outward normal in world axes. A stud is left out when the
    /// cell beyond it in this chunk is filled -- it is buried and nothing can
    /// clip to it.
    ///
    /// The caller turns these into a frame: the face plane is `lo` or `hi`
    /// along `dir`'s axis, and a frame whose origin puts its build plane there
    /// meets the stud exactly, whatever the stud/plate parity would otherwise
    /// allow (Docs/BuildMode.md section 2.2).
    Array get_side_studs(int chunk_id, int block_id) const;

    /// What a part offers on its top and bottom faces, per column, for a UI or
    /// a probe. Length is size.x * size.z.
    PackedByteArray get_archetype_up_face(int archetype_id) const;
    PackedByteArray get_archetype_down_face(int archetype_id) const;

    int get_archetype_count() const;
    Vector3i get_archetype_size(int archetype_id) const;
    String get_archetype_name(int archetype_id) const;
    bool is_archetype_full_box(int archetype_id) const;
    int get_archetype_solid_cells(int archetype_id) const;

    // --- chunks ------------------------------------------------------------

    /// Create a dense chunk. origin is in absolute grid coords, dims in cells.
    int create_chunk(Vector3i origin, Vector3i dims);
    int get_chunk_count() const;
    Vector3i get_chunk_origin(int chunk_id) const;
    Vector3i get_chunk_dims(int chunk_id) const;

    /// Place a block with its min corner at an ABSOLUTE grid cell. Returns the
    /// block id, or -1 if it would leave the chunk or overlap something.
    /// `decorative` places the block in the interior role (Block::decorative)
    /// AND KEEPS THE FACE BAKE VALID.
    ///
    /// That second half is the whole reason the argument exists rather than
    /// leaving set_blocks_decorative to do it afterwards. A decorative block is
    /// not in the bake, so placing one changes nothing the bake holds -- and
    /// invalidating it anyway is what made opening one room in a 50,000-brick
    /// building cost 225 ms, 56% of it re-baking faces that had not moved.
    int place_block(int chunk_id, Vector3i cell, int archetype_id, int colour,
            bool decorative = false);

    // --- editing -----------------------------------------------------------
    //
    // Damage and editing are different operations and must stay different.
    // kill_block DESTROYS: the brick is gone and its cells stay claimed, so
    // nothing can be rebuilt into a crater. remove_block UNDOES a placement:
    // the cells come back and the space is reusable. Build mode needs the
    // second and must never get the first (Docs/BuildMode.md section 10).

    /// Take a block out of the chunk and give its cells back. Returns true if
    /// anything was removed. The block RECORD survives as a tombstone owning no
    /// cells, so block ids stay stable for everything that keys on them.
    bool remove_block(int chunk_id, int block_id);

    /// Would this part fit here? Pure occupancy: every solid cell of the
    /// archetype in bounds and unclaimed. This is exactly the test place_block
    /// runs, without the write, so a ghost can ask it every frame.
    bool can_place(int chunk_id, Vector3i cell, int archetype_id) const;

    /// How many stud joints a part placed here would make. 0 means it fits but
    /// floats; -1 means it would not fit at all. Non-mutating.
    ///
    /// This is the ghost's three tint states in one call: -1 red, 0 amber,
    /// positive cyan (Docs/BuildMode.md section 4-5).
    int would_connect(int chunk_id, Vector3i cell, int archetype_id) const;

    /// Kill the block covering an absolute cell. Returns its id, or -1.
    /// M0: flips the alive bit. M1 routes this through connectivity.
    int kill_block(int chunk_id, Vector3i cell);

    /// Destroy blocks by id. This is how a damage record is replayed onto a
    /// freshly materialised building: the bricks are regenerated by the recipe,
    /// then the ones that were gone are made gone again. Requires the recipe to
    /// be deterministic, so id N always means the same brick.
    void kill_blocks(int chunk_id, const PackedInt32Array &ids);

    /// Which XZ columns still hold anything alive between two grid heights.
    ///
    /// dims.x * dims.z bytes, 1 where any alive cell exists in [y0, y1). This
    /// is the cheap representation's view of damage: a shell is built from the
    /// recipe and cannot ask "is block N dead", but it can ask this and get a
    /// silhouette. Deliberately knows nothing about courses, walls or recipes
    /// -- the caller decides what a band is (Docs/BuildMode.md section 9.5).
    PackedByteArray get_column_mask(int chunk_id, int y0, int y1) const;

    /// Every EXPOSED stud in a chunk, as a MultiMesh buffer in chunk-local
    /// metres: TRANSFORM_3D with colours, sixteen floats an instance -- the
    /// same layout BrickTerrain emits, so the same mesh and material draw both.
    ///
    /// A stud is drawn where a live block's face offers one (`up_face` STUD, or
    /// `down_face` STUD on an inverted part) AND the cell it would stand in is
    /// empty. Covering it with another brick removes it, which is not a visual
    /// nicety: a covered stud is inside the brick above it, and drawing it is
    /// ~0.8k wasted triangles a course on a wall and a z-fight on every seam.
    ///
    /// Dead blocks show their neighbours' studs again, because `solid_at` asks
    /// about LIVE blocks -- a crater exposes the studs under it.
    PackedFloat32Array get_chunk_studs(int chunk_id) const;

    /// Gate G1b: what the cheap representation needs to know about the damage.
    ///
    /// band index -> four segment masks, one per wall side; a band with every
    /// segment standing carries no entry, so an intact building profiles empty.
    /// `bands` is (y0, plates) pairs, because the recipe owns the band layout
    /// and this owns the bricks.
    Dictionary build_damage_profile(int chunk_id, int fx, int fz, int thick,
            int segments, PackedInt32Array bands) const;

    /// The damage record: ids of every block destroyed in this chunk. Small for
    /// a lightly damaged building, and the only thing that has to survive
    /// de-materialisation.
    PackedInt32Array get_dead_blocks(int chunk_id) const;
    /// Ids of every block that left this chunk as part of a piece of its own
    /// (split_island): not destroyed, not here. The other half of what a
    /// building rebuilt from its recipe must not grow back -- get_dead_blocks
    /// leaves these out on purpose, and a record of damage alone brought them
    /// back while the piece they left on still existed.
    PackedInt32Array get_detached_blocks(int chunk_id) const;
    /// How many blocks this chunk has lost to damage, without building the
    /// list of them.
    ///
    /// The count is what callers usually want -- "has the damage moved on since
    /// I last looked" is a comparison, not a set -- and building a
    /// PackedInt32Array of every dead block to ask it allocates once per call.
    /// The room streaming pass asked it thousands of times a tick and that was
    /// 180 ms of a 183 ms pass.
    int get_dead_block_count(int chunk_id) const;

    int get_block_archetype(int chunk_id, int block_id) const;
    int get_block_colour(int chunk_id, int block_id) const;
    /// Repaint a placed block: the paint brush. Colour is only a vertex
    /// attribute, so nothing structural changes -- but a face bake holds
    /// colours, so the chunk's bake is dropped and rebuilds on next demand.
    bool set_block_colour(int chunk_id, int block_id, int colour);
    /// Materials (brick_grid.h BRICK_MATERIALS): what a block is made of. The colour
    /// byte is read through it, so repainting a material keeps its colour
    /// index -- which may name a different colour in the new material's list.
    int get_block_material(int chunk_id, int block_id) const;
    bool set_block_material(int chunk_id, int block_id, int material);

    bool is_solid(int chunk_id, Vector3i cell) const;
    int block_at(int chunk_id, Vector3i cell) const;

    int get_block_count(int chunk_id) const;
    int get_alive_block_count(int chunk_id) const;

    /// Index range this block owns in the last built mesh, as (start, count).
    /// The partition that makes damage an index exclusion rather than a remesh.
    Vector2i get_block_index_range(int chunk_id, int block_id) const;

    // --- meshing -----------------------------------------------------------

    /// Build the chunk's surface arrays, ready for
    /// ArrayMesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, ...).
    /// Cut this chunk's drawing into horizontal bands `plates` tall.
    ///
    /// Drawing only: the chunk, the occupancy, the damage record, the stress
    /// solve and the collision are all untouched and stay whole-chunk. What
    /// changes is that the face bake comes out grouped by band, so a band can
    /// be rebuilt and re-uploaded on its own -- and rebuilding a 50,000-brick
    /// tower's mesh costs about 104 ms, which a collapse forces.
    ///
    /// 0 means one band, which is what every chunk is until asked otherwise.
    /// Re-bakes on change.
    void set_chunk_section_plates(int chunk_id, int plates);
    int get_chunk_sections(int chunk_id) const;
    /// Is this chunk's face bake current? A band built while it is not pays
    /// for re-baking the WHOLE chunk on the calling thread -- 55 ms against
    /// 2.6 for an ordinary band -- so the caller waits for an async bake.
    bool has_bake(int chunk_id) const;

    /// One band's arrays, ready for `add_surface_from_arrays`.
    ///
    /// A slice, not a gather: faces are baked band by band, so a band's
    /// vertices are contiguous and this copies a range rather than walking the
    /// chunk. Indices are local to the band.
    Array build_chunk_mesh_section(int chunk_id, int section);

    /// Re-index every band and return the ones whose index bytes MOVED.
    ///
    /// One array of {section, offset, data, changed_bytes} per band that
    /// changed, so damage uploads the band it happened in rather than the
    /// building it happened to. Empty when the bake is gone and the caller must
    /// rebuild.
    Array update_index_regions(int chunk_id, int index_bytes);

    /// Vertices are local to the chunk origin. Interior faces are culled.
    Array build_chunk_mesh(int chunk_id);

    /// Stats from the last build_chunk_mesh call on this chunk.
    Dictionary get_mesh_stats(int chunk_id) const;

    /// Where the memory actually is, in bytes, per chunk and in total. The
    /// question "how many buildings fit" is answered here, not by arithmetic.
    Dictionary get_memory_report() const;

    /// Recompute which faces are drawn and hand back ONLY the bytes that
    /// changed, for RenderingServer.mesh_surface_update_index_region.
    ///
    /// Returns {} when nothing changed, otherwise {offset, data, drawn_faces,
    /// changed_bytes, update_ms}. The vertex buffer is never touched: damage
    /// only ever swaps a face's indices between real and degenerate.
    /// `index_bytes` is the width the SURFACE stores indices at: Godot uses
    /// uint16 at 65536 vertices or fewer and uint32 above, and a patch written
    /// at the wrong width lands as garbage or past the end of the buffer.
    Dictionary update_index_region(int chunk_id, int index_bytes = 4);

    // --- connectivity (M1) -------------------------------------------------

    /// Blocks joined to this one by studs. Derived from the occupancy grid, not
    /// stored: two blocks connect when their footprints overlap in XZ and one
    /// sits directly on the other. Side-by-side blocks in the same course do
    /// NOT connect -- which is what makes a running bond mean something.
    PackedInt32Array get_block_neighbours(int chunk_id, int block_id) const;

    /// One byte per block: 1 where the block is still reachable from a
    /// foundation through live stud connections. Flood fill over the whole
    /// chunk; M2 narrows it to dirty regions.
    PackedByteArray solve_grounded(int chunk_id);

    /// Live blocks that no longer reach the ground, split into connected
    /// groups. Returns Array[PackedInt32Array], largest group first.
    Array find_detached_groups(int chunk_id);

    /// Cells at or below this grid Y anchor the structure. Default 0.
    void set_foundation_level(int chunk_id, int grid_y);

    // --- stress (M2) -------------------------------------------------------

    /// Flow weight down the structure and break joints that cannot carry it.
    ///
    /// Each block's load is its own weight plus everything resting on it,
    /// shared between its supporters in proportion to contact area. A joint's
    /// capacity comes from the same contact area, so a brick holding on by two
    /// studs carries a quarter of what one holding by eight does.
    ///
    /// Blocks are walked in descending grid Y, which is exactly the order that
    /// makes a single pass correct: load only ever moves downward, so a block's
    /// total is final by the time it is reached.
    ///
    /// Only joints in TENSION can fail -- a block hanging from something above
    /// it. Compression is free. A failed joint SEPARATES: both bricks survive
    /// and the hanging piece becomes debris, because ABS does not pulverise
    /// (Docs/BrickFailure.md section 5).
    ///
    /// Returns {failures, separated, max_ratio, blocks_loaded, peak_load,
    /// solve_ms}. Marks support_broken; it does NOT detach anything -- run
    /// find_detached_groups afterwards.
    Dictionary solve_stress(int chunk_id);

    /// What one cell of stud contact can carry IN TENSION, in the same mass
    /// units archetypes use. This is a real quantity, not a tuning knob: a
    /// brick connection releases at 3-5 N, a brick weighs about 2.5 g, so a
    /// stud holds roughly 400 times a 1-unit mass. See Docs/BrickFailure.md.
    ///
    /// There is deliberately no compression capacity. A brick joint carries
    /// ~4200 N in compression against ~4 N in tension -- a thousand to one --
    /// so a stack never crushes, and a standing tower is stable forever.
    void set_tension_per_stud(int chunk_id, float capacity);
    float get_tension_per_stud(int chunk_id) const;

    /// Worst load-to-capacity ratio from the last solve. Below 1.0 the
    /// structure stands.
    float get_max_stress_ratio(int chunk_id) const;

    /// Mark blocks as fixed TO the structure rather than as structure: they
    /// weigh nothing in the stress solve and are left out of the balance test.
    /// See Block::decorative. Returns how many records actually changed.
    ///
    /// Set after placing, not during: place_block always appends a fresh record,
    /// so there is no state to thread through it and no path by which a reused
    /// id inherits somebody else's role.
    int set_blocks_decorative(int chunk_id, const PackedInt32Array &block_ids, bool on);
    bool is_block_decorative(int chunk_id, int block_id) const;
    /// Every decorative block still alive, ascending. For probes and for saving.
    PackedInt32Array get_decorative_blocks(int chunk_id) const;

    /// A block's severed joints, as bits: JOINT_SUPPORT_BROKEN (joined to
    /// nothing) and JOINT_BOTTOM_BROKEN (cut from what is below it). For a
    /// ChunkRecord to carry them through a piece's sleep -- without them every
    /// joint a landing had severed was whole again when the piece woke.
    static constexpr int JOINT_SUPPORT_BROKEN = 1;
    static constexpr int JOINT_BOTTOM_BROKEN = 2;
    int get_block_joints(int chunk_id, int block_id) const;
    /// Restore a block's severed joints. Only ever sets what a record captured;
    /// it is not a way to break or mend structure by hand.
    void set_block_joints(int chunk_id, int block_id, int joints);

    /// Per-block readouts, for debug overlays and probes.
    float get_block_load(int chunk_id, int block_id) const;
    float get_block_capacity(int chunk_id, int block_id) const;
    bool is_support_broken(int chunk_id, int block_id) const;

    /// Is what is still standing actually balanced on what still holds it up?
    ///
    /// Stress answers "can this joint carry the pull". It cannot answer "is this
    /// building about to fall over", because toppling is a rigid-body question:
    /// the centre of mass leaves the support footprint and the whole thing
    /// rotates. Without this, a tower with half its base blown away stays
    /// standing forever -- standing structure is a STATIC body, and only a
    /// piece that disconnects ever becomes dynamic.
    ///
    /// Returns {stable, com, support_min, support_max, overhang, blocks}.
    /// `blocks` is everything still standing, ready to be handed to
    /// split_island so the building topples as one piece.
    Dictionary check_stability(int chunk_id);

    // --- damage ------------------------------------------------------------

    /// Kill every block within radius_m of a world point. Returns the ids
    /// killed, in ascending order.
    PackedInt32Array apply_hit(int chunk_id, Vector3 world_point, float radius_m);

    /// Shear the joints near a world point WITHOUT destroying anything.
    ///
    /// This is what a hard landing does. A brick does not vaporise on impact --
    /// it comes loose. Blocks in range are marked support_broken, which makes
    /// get_components treat each of them as joined to nothing, so the contact
    /// band falls apart into loose bricks and the island splits if that band
    /// cut it in two. Compare apply_hit, which is a projectile destroying
    /// material. Docs/BrickFailure.md section 4.3.
    /// Shear the joints around a point. `max_blocks` above zero keeps only the
    /// nearest that many.
    ///
    /// The cap is not a performance tweak, it is the model. A sphere measured in
    /// METRES over-selects flat thin geometry: a floor plate is one plate tall
    /// against a brick's three and spans the whole footprint, so a 2.6 m sweep
    /// catches eighteen layers of flooring against six courses of wall. Measured
    /// on a 24-course tower, one sweep loosened 86 blocks, 74% of them plates.
    /// An impact carries finite energy; it does not sever an unbounded area.
    /// Shear the joints around a point.
    ///
    /// `peel` false marks every block in range support_broken -- each becomes
    /// its own piece, which is rubble. `peel` true severs only the underside of
    /// the struck region, so it comes away as one clump held together by its
    /// own running bond. Impacts use peel; see Block::bottom_broken.
    PackedInt32Array separate_near(int chunk_id, Vector3 world_point, float radius_m,
            int max_blocks = 0, bool peel = false);

    /// Cut along course boundaries: the seam a brick model separates at.
    ///
    /// Unlike separate_planes, which turns a whole course into loose brick,
    /// this severs one layer of downward joints and leaves both sides solid.
    /// Only works where the cut normal is the chunk's own Y (the only axis
    /// joints run along); returns empty otherwise so the caller can fall back.
    PackedInt32Array sever_seams(int chunk_id, PackedVector3Array world_points,
            Vector3 world_normal);

    // --- detachment --------------------------------------------------------

    /// Lift a group of blocks out of the chunk and hand back everything needed
    /// to spawn it as one rigid cluster:
    ///   mesh   surface arrays, vertices relative to the centre of mass
    ///   boxes  [{pos, size}] per block, also relative to the centre of mass
    ///   com    centre of mass in world space
    ///   mass, block_count
    /// The blocks are marked detached, so the chunk stops meshing and
    /// colliding them.
    Dictionary detach_group(int chunk_id, const PackedInt32Array &block_ids);

    /// Lift a group of blocks out and make them a CHUNK OF THEIR OWN.
    ///
    /// The island keeps the grid, the archetypes, the connectivity and the
    /// block ids' meaning, so every query works on it: it can be shot, re-solved
    /// and split again. That is what a bag of boxes cannot do, and it is the
    /// groundwork for breaking a cluster apart when it lands.
    ///
    /// Returns {chunk (the new id), com (world), mass, block_count, local_com}.
    /// `local_com` is the centre of mass in the island's own space, which is
    /// what a rigid body wants as its centre-of-mass offset.
    Dictionary split_island(int chunk_id, const PackedInt32Array &block_ids);

    /// Connected components of the live blocks, ignoring the ground entirely.
    /// This is the island question: after damage, is this still one piece?
    /// Largest first, same as find_detached_groups.
    Array get_components(int chunk_id);

    /// Free a chunk's storage. Ids are not reused, so anything still holding
    /// this id gets an empty answer rather than somebody else's blocks.
    void release_chunk(int chunk_id);
    bool is_chunk_alive(int chunk_id) const;
    bool is_chunk_anchored(int chunk_id) const;
    /// Hand a standing chunk over to the physics: it stops being held up by its
    /// own foundation and starts being held up by whatever it lands on.
    void set_chunk_anchored(int chunk_id, bool anchored);

    /// Centre of mass of a chunk's living blocks, in chunk space. Cheap -- the
    /// same walk as get_chunk_mass, with no boxes built.
    Vector3 get_chunk_com(int chunk_id) const;

    /// Sever every joint in a slab of the chunk, rather than a ball of it.
    ///
    /// This is what a long piece striking something across its middle does. A
    /// beam hit mid-span is in bending, and the tension runs across the WHOLE
    /// cross-section at the point of impact, so it comes apart in two long
    /// pieces rather than shedding a handful of bricks around the contact.
    /// `thickness` is the full width of the band, in metres.
    PackedInt32Array separate_plane(int chunk_id, Vector3 world_point,
            Vector3 world_normal, float thickness);

    /// Several parallel breaks in ONE walk of the chunk.
    ///
    /// A landing can tear a piece across in half a dozen places, and doing them
    /// one at a time walks every block in the chunk half a dozen times. The
    /// planes all share a normal -- they are slices across the same long axis --
    /// so one pass can test a block against all of them.
    PackedInt32Array separate_planes(int chunk_id, PackedVector3Array world_points,
            Vector3 world_normal, float thickness);

    // --- placement in the world -------------------------------------------

    /// Islands move, so every world-space query goes through this.
    void set_chunk_transform(int chunk_id, Transform3D xform);
    Transform3D get_chunk_transform(int chunk_id) const;

    // --- collision authoring ----------------------------------------------

    /// Collision boxes for a compound body, in block-id order.
    ///
    /// {block, pos (chunk-local metres), size (metres), alive}. A box-shaped
    /// part contributes ONE entry; a masked part contributes one per solid
    /// cell, so shape index no longer equals block id and the caller has to
    /// keep a block -> shape-indices map. That is the price of odd shapes and
    /// it is worth paying here rather than discovering it later.
    Array get_block_boxes(int chunk_id) const;

    /// Same list, offset so the centre of mass is at the origin -- what a
    /// rigid body wants. Returns {boxes, com, mass}.
    Dictionary get_body_boxes(int chunk_id) const;

    /// Timings and counts from the last solve_grounded / find_detached_groups.
    Dictionary get_solve_stats(int chunk_id) const;

    // --- grid --------------------------------------------------------------

    static Vector3 grid_to_world(Vector3i cell);
    static Vector3i world_to_grid(Vector3 pos);
    static Vector3 get_cell_size();
    static float get_stud_metres();
    static float get_plate_metres();
    static Color get_filament_colour(int index);
    static int get_filament_count();
    static int get_material_count();
    static String get_material_name(int material);
    static bool is_filament_material(int material);
    static int get_material_colour_count(int material);
    /// RGB resolved through the material; alpha carries the material to the
    /// shaders (1.0 = material 0). See brick_grid.h block_rgba.
    static Color get_material_colour(int material, int colour);
    static String get_material_colour_name(int material, int colour);

    // --- determinism (Plan.md D9) -----------------------------------------

    /// Every random draw in the brick world comes from here. Never randf().
    // --- threaded face bake -------------------------------------------------
    // The bake is a pure function of a chunk's geometry: which blocks sit
    // where, what shape they are, what colour. It reads none of the state
    // damage changes, so it can run off the main thread while the game keeps
    // playing. It is the single most expensive thing a collapse does.
    void bake_chunk_async(int chunk_id);
    bool bake_ready(int chunk_id);
    bool bake_pending(int chunk_id) const;
    /// Throw a chunk's baked faces away. The bake is 98% of what a chunk costs,
    /// and wreckage nobody is near has no use for it; bake_chunk_async builds it
    /// again when it matters.
    void drop_chunk_bake(int chunk_id);
    int bakes_in_flight() const;

    /// Which way is down for this chunk, in ITS OWN grid axes.
    ///
    /// A chunk's grid does not rotate when the piece it holds topples -- only
    /// its transform does. So for a building lying on its side, weight no
    /// longer flows along grid -Y, and a solve that assumes it does is solving
    /// a building that is not there. Pass the world's down vector rotated into
    /// chunk space and snapped to the nearest grid axis; the foundation level
    /// is recomputed from the blocks that are actually lowest along it.
    void set_chunk_gravity(int chunk_id, Vector3i down);
    Vector3i get_chunk_gravity(int chunk_id) const;

    /// Build a body's collision shapes for a whole chunk, in one call.
    ///
    /// The same work done from GDScript is one `body_add_shape` per block
    /// across the script/engine boundary -- 2,800 of them for a toppling
    /// building, and 35% of what cutting an island out of one costs. Box shapes
    /// are cached by size and shared, because a city has a handful of distinct
    /// brick sizes and tens of thousands of bricks.
    ///
    /// `offset` is subtracted from every box position, for bodies positioned at
    /// their centre of mass. Returns block id -> the shape indices it owns.
    /// `merge` collapses runs of solid cells into as few boxes as possible,
    /// ignoring which block owns them. A settled piece is inert scenery and one
    /// box per brick is what a collapse makes the solver pay for; a merged box
    /// cannot be disabled per block, so anything that damages the piece has to
    /// rebuild its shapes un-merged first.
    Dictionary add_chunk_shapes(RID body, int chunk_id, Vector3 offset, bool skip_dead,
            bool merge = false);

    /// A stable name for what a chunk HOLDS, independent of how it came to
    /// hold it.
    ///
    /// Chunk ids are array indices handed out in creation order, and creation
    /// order is decided by wall-clock budgets -- so two machines running the
    /// same damage shed the same pieces but number them differently. Hashing
    /// the content instead gives every piece the same name everywhere. Built
    /// from each living block's absolute cell and archetype, in sorted cell
    /// order, so it does not depend on block ordering either.
    int64_t get_chunk_content_hash(int chunk_id) const;

    /// Total mass of a chunk's living blocks. Cheap; no boxes built.
    float get_chunk_mass(int chunk_id) const;

    // --- frames -----------------------------------------------------------
    //
    // A FRAME is this chunk at one of the 24 axis-aligned rotations, offset by
    // an exact integer number of TICKS. Docs/BuildMode.md section 2.
    //
    // A tick is gcd(stud, plate) = 0.07 m, so a stud is 5 ticks and a plate is
    // 2. That is the coincidence the whole thing rests on -- 5 plates is
    // exactly 2 studs -- and it means two frames at different rotations can be
    // offset so their bricks actually meet, with no float anywhere in the test.
    //
    // The tick lattice is NEVER an occupancy grid. It is three integers per
    // frame, not per cell; nothing allocates against it. (A 0.07 m occupancy
    // grid would be 50x the cells per block and is not on the table.)

    static int ticks_per_stud();
    static int ticks_per_plate();

    /// Place this chunk as a frame: one of the 24 rotations, at a tick offset.
    /// Recomputes the chunk transform, so nothing downstream needs to know.
    void set_chunk_frame(int chunk_id, int rotation, Vector3i origin_ticks);
    int get_chunk_rotation(int chunk_id) const;
    Vector3i get_chunk_origin_ticks(int chunk_id) const;

    /// Number of axis-aligned rotations. 24, and the sideways ones are in here
    /// -- that is the point of a frame.
    static int rotation_count();

    /// A block's axis-aligned bounding box in WORLD TICKS, as (min, size).
    /// Exact integers whatever the frame's rotation.
    Array get_block_ticks(int chunk_id, int block_id) const;

    /// Would a part placed here collide with anything in another frame?
    /// Occupancy is per chunk, so nothing else can see across a frame boundary.
    /// Authoring-time only; never on the damage path.
    bool overlaps_frame(int chunk_id, Vector3i cell, int archetype_id, int other_chunk) const;

    /// Live blocks of `other_chunk` whose tick box intersects this block's.
    PackedInt32Array get_frame_overlaps(int chunk_id, int block_id, int other_chunk) const;

    // --- welds ------------------------------------------------------------
    //
    // The one STORED graph in the system. Everything else is derived from the
    // occupancy grid and so cannot go stale -- a weld names two specific
    // blocks, so it can.
    //
    // The answer is to store the endpoints but DERIVE the aliveness: a weld is
    // alive exactly while both of its blocks are. Nothing has to be invalidated
    // when a block dies, because nothing cached the answer.

    int add_weld(int chunk_a, int block_a, int chunk_b, int block_b);
    int get_weld_count() const;
    bool is_weld_alive(int weld_id) const;
    Dictionary get_weld(int weld_id) const;
    /// Ids of every weld whose endpoints are both still alive.
    PackedInt32Array get_live_welds() const;
    /// Drop a weld permanently. Editing, not damage.
    bool remove_weld(int weld_id);

    // --- grounding from an explicit seed set -------------------------------

    /// solve_grounded, but seeded from the blocks you name instead of from the
    /// foundation plane.
    ///
    /// A rotated frame has no foundation of its own: its path to ground runs
    /// sideways, through a weld, into another chunk. Without this every
    /// sideways sub-assembly reads as ungrounded and falls off on the first
    /// solve -- the same failure the interior floor slabs had, and it presents
    /// identically. Docs/BuildMode.md section 3.3.
    PackedByteArray solve_grounded_from(int chunk_id, const PackedInt32Array &seeds);

    void set_seed(int64_t seed);
    int64_t get_seed() const;

private:
    std::vector<brick::Archetype> archetypes;
    // A deque, not a vector, for one reason: the face bake runs on a worker
    // thread holding a reference to its chunk, and creating another chunk
    // meanwhile must not move the one being baked. deque never invalidates
    // references on push_back; vector does.
    std::deque<brick::Chunk> chunks;
    // Chunk ids are never reused. A released chunk keeps its slot and answers
    // empty, so a stale id is harmless rather than pointing at an island that
    // happens to have been created since.
    std::vector<uint8_t> chunk_live;

    struct MeshStats {
        int faces_emitted = 0;
        int faces_culled = 0;
        int vertices = 0;
        int indices = 0;
        int blocks_meshed = 0;
        int baked_faces = 0;
        double bake_ms = 0.0;
        double compact_ms = 0.0;
    };
    std::vector<MeshStats> stats;

    struct SolveStats {
        int blocks_visited = 0;
        int grounded = 0;
        int ungrounded = 0;
        int groups = 0;
        double solve_ms = 0.0;
    };
    std::vector<SolveStats> solve_stats;
    std::vector<int> foundation_level;
    /// Per chunk, which grid direction gravity pulls toward. (0,-1,0) unless a
    /// piece has toppled and someone told us otherwise.
    std::vector<Vector3i> chunk_down;

    struct StressState {
        // Tension only. 3-5 N to release a connection, ~2.5 g per brick, so a stud
        // holds roughly 400 times a 1-unit mass. Docs/BrickFailure.md section 4.2.
        float tension_per_stud = 400.0f;
        float max_ratio = 0.0f;
        int failures = 0;
    };
    std::vector<StressState> stress;

    // The support DAG from the last grounding solve: scratch_queue holds the
    // BFS visit order and scratch_depth how many joints each block is from the
    // ground. Load flows from a block to every neighbour of strictly lower
    // depth, shared by contact area -- NOT down a spanning tree, which would
    // funnel a whole building through one edge, and not straight down either,
    // which leaves an undercut wall transmitting nothing.
    std::vector<int32_t> scratch_depth;

    int64_t rng_seed = 0;
    uint64_t rng_state = 0;

    // Scratch reused across solves so a collapse does not allocate per hit.
    std::vector<uint8_t> scratch_mark;
    std::vector<int32_t> scratch_queue;

    /// A weld: two blocks in two frames, held rigidly together.
    ///
    /// `present` is whether the weld was ever removed by an EDIT. Whether it is
    /// currently load-bearing is derived from its blocks and never stored.
    struct Weld {
        int32_t chunk_a = -1;
        int32_t block_a = -1;
        int32_t chunk_b = -1;
        int32_t block_b = -1;
        bool present = false;
    };
    std::vector<Weld> welds;

    bool valid_chunk(int chunk_id) const;
    bool valid_archetype(int archetype_id) const;

    /// Generate every potentially-visible face of a chunk, once. Invalidated
    /// by placement, never by damage.
    void bake_chunk_faces(brick::Chunk &c);

    /// One chunk's bake, running or finished, on a thread of its own.
    struct BakeJob {
        int chunk_id = -1;
        brick::FaceBake bake;
        std::vector<brick::Archetype> parts; // snapshot: the palette is shared
        std::atomic<bool> done{false};
        std::thread worker;
    };
    std::vector<std::unique_ptr<BakeJob>> bake_jobs;

    /// Box collision shapes, shared by size. Keyed by size in tenths of a
    /// millimetre so a float size is a stable key.
    std::map<Vector3i, RID> box_shapes;
    /// (archetype, hull) -> shared convex shape. Created on first use, like
    /// box_shapes, and freed with the world.
    std::map<std::pair<int, int>, RID> hull_shapes;
    RID hull_shape_for(int archetype_id, int hull);
    void free_hull_shapes(int archetype_id);
    RID box_shape_for(const Vector3 &size);
    Dictionary add_merged_shapes(RID body, int chunk_id, Vector3 offset);

    BakeJob *find_bake_job(int chunk_id);
    /// Join a chunk's bake if one is running. `adopt` takes the result; without
    /// it the work is thrown away, which is what a geometry change wants.
    void settle_bake_job(int chunk_id, bool adopt);

    /// Fill c.live_indices for the current alive state. Fixed length: six per
    /// baked face, degenerate where the face is not drawn.
    void fill_indices(brick::Chunk &c, MeshStats &st, PackedInt32Array &out);

    /// Shared meshing core. mask == nullptr means "every live block"; otherwise
    /// only masked blocks are meshed AND only masked blocks cull each other's
    /// faces, so a group that breaks away grows a surface where the break was.
    Array build_mesh_internal(brick::Chunk &c, MeshStats &st,
            const std::vector<uint8_t> *mask, const Vector3 &offset, bool write_ranges);

    /// Centre of a block in chunk-local metres, plus its size in metres.
    void block_extent(const brick::Chunk &c, const brick::Block &b,
            Vector3 &out_centre, Vector3 &out_size) const;
};

#endif // BRICK_WORLD_H
