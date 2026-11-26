class_name FarmPlant
extends RefCounted
## A plot and the plant on it, as plain data, and the one function that
## brings it up to date (Docs/MineFarming.md 5-7). No nodes: farm_probe runs
## all of it headless.
##
## Plants are NOT ticked. Each plot keeps the world time it was last brought
## up to date (`t`); `settle(plot, now)` works out what grew since then and
## moves it on. The same call serves a plot in view (settled a few times a
## second) and one whose ground was out of reach for an hour (settled once
## when the player comes back), so watching a farm and leaving it give the
## same plant: settle(p, t2) == settle(settle(p, t1), t2), to rounding.
## That holds because growth is plain arithmetic over closed-form daylight
## (`sun_integral`), stage ends are solved for, not stepped to, and every
## random number is drawn from the plot's own seed and the stage it is for.
##
## A PLOT (Dictionary):
##   b        Vector3i  block: (x / 2 studs, top plate of the tilled brick, z / 2)
##   crop     StringName  FarmCrops id, &"" for bare tilled soil
##   stage    int    0 .. stages - 1; the last is ripe
##   p        float  progress through the stage, 0..1
##   t        float  world time it was settled to (seconds, MineWorld's clock)
##   seed     int    the plant's own randomness (new each planting)
##   fert     float  soil fertility 0..100 (the plot's, kept across crops)
##   fam      String the family of the last crop harvested here (rotation)
##   stress   int    what went wrong this growth; sets the stars (quality)
##   wet      bool   water within reach (cached by MineFarming when loaded)
##   wet_until float world time a watering can's water lasts to (0: never
##                   watered); the soil is wet while either holds (`wet_at`)
##   boost_until float world time a grow mix's boost lasts to (x GROW_BOOST)
##   ground   String "farm" on tilled soil, "soil" on plain ground (a sapling)
##   sky      float  0..1, open sky above it (sky light / 15)
##   lamp     float  0..1, other light (lava; lamps later)
##   biome    int    BrickTerrain.biome_at under it
##   planted  float  world time it was planted
##   picks    int    harvests of this planting (a perennial's count)

## A mine world day, seconds (MineWorld DAY_SECONDS; farm_probe checks it).
const DAY := 1200.0
const HOUR := DAY / 24.0
## Growth at night, of a noon's: plants grow slowly in the dark of night
## (and the integral is then strictly increasing, so a stage end is unique).
const NIGHT_SUN := 0.15
## Fertility a day of bare (fallow) tilled soil gains back.
const FALLOW_PER_DAY := 10.0
## A crop of another family than the last one here grows this much faster.
const ROTATION_BONUS := 1.15
const LIKED := 1.25
const DISLIKED := 0.7
## A watering can's water lasts this long on a plot (world seconds).
const CAN_LASTS := DAY
## A grow mix's boost: this much faster while it lasts.
const GROW_BOOST := 1.5
## Under this fertility a stage counts as starved (a stress point).
const POOR_SOIL := 25.0
## A crop counts as wanting water when dry soil drops it under this rate.
const THIRSTY := 0.6

const _SAMPLES := 480
static var _table := PackedFloat64Array()
static var _day_total := 0.0


# ---------------------------------------------------------------------------
# Daylight, closed form

## The sun's growth light at day fraction `u` (0 midnight, 0.5 noon): the mine
## world sky's own curve (MineWorld._day_night: clamp(sin * 2.5 + 0.4, 0, 1)).
static func sun_at(u: float) -> float:
	var h := sin((u - 0.25) * TAU)
	return NIGHT_SUN + (1.0 - NIGHT_SUN) * clampf(h * 2.5 + 0.4, 0.0, 1.0)


static func _build_table() -> void:
	_table.resize(_SAMPLES + 1)
	_table[0] = 0.0
	var dt := DAY / _SAMPLES
	for i in _SAMPLES:
		# Simpson over each sample: exact enough that a day sums the same
		# however it is cut.
		var a := float(i) / _SAMPLES
		var b := float(i + 1) / _SAMPLES
		var m := (a + b) * 0.5
		_table[i + 1] = _table[i] + dt * (sun_at(a) + 4.0 * sun_at(m) + sun_at(b)) / 6.0
	_day_total = _table[_SAMPLES]


## Sun-seconds from world time 0 to `t`: increasing, and linear between table
## samples, so its inverse is exact too.
static func sun_integral(t: float) -> float:
	if _table.is_empty():
		_build_table()
	var days := floorf(t / DAY)
	var f := (t - days * DAY) / DAY * _SAMPLES
	var i := clampi(int(f), 0, _SAMPLES - 1)
	var k := f - i
	return days * _day_total + lerpf(_table[i], _table[i + 1], k)


## Light-seconds a plot gets from t0 to t1: the sun's share by how open its
## sky is, the rest from other light (a cave plot under a lamp).
static func light_between(plot: Dictionary, t0: float, t1: float) -> float:
	var sky := float(plot.sky)
	return sky * (sun_integral(t1) - sun_integral(t0)) + (1.0 - sky) * float(plot.lamp) * (t1 - t0)


## The average light a second, over a whole day: for estimates.
static func mean_light(plot: Dictionary) -> float:
	if _table.is_empty():
		_build_table()
	return float(plot.sky) * _day_total / DAY + (1.0 - float(plot.sky)) * float(plot.lamp)


# ---------------------------------------------------------------------------
# Randomness: a hash, never a sequence (order-free, like the terrain's)

static func mix32(h: int) -> int:
	h &= 0xffffffff
	h ^= h >> 16
	h = (h * 0x7feb352d) & 0xffffffff
	h ^= h >> 15
	h = (h * 0x846ca68b) & 0xffffffff
	h ^= h >> 16
	return h


## 0..1 from the plant's seed and two more numbers.
static func roll(seed: int, a: int, b: int) -> float:
	return float(mix32(seed ^ mix32(a * 73856093 ^ mix32(b * 19349663 + 0x5bd1e995)))) / 4294967296.0


static func seed_for(b: Vector3i, planted: float) -> int:
	return mix32(b.x * 73856093 ^ b.y * 19349663 ^ b.z * 83492791 ^ int(planted * 16.0))


# ---------------------------------------------------------------------------
# Plots

static func new_plot(b: Vector3i, now: float, fert: float, biome: int) -> Dictionary:
	return {"b": b, "crop": &"", "stage": 0, "p": 0.0, "t": now, "seed": 0,
			"fert": clampf(fert, 0.0, 100.0), "fam": "", "stress": 0,
			"wet": false, "sky": 1.0, "lamp": 0.0, "biome": biome, "planted": now, "picks": 0,
			"wet_until": 0.0, "boost_until": 0.0, "ground": "farm"}


static func plant(plot: Dictionary, crop: StringName, now: float) -> void:
	settle(plot, now)
	plot.crop = crop
	plot.stage = 0
	plot.p = 0.0
	plot.t = now
	plot.stress = 0
	plot.planted = now
	plot.picks = 0
	plot.seed = seed_for(plot.b, now)


static func crop_of(plot: Dictionary) -> Dictionary:
	return FarmCrops.get_crop(plot.crop) if plot.crop != &"" else {}


static func is_ripe(plot: Dictionary) -> bool:
	var c := crop_of(plot)
	return not c.is_empty() and int(plot.stage) >= int(c.stages) - 1


static func biome_factor(crop: Dictionary, biome: int) -> float:
	var names: PackedStringArray = BrickTerrain.biome_names()
	if biome < 0 or biome >= names.size():
		return 1.0
	if crop.likes.has(names[biome]):
		return LIKED
	if crop.dislikes.has(names[biome]):
		return DISLIKED
	return 1.0


static func soil_factor(plot: Dictionary, crop: Dictionary) -> float:
	var f := 0.5 + 0.7 * float(plot.fert) / 100.0
	if plot.fam != "" and plot.fam != crop.family:
		f *= ROTATION_BONUS
	return f


## Is the soil wet at world time `t`: water near it, or a can's water not
## run out yet.
static func wet_at(plot: Dictionary, t: float) -> bool:
	return bool(plot.wet) or t < float(plot.get("wet_until", 0.0))


static func water_factor(crop: Dictionary, wet: bool) -> float:
	return 1.0 if wet else float(crop.dry_rate)


## This stage's spread: 0.85 .. 1.15 of the crop's time, the plant's own.
static func jitter(plot: Dictionary) -> float:
	return 0.85 + 0.3 * roll(int(plot.seed), int(plot.stage), int(plot.picks))


## Is a grow mix's boost on at world time `t`?
static func boosted_at(plot: Dictionary, t: float) -> bool:
	return t < float(plot.get("boost_until", 0.0))


## Stages a light-second, with the soil `wet` or not and a grow mix's
## `boost` on or not: everything but the light.
static func rate(plot: Dictionary, crop: Dictionary, wet: bool, boost := false) -> float:
	return soil_factor(plot, crop) * water_factor(crop, wet) * biome_factor(crop, int(plot.biome)) \
			* (GROW_BOOST if boost else 1.0) / (float(crop.stage_hours) * HOUR * jitter(plot))


## Stress points a stage ending now earns (what held it back).
static func stage_stress(plot: Dictionary, crop: Dictionary, wet: bool) -> int:
	var s := 0
	if not wet and float(crop.dry_rate) < THIRSTY:
		s += 1
	if maxf(float(plot.sky), float(plot.lamp)) < float(crop.light):
		s += 1
	if float(plot.fert) < POOR_SOIL:
		s += 1
	if biome_factor(crop, int(plot.biome)) < 1.0:
		s += 1
	return s


## Bring the plot up to world time `now`. True if its stage changed (it looks
## different). Conditions (wet, sky, lamp, fertility) are what they are now:
## the caller settles a plot BEFORE it changes one of them.
static func settle(plot: Dictionary, now: float) -> bool:
	var t0 := float(plot.t)
	if now <= t0:
		return false
	var crop := crop_of(plot)
	if crop.is_empty():
		# Bare tilled soil rests and gets its fertility back.
		plot.fert = minf(100.0, float(plot.fert) + FALLOW_PER_DAY * (now - t0) / DAY)
		plot.t = now
		return false
	var changed := false
	# A can's water running out is a time like a stage's end: the interval is
	# cut there, wet before, as the plot's own water says after.
	# A grow mix's boost running out is one more such time.
	while t0 < now:
		var wu := float(plot.get("wet_until", 0.0))
		var bu := float(plot.get("boost_until", 0.0))
		var t1 := now
		if not bool(plot.wet) and t0 < wu and wu < t1:
			t1 = wu
		if t0 < bu and bu < t1:
			t1 = bu
		if _grow(plot, crop, t0, t1, wet_at(plot, t0), boosted_at(plot, t0)):
			changed = true
		t0 = t1
	plot.t = now
	return changed


## Grow from t0 to t1 with the soil wet or not, boosted or not, all through.
static func _grow(plot: Dictionary, crop: Dictionary, t0: float, t1: float, wet: bool, boost: bool) -> bool:
	var changed := false
	var last := int(crop.stages) - 1
	while int(plot.stage) < last:
		var r := rate(plot, crop, wet, boost)
		var need := (1.0 - float(plot.p)) / maxf(r, 1e-12)
		var have := light_between(plot, t0, t1)
		if have < need or r <= 0.0:
			plot.p = float(plot.p) + have * r
			break
		# The stage ends between t0 and t1: when, exactly (bisection on an
		# increasing function; 50 halvings is under a microsecond of a day).
		var lo := t0
		var hi := t1
		for _i in 50:
			var mid := (lo + hi) * 0.5
			if light_between(plot, t0, mid) < need:
				lo = mid
			else:
				hi = mid
		plot.stress = int(plot.stress) + stage_stress(plot, crop, wet)
		plot.stage = int(plot.stage) + 1
		plot.p = 0.0
		t0 = hi
		changed = true
	if int(plot.stage) >= last:
		plot.p = 0.0
	return changed


## Quality, 1-3 stars, from the stress of this growth.
static func stars(plot: Dictionary) -> int:
	var s := int(plot.stress)
	return 3 if s <= 1 else (2 if s <= 3 else 1)


## Pick a ripe plot: what it gives, and the plot after (bare, or a perennial
## back to its regrow stage). {} if it is not ripe.
static func harvest(plot: Dictionary, now: float) -> Dictionary:
	settle(plot, now)
	if not is_ripe(plot):
		return {}
	var crop := crop_of(plot)
	var st := stars(plot)
	var y: Vector2i = crop.yield
	var n := y.x + int(roll(int(plot.seed), 1000, int(plot.picks)) * (y.y - y.x + 1))
	if st == 3:
		n = ceili(n * 1.5)
	elif st == 1:
		n = maxi(1, floori(n * 0.6))
	var sb: Vector2i = crop.seeds_back
	var seeds := sb.x + int(roll(int(plot.seed), 2000, int(plot.picks)) * (sb.y - sb.x + 1))
	if st == 3 and sb.y > 0:
		seeds += 1
	var out := {"produce": crop.produce, "count": n, "seed": crop.seed, "seeds": seeds, "stars": st,
			"crop": crop.id}
	plot.fert = clampf(float(plot.fert) - float(crop.drain) + float(crop.restores), 0.0, 100.0)
	plot.fam = crop.family
	plot.picks = int(plot.picks) + 1
	if int(crop.regrow_to) >= 0:
		plot.stage = clampi(int(crop.regrow_to), 0, int(crop.stages) - 1)
		plot.p = 0.0
		plot.stress = 0
	else:
		plot.crop = &""
		plot.stage = 0
		plot.p = 0.0
		plot.stress = 0
	plot.t = now
	return out


## Seconds of world time until ripe, roughly (the day's mean light): for the
## HUD and the guide. INF if it cannot grow (no light), 0 if ripe.
static func eta(plot: Dictionary, now: float) -> float:
	var crop := crop_of(plot)
	if crop.is_empty() or is_ripe(plot):
		return 0.0
	var light := mean_light(plot)
	if light <= 0.0:
		return INF
	var wet := wet_at(plot, now)
	var boost := boosted_at(plot, now)
	var copy := plot.duplicate()
	var secs := 0.0
	while int(copy.stage) < int(crop.stages) - 1:
		var r := rate(copy, crop, wet, boost)
		if r <= 0.0:
			return INF
		secs += (1.0 - float(copy.p)) / r / light
		copy.stage = int(copy.stage) + 1
		copy.p = 0.0
	return secs


## What holds the plant back, worst first, as short words for the HUD.
static func limits(plot: Dictionary, now: float) -> PackedStringArray:
	var out := PackedStringArray()
	var crop := crop_of(plot)
	if crop.is_empty():
		return out
	if maxf(float(plot.sky), float(plot.lamp)) < float(crop.light):
		out.append("too dark" if maxf(float(plot.sky), float(plot.lamp)) < 0.15 else "needs more light")
	if not wet_at(plot, now):
		out.append("dry (%d%% speed)" % roundi(float(crop.dry_rate) * 100.0))
	if float(plot.fert) < POOR_SOIL:
		out.append("poor soil")
	if biome_factor(crop, int(plot.biome)) < 1.0:
		out.append("dislikes this biome")
	return out


## World seconds as words: "1 day 4 h", "3 h", "20 min" (in-game time).
static func span_words(secs: float) -> String:
	if secs == INF:
		return "never (no light)"
	var hours := secs / HOUR
	if hours >= 24.0:
		var d := floori(hours / 24.0)
		var h := roundi(hours - d * 24.0)
		return "%d day%s %d h" % [d, "" if d == 1 else "s", h] if h > 0 else "%d day%s" % [d, "" if d == 1 else "s"]
	if hours >= 1.0:
		return "%d h" % roundi(hours)
	return "%d min" % maxi(1, roundi(hours * 60.0))


# ---------------------------------------------------------------------------
# Saving: a plot as an array (FarmStore packs a region of them)

static func to_row(plot: Dictionary) -> Array:
	var b: Vector3i = plot.b
	return [b.x, b.y, b.z, String(plot.crop), int(plot.stage), float(plot.p), float(plot.t), int(plot.seed),
			float(plot.fert), str(plot.fam), int(plot.stress), bool(plot.wet), float(plot.sky),
			float(plot.lamp), int(plot.biome), float(plot.planted), int(plot.picks),
			float(plot.get("wet_until", 0.0)), float(plot.get("boost_until", 0.0)), str(plot.get("ground", "farm"))]


static func from_row(r: Array) -> Dictionary:
	if r.size() < 17:
		return {}
	return {"b": Vector3i(int(r[0]), int(r[1]), int(r[2])), "crop": StringName(str(r[3])),
			"stage": int(r[4]), "p": float(r[5]), "t": float(r[6]), "seed": int(r[7]),
			"fert": float(r[8]), "fam": str(r[9]), "stress": int(r[10]), "wet": bool(r[11]),
			"sky": float(r[12]), "lamp": float(r[13]), "biome": int(r[14]), "planted": float(r[15]),
			"picks": int(r[16]), "wet_until": float(r[17]) if r.size() > 17 else 0.0,
			"boost_until": float(r[18]) if r.size() > 18 else 0.0,
			"ground": str(r[19]) if r.size() > 19 else "farm"}
