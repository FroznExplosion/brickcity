# Joints, hands and held scale

Where two brick assemblies meet and move: a figure's and a mech's joints, the hands that swap on a
wrist, and the grip that lets a gun built at one size sit in a hand at another. One definition,
used by the model converter, the print generator, the workshop and the game.

Status: defined 2026-10-13. **Nothing here has been printed, and links (Docs/BuildMode.md
section 6) are not built.** Dimensions are nominal; test prints set the clearances. Machine-readable
copy: [standards.json](standards.json). Sizes are in mm at print scale; game metres are x0.04375.

## 1. Rules

1. **One bone, one rigid assembly.** Every part is fixed to exactly one bone (spec section 8).
   Nothing bends; a joint is the only place two assemblies move against each other.
2. **A joint is a connector pair.** Same type, or it does not join (BuildMode 6.2). In a model the
   two halves are empties named `socket_<type>_<n>`, +Z out of the joint.
3. **In the game a joint is a bone.** Animation turns it within the limits below. The connector
   says what the *print* can do and where the converter cuts the model.
4. **Bone names are Mixamo's as Godot imports them** (`mixamorig_RightArm`), as in
   `scripts/pawn/view_arms.gd`, so a Mixamo rig and its animations fit.
5. **Positions come from the model's rig**: a joint sits at its bone's head, snapped to the nano
   tick lattice (0.8 mm, [nano.md](nano.md)). The tables give the stock positions for a model
   that has no rig.

## 2. One pin

**Every joint pin is 3.2 mm across**, on a figure and on a mech alike (decided 2026-10-13).

| | mm | On the grid | Game (m) |
|---|---|---|---|
| pin diameter | 3.2 | a plate's height; 2 nano plates; 4 nano ticks | 0.14 |
| the least a part is thick where a pin enters it | 4.8 | a nano brick: the hole and 0.8 of wall each side | 0.21 |

3.2 mm is the bar a real brick figure's hand grips. So one size does everything: any hand goes on
any wrist, a clip or a C hand that holds a bar holds a pin, and there is one hole to tune on a fit
plate instead of five.

A joint that carries more does not get a fatter pin. It gets a **double** knuckle (section 3), or
flat faces round the pin that take the load while the pin only centres it.

## 3. Joint connectors

Three, added to BuildMode 6.1's connector types (`AXLE` and `BALL` are already listed there;
`KNUCKLE` is new).

| Connector | Moves | Link kind (BuildMode 6.3) | Shape (mm) |
|---|---|---|---|
| `AXLE` | spins about its own axis, which runs **along** the bone | `AXLE` (free) or `HINGE` (limited) | a pin Ø3.2, 4.8 long, in a hole 5.2 deep; a detent ring 0.1 proud at two thirds of its length. The faces round the pin are flat and carry the load |
| `KNUCKLE` | bends about a pin that runs **across** the bone | `HINGE` | a tongue 3.2 thick between two cheeks 1.6 thick, on a cross pin Ø3.2, 6.4 long; barrel Ø6.4 |
| `KNUCKLE`, double | the same | `HINGE` | two tongues and three cheeks on one pin 11.2 long: twice the bearing, for a joint that carries weight |
| `BALL` | swings in a cone and twists | `SWIVEL` | a ball Ø6.4 on a pin Ø3.2; a socket wrapped 220° round it, slotted twice so it opens. Defined for props; no stock figure or mech joint uses it |

Around every joint the converter carves a **clearance volume** out of both assemblies: the space
the child sweeps through its whole range, plus one nano tick. Bricks are not laid inside it.

Clearance on the diameter, nominal, applied by the exporter and never modelled:

| Process | AXLE, KNUCKLE (turning) | BALL (holding a pose) |
|---|---|---|
| resin | 0.10 | 0.05 |
| FDM | 0.25 | 0.15 |

Pins and clips print lying down, layers along their length (spec section 7). A link's strength
(BuildMode 6.4) is the pin's, times two for a double knuckle; the constant is set when links are
built.

## 4. Figure joints

The figure is 8 nano bricks: 38.4 mm, 1.68 m ([README](README.md) section 6). Heights are from the
feet. Left and right are mirrored.

| Joint | Bones (parent > child) | Connector | Axis | Range | Stock height, mm (nano ticks) |
|---|---|---|---|---|---|
| neck | Neck > Head | AXLE | up | turn ±90° | 26.4 (33) |
| waist | Hips > Spine | AXLE | up | turn ±45° | 14.4 (18) |
| shoulder | Shoulder > Arm | AXLE | across (out of the torso's side) | swing full circle | 24.8 (31) |
| wrist | ForeArm > Hand | AXLE | along the forearm | turn free | 10.4 (13) |
| hip | Hips > UpLeg | KNUCKLE | across | -90° to +45° | 14.4 (18) |
| elbow | Arm > ForeArm | none on a print: a bone only | across | 0° to 135° | 17.6 (22) |
| knee | UpLeg > Leg | none on a print: a bone only | across | 0° to 120° | 7.2 (9) |

- **Elbows and knees bend in the game and are fixed on a print.** A knuckle's barrel is 6.4 mm,
  wider than a 38.4 mm figure's limb. The printed arm and leg are each one part, in a set pose.
- **The wrist is the hand swap.** A hand is one part on the wrist AXLE (section 6).
- A limb is 4.8 mm thick where its pin goes in: the upper arm at the shoulder, the forearm at the
  wrist, the leg at the hip. That is 0.21 m in the game, a toy's arm rather than a person's.
- Upper arm and forearm are 7.2 mm each (0.315 m), against `ViewArms.UPPER` 0.31 and `FORE` 0.30.
- The head is 12 mm, so the neck is 12 mm under the top. The foot is part of the shin: no ankle.

## 5. Mech joints

The mech is 32 nano bricks: 153.6 mm, 6.72 m, with its cockpit eye 10 bricks up at a second-storey
window ([nano.md](nano.md) section 1). Heights are from the feet, in nano bricks (4.8 mm), and are
`scripts/mech/mech.gd`'s greybox as it stands.

| Joint | Bones (parent > child) | Connector | Axis | Range | Stock height, nano bricks (mm, game m) |
|---|---|---|---|---|---|
| ankle | Leg > Foot | KNUCKLE, double | across | ±30° | 2 (9.6, 0.42) |
| knee | UpLeg > Leg | KNUCKLE, double | across | 0° to 110° | 8 (38.4, 1.68) |
| hip | Hips > UpLeg | KNUCKLE, double | across | ±60° | 16 (76.8, 3.36) |
| hip turn | Hips > UpLeg | AXLE | up | ±30° | 16 |
| waist | Hips > Spine | AXLE | up | turn free: the torso chases the aim, the legs lag (`TitanMotor`) | 17 (81.6, 3.57) |
| shoulder | Spine > Shoulder | AXLE | across | pitch ±89° (`ARM_PITCH_LIMIT`) | 18 (86.4, 3.78) |
| arm yaw | Shoulder > Arm | KNUCKLE | up | ±55° (`ARM_YAW_LIMIT`) | 18 |
| elbow | Arm > ForeArm | KNUCKLE | across | 0° to 120° | by the model |
| wrist | ForeArm > Hand | AXLE | along the forearm | turn free | by the model |
| hatch | Spine > Hatch | KNUCKLE | across | 0° to 100° | 20 (96.0, 4.2): the cockpit |

- The hip and the shoulder are each two joints, a swing and a turn, where a ball would be one:
  a 3.2 mm pin holds a pose better than a ball its size, and the shoulder has to swing ±89°.
- **The wrist takes a hand or a weapon.** A mech's gun mounts on the wrist AXLE at full nano
  size: there is no held scale on a mech.
- The hatch is on the front of a medium or heavy and the back of a light (Docs/AIRoster.md 4.4).
- Light, medium and heavy mechs share the joints; their heights come from their models.

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
is at least 0.3 mm wide and deep at print size.

**The hand frame** is `view_arms.gd`'s: origin at the wrist, +Y out of the wrist to the fingers,
+X through the hole of the C (what is held passes along X), the C's opening toward +Z. The hole's
centre is `HOLE_Y` up the hand. Every shape has the same frame and the same wrist pin.

**On a print the C's hole is 3.2 mm**, the pin's size: a printed hand grips any pin, any bar, and
the grip of a figure-sized gun (section 7). In the game the hole is whatever looks right round a
held gun; it is 0.038 m today (`c_mesh(0.019, ...)`).

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

- a **round core 3.2 mm across** (the pin's size: what a brick figure's C hand grips,
  eight-sided) and at least **3 nano bricks** long (14.4 mm). The grip's shape is built round
  it; where the hand closes, it is the core;
- an empty `hold_0` at its centre, +X through the hand's hole, +Y up the hand. `hold_1` is the
  other hand's place (a handguard), if there is one. Not `socket_...`: that prefix is the gun
  assembler's, for where a part attaches ([custom.md](custom.md) section 4).

A held item has three outputs from one build:

| Output | Size | How |
|---|---|---|
| game | x `HELD_SCALE` | one merged mesh, studs as fine detail |
| collector print | 1:1 nano | resin, separate bricks, real 2.4 mm studs |
| figure print (optional) | x `HELD_SCALE` | one piece for a printed figure's hand, its grip a 3.2 mm bar; studs are texture |
