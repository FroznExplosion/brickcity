extends SceneTree
## What low air does to a player (Docs/Hulls.md 4.3): a suit timer, then damage.
##
##     godot --headless --path . --script res://tools/suit_air_probe.gd
##
##   breathes   in good air (and at LOW exactly) the suit stays full, no damage
##   timer      under LOW the suit runs down a second a second, no damage while it lasts
##   hurts      empty, it takes HURT_SHARE of health a second, straight to health
##              (a shield on top keeps none of it off), dead in 1 / HURT_SHARE s
##   refills    back in air, no more damage, the suit fills in REFILL_S
##   world      a world's air thins with height to none (PlanetSystem.world_air_at's rule)

const DT := 1.0 / 30.0

var _pass := 0
var _fail := 0


func _ok(what: String, cond: bool, detail := "") -> void:
	if cond:
		_pass += 1
		print("  ok   %s%s" % [what, ("  " + detail) if detail else ""])
	else:
		_fail += 1
		print("  FAIL %s%s" % [what, (" -- " + detail) if detail else ""])


func _pool() -> HealthPool:
	var pool := HealthPool.new()
	var sh := DefenseLayer.new()
	sh.layer_type = &"shield"
	sh.max_value = 50.0
	var hp := DefenseLayer.new()
	hp.layer_type = &"health"
	hp.max_value = 100.0
	pool.layer_configs = [sh, hp]
	root.add_child(pool)
	# _initialize runs before the tree's first frame: no _ready yet.
	pool._rebuild_state()
	return pool


func _run(s: SuitAir, pool: HealthPool, p: float, secs: float) -> void:
	for k in roundi(secs / DT):
		s.breathe(DT, p, pool)


func _initialize() -> void:
	print("suit air probe")
	var s := SuitAir.new()
	var pool := _pool()
	_run(s, pool, 1.0, 10.0)
	_run(s, pool, HullAir.LOW, 10.0)
	_ok("breathes: good air (and LOW exactly) keeps the suit full, no damage",
			s.left == SuitAir.SUIT_S and pool.get_layer_value(1) == 100.0 and not s.draining(),
			"%.1f s left, health %.0f" % [s.left, pool.get_layer_value(1)])
	_run(s, pool, 0.2, 30.0)
	_ok("timer: under LOW the suit runs down a second a second, no damage while it lasts",
			absf(s.left - (SuitAir.SUIT_S - 30.0)) < 0.1 and pool.get_layer_value(1) == 100.0
			and s.draining() and not s.empty(), "%.1f s left" % s.left)
	_run(s, pool, 0.0, SuitAir.SUIT_S - 30.0 + 5.0)
	var hp := pool.get_layer_value(1)
	_ok("hurts: empty, health goes at HURT_SHARE a second past the shield",
			s.empty() and absf(hp - 50.0) < 1.0 and pool.get_layer_value(0) == 50.0,
			"health %.1f after 5 s empty, shield %.0f" % [hp, pool.get_layer_value(0)])
	_run(s, pool, 1.0, SuitAir.REFILL_S * 0.5)
	var half := s.left
	_run(s, pool, 1.0, SuitAir.REFILL_S * 0.5 + 0.1)
	_ok("refills: back in air, no more damage, full again in REFILL_S",
			absf(half - SuitAir.SUIT_S * 0.5) < 0.5 and s.left == SuitAir.SUIT_S
			and absf(pool.get_layer_value(1) - hp) < 0.01,
			"%.1f s at half the refill, health %.1f" % [half, pool.get_layer_value(1)])
	_run(s, pool, 0.0, SuitAir.SUIT_S + 1.0 / SuitAir.HURT_SHARE + 0.5)
	_ok("dead: out of air long enough, the pool dies", pool.is_dead(),
			"health %.1f" % pool.get_layer_value(1))
	s.reset()
	_ok("reset: up again, a full suit", s.left == SuitAir.SUIT_S and not s.draining())
	# The world's air with height: PlanetSystem.world_air_at's rule.
	var lo := clampf((PlanetSystem.AIR_TOP - 0.02) / (PlanetSystem.AIR_TOP - PlanetSystem.AIR_FULL), 0.0, 1.0)
	var mid := clampf((PlanetSystem.AIR_TOP - 0.07) / (PlanetSystem.AIR_TOP - PlanetSystem.AIR_FULL), 0.0, 1.0)
	_ok("world: full air low down, under LOW high up (the suit runs there)",
			lo == 1.0 and mid < HullAir.LOW, "%.2f at 2 %% of the radius up, %.2f at 7 %%" % [lo, mid])
	pool.queue_free()
	print("\n%d passed, %d failed" % [_pass, _fail])
	quit(1 if _fail > 0 else 0)
