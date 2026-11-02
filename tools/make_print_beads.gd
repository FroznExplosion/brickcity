extends SceneTree
## Bakes the printed layer lines as a texture (Docs/PbrWood.md 7): what a
## stretch of printed side looks like up close, layer by layer, generated --
## there is no photo of a 1:43.75 print to download.
##
##   godot --headless --path . --script res://tools/make_print_beads.gd
##
## Writes textures/pbr/print_bead.webp, lossless, imported as a Texture2DArray,
## slices stacked down the image, three a filament -- its side, its top, its
## bottom (SLICES; PLA's today). A slice is 32 beads tall and 64 beads long,
## 32 px a bead, and tiles both ways; a bead is a layer on a side and a line
## on a top or bottom. Its channels are DATA, not colour:
##   R  slope along the bead, dh/du     0.5 + s / (2 * SLOPE_MAX)
##   G  slope across it, dh/dv (v up)   the same
##   B  shade, mean 1                    shade * SHADE_K
##   A  roughness offset, mean 0         0.5 + r
## h, u and v all in beads, so a slope is the surface's own tilt.
## print_surface.gdshaderinc ps_bead_tex reads it back with the same
## constants. Each slice draws from its own seed: a slice can be retuned
## without the others changing.
##
## What a printed side is (Docs/PrintLook.md; a 0.2 mm layer of a 0.45 mm
## line): each layer's outer face is a squashed half-cylinder, so the side is
## a washboard with a narrow V between layers. No two layers alike -- one
## stands a hair prouder, one is a shade off (Z variation, temperature). And
## no layer straight: the line swells and thins as the extruder pushes, and
## the seam between two layers wanders a little.
##
## A top is the last layer seen from above: 0.45 mm lines pressed flat by the
## nozzle, flat across their middle and rounding down into a SHALLOW V beside
## the next (not ironed: the sliced top showed none), with a fine ripple
## across each line where the extruder pulsed. Satin. A bottom is the first
## layer, squashed into the bed flattest of all: hairline seams between
## lines and next to no relief (drawn as on smooth PEI; the shader scales it
## for the other beds).

const LAYERS := 32            # tall, in beads
const LONG := 64              # long, in beads
const PX := 32                # pixels a bead
const SLOPE_MAX := 1.5        # encoded range: steeper groove walls are clipped
const SHADE_K := 0.8

## One slice each, in order. In beads: depth the groove's depth, squash the
## profile (2 a circle, higher flatter-faced), proud each bead's own height,
## swell along a bead, wander the seam's, ripple the extruder's pulse across
## a line, micro a fine grain. Shades and roughness 0..1: groove_shade deep
## in a groove (it sees less sky), bead_shade each bead's own.
const SLICES := [
	{"name": "pla_side", "seed": 20261102, "depth": 0.25, "squash": 2.2, "proud": 0.05,
		"swell": 0.035, "wander": 0.03, "ripple": 0.0, "micro": 0.004,
		"groove_shade": 0.2, "bead_shade": 0.05, "groove_rough": 0.14, "micro_rough": 0.04},
	{"name": "pla_top", "seed": 20261103, "depth": 0.14, "squash": 3.5, "proud": 0.012,
		"swell": 0.02, "wander": 0.025, "ripple": 0.006, "micro": 0.003,
		"groove_shade": 0.22, "bead_shade": 0.025, "groove_rough": 0.12, "micro_rough": 0.03},
	{"name": "pla_bottom", "seed": 20261104, "depth": 0.025, "squash": 7.0, "proud": 0.004,
		"swell": 0.008, "wander": 0.02, "ripple": 0.0, "micro": 0.0015,
		"groove_shade": 0.1, "bead_shade": 0.015, "groove_rough": 0.18, "micro_rough": 0.02},
]

var _rng := RandomNumberGenerator.new()


func _init() -> void:
	var w := LONG * PX
	var h := LAYERS * PX
	var data := PackedByteArray()
	for sl in SLICES:
		data.append_array(_slice(sl, w, h))
	var img := Image.create_from_data(w, h * SLICES.size(), false, Image.FORMAT_RGBA8, data)
	var out := "res://textures/pbr/print_bead.webp"
	var err := img.save_webp(out, false)
	print("print beads: %d slices of %dx%d -> %s (%s)" % [SLICES.size(), w, h, out, error_string(err)])
	quit(0 if err == OK else 1)


func _slice(sl: Dictionary, w: int, h: int) -> PackedByteArray:
	_rng.seed = sl.seed
	var depth: float = sl.depth
	var squash: float = sl.squash
	# Per bead: a constant pride and shade, and along it a swell and a
	# wander (and on a top a ripple), each a sum of sines whole numbers of
	# times round the tile so it tiles.
	var proud := PackedFloat32Array()
	var shade := PackedFloat32Array()
	var swell: Array[PackedFloat32Array] = []
	var wander: Array[PackedFloat32Array] = []
	var ripple: Array[PackedFloat32Array] = []
	for i in LAYERS:
		proud.append(_rng.randf_range(-1.0, 1.0) * sl.proud)
		shade.append(_rng.randf_range(-1.0, 1.0) * sl.bead_shade)
		swell.append(_periodic(w, 2, 14, sl.swell))
		wander.append(_periodic(w, 1, 10, sl.wander))
	if sl.ripple > 0.0:
		# A pulse about every bead and a half along, never quite regular.
		for i in LAYERS:
			ripple.append(_periodic(w, 34, 52, sl.ripple))
	var micro := _value_noise(w, h, 8)

	# Height, beads, and what goes with it.
	var hf := PackedFloat32Array()
	var sh := PackedFloat32Array()
	var ro := PackedFloat32Array()
	hf.resize(w * h)
	sh.resize(w * h)
	ro.resize(w * h)
	for y in h:
		var v := (float(y) + 0.5) / PX   # up, in beads
		var base := int(floor(v))
		for x in w:
			# Which bead this is: the seams under and over it wander.
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
			var p := pow(maxf(1.0 - pow(e, squash), 0.0), 1.0 / squash)   # 1 crest, 0 groove
			var m: float = micro[y * w + x]
			var k := y * w + x
			hf[k] = proud[li] + swell[li][x] + depth * p + sl.micro * m
			if not ripple.is_empty():
				hf[k] += ripple[li][x] * p
			var deep := pow(1.0 - p, 3.0)
			sh[k] = 1.0 - sl.groove_shade * deep + shade[li] + 0.012 * m
			ro[k] = sl.groove_rough * deep * deep + sl.micro_rough * m
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
			# A height field that tiles in v wraps a whole tile of beads, so
			# the difference across the wrap is the same as anywhere.
			var sv := (hf[yn * w + x] - hf[yp * w + x]) * PX * 0.5
			if absf(sv) > SLOPE_MAX or absf(su) > SLOPE_MAX:
				clipped += 1
			data[k * 4 + 0] = _byte(0.5 + su / (2.0 * SLOPE_MAX))
			data[k * 4 + 1] = _byte(0.5 + sv / (2.0 * SLOPE_MAX))
			data[k * 4 + 2] = _byte(sh[k] / sh_mean * SHADE_K)
			data[k * 4 + 3] = _byte(0.5 + ro[k] - ro_mean)
	print("  %s: clipped %.2f %%, shade mean %.3f, rough mean %.3f" % [
			sl.name, 100.0 * clipped / (w * h), sh_mean, ro_mean])
	return data


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
