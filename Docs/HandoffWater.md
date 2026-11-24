# Handoff: the mine world's water

From a cloud chat with no Godot (2026-11-24), to a chat with the project and
Godot. Area: **Terrain and water** (`brick_fluid.*`, `scripts/water/`,
`shaders/water*`, `shaders/sea_wave*`). The terrain work has its own handoff
(Docs/HandoffTerrainRegions.md), already with another chat.

## Where the work is

- Branch **`claude/terrain-brick-system-zoyz08`** (FroznExplosion/brickcity),
  docs only, on top of main `157b0b0`. Not merged into main.
- **Read: `Docs/MineWaterNext.md`** -- the user's design (2), what changes
  against what is built (3), the decisions to ask (3), levelling (4), visual
  bugs (5), cost (6), the stages (7), research (1). What is built is
  Docs/MineWater.md; the code is `gdextension/brick/src/brick_fluid.cpp`.

## The user's design, in short

- **Oceans, lakes, rivers: infinite, flat source bricks.** The grid never
  moves; waves are drawn and queried (BrickWave) -- swimmers, floating things
  and boats ride them. A bucket on a wave (crest or trough) takes from the
  source under it.
- **No bricks placed on water**: build up from the floor, out from a beach,
  or down from above. A brick touching source water anywhere acts as a beach
  there; taking it out gives the water back.
- **Everything else is finite and drainable**: ponds, puddles, cave pools,
  above or below the surface, poured water. Finite water collects.
- **Infinite water never collects**: a stream from a source runs like
  Minecraft's and adds water nowhere.
- **Springs** stay infinite, with a running waterfall.
- **The source bucket stays**; a source touching FULL finite water turns
  those full bricks infinite.
- **Rain later** adds finite water that collects.

## What it changes (MineWaterNext.md 3)

- Lakes and rivers get **waves** like the sea (they are flat and wave-less
  today); `surface_at`, floaters and swimming ask the wave at any body's
  level (today only within 3 m of the sea line).
- The bucket's aim hits the **drawn wave** over a source column.
- The builder **refuses a brick on water** (today it places into water and
  deletes it); the **beach** (the real band, today the sea only) on every
  source body; a hole left by a removed brick **refills**.
- **Three rules that make finite water from fed water go**: a cut-off stream
  becoming still water (4.1.6), a pit under a fall filling as still water
  (4.5), fed water over a pond giving its cells back as still water (4.2.5).
- **Full still water beside a source becomes source** (today it drains into
  it, 4.2.4).

## Ask the user first

1. **Their visual bug list** (where, what; pictures if they have them). The
   docs know one: the sea's wave tiers are a little lighter than the fluid's,
   so the real band's edge shows about 50 m out.
2. **A. "Out from a beach"**: terrain bricks join only up and down, so a brick
   laid beside a beach over water falls in the collapse. (1) build up from the
   shallow floor (no rule change, recommended now) or (2) a side joint at the
   water's top course (with the later side studs).
3. **B.** A source into a brim-full pond: the whole connected full body turns
   infinite (recommended) or only the bricks touching it?
4. **C.** Keep thin finite water drying (Minecraft-like), or lose finite water
   only to buckets and drains?

## Stages (MineWaterNext.md 7)

V0 the list and decisions -> V1+ visual fixes -> S1 the fed-to-finite rules
off -> S2 full still beside a source becomes source -> S3 waves on lakes and
rivers, wave queries everywhere, the bucket on a wave -> S4 no placing on
water, beaches on every body, holes refill -> W2 re-measure the tick (release
build, editor closed; 885 ns a flowing cell, 173 ns still, 2026-11-17) ->
P levelling still bodies so finite water fills its shape (U-bends, sealed
rooms) -> W1 water reads the terrain's kept cells (after the terrain chat's
stage A) -> W3 far sections compressed -> rain, packed tops, with the user.

Checks each stage: `fluid_probe` (headless), `-- --gate=water`,
`-- --gate=gen` where generation changes. Add probe checks for each new rule
(listed per stage in MineWaterNext.md 7).

## Research kept (MineWaterNext.md 1)

Flowcraft is closed source (All Rights Reserved), a GPU simulation, single
player only. Flowing Fluids (finite, 1-8 levels, plugs caves at generation,
rain refill), Gradient (open, conserved, lazy regions), mc-fluid-physics
(Apache 2.0, a hybrid), DwarfCorp (CA write-up). Ours is the same or ahead on
volumes, conservation, active cells, cave sealing and multiplayer; Flowcraft
is ahead only on water filling its shape (stage P). Do not move the water to
the GPU: gameplay reads it on the CPU, read-backs break CLAUDE.md, the GPU is
the frame's limit already.

## Rules to keep (CLAUDE.md)

Own worktree (godot-cpp junction removed FIRST before `git worktree
remove`); `override.cfg` from `tools/test_window.cfg`; launch from Bash; one
windowed pass at a time, heat summary after each (`python tools/heat_sum.py`);
timing only with the editor closed; no renderer read-backs or worker waits
during play; stage only your own files; merge small and often.
