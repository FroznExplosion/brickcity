class_name PartBuilder
extends RefCounted
## Rolls a build of a body plan from the catalogue (Docs/ModularParts.md sections 3 and 7,
## stage 6): the root, then every socket from the root out, each from the parts that fit
## what it hangs from (PartFit layer 1) and keep the plan's rules (layer 2: both legs one
## length). A design fixes slots or narrows their pools. The same seed, design and catalogue
## roll the same build every time: candidates in id order, one RandomNumberGenerator.
##
## Only parts that fit are ever rolled. A design's fixed part that does not fit is a fault
## in the design: the build comes back with the problem, and callers make nothing of it.
##
##     var b := PartBuilder.generate("mech", null, 7, cat, {"class": "heavy"})
##     if b.problems.is_empty(): MechAssembler.assemble(b)

## opts:
##   class      the root's class ("light" / "normal" / "heavy"), "" any
##   custom     roll pools from custom parts as well (default: official only, so a seed rolls
##              the same on every machine; a design's fixed parts may be any)
##   optional   fill optional sockets (pods) when anything fits (default true)
## Returns {root: PartRecord, at: {path: PartRecord}, problems: PackedStringArray}.
static func generate(plan_name: String, design: PartDesign, gen_seed: int, cat: PartCatalog,
		opts: Dictionary = {}) -> Dictionary:
	var out := {"root": null, "at": {}, "problems": PackedStringArray(),
			"motion": design.motion.duplicate() if design != null else {}}
	var plan := PartStandards.plan(plan_name)
	if plan.is_empty():
		out.problems.append("no body plan '%s'" % plan_name)
		return out
	var rng := RandomNumberGenerator.new()
	rng.seed = gen_seed
	var slots: Dictionary = design.slots if design != null else {}
	var sources: Array = ["official", "custom"] if opts.get("custom", false) else ["official"]

	# The root.
	var root_q := {"slot": [String(plan.root)], "source": sources}
	if String(opts.get("class", "")) != "":
		root_q["class"] = [String(opts["class"])]
	var root := _choose(slots.get("root", {}), cat.filter(root_q), cat, rng, out.problems, "root",
			func(_r: PartRecord) -> String: return "")
	if root == null:
		if (out.problems as PackedStringArray).is_empty():
			out.problems.append("nothing for the root (%s)" % plan.root)
		return out
	out.root = root

	# The sockets, hosts before what hangs on them.
	var sockets: Dictionary = plan.get("sockets", {})
	var paths := sockets.keys()
	paths.sort_custom(func(a: String, b: String) -> bool:
		var da := a.count("/")
		var db := b.count("/")
		return da < db if da != db else a < b)
	var same_value := {}   # group index -> the param value its paths keep
	for path: String in paths:
		var spot: Dictionary = sockets[path]
		var host: PartRecord = root if not path.contains("/") else (out.at as Dictionary).get(path.get_base_dir())
		var want: Dictionary = slots.get(path, {})
		if want.get("empty", false) or host == null:
			continue
		if not spot.get("required", false) and not opts.get("optional", true) and not want.has("fixed"):
			continue
		var pool := cat.filter({"slot": [String(spot.slot)], "source": sources})
		# Layer 2: a `same` group keeps one value. Its value is rolled once, from those every
		# path of the group can have.
		var group := _group_of(plan, path)
		var rule := func(r: PartRecord) -> String: return ""
		if group >= 0:
			var param := String((plan.same as Array)[group].param)
			if not same_value.has(group):
				same_value[group] = _roll_same(plan_name, plan, group, root, out.at, slots, cat, sources, rng)
			var v: Variant = same_value[group]
			rule = func(r: PartRecord) -> String:
				if v == null or r.param(param) == null or int(r.param(param)) == int(v):
					return ""
				return "its %s is %s, the other's %s" % [param, r.param(param), v]
		var fits := func(r: PartRecord) -> String:
			var why := PartFit.why_not(r, host, path, plan_name)
			return why if why != "" else rule.call(r)
		var pick := _choose(want, pool, cat, rng, out.problems, path, fits)
		if pick != null:
			out.at[path] = pick
		elif spot.get("required", false) and not Array(out.problems).any(
				func(p: String) -> bool: return p.begins_with(path + ":")):
			out.problems.append("%s: nothing fits" % path)
	var whole := PartFit.problems({"root": root, "at": out.at}, plan_name)
	for p in whole:
		if not p in out.problems:
			out.problems.append(p)
	return out


## One slot: its fixed part (checked: a fixed part that does not fit is a problem), or a
## pick from `pool` narrowed by the design's query and to what `fits` passes.
static func _choose(want: Dictionary, pool: Array[PartRecord], cat: PartCatalog,
		rng: RandomNumberGenerator, problems: PackedStringArray, path: String, fits: Callable) -> PartRecord:
	if want.has("fixed"):
		var r := cat.get_part(String(want.fixed))
		if r == null:
			problems.append("%s: no part '%s'" % [path, want.fixed])
			return null
		var why: String = fits.call(r)
		if why != "":
			problems.append("%s: %s does not fit: %s" % [path, r.id, why])
		return r
	if want.has("pool"):
		pool = cat.filter(want.pool, pool)
	var ok: Array[PartRecord] = []
	for r in pool:
		if fits.call(r) == "":
			ok.append(r)
	if ok.is_empty():
		return null
	return ok[rng.randi_range(0, ok.size() - 1)]


static func _group_of(plan: Dictionary, path: String) -> int:
	var groups: Array = plan.get("same", [])
	for i in groups.size():
		if path in (groups[i].paths as Array):
			return i
	return -1


## The value a `same` group keeps: one every path of it has a fitting part for (a fixed
## part's own, if one is fixed), rolled; null when they share none.
static func _roll_same(plan_name: String, plan: Dictionary, group: int, root: PartRecord, at: Dictionary,
		slots: Dictionary, cat: PartCatalog, sources: Array, rng: RandomNumberGenerator) -> Variant:
	var g: Dictionary = (plan.same as Array)[group]
	var param := String(g.param)
	var shared: Variant = null   # Array of values every path can have
	for path: String in g.paths:
		var spot: Dictionary = plan.sockets[path]
		var host: PartRecord = root if not path.contains("/") else at.get(path.get_base_dir())
		var want: Dictionary = slots.get(path, {})
		var vals := {}
		if want.has("fixed"):
			var f := cat.get_part(String(want.fixed))
			if f != null and f.param(param) != null:
				return int(f.param(param))
			continue
		var pool := cat.filter({"slot": [String(spot.slot)], "source": sources})
		if want.has("pool"):
			pool = cat.filter(want.pool, pool)
		for r in pool:
			if r.param(param) != null and host != null and PartFit.fits(r, host, path, plan_name):
				vals[int(r.param(param))] = true
		var keys := vals.keys()
		if shared == null:
			shared = keys
		else:
			shared = (shared as Array).filter(func(v: int) -> bool: return v in keys)
	if shared == null or (shared as Array).is_empty():
		return null
	(shared as Array).sort()
	return shared[rng.randi_range(0, (shared as Array).size() - 1)]

