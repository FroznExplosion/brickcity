#pragma once

#include "brick_terrain.h"

#include <climits>
#include <cstdint>

/// THE GROUND'S BOND (Docs/TerrainBond.md): which brick a ground cell below
/// the top course is in. One stateless rule from absolute coordinates, asked
/// by the mesher (mask_faces: seams are brick edges), by breaking (find_brick,
/// find_bricks: the whole brick goes) and by the collapse survey (its virtual
/// bricks). Before it, the three disagreed: walls were drawn with a random
/// seam lattice, broken one 1x1 cell at a time, and held by a bond each survey
/// worked out afresh.
///
/// A cell is one stud by one course (3 plates). Its GROUP decides how it
/// bonds; the caller says what group a cell is in (0 for anything that is not
/// a bond cell: air, the top course's pieces, outside what it can see).
namespace brick {

enum BondGroup : int {
    BOND_NONE = 0,     ///< air, or not the bond's (a top piece, unknown)
    BOND_LOOSE = 1,    ///< sand, red sand, gravel: 1x1, joined only up and down
    BOND_MEDIUM = 2,   ///< dirt and grass and their kin: 2x2 at most
    BOND_STRONG = 3,   ///< rock and the rest: 2x4 where all eight are rock
    BOND_PILLAR = 4,   ///< the collapse's ring fill: 1x1, held
};

/// The group of a material (TerrainCollapse::material_class is this).
inline int bond_group(int m) {
    switch (m) {
        case MAT_AIR:
            return BOND_NONE;
        case MAT_SAND:
        case MAT_RED_SAND:
        case MAT_GRAVEL:
            return BOND_LOOSE;
        case MAT_GRASS:
        case MAT_DIRT:
        case MAT_SNOW:
        case MAT_CLAY:
        case MAT_PODZOL:
        case MAT_DRY_GRASS:
        case MAT_LUSH_GRASS:
        case MAT_COLD_GRASS:
        case MAT_DARK_GRASS:
            return BOND_MEDIUM;
        default:
            return BOND_STRONG;
    }
}

struct BondRect {
    int x = 0, z = 0;     ///< min corner, studs (absolute)
    int sx = 1, sz = 1;   ///< size, studs
    /// Its bottom course and courses tall (a fitted brick, terrain_fit.h,
    /// may be 2 or 3 tall; the old pattern's are 1). INT_MIN: the course
    /// asked about (bond_rect leaves it to the caller).
    int c = INT_MIN, h = 1;
};

/// A brick's identity: its corner and its course. Unique per brick.
inline int64_t bond_key(int x, int course, int z) {
    return ((int64_t)(x & 0x1FFFFF) << 42) | ((int64_t)(course & 0x1FFFFF) << 21)
            | (int64_t)(z & 0x1FFFFF);
}

inline int bond_fdiv(int a, int b) {
    return a >= 0 ? a / b : -((-a + b - 1) / b);
}

inline uint32_t bond_hash(int a, int b, int c) {
    uint32_t h = (uint32_t)a * 0x8da6b343U ^ (uint32_t)b * 0xd8163841U ^ (uint32_t)c * 0xcb1ab31fU;
    h ^= h >> 16;
    h *= 0x7feb352dU;
    h ^= h >> 15;
    h *= 0x846ca68bU;
    h ^= h >> 16;
    return h;
}

/// The brick of cell (x, course, z). `group(x, z)` gives the group of a cell
/// in THIS course (absolute studs); the cell asked about must be a bond cell.
///
/// A course is laid in 4 x 4 blocks, each two 4 x 2 footprints, both along X
/// or both along Z by a hash (so a floor runs both ways, as the packer's
/// ground always did), each row of blocks shifted 0 or 2 studs by another.
/// Every seam of course c -- block edges, the split between a block's two
/// footprints, a footprint's halves -- is on a stud line of c's parity, in X
/// and in Z; the next course's are all on the other parity. So a full brick
/// never stands with a seam right over a seam (the collapse's first fixed
/// bond did, wherever a shape did not line up with it, and a 2-course arm
/// came apart), whatever the shape round it.
///
/// Clipped where the ground is not: a 2x4 only when all eight cells are
/// STRONG; else its two 2x2 halves; a half not whole is its full 2-wide
/// columns, then single rows. Every cell of a footprint works the same split,
/// so every cell of a brick names the same rectangle.
template <typename G>
BondRect bond_rect(int x, int course, int z, const G &group) {
    const int g0 = group(x, z);
    if (g0 != BOND_MEDIUM && g0 != BOND_STRONG) {
        return BondRect{ x, z, 1, 1 };
    }
    const int p = course & 1;
    const int row = bond_fdiv(z - p, 4);
    const int bz = row * 4 + p;
    const int ox = p + 2 * (int)(bond_hash(row, course, 0x51) & 1U);
    const int bx = bond_fdiv(x - ox, 4) * 4 + ox;
    const bool along_x = (bond_hash(bx, bz, course) & 1U) != 0;
    int fx, fz, qu, qv;
    if (along_x) {
        fx = bx;
        fz = bz + (z - bz >= 2 ? 2 : 0);
        qu = x - fx;
        qv = z - fz;
    } else {
        fz = bz;
        fx = bx + (x - bx >= 2 ? 2 : 0);
        qu = z - fz;
        qv = x - fx;
    }
    // The footprint's cells, u along its length, v across.
    bool valid[4][2];
    bool all_valid = true, all_strong = true;
    for (int u = 0; u < 4; ++u) {
        for (int v = 0; v < 2; ++v) {
            const int cx = along_x ? fx + u : fx + v;
            const int cz = along_x ? fz + v : fz + u;
            const int g = group(cx, cz);
            valid[u][v] = g == BOND_MEDIUM || g == BOND_STRONG;
            all_valid = all_valid && valid[u][v];
            all_strong = all_strong && g == BOND_STRONG;
        }
    }
    int u0, v0, ul, vl;
    if (all_valid && all_strong) {
        u0 = 0; v0 = 0; ul = 4; vl = 2;
    } else {
        const int h0 = (qu / 2) * 2;
        const bool full0 = valid[h0][0] && valid[h0][1];
        const bool full1 = valid[h0 + 1][0] && valid[h0 + 1][1];
        const bool full_q = (qu == h0) ? full0 : full1;
        if (full0 && full1) {
            u0 = h0; v0 = 0; ul = 2; vl = 2;
        } else if (full_q) {
            u0 = qu; v0 = 0; ul = 1; vl = 2;
        } else {
            // The query's column is not full: a row run of cells whose
            // columns are not full either.
            const int other = (qu == h0) ? h0 + 1 : h0;
            const bool full_other = (qu == h0) ? full1 : full0;
            if (valid[other][qv] && !full_other) {
                u0 = h0; v0 = qv; ul = 2; vl = 1;
            } else {
                u0 = qu; v0 = qv; ul = 1; vl = 1;
            }
        }
    }
    if (along_x) {
        return BondRect{ fx + u0, fz + v0, ul, vl };
    }
    return BondRect{ fx + v0, fz + u0, vl, ul };
}

} // namespace brick
