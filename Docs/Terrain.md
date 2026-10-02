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

### 17.11 Where real geometry goes, and where it does not

A 13 mm chamfer subtends `17.8 / distance` pixels: 8.9 px at 2 m, 2.2 px at 8 m, 1.0 px at 18 m.
So real bevel geometry only earns anything inside about three metres, and inside that only on
edges that are actually SILHOUETTES — against sky or a distant surface. On a flat floor almost
every edge is interior, and there the shaded bevel is not an approximation, it is the correct
answer: the eye reads the lighting.

That splits cleanly, and the split is the rule:

| | cost | verdict |
|---|---|---|
| **Shared, instanced, few** — debris brick, stud, scatter | paid ONCE for the whole field | **real geometry.** `PieceMeshes.chamfered_box` is 44 tris; the stud's rim bevel took it 22 → 38 |
| **Baked, many** — the chunk mesh | 685k → 4.8M on one tower, and a vertex-buffer rebuild on a distance test, which is M2c's 175 ms trap driven by camera movement instead of damage | **shaded.** `brick.gdshader`, and now `terrain.gdshader`, which was missing the chamfer entirely |

`_tri_n` decides winding at runtime from the outward normal rather than by hand. That is a direct
response to the mask mesher's inverted faces: hand-derived sign parity is exactly how that
happened, and it was invisible for four rounds.

**And the thing the captures settled.** `shots/geometry_only.png` turns every painted effect off
(F7 in the test scene). What is left is a flat tan slab with studs standing on it. There is no
geometry under the brick outlines at all — two touching coplanar faces are meshed as two touching
coplanar quads. **The seam is not decorating a division that exists; it IS the division**, which
is why "switch the grid off and rely on the real geometry" has nothing to fall back on, and why
the chamfer is hard to see against it: they are the same edge at two fidelities, crevice and lit
facet.

#### 9. `NORMAL` is in VIEW space, and a world-space vector written into it does nothing

The chamfer was visible on studs and invisible on bricks, and the reason is one line.

Studs are real geometry, so their bevel is triangles and is always right. The brick bevel is
shaded — and the first terrain version built its tilt as a world-space, Y-up vector
(`vec3(on.x * dir.x, 1.0, on.y * dir.y)`) and assigned it straight into `NORMAL`. `NORMAL` in a
Godot fragment shader is in **view** space, so that bends the normal in an arbitrary direction
relative to the camera. It is not subtle-but-present; it is noise, and on a vertical face the
Y-up assumption is meaningless as well.

`brick.gdshader` had this right all along: it derives a tangent frame from screen-space
derivatives of `VERTEX` against `UV`, which lands in the same space as `NORMAL` and works
whatever direction the face points or however the chunk is tumbling. `terrain.gdshader` now uses
the same frame, and so does its stud dome, which had the identical bug — and so does the water
shader's dome, which had it too.

**Rule: any normal perturbation must be built in the frame `NORMAL` lives in.** If you catch
yourself writing a literal `1.0` in the Y slot of a normal, that is the bug.

#### 10. A ramp is a wedge, but the voxel under it is a full column

Three reported symptoms, one cause: angled pieces culled wrongly, faces beside them missing, and
a flat square standing behind every slope.

The ramp draws a tilted quad. The mask mesher only knows about CELLS, and the cells under that
quad are a full, solid brick — so it drew the flat wall the wedge was supposed to replace, a
rectangle standing exactly where the slope is. That rectangle is the square; the z-fighting where
it overlaps the tilted quad is the faces that looked missing.

`ramp_faces()` used to handle this and was deleted when the mask mesher replaced the
height-comparison skirts. Nothing replaced what it did.

The fix is smaller than the symptom: **skip every lateral mask face inside the wedge's brick.**
That is safe rather than approximate, because a ramp is *defined* as having exactly one lower
neighbour — its other three sides face solid rock and were interior already — so the one side
that was open is the one the tilted quad covers. A tile went 3,686 to 3,652 triangles, which is
the duplicate walls leaving.

`shots/terrain_ramp.png` finds the nearest ramp in the field and photographs it from its low
side, which is the angle all three symptoms showed from.

#### 11. A running editor keeps the shader it compiled at load

Worth knowing when a shader fix looks like it did nothing: Godot compiles a material's shader when
it first loads it, and an already-running instance does not pick up an edit to the `.gdshader` on
disk. Two rounds were spent looking at a stale compiled chamfer. Restart before concluding a
shader change failed — and the measured gate (`--shot` prints the terrain chamfer's changed-pixel
percentage) is a better answer than looking, for the same reason the winding gate is.

### 17.12 Chamfer: two brick assets, streamed near — the right shape

Chamfering FACES was the wrong decomposition and the captures show why. Two coplanar pieces each
inset their top, and the V-groove between them has **no bottom**, because the terrain mesh is a
skin and there is no brick body under it. At convex corners the opposite fault: only one of the
two faces can own the 45-degree facet without z-fighting, so the other side leaves a notch.

Measured anyway, for the record: 70,426 to **202,862 triangles** over 25 tiles, 22 to 27 ms a
frame. Left behind the `G` toggle, default off, labelled broken.

**A chamfered BRICK does not have either fault, because it is a closed solid.**
`PieceMeshes.chamfered_box` is already watertight; a groove between two of them has a bottom
because each one has a body. So the unit to chamfer is the piece, not the face — which is what
"real assets with the chamfer, real assets without, stream the chamfered ones nearby" says.

How it lands on each surface, and neither needs the vertex-buffer rebuild M2c forbids:

| | mechanism | cost |
|---|---|---|
| **Terrain tiles** | build BOTH meshes when the tile loads — flat faces, and chamfered piece solids — and swap with `visibility_range`. No runtime rebuild at all, the same pattern the stud and scatter tiers already use | ~2x tile build time, ~3x tile VRAM; only near tiles draw the heavy one |
| **City chunks** | exclude the near blocks' face ranges from the baked index buffer and draw those blocks from a per-size chamfered `MultiMesh`. **M2c already implements exactly this**: faces are baked once and damage flips index slots, so excluding a face is O(1) and never re-uploads vertices | index flips on a camera crossing, plus a small instance buffer |

Within 8 m that is ~330 pieces; at 44 triangles a chamfered solid, ~14k triangles. The reason
this is cheap where the face version was not is that only the SURFACE pieces near the camera
become solids, and everything else stays exactly as it is.

The open question before building it is how much of the near surface becomes solids: the packed
top pieces alone, or the exposed mask cells (terrace and cave walls) as well. Tops alone is far
cheaper and covers the case the eye actually reads — a floor seen at a grazing angle.

### 17.13 Built: a near chamfer tier at ~10 bricks

All faces — floor, walls, roof, cave ceilings — get real 45-degree chamfer geometry inside
**12 m**, and flat faces beyond it. `G` toggles the tier; `F7` strips the painted effects so the
geometry can be judged on its own.

**What fixed the open groove.** The earlier face chamfer skipped a strip on two of every four
edges, under a rule that assumed the other half of each edge belonged to a PERPENDICULAR face.
Most edges on this surface are shared with a COPLANAR neighbour instead, where there is no second
face at all — so the V between two pieces had nothing under it. With all four strips emitted, two
coplanar neighbours meet at the shared rim one bevel down and the groove has a bottom. A convex
corner still leaves a 13 mm notch where the strip stops short of the perpendicular face; small
enough to read as part of the bevel, and it goes away when walls are packed into pieces (V2).

**The tile is the granularity, not a sphere.** A true per-metre radius would rebuild tile meshes
as you walk — ~11 ms a tile, which is the trap M2c exists to avoid. Instead BOTH meshes are built
when the tile loads and Godot's `visibility_range` swaps them, so walking costs nothing. This is
the same pattern the stud and scatter tiers already use.

Measured, 25 tiles, 56 m field:

| | |
|---|---|
| Held | 70,426 flat + **352,130 chamfered** |
| Drawn | only tiles inside 12 m carry the chamfered mesh — about 3.6 of 25, so ~50k of that 352k |
| Tile build | 297 ms to 436 ms for the field, because each tile is meshed twice |
| Frame | 22 ms to 26 ms |

The build cost is the honest weak point: each tile samples and packs twice to produce two meshes.
Emitting both from one pass is the obvious fix and was not done.

### 17.14 Generated chamfer or prebuilt chamfered assets?

Both, and the line between them is not "which is better" — it is **what kind of surface it is**.

| | use | why |
|---|---|---|
| **Generated in the mesher** — two mesh variants a tile, swapped by range | terrain, and any procedural surface | the packer emits 1x1 through 2x6 in both orientations, merged wall quads of ARBITRARY size, ramps and overlay courses. No asset library covers a merged quad whose size was decided at runtime. And the chamfered mesh *replaces* the flat one, so there is no face-exclusion or z-fighting problem to solve |
| **Prebuilt chamfered asset, instanced** | debris bricks, studs, scatter | discrete, repeated, a handful of sizes. `PieceMeshes.chamfered_box` caches per size and 44 triangles are paid once for the whole debris field |

Trying to use assets for terrain lands back in the same place anyway: to stop the flat faces
showing through the inset asset you must exclude them, and for a tile that means a second mesh
variant — which is what the generated route already is, minus the asset pipeline.

The one thing assets would give that generation currently does not is a clean convex corner; the
generated strips stop a bevel short of the perpendicular face and leave a 13 mm notch. Emitting
corner triangles in the mesher fixes that and is far less work than an asset set.

#### The winding gate did not cover the geometry added after it

Every chamfer facet was wound backwards — visible from behind the surface, invisible from in
front. `_check_winding` existed and passed, because it only ever ran `build_tile` with the bevel
at its default of zero, so not one of the 128,770 chamfer triangles was ever looked at.

It now runs both variants: **154,524 triangles checked, up from 25,754.**

**A gate that does not cover the geometry added after it is not a gate.** This is the fourth
hand-derived winding error in this system and the second time the gate for it was present and
inapplicable. When new geometry is added, widen the gate in the same change.

#### The convex corner, filled — and no, it did not need assets

The pinwheel of light and dark wedges at every terrace corner was not the chamfer overshooting.
Three faces meet at a convex corner, each one's strip stops a bevel short of the other two, and
the triangular hole between them shows **the backs of the surrounding facets** — which is why it
reads as alternating wedges rather than as a solid overhang.

The hole is the triangle joining the three faces' pulled-back rim points. All three faces can
compute it, because the other two normals are simply this face's two edge-outward directions, so
exactly one must own it — and since the three normals lie on three different axes, "lowest axis
index wins" picks one and only one.

About twenty lines, against an asset pipeline plus the face-exclusion problem that comes with it.
352,130 to 391,354 chamfered triangles held, so the corners are ~11%.

`tri_facing()` **corrects** the winding to match the given normal rather than trusting a
hand-derived vertex order. The corner fan has eight sign cases, and hand-deriving those is
precisely how the previous three winding bugs happened. `shots/terrain_corner.png` finds the
nearest convex corner in the field and photographs it close, which is the only view the artefact
appears in.

#### "The chamfers extend too far" — they were slopes, not chamfers

The wide angled bands at every terrace step are the **ramp layer**, not the bevel. The decisive
test is one frame: `shots/terrain_corner_off.png` is the same camera with the chamfer OFF, and
every wide angled surface is still there.

A ramp is a 1x1 slope dropping one brick (0.42 m) over one stud (0.35 m) — a 50-degree face a
third of a metre across. Up close that is twenty times the width of a 13 mm chamfer and reads as
one, which is why four rounds of screenshots kept pointing at the bevel.

Measured, one tile, at a 13 mm setting: **16,696 chamfer facets, every one 0.0225 m**, no spread
at all. The expected figure is `cut * sqrt(3)`, not `sqrt(2)` — the strip runs from a corner
inset along BOTH in-plane edge axes to a rim pushed back along the normal, so all three axes
contribute. The first version of this check asserted sqrt(2) and would have failed correct
geometry.

It also reported a "0.324 m chamfer", which was **76 ramp tops**: a slope's tilted face has a
diagonal normal too, and the check classified facets by normal alone. A measurement that cannot
tell a slope from a bevel is not a measurement of the bevel.

So the remaining question is not a bug, it is a design choice: **do terraces get slope pieces at
all?** They exist to make a 0.42 m step walkable (section 6.1, section 4), spec section 2 wants
slope bricks, and a 1x1 slope is a real part. Dropping them gives sharp brick terraces and puts
the walkability on the character's step-up height instead.

### 17.15 Slopes off, tiles up

`RAMPS_ENABLED = false`. A 1x1 slope is a 50-degree face a third of a metre across and at close
range it made the ground read as melted rather than built; walkability moves to the character's
step-up height, which already exists. The cells that were ramps do not vanish — they are terrace
edges, so they are not flat plates, so the packer lays them as TILES.

`TILE_CHANCE = 0.22` puts some flat pieces down smooth as well, because ground that is
wall-to-wall studs reads as one material.

| | before | after |
|---|---|---|
| Surface by area | brick 78%, tile 15%, ramp 7% | **brick 62%, tile 38%** |
| Pieces / tris | 8,204 / 70,426 | 6,799 / 67,026 |
| Studs | 15,310 | 12,377 |

A tile takes no studs and nothing clips to it, so this is a BUILD rule as much as a look: you
cannot build on a tiled patch (section 7.6). `ramp_dir` now returns -1 when slopes are off, or
the query would report a ramp where the mesher lays a tile.

### 17.16 The chamfer's corner cases are combinatorial — and solids are not

The olive slots along every terrace lip were **not** the corner notch diagnosed earlier. They
were a continuous open slot the length of every convex edge: a top face's half-facet stops one
bevel below the rim, the wall's stops one bevel inside it, and the strip between them was drawn
by neither.

Fixed with a per-edge `convex` mask — one bit an edge, set when a perpendicular face meets this
one, cleared when the neighbour is coplanar. The two cases need different geometry and no single
formula serves both:

- **coplanar**: each face emits HALF, down to the shared rim one bevel back. The halves meet and
  the groove has a floor.
- **convex**: the facet runs from our inset edge to theirs, and exactly one of the two draws all
  of it.

Facets went 16,696 to 13,002 and the slots closed. **A small sliver still shows where one edge of
a corner is convex and the other coplanar** — the two meet at different depths and leave a
triangle. That is the third distinct corner case, after convex/convex and coplanar/coplanar.

That is the finding worth recording. Chamfering FACES has a combinatorial tail: every pair of
edge kinds, times ownership, is its own geometry. Four rounds have each fixed one case and
exposed the next.

**A closed chamfered SOLID per piece has none of them**, because a solid's corners are modelled
rather than negotiated between faces that cannot see each other. The reason to reject it was
cost, and that reason no longer holds:

| | triangles |
|---|---|
| Face chamfer, whole field | 306,828 |
| Closed solids, 6,799 pieces x 44 | **~299,000** |

Same cost, no corner cases. The recommendation is now to switch the near tier to solids — which
is what was proposed several rounds ago and talked out of on a cost argument that was wrong.

### 17.17 Built: the near tier is closed chamfered solids

`piece_solid()` lays each surface piece as a **closed chamfered brick** rather than a chamfered
top face. The implementation is smaller than the thing it replaces: every edge of a box is
convex, so it is the six faces emitted through `quad()` with `convex` set on all four edges, and
the ownership rule hands each of the twelve edges and eight corners to exactly one face. No new
geometry code. The bottom face is skipped — a piece sits in the ground.

The mask must then skip **every** face of the piece's brick, not only the top: a flush wall a
bevel outside the chamfered one hides it.

Why this ends the problem rather than fixing one more case: **a solid's corners are modelled.** A
face chamfer has to negotiate each corner between two faces that cannot see each other, and that
negotiation has a case per pair of edge kinds times ownership. Four rounds each fixed one and
exposed the next — convex/convex, then coplanar/coplanar, then the long convex slot, then
convex/coplanar. Two adjacent solids touch at the full cell boundary, so their chamfers form a V
whose bottom is the boundary itself: closed by construction, not by agreement.

| | triangles held |
|---|---|
| Flat | 67,026 |
| Face chamfer | 306,828 |
| **Closed solids** | **447,077** |

The estimate for solids was ~299k and the truth is 447k, because a solid emits five faces with
every edge convex where the face version emitted one face with most edges coplanar. It is 46%
more than the face chamfer, not the wash predicted. Only tiles inside 12 m draw it — about 3.6
of 25, so roughly 64k drawn — and the frame is 27.4 ms against 25.3 ms flat.

Both cost estimates in this argument were wrong in opposite directions, which is the reminder
worth keeping: the triangle count of a decomposition is not guessable from the shape of it.

#### The convex facet was degenerate, not reversed

Convex edges came out MISSING, and the cause was a wrong idea about where the facet ends rather
than a winding error.

The facet always runs from a face's inset edge to **the rim pushed back along that face's own
normal**, because that point IS the neighbouring face's inset edge — true whether the neighbour
is coplanar or perpendicular. Pushing it along `out` instead put the far edge exactly on top of
the near one: a zero-area quad, so the edge simply was not there.

So convexity changes **nothing** about the geometry. Its only job is ownership: two coplanar
faces each draw their half and meet at the bottom of the V, while two perpendicular faces would
each draw the whole facet, so one stands down. That is a much smaller rule than the one it
replaced.

The corner fan was wrong the same way — `rim - n*cut` and friends make a triangle twice the size
that does not line up with the facets bounding the hole. The three vertices are where each PAIR
of the corner's facets meet: `rim - (o1+o2)*cut`, `rim - (n+o2)*cut`, `rim - (n+o1)*cut`.

Winding-checked triangles went 135,821 to 184,513 — the corner fans had been degenerate and were
being skipped by the gate's zero-area test, so they passed by not existing.

### 17.18 Authored assets, or generated solids?

We DO lay bricks as closed chamfered solids now. What we do not do is author them as mesh files,
and the reason is that the sizes are not known until runtime:

- the packer emits 1x1 through 2x6 in both orientations, chosen per cell by hash
- wall and cave faces are greedy-merged quads of arbitrary size
- a tile's mix changes the moment anything is carved

An authored set would need a file per size and still could not cover a merged quad. `piece_solid`
generates the same geometry from the size it is handed, and costs one function.

Authored assets remain right where the part is **discrete and repeated**: the debris brick, the
stud, scatter. Those are `PieceMeshes`, cached per size, and the bevel is paid once for the whole
field. That is the same rule as section 17.11, now with the terrain case decided:

| | |
|---|---|
| Procedural, size known at runtime | generate the solid |
| Discrete, repeated, few sizes | author or build one mesh and instance it |

### 17.19 The gaps and the messy corners: two causes, and neither wanted a bigger face

**The gaps were the solid's BOTTOM chamfer.** A brick bevelled on its bottom edges is correct —
on a real model it sits on another brick and that groove is the join. Ours sits on terrain that
is not meshed, so the bevel opened a 13 mm slot round every piece with unlit nothing behind it.
The bottom edges are square now; the bottom face was already skipped, and its edges are too.

**The messy corners were coincident faces.** Two neighbouring bricks each drew the face they
share, back to back in the same plane, and the pair z-fought into a checkerboard of light and
dark triangles along every shared edge. A side abutting a neighbour at the same height is not
drawn at all now — the neighbour's body is already there.

Extending the faces to close the gaps, which was the instinct, is the wrong fix: it means
deliberately overlapping geometry, and deliberate overlap is what produced the checkerboard.

The two interact, and that is the part worth keeping. If a side face is not drawn but the top
still marks that edge CONVEX, the side owns a facet it is no longer drawing and the edge
vanishes — the exact bug of the round before. So both now read the same drop-away test: level
neighbour means coplanar, and the two tops each emit half a facet and meet in the groove. One
test, two consumers, no way for them to drift.

| | |
|---|---|
| Chamfered triangles held | 447,077 to **296,135** |
| Facet triangles | 15,760 to 12,104 |
| Frame | 26.9 ms |

`shots/brick_join.png` looks along flat ground where several pieces meet, which is the view the
gaps were reported from and which no existing capture covered — the wide shots average the
artefact away and the corner shot looks at a terrace instead.

### 17.20 Check the binary before asking anyone to look

Three rounds of this work were spent looking at stale artefacts: twice a DLL whose link had
failed with "Access is denied", once a shader the running editor had already compiled. Each time
the reasoning went to the geometry instead of to what was actually loaded.

A link that fails leaves the previous DLL in place and Godot loads it happily. **Before saying a
fix is testable, confirm the built file is newer than the source it came from.** It is one `ls`
and it would have saved three test cycles.

### 17.21 Approach C: a brick on a backing, and why the facet approach was abandoned

Six rounds of chamfered-FACE geometry each found a real bug — inverted winding, degenerate
facets, an open slot the length of every convex edge, coincident faces between neighbours, a
missing third edge state — and the artefacts survived all of them. That is not a queue of cases;
it is the wrong decomposition.

**The structural reason.** A face chamfer requires every facet to agree with the facet on the
other side of its edge. The other side may belong to the packer, to the greedy mask, or to
nothing at all, because the volume behind the surface is not meshed. Three parties, no shared
knowledge, and an agreement demanded at every edge of every face.

**Approach C removes the agreement instead of getting it right.**

| | |
|---|---|
| The brick | a CLOSED box, every edge convex against air. The same geometry `PieceMeshes.chamfered_box` uses for debris — the one chamfer that has never produced an artefact in any capture |
| The gap | each brick is pulled back `BRICK_GAP` (8 mm) on any side that has a neighbour, so the join is a real physical gap rather than a negotiated V. A side where the ground DROPS AWAY keeps its full extent: no neighbour to leave a gap against, and that face is the cliff |
| The backing | the piece's footprint again, `BACKING_DROP` (30 mm) below the surface, with no bevel of any kind. Every gap shows backing |

The property that matters is not that it is prettier. It is that **a wrong inset is now a
cosmetic gap width and can no longer be a hole.** Nothing is drawn against anything, so nothing
can disagree.

| | |
|---|---|
| Chamfered triangles held | 229,795 to **438,029** |
| Frame | 28.1 ms |

The cost went UP, and honestly: a closed box emits six faces with every edge chamfered, where
the face version emitted one face with most edges needing nothing. Robustness was bought with
triangles. The obvious reductions, neither done: skip the brick's hidden bottom face, and merge
the backing across adjacent pieces instead of one quad each.

### 17.22 Heightfield mode, and §17's decision taken back

`scenes/heightfield_test.tscn` — plate-quantised heightmap, no voxels, no caves, no
destruction. `BrickTerrain.set_flat_mode(true)` is the whole of it: `solid_at` stops consulting
the cave noise and the edit store, and the surface is exactly `nominal_height`. Everything above
the field — the packer, the 2x4-dominant mix, the stud tiers, the scatter, the collision merge —
is untouched and does not know the difference.

Kept as a FLAG rather than by deleting the volumetric path, because the two differ only in what
one function answers, and §17.1's table is still true about what this gives up: overhangs, caves,
digging, and undercut cliffs that fall.

Measured, same 25-tile field:

| | volumetric | heightfield |
|---|---|---|
| Triangles | 67,026 | **21,986** |
| Build | ~400 ms | **156 ms** |
| Frame | 27 ms | **18.6 ms** |
| Pieces | 6,799 | 6,045 |

Three times cheaper, because there are no cave interiors to mesh and no subsurface mask to walk.

**Tiles on studs** are the piece overlay (§6, `OVERLAY_CHANCE`): a smooth tile laid one plate
above the brick it sits on, exactly as a real tile clips over studs. `F5` toggles them so the
studded-everywhere version can be compared, and `hf_close.png` is the shot — smooth raised plates
among studded ground, which is what a brick floor actually looks like and what wall-to-wall studs
was missing.

**The geometry chamfer is off in this scene.** §17.21's brick-on-a-backing works, but six rounds
of artefacts came out of geometric chamfering and the shaded bevel has produced none, at a
measured 7.6% of pixels changed. `TerrainTile.bevel_enabled = false` and the shader does it.

### 17.23 Seams that did not line up, and half-brick steps

**The seams.** A brick's top and its side were divided in different places, because they came
from different systems: the top from the packer, the side from the greedy mask, whose merge
lattice knows nothing about where the packer put piece boundaries. So a 2x4 on top had its side
cut somewhere else entirely.

Fixed by letting a piece draw **its own brick's side faces**, not just its top, and having the
mask skip the piece's brick whether it is bevelled or not. The side of a brick is now the same
brick as its top by construction rather than by coincidence.

**Half-brick steps.** `set_plate_steps(true)` quantises the generated surface to plates (0.14 m)
instead of bricks (0.42 m). The grid was already in plates, so it is one multiplier in the
generator — and `top_plate` is now the primary field function with the brick height derived from
it, rather than the other way round. Flatness also had to become plate-exact: comparing bricks
called a one-plate step flat, which under plate quantisation is most of the terrain.

Measured, 25 tiles, heightfield mode:

| | brick steps | plate steps |
|---|---|---|
| Pieces | 6,045 | **9,508** |
| Studs per piece | 4.2 | 2.7 |
| Triangles | 21,986 | 35,494 |
| Studs | 12,597 | 8,280 |
| Build | 159 ms | 427 ms |

Smoother terrain costs 60% more triangles and a third of the studs, because finer height
variation breaks the packing into smaller pieces and fewer cells qualify as flat. `F6` toggles
it; which reads better is a look decision, not a technical one.

---

### 17.24 Regional plate steps, and the tops-only chamfer, built

Two of §18's entries moved out of "planned" in the same pass.

**Plate steps are regional.** Quantising the whole field to plates (0.14 m) instead of bricks
(0.42 m) reads better where the ground is gentle, and everywhere at once costs ~60% more
triangles and a third of the studs — a one-plate step is not flat, so `stud_at` says no
(§17.23). A low-frequency mask, `value_noise(x·0.004, z·0.004) > 0`, puts it on about half the
map in patches ~250 studs across: big enough to read as different ground rather than as noise.
`set_plate_steps` is now the switch for "allow it at all", and the mask decides where.

**The chamfer is tops-only** (§18.1 option 2), and it replaced the brick-on-backing. The four
top edges of a piece meet the piece's *own* side faces, so there is no second party to agree
with, which is the property every previous version lacked. The top quad is emitted coplanar on
all four edges — level neighbours meet in the groove between them, and at a drop the strip runs
down the piece's own side. The sides are emitted **square**: no bevel, nothing to negotiate.
That is the whole change, and it removes the backing quad as well.

### 17.25 The print pass, and the mask that was never a mask

Two things got measured in the same pass and one of them was a bug that had
been sitting in the "regional" plate steps since they were written.

**A mask whose wavelength exceeds the world is a constant.** The plate-step
mask ran `value_noise(x * 0.004, z * 0.004)`, which is a 250-stud patch — and
the whole test field is 160 studs, so the entire map sat inside ONE noise cell
and "about half the map" was, every time, all of it or none of it. The curved-
ground mask was written the same way (0.0035) and came out **100% curved** on
its first run, which is what exposed it. Both are 0.012–0.015 now, a 67–83
stud patch, and the probe measures the share rather than trusting the maths:
a mask that returns 0% or 100% fails the gate.

**Layer lines got the treatment they were missing.**

| | before | now |
|---|---|---|
| Studs | a `StandardMaterial3D` — **no print lines at all**, on the most numerous object in the world | `printed.gdshader`: layer bands on the sides, concentric **octagon** loops on top |
| Brick tops | a 45° raster in world space, running straight through piece seams as if the ground were one printed object | loops following the PIECE's outline, from `UV`/`UV2`, which the mesher already hands over |
| Stud tops | concentric **circles** | octagons — `PieceMeshes.SIDES` is 8, and circles were visibly the wrong shape |
| Relief | a dark hairline | the bead is a ridge: the normal leans along the direction the bead count grows in and back again, so it catches light |
| Groove | antialiased to one pixel | a third of a bead wide, because a printed surface is beads with shadow between them |

The relief normal needs the bead count to be CONTINUOUS — the lean comes from
its screen-space gradient, and `fract()` in front of that puts a cliff in the
gradient once a bead.

#### The three things that were wrong with it

**The lines crawled.** Reported as z-fighting, and it is the same symptom from
a different cause: a bead is 8.75 mm, and seen edge-on or past a few metres
more than one of them lands in a pixel. A pattern sampled below its own
frequency does not fade — it re-picks which beads hit which pixels on every
small camera move, so the surface looks like it is fighting itself. The
DISTANCE fade could never fix it, because a grazing angle compresses the beads
at any distance. What fixes it is filtering on `fwidth` of the bead count:
the pattern, and the relief with it, dissolves toward its own average as soon
as a bead approaches a pixel. Drawing detail you cannot resolve is worse than
drawing none.

**The top paths were loops all the way in.** Nested rectangles are four sets
of parallel lines with a mitre seam running out of every corner, and that is
exactly what they looked like — creases, not a path. A slicer walks the
outline two or three times and then rasters the middle, so that is what the
shader does now, with the raster in PIECE space and its diagonal hashed per
piece, so neighbouring bricks read as separately printed parts rather than as
one object with a grid drawn on it.

**Most of the shimmer was the SEAM, and it took an A/B to find.** The seam
was widened to a minimum of one pixel (`w = max(seam_width, aa)`) so it would
stay visible at range, and kept at full contrast. At a grazing angle `d`
changes fast along an edge, so which pixels that widened line landed in
shifted with every small camera move: the seam broke into DASHES that
crawled. Dimming it by its coverage helped and did not fix it.

The seam is now **analytic coverage** — how much of this pixel the band
`d < seam_width` actually covers, one clamp — with no widening at all. Sub-
pixel seams fall off by themselves.

Finding it needed captures that turn one thing off at a time:
`hf_curves_noprint`, `hf_curves_noseam`, `hf_curves_bare`, all from the same
camera. Print off with seams on still dashed; seams off with print on was
clean. Two suspects, one capture each, no argument.

`P` toggles the whole print pass in both test scenes, so "is that the layer
lines or the seams" is one keypress rather than an argument.

**The crawl that survived the filter was in the NORMALS, not the bands.**
Filtering the albedo stops it aliasing; filtering a normal the same way does
not, because a half-resolved ridge still swings the specular highlight a long
way for a small camera move — and a bright speckle moving over a surface
reads exactly like z-fighting. Normals have to give up earlier than colour,
so the relief fades with `resolved²`, and the roughness takes over what the
normal drops: a bead that is no longer resolved has not gone away, it is
sub-pixel roughness now, and saying so is what stops the highlight sparkling
where the ridges used to be. (This is Toksvig's argument in one line.)

**A 0.2 mm layer is one pixel, and the filter was right to bin it.** With the
filtering in place the print vanished almost everywhere, and that was correct:
0.2 mm at 1:43.75 is 8.75 mm, and at two metres on a 1152-wide frame that is
about one pixel. The pattern was never resolvable — it had only ever been
*visible* as the crawl. So the print itself got coarser: **0.46 mm layers
through a 0.55 mm nozzle**, which is 20 mm and 24 mm at this scale, twenty-one
layers a course. Still a real print, and one you can see.

The diagnosis took a red-channel dump of `resolved` to reach, after two
rounds of "the block must not be running". It was running; it was resolving
to nothing.

**The stud contact shadow fought the beads.** Two dark patterns multiplied
into the same pixels is noise, not detail, so the ink is damped by 70% of the
shadow. The ground was also drawing the painted stud's octagon paths
UNDERNEATH the geometry stud inside the near tier — two sets of loops in the
same pixels — and now only draws them where the painted stud is the one being
shown.

City bricks run it too, and they were the last surface in the world still
coming out of the mould smooth. One difference from the ground: the layer
axis is `UV.y`, the height WITHIN THE BLOCK, not a world or object height.
The chunk mesher emits vertices in world metres, so on a tower a hundred
metres out the bead count ran into the thousands and `fwidth` of it came back
larger than a bead — the pattern filtered itself away completely. Per-block
UV is precise, tumbles with a falling chunk, and restarts the layers at each
brick's own base, which is what a separately printed brick does anyway.

Debris runs the same shader. A brick that has just come off the ground is the
same printed plastic the ground is, and it was a matte `StandardMaterial3D`
with no lines at all. A single mesh carries no vertex colours, so the shader
takes a `tint` uniform and multiplies: a MultiMesh leaves it white and writes
COLOR per instance, a lone mesh leaves COLOR white and sets the tint.

`printed.gdshader` evaluates in OBJECT space, the ground shader in world
space, and the difference is not an oversight: a stud is one mesh drawn 8,300
times and a tumbling brick is that mesh with a different transform, so the
paths have to belong to the part. The ground never moves, and world space is
what keeps its layers continuous across a seam.

### 17.26c "Curves cause the z-fighting" — half true, and the half was useful

Turning curves off did clean the ground up, which pointed at the mixed
surface. Two real things came out of following it, and neither was overlapping
geometry:

**Curve-to-curve skirts were redundant geometry inside the surface.** Two
neighbouring curve cells SHARE their corner vertices, so their surfaces
already meet exactly — but a skirt was emitted anyway, sized from the
neighbour's COLUMN (`(tp + 1) × plate`), which is not where a curve is drawn.
Where that came out above the neighbour's real surface the skirt stood up
through it. A curve only needs a wall against BRICK. 4,308 triangles a field
removed with it (63.4k → 59.1k).

**A curve's pattern has nothing to reset on.** A piece restarts its nozzle
path every 0.35–1.4 m, so the near-Nyquist band — a bead about a pixel wide,
still at full contrast — is broken into short stretches and reads as texture.
Curved ground is one raster running unbroken across the whole field, and the
same band becomes a sheet of moiré that swims with the camera. Curves now
treat themselves as less resolvable than they are (`aa × 1.7`) and draw
fainter.

And the invariant that should have existed from the start: **every cell has
exactly one top surface**, `curve_cells + owned_cells == TILE²`, checked over
nine tiles. A cell drawn twice is z-fighting and a cell drawn by neither is a
hole, and neither shows up in a triangle count.

### 17.26b F8 is Godot's Stop

The curved-ground toggle was bound to F8, which is the editor's "stop the
running game" and is taken even while the game has focus — so the key that
was supposed to turn curves off quit instead. It is `C` now. Worth checking
any new binding against the editor's own list; F5, F6 and F7 are Play,
Play Scene and Pause in the editor, and only survive here because the game
window has focus and the editor does not treat those as global.

### 17.26 Scatter stopped standing on curved ground, and nothing said so

Turning curves on took scatter from 492 pieces a field to 146. Nothing
errored; the terrain simply had fewer boulders on it, which reads as "the
generator changed" rather than as a bug.

`footprint_ok` required every cell under a boulder to belong to a
`PIECE_BRICK`, and curved ground has no piece at all — so every tuft and
every pebble on a curve was refused. The test now accepts a curved cell as
well as a studded brick. Tiles and ramps still refuse, for the reasons they
always did: nothing clips to a smooth tile, and a ramp is not flat. Measured
back up to **719**.

The general shape of this: when a new surface bypasses a system, everything
that asked that system a question quietly gets "no". Studs were checked and
fixed in the same pass; scatter was not, because it asks through
`owner`/`pieces` rather than through the sample.

## 18. Planned, not built

### 18.1 Real chamfer geometry: the option that has not been tried

> **Built.** Option 2 (top edges only) is what the mesher now emits — see §17.24. Kept here for
> the reasoning.

Two are available, and the second is new:

1. **Brick on a backing** (§17.21) works and is probe-verified; it is off in the heightfield
   scene only because confidence in geometric chamfer was spent. `TerrainTile.bevel_enabled` is
   the flag.
2. **Top edges only.** Every artefact in six rounds came from a facet negotiating with a
   neighbour — a wall, another piece, or unmeshed space. A bevel on the piece's four TOP edges
   alone never touches another system: those edges meet the piece's own side faces, which the
   piece now draws itself (§17.23). Four strips per piece, ~8 triangles, no corner cases with
   anything outside the brick.

   On a floor seen at a grazing angle the top edge is the only one that reads anyway, which is
   where this began.

### 18.2 Water as bricks that never despawn

> **Built**, and with tall waves, a shore taper, submerged column collapse and swimming on top
> of it — Water.md §3.6, §3.7 and §7.2.

The proposal — 1x1 flat-topped bricks that bob, colour shifting to show the wave, white tops at
the crest, nothing ever created or destroyed — is **simpler than what is built and should
replace it**. `water.gdshader` currently packs pieces in the vertex shader, walks a cut lattice
and collapses non-origin instances, and that machinery exists only to make varied piece sizes.
Fixed 1x1 pieces delete all of it.

| | |
|---|---|
| Geometry | one 1x1 flat-topped brick, one MultiMesh, instance count fixed forever |
| Motion | Y from the shared wave function, snapped to a brick step, per-row stop-motion hold (Water §3.4) |
| Waves | **colour, not geometry** — tint by height above the mean, white at the crest. A crest reads as a moving band of pale bricks, which is the brick-film look and costs one lerp |
| Despawn | never. A piece below its neighbours is hidden by their columns; at the shore it scales to zero (§3.4) |
| Surf | white tops where `height > threshold`, which also gives foam for free |

Keeps: the one wave function in `BrickWave` (D9), the seabed texture for shore culling and
absorption, the brick-step quantisation. Deletes: the GPU packer, the cut lattice in the shader,
the bonding logic.

### 18.3 Plastic, and materials later

Flat filament colour with `roughness 0.9` is why it reads as matte card. Plastic needs three
things, none of them textures:

1. **Roughness 0.35-0.45** and a real specular. ABS is glossy.
2. **A tight specular highlight that MOVES** — that is what says "hard shiny surface", and it is
   why the chamfer matters: a bevel catches a moving highlight along every edge.
3. **Slight subsurface/backlight tint.** Thin ABS glows at the edges. `SSS` or a cheap rim term.

Materials become a **material id per block**, not a texture per block, driving a small table:

| | roughness | specular | rim | grain |
|---|---|---|---|---|
| ABS / PLA | 0.40 | 0.5 | slight | layer lines |
| Wood-fill | 0.85 | 0.1 | none | layer lines + long grain streaks |
| Metal-fill | 0.30 | 0.9, metallic | none | layer lines, coarser |
| TPU | 0.55 | 0.4 | strong | layer lines, softer |

One `uint8` per block, one branch in the shader. Filament colour already works this way, so the
material id sits beside it.

### 18.4 Layer lines and print paths: procedural, with one authored exception

**Procedural, and it is not close.** Spec §2 already says so and the reasons hold:

- Layer lines are a function of `print_axis` and world position. A texture would have to be
  unwrapped per part, at a density that changes with part size, and would swim on debris as it
  tumbles. The shader evaluates it in object space and it tumbles correctly for free.
- Every part is a different size. A brick, a 2x6, a stud and a boulder share one procedural
  rule and would need four textures.
- Spec §2's whole memory argument: no texture memory for parts.

Three effects, all from the same object-space coordinate:

1. **Layer lines** — bands perpendicular to `print_axis`, ~0.2 mm at print scale. Fade with
   `fwidth` like the seam already does.
2. **Top-surface print paths** — the nozzle's infill. Concentric rings on a stud (which is
   exactly how a printer does a small cylinder) and a raster or gyroid on a flat top. A polar
   coordinate around the stud centre for rings, a rotated stripe for infill, chosen by whether
   the fragment is inside a stud disc — and the shader already computes that for the dome.
3. **The seam line** — a printer's layer-change seam is a faint vertical scar. One per part, at
   a hashed angle.

**The one authored case:** a part whose print path is genuinely irregular, like a sculpted
outcrop. Those are prefabs (§6.6), and a prefab can carry a texture if it earns one. Nothing on
the procedural path should.

### 18.5 Smooth heightfield AND bricks — BUILT

> **Built, and OFF.** `BrickTerrain.set_smooth_terrain` is off everywhere,
> including in `heightfield_test`, where `C` turns it on. What follows is the
> design; what differed in the building is at the end.
>
> It works — regional, genuinely curved, studs and tiles standing on it — and
> it is not what the game is made of. Curved ground has no PIECES in it, so
> wherever it goes the packed 2x4s and the smooth tiles go with it, and the
> ground stops reading as laid brick. That is the whole look. It stays as a
> thing the generator CAN do, for dunes, a moor, a golf course, whatever
> later wants ground that is not built out of bricks.

#### The design

A smooth curved surface with studs standing on the flat parts is not an alternative to the brick
mesher; it is **the same data with a different top face**. Both read `tp` per column.

- **Smooth**: emit one vertex per column at its exact height and let the GPU interpolate. No
  packing, no terraces, no side faces. Studs stay exactly as they are — `stud_at` already asks
  "are my four neighbours at my height", which on a smooth field means "am I on a flat spot".
- **Bricks**: what exists now.

So it is a per-biome or per-region switch, not a fork: sand dunes and hills smooth, built ground
and cliffs bricked, and the stud layer identical over both. The honest cost is that collision
needs a `HeightMapShape3D` for smooth regions instead of merged boxes — twenty lines, and it was
the original plan in §6 before the terraces existed.

#### Driven by biome AND steepness — yes, and steepness is the cheaper half

The switch wants to be a **per-column float**, `smooth01`, not a bool, and it takes both inputs:

```
smooth01 = clamp(biome_smoothness + steepness_bias · slope, 0, 1)
```

* **Steepness** is free. `top_plate` is already sampled for the four neighbours of every column
  (that is what `plate[]` is), so `slope = max |Δtp|` costs nothing new. Steep ground going
  *bricked* is the useful direction: a cliff made of stacked courses looks built, and a smooth
  one at 45° is where a heightfield looks most like a heightfield. Flat ground can go either way
  — which is what the biome term decides.
* **Biome** is one more low-frequency noise field, exactly like the plate-step mask that was
  just built, so the machinery exists. Dunes and moor smooth, quarry and built ground bricked.

Two things have to be true for a mixed field not to crack open:

1. **The boundary has to be a seam, not a gap.** A smooth column adjacent to a bricked one meets
   a vertical face of up to one brick. The bricked side must draw that face — the same test the
   mesher already runs for "my neighbour is lower", with `tp` compared against the *smooth*
   height rather than the quantised one.
2. **`smooth01` must be hysteretic or quantised per region**, not thresholded per column, or
   the boundary dances between neighbours and every frame of a moving camera re-seams. Snapping
   the decision to a coarse grid (say 8 studs) is the cheap fix, and it matches how the plate
   mask already works.

The plate-step mask (§17.24) is the same shape of decision at a third of the ambition, so it is
the thing to generalise: mask → region field, bool → float, one quantiser → two surfaces.

#### One thing or the other, over an area you can walk across

The decision started per column and so did every test in it — which meant the
steepness test, whose input varies fast, speckled. Measured: slope median
0.17, p90 0.50, so a 0.30 threshold rejected about a third of the columns
INSIDE a curved patch, and each rejection came back as a single brick standing
in the middle of smooth ground. From a low camera the ground read as brick
slabs half-buried in a smooth field, which is neither of the two things it is
supposed to be.

Which tests may be per column is the whole answer:

| test | scope | why |
|---|---|---|
| a step over two plates | **column** | a wall is a wall whatever is around it |
| steepness | **region**, 8 studs | its input varies fast; per column it speckles |
| biome | **column** | a smooth field, so its contour IS the organic edge |

Only the tests that can flip between neighbours had to become regional. The
biome boundary stays per column, which is what keeps the edge between smooth
ground and laid brick from being a rectangle.

Measured over 19,600 columns after the change: **zero** lone bricks inside
curved ground and **zero** lone curves inside brick. That is the number worth
keeping — not the share, which moved to 54% as a side effect of the looser
steepness gate, but the count of cells that disagree with everything around
them. A region test that still speckles has not been made regional.

Curved ground also lays some of its flat patches SMOOTH — the same one in five
the packer tiles a brick floor with, off the same hash, so a curve gets the
mix of studded and smooth ground that brick already has. A curve has no
pieces, so a tile there is simply a cell that takes no stud.

#### The curve has to come from the UNQUANTISED field

The first version averaged the four `tp` values round a corner. `tp` IS the
staircase, and the mean of four steps is another step with a bevel on it — so
on gentle plate-quantised ground, where the four columns usually agree, the
"curve" was the same flat quad the bricks would have drawn. The ground lost
its 2x4s and its smooth tiles wherever curves went and gained nothing visible
in exchange. Turning curves on made the terrain worse and no curve was
findable anywhere, which is exactly how it was reported.

A corner is now the mean of `raw_plate` at its four columns — the surface
before the floor — plus half a plate, so the curve runs through the middle of
the staircase it replaces rather than along its top. Against brick it still
snaps to the brick's exact top, which is what keeps the seam shut.

Everything that STANDS on a curve moved with it. A stud or a boulder at
`(tp + 1) × plate` floats or sinks by up to half a plate once the curve stops
agreeing with the column, so studs, scatter and the collision box all read
`cell_surface()`, the mean of the cell's four drawn corners. One helper, four
callers, no second opinion about where the ground is.

`BrickTerrain.surface_raw(x, z)` exposes the continuous surface, because
nothing outside the mesher could otherwise predict where a curve is — the
probe included, which is how this got measured.

The share came down with it: bias 0.35 instead of 0.0, so curves are ~35–40%
of the map rather than 63%. Curved ground has no PIECES in it; wherever it
goes, the packed 2x4s and the smooth tiles go with it. Curves are the odd
hillside, not the default surface.

#### What differed in the building

* **Steepness has to be measured on the UNQUANTISED surface.** On plate-quantised ground every
  slope between 0.1 and 0.9 plates a stud measures as exactly one plate, so a steepness test on
  `top_plate` can only ever answer "1 or 0" and does nothing. `Field::raw_plate` returns the
  surface before the floor, and the test is a central difference on that. Measured on the test
  field: median 0.17 plates a stud, p90 0.50, max 0.67 — so the threshold is 0.30, which keeps
  the flats and hands the valley sides back to the bricks.
* **...and on the quantised one as well.** A column can be gentle and still sit where the
  plate-step mask changes quantisation, and the drawn step there is a whole brick. The probe
  found a 3-plate cliff under a curve on its first run. Both tests now apply.
* **It is still a bool, not the float the plan asked for.** `smooth01` as a blend needs the two
  surfaces to be interpolable and they are not — one has side walls. The decision is per column
  and the seam is handled instead of avoided.
* **The seam is handled by giving the curve the brick's exact height.** A corner vertex is the
  mean of the four columns that meet there, unless one of them is bricked, in which case it takes
  that brick's top exactly. The curve then lands ON the brick's top edge rather than near it.
  Where the neighbouring column is lower, the curve draws its own skirt down to it — the same
  rule the brick mesher already follows, so the two surfaces meet without either knowing much
  about the other.
* **Studs needed no change at all**, which was the claim: `plate` already means "my four
  neighbours are at my exact height", and on a curve that is "I am on a flat spot". A flat cell's
  four corners are all at its own height, so a stud sits exactly on the surface.
* **UV2 = (0, 0) means "not a piece"** to the shader: no seam outline, and the nozzle rasters in
  world space instead of walking a perimeter, because a curve is not a moulded part with edges.
  Without that test `mod(UV, 0)` takes the whole surface to NaN.
* **Collision follows the curve, and stays boxes.** A curved cell's box top is the mean of its
  four drawn corners, not its column — `HeightMapShape3D` was the plan, but a heightmap cannot
  hold the vertical walls the bricked half of the same tile needs, and two shape types over one
  tile is worse than one. The trick that keeps it affordable is **quantising the box top to a
  quarter plate**: the greedy merge joins cells of EQUAL height, continuous heights are never
  equal, and an unquantised curve hands back one box a cell — 1,024 a tile, which is the 813 ms
  scene build that merge exists to prevent. Measured: **0.018 m off the drawn surface** (was
  0.07 against the column), 209 boxes on a mixed tile.

  That probe check has now measured the feature instead of the defect twice: first comparing the
  box against the COLUMN (0.175 m), then still rebuilding the surface out of `surface_plate`
  after the curve moved to the unquantised field (0.28 m). A mirror of a calculation is a second
  implementation and goes stale exactly like one.

  The first version of that probe check compared the box against the COLUMN and reported 0.175 m
  of error. It was measuring the curve doing its job. A check needs the right reference or it
  fails the feature instead of the bug.

Measured, `heightfield_test` at seed 20260921: 66% of columns curved, 2,769 pieces where
all-brick was 9,186, 65.9k triangles against 34.2k. **Curves cost about twice the triangles of
packed brick** — one quad a cell against one quad a 2x4 — which is the price of the look and the
reason it is a region and not the whole map.

---

## 19. View distance, and what it actually costs

Measured, not guessed. `heightfield_test.tscn -- --bench --tiles=N` turns one
layer off at a time and reports drawn triangles, draw calls and mean frame
time with vsync disabled. Debug build, Radeon iGPU, 1152x648.

| field | square | built | baked | drawn tris | calls | GPU frame |
|---|---|---|---|---|---|---|
| 9x9 | 101 m | 318 ms | 26 ms | 518k | 161 | 3.2 ms |
| 13x13 | 146 m | 739 ms | 57 ms | 636k | 244 | 3.8 ms |
| 21x21 | 235 m | 1,609 ms | 146 ms | 884k | 451 | 4.1 ms |
| 31x31 | 347 m | 3,599 ms | 308 ms | 1.20M | 707 | 5.5 ms |

**The frame is not the problem and never was.** Six times the view distance
costs 1.7x the frame time. A 347 m field draws in 5.5 ms on an integrated
GPU in a debug build; 60 fps allows 16.7 and 144 fps allows 6.9.

### 19.1 What the frame is made of

At 13x13, turning layers off one at a time:

| layer | tris | cost |
|---|---|---|
| water | 264k | 1.2 ms |
| studs and scatter | 106k | 0.9 ms |
| shadow pass | 183k | 0.5 ms |
| terrain surface | 82k | the rest |

**Water is the biggest single consumer of triangles in the world** — 26,450
pieces at ten triangles each, regardless of field size, because it follows the
camera. The terrain mesh is 82k for a 146 m square: about 9 triangles a square
metre of ground, which is nothing.

So: no, the terrain does not use too many triangles. If anything it is
under-drawn — there is room for the real chamfer geometry (§18.1) near the
camera.

### 19.2 The thing that actually limits view distance is BUILD time

At 21x21 the field took **4.2 seconds** to build, and the C++ that does the
real work — sample, pack, mesh, merge the collider — was 100% of one core
while fifteen others idled.

Two changes, both measured:

* **Bake in parallel.** `build_tile` only reads the field and returns fresh
  arrays, so a `WorkerThreadPool` group task can run every tile at once.
  4,156 ms → **146 ms** at 21x21 on 16 threads. Node assembly stays on the
  main thread, because it has to.
* **Collision through the physics server, not nodes.** A `CollisionShape3D`
  per merged box was 200-300 nodes a tile, ~100,000 across a 21x21 field.
  One server body a tile with shared box shapes: total build 3,394 ms →
  **1,609 ms**. `brick_sandbox.gd` had done this since M3; terrain never did.

Box shapes are shared by size, and freed when the last tile leaves the tree —
Jolt reported 305 leaked shapes the first time, because a static cache of RIDs
has no owner.

A ray-cast check runs with the bench (40 rays, 40 hits, worst 0.14 m off the
surface — one plate, which is the merge doing its job). A collider with no
node behind it is invisible to the scene tree, so it needs a test that is not
"look at the remote".

### 19.3 To go further

In the order the numbers justify:

1. **Stream tiles instead of building them all** — 1.6 s at startup is a
   loading screen, and it is all main-thread node assembly (ArrayMesh upload,
   MultiMesh buffers). Building a ring of tiles a frame as the camera moves
   turns it into nothing.
2. **A coarse tier per tile.** Draw calls grow linearly with the field (161 at
   101 m, 707 at 347 m). One merged quad per 4x4 block for tiles past ~120 m
   would cut both calls and triangles by an order of magnitude, and at that
   range the pieces are sub-pixel anyway — the same argument the stud tiers
   already make.
3. **Water tier 2.** The sea is a fixed 26,450 pieces whatever the view
   distance; past the 80 m ring there is nothing at all.

Budgets worth holding to, for a stylised game on mid hardware: **1-2M
triangles and under ~2,000 draw calls a frame**, with the CPU side under
~4 ms. Everything above sits inside that today.

### 19.4 The far tier, built

`BrickTerrain::build_coarse(tx0, tz0, span, step)` — a block of `span x span`
tiles as ONE mesh, sampling the surface every `step` studs. No packing, no
pieces, no studs, no scatter, no collider, and it does not cast shadows: the
shadow of a hill 300 m away lands on ground nobody can see.

It is deliberately not the same mesher. Everything the near tier exists for —
the seam around a 2x4, the nozzle path, the stud — is under a pixel out there.

Two details decide whether it holds together:

* **Sample the CORNERS, not cell middles.** Two neighbouring blocks then read
  the same number on their shared edge and cannot disagree about where the
  ground is.
* **A cell takes the MAX of its four corners.** A coarse cell stands in for up
  to `step²` columns and the tallest is what the silhouette should follow;
  averaging sinks the mesh into the hills and the near tier pokes through the
  join.

**The ring.** A coarse block is kept only if none of its tiles are inside the
detailed square — half a block would draw over real ground — and skipping
whole blocks left a band up to `FAR_SPAN` tiles wide with nothing in it. The
first capture had a 45 m black moat around the detailed ground. Whatever the
block lattice misses now gets a one-tile coarse mesh.

#### One coarse level does not scale, and the numbers say so plainly

At a fixed 1.4 m sample: 560 m held 2.9M triangles, 1.12 km held 10.7M, and
2.24 km held **40.9M and drew at 80 ms**. Constant density over a disc is
quadratic in the radius, and no amount of culling fixes quadratic.

So the tier **cascades**: every doubling of the radius doubles the block and
doubles the sample spacing. A block then always holds the same
`(span x TILE / step)²` cells, so each ring costs what the one inside it
costs, and the whole tier is linear in the NUMBER of rings — logarithmic in
distance.

Placement is a greedy fill, not a lattice sweep: walk every uncovered tile,
ask which ring its radius puts it in, lay the LARGEST aligned block that
fits, halving until one does. Two attempts at "sweep each ring and skip
blocks that overlap" both left bands a whole block wide — a tile exactly on a
ring boundary belongs to neither sweep — and 2,500 one-tile fills with them.
A fill that terminates at span 1 cannot leave a hole.

Two details the measurements forced:

* **Cap the levels at what the reach needs.** Rounding a 560 m field up to
  the six-level lattice drew 1.4 km of ground nobody asked for.
* **Round the reach up to the coarsest span in use.** A block must fit
  entirely inside the reach or the fill drops a level, so a reach off the
  lattice frays the whole rim to one-tile blocks — 3,212 of them at 9 km.

| view | held | drawn | calls | GPU frame | build |
|---|---|---|---|---|---|
| 56 m, no far tier | — | 425k | 91 | 3.0 ms | 116 ms |
| 560 m (**default**) | 988k | 559k | 274 | 2.9 ms | 346 ms |
| 2.24 km | 1.91M | 882k | 439 | 4.3 ms | 718 ms |
| 8.96 km | 3.62M | 1.40M | 1,157 | 6.4 ms | 8,890 ms |

**Ten times the view distance for nothing**, and 160 times it for about twice
the frame. The near tier is untouched throughout — the ground you can walk on
is still packed 2x4s with studs and a collider.

The wall is no longer triangles. At 9 km it is **build time** (8.9 s, which
streaming fixes) and **draw calls** (1,157, which merging whole rings into one
mesh fixes). Both are ordinary work; the quadratic was not.

`FAR_TILES` defaults to 50 — 560 m — and `-- --far=N` overrides it. Water is
off by default in this scene: the sea is a fixed 26,450 pieces and ~264k
triangles whatever the terrain does, and it dominates a measurement it is not
the subject of.

### 19.5 Against the city, which is the half that actually costs

The same bench, `city.tscn -- --bench --buildings=N`, from three viewpoints.
Building shells, nothing materialised into live bricks yet.

| | drawn | calls | GPU frame |
|---|---|---|---|
| city, 22 buildings | 164k | 118 | 1.4 ms |
| big_city, 22 | 957k | 179 | 3.0 ms |
| big_city, 60 | 686k | 229 | 3.3 ms |
| big_city, 150 | **3.34M** | 437 | **10.0 ms** |
| terrain, 560 m | 1.22M | 352 | 6.8 ms |

Worst viewpoint each, debug build, Radeon iGPU, 1152x648.

> **Correction (2026-09-29, Docs/Impostors.md §7.1).** These city rows were not shells. The bench
> sampled while the streamer was still settling, and its street-level viewpoint promoted the
> buildings beside it into live bricks at whatever tick it got to them. Most of the millions were
> those bricks, drawn again in every shadow cascade. The bench now settles each viewpoint and does
> not promote (`--with-bricks` puts that back). Shells only, big_city, 150 buildings, worst
> viewpoint: **~250–300k tris, ~100 calls**. With three brick buildings beside the camera: 2.1M
> tris, 145 calls after the shadow LOD. So the conclusion below still holds, but for a different
> reason: the city is the expensive half because of **materialised bricks**, not shells.

**The city is the expensive half and terrain is not close.** 150 buildings
cost 3.3M triangles where a 560 m terrain costs 1.2M, and the city's number
climbs with building count while the terrain's is nearly flat in view
distance once the far tier exists.

Added together — and they do add, they are the same frame — a 150-building
city on 560 m of ground is roughly **4.5M triangles, ~790 draw calls, ~17 ms**
in a DEBUG build. That is the 60 fps line exactly, before:

* a release build, which is typically 1.5-2x on the CPU side
* materialised buildings, which replace shells with real bricks and cost more
* the water, which is another 264k and 1.2 ms
* a GPU that is not integrated

So the shape of the budget is clear: **terrain can have its view distance and
the city cannot have unlimited buildings.** The next lever is not more terrain
LOD, it is building impostors past ~150 m, which `SHELL_RANGE` already half
implements.

### 19.6 Streaming, for a world that has edges

This terrain is an **authored size per world**, not an infinite field, so the
streamer is not a chunk loader and does not pretend to be one. The coarse tier
covers the whole world and is built once. What streams is the near tier, which
is the expensive half: packed pieces, studs, scatter and a collider.

`TerrainStreamer` keeps a square of detailed tiles around the camera, drops
what falls behind, and never builds past `world_half` — the world ends and the
code knows where.

Three rules, and the middle one is the point:

1. **Bake on worker threads.** `build_tile` only reads the field.
2. **Assemble on the main thread under a TIME BUDGET.** Node creation and mesh
   upload cannot leave the main thread, so the only lever is how much of it
   happens in one frame.
3. **Drop with hysteresis** — `keep_radius` two tiles beyond `near_radius`, or
   walking a boundary rebuilds the same tile every step.

#### A budget cannot split one piece of work, so the pieces had to get smaller

The first version budgeted 3 ms a frame and still hitched at 16.5 ms, because
the budget is only checked BETWEEN tiles and one tile took **54 ms**. Measured
by phase:

| phase | worst |
|---|---|
| surface mesh | 0.5 ms |
| studs and scatter (3 MultiMesh uploads) | 4.2 ms |
| collider (200-300 boxes through the server) | 5.6 ms |

So a tile is three phases now, taken a frame at a time, and the collider is
only built within `collide_radius` — you cannot stand on a tile four away, and
it is the most expensive phase and the only one nobody can see.

Sprinting at 14 m/s across six tiles: **worst frame 11.2 ms**, 30 tiles built
and 20 dropped, nothing above the 16.7 ms a 60 fps frame allows.

Then the collider spiked to 18.9 ms on its own at a wider detail radius, for
the same reason one tile did: a budget checked BETWEEN units of work cannot
help with one big unit. So the collider goes in **32 boxes at a time** across
frames, and the budget came down to 1.5 ms.

#### Shadows are the other half of what a detail radius costs

Pushing full detail from 56 m to 145 m took the frame from 3.0 ms to 9.1 —
and 6.5 of that was the SHADOW PASS: 290k triangles and 167 of the 429 draw
calls. A brick terrace a hundred metres away casts almost nothing anyone can
see on ground this gentle, so tiles past `shadow_radius` (3, about 34 m) do
not cast at all.

Settled, with detail at 101 m and the coarse tier at 560 m:

| | |
|---|---|
| steady frame | 5.7 ms |
| sprinting at 14 m/s, worst frame | **9.8 ms** |
| worst single phase | 3.7 ms (instances), 1.5 ms (collider) |
| detail resident | ~81 tiles |

#### "The smooth terrain is on and C will not turn it off"

It was not. Curves default to off, `C` toggles them correctly, and a direct
measurement says so: 0 curve cells a tile with the default, 992 with curves
on, 0 again when turned back off.

What was being seen is the COARSE TIER, which at a 56 m detail radius began
close enough to walk up to — and coarse ground is exactly what smooth ground
looks like. `C` has no effect on it, correctly, because it is LOD and not a
generator setting.

The fix was not a toggle: full detail now reaches **101 m**, which the shadow
and collider work above paid for. Worth remembering as a diagnosis — when two
systems can produce the same appearance, the report will name whichever one
has a button.

### 19.7 The coarse tier has to know where the detail IS

Reported as "the LOD levels never remove even when the player goes near". They
did not, and the reason is that the coarse tier was built once with a hole
where the detail happened to start, while the detail moved. Everywhere the
detail went after that, it streamed in ON TOP of coarse ground — two surfaces
in the same place, the coarse one poking through wherever its max-of-cell
height beat the real surface.

Three attempts, because each fix exposed the next assumption:

1. **Hole at build time.** The detail moves, the hole does not: walking away
   from the origin left a black pit behind.
2. **Build everywhere, hide what the detail region covers.** The region fills
   at a couple of tiles a frame, so hiding against WANTED tiles opened a pit
   the size of the detail square every time the camera jumped.
3. **Hide only where every tile of a block is BUILT.** Correct, and it needs
   the two tiers on one lattice: the streamer snaps its region out to the
   coarse tier's smallest block (4 tiles), so a block is covered or it is
   not. Unaligned, a half-covered block can neither be hidden (hole) nor kept
   (poke-through).

Only the smallest blocks are ever tested; anything bigger is further out than
the detail reaches, so a 128-tile block never walks its tiles.

The alignment made streaming cheaper as well: the resident region changes in
whole blocks instead of one row at a time, and the worst frame while sprinting
went from 9.8 ms to 6.6.

### 19.8 Elevation, and one height function

The relief was `fbm x 7 bricks` — **2.9 m of total range**, the whole world
inside a two-storey building, which is why every view looked like a textured
plain. It is three octaves now:

| octave | wavelength | amplitude |
|---|---|---|
| landform | ~400 studs (140 m) | 90 bricks (38 m) |
| relief | ~100 studs (35 m) | 9 bricks |
| detail | ~29 studs (10 m) | 1.5 bricks |

Measured over 1.7 km: **48.7 m of range**, median slope 0.25, p90 0.47, max
0.90. A tile costs the same as before (328 pieces, 1,224 triangles), because
the mesher does not care how high the ground is.

`raw_plate` and `top_plate` were two copies of the same expression and drifted
apart the moment the relief changed; `top_plate` now quantises `raw_plate`.
The material bands moved with it — at 7 bricks they were tuned for a world
eight courses tall, and with a landform octave that put stone on everything.

Two probe gates failed on the new world and **both were measuring the world's
shape, not a defect**: the tile share (a piece takes studs only where the
ground is flat, so more relief necessarily means more smooth ground — 56%, and
the gate said 55%) and the shore taper (it fixed the sea at 1.9 m, which the
new terrain is entirely above, so it reported "the sea gets no swell" about a
world with no sea in it — it picks a level from the sampled ground now).

### 19.9 Baked sun shadows, because the ground does not move

The ground is a static heightfield, so which of it the sun reaches is a
property of the world and not of the frame. `set_sun_direction` makes the
mesher march the field along the sun — 24 samples a piece, at build time, on
worker threads — and darken what the sun cannot see. The terrain then stops
casting into the shadow map altogether.

| | frame | calls |
|---|---|---|
| terrain casting (radius 3) | 4.9 ms | 347 |
| baked, terrain never casts | **3.3 ms** | 285 |

and the worst frame while sprinting went from 15.6 ms to **5.8**.

Everything else was already audited off: studs and scatter never cast (they
have a painted contact shadow instead, §7.4), the coarse tier never casts,
water never casts. The sun still has a shadow map — for everything that stands
ON the ground, which is all of the city.

**The sun had to come down to 30 degrees for any of it to matter.** Measured
against this terrain: at 44 degrees, the angle the scene had, NOTHING is in
shadow, because the steepest ground is a 42-degree slope. At 30 it is 8% of
columns and at 12 it is 26%. A feature that bakes a shadow nothing casts is
indistinguishable from a broken one, and the only way to tell was to count.

### 19.10 Sea level is a property of the terrain, not a constant

Raising the relief broke the water in both scenes and neither said so: the
heightfield scene had sea level 2.8 m against ground with a 3.4 m median, and
the volumetric one reported a seabed **15 m above** its sea. A capture aimed
at "the deepest water" put the camera inside a hill.

A metre value is a guess about a generator. The number that survives a change
of relief is **how much of the world is under water**, so `TerrainWorld.
sea_level_for(half_tiles, drowned)` samples the ground on a coarse lattice and
takes that percentile. 30% drowned gives a coast on any seed.

It has to be sampled over the ground the scene actually BUILDS. The volumetric
scene builds a fixed 5x5 tiles and never streams; a sea derived from a wider
sample left it dry, because the wider sample included valleys it does not
contain.

And the captures that hunt for water now say so when there is none, instead of
photographing the inside of a hill.

### 19.11 Coarsest first, merged rings, and a gate that finally watches

**Place the big blocks first.** A block per uncovered tile, at that tile's own
level, fragments: a big block is refused whenever any of its cells was already
taken, so the scan produced 471 blocks where the ring arithmetic says 140.
Laying the coarsest first and letting the fine ones fill around them is the
same greedy idea with the order that works — 471 blocks became 195, and at
4.5 km 2,488 became 339.

**Merge each ring into one mesh.** Only the smallest blocks are ever hidden
under detail, so everything bigger can share a mesh. Draw calls at 4.5 km:
**832 → 371**, frame 11.1 → 6.9 ms.

A merged block cannot be removed on its own, which matters because of the next
part: retiring one rebuilds its ring. A ring is ~48 blocks and re-bakes in
parallel, so it costs a few milliseconds and happens only when the detail
walks somewhere new.

**The detail can be ANYWHERE, so any block may need splitting.** The rings are
laid out from the origin, so a block far out is 16, 64 or 128 tiles across and
the detail square is 12: walking far from the origin lands inside a block too
big to hide, and both tiers draw the same ground. A quadtree split fixes it and
is cheap because only the children that touch the detail recurse — a 128-tile
block becomes about fifteen smaller ones, not a thousand.

#### The gate

`coverage: N tiles, N drawn twice, N drawn by nothing`, from four camera
positions including one at the world's rim. A tile drawn twice is z-fighting; a
tile drawn by neither is a hole; neither shows up in a triangle count.

It failed on its first run — 129 doubles, 21 holes — and every one was real:

* the coarse fill still skipped the ORIGIN square, from before the detail
  streamed, so those tiles were drawn by nothing once the camera left
* the streamer kept tiles two beyond its region, off the block lattice, so
  they drew on top of coarse ground no block could be hidden against
* blocks straddling the WORLD EDGE waited forever for tiles outside the world
  to be built, and stayed visible under real detail

Three bugs that had each been looked at and pronounced fine.

### 19.12 Authored pads, and buildings that stand on them

The terrain is an authored size with authored buildings, so a building site is
a decision rather than a noise function. `BrickTerrain.add_pad(x, z, radius,
skirt, height)` flattens the field to one height inside `radius` studs and
eases back over `skirt` more.

It goes in the **field**, not in the mesher, and that is the whole point:
the detailed tier, the coarse tier, the collider, the stud test, the seabed
texture and the buoyancy solver all read the same surface and agree about the
pad without being told it exists. Flattening ground under a building after the
fact is what produces a building with a cliff behind it.

Chebyshev distance, not Euclidean: a building is a rectangle on a square
lattice, and a round pad under a square building leaves the corners hanging.

`TerrainWorld.SITES` holds this world's five sites and `heightfield_test`
stands a blocky shell on each. That is the terrain half of the contract — the
real buildings are `city_scene.gd`, with their own streaming, damage and
rooms.

### 19.13 Closing out: materials, the volumetric bench, and building shadows

**The material table.** Colour says which filament; it says nothing about
what the thing is MADE of. Two spools of the same grey behave nothing alike —
filled plastics are rough and dead, polished ABS is glossy, TPU is soft — and
none of that lives in the albedo.

The mesher writes the terrain material per vertex into **ARRAY_CUSTOM0.r**,
one byte, and the shader indexes a table of (roughness, specular, rim)
multipliers with it. Grass and dirt go matte, sand brightens slightly, road
is the glossiest ground there is. One draw call, one material, no second
surface.

Two things that cost a build each:

* A custom channel is ignored unless the surface DECLARES its format, so
  `ARRAY_CUSTOM_RGBA8_UNORM << ARRAY_FORMAT_CUSTOM0_SHIFT` travels with every
  terrain upload — the tiles, the coarse blocks and the merged rings.
* `CUSTOM0` does not exist in a fragment shader. It is read in the vertex
  stage and passed as a **flat** varying, which is also what it wants: a
  material index has no business being interpolated, and half-stone is not a
  material.

**The volumetric bench keeps its fixed field** and gets the parallel bake
instead. It is the DESTRUCTION fixture: `_tile_at` has to hold every tile for
a carve to find what it dirtied, and 56 m is the point of it. What it did not
need was one core building tiles in series.

**Buildings cast, ground does not.** The ground bakes its own sun shadow
(§19.9) and never enters the shadow map; the buildings standing on it are a
handful of meshes and cast normally. The first capture of a site reported "no
shadows" — the camera was standing on the wrong side of the building. The
capture stands DOWN-SUN now, which is the only place a shadow can be seen
from.

One HUD bug fell out of the same shot: the curved-ground percentage divided
by a fixed 5x5 field that stopped existing when streaming went in, and read
122%.

---

### 19.14 Smooth far ground, from LOD 2 out

The coarse tier drew every sample as a flat-topped column with walls down to
its neighbours: four to six triangles a sample, for steps a brick high that
are under a pixel past ~150 m. It was the largest single cost in the scene.

Blocks sampled every 8 studs or coarser (`BrickTerrain.set_coarse_smooth_step`,
default 8) are now built SMOOTH: one vertex a sample, heights at the samples,
a colour, a material and a baked sun a vertex, and a skirt round the edge.
Neighbouring blocks sample the same corners on their shared edge and meet
exactly; the skirt hides the join against a blocky neighbour, whose tops stand
at the max of a cell.

That is ring 1 and out (LOD 2+, ~180 m). Ring 0 and every block split to sit
next to the detail stay blocky, so the ground the eye can resolve is still
laid brick. Measured: the heightfield far tier 1,152k → 807k triangles; the
city's 643k → 426k.

### 19.15 LOD borders: the farther level sits lower, the nearer one hangs a skirt

The water's rule, applied to the ground. Blocky coarse cells took the MAX of
their four corners, so at every border the far tier stood ABOVE the detailed
ground: a step up into the next level, and where the step was more than the
one brick its edge wall dropped, a slit through to the water or the sky.

  * coarse cells take the MIN of their corners — at or below the real ground;
  * every LOD piece's outer edge hangs 4 bricks (1.68 m, `EDGE_SKIRT_M`): the
    detailed tiles gain a one-stud-a-quad skirt round their edge (hidden
    inside the neighbour's ground when the neighbour is detail too), the
    blocky blocks' edge walls and the smooth blocks' skirts go that deep.

Seen with the dev menu's Freeze LOD at the detail/LOD 1 and LOD 1/LOD 2
borders: no slit, no step up. Cost: ~5k triangles more drawn in the bench
view (541k → 546k).

### 19.16 The borders that were still open

Two more, after 19.15:

  * **The detail could border LOD 2 directly.** A far block is split to
    LOD 1 only where it touches the detail square, so a block just outside
    it stayed a 16-tile smooth block — a coarse, much lower surface right
    against the detail edge. The split region is now the detail square grown
    by one block lattice step, so the detail is always ringed by LOD 1.
  * **Skirts read as gaps.** An edge skirt is only SEEN where the next level
    is lower, and lit as a vertical wall it was a dark band. Edge skirts
    (detail tiles, blocky block edges, smooth block skirts) are now lit like
    the ground they hang from. Inner steps of a blocky block are still walls.

The dev menu fits its window now (it scrolls; it ran off shorter screens).

### 19.17 Coarse skirts deep enough for the next ring, from both sides

Blocky-to-smooth and smooth-to-smooth borders still gapped on steep ground:
the next ring out samples twice as far apart, and on a hill two samples that
far apart differ by metres, not the fixed 1.68 m the skirt hung. A coarse
block's edge skirt is now `max(1.68 m, 2 x its sample spacing)` — 2.8 m on
LOD 1, 5.6 m on LOD 2, 11.2 m on LOD 3 — and drawn from both sides, since a
border is looked at from either level.

Cost, bench view: far tier 807k → 1,246k triangles built, 546k → 657k drawn,
3.3 → 3.6 ms. Most of it is 19.16's LOD 1 ring round the detail (more blocky
blocks); the skirts are under 100k of it.

### 19.18 Fewer triangles: merged blocky faces, one-sided skirts, a smaller LOD 1 ring

* **Merged blocky faces.** A blocky coarse block drew a top and up to four
  walls per cell. Runs of cells with the same height, material and colour now
  share one top quad (along X), and runs of walls with the same drop share one
  wall quad (along the wall).
* **Skirts face one way.** A skirt is only seen from outside its own block, and
  the GPU drops the back face for free, so 19.17's second copies are gone. One
  skirt per border is NOT enough: the rings are laid out from the world's
  origin, not the camera, so away from it you look across some borders from
  the coarser side — each block keeps its own outward skirt.
* **No skirt on the detail tiles.** The detail square always surrounds the
  camera, so a skirt facing out of it is never seen.
* **LOD 1 only where it touches the detail** (19.16's ring grown by a lattice
  step is undone). The deep coarse skirts (19.17) now cover the border where
  the detail meets a coarser block.

Bench view: far tier 1,246k → 686k triangles built, 657k → 469k drawn,
3.6 → 3.1 ms. City far ground 426k → 370k. Borders checked with LOD frozen at
the origin, at 179 m, and 390 m out where the detail meets LOD 2 directly.

**Fixed after (reported):** the smooth blocks' skirts were wound backwards — they
faced INTO their own block, so they were culled from the one side they can be
seen from and showed from behind. Wound clockwise from outside now; the blocky
blocks' walls were already right.

### 19.19 Small far blocks follow the camera's LOD; courses drawn on smooth ground

**Always blocky round the origin.** Ring 0 of the far tier (LOD 1, blocky) is
laid out round the world's origin — where the sites are — and blocks split to
sit beside the detail were kept once split. So the ground round the buildings,
and everywhere the camera had passed, stayed LOD 1 wherever the camera went.
Now every small far block is re-baked at the step its distance from the CAMERA
calls for (the same 16/32/64-tile rings, measured from the camera tile)
whenever the camera enters a new tile — smooth past LOD 1, as the rest is
(`_relod_far`). The big merged rings still follow the origin's layout.

**Smooth far ground drawn as courses.** A smooth coarse block has no bricks,
so the terrain shader draws what a brick hillside shows at that distance: a
darker line at every course (0.42 m) and each course a touch lighter at its
top than its foot, faded where a course is under ~2 px. Only on smooth far
ground (the mesher flags it in CUSTOM0.g). Dev menu: "Course lines on smooth
far ground".

**The sea is three bricks lower** (`SEA_AT_SAND` −0.76 m): 0.5 m covered
nearly all the sand.

### 19.20 Smooth far ground that reads as brick

The switch from blocky LOD 1 to smooth LOD 2 was easy to see, for three
reasons, each now fixed at no triangle cost (far tier 547,548 triangles before
and after):

  * **Colour bled.** A smooth vertex was shared by four cells, so material
    colours blended into blobs. Each cell now has its own four vertices: one
    flat colour, a hard edge, as a blocky cell has. Heights still come from the
    shared corners, so there are no cracks.
  * **Slopes were continuous.** Corner heights are snapped to a brick course
    (0.42 m): gentle ground becomes flat shelves joined by short ramps.
  * **Lighting was smooth.** The shader lights smooth far ground flat per
    triangle (normal from screen-space derivatives), and darkens ramps
    (`far_ramp_shade` 0.72) the way a blocky wall is darker than its top.

With the course lines (19.19) the far ground now reads as terraces of brick.

The `--terrain --nav` flush gate now checks only the site buildings: the
registry also holds brick trees and small items since the impostor work (822
entries), and those do not stand on pads.

### 19.21 Speckled seams, and one lighting rule for all far ground

**The speckle** along skirts and smooth ramps was shadow acne: 19.20 gave
smooth far vertices and skirts an "up" normal and did the lighting in the
shader, but shadow bias reads the VERTEX normal, and "up" on a steep face
biases the wrong way. Smooth cells now carry their real slope as the vertex
normal and skirts face out; the shader still lights them flat.

**The LOD 1 / LOD 2 border.** Blocky far blocks are flagged too (CUSTOM0.g =
0.5) and lit by the same rule as smooth ones: flat per face, tops full
brightness, anything steeper darkened by `far_ramp_shade`. The border now
changes shape (steps to ramps) but not shading. Course lines stay on smooth
ground only.

### 19.22 Slopes and curves along terrace edges (after LEGO Worlds)

`Docs/Reference/lego-worlds.md`: LEGO Worlds' hills are rows of slopes and
curved slopes laid along the contour, not 1x1 ramps (which we tried and turned
off, `RAMPS_ENABLED`, because a 50-degree face a third of a metre wide read as
melted). So a new piece, `PIECE_SLOPE`:

* **Where:** a cell whose neighbour on one side is 1-3 plates lower, with the
  terrace running back at least 2 studs behind it at the same height, material
  and colour. Placed before the flat packer.
* **Which:** the run decides. 2 studs: a **1x2 slope** (flat back stud, 39
  degree face, a plate-high lip). 3-4 studs: a **1x3 / 1x4 curved slope** (flat
  at the back, falling ever steeper, two stations a stud). A one-plate fall
  (the half-brick regions): a **cheese slope**, one straight face, no lip.
* **Width:** rows along the contour with the same shape merge up to 4 wide,
  like LEGO's 2x4 slopes.
* **Drawn by the piece itself** (the mask skips a piece's own brick): the
  profiled top, the front lip, a back wall where the ground behind is lower,
  and each side a wall down to lower ground or a CHEEK up to higher ground --
  the neighbour's face the slope's cut exposes. Neighbouring slopes are
  measured at their real surface, not their column, or the walls stopped short
  and showed the water through a slit.
* **Collision:** each cell's box at the slope's height over its middle.
* **Toggle:** `BrickTerrain.set_slope_pieces`; the F10 menu has "Slopes and
  curves on terrace edges".

Cost: 381k -> 660k detail triangles at the origin view (a first version with
three stations a stud was 1.65M). Known gaps: a few specks where a slope meets
a slope in the next tile (a tile cannot see its neighbour's pieces); no corner
pieces yet, so a turning contour steps rather than wrapping.

The workshop palette gained the same parts (Build mode area, small change):
`curve_1x3`, `curve_1x4`, `curve_2x4`, and one-plate `cheese_1x1`, `cheese_1x2`,
`cheese_2x2` (studless, in the Slopes category).

### 19.23 Slope sides that meet, and steep slopes on steep ground

**Slivers and fins beside slopes.** A slope's side used one flat bottom per
segment, sized from the neighbour's height at one point. Where two slopes of
different length met side by side their surfaces CROSS, and the side left a
gap (blue water showing) on one part and a fin on the other. Sides are now
sampled every stud (half stud on curves) against the neighbour's real surface:
a wall where it is lower, a cheek where it is higher, split exactly where the
two cross.

**Steep slopes.** Where the ground drops two or three bricks over one stud --
sculpted mounds, mostly; the generator rarely does -- the edge is a STEEP
slope, like LEGO's 1x2x3 (~73 degrees): a flat back stud where there is room,
one stud of steep face, a plate lip. A taller drop gets the steep slope on its
top three bricks and plain brick below. A steep slope owns its column down to
the ground in front (`in_piece_solid`), so the wall pass leaves that face to
it.

### 19.24 Slopes decided per column, from the field

The packer used to decide slopes first-come, inside one tile, so the next
tile could not know where its neighbour's slopes were: at tile borders sides
were sized against the wrong surface (water slivers, fins), and on steep
mounds slopes pointing different ways overlapped.

Now `sample_tile` classifies every column -- its tile and a two-stud margin --
from the FIELD alone (heights, material, colour over an 8-stud border): the
side it falls toward, the run length, its distance from the front, the fall.
Every tile gets the same answer about every column, so `column_surface` gives
the exact slope surface of any neighbour, in or out of the tile. Pieces are
built from runs of those columns (cut at tile edges, which is fine: the
surface is the same either side).

Each piece's sides, back wall and top share one UV frame, so the seam outline
goes round the whole piece rather than round every segment -- the "small
bricks" lines on slope sides. The side fillers (wall down to a lower
neighbour, cheek up to a higher one -- the angled non-brick pieces that plug
gaps) are split exactly where the two surfaces cross.

Slopes are heightfield-only (`g_flat_mode`): the volumetric bench carves its
field and keeps its bricks.

## 20. Editing terrain is a LEVEL EDITING job

Nothing in this section is reachable from gameplay. The game loads a world and
never writes one; an author writes worlds and never plays them from here.

### 20.1 An edit goes into the FIELD

`scenes/terrain_editor.tscn` edits **pads** (§19.12), not meshes and not a
heightmap. That is the whole reason it is a short script: a pad goes into the
generator, and the detailed tier, the coarse tier, the collider, the stud
test, the seabed texture and the buoyancy solver all agree about it without
being told. An editor that pushed vertices around would have to tell every one
of them, forever, and would have to keep telling them as new consumers
appeared.

| | |
|---|---|
| LEFT CLICK | place a pad under the cursor, or select the one already there |
| DELETE | remove the selected pad |
| `[` `]` | radius · `,` `.` skirt · `-` `=` height, a brick at a time |
| CTRL+S / CTRL+O | save the world / reload it |

Placement raycasts against the terrain's OWN collider, so what gets hit is
exactly what is drawn — the same body the player stands on (§19.2).

Pads are drawn as flat discs over the ground, because the ground only shows
the RESULT of a pad, which is a flat spot that looks like every other flat
spot. An author has to be able to see the thing being edited.

### 20.2 Rebuild what the edit touched

An edit changes the field, so every tile over it is stale — and only those. A
pad is tens of studs across and the world is thousands, so
`TerrainStreamer.invalidate(rect)` drops that rectangle and lets it stream
back. The difference between an editor that answers a keypress and one that
stops for a second each time.

Resizing rebuilds the OLD bounds as well as the new. Shrinking a pad otherwise
leaves the ground it used to flatten exactly as it was, and the author is left
with a flat spot nothing explains.

### 20.3 A world is a seed and a short list of edits

`worlds/<name>.json`: version, seed, the drowned fraction the sea is derived
from (§19.10), and the pads. Small, diffable, mergeable, and hand-editable —
which a baked heightfield never is.

A missing world file is **not an error**: a level that has never been edited
is a seed and nothing else, and the editor says so rather than refusing to
open.

The probe gates the round trip — save, clear, load, and every pad comes back
the same pad — because a world file is the only thing here that outlives the
session.

### 20.4 Three tools, because a level has three kinds of edit

| key | tool | what it is |
|---|---|---|
| 1 | PAD | flatten ground to a height — where something stands |
| 2 | PAINT | say what the ground is MADE of, whatever the noise thinks |
| 3 | SITE | a building: a pad, plus how many storeys stand on it |

**Painted material is dithered, not blended.** A pad's skirt interpolates
because height is a number and half way up is a height. Material is a
CATEGORY: half sand is not a material. So the skirt decides per column, by a
hash, with the odds falling off with distance — a hard edge would draw a
visible circle on the ground, and breaking the boundary up is what a hand
with a brush does. The probe checks both materials appear across the skirt,
because a dither that has gone hard is still a circle.

**Sites own pads, and pads all live in one list**, because the FIELD only has
one kind of flat spot — the editor is what knows which pad a site cut. Moving
or resizing a site re-cuts them, taking the hand-placed pads out first and
putting them back.

**The buildings are the city's own.** `BuildingShell.build_coarse_mesh` is
what `city_scene` draws before a building materialises into real bricks, and
a site here uses the same call with the same `brick.gdshader` — same course
banding, same seams, same print pass. Testing the terrain half of the
contract against a placeholder box proves nothing about the real article.
Footprints snap to `TowerRecipe.PANEL`, because a building off that grid has
its columns in the wrong places.

### 20.5 One editor, any level

`-- --world=<name>` picks the file, for the editor and the game scene alike.
A world is a file, not a scene, so there is nothing to duplicate to make a
second level — and `TerrainWorld.list_worlds()` enumerates what exists.

The world file is version 2 now: seed, drowned fraction, pads, **paints** and
**sites**. `TerrainWorld.SITES` is no longer where the sites live; it is only
what a brand new world starts with.

### 20.6 Brushes: sculpting, the way smooth terrain is edited

Pads, paints and sites are PLACED. Shaping a hillside is not placing
anything — it is dragging a brush across it — so the editor has four:

| key | brush | while the left button is held |
|---|---|---|
| 4 | RAISE | lifts the ground under it, `strength` metres a second at the middle |
| 5 | LOWER | the same, down |
| 6 | FLATTEN | pulls the ground towards the height where the stroke BEGAN |
| 7 | SMOOTH | pulls each column towards its neighbours' average |

`[` `]` is the radius (2–64 studs), `-` `=` the strength, CTRL+Z undoes a
whole stroke (64 deep). A yellow ring shows where it lands.

**A stroke goes into the field**, like a pad (§20.1): `BrickTerrain.sculpt`
adds a height offset per stud column to the noise, UNDER the pads — so a
building's pad stays dead flat whatever is painted round it, and every
consumer (tiles, coarse tier, colliders, seabed, the AI's ground) agrees
without being told. The offsets live per tile and are saved in the world file
(`"sculpt"`, base64 float32 per touched tile; version 3). The sea is measured
before them (§21.6): digging a lake does not move the ocean.

Three things made it feel like a brush rather than a slideshow:

* **Copy-on-write storage.** Tiles bake on worker threads while the editor
  paints, so a stroke publishes a new map (untouched tiles shared, touched
  ones cloned) and a bake keeps whichever it started with. Readers hold a
  thread-local pointer and reload only when the generation moves.
* **`TerrainStreamer.refresh(rect)`**, not `invalidate`. The old tile stays on
  screen while its replacement bakes and is swapped when ready; a bake that
  started before the edit is thrown away and done again. A replacement gets
  its collider at once — ground under something must never go a frame
  without one. Ten refreshes a second; the dabs themselves are every frame.
* **The brush aims at the field, not the colliders.** A ray against ground
  that is mid-swap fell through it: the first stroke raised 0.07 m where it
  should have raised a metre and a half. Marching `surface_plate` along the
  view ray is exact and never mid-swap.

`-- --shot` in the editor drags a raise stroke and a flatten across open
ground (`editor_raised.png`, `editor_flattened.png`) and undoes both.

### 20.7 The paint brush: material AND colour, a stud at a time

Tool 8. The PAINT tool (2) places a disc of one material with a dithered
edge; the paint BRUSH is held and dragged like the sculpting brushes, and
lays both what the ground is MADE of and what COLOUR it is:

| | |
|---|---|
| palette | a row of ground materials (plus KEEP, and NATURAL to put the generator's back) and every filament colour (plus the material's OWN, and KEEP) — `scripts/paint_palette.gd`, the same one the workshop's brick brush uses |
| `,` `.` / PAGE UP, DOWN | step the colour / the material without the mouse |
| P | take the material and colour of the ground under the cursor |
| `[` `]`, CTRL+Z | radius, and undo a stroke, as for every brush |

It lives in the same copy-on-write tiles and undo strokes as the sculpt
(§20.6): per column, a material byte and a colour byte, 255 for "not
painted". A painted material wins over PAINT discs and over the noise; a
painted colour is what the mesher draws the column in, and **pieces are cut
where it changes**, as they are at a material change — otherwise a 2x4 half
in the stroke is all one colour or the other. The coarse tier reads it too,
so a painted road reads as a road from the far hills. The world file carries
it beside the heights (`"paint"`, base64, per touched tile).

`BrickTerrain.paint_surface(x, z, radius, material, colour)`: -1 leaves
that half alone, -2 resets it. `colour_at` answers the filament a column is
drawn in. The probe gates set, KEEP/RESET, undo, clear and the round trip;
`-- --shot` in the editor paints a red sand stripe (`editor_paint_brush.png`).

### 20.8 See-through ground, and why

Reported from the editor: a dug pad and a sculpted spire looked like glass —
the hillside behind showed through the ground in front.

Each tile could carry TWO surface meshes: the bevelled one (§17.21's real
chamfer geometry) out to 12 m and the flat one from there, swapped by
Godot's visibility range with a 6 m fade. FADE_SELF fades both by making
them part-transparent, and two part-transparent copies of a surface do not
add up to an opaque one — so everything 6 to 18 m from the camera was
see-through. The heightfield scene had turned the bevel mesh off long ago
(§17.22, the shader draws the chamfer); `TerrainTile.bevel_enabled` still
DEFAULTED to on, so the editor and the city both had it.

It defaults to off now. The volumetric bench, which is where the geometry
chamfer is measured, turns it on for itself. Rendered A/B at one view over a
6 m pit: with it on, the near hill is glass and the pit shows through it;
off, solid.

### 20.9 One terrain scene, with the sea in it

There were two scenes on the same ground: `heightfield_test` (the far tier,
the water, the sites, the bench and the captures) and `terrain_editor` (the
tools, with a streamer, camera and sun of its own). They had drifted: the
editor had no far tier and no sea, so an edit was made on ground that did
not look like the ground it was for.

Now there is one. `heightfield_scene.gd` is the scene, and
`terrain_editor.gd` is the TOOLS — a node it adds on top of its own terrain,
far tier, water and sites (not in `--bench` or `--shot`, which measure and
photograph the terrain rather than an editor's markers).
`scenes/terrain_editor.tscn` is the same scene under its old name.

* **Tool 0, LOOK, is the default**, so the click that takes the mouse never
  places anything. 1–8 as before. The eyedropper is `I` (P is the print
  pass). The editor's readout is top right, the scene's top left.
* **An edit reaches everything baked from the field.** The tools refresh
  the detailed tiles; `terrain_changed(rect)` re-bakes the coarse blocks over
  the edit at the step each was built with (a merged ring as a whole) and
  re-reads the seabed the water takes its shore from. Once a stroke, not per
  dab.
* **The world is loaded the editor's way**: the file's own seed, drowned
  fraction and sculpt.
* **The sea is ON by default** (`water_sea.gd`, the city's): its brick tiers
  draw only where there is water within their reach, so a dry hilltop pays
  nothing for them. F7 still hides it; the bench measures with and without.
* `-- --editshot` runs the editor's capture pass in this scene.

**The crash flying out over the far ground.** A coarse block made by an
earlier split was split again and freed, but stayed in `_far_nodes`, and the
next frame set `visible` on a freed node — 105 errors over a scripted 1 km
flight on the old code (the editor's debugger stops on the first). Retired
blocks are let go of now; the same flight is clean.

### 20.10 The dev menu (F10)

F10 in heightfield_test (and the terrain editor, the same scene) opens a
menu on the left; the mouse is the menu's while it is open and the world keeps
running. `scripts/terrain_dev_menu.gd`:

| control | does |
|---|---|
| Freeze LOD streaming | the detail square, the far tier's hiding and the water rings stop following the camera: fly over to a border and look at it |
| LOD colour view | the L tint |
| Detail radius | tiles of full detail round the camera |
| Smooth far terrain from + Rebuild far terrain | the coarse step past which far ground is smooth; rebuilds the far tier |
| Wave height | the wave gain (height and length together) |
| Strength at the shore, Full strength by | the wave strength at the waterline and how far out it reaches full |
| Swell rolls to shore within | how far from land the swell is steered to the shore |
| Studded water radius | how far the brick water reaches; rebuilds the sea |
| Tile lean, Grid lines | the studded tiles' look |

The wave settings are live in `BrickWave` (`set_wave_gain`, `set_shore_calm`,
`set_swell_steer`), so swimming, floating and the collider follow them, not
only the picture. Nothing is saved: a session's tuning ends with it.

## 21. The city on the terrain

Everything above is terrain with placeholders standing on it. This is the
city — `city_scene.gd`, with its registry, its damage, its rooms, its
collapse — standing on the field instead of on a grey plane at y=0.

    godot --path . scenes/city.tscn -- --terrain
    godot --path . scenes/big_city.tscn -- --terrain

### 21.1 The generator is told first

A building does not get put on the terrain; the terrain is told a building is
coming. `_build_city` stamps a PAD (§19.12) at each building's middle before
any ground exists, then reads the floor height back out of the field:

    pos.y = _stamp_pad(pos, footprint)      # cuts the pad, returns the level

The pad is the footprint plus four studs of margin — ground to stand on, not
ground exactly its own size — with a skirt half as wide again, and its height
is the natural surface rounded to a COURSE, because a building standing
between two courses has its ground floor half a brick into the hill.

Two consequences worth stating:

**Neighbours see each other's pads.** A pad is in the field the moment it is
stamped, so the next building's `surface_plate` already includes it. A row
terraces instead of each tower carving its own island out of the same slope.

**Nothing is flattened afterwards.** There is no pass that pushes terrain out
of the way once a building is placed, and no building that hovers while the
ground catches up: there is one height function, and both the tower and the
tile under it read it. Measured at the default city: 22 pads, floors between
17.6 and 21.8 m — four metres of terracing across the precinct. At `--big`,
which is 240 m across, 2.1 to 27.3 m.

### 21.2 The city holds all its ground

A city is an authored place of a known size, so its detail tier is not
streamed around the camera — it IS the city, resident, all of it, from the
first frame (`TerrainStreamer.whole_world`). That buys two things:

  * the ground a collapse lands on is never half-built, and debris two
    streets away lands on collision rather than falling through
    (`collide_radius = -1`, every resident tile);
  * the hole in the coarse tier never moves, so the far ground can be baked
    once — no per-frame coverage test, no quadtree, no per-block hiding, all
    of which §19.7 and §19.11 needed only because the detail square moves.

`TerrainCoarse` is that simpler far tier: the same cascade of doubling blocks
and doubling sample steps, a static hole cut for the city, one merged mesh a
ring. 203 blocks in 4 rings, 643k triangles, out to 448 m.

This is also where a camera-centred region turned out to be wrong in a way
that is easy to miss. `region()` is built around the camera's tile, and every
scripted pass stands OUTSIDE the city looking in: the big city asked for 144
of its 625 tiles and the far half of it stood on coarse ground. It looked
fine from the camera that caused it, which is the worst kind of bug.

### 21.3 What it costs

| | detail tiles | settle | coarse | total |
|---|---|---|---|---|
| `city` | 169 | 1.66 s | 203 blocks, 643k tris | 1.86 s |
| `big_city` | 625 | 12.9 s | 242 blocks, 502k tris | 13.5 s |

Load time, once, and it is collision-dominated: every tile in the city gets a
collider because anywhere in the city is somewhere a tower can fall. The
default city pays 1.9 s for that; `--big` pays 13.5 s for four times the
ground, which is the price of holding 240 m of city whole and is why the
flag is opt-in.

### 21.4 What this did not do, and now does

The first cut of §21 left three things open. All three are closed below:

  * the layout was a grid — the city now reads its **sites** (§21.5);
  * the sea was the heightfield scene's alone — it is now **the world's**,
    and the city has a coast (§21.6);
  * navigation assumed a floor at y = 0 — the AI's ground is now **the
    field** (§21.7).

### 21.5 The city is built from its sites

On terrain the layout is the WORLD's, not a lattice `city_scene` makes up.
`worlds/city.json` (and `worlds/big_city.json` with `--big`) holds the
city's sites, and `_build_city_on_sites` builds one building per site:

| site key | meaning |
|---|---|
| `tile_x`, `tile_z` | the tile it is in — how the editor addresses a site |
| `x`, `z` | its middle, in studs, when it has a finer one than a tile's |
| `footprint_x`, `footprint_z` | its footprint, when it is not the square that fills the pad |
| `radius`, `skirt` | the pad it cuts (§19.12); `skirt` defaults to half the radius |
| `storeys` | × `TowerRecipe.COURSES_PER_FLOOR` courses |
| `program` | the room mix (Docs/Workshop.md, Stage F), when it has its own |

A site the editor places is a tile, a radius and storeys, and its file entry
stays that small. The city's grid needs the rest: a tile is 32 studs and a
street is nine, and the city's shapes are not square. `TerrainWorld.
site_centre / site_footprint / site_corner / site_skirt` answer for both, so
the heightfield scene, the editor and the city ask one set of questions.

**A world with no sites gets the street grid AS sites** (`_grid_sites`), so
there is one path either way and the grid is a starting point rather than a
second layout. `-- --terrain --save-world` writes whatever the city was just
built from to its world file and quits; that is how the two files in
`worlds/` were made, and it is how to reset one.

    godot --path . scenes/city.tscn -- --terrain --save-world
    godot --path . scenes/terrain_editor.tscn -- --world=city

The editor opens a city world on the city's own seed (it takes the seed from
the file now, not from a constant), selects a site by clicking anywhere on
its pad, and moves a city site to the stud rather than to the tile.
`--buildings=N` still caps a city built from sites, but only when it is on
the command line: with a world file, the sites decide how many buildings
there are.

The floor is read back OUT of the field after every pad is in — one height
function, which both the tower and the tile under it read (§21.1).

### 21.6 One sea, and it is the world's

The sea used to be chosen per scene: `sea_level_for(half_tiles, drowned)`
over whatever area the scene sampled, AFTER its pads were cut. Two scenes on
one seed could put the water at two heights, and an author moving a building
moved the sea.

**`TerrainWorld.sea_level` is now a property of the world**: its seed and its
drowned fraction, sampled over a fixed `SEA_TILES` (8 tiles each way — what
the heightfield scene always used) on the field as generated, BEFORE any pad.
Loading a world settles it (`settle_sea`, which also sets `BrickWave`), and
everything that cares reads that one number: the water tiers, the pads, and
navigation.

| world | drowned | sea | |
|---|---|---|---|
| `heightfield` (default) | 0.30 | 14.91 m | unchanged from before |
| `city` | 0.20 | 10.29 m | the default city's ground is 12.5 m and up: dry |
| `big_city` | 0.20 | 10.29 m | its ground reaches −13 m: a coast |

**A pad never sits in the sea.** `stamp_sites_only` raises a site whose
ground is low to `FREEBOARD_BRICKS` (one course) above the water: a quay. And
the street grid leaves out the cells that ARE sea — a building does not stand
in the water, and leaving those cells empty is what gives a city on low
ground a shoreline. The big city keeps 14 of its 22 buildings; the other 8
grid cells were under water.

**The water itself** is `scripts/water_sea.gd`: the heightfield scene's three
tiers (studded pieces round the camera, four-stud pieces to 80 m, one sheet
to the horizon) as one node, over a seabed texture that reaches as far as the
coarse ground (448 m). The brick tiers are 26k pieces whatever is under them,
so they are shown only where a coarse WET map (64-stud cells) says there is
water within their reach; on the default city the camera never sees them.
The near tier carries the water collider (§Water 7.1), and the city camera
swims in it. Built in 64–97 ms.

### 21.7 The AI stands on the field

`AIWorld.set_terrain_ground(true)` makes the ground a thing the AI can ask
about. Every plate under the field's surface is solid to every question
above it:

  * **navigation** — `column_solid` fills the column up to the ground, so a
    column's first floor is ON the hillside, not at y = 0. Nothing in
    `AINav` had to learn what terrain is; it asks AIWorld what is solid, as
    it always did;
  * **sight and cover** — `line_clear`, `trace`, `bricks_between` and
    `cover_seconds` march the segment a stud at a time against the field, so
    a crest blocks a line and is cover no gun wears away (`cover_seconds`
    is INF, `bricks_between` counts it as 1,000 bricks). Half a brick of
    slack, so a line from a figure's feet on a slope is not blocked by the
    slope. The soldiers' own eyes are physics rays, which already hit the
    terrain collider;
  * `ground_at(x, z)` — the city's `_on_ground()` puts script points (a
    street, a spawn) on the ground instead of at y = 0.

The field is a noise function, so the ground under each stud column is
cached (the city's pads are all cut before anything asks).

**The sea is not a floor.** `AINav.set_water_level(sea)`: a floor more than
`WADE` (0.5 m) under the surface is not somewhere a body stands, so a path
never goes into the water and a point in it does not snap.

**On a hillside the search is weighted (1.2).** The heuristic now counts
only net CLIMB, and only climbing costs height — a path that dips and rises
again pays for the rise once. That alone did little: every stud of a
hillside is a plate up or down, the cheapest route is a hair cheaper than a
hundred others, and exact A* expanded all of them — 30,000 nodes for a
100 m walk. Weighted at 1.2 it is ~300, for a path at most a fifth longer
than the best. The flat city keeps its 1.001 (its heuristic is exact there
and only ties need breaking) and measured the same as before: 3,999
expansions for the pass, 7 of 7.

`-- --terrain --nav` runs the nav pass on the hillside, with three gates of
its own:

| gate | measured |
|---|---|
| a path climbs from the lowest building to the highest, never under the ground | 17.9 → 21.0 m, 27 m long, at most 0.42 m (one step, at a corner) under it |
| a crest blocks the AI's sight and is cover no gun wears away | 12 of 12 |
| the sea is not somewhere a path goes | a point on the seabed does not stand, and no path reaches it |
| every building on the stud grid and flush with the ground (§21.8) | 22 buildings, 0 of 23,100 columns off |
| a build placed on the hillside gets ground at its floor (§21.8) | 0 columns off |

and the pass's own gates on terrain: 12 of 12; fifty requesters, 50 found,
none failed, inside the budget.

**The soldiers' own eyes agree.** They see with physics rays, and the
terrain only has colliders where the city's detail tier is: of the 12 crests
above, physics alone saw 8 — the other 4 were out on coarse ground with no
collision. `Soldier.can_see` now also asks `AIWorld.ground_blocks`, the
terrain half of `line_clear`, which knows every crest; the gate requires both
to see all 12.

### 21.8 Buildings stand ON the ground, on the world's grid

A building's footprint is on the stud grid by construction (a site's corner
is its centre minus half its footprint, in whole studs) and its floor on a
course. What was not true until now is that the GROUND under it was at its
floor:

* **A pad is a rectangle.** `add_pad(..., radius_z)`. A site's pad is its
  footprint plus its margin all round, not a square sized for the long side.
* **On a pad the ground's top IS the pad's height.** The field quantises in
  two ways — plate steps in some patches, whole bricks in others — and a
  footprint straddling the two stood a plate off on one side and three on
  the other. Where a pad is flat, `top_plate` now returns its height exactly.
  Pad heights are snapped to 1/64 plate as well: 18.06000007689 m came back
  as 128.99999 plates and floored to the plate below the floor.
* **A pad's flat beats every other pad's skirt.** Neighbours' skirts reached
  under each other's buildings: 718 of the default city's 23,100 footprint
  columns were off. Neighbours at different heights now meet at the edge of
  the higher flat — a terrace step.
* **A site's floor can be set** (`-` `=` on a selected site in the editor,
  a course at a time; `"level"` in the world file). The building stays on the
  grid and the ground comes to it — a plinth when raised, a cut when lowered.
* **A build placed with P lands on the hillside** at the course nearest the
  ground it was aimed at, and the city cuts a pad for it at its floor — the
  building never moves to suit the hill; the hill gives
  (`city_scene._ground_building`). Only on the ground: a build set on a roof
  or at a height held with E cuts nothing.

A building that has taken damage is whatever its bricks are; none of this
touches a piece that has fallen.

`-- --terrain --nav` gates both: every building on the stud and plate grid
with 0 of 23,100 footprint columns off the floor, and a cottage placed on the
hillside flush in every column.

## 22. Plan: heightfield until it must be volumetric

Status: **plan, not built.** The terrain has two working modes today — the heightfield
(`set_flat_mode(true)`: one surface per column, slopes, sculpt, paint) and the volumetric bench
(carving, caves, a sparse cell-edit map `g_edits`) — but the mode is one global switch. This is
the plan for both in one world, chosen per tile, with volumetric only where the ground actually
needs it. Prior art: STA's blocky track stores nothing for unedited chunks, "the heightmap is the
store there, which is also the far LOD" (`Docs/Reference/sta.md`).

### 22.1 The rule: what a hit leaves decides the mode

A tile is HEIGHT by default. A hit (explosion, dig, collapse) is applied as a carve, and the carve
is classified per column before anything is stored:

| what the column ends up as | stored as | tile stays |
|---|---|---|
| removed from the top down — the hole reaches the surface | a **height delta** in the sculpt layer (§20.6), exposed material in the surface-paint layer (§20.7) | HEIGHT |
| a hollow under a lip at most `LIP_MAX` thick (default one brick) | the lip is removed too (it crumbles; debris spawned) → height delta | HEIGHT |
| a hollow under a lip of sand, dirt or grass (ground that cannot hold an overhang) | the lip collapses → height delta | HEIGHT |
| a hollow under a lip thicker than `LIP_MAX`, in rock | cell edits in the tile's volume store | **VOLUME** |

So a crater blown into flat dirt from above is a heightfield crater. A blast into the side of a
steep **stone** hill that leaves a roof thicker than a brick is an overhang, and only that tile
(and any neighbour the hollow crosses into) becomes VOLUME. The material rule is the natural gate:
loose ground slumps, rock arches. `LIP_MAX` and the material list are the knobs for "only
sometimes".

Heightfield craters are nearly free: they are the same per-column offsets the sculpt brush writes
(copy-on-write tiles, saved in the world file), so the detail mesher, slopes, the coarse tier,
collision, the AI's ground and the water's seabed all see them with no new code.

### 22.2 A VOLUME tile

* **Store:** the existing `g_edits` (cell → material, sparse), scoped to the tile. A converted tile
  is the heightfield's own columns, solid to their tops, plus the edits — so converting never
  changes the shape, and its edges still match its HEIGHT neighbours (both read one field).
* **Mesher:** `sample_tile` picks the path per tile instead of from `g_flat_mode`; the volumetric
  path already handles caves, craters and the wall pass.
* **Slopes:** HEIGHT tiles only, at first. A blown-open rock face of plain bricks reads as rubble.
  3D slope rules (a slope over a hollow, under an overhang) are a later step.
* **Collision:** the volumetric box builder per tile (exists for the bench).
* **AI:** `AINav` already reads columns with several floors (built for storeys); a VOLUME tile
  answers `column_solid` from its cells instead of from one ground height.
* **Water:** the seabed top is the highest solid cell; a cave floods only through the cell water
  of Water.md §12.

### 22.3 Far LOD and saving

* Far tiers sample `surface_plate`, which for a VOLUME column is its highest solid cell: from far
  away an overhang reads as a solid bump, filled under by skirts. A large authored arch or cave
  mouth can carry a baked low-detail mesh, built once when its tile changes. Optional.
* HEIGHT edits are sculpt/paint tiles (already saved). VOLUME tiles save their cell edits per
  tile, run-length per column. Authored caves are VOLUME tiles from the start.

### 22.4 Budgets (estimates, not measured)

| | HEIGHT tile | VOLUME tile |
|---|---|---|
| build | ~3 ms | ~8–15 ms |
| memory | heights + two layers | + sparse cell edits (a big crater ~10–50 KB) |
| a hit | rebuild touched tiles | same + volumetric re-mesh, 5–20 ms, spread over frames |

A battle that wrecks a hillside converts a handful of tiles; the rest of the world never pays.

### 22.5 Build order

1. Per-tile mode flag; `sample_tile` chooses the path per tile. Gate: a VOLUME tile beside HEIGHT
   tiles has no seam (coverage gate).
2. Carve classifier (§22.1) writing height deltas. Gate: a crater on flat dirt stays HEIGHT and
   the far tier shows it.
3. Lip rule, material rule, debris for collapsed lips.
4. VOLUME conversion for thick rock overhangs; collision and AI per tile.
5. Save/load of both; level-editor caves.
6. Later: 3D slopes in VOLUME tiles; baked far proxies for big overhangs.

### 22.6 Why Minecraft does not do this

Minecraft stores the world in 16x16x16 sections and gets most of the memory saving without a
second format: an all-air section is not stored, and a section of one block type is a one-entry
palette, a few bytes. Its underground is full of caves and ores, so a heightfield could not
describe most sections anyway, and every block is editable by every player. One uniform format is
simpler for them than two paths and a conversion.

This game is different: the terrain is a surface with nothing under it to find, most of it is
never dug, and the far LOD already is a heightfield. Two formats cost a conversion step and buy
the cheapest surface mesher, and all the slope work, for the ground nobody digs.
