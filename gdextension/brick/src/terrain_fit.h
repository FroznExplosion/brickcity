#pragma once

#include <godot_cpp/classes/ref_counted.hpp>
#include <godot_cpp/variant/array.hpp>
#include <godot_cpp/variant/dictionary.hpp>
#include <godot_cpp/variant/vector2i.hpp>

using namespace godot;

#include "terrain_bond.h"

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
/// THE PATTERN LIBRARY (Docs/HandoffBrickPatterns.md, TerrainRegions.md 13):
/// the game's fitted bricks. At world set-up the fitter fills SOLID 16 x 16
/// regions (one layer of 3 courses) with the world's shares, `pattern_count`
/// of them a depth band and layer parity. A cell's brick is the brick over
/// it in the pattern its region (square of its course, odd courses shifted,
/// as the fit's) picks by hash: no generated cells read, nothing cached but
/// the library. Where the ground cuts a pattern brick (cave air, a hole, an
/// edit, the top course, sand), that brick ALONE is split, course by course,
/// into the largest listed shapes its remaining bond cells hold -- from its
/// own cells only, so every cell of it names the same piece.
struct PatternLib;
class PatternView {
public:
    PatternView();   ///< the world's library (none while the fit is off)
    explicit PatternView(std::shared_ptr<const PatternLib> lib);
    ~PatternView();
    PatternView(const PatternView &) = delete;
    PatternView &operator=(const PatternView &) = delete;
    bool on() const { return (bool)lib_; }
    /// The pattern's whole brick over (x, course, z), as laid in solid
    /// ground. False without a library.
    bool brick(int x, int course, int z, FitBrick &out);
    /// The brick of bond cell (x, course, z) as the ground has it:
    /// `group(x, course, z)` gives a cell's BondGroup (MEDIUM / STRONG bond;
    /// anything else cuts). `out.c` / `out.h` always set.
    template <typename G>
    bool rect(int x, int course, int z, const G &group, BondRect &out);
    /// The column's top course for the depth bands (default: the generator's).
    void set_top(std::function<int(int, int)> top) { top_ = std::move(top); }
    /// The pieces of cut brick `b` (cells' groups `g`, course, then z, then
    /// x) added to `out`; true (nothing added) when it stands whole. A cut
    /// brick may have no pieces at all (no bond cell left in it).
    bool split(const FitBrick &b, const uint8_t *g, std::vector<BondRect> &out) const;

private:
    std::shared_ptr<const PatternLib> lib_;
    std::function<int(int, int)> top_;
    std::unordered_map<int64_t, int> band_;   ///< region column -> its generated top course
    int64_t band_key_ = INT64_MIN;            ///< the last region column asked, and its top
    int band_top_ = 0;
    /// Each brick asked: its pieces in `pieces_` (n -1: whole). Open
    /// addressing, no allocation a brick (a tile's mesh asks thousands).
    struct Slot {
        int64_t key = INT64_MIN;
        int32_t first = 0, n = 0;
    };
    std::vector<Slot> slots_;
    size_t used_ = 0;
    std::vector<BondRect> pieces_;
    const Slot *last_ = nullptr;
    Slot &slot(int64_t key);
};

template <typename G>
bool PatternView::rect(int x, int course, int z, const G &group, BondRect &out) {
    FitBrick b;
    if (!brick(x, course, z, b)) {
        return false;
    }
    const int64_t k = bond_key(b.x, b.c, b.z);
    const Slot *sl = last_;
    if (!sl || sl->key != k) {
        Slot &ns = slot(k);
        if (ns.key != k) {
            uint8_t g[3 * 8 * 8];
            int i = 0;
            for (int cc = b.c; cc < b.c + b.h; ++cc)
                for (int zz = b.z; zz < b.z + b.sz; ++zz)
                    for (int xx = b.x; xx < b.x + b.sx; ++xx) g[i++] = (uint8_t)group(xx, cc, zz);
            const size_t first = pieces_.size();
            const bool whole = split(b, g, pieces_);
            ns.key = k;
            ns.first = (int32_t)first;
            ns.n = whole ? -1 : (int32_t)(pieces_.size() - first);
        }
        sl = &ns;
        last_ = sl;
    }
    if (sl->n < 0) {
        out = BondRect{ b.x, b.z, b.sx, b.sz, b.c, b.h };
        return true;
    }
    for (int32_t j = sl->first; j < sl->first + sl->n; ++j) {
        const BondRect &r = pieces_[(size_t)j];
        if (x >= r.x && x < r.x + r.sx && z >= r.z && z < r.z + r.sz && course >= r.c && course < r.c + r.h) {
            out = r;
            return true;
        }
    }
    out = BondRect{ x, z, 1, 1, course, 1 };   // not a bond cell: its own
    return true;
}

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
/// The top course cut from the fit too (the world's "fit_top"; deferred,
/// off: the old pattern's top course over the fitted ground).
bool fit_top_enabled();

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
    /// What configure's calibration did: calibration_ms, calibration_error.
    static Dictionary get_calibration();
    /// The pattern library's whole brick over a cell, for scripts:
    /// {x, z, c, sx, sz, h, mat}, or empty (the fit off).
    static Dictionary brick_at(int x, int course, int z);
    /// The game's ground bricks from the fit (off: the old pattern). Every
    /// tile is drawn again.
    static void set_enabled(bool on);
    /// generated_cells made fresh against the kept tile and sections.
    static Dictionary check_generated(Vector2i tile, int y_lo, int y_hi);
    static bool get_enabled();
};
