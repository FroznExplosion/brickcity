# Reference — STA (planet sandbox: SDF terrain, blocky cubed sphere, water)

Source: `C:\Users\lbaun\Documents\sta`. Godot 4.6, native C++ module `sta_native`.
Two terrain tracks: a smooth SDF planet (the locked path) and a **blocky cubed-sphere**
alternative (`Docs/23_CUBED_SPHERE_BLOCKY.md`), each with its own water design.

## Water — what exists and what is only designed

| Doc | System | State |
|---|---|---|
| `18_WATER_IMPLEMENTATION.md` | first water pass on the SDF planet | built, superseded |
| `20_WATER_V2_FLOWGRAPH.md` | body graph: basins, spill edges, streams | built, superseded |
| `22_WATER_V3_BC.md` | native `WaterSolver`: priority-flood basin discovery, level-from-volume, spill / cascade, SDF-derived surface | **the live system** (`native/src/water_solver.*`) |
| `24_CUBED_SPHERE_WATER.md` | **cellular-automaton water on blocky cells** — the "blocky water" | design + build plan (rev 2, 2026-09-09), not built |
| `GeminiWater.txt`, `Astrobotwater.txt` | research notes (gather-form CA, threading, chunk halos) | notes |

## The blocky water design (`24`), in short

- **Cell state:** `mass u16`, `MAX 4096`, per cell, in a per-chunk water channel; dry chunks
  store nothing. Integer, so every peer is bit-identical.
- **Rules per tick** (gather form, double-buffered, no atomics): down into the cell below up to its
  capacity; sideways a quarter of the difference times `FLOW`; up when over capacity. A loaded
  cell holds `MAX + COMPRESS·mass(above)` — that one term gives hydrostatics (U-bends,
  communicating vessels).
- **Active set:** only cells that changed, or whose neighbour changed, tick. A still lake costs 0.
  Budget 100 k active cells at 20 Hz ≈ 3 ms on a worker thread; over the cap, the farthest
  chunks freeze.
- **Who is infinite:** the ocean (open-sky, never-dug cells below sea level read as full and are
  never written) and authored springs. Everything else — lakes, streams, waterfalls — is finite
  mass in motion. Absorption per material (sand, soil) dries spills.
- **Trapped air:** a sealed pocket only admits water up to a Boyle-law cap, so a breach into a
  cave does not flood it from nothing; dig a vent and it does.
- **Render:** top face at `mass/MAX`, corners averaged with wet neighbours so the surface slopes
  toward lower water (Minecraft's flow look); flow vector per cell in COLOR for foam streaks.
- **LOD:** sim ring (~150 m) ticks; frozen ring keeps stored mass; far ring is a per-column
  "water top" map drawn as flat quads, ocean is a far shell.
- **Storage idea worth stealing:** *"Unedited dry chunks store nothing — the heightmap is the
  store there, which is also the far LOD"* (`24` §10.2 decision 4). A chunk allocates a 3D cell
  window only on first edit or first fluid. This is the heightfield/volumetric hybrid in
  Terrain.md §22.

Used by: `Docs/Terrain.md` §22 (hybrid terrain), `Docs/Water.md` §12 (brick water).
