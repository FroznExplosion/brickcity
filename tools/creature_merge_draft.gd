extends SceneTree
## brickcity, 2026-09-25: FIRST RUN of this draft (BoomerBorder never ran it). Not a
## gate -- named *_draft so probe sweeps skip it. 6 of 13 pass: M1 bones from
## morphology, M2 finite and walks 10.6 m, M3 keeps walking, M5 no leaked bodies, M6
## second morphology builds. Fails: M2 tracking 5.7 cm against a 5 cm target; the
## stumble (spike 5.4 cm, wants > 8), knockdown and both recoveries; M5 re-track and
## M6 track+walk. See Docs/Creatures/README.md.
## Gait ⇄ Physics MERGE — headless smoke test  ·  DRAFT, NOT YET EXECUTED
## =====================================================================
## Reference embodiment of gait_physics_merge/VERIFICATION.md (invariants M1–M6).
## Proves the two systems compose: a procedural creature (gait = Target) driven by the physics
## layer (Puppet) tracks its walk AND stumbles on impulse, then recovers.
##
## Requires a project that has BOTH the procgen creature system (res://scripts/creatures/*) and this
## module. Run (WHEN READY):
##   godot --headless --path . --import
##   godot --headless --path . --script res://tools/creature_merge_draft.gd
##   exit 0 = all pass, 1 = a failure

const CREATURE_DNA := "res://scripts/creatures/creature_dna.gd"
const PROC_CREATURE := "res://scripts/creatures/proc_creature.gd"
const CREATURE_RAGDOLL := "res://scripts/creatures/creature_ragdoll.gd"

const FRAMES_SETTLE := 30
const FRAMES_TRACK := 120
const TRACK_MEAN := 0.05      # M2 mean tracking (m) — creatures looser than humanoid
const SPIKE_MIN := 0.08       # M3 a real stumble
const COLLAPSE_MIN := 0.25    # M4 knockdown leaves the pose far

var _fail := 0
var _world: Node3D


func _check(cond: bool, msg: String) -> void:
	if cond:
		print("  PASS  ", msg)
	else:
		_fail += 1
		printerr("  FAIL  ", msg)


func _init() -> void:
	await physics_frame
	print("=== gait⇄physics merge smoke test (Godot %s) ===" % Engine.get_version_info().string)

	var DNA = load(CREATURE_DNA)
	var PC = load(PROC_CREATURE)
	var CR = load(CREATURE_RAGDOLL)
	if DNA == null or PC == null or CR == null:
		print("  SKIP  procgen creature system or merge module not in this project")
		quit(0)
		return

	_world = Node3D.new()
	root.add_child(_world)
	_world.add_child(_static_box(Vector3(0, -0.5, 0), Vector3(80, 1, 80)))

	# ---- M1 + M2 + M3 on creature A ----------------------------------------
	var a = await _spawn_merged(DNA, PC, CR, 4242)
	var creature = a[0]
	var rag = a[1]

	var expected := 1 + int(creature.rig.spine.size()) + int(creature.rig.legs.size()) * 2
	if creature.rig.has("head") and creature.rig.head >= 0:
		expected += 1
	_check(rag.get_physical_bone_count() == expected,
		"M1 physical bones %d == %d (from morphology)" % [rag.get_physical_bone_count(), expected])

	var start: Vector3 = creature.global_position
	for f in FRAMES_SETTLE + FRAMES_TRACK:
		await physics_frame
	var moved: float = (creature.global_position - start).length()
	var mean: float = rag.get_mean_tracking_error()
	_check(is_finite(mean), "M2 tracking error finite (no blow-up)")
	_check(mean < TRACK_MEAN, "M2 tracks gait, mean %.4f m < %.3f" % [mean, TRACK_MEAN])
	_check(moved > 1.0, "M2 creature locomoted %.2f m" % moved)

	# ---- M3 stumble + recover ----------------------------------------------
	var leg_bone: int = creature.rig.legs[0].lower
	var err_before: float = rag.get_mean_tracking_error()
	rag.hit(leg_bone, Vector3(6, 2, 0), 0.6)
	for f in 3: await physics_frame
	var err_spike: float = rag.get_mean_tracking_error()
	for f in 60: await physics_frame           # ride out the stagger window
	var err_after: float = rag.get_mean_tracking_error()
	var moved_after: float = (creature.global_position - start).length()
	_check(err_spike > err_before + SPIKE_MIN, "M3 hit produced a stumble (spike %.3f m)" % err_spike)
	_check(err_after < TRACK_MEAN, "M3 recovered to %.4f m" % err_after)
	_check(moved_after > moved, "M3 creature kept walking after the hit")

	# ---- M4 knockdown / death ----------------------------------------------
	rag.knockdown(Vector3(0, 3, 8))
	for f in 20: await physics_frame
	var err_down: float = rag.get_mean_tracking_error()
	_check(err_down > COLLAPSE_MIN, "M4 knockdown collapses the body (%.3f m)" % err_down)
	for f in 120: await physics_frame          # authority ramps back
	_check(rag.get_mean_tracking_error() < TRACK_MEAN, "M4 recovered after knockdown")

	# ---- M5 LOD gate --------------------------------------------------------
	rag.set_lod(1)
	await physics_frame
	_check(rag.get_physical_bone_count() == expected, "M5 no bodies leaked on LOD demotion")
	rag.set_lod(0)
	await physics_frame
	for f in 30: await physics_frame
	_check(rag.get_mean_tracking_error() < TRACK_MEAN, "M5 re-tracks after LOD0 return")

	# ---- M6 morphology-agnostic (a different creature) ---------------------
	var b = await _spawn_merged(DNA, PC, CR, 909090)
	var creature_b = b[0]
	var rag_b = b[1]
	var exp_b := 1 + int(creature_b.rig.spine.size()) + int(creature_b.rig.legs.size()) * 2
	if creature_b.rig.has("head") and creature_b.rig.head >= 0:
		exp_b += 1
	_check(rag_b.get_physical_bone_count() == exp_b,
		"M6 second morphology built (%d bones, %d legs)" % [exp_b, creature_b.rig.legs.size()])
	var start_b: Vector3 = creature_b.global_position
	for f in FRAMES_SETTLE + FRAMES_TRACK:
		await physics_frame
	_check(rag_b.get_mean_tracking_error() < TRACK_MEAN and (creature_b.global_position - start_b).length() > 1.0,
		"M6 second morphology tracks + walks")

	print("\n=== %s — %d failure(s) ===" % ["OK" if _fail == 0 else "FAILED", _fail])
	quit(1 if _fail > 0 else 0)


## Build a ProcCreature (Target), duplicate its skeleton as a Puppet, attach CreatureRagdoll.
## Returns [creature, ragdoll].
func _spawn_merged(DNA, PC, CR, seed_v: int) -> Array:
	var dna = DNA.random(seed_v)
	var creature = PC.spawn(dna)
	_world.add_child(creature)
	creature.global_position = Vector3(randf_range(-3, 3), 1.0, randf_range(-3, 3))
	creature.set_forced_lod(0)              # gait runs on rig.skeleton = Target
	await physics_frame

	# Real Target/Puppet split + driven ragdoll in one call (CreatureSplit + CreatureRagdoll).
	var rag = CR.attach_to(creature)        # physics ON at LOD0
	return [creature, rag]


func _static_box(pos: Vector3, size: Vector3) -> StaticBody3D:
	var b := StaticBody3D.new()
	b.position = pos
	b.collision_layer = 1                   # World — ragdoll bones mask this
	var cs := CollisionShape3D.new()
	var bx := BoxShape3D.new()
	bx.size = size
	cs.shape = bx
	b.add_child(cs)
	return b
