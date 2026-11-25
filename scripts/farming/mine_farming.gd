class_name MineFarming
extends Node3D
## Farming in the mine world (Docs/MineFarming.md): tilled soil, crops that
## grow on the world clock, harvests, and the player trampling a field.
##
##   hoe, RMB on the top of soil     that 2x2 brick (its course) becomes ONE
##                                   tilled brick: smooth, furrowed (the
##                                   terrain's farmland material), a plot
##   seed, RMB on tilled soil        plants it
##   RMB on a ripe crop              harvests it (replants from your seeds)
##   LMB on a crop                   harvests it if ripe, else pulls it (seed back)
##   LMB on bare tilled soil         breaks it like any block (gives soil)
##   landing from 3 bricks or more   tramples the plot under you: the crop is
##                                   lost (its seed pops out), the soil is dirt
##
## No more chores (stage 3, `area`): hold RMB with a hoe, seeds, a scythe or
## a watering can and let go somewhere else -- the whole rectangle between is
## tilled, planted, harvested (and replanted) or watered, up to AREA_MAX
## plots a side. A scythe's click takes the ripe crops 3 x 3 round it. What a
## harvest gives goes into the inventory, then the nearest chest within
## CHEST_REACH, then the ground.
##
## Growth is FarmPlant.settle on the world clock (host.world_time): a plot in
## reach is settled a few dozen a frame, and its water and light looked at
## again one or two a frame; a plot out of reach is not touched at all and
## catches up when the player comes back. All of it saved by region
## (FarmStore) with the world.
##
## A child of the mine world with no transform of its own: positions are the
## terrain frame (MineChests' rule).

## A fall this far onto a plot tramples it: 3 bricks (1.26 m), a little under
## so a fall of exactly 3 bricks counts; a jump on the flat never does (the
## pawn takes the jump's own rise off the fall).
const TRAMPLE_FALL := 1.2
## Plots within this of the eye are settled and drawn; within COND_M their
## water and light are looked at again.
const NEAR_M := 96.0
const COND_M := 64.0
const SETTLE_PER_FRAME := 48
## One a frame: a dry plot's water look reads up to 200 water cells (~0.3 ms).
const COND_PER_FRAME := 1
## Water this many studs round a plot (on its course or the one above) wets it.
const WET_STUDS := 4
## The most plots a side an area action reaches (MineBuilder's RMB drag).
const AREA_MAX := 9
## A harvest that does not fit the inventory goes into a chest this near.
const CHEST_REACH := 8.0
## A watering can's water: plots it waters before it is filled again.
const CAN_WATER := 16
## Soil a hoe tills, and the fertility each starts with.
const SOIL_FERTILITY := {"grass": 60.0, "dirt": 55.0, "podzol": 80.0, "dry grass": 40.0,
		"lush grass": 75.0, "cold grass": 50.0, "dark grass": 70.0}

var host: Node = null
var store := FarmStore.new()
var draw: FarmDraw
## What the last action did, for the gate and the log.
var log_lines: Array[String] = []
var tilled := 0
var planted := 0
var harvested := 0
var trampled := 0

var _stud := 0.35
var _plate := 0.14
var _soil := {}             ## material index -> fertility
var _near: Array = []       ## blocks of plots in reach (rebuilt each second)
var _near_in := 0.0
var _settle_i := 0
var _cond_i := 0
var _draw_dirty := true
var _drawn_eye := Vector3.INF
## The slowest refresh (water, light, soil look) so far, microseconds.
var worst_refresh_us := 0


func setup(p_host: Node) -> void:
	host = p_host
	_stud = BrickWorld.get_stud_metres()
	_plate = BrickWorld.get_plate_metres()
	var names := Array(BrickTerrain.material_names())
	for n in SOIL_FERTILITY:
		var i := names.find(n)
		if i > 0:
			_soil[i] = SOIL_FERTILITY[n]
	draw = FarmDraw.new()
	draw.name = "Crops"
	add_child(draw)
	draw.setup()
	FarmCrops.load_all()


func now() -> float:
	return float(host.world_time)


# ---------------------------------------------------------------------------
# Loading and saving (MineWorld.generate / save_edits)

func load_world(regions_dir: String) -> int:
	var n := store.load_dir(regions_dir)
	_near.clear()
	_near_in = 0.0
	_draw_dirty = true
	return n


func reset() -> void:
	store.clear()
	_near.clear()
	_draw_dirty = true


# ---------------------------------------------------------------------------
# Every frame

func step(delta: float, eye: Vector3) -> void:
	var t := now()
	_near_in -= delta
	if _near_in <= 0.0:
		_near_in = 1.0
		_find_near(eye)
	if not _near.is_empty():
		for _i in mini(SETTLE_PER_FRAME, _near.size()):
			_settle_i = (_settle_i + 1) % _near.size()
			var plot := store.get_plot(_near[_settle_i])
			if not plot.is_empty() and FarmPlant.settle(plot, t):
				_draw_dirty = true
		for _i in mini(COND_PER_FRAME, _near.size()):
			_cond_i = (_cond_i + 1) % _near.size()
			var b: Vector3i = _near[_cond_i]
			var at := _top_middle(b)
			if Vector2(at.x - eye.x, at.z - eye.z).length() <= COND_M:
				var t0 := Time.get_ticks_usec()
				refresh(b)
				worst_refresh_us = maxi(worst_refresh_us, Time.get_ticks_usec() - t0)
	if _draw_dirty or _drawn_eye == Vector3.INF or Vector2(eye.x - _drawn_eye.x, eye.z - _drawn_eye.z).length() > 8.0:
		_draw_dirty = false
		_drawn_eye = eye
		draw.rebuild(store.plots, eye)


func _find_near(eye: Vector3) -> void:
	_near.clear()
	var r2 := NEAR_M * NEAR_M
	for b in store.plots:
		var at := _top_middle(b)
		if Vector2(at.x - eye.x, at.z - eye.z).length_squared() <= r2:
			_near.append(b)
	if _settle_i >= _near.size():
		_settle_i = 0
	if _cond_i >= _near.size():
		_cond_i = 0


## Settle every plot in reach now (a gate, or before reading them all).
func settle_all() -> void:
	var t := now()
	for b in store.plots:
		if FarmPlant.settle(store.plots[b], t):
			_draw_dirty = true


# ---------------------------------------------------------------------------
# Where things are

## The middle of a plot's top, terrain frame.
func _top_middle(b: Vector3i) -> Vector3:
	return Vector3((b.x * 2 + 1) * _stud, (b.y + 1) * _plate, (b.z * 2 + 1) * _stud)


static func _course_lo(b: Vector3i) -> Vector3i:
	return Vector3i(b.x * 2, b.y - 2, b.z * 2)


static func _course_hi(b: Vector3i) -> Vector3i:
	return Vector3i(b.x * 2 + 1, b.y, b.z * 2 + 1)


static func is_farmland(m: int) -> bool:
	return m == BrickTerrain.MAT_FARMLAND or m == BrickTerrain.MAT_WET_FARMLAND


## The plot holding plate cell `cell` (its tilled brick's), or {}.
func plot_at_cell(cell: Vector3i) -> Dictionary:
	var bx := floori(float(cell.x) / 2.0)
	var bz := floori(float(cell.z) / 2.0)
	for dy in 3:
		var p := store.get_plot(Vector3i(bx, cell.y + dy, bz))
		if not p.is_empty():
			return p
	return {}


## The plot a ray's answer (MineBuilder.target) is on, or {}.
func plot_at_target(target: Dictionary) -> Dictionary:
	if target.is_empty() or not target.has("cell"):
		return {}
	return plot_at_cell(target.cell)


# ---------------------------------------------------------------------------
# The hoe

## The 2x2 block of soil looked at becomes one tilled brick. Its course: the
## 3-plate course whose top is at or under the ground's top -- a top part way
## up a course is dug down to the course under it. False if it cannot be
## tilled here (not the top of soil, not flat, something on it).
func till(target: Dictionary) -> bool:
	if target.is_empty() or not target.has("cell"):
		return false
	var n: Vector3i = target.get("normal", Vector3i.ZERO)
	if n != Vector3i.UP:
		log_lines.append("till refused: not a top face")
		return false
	var cell: Vector3i = target.cell
	if not plot_at_cell(cell).is_empty():
		return false
	var ytop := cell.y
	var c := floori(float(ytop + 1) / 3.0) - 1   # the course whose top is at or under ytop
	var top := c * 3 + 2
	var bx := floori(float(cell.x) / 2.0)
	var bz := floori(float(cell.z) / 2.0)
	var fert := 0.0
	var count := 0
	for x in [bx * 2, bx * 2 + 1]:
		for z in [bz * 2, bz * 2 + 1]:
			# Room over it, ground all the way through its course.
			for yy in range(ytop + 1, ytop + 4):
				if BrickTerrain.solid_at(x, yy, z) != 0:
					log_lines.append("till refused: something on it")
					return false
			var m := BrickTerrain.solid_at(x, top, z)
			for yy in range(top + 1, ytop + 1):
				m = BrickTerrain.solid_at(x, yy, z) if BrickTerrain.solid_at(x, yy, z) != 0 else m
			if not _soil.has(m):
				log_lines.append("till refused: not soil (%d)" % m)
				return false
			for yy in range(c * 3, top + 1):
				if BrickTerrain.solid_at(x, yy, z) == 0 and yy < top:
					log_lines.append("till refused: not flat")
					return false
			fert += float(_soil[m])
			count += 1
	var lo := Vector3i(bx * 2, c * 3, bz * 2)
	var hi := Vector3i(bx * 2 + 1, top, bz * 2 + 1)
	if host.chests.overlaps(AABB(Vector3(lo.x * _stud, lo.y * _plate, lo.z * _stud),
			Vector3(2 * _stud, (ytop - lo.y + 4) * _plate, 2 * _stud))):
		return false
	if ytop > top:
		var cut: Dictionary = BrickTerrain.fill_box(Vector3i(lo.x, top + 1, lo.z), Vector3i(hi.x, ytop, hi.z), 0, false)
		host.terrain_edited(cut)
	var res: Dictionary = BrickTerrain.fill_box(lo, hi, BrickTerrain.MAT_FARMLAND, false)
	BrickTerrain.mark_placed(lo, hi, BrickTerrain.MAT_FARMLAND)
	host.terrain_edited(res)
	var b := Vector3i(bx, top, bz)
	var plot := FarmPlant.new_plot(b, now(), fert / maxf(count, 1), BrickTerrain.biome_at(bx * 2, bz * 2))
	store.put(plot)
	refresh(b)
	_near_in = 0.0
	tilled += 1
	log_lines.append("tilled %s" % b)
	return true


# ---------------------------------------------------------------------------
# Seeds, harvests

## Plant seed item `item` on the tilled soil looked at. True if planted (the
## caller takes the seed from the hand).
func plant(target: Dictionary, item: StringName) -> bool:
	var plot := plot_at_target(target)
	var crop := FarmCrops.crop_of_seed(item)
	if plot.is_empty() or crop == &"" or plot.crop != &"":
		return false
	FarmPlant.plant(plot, crop, now())
	store.touch(plot.b)
	_draw_dirty = true
	planted += 1
	log_lines.append("planted %s at %s" % [crop, plot.b])
	return true


## Pick the plot looked at if it is ripe: what it gives into the inventory
## (what does not fit drops), and a non-perennial is replanted from a seed
## carried. True if it was picked.
func harvest_target(target: Dictionary) -> bool:
	var plot := plot_at_target(target)
	if plot.is_empty():
		return false
	return harvest(plot)


func harvest(plot: Dictionary) -> bool:
	var got := FarmPlant.harvest(plot, now())
	if got.is_empty():
		return false
	var at := _top_middle(plot.b) + Vector3(0, 0.3, 0)
	_give(got.produce, int(got.count), at)
	_give(got.seed, int(got.seeds), at)
	harvested += 1
	log_lines.append("harvested %s x%d (+%d seeds, %d stars) at %s" % [got.crop, got.count, got.seeds, got.stars, plot.b])
	# Replant from the seeds carried: no second click per plot.
	if plot.crop == &"" and host.builder.inv.take_item(got.seed, 1) > 0:
		FarmPlant.plant(plot, got.crop, now())
		log_lines.append("replanted %s at %s" % [got.crop, plot.b])
	store.touch(plot.b)
	_draw_dirty = true
	return true


## LMB on a plot: a ripe crop is harvested, a growing one pulled (its seed
## back). False if there is no crop (the builder then breaks the soil).
func break_target(target: Dictionary) -> bool:
	var plot := plot_at_target(target)
	if plot.is_empty() or plot.crop == &"":
		return false
	if FarmPlant.is_ripe(plot):
		return harvest(plot)
	var crop := FarmPlant.crop_of(plot)
	FarmPlant.settle(plot, now())
	_give(crop.seed, 1, _top_middle(plot.b) + Vector3(0, 0.3, 0))
	plot.crop = &""
	plot.stage = 0
	plot.p = 0.0
	store.touch(plot.b)
	_draw_dirty = true
	log_lines.append("pulled %s at %s" % [crop.id, plot.b])
	return true


func _give(id: StringName, n: int, at: Vector3) -> void:
	if n <= 0 or id == &"" or not ItemCatalog.has(id):
		return
	var left: ItemStack = host.builder.inv.add_item(ItemStack.make(id, n))
	if left != null:
		left = _into_chest(left, at)
	if left != null:
		host.drops.spawn(left, at)


## What the inventory could not hold, into the nearest chest within
## CHEST_REACH of `at` that has room (merged into its stacks first, then its
## empty slots). What still does not fit, back.
func _into_chest(s: ItemStack, at: Vector3) -> ItemStack:
	var chests: MineChests = host.chests
	var keys: Array = []
	for key in chests.chests:
		if MineChests.is_container(chests.item_of(key)) \
				and chests.box_of(chests.chests[key].block).get_center().distance_to(at) <= CHEST_REACH:
			keys.append(key)
	keys.sort_custom(func(a, b) -> bool:
			return chests.box_of(chests.chests[a].block).get_center().distance_to(at) \
					< chests.box_of(chests.chests[b].block).get_center().distance_to(at))
	var cap := ItemCatalog.max_stack(s.id)
	for key in keys:
		var slots: Array = chests.slots_of(key)
		for i in slots.size():
			var o = slots[i]
			if o is ItemStack and (o as ItemStack).id == s.id and (o as ItemStack).data == s.data:
				var mv := mini(cap - (o as ItemStack).count, s.count)
				if mv > 0:
					(o as ItemStack).count += mv
					s.count -= mv
			if s.count <= 0:
				break
		for i in slots.size():
			if s.count <= 0:
				break
			if slots[i] == null:
				var mv := mini(cap, s.count)
				slots[i] = ItemStack.make(s.id, mv, s.data)
				s.count -= mv
		if s.count <= 0:
			break
	if not keys.is_empty() and host.has_method("world_items_changed"):
		host.world_items_changed()
	if s.count <= 0:
		return null
	return s


# ---------------------------------------------------------------------------
# Areas (stage 3): the rectangle between two looked-at cells

## The top solid plate of column (x, z) with air over it, nearest under
## `y_ref + 4` and no lower than `y_ref - 6` (a field on a slope, or in a
## cave: never the surface far over it). -1 if none.
static func _top_near(x: int, z: int, y_ref: int) -> int:
	for yy in range(y_ref + 4, y_ref - 7, -1):
		if BrickTerrain.solid_at(x, yy, z) != 0 and BrickTerrain.solid_at(x, yy + 1, z) == 0:
			return yy
	return -1


## The block columns of the rectangle between plate cells a and b, at most
## AREA_MAX a side, from a's corner.
static func area_blocks(a: Vector3i, b: Vector3i, grow := 0) -> Array[Vector2i]:
	var ax := floori(a.x / 2.0)
	var az := floori(a.z / 2.0)
	var bx := floori(b.x / 2.0)
	var bz := floori(b.z / 2.0)
	bx = clampi(bx, ax - AREA_MAX + 1, ax + AREA_MAX - 1)
	bz = clampi(bz, az - AREA_MAX + 1, az + AREA_MAX - 1)
	var out: Array[Vector2i] = []
	for x in range(mini(ax, bx) - grow, maxi(ax, bx) + 1 + grow):
		for z in range(mini(az, bz) - grow, maxi(az, bz) + 1 + grow):
			out.append(Vector2i(x, z))
	return out


## The plot on block column `c` nearest plate `y_ref` (within 6), or {}.
func plot_near(c: Vector2i, y_ref: int) -> Dictionary:
	for dy in [0, -1, 1, -2, 2, -3, 3, -4, 4, -5, 5, -6, 6]:
		var p := store.get_plot(Vector3i(c.x, y_ref + dy, c.y))
		if not p.is_empty():
			return p
	return {}


## An area action from cell a to cell b: "hoe" tills, "seed" plants `item`
## (at most `budget`), "scythe" harvests the ripe crops (a click: 3 x 3),
## "can" waters (at most `budget`). How many plots it acted on.
func area(kind: String, a: Vector3i, b: Vector3i, item: StringName = &"", budget := 1 << 30) -> int:
	var n := 0
	var y_ref := a.y
	var grow := 1 if kind == "scythe" and floori(a.x / 2.0) == floori(b.x / 2.0) \
			and floori(a.z / 2.0) == floori(b.z / 2.0) else 0
	for c in area_blocks(a, b, grow):
		if n >= budget:
			break
		match kind:
			"hoe":
				var top := _top_near(c.x * 2, c.y * 2, y_ref)
				if top >= 0 and plot_near(c, top).is_empty() \
						and till({"cell": Vector3i(c.x * 2, top, c.y * 2), "normal": Vector3i.UP}):
					n += 1
			"seed":
				var p := plot_near(c, y_ref)
				if not p.is_empty() and p.crop == &"" \
						and plant({"cell": Vector3i(c.x * 2, p.b.y, c.y * 2)}, item):
					n += 1
			"scythe":
				var p := plot_near(c, y_ref)
				if not p.is_empty() and FarmPlant.is_ripe(p) and harvest(p):
					n += 1
			"can":
				var p := plot_near(c, y_ref)
				if not p.is_empty() and water(p):
					n += 1
	if n > 0:
		log_lines.append("%s over %d plots" % [kind, n])
	return n


## A watering can on a plot: wet for a day (FarmPlant.CAN_LASTS), the soil
## dark at once. False if it is wet with its own water already.
func water(plot: Dictionary) -> bool:
	if bool(plot.wet):
		return false
	var t := now()
	FarmPlant.settle(plot, t)
	plot.wet_until = t + FarmPlant.CAN_LASTS
	store.touch(plot.b)
	_set_soil(plot, t)
	return true


## The tilled brick's material for its wetness at `t`.
func _set_soil(plot: Dictionary, t: float) -> void:
	var b: Vector3i = plot.b
	var lo := _course_lo(b)
	var m := BrickTerrain.solid_at(lo.x, b.y, lo.z)
	var want := BrickTerrain.MAT_WET_FARMLAND if FarmPlant.wet_at(plot, t) else BrickTerrain.MAT_FARMLAND
	if is_farmland(m) and m != want:
		var res: Dictionary = BrickTerrain.fill_box(_course_lo(b), _course_hi(b), want, false)
		BrickTerrain.mark_placed(_course_lo(b), _course_hi(b), want)
		host.terrain_edited(res)


# ---------------------------------------------------------------------------
# Trampling

## The pawn landed, `fall` metres down, feet at `feet` (terrain frame).
func landed(fall: float, feet: Vector3) -> void:
	if fall < TRAMPLE_FALL or feet == Vector3.INF:
		return
	var cell := Vector3i(floori(feet.x / _stud), floori((feet.y - 0.02) / _plate), floori(feet.z / _stud))
	var plot := plot_at_cell(cell - Vector3i(0, 2, 0))
	if plot.is_empty():
		return
	trample(plot)


## The crop is lost (its seed pops out) and the tilled brick is dirt again.
func trample(plot: Dictionary) -> void:
	var b: Vector3i = plot.b
	if plot.crop != &"":
		var crop := FarmPlant.crop_of(plot)
		host.drops.spawn(ItemStack.make(crop.seed, 1), _top_middle(b) + Vector3(0, 0.3, 0))
	var res: Dictionary = BrickTerrain.fill_box(_course_lo(b), _course_hi(b), BrickTerrain.MAT_DIRT, false)
	BrickTerrain.mark_placed(_course_lo(b), _course_hi(b), BrickTerrain.MAT_DIRT)
	host.terrain_edited(res)
	store.remove(b)
	_near.erase(b)
	_draw_dirty = true
	trampled += 1
	log_lines.append("trampled %s" % b)


# ---------------------------------------------------------------------------
# What a plot has: water, light, its soil still there

## Look at a plot's ground, water and light again. Settles it first, so what
## grew before the change grew under the old conditions.
func refresh(b: Vector3i) -> void:
	var plot := store.get_plot(b)
	if plot.is_empty():
		return
	var lo := _course_lo(b)
	var m := BrickTerrain.solid_at(lo.x, b.y, lo.z)
	if not is_farmland(m):
		_lost(plot, "its soil is gone")
		return
	for x in [lo.x, lo.x + 1]:
		for z in [lo.z, lo.z + 1]:
			if BrickTerrain.solid_at(x, b.y + 1, z) != 0:
				# A block put on it: the crop is crushed and the soil packed down.
				trample(plot)
				return
	var t := now()
	FarmPlant.settle(plot, t)
	var wet := _wet_at(b)
	var mid := _top_middle(b) + Vector3(0, 0.25, 0)
	var sky := clampf(BrickTerrain.sky_light_at(mid) / 15.0, 0.0, 1.0)
	var lamp := clampf(BrickTerrain.block_light_at(mid) / 15.0, 0.0, 1.0)
	var changed: bool = wet != bool(plot.wet) or absf(sky - float(plot.sky)) > 0.01 or absf(lamp - float(plot.lamp)) > 0.01
	plot.wet = wet
	plot.sky = sky
	plot.lamp = lamp
	if changed:
		store.touch(b)
	_set_soil(plot, t)


func _lost(plot: Dictionary, why: String) -> void:
	if plot.crop != &"":
		var crop := FarmPlant.crop_of(plot)
		host.drops.spawn(ItemStack.make(crop.seed, 1), _top_middle(plot.b) + Vector3(0, 0.3, 0))
	store.remove(plot.b)
	_near.erase(plot.b)
	_draw_dirty = true
	log_lines.append("plot %s gone: %s" % [plot.b, why])


## Water (not lava) within WET_STUDS of the plot, on the tilled brick's course
## or the one above it (a channel dug beside it, or water standing by it).
func _wet_at(b: Vector3i) -> bool:
	@warning_ignore("integer_division")
	var course := b.y / 3
	for cy in [course, course + 1]:
		for x in range(b.x * 2 - WET_STUDS, b.x * 2 + 2 + WET_STUDS):
			for z in range(b.z * 2 - WET_STUDS, b.z * 2 + 2 + WET_STUDS):
				if int(BrickFluid.cell_info(Vector3i(x, cy, z)).fluid) == 1:
					return true
	return false


## Builder breaks (terrain_edited): plots whose soil went are dropped at once.
func cells_changed(lo: Vector3i, hi: Vector3i) -> void:
	var bx0 := floori(float(lo.x) / 2.0) - 1
	var bx1 := floori(float(hi.x) / 2.0) + 1
	var bz0 := floori(float(lo.z) / 2.0) - 1
	var bz1 := floori(float(hi.z) / 2.0) + 1
	for b in store.plots.keys():
		if b.x >= bx0 and b.x <= bx1 and b.z >= bz0 and b.z <= bz1 and b.y >= lo.y - 3 and b.y <= hi.y + 3:
			refresh(b)


# ---------------------------------------------------------------------------
# The HUD's line for what is looked at

func look_text(target: Dictionary) -> String:
	var plot := plot_at_target(target)
	if plot.is_empty():
		return ""
	var t := now()
	FarmPlant.settle(plot, t)
	var wet_words := "wet" if plot.wet else ("watered, %s left" % FarmPlant.span_words(float(plot.wet_until) - t)
			if FarmPlant.wet_at(plot, t) else "dry")
	var soil := "Tilled soil, %s, fertility %d" % [wet_words, roundi(float(plot.fert))]
	if plot.fam != "":
		soil += " (last: %s)" % plot.fam
	var crop := FarmPlant.crop_of(plot)
	if crop.is_empty():
		return soil + "  ·  RMB with seeds to plant"
	var last := int(crop.stages) - 1
	var head := "%s  %s" % [crop.name, "★".repeat(FarmPlant.stars(plot)) + "☆".repeat(3 - FarmPlant.stars(plot))]
	var state: String
	if FarmPlant.is_ripe(plot):
		state = "RIPE: RMB or LMB to harvest"
	else:
		state = "stage %d/%d, %d%%, ripe in ~%s" % [int(plot.stage) + 1, last, roundi(float(plot.p) * 100.0),
				FarmPlant.span_words(FarmPlant.eta(plot, t))]
	var held := FarmPlant.limits(plot, t)
	var line := "%s  ·  %s" % [head, state]
	if not held.is_empty():
		line += "  ·  held back: " + ", ".join(held)
	return line + "\n" + soil
