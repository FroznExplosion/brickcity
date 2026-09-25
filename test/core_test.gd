## core_test.gd — headless checks for the shared core modules:
## ComponentCache, EntityTime, Spring/Spring3, and StatusEffect's time-scale seam.
##
## Run:
##   <godot> --headless --path . res://test/core_test.tscn
## Exits non-zero on failure.
##
## This is a SCENE, not a `--script` MainLoop, on purpose: StatusManager references the
## StatusTicker autoload, and autoloads are not registered for a bare script main loop
## ("Identifier not found: StatusTicker"). Same reason `--check-only` cannot be used to
## lint the status/combat tree.
extends Node

const DT := 1.0 / 60.0

## Fixture DoT: a fine tick interval keeps discrete-tick quantization small relative to
## the measurement window (120 * 1/60 accumulates to 1.99999 s, not 2.0, so a coarse
## interval loses a whole tick and turns an exact 0.25 ratio into 4/19).
const TICK_INTERVAL := 0.01
const DMG_PER_TICK := 1.0
## High enough that the fixture never dies mid-measurement and truncates the count.
const MAX_HP := 10000.0

var _fails: int = 0


func _ready() -> void:
	print("=== core modules ===")
	_test_component_cache()
	_test_entity_time()
	_test_spring()
	_test_spring3()
	_test_status_time_scale()
	print("=== %s ===" % ("ALL PASS" if _fails == 0 else "%d FAILURE(S)" % _fails))
	get_tree().quit(1 if _fails > 0 else 0)


func _ok(label: String, cond: bool, detail: String = "") -> void:
	if cond:
		print("  PASS  ", label, ("   " + detail) if detail != "" else "")
	else:
		_fails += 1
		print("  FAIL  ", label, "   ", detail)


# ---------------------------------------------------------------- ComponentCache

func _test_component_cache() -> void:
	print("-- ComponentCache")
	var host := Node.new()
	var mid := Node.new()
	host.add_child(mid)

	# A negative lookup must NOT be cached: components get added after spawn.
	_ok("miss returns null", ComponentCache.find(host, &"HealthPool", &"_t_hp") == null)
	_ok("miss not cached", not host.has_meta("_t_hp"))

	var pool := HealthPool.new()
	pool.name = "HealthPool"
	mid.add_child(pool)
	_ok("finds after late add", ComponentCache.find(host, &"HealthPool", &"_t_hp") == pool)
	_ok("hit is cached", host.has_meta("_t_hp"))
	_ok("second call same instance",
		ComponentCache.find(host, &"HealthPool", &"_t_hp") == pool)

	# A freed component must self-heal, never hand back a dangling reference.
	mid.remove_child(pool)
	pool.free()
	_ok("stale entry re-resolves", ComponentCache.find(host, &"HealthPool", &"_t_hp") == null)

	host.set_meta("_t_hp", mid)
	ComponentCache.invalidate(host, &"_t_hp")
	_ok("invalidate clears meta", not host.has_meta("_t_hp"))
	host.free()


# ------------------------------------------------------------------- EntityTime

func _test_entity_time() -> void:
	print("-- EntityTime")
	var host := Node3D.new()
	add_child(host)

	_ok("no node -> 1.0", is_equal_approx(EntityTime.scale_of(host), 1.0))

	var et := EntityTime.new()
	et.name = EntityTime.NODE_NAME
	host.add_child(et)
	# Only works because ComponentCache caches positives and not the earlier miss.
	_ok("resolves after add", EntityTime.of(host) == et)

	var seen: Array = []
	et.scale_changed.connect(func(s: float) -> void: seen.append(s))

	et.set_source(&"stasis", 0.15)
	_ok("one source", is_equal_approx(et.get_scale(), 0.15), str(et.get_scale()))

	et.set_source(&"hitstop", 0.0)
	_ok("sources multiply to a full stop", et.is_stopped())

	et.clear_source(&"hitstop")
	_ok("returns to the stasis rate", is_equal_approx(et.get_scale(), 0.15), str(et.get_scale()))
	_ok("emitted once per real change", seen.size() == 3, str(seen))

	et.set_source(&"stasis", 0.15)
	_ok("idempotent set is silent", seen.size() == 3, str(seen.size()))

	et.base_scale = 2.0
	_ok("base_scale folds in", is_equal_approx(et.get_scale(), 0.3), str(et.get_scale()))

	EntityTime.world_scale = 0.5
	_ok("world_scale folds in", is_equal_approx(et.get_scale(), 0.15), str(et.get_scale()))
	var bare := Node.new()
	add_child(bare)
	_ok("world_scale applies to un-instrumented entities",
		is_equal_approx(EntityTime.scale_of(bare), 0.5))
	EntityTime.world_scale = 1.0
	bare.free()

	et.clear_all_sources()
	_ok("clear_all -> base only", is_equal_approx(et.get_scale(), 2.0), str(et.get_scale()))
	host.free()


# ----------------------------------------------------------------------- Spring

func _test_spring() -> void:
	print("-- Spring")
	var s := Spring.new(4.0, 1.0, 0.0, 0.0)
	for i in 300:
		s.update(DT, 10.0)
	_ok("converges to target", absf(s.value - 10.0) < 0.01, str(s.value))

	var crit := Spring.new(4.0, 1.0, 0.0, 0.0)
	var peak: float = 0.0
	for i in 300:
		peak = maxf(peak, crit.update(DT, 1.0))
	_ok("z=1 does not overshoot", peak <= 1.0001, str(peak))

	var under := Spring.new(4.0, 0.25, 0.0, 0.0)
	peak = 0.0
	for i in 300:
		peak = maxf(peak, under.update(DT, 1.0))
	_ok("z=0.25 overshoots", peak > 1.05, str(peak))

	# The stability clamp is the entire reason this is allowed to run the camera.
	var hitch := Spring.new(30.0, 0.4, 2.0, 0.0)
	for i in 40:
		hitch.update(0.75, 5.0)          # 750 ms steps, far past the naive stable limit
	_ok("survives repeated 750ms hitches",
		is_finite(hitch.value) and absf(hitch.value) < 100.0, str(hitch.value))

	# Impulse injection — ProceduralCombat §3 hit/parry recoil.
	var imp := Spring.new(6.0, 0.5, 0.0, 0.0)
	imp.add_velocity(20.0)
	_ok("impulse moves the spring", imp.update(DT, 0.0) > 0.1, str(imp.value))
	for i in 600:
		imp.update(DT, 0.0)
	_ok("impulse settles back to rest", absf(imp.value) < 0.01, str(imp.value))

	var kc := Spring.from_kc(100.0, 20.0)
	for i in 400:
		kc.update(DT, 3.0)
	_ok("from_kc converges", absf(kc.value - 3.0) < 0.01, str(kc.value))

	var r := Spring.new(6.0, 1.0, 0.0, 5.0)
	_ok("reset clears motion",
		is_equal_approx(r.value, 5.0) and is_equal_approx(r.velocity, 0.0))


func _test_spring3() -> void:
	print("-- Spring3")
	var target := Vector3(1.0, -2.0, 3.0)
	var s := Spring3.new(5.0, 1.0, 0.0, Vector3.ZERO)
	for i in 400:
		s.update(DT, target)
	_ok("converges to target", s.value.distance_to(target) < 0.01, str(s.value))

	var imp := Spring3.new(6.0, 0.6, 0.0, Vector3.ZERO)
	imp.add_velocity(Vector3(0.0, 0.0, -15.0))
	imp.update(DT, Vector3.ZERO)
	_ok("impulse is directional",
		imp.value.z < -0.05 and is_zero_approx(imp.value.x), str(imp.value))
	for i in 600:
		imp.update(DT, Vector3.ZERO)
	_ok("impulse settles", imp.value.length() < 0.01, str(imp.value.length()))

	# An explicit target velocity must beat the finite-difference estimate. Two steps:
	# the integrator moves `value` from LAST step's velocity, so one step shows nothing.
	var lead := Spring3.new(5.0, 1.0, 1.0, Vector3.ZERO)
	var est := Spring3.new(5.0, 1.0, 1.0, Vector3.ZERO)
	for i in 2:
		lead.update(DT, Vector3.ZERO, Vector3(10.0, 0.0, 0.0))
		est.update(DT, Vector3.ZERO)
	_ok("target_velocity leads the estimate", lead.value.x > est.value.x,
		"%.5f vs %.5f" % [lead.value.x, est.value.x])


# ------------------------------------------------------ StatusEffect x EntityTime

func _test_status_time_scale() -> void:
	print("-- StatusEffect x EntityTime")

	# --- DoT RATE. Long duration so neither effect expires inside the window; an
	# effect that expires stops burning, which would cap the ratio and hide the real
	# rate (a 1 s effect measured over 2 s reads 0.44x, not 0.25x).
	var normal := _make_enemy(-1.0, 1000.0)
	var slowed := _make_enemy(0.25, 1000.0)
	# A runtime error below would otherwise leave the section unrun while the summary
	# still printed ALL PASS. Fail loudly instead.
	if normal.fx == null or slowed.fx == null:
		_ok("enemy fixtures built", false, "construction failed — section skipped")
		return

	for i in 120:                      # ~2 s real
		normal.fx.tick(DT)
		slowed.fx.tick(DT)

	var n_dealt: float = MAX_HP - normal.pool.total_current()
	var s_dealt: float = MAX_HP - slowed.pool.total_current()
	_ok("normal enemy burns at real-time rate", absf(n_dealt - 200.0) <= 2.0,
		"dealt %.1f of an expected ~200" % n_dealt)
	_ok("stasis enemy burns at 1/4 rate",
		absf(s_dealt / n_dealt - 0.25) < 0.01,
		"normal %.0f vs stasis %.0f = %.4f" % [n_dealt, s_dealt, s_dealt / n_dealt])

	# --- DURATION also runs on host time, so a slowed DoT lasts proportionally longer.
	var n_short := _make_enemy(-1.0, 1.0)
	var s_short := _make_enemy(0.25, 1.0)
	for i in 120:
		n_short.fx.tick(DT)
		s_short.fx.tick(DT)
	_ok("normal effect expires on schedule", n_short.fx.is_expired())
	_ok("stasis effect outlives it", not s_short.fx.is_expired())

	# --- A FULL STOP holds both the DoT and the duration clock.
	var frozen := _make_enemy(0.0, 1.0)
	for i in 120:
		frozen.fx.tick(DT)
	_ok("stopped host takes zero DoT",
		is_equal_approx(frozen.pool.total_current(), MAX_HP), str(frozen.pool.total_current()))
	_ok("stopped host's status does not expire", not frozen.fx.is_expired())

	# --- The opt-out escape hatch (the "DoTs keep ticking under the ice" rule).
	var immune := _make_enemy(0.0, 1000.0, true)
	for i in 120:
		immune.fx.tick(DT)
	_ok("ignore_time_scale keeps real-time pace even at a full stop",
		is_equal_approx(MAX_HP - immune.pool.total_current(), n_dealt),
		str(MAX_HP - immune.pool.total_current()))

	for e in [normal, slowed, n_short, s_short, frozen, immune]:
		e.root.free()


## Builds root(Node3D) -> HealthPool + [EntityTime] + StatusManager -> TestDoT,
## parents it into the tree so _ready() runs, then binds the effect.
## `time_scale` < 0 means "no EntityTime node at all".
func _make_enemy(time_scale: float, duration: float, ignore_scale: bool = false) -> Dictionary:
	var layer := DefenseLayer.new()
	layer.layer_type = &"health"
	layer.max_value = MAX_HP

	var host := Node3D.new()

	var pool := HealthPool.new()
	pool.name = "HealthPool"
	pool.layer_configs = [layer]
	host.add_child(pool)

	if time_scale >= 0.0:
		var et := EntityTime.new()
		et.name = EntityTime.NODE_NAME
		host.add_child(et)
		et.set_source(&"stasis", time_scale)

	var mgr := StatusManager.new()
	mgr.name = "StatusManager"
	host.add_child(mgr)

	# ElementDoT in DoT mode: _on_tick -> _deal_dot(damage_per_tick). Its overlay/flash
	# calls are has_method-guarded, so a bare Node3D host is fine.
	var fx := ElementDoT.new()
	fx.status_id = &"test_dot"
	fx.duration = duration
	fx.tick_interval = TICK_INTERVAL
	fx.damage_per_tick = DMG_PER_TICK
	fx.ignore_time_scale = ignore_scale
	mgr.add_child(fx)

	add_child(host)               # _ready() cascade: HealthPool builds its layers
	fx.bind(mgr, pool)            # bypasses StatusManager.apply()/StatusTicker: we tick manually
	return {"root": host, "pool": pool, "mgr": mgr, "fx": fx}
