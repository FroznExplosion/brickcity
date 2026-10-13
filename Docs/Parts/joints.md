# Joints, hands and held scale

Where two brick assemblies meet and move: a figure's and a mech's joints, the hands that swap on a
wrist, and the grip that lets a gun built at one size sit in a hand at another. One definition,
used by the model converter, the print generator, the workshop and the game.

Status: defined 2026-10-13. **Nothing here has been printed, and links (Docs/BuildMode.md
section 6) are not built.** Dimensions are nominal; test prints set the clearances. Machine-readable
copy: [standards.json](standards.json). Sizes are in mm at print scale and in nano ticks
(0.8 mm, [nano.md](nano.md)); game metres are x0.04375.

## 1. Rules

1. **One bone, one rigid assembly.** Every part is fixed to exactly one bone (spec section 8).
   Nothing bends; a joint is the only place two assemblies move against each other.
2. **A joint is a connector pair.** Same type, same size, or it does not join (BuildMode 6.2).
   In a model the two halves are empties named `socket_<type>_<size>_<n>`, +Z out of the joint.
3. **In the game a joint is a bone.** Animation turns it within the limits below. The connector
   says what the *print* can do and where the converter cuts the model.
4. **Bone names are Mixamo's as Godot imports them** (`mixamorig_RightArm`), as in
   `scripts/pawn/view_arms.gd`, so a Mixamo rig and its animations fit.
5. **Positions come from the model's rig**: a joint sits at its bone's head, snapped to the nano
   tick lattice. The tables give the stock positions for a model that has no rig.

## 2. The size ladder

Every joint diameter comes from one ladder, and every rung is a size the brick system already has,
so a joint part plugs into bricks without a special fitting.

| Size | Ø mm | Nano ticks | Game (m) | Same as |
|---|---|---|---|---|
| D2 | 1.6 | 2 | 0.07 | a nano plate's height |
| D3 | 2.4 | 3 | 0.105 | a nano stud |
| D4 | 3.2 | 4 | 0.14 | a plate's height; a bar |
| D6 | 4.8 | 6 | 0.21 | a full stud |
| D8 | 6.4 | 8 | 0.28 | |

Figures use D2-D4. Mechs use D4-D8. D2 is the smallest a resin print will carry.

## 3. Joint connectors

Three, added to BuildMode 6.1's connector types (`AXLE` and `BALL` are already listed there;
`KNUCKLE` is new).

| Connector | Moves | Link kind (BuildMode 6.3) | Shape, from its size D |
|---|---|---|---|
| `AXLE` | spins about its own axis, which runs **along** the bone | `AXLE` (free) or `HINGE` (limited) | a round pin Ø D, 1.5 D long, in a round hole 1.5 D + 0.4 deep; a detent ring 0.1 proud at two thirds of its length |
| `KNUCKLE` | bends about a pin that runs **across** the bone | `HINGE` | a tongue D thick between two cheeks D/2 thick, on a cross pin Ø D, 2 D long; barrel Ø 2 D |
| `BALL` | swings in a cone and twists | `SWIVEL` | a ball Ø D on a neck Ø D/2; a socket wrapped 220° round it, slotted twice so it opens |

Around every joint the converter carves a **clearance volume** out of both assemblies: the space
the child sweeps through its whole range, plus one nano tick. Bricks are not laid inside it.

Clearance on the diameter, nominal, applied by the exporter and never modelled:

| Process | AXLE, KNUCKLE (turning) | BALL (holding a pose) |
|---|---|---|
| resin | 0.10 | 0.05 |
| FDM (D6 and up only) | 0.25 | 0.15 |

Pins and clips print lying down, layers along their length (spec section 7). A link's strength
(BuildMode 6.4) goes with D squared; the constants are set when links are built.

## 4. Figure joints

The figure is 8 nano bricks: 38.4 mm, 1.68 m ([README](README.md) section 6). Heights are from the
feet. Left and right are mirrored.

| Joint | Bones (parent > child) | Connector | Axis | Range | Stock height, mm (nano ticks) |
|---|---|---|---|---|---|
| neck | Neck > Head | AXLE D3 | up | turn ±90° | 26.4 (33) |
| waist | Hips > Spine | AXLE D4 | up | turn ±45° | 14.4 (18) |
| shoulder | Shoulder > Arm | AXLE D3 | across (out of the torso's side) | swing full circle | 24.8 (31) |
| elbow | Arm > ForeArm | KNUCKLE D2 | across | 0° to 135° | 17.6 (22) |
| wrist | ForeArm > Hand | AXLE D2 | along the forearm | turn free | 10.4 (13) |
| hip | Hips > UpLeg | KNUCKLE D3 | across | -90° to +45° | 14.4 (18) |
| knee | UpLeg > Leg | KNUCKLE D2 | across | 0° to 120° | 7.2 (9) |

- Upper arm and forearm are 7.2 mm each (0.315 m), against `ViewArms.UPPER` 0.31 and `FORE` 0.30.
- The head is 12 mm, so the neck is 12 mm under the top. The foot is part of the shin: no ankle.
- **The wrist is the hand swap.** A hand is one part on the wrist AXLE (section 6).
- The figure is 12 mm across, so a limb is about 3 mm thick and D2 is the only pin that fits an
  elbow, knee or wrist. That is the resin limit. If the first test print cannot hold them, the
  printed figure keeps fixed elbows and knees and the game's bones stay as they are.

## 5. Mech joints

The mech is 28 nano bricks: 134.4 mm, 5.88 m ([nano.md](nano.md)). Heights are from the feet, in
nano bricks (4.8 mm). The stock heights are `scripts/mech/mech.gd`'s greybox restated at 14 bricks:
the shoulder and cockpit keep the metres they have today.

| Joint | Bones (parent > child) | Connector | Axis | Range | Stock height, nano bricks (mm, game m) |
|---|---|---|---|---|---|
| ankle | Leg > Foot | KNUCKLE D6 | across | ±30° | 2 (9.6, 0.42) |
| knee | UpLeg > Leg | KNUCKLE D8 | across | 0° to 110° | 8 (38.4, 1.68) |
| hip | Hips > UpLeg | BALL D8 | | cone 40°, twist ±30° | 14 (67.2, 2.94) |
| waist | Hips > Spine | AXLE D8 | up | turn free: the torso chases the aim, the legs lag (`TitanMotor`) | 16 (76.8, 3.36) |
| shoulder | Spine > Shoulder | AXLE D8 | across | pitch ±89° (`ARM_PITCH_LIMIT`) | 18 (86.4, 3.78) |
| arm yaw | Shoulder > Arm | KNUCKLE D6 | up | ±55° (`ARM_YAW_LIMIT`) | 18 |
| elbow | Arm > ForeArm | KNUCKLE D6 | across | 0° to 120° | by the model |
| wrist | ForeArm > Hand | AXLE D6 | along the forearm | turn free | by the model |
| hatch | Spine > Hatch | KNUCKLE D4 | across | 0° to 100° | 20 (96.0, 4.2): the cockpit |

- The shoulder is two joints, pitch then yaw, because a ball cannot swing ±89°.
- **The wrist takes a hand or a weapon.** A mech's gun mounts on the wrist AXLE D6 at full nano
  size: there is no held scale on a mech. D6 is a full stud, so a full stud socket is a mount.
- The hatch is on the front of a medium or heavy and the back of a light (Docs/AIRoster.md 4.4).
- Light, medium and heavy mechs share the joints and sizes; their heights come from their models.

## 6. Hands

A hand never moves a finger. It is one rigid part, one of five shapes, and an animation swaps the
whole hand -- in the game while it is off the screen (`ViewArms.set_hand`), on a print by pulling
it off the wrist pin.

| Shape | For | In the code today (`ViewArms.Hand`) |
|---|---|---|
| `C` | gripping: a gun's grip or handguard passes through it | `C` |
| `PINCH` | a tighter C for flat things: a magazine | `PINCH` |
| `FLAT` | a flat open hand | `OPEN` |
| `FIST` | closed | `FIST` |
| `REST` | open and relaxed: the hand with nothing to do | not built |

**The look is ours.** Four fingers joined into one block with three grooves that mark them, a
separate thumb, a knuckle line across the back. Visible fingers, never the smooth clip. A groove
is at least 0.3 mm wide and deep at print size, which a mech's hand has room for and a figure's
hand only just.

**The hand frame** is `view_arms.gd`'s: origin at the wrist, +Y out of the wrist to the fingers,
+X through the hole of the C (what is held passes along X), the C's opening toward +Z. The hole's
centre is `HOLE_Y` up the hand. Every shape has the same frame and the same wrist pin, so any
hand goes on any wrist of its size: D2 on a figure, D6 on a mech.

## 7. Held items and `HELD_SCALE`

A gun is built of nano bricks at a size worth printing, about 4 to 5 inches long. A figure that is
38.4 mm tall cannot carry that, so the game draws a held item smaller:

    game size  = the nano build x HELD_SCALE
    print (mm) = game (m) / 0.04375 / HELD_SCALE

**`HELD_SCALE` is one number, 1/6 to start**, in [standards.json](standards.json). It is the same
for every held item, so a pistol stays smaller than a rifle at both sizes. It is to be tuned by
eye in the game (`city.tscn -- --arms`); nothing else changes when it does.

| At 1/6 | Game | Print | In nano studs |
|---|---|---|---|
| a rifle | 0.85 m | 116.6 mm (4.6 in) | 29 long |
| a pistol | 0.20 m | 27.4 mm | 7 long |
| a nano stud | 0.029 m apart | 4.0 mm | |

**The grip.** Every held item has one, and it is the only thing the hand needs to know:

- a clear section **1 x 2 nano studs** (4 x 8 mm printed) and at least **3 nano bricks** long
  (14.4 mm), the long side fore and aft;
- `socket_grip_0` at its centre, +X through the hand's hole, +Y up the hand. `socket_grip_1` is
  the other hand's place (a handguard), if there is one;
- `socket_muzzle_0` where rounds leave, +Z out.

The C hand's hole is the grip section x `HELD_SCALE`: 0.029 x 0.058 m in the game at 1/6. `PINCH`
is sized the same way from a magazine one nano stud thick. The hole follows the scale; hands are
not remodelled when it changes.

A held item has three outputs from one build:

| Output | Size | How |
|---|---|---|
| game | x `HELD_SCALE` | one merged mesh, studs as fine detail |
| collector print | 1:1 nano | resin, separate bricks, real 2.4 mm studs |
| figure print (optional) | x `HELD_SCALE` | one piece for a printed figure's hand; studs are texture |
