# Handoff: the universe -- star systems, ships, garrisons, saving (Planets.md 11.12)

For a new chat. Read this, then the repo's CLAUDE.md, then Docs/Planets.md §11.12: "Frames" for how the
world moves, and **"What is not done"** for the open list. The plan and results of every step are there.
Written 2026-11-02; main at the time: `979b0b1`.

## The user's rules for this work

- Write the plan into Docs/Planets.md before building; record results there after, as they came out.
- Merge into main (`--no-ff`) and push when something works, small and often. Standing OK, no need to ask.
- Only terrain is low-poly: everything else is bricks, furniture, items.
- The user budgets chats by weekly usage: read `get_usage`, land small, say what a step cost.
- "next please" means: take the top of the list you last gave, in this chat.
- Say plainly what was not checked. A test that passed before the last change is not a test of it.

## What is built (all merged)

Steps 1-7 of 11.12, then these, each in Planets.md under its own heading:

- **Star systems**: `Universe` (400 systems), `StarSystem`, `PlanetSystem`. Analytic orbits off a clock;
  the planet the player is on stands still with an identity basis and the rest moves round it.
- **Stations and a ship**: `SpaceStation`, `SpaceShip`, damage, docking by speed match, rams.
- **Generated worlds**: towns, trees, biomes by warmth and air.
- **Jumps**: M galaxy map (opens anywhere, says why no jump), J jumps, in open space aboard the ship.
- **Open space** is past 5 radii (`SHELL`). Gravity is zero there; aboard, the ship's own.
- **Debris and rocks**: `Drift` records, `RockField` rings and belts; ships stopped by rocks along their step.
- **Markers**: `SpaceMarkers`, windowed only. Green settled, white planets, blue moons and stations.
- **The AI on any world**: `PlanetScene.ai_of`, `setup_ai(dir, body)`, `PlayerKit.use_services`.
- **Garrisons**: `PlanetGarrison`. Generated towns wake at 250 m and clear for good. Home's town wakes at
  130 m (the spawn is 220 m off) and comes back in waves of 4, 6, 8, 8... with 20 s between.
- **Saving**: `UniverseSave` (`user://saves/<universe_id>/`, `universe.dat`, `s<system>_b<body>.dat`),
  `PlanetSaver` (reads, applies as things are made, `resume`), `UniversePanel` (M then U; N new, Enter
  play). After zylanntest's model: the seed makes the worlds, a file keeps what happened to them.

The room-modules chat (`bc-modules`) owns ship and station interiors; `--gate=hull` is theirs. The
materials chat (`bc-wood`) changes the DLL now and then.

## Testing

Console Godot and the worktree setup are in CLAUDE.md. Copy main's DLL into the worktree rather than
building (check its date against the last C++ commit), `--import`, then:

`--headless --path . res://scenes/planet.tscn -- --gate=<name>`

| Gate | Checks | Limit to give it |
|---|---|---|
| `seat` | 16 windowed, 13 headless: jitter, leaving the seat, map, gravity, markers | 200 s |
| `belt` | 6: a belt from a turned ship, slow flight, rocks at speed | 170 s |
| `home` | 11: the waves, their kinds, wave 4's tank | 240 s |
| `garrison` | 17: a world's AI, sleep and wake, down and up | 280 s (170 stops it on the flight home) |
| `jump` 10, `ship` 9, `dock` 9, `worlds` 8, `rocks` 4, `debris` 8, `system` 17 | | 280 s |
| `falling` 5, `mechwave` 2, `squad` 10, `far` 11, `pawn` 12 | the AI and the pawn on a planet | 240 s |
| `bricks` 9, `damage` 12, `fall` 7, `hits` 8, `topple` 6, `storey` 12 | buildings; run these if `PlanetBuildings` changes | 240 s |
| `save --stage=1`, then `2`, then `3` | separate processes, in order; 1 wipes `user://saves_test/`; 3 runs on into stage 4 | 250 s each |

`--headless --script res://tools/system_probe.gd`: 34 checks, the generator.

Headless RID errors on waking a world are the dummy renderer's, known and harmless. Gates never touch the
player's saves.

## Traps, all paid for

- **Chaining hides failure.** `| tail` before `&&`, or `;`, carries on after a failure. In this work it
  committed a false message, started a windowed run on a held-back chip (100.1 C) and merged into the
  main folder mid-conflict. Land with `git merge ... > log 2>&1 || { ...; exit 1; }`, and end the command
  at a held-back heat check.
- **Display asleep**: 2-6 fps windowed, and gates fail on their time limits. After a run, read the fps
  (the HUD in a shot, or `smooth`'s line in `seat`) before believing a failure. The user's AC timeout is 5 min.
- **A log of 100,000+ lines** means errors each frame have slowed the game: a gate then "fails" on time.
  Group the lines before looking anywhere else. It was the first marker build, and later `aim()` making a
  singular basis.
- **float32**: a planet is 1.6e6 m from the star, belts 2-6e6, good to 0.125-0.5 m. Nothing near the player
  may be placed through the star's frame: go off the planet (`ship_world`, `orbital_local`) or the ship
  (`_belt_near`, `SpaceShip.fine`). Angles are float32 too, in `Basis()`: wrap them (`StarSystem._turn`).
- **Physics interpolation is on at 30 Hz.** A node moved in `_process` needs `PHYSICS_INTERPOLATION_MODE_OFF`.
- **Bodies far from the player fall through the ground**: it is coarse there and swapped as they near.
  `PlanetGarrison.hold` is the way; anything new left awake on a planet needs it.
- **ADVANCE fails at once with no contact.** To send a squad at someone it cannot see, `AIServices.noise`.
- **`await process_frame` comes before that frame's `_process`.** Measuring motion, use the last step's delta.
- **A scene's `tree_exiting` is too late**: its children have gone. Save on `NOTIFICATION_WM_CLOSE_REQUEST`
  and `before_leaving`.
- **Class cycles crash the quit** (139): where two `class_name`s would type each other, one is untyped
  (`scene`, `ps`).

## Not yet seen

- **The user has not played saving.** Press the keys: leave, come back, change universe. The panel has
  only been driven by the gate, never by keys.
- `save --stage=3` is two-valued on one build: the player comes back 0.50 m or exactly 2.90 m off (limit
  1.5), on the far world with the blown wall. 3 runs on 2026-11-02: 2.90, 2.90, 0.50; once with this day's
  fixes reverted: 0.50, so those are not cleared. A landing on two different surfaces? Not looked into.
- Home's soldiers hunting a player they have lost, on screen: headless only.
- Frame times in a fight and on arrival: every number so far had the editor open or the display asleep.
  Close to 165-315 ms at arrival. CLAUDE.md's rule applies.
- A belt's far disc from afar, since the star got a basis. `keep_over_ground` has never fired.
- One exit 127 mid-fight on 2026-10-31, no error, nothing in the Windows log; not seen since.

## What to do next

The user chooses. In the order I would take them:

1. **Rubble in saves**: done (rubble on a world, pieces adrift and fallen from space; `ChunkRecord`, no
   C++). Not tried: a real save and load with pieces adrift (the gates go through bytes).
2. **Something on a planet besides rifles**: done for home's waves (five foot kinds, a tank from wave 4).
   A mech from wave 5 (2026-11-06). Open: generated towns' squads are rifles and assault only; a wave's tank
   and mech are not saved.
3. **Ship damage**: rams hurt it now (`take_ram`). Open: rocks, its holes from afar before it is laid.

The full list is Planets.md, "What is not done".
