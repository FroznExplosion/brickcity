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
##   main                 MAIN_SIZE
##   chest                the open chest's slots (borrowed array, see open_chest)
## All the rules go through get_slot / set_slot / slot_accepts, so the UI only
## sends addresses and redraws on `changed`.
##
## A plain object the mine world owns, not an autoload: nothing else uses it yet.

signal changed
signal active_changed

const HOTBAR_SIZE := 9
const OFFHAND_SIZE := 2
const MAIN_SIZE := 27
const CHEST_SIZE := 27
## X held this long swaps the off-hand instead of the hotbar.
const HOLD_MS := 350

var hotbars: Array = [[], []]
var offhands: Array = [null, null]
var main: Array = []
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

var _drag_active := false
var _drag_button := -1
var _drag_touched: Array = []


func _init() -> void:
	hotbars[0] = _empty(HOTBAR_SIZE)
	hotbars[1] = _empty(HOTBAR_SIZE)
	main = _empty(MAIN_SIZE)


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
	var blocks := ["grass", "dirt", "stone", "dark_stone", "sand", "sandstone", "gravel", "snow", "terracotta"]
	for i in blocks.size():
		var id := StringName(blocks[i])
		if ItemCatalog.has(id):
			hotbars[0][i] = ItemStack.make(id, ItemCatalog.max_stack(id))
	var bar2 := ["bucket", "source_bucket", "water_source", "water_brick", "lava_source", "pickaxe"]
	for i in bar2.size():
		var id := StringName(bar2[i])
		if ItemCatalog.has(id):
			hotbars[1][i] = ItemStack.make(id, ItemCatalog.max_stack(id))
	changed.emit()


# ---------------------------------------------------------------------------
# Slots

func get_slot(a: Dictionary) -> ItemStack:
	var arr := _array(a.area)
	var i: int = a.index
	return arr[i] if i >= 0 and i < arr.size() else null


func set_slot(a: Dictionary, s: ItemStack) -> void:
	var arr := _array(a.area)
	var i: int = a.index
	if i >= 0 and i < arr.size():
		arr[i] = null if s == null or s.is_empty() else s


func _array(area: StringName) -> Array:
	match area:
		&"hotbar_0": return hotbars[0]
		&"hotbar_1": return hotbars[1]
		&"offhand": return offhands
		&"main": return main
		&"chest": return chest_slots
	return []


func area_size(area: StringName) -> int:
	return _array(area).size()


## May `s` go in slot `a`? Storage takes anything; the hands go by the item's
## `hand`: the off-hand takes one-handed ("any") and off-hand-only items, the
## hotbars everything but off-hand-only.
func slot_accepts(a: Dictionary, s: ItemStack) -> bool:
	if s == null:
		return true
	var d := ItemCatalog.get_def(s.id)
	if d.is_empty():
		return false
	match a.area:
		&"offhand":
			return d.hand == "any" or d.hand == "off"
		&"hotbar_0", &"hotbar_1":
			return d.hand != "off"
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
		elif s.same_kind(cursor) and s.count < ItemCatalog.max_stack(s.id):
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
	var targets: Array = []
	if not chest_key.is_empty() and a.area == &"chest":
		targets = [hotbar_area(), hotbar_area(1 - active_hotbar), &"main"]
	elif not chest_key.is_empty():
		targets = [&"chest"]
	elif a.area == &"main":
		targets = [hotbar_area(), hotbar_area(1 - active_hotbar), &"offhand"]
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


func all_addrs() -> Array:
	var out: Array = []
	for area in [&"hotbar_0", &"hotbar_1", &"offhand", &"main", &"chest"]:
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

## Put `s` into the player's storage: the active hotbar, the other, the
## off-hand, main -- same items first, then empty slots. What did not fit, or null.
func add_item(s: ItemStack) -> ItemStack:
	if s == null or s.is_empty():
		return null
	var left := _insert(s, [hotbar_area(), hotbar_area(1 - active_hotbar), &"offhand", &"main"])
	changed.emit()
	return left


func _insert(s: ItemStack, areas: Array) -> ItemStack:
	for area in areas:
		for i in area_size(area):
			var t := get_slot(addr(area, i))
			if t != null and t.same_kind(s):
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


func hand_addr() -> Dictionary:
	return addr(hotbar_area(), active_slot)


## What is in the hand: the active hotbar's selected slot.
func hand() -> ItemStack:
	return hotbars[active_hotbar][active_slot]


## The off-hand, or null while a two-handed item is in the hand.
func offhand() -> ItemStack:
	var h := hand()
	if h != null and ItemCatalog.get_def(h.id).get("hand", "") == "two":
		return null
	return offhands[active_offhand]


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
		hotbars[active_hotbar][active_slot] = null
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


## The cursor stack back into storage (the screen closing). False if some did
## not fit (it is kept on the cursor).
func return_cursor() -> bool:
	if cursor == null:
		return true
	cursor = _insert(cursor, [&"main", hotbar_area(), hotbar_area(1 - active_hotbar), &"offhand"])
	changed.emit()
	return cursor == null


func toggle_hotbar() -> void:
	active_hotbar = 1 - active_hotbar
	active_changed.emit()
	changed.emit()


func toggle_offhand() -> void:
	active_offhand = 1 - active_offhand
	active_changed.emit()
	changed.emit()


func select_slot(i: int) -> void:
	i = clampi(i, 0, HOTBAR_SIZE - 1)
	if i == active_slot:
		return
	active_slot = i
	active_changed.emit()
	changed.emit()


func scroll(step: int) -> void:
	select_slot(posmod(active_slot + step, HOTBAR_SIZE))


## Find an item in the hotbars (the active one first) and put it in the hand.
## False if neither has it.
func select_item(id: StringName) -> bool:
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
	var old := hand()
	hotbars[active_hotbar][active_slot] = ItemStack.make(id, ItemCatalog.max_stack(id))
	if old != null:
		_insert(old, [&"main"])
	changed.emit()
	return true


# ---------------------------------------------------------------------------
# A chest open in the screen

## Borrow `slots` (kept by the chest's owner) under `key`, so the clicks change
## it in place.
func open_chest(key: String, slots: Array) -> void:
	chest_key = key
	chest_slots = slots
	changed.emit()


func close_chest() -> void:
	chest_key = ""
	chest_slots = []
	changed.emit()


# ---------------------------------------------------------------------------
# Saving

func to_dict() -> Dictionary:
	return {
		"format": 1,
		"hotbar_0": _save_array(hotbars[0]),
		"hotbar_1": _save_array(hotbars[1]),
		"offhand": _save_array(offhands),
		"main": _save_array(main),
		"active_hotbar": active_hotbar,
		"active_slot": active_slot,
		"active_offhand": active_offhand,
		"creative": creative,
	}


## Back from `to_dict`. Items no pack has any more are dropped. False if `d`
## is not an inventory.
func from_dict(d) -> bool:
	if not (d is Dictionary) or int(d.get("format", 0)) != 1:
		return false
	_load_array(hotbars[0], d.get("hotbar_0", []))
	_load_array(hotbars[1], d.get("hotbar_1", []))
	_load_array(offhands, d.get("offhand", []))
	_load_array(main, d.get("main", []))
	active_hotbar = clampi(int(d.get("active_hotbar", 0)), 0, 1)
	active_slot = clampi(int(d.get("active_slot", 0)), 0, HOTBAR_SIZE - 1)
	active_offhand = clampi(int(d.get("active_offhand", 0)), 0, OFFHAND_SIZE - 1)
	creative = bool(d.get("creative", true))
	cursor = null
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


static func _load_array(into: Array, from) -> void:
	for i in into.size():
		into[i] = null
		if from is Array and i < from.size():
			var s := ItemStack.from_dict(from[i])
			if s != null and ItemCatalog.has(s.id):
				into[i] = s
