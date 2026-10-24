class_name MechAssembler
extends RefCounted
## A mech in the game from its parts (Docs/ModularParts.md section 4, stage 6): each part's
## saved scene on a joint, the joint where the part it hangs from has its socket for it --
## as GunAssembler does a gun's, one level deeper (the hand hangs on the arm). The chassis
## is the mech's class, and so its layers; the legs' length is its hip height.
##
##     var b := PartBuilder.generate("mech", design, seed, cat)
##     if b.problems.is_empty(): MechAssembler.dress(mech, b)

const PART_SCENE := "part.scn"
## A nano plate in the game's metres (Docs/Parts/nano.md section 1).
const NANO_PLATE_M := 0.07
## Each class's layers (Docs/AIRoster.md 4.1): the chassis's class is the mech's, whatever
## its arms and legs look like.
const CLASS_LAYERS := {
	"light": {"shield": 1400.0, "armor": 800.0, "health": 800.0, "hatch": 200.0,
			"cell_door": 150.0, "hatch_side": "back"},
	"normal": {"shield": 1000.0, "armor": 1500.0, "health": 1250.0, "hatch": 350.0,
			"cell_door": 250.0, "hatch_side": "front"},
	"heavy": {"shield": 600.0, "armor": 2400.0, "health": 1500.0, "hatch": 500.0,
			"cell_door": 350.0, "hatch_side": "front"},
}


## Hip height in nano bricks for a leg `length`: the players' three from MechReference,
## and any other (a boss's) on the same line, 4 bricks a step.
static func hip_bricks(length: int) -> int:
	return MechReference.HIP_BRICKS.get(length, 8 + 4 * length)


## How high the hips are, in the game's metres: from the legs' length.
static func hip_height(build: Dictionary) -> float:
	var length := 2
	for path in ["leg_L", "leg_R"]:
		var leg: PartRecord = (build.get("at", {}) as Dictionary).get(path)
		if leg != null and leg.param("length") != null:
			length = int(leg.param("length"))
			break
	return hip_bricks(length) * MechReference.PLATES_PER_BRICK * NANO_PLATE_M


## The build put together: a Node3D whose origin is the hips, the chassis on it, every other
## part under a joint node "Joint_<path>" (arm_L, arm_L_hand) where its host's socket is.
## meta "joints": {path: joint node}. Null if the chassis has no scene.
static func assemble(build: Dictionary) -> Node3D:
	var root_rec: PartRecord = build.get("root")
	var chassis := _instance(root_rec)
	if chassis == null:
		return null
	var model := Node3D.new()
	model.name = "MechModel"
	chassis.name = "Chassis"
	model.add_child(chassis)
	var scenes := {"": chassis}
	var xf := {"": Transform3D.IDENTITY}
	var joints := {}
	var at: Dictionary = build.get("at", {})
	var paths := at.keys()
	paths.sort_custom(func(a: String, b: String) -> bool:
		var da := a.count("/")
		var db := b.count("/")
		return da < db if da != db else a < b)
	for path: String in paths:
		var host_path := path.get_base_dir() if path.contains("/") else ""
		if not scenes.has(host_path):
			continue
		var host: Node3D = scenes[host_path]
		var sock := host.get_node_or_null("socket_" + path.get_file()) as Node3D
		if sock == null:
			push_warning("MechAssembler: %s has no socket_%s" % [host.get_meta(&"part_id", "?"), path.get_file()])
		var j_xf: Transform3D = (xf[host_path] as Transform3D) * (sock.transform if sock != null else Transform3D.IDENTITY)
		var inst := _instance(at[path])
		if inst == null:
			continue
		var j := Node3D.new()
		j.name = "Joint_" + path.replace("/", "_")
		j.transform = j_xf
		model.add_child(j)
		var mount := inst.get_node_or_null("mount") as Node3D
		inst.transform = mount.transform.affine_inverse() if mount != null else Transform3D.IDENTITY
		j.add_child(inst)
		scenes[path] = inst
		xf[path] = j_xf * inst.transform
		joints[path] = j
	model.set_meta(&"joints", joints)
	return model


## Give mech `m` the parts of `build` (PartBuilder.generate's): its boxes go, its parts
## come, its layers become the chassis's class's. False (and the mech as it was) when the
## build has problems or its chassis no scene: only parts that fit are ever put together.
static func dress(m: Mech, build: Dictionary, take_class: bool = true) -> bool:
	if not (build.get("problems", []) as Array).is_empty():
		return false
	var model := assemble(build)
	if model == null:
		return false
	var klass := (build.root as PartRecord).weight_class
	var spec: Dictionary = CLASS_LAYERS.get(klass, {}) if take_class else {}
	m.set_parts(model, hip_height(build), spec)
	m.set_meta(&"mech_parts", _ids(build))
	return true


## The workshop's mech builds as designs: the parts saved from one build (by its name)
## fixed on their paths. And every design file of the mech plan. id -> PartDesign.
static func designs(cat: PartCatalog = null) -> Dictionary:
	if cat == null:
		cat = PartCatalog.load_all()
	var by_from := {}
	for r in cat.filter({"family": ["mech", "pod"]}):
		var from := String(r.extra.get("from", ""))
		if from != "" and FileAccess.file_exists(r.dir + PART_SCENE):
			(by_from.get_or_add(from, []) as Array).append(r)
	var out := {}
	for from: String in by_from:
		var did := AssetGuns.slug(from)
		out[did] = PartDesign.from_parts(did, from, "mech", by_from[from])
	var files := PartDesign.load_all()
	for did: String in files:
		if (files[did] as PartDesign).plan == "mech" and not out.has(did):
			out[did] = files[did]
	return out


static func _ids(build: Dictionary) -> Dictionary:
	var out := {"root": (build.root as PartRecord).id}
	for path in build.get("at", {}):
		out[path] = (build.at[path] as PartRecord).id
	return out


static func _instance(r: PartRecord) -> Node3D:
	if r == null or r.dir == "":
		return null
	var ps := ResourceLoader.load(r.dir + PART_SCENE) as PackedScene
	if ps == null:
		return null
	var n := ps.instantiate() as Node3D
	if n != null:
		n.set_meta(&"part_id", r.id)
	return n


static var _cat: PartCatalog


## The catalogue mechs are rolled from, read once (reload: read the part folders again).
static func catalog(reload: bool = false) -> PartCatalog:
	if _cat == null or reload:
		_cat = PartCatalog.load_all()
	return _cat


## A roster recipe's class as a chassis's: the roster says medium, the parts normal.
static func class_of(roster_class: String) -> String:
	return "normal" if roster_class == "medium" else roster_class


## Roll mech `m` a build (of `design`, else of any parts; a chassis of `klass` if given) and
## dress it. False, and the mech left as it was, when nothing whole fits -- as now, with no
## mech parts shipped, for every rolled mech. Pools are official parts only, so a seed
## makes the same mech on every machine; a design's fixed parts may be anyone's.
static func dress_rolled(m: Mech, gen_seed: int, klass: String = "", design: PartDesign = null,
		take_class: bool = false) -> bool:
	var b := PartBuilder.generate("mech", design, gen_seed, catalog(), {"class": klass})
	return dress(m, b, take_class)


## The mech guns made in the workshop (scale mech, Docs/ModularParts.md section 5): their
## design ids, in order.
static func mech_gun_ids(cat: PartCatalog = null) -> Array:
	var ids := AssetGuns.designs(cat if cat != null else catalog(), "mech").keys()
	ids.sort()
	return ids


## A mech gun rolled from `seed`: one of the workshop's mech gun designs, its stats and
## modifiers rolled as any gun's. Null when there is none.
static func roll_gun(lib: GunPartLibrary, gen_seed: int, cat: PartCatalog = null) -> GunGenerator.Result:
	if cat == null:
		cat = catalog()
	var ids := mech_gun_ids(cat)
	if ids.is_empty():
		return null
	return AssetGuns.generate(lib, ids[posmod(gen_seed, ids.size())], gen_seed, 1, 3, cat, "mech")


## Put mech gun `res` in mech `m`'s right hand, seen, in place of what it held: at the
## wrist, pointing along the arm's aim, the arm's muzzle moved to the gun's.
static func arm_gun(m: Mech, res: GunGenerator.Result) -> GunInstance:
	if res == null or m.gun == null:
		return null
	var gi := GunInstance.from_result(res)
	var old: Node = m.gun.gun
	var pose := m.arm.get_node_or_null(^"Pose") as Node3D
	var hand := m.arm.get_node_or_null(^"Pose/Joint_arm_R_hand") as Node3D
	gi.position = pose.transform * hand.position if pose != null and hand != null else Vector3.FORWARD * 1.5
	m.arm.add_child(gi)
	m.gun.equip(gi)
	gi.visible = true
	if old != null and old != gi:
		old.queue_free()
	var mp := gi.get_muzzle_point()
	if mp != null and mp != gi and m.arm.is_inside_tree():
		m.muzzle.position = m.arm.to_local(mp.global_position)
	return gi
