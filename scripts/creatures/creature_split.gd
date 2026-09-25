class_name CreatureSplit
extends RefCounted
## Builder-level Target/Puppet split for procedural creatures (gait_physics_merge).
## ============================================================================================
## DRAFT reference — NOT YET RUN.
##
## The procgen `CreatureBuilder` builds ONE skeleton (gait + TwoBoneIK3D pose it; the skinned
## mesh renders from it). To add the physics layer we need TWO skeletons of the same rig:
##   TARGET = the creature's own skeleton — gait + IK keep posing it kinematically.
##   PUPPET = a bones-only duplicate that the visible skinned mesh now renders from, so the
##            physics layer (CreatureRagdoll) can drive it without the gait fighting it.
## The canonical split now lives in `CreatureBuilder.split_rig` (procgen owns it — correct dependency
## direction). This is a thin convenience for the "split an already-built ProcCreature" case; to build
## split from scratch use `CreatureBuilder.build(dna, root, true)`.

## Split a built ProcCreature. Delegates to CreatureBuilder.split_rig; returns the rig with
## `target` / `puppet` / `puppet_mesh` added (the visible mesh now renders from the Puppet; the
## Target's mesh is hidden and it stays kinematic-only, gait + IK still running on it).
static func make(creature) -> Dictionary:
	return CreatureBuilder.split_rig(creature.rig, creature)
