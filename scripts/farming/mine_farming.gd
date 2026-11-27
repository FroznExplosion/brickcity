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
## A felled tree gives its sapling this often (survival).
const SAPLING_CHANCE := 0.5
## Saplings planted by a drag stand this many plots apart (canopies).
const SAPLING_SPACING := 3
## A scarecrow keeps most birds off plots within this (metres).
const SCARE_M := 8.0
## Stage 7, automation (Docs/MineFarming.md 21): a sprinkler wets the plots
## within this many plots of it (a square 7 x 7), no water source needed; a
## collector harvests the ripe plots within this many (9 x 9) into its own
## slots and replants them from what it holds. Both within this many plates
## up or down.
const SPRINKLER_PLOTS := 3
const COLLECTOR_PLOTS := 4
const AUTO_PLATES := 6
## Stage 6 (Docs/MineFarming.md 20). A bare tilled plot between two ripe
## plants of one crop (in a line) sprouts a cross of them about once in this
## many in-game days (while in reach).
const CROSS_DAYS := 0.5
## A 2x2 of a giant crop, all ripe at 3 stars: the chance it merges.
static var giant_chance := 0.4
## A giant gives this many times what its four plots would.
const GIANT_YIELD := 2
## A plot's light is asked again only when the ground changed since it was
## last asked (`terrain_changed`), or after this long (seconds) anyway --
## the sky light fill was the refresh's second cost (Docs/MineFarming.md 19).
const LIGHT_AGAIN := 30.0
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
## Bites real animals took (animal_eat, Docs/MineCreatures.md).
var eaten := 0
var trees_grown := 0
var fertilised := 0
var weeded := 0
var crossed := 0
var giants := 0
var collected := 0
## Fields and enclosure (stage 5): grouped plots, a flood on a worker.
var fields := FarmFields.new()
## Bumped by every terrain edit (`terrain_changed`): a plot's light is asked
## again only when it moved on.
var _terrain_ver := 0
## Where the scarecrows stand (terrain frame), gathered once a second.
var _scarecrows: Array[Vector3] = []
## Sprinklers and collectors: their block (the plots' 2-stud lattice, its
## bottom plate), and a collector's chest key -- gathered with the scarecrows.
var _sprinklers: Array[Vector3i] = []
var _collectors: Array = []          ## [[block, key], ...]
var _scare_in := 0.0
var _scare_count := -1

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
	# Crops lit like the cave they are in when the world draws sky light.
	draw.setup(host.get("sky_lit") != null)
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
	_scare_in -= delta
	if _scare_in <= 0.0:
		_scare_in = 1.0
		_gather_scarecrows()
	if not _near.is_empty():
		for _i in mini(SETTLE_PER_FRAME, _near.size()):
			_settle_i = (_settle_i + 1) % _near.size()
			var plot := store.get_plot(_near[_settle_i])
			if not plot.is_empty() and FarmPlant.settle(plot, t):
				_draw_dirty = true
				if _grown_tree(plot):
					_grow_tree(plot)
				elif bool(plot.get("packed", false)):
					_packed(plot)
				if _near.is_empty():
					break
		for _i in mini(COND_PER_FRAME, _near.size()):
			_cond_i = (_cond_i + 1) % _near.size()
			var b: Vector3i = _near[_cond_i]
			var at := _top_middle(b)
			if Vector2(at.x - eye.x, at.z - eye.z).length() <= COND_M:
				var t0 := Time.get_ticks_usec()
				refresh(b)
				worst_refresh_us = maxi(worst_refresh_us, Time.get_ticks_usec() - t0)
	fields.step(delta, store, eye, _stud, _apply_field)
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
	for b in store.plots.keys():
		var plot: Dictionary = store.plots[b]
		if FarmPlant.settle(plot, t):
			_draw_dirty = true
		if _grown_tree(plot):
			_grow_tree(plot)
		elif bool(plot.get("packed", false)):
			_packed(plot)


# ---------------------------------------------------------------------------
# Trouble (stage 5, Docs/MineFarming.md 9)

## A field's answer is in: its plots open to animals or not, one-crop or not
## -- each settled first, so what grew before grew under the old flags.
func _apply_field(f: Dictionary) -> void:
	var t := now()
	for b in f.plots:
		var plot := store.get_plot(b)
		if plot.is_empty():
			continue
		var open := bool(f.open)
		var mono: bool = f.mono != &"" and plot.crop == f.mono
		if open != bool(plot.get("open", false)) or mono != bool(plot.get("mono", false)):
			FarmPlant.settle(plot, t)
			plot.open = open
			plot.mono = mono
			store.touch(b)


## The ground near the farms changed (MineWorld.terrain_edited): fields are
## looked at again (a wall built or broken).
func terrain_changed() -> void:
	fields.dirty = true
	_terrain_ver += 1


## Animals trampled it (FarmPlant's event): the tilled brick is dirt again.
func _packed(plot: Dictionary) -> void:
	plot.packed = false
	plot.crop = &""
	trample(plot)
	trampled -= 1             # (not the player's)
	log_lines.append("animals trampled %s" % plot.b)


## Is a scarecrow standing within SCARE_M of the plot? (From the list
## gathered once a second: the chests were walked for every plot.)
func _scared(b: Vector3i) -> bool:
	if host.chests != null and host.chests.count() != _scare_count:
		_gather_scarecrows()     # one put down or taken away just now
	var at := _top_middle(b)
	for sc in _scarecrows:
		if sc.distance_to(at) <= SCARE_M:
			return true
	return false


func _gather_scarecrows() -> void:
	_scarecrows.clear()
	_sprinklers.clear()
	_collectors.clear()
	var chests: MineChests = host.chests
	if chests == null:
		return
	_scare_count = chests.count()
	for key in chests.chests:
		match chests.item_of(key):
			&"scarecrow":
				_scarecrows.append(chests.box_of(chests.chests[key].block).get_center())
			&"sprinkler":
				_sprinklers.append(chests.chests[key].block)
			&"collector":
				_collectors.append([chests.chests[key].block, key])


func _in_reach(block: Vector3i, b: Vector3i, plots: int) -> bool:
	return absi(block.x - b.x) <= plots and absi(block.z - b.z) <= plots \
			and absi(block.y - (b.y + 1)) <= AUTO_PLATES


## A sprinkler within reach of plot `b`?
func _sprinkled(b: Vector3i) -> bool:
	if host.chests != null and host.chests.count() != _scare_count:
		_gather_scarecrows()
	for sp in _sprinklers:
		if _in_reach(sp, b, SPRINKLER_PLOTS):
			return true
	return false


## The key of a collector with plot `b` in reach, or "".
func _collector_for(b: Vector3i) -> String:
	for c in _collectors:
		if _in_reach(c[0], b, COLLECTOR_PLOTS):
			return str(c[1])
	return ""


## A collector harvests a ripe plot into its own slots (Docs/MineFarming.md
## 21) and replants it from a seed it holds (the harvest's own first). Only
## when it has an empty slot: a full collector leaves the crop ripe.
func _collect(plot: Dictionary, key: String) -> bool:
	var chests: MineChests = host.chests
	var slots: Array = chests.slots_of(key)
	if not slots.has(null):
		return false
	var got := FarmPlant.harvest(plot, now())
	if got.is_empty():
		return false
	var at := chests.box_of(chests.chests[key].block).get_center() + Vector3(0, 0.5, 0)
	for pair in [[got.produce, int(got.count), got.produce_data], [got.seed, int(got.seeds), got.seed_data]]:
		var left := _put_in(slots, pair[0], int(pair[1]), pair[2])
		if left > 0:
			host.drops.spawn(ItemStack.make(pair[0], left, pair[2]), at)
	# Replant from its own slots.
	if plot.crop == &"":
		var data: Dictionary = got.seed_data if int(got.seeds) > 0 else got.produce_data
		var i := _find_in(slots, got.seed, data)
		if i < 0:
			i = _find_in(slots, got.seed, null)
		if i >= 0:
			var st: ItemStack = slots[i]
			FarmPlant.plant(plot, got.crop, now(), FarmPlant.traits_of(st.data))
			st.count -= 1
			if st.count <= 0:
				slots[i] = null
	store.touch(plot.b)
	_draw_dirty = true
	collected += 1
	if host.has_method("world_items_changed"):
		host.world_items_changed()
	log_lines.append("collector %s took %s x%d at %s" % [key, got.crop, got.count, plot.b])
	return true


## Put n of `id` (with `data`) into `slots`: its stacks first, then empty
## ones. How many did not fit.
static func _put_in(slots: Array, id: StringName, n: int, data: Dictionary) -> int:
	if n <= 0 or id == &"" or not ItemCatalog.has(id):
		return 0
	var cap := ItemCatalog.max_stack(id)
	for o in slots:
		if n <= 0:
			break
		if o is ItemStack and (o as ItemStack).id == id and (o as ItemStack).data == data:
			var mv := mini(cap - (o as ItemStack).count, n)
			if mv > 0:
				(o as ItemStack).count += mv
				n -= mv
	for i in slots.size():
		if n <= 0:
			break
		if slots[i] == null:
			var mv := mini(cap, n)
			slots[i] = ItemStack.make(id, mv, data)
			n -= mv
	return n


## A slot holding `id` (with `data`, or any data when null), or -1.
static func _find_in(slots: Array, id: StringName, data) -> int:
	for i in slots.size():
		var o = slots[i]
		if o is ItemStack and (o as ItemStack).id == id and (data == null or (o as ItemStack).data == data):
			return i
	return -1


# ---------------------------------------------------------------------------
# Saplings (Docs/MineFarming.md 17)

## The sapling item that grows into tree variant `variant`, or &"".
static func sapling_of(variant: int) -> StringName:
	if variant < 0:
		return &""
	for id in FarmCrops.ids():
		var c := FarmCrops.get_crop(id)
		if int(c.tree) == variant:
			return c.seed
	return &""


func _grown_tree(plot: Dictionary) -> bool:
	var c := FarmPlant.crop_of(plot)
	return not c.is_empty() and int(c.tree) >= 0 and FarmPlant.is_ripe(plot)


## A grown sapling becomes a real tree (TerrainTrees.plant_tree, saved with
## the world): felled, collided and drawn like the seed's own.
func _grow_tree(plot: Dictionary) -> void:
	var c := FarmPlant.crop_of(plot)
	var b: Vector3i = plot.b
	if not host.plant_tree(Vector3i(b.x * 2, b.y + 1, b.z * 2), int(c.tree)):
		return
	store.remove(b)
	_near.erase(b)
	_draw_dirty = true
	trees_grown += 1
	log_lines.append("%s grew into a tree at %s" % [c.id, b])


## A plot on plain soil for a sapling (no hoe): the 2x2 looked at, its four
## tops within a brick of each other, soil (or tilled soil), room over it.
func _soil_plot(target: Dictionary) -> Dictionary:
	if target.is_empty() or not target.has("cell") or target.get("normal", Vector3i.ZERO) != Vector3i.UP:
		return {}
	var cell: Vector3i = target.cell
	var bx := floori(cell.x / 2.0)
	var bz := floori(cell.z / 2.0)
	var lo_t := 1 << 30
	var hi_t := -(1 << 30)
	var fert := 0.0
	for x in [bx * 2, bx * 2 + 1]:
		for z in [bz * 2, bz * 2 + 1]:
			var top := _top_near(x, z, cell.y)
			if top < 0:
				return {}
			var m := BrickTerrain.solid_at(x, top, z)
			if not _soil.has(m) and not is_farmland(m):
				return {}
			fert += float(_soil.get(m, 60.0))
			lo_t = mini(lo_t, top)
			hi_t = maxi(hi_t, top)
	if hi_t - lo_t > 3:
		return {}
	var b := Vector3i(bx, hi_t, bz)
	if not plot_near(Vector2i(bx, bz), hi_t).is_empty():
		return {}
	var plot := FarmPlant.new_plot(b, now(), fert / 4.0, BrickTerrain.biome_at(bx * 2, bz * 2))
	plot.ground = "soil"
	store.put(plot)
	_near_in = 0.0
	return plot


# ---------------------------------------------------------------------------
# Compost and grow mix

## A fertiliser item (`def`, ItemCatalog) on a plot: its fertility, and a
## grow mix's boost for its days. False if it would do nothing (rich soil and
## no boost to give).
func fertilise(plot: Dictionary, def: Dictionary) -> bool:
	var add := float(def.get("fertility", 0.0))
	var days := float(def.get("boost_days", 0.0))
	var mulch := bool(def.get("mulch", false))
	if mulch and bool(plot.get("mulch", false)):
		return false
	if not mulch and days <= 0.0 and float(plot.fert) >= 100.0:
		return false
	var t := now()
	FarmPlant.settle(plot, t)
	plot.fert = minf(100.0, float(plot.fert) + add)
	if mulch:
		# Mulch: no weeds come up; the ones there are smothered.
		plot.mulch = true
		plot.weeds = false
	if days > 0.0:
		plot.boost_until = t + days * FarmPlant.DAY
	store.touch(plot.b)
	fertilised += 1
	log_lines.append("%s on %s" % [def.get("id", "?"), plot.b])
	return true


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
		refuse("Hoe: the top of soil, not its side")
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
					refuse("Hoe: clear what stands on it first")
					return false
			var m := BrickTerrain.solid_at(x, top, z)
			for yy in range(top + 1, ytop + 1):
				m = BrickTerrain.solid_at(x, yy, z) if BrickTerrain.solid_at(x, yy, z) != 0 else m
			if not _soil.has(m):
				log_lines.append("till refused: not soil (%d)" % m)
				refuse("Hoe: only grass, dirt or podzol can be tilled")
				return false
			for yy in range(c * 3, top + 1):
				if BrickTerrain.solid_at(x, yy, z) == 0 and yy < top:
					log_lines.append("till refused: not flat")
					refuse("Hoe: the 2x2 under it must be flat")
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
func plant(target: Dictionary, item: StringName, data := {}) -> bool:
	var plot := plot_at_target(target)
	var crop := FarmCrops.crop_of_seed(item)
	if crop == &"":
		return false
	var cdef := FarmCrops.get_crop(crop)
	if plot.is_empty() and str(cdef.ground) == "soil":
		plot = _soil_plot(target)
	if plot.is_empty() and str(cdef.ground) == "farm":
		refuse("%s go on tilled soil: use a hoe first" % ItemCatalog.get_def(item).get("name", "Seeds"))
		return false
	if plot.is_empty() or plot.crop != &"":
		return false
	# A crop wants tilled soil: a sapling's plain-soil plot takes only saplings.
	if str(cdef.ground) == "farm" and str(plot.get("ground", "farm")) != "farm":
		refuse("%s go on tilled soil: use a hoe first" % ItemCatalog.get_def(item).get("name", "Seeds"))
		return false
	# A biome crop grows only in its biomes (stage 6).
	if not grows_here(cdef, int(plot.biome)):
		log_lines.append("%s refused at %s: only in %s" % [crop, plot.b, ", ".join(cdef.only)])
		refuse("%s only grows in %s" % [cdef.name, ", ".join(cdef.only)])
		return false
	FarmPlant.plant(plot, crop, now(), FarmPlant.traits_of(data))
	store.touch(plot.b)
	_draw_dirty = true
	planted += 1
	if str(plot.get("ground", "farm")) == "soil":
		refresh(plot.b)          # its water and light, now it holds a sapling
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
	if int(plot.get("giant", 0)) != 0:
		return _harvest_giant(plot)
	var got := FarmPlant.harvest(plot, now())
	if got.is_empty():
		return false
	var at := _top_middle(plot.b) + Vector3(0, 0.3, 0)
	_give(got.produce, int(got.count), at, got.produce_data)
	_give(got.seed, int(got.seeds), at, got.seed_data)
	harvested += 1
	log_lines.append("harvested %s x%d (+%d seeds, %d stars) at %s" % [got.crop, got.count, got.seeds, got.stars, plot.b])
	_replant(plot, got)
	store.touch(plot.b)
	_draw_dirty = true
	return true


## Replant from the seeds carried: no second click per plot. The harvest's
## own seeds first (its traits, maybe one point better), else any of them.
func _replant(plot: Dictionary, got: Dictionary) -> void:
	if plot.crop != &"":
		return
	var inv: Inventory = host.builder.inv
	var data: Dictionary = got.seed_data if int(got.seeds) > 0 else got.produce_data
	if inv.take_item(got.seed, 1, data) > 0:
		FarmPlant.plant(plot, got.crop, now(), FarmPlant.traits_of(data))
	elif inv.take_item(got.seed, 1) > 0:
		FarmPlant.plant(plot, got.crop, now())
	else:
		return
	log_lines.append("replanted %s at %s" % [got.crop, plot.b])


# ---------------------------------------------------------------------------
# Depth (stage 6, Docs/MineFarming.md 20)

## The last thing tilling or planting refused, and when (ms), for the HUD:
## shown over the hotbar for REFUSAL_MS (Docs/MineFarming.md 22).
var last_refusal := ""
var _refusal_at := -100000
const REFUSAL_MS := 3000


func refuse(why: String) -> void:
	last_refusal = why
	_refusal_at = Time.get_ticks_msec()


## The line over the hotbar: why the last till or plant was refused (for a
## few seconds), then the plot or crop looked at.
func hud_text(target: Dictionary) -> String:
	var look := look_text(target)
	if last_refusal != "" and Time.get_ticks_msec() - _refusal_at < REFUSAL_MS:
		return last_refusal + ("\n" + look if look != "" else "")
	return look


## Does crop `c` grow in biome `biome` at all? (Its `only` list; empty: anywhere.)
static func grows_here(c: Dictionary, biome: int) -> bool:
	var only: PackedStringArray = c.get("only", PackedStringArray())
	if only.is_empty():
		return true
	var names: PackedStringArray = BrickTerrain.biome_names()
	return biome >= 0 and biome < names.size() and only.has(names[biome])


## A companion crop growing in one of the 8 plots round it?
func _companion_near(plot: Dictionary) -> bool:
	var c := FarmPlant.crop_of(plot)
	if c.is_empty() or (c.companions as PackedStringArray).is_empty():
		return false
	var b: Vector3i = plot.b
	for dx in [-1, 0, 1]:
		for dz in [-1, 0, 1]:
			if dx == 0 and dz == 0:
				continue
			var n := plot_near(Vector2i(b.x + dx, b.z + dz), b.y)
			if not n.is_empty() and (c.companions as PackedStringArray).has(String(n.crop)):
				return true
	return false


## A bare tilled plot between two ripe plants of one crop (in a line, E-W or
## N-S) may sprout a CROSS of them: each trait the better parent's, and half
## the time one point more. Only while in reach (both parents in view).
func _try_cross(plot: Dictionary, t: float) -> void:
	var b: Vector3i = plot.b
	var last := float(plot.get("_cross_t", t))
	plot["_cross_t"] = t
	var dt := t - last
	if dt <= 0.0:
		return
	for d in [Vector2i(1, 0), Vector2i(0, 1)]:
		var p1 := plot_near(Vector2i(b.x + d.x, b.z + d.y), b.y)
		var p2 := plot_near(Vector2i(b.x - d.x, b.z - d.y), b.y)
		if p1.is_empty() or p2.is_empty() or p1.crop == &"" or p1.crop != p2.crop:
			continue
		var c := FarmPlant.crop_of(p1)
		if int(c.tree) >= 0 or not FarmPlant.is_ripe(p1) or not FarmPlant.is_ripe(p2):
			continue
		if randf() >= 1.0 - exp(-dt / (CROSS_DAYS * FarmPlant.DAY)):
			continue
		var t1 := FarmPlant.traits(p1)
		var t2 := FarmPlant.traits(p2)
		var tr := Vector3i(maxi(t1.x, t2.x), maxi(t1.y, t2.y), maxi(t1.z, t2.z))
		if randf() < 0.5:
			var which := randi() % 3
			tr[which] = mini(tr[which] + 1, FarmPlant.TRAIT_MAX)
		FarmPlant.plant(plot, p1.crop, t, tr)
		store.touch(b)
		_draw_dirty = true
		crossed += 1
		log_lines.append("crossed %s at %s (G%d Y%d H%d)" % [p1.crop, b, tr.x, tr.y, tr.z])
		return


## A ripe 3-star plot of a giant crop: is it the corner of a 2x2 of them that
## merges into a giant? Rolled once per 2x2 (from its plants' seeds), so a
## miss stays a miss until replanted.
func _try_giant(plot: Dictionary) -> void:
	var c := FarmPlant.crop_of(plot)
	if c.is_empty() or not bool(c.get("giant", false)) or not FarmPlant.is_ripe(plot) \
			or FarmPlant.stars(plot) < 3 or int(plot.get("giant", 0)) != 0:
		return
	var b: Vector3i = plot.b
	for o in [Vector2i(0, 0), Vector2i(-1, 0), Vector2i(0, -1), Vector2i(-1, -1)]:
		var corner := Vector2i(b.x + o.x, b.z + o.y)
		var four: Array = []
		for k in 4:
			var q := plot_near(Vector2i(corner.x + (k >> 1), corner.y + (k & 1)), b.y)
			if q.is_empty() or q.crop != plot.crop or not FarmPlant.is_ripe(q) \
					or FarmPlant.stars(q) < 3 or int(q.get("giant", 0)) != 0:
				break
			four.append(q)
		if four.size() != 4:
			continue
		var s := 0
		for q in four:
			s ^= int(q.seed)
		if FarmPlant.roll(s, 4242, 0) >= giant_chance:
			continue
		var anchor: Dictionary = four[0]
		for q in four:
			FarmPlant.settle(q, now())
			q.giant = 2
			q.gdx = int(anchor.b.x) - int(q.b.x)
			q.gdz = int(anchor.b.z) - int(q.b.z)
			store.touch(q.b)
		anchor.giant = 1
		anchor.gdx = 0
		anchor.gdz = 0
		giants += 1
		_draw_dirty = true
		log_lines.append("a giant %s at %s" % [plot.crop, anchor.b])
		return


## The four plots of the giant `plot` belongs to (its corner first), or [].
func _giant_plots(plot: Dictionary) -> Array:
	var b: Vector3i = plot.b
	var corner := Vector2i(b.x + int(plot.get("gdx", 0)), b.z + int(plot.get("gdz", 0)))
	var out: Array = []
	for dx in 2:
		for dz in 2:
			var q := plot_near(Vector2i(corner.x + dx, corner.y + dz), b.y)
			if q.is_empty() or int(q.get("giant", 0)) == 0 or q.crop != plot.crop:
				return []
			out.append(q)
	return out


## A giant picked (any of its plots): what its four plots give, GIANT_YIELD
## times over; each plot replanted from the seeds carried.
func _harvest_giant(plot: Dictionary) -> bool:
	var four := _giant_plots(plot)
	if four.is_empty():
		plot.giant = 0
		return harvest(plot)
	var produce := 0
	var seeds := 0
	var got := {}
	for q in four:
		q.giant = 0
		var g := FarmPlant.harvest(q, now())
		if g.is_empty():
			continue
		got = g
		produce += int(g.count)
		seeds += int(g.seeds)
	if got.is_empty():
		return false
	var at := _top_middle(four[0].b) + Vector3(0.35, 0.6, 0.35)
	_give(got.produce, produce * GIANT_YIELD, at, got.produce_data)
	_give(got.seed, seeds * GIANT_YIELD, at, got.seed_data)
	harvested += 1
	log_lines.append("harvested a giant %s: %d (+%d seeds)" % [got.crop, produce * GIANT_YIELD, seeds * GIANT_YIELD])
	for q in four:
		_replant(q, got)
		store.touch(q.b)
	_draw_dirty = true
	return true


## A giant missing a plot (trampled, broken) falls apart into ripe plots.
func _check_giant(plot: Dictionary) -> void:
	if int(plot.get("giant", 0)) != 0 and _giant_plots(plot).is_empty():
		plot.giant = 0
		store.touch(plot.b)
		_draw_dirty = true


## LMB on a plot: a ripe crop is harvested, a growing one pulled (its seed
## back). False if there is no crop (the builder then breaks the soil).
func break_target(target: Dictionary) -> bool:
	var plot := plot_at_target(target)
	if plot.is_empty() or plot.crop == &"":
		return false
	FarmPlant.settle(plot, now())
	if bool(plot.get("weeds", false)):
		# Weeds first: pulled, the crop stays.
		plot.weeds = false
		store.touch(plot.b)
		weeded += 1
		log_lines.append("weeded %s" % plot.b)
		return true
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


func _give(id: StringName, n: int, at: Vector3, data := {}) -> void:
	if n <= 0 or id == &"" or not ItemCatalog.has(id):
		return
	# In stacks no bigger than the item's own (an empty slot takes a whole
	# stack, whatever its size).
	var cap := ItemCatalog.max_stack(id)
	while n > 0:
		var k := mini(n, cap)
		n -= k
		var left: ItemStack = host.builder.inv.add_item(ItemStack.make(id, k, data))
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
func area(kind: String, a: Vector3i, b: Vector3i, item: StringName = &"", budget := 1 << 30, data := {}) -> int:
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
				if p.is_empty() and str(FarmCrops.get_crop(FarmCrops.crop_of_seed(item)).get("ground", "farm")) == "soil":
					# Saplings: on plain soil, SAPLING_SPACING plots apart.
					var ax := floori(a.x / 2.0)
					var az := floori(a.z / 2.0)
					var top := _top_near(c.x * 2, c.y * 2, y_ref)
					if posmod(c.x - ax, SAPLING_SPACING) == 0 and posmod(c.y - az, SAPLING_SPACING) == 0 and top >= 0 \
							and plant({"cell": Vector3i(c.x * 2, top, c.y * 2), "normal": Vector3i.UP}, item, data):
						n += 1
				elif not p.is_empty() and p.crop == &"" \
						and plant({"cell": Vector3i(c.x * 2, p.b.y, c.y * 2)}, item, data):
					n += 1
			"fertiliser":
				var p := plot_near(c, y_ref)
				if not p.is_empty() and fertilise(p, ItemCatalog.get_def(item)):
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
	if str(plot.get("ground", "farm")) != "farm":
		return
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


## A creature landed on the plot under `feet` (terrain frame) from a fall at
## least its own trample height (Docs/MineCreatures.md 5.3: a zombie 3 bricks,
## a pig 2; the creature decides). True if a plot was trampled.
func creature_landed(feet: Vector3) -> bool:
	if feet == Vector3.INF:
		return false
	var cell := Vector3i(floori(feet.x / _stud), floori((feet.y - 0.02) / _plate), floori(feet.z / _stud))
	var plot := plot_at_cell(cell - Vector3i(0, 2, 0))
	if plot.is_empty() or plot.crop == &"":
		return false
	trample(plot)
	return true


## Planted plots within `r` metres of `at` (terrain frame), of these crops
## (empty: any), nearest first: [{"b": Vector3i, "at": top middle, "crop"}].
func crops_near(at: Vector3, r: float, crops: Array = []) -> Array:
	var out := []
	var r2 := r * r
	for b in store.plots:
		var plot: Dictionary = store.plots[b]
		if plot.crop == &"" or (not crops.is_empty() and not crops.has(plot.crop)):
			continue
		var top := _top_middle(b)
		var d2 := Vector2(top.x - at.x, top.z - at.z).length_squared()
		if d2 <= r2 and absf(top.y - at.y) < 8.0:
			out.append({"b": b, "at": top, "crop": plot.crop, "d2": d2})
	out.sort_custom(func(a, c) -> bool: return a.d2 < c.d2)
	return out


## An animal standing on plot `b` takes a bite: settled first, then eaten back
## two stages (FarmPlant's animals event, done by a real animal). At sprout
## already: the crop is eaten up. True if there was a crop to eat.
func animal_eat(b: Vector3i) -> bool:
	var plot := store.get_plot(b)
	if plot.is_empty() or plot.crop == &"":
		return false
	FarmPlant.settle(plot, now())
	if int(plot.stage) <= 0:
		plot.crop = &""
		plot.p = 0.0
		plot.stress = 0
		plot.last_event = "eaten up by an animal"
	else:
		plot.stage = maxi(0, int(plot.stage) - 2)
		plot.p = 0.0
		plot.stress = int(plot.stress) + 1
		plot.last_event = "eaten back by an animal"
	plot.event_at = now()
	store.touch(b)
	_draw_dirty = true
	eaten += 1
	log_lines.append("eaten %s" % b)
	return true


## The crop is lost (its seed pops out) and the tilled brick is dirt again.
func trample(plot: Dictionary) -> void:
	var b: Vector3i = plot.b
	if plot.crop != &"":
		var crop := FarmPlant.crop_of(plot)
		host.drops.spawn(ItemStack.make(crop.seed, 1), _top_middle(b) + Vector3(0, 0.3, 0))
	if str(plot.get("ground", "farm")) == "farm":
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
	var soil_plot := str(plot.get("ground", "farm")) == "soil"
	if (soil_plot and _top_near(lo.x, lo.z, b.y) < b.y - 3) or (not soil_plot and not is_farmland(m)):
		_lost(plot, "its soil is gone")
		return
	if soil_plot and plot.crop == &"":
		_lost(plot, "nothing planted on plain soil")
		return
	for x in [lo.x, lo.x + 1]:
		for z in [lo.z, lo.z + 1]:
			if BrickTerrain.solid_at(x, b.y + 1, z) != 0:
				# A block put on it: the crop is crushed and the soil packed down.
				trample(plot)
				return
	var t := now()
	var u0 := Time.get_ticks_usec()
	FarmPlant.settle(plot, t)
	var u1 := Time.get_ticks_usec()
	# Water: looked at again only when some water changed (BrickFluid's
	# change count) or the ground did, since this plot was last looked at.
	var water_wet := bool(plot.get("_water_wet", plot.wet))
	var cc := BrickFluid.change_count()
	if int(plot.get("_water_cc", -1)) != cc or int(plot.get("_water_ver", -1)) != _terrain_ver:
		water_wet = _wet_at(b)
		plot["_water_wet"] = water_wet
		plot["_water_cc"] = cc
		plot["_water_ver"] = _terrain_ver
	# A sprinkler in reach wets it too (stage 7).
	var sprinkled := _sprinkled(b)
	plot["_sprinkled"] = sprinkled
	var wet := water_wet or sprinkled
	var u2 := Time.get_ticks_usec()
	# Light: asked again only when the ground changed or LIGHT_AGAIN passed
	# (kept on the plot, not saved: a reload asks once).
	var sky := float(plot.sky)
	var lamp := float(plot.lamp)
	var u3 := u2
	var since := Time.get_ticks_msec() / 1000.0 - float(plot.get("_light_at", -1e9))
	if int(plot.get("_light_ver", -1)) != _terrain_ver or since >= LIGHT_AGAIN:
		var mid := _top_middle(b) + Vector3(0, 0.25, 0)
		sky = clampf(BrickTerrain.sky_light_at(mid) / 15.0, 0.0, 1.0)
		u3 = Time.get_ticks_usec()
		lamp = clampf(BrickTerrain.block_light_at(mid) / 15.0, 0.0, 1.0)
		plot["_light_ver"] = _terrain_ver
		plot["_light_at"] = Time.get_ticks_msec() / 1000.0
	var u4 := Time.get_ticks_usec()
	var scared := _scared(b)
	var u5 := Time.get_ticks_usec()
	# Stage 6: a companion next to it; a cross into a bare plot; a giant.
	var companion := _companion_near(plot)
	if companion != bool(plot.get("companion", false)):
		plot.companion = companion
		store.touch(b)
	if plot.crop == &"" and str(plot.get("ground", "farm")) == "farm":
		_try_cross(plot, t)
	_check_giant(plot)
	_try_giant(plot)
	# A collector in reach takes a ripe crop (stage 7; not a giant, not a tree).
	if FarmPlant.is_ripe(plot) and int(plot.get("giant", 0)) == 0 \
			and int(FarmPlant.crop_of(plot).get("tree", -1)) < 0:
		var ck := _collector_for(b)
		if ck != "":
			_collect(plot, ck)
	_prof("settle", u1 - u0)
	_prof("water", u2 - u1)
	_prof("sky light", u3 - u2)
	_prof("block light", u4 - u3)
	_prof("scarecrow", u5 - u4)
	var changed: bool = wet != bool(plot.wet) or absf(sky - float(plot.sky)) > 0.01 \
			or absf(lamp - float(plot.lamp)) > 0.01 or scared != bool(plot.get("scared", false))
	plot.wet = wet
	plot.sky = sky
	plot.lamp = lamp
	plot.scared = scared
	if changed:
		store.touch(b)
		_draw_dirty = true            # its light is drawn on it (FarmDraw)
	var u6 := Time.get_ticks_usec()
	_set_soil(plot, t)
	_prof("soil swap", Time.get_ticks_usec() - u6)


## What a plot refresh's parts cost (us): name -> [count, total, worst].
var prof := {}


func _prof(key: String, us: int) -> void:
	var e: Array = prof.get(key, [0, 0, 0])
	e[0] += 1
	e[1] += us
	e[2] = maxi(e[2], us)
	prof[key] = e


func prof_line() -> String:
	var parts := PackedStringArray()
	for k in prof:
		var e: Array = prof[k]
		parts.append("%s mean %.0f worst %d us (%d)" % [k, float(e[1]) / maxi(e[0], 1), e[2], e[0]])
	return ", ".join(parts)


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
	# One call, one lock (BrickFluid.any_fluid): it was ~200 cell_info calls,
	# each a Dictionary, ~0.2 ms a plot (Docs/MineFarming.md 19).
	return BrickFluid.any_fluid(Vector3i(b.x * 2 - WET_STUDS, course, b.z * 2 - WET_STUDS),
			Vector3i(b.x * 2 + 1 + WET_STUDS, course + 1, b.z * 2 + 1 + WET_STUDS), 1)


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
	var wet_words := ("wet (sprinkler)" if bool(plot.get("_sprinkled", false)) else "wet") if plot.wet else ("watered, %s left" % FarmPlant.span_words(float(plot.wet_until) - t)
			if FarmPlant.wet_at(plot, t) else "dry")
	var soil := "%s, %s, fertility %d" % ["Tilled soil" if str(plot.get("ground", "farm")) == "farm" else "Soil",
			wet_words, roundi(float(plot.fert))]
	if FarmPlant.boosted_at(plot, t):
		soil += ", grow mix: %s left" % FarmPlant.span_words(float(plot.boost_until) - t)
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
	if str(plot.get("last_event", "")) != "" and t - float(plot.get("event_at", 0.0)) < FarmPlant.DAY:
		line += "  ·  %s %s ago" % [plot.last_event, FarmPlant.span_words(t - float(plot.event_at))]
	var tr := FarmPlant.traits(plot)
	if tr != Vector3i.ZERO:
		line += "  ·  traits G%d Y%d H%d" % [tr.x, tr.y, tr.z]
	if bool(plot.get("companion", false)):
		line += "  ·  companion near (+15%)"
	if int(plot.get("giant", 0)) != 0:
		line = "GIANT " + line
	if bool(plot.get("mulch", false)):
		soil += ", mulched"
	if bool(plot.get("scared", false)):
		soil += ", scarecrow near"
	return line + "\n" + soil
