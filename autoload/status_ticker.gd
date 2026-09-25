# status_ticker.gd — AUTOLOAD (name: StatusTicker)
# The single global loop that ticks every active StatusEffect in the game — the
# ElementalParticales "one ticker, no per-enemy Timers" perf pattern (INTEGRATION §1),
# running OUR status model. Effects route their own DoT through HealthPool (layer
# bypass, matrix, strongest-applier-wins); this node only drives their per-frame tick.
#
# Effects stay DECOUPLED from the ticker: they never reference it. StatusManager
# registers a freshly-applied effect here; freed/expired effects are pruned
# automatically. 500 burning enemies = one loop, not 500 _physics_process callbacks.
#
# TIME SCALE: this loop deliberately hands out RAW delta. Per-entity dilation is
# applied inside StatusEffect.tick() (see EntityTime) because the rate is a property
# of the effect's HOST, not of the ticker — in 4-player co-op one player's stasis
# bubble must not slow another player's burns. Do not scale delta here.
extends Node

var _active: Array[StatusEffect] = []


func register(fx: StatusEffect) -> void:
	if fx != null and not _active.has(fx):
		_active.append(fx)


func _physics_process(delta: float) -> void:
	var i := _active.size() - 1
	while i >= 0:
		var fx := _active[i]
		if not is_instance_valid(fx) or fx.is_expired():
			_active.remove_at(i)
		else:
			fx.tick(delta)
		i -= 1


func active_count() -> int:
	return _active.size()
