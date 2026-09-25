class_name CreatureDNA
extends RefCounted
## Seeded "genome" describing a creature body plan.
## Pure data — no scene nodes. Deterministic from `seed`.

enum Archetype { ORGANIC, ROBOTIC }

var seed_value: int = 0
var archetype: int = Archetype.ORGANIC
var creature_name: String = "Unnamed"

# --- Body plan -------------------------------------------------------------
var scale: float = 1.0
var spine_joints: int = 4            # number of spine bones/joints (>= 2)
var body_len: float = 1.4            # rear spine joint -> front spine joint
var body_r: float = 0.3              # base body radius
var belly: PackedFloat32Array = []   # per-spine-joint radius multiplier

var leg_pairs: Array[Dictionary] = []  # { spine_i, upper, lower, hip_out, splay, knee_forward }

var neck_len: float = 0.3
var head_r: float = 0.22
var snout_len: float = 0.3
var head_up: float = 0.12

var tail_joints: int = 3             # 0 disables tail. Robots grow an antenna instead.
var tail_seg: float = 0.25

var color: Color = Color(0.5, 0.6, 0.4)
var accent: Color = Color(0.95, 0.9, 0.2)

# --- Gait ------------------------------------------------------------------
var move_speed: float = 1.6
var step_time: float = 0.22
var step_height_f: float = 0.30      # fraction of stand height
var step_trigger_f: float = 0.38     # fraction of stand height
var bob_amp: float = 0.03

const _SYL_A := ["Vro", "Ka", "Zu", "Mor", "Tik", "Gla", "Ur", "Ske", "Bo", "Ny"]
const _SYL_B := ["k", "rr", "th", "z", "l", "m", "x", "g"]
const _SYL_C := ["tar", "ok", "una", "eth", "ilo", "ash", "orn", "ub", "ee", "ax"]

func stand_height() -> float:
	var reach := 0.0
	for lp in leg_pairs:
		reach = maxf(reach, float(lp.upper) + float(lp.lower))
	return reach * 0.82

func front_spine_z() -> float: return -body_len * 0.5
func rear_spine_z() -> float: return body_len * 0.5

static func random(p_seed: int) -> CreatureDNA:
	var rng := RandomNumberGenerator.new()
	rng.seed = p_seed
	var d := CreatureDNA.new()
	d.seed_value = p_seed
	d.archetype = Archetype.ROBOTIC if rng.randf() < 0.4 else Archetype.ORGANIC
	d.creature_name = _SYL_A[rng.randi() % _SYL_A.size()] \
		+ _SYL_B[rng.randi() % _SYL_B.size()] \
		+ _SYL_C[rng.randi() % _SYL_C.size()]

	d.scale = rng.randf_range(0.7, 1.6)
	d.spine_joints = rng.randi_range(3, 5)
	d.body_len = rng.randf_range(0.9, 2.0) * d.scale
	d.body_r = rng.randf_range(0.18, 0.4) * d.scale
	d.belly = PackedFloat32Array()
	for i in d.spine_joints:
		var t := float(i) / maxf(1.0, d.spine_joints - 1.0)
		# widest slightly behind center, taper at both ends
		var bulge := 1.0 + 0.45 * sin(PI * clampf(t * 1.1, 0.0, 1.0)) * rng.randf_range(0.6, 1.2)
		d.belly.append(bulge)

	var pairs := rng.randi_range(1, 3)
	var upper := rng.randf_range(0.35, 0.7) * d.scale
	var lower := upper * rng.randf_range(0.8, 1.2)
	for p in pairs:
		# spread pairs along spine; single pair sits mid-rear
		var si: int
		if pairs == 1:
			si = d.spine_joints / 2
		else:
			si = int(round(lerpf(d.spine_joints - 1, 0, float(p) / float(pairs - 1))))
		d.leg_pairs.append({
			"spine_i": si,
			"upper": upper * rng.randf_range(0.92, 1.08),
			"lower": lower * rng.randf_range(0.92, 1.08),
			"hip_out": d.body_r * rng.randf_range(0.75, 1.05),
			"splay": rng.randf_range(1.15, 1.6),
			"knee_forward": rng.randf() < 0.65,
		})

	d.neck_len = rng.randf_range(0.12, 0.55) * d.scale
	d.head_r = d.body_r * rng.randf_range(0.55, 0.95)
	d.snout_len = rng.randf_range(0.15, 0.6) * d.scale
	d.head_up = rng.randf_range(0.0, 0.3) * d.scale

	d.tail_joints = rng.randi_range(0, 4)
	d.tail_seg = rng.randf_range(0.18, 0.35) * d.scale
	if d.archetype == Archetype.ROBOTIC:
		d.tail_joints = rng.randi_range(2, 4)  # antenna
		d.tail_seg = rng.randf_range(0.12, 0.2) * d.scale

	d.color = Color.from_hsv(rng.randf(), rng.randf_range(0.35, 0.8), rng.randf_range(0.45, 0.9))
	if d.archetype == Archetype.ROBOTIC:
		d.color = Color.from_hsv(rng.randf(), rng.randf_range(0.05, 0.3), rng.randf_range(0.5, 0.85))
	d.accent = Color.from_hsv(fmod(d.color.h + 0.5, 1.0), 0.9, 1.0)

	var sh := d.stand_height()
	d.move_speed = rng.randf_range(0.9, 2.2) * sqrt(maxf(sh, 0.2))
	d.step_time = rng.randf_range(0.16, 0.3)
	d.bob_amp = sh * rng.randf_range(0.02, 0.05)
	return d
