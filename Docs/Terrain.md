# Terrain and studs

Design note. Answers [Plan.md](Plan.md) §8 question 5 ("Terrain. Spec §4 says heightfield +
Terrain3D. Untouched until M6") and revises [spec §4](printed-brick-city-spec.md) where the
arithmetic disagrees with it.

**Slice 1 is built** — see §16 for what exists, what it measured, and what the captures caught
that this note did not. The CITY still sits on a `PlaneMesh` and a `WorldBoundaryShape3D`
(`city_scene.gd` `_build_scenery`); terrain lives in its own scene until streaming lands.

Three proposals were on the table:

1. Heightfield terrain, with studs on flat cells and none on curves.
2. **Only bricks** — no heightfield — for the brick-film look.
3. A **voxel world in the Minecraft shape**: a fixed set of brick types in a 3D grid, with studs
   on exposed tops, smooth/slope pieces auto-placed on the surface, and scattered grass and rock
   parts on top of that.

(3) wins, and (1) survives inside it as the far LOD. The reasoning is §1–§3. Nothing about the
stud system (§7) changes between them, which is why the stud work can start before the terrain
representation is settled.

---

## 1. The arithmetic

5000 buildings at 13 m spacing is a 71 × 71 block, about **920 m square**. Call the world 1 km².
At 0.35 m stud pitch that is **8.16 million stud columns** (1/0.35² = 8.16 per m²).

*Paper arithmetic, not measured. The measured figures it leans on are M3/M4's, quoted from
Plan.md.*

| Representation | Cost for 1 km² | Verdict |
|---|---|---|
| **1×1 plates as real `Block`s** | 8.16M × 16 B = **131 MB** of block data, before occupancy, and that is one plate deep | Dead |
| **`Chunk`s over the whole ground** | `Chunk::occupancy` is `int32` **per cell**. A 32×32×32 chunk is 131 KB and covers 125 m². 8000 of them = **1.05 GB** | Dead. Same trap Plan §4.1 found in buildings |
| **Heightmap, quantised** | `uint16` height + `uint8` colour per stud column = **24.5 MB, resident forever** | Cheapest. Cannot hold a cave |
| **Palettised voxel sections** | §2 | **~18 MB streamed + the 24.5 MB heightmap as far LOD** |

The second row is the important one and it is worth being precise about: **"voxel terrain is too
expensive" is only true of `Chunk`'s storage, not of voxels.** `Chunk` spends 4 bytes a cell
because it is built for a damaged building — a few thousand cells that each need a block id.
Minecraft spends about a quarter of a byte, and the difference is entirely representation.

---

## 2. What a palettised section actually costs

Minecraft's storage is a **palette plus a packed bit array, per section, with a uniform-section
short circuit**. Applied to our grid:

| | |
|---|---|
| Terrain voxel | 1 stud × **1 brick** × 1 stud = 0.35 × 0.42 × 0.35 m (§4 argues for brick, not plate) |
| Section | 32 × 16 × 32 voxels = 16,384, covering 11.2 × 6.72 × 11.2 m — same XZ footprint as a chunk and a tile |
| Palette | ≤ 4 materials in a typical terrain section → **2 bits a voxel** = 4 KB, plus the palette itself |
| Uniform section | all air, or all stone: **2 bytes** |
| Non-uniform sections per tile column | ~2 (the surface, and the one under it). Everything above is air, everything below is rock |

1 km² is 90 × 90 = 8100 tile columns. Resident only within the 300 m streaming radius —
π·300²/125 m² = **2261 tiles × 2 sections × 4 KB = 18 MB**.

Outside that radius a tile keeps only its **derived heightmap** — the surface profile, 3 KB — and
its voxels come off disk on approach. That heightmap is not a fallback bolted on; **it is the same
24.5 MB structure §1 costed, and it is what LOD 2 and LOD 3 draw.**

Minecraft does exactly this split, and for the same reason: it keeps per-chunk heightmaps because
scanning sections to find the surface is expensive, and the surface is what almost every query
wants.

**Total: ~42 MB for a square kilometre of diggable, cave-bearing brick ground.**

---

## 3. What the voxels buy, and what they cost

| | Heightmap terraces | Palettised voxels |
|---|---|---|
| Storage, 1 km² | 24.5 MB | 42 MB |
| Overhangs, caves, arches, bridges | no | yes |
| Digging and tunnelling | no | yes |
| A crater that undercuts | must be flattened to a bowl — this was §11's worst open question | just works |
| Collision | one `HeightMapShape3D` a tile | merged boxes, ~100 a tile (§9) |
| Damage | build blocks from heights on first hit, then throw them away | **the terrain already is a chunk.** `apply_hit` runs on it unchanged |
| New C++ | a quadtree mesher | palettised section storage + a greedy mesher |

The row that decides it is **Damage**. With a heightmap, terrain destruction is a special case:
materialise, hit, lower the heights, de-materialise, and hope the crater was heightfield-shaped.
With voxels there is no special case — the ground is made of the same thing buildings are made of,
and every gate that already passes for a building passes for the ground.

The collision row used to be the objection. It is not one any more: **`add_merged_shapes`
(`brick_world.cpp:1155`) already greedy-merges a chunk's live cells into boxes**, and
`add_chunk_shapes(..., merge)` is bound to GDScript. A flat tile merges to one box; a rough one to
a hundred. Static, built once, no solver cost.

**Recommendation: voxels near, heightmap far.** Not a compromise — the split is what makes both
affordable.

---

## 4. Why the voxel is a brick tall, not a plate

A plate-tall voxel (0.14 m) is three times the data for a step nobody reads at ground scale. A
brick-tall voxel (0.42 m) is the right granularity for a hillside.

But 0.42 m against a 1.68 m player (D6: four bricks) is proportionally a 0.75 m step for a human.
Nobody walks up that.

**The user's own §6 answers it:** the top layer is not a cube. It auto-places slopes, so a 0.42 m
rise is a ramp, not a wall. The step problem and the "smooth top pieces" idea are the same idea,
and taking both makes the brick-tall voxel correct.

Everything stays on the integer lattice — a terrain voxel is a `Vector3i` size of `(1, 3, 1)`,
which is just the standard brick archetype. D5 and D6 are untouched.

---

## 5. Materials are a small fixed set

That is the part of the Minecraft shape that transfers best. A handful of terrain materials, each
one a **colour byte and a set of behaviours**, not a texture:

| | |
|---|---|
| Palette | grass, dirt, sand, stone, dark stone, gravel, clay, road, plus air |
| Per material | filament colour, does it take studs, does it take scatter, which scatter parts, crumble behaviour |
| Storage | the palette index in the section's bit array. Nothing per voxel beyond that |

---

## 6. The surface layer: slopes, piece variety and odd shapes

The voxel field says *where* the ground is. This section is about *what pieces it is built from*,
which is a separate decision and is where almost all of the look lives.

### 6.1 Auto-tiling: slopes, corners, smooth tops

The surface piece is chosen from the **8 neighbours in XZ plus the voxel above**, the way an
auto-tiling terrain does. That is a lookup table, evaluated at mesh time, not stored.

| Neighbourhood | Piece |
|---|---|
| Flat, all four sides level | **plate** — studs up |
| One side one step down | **slope 1×1** facing that side |
| Two adjacent sides down | **outer corner slope** |
| Two opposite sides down | a ridge — plate, or a **roof piece** |
| Three sides down | **pyramid / stud cap** |
| Cell is on the edge of a terrace | **tile** — smooth top, no stud (§7.1) |

These are archetypes, and the machinery is already there: `bake_shaped_archetype` and
`bake_faced_archetype` exist, `Archetype` carries an occupancy mask plus per-column `up_face`, and
M2b's note is explicit that "nothing downstream assumes a box". A slope with `FACE_NONE` on top is
a slope nothing clips to, and `mates()` enforces that with no new code.

Two consequences worth naming:

- **Walkability.** A ramp is what makes a brick-tall voxel acceptable (§4). Slopes are not
  decoration here; they are the reason the grid size works.
- **Open question 3 in the spec closes.** Spec §12 asks "terrain slopes: smooth only, or
  stepped/slope bricks in some biomes?" The answer is stepped voxels with slope pieces on top,
  everywhere, because that is also the cheapest thing that is walkable.

### 6.2 Piece variety: largest first, then medium, then fill

A greedy mesher produces **maximal rectangles**, which is the wrong answer
visually: a flat field becomes one enormous quad with a procedural plate grid
drawn on it, and reads as a single moulded baseplate. Real brick ground is
*laid* — a mix of 1×1, 1×2, 1×3, 1×4, 1×6, 2×2, 2×3, 2×4, 2×6, with staggered
joints and courses running both ways.

**The packer walks a size ladder, biggest first.** Each pass places wherever it
still fits; the next pass takes the gaps the last one left; the last pass fills
what is over with 1×1s. Both orientations of every non-square size are
candidates, chosen per cell by hash, which is what puts horizontal and vertical
courses next to each other instead of giving each tile a grain.

`chance` on a rung is a hashed skip, so the big sizes do not carpet the ground
in a regular grid. **It has to be divided by the piece's area to read as a
share** — 2×6 at 0.22 measured *43%* of the ground and pushed 2×4 down to 25%.
At 0.05 it sits at 20% and 2×4 takes half.

**Measured**, `brick_terrain.cpp` against `tools/terrain_probe.gd`, 25 tiles of
the test field:

| 2×4 | 2×6 | 1×4 | 1×2 | 2×3 | 1×1 | 1×3 | 2×2 |
|---|---|---|---|---|---|---|---|
| **50%** | 20% | 7% | 7% | 6% | 4% | 3% | 3% |

| | |
|---|---|
| Mean brick | **5.0 studs** over 4,013 bricks |
| 4-long pieces | **57%** of brick area |
| Orientation balance | 1,365 wide against 1,661 tall — **0.82**, so courses genuinely run both ways |
| Surface by area | brick 78%, tile 15%, ramp 7% |
| A 32×32 tile | 259 pieces, 614 triangles, 901 studs, 72 collision boxes, **0.59 ms** |
| 25 tiles (56 m square) | 8,204 pieces, 20,300 triangles, 19,990 studs |

Extrapolated from 614 tris a tile: **90 tiles inside 60 m is 55k triangles**,
and using it to 300 m would be 1.4M — so it stays a near-field tier and §6.4
still has to answer the handover.

**Three kinds of piece, and the packer runs twice.** A flat plate cell becomes
a `PIECE_BRICK` and takes studs. A flat cell that is *not* a plate — a terrace
lip, a corner — becomes a `PIECE_TILE`: packed the same way, up the same
ladder, but smooth and studless, which is what a tile is for. Ramps are placed
first and are always 1×1, because a tilted top cannot be shared by a longer
piece.

### 6.3 The packer has to be stateless, or streaming breaks it

A scanline packer that walks left to right accumulating state gives a different answer depending
on where it started, which means a piece changes shape when you approach a tile from the other
side. Unacceptable.

**Cut points are a hash, not a walk.** On row `z`, a piece boundary exists at global `x` iff:

```
forced   if material[x] != material[x-1]            // pieces never span two materials
forced   if height[x]   != height[x-1]              // a piece is flat by definition
forced   if the auto-tiled piece here is not a PLATE  // §6.1 owns slopes and corners; they are 1x1
forced   if run_length_since_last_cut == MAX_LEN     // 6
suppressed if run_length_since_last_cut < MIN_LEN    // 1, or 2 for a bonded look
otherwise  hash(x + row_offset(z), z, world_seed) < p
```

Finding the piece that contains a cell needs a scan of at most `MAX_LEN` cells either side, so it
is **O(1), order-independent and tile-independent**. Pieces cross tile boundaries correctly
without a tile ever knowing about its neighbour, which is the property that makes streaming safe.

- **Staggered joints** come from `row_offset(z)`, a hash of the row. Free.
- **Two-deep pieces** (2×N) come from pairing rows by `floor(z/2)` and generating the pair's cuts
  jointly, so both rows agree on where the piece ends. A hash per pair decides whether it bonds
  into 2×N or stays as two 1×N rows.

This is the same class of function as the §8 scatter hash and belongs in the same named place on
`BrickWorld`, for the same auditability reason D9 gives about `randf()`.

### 6.4 Near and far draw the same tessellation

The 60 m handover must not change the pattern, or the ground visibly re-lays itself as you walk.

`brick.gdshader`'s existing contract is exactly what is needed — *"UV = position within the
block's face rectangle, in metres; UV2 = that rectangle's size"* — so the far tier emits **one
merged quad** and supplies per-cell UV/UV2 from a small **piece-index texture** baked with the
tile: each stud cell stores its offset within its piece and its piece's size. Offsets and sizes
are ≤ 6, so three bits each packs into **2 bytes a cell — 2 KB a tile, 4.3 MB across the 60–300 m
band.**

The shader is then drawing the identical tessellation the near tier built out of real quads, and
the handover is invisible.

| Far-tier option | Cost | Pop |
|---|---|---|
| **Piece-index texture** | 4.3 MB, one extra sampler | none — same tessellation |
| Coarser packing (mean area 16) | 2171 tiles × 128 = 278k tris | mild; both tiers still read as varied brick |
| Greedy merge + plain 1×1 seam grid | ~2 tris a tile | **visible** — the pattern changes from laid brick to uniform plates |

Recommendation: the texture, with coarser packing as the fallback if the extra sampler is
awkward. The third option is what the previous draft of this document assumed and it is the one
that pops.

### 6.5 Debris is real bricks, because the packer runs before `place_block`

The packing is not only presentation. When a tile materialises into a real `Chunk`, the packer
chooses which **archetypes** to place, so `Chunk::blocks` holds actual 2×4 plates and
`occupancy` maps every cell to them — which `Chunk` already supports and `place_block` already
does.

The payoff: blowing a hole in the ground throws **recognisable bricks**, not a cloud of 1×1s.

It works only because §6.3 made the packer stateless. A hit forces cuts at the dead cells, and
because a cut's influence is bounded by `MAX_LEN`, re-packing disturbs **at most six cells either
side of the hole** and leaves the rest of the tile byte-identical. A stateful packer would re-lay
the entire tile every time something was shot at it.

### 6.6 Odd-shaped features come from three places, and they layer

| Mechanism | Gives | Cost |
|---|---|---|
| **The voxel field** | overhangs, arches, natural bridges, caves, spires, undercut cliffs — anything expressible on the grid. This is the thing a heightmap could not do at all | the generator's noise and carving; no storage beyond §2 |
| **The auto-tile layer** (§6.1) | slopes, corners, curved and rounded surface pieces, so the field reads as *shaped* rather than blocky | a lookup table |
| **Prefab features** | genuinely odd shapes: boulders, rock arches, mushroom rocks, crystal clusters, ruins, trees. Authored, not derived | a 16×16×16 stamp at 2 bits is **1 KB**; fifty of them is 50 KB |

A prefab is stamped into the section at hashed positions, so it is **just voxels afterwards** —
destructible, packable, meshable, with no special case anywhere. Minecraft calls these
"structures" and the word fits.

A prefab may also carry an **explicit piece list** that overrides the packer for cells it covers.
That is the escape hatch for a shape where the exact bricks matter — a curved arch keystone, a
sculpted outcrop — and it means "the packer decides" is a default, not a constraint.

What none of this gives is **sub-grid curves**, and it should not: spec §2's whole art direction
is brick-toy, so a smooth organic rock face would be the off-style thing. Curves come from
*parts*, the way they do in a real model.

---

## 7. Studs

The shared system. M5's stud layer on bricks, terrain studs and water studs are one
implementation. **This section is unchanged whether terrain is voxels or a heightmap** — the only
difference is where `stud_at` reads from.

### 7.1 The rule: flat gets a stud, curved gets a tile

```
stud_at(cell) :=
      the voxel above is air                       // it is a surface
  AND the auto-tiled piece here is a PLATE         // §6: not a slope, not a corner
  AND material_takes_studs(palette[cell])          // grass yes, road no
```

With voxels this is an **integer test on the neighbourhood**, not a normal threshold. No tuning
constant, no half-studs melting into hills (spec §4's actual words), and a slope gets *none*
rather than *some*, because a slope is not a plate.

The outermost ring of a terrace auto-tiles to a slope or a tile, so it loses its studs for free.
That is what a real brick terrace edge looks like, so the rule pays twice.

### 7.2 Three tiers, and the cheapest one is the default

Paper arithmetic. A game-scale stud is 0.21 m across and 0.074 m tall (spec §3's 4.8 mm on 8 mm
pitch at 1:43.75). An 8-sided tapered stud with a fan cap and no bottom is **22 triangles**. At
1080p / 70° FOV it is 28 px across at 10 m, 9 px at 30 m, 4.6 px at 60 m — and a 22-triangle mesh
at 9 px is deep in the quad-overdraw penalty, shading more pixels than it covers.

| Tier | Range | How | Cost | Silhouette |
|---|---|---|---|---|
| **0** | 0–18 m | **static per-tile `MultiMesh`**, baked with the tile mesh, `cast_shadow = OFF`, `visibility_range_*` with fade | π·18²·8.16 = **8.3k instances, 183k tris**, one draw call a tile | real |
| **1** | 18–60 m | **shader studs** — a dome normal inside each stud cell, in a fragment shader already running | **~15 ALU**, no geometry, no memory | none |
| **2** | 60 m+ | nothing; the seam grid alone carries the brick read | 0 | none |

**Tier 1 is the answer to "the cheapest way to add studs."** A handful of instructions bolted onto
a fragment the ground already pays for. Tier 0 exists only because the silhouette against the sky
matters when you are standing on it.

The tiers overlap in an 18–24 m band, tier 0 fading by `visibility_range_fade_mode` while the
shader term fades in on the same curve. Same cells, same `stud_at`, so there is nothing to pop.

Terrain studs are **static**, which is the important difference from water: the `MultiMesh` is
built once with the tile and Godot's visibility range does the LOD. A camera-following ring would
cost a ~640 KB buffer upload every time the camera moved a third of a metre.

### 7.3 Colour: matching what they sit on

- **Tier 0**: `MultiMesh.use_colors = true`, per-instance colour written at bake from the voxel's
  palette entry. On buildings, from the block's colour byte. Bake-time lookup, no runtime cost.
- **Tier 1**: the fragment already holds the surface albedo. The dome is a normal perturbation,
  not a separate colour, so it *cannot* mismatch.

### 7.4 Shadows: faked, permanently, and here is the number

Real casting from tier 0 is 8.3k instances × 22 tris through ~2 shadow cascades = **~365k
depth-only triangles a frame**, for a shadow cast by a 0.074 m bump — about 0.07 m long with the
sun at 45°. That is most of a Steam Deck's budget (D2) for something a few pixels wide.

**Studs never cast. The surface draws their shadows**, in the same fragment, on the cell maths
tier 1 already does:

```
// sun_dir points from surface to light, a uniform fed from the DirectionalLight3D
vec2  d = -sun_dir.xz / max(sun_dir.y, 0.2) * STUD_H;   // where the stud top's shadow lands
vec2  c = (floor(p.xz / STUD) + 0.5) * STUD;            // this cell's stud centre
float t = dist_to_segment(p.xz, c, c + d);              // a stadium: the swept disc
albedo *= mix(1.0, contact_darken, 1.0 - smoothstep(r, r + fwidth(t), t));
```

Two taps — this cell and the cell one step along `-d` — cover the sun down to ~15° above the
horizon. `|d|` is clamped to one cell so low sun never needs more, and the error at sunset hides
inside the building shadows that dominate the frame.

Correct as the sun moves, free per stud, and **identical under tier 1 where no stud geometry
exists.** The fake is not compensating for missing geometry; it is the better way even where the
geometry is there. Studs still *receive* the world shadow map, which is free and is what makes
studs under a building go dark.

### 7.5 No collision, ever

D4, restated for terrain. The collision surface is the **plate top**, so a character stands
0.074 m into the studs. The alternatives are an invisible lip at every terrace or 8.16M collision
primitives.

### 7.6 The stud mask is the build mask

A cell with a stud accepts a brick; a cell without one does not. `mates()` in `brick_types.h`
already says so — `FACE_STUD` meets `FACE_SOCKET`, `FACE_NONE` meets nothing — so "you cannot
build on a slope" is not a rule anyone writes. It is the existing connectivity test reading a
terrain voxel's up-face. Build mode gets it for nothing.

---

## 8. Scatter: grass, rocks and the things on top

Small brick parts standing on the surface — tufts, pebbles, plants, debris. Same machinery as tier
0 studs, one `MultiMesh` per scatter type per tile, baked with the tile.

| | |
|---|---|
| Density | ~1 per 16 stud cells (about one per 2 m²), per material |
| Range | 30 m, `visibility_range` with fade |
| Instances | π·30²·8.16/16 = **1.4k a type**; three types ≈ 4.3k |
| Cost | ~30 tris a part → **~130k triangles**, three draw calls a tile |
| Shadows | off, same argument as §7.4 |

**Placement is a stateless hash, not the RNG.** `hash(cell_x, cell_z, world_seed)` picks whether a
cell scatters, which part, which of the eight grid-legal yaws, and the colour jitter. This is
stronger than D9 asks for rather than weaker: a hash needs no state, is independent of streaming
order, and gives the same world whether a tile loads first or last — which `BrickWorld.rng` alone
could not guarantee once tiles stream. It should be a named function on `BrickWorld` so it is as
auditable as the RNG is.

Scatter is **presentation only**: no collision, no connectivity, no stress, destroyed without
being simulated. Same call [BuildMode §9.2](BuildMode.md) made for decorative fixtures, and
[Interiors §1](Interiors.md) for room contents. Third time — it should be one shared tier, not a
third implementation.

---

## 9. Textures: no, and here is what to do instead

"Apply a texture to the bricks" is the one part of the Minecraft shape that does not transfer.
Spec §2 is explicit — *flat filament colours, no textures, very low memory* — and it is a pillar,
not an optimisation: the world is meant to read as printed plastic, and printed plastic has no
grain.

What textures are actually doing in Minecraft is making a large flat field of one material
**readable**. Three things already in the project do that for nothing:

| | |
|---|---|
| **The seam grid** | `brick.gdshader` wraps `UV` by `UV2`, so a merged quad of any size draws a 1×1 plate grid across itself with no extra geometry (`building_shell.gd` `SEAM_UNIT` is the same trick). Set `UV2 = (0.35, 0.35)` and a 32-stud merged quad reads as a baseplate |
| **Per-cell colour jitter** | ±4% value from the §8 hash. ~3 ALU. This is what stops a grass field being one flat slab of green, and it is what a real print of many parts looks like |
| **Scatter** | material identity comes from the tufts and pebbles standing on it (§8), which is also how the eye reads real ground |

If a material genuinely needs a pattern — a road marking, a manhole — that is a **part**, modelled
and printable, not a texel. Spec §10's pipeline already produces those, and a texture would be the
one thing in the world that cannot be printed.

---

## 10. Collision

| State | Shape |
|---|---|
| Resident voxel tile | `add_chunk_shapes(body, tile_chunk, offset, true, /*merge*/ true)` — the greedy merge at `brick_world.cpp:1155`. A flat tile is one box; a rough one ~100. Static, built once |
| Streamed-out tile | one `HeightMapShape3D` from the derived heightmap. Cheap, Jolt-native, and exact wherever there is no overhang |
| Damaged | nothing changes. It was already a chunk; `body_set_shape_disabled` is the whole operation |

Paper: 2261 tiles within 300 m × ~100 boxes = ~226k static boxes. Static, so no solver cost and no
per-frame work; the cost is broadphase build, paid once a tile. No `ConcavePolygonShape3D`
anywhere, per Plan §3.

---

## 11. Digging, craters and damage

There is nothing to design. The terrain is a chunk.

1. A hit lands. `apply_hit(tile_chunk, point, radius)` runs, exactly as it does on a building.
2. Dead voxels go. `find_detached_groups` finds anything that came loose — **an undercut ledge now
   actually falls**, which a heightmap could never express.
3. The surface auto-tiles again around the hole (§6), so a crater gets slope pieces on its rim for
   free and reads as a bowl of brick rather than a cube hole.
4. The **damage record is the section's bit array**, diffed against the generator's output. An
   undamaged section stores nothing.

Gate **G1b** — the cheap representation must show the damage — needs the derived heightmap updated
when voxels die, which is a max-scan of the affected columns. For an overhang removed from
underneath the heightmap is simply wrong, and that is acceptable: it is the 300 m+ tier, and the
silhouette from there is a hill either way.

---

## 12. Streaming and LOD

| Tier | Range | Draws | Data | Collision |
|---|---|---|---|---|
| **0** | < 18 m | greedy voxel mesh + stud `MultiMesh` + scatter | sections | merged boxes |
| **1** | 18–60 m | greedy voxel mesh + shader studs | sections | merged boxes |
| **2** | 60–300 m | greedy voxel mesh, no studs, no scatter | sections | merged boxes |
| **3** | > 300 m | terrace quadtree from the derived heightmap, quantised to 3 bricks | **heightmap only, 3 KB a tile** | none until needed |

The heightmap is resident for the whole city (24.5 MB) and sections stream against it, so tier 3 is
always available instantly and **gate G2 is close to trivial**: walking two tiles away and back
reloads a section whose contents are regenerable plus a diff.

30 m hysteresis on every threshold, for the reason Plan §4.2b gives.

---

## 13. What this does to Terrain3D

Spec §4 names Terrain3D. Under a voxel model it has nothing left to contribute: its clipmap is a
smooth continuous surface, its splatting is texture work §9 rejects, and its collision is
`HeightMapShape3D`, which is twenty lines and only used at tier 3.

**Terrain3D leaves the runtime entirely.** It may still earn a place as an authoring tool —
sculpt, export a heightmap, run the generator against it — but nothing ships with it. Spec §4
revision.

---

## 14. Order of work

| Step | Deliverable | Gate |
|---|---|---|
| **T0** | Palettised `TerrainSection` in C++ — 2-bit array, palette, uniform short circuit, derived heightmap | One section costs 4 KB; a uniform one costs 2 bytes |
| **T1** | Greedy mesher, flat colour through `brick.gdshader` with `UV2` = one stud | A flat tile is one quad and reads as a baseplate |
| **T2** | §6.1 auto-tiling: slopes, corners, tiles on the surface layer | A hillside is walkable; no 0.42 m walls |
| **T2b** | §6.2–6.4 **the packer**: hashed cut points, 1×N and 2×N pieces, staggered joints, hashed yaw, the piece-index texture for the far tier | A flat tile is ~256 pieces at ~512 tris; the pattern is identical either side of the 60 m handover; approaching a tile from any direction lays the same bricks |
| **T3** | `add_chunk_shapes(..., merge)` collision; the walking capsule climbs a slope and cannot climb a cliff | Box count matches §10's ~100 a tile within 2× |
| **T4** | **Studs.** `stud_at`, tier 1 shader dome + faked contact shadow, tier 0 per-tile `MultiMesh`. This is M5 — do it here and buildings inherit it | Flat studded, slopes bare, no popping across 18–24 m |
| **T5** | Scatter and per-cell colour jitter, both off the stateless hash | Same world from any streaming order (**G6**-shaped) |
| **T6** | Tiling, streaming, the four LOD tiers, the derived-heightmap tier 3 | 42 MB for 1 km²; frame budget at the Deck floor |
| **T6b** | §6.6 prefab features — stamps, hashed placement, explicit piece lists | A rock arch stands, is made of nameable bricks, and blows up like a building |
| **T7** | Digging and craters — `apply_hit` on a terrain chunk, undercut ledges falling. §6.5: debris is real 2×4s, and re-packing disturbs ≤ 6 cells either side of the hole | **G1**, **G1b**, **G2** on ground |
| **T8** | Terrain voxels as a build surface — `mates()` against the terrain up-face | A brick on flat ground sits flush and is grounded; on a slope it is refused |

T4 comes before the city-scale tiling on purpose: studs are the likeliest thing to blow the
budget, and one tile is enough to find out.

**T0–T2 is the milestone that decides everything else.** If a palettised section plus a greedy
mesher does not land near 4 KB and near the tri counts above, the heightmap terrace model from the
previous draft of this document is still there and still works — it just cannot hold a cave.

---

## 15. Open questions

1. **Does the world generator exist yet?** Voxels need one — noise, biomes, material layering,
   cave carving — and it has to be a **pure deterministic generator with a version stamp**, for
   exactly the reason Plan §4.2 gives about recipes and mvs-c's `LAYOUT_VERSION`. A stale stamp
   must invalidate a saved diff rather than misapply it.
2. **Does terrain get a stress solve?** Today the ground *is* the foundation
   (`set_foundation_level`). Voxels make an undermined cliff physically expressible for the first
   time, which is a feature request, not a free consequence. Default: terrain stays anchored,
   `find_detached_groups` handles the ledge, no stress solve.
3. **How deep do sections go?** 8 m of real voxels under the surface covers craters and shallow
   digging. Deeper tunnelling means more non-uniform sections and the §2 budget grows linearly.
   Pick a depth and cap it.
4. **Tier 0 radius and scatter density** are from the pixel arithmetic in §7.2 and §8, not
   measured. Real numbers come from a frame capture with the walking body on studded ground.
4b. ~~**What is the piece mix?**~~ **Answered by building it.** Mostly 2×4s, as asked: 2×4 is 35%
   of the ground by area and the largest single share, mean piece 5.0 studs. The table is
   `PARTITIONS` in `brick_terrain.cpp` and the measured breakdown is in §6.2. `shots/terrain_packing.png`
   is the top-down capture that settles whether it reads as laid brick — it does.
4c. **Does the packer need to know about buildings?** A building sits on the ground on the same
   grid. If the packer lays pieces under a building's footprint they are never seen, which is
   wasted geometry, and if it lays them *across* the footprint edge the seam will not line up with
   the building's own bricks. Cheapest fix is a forced cut at any footprint boundary, which is the
   same rule §6.3 already applies at a material change.
5. **Water on a voxel world.** [Water.md](Water.md) treats water as a surface, not as voxels, and
   [§3.4 there](Water.md) now has the arithmetic for why water pieces must move rather than be
   created and destroyed. The shoreline is where the two models meet and it is the only awkward
   seam.

---

## 16. What is built

Slice 1, 2026-09-20. `scenes/terrain_test.tscn`, `tools/terrain_probe.gd` (passes).

**In C++** (`gdextension/brick/src/brick_terrain.{h,cpp}`), per D1 — terrain truth is core, so
none of it was prototyped in GDScript: the value-noise generator, plate/ramp classification, the
size-ladder packer, the mesher, the stud and scatter instance buffers, the merged collision boxes,
and `BrickWave`. `build_tile` returns all of it in one crossing, with the instance buffers already
in `MultiMesh.set_buffer`'s layout so GDScript uploads them without a loop.

**In GDScript**: `terrain_tile.gd` (node assembly only), `water_surface.gd`, `terrain_scene.gd`,
`piece_meshes.gd`, and the two shaders.

Done: T0, T1, T2, **T2b**, T4, most of T5, W0–W3, plus the overlay course (§6 "a second
course") and multi-stud scatter that suppresses the studs it covers.
Not done: sections and streaming (T3, T6), prefabs (T6b), digging (T7), build surface (T8),
water tiers 1–3, buoyancy.

### What the captures and the probe caught that the design note did not

1. **Instanced pieces need a material that reads `COLOR`.** Without one, `use_colors` writes a
   buffer nothing samples and every stud renders white. §7.3's "a stud can never disagree with its
   brick" is a claim about a material, not only about a bake.
2. **Terrace faces have to merge along the piece.** Per-cell side quads gave each cell its own
   `UV2`, so the seam shader outlined all four and a 2×4 above a drop read as four 1×1 cubes.
3. **A ramp must not draw a wall on its low side.** The tilted top already reaches the
   neighbour's level, so the rectangular skirt sat exactly on the ramp surface and the coincident
   faces z-fought into dark wedges. The two perpendicular walls are trapezoids, not rectangles.
4. **The sea needs the seabed before anything else.** Without it the water drew straight through
   every hill. The fix is [Water §5](Water.md)'s absorption texture doing its second job.
5. **A hashed skip on a big piece buys area, not frequency.** §6.2.
6. **Collision must not be per piece.** A piece is a rendering decision; the collider only has to
   match the surface. One box a piece was 338 nodes a tile, 8,450 across the field, and the whole
   of an 813 ms scene build against 0.5 ms of C++. Greedy rectangles over equal collision height
   give **72 boxes a tile and a 146 ms build**. A ramp collides at half a brick, so the rise it
   exists to soften is soft to walk up and not only to look at.

7. **A second course changes the collision merge, and that is correct.** An overlay raises its
   piece by a plate, so the greedy merge can no longer run between a covered piece and a bare one:
   72 boxes a tile became 146. You stand on the tile, so the collider has to follow it.
8. **Scatter must run before studs.** A rock is placed, marks its footprint, and only then are
   studs emitted for what is left. The other order drew studs poking through boulders.
9. **A uniform instance scale scales HEIGHT too.** A 3-stud boulder came out 1.26 m tall on ground
   with 4 m of total relief. XZ and Y scale separately now; width grows by n, height by
   0.75 + 0.15n.
10. **Scatter has to use the filament palette.** A hand-mixed grey read as chalk-white beside
    ground that was using the palette properly. A boulder and a brick printed in the same colour
    have to *be* the same colour.

### Known, and deliberate for now

- **A piece is clipped at the tile boundary** instead of being owned by the tile holding its
  origin. Much less visible now that orientation is per cell rather than per tile, but a piece
  still cannot cross an 11.2 m line.
- **A ramp's collider is a box at half height, not a wedge.** `bake_shaped_archetype` is the real
  answer and exists; this is the cheap version.
- **Collision is still one `CollisionShape3D` node a box.** 72 a tile is affordable;
  `add_chunk_shapes(..., merge)` in C++ is where it ends up.

---

## 17. Volumetric terrain — the decision, and what it costs

**Decided 2026-09-20: terrain goes volumetric.** Destructible ground, digging and caves are
wanted, and §17.1's table is the reason a heightfield cannot deliver the last three rows at any
price. The heightfield does not disappear — it survives as the *derived* far LOD (§17.7), which
is the one thing the outside analysis was unambiguously right about.

This supersedes §2–§4's costings, which were written against a brick-tall voxel and are wrong for
the reason §17.3 gives.

### 17.1 What the switch buys

| | Heightfield (built today) | Volumetric |
|---|---|---|
| Blast crater, debris, a lasting scar | yes — lower the heights | yes |
| Overhang, arch, natural bridge | **no** | yes |
| Cave, tunnel, digging downward | **no** | yes |
| Undercut cliff that comes loose and falls | **no** | yes |
| Storage, 1 km² | 24.5 MB | **~79 MB** (§17.4) |

The last row of the "no" column is what made the decision easy: ground standing on nothing is the
only case where a heightfield is not merely less capable but actively *wrong*.

### 17.2 The system described is the one that already exists

The proposal was: the world is a grid, each grid square holds one brick, and a brick may span
several squares. **That is `Chunk`, unchanged.** `brick_types.h` already holds:

- `occupancy` — one `int32` a cell, `-1` for empty, else the id of the block occupying it
- `blocks[]` — each with a `cell` (min corner) and an archetype, so **a 2x4 occupies eight cells
  and is one block**
- connectivity by integer rectangle overlap plus a plate equality — no geometry, no sockets
- `apply_hit`, `find_detached_groups`, `solve_grounded`, `add_merged_shapes`

Terrain does not need a new system. It needs to *become* a chunk, which is what §3 already
claimed and what the heightfield implementation quietly never did.

**One constraint does not move: placement is on the integer lattice, never at an arbitrary
position.** "A brick can go anywhere" means anywhere on the stud/plate grid. D5 is what the whole
destruction stack rides on and it is not relaxed for terrain.

### 17.3 The grid's Y unit is a PLATE, not a brick — and §4 was wrong

§4 argued the terrain voxel should be one brick tall (0.42 m) to save memory, and made the ramp
layer carry the walkability cost. That argument does not survive the question about **tiles**.

A tile is one plate. A plate is one plate. A brick is three. If the cell is a brick tall, a tile
has nowhere to live, cannot be stacked, and cannot sit on top of a brick — which is exactly the
overlay course §6 just added, done properly.

So the terrain grid is the grid everything else is on: **x and z in studs, y in plates** (Plan §2,
D6). A brick occupies three cells vertically, a tile one. Nothing about terrain is special any
more, which is the point.

The cost is 3× the Y cells, and §17.4 says that is affordable. §4's memory argument was made
against a dense array; against a palettised section with a uniform short circuit it is the wrong
comparison.

### 17.4 What it costs

Paper arithmetic. Storage is Minecraft-shaped — a palette plus a packed bit array per section,
with a uniform-section short circuit — because **most of the volume is either all air or all
rock**, and those cost two bytes each.

| | |
|---|---|
| Section | 32 studs × 48 plates × 32 studs = 49,152 cells, covering 11.2 × 6.72 × 11.2 m |
| At 3 bits a cell (8 materials) | **18 KB**; a uniform section is 2 bytes |
| Non-uniform sections a tile column | ~2 — the surface, and the one under it. Above is air, below is rock |
| Resident inside 300 m | 2261 tiles × 2 × 18 KB = **~65 MB** |
| Derived heightmap, whole city | 24.5 MB, always resident (§17.7) |
| **Total** | **~79 MB a square kilometre** |

Block storage — real `Block` entries with piece identity — exists **only for damaged or edited
sections**, exactly as it does for buildings. An untouched cave wall is a material id, not a list
of bricks.

### 17.5 Can the randomised brick shapes survive? Yes, and they get better

This is the part that improves rather than degrades.

- **The surface packer is unchanged.** The exposed top faces of a volumetric world are still a 2D
  set of cells with a height and a material each, which is exactly what `TileSample` feeds the
  size ladder today. The 2×4-dominant mix, the mixed orientations, the tiles, the overlay course
  and the ramps all keep working.
- **Walls get packed too, and that is new.** A cliff face or a cave wall is another 2D region, so
  the same ladder lays it in courses. A cut through the ground currently reads as a sheared
  surface; packed, it reads as a wall someone built. This is the biggest visual gain of the switch.
- **Random heights become a real axis.** Today every surface piece is implicitly one brick tall.
  With plate-Y the packer picks a vertical size too — brick, plate or tile — so a terrace can step
  in plates where the generator wants it to and in bricks where it does not.

What makes all of this work is the property already built for streaming: **the packer is
stateless**. The pieces you see before anything touches the ground are the same pieces that
materialise when it does, because both come from the same hash of the same global cells. That was
paid for in §6.3 for a different reason, and it is what makes recipe-to-chunk seamless.

### 17.6 The five things that change, and how much

| | Effect |
|---|---|
| **Water** | Almost none. Water is a surface, not a volume, so the GPU packer stays. The seabed texture keeps working, because it stores the *topmost solid* per column and that is still one well-defined number. What it cannot do is a **flooded cave** — that needs a per-region water level rather than one plane, and it is out of scope until something asks for it |
| **Collision** | Gets *simpler*. `add_chunk_shapes(..., merge)` (`brick_world.cpp:1155`) already greedy-merges a chunk's live cells into boxes; terrain drops its own 2D merge and uses it. Only the **surface shell** needs shapes — nothing can reach solid rock until it is dug — so the box count stays near today's 72 a tile |
| **Odd-shaped pieces** | Already supported, untouched. `bake_shaped_archetype` gives an archetype an occupancy mask, per-column `up_face`/`down_face` and side studs; M2b's note is explicit that nothing downstream assumes a box. Slopes, wedges and corners are archetypes, not special cases |
| **Tiles shorter than a brick** | Solved by §17.3 and only by it. This is the requirement that forces plate-Y |
| **Curved pieces spanning several cells** | Expressible — an archetype is a bounding `size` plus an occupancy mask plus a mesh, so a curve filling 4×3×4 cells is one block. Three caveats: its studs sit on the top solid cell of each column, so `mates()` still works; its collision is box-per-cell merged, which is chunky until Plan §8 question 3 is revisited; and face culling only removes its *cell-boundary* faces, so a curve costs more triangles than a box. They are decoration, not the bulk, so that is the right trade |

### 17.7 The heightfield survives as the far LOD

Outside the streaming radius a tile keeps only its **derived heightmap** — topmost solid per
column, 3 KB — and its sections load on approach. Not a fallback bolted on: it is the same 24.5 MB
structure §1 costed, it is what LOD 2 and LOD 3 draw, and it is why gate G2 stays cheap.

Minecraft keeps per-chunk heightmaps for exactly this reason — scanning sections to find the
surface is expensive, and the surface is what almost every query wants.

### 17.8 Order of work

The seam is narrow on purpose. Everything above the field reads one interface — a surface height
and a material per column — so most of it does not move.

| Step | Deliverable | Gate |
|---|---|---|
| **V0** | `Field::solid_at(x, y, z)` replaces `height_at`: the same noise for the surface plus a 3D carve for caves. `sample_tile` becomes `sample_section` and derives the topmost-solid heightmap from it | The existing probe passes **unchanged** — same packer, same mix, same studs. Caves exist but nothing draws their insides yet |
| **V1** | Palettised section storage with the uniform short circuit; the derived heightmap as the far tier | A uniform section is 2 bytes, a surface section ~18 KB, and §17.4's per-km² figure holds |
| **V2** | Pack and mesh **exposed vertical faces**, not only tops | A cliff reads as laid courses, not as a shear |
| **V3** | Materialise a section into a real `Chunk` via `place_block`; collision through `add_chunk_shapes(..., merge)` | `apply_hit` digs the ground with no terrain-specific code. **G1**, **G1b**, **G2** |
| **V4** | Undercut ledges come loose — `find_detached_groups` on a terrain chunk | Dig under a cliff and it falls |
| **V5** | Plate and tile heights in the packer's ladder | A terrace steps in plates where the generator asks for it |

**V0 decides the rest.** If a volumetric field plus a derived heightmap does not reproduce today's
surface exactly, the migration has a bug in it and everything after V0 would be built on that.

### 17.9 What must be bumped

`FIELD_VERSION`. A heightmap delta and a voxel diff are different formats, so saved terrain damage
written under the current version is meaningless under the new one and must be **rejected rather
than misapplied** — mvs-c's `LAYOUT_VERSION` lesson, and §15 question 1.

### 17.10 Built, 2026-09-20 — V0, V1's edit store, V3's destruction

60 probe checks pass. `shots/terrain_blast.png` is three craters punched into a hillside.

| | |
|---|---|
| `Field::solid_at(x, yp, z)` | the truth. The surface is DERIVED by scanning down from the nominal top, so a cave mouth or a crater lowers it and nothing raises it |
| Caves | two crossing sheets of ridged 3D value noise. One threshold gives blobs; two fields near zero at once gives **tubes**. Measured **7% of the subsurface is air** |
| Edit store | sparse `unordered_map`, keyed by packed global plate cell. An untouched world stores nothing; a crater stores one byte a plate. **This is the whole damage record** |
| `carve(point, radius)` | edits the truth, returns dirtied tiles, cells removed and rim debris. Same shape as `apply_hit` — no presentation inside it |
| Mesher | six-direction greedy over the mask, skipping the tops the surface packer drew |
| A tile | 259 pieces, 3,562 tris, **3.8 ms** |

**V0's gate held: the surface is unchanged.** Same 2×4 mix at 50%, same 259 pieces, 688 studs,
146 collision boxes, 499 ramps as the heightfield build. The volumetric field reproduces it
exactly, which is what §17.8 said had to be true before anything else was built on it.

#### Three things measurement changed

1. **Per-cell sampling was 16× too slow.** `nominal_height` is three octaves of fBm and
   `material_at` another noise, and both are functions of the *column*. Calling `solid_at` per
   cell recomputed them for all ~85 plates of every column: **9.4 ms a tile against 0.6 ms** for
   the heightfield it replaced. Hoisted to the column, only the cave test and the edit lookup
   stay per cell — **3.4 ms**.
2. **Cave thresholds cannot be reasoned about.** Two independent `|noise| < w` tests multiply, and
   trilinear value noise is peaked at zero, so the joint probability collapses far faster than `w`
   suggests. `w = 0.055` measured **0.35%** subsurface air, which is no caves at all. `0.15` gives
   7%. Tuned against the probe, not derived.
3. **Reachability culling has to seed from the SKY only.** Caves tripled the triangle count to
   82,748, almost all of it chambers sealed in rock. A flood fill seeded from the sky *and the
   section's sides* culled **nothing** — a cave is a tube, almost every tube touches the sampled
   boundary, so everything came back reachable. Sky-only brings it to **32,236**, against 28,588
   before caves existed.

The cost of sky-only: a cave crossing a tile line can be open in one tile and sealed in the next,
so a long tunnel's far wall may not draw until you are in the tile that owns its mouth. Same class
as pieces clipping at tile boundaries, and real sections fix both.

#### Not done

V2 (pack and mesh vertical faces as courses — crater walls are currently plain greedy quads, not
laid brick), V4 (undercut ledges coming loose via `find_detached_groups`), V5 (plate and tile
heights in the ladder), and materialising a section into a real `Chunk` — carve edits the field
directly rather than going through `place_block`, so terrain damage does not yet share the
building destruction path.

#### Two more, after looking at a crater

4. **A piece's top must be its top PLATE, not its brick's top.** The packer keyed on `h`, the
   brick index, and drew the top face at `(h + 1) * BRICK`. Untouched ground is built on brick
   boundaries so the two always agreed — but a crater leaves one or two plates of a brick
   standing, and then the packed quad floated up to two plates above the rock **with nothing
   under it**. Worse, `top_is_packed` compared against the brick top too, so the mask did not
   recognise the real top face as covered and drew it as well: a floating quad and a correct one,
   both. `TileSample::tp` now records the exact top plate, `fits` requires two columns to agree
   about it before merging them, and everything that sits on the surface — the top face, studs,
   the overlay, collision — reads it.
5. **An unbounded greedy merge makes one enormous brick.** A three-metre cliff merged into a
   single quad, and because `UV2` carries the quad's size the seam shader drew **one brick
   outline around the whole wall**. A merged face is now capped to something a real part could
   be: 6 studs wide, 2 deep for a horizontal face, and a vertical face is additionally stopped at
   every brick course so a wall reads as courses. Joints stagger off the same cut lattice the
   ground is packed with, so the courses do not line up into vertical seams.

Together those moved a tile from 3,562 triangles to 976 — the duplicate top layer was most of it
— while the field as a whole went 32,236 to 35,072, which is the course capping buying detail
back in the walls. That is most of **V2** done, arriving as a bug fix rather than as a milestone.

#### Two see-through bugs, and why one of them was my own culling

Standing inside a dug-out cavern showed sky through the ground. Two independent causes.

6. **The mask stopped at the section floor, and digging did not.** `sample_tile` reached
   `SECTION_BELOW` plates under the surface and no further, so anything dug deeper was edited in
   the field but still read as solid rock to the mesher: the floor of a deep pit was simply never
   built. `g_tile_floor` now records the deepest edit per tile column, and both `sample_tile` and
   `surface_plate` reach past it. Probed with a 12.6 m shaft.

7. **The reachability fill was culling faces that were genuinely visible.** Seeding it from the
   sky alone culled a great deal — and some of what it culled was air that reaches the sky by a
   path *leaving the tile's span*. That air is open; throwing its faces away is a hole in the
   world.

   The fix is to seed the span's SIDES as well, which makes the test conservative: it can now
   only cull a pocket entirely inside the span that reaches no sky, and such a pocket really is
   sealed globally, not merely locally.

   **This is the version I wrote first, measured as culling nothing, and replaced for that
   reason.** "Culls nothing" was the correct answer and the measurement was the wrong question —
   a cull that saves triangles by not drawing visible geometry is not a saving.

   The triangles it gives back are paid for where they should be: `cave_at` now generates caves
   in a **band** (4 to 34 plates below the surface) instead of a half-space, so there are no deep
   sealed chambers left to mesh. That is a generation decision rather than a rendering lie.
   Subsurface air 7% → 5%, and a tile is 3,686 triangles at 3.85 ms.

The general lesson, worth keeping: **an occlusion test that can only see one tile must fail
towards drawing.** Anything else trades a hole in the world for a triangle count, and the hole
costs more.

#### 8. The see-through was inverted winding, and it was silent

The two culling fixes above were real, but they were not what the screenshots showed. The actual
cause: **both horizontal directions of the mask mesher emitted their quads back to front**, so
`cull_back` discarded every one of them.

The rule, which is not derivable and has to be read off a face already known to render — the
packer's top quad:

> for a face with outward normal **N**, the winding must give `(b - a) x (c - a)` along **-N**.

The four lateral directions obeyed it. `dy < 0` and `dy > 0` did not. Measured by the new probe
gate, on nine tiles:

```
normal (0,-1,0): 2958   normal (0,1,0): 1936
FAIL  4894 of 26164 triangles backwards
```

**Every backwards triangle had a vertical normal.** 2,958 cave roofs and overhang undersides,
1,936 floors of lower spans — in the vertex buffer, costing triangles, invisible. After the
vertex reorder: 0 of 26,164.

Why it survived so long, and the lesson:

- **The main surface looked right.** The packer draws the topmost face of each column with
  correct winding, so open ground was never affected. Only faces the MASK drew were lost, and
  those are exactly the ones you have to be inside a hole to see.
- **Nothing counted wrong.** Triangle counts, piece counts, collision boxes, the mix — all
  correct. A backwards quad is present and paid for; it is only invisible.
- **Side faces were fine**, so any capture looking at a wall showed nothing amiss.
  `shots/terrain_ceiling.png` looks straight UP a shaft and is the only angle that could have
  caught it.

`_check_winding` now walks every triangle of nine tiles and compares the cross product against
the stored normal, so a backwards quad can never be silent again. **When geometry is missing,
check winding before reasoning about which faces ought to be culled** — an occlusion argument
cannot explain a face that is in the buffer.
