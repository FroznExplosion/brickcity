#pragma once

#include <godot_cpp/classes/ref_counted.hpp>
#include <godot_cpp/variant/array.hpp>
#include <godot_cpp/variant/dictionary.hpp>
#include <godot_cpp/variant/packed_byte_array.hpp>
#include <godot_cpp/variant/vector3.hpp>
#include <godot_cpp/variant/vector3i.hpp>

using namespace godot;

/// WATER AND LAVA ON THE BRICK GRID. Docs/MineWater.md.
///
/// A layer on the terrain's own grid: a cell is one stud by one brick course
/// (three of the terrain's plate cells), and inside it the fluid has a level
/// in whole plates, 1 to 3. The terrain is read (which plates are solid); the
/// fluid is never written into it, so moving water re-meshes only its own
/// small mesh.
///
/// Four kinds: SOURCE (infinite, the sea, a source brick), FLOW (fed by a
/// source, level by distance: Minecraft's rules), FALL (fed, dropping), STILL
/// (a water brick's water: whole tiles, conserved, thin spills dry).
///
/// Generated water (the sea) is a function of the seed: nothing is stored for
/// it until something disturbs it. Only cells that changed are visited, so a
/// calm world costs nothing. A tick runs on a worker thread; the main thread
/// starts it, polls it, never waits on it.
class BrickFluid : public RefCounted {
    GDCLASS(BrickFluid, RefCounted)

protected:
    static void _bind_methods();

public:
    enum Fluid { NONE = 0, WATER = 1, LAVA = 2 };
    enum Kind { SOURCE = 0, FLOW = 1, FALL = 2, STILL = 3 };

    /// Forget everything. `sea_m` is snapped to a brick course (the sea's top
    /// is a course of bricks); returns the snapped level in metres.
    static double reset(double sea_m, bool sea_on);
    static double get_sea_level();
    static int get_sea_course();
    static bool get_sea_on();

    /// Where the player is, and how far round them fluid ticks. Past it,
    /// cells wait (frozen) until someone comes back.
    static void set_centre(Vector3 at, double sim_radius_m);
    /// Minecraft's sloped tops (corners averaged) or flat plate steps.
    static void set_sloped(bool on);
    static bool get_sloped();

    /// The ground changed over these PLATE cells (inclusive): solids are
    /// read again there and the fluid round them wakes.
    static void terrain_changed(Vector3i lo, Vector3i hi);
    /// Put fluid in a cell (stud, course, stud): `kind` SOURCE or STILL;
    /// `amount` plates (STILL; SOURCE fills the cell). Applied next tick.
    static void place(Vector3i cell, int fluid, int kind, int amount);
    /// Take up to `amount` plates out of a cell (-1: all; a SOURCE goes).
    static void remove(Vector3i cell, int amount);

    /// Call every frame. Starts a tick on a worker when one is due and none is
    /// running. Returns true when a tick finished since the last call and its
    /// results are ready for `take`.
    static bool update(double delta);
    /// The finished tick's results: {"meshes": [{tile: Vector2i, water: Array,
    /// lava: Array, far: bool}], "terrain": PackedInt32Array (x, z, first plate,
    /// last plate, material ...: rock the lava made),
    /// "mask_changed": bool}.
    static Dictionary take();
    /// Probes: run `ticks` ticks now, on this thread.
    static void tick_now(int ticks);
    static bool busy();
    /// Mesh one tile now (probes, a tile coming into view).
    static Dictionary build_tile_mesh(int tx, int tz);
    /// Ask for a tile's mesh with the next tick (it came into view).
    static void request_mesh(int tx, int tz);
    /// Ask for a tile's FAR mesh (one quad per 4 x 4 studs, no sides) with the
    /// next tick: the tile left the sim ring, where water is frozen (8).
    /// take() gives it with "far": true.
    static void request_far_mesh(int tx, int tz);
    /// Tiles that hold anything to draw, as Vector2i.
    static Array drawn_tiles();

    /// What is in a cell: {fluid, kind, amount, dist, solid, ocean, capacity}.
    static Dictionary cell_info(Vector3i cell);
    static Vector3i cell_of(Vector3 p);
    /// The fluid at a point: 0 none, 1 water, 2 lava (by its drawn height).
    static int fluid_at(Vector3 p);
    /// The top of the fluid the point is in, metres; -INF when not in fluid.
    static double surface_at(Vector3 p);
    /// Push of flowing water at a point, m/s.
    static Vector3 flow_at(Vector3 p);
    /// The first fluid or ground cell along a ray: {cell: Vector3i (stud,
    /// course, stud), normal: Vector3i, fluid, kind, amount, position}.
    /// `fluids_only` passes through ground (never: it stops there and says
    /// fluid 0).
    static Dictionary ray_cell(Vector3 from, Vector3 dir, double max_metres);

    /// RG8 over a window of studs (row-major, z then x): R 255 where the
    /// sea's waves must NOT draw (the sea was changed there); G how much of
    /// its wave the sea keeps (0 against calm water). water.gdshader's
    /// pool_mask / pool_calm.
    static PackedByteArray sea_mask(int x0, int z0, int size);
    static int changed_columns();

    static Dictionary stats();
    static int active_count();
    static int section_count();
    /// Still fluid, in plates (units), of one fluid.
    static int64_t still_units(int fluid);

    static PackedByteArray get_save();
    static int set_save(const PackedByteArray &bytes);
};
