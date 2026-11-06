extends Node

## The city's developer overlays and reports: the stats HUD's lines (built a
## part a tick), the AI overlay (F4), the live profiler (F2), the AI tick's
## worst-tick and spike tracking and the report it prints at exit.
##
## A part of the city scene, made by it (CityScene.dev_hud), and moved out of
## city_scene.gd so the game's own code is the game and this debug view is in
## one place. It reads the city through `city` -- typed against the city's
## script, so a name the city no longer has is a parse error here. Called about
## once a frame, never per brick or per building.

const City := preload("res://scripts/city_scene.gd")

var city: City

var _ai_worst_ms := 0.0

var _ai_worst_steps := {}

var _ai_spikes: Array = []

const AI_SPIKE_MS := 8.0

## The HUD's counts, each a walk of something big (every building, every
## room, every island): together 7 ms, six times a second. One of them is
## brought up to date per refresh, in turn, so each is under a second old
## and no refresh walks them all; none while the stats are hidden (F1).
const _HUD_PARTS := ["mem", "rep", "isl", "rooms", "groups"]

var _hud_turn := 0


func _init(c: Node3D) -> void:
	city = c
	name = "DevHud"


## Keep the worst AI tick and its breakdown, and every tick over AI_SPIKE_MS
## with its three biggest steps. Shown on F4, printed at exit.
func ai_track_worst(total_ms: float) -> void:
	var s: Dictionary = city.ai_sched.get_stats()
	for sub in ["perception", "nav", "tactical", "trees", "onnx", "commander"]:
		city._ai_steps["run:" + sub] = float((s[sub] as Dictionary).ms)
	for k in city.ai_services.tick_steps:
		city._ai_steps["svc:" + k] = float(city.ai_services.tick_steps[k])
	if total_ms > _ai_worst_ms:
		_ai_worst_ms = total_ms
		_ai_worst_steps = city._ai_steps.duplicate()
	if total_ms > AI_SPIKE_MS and _ai_spikes.size() < 200:
		_ai_spikes.append([total_ms, Engine.get_physics_frames(), City._ai_top(city._ai_steps, 3)])


func report_ai_profile() -> void:
	if _ai_worst_steps.is_empty():
		return
	print("[ai-prof] worst AI tick %.1f ms: %s" % [_ai_worst_ms, City._ai_top(_ai_worst_steps, 6)])
	if city._promotions > 0:
		var pw: Dictionary = city._promote_worst[2]
		var wb := city.registry.get_building(int(city._promote_worst[1])) if city.registry != null else null
		print("[ai-prof] promotions %d, %.1f ms each; the worst %.1f ms (building %d, %s, %d bricks): %s" % [
				city._promotions, city._promote_ms / city._promotions, float(city._promote_worst[0]),
				int(city._promote_worst[1]),
				"" if wb == null else ("build" if wb.is_build() else "%dx%d, %d courses" % [
					int(wb.recipe.footprint_x), int(wb.recipe.footprint_z), int(wb.recipe.courses)]),
				0 if wb == null else wb.blocks, City._ai_top(pw, 9)])
		if wb != null and wb.is_build():
			print("[ai-prof]   that build: %d frame(s), '%s'" % [maxi(wb.frames.size(), 1), wb.build.name])
		for sl in city._promote_slow.slice(0, 8):
			print("[ai-prof]   slow: %.1f ms, building %d, promotion #%d: %s" % [
					float(sl[0]), int(sl[1]), int(sl[2]), City._ai_top(sl[3], 3)])
	var spikes := _ai_spikes.duplicate()
	spikes.sort_custom(func(a: Array, c: Array) -> bool: return a[0] > c[0])
	print("[ai-prof] %d AI tick(s) over %.0f ms; the worst:" % [_ai_spikes.size(), AI_SPIKE_MS])
	for k in mini(12, spikes.size()):
		print("[ai-prof]   %.1f ms at tick %d: %s" % [spikes[k][0], spikes[k][1], spikes[k][2]])
	if city.ai_services != null:
		print("[ai-prof] tactic decisions %d, worst %d us, %d put off to a later think" % [
				city.ai_services.decisions_made, city.ai_services.decide_worst_usec, city.ai_services.decisions_deferred])
	var navs: Array = city.ai_services.all_navs() if city.ai_services != null else []
	if city.mech_nav != null and not navs.has(city.mech_nav):
		navs.append(city.mech_nav)
	for n in navs:
		var st: Dictionary = (n as AINav).get_stats()
		if not st.has("worst_service_us"):
			continue
		print("[ai-prof] nav span %d: worst service %d us, hier begin %d, enclosed %d, side edges %d, cluster sides %d, column %d, snap %d, expand %d" % [
				(n as AINav).get_span(), int(st.worst_service_us), int(st.worst_hier_begin_us), int(st.get("worst_enclosed_us", 0)),
				int(st.worst_side_edges_us), int(st.worst_cluster_sides_us),
				int(st.worst_column_us), int(st.worst_snap_us), int(st.worst_expand_us)])
		print("[ai-prof]   of which one step: search %d us, flow field %d, warming %d" % [
				int(st.get("worst_search_step_us", 0)), int(st.get("worst_field_step_us", 0)),
				int(st.get("worst_warm_step_us", 0))])


func update_ai_label() -> void:
	var w: Dictionary = city.ai_world.get_stats()
	var s: Dictionary = city.ai_sched.get_stats()
	var lines := [
		"AI (F4)   level %d of %d   budget %.2f ms   sync %.2f ms   run %.2f ms   city normal %.1f ms" % [
			city.ai_sched.get_level(), AIScheduler.LEVEL_MAX, city.ai_sched.get_budget_ms(),
			city._ai_sync_ms, city._ai_run_ms, city.ai_sched.get_baseline_ms()],
		"world     %d chunks  %d proxies  %d danger  %d smoke  %d queries, %.2f us mean" % [
			int(w.indexed_chunks), int(w.proxies), int(w.danger), int(w.smoke),
			int(w.queries), float(w.mean_usec)],
		"queue     %d waiting, %d ran last tick, %.2f ms over" % [
			int(s.queued), int(s.ran), float(s.overrun_ms)],
		"nav       %d columns  %d pending  %d paths  %d failed  %.1f ms searching  worst tick %d us" % [
			int(city.ai_nav.get_stats().columns_cached), int(city.ai_nav.get_stats().pending),
			int(city.ai_nav.get_stats().paths), int(city.ai_nav.get_stats().failed),
			float(city.ai_nav.get_stats().search_ms), city._nav_worst_us],
		"worst     %.1f ms: %s" % [_ai_worst_ms, City._ai_top(_ai_worst_steps, 4)],
	]
	for sub in ["perception", "nav", "tactical", "trees", "onnx", "commander"]:
		var d: Dictionary = s[sub]
		lines.append("  %-11s %5.2f ms  %3d ran  %3d deferred" % [sub, float(d.ms),
				int(d.ran), int(d.deferred)])
	city._ai_label.text = "\n".join(lines)


func spike_parts(phase: String) -> String:
	if phase == "islands":
		var lt: Array = city.islands.last_tick
		if lt.size() < 6:
			return ""
		return "loop %.1f, resolve %s, landings %.1f, reshapes %.1f, mesh %.1f; slowest mesh so far %s" % [
				lt[1], str(lt[2]), lt[3], lt[4], lt[5], str(city.islands.mesh_drain_worst)]
	var out := ""
	for k in City._SPIKE_PARTS.get(phase, []):
		var v := float(city._prof.get(k, 0.0))
		if v >= 0.5:
			out += "%s %.1f  " % [k, v]
	if phase == "damage" and float(city._prof.get("dmg_shell_pieces", 0.0)) >= 0.5:
		out += "(last shell piece made bricks: %s) " % city.shell_brick_split
	if phase == "damage" and city._near_at_tick.size() == 5:
		var dn: Array = city.islands.damage_near_ms
		out += "(near: wake %.1f, walk %.1f, hits %.1f, push %.1f, %d call(s); worst unit so far %s)" % [
				dn[0] - city._near_at_tick[0], dn[1] - city._near_at_tick[1], dn[2] - city._near_at_tick[2],
				dn[3] - city._near_at_tick[3], dn[4] - city._near_at_tick[4], str(city.islands.unit_worst)]
	return out


func _hud_part(key: String) -> Variant:
	match key:
		"mem":
			return city.world.get_memory_report()
		"rep":
			return city.registry.report()
		"isl":
			return city.islands.report()
		"rooms":
			return city.registry.room_report()
		_:
			return _groups_hud_line()


func update_hud() -> void:
	if city.stats_label == null or not city.stats_label.visible:
		return
	# Shown or hidden before the city is built (visibility_changed).
	if city.registry == null or city.islands == null or city.world == null:
		return
	if city._hud_cache.size() < _HUD_PARTS.size():
		for key in _HUD_PARTS:
			city._hud_cache[key] = _hud_part(key)
	else:
		var key: String = _HUD_PARTS[_hud_turn % _HUD_PARTS.size()]
		city._hud_cache[key] = _hud_part(key)
		_hud_turn += 1
	var mem: Dictionary = city._hud_cache.mem
	var rep: Dictionary = city._hud_cache.rep
	var isl: Dictionary = city._hud_cache.isl
	var rooms: Dictionary = city._hud_cache.rooms
	city.stats_label.text = "\n".join([
		"buildings     %d  (%d materialised, %d damaged)" % [
			rep.buildings, rep.materialised, rep.damaged],
		"bricks        %d live · BrickWorld %.1f MB · %d chunks" % [
			rep.live_blocks, float(mem.total_bytes) / 1048576.0, mem.chunks],
		"islands       %d  (%d settled, %d loose, %d blocks)" % [
			isl.islands, isl.settled, isl.disposable, isl.blocks],
		"asleep        %d piece(s), %d blocks, %.1f KB  (%d slept, %d woken)" % [
			isl.dormant, isl.dormant_blocks, float(isl.dormant_bytes) / 1024.0,
			isl.slept, isl.woken],
		"debris        %d bricks discarded unseen · %d impact(s) sheared %d joint(s)" % [
			isl.discarded, isl.impacts, isl.impact_blocks],
		"promotions    %d in %.0f ms (%.1f ms each), %d queued" % [
			city._promotions, city._promote_ms, city._promote_ms / maxf(city._promotions, 1), city._promote_queue.size()],
		"impact damage %d brick(s) sheared by falling debris" % city._impact_damage,
		"fixtures      %d, built with the buildings that hold them" % rep.fixtures,
		"rooms         %d  (%d with a diff, %d piece(s) laid as bricks)" % [
			rooms.rooms, rooms.changed, rooms.laid],
		city._hud_cache.groups,
		caps_hud_line(),
		city._physics_view.hud_line() if city._physics_view != null else "physics view  off (shift+G)",
		_view_hud_line(),
		"",
		("%s  %d/%d%s   %s (SPACE SPACE)" % [city._gun.gun.gun_name, city._gun.ammo, city._gun.mag_size(),
				"  reloading" if city._gun.is_reloading() else "",
				city._mode_word()]) if city._gun_armed and city._gun.gun != null
			else "blast %.1f m (wheel)   %s (SPACE SPACE)" % [
				city._blast_radius, city._mode_word()],
		"1 gun · 2 blast · T next gun · R reload · V on foot · K soldier · U squad · Y enemy mech · F mech order · L flashlight" + (" · H disasters (shift: end)" if city.disasters != null else ""),
		"LMB fire · X big blast · P place a saved build · WASD move · shift fast · G grids (shift: physics) · B bevel · J overlap"
			+ "\nF1 stats · F2 profiler · F3 reset worst · F4 AI · F5 save · F9 load · F10 terrain dev menu · F11 terrain edit · N respawn\n7 structure solid/see-through/hidden · 8 interior pieces · 9 items  (what is hidden is still there)"
			+ ("" if city.respawn_buildings else "\nRESPAWN OFF (N) — buildings keep their bricks once promoted"),
	])


## The debris caps against what holds them (IslandManager.cap_counts).
func caps_hud_line() -> String:
	var c := city.islands.cap_counts()
	return "caps          settled small %d/%d · large %d/%d · total %d/%d · %d falling" % [
		c.small, city.islands.small_live_max, c.large, city.islands.large_live_max,
		c.small + c.large, city.islands.total_live_max, c.falling]


func _view_hud_line() -> String:
	if not DebugView.active():
		return "view          everything shown  (7 structure · 8 interior pieces · 9 items)"
	var s: Array = DebugView.seen
	return "view          %s\n              drawn now: %d structure mesh(es), %d interior box(es) in %d drawing(s), %d item(s) in %d" % [
			DebugView.line(), int(s[0][1]), int(s[1][1]), int(s[1][0]), int(s[2][1]), int(s[2][0])]


func _groups_hud_line() -> String:
	var gr: Dictionary = city.interior_groups.report()
	return "interiors     %d storey group(s) in %d building(s): %d piece box(es), %d item box(es); %d piece(s) of wreckage drawn" % [
			gr.groups, gr.buildings, gr.piece_boxes, gr.item_boxes, gr.piece_drawings]


## What the last second of ticks cost, by phase, worst first.
##
## Drawn from the same `_prof` the scripted passes read, so a number seen here
## and a number in a pass summary mean the same thing.
func update_live_prof(delta: float) -> void:
	if city._live_label == null:
		return
	city._live_frame_ms.append(delta * 1000.0)
	if city._live_frame_ms.size() > City.LIVE_WINDOW:
		city._live_frame_ms.remove_at(0)
	if not city._live_prof or city._live_ring.is_empty():
		return
	var mean := {}
	for entry in city._live_ring:
		for k in (entry as Dictionary):
			mean[k] = float(mean.get(k, 0.0)) + float(entry[k])
	var n := float(city._live_ring.size())
	var phases: Array = []
	for k in mean:
		if k == "script_total":
			continue
		phases.append([float(mean[k]) / n, str(k)])
	phases.sort_custom(func(a, b) -> bool: return float(a[0]) > float(b[0]))

	var frame_mean := 0.0
	var frame_worst := 0.0
	for ms in city._live_frame_ms:
		frame_mean += float(ms)
		frame_worst = maxf(frame_worst, float(ms))
	frame_mean /= maxf(float(city._live_frame_ms.size()), 1.0)

	var lines: Array = []
	lines.append("frame     %6.2f ms mean   %6.2f worst   (%.0f fps)" % [
			frame_mean, frame_worst, 1000.0 / maxf(frame_mean, 0.01)])
	# TIME_PHYSICS_PROCESS includes this script's own tick, so subtracting it
	# leaves the solver. The PHYSICS_3D_* counters are NOT used anywhere here:
	# Jolt does not populate them and they read zero whoever asks.
	var phys := float(Performance.get_monitor(Performance.TIME_PHYSICS_PROCESS)) * 1000.0
	var script_ms := float(mean.get("script_total", 0.0)) / n
	lines.append("physics   %6.2f ms   script %6.2f   solver ~%6.2f" % [
			phys, script_ms, maxf(phys - script_ms, 0.0)])
	lines.append("")
	lines.append("per tick, mean of the last %d:" % city._live_ring.size())
	for i in mini(phases.size(), 8):
		var row: Array = phases[i]
		lines.append("  %-16s %6.2f ms" % [row[1], row[0]])
	if city._live_worst_ms > 0.0:
		lines.append("")
		lines.append("worst tick %.2f ms (F3 resets):" % city._live_worst_ms)
		var worst: Array = []
		for k in city._live_worst:
			if k != "script_total":
				worst.append([float(city._live_worst[k]), str(k)])
		worst.sort_custom(func(a, b) -> bool: return float(a[0]) > float(b[0]))
		for i in mini(worst.size(), 4):
			var row: Array = worst[i]
			if float(row[0]) < 0.01:
				break
			lines.append("  %-16s %6.2f ms" % [row[1], row[0]])
	var isl: Dictionary = city.islands.report()
	lines.append("")
	lines.append("islands %d (%d settled, %d loose) · dormant %d" % [
			isl.islands, isl.settled, isl.islands - int(isl.settled), isl.dormant])
	lines.append("resident buildings %d · interior pieces laid as bricks %d" % [
			city._materialised.size(), int(city.registry.room_report().laid)])
	# The census in one line rather than the full sentence _collision_report
	# writes: this label is 430 pixels wide.
	var boxes := 0
	for bid in city._brick_cols:
		boxes += (city._brick_cols[bid] as BuildingCollision).shape_count()
	lines.append("collision boxes %d standing · %d falling · %d settled" % [
			boxes, int(isl.get("loose_boxes", 0)), int(isl.get("settled_boxes", 0))])
	city._live_label.text = "\n".join(lines)
