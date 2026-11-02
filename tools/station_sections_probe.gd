extends SceneTree
## A generated station in space (Docs/RoomModules.md 7.3, stage 10): SpaceStation
## with an orbital of layout "generated" -- grown from the station kit by its
## seed, laid in bricks, held by its keel, and a section shot off at its joint
## leaving whole.
##
##     godot --headless --path . --script res://tools/station_sections_probe.gd
##
##   systems   a generated system's stations are "generated", home's a tower
##   grown     prepare grows it (the same each time for its seed), its template
##             built, its shell a box round each section, its box its own
##   laid      activate lays every brick of it, nothing loose: its keel the
##             foundation
##   drift     every brick where a section (its fewest joints) meets the rest killed: the solve
##             sends the section off whole (`drifted`, one rigid piece)

var _pass := 0
var _fail := 0
var _drifts := []
var _done := false


func _process(_d: float) -> bool:
	if not _done:
		_done = true
		print("station sections probe")
		_run()
		if _st == null:
			_finish()
		return false
	if _st == null:
		return true
	_frames += 1
	if not _st.bricked and _frames < 600:
		return false
	_after_laid()
	_st = null
	_finish()
	return true


func _finish() -> void:
	print("\n%d passed, %d failed" % [_pass, _fail])
	quit(1 if _fail > 0 else 0)


func _ok(what: String, cond: bool, detail := "") -> void:
	if cond:
		_pass += 1
		print("  ok   %s%s" % [what, ("  " + detail) if detail else ""])
	else:
		_fail += 1
		print("  FAIL %s%s" % [what, (" -- " + detail) if detail else ""])


func _run() -> void:
	# Systems: home's station a tower, any other a generated one.
	var n_gen := 0
	var n_tower := 0
	var home_ok := true
	for sd in [1, 2, 3, 4, 5]:
		var sys := StarSystem.generate(sd, PlanetData.new() if sd == 1 else null)
		for o: OrbitalData in sys.orbitals:
			if o.kind != "station":
				continue
			if o.layout == "generated":
				n_gen += 1
			else:
				n_tower += 1
			if (o.parent == sys.home) != (o.layout == "tower"):
				home_ok = false
	_ok("home's station is the story's tower; any other station generated", home_ok and n_gen > 0,
			"%d tower(s), %d generated in 5 systems" % [n_tower, n_gen])

	var d := OrbitalData.new()
	d.kind = "station"
	d.layout = "generated"
	d.orbital_name = "probe station"
	d.orbital_seed = 4242
	var st := SpaceStation.new()
	root.add_child(st)
	st.setup(d)
	st.drifted.connect(func(_arrays, _com, _lc, count: int, _m) -> void: _drifts.append(count))
	st.prepare()
	var r: BuildRecipe = st.recipe
	var again := RoomStation.generate(StationKit.library(), {"seed": 4242, "modules": 12 + 4242 % 12,
			"spine": 3 + 4242 % 3, "section_bricks": SpaceStation.SECTION_BRICKS})
	var secs: Array = r.meta.sections.sections if r != null else []
	_ok("prepare grows it from its seed (the same each time), its shell a box round each section",
			r != null and again.recipe.size() == r.size() and st.shell.mesh.get_surface_count() == secs.size()
			and st.shell_body.get_child_count() >= secs.size() and d.fx == (r.bounds()[1] as Vector3i).x,
			"%d bricks, %d section(s), grown in %.0f ms, template %.0f ms" % [r.size() if r else 0, secs.size(),
				st.grow_ms, st.template_ms])
	if r == null:
		return

	st.activate()
	_st = st
	_r = r
	_again = again


var _st: SpaceStation
var _r: BuildRecipe
var _again: Dictionary
var _frames := 0


## Its bands drawn and its collision made, frame by frame; then the rest.
func _after_laid() -> void:
	var st := _st
	var r := _r
	var again := _again
	_ok("its bricks drawn and solid, frame by frame", st.bricked, "%d frame(s)" % _frames)
	var alive := st.bricks.get_alive_block_count(st.chunk)
	var loose: Array = st.bricks.find_detached_groups(st.chunk)
	_ok("activate lays every brick, nothing loose: the keel its foundation",
			alive == r.size() and loose.is_empty(), "%d of %d alive, %d loose group(s)" % [alive, r.size(), loose.size()])

	# A leaf section's joint shot away.
	var lib := StationKit.library()
	var cut := BuildSections.of_plan(lib, again.plan, again.recipe, again.plan.at, 2500)
	var org := r.origin()
	var touch := {}
	for j: Dictionary in cut.joints:
		touch[int(j.a)] = int(touch.get(int(j.a), 0)) + 1
		touch[int(j.b)] = int(touch.get(int(j.b), 0)) + 1
	# The section with the fewest joints (a leaf, where there is one; bridges can
	# close every section into a loop): all its joints are killed, so it is cut off.
	var leaf := -1
	for k in touch:
		if int(k) != 0 and (leaf < 0 or int(touch[k]) < int(touch[leaf])):
			leaf = int(k)
	var size_leaf := 0
	for k in (cut.of as PackedInt32Array).size():
		if int(cut.of[k]) == leaf:
			size_leaf += 1
	var killed := PackedInt32Array()
	for j: Dictionary in cut.joints:
		if int(j.a) == leaf or int(j.b) == leaf:
			for cell: Vector3i in j.cells:
				var b := st.bricks.block_at(st.chunk, cell - org)
				if b >= 0 and not killed.has(b):
					killed.append(b)
	st.bricks.kill_blocks(st.chunk, killed)
	st._after_kill(killed)
	st._solve()
	var biggest := 0
	for n: int in _drifts:
		biggest = maxi(biggest, n)
	_ok("a section's joints shot away: the section drifts off whole",
			leaf > 0 and biggest >= size_leaf * 0.6,
			"section %d of %d bricks, %d killed at its joint, drifted %s" % [leaf, size_leaf, killed.size(), str(_drifts)])
	st.deactivate()
	st.queue_free()
