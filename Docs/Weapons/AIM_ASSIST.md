# Aim assist

`scripts/combat/aim_assist.gd` (`AimAssist`). Built 2026-10-11. Probe: `tools/aim_assist_probe.gd`.

## 1. What it is for

Help the player land shots without the feeling that the game is aiming for them. The view
should move as little as possible, while shots still land where the player meant them to go.
Halo is the model:

- slowdown near an enemy;
- the view follows an enemy's *movement*, never a fixed point;
- a little bullet magnetism.

Not Call of Duty's hard snap.

## 2. The pieces

| Piece | What it does | Moves the view? |
|---|---|---|
| **Slowdown** (friction) | The look turns slower over and near a target (`filter_look`, called by `DebugCamera` for every mouse move). | No |
| **Tracking** (magnetism) | The view follows how far the target's aim line moved across the screen since the last frame: the enemy strafing, or the player's own movement. A still enemy, with the player not moving, gets **no pull at all**. | Yes, only by the target's own motion |
| **Centering** | A gentle pull toward the aim line, only while the player is turning or firing, and **never against** the way the player is turning. | Yes, gently |
| **Snap when aiming** | Starting to aim down the sights within 2.5 half-widths of the line closes part of the gap (Snap Strength, default 60%) over 0.16 s. Once per aim. | Yes, once |
| **Bullet magnetism** | A round that would just miss (within the target's half-width plus a few tenths of a degree) is bent onto the aim line before the spread (`bend`, from `GunController._fire_one`). | No |

## 3. The aim line

Every target is a vertical segment from its feet to its top. The assists aim for the **nearest
point** on that segment to the crosshair.

- Anywhere between the feet and the top, the vertical error is zero. The assist only helps
  sideways, so a player aiming at the head keeps the head.
- Vertical Help (off by default) also pulls the crosshair back onto the body when it is above
  or below it.
- The segment stands on the target's **weak point nearest the crosshair among those facing the
  player**:
  - a pawn's `CritSpots`;
  - a mech's hatch and power cell (`MechLayers.side_faces`).

  A weak point round the far side is never aimed for. With none facing, the line runs up the
  body's middle.
- Any enemy works:
  - pawns;
  - mechs (`mechs` group);
  - tanks and trucks (`tanks` and `trucks` groups, read from their collision shapes).

## 4. Limits

- **Weapon range** (`AimAssist.WEAPONS`): a shotgun gives no assist past 14 m, an SMG past
  28 m, a rifle past 60 m, a sniper rifle past 150 m. Strength fades out over the last fifth of
  the range. These numbers stand in until guns have a real range stat.
- **Slow projectiles:** the grenade tube's lob gets more tracking (×1.5), and its aim line is
  led to where the target will be. A future plasma pistol adds a row to `WEAPONS` with its
  projectile speed.
- **The cone:** the target's angular half-width ×2.5 + 2.5° from the hip, ×1.6 + 1.2° down the
  sights. It shrinks with distance on its own, because the target looks smaller.
- **Weight:** full inside the target's own width, falling to nothing at the cone's edge.
- **Line of sight:** a target behind a wall or bricks is skipped. The three nearest candidates
  are checked.
- **Hysteresis:** the current target counts 25% nearer, so the assist does not flick between two.

## 5. Hip fire, sights, engagement

- Every strength is a blend of its hip value and its sights value, weighted by the sights' rise
  (`PlayerView.ads_amount`), so the change between them is smooth.
- **Engagement:** staying on a target while firing builds engagement over 0.5 s, lost in 0.3 s.
  At full engagement, tracking and centering are 1.5× as strong.

## 6. Mouse and controller

- Each device has its own level (Off, Low, Medium, High = ×0, ×0.6, ×1, ×1.5) and its own base
  numbers (`FRICTION`, `TRACKING`, `CENTERING`, `BULLET_DEG`). The controller's are stronger.
- The last look input decides which device is in use.
- The mouse is **on (Medium) for testing**. The intended release default is Off or Low, which
  is still to decide.
- Controller look is not in the game yet, so the controller row waits for it.

## 7. Settings (Options > Aim Assist)

**Simple:**
- Mouse Aim Assist
- Controller Aim Assist
- Snap When Aiming

**Advanced:**
- Slowdown, Tracking, Centering, Bullet Magnetism (each ×0–2)
- Snap Strength
- Stronger While Firing
- Limit to Weapon Range
- Aim for Weak Points
- Vertical Help

The values are static fields on `AimAssist`, set by `BrickcityMenuHost._apply_setting`. The tab
is the host's own (`_build_aim_tab`), so the shared `menu/` folder is unchanged.

## 8. Not yet

- Controller look and bindings, and with them the controller assist felt in play.
- In the mech: `MechPilot` drives its own camera; the assist is on foot only.
- A real per-gun range stat, in place of the per-class table.
- The release defaults for the mouse.
