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
##   wood      wood and leaves (Docs/Inventory.md 13): material families of
##             their own colours, every colour floats and burns, a felled
##             tree's yield in plate cells, its boxes, the wood recipes, the
##             felled set's save shape. (Felling a real tree in survival is
##             --gate=inventory's.)

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
	_crafting()
	_wood_and_leaves()
	_guns()
	_placed_backpacks()
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
	var ds := ItemCatalog.get_def(&"stone")
	_ok("the stone material lays dark stone and granite too (stage 11)",
			PackedInt32Array(ds.get("colours", [])).has(Array(names).find("dark stone"))
			and PackedInt32Array(ds.get("colours", [])).has(Array(names).find("granite")))
	_ok("granite is folded into stone, grass into soil", not ItemCatalog.has(&"granite")
			and ItemCatalog.folded_into(&"granite") == &"stone" and ItemCatalog.folded_into(&"grass") == &"soil"
			and ItemCatalog.block_item(Array(names).find("dark grass")) == &"soil")
	_ok("a material stacks to 999 plate cells", ItemCatalog.max_stack(&"stone") == 999)
	for id in [&"bucket", &"source_bucket", &"water_source", &"water_brick", &"lava_source", &"pickaxe", &"chest"]:
		_ok("pack item %s" % id, ItemCatalog.has(id), str(ContentPacks.files("data/items")))
	_ok("lava source pours lava", int(ItemCatalog.get_def(&"lava_source").fluid) == 2)
	_ok("buckets do not stack", ItemCatalog.max_stack(&"bucket") == 1)
	_ok("blocks are right-hand only", ItemCatalog.get_def(&"stone").hand == "right")


func _stacks() -> void:
	print("stacks")
	var inv := Inventory.new()
	inv.main[0] = ItemStack.make(&"chest", 60)
	inv.cursor = ItemStack.make(&"chest", 10)
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
	inv.main[0] = ItemStack.make(&"soil", 11)
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
	_ok("left click on another item swaps", inv.main[2].id == &"sand" and inv.cursor.id == &"soil"
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
	_ok("the kit: materials on bar 1, the bucket on bar 2", inv.hand() != null and inv.hand().id == &"soil"
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
	_ok("pick (creative): a block on no bar comes into the hand", inv.pick(&"coal_ore")
			and inv.hand().id == &"coal_ore" and inv.hand().count == 999)
	_ok("... and the old stack went to storage", inv.main.has(old))
	var n := inv.hand().count
	_ok("creative: placing uses nothing up", inv.consume_hand(4) and inv.hand().count == n)
	inv.creative = false
	inv.consume_hand(4)
	_ok("survival: placing uses the stack up", inv.hand().count == n - 4)
	_ok("survival: pick of a block you have none of does nothing", not inv.pick(&"diamond_ore"))
	inv.hotbars[0][8] = ItemStack.make(&"coal_ore", 2)
	_ok("survival: not enough for a block", not inv.consume_hand(4) and inv.hand().count == 2)
	var left := inv.add_item(ItemStack.make(&"coal_ore", 10))
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
	_ok("blocks came back", back.hotbars[0][3] != null and back.hotbars[0][3].id == &"snow")
	var old := {"format": 1, "hotbar_0": [{"id": "granite", "count": 10}, {"id": "sand", "count": 4}],
			"hotbar_1": [], "offhand": []}
	var o := Inventory.new()
	o.from_dict(old)
	_ok("a save from before stage 11: granite is stone, bricks are plate cells (10 -> 30, 4 -> 12)",
			o.hotbars[0][0] != null and o.hotbars[0][0].id == &"stone" and o.hotbars[0][0].count == 30
			and o.hotbars[0][1] != null and o.hotbars[0][1].count == 12 and not Inventory.units_in_bricks)
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


## Stage 12: crafting, Terraria's -- what a recipe takes, where it is made,
## from what is carried (data/recipes; the stage 9 grid went).
func _crafting() -> void:
	print("crafting")
	RecipeBook.load_all(true)
	_ok("the base pack's recipes load", RecipeBook.all().size() >= 12, str(RecipeBook.all().size()))
	var by := {}
	for r in RecipeBook.all():
		by[r.name] = r
	var inv := Inventory.new()
	for b in 2:
		for i in Inventory.HOTBAR_SIZE:
			inv.hotbars[b][i] = null
	inv.main[0] = ItemStack.make(&"stone", 40)
	_ok("gravel by hand: can be made with 40 stone", inv.can_craft(by["Gravel"], []))
	var res := inv.craft(by["Gravel"], [])
	_ok("made: 12 stone used, 12 gravel given", res.made == 1 and inv.count_of({"id": &"stone", "tag": "", "count": 1}) == 28
			and inv.count_of({"id": &"gravel", "tag": "", "count": 1}) == 12)
	_ok("a chest needs a workbench near", not inv.can_craft(by["Chest"], [])
			and inv.missing(by["Chest"], []).has("a workbench near"))
	inv.main[2] = ItemStack.make(&"wood", 40)
	_ok("... and 96 wood (section 13): with only 40, 56 more", not inv.can_craft(by["Chest"], [&"workbench"])
			and inv.missing(by["Chest"], [&"workbench"]).has("56 more Wood"),
			str(inv.missing(by["Chest"], [&"workbench"])))
	inv.main[3] = ItemStack.make(&"wood", 60)
	inv.main[1] = ItemStack.make(&"stone", 52)
	_ok("with the wood and a workbench near: a chest", inv.craft(by["Chest"], [&"workbench"]).made == 1
			and inv.count_of({"id": &"chest", "tag": "", "count": 1}) == 1
			and inv.count_of({"id": &"wood", "tag": "", "count": 1}) == 4)
	var all_res := inv.craft(by["Gravel"], [], true)
	_ok("All: as many as the stone makes (80 left -> 6)", all_res.made == 6
			and inv.count_of({"id": &"stone", "tag": "", "count": 1}) == 8)
	var small := Inventory.make_backpack(&"small_backpack")
	small.contents[3] = ItemStack.make(&"coal_ore", 7)
	inv.main[5] = small
	inv.main[6] = ItemStack.make(&"iron_ore", 40)
	var up := inv.craft(by["Medium Backpack"], [&"workbench"])
	var med: ItemStack = null
	for a2 in inv.all_addrs():
		var s := inv.get_slot(a2)
		if s != null and s.id == &"medium_backpack":
			med = s
	_ok("a Medium backpack from a Small one keeps its contents, 18 slots", up.made == 1 and med != null
			and med.contents.size() == 18 and med.contents[3] != null and med.contents[3].count == 7)
	_ok("... the Small one used up", inv.count_of({"id": &"small_backpack", "tag": "", "count": 1}) == 0)
	var old := {"format": 2, "hotbar_0": [], "hotbar_1": [], "offhand": [], "craft": [{"id": "clay", "count": 5}]}
	var o := Inventory.new()
	o.from_dict(old)
	_ok("an old save's craft grid goes into storage", o.count_of({"id": &"clay", "tag": "", "count": 1}) == 5)
	var drops := DroppedItems.new()
	drops.setup(null, inv)
	var chests := MineChests.new()
	chests.setup(null, inv, drops)
	chests.place(Vector3i(0, 10, 0), [], true, &"workbench")
	chests.place(Vector3i(5, 10, 0), [], true, &"chest")
	var at := chests.box_of(Vector3i(0, 10, 0)).get_center()
	_ok("a placed workbench is a station in reach; a chest is not", chests.stations_near(at) == [&"workbench"])
	_ok("... and out of reach 10 m away", chests.stations_near(at + Vector3(10, 0, 0)).is_empty())
	var back := MineChests.new()
	back.setup(null, inv, drops)
	back.restore(JSON.parse_string(JSON.stringify(chests.to_save())))
	_ok("saved and back: the workbench and the chest", back.count() == 2
			and back.item_of(MineChests.key_of(Vector3i(0, 10, 0))) == &"workbench")
	chests.break_chest(MineChests.key_of(Vector3i(0, 10, 0)), true)
	_ok("broken (survival): it drops a workbench", drops.count() == 1 and (drops.drops[0].stack as ItemStack).id == &"workbench")
	for x in [drops, chests, back]:
		for n in x.get_children():
			n.free()
	drops.clear()
	chests.clear()
	back.clear()
	drops.free()
	chests.free()
	back.free()


## Section 13: wood and leaves, the materials and what a tree gives.
func _wood_and_leaves() -> void:
	print("wood and leaves")
	ItemCatalog.load_all(true)
	var names := Array(BrickTerrain.material_names())
	var fam := {&"wood": ["wood", "pale wood", "birch wood"],
			&"leaves": ["leaves", "light leaves", "autumn leaves", "red leaves"]}
	for id in fam:
		var d := ItemCatalog.get_def(id)
		var cols := PackedInt32Array(d.get("colours", []))
		var all_in := true
		for n in fam[id]:
			var m := names.find(n)
			all_in = all_in and m > 0 and cols.has(m) and ItemCatalog.block_item(m) == id
		_ok("%s is a material of its colours %s" % [id, fam[id]], d.get("kind", "") == "block"
				and cols.size() == (fam[id] as Array).size() and all_in, str(cols))
	_ok("pale wood folds into wood, autumn leaves into leaves", not ItemCatalog.has(&"pale_wood")
			and ItemCatalog.folded_into(&"pale_wood") == &"wood"
			and ItemCatalog.folded_into(&"autumn_leaves") == &"leaves")
	# Each colour a filament no other ground material uses: a thrown brick's
	# colour says what it is (floaters.gd material_of_colour).
	var unique := true
	for n in fam[&"wood"] + fam[&"leaves"]:
		var f := BrickTerrain.material_filament_index(names.find(n))
		for m in names.size():
			if names[m] != n and BrickTerrain.material_filament_index(m) == f:
				unique = false
				print("    %s shares filament %d with %s" % [n, f, names[m]])
	_ok("every wood and leaf colour has a filament of its own", unique)
	var fl = load("res://scripts/water/floaters.gd")
	_ok("every colour floats: birch wood, red leaves", fl.density_of("birch wood") < 1.0
			and fl.density_of("red leaves") < 1.0 and fl.density_of("stone") > 1.0)
	var y := Trees.yield_cells(0)
	_ok("a felled tree gives its trunk as wood (7 round 2x2 = 84) and its canopy as leaves",
			int(y.wood) == int(Trees.TRUNK_HEIGHTS[0]) * 12 and int(y.leaves) > 100, str(y))
	var bx := Trees.boxes(0)
	var stud := BrickWorld.get_stud_metres()
	_ok("its trunk box is 2 studs across, the canopy box over it and wider",
			absf((bx[0] as AABB).size.x - 2.0 * stud) < 1e-4
			and (bx[1] as AABB).position.y >= (bx[0] as AABB).end.y - 1e-4
			and (bx[1] as AABB).size.x > (bx[0] as AABB).size.x, str(bx))
	RecipeBook.load_all(true)
	var by := {}
	for r in RecipeBook.all():
		by[r.name] = r
	var wb_wood := false
	for inp in by["Workbench"].inputs:
		wb_wood = wb_wood or (inp.id == &"wood" and int(inp.count) == 48)
	_ok("a workbench is made from 48 wood", wb_wood and (by["Workbench"].inputs as Array).size() == 1)
	var inv := Inventory.new()
	for b in 2:
		for i in Inventory.HOTBAR_SIZE:
			inv.hotbars[b][i] = null
	inv.main[0] = ItemStack.make(&"wood", 50)
	_ok("... by hand, from a felled tree's wood", inv.craft(by["Workbench"], []).made == 1
			and inv.count_of({"id": &"workbench", "tag": "", "count": 1}) == 1)
	var tt := TerrainTrees.new()
	tt.set_felled([[30, -4], [12, 7]])
	_ok("the felled trees' save shape round-trips, sorted", tt.felled_list() == [[12, 7], [30, -4]]
			and tt.fell(Vector2i(1, 1)) == -1 and tt.felled.has(Vector2i(1, 1)), str(tt.felled_list()))
	tt.free()


## Stage 10: a gun is an item -- the stack's data makes the same gun again.
func _guns() -> void:
	print("guns")
	_ok("a gun item a weapon class", ItemCatalog.has(&"gun_rifle") and ItemCatalog.kind(&"gun_pistol") == "gun")
	var lib := GunPlaceholderParts.build_library()
	var res := GunGenerator.generate(lib, 4242, WeaponClass.rolled(&"rifle", 4242), 2)
	var g := GunInstance.from_result(res)
	var s := MineHands.stack_of(g, 17)
	_ok("a rifle's stack: gun_rifle, its name, its rounds", s.id == &"gun_rifle" and s.data.get("name") == g.gun_name
			and int(s.data.get("ammo")) == 17)
	var back := ItemStack.from_dict(JSON.parse_string(JSON.stringify(s.to_dict())))
	var again := CharacterSave.make_gun(back.data, lib)
	_ok("saved and made again: the same gun (seed, name, tier)", again != null and again.gun_seed == g.gun_seed
			and again.gun_name == g.gun_name and again.tier == g.tier)
	_ok("guns never stack", not s.same_kind(MineHands.stack_of(g)) or ItemCatalog.max_stack(&"gun_rifle") == 1)
	var inv := Inventory.new()
	var hands := MineHands.new()
	hands.library = lib
	_ok("no guns carried: a rifle and a pistol are given", hands.ensure_guns(inv, {}))
	var n := 0
	for a in inv.all_addrs():
		if MineHands.is_gun(inv.get_slot(a)):
			n += 1
	_ok("... two of them", n == 2)
	_ok("... and not again once there are some", not hands.ensure_guns(inv, {}))
	g.free()
	again.free()
	hands.free()


## A backpack put down (zylanntest's): a container whose slots are its own
## contents; broken, it falls as itself with them; picked up, nothing drops.
func _placed_backpacks() -> void:
	print("placed backpacks")
	var inv := Inventory.new()
	var drops := DroppedItems.new()
	drops.setup(null, inv)
	var chests := MineChests.new()
	chests.setup(null, inv, drops)
	var bag := Inventory.make_backpack(&"small_backpack")
	bag.contents[2] = ItemStack.make(&"coal_ore", 5)
	var b := Vector3i(1, 20, 1)
	_ok("a backpack is a container with its own size (9)", MineChests.is_container(&"small_backpack")
			and MineChests.slot_count(&"small_backpack") == 9)
	chests.place(b, bag.contents, true, &"small_backpack")
	var key := MineChests.key_of(b)
	_ok("put down: its slots are the very contents it carried", chests.slots_of(key) == bag.contents
			and chests.slots_of(key)[2].count == 5)
	var back := MineChests.new()
	back.setup(null, inv, drops)
	back.restore(JSON.parse_string(JSON.stringify(chests.to_save())))
	_ok("saved and back: 9 slots, the coal in slot 3", back.slots_of(key).size() == 9
			and back.slots_of(key)[2] != null and back.slots_of(key)[2].count == 5)
	chests.break_chest(key, false)
	_ok("broken: it falls as one backpack with its contents (creative too)", drops.count() == 1
			and (drops.drops[0].stack as ItemStack).id == &"small_backpack"
			and (drops.drops[0].stack as ItemStack).contents[2].count == 5)
	back.remove(key)
	_ok("removed (picked up): gone, nothing dropped", back.count() == 0 and drops.count() == 1)
	for x in [drops, chests, back]:
		for n in x.get_children():
			n.free()
	drops.clear()
	chests.clear()
	drops.free()
	chests.free()
	back.free()
