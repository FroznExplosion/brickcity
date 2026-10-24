class_name PartFit
extends RefCounted
## What fits what (Docs/ModularParts.md section 3): layer 1, a part on one socket; layer 2,
## a whole build against its body plan. Every answer is a reason, "" or empty when it fits,
## so the workshop can mark an unfit part with why (section 9) and the generator can refuse
## it (section 7: the game only ever puts together parts that fit).
##
## A build here is {root: PartRecord, at: {path: PartRecord}}. A path is the host's path,
## "/", the socket's name ("arm_L/hand"); the root's sockets have bare names ("arm_L").


## Why `part` does not fit the socket at `path` of a build of `plan_name` whose part there
## would hang from `host`; "" when it fits.
static func why_not(part: PartRecord, host: PartRecord, path: String, plan_name: String) -> String:
	var spot: Dictionary = (PartStandards.plan(plan_name).get("sockets", {}) as Dictionary).get(path, {})
	if spot.is_empty():
		return "a %s has no '%s'" % [plan_name, path]
	if part.slot != String(spot.slot):
		return "'%s' takes a %s, this is a %s" % [path, spot.slot, part.slot]
	var want_side := String(spot.get("side", "any"))
	if want_side != "any" and part.side != "any" and part.side != want_side and not part.mirrorable:
		return "'%s' is the %s side, this part is %s only" % [path, want_side, part.side]
	if host == null:
		return "nothing for '%s' to hang from" % path
	if part.scale != host.scale:
		return "a %s part on a %s build" % [_scale_word(part.scale), _scale_word(host.scale)]
	var sock := host.socket(path.get_file())
	if sock.is_empty():
		return "%s has no socket '%s'" % [host.id, path.get_file()]
	var iface := part.interface()
	if iface == "" or PartStandards.interface(iface).is_empty():
		return "mounts on no known interface ('%s')" % iface
	var accepts: Array = sock.get("accepts", [])
	if not iface in accepts:
		return "mounts on %s, socket takes %s" % [iface, " or ".join(PackedStringArray(accepts))]
	return ""


static func fits(part: PartRecord, host: PartRecord, path: String, plan_name: String) -> bool:
	return why_not(part, host, path, plan_name) == ""


## Everything wrong with a whole build (empty: it fits). Layer 1 for every part, then the
## plan's rules: the root, required sockets filled, and parts that must agree (`same`: both
## legs one length).
static func problems(build: Dictionary, plan_name: String) -> PackedStringArray:
	var out := PackedStringArray()
	var plan := PartStandards.plan(plan_name)
	if plan.is_empty():
		out.append("no body plan '%s'" % plan_name)
		return out
	var root: PartRecord = build.get("root")
	var at: Dictionary = build.get("at", {})
	if root == null:
		out.append("no %s" % plan.root)
		return out
	if root.slot != String(plan.root):
		out.append("the root is a %s, a %s is built on a %s" % [root.slot, plan_name, plan.root])
	for path: String in at:
		var host: PartRecord = root if path.get_base_dir() == "" else at.get(path.get_base_dir())
		var why := why_not(at[path], host, path, plan_name)
		if why != "":
			out.append("%s: %s" % [path, why])
	var spots: Dictionary = plan.get("sockets", {})
	for path: String in spots:
		if bool(spots[path].get("required", false)) and not at.has(path):
			out.append("%s: empty, and a %s needs it" % [path, plan_name])
	for rule: Dictionary in plan.get("same", []):
		var seen := {}
		for path: String in rule.paths:
			if at.has(path):
				seen[path] = (at[path] as PartRecord).param(String(rule.param))
		var values := {}
		for v in seen.values():
			values[str(v)] = true
		if values.size() > 1:
			var said := PackedStringArray()
			for path: String in seen:
				said.append("%s %s" % [path, str(seen[path])])
			out.append("%s must match: %s" % [rule.param, ", ".join(said)])
	return out


static func _scale_word(s: String) -> String:
	return s if s != "" else "unscaled"
