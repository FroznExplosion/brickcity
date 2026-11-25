extends RefCounted

## WHERE THE MINE WORLD'S MEMORY GOES (Docs/TerrainRegions.md 2, stage A0).
## A report, not checks: it decides what stage A and B cut first.
##
##     godot --path . res://scenes/terrain_test.tscn -- --gate=mem
##
## Windowed (video memory is only real with a renderer); the gate's own save
## folder, so the player's world is never touched. Run by MineWorld's
## --gate=mem: the spawn settled, then a flight of ~480 m along X and a
## settle, then a few shots so the edit table is not empty; a second 480 m
## for the water's sections (they must level off).
##
## For each part of the world (the scene's children: Streamer = the near
## tiles, Deep = the cave sections, Far = the coarse rings, Trees, Bricks =
## the overlay, Water ...):
##   * GPU mesh bytes: RenderingServer.mesh_get_surface's vertex, attribute
##     and index data of every distinct mesh drawn (a read-back: probe only).
##   * MultiMesh bytes: instances allocated x their floats (studs, tufts,
##     the overlay's boxes, tree parts).
##   * CPU arrays kept by GDScript (a tile's `_data`, `overlay`, `buffer`).
##   * physics shapes (the tiles' boxes), counted; ~bytes estimated.
## Then the C++ stores (packed tiles, edit table, water sections), a sample
## of every kept tile and drawn deep section counted as runs (what stage A's
## store would hold), and Godot's own totals plus the process's private bytes.

const BOX_SHAPE_BYTES := 400   ## a Jolt box + Godot's shape object, estimated

var _world: Node3D
var _seen_meshes := {}


func run(world: Node3D) -> void:
	_world = world
	await _settle(240)
	_report("spawn")
	# What ONE visible ReflectionProbe costs: the renderer makes its whole
	# reflection atlas for the first one (the held-item light box under ground,
	# MineWorld._held_light, is such a probe). It stays made, so the later
	# underground stop shows no jump if this is the cause.
	var v0 := Performance.get_monitor(Performance.RENDER_TEXTURE_MEM_USED)
	var probe := ReflectionProbe.new()
	probe.interior = true
	probe.cull_mask = 0
	probe.update_mode = ReflectionProbe.UPDATE_ONCE
	probe.ambient_mode = ReflectionProbe.AMBIENT_COLOR
	probe.size = Vector3(4, 4, 4)
	world.get_viewport().get_camera_3d().add_child(probe)
	for i in 20:
		await world.get_tree().process_frame
	print("[mem] one visible ReflectionProbe: textures %.1f -> %.1f MB (reflection atlas %s px x %s)" % [v0 / 1e6,
			Performance.get_monitor(Performance.RENDER_TEXTURE_MEM_USED) / 1e6,
			ProjectSettings.get_setting("rendering/reflections/reflection_atlas/reflection_size"),
			ProjectSettings.get_setting("rendering/reflections/reflection_atlas/reflection_count")])
	probe.queue_free()
	await _renderer_own(world)
	world.set_on_foot(false)
	var w: Node3D = world.walker
	w.place(w.global_position + Vector3(0, 40, 0), Vector3(1, -0.35, 0.2).normalized())
	await _settle(60)
	var from := w.global_position
	for i in 600:
		w.global_position = from + Vector3(1.0, 0.0, 0.2) * float(i) * 0.8
		await world.get_tree().process_frame
	await _settle(300)
	# A few cells edited, so the edit table has entries (shots' cost aside).
	var at: Vector3 = w.global_position
	var stud := BrickWorld.get_stud_metres()
	for k in 40:
		var c := Vector3i(floori(at.x / stud) + k * 3, 0, floori(at.z / stud) + 5)
		c.y = BrickTerrain.surface_plate(c.x, c.z) - 1
		BrickTerrain.carve(Vector3(c.x + 0.5, c.y + 0.5, c.z + 0.5) * Vector3(stud, BrickWorld.get_plate_metres(), stud), 0.5 * stud)
	await _settle(120)
	_report("after a 480 m flight")
	_runs_report()
	_textures()
	# Twice as far: the water's sections must level off, not grow with the
	# distance flown (W3, Docs/MineWaterNext.md 6: wet sections far away are
	# let go or parked).
	var from2 := w.global_position
	for i in 600:
		w.global_position = from2 + Vector3(1.0, 0.0, 0.2) * float(i) * 0.8
		await world.get_tree().process_frame
	await _settle(420)
	var f2: Dictionary = BrickFluid.memory_stats()
	print("[mem] after a second 480 m: C++ water %d sections, %.2f MB (%d parked, %.3f MB)" % [f2.sections,
			f2.bytes / 1e6, int(f2.get("parked", 0)), int(f2.get("parked_bytes", 0)) / 1e6])
	# Underground, so the deep tier (cave sections) is drawn and counted.
	var e: Vector3 = w.global_position
	var top := BrickTerrain.surface_plate(floori(e.x / stud), floori(e.z / stud)) * BrickWorld.get_plate_metres()
	w.place(Vector3(e.x, top - 25.0, e.z), Vector3(1, 0, 0.3).normalized())
	await _settle(120)
	for i in 900:
		if i > 60 and world._deep._tasks.is_empty():
			break
		await world.get_tree().process_frame
	_report("25 m underground")
	_runs_report()
	world.get_tree().quit()


## The textures the scene's materials use (mesh surfaces, overrides,
## MultiMeshes, ShaderMaterial uniforms, StandardMaterial3D slots), each once,
## biggest first, sized from its image (mips included). Probe only. What the
## renderer holds beyond them is its own buffers (shadow maps, the screen's
## targets, the sky).
func _textures() -> void:
	var seen := {}
	var mats := {}
	_collect_mats(_world.get_tree().root, mats)
	for m in mats:
		_mat_textures(m, seen)
	for g in RenderingServer.global_shader_parameter_get_list():
		var v = RenderingServer.global_shader_parameter_get(g)
		if v is Texture and not seen.has(v.get_rid()):
			seen[v.get_rid()] = [_tex_bytes(v), "global %s (%s)" % [g, v.get_class()]]
	var keys := seen.keys()
	keys.sort_custom(func(a, b): return seen[a][0] > seen[b][0])
	var total := 0
	for k in keys:
		total += seen[k][0]
	print("[mem] textures the materials use: %d, %.1f MB; the biggest:" % [keys.size(), total / 1e6])
	for k in keys.slice(0, 16):
		print("[mem]   %7.1f MB  %s" % [seen[k][0] / 1e6, seen[k][1]])


func _collect_mats(n: Node, mats: Dictionary) -> void:
	if n is GeometryInstance3D:
		var g := n as GeometryInstance3D
		if g.material_override != null:
			mats[g.material_override] = true
		var mesh: Mesh = null
		if n is MeshInstance3D:
			mesh = (n as MeshInstance3D).mesh
			for i in (n as MeshInstance3D).get_surface_override_material_count():
				var o := (n as MeshInstance3D).get_surface_override_material(i)
				if o != null:
					mats[o] = true
		elif n is MultiMeshInstance3D and (n as MultiMeshInstance3D).multimesh != null:
			mesh = (n as MultiMeshInstance3D).multimesh.mesh
		if mesh != null:
			for i in mesh.get_surface_count():
				var sm := mesh.surface_get_material(i)
				if sm != null:
					mats[sm] = true
	if n is WorldEnvironment and (n as WorldEnvironment).environment != null:
		var env := (n as WorldEnvironment).environment
		if env.sky != null and env.sky.sky_material != null:
			mats[env.sky.sky_material] = true
	for c in n.get_children():
		_collect_mats(c, mats)


func _mat_textures(m: Material, seen: Dictionary) -> void:
	var vals := []
	if m is ShaderMaterial and (m as ShaderMaterial).shader != null:
		for u in (m as ShaderMaterial).shader.get_shader_uniform_list(true):
			vals.append((m as ShaderMaterial).get_shader_parameter(u.name))
	else:
		for p in m.get_property_list():
			if p.type == TYPE_OBJECT:
				vals.append(m.get(p.name))
	if m.next_pass != null:
		_mat_textures(m.next_pass, seen)
	for v in vals:
		if v is Texture and not seen.has(v.get_rid()):
			seen[v.get_rid()] = [_tex_bytes(v), "%s %s" % [v.get_class(), v.resource_path if v.resource_path != "" else v.resource_name]]


func _tex_bytes(t: Texture) -> int:
	if t is Texture2D:
		var img := (t as Texture2D).get_image()
		return img.get_data_size() if img != null else 0
	if t is TextureLayered:
		var tl := t as TextureLayered
		var img := tl.get_layer_data(0)
		return img.get_data_size() * tl.get_layers() if img != null else 0
	if t is Texture3D:
		var n := 0
		for img in (t as Texture3D).get_data():
			n += (img as Image).get_data_size()
		return n
	return 0


func _settle(frames: int) -> void:
	for i in frames:
		await _world.get_tree().process_frame
	var s = _world._streamer
	for i in 600:
		if s == null or s.bare_near_tiles() == 0:
			break
		await _world.get_tree().process_frame


func _report(when: String) -> void:
	_seen_meshes.clear()
	print("[mem] ==== %s ====" % when)
	print("[mem] %-14s %6s %8s %9s %8s %9s %9s %7s" % ["part", "nodes", "meshes", "mesh MB", "mm inst", "mm MB", "cpu MB", "shapes"])
	var tot := {}
	for c in _world.get_children():
		var r := {"nodes": 0, "meshes": 0, "mesh_b": 0, "mm_inst": 0, "mm_b": 0, "cpu_b": 0, "shapes": 0}
		_walk(c, r)
		if r.nodes <= 1 and r.mesh_b == 0 and r.mm_b == 0 and r.cpu_b == 0:
			continue
		print("[mem] %-14s %6d %8d %9.2f %8d %9.2f %9.2f %7d" % [str(c.name).left(14), r.nodes, r.meshes,
				r.mesh_b / 1e6, r.mm_inst, r.mm_b / 1e6, r.cpu_b / 1e6, r.shapes])
		for k in r:
			tot[k] = tot.get(k, 0) + r[k]
	print("[mem] %-14s %6d %8d %9.2f %8d %9.2f %9.2f %7d" % ["TOTAL", tot.nodes, tot.meshes,
			tot.mesh_b / 1e6, tot.mm_inst, tot.mm_b / 1e6, tot.cpu_b / 1e6, tot.shapes])
	print("[mem] shapes ~%.2f MB (at ~%d B a box, estimated)" % [tot.shapes * BOX_SHAPE_BYTES / 1e6, BOX_SHAPE_BYTES])
	var s = _world._streamer
	if s != null:
		print("[mem] streamer: %d tiles resident (near_radius %d, keep_radius %d)" % [s.tile_count(), s.near_radius, s.keep_radius])
	var d = _world._deep
	if d != null:
		print("[mem] deep: %d sections resident (radius %d, up %d, down %d)" % [d._secs.size(), d.radius, d.up, d.down])
	var m: Dictionary = BrickTerrain.memory_stats()
	print("[mem] C++ packed tiles: %d kept, %.2f MB (%d pieces, %d B a piece)" % [m.packs_kept,
			m.packs_bytes / 1e6, m.packs_pieces, m.piece_bytes])
	print("[mem] C++ edit table: %d edits, %.3f MB (tables kept for readers included)" % [m.edits, m.edits_bytes / 1e6])
	var f: Dictionary = BrickFluid.memory_stats()
	print("[mem] C++ water: %d sections, %.2f MB (%d ever written, %d wet; %d evicted so far; %d parked, %.3f MB)" % [f.sections,
			f.bytes / 1e6, f.written, f.wet, int(BrickFluid.stats().get("evicted", 0)), int(f.get("parked", 0)),
			int(f.get("parked_bytes", 0)) / 1e6])
	print("[mem] Godot static %.1f MB; video %.1f MB (textures %.1f, buffers %.1f); objects %d, nodes %d, resources %d" % [
			Performance.get_monitor(Performance.MEMORY_STATIC) / 1e6,
			Performance.get_monitor(Performance.RENDER_VIDEO_MEM_USED) / 1e6,
			Performance.get_monitor(Performance.RENDER_TEXTURE_MEM_USED) / 1e6,
			Performance.get_monitor(Performance.RENDER_BUFFER_MEM_USED) / 1e6,
			Performance.get_monitor(Performance.OBJECT_COUNT),
			Performance.get_monitor(Performance.OBJECT_NODE_COUNT),
			Performance.get_monitor(Performance.OBJECT_RESOURCE_COUNT)])
	var out := []
	OS.execute("powershell", ["-NoProfile", "-Command",
			"$p = Get-Process -Id %d; '{0} {1}' -f $p.PrivateMemorySize64, $p.WorkingSet64" % OS.get_process_id()], out)
	if not out.is_empty():
		var parts: PackedStringArray = str(out[0]).strip_edges().split(" ")
		if parts.size() == 2:
			print("[mem] process: private %.0f MB, working set %.0f MB" % [int(parts[0]) / 1e6, int(parts[1]) / 1e6])


func _walk(n: Node, r: Dictionary) -> void:
	r.nodes += 1
	if n is MeshInstance3D and (n as MeshInstance3D).mesh != null:
		_add_mesh((n as MeshInstance3D).mesh, r)
	elif n is MultiMeshInstance3D and (n as MultiMeshInstance3D).multimesh != null:
		var mm: MultiMesh = (n as MultiMeshInstance3D).multimesh
		var floats := 12 if mm.transform_format == MultiMesh.TRANSFORM_3D else 8
		if mm.use_colors:
			floats += 4
		if mm.use_custom_data:
			floats += 4
		r.mm_inst += mm.instance_count
		r.mm_b += mm.instance_count * floats * 4
		if mm.mesh != null:
			_add_mesh(mm.mesh, r)
	for p in ["_data", "overlay", "buffer"]:
		if p in n:
			r.cpu_b += _bytes(n.get(p))
	if "_body" in n:
		var b = n.get("_body")
		if b is RID and (b as RID).is_valid():
			r.shapes += PhysicsServer3D.body_get_shape_count(b)
	for c in n.get_children():
		_walk(c, r)


func _add_mesh(mesh: Mesh, r: Dictionary) -> void:
	var rid := mesh.get_rid()
	if _seen_meshes.has(rid):
		return
	_seen_meshes[rid] = true
	r.meshes += 1
	for i in mesh.get_surface_count():
		var s: Dictionary = RenderingServer.mesh_get_surface(rid, i)
		for k in ["vertex_data", "attribute_data", "skin_data", "index_data"]:
			if s.has(k):
				r.mesh_b += (s[k] as PackedByteArray).size()


func _bytes(v) -> int:
	if v is Dictionary:
		var n := 0
		for k in v:
			n += _bytes(v[k])
		return n
	if v is Array:
		var n := 0
		for e in v:
			n += _bytes(e)
		return n
	if v is PackedByteArray:
		return v.size()
	if v is PackedInt32Array or v is PackedFloat32Array:
		return v.size() * 4
	if v is PackedInt64Array or v is PackedFloat64Array or v is PackedVector2Array:
		return v.size() * 8
	if v is PackedVector3Array:
		return v.size() * 12
	if v is PackedColorArray or v is PackedVector4Array:
		return v.size() * 16
	return 0


## Stage A's store, estimated from the real cells: every resident tile and
## drawn deep section sampled as a bake samples it, its columns' material
## runs counted. Kept as (top plate u16, material u8) per run, twice (now and
## as generated), plus a u16 run count a column.
func _runs_report() -> void:
	var s = _world._streamer
	var tiles: Array = s.tiles_at()
	var tot := {"ms": 0.0, "bytes": 0, "runs": 0, "columns": 0, "solid": 0, "plates": 0, "n": 0}
	for c in tiles:
		var r: Dictionary = BrickTerrain.sample_stats(c.x, c.y)
		_sum(tot, r)
	_print_runs("surface band", tot)
	var sec := {"ms": 0.0, "bytes": 0, "runs": 0, "columns": 0, "solid": 0, "plates": 0, "n": 0}
	for k in _world._deep._secs.keys():
		var r: Dictionary = BrickTerrain.section_sample_stats(k.x, k.y, k.z)
		if not r.is_empty():
			_sum(sec, r)
	_print_runs("deep sections", sec)


func _sum(tot: Dictionary, r: Dictionary) -> void:
	tot.ms += r.ms
	tot.bytes += r.bytes
	tot.runs += r.runs
	tot.columns += r.columns
	tot.solid += r.solid_cells
	tot.plates += r.plates
	tot.n += 1


func _print_runs(what: String, t: Dictionary) -> void:
	if t.n == 0:
		print("[mem] runs %s: none" % what)
		return
	var store: int = t.runs * 3 * 2 + t.columns * 2
	print("[mem] runs %s: %d sampled, %.1f plates tall, %.2f ms each; a sample %.0f KB (transient); %.1f runs a column -> store %.1f KB each, %.2f MB for all %d; solid %.0f %%" % [
			what, t.n, float(t.plates) / t.n, t.ms / t.n, t.bytes / 1024.0 / t.n, float(t.runs) / t.columns,
			store / 1024.0 / t.n, store / 1e6, t.n, 100.0 * t.solid / maxf(1.0, float(t.columns) * t.plates / t.n)])


## THE RENDERER'S OWN VIDEO MEMORY (Docs/TerrainRegions.md 2.1): what is
## left of the textures once the asset textures are counted, taken apart by
## changing one thing at a time and reading the total (each change put back).
func _renderer_own(world: Node3D) -> void:
	var vp := world.get_viewport()
	var tex_mb := func() -> float:
		return Performance.get_monitor(Performance.RENDER_TEXTURE_MEM_USED) / 1e6
	var base: float = tex_mb.call()
	print("[mem] renderer: textures %.1f MB before the steps" % base)
	var rig = world.get("_rig")
	var env: Environment = rig.env if rig != null else null
	var steps := []
	steps.append(["directional shadow atlas 2048 -> 512", func(): RenderingServer.directional_shadow_atlas_set_size(512, false),
			func(): RenderingServer.directional_shadow_atlas_set_size(2048, false)])
	steps.append(["positional shadow atlas %d -> 0" % vp.positional_shadow_atlas_size,
			func(): vp.set_meta(&"pos", vp.positional_shadow_atlas_size); vp.positional_shadow_atlas_size = 0,
			func(): vp.positional_shadow_atlas_size = int(vp.get_meta(&"pos"))])
	if env != null:
		steps.append(["glow off", func(): vp.set_meta(&"glow", env.glow_enabled); env.glow_enabled = false,
				func(): env.glow_enabled = bool(vp.get_meta(&"glow"))])
		steps.append(["SSAO/SSIL/SSR/SDFGI/fog off", func():
				vp.set_meta(&"fx", [env.ssao_enabled, env.ssil_enabled, env.ssr_enabled, env.sdfgi_enabled, env.volumetric_fog_enabled])
				env.ssao_enabled = false; env.ssil_enabled = false; env.ssr_enabled = false
				env.sdfgi_enabled = false; env.volumetric_fog_enabled = false,
				func():
				var f: Array = vp.get_meta(&"fx")
				env.ssao_enabled = f[0]; env.ssil_enabled = f[1]; env.ssr_enabled = f[2]
				env.sdfgi_enabled = f[3]; env.volumetric_fog_enabled = f[4]])
		if env.sky != null:
			steps.append(["sky radiance %d -> 32" % env.sky.radiance_size, func():
					vp.set_meta(&"rad", env.sky.radiance_size); env.sky.radiance_size = Sky.RADIANCE_SIZE_32,
					func(): env.sky.radiance_size = int(vp.get_meta(&"rad"))])
	steps.append(["render scale %.2f -> 0.25" % vp.scaling_3d_scale, func():
			vp.set_meta(&"scale", vp.scaling_3d_scale); vp.scaling_3d_scale = 0.25,
			func(): vp.scaling_3d_scale = float(vp.get_meta(&"scale"))])
	steps.append(["msaa %d, screen AA %d, TAA %s -> off" % [vp.msaa_3d, vp.screen_space_aa, vp.use_taa], func():
			vp.set_meta(&"aa", [vp.msaa_3d, vp.screen_space_aa, vp.use_taa])
			vp.msaa_3d = Viewport.MSAA_DISABLED; vp.screen_space_aa = Viewport.SCREEN_SPACE_AA_DISABLED; vp.use_taa = false,
			func():
			var a: Array = vp.get_meta(&"aa")
			vp.msaa_3d = a[0]; vp.screen_space_aa = a[1]; vp.use_taa = a[2]])
	for st: Array in steps:
		var before: float = tex_mb.call()
		(st[1] as Callable).call()
		for i in 10:
			await world.get_tree().process_frame
		var after: float = tex_mb.call()
		(st[2] as Callable).call()
		for i in 10:
			await world.get_tree().process_frame
		print("[mem]   %-44s %+8.1f MB" % [st[0], after - before])
	print("[mem] renderer: textures back to %.1f MB" % tex_mb.call())
	# Every SubViewport alive (each holds render buffers of its own while it
	# is in the tree): icons, impostor bakers, previews.
	var vps := world.get_tree().root.find_children("*", "SubViewport", true, false)
	var px := 0
	for v in vps:
		var sv := v as SubViewport
		px += sv.size.x * sv.size.y
	print("[mem] renderer: %d SubViewports alive, %.1f Mpx in all" % [vps.size(), px / 1e6])
	var shown := 0
	for v in vps:
		var sv := v as SubViewport
		if shown < 12:
			print("[mem]   %s %dx%d update %d 3d %s own_world %s" % [sv.get_path(), sv.size.x, sv.size.y,
					sv.render_target_update_mode, not sv.disable_3d, sv.own_world_3d])
			shown += 1
