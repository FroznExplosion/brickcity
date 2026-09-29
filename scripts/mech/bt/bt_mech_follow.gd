@tool
class_name BTMechFollow
extends BTAction
## FOLLOW (AI.md 2.1): in a band round the pilot -- it comes when further than
## FOLLOW_FAR and stops inside FOLLOW_NEAR.

var _coming := false


func _tick(_delta: float) -> Status:
	var br := MechTree.brain_of(agent)
	if br.leader == null or not is_instance_valid(br.leader):
		return FAILURE
	var feet := br.mech.feet()
	var lead := br.leader.feet()
	var d := Vector2(feet.x - lead.x, feet.z - lead.z).length()
	if d > MechBrain.FOLLOW_FAR:
		_coming = true
	elif d < MechBrain.FOLLOW_NEAR + 0.5:
		_coming = false
	br.state = "follow"
	if _coming:
		# To the near edge of the band, on the side it is coming from.
		var back := feet - lead
		back.y = 0.0
		var spot := lead + back.normalized() * (MechBrain.FOLLOW_NEAR + 0.5)
		if br.move_to(spot, d > 20.0) == 1:
			_coming = false
	else:
		br.stop()
		br.face(lead)
	return RUNNING
