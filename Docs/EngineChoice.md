# Engine choice — why the game stays on Godot

Decided 2026-11-07. Read this before proposing a move to another engine.

## The decision

**Stay on Godot 4 + the C++ GDExtension.** Porting would mean rewriting nearly everything:
about 235,000 lines of GDScript, 36,000 lines of C++ and 90 shaders, plus 1,858 commits of tuning.
The hardest systems are custom in any engine: brick destruction and the tension-only joint
model, the structural solve, the face mesher and stand-ins, swarm AI, streaming and scaled space.
No engine ships them.

## Engines looked at

| | Godot (now) | Unity | Unreal 5 | EdenSpark 1.0 |
|---|---|---|---|---|
| Our C++ | GDExtension: C++ builds engine objects directly | Native plugin only: C ABI, no engine objects, arrays copied over; speed path is Burst/Jobs/DOTS (a rewrite) | Native, first-class | **None for game projects.** Games are Daslang only; C++ modules need the engine source, not released as of 2026-11 |
| Scripting | GDScript (slow), C# available | C# | C++ / Blueprints (binary) | Daslang (fast, AOT/JIT, C++-like memory layout) |
| GPU compute | Compute shaders, RenderingDevice | Compute shaders | Compute shaders | **None documented.** User shaders are pixel-only (no vertex/compute, no buffers, constant loop counts) |
| Threads | WorkerThreadPool, std::thread in C++ | Jobs + Burst | Task graph | Daslang `jobque` (jobs, threads, channels, atomics); engine-world access from jobs not documented |
| Runtime meshes | ArrayMesh / RenderingServer, from C++ workers | Mesh API | Procedural/Dynamic Mesh | `[mesh_generator]` files, `generate_mesh` (async); update rate and mesh colliders not documented |
| Physics | Jolt | PhysX | Chaos | Jolt |
| Destruction | Ours | None built in | Chaos (pre-cut meshes, not brick stress) | None |
| Multiplayer | Basic ENet/RPC | Netcode for GameObjects/Entities | Strong replication | Server-authoritative, 20 Hz replication, `[net_command]`, up to 127 players, lobby |
| LOD / open world | Auto mesh LOD, visibility ranges; streaming is ours | LOD Group, GPU Resident Drawer; no world partition | Nanite, HLOD, World Partition, double precision | LodSelector; no terrain or streaming documented |
| Text files for parallel chats | Yes (.gd, .tscn) | Mostly (YAML, but .meta GUIDs, prefab merges) | No (.uasset binary) | Yes (.das) |
| Source | MIT, open | Closed | Source-available, 5% royalty over $1M | Promised permissive FOSS; engine source not out yet (only samples, BSD-3) |

## EdenSpark in short (checked 2026-11-07)

Gaijin's engine on Dagor (War Thunder). 1.0 released 2026-09-30, adding serverless multiplayer
and offscreen GI. PC, with Xbox/PS5 promised. Good fit for small Daslang games. **Not a fit
here**: no C++ for our brick world, no compute shaders, pixel-only user shaders, and no
documented runtime mesh collision, terrain or streaming. Look again once the engine source is
out and native modules or compute are documented.

## What to do instead (the three better options)

1. **Move the slow GDScript paths into C++** (or C# where that is enough): the island tick,
   fracture spawning and promotion. These are the measured worst ticks (8–42 ms, WhereWorkRuns.md §2).
2. **Make fewer nodes and bodies per fracture.** Creating nodes and bodies on the main thread
   is what those ticks pay for. Pool them, merge shapes, and drive more through RenderingServer
   and PhysicsServer directly.
3. **Finish the renderer-off-main-thread work** in WhereWorkRuns.md §3.1 (a–e), so renderer
   calls stop stalling the main thread.

## If a port is ever forced

Only **Unreal 5** is a real target: native C++ (the brick world moves over almost as is),
engine source, compute shaders, a threaded renderer, strong replication, console support at no
fee (5% royalty over $1M). Unity with DOTS/Burst is a distant second: the C++ becomes a native
plugin or a Burst rewrite. Costs of Unreal that stay: every GDScript system is rewritten, the
editor is heavy on the Legion Go, and `.uasset` files are binary, which is bad for several Claude
chats working in parallel.

## Worth borrowing (ideas from other engines, done in Godot)

| Idea | Seen in | In Godot | First step |
|---|---|---|---|
| Renderer on its own thread | Unreal (RHI thread, render graph) | `rendering/driver/threads/thread_model` = Separate; the rest is WhereWorkRuns.md §3.1 | Time a city collapse with the separate thread mode on and off (editor closed) |
| Client prediction / rollback for movement and shots | Unreal (Iris, Network Prediction), Unity Netcode for Entities | the **netfox** add-on, or our own on the command stream in Multiplayer.md | Try netfox on the player mech in a two-client test |
| GPU particles that collide | Unreal Niagara | GPUParticles3D with collision (heightfield, SDF, box) | Try hit debris colliding with a heightfield collider, compare with crumbs (GpuOffload.md 2.1) |
| Many entities in flat data | Unreal Mass, Unity DOTS | Already done in the C++ swarm core | Keep new crowds (pieces, AI) in C++ arrays, not nodes |
| Jobs with race checks | Unity Burst/Jobs | WorkerThreadPool + C++, no checks | Debug-build asserts on shared brick data touched by jobs |
| Compute for heavy maps | all three | RenderingDevice compute shaders | Terrain/planet noise (GpuOffload.md 2.3) |

## A custom engine inside Godot (direction, not yet started)

A custom engine would stop treating bricks as nodes and meshes and treat them as data. That is
the real gain, and it does not need a new engine: the brick extension can grow into a
self-contained brick engine while Godot keeps the editor, UI, audio, input, scenes and asset
import (and the workshops, UI kit and editor kit built on them).

**Options rejected (2026-11-07):**

- **A custom Godot build** (engine fork): only for one specific patch the public API cannot
  reach, such as the renderer-thread waits (WhereWorkRuns.md §3.1) or mesh shaders. It means
  building the engine, redoing patches on every upgrade and shipping custom editors to every
  worktree.
- **Bevy** (Rust ECS, rendering already pipelined on its own thread, wgpu compute): a rewrite
  of everything in Rust, no mature editor, no Jolt, breaking releases every few months.
- **An entirely custom engine**: years of work on editor, UI, audio, input, assets and tools.

**What changes, and the measured problem each one targets:**

| Area | Now | Brick engine | Targets |
|---|---|---|---|
| Drawing bricks | Face bake per chunk, mesh upload, a node | Bricks as rows in a GPU buffer, drawn GPU-driven (indirect draws) through RenderingDevice into Godot's frame; breaking a brick clears a slot | First-hit lag (promotion + bake), second-long bakes, upload stalls |
| Debris collision | A Jolt body per piece from merged boxes, nodes and shapes made on the main thread | Pieces as data rows; grid-against-grid collision in our own solver or a Jolt world linked into the extension | Fracture/spawn ticks (42 ms), 1–2 ms collision per promotion |
| Pieces and islands | A node per piece, main thread only | Flat arrays updated across threads | Island tick 8–12 ms |
| Structure solve | C++ worker, 3–6 ms a tower | Compute shader, or a solve that only updates what changed | The second before a building falls |
| Netcode | Jolt is not deterministic across machines | Our own fixed-point debris physics can be identical everywhere: send commands, never debris positions | Multiplayer.md's second stream |

**Order:** each step lands alone and is measured against the current path.

1. **Brick renderer prototype.** One building drawn from a brick buffer next to the baked
   version: frame time, GPU time and triangles. Drawing bricks one by one instead of baked
   culled faces may cost more triangles; the prototype decides.
2. **Debris physics in the extension.** Loose pieces leave Godot's physics; the player, vehicles
   and shots stay in it. The bridge between the two worlds (standing on debris, shots hitting
   pieces, pieces hitting the player) is the main design work.
3. **GPU or incremental structure solve.**

## Consoles from Godot (checked 2026-11-07)

Godot ships no console exports (console SDKs are under NDA, so they cannot be in open source).
The routes are **W4 Games** (W4 Consoles) or a porting studio. Either way the studio must also be
a licensed developer with each platform holder (ID@Xbox, PlayStation Partners, Nintendo) and use
their devkits.

**W4 Consoles, as listed on its page:** Starter $800 a year per platform or $2,000 for all
(under $300k revenue or funding, up to 30 people); Pro $4,000 per platform or $10,000 for all;
Enterprise quoted. PS5, Xbox Series X|S, Switch; Switch 2 in beta and billed separately.
Godot 4.4–4.6. C# is beta on Switch and Xbox only. **GDExtension on consoles is not mentioned:
ask W4 before relying on it.**

What our game adds to a port:

| Need | Why it costs | Plan |
|---|---|---|
| Three native extensions: `brick` (ours), `zylann.voxel`, `limboai` | Consoles limit or forbid loading DLLs; each must be built with the console toolchain | Ask W4 if GDExtension works; if not, build all three as engine modules (voxel and LimboAI support module builds; ours needs a module wrapper around the same sources) |
| Jolt physics | Must be in the console engine build | Built into Godot since 4.4; confirm W4's builds include it |
| Online co-op | Each platform's sessions, invites, friends, crossplay rules and its certification checks; W4 does not list networking | The largest unknown: platform SDK work per console, plus relay or server hosting |
| Memory and speed | Series S (10 GB shared) is the hardest target and Xbox requires it; Switch 1 (4 GB) is out of reach | Our Legion Go budgets are close to Series S class; PS5 and Series X have headroom |
| Certification | Suspend/resume, controller loss, saves, user accounts, rating boards, every patch | Weeks per platform at first, then per update |
| Staying current | Each Godot upgrade waits for W4's matching version | Upgrade Godot only to versions W4 supports |

Rough cost (an estimate, not a quote): W4 $2,000–10,000 a year; devkits and age ratings in the
low thousands; the port itself weeks to months of engineering, or a porting studio (one
developer's figure for a small game was ~$20k per title; a game with native extensions and
online co-op will cost much more). The online platform work and Series S performance are the
real costs, and they are the same in any engine.
