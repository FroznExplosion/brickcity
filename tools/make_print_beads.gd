extends SceneTree
## Bakes the printed layer lines as a texture (Docs/PbrWood.md 7): what a
## stretch of printed side looks like up close, layer by layer, generated --
## there is no photo of a 1:43.75 print to download.
##
##   godot --headless --path . --script res://tools/make_print_beads.gd
##
## Writes textures/pbr/print_bead.webp, lossless, imported as a Texture2DArray
## (one slice a filament; today PLA's sides only). A slice is 32 layers tall
## and 64 layers' worth long, 32 px a layer, and tiles both ways. Its channels
## are DATA, not colour:
##   R  slope along the layer, dh/du    0.5 + s / (2 * SLOPE_MAX)
##   G  slope across it, dh/dv (v up)   the same
##   B  shade, mean 1                    shade * SHADE_K
##   A  roughness offset, mean 0         0.5 + r
## h, u and v all in layer heights, so a slope is the surface's own tilt.
## print_surface.gdshaderinc ps_bead_tex reads it back with the same
## constants.
##
## What a printed side is (Docs/PrintLook.md; a 0.2 mm layer of a 0.45 mm
## line): each layer's outer face is a squashed half-cylinder, so the side is
## a washboard with a narrow V between layers. No two layers alike -- one
## stands a hair prouder, one is a shade off (Z variation, temperature). And
## no layer straight: the line swells and thins as the extruder pushes, and
## the seam between two layers wanders a little.

const LAYERS := 32            # tall, in layers
const LONG := 64              # long, in layers
const PX := 32                # pixels a layer
const SLOPE_MAX := 1.5        # encoded range: steeper groove walls are clipped
const SHADE_K := 0.8

const DEPTH := 0.25           # groove depth, layers
const SQUASH := 2.2           # bead profile: 2 a circle, higher flatter-faced
const PROUD := 0.05           # per layer: how much prouder or not, layers
const SWELL := 0.035          # along a layer: the line swelling, layers
const WANDER := 0.03          # along a layer: the seam wandering, layers
const MICRO := 0.004          # fine surface grain, layers
const GROOVE_SHADE := 0.2     # darkening deep in a groove (it sees less sky)
const LAYER_SHADE := 0.05     # per layer: a shade off
const GROOVE_ROUGH := 0.14    # a groove is duller than a crest
const MICRO_ROUGH := 0.04

var _rng := RandomNumberGenerator.new()


func _init() -> void:
	_rng.seed = 20261102
	var w := LONG * PX
	var h := LAYERS * PX
	# Per layer: a constant pride and shade, and along it a swell and a
	# wander, each a sum of sines whole numbers of times round the tile so it
	# tiles.
	var proud := PackedFloat32Array()
	var shade := PackedFloat32Array()
	var swell: Array[PackedFloat32Array] = []
	var wander: Array[PackedFloat32Array] = []
	for i in LAYERS:
		proud.append(_rng.randf_range(-1.0, 1.0) * PROUD)
		shade.append(_rng.randf_range(-1.0, 1.0) * LAYER_SHADE)
		swell.append(_periodic(w, 2, 14, SWELL))
		wander.append(_periodic(w, 1, 10, WANDER))
	var micro := _value_noise(w, h, 8)

	# Height, layers, and what goes with it.
	var hf := PackedFloat32Array()
	var sh := PackedFloat32Array()
	var ro := PackedFloat32Array()
	hf.resize(w * h)
	sh.resize(w * h)
	ro.resize(w * h)
	for y in h:
		var v := (float(y) + 0.5) / PX   # up, in layers
		var base := int(floor(v))
		for x in w:
			# Which layer this is: the seams under and over it wander.
			var i := base
			var lo := i + wander[posmod(i, LAYERS)][x]
			if v < lo:
				i -= 1
			else:
				var hi := i + 1 + wander[posmod(i + 1, LAYERS)][x]
				if v >= hi:
					i += 1
			var li := posmod(i, LAYERS)
			var b0 := i + wander[li][x]
			var b1 := i + 1 + wander[posmod(i + 1, LAYERS)][x]
			var s := clampf((v - b0) / maxf(b1 - b0, 1e-3), 0.0, 1.0)
			var e := absf(2.0 * s - 1.0)
			var p := pow(maxf(1.0 - pow(e, SQUASH), 0.0), 1.0 / SQUASH)   # 1 crest, 0 groove
			var m: float = micro[y * w + x]
			var k := y * w + x
			hf[k] = proud[li] + swell[li][x] + DEPTH * p + MICRO * m
			var deep := pow(1.0 - p, 3.0)
			sh[k] = 1.0 - GROOVE_SHADE * deep + shade[li] + 0.012 * m
			ro[k] = GROOVE_ROUGH * deep * deep + MICRO_ROUGH * m
	var sh_mean := _mean(sh)
	var ro_mean := _mean(ro)

	var data := PackedByteArray()
	data.resize(w * h * 4)
	var clipped := 0
	for y in h:
		var yn := posmod(y + 1, h)
		var yp := posmod(y - 1, h)
		for x in w:
			var k := y * w + x
			var su := (hf[y * w + posmod(x + 1, w)] - hf[y * w + posmod(x - 1, w)]) * PX * 0.5
			# A height field that tiles in v wraps a whole tile of layers, so
			# the difference across the wrap is the same as anywhere.
			var sv := (hf[yn * w + x] - hf[yp * w + x]) * PX * 0.5
			if absf(sv) > SLOPE_MAX or absf(su) > SLOPE_MAX:
				clipped += 1
			data[k * 4 + 0] = _byte(0.5 + su / (2.0 * SLOPE_MAX))
			data[k * 4 + 1] = _byte(0.5 + sv / (2.0 * SLOPE_MAX))
			data[k * 4 + 2] = _byte(sh[k] / sh_mean * SHADE_K)
			data[k * 4 + 3] = _byte(0.5 + ro[k] - ro_mean)
	var img := Image.create_from_data(w, h, false, Image.FORMAT_RGBA8, data)
	var out := "res://textures/pbr/print_bead.webp"
	var err := img.save_webp(out, false)
	print("print beads: %dx%d, clipped %.2f %%, shade mean %.3f, rough mean %.3f -> %s (%s)" % [
			w, h, 100.0 * clipped / (w * h), sh_mean, ro_mean, out, error_string(err)])
	quit(0 if err == OK else 1)


## `n` samples of a sum of sines at whole frequencies lo..hi round the tile,
## amplitude falling as 1/f, peak about `amp`.
func _periodic(n: int, lo: int, hi: int, amp: float) -> PackedFloat32Array:
	var out := PackedFloat32Array()
	out.resize(n)
	var f := []
	var total := 0.0
	for k in range(lo, hi + 1):
		var a := 1.0 / k * _rng.randf_range(0.3, 1.0)
		f.append([k, a, _rng.randf() * TAU])
		total += a
	for x in n:
		var s := 0.0
		for c in f:
			s += c[1] * sin(TAU * c[0] * x / n + c[2])
		out[x] = s / total * amp * 2.0
	return out


## Tiling value noise in -1..1, lattice `cell` pixels, smoothstepped.
func _value_noise(w: int, h: int, cell: int) -> PackedFloat32Array:
	var gw := w / cell
	var gh := h / cell
	var g := PackedFloat32Array()
	g.resize(gw * gh)
	for k in g.size():
		g[k] = _rng.randf_range(-1.0, 1.0)
	var out := PackedFloat32Array()
	out.resize(w * h)
	for y in h:
		var fy := float(y) / cell
		var y0 := int(fy) % gh
		var y1 := (y0 + 1) % gh
		var ty := smoothstep(0.0, 1.0, fy - floor(fy))
		for x in w:
			var fx := float(x) / cell
			var x0 := int(fx) % gw
			var x1 := (x0 + 1) % gw
			var tx := smoothstep(0.0, 1.0, fx - floor(fx))
			var a := lerpf(g[y0 * gw + x0], g[y0 * gw + x1], tx)
			var b := lerpf(g[y1 * gw + x0], g[y1 * gw + x1], tx)
			out[y * w + x] = lerpf(a, b, ty)
	return out


func _mean(a: PackedFloat32Array) -> float:
	var s := 0.0
	for v in a:
		s += v
	return s / a.size()


func _byte(v: float) -> int:
	return clampi(int(round(v * 255.0)), 0, 255)
