# Reference — Ceramic Edge (FPS movement, view model, gun feel, grapple)

**Location:** `C:\Users\lbaun\Documents\ceramicedge`
**Stack:** Godot 4.6.1 · GDScript · Jolt. A small C++ extension (`native/`, active ragdoll) that
nothing here needs.
**State:** a first-person movement shooter prototype, far along. Titanfall 2 depth, Mirror's Edge
rooftops, ceramic enemies that shatter. A 3,100-line movement controller, a procedural view model,
a recoil and spread model, a whip grapple, a pause/options menu module, and **Forge** — an in-game
level editor with its own test suite (`forge/`, ~100 smokes).

**Why it is here:** it is the best-tuned first-person movement and gun feel we own. This game is a
co-op mech FPS ([AI.md §0](../AI.md#0-decided)), and its player needed exactly what Ceramic Edge
spent months tuning: momentum, a slide, a wall-run, a mantle, a gun that moves in the hands and a
view that kicks.

**What this game is not:** Ceramic Edge's player holds **two guns** (one per hand, per-hand fire,
per-hand ammo) and has **abilities** — a telekinetic pull, a vortex shield that catches bullets,
slow motion, a dash tied to slow motion. Printed Brick City's player is an ordinary FPS player:
**one gun, no abilities**. Everything below is read through that filter; §7 lists what was left
behind and why.

Primary sources: `Docs/01_design_spec.md`, `Docs/10_movement_actions.md` (the action set and its
clearance rules), `Docs/06_player_movement_full.md` and `07_player_movement_final.md` (tunables),
`Docs/16_grapple_hook.md`, `Docs/24_surface_response.md`, `Docs/03_player_code.md`, and the code
in `scenes/player/`, `scenes/weapons/`, `scenes/ui/`.

---

## 0. What came across (2026-09-29)

| Ceramic Edge | Here | How it changed on the way |
|---|---|---|
| `PlayerMovement.gd` — locomotion, slide, wall-run, wall-jump, vault, ledge grab, coyote, jump buffer | [`scripts/pawn/pawn_moves.gd`](../../scripts/pawn/pawn_moves.gd) (`PawnMoves`) | A motor behind `PawnIntents`, not a player script: it never reads input. Speeds in the figure's own units (§2.1). Vault and ledge grab merged into one **mantle** |
| `PlayerGrapple.gd` + the grapple states | `PawnMoves` (the GRAPPLE state) | Hooks **any** solid surface, not authored anchors; Q, hold to keep the line (§6) |
| `ViewmodelSway.gd` — sway, bob, recoil spring, land dip, wall retract | [`scripts/pawn/player_view.gd`](../../scripts/pawn/player_view.gd) (`PlayerView`) | One hand. Adds aim-down-sights, a sprint pose, a reload pose (§3) |
| Recoil + camera shake in `PlayerMovement` | `PlayerView` | View kick per gun class, recovered once the trigger rests; shake on the frustum offsets |
| Spread bloom in `Weapon.gd` | [`GunController`](../../scripts/combat/gun_controller.gd) `bloom_per_shot`, `spread_mult` | Opt-in, so a soldier's gun behaves exactly as before; every roll still the gun's seeded RNG |
| `Reticle.gd`, `AmmoOverlay`, `HealthOverlay` | [`scripts/pawn/player_hud.gd`](../../scripts/pawn/player_hud.gd) (`PlayerHud`) | Crosshair gap = the real cone at the real FOV; hitmarkers stay `CombatFeedback`'s |
| Hor+ FOV (`PlayerController._apply_fov`) | `PlayerView` | Horizontal 90°, converted to the camera's vertical FOV per aspect |

The gate for it is [`tools/moves_probe.gd`](../../tools/moves_probe.gd) (the moves) and the city's
`-- --play` pass (the pawn in the city, with the view and HUD on).

---

## 1. What exists there

| Piece | Where | What it is |
|---|---|---|
| Player root | `scenes/player/PlayerController.gd` | `CharacterBody3D`; routes input to components; FOV; the pull/shield/grapple button logic |
| Movement | `scenes/player/PlayerMovement.gd` (3,116 lines) | 12 states: GROUNDED, AIRBORNE, SLIDING, DASHING, VAULTING, WALL_RUNNING, AIR_SLIDING, CROUCHING, LEDGE_HANG, WALL_SLIDE, GRAPPLE_ZIP, GRAPPLE_SWING |
| View model | `scenes/player/ViewmodelSway.gd` | Procedural motion of both hands' slots |
| Hands | `scenes/player/PlayerHands.gd` (1,649 lines) | Two-hand item economy, stow, IK plants on walls and ledges |
| Grapple | `scenes/player/PlayerGrapple.gd`, `scenes/props/GrappleAnchor.gd` | Whip on authored anchors: zip, swing, yank |
| Abilities | `PlayerPull.gd`, `PlayerShield.gd`, `PlayerSlowMo.gd` | Telekinetic pull, vortex shield, slow motion |
| Health | `PlayerHealth.gd` | Health + a "gold" regen bar, delayed regen |
| Weapon | `scenes/weapons/Weapon.gd`, `WeaponStats.gd` | Hitscan from the camera, bursts, pellets, projectiles, bloom, recoil, casings, slide/bolt kick, belt feed |
| HUD | `scenes/ui/Reticle.gd`, `AmmoOverlay.gd`, `HealthOverlay.gd`, `CombatFeedback.gd` | Dot reticle with hitmarkers, per-hand ammo, health, damage wedges and a low-health vignette |
| Surfaces | `scripts/systems/Surfaces.gd`, Doc 24 | Material id → impact sound, spark, footstep sound |
| Level editor | `forge/` | Forge: brush/terrain/cave tools, packaging, Steam Workshop. Not a player system; see [reddawn §8](reddawn.md#8-forge-style-placement-and-snapping) for placement |

---

## 2. Movement

### 2.1 Numbers, and why ours are different

Ceramic Edge's operative is a 1.8 m human who walks at 8 m/s and sprints at 11 — arcade speed. The
figure here is four bricks (1.68 m) and walks 6.7 and runs 13.3 **courses** a second (2.8 and
5.6 m/s, [`pawn.gd`](../../scripts/pawn/pawn.gd)). The moves were rescaled to the figure rather than
the figure to the moves:

| Move | Ceramic Edge | Here |
|---|---|---|
| Sprint | 11 m/s | `Pawn.RUN_SPEED` 5.6 m/s |
| Slide boost | 14 m/s, 1 s free, then 8 m/s² | 1.3 × run (7.3 m/s), 0.35 s free, then 5 m/s² |
| Wall-run | 9 m/s, 4 s, 1 s level | 1.15 × run, 1.6 s, 0.6 s level with a lift onto the wall |
| Mantle reach | ledge band to 2.4 m | body + 0.45 m (2.13 m, five bricks) |
| Grapple | 10–30 m/s, reach 30 m | reel to 17 m/s, reach 32 m |
| Jump | 5.0–8.6 m/s, charged | `Pawn.JUMP_SPEED` 4.2 — one course, unchanged: the city is built around it |

### 2.2 The rules that made it feel good (kept)

From `Docs/10_movement_actions.md`, worth keeping whatever the numbers become:

1. **Preserve momentum.** Actions carry speed in and out. Air control is Quake-style: input adds
   speed up to the walk's and never removes speed already above it, so a wall-jump or a grapple
   keeps its flight. (`PawnMoves._walk_tick`.)
2. **No teleports.** Transitions are eased motion, never a position set. The mantle drives the body
   along its path over 0.2–0.4 s and sets the velocity that path implies, so the camera and the gun
   read it as motion.
3. **Forgiving detection.** Coyote time and a jump buffer (0.12 s, 0.15 s). Generous probes. A
   movement game errs toward "it worked".
4. **Intent gates.** Auto moves need the input to agree: a wall-run needs the stick pushing along
   the flight (dot > 0.3), an air mantle needs it pushing into the wall. Falling past a wall with
   no input does nothing — the thing that makes auto-parkour not feel like being grabbed.
5. **Ask what fits before committing.** Every move sweeps a capsule where it will put the body:
   stand, crouch, or refuse (their "clearance bands"). The mantle here lands crouched under a low
   ceiling and refuses where neither fits.
6. **The mantle path is an L, never a diagonal.** Straight up in front of the face until the feet
   clear the lip, then across. Their old arc cut the corner *through* the wall and relied on
   collision being off — which is how players climbed through walls. Each leg is swept with
   `test_move` before the mantle starts.
7. **Walls are identified by facing, not by collider.** Their baked levels put every wall on one
   collider, so "the same wall" is "a wall facing the same way" (normal dot > 0.8). Same here, for
   a different reason: a building's bricks are one compound body.

### 2.3 Traps they paid for

- **Phasing through an obstacle is coarse.** A collision exception on "the wall I'm vaulting"
  switches off every wall on that body. Their fix — collision on unless the path truly enters the
  obstacle — is moot here because the L-path never enters it; **do not add phasing**.
- **Air-crouch was switched off**: a top-anchored crouch capsule sank the origin below the floor
  and broke every feet-relative test. The pawn crouches with the feet planted (`Pawn._set_height`),
  which is the fix.
- **Reel by distance, not by time.** A time-ramped pull overshoots; speed proportional to the
  remaining distance (clamped) arrives cleanly. The grapple here accelerates toward the hook, caps
  its speed, and only lets the line shorten.
- **Snag release.** A zip that moves a fraction of what it asked for for ~0.3 s lets go rather
  than grinding. Kept (`_g_stall`).

---

## 3. View model and camera feel

`ViewmodelSway.gd` is the reason Ceramic Edge's guns feel held. Its channels, and what came across
into `PlayerView`:

| Channel | How | Kept |
|---|---|---|
| Look sway | The rig lags and **leans** with the turn rate. The rate is **low-passed** first: mouse deltas arrive in spikes, and a gun chasing the raw rate jitters | yes |
| Tilt about the muzzle | The lean is applied about a point ~0.6 m ahead, so the muzzle stays near the crosshair while the body of the gun swings. The single best idea in the file | yes |
| Move bob | Sinusoid scaled by ground speed | yes, by stride distance |
| Recoil spring | Underdamped spring: back, up, muzzle up, a random bank. Applied **after** aim convergence so the kick really throws the muzzle | yes |
| Jump/land spring | Dip on landing proportional to fall speed | yes |
| Air follow | Hands sink rising, float falling | yes |
| Wall retract | A box sweep pulls the gun back off a wall instead of poking through | yes, as one ray |
| Weight | Heavier guns sway less and slower | not yet — our guns have no weight stat |
| Two-hand convergence, hand plants on walls, ledge grip IK | — | no: one gun, no hand IK |
| — | Fit to the hands: each generated model is measured, scaled to its class's length (`VIEW_LENGTH`) and anchored at the top of its back end, so hip, sights, sprint and reload poses place any gun the same way | new here: our guns are whatever size their parts make them |

Camera, from `PlayerMovement`:

- **Recoil kicks the view, then recovers.** Here the recovery waits until the trigger rests
  (`KICK_RECOVER_AFTER`) and never returns more than the rounds put on — a player who pulled down
  against the climb keeps it.
- **Shake on the frustum offsets** (`h_offset`/`v_offset`), trauma², never on rotation — so it can
  never corrupt the look angles or the wall-run lean.
- **Hor+ FOV**: the setting is horizontal degrees, converted per aspect ratio, so an ultrawide sees
  more to the sides instead of losing the top and bottom.
- Not kept: the reticle 4% below centre (their aim ray was pitched to match; ours shoots from the
  centre), the eye pivot and look-down push.

---

## 4. Shooting

`Weapon.gd` + `WeaponStats.gd`. Our guns are BoomerBorder's generated ones
([boomer-border §5](boomer-border.md)); what Ceramic Edge adds is the **feel** layer on top:

| Idea | Theirs | Here |
|---|---|---|
| Spread | `spread_min` flat for `accurate_shots`, then `+spread_per_shot` to `spread_max`, recovering per second | `GunController.bloom_per_shot` per class (`PlayerView.FEEL`), recovering at 7°/s, capped at 4° over the gun's own cone |
| Aim state | none (boomer shooter, no ADS) | ADS narrows the cone to 0.35×; moving widens it up to 1.6×; airborne 1.8× |
| View kick | `recoil_pitch_deg`, `recoil_yaw_deg`, `recoil_recovery` per weapon | per class in `PlayerView.FEEL`; yaw not recovered |
| Hitscan origin | camera ray, tracer from the muzzle | same (was already so) |
| Casings, slide kick, belt feed | per-weapon moving parts | not yet — needs parts on the generated guns |
| Pellets | `pellets`, `pellet_spread_deg` | not yet: the shotgun fires one ray |
| Surface response | Doc 24: material id → sound, spark, footstep | `MaterialFx` already covers impacts; footsteps not yet |

Lesson worth keeping: **a stat that decides where rounds go belongs to the gun; one that only moves
the picture belongs to the view.** The bloom and the cone multiplier live on `GunController` because
they change where a round lands; the kick, the sway and the FOV live on `PlayerView`.

---

## 5. HUD

Theirs: a dot reticle with hitmarkers (red and bigger on a kill), per-hand ammo panels, a health bar
with a regen bar under it, directional damage wedges and a low-health vignette.

Here `CombatFeedback` already had hitmarkers, damage numbers, the hurt edge and the wedge (the
arena's). `PlayerHud` adds what an FPS shows and a debug build did not: a crosshair whose gap **is**
the cone at the current FOV (so aiming visibly tightens it and running visibly loosens it), rounds
and magazine bottom right with the gun's name in its rarity colour, a bar per defence layer bottom
left, the grapple's recharge, a reload bar, a scope on the sniper, and the keys for the first ten
seconds. The city's stats and blast reticle are put away on foot (F1 still shows the stats).

---

## 6. Grapple

Theirs (Doc 16): a whip on the melee button that attaches only to authored `GrappleAnchor` nodes —
ZIP (reel to it, then the ledge logic climbs the lip), SWING (a pendulum done as a velocity
projection, not a position snap), YANK (rip a linked target down). One hand stows its gun while the
line is out.

Here: **Titanfall's grapple, not Indiana Jones's whip.** A city of bricks has no authored anchors,
and a line that bites anything solid is what a pilot has. Q shoots it at whatever the eye is on
within 32 m; hold to keep it, release to let go, jump to let go with a kick up. The swing's
lesson came across as the constraint — the line only shortens, and motion away from the hook is
projected out of the velocity. A miss costs half a second; a use costs three. If the body it hooked
goes away (a piece of wreckage cleared), the line lets go; a brick shot out of a standing building
does not free its body, so the hook holds where it bit.

---

## 7. What was left behind, and why

| Theirs | Why not |
|---|---|
| Two guns, per-hand fire and ammo, throw-your-gun | One gun, like any FPS |
| Telekinetic pull, vortex shield, slow motion, dash | No abilities |
| Air-slide, ground hop | Sci-fi excess their own Doc 10 recommended against |
| Wall-stick / wall-slide, same-wall climb budget | A mechanic for a player with full hands; a wall-run and a mantle cover the verticality |
| Ledge hang, shimmy, corner wrap, beam ladders | Assassin's Creed climbing; the mantle is enough for an FPS |
| Charged jump (tap small, hold big) | The city's jump is one course by design |
| Halo fall-death timer, void recovery | Fall damage already exists (`Pawn.SAFE_FALL`, Collapse.md 4.4) |
| Skulls/modifiers, floor-is-lava | Their game's run structure, not ours |
| Ceramic shaders, fracture, Synty art | Destruction is bricks ([reddawn](reddawn.md)); no third-party models ship (legal brief) |

---

## 8. Still worth taking later

- **Footsteps by distance, sound by surface** (Doc 24): a step every 2.1 m of ground covered, so a
  sprint steps faster with no second rate to tune; the sound from what the feet are on.
- **Pellets** for the shotgun, and **casings** with inherited velocity.
- **Gun weight** into the sway (heavier = slower, smaller).
- **Swing** as a second grapple mode if a level wants it.
- **Menu module** (`menu/`): options with a horizontal-FOV slider and sensitivity/invert that the
  player controller reads at spawn — their note: the settings autoload only pushes *changes*, so
  read it once at spawn or the saved value is ignored until touched.
