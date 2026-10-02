#pragma once

#include <godot_cpp/classes/ref_counted.hpp>
#include <godot_cpp/variant/array.hpp>
#include <godot_cpp/variant/dictionary.hpp>
#include <godot_cpp/variant/rect2i.hpp>

using namespace godot;

/// POOLS: water that flows over the heightfield, near where the ground was
/// dug. Docs/Water.md section 12.
///
/// The sea stays what it was -- one wave function over the ground the world
/// was GENERATED with, infinite and never drained. A hole dug below sea level
/// where the world was dry is not sea: it fills by flowing in from the sea
/// columns next to it (a breach), or by seeping in from a beach close to the
/// sea, and the water in it is a pool of its own -- calm, flat, a brick tall
/// per course.
///
/// One water depth per stud column, in tiles of TILE x TILE, held only where
/// there is something to hold: a tile is made when the ground under it is
/// dug below the sea, or when water flows to its edge. Flow is the "virtual
/// pipe" model -- a flux out of each column to each of its four neighbours,
/// driven by the difference in water level, with momentum -- and only the
/// columns that changed (or whose neighbour did) are ticked, so a still pool
/// costs nothing.
class BrickPools : public RefCounted {
    GDCLASS(BrickPools, RefCounted)

protected:
    static void _bind_methods();

public:
    /// Forget every pool.
    static void clear();
    /// The ground changed over these studs: re-read the floor of every tile
    /// that holds water there, and make tiles where the ground is now below
    /// the sea but the world as generated was not. Returns the tiles touched.
    static int ground_changed(const Rect2i &studs);
    /// After a world loads: every sculpted tile is a ground change.
    static int scan_sculpt();
    /// Advance by `delta` seconds (fixed sub-steps inside). Returns the
    /// columns that were ticked.
    static int tick(double delta);
    /// Run `ticks` sub-steps at once: a loaded world's pools are full before
    /// anyone sees them.
    static void settle(int ticks);

    /// The pool's surface over a world point, in metres. NAN where this
    /// system says nothing (no pool tile there, or the column is sea: ask the
    /// wave); -INF where the column is dug, dry, and not sea.
    static double level_at(double x, double z);
    /// Water depth over a column's floor, in metres (0 for sea or untracked).
    static double depth_at(int x, int z);
    /// Pour water onto a column (tests; a burst tank later).
    static void add_water(int x, int z, double metres);
    /// Water in pools (not sea), in cubic metres.
    static double total_volume();
    static int active_count();
    /// The ticked columns, for a HUD or a probe: x, z, sea, floor, depth,
    /// flux (four), calm.
    static Array active_columns(int limit);
    static int tile_count();

    /// Tiles whose drawn water changed since the last call, as Vector2i.
    static Array take_dirty_tiles();
    /// The tile's water as mesh arrays ({"mesh": Array, "triangle_count"}).
    /// "mesh" is empty when there is nothing to draw.
    static Dictionary build_mesh(int tx, int tz);

    /// Seeping: a dug column within `studs` of the sea fills toward sea level
    /// at `metres_per_second` even with ground between (a hole in a beach).
    static void set_seep(int studs, double metres_per_second);
};
