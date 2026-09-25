class_name GunPlaceholderParts
extends RefCounted
## Builds a complete GunPartLibrary out of box primitives, in code, with correctly
## named socket_* / mount empties so the REAL GunAssembler runs unmodified.
##
## Why this exists: the project ships zero part .tres and zero part GLBs, so nothing
## can currently produce a gun at all. This is scaffolding for the loot bed — when real
## art lands, delete this file and assign a real library; no other code changes.
##
## Sockets follow SPEC_procedural_gun_system §2: receiving parts carry `socket_<slot>`
## children, attaching parts carry one `mount` child marking the point that must
## coincide with the socket.

const SLOT := GunPartDef.Slot

## Part tier -> colour, so a placeholder gun visibly shows its part mix at a glance.
const TIER_COLORS: Array[Color] = [
	Color(0.78, 0.78, 0.78),   # 1 common - white
	Color(0.35, 0.85, 0.35),   # 2 uncommon - green
	Color(0.30, 0.60, 1.00),   # 3 rare - blue
	Color(0.70, 0.35, 0.95),   # 4 unique - purple
	Color(1.00, 0.60, 0.10),   # 5 legendary - orange
	Color(1.00, 0.25, 0.35),   # 6 mythic - red
]

## Body fragments are NOUNS, barrel fragments are ADJECTIVES (QUALITY_NAMING §3).
## The name schema depends on this split; swapping them produces "AK47 Silenced".
const BODY_NOUNS := ["AK47", "Ravager", "Pitbull", "Mongrel", "Warrant", "Vendetta"]
const BARREL_ADJS := ["Silenced", "Long", "Ported", "Vented", "Bolt-Action", "Snub"]

const BRANDS: Array[StringName] = [&"jakobs", &"maliwan", &"vladof", &"torgue"]


## One library covering every slot at every tier. `per_tier` part variants per slot.
static func build_library(per_tier: int = 2) -> GunPartLibrary:
	var lib := GunPartLibrary.new()
	var parts: Array[GunPartDef] = []
	for tier in range(1, 7):
		for variant in per_tier:
			parts.append(_body(tier, variant))
			parts.append(_barrel(tier, variant))
			parts.append(_simple(SLOT.GRIP, tier, variant, Vector3(0.06, 0.22, 0.08)))
			parts.append(_simple(SLOT.MAGAZINE, tier, variant, Vector3(0.07, 0.26, 0.05)))
			parts.append(_simple(SLOT.STOCK, tier, variant, Vector3(0.08, 0.14, 0.34)))
			parts.append(_simple(SLOT.SIGHT, tier, variant, Vector3(0.05, 0.06, 0.14)))
			parts.append(_simple(SLOT.MUZZLE, tier, variant, Vector3(0.06, 0.06, 0.12)))
			parts.append(_simple(SLOT.UNDERBARREL, tier, variant, Vector3(0.05, 0.10, 0.14)))
	# One exclusive barrel per authored legendary. These are the ONLY parts carrying a
	# legendary effect, and `exclusive_to` keeps them out of every world-drop pool
	# (QUALITY_NAMING §5) — a legendary part appears on its own legendary or nowhere.
	for leg_id: StringName in LegendaryTable.all_ids():
		parts.append(_legendary_barrel(LegendaryTable.get_def(leg_id)))

	lib.parts = parts
	return lib


static func _legendary_barrel(leg: LegendaryDef) -> GunPartDef:
	var def := GunBarrelDef.new()
	def.id = StringName("ph_legbarrel_%s" % leg.id)
	def.display_name = "%s Barrel" % leg.display_name
	def.slot = SLOT.BARREL
	def.native_rarity = 5
	def.min_rarity = 5
	def.max_rarity = 6
	def.exclusive_to = leg.id
	def.manufacturer = &"unique"
	def.weight = 1.0
	def.effect_id = leg.effect_id
	def.effect_min_rarity = 5
	def.name_fragment = ""              # a legendary's name is authored, not assembled
	def.element_ratio = 0.35
	def.barrel_family = &"hybrid"

	var root := _box(Vector3(0.08, 0.08, 0.46), 5)
	root.name = "legbarrel_%s" % leg.id
	_socket(root, "mount", Vector3(0, 0, 0.23))
	_socket(root, "socket_muzzle", Vector3(0, 0, -0.25))
	def.scene = _pack(root)
	return def


# ------------------------------------------------------------------------ receivers

static func _body(tier: int, variant: int) -> GunPartDef:
	var def := GunReceiverDef.new()
	_stamp(def, SLOT.BODY, tier, variant, "body")
	def.name_fragment = BODY_NOUNS[(tier + variant) % BODY_NOUNS.size()]

	var root := _box(Vector3(0.10, 0.18, 0.46), tier)
	root.name = "body_%d_%d" % [tier, variant]
	# Receivers RECEIVE, so they carry sockets and no mount.
	_socket(root, "socket_barrel", Vector3(0, 0.02, -0.30))
	_socket(root, "socket_grip", Vector3(0, -0.14, 0.06))
	_socket(root, "socket_magazine", Vector3(0, -0.13, -0.06))
	_socket(root, "socket_stock", Vector3(0, 0.0, 0.30))
	_socket(root, "socket_sight", Vector3(0, 0.11, 0.02))
	def.scene = _pack(root)
	return def


static func _barrel(tier: int, variant: int) -> GunPartDef:
	var def := GunBarrelDef.new()
	_stamp(def, SLOT.BARREL, tier, variant, "barrel")
	def.name_fragment = BARREL_ADJS[(tier + variant) % BARREL_ADJS.size()]
	# Higher-tier barrels lean elemental, so the name's element word actually varies.
	def.element_ratio = 0.0 if tier <= 2 else clampf(0.15 * float(tier - 2), 0.0, 0.6)
	def.barrel_family = &"kinetic" if tier <= 2 else &"hybrid"

	var root := _box(Vector3(0.07, 0.07, 0.40), tier)
	root.name = "barrel_%d_%d" % [tier, variant]
	# A barrel both attaches (mount) and receives (muzzle/underbarrel) — this is why
	# GunAssembler recurses instead of doing one flat pass.
	_socket(root, "mount", Vector3(0, 0, 0.20))
	_socket(root, "socket_muzzle", Vector3(0, 0, -0.22))
	_socket(root, "socket_underbarrel", Vector3(0, -0.06, -0.10))
	def.scene = _pack(root)
	return def


static func _simple(slot: GunPartDef.Slot, tier: int, variant: int,
		size: Vector3) -> GunPartDef:
	var def := GunPartDef.new()
	var slot_name := String(GunPartDef.Slot.keys()[slot]).to_lower()
	_stamp(def, slot, tier, variant, slot_name)

	var root := _box(size, tier)
	root.name = "%s_%d_%d" % [slot_name, tier, variant]
	_socket(root, "mount", Vector3.ZERO)
	def.scene = _pack(root)
	return def


# ---------------------------------------------------------------------- scaffolding

## Effects a placeholder part may carry, drawn from the AbilityLoadout catalog so a
## part and an ability trade in the same currency (QUALITY_NAMING §11). A SMALL pool on
## purpose: with few effects to draw from, a high-rarity gun filling several slots will
## sometimes roll the same one twice, which is exactly the part+part stacking case.
const PART_EFFECTS: Array[StringName] = [
	&"ricochet", &"explosive", &"lifesteal", &"fire_ramp",
]


static func _stamp(def: GunPartDef, slot: GunPartDef.Slot, tier: int, variant: int,
		prefix: String) -> void:
	def.id = StringName("ph_%s_t%d_%d" % [prefix, tier, variant])
	def.display_name = "%s T%d" % [prefix.capitalize(), tier]
	def.slot = slot
	def.native_rarity = tier
	# Legal one tier either side of native, so the offset roll has somewhere to land
	# without the fallback walk firing on every pick.
	def.min_rarity = maxi(1, tier - 1)
	def.max_rarity = mini(6, tier + 1)
	def.manufacturer = BRANDS[(tier + variant) % BRANDS.size()]
	def.weight = 1.0
	# Rare and up carry an effect. Higher tiers draw from the same short pool, so the
	# chance two slots land the same effect climbs with rarity — legendary/mythic guns
	# self-upgrade an effect fairly often, which is the intended behaviour.
	if tier >= 3:
		def.effect_id = PART_EFFECTS[(tier * 3 + variant + int(slot)) % PART_EFFECTS.size()]
		def.effect_min_rarity = 3


static func _box(size: Vector3, tier: int) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	var mesh := BoxMesh.new()
	mesh.size = size
	mi.mesh = mesh
	var mat := StandardMaterial3D.new()
	mat.albedo_color = TIER_COLORS[clampi(tier - 1, 0, 5)]
	mat.roughness = 0.55
	mat.metallic = 0.35
	mi.material_override = mat
	return mi


static func _socket(parent: Node3D, socket_name: String, pos: Vector3) -> void:
	var n := Node3D.new()
	n.name = socket_name
	n.position = pos
	parent.add_child(n)
	n.owner = parent


## PackedScene.pack() only captures children whose `owner` is the root, which is why
## _socket sets owner explicitly. Miss that and every gun assembles as a bare body.
static func _pack(root: Node3D) -> PackedScene:
	var ps := PackedScene.new()
	var err := ps.pack(root)
	if err != OK:
		push_error("GunPlaceholderParts: pack failed for %s (%d)" % [root.name, err])
	return ps
