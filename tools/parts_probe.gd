extends SceneTree

## The part record, the fit check and the catalogue (Docs/ModularParts.md stage 1).
##
##     godot --headless --path . --script res://tools/parts_probe.gd
##
##   standards   the interfaces and body plans are read from standards.json; mech.hip
##               needs a length
##   record      a part survives a round trip, keys it does not know included; a part
##               with its own problems says what they are (unknown interface, custom with
##               no creator, a hip with no length, an interface of another slot)
##   fit         layer 1: any class of arm on any chassis; the wrong slot, side, scale or
##               interface refused with its reason; a mirrorable part on either side
##   build       layer 2: a whole mech fits; two different legs fit if one length, two
##               lengths do not; a required socket left empty; pods optional; a boss's
##               legs of any length; John, fixed body and a hat, as a figure
##   catalogue   light alone, legs alone, brands OR'd and AND'd with slot and class; a
##               barrel is in the class of every receiver that takes it; mech and held gun
##               parts kept apart by scale; counts per value; sorting the same every time,
##               ties on id; the Fits toggle
##   folders     parts read from folders; the folder says official or custom, never the
##               file; a broken file and a duplicate id left out; the creator is a facet

const TMP := "user://parts_probe/"

var _pass := 0
var _fail := 0


func _init() -> void:
	print("parts probe")
	_run.call_deferred()


func _ok(what: String, cond: bool, detail: String = "") -> void:
	if cond:
		_pass += 1
		print("  ok   %s%s" % [what, ("  " + detail) if detail else ""])
	else:
		_fail += 1
		print("  FAIL %s%s" % [what, (" -- " + detail) if detail else ""])


func _run() -> void:
	_standards()
	_record()
	_fit()
	_build()
	_catalogue()
	_folders()
	print("parts probe: %d passed, %d failed" % [_pass, _fail])
	quit(1 if _fail > 0 else 0)


# --- parts to test with -------------------------------------------------------

func _part(d: Dictionary) -> PartRecord:
	return PartRecord.from_dict(d)


func _chassis(id: String, klass: String, maker: String = "korr") -> PartRecord:
	return _part({"id": id, "family": "mech", "slot": "chassis", "class": klass,
			"manufacturer": maker, "sockets": [
				{"name": "neck", "accepts": ["mech.neck"]},
				{"name": "arm_L", "accepts": ["mech.shoulder"]},
				{"name": "arm_R", "accepts": ["mech.shoulder"]},
				{"name": "leg_L", "accepts": ["mech.hip"]},
				{"name": "leg_R", "accepts": ["mech.hip"]},
				{"name": "pod_L", "accepts": ["mech.pod"]},
				{"name": "pod_R", "accepts": ["mech.pod"]}]})


func _arm(id: String, klass: String, side: String, maker: String = "korr", mirror := false) -> PartRecord:
	return _part({"id": id, "family": "mech", "slot": "arm", "class": klass, "side": side,
			"mirrorable": mirror, "manufacturer": maker, "mount": {"interface": "mech.shoulder"},
			"sockets": [{"name": "hand", "accepts": ["mech.wrist"]}]})


func _hand(id: String, side: String) -> PartRecord:
	return _part({"id": id, "family": "mech", "slot": "hand", "side": side,
			"mount": {"interface": "mech.wrist"}})


func _leg(id: String, klass: String, side: String, length: int, maker: String = "korr") -> PartRecord:
	return _part({"id": id, "family": "mech", "slot": "leg", "class": klass, "side": side,
			"manufacturer": maker, "mount": {"interface": "mech.hip", "params": {"length": length}}})


func _head(id: String) -> PartRecord:
	return _part({"id": id, "family": "mech", "slot": "head", "mount": {"interface": "mech.neck"}})


func _pod(id: String, kind: String) -> PartRecord:
	return _part({"id": id, "family": "pod", "slot": "pod", "pod_kind": kind,
			"mount": {"interface": "mech.pod"}})


func _receiver(id: String, wc: String, scale: String, mag: String) -> PartRecord:
	var p := "mgun." if scale == "mech" else ""
	return _part({"id": id, "family": "gun", "scale": scale, "slot": "body", "weapon_class": wc,
			"sockets": [{"name": "barrel", "accepts": [p + "barrel.collar"]},
				{"name": "grip", "accepts": [p + "grip.pin"]},
				{"name": "magazine", "accepts": [p + mag]}]})


func _gun_part(id: String, slot: String, iface: String, scale: String = "held") -> PartRecord:
	return _part({"id": id, "family": "gun", "scale": scale, "slot": slot,
			"mount": {"interface": iface}})


## A light Korr chassis, heavy Vex left arm, light right arm, normal legs: the doc's example.
func _example_mech() -> Dictionary:
	return {"root": _chassis("korr_chassis_light", "light"), "at": {
		"neck": _head("korr_head"),
		"arm_L": _arm("vex_arm_heavy_L", "heavy", "L", "vex"),
		"arm_R": _arm("korr_arm_light_R", "light", "R"),
		"arm_L/hand": _hand("hand_fist_L", "L"),
		"arm_R/hand": _hand("hand_c_R", "R"),
		"leg_L": _leg("korr_leg_normal_L", "normal", "L", 2),
		"leg_R": _leg("korr_leg_normal_R", "normal", "R", 2),
	}}


# --- the checks ---------------------------------------------------------------

func _standards() -> void:
	print("standards")
	for i in ["mag.narrow", "mgun.mag.narrow", "mech.shoulder", "mech.hip", "mech.pod", "fig.hat"]:
		_ok("interface %s" % i, not PartStandards.interface(i).is_empty())
	_ok("mech.hip needs a length", "length" in PartStandards.interface("mech.hip").get("params", []))
	for p in ["mech", "figure", "gun"]:
		_ok("body plan %s" % p, not PartStandards.plan(p).is_empty())
	_ok("the mech plan's legs must match", (PartStandards.plan("mech").same as Array).size() == 1)


func _record() -> void:
	print("record")
	var leg := _leg("korr_leg_tall_L", "heavy", "L", 3)
	leg.tags = PackedStringArray(["armored"])
	leg.creator = {}
	leg.extra["future_key"] = {"a": 1}
	# JSON has no ints, so an unknown key's 1 reads back 1.0: the first trip settles the
	# numbers, and from then on nothing changes.
	var back := PartRecord.from_dict(JSON.parse_string(JSON.stringify(leg.to_dict())))
	var again := PartRecord.from_dict(JSON.parse_string(JSON.stringify(back.to_dict())))
	_ok("round trip", JSON.stringify(again.to_dict()) == JSON.stringify(back.to_dict()))
	_ok("the known fields", back.id == leg.id and back.slot == "leg" and back.side == "L"
			and back.weight_class == "heavy" and back.tags == leg.tags and back.rev == 1)
	_ok("an unknown key is kept", back.extra.get("future_key", {}).get("a") == 1)
	_ok("its length", int(back.param("length")) == 3)
	_ok("a good part has no problems", leg.problems().is_empty(), "; ".join(leg.problems()))

	var typo := _part({"id": "x", "family": "mech", "slot": "arm", "mount": {"interface": "mech.sholder"}})
	_ok("a typo'd interface is a problem", _has(typo.problems(), "no interface"))
	var nobody := _leg("y", "light", "L", 1)
	nobody.source = "custom"
	_ok("custom with no creator", _has(nobody.problems(), "no creator"))
	var no_len := _part({"id": "z", "family": "mech", "slot": "leg", "mount": {"interface": "mech.hip"}})
	_ok("a hip with no length", _has(no_len.problems(), "needs its length"))
	var wrong := _part({"id": "w", "family": "mech", "slot": "leg", "mount": {"interface": "mech.shoulder"}})
	_ok("an arm's interface on a leg", _has(wrong.problems(), "a arm's interface"))
	var noscale := _part({"id": "v", "family": "gun", "slot": "barrel", "mount": {"interface": "barrel.collar"}})
	_ok("a gun part with no scale", _has(noscale.problems(), "no scale"))


func _fit() -> void:
	print("fit")
	var light := _chassis("c_light", "light")
	var heavy_arm := _arm("a_heavy_L", "heavy", "L")
	_ok("a heavy arm on a light chassis", PartFit.fits(heavy_arm, light, "arm_L", "mech"))
	var why := PartFit.why_not(_leg("l", "light", "L", 2), light, "arm_L", "mech")
	_ok("a leg on an arm socket", why.contains("takes a arm"), why)
	why = PartFit.why_not(heavy_arm, light, "arm_R", "mech")
	_ok("a left-only arm on the right", why.contains("L only"), why)
	_ok("a mirrorable left arm on the right",
			PartFit.fits(_arm("a_m", "light", "L", "korr", true), light, "arm_R", "mech"))
	_ok("an any-side head", PartFit.fits(_head("h"), light, "neck", "mech"))

	var rifle := _receiver("r_rifle", "rifle", "held", "mag.narrow")
	why = PartFit.why_not(_gun_part("m_wide", "magazine", "mag.wide"), rifle, "magazine", "gun")
	_ok("a wide magazine in a narrow well", why == "mounts on mag.wide, socket takes mag.narrow", why)
	_ok("a narrow magazine in it", PartFit.fits(_gun_part("m_n", "magazine", "mag.narrow"), rifle, "magazine", "gun"))
	var mech_rifle := _receiver("mr", "rifle", "mech", "mag.narrow")
	why = PartFit.why_not(_gun_part("b_held", "barrel", "barrel.collar"), mech_rifle, "barrel", "gun")
	_ok("a held barrel on a mech gun", why.contains("held part on a mech build"), why)
	_ok("a mech barrel on a mech gun",
			PartFit.fits(_gun_part("b_mech", "barrel", "mgun.barrel.collar", "mech"), mech_rifle, "barrel", "gun"))
	why = PartFit.why_not(_head("h"), light, "tail", "mech")
	_ok("a socket the plan has not", why.contains("no 'tail'"), why)


func _build() -> void:
	print("build")
	var b := _example_mech()
	var bad := PartFit.problems(b, "mech")
	_ok("light chassis, heavy left arm, light right, normal legs", bad.is_empty(), "; ".join(bad))

	b.at["leg_R"] = _leg("vex_leg_light_R", "light", "R", 2, "vex")
	_ok("two different legs of one length", PartFit.problems(b, "mech").is_empty())
	b.at["leg_R"] = _leg("vex_leg_tall_R", "light", "R", 3, "vex")
	bad = PartFit.problems(b, "mech")
	_ok("legs of two lengths", _has(bad, "length must match"), "; ".join(bad))

	b = _example_mech()
	b.at.erase("arm_R/hand")
	bad = PartFit.problems(b, "mech")
	_ok("a hand left off", _has(bad, "arm_R/hand: empty"), "; ".join(bad))

	b = _example_mech()
	b.at["pod_L"] = _pod("missiles", "active_fixed")
	b.at["pod_R"] = _pod("third_arm", "active_animated")
	_ok("two pods", PartFit.problems(b, "mech").is_empty())
	b.at.erase("pod_R")
	_ok("one pod: pods are optional", PartFit.problems(b, "mech").is_empty())

	b = _example_mech()
	b.at["leg_L"] = _leg("boss_leg_L", "heavy", "L", 7)
	b.at["leg_R"] = _leg("boss_leg_R", "heavy", "R", 7)
	_ok("a boss's legs, 7 long", PartFit.problems(b, "mech").is_empty())

	b = _example_mech()
	b.root = _arm("not_a_chassis", "light", "L")
	_ok("a build on an arm", _has(PartFit.problems(b, "mech"), "built on a chassis"))

	var torso := _part({"id": "john_torso", "family": "figure", "slot": "torso", "sockets": [
			{"name": "neck", "accepts": ["fig.neck"]}, {"name": "arm_L", "accepts": ["fig.shoulder"]},
			{"name": "arm_R", "accepts": ["fig.shoulder"]}, {"name": "leg_L", "accepts": ["fig.hip"]},
			{"name": "leg_R", "accepts": ["fig.hip"]}]})
	var john := {"root": torso, "at": {
		"neck": _part({"id": "john_head", "family": "figure", "slot": "head", "mount": {"interface": "fig.neck"},
				"sockets": [{"name": "hat", "accepts": ["fig.hat"]}]}),
		"neck/hat": _part({"id": "cowboy_hat", "family": "figure", "slot": "hat", "tags": ["john"],
				"mount": {"interface": "fig.hat"}}),
	}}
	for s in ["L", "R"]:
		john.at["arm_" + s] = _part({"id": "john_arm_" + s, "family": "figure", "slot": "arm", "side": s,
				"mount": {"interface": "fig.shoulder"}, "sockets": [{"name": "hand", "accepts": ["fig.wrist"]}]})
		john.at["arm_%s/hand" % s] = _part({"id": "john_hand_" + s, "family": "figure", "slot": "hand",
				"side": s, "mount": {"interface": "fig.wrist"}})
		john.at["leg_" + s] = _part({"id": "john_leg_" + s, "family": "figure", "slot": "leg", "side": s,
				"mount": {"interface": "fig.hip"}})
	bad = PartFit.problems(john, "figure")
	_ok("John, with a hat", bad.is_empty(), "; ".join(bad))
	john.at["neck/hat"] = _head("mech_head_as_hat")
	_ok("a mech head for a hat", not PartFit.problems(john, "figure").is_empty())


func _sample() -> PartCatalog:
	var cat := PartCatalog.new()
	for r in [_chassis("korr_chassis_light", "light"), _chassis("vex_chassis_heavy", "heavy", "vex"),
			_chassis("bolt_chassis_normal", "normal", "bolt"),
			_arm("korr_arm_light_L", "light", "L"), _arm("vex_arm_heavy_L", "heavy", "L", "vex"),
			_arm("vex_arm_heavy_R", "heavy", "R", "vex"), _arm("bolt_arm_heavy_R", "heavy", "R", "bolt"),
			_leg("korr_leg_short_L", "light", "L", 1), _leg("korr_leg_tall_R", "heavy", "R", 3),
			_leg("vex_leg_normal_L", "normal", "L", 2, "vex"),
			_pod("pod_missiles", "active_fixed"), _pod("pod_shield", "passive"),
			_receiver("smg_body", "smg", "held", "mag.narrow"), _receiver("rifle_body", "rifle", "held", "mag.wide"),
			_receiver("mech_rifle_body", "rifle", "mech", "mag.narrow"),
			_gun_part("barrel_short", "barrel", "barrel.collar"),
			_gun_part("mag_wide_30", "magazine", "mag.wide"),
			_gun_part("mech_barrel", "barrel", "mgun.barrel.collar", "mech")]:
		cat.add(r)
	return cat


func _catalogue() -> void:
	print("catalogue")
	var cat := _sample()
	_ok("every sample part went in", cat.size() == 18, str(cat.size()))
	var light := _ids(cat.filter({"class": ["light"]}))
	_ok("light alone, any brand", light == ["korr_arm_light_L", "korr_chassis_light", "korr_leg_short_L"], str(light))
	var legs := _ids(cat.filter({"slot": ["leg"]}))
	_ok("legs alone", legs.size() == 3, str(legs))
	var heavy_arms := _ids(cat.filter({"manufacturer": ["vex", "bolt"], "slot": ["arm"], "class": ["heavy"]}))
	_ok("vex or bolt, arms, heavy", heavy_arms == ["bolt_arm_heavy_R", "vex_arm_heavy_L", "vex_arm_heavy_R"], str(heavy_arms))
	_ok("an empty facet does not filter", cat.filter({"slot": []}).size() == cat.size())
	_ok("no match is an empty list", cat.filter({"slot": ["tail"]}).is_empty())
	_ok("filtering an empty list stays empty", cat.filter({}, [] as Array[PartRecord]).is_empty())

	_ok("a barrel is in every class whose receiver takes it",
			cat.facets_of(cat.get_part("barrel_short")).get("weapon_class") == ["rifle", "smg"])
	_ok("a wide magazine only the rifle's",
			cat.facets_of(cat.get_part("mag_wide_30")).get("weapon_class") == ["rifle"])
	var smg := _ids(cat.filter({"family": ["gun"], "weapon_class": ["smg"]}))
	_ok("smg parts", smg == ["barrel_short", "smg_body"], str(smg))
	var mech_guns := _ids(cat.filter({"family": ["gun"], "scale": ["mech"]}))
	_ok("mech gun parts by scale", mech_guns == ["mech_barrel", "mech_rifle_body"], str(mech_guns))
	_ok("pods by kind", _ids(cat.filter({"pod_kind": ["passive"]})) == ["pod_shield"])
	_ok("legs by length", _ids(cat.filter({"length": [3]})) == ["korr_leg_tall_R"])

	var counts := cat.values("manufacturer", cat.filter({"family": ["mech"]}))
	_ok("counts per maker", counts == {"bolt": 2, "korr": 4, "vex": 4}, str(counts))

	var by_class := _ids(PartCatalog.sorted(cat.filter({"slot": ["arm"]}), "class"))
	_ok("arms light to heavy, ties on id",
			by_class == ["korr_arm_light_L", "bolt_arm_heavy_R", "vex_arm_heavy_L", "vex_arm_heavy_R"], str(by_class))
	var shuffled := cat.filter({"slot": ["arm"]})
	shuffled.reverse()
	_ok("the same order from any start", _ids(PartCatalog.sorted(shuffled, "class")) == by_class)

	var host := cat.get_part("korr_chassis_light")
	var fit_r := _ids(cat.fitting(cat.all(), host, "arm_R", "mech"))
	_ok("Fits: the right arms for a chassis", fit_r == ["bolt_arm_heavy_R", "vex_arm_heavy_R"], str(fit_r))
	var fit_mag := _ids(cat.fitting(cat.all(), cat.get_part("rifle_body"), "magazine", "gun"))
	_ok("Fits: the rifle's magazines", fit_mag == ["mag_wide_30"], str(fit_mag))


func _folders() -> void:
	print("folders")
	_wipe(TMP)
	var official := TMP + "official/"
	var custom := TMP + "custom/"
	_leg("korr_leg_short_L", "light", "L", 1).save_file(official + "mech/korr_leg_short_L/part.json")
	_head("korr_head").save_file(official + "mech/korr_head/part.json")
	var mine := _arm("lukas.spiked_arm.0a1b2c3d", "heavy", "L")
	mine.creator = {"name": "Lukas", "steam_id": "0"}
	mine.source = "official"    # a file that says so: the folder decides
	mine.save_file(custom + "lukas.spiked_arm.0a1b2c3d/part.json")
	var twin := _head("korr_head")
	twin.creator = {"name": "Someone"}
	twin.save_file(custom + "korr_head_copy/part.json")
	DirAccess.make_dir_recursive_absolute(custom + "broken")
	var f := FileAccess.open(custom + "broken/part.json", FileAccess.WRITE)
	f.store_string("{not json")
	f = null

	var cat := PartCatalog.new()
	var n1 := cat.load_dir(official, "official")
	var n2 := cat.load_dir(custom, "custom")
	_ok("two official parts", n1 == 2, str(n1))
	_ok("one custom part: the broken one and the duplicate left out", n2 == 1, str(n2))
	var arm := cat.get_part("lukas.spiked_arm.0a1b2c3d")
	_ok("a custom part is custom whatever its file says", arm != null and arm.source == "custom")
	_ok("custom alone", _ids(cat.filter({"source": ["custom"]})) == ["lukas.spiked_arm.0a1b2c3d"])
	_ok("by creator", _ids(cat.filter({"creator": ["Lukas"]})) == ["lukas.spiked_arm.0a1b2c3d"])
	_ok("custom and official in one list", cat.filter({"family": ["mech"]}).size() == 3)
	_wipe(TMP)


# --- helpers ------------------------------------------------------------------

func _has(problems: PackedStringArray, bit: String) -> bool:
	for p in problems:
		if p.contains(bit):
			return true
	return false


func _ids(list: Array[PartRecord]) -> Array:
	var out := []
	for r in list:
		out.append(r.id)
	return out


func _wipe(dir: String) -> void:
	if not DirAccess.dir_exists_absolute(dir):
		return
	for d in DirAccess.get_directories_at(dir):
		_wipe(dir.path_join(d))
	for file in DirAccess.get_files_at(dir):
		DirAccess.remove_absolute(dir.path_join(file))
	DirAccess.remove_absolute(dir)
