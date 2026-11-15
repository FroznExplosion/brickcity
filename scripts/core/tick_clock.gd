class_name TickClock
## One clock for a physics tick (2026-11-11 brick-system audit, item 2).
##
## Each queue in the city tick had a budget of its own -- spawns 3 ms, damage
## 6, remesh 8, bands 6, trim 6, the islands' work 4, meshes 3, harvest 3,
## slices 3, ... -- and each may overrun by its first item: about 40 ms a
## tick allowed, against a 16.6 ms frame. With the clock on, a tick has
## TOTAL_MS, and a queue is allowed min(its own cap, what is left of it).
##
##   * CityScene._physics_process calls begin() first thing. A tick nobody
##     began (a planet, a ship, a probe driving IslandManager alone) runs
##     every queue on its own cap, as before.
##   * The islands' tick runs LAST, so island_share_ms of the total is held
##     back from the city's queues -- and the islands then run on their OWN
##     caps, off the clock (enter_islands). Clamped by it, a piece's mesh
##     waited: the worst invisible spell went 10-11 -> 16 ticks and
##     collapse_probe's "no gap" failed 3 runs in 5; off it, 0 in 3
##     (2026-11-15, HandoffPerf 7).
##   * A queue whose backlog is a visible hole -- spawns, hits, bands --
##     still always runs its first unit. Any other queue runs
##     nothing once the clock is out (skip()), and waits for a later tick --
##     at most MAX_SKIPS of them in a row.
##
## `shared` turns it off for A/B runs (`city.tscn -- --clock=0`): every
## queue then has its own budget and its first unit, exactly as before.

## Off: every queue on its own cap, as before the shared clock.
static var shared := true
## The whole tick's allowance for the queues, ms.
static var total_ms := 8.0
## Held back from the city's queues for IslandManager.tick, which runs last
## and is guaranteed this much.
static var island_share_ms := 2.0

static var _frame := -1
static var _start := 0
static var _end := 0


## Start this tick's clock.
static func begin() -> void:
	_frame = Engine.get_physics_frames()
	_start = Time.get_ticks_usec()
	_end = _start + int((total_ms - island_share_ms) * 1000.0)


## The islands' turn: from here every queue is on its own cap again (see the
## top). Their share was held back from the city's queues for them.
static func enter_islands() -> void:
	if not running():
		return
	_end = 1 << 62


## Whether this tick is on the shared clock.
static func running() -> bool:
	return shared and _frame == Engine.get_physics_frames()


## The deadline (Time.get_ticks_usec) for a queue whose own cap is `cap_ms`,
## starting now.
static func until(cap_ms: float) -> int:
	var own := Time.get_ticks_usec() + int(cap_ms * 1000.0)
	return mini(own, _end) if running() else own


## Whether a queue that need not run its first unit should run nothing this
## tick: the clock is running and `deadline` has passed. Asked once, before
## the queue's first unit. Off the clock, false -- the first unit always ran.
## Never MAX_SKIPS ticks in a row for one `queue`: a queue that is always
## behind the others still moves (four ticks is 67 ms).
static func skip(queue: StringName, deadline: int) -> bool:
	if not running() or Time.get_ticks_usec() < deadline:
		_skips[queue] = 0
		return false
	var n := int(_skips.get(queue, 0))
	if n >= MAX_SKIPS:
		_skips[queue] = 0
		return false
	_skips[queue] = n + 1
	skipped += 1
	return true


## How many ticks in a row skip() may say so for one queue.
const MAX_SKIPS := 4
static var _skips := {}
## Queue-ticks skipped since start, for the [prof] line.
static var skipped := 0


## The clock's end (Time.get_ticks_usec), or never when it is not running.
static func end_usec() -> int:
	return _end if running() else 1 << 62


## Milliseconds left on the tick's clock (huge when it is not running).
static func left_ms() -> float:
	if not running():
		return 1.0e9
	return float(_end - Time.get_ticks_usec()) / 1000.0
