class_name DisasterSounds
extends RefCounted

## Disaster sounds, synthesised once and cached -- the project ships no audio
## files (BrickMaterials synthesises its hits the same way).

const RATE := 22050

static var _cache := {}


## A meteor strike: a low thump under a burst of filtered noise.
static func boom() -> AudioStreamWAV:
	if not _cache.has("boom"):
		_cache["boom"] = _synth_boom()
	return _cache["boom"]


## A distant, rolling rumble. Loops.
static func rumble() -> AudioStreamWAV:
	if not _cache.has("rumble"):
		_cache["rumble"] = _synth_rumble()
	return _cache["rumble"]


## Thunder: a bright crack, then a long rumble that rolls in and out.
static func thunder() -> AudioStreamWAV:
	if not _cache.has("thunder"):
		_cache["thunder"] = _synth_thunder()
	return _cache["thunder"]


## Wind, gusting. Loops.
static func wind() -> AudioStreamWAV:
	if not _cache.has("wind"):
		_cache["wind"] = _synth_loop(0x3D, 0.06, 0.1, 6.0, 0.25)
	return _cache["wind"]


## Rain: a soft, even hiss. Loops.
static func rain() -> AudioStreamWAV:
	if not _cache.has("rain"):
		_cache["rain"] = _synth_loop(0x7A1, 0.6, 0.5, 0.9, 0.5)
	return _cache["rain"]


## Fire: a low roar with crackles. Loops.
static func fire() -> AudioStreamWAV:
	if not _cache.has("fire"):
		_cache["fire"] = _synth_fire()
	return _cache["fire"]


static func _synth_thunder() -> AudioStreamWAV:
	var rng := RandomNumberGenerator.new()
	rng.seed = 0x7B0
	var n := int(RATE * 4.0)
	var out := PackedFloat32Array()
	out.resize(n)
	var lp := 0.0
	var lp2 := 0.0
	var bright := 0.0
	for i in n:
		var t := float(i) / RATE
		var white := rng.randf_range(-1.0, 1.0)
		# The crack: nearly white, over in a fifth of a second.
		bright += (white - bright) * 0.6
		var crack := bright * exp(-t * 18.0) * 0.8
		# The roll: dark noise under a slow, lumpy envelope.
		lp += (white - lp) * 0.03
		lp2 += (lp - lp2) * 0.08
		var env := minf(t / 0.15, 1.0) * exp(-t * 0.9) * (0.75 + 0.25 * sin(TAU * 1.3 * t + 0.7))
		out[i] = clampf(crack + lp2 * 9.0 * env, -1.0, 1.0)
	return _wav(out, false)


static func _synth_fire() -> AudioStreamWAV:
	var rng := RandomNumberGenerator.new()
	rng.seed = 0xF1E
	var n := RATE * 3
	var out := PackedFloat32Array()
	out.resize(n)
	var lp := 0.0
	var crackle := 0.0
	for i in n:
		lp += (rng.randf_range(-1.0, 1.0) - lp) * 0.05
		if rng.randf() < 0.0008:
			crackle = rng.randf_range(0.4, 0.9) * (1.0 if rng.randf() < 0.5 else -1.0)
		crackle *= 0.93
		out[i] = clampf(lp * 5.0 + crackle * rng.randf(), -1.0, 1.0)
	return _wav(_loop_ends(out), true)


## A loop of filtered noise. `a` and `b` are the two low-pass steps (lower is
## darker), `gain` makes up what the filters took, `swell` is how much a slow
## 0.5 Hz swell moves the level.
static func _synth_loop(seed_value: int, a: float, b: float, gain: float, swell: float) -> AudioStreamWAV:
	var rng := RandomNumberGenerator.new()
	rng.seed = seed_value
	var n := RATE * 4
	var out := PackedFloat32Array()
	out.resize(n)
	var lp := 0.0
	var lp2 := 0.0
	for i in n:
		var t := float(i) / RATE
		lp += (rng.randf_range(-1.0, 1.0) - lp) * a
		lp2 += (lp - lp2) * b
		out[i] = clampf(lp2 * gain * (1.0 - swell + swell * sin(TAU * 0.5 * t)), -1.0, 1.0)
	return _wav(_loop_ends(out), true)


## Cross-fade the tail into the head so a loop does not click at its seam.
static func _loop_ends(out: PackedFloat32Array) -> PackedFloat32Array:
	var n := out.size()
	var fade := RATE / 10
	for i in fade:
		var k := float(i) / fade
		out[i] = out[i] * k + out[n - fade + i] * (1.0 - k)
	return out.slice(0, n - fade)


static func _synth_boom() -> AudioStreamWAV:
	var rng := RandomNumberGenerator.new()
	rng.seed = 0xB00
	var n := int(RATE * 1.8)
	var out := PackedFloat32Array()
	out.resize(n)
	var lp := 0.0
	var lp2 := 0.0
	for i in n:
		var t := float(i) / RATE
		# The thump: a falling sine, 70 Hz to 35.
		var f := lerpf(70.0, 35.0, minf(t / 0.6, 1.0))
		var thump := sin(TAU * f * t) * exp(-t * 3.0) * 0.9
		# The body: noise, darkened twice, decaying slower than it attacks.
		lp += (rng.randf_range(-1.0, 1.0) - lp) * 0.08
		lp2 += (lp - lp2) * 0.15
		var body := lp2 * 4.0 * exp(-t * 2.2) * minf(t / 0.01, 1.0)
		out[i] = clampf(thump + body, -1.0, 1.0)
	return _wav(out, false)


static func _synth_rumble() -> AudioStreamWAV:
	var rng := RandomNumberGenerator.new()
	rng.seed = 0x20B
	var n := RATE * 4
	var out := PackedFloat32Array()
	out.resize(n)
	var lp := 0.0
	var lp2 := 0.0
	for i in n:
		var t := float(i) / RATE
		lp += (rng.randf_range(-1.0, 1.0) - lp) * 0.02
		lp2 += (lp - lp2) * 0.05
		# A slow swell so the loop breathes; whole cycles over 4 s so it joins.
		var swell := 0.7 + 0.3 * sin(TAU * 0.5 * t)
		out[i] = clampf(lp2 * 14.0 * swell, -1.0, 1.0)
	# Cross-fade the ends so the loop point does not click.
	var fade := RATE / 10
	for i in fade:
		var a := float(i) / fade
		out[i] = out[i] * a + out[n - fade + i] * (1.0 - a)
	return _wav(out.slice(0, n - fade), true)


static func _wav(samples: PackedFloat32Array, loop: bool) -> AudioStreamWAV:
	var bytes := PackedByteArray()
	bytes.resize(samples.size() * 2)
	for i in samples.size():
		bytes.encode_s16(i * 2, int(samples[i] * 32000.0))
	var w := AudioStreamWAV.new()
	w.format = AudioStreamWAV.FORMAT_16_BITS
	w.mix_rate = RATE
	w.stereo = false
	w.data = bytes
	if loop:
		w.loop_mode = AudioStreamWAV.LOOP_FORWARD
		w.loop_end = samples.size()
	return w
