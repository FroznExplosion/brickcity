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
