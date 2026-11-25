class_name MineHands
extends Node3D
## What is in the player's hands in the mine world (Docs/Inventory.md 10):
## the selected hotbar slot, whatever it holds. A gun item goes into the
## GunController and the view (the arsenal's way of showing one, without
## the arsenal: the mine world asks PlayerKit for none); anything else puts
## the gun away and lets the builder act (MineBuilder.set_active).
##
## A gun item's stack `data` is the gun itself -- CharacterSave.gun_entry
## (class, seed, tier, rarity, parts) plus `name` and `ammo` -- so it is made
## again exactly from a save, a chest or the ground. Made once while carried
## (`_made`, under a hidden holster); its rounds go back into the stack when
## it is put away and before a save (`sync_ammo`).
##
## The city and the planets keep the arsenal: nothing here is theirs.

var host: Node = null
var inv: Inventory = null
var gun: GunController = null
var view: PlayerView = null
var library: GunPartLibrary = null
var builder: Node = null

## The stack whose gun is in the hands, or null.
var held: ItemStack = null
## ItemStack -> GunInstance, the guns made for stacks still carried.
var _made := {}
var _holster: Node3D


func setup(p_host: Node, p_gun: GunController, p_view: PlayerView, p_library: GunPartLibrary,
		p_builder: Node) -> void:
	host = p_host
	gun = p_gun
	view = p_view
	library = p_library
	builder = p_builder
	_holster = Node3D.new()
	_holster.name = "Holster"
	_holster.visible = false
	add_child(_holster)


func set_inventory(p_inv: Inventory) -> void:
	if inv != null:
		if inv.changed.is_connected(refresh):
			inv.changed.disconnect(refresh)
		if inv.active_changed.is_connected(refresh):
			inv.active_changed.disconnect(refresh)
	inv = p_inv
	inv.changed.connect(refresh)
	inv.active_changed.connect(refresh)
	refresh()


static func is_gun(s: ItemStack) -> bool:
	return s != null and ItemCatalog.kind(s.id) == "gun"


## A gun as an item: its entry, its name, the rounds in it.
static func stack_of(g: GunInstance, ammo := -1) -> ItemStack:
	var d := CharacterSave.gun_entry(g)
	d["name"] = g.gun_name
	if ammo >= 0:
		d["ammo"] = ammo
	return ItemStack.make(ItemCatalog.gun_id(StringName(d.get("class", "pistol"))), 1, d)


## The hands follow the selected slot.
func refresh() -> void:
	if inv == null or gun == null:
		return
	var h := inv.hand()
	var want_gun := is_gun(h)
	if want_gun and h == held and gun.gun != null:
		return
	if not want_gun and held == null:
		if builder != null and not builder.active:
			builder.set_active(true)
		return
	# Put away what is held.
	if held != null and gun.gun != null and is_instance_valid(gun.gun):
		held.data["ammo"] = gun.ammo
		var old := gun.gun
		gun.set_trigger(false)
		gun.equip(null)
		if view != null:
			view.put_away(old, _holster)
		else:
			old.reparent(_holster, false)
	held = null
	if want_gun:
		var g := _gun_for(h)
		if g != null:
			gun.equip(g)
			if h.data.has("ammo"):
				gun.ammo = mini(int(h.data.ammo), gun.mag_size())
			if view != null:
				view.hold(g)
			held = h
	if builder != null:
		builder.set_active(held == null)
	_prune()


func _gun_for(s: ItemStack) -> GunInstance:
	var g = _made.get(s)
	if g != null and is_instance_valid(g):
		return g
	if library == null:
		return null
	var made := CharacterSave.make_gun(s.data, library)
	if made == null:
		return null
	_holster.add_child(made)
	_made[s] = made
	return made


## Guns made for stacks no longer carried (dropped, put in a chest): freed.
func _prune() -> void:
	if inv == null:
		return
	var carried := {}
	for a in inv.all_addrs():
		var s := inv.get_slot(a)
		if s != null:
			carried[s] = true
	if inv.cursor != null:
		carried[inv.cursor] = true
	for s in _made.keys():
		if not carried.has(s) and s != held:
			var g = _made[s]
			_made.erase(s)
			if g != null and is_instance_valid(g) and g != gun.gun:
				(g as Node).queue_free()


## The rounds in the held gun into its stack (before a save).
func sync_ammo() -> void:
	if held != null and gun != null and gun.gun != null:
		held.data["ammo"] = gun.ammo


## No gun anywhere in the inventory: the character's kit guns
## (CharacterSave.loadout), else a rifle and a pistol rolled from the
## character's seed, into the first free hotbar slots (or storage). True if
## any were given.
func ensure_guns(p_inv: Inventory, loadout: Dictionary) -> bool:
	for a in p_inv.all_addrs():
		if is_gun(p_inv.get_slot(a)):
			return false
	var entries: Array = []
	for key in ["slots", "backpack"]:
		var arr = loadout.get(key, [])
		if arr is Array:
			for e in arr:
				if e is Dictionary and e.has("class") and WeaponClass.gun_ids().has(StringName(str(e["class"]))):
					entries.append(e)
	var stacks: Array = []
	for e in entries.slice(0, 4):
		var g := CharacterSave.make_gun(e, library) if library != null else null
		if g != null:
			stacks.append(stack_of(g))
			g.free()
	if stacks.is_empty() and library != null:
		var rng := RandomNumberGenerator.new()
		rng.seed = 0x1007
		for cid in [&"rifle", &"pistol"]:
			var gen_seed := rng.randi()
			var res := GunGenerator.generate(library, gen_seed, WeaponClass.rolled(cid, gen_seed), 1)
			var g := GunInstance.from_result(res)
			stacks.append(stack_of(g))
			g.free()
	for s in stacks:
		var left := p_inv.add_item(s)
		if left != null:
			push_warning("[hands] no room for %s" % s.id)
	return not stacks.is_empty()
