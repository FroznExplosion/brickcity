class_name BrickMaterials

## Everything about a material beyond how it is drawn: how hard it is to break,
## what it sounds like underfoot and when something hits it, what a hit leaves
## behind and what flies off.
##
## The material list itself and its colours live in the extension (brick_grid.h
## BRICK_MATERIALS, read through BrickWorld.get_material_*), and so does
## TOUGHNESS, because the damage it scales is applied there (apply_hit). What
## is here is presentation, grouped into FAMILIES -- five ways of sounding and
## breaking -- so a new material only has to say which family it is:
##
##   plastic   PLA, ABS, PETG, silk, glow, carbon, wood-fill: a bright tick
##             underfoot, a sharp crack when hit, a hole with a ring of
##             stress-whitened plastic round it, chips of its own colour
##   soft      TPU, nylon: a dull thud, a small dimple rather than a hole
##   wood      a hollow knock, a splintered hole, splinters
##   metal     a ringing clang, a bright dent, sparks
##   stone     a gritty thud, a chipped crater, dust
##
## No audio files and no textures: every sound is synthesised here once and
## every mark drawn here once, the same rule as the rest of the palette.
##
## And the FINISH (set_look): printed on which bed, or injection moulded, for
## every printed part in the world at once (shaders/print_finish.gdshaderinc).

const FAMILY_OF := {
	"PLA": "plastic", "PLA matte": "plastic", "PLA silk": "plastic", "ABS": "plastic",
	"PETG": "plastic", "Glow PLA": "plastic", "Carbon PLA": "plastic", "Wood PLA": "plastic",
	"TPU": "soft", "Nylon": "soft",
	"Wood": "wood", "Metal": "metal", "Stone": "stone",
}

const RATE := 22050

const _GLASS_FOR := {
	"res://shaders/brick.gdshader": "res://shaders/brick_glass.gdshader",
	"res://shaders/printed.gdshader": "res://shaders/printed_glass.gdshader",
}

static var _sounds := {}     ## "family:kind:variant" -> AudioStreamWAV
static var _holes := {}      ## family -> ImageTexture


## "plastic", "soft", "wood", "metal" or "stone". A material nobody has filed
## sounds like plastic, which is what most of the world is made of.
static func family(material: int) -> String:
	return FAMILY_OF.get(BrickWorld.get_material_name(material), "plastic")


## Multiple of PLA's life (the extension's number: it is what apply_hit uses).
static func toughness(material: int) -> float:
	return BrickWorld.get_material_toughness(material)


## Give a brick or stud material its see-through pass: PETG bricks are then
## drawn blended by the second pass and skipped by the first. A material
## without it still draws PETG, solid. Returns `mat`.
static func add_glass(mat: ShaderMaterial) -> ShaderMaterial:
	load_look()
	if mat == null or mat.shader == null or not _GLASS_FOR.has(mat.shader.resource_path):
		return mat
	var glass := ShaderMaterial.new()
	glass.shader = load(_GLASS_FOR[mat.shader.resource_path])
	mat.next_pass = glass
	mat.set_shader_parameter("glass_pass", true)
	return mat


# ---------------------------------------------------------------------------
# Finish
# ---------------------------------------------------------------------------

## How every printed part in the world is finished: printed, with its layer
## lines, or injection moulded -- one glossy skin, as a bought brick is.
enum Finish { PRINTED, MOULDED }
## What a printed part's bottom face was printed on.
enum Bed { GLASS, SMOOTH_PEI, TEXTURED_PEI }

const BED_NAMES := ["glass", "smooth PEI", "textured PEI"]
const LOOK_PATH := "user://print_look.cfg"
const _FINISH_INC := "res://shaders/print_finish.gdshaderinc"

static var finish: int = Finish.PRINTED
static var bed: int = Bed.GLASS
static var _look_loaded := false


## Set the finish and the bed, for every brick, stud and scatter shader at
## once. They are constants in print_finish.gdshaderinc, and this rewrites
## that include in memory: Godot recompiles every shader that includes it,
## whoever made the material. Costs one recompile when it changes and
## nothing a frame. Remembered in `LOOK_PATH` unless `save` is false.
static func set_look(p_finish: int, p_bed: int, save := true) -> void:
	_look_loaded = true
	finish = clampi(p_finish, 0, Finish.size() - 1)
	bed = clampi(p_bed, 0, Bed.size() - 1)
	var inc := load(_FINISH_INC) as ShaderInclude
	if inc != null:
		var code := _with_const(inc.code, "PRINT_FINISH", finish)
		code = _with_const(code, "PRINT_BED", bed)
		if code != inc.code:
			inc.code = code
	if save:
		var cf := ConfigFile.new()
		cf.set_value("print", "finish", finish)
		cf.set_value("print", "bed", bed)
		cf.save(LOOK_PATH)


## The look the player chose last time, once a run. Called wherever a brick
## material is made (add_glass); harmless to call again.
static func load_look() -> void:
	if _look_loaded:
		return
	_look_loaded = true
	var cf := ConfigFile.new()
	if cf.load(LOOK_PATH) == OK:
		set_look(int(cf.get_value("print", "finish", Finish.PRINTED)),
				int(cf.get_value("print", "bed", Bed.GLASS)), false)


## Step through the looks: printed on each bed, then moulded. Returns its name.
static func cycle_look() -> String:
	load_look()
	if finish == Finish.MOULDED:
		set_look(Finish.PRINTED, Bed.GLASS)
	elif bed < Bed.size() - 1:
		set_look(Finish.PRINTED, bed + 1)
	else:
		set_look(Finish.MOULDED, bed)
	return look_name()


static func look_name() -> String:
	if finish == Finish.MOULDED:
		return "injection moulded"
	return "printed, %s bed" % BED_NAMES[bed]


static func _with_const(code: String, name: String, value: int) -> String:
	var re := RegEx.create_from_string("const int %s = -?\\d+;" % name)
	return re.sub(code, "const int %s = %d;" % [name, value])


# ---------------------------------------------------------------------------
# Sound
# ---------------------------------------------------------------------------

## A footstep on this family. `variant` picks one of a few takes so a walk is
## not the same sample on a loop.
static func step_sound(fam: String, variant: int = 0) -> AudioStreamWAV:
	return _sound(fam, "step", variant % 3)


## Something hitting it: a bullet, a thrown brick.
static func hit_sound(fam: String, variant: int = 0) -> AudioStreamWAV:
	return _sound(fam, "hit", variant % 3)


static func _sound(fam: String, kind: String, variant: int) -> AudioStreamWAV:
	var key := "%s:%s:%d" % [fam, kind, variant]
	if not _sounds.has(key):
		_sounds[key] = _synth(fam, kind == "hit", variant)
	return _sounds[key]


## One impact, synthesised: a few decaying partials for the body of the sound
## and a burst of noise for the contact. The families differ in what those
## are -- plastic high and short, wood hollow and mid, metal inharmonic and
## ringing, stone and TPU mostly filtered noise.
static func _synth(fam: String, hit: bool, variant: int) -> AudioStreamWAV:
	var rng := RandomNumberGenerator.new()
	rng.seed = hash("%s%s%d" % [fam, hit, variant])
	var detune := 1.0 + (variant - 1) * 0.06
	var partials: Array = []     # [frequency, amplitude, decay seconds]
	var noise_amp := 0.0
	var noise_decay := 0.02
	var noise_lp := 0.5          # 0..1, lower is darker
	var length := 0.12
	match fam:
		"metal":
			partials = [[480.0, 0.5, 0.22], [1270.0, 0.35, 0.16], [2210.0, 0.25, 0.1], [3400.0, 0.15, 0.07]]
			noise_amp = 0.35
			noise_decay = 0.008
			noise_lp = 0.8
			length = 0.35
		"wood":
			partials = [[380.0, 0.55, 0.05], [610.0, 0.35, 0.035], [1150.0, 0.2, 0.02]]
			noise_amp = 0.4
			noise_decay = 0.012
			noise_lp = 0.45
			length = 0.14
		"stone":
			partials = [[220.0, 0.4, 0.035]]
			noise_amp = 0.8
			noise_decay = 0.03
			noise_lp = 0.3
			length = 0.16
		"soft":
			partials = [[140.0, 0.6, 0.04]]
			noise_amp = 0.5
			noise_decay = 0.025
			noise_lp = 0.12
			length = 0.12
		_:  # plastic
			partials = [[1100.0, 0.45, 0.018], [2300.0, 0.3, 0.012], [3700.0, 0.12, 0.008]]
			noise_amp = 0.45
			noise_decay = 0.006
			noise_lp = 0.7
			length = 0.08
	var gain := 0.5
	if hit:
		# Harder, longer and with more of the crack in it than a step.
		length *= 1.8
		noise_amp *= 1.6
		for p in partials:
			p[2] *= 1.6
		gain = 0.9
	var n := int(length * RATE)
	var data := PackedByteArray()
	data.resize(n * 2)
	var lp := 0.0
	for i in n:
		var t := float(i) / RATE
		var v := 0.0
		for p in partials:
			v += p[1] * sin(TAU * p[0] * detune * t) * exp(-t / p[2])
		lp += noise_lp * (rng.randf_range(-1.0, 1.0) - lp)
		v += noise_amp * lp * exp(-t / noise_decay)
		# Stone is gritty: sparse crackles on top of the thud.
		if fam == "stone" and rng.randf() < 0.004:
			v += rng.randf_range(-0.5, 0.5) * exp(-t / 0.05)
		# A 2 ms fade in, so the start is a hit and not a click.
		v *= clampf(t / 0.002, 0.0, 1.0) * gain
		data.encode_s16(i * 2, int(clampf(v, -1.0, 1.0) * 32767.0))
	var wav := AudioStreamWAV.new()
	wav.format = AudioStreamWAV.FORMAT_16_BITS
	wav.mix_rate = RATE
	wav.stereo = false
	wav.data = data
	return wav


# ---------------------------------------------------------------------------
# Marks
# ---------------------------------------------------------------------------

## The mark a hit leaves, as a decal texture, drawn once per family:
##   plastic  a dark hole in a ring of stress-whitened plastic
##   soft     a small dark dimple -- it gives, it does not shatter
##   wood     a dark hole with splinters torn out along the grain
##   metal    a bright dent with a dark centre and a sooty ring
##   stone    a chipped crater, light where the face spalled off
static func hole_texture(fam: String) -> ImageTexture:
	if not _holes.has(fam):
		_holes[fam] = ImageTexture.create_from_image(_draw_hole(fam))
	return _holes[fam]


static func _draw_hole(fam: String) -> Image:
	var size := 64
	var img := Image.create(size, size, false, Image.FORMAT_RGBA8)
	var rng := RandomNumberGenerator.new()
	rng.seed = hash(fam)
	var noise := FastNoiseLite.new()
	noise.seed = hash(fam) & 0xffff
	noise.frequency = 0.12
	for y in size:
		for x in size:
			var p := Vector2(x + 0.5, y + 0.5) / size - Vector2(0.5, 0.5)
			var r := p.length() * 2.0                  # 0 centre, 1 edge
			var a := atan2(p.y, p.x)
			var jag := noise.get_noise_2d(x, y) * 0.12
			var c := Color(0, 0, 0, 0)
			match fam:
				"metal":
					if r < 0.22 + jag * 0.5:
						c = Color(0.08, 0.08, 0.09, 1.0)
					elif r < 0.5 + jag:
						var k := (r - 0.22) / 0.28
						c = Color(0.85, 0.86, 0.9, 1.0).lerp(Color(0.45, 0.46, 0.5, 1.0), k)
						c = c.lerp(Color(0.95, 0.95, 1.0, 1.0),
								0.4 * maxf(0.0, sin(a * 11.0 + noise.get_noise_1d(a * 40.0) * 3.0)))
					elif r < 0.85 + jag:
						c = Color(0.05, 0.05, 0.05, 0.55 * (1.0 - (r - 0.5) / 0.35))
				"wood":
					# Splinters run along the grain: stretch the hole on x.
					var q := Vector2(p.x * 0.55, p.y) * 2.0
					var rq := q.length()
					var streak := absf(sin(p.y * 70.0 + noise.get_noise_1d(p.y * 90.0) * 4.0))
					if rq < 0.25 + jag:
						c = Color(0.07, 0.05, 0.04, 1.0)
					elif rq < 0.62 + jag * 1.5 and streak > 0.35:
						c = Color(0.82, 0.68, 0.48, 0.9 * (1.0 - (rq - 0.25) / 0.37))
				"stone":
					if r < 0.2 + jag:
						c = Color(0.12, 0.12, 0.12, 1.0)
					elif r < 0.7 + jag * 2.0:
						var pit := rng.randf() < 0.08
						var g := 0.75 + noise.get_noise_2d(x * 3.0, y * 3.0) * 0.2
						c = Color(g, g, g * 0.98, 0.85) if not pit else Color(0.3, 0.3, 0.3, 0.9)
				"soft":
					if r < 0.32 + jag * 0.5:
						var k := r / 0.32
						c = Color(0.05, 0.05, 0.05, 0.85 * (1.0 - k * k))
				_:  # plastic
					if r < 0.2 + jag * 0.6:
						c = Color(0.04, 0.04, 0.04, 1.0)
					elif r < 0.55 + jag:
						# Stress whitening: plastic turns white where it was
						# strained, brightest near the hole, with radial cracks.
						var k := (r - 0.2) / 0.35
						var crack := maxf(0.0, sin(a * 7.0 + noise.get_noise_1d(a * 30.0) * 5.0))
						c = Color(1, 1, 1, (0.75 - 0.6 * k) + 0.25 * crack * (1.0 - k))
			img.set_pixel(x, y, c)
	return img


## What flies off: {colour, count, speed, size, glow, gravity}. `brick` is the
## struck brick's own colour, which plastic chips and stone dust take.
static func debris(fam: String, brick: Color) -> Dictionary:
	match fam:
		"metal":
			return {"colour": Color(1.0, 0.78, 0.35), "count": 18, "speed": 6.0,
					"size": 0.012, "glow": true, "gravity": 9.8, "life": 0.35}
		"wood":
			return {"colour": Color(0.72, 0.56, 0.36), "count": 10, "speed": 3.0,
					"size": 0.03, "glow": false, "gravity": 9.8, "life": 0.8}
		"stone":
			return {"colour": brick.lerp(Color(0.8, 0.8, 0.78), 0.4), "count": 24, "speed": 1.6,
					"size": 0.025, "glow": false, "gravity": 2.5, "life": 1.2}
		"soft":
			return {"colour": brick, "count": 4, "speed": 1.2, "size": 0.02, "glow": false,
					"gravity": 9.8, "life": 0.5}
		_:
			return {"colour": brick, "count": 10, "speed": 3.5, "size": 0.02, "glow": false,
					"gravity": 9.8, "life": 0.7}
