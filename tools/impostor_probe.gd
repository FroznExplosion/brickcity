extends SceneTree

## The impostor system on its own (Docs/Impostors.md 8): tree recipes, their
## meshes, an octahedral bake, and an ImpostorLod drawing a field of them.
##
##     godot --path . --script res://tools/impostor_probe.gd
##
## Not headless: a bake needs a renderer. Writes shots/impostor_*.png.

var _ok := 0
var _fail := 0


func _check(what: String, cond: bool, detail: String = "") -> void:
	if cond:
		_ok += 1
		print("  ok   %s" % what)
	else:
		_fail += 1
		print("  FAIL %s%s" % [what, (" -- " + detail) if detail else ""])


func _grab() -> Image:
	for i in 4:
		await process_frame
	return get_root().get_texture().get_image()


## Overlap of what two pictures cover -- every pixel not the background.
static func _iou(a: Image, b: Image, bg: Color) -> float:
	var both := 0
	var either := 0
	for y in range(0, a.get_height(), 2):
		for x in range(0, a.get_width(), 2):
			var ia := _covered(a.get_pixel(x, y), bg)
			var ib := _covered(b.get_pixel(x, y), bg)
			if ia and ib:
				both += 1
			if ia or ib:
				either += 1
	return float(both) / maxf(either, 1)


static func _covered(c: Color, bg: Color) -> bool:
	return absf(c.r - bg.r) + absf(c.g - bg.g) + absf(c.b - bg.b) > 0.12


func _init() -> void:
	_run.call_deferred()


func _run() -> void:
	print("[impostor] trees, meshes, bakes")
	var w := BrickWorld.new()
	var pal := TowerRecipe.bake_palette(w)
	var meshes := []
	for v in Trees.VARIANTS:
		var r := Trees.recipe(v)
		var asm := Assembly.new(w, pal)
		var placed := r.build_into(asm, pal)
		_check("tree %d: all %d pieces placed" % [v, r.size()], placed == r.size(),
				"%d placed" % placed)
		var m := RecipeMesh.build(r, "tree_%d" % v)
		@warning_ignore("integer_division")
		var tris := m.get_faces().size() / 3 if m.get_surface_count() > 0 else 0
		print("[impostor]   tree %d: %d pieces, %.1f m tall, %d triangles" % [
				v, r.size(), Trees.height_m(v), tris])
		_check("tree %d has a mesh" % v, tris > 0)
		meshes.append(m)

	# A scene to look at it in.
	var root := Node3D.new()
	get_root().add_child(root)
	var cam := Camera3D.new()
	cam.far = 2000.0
	# Where it is put, the frame it is put there. The project interpolates
	# between physics ticks, a camera included, and this scene draws hundreds
	# of frames a tick: a picture taken four frames after a move was taken from
	# somewhere on the way (a card 120 m off measured a twentieth of its size,
	# a different fraction every run).
	cam.physics_interpolation_mode = Node.PHYSICS_INTERPOLATION_MODE_OFF
	root.add_child(cam)
	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-40, -35, 0)
	sun.shadow_enabled = true
	root.add_child(sun)
	var env := Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color(0.55, 0.7, 0.85)
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color(0.6, 0.6, 0.6)
	var we := WorldEnvironment.new()
	we.environment = env
	root.add_child(we)
	var ground := MeshInstance3D.new()
	var plane := PlaneMesh.new()
	plane.size = Vector2(2000, 2000)
	ground.mesh = plane
	root.add_child(ground)

	var brick := ShaderMaterial.new()
	brick.shader = load("res://shaders/brick.gdshader")
	var lod := ImpostorLod.new()
	root.add_child(lod)
	lod.setup(meshes[0], brick, 30.0)
	# A row going away from the camera, and a field behind it.
	for i in 40:
		lod.add(Transform3D(Basis(Vector3.UP, float(i) * 0.7), Vector3(-6.0, 0.0, -8.0 - i * 6.0)))
	for i in 200:
		lod.add(Transform3D(Basis(), Vector3(-60.0 + (i % 20) * 7.0, 0.0, -60.0 - (i / 20) * 9.0)))

	# Wait for the bake.
	var guard := 0
	while lod.bake.is_empty() and guard < 300:
		await process_frame
		guard += 1
	_check("the impostor baked", not lod.bake.is_empty(), "%d frames" % guard)
	if not lod.bake.is_empty():
		var img: Image = (lod.bake.albedo as Texture2D).get_image()
		var covered := 0
		var n := 0
		for y in range(0, img.get_height(), 4):
			for x in range(0, img.get_width(), 4):
				n += 1
				if img.get_pixel(x, y).a > 0.5:
					covered += 1
		print("[impostor]   atlas %dx%d, %.0f%% covered, radius %.2f m" % [
				img.get_width(), img.get_height(), 100.0 * covered / n, float(lod.bake.radius)])
		_check("the atlas has the tree in it", covered > n / 20)
		img.save_png("res://shots/impostor_atlas.png")

	cam.position = Vector3(0.0, 3.0, 4.0)
	cam.look_at(Vector3(-6.0, 3.0, -40.0), Vector3.UP)
	lod.update(cam.position)
	print("[impostor]   %d near, %d far" % [lod.near_count, lod.far_count])
	_check("near and far both drawn", lod.near_count > 0 and lod.far_count > 0)
	for i in 6:
		await process_frame
	get_root().get_texture().get_image().save_png("res://shots/impostor_row.png")

	# The same tree at 60 m, as mesh and as card, side by side.
	var twin := MeshInstance3D.new()
	twin.mesh = meshes[0]
	twin.material_override = brick
	root.add_child(twin)
	twin.position = Vector3(2000.0, 0.0, 0.0)
	var solo := ImpostorLod.new()
	root.add_child(solo)
	solo.setup(meshes[0], brick, 1.0)
	guard = 0
	while solo.bake.is_empty() and guard < 300:
		await process_frame
		guard += 1
	solo.add(Transform3D(Basis(), Vector3(2004.0, 0.0, 0.0)))
	twin.position = Vector3(1996.0, 0.0, 0.0)
	cam.position = Vector3(2000.0, 4.0, 14.0)
	cam.look_at(Vector3(2000.0, 3.0, 0.0), Vector3.UP)
	solo.update(Vector3(2000.0, 0.0, 200.0))   # far, whatever the camera says
	for i in 6:
		await process_frame
	get_root().get_texture().get_image().save_png("res://shots/impostor_pair.png")

	# The card stands where the tree stands, from any height: a card that swam
	# put its views' features in different places as the camera moved. Card
	# against mesh, the same spot, over sky only (nothing out here but them).
	var spot := Vector3(2004.0, 0.0, 0.0)
	twin.position = spot
	var ious := []
	for elev in [2.0, 15.0, 40.0]:
		cam.position = spot + Vector3(0.0, elev, 60.0)
		cam.look_at(spot + Vector3(0.0, 3.0, 0.0), Vector3.UP)
		twin.visible = true
		solo.set_wanted(0, false)
		solo.update(Vector3(2000.0, 0.0, 200.0))
		var mesh_img := await _grab()
		twin.visible = false
		solo.set_wanted(0, true)
		solo.update(Vector3(2000.0, 0.0, 200.0))
		var card_img := await _grab()
		ious.append(_iou(mesh_img, card_img, env.background_color))
	print("[impostor]   card over mesh, from 2 / 15 / 40 m up at 60 m: %.2f / %.2f / %.2f" % ious)
	_check("the card stands where the tree does, from any height",
			ious.all(func(v): return v > 0.75), str(ious))
	twin.visible = false

	# The mesh-to-card band: drawn as both, dithered into each other, it has
	# no holes. A tree in the middle of the band, against the tree as mesh
	# alone, and against the mesh fading with no card behind it.
	var band := ImpostorLod.new()
	root.add_child(band)
	band.setup(meshes[0], brick, 60.0)
	guard = 0
	while band.bake.is_empty() and guard < 300:
		await process_frame
		guard += 1
	var bspot := Vector3(2100.0, 0.0, 0.0)
	band.add(Transform3D(Basis(), bspot))
	cam.position = bspot + Vector3(0.0, 3.0, 60.0)
	cam.look_at(bspot + Vector3(0.0, 3.0, 0.0), Vector3.UP)
	band.update(cam.position)
	_check("a tree at the switch range is drawn as both", band.tier_of(0) == 3,
			"tier %d" % band.tier_of(0))
	var both := await _grab()
	twin.position = bspot
	twin.visible = true
	band.visible = false
	var mesh_only := await _grab()
	twin.visible = false
	band.visible = true
	for c in band.get_children():
		if c is MultiMeshInstance3D and (c as MultiMeshInstance3D).material_override is ShaderMaterial \
				and ((c as MultiMeshInstance3D).material_override as ShaderMaterial).shader \
				== load("res://shaders/impostor.gdshader"):
			(c as Node3D).visible = false
	var fading_alone := await _grab()
	var holes_both := 1.0 - _iou(both, mesh_only, env.background_color)
	var holes_alone := 1.0 - _iou(fading_alone, mesh_only, env.background_color)
	print("[impostor]   in the band: %.0f%% off the mesh as both, %.0f%% fading with no card" % [
		holes_both * 100.0, holes_alone * 100.0])
	_check("  and has no holes", holes_both < holes_alone * 0.5 and holes_alone > 0.1,
			"%.2f vs %.2f" % [holes_both, holes_alone])
	get_root().get_texture().get_image().save_png("res://shots/impostor_band.png")

	# Small items: a brick gun, a hundred of them on the ground.
	print("[impostor] items")
	var gun := BuildRecipe.new()
	gun.name = "probe_gun"
	# From the min corner, as every recipe is. Long parts name their axis.
	gun.add("brick_1x2_z", Vector3i(0, 0, 4), 1)          # grip
	gun.add("plate_1x2_z", Vector3i(0, 2, 0), 3)          # under the barrel
	gun.add("brick_1x6_z", Vector3i(0, 3, 0), 3)          # barrel and body
	gun.add("plate_1x4_z", Vector3i(0, 6, 1), 1)          # top rail
	var gun_mesh := RecipeMesh.build(gun, "probe_gun")
	_check("the gun has a mesh", gun_mesh.get_surface_count() > 0)
	var items := ImpostorItems.new()
	root.add_child(items)
	items.kind("gun", gun_mesh, brick)
	var base := Vector3(3000.0, 0.0, 0.0)
	var handles := []
	for i in 100:
		var ang := float(i) * 2.399
		var r := 2.0 + float(i) * 2.2          # 2 m out to 220 m
		handles.append(items.add("gun", Transform3D(Basis(Vector3.UP, ang),
				base + Vector3(cos(ang) * r, 0.2, sin(ang) * r))))
	guard = 0
	var gk: ImpostorLod = items._kinds["gun"]
	while gk.bake.is_empty() and guard < 300:
		await process_frame
		guard += 1
	_check("the gun baked", not gk.bake.is_empty())
	cam.position = base + Vector3(0.0, 1.7, 0.0)
	cam.look_at(base + Vector3(10.0, 0.0, 10.0), Vector3.UP)
	items.update()
	var n_near := 0
	var n_far := 0
	var n_cull := 0
	var n_band := 0
	for i in 100:
		match items.tier_of(handles[i]):
			1: n_near += 1
			2: n_far += 1
			3: n_band += 1    # in the fade band: drawn as both
			_: n_cull += 1
	print("[impostor]   items: %d near, %d crossing, %d cards, %d culled" % [n_near, n_band, n_far, n_cull])
	_check("items near are meshes, further cards, furthest culled",
			n_near > 0 and n_far > 0 and n_cull > 0)
	_check("  two draw calls' worth of instances", gk.near_count == n_near + n_band
			and gk.far_count == n_far + n_band, "%d/%d near, %d/%d far" % [
			gk.near_count, n_near + n_band, gk.far_count, n_far + n_band])
	var last: int = handles[99]
	items.move(last, Transform3D(Basis(), base + Vector3(3.0, 0.2, 3.0)))
	items.update()
	_check("an item moved close is a mesh", items.tier_of(last) == 1)
	items.remove(last)
	items.update()
	_check("an item removed is gone", items.tier_of(last) == 0 and gk.count() == 99)
	for i in 6:
		await process_frame
	get_root().get_texture().get_image().save_png("res://shots/impostor_items.png")

	# Nothing interpolated. With physics interpolation on (the project has it)
	# a MultiMesh blends each slot from its last transform to its new one,
	# and a repack puts different copies in the same slots: trees slid and
	# flickered whenever the player moved.
	var interpolated := 0
	var mmis := 0
	for set_ in [lod, gk]:
		for c in (set_ as Node).get_children():
			if c is MultiMeshInstance3D:
				mmis += 1
				if (c as Node).is_physics_interpolated():
					interpolated += 1
	print("[impostor]   project physics interpolation %s; %d of %d MultiMeshes interpolated" % [
		ProjectSettings.get_setting("physics/common/physics_interpolation"), interpolated, mmis])
	_check("no MultiMesh of copies is interpolated", mmis > 0 and interpolated == 0)

	# Areas: the field of 240 trees spans several 128 m squares.
	print("[impostor]   %d trees in %d area(s)" % [lod.count(), lod.chunk_count()])
	_check("copies are kept in areas", lod.chunk_count() > 1)

	# A node kind: an assembled thing with its own materials, drawn by its
	# owner up close and by a card past NEAR.
	var model := Node3D.new()
	var body := MeshInstance3D.new()
	var bm := BoxMesh.new()
	bm.size = Vector3(0.12, 0.2, 0.7)
	body.mesh = bm
	var red := StandardMaterial3D.new()
	red.albedo_color = Color(0.8, 0.1, 0.1)
	body.material_override = red
	model.add_child(body)
	var grip := MeshInstance3D.new()
	var gm := BoxMesh.new()
	gm.size = Vector3(0.1, 0.25, 0.1)
	grip.mesh = gm
	grip.position = Vector3(0.0, -0.2, 0.2)
	model.add_child(grip)
	var node_kind := items.kind_from_node("model", model)
	var mh := items.add("model", Transform3D(Basis(), base + Vector3(40.0, 0.3, 40.0)))
	items.update()
	_check("a node kind stays its owner's until its card is baked", items.tier_of(mh) == 1)
	guard = 0
	while node_kind.bake.is_empty() and guard < 300:
		await process_frame
		guard += 1
	items.update()
	items.update()
	_check("then, past NEAR, the card stands in", not node_kind.bake.is_empty()
			and items.tier_of(mh) == 2, "tier %d" % items.tier_of(mh))
	var node_img: Image = (node_kind.bake.albedo as Texture2D).get_image() if not node_kind.bake.is_empty() else null
	var reddish := 0
	if node_img != null:
		for y in range(0, node_img.get_height(), 2):
			for x in range(0, node_img.get_width(), 2):
				var px := node_img.get_pixel(x, y)
				if px.a > 0.5 and px.r > px.g * 2.0:
					reddish += 1
	_check("  baked in its own material's colour", reddish > 0)

	# The cull edge (Docs/Interiors.md 8.2, stage 5): a card thins out over
	# the last CULL_FADE metres before its range, so a copy that is culled has
	# nothing left on screen to vanish. Through a long lens -- at 150 m a gun
	# is a few pixels -- from the side, where there is most of it, and looking
	# at its middle. Measured as how far the picture is from the empty sky,
	# summed, and not as pixels counted: anti-aliasing spreads a dither's holes
	# into their neighbours, and a count of touched pixels then reads three
	# quarters drawn as all of it.
	print("[impostor] the cull edge")
	var edge := items.kind("edge", gun_mesh, brick)
	guard = 0
	while edge.bake.is_empty() and guard < 300:
		await process_frame
		guard += 1
	var espot := Vector3(6000.0, 0.0, 0.0)
	var eh := items.add("edge", Transform3D(Basis(), espot))
	var emid: Vector3 = espot + gun_mesh.get_aabb().get_center()
	var fov0 := cam.fov
	cam.fov = 2.0
	var cull := ImpostorItems.CULL
	var fade := ImpostorItems.CULL_FADE
	var d0 := cull - fade - 5.0
	var seen: Array[float] = []   # how much of it is drawn, as it would measure from d0
	var tiers: Array[int] = []
	var wide := 0                 # pixels across, from d0
	for d in [d0, cull - fade * 0.75, cull - fade * 0.5, cull - fade * 0.25, cull - 0.5, cull + 3.0]:
		# The fade is measured to the copy's origin, as the tiers are.
		var off := Vector3(emid.x - espot.x + d, emid.y - espot.y, emid.z - espot.z)
		cam.position = espot + off.normalized() * d
		cam.look_at(emid, Vector3.UP)
		items.update()
		tiers.append(items.tier_of(eh))
		var img := await _grab()
		var sky: Color = img.get_pixel(img.get_width() - 4, img.get_height() - 4)
		var n := 0.0
		var x_lo := img.get_width()
		var x_hi := -1
		@warning_ignore("integer_division")
		for y in range(img.get_height() / 4, img.get_height() * 3 / 4):
			@warning_ignore("integer_division")
			for x in range(img.get_width() / 4, img.get_width() * 3 / 4):
				var px := img.get_pixel(x, y)
				var off_sky := absf(px.r - sky.r) + absf(px.g - sky.g) + absf(px.b - sky.b)
				n += off_sky
				if off_sky > 0.12:
					x_lo = mini(x_lo, x)
					x_hi = maxi(x_hi, x)
		if seen.is_empty():
			wide = maxi(x_hi - x_lo + 1, 0)
		seen.append(n * (d / d0) * (d / d0))
		if is_equal_approx(d, cull - fade * 0.5):
			img.save_png("res://shots/impostor_cull_fade.png")
	cam.fov = fov0
	print("[impostor]   %d px across from %.0f m; how much of it is drawn, out to past %.0f m: %s; tiers %s" % [
			wide, d0, cull, seen.map(func(v): return int(v)), tiers])
	@warning_ignore("integer_division")
	_check("short of the fade the card is whole, and all of it in the picture",
			tiers[0] == 2 and wide > 60 and wide < get_root().size.x / 2 - 8,
			"tier %d, %d px across" % [tiers[0], wide])
	_check("  it thins all the way through the last %.0f m" % fade,
			seen[1] < seen[0] and seen[2] < seen[1] and seen[3] < seen[2] and seen[4] < seen[3])
	_check("  half way, about half of it is drawn",
			seen[2] > seen[0] * 0.35 and seen[2] < seen[0] * 0.65,
			"%.0f%%" % (100.0 * seen[2] / maxf(seen[0], 1.0)))
	_check("  at its range almost nothing is left to vanish",
			tiers[4] == 2 and seen[4] < seen[0] * 0.08,
			"tier %d, %.1f%%" % [tiers[4], 100.0 * seen[4] / maxf(seen[0], 1.0)])
	_check("  and past it the copy is culled", tiers[5] == 0 and seen[5] < seen[0] * 0.005,
			"tier %d, %.2f%%" % [tiers[5], 100.0 * seen[5] / maxf(seen[0], 1.0)])

	print("[impostor] %d ok, %d FAIL" % [_ok, _fail])
	quit(1 if _fail > 0 else 0)
