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
