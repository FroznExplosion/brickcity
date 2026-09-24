extends SceneTree

## Acceptance probe for gate G1b: the cheap representation must show the damage
## the truth layer is holding.
##
##     godot --headless --path . --script tools/shell_probe.gd
##
## G1 says damage state survives demote -> promote byte-identical, and it did.
## The PICTURE did not: _make_shell built from (footprint, courses) and read the
## damage record nowhere, so a building you blew a hole in, walked away from and
## looked back at redrew intact. Docs/BuildMode.md section 9.5.

var _pass := 0
var _fail := 0


func _init() -> void:
	print("shell probe (G1b)")
	_check_runs()
	_check_intact_is_unchanged()
	_check_damage_shows()
	_check_profile_survives_dematerialise()
	_check_windows()
	print("\n%d passed, %d failed" % [_pass, _fail])
	quit(1 if _fail > 0 else 0)


func _ok(what: String, cond: bool, detail: String = "") -> void:
	if cond:
		_pass += 1
		print("  ok   %s" % what)
	else:
		_fail += 1
		print("  FAIL %s%s" % [what, (" -- " + detail) if detail else ""])


func _tris(mesh: ArrayMesh) -> int:
	if mesh.get_surface_count() == 0:
		return 0
	var a := mesh.surface_get_arrays(0)
	@warning_ignore("integer_division")
	var n: int = (a[Mesh.ARRAY_INDEX] as PackedInt32Array).size() / 3
	return n


func _full() -> PackedInt32Array:
	var v := BuildingShell.ALL_STANDING
	return PackedInt32Array([v, v, v, v])


# ---------------------------------------------------------------------------

func _check_runs() -> void:
	print("\nsegment runs")
	var span := 32.0
	_ok("a full mask is ONE run, not 32",
			BuildingShell._runs(BuildingShell.ALL_STANDING, span).size() == 1)
	_ok("and it spans the whole wall",
			BuildingShell._runs(BuildingShell.ALL_STANDING, span)[0] == Vector2(0.0, span))
	_ok("an empty mask is no runs at all",
			BuildingShell._runs(0, span).is_empty())

	# A hole in the middle splits one wall into two.
	var holed := BuildingShell.ALL_STANDING & ~(15 << 8)
	var runs := BuildingShell._runs(holed, span)
	_ok("a hole in the middle makes two runs", runs.size() == 2, "%s" % [runs])
	_ok("the gap is where the hole is",
			runs.size() == 2 and runs[0].y == 8.0 and runs[1].x == 12.0, "%s" % [runs])

	# Adjacent set bits must merge, or a damaged wall costs 32 quads.
	var half := 0xFFFF
	_ok("adjacent segments merge into one run",
			BuildingShell._runs(half, span).size() == 1)
	_ok("and it is half the wall",
			BuildingShell._runs(half, span)[0] == Vector2(0.0, 16.0))


func _check_intact_is_unchanged() -> void:
	print("\nan intact building is untouched by G1b")
	var plain := BuildingShell.build_arrays(24, 16, 12)
	var empty := BuildingShell.build_arrays(24, 16, 12, {})
	_ok("no profile and an empty profile agree",
			plain[Mesh.ARRAY_VERTEX] == empty[Mesh.ARRAY_VERTEX])

	# All-standing masks must produce the identical mesh, or the intact case is
	# paying for the feature.
	var all := {}
	for i in TowerRecipe.layout(12).size():
		all[i] = _full()
	var masked := BuildingShell.build_arrays(24, 16, 12, all)
	_ok("an all-standing profile is byte-identical to no profile",
			plain[Mesh.ARRAY_VERTEX] == masked[Mesh.ARRAY_VERTEX])
	_ok("and so are its colours", plain[Mesh.ARRAY_COLOR] == masked[Mesh.ARRAY_COLOR])


func _check_damage_shows() -> void:
	print("\ndamage reaches the shell")
	var intact := BuildingShell.build_mesh(24, 16, 12)
	var base := _tris(intact)
	_ok("an intact shell has geometry", base > 0, "%d tris" % base)

	# Blow one side out of one band entirely.
	var v := BuildingShell.ALL_STANDING
	var one_gone := {4: PackedInt32Array([0, v, v, v])}
	var t1 := _tris(BuildingShell.build_mesh(24, 16, 12, one_gone))
	_ok("losing a whole wall of one band loses triangles", t1 < base, "%d vs %d" % [t1, base])

	# A hole in the MIDDLE of a side splits it, so triangles go UP, not down --
	# which is what proves the hole is really being drawn round, rather than the
	# wall being quietly deleted.
	var holed_mask := v & ~(3 << 14)
	var holed := {4: PackedInt32Array([holed_mask, v, v, v])}
	var t2 := _tris(BuildingShell.build_mesh(24, 16, 12, holed))
	_ok("a hole in the middle ADDS triangles (the wall splits round it)",
			t2 > base, "%d vs %d" % [t2, base])

	# Everything gone is a mesh with no surface, not a crash and not a phantom.
	var all_gone := {}
	for i in TowerRecipe.layout(12).size():
		all_gone[i] = PackedInt32Array([0, 0, 0, 0])
	_ok("a building with nothing left draws nothing",
			_tris(BuildingShell.build_mesh(24, 16, 12, all_gone)) == 0)


func _check_profile_survives_dematerialise() -> void:
	print("\nthe profile outlives the bricks")
	var w := BrickWorld.new()
	var palette := TowerRecipe.bake_palette(w)
	var reg := BuildingRegistry.new(w, palette)
	var id := reg.register(24, 16, 12, Transform3D())
	_ok("registered", id >= 0)
	_ok("an untouched building has no profile",
			reg.get_building(id).damage_profile.is_empty())

	var chunk := reg.materialise(id)
	_ok("materialised", chunk >= 0)
	var before := w.get_alive_block_count(chunk)

	# Blow a hole low in one wall, where the shell will have to show it. Go
	# through the registry rather than straight at BrickWorld: that is what
	# marks the building damaged, and it is what the game actually calls.
	var hit := reg.damage(id, Vector3(24 * 0.35 * 0.5, 1.4, 0.2), 1.6)
	_ok("the hit removed bricks", hit.size() > 0, "%d" % hit.size())
	_ok("the building is damaged", reg.get_building(id).is_damaged())

	reg.dematerialise(id)
	var b := reg.get_building(id)
	_ok("the bricks are gone", not b.is_materialised())
	_ok("but the damage record is not", not b.dead.is_empty(), "%d dead" % b.dead.size())
	_ok("and a damage PROFILE now exists", not b.damage_profile.is_empty(),
			"%d bands" % b.damage_profile.size())

	# The whole point: the shell drawn from it is not the intact shell.
	var intact := _tris(BuildingShell.build_mesh(24, 16, 12))
	var damaged := _tris(BuildingShell.build_mesh(24, 16, 12, b.damage_profile))
	_ok("the shell drawn for it differs from the intact one", damaged != intact,
			"%d vs %d" % [damaged, intact])
	_ok("and it still draws something", damaged > 0, "%d" % damaged)

	# It must be stable: asking twice gives the same picture.
	_ok("rebuilding the shell is deterministic",
			_tris(BuildingShell.build_mesh(24, 16, 12, b.damage_profile)) == damaged)

	# And re-materialising must not lose it.
	reg.materialise(id)
	_ok("re-materialised", reg.get_building(id).is_materialised())
	_ok("the same bricks are still missing",
			w.get_alive_block_count(reg.get_building(id).chunk) < before,
			"%d vs %d" % [w.get_alive_block_count(reg.get_building(id).chunk), before])
	_ok("and the profile is still there", not reg.get_building(id).damage_profile.is_empty())


# ---------------------------------------------------------------------------

## A shell's windows: panes of glass over exactly the openings the bricks have,
## each showing the kind of room really behind it.
func _check_windows() -> void:
	print("\nits windows are where the bricks' windows are")
	var w := BrickWorld.new()
	var palette := TowerRecipe.bake_palette(w)
	var reg := BuildingRegistry.new(w, palette)
	var fx := 40
	var fz := 30
	var courses := 42
	var id := reg.register(fx, fz, courses, Transform3D())
	var seed := reg.room_seed_of(id)
	var mesh := BuildingShell.build_window_mesh(fx, fz, courses, seed)
	_ok("a shell has windows", mesh != null and mesh.get_surface_count() == 1)
	if mesh == null:
		return
	var a := mesh.surface_get_arrays(0)
	var verts: PackedVector3Array = a[Mesh.ARRAY_VERTEX]
	var colours: PackedColorArray = a[Mesh.ARRAY_COLOR]
	@warning_ignore("integer_division")
	var panes: int = verts.size() / 4

	# As many as the recipe cuts: every window course's storey, every gap, four
	# sides.
	var storeys := 0
	for c in courses:
		if c % TowerRecipe.COURSES_PER_FLOOR == TowerRecipe.COURSES_PER_FLOOR - 1 \
				- TowerRecipe.WINDOW_COURSES and TowerRecipe.is_window_course(c, courses):
			storeys += 1
	var per_storey: int = 2 * TowerRecipe.window_gaps(fx).size() \
			+ 2 * TowerRecipe.window_gaps(fz).size()
	_ok("one pane for every window the bricks have", panes == storeys * per_storey,
			"%d panes, %d storeys x %d" % [panes, storeys, per_storey])

	# Proud of the wall, never inside the building.
	var inside := 0
	var wm := fx * BuildingShell.STUD
	var dm := fz * BuildingShell.STUD
	for v in verts:
		if v.x > 0.0 and v.x < wm and v.z > 0.0 and v.z < dm:
			inside += 1
	_ok("every pane stands just proud of its wall", inside == 0, "%d corners inside" % inside)

	# And over a real opening: the brick wall straight behind each pane's middle
	# is not there.
	var chunk := reg.materialise(id)
	var solid := 0
	for k in panes:
		var mid := (verts[k * 4] + verts[k * 4 + 3]) * 0.5
		var cell := Vector3i(floori(mid.x / BuildingShell.STUD),
				floori(mid.y / BuildingShell.PLATE), floori(mid.z / BuildingShell.STUD))
		cell.x = clampi(cell.x, 0, fx - 1)
		cell.z = clampi(cell.z, 0, fz - 1)
		if w.is_solid(chunk, cell):
			solid += 1
	_ok("and over a hole in the brick wall, not over brickwork", solid == 0,
			"%d of %d panes over brick" % [solid, panes])

	# The kind a pane paints is the kind of the room behind it.
	var wrong := 0
	for room in reg.rooms_of(id):
		var at := Vector2(room.lo.x + room.size.x * 0.5, room.lo.z + room.size.z * 0.5)
		var storey := -1
		var list := RoomManifest.storeys_of(courses)
		for si in list.size():
			if int(list[si].floor_y) == room.lo.y:
				storey = si
		var kind := RoomManifest.kind_at(fx, fz, courses, seed, storey, at)
		if kind != Room.KINDS.find(room.kind):
			wrong += 1
	_ok("the room kind a window paints is the room that is there", wrong == 0,
			"%d rooms disagree" % wrong)
	var kinds := {}
	for c in colours:
		kinds[int(round(c.a * 4.0))] = true
	_ok("and a building's windows show more than one kind of room", kinds.size() > 1,
			"%d kinds" % kinds.size())

	# A damaged storey loses its panes: glass over a hole is glass in mid-air.
	var bands := TowerRecipe.layout(courses)
	var damaged_band := -1
	for i in bands.size():
		var band: Dictionary = bands[i]
		if band.kind == "course" and TowerRecipe.is_window_course(int(band.index), courses):
			damaged_band = i
			break
	var damage := {damaged_band: PackedInt32Array([0, -1, -1, -1])}
	var hurt := BuildingShell.build_window_mesh(fx, fz, courses, seed, damage)
	@warning_ignore("integer_division")
	var left: int = (hurt.surface_get_arrays(0)[Mesh.ARRAY_VERTEX] as PackedVector3Array).size() / 4
	_ok("a damaged storey shows no glass", left == panes - per_storey,
			"%d panes, expected %d" % [left, panes - per_storey])
