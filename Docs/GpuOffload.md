# Moving work to the GPU

What the game does on the CPU that the GPU could do instead, what is not worth moving, and what
texture streaming would and would not change. Written 2026-11-02; nothing here is built yet.
Each item names the area that owns it (CLAUDE.md, Areas).

## 1. Why GPU time still matters

Most of the hitches are the CPU's -- physics ticks, mesh uploads, the AI (Docs/PerfCaps.md 4) --
but the GPU is not idle:

* The dearest city view drew in 20-21 ms on the GPU, over a 60 fps frame (16.6 ms), before the
  far tier took it to 12 ms; a street walk is now ~10 ms GPU mean, 17 at worst (PerfCaps.md 5).
* The development machine is a Legion Go: one chip, CPU and integrated Radeon sharing one power
  and heat budget and one pool of RAM. GPU work heats the same silicon and takes clock from the
  CPU; the heat log sits at 90-99 C under test runs. Saved GPU work is CPU headroom here.
* On a desktop with its own graphics card the two are separate, and GPU time matters only where
  a view is GPU-bound.

So moving CPU work to the GPU is worth it where the GPU does it nearly free -- work that is
wide, uniform and needs no answer back on the CPU the same frame.

## 2. What could move, best first

### 2.1 Crumbs: a falling path worked out in the vertex shader

**Now.** A small piece is not a body but crumbs: each brick drawn in a MultiMesh, falling with
a kick, a scatter and a spin to the floor one ray found when it broke, lying there, then
shrinking away (`IslandManager` CRUMB_*, scripts/island_manager.gd; `PlanetCrumbs`,
scripts/planet/planet_crumbs.gd). Every physics tick GDScript steps every crumb and writes its
transform and colour back into the MultiMesh, one call each -- "about a microsecond a brick, on
the main thread" by its own note, so up to ~1.5 ms a tick at the cap (CRUMBS_MAX 1500), in
exactly the ticks a building is coming down.

**On the GPU.** Everything about a crumb's path is known when it is thrown: start, velocity,
gravity, spin axis and rate, and where it lands. Write those once into the instance
(transform plus INSTANCE_CUSTOM: born time, velocity, spin, floor height) and let the vertex
shader place it at `TIME - born`: a parabola to the floor, then still, then the shrink. The CPU
writes a crumb when it is thrown and frees its slot when it is gone; between, nothing.

* Saves: the per-tick loop -- up to ~1.5 ms a tick during collapses, the frames that hitch.
* Catch: the landing recheck (CRUMB_FLOOR_RECHECK: was the floor still there?) stays a CPU ray,
  once a crumb at its landing time, rewriting that one instance if the floor went. A planet's
  down is toward its centre (`Gravity.down_at`), which over a few metres of fall is a straight
  line: the same parabola along it. Bounds: the MultiMesh's AABB must cover where crumbs fall,
  or they are culled mid-air (set a custom AABB).
* Owner: city and buildings (IslandManager, shared) and planets (PlanetCrumbs). Small, and the
  biggest win here. It is also the "small pieces as particles" the break-lag list asks for.

### 2.2 CPU particles to GPU particles

**Now.** Dust, bursts and flames are CPUParticles3D, simulated on the main thread:
`CollapseDust` (collapse_dust.gd, a placeholder by its own note), `MaterialFx` bursts,
`CombatFeedback` death bursts, the torch flame, the tank and the truck. The disasters already
use GPUParticles3D (autoload/vfx_pool.gd and scripts/disasters/).

**On the GPU.** GPUParticles3D with a ParticleProcessMaterial: the same settings, simulated on
the GPU, nothing on the CPU per particle. Collision against the ground with a heightfield or
SDF collider if a burst should land.

* Saves: a little per effect; a lot when a collapse sets off dozens at once.
* Catch: a GPU particle cannot rest on a brick the physics knows about -- fine for dust, chips
  and sparks, not for anything that piles up. `tools/fx_cap_probe.gd` already watches effect
  counts. The Compatibility renderer runs GPU particles differently; Forward+ is what ships.
* Owner: weapons and effects (`fx/`, autoload), with CollapseDust from city.

### 2.3 Terrain and planet noise in a compute shader

**Now.** The ground's heights come from C++ value noise (`brick_terrain.cpp`); a planet's from
`ZN_FastNoiseLite` in the voxel module (scripts/planet/planet_data.gd). Both on CPU workers, as
tiles stream in.

**On the GPU.** A compute shader (RenderingDevice) evaluating the same noise into a height
texture, many tiles at once; the ground drawn from that texture by its vertex shader rather
than from a mesh the CPU built. The voxel module has GPU generation of its own in recent
versions -- check what our build has before writing one.

* Catch: collision and the AI's navigation need the heights ON the CPU, so they are read back
  (a frame late, and only near the player); the CPU noise must stay as the reference so both
  agree to the bit. Already on workers, so this frees worker time, not the main thread.
* Owner: terrain and water; planets. Medium effort, medium win, worth it only if streaming
  tiles is found to be what stalls.

### 2.4 Scatter placed by the shader

**Now.** Tufts and pebbles are worked out per tile and uploaded as MultiMesh instances
(terrain_tile.gd, "three MultiMesh uploads"); their sway is already on the GPU
(weather.gdshaderinc).

**On the GPU.** One instance list per tile size, each instance placed by the vertex shader
from the tile's seed and its height texture (2.3): no per-tile placement or upload on the CPU.

* Saves: placement and upload as tiles come in; nothing per frame (it costs nothing per frame
  now). Low priority on its own; natural once 2.3 exists.
* Owner: terrain.

### 2.5 Far stand-ins rendered by the GPU

A far building is a coarse mesh built on a CPU worker (`build_chunk_coarse_mesh`,
PerfCaps.md 5). An impostor -- a few pictures of the building rendered on the GPU into a
texture, drawn on a card (Docs/Impostors.md) -- moves the building of it to the GPU and cuts
triangles further. Owner: city and buildings. Only if the far tier's build time shows up.

## 3. What is not worth moving

| | Why it stays on the CPU |
|---|---|
| Building brick meshes (bands, chamfered near meshes, studs) | Godot 4.6 offers no simple, supported way to draw a mesh straight from a compute shader's buffer (it would be copied back through the CPU); the cost found was the UPLOAD, and that is on workers already (PerfCaps.md 4) |
| Physics, joints, the brick attachment rule | Branchy, sequential, and the answer is needed on the CPU this tick |
| AI: sight lines, choices, navigation | The same: small queries whose answer the CPU needs at once; a GPU round trip is slower than the query |
| Occlusion culling | Godot 4.6's is a CPU raster of occluders; GPU-driven culling is not in the engine |
| Wind, layer lines, the PBR sets, weather on surfaces | Already on the GPU (shaders) |

## 4. Texture streaming (Godot 4.8)

**Textures already live on the GPU.** Every texture set (Docs/PbrWood.md: ~165 MB of wood,
metal, stone and leaves, ~8 MB of printed beads) is uploaded to video memory once, at load,
every mip level of it, and sampled there; the CPU does no work for a texture after that.
Streaming does not move work to the GPU. It decides how MUCH of each texture is in video memory:
only the mip levels the screen needs, the fine ones loaded as something comes close and dropped
as it goes away.

What that buys:

| Machine | Its video memory | What streaming gives |
|---|---|---|
| Integrated graphics (the Legion Go, laptops, a Steam Deck) | carved out of system RAM, shared with the game | RAM back for the game: ~175 MB of sets kept to what is near |
| A graphics card with 8 GB or more | its own | next to nothing at today's ~175 MB |
| A graphics card with 4 GB or less | its own, tight | room: with the city's meshes and shadows it can fill, and a card that runs out spills into system RAM over the bus and stutters |
| Any | | faster loading: the coarse mips first, the fine ones after |

So for dedicated cards it is not a speed-up today; it is what lets the sets GROW -- 4K slices,
more sets per material, leaves by colour -- without a 4 GB card running out. On integrated
graphics it gives RAM back now.

Open before relying on it: 4.8 is in beta (4.8-beta2, 2026-10-29; stable planned for late
2026), and whether its streaming reaches texture ARRAYS bound as global shader uniforms and
sampled with `textureGrad` -- all of ours -- is untested. Until then the lever is a slice's
size: 1K instead of 2K quarters its memory (Docs/PbrWood.md 1.2).

## 5. Order, if this is taken up

1. Crumbs in the vertex shader (2.1): biggest main-thread saving in the frames that hitch,
   small change.
2. CPU particles to GPU particles (2.2), with the effects area.
3. After 4.8 stable: test streaming on the texture arrays (4).
4. Terrain noise on the GPU (2.3) and scatter (2.4), only if tile streaming is found to stall.
5. Impostors (2.5), only if the far tier's build time shows up.
