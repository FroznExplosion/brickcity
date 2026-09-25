class_name ProcCreature
extends Node3D
## A procedurally generated, procedurally animated creature.
## Usage:  var c := ProcCreature.spawn(CreatureDNA.random(seed))
##         world.add_child(c)   # position it, done.

var dna: CreatureDNA
var rig: Dictionary = {}
var gait: GaitController
var canned: CannedGait
var lod: CreatureLOD

static func spawn(p_dna: CreatureDNA) -> ProcCreature:
	var c := ProcCreature.new()
	c.dna = p_dna
	c.name = "%s_%d" % [p_dna.creature_name, p_dna.seed_value]
	return c

func _ready() -> void:
	rig = CreatureBuilder.build(dna, self)
	gait = GaitController.new()
	gait.name = "Gait"
	add_child(gait)
	gait.setup(self, rig, dna)
	canned = CannedGait.new()
	canned.name = "CannedGait"
	add_child(canned)
	canned.setup(self, rig, dna)
	lod = CreatureLOD.new()
	lod.name = "LOD"
	add_child(lod)
	lod.setup(self, rig, gait, canned)

func set_forced_lod(tier: int) -> void:
	lod.force_now(tier)
