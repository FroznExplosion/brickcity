#pragma once

#include <godot_cpp/classes/ref_counted.hpp>
#include <godot_cpp/variant/array.hpp>
#include <godot_cpp/variant/dictionary.hpp>
#include <godot_cpp/variant/vector2i.hpp>

using namespace godot;

#include <array>
#include <functional>
#include <memory>
#include <vector>
#include <unordered_map>

namespace brick {
/// A fitted brick: its min corner (studs), bottom course, size in studs and
/// courses, the material of most of its cells (its strength; each cell keeps
/// its own colour).
struct FitBrick {
    int x = 0, z = 0, c = 0, sx = 1, sz = 1, h = 1, mat = 0;
};
/// THE LOOKUP (Docs/TerrainRegions.md 12): the fitted brick a GENERATED cell
/// is in, at any depth. Any thread; a region's first ask fits it (with its
/// tile's others), later ones are a lookup. False where no brick is fitted:
/// air, the top course (the surface's pieces), sand and gravel (their own
/// 1x1s), partly solid cells, no biome generator, not configured. Edits are
/// the caller's to check.
bool fitted_brick(int x, int course, int z, FitBrick &out);
/// Many lookups from one thread (a tile's mesh, a survey): the regions it
/// has read stay open, no lock taken for them.
class FitView {
public:
    FitView();
    ~FitView();
    FitView(const FitView &) = delete;
    FitView &operator=(const FitView &) = delete;
    bool at(int x, int course, int z, FitBrick &out);
    /// The regions holding these cells {x, course, z} fitted in one go (a
    /// tile's mesh asks its open faces first): a miss in `at` fits the
    /// whole of its tile's layers instead.
    void prefetch(const std::vector<std::array<int, 3>> &cells);
    void clear();

private:
    struct Open;
    std::unordered_map<int64_t, std::unique_ptr<Open>> open_;
    Open *last_ = nullptr;
    uint64_t gen_ = 0;
};
/// The game's ground bricks come from the fit (TerrainFit.set_enabled).
bool fit_enabled();

/// THE TOP COURSE's bricks (Docs/TerrainRegions.md 12.3): the surface's
/// pieces cut by the fit, not the old pattern. A cell's brick is fitted in
/// its square of its course among the cells `group` says go with it (the
/// packer's rule: same height, material, colour, free), each one's bond
/// group (BOND_MEDIUM / STRONG; NONE: not with it): a pure function of
/// those cells, so tiles either side of an edge agree. One course only.
/// `cls` names the group (the packer's height, material and colour), the
/// memo keeps a square's fit for one caller.
class TopFitMemo {
public:
    TopFitMemo();
    ~TopFitMemo();
    struct Square;
    std::unordered_map<uint64_t, std::unique_ptr<Square>> squares;
};
bool fit_top(TopFitMemo &memo, int x, int course, int z, uint64_t cls,
        const std::function<int(int, int)> &group, FitBrick &out);
/// Column (x, z)'s GENERATED top plate and the material there (edits
/// ignored), kept by tile. False without the biome generator.
bool generated_top(int x, int z, int &plate, int &mat);
/// A group let go of at least this many cells floats (the world's
/// "float_cells"; 0 never). Docs/TerrainRegions.md 11.
int fit_float_cells();

/// Drops every kept region (new settings, a new world).
void fitted_clear();
} // namespace brick

/// THE REGION FIT (Docs/TerrainRegions.md 3, 11): bricks of random sizes,
/// fitted per region from the GENERATED cells, staggered by a score.
/// Stage B1: only the probe's side (region_fit_probe) -- nothing in the game
/// reads it yet.
///
/// A cell is one stud by one course (3 plates). Courses come in LAYERS of
/// three; a tall brick stays inside its layer. Each course is cut into
/// 16 x 16 squares, shifted 8 studs on odd courses, so a cut never stands
/// over a cut; a brick stays inside its square in every course it spans.
/// Even layers are fitted first, each on its own (a pure function of the
/// generated cells); odd layers are then scored against the even layers
/// under and over them, so the stagger never needs more than one layer
/// round it.
class TerrainFit : public RefCounted {
    GDCLASS(TerrainFit, RefCounted);

protected:
    static void _bind_methods();

public:
    /// Runs the fits a probe asks for over sampled areas of the current
    /// world. `areas`: Vector2i tile origins of 5 x 5 tile areas (metrics on
    /// the middle 3 x 3). `variants`: Dictionaries (see terrain_fit.cpp
    /// FitParams). Returns one Dictionary a variant: metrics summed over the
    /// areas, plus pictures of the first area.
    static Array run(const Array &areas, const Array &variants);
    /// The world's fill settings (the worldgen preset's "bricks",
    /// WorldgenPresets.DEFAULT_BRICKS' keys). Held for the game's bricks.
    static void configure(const Dictionary &settings);
    static Dictionary get_configured();
    /// fitted_brick for scripts: {x, z, c, sx, sz, h, mat, loose}, or empty.
    static Dictionary brick_at(int x, int course, int z);
    static Dictionary lookup_stats();
    /// The lookup against the batch fit (region_fit_probe): counts of cells
    /// checked, wrong and missing, from `threads` threads.
    static Dictionary check_lookup(Vector2i tile, int threads = 4, int depth = 0);
    /// The game's ground bricks from the fit (off: the old pattern). Every
    /// tile is drawn again.
    static void set_enabled(bool on);
    /// generated_cells made fresh against the kept tile and sections.
    static Dictionary check_generated(Vector2i tile, int y_lo, int y_hi);
    static bool get_enabled();
};
