class_name Smelting
extends RefCounted
## Furnaces that smelt over time with fuel, Minecraft's (Docs/Inventory.md 15).
## A placed furnace (an item with `"smelter": true`) holds three slots --
## INPUT, FUEL, OUTPUT -- and a state {burn, burn_max, cook, t}; `settle`
## brings it up to the world time `now`, so a furnace keeps working with the
## screen shut and catches up after a load (MineFarming's settle, the same idea).
##
## Tables in packs, `content/<pack>/data/smelting/*.json`, read through
## ContentPacks, so a mod adds what smelts and what burns:
##
##   {"smelting": [{"name": "Iron ingot", "input": "iron_ore", "take": 12,
##       "output": "iron_ingot", "count": 1, "time": 5}],
##    "fuels": {"coal_ore": {"take": 12, "seconds": 40}}}
##
## `take`: how much input one smelt uses (materials count plate cells: a 2x2
## brick is 12). `time`: seconds a smelt takes. A fuel's `take` is used up
## at once when the fire is lit and burns `seconds`. As in Minecraft the fire
## goes on burning when there is nothing to smelt, and a smelt left half done
## when the fire goes out starts again.

const INPUT := 0
const FUEL := 1
const OUTPUT := 2
const SLOTS := 3

static var _recipes: Array = []
static var _fuels := {}
static var _loaded := false


static func load_all(force := false) -> void:
	if _loaded and not force:
		return
	_loaded = true
	_recipes.clear()
	_fuels.clear()
	ItemCatalog.load_all()
	for path in ContentPacks.files("data/smelting"):
		var parsed = JSON.parse_string(FileAccess.get_file_as_string(path))
		if not (parsed is Dictionary):
			push_warning("[smelting] %s: not a table" % path)
			continue
		for raw in parsed.get("smelting", []):
			var r := parse(raw)
			if r.is_empty():
				push_warning("[smelting] %s: a recipe not understood: %s" % [path, raw])
			else:
				# A later pack's recipe for the same input replaces the earlier.
				_recipes = _recipes.filter(func(o: Dictionary) -> bool: return o.input != r.input)
				_recipes.append(r)
		var fuels = parsed.get("fuels", {})
		if fuels is Dictionary:
			for k in fuels:
				var id := StringName(str(k))
				var f = fuels[k]
				if ItemCatalog.has(id) and f is Dictionary and float(f.get("seconds", 0)) > 0.0:
					_fuels[id] = {"take": maxi(int(f.get("take", 1)), 1), "seconds": float(f.seconds)}


static func parse(raw) -> Dictionary:
	if not (raw is Dictionary):
		return {}
	var input := StringName(str(raw.get("input", "")))
	var output := StringName(str(raw.get("output", "")))
	if not ItemCatalog.has(input) or not ItemCatalog.has(output):
		return {}
	return {"name": str(raw.get("name", ItemCatalog.get_def(output).get("name", output))),
			"input": input, "take": maxi(int(raw.get("take", 1)), 1), "output": output,
			"count": maxi(int(raw.get("count", 1)), 1), "time": maxf(float(raw.get("time", 5.0)), 0.1)}


static func recipes() -> Array:
	load_all()
	return _recipes


## The recipe that smelts item `id`, or {}.
static func recipe_of(id: StringName) -> Dictionary:
	for r in recipes():
		if r.input == id:
			return r
	return {}


static func smelts(id: StringName) -> bool:
	return not recipe_of(id).is_empty()


## What stack `s` gives as fuel: {take, seconds}, or {} if it does not burn.
static func fuel_of(id: StringName) -> Dictionary:
	load_all()
	return _fuels.get(id, {})


## A new furnace's state at world time `now`.
static func new_state(now: float) -> Dictionary:
	return {"burn": 0.0, "burn_max": 0.0, "cook": 0.0, "t": now}


## The recipe the furnace can work on now: enough input, room in the output. {} if none.
static func working_recipe(slots: Array) -> Dictionary:
	var inp: ItemStack = slots[INPUT]
	if inp == null:
		return {}
	var r := recipe_of(inp.id)
	if r.is_empty() or inp.count < int(r.take):
		return {}
	var out: ItemStack = slots[OUTPUT]
	if out != null and (out.id != r.output or out.count + int(r.count) > ItemCatalog.max_stack(out.id)):
		return {}
	return r


## Bring furnace state `f` (its `slots`) up to world time `now`: fuel lit,
## burnt, input smelted into the output. True if the slots changed.
static func settle(f: Dictionary, slots: Array, now: float) -> bool:
	var dt := now - float(f.get("t", now))
	f.t = now
	if dt <= 0.0 or slots.size() < SLOTS:
		return false
	var changed := false
	var guard := 0
	while dt > 1e-6 and guard < 4096:
		guard += 1
		var r := working_recipe(slots)
		if float(f.burn) <= 0.0:
			var fuel: ItemStack = slots[FUEL]
			var fd := fuel_of(fuel.id) if fuel != null else {}
			if r.is_empty() or fd.is_empty() or fuel.count < int(fd.take):
				f.cook = 0.0
				break
			fuel.count -= int(fd.take)
			if fuel.count <= 0:
				slots[FUEL] = null
			f.burn = float(fd.seconds)
			f.burn_max = float(fd.seconds)
			changed = true
		var step := minf(dt, float(f.burn))
		if not r.is_empty():
			step = minf(step, float(r.time) - float(f.cook))
		f.burn = float(f.burn) - step
		dt -= step
		if r.is_empty():
			f.cook = 0.0
			continue
		f.cook = float(f.cook) + step
		if float(f.cook) >= float(r.time) - 1e-6:
			f.cook = 0.0
			var inp: ItemStack = slots[INPUT]
			inp.count -= int(r.take)
			if inp.count <= 0:
				slots[INPUT] = null
			var out: ItemStack = slots[OUTPUT]
			if out == null:
				slots[OUTPUT] = ItemStack.make(r.output, int(r.count))
			else:
				out.count += int(r.count)
			changed = true
	if float(f.burn) < 0.0:
		f.burn = 0.0
	return changed


## How far the smelt is (0..1) and how much fire is left (0..1), for the screen.
static func progress(f: Dictionary, slots: Array) -> Vector2:
	var r := working_recipe(slots) if slots.size() >= SLOTS else {}
	var cook := 0.0 if r.is_empty() else clampf(float(f.get("cook", 0.0)) / float(r.time), 0.0, 1.0)
	var bm := float(f.get("burn_max", 0.0))
	var burn := 0.0 if bm <= 0.0 else clampf(float(f.get("burn", 0.0)) / bm, 0.0, 1.0)
	return Vector2(cook, burn)
