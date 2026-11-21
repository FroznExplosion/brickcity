extends SceneTree

## The mine world's inventory (Docs/Inventory.md): items, stacks, the clicks
## of the inventory screen, the hands, saving.
##
##     godot --headless --path . --script res://tools/probes/inventory_probe.gd
##
## What each group is for:
##   catalog   every terrain block but air and bedrock is an item, and the
##             base pack's table (data/items, through ContentPacks) adds the
##             buckets, fluids, pickaxe and chest -- what the builder needs.
##   stacks    stacks merge only with their own kind (a bucket's water is part
##             of its kind) and never past the max.
##   clicks    left/right/shift/double click and the drags do what
##             Minecraft's do (zylanntest's rules, Docs/Inventory.md 3.2).
##   hands     the off-hand takes only one-handed items; 1-9/wheel/X choose
##             the hand; pick finds a block or (creative) makes one;
##             survival uses stacks up, creative never does.
##   chest     a borrowed chest array is changed in place by the clicks and
##             shift-click moves between it and the player.
##   save      to_dict / from_dict give the same inventory back.

var _pass := 0
var _fail := 0


func _ok(what: String, cond: bool, detail: String = "") -> void:
	if cond:
		_pass += 1
		print("  ok   %s" % what)
	else:
		_fail += 1
		print("  FAIL %s%s" % [what, (" -- " + detail) if detail else ""])


func _init() -> void:
	print("inventory probe")
	_catalog()
	_stacks()
	_clicks()
	_drags()
	_hands()
	_chest()
	_save()
	_screen_rules()
	_mega_pickaxe()
	_chests_and_drops()
	_character()
	_backpacks()
	print("inventory probe: %d ok, %d failed" % [_pass, _fail])
	quit(1 if _fail > 0 else 0)


## Stage 5 without a world: a chest's slots are the store's and the screen
## borrows them; its save round trip; breaking it drops what it held (and in
## survival the chest); dropped items' own save. (Placing on real ground,
## the shot and the ground going are --gate=inventory's.)
func _chests_and_drops() -> void:
	print("chests and drops")
	var inv := Inventory.new()
	inv.seed_default()
	_ok("the kit has chests (hotbar 2 slot 8)", inv.hotbars[1][7] != null and inv.hotbars[1][7].id == &"chest")
	var drops := DroppedItems.new()
	drops.setup(null, inv)
	var chests := MineChests.new()
	chests.setup(null, inv, drops)
	var b := Vector3i(3, 40, -2)
	_ok("a chest put down (no ground check: forced)", chests.place(b, [], true) and chests.count() == 1)
	var key := MineChests.key_of(b)
	inv.open_chest(key, chests.slots_of(key))
	inv.hotbars[0][0] = ItemStack.make(&"coal_ore", 12)
	inv.shift_click(Inventory.addr(&"hotbar_0", 0))
	_ok("shift click fills the chest's own slots", chests.slots_of(key)[0] != null
			and chests.slots_of(key)[0].id == &"coal_ore")
	inv.close_chest()
	var saved = JSON.parse_string(JSON.stringify(chests.to_save()))
	chests.restore(saved)
	_ok("a chest's contents come back from the save", chests.count() == 1
			and chests.slots_of(key)[0] != null and chests.slots_of(key)[0].count == 12)
	_ok("a chest's box: 2 x 2 studs, 3 plates, its bottom at its plate",
			is_equal_approx(chests.box_of(b).size.x, 2.0 * BrickWorld.get_stud_metres())
			and is_equal_approx(chests.box_of(b).position.y, 40 * BrickWorld.get_plate_metres()))
	_ok("a block in the chest's box is refused", chests.overlaps(chests.box_of(b).grow(-0.1)))
	_ok("a point in the chest is found (a shot)", chests.at_point(chests.box_of(b).get_center()) == key)
	chests.break_chest(key, false)
	_ok("creative: breaking drops what it held, not the chest", chests.count() == 0 and drops.count() == 1
			and (drops.drops[0].stack as ItemStack).id == &"coal_ore")
	chests.place(b, [], true)
	chests.break_chest(key, true)
	_ok("survival: an empty chest drops itself", drops.count() == 2
			and (drops.drops[1].stack as ItemStack).id == &"chest")
	var dsave = JSON.parse_string(JSON.stringify(drops.to_save()))
	drops.restore(dsave)
	_ok("dropped items come back from the save", drops.count() == 2
			and (drops.drops[0].stack as ItemStack).count == 12)
	drops.clear()
	chests.clear()
	for n in drops.get_children() + chests.get_children():
		n.free()
	drops.free()
	chests.free()


## The screen's own helpers (stage 3): 1-9 over a slot, the held stack put
## back on Escape or close.
func _screen_rules() -> void:
	print("screen")
	var inv := Inventory.new()
	inv.main[2] = ItemStack.make(&"clay", 7)
	inv.hotbars[0][4] = ItemStack.make(&"ice", 3)
	inv.swap_with_hotbar(A(&"main", 2), 4)
	_ok("5 over a storage slot swaps it with hotbar slot 5", inv.hotbars[0][4].id == &"clay"
			and inv.main[2].id == &"ice")
	inv.offhands[0] = ItemStack.make(&"pickaxe", 1)
	inv.swap_with_hotbar(A(&"offhand", 0), 4)
	_ok("... never a block into the off-hand", inv.offhands[0].id == &"pickaxe" and inv.hotbars[0][4].id == &"clay")
	inv.cursor = ItemStack.make(&"ice", 5)
	_ok("the held stack goes back, onto its own kind first", inv.return_cursor() and inv.cursor == null
			and inv.main[2].count == 8)
	for i in inv.main.size():
		inv.main[i] = ItemStack.make(&"obsidian", 64)
	for b in 2:
		for i in Inventory.HOTBAR_SIZE:
			inv.hotbars[b][i] = ItemStack.make(&"obsidian", 64)
	inv.offhands[1] = ItemStack.make(&"pickaxe", 1)
	inv.cursor = ItemStack.make(&"snow", 2)
	_ok("no room: it stays on the cursor", not inv.return_cursor() and inv.cursor != null)
## The Mega Pickaxe (2026-11-19): in the kit right after the pickaxe, and put
## into a save made before it existed -- once.
func _mega_pickaxe() -> void:
	var inv := Inventory.new()
	inv.seed_default()
	var at := -1
	for i in Inventory.HOTBAR_SIZE - 1:
		var s: ItemStack = inv.hotbars[1][i]
		if s != null and s.id == &"pickaxe":
			var n: ItemStack = inv.hotbars[1][i + 1]
			at = i + 1 if n != null and n.id == &"mega_pickaxe" else -2
	_ok("the Mega Pickaxe is in the kit right after the pickaxe", at >= 0, "slot %d" % at)
	var d: Dictionary = ItemCatalog.get_def(&"mega_pickaxe")
	_ok("it breaks 5 across, faster than the pickaxe", int(d.get("break_area", 1)) == 5
			and float(d.get("break_repeat", 1.0)) < 0.22, str(d))
	for i in Inventory.HOTBAR_SIZE:
		var s: ItemStack = inv.hotbars[1][i]
		if s != null and s.id == &"mega_pickaxe":
			inv.hotbars[1][i] = null
	var added := inv.ensure_item(&"mega_pickaxe", &"pickaxe")
	var again := inv.ensure_item(&"mega_pickaxe", &"pickaxe")
	_ok("an old save gets it once", added and not again, "added %s, again %s" % [added, again])


static func A(area: StringName, i := 0) -> Dictionary:
	return Inventory.addr(area, i)


func _catalog() -> void:
	print("catalog")
	ItemCatalog.load_all(true)
	var names: PackedStringArray = BrickTerrain.material_names()
	var blocks := 0
	for m in names.size():
		if ItemCatalog.block_item(m) != &"":
			blocks += 1
	_ok("every material but air and bedrock is a block item", blocks == names.size() - 2,
			"%d of %d" % [blocks, names.size()])
	_ok("air and bedrock are not items", not ItemCatalog.has(&"air") and not ItemCatalog.has(&"bedrock"))
	var ds := ItemCatalog.get_def(&"dark_stone")
	_ok("dark_stone places 'dark stone'", ds.get("material", -1) == Array(names).find("dark stone"))
	for id in [&"bucket", &"source_bucket", &"water_source", &"water_brick", &"lava_source", &"pickaxe", &"chest"]:
		_ok("pack item %s" % id, ItemCatalog.has(id), str(ContentPacks.files("data/items")))
	_ok("lava source pours lava", int(ItemCatalog.get_def(&"lava_source").fluid) == 2)
	_ok("buckets do not stack", ItemCatalog.max_stack(&"bucket") == 1)
	_ok("blocks are right-hand only", ItemCatalog.get_def(&"stone").hand == "right")


func _stacks() -> void:
	print("stacks")
	var inv := Inventory.new()
	inv.main[0] = ItemStack.make(&"stone", 60)
	inv.cursor = ItemStack.make(&"stone", 10)
	inv.left_click(A(&"main", 0))
	_ok("merge stops at 64, the rest stays on the cursor",
			inv.main[0].count == 64 and inv.cursor != null and inv.cursor.count == 6)
	var full := ItemStack.make(&"bucket", 1, {"tiles": 9})
	var empty := ItemStack.make(&"bucket", 1)
	_ok("a full bucket is not the same kind as an empty one", not full.same_kind(empty))
	var s := ItemStack.from_dict(full.to_dict())
	_ok("a stack's data comes back from a dict", s.same_kind(full) and s.count == 1)


func _clicks() -> void:
	print("clicks")
	var inv := Inventory.new()
	inv.main[0] = ItemStack.make(&"dirt", 11)
	inv.right_click(A(&"main", 0))
	_ok("right click on a stack picks up half, rounded up", inv.cursor.count == 6 and inv.main[0].count == 5)
	inv.right_click(A(&"main", 1))
	_ok("right click with a stack puts down one", inv.main[1].count == 1 and inv.cursor.count == 5)
	inv.right_click(A(&"main", 1))
	_ok("... and one more onto the same item", inv.main[1].count == 2 and inv.cursor.count == 4)
	inv.left_click(A(&"main", 2))
	_ok("left click puts the cursor stack down", inv.cursor == null and inv.main[2].count == 4)
	inv.main[3] = ItemStack.make(&"sand", 3)
	inv.left_click(A(&"main", 3))
	inv.left_click(A(&"main", 2))
	_ok("left click on another item swaps", inv.main[2].id == &"sand" and inv.cursor.id == &"dirt"
			and inv.cursor.count == 4)
	inv.cursor = null
	inv.double_click(A(&"main", 0))
	_ok("double click gathers every dirt into the cursor", inv.cursor != null and inv.cursor.count == 7
			and inv.main[0] == null and inv.main[1] == null)
	inv.cursor = null
	inv.main[5] = ItemStack.make(&"gravel", 20)
	inv.shift_click(A(&"main", 5))
	_ok("shift click from main goes to the active hotbar", inv.main[5] == null
			and inv.hotbars[0][0] != null and inv.hotbars[0][0].id == &"gravel")
	inv.shift_click(A(&"hotbar_0", 0))
	_ok("shift click from a hotbar goes back to main", inv.hotbars[0][0] == null
			and inv.main[0] != null and inv.main[0].id == &"gravel")


func _drags() -> void:
	print("drags")
	var inv := Inventory.new()
	inv.cursor = ItemStack.make(&"stone", 10)
	inv.begin_drag(MOUSE_BUTTON_LEFT)
	for i in 3:
		inv.drag_touch(A(&"main", i))
	_ok("the preview shows 3 a slot", inv.drag_amount_for(A(&"main", 1)) == 3)
	inv.finish_drag()
	_ok("left drag spreads 10 over 3 slots: 3 each, 1 left",
			inv.main[0].count == 3 and inv.main[2].count == 3 and inv.cursor.count == 1)
	inv.cursor = ItemStack.make(&"sand", 5)
	inv.begin_drag(MOUSE_BUTTON_RIGHT)
	for i in [3, 4, 0]:
		inv.drag_touch(A(&"main", i))     # 0 holds stone: skipped
	inv.finish_drag()
	_ok("right drag puts one in each, never onto another item",
			inv.main[3].count == 1 and inv.main[4].count == 1 and inv.main[0].id == &"stone" and inv.cursor.count == 3)


func _hands() -> void:
	print("hands")
	var inv := Inventory.new()
	inv.seed_default()
	_ok("the kit: blocks on bar 1, the bucket on bar 2", inv.hand() != null and inv.hand().id == &"grass"
			and inv.hotbars[1][0] != null and inv.hotbars[1][0].id == &"bucket")
	inv.cursor = ItemStack.make(&"stone", 1)
	inv.left_click(A(&"offhand", 0))
	_ok("a block does not go in the off-hand", inv.offhands[0] == null and inv.cursor != null)
	inv.cursor = ItemStack.make(&"pickaxe", 1)
	inv.left_click(A(&"offhand", 0))
	_ok("a one-handed tool does", inv.offhands[0] != null and inv.cursor == null)
	inv.select_slot(3)
	inv.scroll(-4)
	_ok("the wheel wraps round the bar", inv.active_slot == 8)
	inv.toggle_hotbar()
	_ok("X: the other bar is in the hand", inv.active_hotbar == 1 and inv.hand() == inv.hotbars[1][8])
	_ok("select_item finds the bucket on bar 2", inv.select_item(&"bucket") and inv.hand().id == &"bucket")
	_ok("select_item switches back to bar 1 for sand", inv.select_item(&"sand") and inv.active_hotbar == 0
			and inv.hand().id == &"sand")
	inv.select_slot(8)
	var old := inv.hand()
	_ok("pick (creative): a block on no bar comes into the hand", inv.pick(&"granite")
			and inv.hand().id == &"granite" and inv.hand().count == 64)
	_ok("... and the old stack went to storage", inv.main.has(old))
	var n := inv.hand().count
	_ok("creative: placing uses nothing up", inv.consume_hand(4) and inv.hand().count == n)
	inv.creative = false
	inv.consume_hand(4)
	_ok("survival: placing uses the stack up", inv.hand().count == n - 4)
	_ok("survival: pick of a block you have none of does nothing", not inv.pick(&"obsidian"))
	inv.hotbars[0][8] = ItemStack.make(&"granite", 2)
	_ok("survival: not enough for a block", not inv.consume_hand(4) and inv.hand().count == 2)
	var left := inv.add_item(ItemStack.make(&"granite", 10))
	_ok("add_item tops up the hand's stack first", left == null and inv.hand().count == 12)


func _chest() -> void:
	print("chest")
	var inv := Inventory.new()
	var slots := Inventory._empty(Inventory.CHEST_SIZE)
	slots[0] = ItemStack.make(&"coal_ore", 5)
	inv.open_chest("1,2,3", slots)
	inv.shift_click(A(&"chest", 0))
	_ok("shift click out of a chest goes to the player", slots[0] == null
			and inv.hotbars[0][0] != null and inv.hotbars[0][0].id == &"coal_ore")
	inv.shift_click(A(&"hotbar_0", 0))
	_ok("shift click from the player goes into the open chest", slots[0] != null and slots[0].count == 5)
	inv.close_chest()
	_ok("closed: the chest is no area", inv.area_size(&"chest") == 0 and slots[0] != null)


func _save() -> void:
	print("save")
	var inv := Inventory.new()
	inv.seed_default()
	inv.hotbars[1][0].data = {"tiles": 6}
	inv.main[4] = ItemStack.make(&"chest", 3)
	inv.toggle_hotbar()
	inv.select_slot(5)
	inv.creative = false
	var text := JSON.stringify(inv.to_dict())
	var back := Inventory.new()
	_ok("from_dict takes the saved text", back.from_dict(JSON.parse_string(text)))
	_ok("same hand, bar and mode", back.active_hotbar == 1 and back.active_slot == 5 and not back.creative)
	_ok("the bucket kept its water (JSON numbers come back as floats)",
			int(back.hotbars[1][0].data.get("tiles", 0)) == 6)
	_ok("storage kept its chests", back.main[4] != null and back.main[4].id == &"chest" and back.main[4].count == 3)
	_ok("blocks came back", back.hotbars[0][3] != null and back.hotbars[0][3].id == &"dark_stone")
	var d := inv.to_dict()
	d["backpack"]["contents"][6] = {"id": "no_such_item", "count": 1}
	back.from_dict(d)
	_ok("an item no pack has any more is left out (in the backpack too)", back.main[6] == null
			and back.main[4] != null)


## Stage 6: the inventory is the character's -- it rides in CharacterSave,
## and a save that only changes another field (PlayerKit's way: read, change
## its own, write) keeps it.
func _character() -> void:
	print("character")
	var path := UserPaths.DEV + "_probe_character.json"
	if FileAccess.file_exists(path):
		DirAccess.remove_absolute(path)
	var inv := Inventory.new()
	inv.seed_default()
	inv.hotbars[1][8] = ItemStack.make(&"obsidian", 5)
	var s := CharacterSave.load_from(path)
	s.items = inv.to_dict()
	DirAccess.make_dir_recursive_absolute(path.get_base_dir())
	s.save(path)
	var k := CharacterSave.load_from(path)
	k.character["level"] = 7
	k.save(path)
	var back := Inventory.new()
	_ok("the inventory comes back from the character file", back.from_dict(CharacterSave.load_from(path).items)
			and back.hotbars[1][8] != null and back.hotbars[1][8].id == &"obsidian" and back.hotbars[1][8].count == 5)
	_ok("... after a save that changed only the level", int(CharacterSave.load_from(path).character.level) == 7)
	DirAccess.remove_absolute(path)
	_ok("no character file: no items (the starting kit)", not Inventory.new().from_dict(CharacterSave.load_from(path).items))


## Stage 8: backpacks (zylanntest's). The worn backpack's contents are the
## storage; its stack carries them wherever it goes.
func _backpacks() -> void:
	print("backpacks")
	var inv := Inventory.new()
	_ok("a new inventory wears a Large backpack: 27 storage slots", inv.backpack != null
			and inv.backpack.id == &"large_backpack" and inv.area_size(&"main") == 27)
	inv.main[0] = ItemStack.make(&"coal_ore", 9)
	inv.left_click(A(&"backpack"))
	_ok("taken off: onto the cursor, and no storage", inv.cursor != null and inv.cursor.id == &"large_backpack"
			and inv.backpack == null and inv.area_size(&"main") == 0)
	_ok("... its contents went with it", inv.cursor.contents[0] != null and inv.cursor.contents[0].id == &"coal_ore")
	inv.left_click(A(&"hotbar_0", 0))
	_ok("a backpack can be held in a hotbar slot", inv.hotbars[0][0] != null and inv.hotbars[0][0].id == &"large_backpack")
	inv.cursor = ItemStack.make(&"stone", 1)
	inv.left_click(A(&"backpack"))
	_ok("the backpack slot takes only backpacks", inv.backpack == null and inv.cursor.id == &"stone")
	inv.cursor = null
	inv.shift_click(A(&"hotbar_0", 0))
	_ok("shift click puts a backpack on (none worn)", inv.backpack != null and inv.hotbars[0][0] == null
			and inv.main[0] != null and inv.main[0].id == &"coal_ore")
	var small := Inventory.make_backpack(&"small_backpack")
	_ok("a Small backpack has 9 slots", small.contents.size() == 9)
	inv.cursor = small
	inv.left_click(A(&"backpack"))
	_ok("a small one swapped on: 9 storage slots, the large one held", inv.area_size(&"main") == 9
			and inv.cursor != null and inv.cursor.id == &"large_backpack")
	inv.left_click(A(&"main", 0))
	_ok("a backpack inside the worn backpack, with its own contents", inv.main[0] != null
			and inv.main[0].contents[0] != null and inv.main[0].contents[0].id == &"coal_ore")
	var back := Inventory.new()
	back.from_dict(JSON.parse_string(JSON.stringify(inv.to_dict())))
	_ok("save round trip: the small one worn, the large one in it, its coal in that",
			back.backpack.id == &"small_backpack" and back.main[0] != null and back.main[0].id == &"large_backpack"
			and back.main[0].contents.size() == 27 and back.main[0].contents[0].count == 9)
	var old := {"format": 1, "hotbar_0": [], "hotbar_1": [], "offhand": [], "main": [{"id": "clay", "count": 4}]}
	var o := Inventory.new()
	o.from_dict(old)
	_ok("a save from before backpacks: its storage in a Large backpack", o.backpack.id == &"large_backpack"
			and o.main[0] != null and o.main[0].id == &"clay")
	var none := Inventory.new()
	none.backpack = null
	var left := none.add_item(Inventory.make_backpack(&"medium_backpack"))
	_ok("picked up with none worn: it is put on (18 slots)", left == null and none.area_size(&"main") == 18)
	_ok("a backpack never stacks", not Inventory.make_backpack(&"small_backpack").same_kind(Inventory.make_backpack(&"small_backpack")))
