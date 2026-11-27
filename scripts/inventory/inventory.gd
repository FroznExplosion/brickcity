class_name Inventory
extends RefCounted
## The player's items (Docs/Inventory.md 3.2), ported from zylanntest's
## Inventory autoload: two hotbars of 9, two off-hand slots, the main storage,
## an open chest, and the cursor stack the mouse carries in the screen. Guns
## are not here: they are the arsenal's (Docs/Inventory.md 1).
##
## Every slot has an address `{area, index}`:
##   hotbar_0, hotbar_1   9 each
##   offhand              2
##   quick                1, the quick slot (Docs/Inventory.md round four):
##                        B pulls it out as the main hand, until put away
##   backpack             1, the backpack worn (Docs/Inventory.md 8)
##   main                 the worn backpack's own slots (its `contents`): no
##                        backpack, no storage -- zylanntest's rule
##   chest                the open chest's slots (borrowed array, see open_chest)
## Crafting (Docs/Inventory.md 12) is Terraria's: a recipe takes what you
## carry (can_craft / craft), no grid.
## All the rules go through get_slot / set_slot / slot_accepts, so the UI only
## sends addresses and redraws on `changed`.
##
## A plain object the mine world owns, not an autoload: nothing else uses it yet.

signal changed
signal active_changed

const HOTBAR_SIZE := 9
const OFFHAND_SIZE := 2
## The storage of the kit's backpack (a Large one).
const MAIN_SIZE := 27
const KIT_BACKPACK := &"large_backpack"
const CHEST_SIZE := 27
## X held this long swaps the off-hand instead of the hotbar.
const HOLD_MS := 350

var hotbars: Array = [[], []]
var offhands: Array = [null, null]
## The quick slot (round four): one item, out in the main hand while
## `quick_out`, else resting.
var quick: Array = [null]
var quick_out := false
## The off-hand up (C, pad: hold LB): RMB uses it. Down: RMB is the main
## hand's (aim, place). A two-handed item in the main hand lowers it while
## held; the flag stays.
var offhand_up := false
## Set for the length of one off-hand use (MineBuilder.with_offhand): `hand`
## and `hand_addr` then mean the off-hand, so the builder's place/pour code
## works on it unchanged.
var using_off := false
## The backpack worn, or null; its `contents` are the storage.
var backpack: ItemStack = null
## The old 2 x 2 craft grid's contents (stage 9), only to give them back from
## an old save (from_dict empties it into storage).
var old_craft: Array = []
## The crafting grid in the screen (Docs/Inventory.md 16): craft_n x craft_n
## of craft_grid (row by row; 2 by hand, a station's `grid`), area "craft".
## Never saved: the screen closing puts it back (clear_craft).
var craft_grid: Array = []
var craft_n := 2
## The storage: the worn backpack's slots, or none.
var main: Array:
	get:
		return backpack.contents if backpack != null else _no_storage
var _no_storage: Array = []
var active_hotbar := 0
var active_slot := 0
var active_offhand := 0
## What the mouse carries in the inventory screen.
var cursor: ItemStack = null
## Creative (the default): placing does not use a stack up, breaking gives
## nothing, the creative tab hands out stacks.
var creative := true

## The open chest: its slots array (shared with whoever stores it, so the
## clicks change it in place) and its key.
var chest_slots: Array = []
var chest_key := ""
## What the open container is called (a chest, a backpack put down).
var chest_title := "Chest"
## Whose rules its slots follow: "" (any item anywhere) or "furnace"
## (Smelting: input, fuel only fuels, output taken from, never put into).
var chest_rules := ""

var _drag_active := false
var _drag_button := -1
var _drag_touched: Array = []


func _init() -> void:
	hotbars[0] = _empty(HOTBAR_SIZE)
	hotbars[1] = _empty(HOTBAR_SIZE)
	old_craft = _empty(4)
	craft_grid = _empty(RecipeBook.MAX_GRID * RecipeBook.MAX_GRID)
	backpack = make_backpack(KIT_BACKPACK)


## A backpack of item `id`, its slots sized from the catalog, empty (or
## holding `items`, as many as fit).
static func make_backpack(id: StringName, items: Array = []) -> ItemStack:
	var s := ItemStack.make(id, 1)
	var n := int(ItemCatalog.get_def(id).get("slots", 0))
	if n <= 0:
		n = MAIN_SIZE
	s.contents = _empty(n)
	for i in mini(items.size(), n):
		s.contents[i] = items[i]
	return s


static func is_backpack(s: ItemStack) -> bool:
	return s != null and ItemCatalog.kind(s.id) == "backpack"


static func _empty(n: int) -> Array:
	var a := []
	a.resize(n)
	return a


static func addr(area: StringName, index := 0) -> Dictionary:
	return {"area": area, "index": index}


func hotbar_area(which := -1) -> StringName:
	return StringName("hotbar_%d" % (active_hotbar if which < 0 else which))


## The starting kit: the old builder hotbar's blocks on bar 1, fluids and
## buckets on bar 2.
func seed_default() -> void:
	# Materials (Docs/Inventory.md 11): soil, stone, sand and clay lay several
	# colours each (V); the count is plate cells.
	var blocks := ["soil", "stone", "gravel", "snow", "sand", "sandstone", "clay", "ice", "obsidian"]
	for i in blocks.size():
		var id := StringName(blocks[i])
		if ItemCatalog.has(id):
			hotbars[0][i] = ItemStack.make(id, ItemCatalog.max_stack(id))
	var bar2 := ["bucket", "source_bucket", "water_source", "water_brick", "lava_source", "pickaxe",
			"mega_pickaxe", "chest"]
	for i in bar2.size():
		var id := StringName(bar2[i])
		if ItemCatalog.has(id):
			hotbars[1][i] = ItemStack.make(id, ItemCatalog.max_stack(id))
	# Wood and leaves (Docs/Inventory.md 13), then the crafting stations
	# (stage 12), at the end of the storage.
	for k in 2:
		var wl := [&"wood", &"leaves"][k] as StringName
		if ItemCatalog.has(wl) and main.size() > 24:
			main[21 + k] = ItemStack.make(wl, ItemCatalog.max_stack(wl))
	for k in 2:
		var st := [&"workbench", &"furnace"][k] as StringName
		if ItemCatalog.has(st) and main.size() > 24:
			main[23 + k] = ItemStack.make(st, 1)
	if ItemCatalog.has(&"grenade") and main.size() > 22:
		main[22] = ItemStack.make(&"grenade", ItemCatalog.max_stack(&"grenade"))
	changed.emit()


# ---------------------------------------------------------------------------
# Slots

func get_slot(a: Dictionary) -> ItemStack:
	if a.area == &"backpack":
		return backpack
	var arr := _array(a.area)
	var i: int = a.index
	return arr[i] if i >= 0 and i < arr.size() else null


func set_slot(a: Dictionary, s: ItemStack) -> void:
	if a.area == &"backpack":
		backpack = null if s == null or s.is_empty() else s
		if backpack != null:
			_fit_backpack(backpack)
		return
	var arr := _array(a.area)
	var i: int = a.index
	if i >= 0 and i < arr.size():
		arr[i] = null if s == null or s.is_empty() else s


func _array(area: StringName) -> Array:
	match area:
		&"hotbar_0": return hotbars[0]
		&"hotbar_1": return hotbars[1]
		&"offhand": return offhands
		&"quick": return quick
		&"main": return main
		&"chest": return chest_slots
		&"craft": return craft_grid
	return []


func area_size(area: StringName) -> int:
	if area == &"backpack":
		return 1
	if area == &"craft":
		return craft_n * craft_n
	return _array(area).size()


## A backpack's slots made the size its item says (a new one, or one saved
## by an older game), keeping what is in them.
static func _fit_backpack(s: ItemStack) -> void:
	var n := int(ItemCatalog.get_def(s.id).get("slots", 0))
	if n > 0 and s.contents.size() < n:
		s.contents.resize(n)


## May `s` go in slot `a`? Storage, the hotbars and the quick slot take
## anything; the off-hand anything but a two-handed item (`hand: "two"`);
## the backpack slot backpacks; a furnace its own rules.
func slot_accepts(a: Dictionary, s: ItemStack) -> bool:
	if s == null:
		return true
	var d := ItemCatalog.get_def(s.id)
	if d.is_empty():
		return false
	if a.area == &"backpack":
		return d.kind == "backpack"
	if a.area == &"chest" and chest_rules == "furnace":
		match int(a.index):
			Smelting.OUTPUT:
				return false
			Smelting.FUEL:
				return not Smelting.fuel_of(s.id).is_empty()
		return true
	# The hands (the user, 2026-11-26): the hotbars and the quick slot (an
	# extra hotbar slot) take anything; the off-hand anything but a
	# two-handed item -- blocks and other placeables, food, one-handed guns,
	# shields, tools.
	if a.area == &"offhand":
		return d.hand != "two"
	return true


## As much of `src` as fits into `dst`; what is left of src, or null.
func _merge_into(dst: ItemStack, src: ItemStack) -> ItemStack:
	if dst == null or src == null or not dst.same_kind(src):
		return src
	var moved := mini(ItemCatalog.max_stack(dst.id) - dst.count, src.count)
	if moved <= 0:
		return src
	dst.count += moved
	src.count -= moved
	return src if src.count > 0 else null


# ---------------------------------------------------------------------------
# Clicks (the inventory screen)

## Pick up, put down, merge or swap with the cursor.
func left_click(a: Dictionary) -> void:
	var s := get_slot(a)
	if cursor == null and s == null:
		return
	if cursor == null:
		cursor = s
		set_slot(a, null)
	elif s == null:
		if not slot_accepts(a, cursor):
			return
		set_slot(a, cursor)
		cursor = null
	elif s.same_kind(cursor) and not slot_accepts(a, cursor):
		# A furnace's output: what is there comes onto the held stack.
		var n := mini(s.count, ItemCatalog.max_stack(s.id) - cursor.count)
		if n <= 0:
			return
		cursor.count += n
		s.count -= n
		if s.count <= 0:
			set_slot(a, null)
	elif s.same_kind(cursor):
		cursor = _merge_into(s, cursor)
	else:
		if not slot_accepts(a, cursor):
			return
		set_slot(a, cursor)
		cursor = s
	changed.emit()


## Cursor full: put one down. Cursor empty: pick up half (rounded up).
func right_click(a: Dictionary) -> void:
	var s := get_slot(a)
	if cursor != null:
		if s == null:
			if not slot_accepts(a, cursor):
				return
			set_slot(a, ItemStack.make(cursor.id, 1, cursor.data))
		elif s.same_kind(cursor) and s.count < ItemCatalog.max_stack(s.id) and slot_accepts(a, cursor):
			s.count += 1
		else:
			return
		cursor.count -= 1
		if cursor.count <= 0:
			cursor = null
		changed.emit()
		return
	if s == null:
		return
	var half := ceili(s.count / 2.0)
	cursor = ItemStack.make(s.id, half, s.data)
	s.count -= half
	if s.count <= 0:
		set_slot(a, null)
	changed.emit()


## To the other side: a chest <-> the player; else main -> hotbars, off-hand;
## the hands -> main. Same items first, then the first empty slot.
func shift_click(a: Dictionary) -> void:
	var s := get_slot(a)
	if s == null:
		return
	# A backpack: on, if none is worn (zylanntest's); the one worn: off, into
	# a hotbar (never into the storage it is).
	if is_backpack(s) and a.area != &"backpack" and backpack == null:
		set_slot(a, null)
		set_slot(addr(&"backpack"), s)
		changed.emit()
		return
	var targets: Array = []
	if a.area == &"backpack":
		targets = [hotbar_area(), hotbar_area(1 - active_hotbar)] + ([&"chest"] if not chest_key.is_empty() else [])
	elif not chest_key.is_empty() and a.area == &"chest":
		targets = [hotbar_area(), hotbar_area(1 - active_hotbar), &"main"]
	elif not chest_key.is_empty() and chest_rules == "furnace":
		# Into a furnace: what smelts on top, what burns below (fuel first
		# for what only burns).
		var order := [addr(&"chest", Smelting.INPUT), addr(&"chest", Smelting.FUEL)]
		if not Smelting.smelts(s.id):
			order.reverse()
		set_slot(a, _insert_addrs(s, order))
		changed.emit()
		return
	elif not chest_key.is_empty():
		targets = [&"chest"]
	elif a.area == &"main":
		targets = [hotbar_area(), hotbar_area(1 - active_hotbar)]
	else:
		targets = [&"main"]
	var left := _insert(s, targets)
	set_slot(a, left)
	changed.emit()


## Gather every stack like the cursor's into it, smallest first, to a full stack.
func double_click(a: Dictionary) -> void:
	if cursor == null:
		var s := get_slot(a)
		if s == null:
			return
		cursor = s
		set_slot(a, null)
	var cap := ItemCatalog.max_stack(cursor.id)
	var found: Array = []
	for x in all_addrs():
		var s := get_slot(x)
		if s != null and s != cursor and s.same_kind(cursor):
			found.append([x, s])
	found.sort_custom(func(p, q): return p[1].count < q[1].count)
	for f in found:
		if cursor.count >= cap:
			break
		var moved := mini(cap - cursor.count, f[1].count)
		cursor.count += moved
		f[1].count -= moved
		if f[1].count <= 0:
			set_slot(f[0], null)
	changed.emit()


## A kit item added after a save was made (the Mega Pickaxe, 2026-11-19): put
## it in the slot after `after` if that is free, else the first free hotbar
## slot, else the backpack -- once; never a second copy. True if it was added.
func ensure_item(id: StringName, after: StringName = &"") -> bool:
	if not ItemCatalog.has(id):
		return false
	for a in all_addrs():
		var s := get_slot(a)
		if s != null and s.id == id:
			return false
	var stack := ItemStack.make(id, ItemCatalog.max_stack(id))
	if after != &"":
		for bar in 2:
			for i in HOTBAR_SIZE - 1:
				var s: ItemStack = hotbars[bar][i]
				if s != null and s.id == after and hotbars[bar][i + 1] == null:
					hotbars[bar][i + 1] = stack
					changed.emit()
					return true
	for bar in 2:
		for i in HOTBAR_SIZE:
			if hotbars[bar][i] == null:
				hotbars[bar][i] = stack
				changed.emit()
				return true
	var left := _insert(stack, [&"main"])
	changed.emit()
	return left == null


func all_addrs() -> Array:
	var out: Array = []
	for area in [&"hotbar_0", &"hotbar_1", &"offhand", &"quick", &"backpack", &"main", &"chest"]:
		for i in area_size(area):
			out.append(addr(area, i))
	return out


# ---------------------------------------------------------------------------
# Dragging the cursor across slots: left spreads it evenly, right puts one in each.

func begin_drag(button: int) -> void:
	if cursor == null:
		return
	_drag_active = true
	_drag_button = button
	_drag_touched = []


func is_dragging() -> bool:
	return _drag_active


func drag_touch(a: Dictionary) -> void:
	if not _drag_active or cursor == null:
		return
	for t in _drag_touched:
		if t.area == a.area and t.index == a.index:
			return
	var s := get_slot(a)
	if (s != null and not s.same_kind(cursor)) or not slot_accepts(a, cursor):
		return
	_drag_touched.append(a)
	changed.emit()


func finish_drag() -> void:
	if not _drag_active:
		return
	var touched := _drag_touched
	var button := _drag_button
	if cursor != null:
		if (button == MOUSE_BUTTON_LEFT and touched.size() > 1) or button == MOUSE_BUTTON_RIGHT:
			var amounts := _amounts()
			for t in touched:
				var n: int = amounts.get(_key(t), 0)
				if n <= 0:
					continue
				var s := get_slot(t)
				if s != null:
					s.count += n
				else:
					set_slot(t, ItemStack.make(cursor.id, n, cursor.data))
				cursor.count -= n
			if cursor.count <= 0:
				cursor = null
		elif touched.size() == 1:
			_drag_active = false
			if button == MOUSE_BUTTON_LEFT:
				left_click(touched[0])
			else:
				right_click(touched[0])
	_drag_active = false
	_drag_button = -1
	_drag_touched = []
	changed.emit()


func cancel_drag() -> void:
	_drag_active = false
	_drag_button = -1
	_drag_touched = []


## How many the slot would get if the drag ended now (the live preview).
func drag_amount_for(a: Dictionary) -> int:
	return _amounts().get(_key(a), 0) if _drag_active else 0


static func _key(a: Dictionary) -> String:
	return "%s:%d" % [a.area, a.index]


func _amounts() -> Dictionary:
	var out := {}
	if cursor == null or _drag_touched.is_empty():
		return out
	var cap := ItemCatalog.max_stack(cursor.id)
	var left := cursor.count
	var per := 1
	if _drag_button == MOUSE_BUTTON_LEFT:
		if _drag_touched.size() < 2:
			return out
		per = maxi(1, floori(cursor.count / float(_drag_touched.size())))
	for t in _drag_touched:
		if left <= 0:
			break
		var s := get_slot(t)
		var n := mini(mini(per, cap - (s.count if s != null else 0)), left)
		if n > 0:
			out[_key(t)] = n
			left -= n
	return out


# ---------------------------------------------------------------------------
# From play

## Put `s` into the player's storage: the active hotbar, the other, main --
## same items first, then empty slots. What did not fit, or null.
func add_item(s: ItemStack) -> ItemStack:
	if s == null or s.is_empty():
		return null
	if is_backpack(s) and backpack == null:
		set_slot(addr(&"backpack"), s)
		changed.emit()
		return null
	# Never into the off-hand by itself (round four: blocks fit there now, and
	# what is in it is the player's choice); same kind there is topped up.
	var left := _insert(s, [hotbar_area(), hotbar_area(1 - active_hotbar), &"main"])
	if left != null:
		left = _merge_only(left, [&"offhand"])
	changed.emit()
	return left


## `s` merged onto stacks of its kind in `areas`, never into empty slots.
func _merge_only(s: ItemStack, areas: Array) -> ItemStack:
	for area in areas:
		for i in area_size(area):
			var t := get_slot(addr(area, i))
			if t != null and t.same_kind(s):
				s = _merge_into(t, s)
				if s == null:
					return null
	return s


func _insert(s: ItemStack, areas: Array) -> ItemStack:
	for area in areas:
		for i in area_size(area):
			var t := get_slot(addr(area, i))
			if t != null and t.same_kind(s) and slot_accepts(addr(area, i), s):
				s = _merge_into(t, s)
				if s == null:
					return null
	for area in areas:
		for i in area_size(area):
			var a := addr(area, i)
			if get_slot(a) == null and slot_accepts(a, s):
				set_slot(a, s)
				return null
	return s


## `s` into the slots `addrs` in order (those that take it): onto its own
## kind, else an empty one. What did not fit, or null.
func _insert_addrs(s: ItemStack, addrs: Array) -> ItemStack:
	for a in addrs:
		var t := get_slot(a)
		if t != null and t.same_kind(s) and slot_accepts(a, s):
			s = _merge_into(t, s)
			if s == null:
				return null
	for a in addrs:
		if get_slot(a) == null and slot_accepts(a, s):
			set_slot(a, s)
			return null
	return s


## Everything carried of item `id` moved into slot `a` (onto what is there,
## up to a full stack): the recipe book filling a furnace (Bedrock's). How many.
func fill_slot(a: Dictionary, id: StringName) -> int:
	var t := get_slot(a)
	if t != null and t.id != id:
		return 0
	var moved := 0
	for c in _carried():
		var s := get_slot(c)
		if s == null or s.id != id or not s.contents.is_empty():
			continue
		t = get_slot(a)
		var room := ItemCatalog.max_stack(id) - (t.count if t != null else 0)
		if room <= 0:
			break
		var n := mini(room, s.count)
		if t == null:
			set_slot(a, ItemStack.make(id, n, s.data))
		else:
			t.count += n
		s.count -= n
		moved += n
		if s.count <= 0:
			set_slot(c, null)
	if moved > 0:
		changed.emit()
	return moved


## Take one (or the whole stack) out of slot `a`, for dropping into the world.
func take_from(a: Dictionary, whole: bool) -> ItemStack:
	var s := get_slot(a)
	if s == null:
		return null
	var out: ItemStack
	if whole:
		out = s
		set_slot(a, null)
	else:
		out = ItemStack.make(s.id, 1, s.data)
		s.count -= 1
		if s.count <= 0:
			set_slot(a, null)
	changed.emit()
	return out


## The slot the hand in use takes from: the off-hand during an off-hand use
## (`using_off`), else the main hand's (main_addr).
func hand_addr() -> Dictionary:
	if using_off:
		return addr(&"offhand", active_offhand)
	return main_addr()


## The main (right) hand's slot: the quick slot while it is out, else the
## active hotbar's selected slot.
func main_addr() -> Dictionary:
	return addr(&"quick", 0) if quick_out else addr(hotbar_area(), active_slot)


## What is in the hand in use (see hand_addr).
func hand() -> ItemStack:
	return get_slot(hand_addr())


## What is in the main hand, whatever is being used.
func main_hand() -> ItemStack:
	return get_slot(main_addr())


static func two_handed(s: ItemStack) -> bool:
	return s != null and ItemCatalog.get_def(s.id).get("hand", "") == "two"


## The off-hand in use: its active slot's item while it is up and not
## lowered by a two-handed item in the main hand; else null.
func offhand() -> ItemStack:
	if not offhand_up or offhand_lowered():
		return null
	return offhands[active_offhand]


## Up, but held down by a two-handed item in the main hand.
func offhand_lowered() -> bool:
	return offhand_up and two_handed(main_hand())


## C (pad: hold LB): the off-hand up or down.
func toggle_offhand_up() -> void:
	offhand_up = not offhand_up
	active_changed.emit()
	changed.emit()


## B (pad: hold RB): the quick slot into the main hand; again, put away.
## Nothing in it: nothing happens. True if it is out after.
func toggle_quick() -> bool:
	if quick_out:
		put_away_quick()
	elif quick[0] != null:
		quick_out = true
		active_changed.emit()
		changed.emit()
	return quick_out


## The toolbar slot back in the main hand. True if the quick slot was out.
func put_away_quick() -> bool:
	if not quick_out:
		return false
	quick_out = false
	active_changed.emit()
	changed.emit()
	return true


## Use up `n` of the hand's stack (survival only: creative never runs out).
## False if there are not that many.
func consume_hand(n := 1) -> bool:
	if creative:
		return true
	var h := hand()
	if h == null or h.count < n:
		return false
	h.count -= n
	if h.count <= 0:
		set_slot(hand_addr(), null)
	changed.emit()
	return true


func swap_hand_offhand() -> void:
	var ha := hand_addr()
	var oa := addr(&"offhand", active_offhand)
	var h := get_slot(ha)
	var o := get_slot(oa)
	if not slot_accepts(ha, o) or not slot_accepts(oa, h):
		return
	set_slot(ha, o)
	set_slot(oa, h)
	changed.emit()


## 1-9 over a slot in the screen: that slot and slot `i` of the active hotbar
## change places (if each may hold the other's item).
func swap_with_hotbar(a: Dictionary, i: int) -> void:
	var h := addr(hotbar_area(), clampi(i, 0, HOTBAR_SIZE - 1))
	if a.area == h.area and a.index == h.index:
		return
	var s := get_slot(a)
	var t := get_slot(h)
	if not slot_accepts(a, t) or not slot_accepts(h, s):
		return
	set_slot(a, t)
	set_slot(h, s)
	changed.emit()


## Slots `a` and `b` change places, if each may hold the other's item (C and
## B over a slot in the screen: the off-hand, the quick slot). True if they did.
func swap_slots(a: Dictionary, b: Dictionary) -> bool:
	if a.area == b.area and a.index == b.index:
		return false
	var s := get_slot(a)
	var t := get_slot(b)
	if not slot_accepts(a, t) or not slot_accepts(b, s):
		return false
	set_slot(a, t)
	set_slot(b, s)
	# The quick slot emptied while out: the toolbar slot is the hand again.
	if get_slot(main_addr()) == null and quick_out:
		quick_out = false
	changed.emit()
	return true


## The cursor stack back into storage (the screen closing). False if some did
## not fit (it is kept on the cursor).
func return_cursor() -> bool:
	if cursor == null:
		return true
	cursor = _insert(cursor, [&"main", hotbar_area(), hotbar_area(1 - active_hotbar)])
	changed.emit()
	return cursor == null


func toggle_hotbar() -> void:
	active_hotbar = 1 - active_hotbar
	quick_out = false
	active_changed.emit()
	changed.emit()


func toggle_offhand() -> void:
	active_offhand = 1 - active_offhand
	active_changed.emit()
	changed.emit()


func select_slot(i: int) -> void:
	i = clampi(i, 0, HOTBAR_SIZE - 1)
	if i == active_slot and not quick_out:
		return
	# Choosing a toolbar slot puts the quick slot away (round four).
	quick_out = false
	active_slot = i
	active_changed.emit()
	changed.emit()


func scroll(step: int) -> void:
	select_slot(posmod(active_slot + step, HOTBAR_SIZE))


## Find an item in the hotbars (the active one first) and put it in the hand.
## False if neither has it.
func select_item(id: StringName) -> bool:
	if quick_out and quick[0] != null and quick[0].id == id:
		return true
	for k in 2:
		var bar := active_hotbar if k == 0 else 1 - active_hotbar
		for i in HOTBAR_SIZE:
			var s: ItemStack = hotbars[bar][i]
			if s != null and s.id == id:
				if bar != active_hotbar:
					toggle_hotbar()
				select_slot(i)
				return true
	return false


## Middle click on a block: a hotbar slot that has it, else (creative) a full
## stack of it into the hand, the hand's old stack moved to storage if it fits.
func pick(id: StringName) -> bool:
	if id == &"" or select_item(id):
		return id != &""
	if not creative or not ItemCatalog.has(id):
		return false
	put_away_quick()
	var old := hand()
	hotbars[active_hotbar][active_slot] = ItemStack.make(id, ItemCatalog.max_stack(id))
	if old != null:
		_insert(old, [&"main"])
	changed.emit()
	return true


# ---------------------------------------------------------------------------
# Crafting (Docs/Inventory.md 9; zylanntest's 2 x 2 grid)

## Where crafting takes from: the hotbars, the off-hand, the storage (the
## worn backpack's slots) -- not the backpack worn itself, nor an open chest.
func _carried() -> Array:
	var out: Array = []
	for area in [&"main", hotbar_area(), hotbar_area(1 - active_hotbar), &"offhand", &"quick"]:
		for i in area_size(area):
			out.append(addr(area, i))
	return out


## The crafting grid's slots in use.
func _grid_addrs() -> Array:
	var out: Array = []
	for i in craft_n * craft_n:
		out.append(addr(&"craft", i))
	return out


## How many of recipe input `inp` are carried (the crafting grid's too).
func count_of(inp: Dictionary) -> int:
	return count_carried(inp) + _count_in(inp, _grid_addrs())


## How many of `inp` are carried outside the crafting grid.
func count_carried(inp: Dictionary) -> int:
	return _count_in(inp, _carried())


func _count_in(inp: Dictionary, addrs: Array) -> int:
	var n := 0
	for a in addrs:
		var s := get_slot(a)
		if RecipeBook.takes(inp, s):
			n += s.count
	return n


## Can recipe `r` be made now, with the stations `near` (item ids) in reach?
func can_craft(r: Dictionary, near: Array) -> bool:
	if r.station != &"" and not near.has(r.station):
		return false
	for inp in r.inputs:
		if count_of(inp) < int(inp.count):
			return false
	return true


## What `r` still needs, in words ("12 more Iron Ore", "a furnace near").
func missing(r: Dictionary, near: Array) -> PackedStringArray:
	var out := PackedStringArray()
	for inp in r.inputs:
		var lack := int(inp.count) - count_of(inp)
		if lack > 0:
			var what: String = ("any " + inp.tag) if inp.tag != "" else str(ItemCatalog.get_def(inp.id).get("name", inp.id))
			out.append("%d more %s" % [lack, what])
	if r.station != &"" and not near.has(r.station):
		out.append("a %s near" % str(ItemCatalog.get_def(r.station).get("name", r.station)).to_lower())
	return out


## Make `r` (once, or `all`: as many as can be, up to 64 times): its inputs
## taken from what is carried, its output into the inventory. A backpack made
## from a backpack (`keep_contents`) keeps that one's contents. What did not
## fit is returned, for the caller to drop. {"made": n, "left": [stacks]}.
func craft(r: Dictionary, near: Array, all := false) -> Dictionary:
	var made := 0
	var left: Array = []
	for n in (64 if all else 1):
		if not can_craft(r, near):
			break
		var kept: Array = []
		for inp in r.inputs:
			var need := int(inp.count)
			for a in _carried() + _grid_addrs():
				if need <= 0:
					break
				var s := get_slot(a)
				if not RecipeBook.takes(inp, s):
					continue
				var take := mini(need, s.count)
				if not s.contents.is_empty() and kept.is_empty():
					kept = s.contents
				s.count -= take
				need -= take
				if s.count <= 0:
					set_slot(a, null)
		var out := ItemStack.make(r.output, int(r.count))
		if is_backpack(out):
			out = make_backpack(r.output)
			if r.keep_contents and not kept.is_empty():
				out.contents = kept
				_fit_backpack(out)
		made += 1
		var l := _insert(out, [hotbar_area(), hotbar_area(1 - active_hotbar), &"main"])
		if is_backpack(out) and l != null and backpack == null:
			set_slot(addr(&"backpack"), l)
			l = null
		if l != null:
			left.append(l)
			break
	if made > 0:
		changed.emit()
	return {"made": made, "left": left}


## Take up to `n` of item `id` from what is carried (a harvest replanting its
## seed, Docs/MineFarming.md). Creative: nothing is used up. How many.
func take_item(id: StringName, n := 1, data = null) -> int:
	if creative:
		return n
	var need := n
	for a in _carried():
		if need <= 0:
			break
		var s := get_slot(a)
		if s == null or s.id != id or (data != null and s.data != data):
			continue
		var take := mini(need, s.count)
		s.count -= take
		need -= take
		if s.count <= 0:
			set_slot(a, null)
	if need < n:
		changed.emit()
	return n - need


## Would all of `s` fit into `areas`?
func _can_fit(s: ItemStack, areas: Array) -> bool:
	var need := s.count
	var cap := ItemCatalog.max_stack(s.id)
	for area in areas:
		for i in area_size(area):
			var a := addr(area, i)
			var t := get_slot(a)
			if t == null:
				if slot_accepts(a, s):
					need -= cap
			elif t.same_kind(s):
				need -= cap - t.count
			if need <= 0:
				return true
	return false


## The grid emptied back into the inventory (the screen closing, Minecraft's).
## What did not fit, for the caller to drop.
func clear_craft() -> Array:
	var left := []
	for arr in [old_craft, craft_grid]:
		for i in (arr as Array).size():
			var s: ItemStack = arr[i]
			arr[i] = null
			if s != null:
				var l := _insert(s, [&"main", hotbar_area(), hotbar_area(1 - active_hotbar)])
				if l != null:
					left.append(l)
	changed.emit()
	return left


# ---------------------------------------------------------------------------
# The crafting grid (Docs/Inventory.md 16): shapes 2x2 / 3x3 / 4x4, a cell
# may need several of its item, and what a cell lacks comes from what the
# player carries.

## The grid made `n` x `n` (the screen opening by hand or at a station):
## what was in it goes back first. What did not fit, to drop.
func set_craft_size(n: int) -> Array:
	n = clampi(n, 2, RecipeBook.MAX_GRID)
	if n == craft_n:
		return []
	var left := clear_craft()
	craft_n = n
	changed.emit()
	return left


## The grid's stacks, n*n, row by row.
func grid() -> Array:
	return craft_grid.slice(0, craft_n * craft_n)


## The recipe the grid's layout makes ({} or RecipeBook.match_grid's); the
## recipe picked in the book (`grid_prefer`) is tried first.
var grid_prefer: Dictionary = {}


func grid_match() -> Dictionary:
	return RecipeBook.match_grid(grid(), craft_n, grid_prefer)


## What the matched grid `m` still lacks, in words ("7 more Wood", "a
## workbench near"): each item's cells short of their count, made up from
## what is carried outside the grid.
func grid_lack(m: Dictionary, near: Array) -> PackedStringArray:
	var out := PackedStringArray()
	if m.is_empty():
		return out
	var r: Dictionary = m.recipe
	var extra := {}
	var cells := {}
	for e in m.need:
		var have := 0
		for gi in e.idx:
			var st: ItemStack = craft_grid[gi]
			have += st.count if st != null else 0
		var k := "%s|%s" % [e.cell.id, e.cell.tag]
		extra[k] = int(extra.get(k, 0)) + maxi(0, int(e.cell.count) - have)
		cells[k] = e.cell
	for k in extra:
		var lack := int(extra[k]) - count_carried(cells[k])
		if lack > 0:
			var c: Dictionary = cells[k]
			var what: String = ("any " + c.tag) if str(c.tag) != "" else str(ItemCatalog.get_def(c.id).get("name", c.id))
			out.append("%d more %s" % [lack, what])
	if r.station != &"" and not near.has(r.station):
		out.append("a %s near" % str(ItemCatalog.get_def(r.station).get("name", r.station)).to_lower())
	return out


## Make what the grid shows (once; `all`: as many as can be, the grid's
## cells topped up from what is carried between makes): each cell's count
## from the cell first, the rest from what is carried. `to_cursor`: the
## result onto the held stack (Minecraft's click; stops when it would not
## fit), else into the inventory. {"made": n, "left": [stacks to drop]}.
func craft_grid_now(near: Array, to_cursor: bool, all := false) -> Dictionary:
	var made := 0
	var left: Array = []
	var first := ""
	for _n in (64 if all else 1):
		var m := grid_match()
		if m.is_empty() or not grid_lack(m, near).is_empty():
			break
		var r: Dictionary = m.recipe
		# "As many as you can" of what was shown: what is left in the grid may
		# make another recipe (a ring of wood half used up is a compost bin).
		if first.is_empty():
			first = r.name
		elif r.name != first:
			break
		var out := ItemStack.make(r.output, int(r.count))
		if to_cursor and cursor != null and (not cursor.same_kind(out)
				or cursor.count + out.count > ItemCatalog.max_stack(out.id)):
			break
		var ids := {}
		var kept: Array = []
		for e in m.need:
			var need := int(e.cell.count)
			for gi in e.idx:
				var st: ItemStack = craft_grid[gi]
				if st == null:
					continue
				ids[gi] = st.id
				if not st.contents.is_empty() and kept.is_empty():
					kept = st.contents
				var take := mini(need, st.count)
				st.count -= take
				need -= take
				if st.count <= 0:
					craft_grid[gi] = null
				if need <= 0:
					break
			if need > 0:
				for a in _carried():
					var st2 := get_slot(a)
					if not RecipeBook.takes(e.cell, st2):
						continue
					var take2 := mini(need, st2.count)
					st2.count -= take2
					need -= take2
					if st2.count <= 0:
						set_slot(a, null)
					if need <= 0:
						break
		if is_backpack(out):
			out = make_backpack(r.output)
			if r.keep_contents and not kept.is_empty():
				out.contents = kept
				_fit_backpack(out)
		made += 1
		if to_cursor:
			if cursor == null:
				cursor = out
			else:
				cursor.count += out.count
		else:
			var l := _insert(out, [hotbar_area(), hotbar_area(1 - active_hotbar), &"main"])
			if l != null:
				left.append(l)
				break
		if all:
			# Keep the shape: an emptied cell gets its item back from what is carried.
			for e in m.need:
				for gi in e.idx:
					if craft_grid[gi] == null and ids.has(gi):
						_fill_cell(gi, ids[gi], int(e.cell.count))
	if made > 0:
		changed.emit()
	return {"made": made, "left": left}


## Up to `upto` of item `id` moved from what is carried into grid cell `gi`
## (onto what is there). How many.
func _fill_cell(gi: int, id: StringName, upto: int) -> int:
	var moved := 0
	for a in _carried():
		var t: ItemStack = craft_grid[gi]
		var want := upto - (t.count if t != null else 0)
		if want <= 0:
			break
		var st := get_slot(a)
		if st == null or st.id != id or not st.contents.is_empty():
			continue
		var n := mini(want, st.count)
		if t == null:
			craft_grid[gi] = ItemStack.make(id, n, st.data)
		else:
			t.count += n
		st.count -= n
		moved += n
		if st.count <= 0:
			set_slot(a, null)
	return moved


## The recipe book's click (Bedrock's fill): the grid emptied back, then recipe
## `r` laid in it from what is carried -- its shape from the top left, each
## cell up to its count (a list: one input a cell). False if `r` needs a
## bigger grid. `ghosts`: grid cell -> the cell it wants (the screen shows what
## is missing); `left`: what did not fit back, to drop.
func fill_grid(r: Dictionary) -> Dictionary:
	if int(r.grid) > craft_n:
		return {"ok": false, "ghosts": {}, "left": []}
	var left := clear_craft()
	var place := []
	var sh: Dictionary = r.get("shape", {})
	if not sh.is_empty():
		for y in int(sh.h):
			for x in int(sh.w):
				var c = sh.cells[y * int(sh.w) + x]
				if c != null:
					place.append([y * craft_n + x, c])
	else:
		for i in r.inputs.size():
			place.append([i, r.inputs[i]])
	var ghosts := {}
	for pc in place:
		var gi: int = pc[0]
		var c: Dictionary = pc[1]
		ghosts[gi] = c
		var id: StringName = c.id
		if str(c.tag) != "":
			id = &""
			for a in _carried():
				var st := get_slot(a)
				if RecipeBook.takes(c, st):
					id = st.id
					break
		if id != &"":
			_fill_cell(gi, id, int(c.count))
	changed.emit()
	return {"ok": true, "ghosts": ghosts, "left": left}


# ---------------------------------------------------------------------------
# A chest open in the screen

## Borrow `slots` (kept by the chest's owner) under `key`, so the clicks change
## it in place.
func open_chest(key: String, slots: Array, title := "Chest", rules := "") -> void:
	chest_key = key
	chest_slots = slots
	chest_title = title
	chest_rules = rules
	changed.emit()


func close_chest() -> void:
	chest_key = ""
	chest_slots = []
	chest_rules = ""
	changed.emit()


# ---------------------------------------------------------------------------
# Saving

func to_dict() -> Dictionary:
	return {
		# 2: a block's count is plate cells (1: whole bricks, before stage 11).
		"format": 2,
		"hotbar_0": _save_array(hotbars[0]),
		"hotbar_1": _save_array(hotbars[1]),
		"offhand": _save_array(offhands),
		"quick": _save_array(quick),
		"offhand_up": offhand_up,
		# The backpack carries the storage (its contents); "main" was the
		# storage before backpacks (stage 8).
		"backpack": _stack_dict(backpack),
		"active_hotbar": active_hotbar,
		"active_slot": active_slot,
		"active_offhand": active_offhand,
		"creative": creative,
	}


## Back from `to_dict`. Items no pack has any more are dropped. False if `d`
## is not an inventory.
func from_dict(d) -> bool:
	if not (d is Dictionary) or not [1, 2].has(int(d.get("format", 0))):
		return false
	units_in_bricks = int(d.format) == 1
	_load_array(hotbars[0], d.get("hotbar_0", []))
	_load_array(hotbars[1], d.get("hotbar_1", []))
	_load_array(offhands, d.get("offhand", []))
	_load_array(quick, d.get("quick", []))
	quick_out = false
	using_off = false
	offhand_up = bool(d.get("offhand_up", false))
	_load_array(old_craft, d.get("craft", []))
	if d.has("backpack"):
		backpack = _keep_known(ItemStack.from_dict(d.backpack))
		if backpack != null and not is_backpack(backpack):
			backpack = null
		if backpack != null:
			_fit_backpack(backpack)
	else:
		# Saved before backpacks: the old storage goes into the kit's backpack.
		var old := _empty(MAIN_SIZE)
		_load_array(old, d.get("main", []))
		backpack = make_backpack(KIT_BACKPACK, old)
	active_hotbar = clampi(int(d.get("active_hotbar", 0)), 0, 1)
	active_slot = clampi(int(d.get("active_slot", 0)), 0, HOTBAR_SIZE - 1)
	active_offhand = clampi(int(d.get("active_offhand", 0)), 0, OFFHAND_SIZE - 1)
	creative = bool(d.get("creative", true))
	cursor = null
	units_in_bricks = false
	# Items left in the old craft grid (stage 9) go into storage.
	for i in old_craft.size():
		if old_craft[i] != null:
			_insert(old_craft[i], [&"main", hotbar_area(), hotbar_area(1 - active_hotbar)])
			old_craft[i] = null
	changed.emit()
	return true


static func _save_array(a: Array) -> Array:
	var out := []
	for s in a:
		if s == null:
			out.append(null)
		else:
			out.append((s as ItemStack).to_dict())
	return out


static func _stack_dict(s: ItemStack) -> Variant:
	if s == null:
		return null
	return s.to_dict()


## `s` without anything no pack has any more (in it too, a backpack's), or
## null if it is such a thing itself.
## Set while a save from before stage 11 is read: its block counts were
## whole bricks (3 plate cells each). The world's chests and drops set it
## from their own file's format.
static var units_in_bricks := false


static func _keep_known(s: ItemStack) -> ItemStack:
	if s == null:
		return null
	if not ItemCatalog.has(s.id):
		# A block colour folded into a material (stone's granite): the material.
		var f := ItemCatalog.folded_into(s.id)
		if f == &"":
			return null
		s.id = f
	if units_in_bricks and ItemCatalog.kind(s.id) == "block":
		s.count = mini(s.count * 3, ItemCatalog.max_stack(s.id))
	for i in s.contents.size():
		s.contents[i] = _keep_known(s.contents[i])
	return s


static func _load_array(into: Array, from) -> void:
	for i in into.size():
		into[i] = null
		if from is Array and i < from.size():
			into[i] = _keep_known(ItemStack.from_dict(from[i]))
