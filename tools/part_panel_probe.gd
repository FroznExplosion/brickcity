extends SceneTree

## The catalogue panel (Docs/ModularParts.md section 6, stage 3), headless.
##
##     godot --headless --path . --script res://tools/part_panel_probe.gd
##
##   facets    any one facet alone filters: light alone, legs alone, SMG alone, custom alone;
##             OR inside a facet, AND across; counts leave out the facet's own ticks, so the
##             other values keep their buttons; a facet every part shares has no row
##   search    words AND'd over name, id, maker, creator
##   order     grouped by maker then the sort; flat when grouping is off; ties on id; the
##             list drawn is the list shown()
##   custom    custom parts mixed in, marked with their creator; the creator is a facet
##   fits      the toggle is off with no target; with one, only what fits that socket; the
##             detail line says why a part does not fit
##   pool      the inventory's own parts only
##   pick      a pick sends the part

var _pass := 0
var _fail := 0


func _init() -> void:
	print("part panel probe")
	_run.call_deferred()


func _ok(what: String, cond: bool, detail: String = "") -> void:
	if cond:
		_pass += 1
		print("  ok   %s%s" % [what, ("  " + detail) if detail else ""])
	else:
		_fail += 1
		print("  FAIL %s%s" % [what, (" -- " + detail) if detail else ""])


func _p(d: Dictionary) -> PartRecord:
	return PartRecord.from_dict(d)


func _catalog() -> PartCatalog:
	var cat := PartCatalog.new()
	for r in [
		_p({"id": "korr_chassis_light", "family": "mech", "slot": "chassis", "class": "light",
				"manufacturer": "Korr", "sockets": [{"name": "leg_L", "accepts": ["mech.hip"]},
				{"name": "leg_R", "accepts": ["mech.hip"]}]}),
		_p({"id": "korr_leg_L", "name": "Korr strider L", "family": "mech", "slot": "leg",
				"class": "light", "side": "L", "manufacturer": "Korr",
				"mount": {"interface": "mech.hip", "params": {"length": 2}}}),
		_p({"id": "vex_leg_L", "name": "Vex pillar L", "family": "mech", "slot": "leg",
				"class": "heavy", "side": "L", "manufacturer": "Vex",
				"mount": {"interface": "mech.hip", "params": {"length": 3}}}),
		_p({"id": "vex_arm_R", "name": "Vex crusher R", "family": "mech", "slot": "arm",
				"class": "heavy", "side": "R", "manufacturer": "Vex",
				"mount": {"interface": "mech.shoulder"}}),
		_p({"id": "ash_body_smg", "name": "Ash sprayer", "family": "gun", "scale": "held",
				"slot": "body", "weapon_class": "smg", "manufacturer": "Ash",
				"sockets": [{"name": "magazine", "accepts": ["mag.narrow"]}]}),
		_p({"id": "ash_body_rifle", "name": "Ash longarm", "family": "gun", "scale": "held",
				"slot": "body", "weapon_class": "rifle", "manufacturer": "Ash",
				"sockets": [{"name": "magazine", "accepts": ["mag.wide"]}]}),
		_p({"id": "ash_mag_narrow", "name": "Ash stick", "family": "gun", "scale": "held",
				"slot": "magazine", "manufacturer": "Ash", "mount": {"interface": "mag.narrow"}}),
		_p({"id": "lu.mag_wide", "name": "Drum of Lu", "family": "gun", "scale": "held",
				"slot": "magazine", "manufacturer": "workshop", "source": "custom",
				"creator": {"name": "Lu"}, "mount": {"interface": "mag.wide"}}),
	]:
		_ok("fixture %s" % r.id, cat.add(r), "; ".join(r.problems()))
	return cat


func _ids(list: Array[PartRecord]) -> Array:
	var out := []
	for r in list:
		out.append(r.id)
	return out


func _drawn(panel: PartCatalogPanel) -> Array:
	var out := []
	var tree: Tree = panel._tree
	var stack := [tree.get_root()]
	while not stack.is_empty():
		var it: TreeItem = stack.pop_back()
		var kids := it.get_children()
		kids.reverse()
		stack.append_array(kids)
		if it.get_metadata(0) != null:
			out.append(String(it.get_metadata(0)))
	return out


func _buttons(panel: PartCatalogPanel, facet: String) -> Dictionary:
	var out := {}
	for b in panel._facet_box.find_children("*", "Button", true, false):
		if b.has_meta(&"facet") and String(b.get_meta(&"facet")) == facet:
			out[b.get_meta(&"value")] = b
	return out


func _run() -> void:
	var panel := PartCatalogPanel.new()
	root.add_child(panel)
	var cat := _catalog()
	panel.set_catalog(cat)
	_ok("every part listed", panel.shown().size() == 8, str(panel.shown().size()))

	print("facets")
	panel.tick("class", "light")
	_ok("light alone: light parts of any kind, by name", _ids(panel.shown()) == ["korr_leg_L", "korr_chassis_light"],
			str(_ids(panel.shown())))
	var cls := panel.counts("class")
	_ok("ticking light keeps heavy's button and count", cls.get("heavy") == 2 and cls.get("light") == 2, str(cls))
	panel.clear_ticks()
	panel.tick("slot", "leg")
	_ok("legs alone: every leg", _ids(panel.shown()).size() == 2 and "vex_leg_L" in _ids(panel.shown()))
	panel.clear_ticks()
	panel.tick("weapon_class", "smg")
	var smg := _ids(panel.shown())
	_ok("SMG alone: its receiver and what it takes", smg.size() == 2 and "ash_mag_narrow" in smg
			and "ash_body_smg" in smg, str(smg))
	panel.clear_ticks()
	panel.tick("manufacturer", "Korr")
	panel.tick("manufacturer", "Vex")
	_ok("two makers OR'd", panel.shown().size() == 4)
	panel.tick("slot", "leg")
	_ok("and AND'd with the part", panel.shown().size() == 2)
	panel.tick("class", "heavy")
	_ok("and with the class", _ids(panel.shown()) == ["vex_leg_L"])
	_ok("a ticked button shows pressed", (_buttons(panel, "class").get("heavy") as Button).button_pressed)
	panel.tick("class", "heavy", false)
	_ok("untick", panel.shown().size() == 2)
	panel.clear_ticks()
	_ok("Clear filters", panel.shown().size() == 8 and panel.query.is_empty())
	_ok("a facet every part shares has no row", _buttons(panel, "rarity").is_empty()
			and not _buttons(panel, "family").is_empty())
	panel.tick("source", "custom")
	_ok("custom alone", _ids(panel.shown()) == ["lu.mag_wide"])
	panel.clear_ticks()
	panel.tick("creator", "Lu")
	_ok("the creator is a facet", _ids(panel.shown()) == ["lu.mag_wide"])
	panel.clear_ticks()

	print("search")
	panel.search = "vex L"
	panel.refresh()
	_ok("words AND'd", _ids(panel.shown()) == ["vex_leg_L"], str(_ids(panel.shown())))
	panel.search = "lu"
	panel.refresh()
	_ok("finds a creator", "lu.mag_wide" in _ids(panel.shown()))
	panel.clear_ticks()

	print("order")
	var grouped := _ids(panel.shown())
	_ok("grouped by maker, makers in order", grouped.slice(0, 3) == ["ash_body_rifle", "ash_body_smg", "ash_mag_narrow"]
			and grouped[3] == "korr_leg_L" and grouped[7] == "lu.mag_wide", str(grouped))
	_ok("the tree draws what shown() says", _drawn(panel) == grouped, str(_drawn(panel)))
	var heads := panel._tree.get_root().get_children()
	_ok("one heading per maker", heads.size() == 4 and heads[0].get_text(0) == "Ash")
	panel.group_by_maker = false
	panel.sort_key = "class"
	panel.descending = true
	panel.refresh()
	var flat := _ids(panel.shown())
	_ok("flat, heavy first, ties on id", flat.slice(0, 2) == ["vex_arm_R", "vex_leg_L"], str(flat))
	_ok("flat tree", _drawn(panel) == flat and panel._tree.get_root().get_child_count() == 8)
	panel.group_by_maker = true
	panel.sort_key = "name"
	panel.descending = false
	panel.refresh()

	print("custom")
	var lu_item: TreeItem = null
	for g in panel._tree.get_root().get_children():
		for it in g.get_children():
			if it.get_metadata(0) == "lu.mag_wide":
				lu_item = it
	_ok("marked custom with its creator", lu_item != null and lu_item.get_text(2) == "custom, by Lu")

	print("fits")
	panel.fits_only = true
	panel.refresh()
	_ok("no target: Fits does nothing and is off", panel.shown().size() == 8 and panel._fits_box.disabled)
	panel.set_fit_target(cat.get_part("ash_body_smg"), "magazine", "gun")
	_ok("with a target the toggle is on", not panel._fits_box.disabled)
	_ok("only what fits the SMG's magazine well", _ids(panel.shown()) == ["ash_mag_narrow"], str(_ids(panel.shown())))
	panel.fits_only = false
	panel.select_part("lu.mag_wide")
	_ok("the detail says why not", "mounts on mag.wide, socket takes mag.narrow" in panel._detail.text,
			panel._detail.text)
	panel.set_fit_target(cat.get_part("korr_chassis_light"), "leg_L", "mech")
	panel.fits_only = true
	panel.refresh()
	_ok("legs of any class fit the light chassis", _ids(panel.shown()) == ["korr_leg_L", "vex_leg_L"],
			str(_ids(panel.shown())))
	panel.fits_only = false
	panel.set_fit_target(null, "", "")

	print("pool")
	panel.set_catalog(cat, [cat.get_part("vex_arm_R"), cat.get_part("korr_leg_L")])
	_ok("the inventory's own parts only", _ids(panel.shown()) == ["korr_leg_L", "vex_arm_R"])
	panel.tick("class", "heavy")
	_ok("filters work on the pool", _ids(panel.shown()) == ["vex_arm_R"])
	panel.clear_ticks()
	panel.set_catalog(cat)

	print("pick")
	var got := []
	panel.part_picked.connect(func(r: PartRecord) -> void: got.append(r.id))
	panel.pick("vex_arm_R")
	_ok("a pick sends the part", got == ["vex_arm_R"])

	print("part panel probe: %d ok, %d FAIL" % [_pass, _fail])
	quit(1 if _fail > 0 else 0)
