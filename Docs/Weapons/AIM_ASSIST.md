# Aim assist, and the gun numbers it works with

`scripts/combat/aim_assist.gd` (`AimAssist`). Built 2026-10-11. Probe: `tools/aim_assist_probe.gd`
(23 checks). Section 9 gives every gun's worst and best numbers, rolled by
`tools/gun_stat_table.gd`.

Line numbers below are as of 2026-10-12. Search for the constant's name if they have moved.

---

## 1. What it is for

Help the player land shots without the feeling that the game is aiming for them. The view
should move as little as possible, while shots still land where the player meant them to go.
Halo is the model:

- slowdown near an enemy;
- the view follows an enemy's *movement*, never a fixed point;
- a little bullet magnetism.

Not Call of Duty's hard snap.

Rules every piece keeps:

- **The player can always overpower it.** Centering never pushes against the way the player
  is turning.
- **A still enemy does not drag the view.** With no input and no firing, the view does not
  move.
- **It only helps sideways** (unless Vertical Help is on). A player aiming at the head keeps
  the head.
- **No help past the gun's range.** A shotgun does not pull toward someone it can't reach.

## 2. One frame, in order

1. **The mouse moves.** `DebugCamera._input` (`scripts/debug_camera.gd:191`) passes the turn
   through `AimAssist.filter_look`, which slows it over a target (friction) and remembers that
   the player turned.
2. **`AimAssist._process`** (`aim_assist.gd:170`) runs after the camera has been put at the
   eye:
   1. `pick()` finds the target (§4).
   2. It builds or drains the **engagement** meter.
   3. **Tracking:** turns the view by how far the target's aim line moved across the view since
      last frame.
   4. **Centering:** a small pull toward the line, only if the player turned or fired this
      frame, and never against their turn.
   5. **Snap:** on the frame the sights start up near a target, it queues a part-way turn,
      spent over 0.16 s.
   6. It turns the camera with `camera.add_look`.
3. **A round fires.** `GunController._fire_one` (`gun_controller.gd:551`) asks
   `AimAssist.bend` for the round's centre line before spread is added. A near miss is bent
   onto the aim line at the crosshair's height.

`CityScene._enter_pawn` (`city_scene.gd:4195`) makes one `AimAssist` and gives it to the
camera (`camera.assist`) and the player's gun (`_gun.assist`). It does nothing while the player
is not on foot (`active()`).

## 3. The pieces

| Piece | What it does | Moves the view? | Function |
|---|---|---|---|
| **Slowdown** (friction) | The look turns slower over and near a target. Capped at 80% slower. | No | `filter_look` |
| **Tracking** (magnetism) | The view follows the target's motion across the screen: its strafe, or the player's own movement. A still target is never pulled toward. | Only by the target's motion | `_process` |
| **Centering** | Closes a share of the sideways gap each second while the player turns or fires. | Gently | `_process` |
| **Snap when aiming** | Raising the sights within 2.5 half-widths of the line closes part of the gap (default 60%) over 0.16 s, once per aim. | Once | `_process` |
| **Bullet magnetism** | A round within the target's half-width plus a few tenths of a degree is bent onto the line. | No | `bend` |
| **Engagement** | Firing on a target builds to full in 0.5 s and is lost in 0.3 s. At full, tracking and centering are 1.5× as strong. | — | `_process` |

## 4. Picking the target, and its aim line

**Candidates** (`candidates`):
- every pawn of another side in `AIServices.pawns`;
- every node in the `mechs`, `tanks` and `trucks` groups that has `team` and `health`.

Dead ones are skipped.

**The target's shape** (`body_of`, `aim_assist.gd:359`):

| Target | Feet | Top | Width | Weak points |
|---|---|---|---|---|
| Pawn | `Pawn.feet()` | feet + eye height + 0.2 m | radius 0.4 m | its `CritSpots` facing the player |
| Mech | `Mech.feet()` | + `Mech.HEIGHT` | `Mech.RADIUS` | hatch and power cell, where `MechLayers.side_faces` |
| Tank or truck | its collision shapes' box | box top | half the box's width | none yet |

**Facing** (`facing`, `aim_assist.gd:409`):
- A weak point within 0.15 m of the body's middle (a head) faces every way.
- Otherwise it must not point away from the player: dot product > −0.1.

So a weak point on the back is ignored until the player is behind.

**The aim line** (`describe`, `aim_assist.gd:286`):
- A vertical segment from 0.1 m above the feet up to the top.
- It stands on the facing weak point nearest the crosshair, or on the body's middle when none
  faces.
- For a slow projectile it is moved to where the target will be when the round arrives (lead).
- The assists aim at its **nearest point to the crosshair** (`line_point`). Anywhere between
  the feet and the top, the vertical error is zero.

**The cone:**
- Half-width = atan(width / distance), so it shrinks with distance on its own.
- From the hip the cone is half-width ×2.5 + 2.5°; down the sights, ×1.6 + 1.2°.
- **Weight k** is 1 inside the half-width, falling to 0 at the cone's edge. Every piece is
  multiplied by k.

**Choosing:**
- The score is distance from the crosshair ÷ cone. Under 1 qualifies, and the lowest score
  wins.
- The current target scores 25% lower, so the assist does not flick between two.
- The three best are checked for line of sight (`Layers.HITSCAN_MASK`). Behind bricks means
  not picked.

**Range** (`GunRange.of`, `scripts/guns/gun_range.gd`):
- Past the gun's range: no target.
- Over the last fifth of the range, all strength fades to 0.

## 5. Mouse and controller

- `AimAssist.device` is whichever was used last to look: mouse motion, or a stick moved past
  0.4.
- Each device has its own level and its own base numbers. The controller's are stronger.
- Controller look is **not in the game yet**, so today it is always the mouse.

## 6. Settings

The Options > Aim Assist tab is built by `BrickcityMenuHost._build_aim_tab`
(`scripts/brickcity_menu_host.gd:276`). The rows are at `brickcity_menu_host.gd:172` (simple)
and `:182` (advanced). The values land in static fields on `AimAssist` (`aim_assist.gd:34–45`)
through `_apply_setting` (`brickcity_menu_host.gd:131`).

| Row | Id | Default | Field | Effect |
|---|---|---|---|---|
| Mouse Aim Assist | `aa_mouse` | Medium (for testing) | `mouse_level` | Off, Low, Medium, High → ×0, ×0.6, ×1, ×1.5 on every piece (`LEVEL_MULT`) |
| Controller Aim Assist | `aa_pad` | Medium | `pad_level` | same |
| Snap When Aiming | `aa_snap` | on | `snap_on_aim` | the snap on raising the sights |
| *Advanced:* Slowdown | `aa_friction` | 1.0× | `friction_scale` | × the friction |
| Tracking | `aa_tracking` | 1.0× | `tracking_scale` | × the tracking |
| Centering | `aa_centering` | 1.0× | `centering_scale` | × the centering |
| Bullet Magnetism | `aa_bullet` | 1.0× | `bullet_scale` | × the bend's extra degrees; 0 = off |
| Snap Strength | `aa_snap_strength` | 60% | `snap_strength` | share of the gap the snap closes |
| Stronger While Firing | `aa_engage` | on | `engage_on` | engagement |
| Limit to Weapon Range | `aa_range` | on | `range_limit` | off = no range limit, no fade |
| Aim for Weak Points | `aa_weak_points` | on | `weak_points` | off = the line is always the body's middle |
| Vertical Help | `aa_vertical` | off | `vertical_pull` | on = centering and snap also pull up and down onto the body |

To change a **default**, change the row's `"default"` in `brickcity_menu_host.gd` *and* the
static field's initial value in `aim_assist.gd`. A probe that never loads the menu runs on the
field.

## 7. Where to change the feel: every number

### 7.1 Aim assist (`scripts/combat/aim_assist.gd`)

Pairs are `[hip, sights]`; rows are `[mouse, controller]`.

| Constant | Line | Value | What it does |
|---|---|---|---|
| `LEVEL_MULT` | 49 | `[0, 0.6, 1, 1.5]` | what Off, Low, Medium, High multiply everything by |
| `FRICTION` | 51 | mouse `[0.15, 0.3]`, pad `[0.35, 0.5]` | share the look is slowed over a target |
| `FRICTION_CAP` | 68 | 0.8 | the most the look is ever slowed |
| `TRACKING` | 52 | mouse `[0.25, 0.45]`, pad `[0.45, 0.7]` | share of the target's motion followed |
| `CENTERING` | 54 | mouse `[1.2, 2.5]`, pad `[2.0, 4.0]` | share of the sideways gap closed per second (capped at half per frame) |
| `BULLET_DEG` | 56 | mouse `[0.5, 0.8]`, pad `[0.9, 1.3]` | degrees past the target's edge a round may be bent |
| `CONE_WIDTH` | 59 | `[2.5, 1.6]` | the cone in target half-widths |
| `CONE_DEG` | 60 | `[2.5, 1.2]` | plus this many degrees |
| `SNAP_CONE` | 62 | 2.5 | the snap works within this many half-widths |
| `SNAP_TIME` | 63 | 0.16 s | how long the snap takes (the sights' rise) |
| `ENGAGE_RISE` / `ENGAGE_FALL` | 64 / 65 | 0.5 s / 0.3 s | engagement build and loss |
| `ENGAGE_BOOST` | 67 | 0.5 | full engagement adds +50% tracking and centering |
| `WEAPONS` | 71 | sniper 0.8, shotgun 1.1, rocket and grenade launchers 1.3 | tracking multiplier and projectile speed per class (the rest 1.0, hitscan) |
| `TUBE_WEAPON` | 78 | ×1.5, 32 m/s | the grenade tube's lob: more tracking, led |
| `RANGE_FADE` | 80 | 0.8 | strength fades over the last 20% of range |
| hysteresis | `pick`, 242 | 0.75 | the current target's score multiplier |
| facing slack | `facing`, 409 | −0.1, 0.15 m axis | how far round the side a weak point still counts |
| pawn top and width | `body_of`, 359 | eye + 0.2 m, 0.4 m | a pawn's aim line |

A **slow projectile weapon** such as a plasma pistol needs one `WEAPONS` row,
`&"plasma_pistol": [1.6, 40.0]`: more tracking, and led at 40 m/s.

### 7.2 Range (`scripts/guns/gun_range.gd`)

| Constant | Line | Value |
|---|---|---|
| `CLASS_RANGE` | 12 | pistol 35, revolver 40, SMG 28, rifle 60, LMG 55, DMR 90, sniper 150, shotgun 14 (pellet guns use their pattern instead), rocket 60, grenade launcher 40, arc caster 20 |
| `RANGE_SCALE` | 18 | 0.75–1.35: the most the accuracy roll can shrink or stretch it |
| formula | `of()` | pellet gun: `fire.far`; others: class range × (accuracy ÷ class base accuracy)², clamped |

### 7.3 Spread: how accurate a gun is

- Spread (degrees) = `MAX_SPREAD_DEG` × (1 − accuracy) + bloom, all × the view's multiplier.

| Where | Constant | Value | What it does |
|---|---|---|---|
| `gun_controller.gd:45` | `MAX_SPREAD_DEG` | 8° | the cone at accuracy 0 |
| `gun_controller.gd:51` | `BLOOM_MAX_DEG` | 4° | the most sustained fire adds |
| `gun_controller.gd:52` | `BLOOM_RECOVER` | 7°/s | how fast bloom drains |
| `player_view.gd:101` | `HIP_SPREAD` | 0.4 | from the hip: 40% of the cone |
| `player_view.gd:102` | `ADS_SPREAD` | 0.25 | down the sights: 25% |
| `player_view.gd:456` | run penalty | +40% at a run (+12% aimed) | |
| `player_view.gd:458` | air penalty | ×1.5 | |
| `gun_fire_mode.gd:68` | `PELLETS` | see below | a shotgun's own pattern, apart from accuracy |

Shotgun patterns (`PELLETS`):

| Kind | Pellets | Cone | Full damage to | Down to | By |
|---|---|---|---|---|---|
| light | 6–8 | 8–12° | 3–5 m | 15% | 10–14 m |
| heavy | 8–10 | 4–7° | 6–9 m | 25% | 16–22 m |

Enemy soldiers' guns do not go through `PlayerView`, so changing `HIP_SPREAD` or `ADS_SPREAD`
does not change their aim.

## 8. Tuning: symptom → knob

| It feels… | Turn |
|---|---|
| sticky or "aimbot" when sweeping past enemies | `FRICTION` hip value down, or `CONE_DEG` down |
| like the view drifts on its own | `CENTERING` down (it acts only while turning or firing); `TRACKING` down |
| loses strafing enemies | `TRACKING` up, or `ENGAGE_BOOST` up |
| fine up close, useless far | `CONE_DEG` up (the cone shrinks with distance; the degrees are the floor) |
| too strong far out | `CONE_DEG` down; `RANGE_FADE` down (a longer fade) |
| the snap jerks | `SNAP_TIME` up, or Snap Strength down |
| near misses still miss | `BULLET_DEG` up |
| one class wrong only | its `WEAPONS` row (tracking) or `CLASS_RANGE` (reach) |
| hip fire too loose or too laser-like | `HIP_SPREAD` |

Every change: rerun `tools/aim_assist_probe.gd`. It checks no drift, no fighting the player,
the head's pitch kept, range, weak points facing, bullets, the snap and a freed target.

---

## 9. The guns: worst and best of every stat

### 9.1 How a gun's numbers are made

| Step | Where | What |
|---|---|---|
| Class preset | `weapon_class.gd:41` `_PRESETS` | base damage, fire rate, magazine, crit, reload, accuracy |
| Kind | `weapon_class.gd:88` `KINDS` | heavy (Magnum, Hand Cannon, Heavy SMG, Battle Rifle…) multiplies damage, fire rate, reload, accuracy, magazine. Heavy chance by rarity: `HEAVY_CHANCE` (`:100`) 15%→40% |
| Parts and rolls | `gun_stats.gd` | each stat rolled in a band; accuracy × 0.94–1.06 (`ACC_LO`/`ACC_HI`, `:39`); DPS held to a window (`DPS_WINDOW_LO`/`HI`, `:26`) |
| Rarity | `rarity.gd:28` `MULTS` | damage ×1.00 / 1.03 / 1.06 / 1.09 / 1.12 / 1.12, Common → Mythic; modifier slots `SLOTS` (`:31`) 1/2/3/4/4/4 |
| Modifiers | `gun_modifiers.gd` | the slots' rolls: they move damage, fire rate, reload, magazine and the rest — the reason the best Mythic is far above the best Common |
| Tier | `tier.gd:26` `TIER_STEP` | damage ×1.25 a tier, nothing else |

### 9.2 Tier: damage and DPS only

| Tier | 1 | 2 | 3 | 4 | 5 | 6 | 7 | 8 | 9 | 10 |
|---|---|---|---|---|---|---|---|---|---|---|
| × damage | 1.00 | 1.25 | 1.56 | 1.95 | 2.44 | 3.05 | 3.81 | 4.77 | 5.96 | 7.45 |

For a stat at tier *t*, multiply the tables below (tier 1) for **damage** and **DPS** only. For
example, a Common pistol's worst tier-1 damage 7.5 is 7.5 × 7.45 = 56 at tier 10, and a Mythic
Magnum's best 64.2 is 478. Enemy health steps by the same 1.25, so shots-to-kill stay the same
on level.

### 9.3 The tables

How to read them:
- Each cell is **worst – best**, rolled 300 times per row, at tier 1.
- **Reload** (lower is better) and **spread** (smaller is better) are written worst first too,
  so the left number is always the worse one.
- **Damage / shot:** a heavy fires two rounds a shot. For a shotgun it's the whole blast.
- **DPS:** damage × fire rate, before crits and modifier effects.
- **Hip / ADS spread:** the cone standing still, before bloom.
- **Range:** `GunRange.of`. A shotgun's is its pattern's far distance.
- The worst damage can rise less with rarity than the best. A rarer gun's modifiers can trade
  damage for fire rate. **DPS is the fair comparison.**

Regenerate after any number changes:

```
godot --headless --path . --script res://tools/gun_stat_table.gd -- out.md 300
```

Tier check: rifle seed 1234, tier 10 / tier 1 damage = 7.451 (Tier.power_mult(10) = 7.451); other stats the same: true.

#### Pistol

| Kind | Rarity | Damage / shot | Fire rate /s | DPS | Accuracy | Hip spread | ADS spread | Range m | Reload s | Magazine | Crit x |
|---|---|---|---|---|---|---|---|---|---|---|---|
| Pistol | Common | 9.0 – 15.7 | 6.83 – 10.73 | 87 – 121 | 85% – 95% | 0.49° – 0.15° | 0.31° – 0.09° | 31 – 39 | 1.60 – 0.66 | 10 – 20 | 2.00 |
| Pistol | Uncommon | 9.2 – 17.9 | 6.60 – 10.76 | 87 – 137 | 85% – 95% | 0.49° – 0.15° | 0.31° – 0.09° | 31 – 39 | 1.59 – 0.65 | 10 – 20 | 2.00 |
| Pistol | Rare | 9.6 – 19.9 | 6.77 – 10.78 | 91 – 176 | 85% – 95% | 0.49° – 0.15° | 0.31° – 0.09° | 31 – 39 | 1.60 – 0.64 | 10 – 20 | 2.00 |
| Pistol | Unique | 10.5 – 21.4 | 6.79 – 10.62 | 95 – 175 | 85% – 95% | 0.49° – 0.15° | 0.31° – 0.09° | 31 – 39 | 1.60 – 0.63 | 10 – 20 | 2.00 |
| Pistol | Legendary | 10.4 – 23.0 | 6.80 – 10.76 | 97 – 181 | 85% – 95% | 0.49° – 0.15° | 0.31° – 0.09° | 31 – 39 | 1.60 – 0.62 | 10 – 20 | 2.00 |
| Pistol | Mythic | 10.2 – 26.7 | 6.77 – 10.75 | 97 – 182 | 85% – 95% | 0.49° – 0.15° | 0.31° – 0.09° | 31 – 39 | 1.60 – 0.62 | 10 – 20 | 2.00 |
| Magnum | Common | 26.7 – 41.5 | 2.71 – 3.50 | 88 – 118 | 89% – 100% | 0.36° – 0.00° | 0.22° – 0.00° | 31 – 39 | 1.84 – 0.75 | 10 – 20 | 2.00 |
| Magnum | Uncommon | 27.6 – 48.6 | 2.72 – 3.51 | 90 – 137 | 89% – 100% | 0.36° – 0.00° | 0.22° – 0.00° | 31 – 39 | 1.82 – 0.75 | 10 – 20 | 2.00 |
| Magnum | Rare | 28.5 – 54.8 | 2.74 – 3.51 | 93 – 171 | 89% – 100% | 0.36° – 0.00° | 0.22° – 0.00° | 31 – 39 | 1.84 – 0.74 | 10 – 20 | 2.00 |
| Magnum | Unique | 29.1 – 56.7 | 2.74 – 3.49 | 98 – 171 | 89% – 100% | 0.36° – 0.00° | 0.22° – 0.00° | 31 – 39 | 1.83 – 0.72 | 10 – 20 | 2.00 |
| Magnum | Legendary | 30.6 – 62.7 | 2.71 – 3.51 | 101 – 187 | 89% – 100% | 0.36° – 0.00° | 0.22° – 0.00° | 31 – 39 | 1.84 – 0.71 | 10 – 20 | 2.00 |
| Magnum | Mythic | 29.8 – 67.9 | 2.72 – 3.52 | 99 – 193 | 89% – 100% | 0.36° – 0.00° | 0.22° – 0.00° | 31 – 39 | 1.84 – 0.72 | 10 – 20 | 2.00 |

#### Revolver

| Kind | Rarity | Damage / shot | Fire rate /s | DPS | Accuracy | Hip spread | ADS spread | Range m | Reload s | Magazine | Crit x |
|---|---|---|---|---|---|---|---|---|---|---|---|
| Revolver | Common | 9.0 – 15.7 | 6.83 – 10.73 | 87 – 121 | 83% – 93% | 0.55° – 0.22° | 0.35° – 0.14° | 35 – 45 | 2.80 – 1.15 | 5 – 8 | 2.50 |
| Revolver | Uncommon | 9.2 – 17.9 | 6.60 – 10.76 | 87 – 137 | 83% – 93% | 0.55° – 0.22° | 0.35° – 0.13° | 35 – 45 | 2.78 – 1.14 | 5 – 8 | 2.50 |
| Revolver | Rare | 9.6 – 19.9 | 6.77 – 10.78 | 91 – 176 | 83% – 93% | 0.55° – 0.22° | 0.34° – 0.13° | 35 – 45 | 2.80 – 1.13 | 5 – 8 | 2.50 |
| Revolver | Unique | 10.5 – 21.4 | 6.79 – 10.62 | 95 – 175 | 83% – 93% | 0.55° – 0.22° | 0.35° – 0.14° | 35 – 45 | 2.79 – 1.09 | 5 – 8 | 2.50 |
| Revolver | Legendary | 10.4 – 23.0 | 6.80 – 10.76 | 97 – 181 | 83% – 93% | 0.55° – 0.22° | 0.35° – 0.13° | 35 – 45 | 2.79 – 1.08 | 5 – 8 | 2.50 |
| Revolver | Mythic | 10.2 – 26.7 | 6.77 – 10.75 | 97 – 182 | 83% – 93% | 0.55° – 0.22° | 0.34° – 0.13° | 35 – 45 | 2.79 – 1.09 | 5 – 8 | 2.50 |
| Hand Cannon | Common | 26.7 – 41.5 | 2.71 – 3.50 | 88 – 118 | 85% – 96% | 0.47° – 0.13° | 0.30° – 0.08° | 35 – 45 | 3.22 – 1.32 | 5 – 8 | 2.50 |
| Hand Cannon | Uncommon | 27.6 – 48.6 | 2.72 – 3.51 | 90 – 137 | 85% – 96% | 0.47° – 0.13° | 0.30° – 0.08° | 35 – 45 | 3.19 – 1.31 | 5 – 8 | 2.50 |
| Hand Cannon | Rare | 28.5 – 54.8 | 2.74 – 3.51 | 93 – 171 | 85% – 96% | 0.47° – 0.13° | 0.30° – 0.08° | 35 – 45 | 3.22 – 1.30 | 5 – 8 | 2.50 |
| Hand Cannon | Unique | 29.1 – 56.7 | 2.74 – 3.49 | 98 – 171 | 85% – 96% | 0.47° – 0.13° | 0.30° – 0.08° | 35 – 45 | 3.21 – 1.26 | 5 – 8 | 2.50 |
| Hand Cannon | Legendary | 30.6 – 62.7 | 2.71 – 3.51 | 101 – 187 | 85% – 96% | 0.47° – 0.13° | 0.30° – 0.08° | 35 – 45 | 3.21 – 1.24 | 5 – 8 | 2.50 |
| Hand Cannon | Mythic | 29.8 – 67.9 | 2.72 – 3.52 | 99 – 193 | 85% – 96% | 0.47° – 0.13° | 0.30° – 0.08° | 35 – 45 | 3.21 – 1.26 | 5 – 8 | 2.50 |

#### Smg

| Kind | Rarity | Damage / shot | Fire rate /s | DPS | Accuracy | Hip spread | ADS spread | Range m | Reload s | Magazine | Crit x |
|---|---|---|---|---|---|---|---|---|---|---|---|
| Smg | Common | 4.0 – 7.1 | 11.96 – 18.77 | 68 – 95 | 71% – 79% | 0.94° – 0.66° | 0.59° – 0.41° | 25 – 31 | 1.80 – 0.74 | 25 – 51 | 2.00 |
| Smg | Uncommon | 4.2 – 8.1 | 11.55 – 18.83 | 69 – 108 | 71% – 79% | 0.94° – 0.66° | 0.59° – 0.41° | 25 – 31 | 1.78 – 0.73 | 25 – 54 | 2.00 |
| Smg | Rare | 4.3 – 9.0 | 11.84 – 18.86 | 72 – 138 | 71% – 79% | 0.94° – 0.66° | 0.59° – 0.41° | 25 – 31 | 1.80 – 0.73 | 25 – 54 | 2.00 |
| Smg | Unique | 4.7 – 9.6 | 11.88 – 18.59 | 75 – 138 | 71% – 79% | 0.94° – 0.66° | 0.59° – 0.41° | 25 – 31 | 1.79 – 0.70 | 25 – 54 | 2.00 |
| Smg | Legendary | 4.7 – 10.4 | 11.91 – 18.83 | 76 – 143 | 71% – 79% | 0.94° – 0.66° | 0.59° – 0.41° | 25 – 31 | 1.80 – 0.70 | 25 – 54 | 2.00 |
| Smg | Mythic | 4.6 – 12.0 | 11.85 – 18.81 | 76 – 143 | 71% – 79% | 0.94° – 0.66° | 0.59° – 0.41° | 25 – 31 | 1.80 – 0.70 | 25 – 54 | 2.00 |
| Heavy SMG | Common | 7.3 – 11.3 | 8.59 – 11.08 | 76 – 102 | 74% – 83% | 0.83° – 0.53° | 0.52° – 0.33° | 25 – 31 | 2.07 – 0.85 | 25 – 51 | 2.00 |
| Heavy SMG | Uncommon | 7.5 – 13.2 | 8.61 – 11.12 | 78 – 119 | 74% – 83% | 0.83° – 0.53° | 0.52° – 0.33° | 25 – 31 | 2.05 – 0.84 | 25 – 54 | 2.00 |
| Heavy SMG | Rare | 7.8 – 14.9 | 8.68 – 11.14 | 81 – 148 | 74% – 83% | 0.83° – 0.53° | 0.52° – 0.33° | 25 – 31 | 2.07 – 0.83 | 25 – 54 | 2.00 |
| Heavy SMG | Unique | 8.0 – 15.5 | 8.69 – 11.05 | 85 – 148 | 74% – 83% | 0.83° – 0.53° | 0.52° – 0.33° | 25 – 31 | 2.06 – 0.81 | 25 – 54 | 2.00 |
| Heavy SMG | Legendary | 8.4 – 17.1 | 8.60 – 11.13 | 87 – 161 | 74% – 83% | 0.83° – 0.53° | 0.52° – 0.33° | 25 – 31 | 2.07 – 0.80 | 25 – 54 | 2.00 |
| Heavy SMG | Mythic | 8.1 – 18.5 | 8.63 – 11.14 | 86 – 167 | 74% – 83% | 0.83° – 0.53° | 0.52° – 0.33° | 25 – 31 | 2.06 – 0.81 | 25 – 54 | 2.00 |

#### Rifle

| Kind | Rarity | Damage / shot | Fire rate /s | DPS | Accuracy | Hip spread | ADS spread | Range m | Reload s | Magazine | Crit x |
|---|---|---|---|---|---|---|---|---|---|---|---|
| Rifle | Common | 5.4 – 9.4 | 10.25 – 16.09 | 78 – 109 | 80% – 90% | 0.64° – 0.32° | 0.40° – 0.20° | 53 – 67 | 2.40 – 0.98 | 24 – 51 | 2.00 |
| Rifle | Uncommon | 5.5 – 10.8 | 9.90 – 16.14 | 78 – 124 | 80% – 90% | 0.64° – 0.32° | 0.40° – 0.20° | 53 – 67 | 2.38 – 0.98 | 24 – 54 | 2.00 |
| Rifle | Rare | 5.7 – 11.9 | 10.15 – 16.17 | 82 – 158 | 80% – 90% | 0.64° – 0.32° | 0.40° – 0.20° | 53 – 67 | 2.40 – 0.97 | 24 – 54 | 2.00 |
| Rifle | Unique | 6.3 – 12.9 | 10.18 – 15.93 | 86 – 158 | 80% – 90% | 0.64° – 0.32° | 0.40° – 0.20° | 53 – 67 | 2.39 – 0.94 | 24 – 54 | 2.00 |
| Rifle | Legendary | 6.2 – 13.8 | 10.20 – 16.14 | 87 – 163 | 80% – 90% | 0.64° – 0.32° | 0.40° – 0.20° | 53 – 67 | 2.39 – 0.93 | 24 – 54 | 2.00 |
| Rifle | Mythic | 6.1 – 16.0 | 10.16 – 16.12 | 87 – 164 | 80% – 90% | 0.64° – 0.32° | 0.40° – 0.20° | 53 – 67 | 2.39 – 0.94 | 24 – 54 | 2.00 |
| Battle Rifle | Common | 8.2 – 12.8 | 7.04 – 9.09 | 71 – 95 | 84% – 95% | 0.51° – 0.17° | 0.32° – 0.11° | 53 – 67 | 2.76 – 1.13 | 24 – 51 | 2.00 |
| Battle Rifle | Uncommon | 8.5 – 15.0 | 7.07 – 9.12 | 72 – 110 | 84% – 95% | 0.52° – 0.17° | 0.32° – 0.11° | 53 – 67 | 2.74 – 1.12 | 24 – 54 | 2.00 |
| Battle Rifle | Rare | 8.8 – 16.9 | 7.12 – 9.14 | 75 – 138 | 84% – 95% | 0.51° – 0.17° | 0.32° – 0.11° | 53 – 67 | 2.76 – 1.11 | 24 – 54 | 2.00 |
| Battle Rifle | Unique | 9.0 – 17.5 | 7.13 – 9.07 | 79 – 137 | 84% – 95% | 0.52° – 0.17° | 0.32° – 0.11° | 53 – 67 | 2.75 – 1.08 | 24 – 54 | 2.00 |
| Battle Rifle | Legendary | 9.5 – 19.4 | 7.05 – 9.13 | 81 – 150 | 84% – 95% | 0.52° – 0.17° | 0.32° – 0.11° | 53 – 67 | 2.75 – 1.07 | 24 – 54 | 2.00 |
| Battle Rifle | Mythic | 9.2 – 21.0 | 7.08 – 9.14 | 80 – 155 | 84% – 95% | 0.51° – 0.17° | 0.32° – 0.11° | 53 – 67 | 2.75 – 1.08 | 24 – 54 | 2.00 |

#### Lmg

| Kind | Rarity | Damage / shot | Fire rate /s | DPS | Accuracy | Hip spread | ADS spread | Range m | Reload s | Magazine | Crit x |
|---|---|---|---|---|---|---|---|---|---|---|---|
| Lmg | Common | 5.7 – 9.9 | 11.10 – 17.43 | 89 – 124 | 66% – 74% | 1.09° – 0.83° | 0.68° – 0.52° | 49 – 62 | 4.00 – 1.64 | 80 – 157 | 2.00 |
| Lmg | Uncommon | 5.8 – 11.3 | 10.72 – 17.48 | 89 – 141 | 66% – 74% | 1.09° – 0.83° | 0.68° – 0.52° | 49 – 62 | 3.97 – 1.63 | 80 – 163 | 2.00 |
| Lmg | Rare | 6.0 – 12.5 | 11.00 – 17.51 | 93 – 180 | 66% – 74% | 1.09° – 0.83° | 0.68° – 0.52° | 49 – 62 | 4.00 – 1.61 | 80 – 164 | 2.00 |
| Lmg | Unique | 6.6 – 13.5 | 11.03 – 17.26 | 98 – 180 | 66% – 74% | 1.09° – 0.83° | 0.68° – 0.52° | 49 – 62 | 3.99 – 1.56 | 80 – 163 | 2.00 |
| Lmg | Legendary | 6.6 – 14.5 | 11.05 – 17.48 | 99 – 185 | 66% – 74% | 1.09° – 0.83° | 0.68° – 0.52° | 49 – 62 | 3.99 – 1.55 | 80 – 166 | 2.00 |
| Lmg | Mythic | 6.4 – 16.8 | 11.01 – 17.46 | 99 – 186 | 66% – 74% | 1.09° – 0.83° | 0.68° – 0.52° | 49 – 62 | 3.99 – 1.56 | 81 – 165 | 2.00 |
| Heavy Machine Gun | Common | 7.8 – 12.1 | 8.12 – 10.49 | 77 – 103 | 69% – 78% | 0.99° – 0.71° | 0.62° – 0.44° | 49 – 62 | 4.60 – 1.89 | 80 – 157 | 2.00 |
| Heavy Machine Gun | Uncommon | 8.0 – 14.1 | 8.15 – 10.52 | 78 – 120 | 69% – 78% | 0.99° – 0.71° | 0.62° – 0.44° | 49 – 62 | 4.56 – 1.87 | 80 – 163 | 2.00 |
| Heavy Machine Gun | Rare | 8.3 – 15.9 | 8.21 – 10.54 | 82 – 150 | 69% – 78% | 0.99° – 0.71° | 0.62° – 0.44° | 49 – 62 | 4.60 – 1.85 | 80 – 164 | 2.00 |
| Heavy Machine Gun | Unique | 8.5 – 16.5 | 8.23 – 10.46 | 86 – 149 | 69% – 78% | 0.99° – 0.71° | 0.62° – 0.44° | 49 – 62 | 4.59 – 1.80 | 80 – 163 | 2.00 |
| Heavy Machine Gun | Legendary | 8.9 – 18.2 | 8.14 – 10.53 | 88 – 163 | 69% – 78% | 0.99° – 0.71° | 0.62° – 0.44° | 49 – 62 | 4.59 – 1.78 | 80 – 166 | 2.00 |
| Heavy Machine Gun | Mythic | 8.7 – 19.8 | 8.16 – 10.54 | 87 – 169 | 69% – 78% | 0.99° – 0.71° | 0.62° – 0.44° | 49 – 62 | 4.59 – 1.80 | 81 – 165 | 2.00 |

#### Dmr

| Kind | Rarity | Damage / shot | Fire rate /s | DPS | Accuracy | Hip spread | ADS spread | Range m | Reload s | Magazine | Crit x |
|---|---|---|---|---|---|---|---|---|---|---|---|
| Dmr | Common | 18.0 – 31.4 | 2.99 – 4.69 | 76 – 106 | 89% – 100% | 0.34° – 0.00° | 0.21° – 0.00° | 80 – 100 | 2.60 – 1.07 | 12 – 23 | 2.00 |
| Dmr | Uncommon | 18.5 – 35.8 | 2.89 – 4.71 | 76 – 120 | 89% – 100% | 0.34° – 0.00° | 0.21° – 0.00° | 80 – 100 | 2.58 – 1.06 | 12 – 23 | 2.00 |
| Dmr | Rare | 19.1 – 39.8 | 2.96 – 4.71 | 80 – 154 | 89% – 100% | 0.34° – 0.00° | 0.21° – 0.00° | 80 – 100 | 2.60 – 1.05 | 12 – 23 | 2.00 |
| Dmr | Unique | 21.1 – 42.9 | 2.97 – 4.65 | 84 – 154 | 89% – 100% | 0.34° – 0.00° | 0.21° – 0.00° | 80 – 100 | 2.59 – 1.02 | 12 – 23 | 2.00 |
| Dmr | Legendary | 20.8 – 46.1 | 2.98 – 4.71 | 85 – 158 | 89% – 100% | 0.34° – 0.00° | 0.21° – 0.00° | 80 – 100 | 2.59 – 1.00 | 12 – 23 | 2.00 |
| Dmr | Mythic | 20.4 – 53.3 | 2.96 – 4.70 | 85 – 159 | 89% – 100% | 0.34° – 0.00° | 0.21° – 0.00° | 80 – 100 | 2.59 – 1.02 | 12 – 23 | 2.00 |
| Heavy DMR | Common | 40.7 – 63.4 | 1.62 – 2.10 | 81 – 108 | 91% – 100% | 0.28° – 0.00° | 0.18° – 0.00° | 80 – 96 | 2.99 – 1.23 | 12 – 23 | 2.00 |
| Heavy DMR | Uncommon | 42.2 – 74.2 | 1.63 – 2.10 | 82 – 126 | 91% – 100% | 0.29° – 0.00° | 0.18° – 0.00° | 80 – 96 | 2.96 – 1.22 | 12 – 23 | 2.00 |
| Heavy DMR | Rare | 43.6 – 83.6 | 1.64 – 2.11 | 86 – 157 | 91% – 100% | 0.28° – 0.00° | 0.18° – 0.00° | 80 – 96 | 2.99 – 1.21 | 12 – 23 | 2.00 |
| Heavy DMR | Unique | 44.5 – 86.6 | 1.64 – 2.09 | 90 – 157 | 91% – 100% | 0.29° – 0.00° | 0.18° – 0.00° | 80 – 96 | 2.98 – 1.17 | 12 – 23 | 2.00 |
| Heavy DMR | Legendary | 46.8 – 95.7 | 1.63 – 2.11 | 92 – 171 | 91% – 100% | 0.29° – 0.00° | 0.18° – 0.00° | 80 – 96 | 2.98 – 1.16 | 12 – 23 | 2.00 |
| Heavy DMR | Mythic | 45.4 – 103.7 | 1.63 – 2.11 | 91 – 177 | 91% – 100% | 0.28° – 0.00° | 0.18° – 0.00° | 80 – 96 | 2.98 – 1.17 | 12 – 23 | 2.00 |

#### Sniper

| Kind | Rarity | Damage / shot | Fire rate /s | DPS | Accuracy | Hip spread | ADS spread | Range m | Reload s | Magazine | Crit x |
|---|---|---|---|---|---|---|---|---|---|---|---|
| Sniper | Common | 44.9 – 78.4 | 1.20 – 1.88 | 76 – 106 | 92% – 100% | 0.25° – 0.00° | 0.16° – 0.00° | 133 – 156 | 3.20 – 1.31 | 4 – 6 | 3.00 |
| Sniper | Uncommon | 46.2 – 89.6 | 1.15 – 1.88 | 76 – 120 | 92% – 100% | 0.25° – 0.00° | 0.16° – 0.00° | 133 – 156 | 3.17 – 1.30 | 4 – 6 | 3.00 |
| Sniper | Rare | 47.8 – 99.6 | 1.18 – 1.89 | 80 – 154 | 92% – 100% | 0.25° – 0.00° | 0.16° – 0.00° | 133 – 156 | 3.20 – 1.29 | 4 – 6 | 3.00 |
| Sniper | Unique | 52.7 – 107.2 | 1.19 – 1.86 | 84 – 154 | 92% – 100% | 0.25° – 0.00° | 0.16° – 0.00° | 133 – 156 | 3.19 – 1.25 | 4 – 6 | 3.00 |
| Sniper | Legendary | 52.1 – 115.2 | 1.19 – 1.88 | 85 – 158 | 92% – 100% | 0.25° – 0.00° | 0.16° – 0.00° | 133 – 156 | 3.19 – 1.24 | 4 – 6 | 3.00 |
| Sniper | Mythic | 51.1 – 133.3 | 1.19 – 1.88 | 85 – 159 | 92% – 100% | 0.25° – 0.00° | 0.16° – 0.00° | 133 – 156 | 3.19 – 1.25 | 4 – 6 | 3.00 |
| Anti-Materiel Rifle | Common | 70.3 – 109.5 | 0.63 – 0.82 | 54 – 72 | 92% – 100% | 0.25° – 0.00° | 0.16° – 0.00° | 133 – 156 | 3.84 – 1.58 | 4 – 6 | 3.00 |
| Anti-Materiel Rifle | Uncommon | 72.8 – 128.0 | 0.63 – 0.82 | 55 – 85 | 92% – 100% | 0.25° – 0.00° | 0.16° – 0.00° | 133 – 156 | 3.81 – 1.56 | 4 – 6 | 3.00 |
| Anti-Materiel Rifle | Rare | 75.3 – 144.4 | 0.64 – 0.82 | 57 – 105 | 92% – 100% | 0.25° – 0.00° | 0.16° – 0.00° | 133 – 156 | 3.84 – 1.55 | 4 – 6 | 3.00 |
| Anti-Materiel Rifle | Unique | 76.8 – 149.6 | 0.64 – 0.81 | 60 – 105 | 92% – 100% | 0.25° – 0.00° | 0.16° – 0.00° | 133 – 156 | 3.83 – 1.50 | 4 – 6 | 3.00 |
| Anti-Materiel Rifle | Legendary | 80.8 – 165.2 | 0.63 – 0.82 | 62 – 115 | 92% – 100% | 0.25° – 0.00° | 0.16° – 0.00° | 133 – 156 | 3.83 – 1.48 | 4 – 6 | 3.00 |
| Anti-Materiel Rifle | Mythic | 78.4 – 179.0 | 0.64 – 0.82 | 61 – 119 | 92% – 100% | 0.25° – 0.00° | 0.16° – 0.00° | 133 – 156 | 3.83 – 1.50 | 4 – 6 | 3.00 |

#### Shotgun

| Kind | Rarity | Damage / shot | Fire rate /s | DPS | Accuracy | Hip spread | ADS spread | Range m | Reload s | Magazine | Crit x |
|---|---|---|---|---|---|---|---|---|---|---|---|
| Pump Shotgun | Common | 44.9 – 78.4 | 1.20 – 1.88 | 76 – 106 | 47% – 53% | 1.70° – 1.50° | 1.06° – 0.94° | 10 – 14 | 3.50 – 1.44 | 5 – 9 | 2.00 |
| Pump Shotgun | Uncommon | 46.2 – 89.6 | 1.15 – 1.88 | 76 – 120 | 47% – 53% | 1.70° – 1.50° | 1.06° – 0.94° | 10 – 14 | 3.47 – 1.43 | 5 – 9 | 2.00 |
| Pump Shotgun | Rare | 47.8 – 99.6 | 1.18 – 1.89 | 80 – 154 | 47% – 53% | 1.70° – 1.50° | 1.06° – 0.94° | 10 – 14 | 3.50 – 1.41 | 5 – 9 | 2.00 |
| Pump Shotgun | Unique | 52.7 – 107.2 | 1.19 – 1.86 | 84 – 154 | 47% – 53% | 1.70° – 1.50° | 1.06° – 0.94° | 10 – 14 | 3.49 – 1.37 | 5 – 9 | 2.00 |
| Pump Shotgun | Legendary | 52.1 – 115.2 | 1.19 – 1.88 | 85 – 158 | 47% – 53% | 1.70° – 1.50° | 1.06° – 0.94° | 10 – 14 | 3.49 – 1.35 | 5 – 9 | 2.00 |
| Pump Shotgun | Mythic | 51.1 – 133.3 | 1.19 – 1.88 | 85 – 159 | 47% – 53% | 1.70° – 1.50° | 1.06° – 0.94° | 10 – 14 | 3.49 – 1.37 | 5 – 9 | 2.00 |
| Heavy Shotgun | Common | 70.3 – 109.5 | 0.63 – 0.82 | 54 – 72 | 52% – 58% | 1.55° – 1.34° | 0.97° – 0.83° | 16 – 22 | 4.20 – 1.72 | 5 – 9 | 2.00 |
| Heavy Shotgun | Uncommon | 72.8 – 128.0 | 0.63 – 0.82 | 55 – 85 | 52% – 58% | 1.55° – 1.33° | 0.97° – 0.83° | 16 – 22 | 4.16 – 1.71 | 5 – 9 | 2.00 |
| Heavy Shotgun | Rare | 75.3 – 144.4 | 0.64 – 0.82 | 57 – 105 | 52% – 58% | 1.54° – 1.33° | 0.97° – 0.83° | 16 – 22 | 4.20 – 1.69 | 5 – 9 | 2.00 |
| Heavy Shotgun | Unique | 76.8 – 149.6 | 0.64 – 0.81 | 60 – 105 | 52% – 58% | 1.55° – 1.34° | 0.97° – 0.83° | 16 – 22 | 4.19 – 1.64 | 5 – 9 | 2.00 |
| Heavy Shotgun | Legendary | 80.8 – 165.2 | 0.63 – 0.82 | 62 – 115 | 52% – 58% | 1.55° – 1.33° | 0.97° – 0.83° | 16 – 22 | 4.19 – 1.62 | 5 – 9 | 2.00 |
| Heavy Shotgun | Mythic | 78.4 – 179.0 | 0.64 – 0.82 | 61 – 119 | 52% – 58% | 1.54° – 1.33° | 0.97° – 0.83° | 16 – 22 | 4.19 – 1.64 | 5 – 9 | 2.00 |
| Auto Shotgun | Common | 20.2 – 35.3 | 2.39 – 3.75 | 68 – 95 | 47% – 53% | 1.70° – 1.50° | 1.06° – 0.94° | 10 – 14 | 3.50 – 1.44 | 7 – 13 | 2.00 |
| Auto Shotgun | Uncommon | 20.8 – 40.3 | 2.31 – 3.77 | 69 – 108 | 47% – 53% | 1.70° – 1.50° | 1.06° – 0.94° | 10 – 14 | 3.47 – 1.43 | 7 – 13 | 2.00 |
| Auto Shotgun | Rare | 21.5 – 44.8 | 2.37 – 3.77 | 72 – 138 | 47% – 53% | 1.70° – 1.50° | 1.06° – 0.94° | 10 – 14 | 3.50 – 1.41 | 7 – 13 | 2.00 |
| Auto Shotgun | Unique | 23.7 – 48.2 | 2.38 – 3.72 | 75 – 138 | 47% – 53% | 1.70° – 1.50° | 1.06° – 0.94° | 10 – 14 | 3.49 – 1.37 | 7 – 13 | 2.00 |
| Auto Shotgun | Legendary | 23.4 – 51.8 | 2.38 – 3.77 | 76 – 143 | 47% – 53% | 1.70° – 1.50° | 1.06° – 0.94° | 10 – 14 | 3.49 – 1.35 | 7 – 13 | 2.00 |
| Auto Shotgun | Mythic | 23.0 – 60.0 | 2.37 – 3.76 | 76 – 143 | 47% – 53% | 1.70° – 1.50° | 1.06° – 0.94° | 10 – 14 | 3.49 – 1.37 | 7 – 13 | 2.00 |

#### Ordnance

| Class | Rarity | Damage | Cooldown s | Charges | Blast m |
|---|---|---|---|---|---|
| Grenade | Common | 128 – 225 | 2.75 – 1.65 | 2 – 3 | 4.0 |
| Grenade | Mythic | 171 – 352 | 2.71 – 1.65 | 2 – 3 | 4.0 |
| Rocket Launcher | Common | 206 – 361 | 4.40 – 2.64 | 1 | 5.0 |
| Rocket Launcher | Mythic | 274 – 564 | 4.34 – 2.65 | 1 | 5.0 |
| Grenade Launcher | Common | 86 – 150 | 1.83 – 1.10 | 3 – 5 | 3.0 |
| Grenade Launcher | Mythic | 114 – 235 | 1.81 – 1.10 | 3 – 5 | 3.0 |
| Mine Layer | Common | 103 – 180 | 2.20 – 1.32 | 3 – 4 | 3.5 |
| Mine Layer | Mythic | 137 – 282 | 2.17 – 1.32 | 3 – 4 | 3.5 |
| Drone | Common | 34 – 60 | 0.73 – 0.44 | 1 | 1.5 |
| Drone | Mythic | 46 – 94 | 0.72 – 0.44 | 1 | 1.5 |
| Arc Caster | Common | 103 – 180 | 2.20 – 1.32 | 2 | 0.0 |
| Arc Caster | Mythic | 137 – 282 | 2.17 – 1.32 | 2 | 0.0 |


### 9.4 Where these numbers come from (2026-10-12)

Every gun type and kind is built from its **shots to kill a medium enemy** (shield 0.6, armor
1.2, health 1, in units of its health) at Unique, on level: the Armory Ledger's Time to kill tab
and Docs/Weapons/COMBAT_DESIGN.md section 3. `WeaponClass._PRESETS` states each class's damage
a round in those units (`DMG_UNIT`) and `KINDS` its heavy (and the shotgun's auto) from their
own targets; `tools/combat_numbers_probe.gd` checks every count through the real
DamageSystem. The tables above are the rolls around those targets, modifiers included in the
best end.

## 10. Tests and what is not built

- `tools/aim_assist_probe.gd` (23 checks):
  - picking a target;
  - no drift on a still enemy;
  - friction;
  - tracking a strafe;
  - the head's pitch kept;
  - never fighting the player;
  - shotgun range;
  - weak points on the back skipped;
  - bullets bent;
  - the snap, once;
  - engagement;
  - range from accuracy;
  - a freed target;
  - a re-armed gun keeping one listener;
  - Off.
- `tools/gun_stat_table.gd`: regenerates §9.3.

**Not yet:**
- Controller look and bindings, and with them the controller assist.
- No assist in the mech: `MechPilot` drives its own camera.
- Tank and truck weak points.
- The mouse's release default (Medium today, for testing).
