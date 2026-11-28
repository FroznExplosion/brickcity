extends SceneTree
## The inventory screen keeps ONE size (Docs/Inventory.md 14.1, the user
## 2026-11-27): the panels and the slots are sized from the window and the
## menu scale only, Minecraft's way -- never from what a tab shows. Changing
## tab (recipes, creative, spawn, farming, editor, search), opening the
## crafting table or the furnace, the book on or off, a bigger backpack:
## the slot size and both panels' sizes stay as they were (the panels'
## contents scroll or sit in the room they have).
##
## Headless: the screen in a SubViewport of each size (1280x720, 800x450,
## 640x400), its layout measured after a few frames. Prints
## INV-LAYOUT PASS/FAIL.

var _fails: Array[String] = []
var _oks := 0


func _ok(what: String, cond: bool) -> void:
	if cond:
		_oks += 1
		print("  ok   ", what)
	else:
		_fails.append(what)
		print("  FAIL ", what)


class _Host extends Node:
	func stations_near() -> Array:
		return [&"workbench", &"furnace"]
	func drop_from_player(_s) -> void:
		pass
	func inventory_closed() -> void:
		pass


func _initialize() -> void:
	_run.call_deferred()


func _frames(n: int) -> void:
	for i in n:
		await process_frame


## The sizes that must not change: the slot, both panels.
func _measure(scr: InventoryScreen) -> Dictionary:
	var left: Control = scr.get("_left")
	var right: Control = scr.get("_right")
	return {"slot": float(scr.get("_slot_px")),
			"left": left.size if left.visible else Vector2.ZERO,
			"right": right.size}


func _same(a: Dictionary, b: Dictionary) -> bool:
	return is_equal_approx(a.slot, b.slot) and (a.left as Vector2).distance_to(b.left) < 1.0 \
			and (a.right as Vector2).distance_to(b.right) < 1.0


func _run() -> void:
	ItemCatalog.load_all()
	RecipeBook.load_all()
	for size in [Vector2i(1280, 720), Vector2i(800, 450), Vector2i(640, 400)]:
		print("[layout] window %s" % size)
		var vp := SubViewport.new()
		vp.size = size
		vp.disable_3d = true
		root.add_child(vp)
		var host := _Host.new()
		vp.add_child(host)
		var inv := Inventory.new()
		inv.seed_default()
		inv.creative = true
		var scr := InventoryScreen.new()
		scr.setup(inv, host)
		vp.add_child(scr)
		await _frames(6)
		var base := _measure(scr)
		_ok("%s: a slot size (%.0f px), both panels laid out" % [size, base.slot],
				base.slot > 0.0 and (base.right as Vector2).x > 0.0 and (base.left as Vector2).x > 0.0)
		for p in ["creative", "spawn", "farming", "editor", "recipes"]:
			scr.show_page(p)
			await _frames(4)
			var m := _measure(scr)
			_ok("%s: the %s tab keeps the size (slot %.0f, left %s, right %s)" % [size, p, m.slot, m.left, m.right],
					_same(base, m))
		# The search tab (all recipes) and a search typed.
		scr.call("_on_left_tab", "all")
		await _frames(4)
		_ok("%s: the search tab keeps the size" % size, _same(base, _measure(scr)))
		# The stations: their grid (3x3 at a workbench) and the furnace.
		for st in [&"workbench", &"furnace"]:
			scr.open_station(st)
			await _frames(4)
			var ms := _measure(scr)
			_ok("%s: at a %s the size stays (slot %.0f, right %s)" % [size, st, ms.slot, ms.right], _same(base, ms))
		scr.open_station(&"")
		await _frames(4)
		# A smaller backpack worn: fewer storage rows, the same size.
		inv.set_slot(Inventory.addr(&"backpack"), Inventory.make_backpack(&"small_backpack"))
		inv.changed.emit()
		await _frames(4)
		_ok("%s: a small backpack worn: the size stays" % size, _same(base, _measure(scr)))
		vp.queue_free()
		await _frames(2)
	print("[layout] INV-LAYOUT %s (%d ok, %d failed)%s" % ["PASS" if _fails.is_empty() else "FAIL", _oks,
			_fails.size(), "" if _fails.is_empty() else ": " + ", ".join(_fails)])
	quit(0 if _fails.is_empty() else 1)
