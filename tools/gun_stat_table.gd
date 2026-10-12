extends SceneTree

## Rolls many guns of every class, kind and rarity and writes the worst and best of each
## stat as Markdown tables (Docs/Weapons/AIM_ASSIST.md section 9.3 is its
## output). Rerun after changing any gun number:
##
##     godot --headless --path . --script res://tools/gun_stat_table.gd -- [out.md] [rolls]
##
## Stats are tier 1; damage and DPS scale by Tier.power_mult (x1.25 a tier), checked here.

const GUNS := [&"pistol", &"revolver", &"smg", &"rifle", &"lmg", &"dmr", &"sniper", &"shotgun"]
const ORDNANCE := [&"grenade", &"rocket_launcher", &"grenade_launcher", &"mine_layer", &"drone",
		&"arc_caster"]


func _init() -> void:
	var args := OS.get_cmdline_user_args()
	var out := args[0] if args.size() > 0 else "user://gun_stat_table.md"
	var n := int(args[1]) if args.size() > 1 else 400
	var lib := GunPlaceholderParts.build_library()
	var md := PackedStringArray()

	# The tier step, measured: the same seed at tier 1 and tier 10.
	var a := GunGenerator.generate(lib, 1234, WeaponClass.builtin(&"rifle").with_kind(&"light"), 1, 3)
	var b := GunGenerator.generate(lib, 1234, WeaponClass.builtin(&"rifle").with_kind(&"light"), 10, 3)
	var other_same := true
	for k in a.stats:
		if k != &"damage" and not is_equal_approx(float(a.stats[k]), float(b.stats[k])):
			other_same = false
	md.append("Tier check: rifle seed 1234, tier 10 / tier 1 damage = %.3f (Tier.power_mult(10) = %.3f); other stats the same: %s."
			% [float(b.stats[&"damage"]) / float(a.stats[&"damage"]), Tier.power_mult(10), other_same])
	md.append("")

	for cls in GUNS:
		var wc0 := WeaponClass.builtin(cls)
		var kinds: Array = [&"light", &"heavy"]
		if (WeaponClass.KINDS.get(cls, {}) as Dictionary).has(&"auto"):
			kinds.append(&"auto")
		md.append("#### %s" % String(cls).capitalize())
		md.append("")
		md.append("| Kind | Rarity | Damage / shot | Fire rate /s | DPS | Accuracy | Hip spread | ADS spread | Range m | Reload s | Magazine | Crit x |")
		md.append("|---|---|---|---|---|---|---|---|---|---|---|---|")
		for kind in kinds:
			var wc := wc0.with_kind(kind)
			var kname := wc.kind_name() if wc.has_method(&"kind_name") else String(kind)
			for r in range(1, 7):
				var lo := {}
				var hi := {}
				for i in n:
					var res := GunGenerator.generate(lib, 100000 + i * 7919 + r * 31, wc, 1, r)
					var s := res.stats
					var acc := float(s.get(&"accuracy", 0.0))
					var row := {
						"dmg": float(s.get(&"damage", 0.0)),
						"fr": float(s.get(&"fire_rate", 0.0)),
						"dps": float(s.get(&"damage", 0.0)) * float(s.get(&"fire_rate", 0.0)),
						"acc": acc,
						"hip": GunController.MAX_SPREAD_DEG * (1.0 - acc) * PlayerView.HIP_SPREAD,
						"ads": GunController.MAX_SPREAD_DEG * (1.0 - acc) * PlayerView.ADS_SPREAD,
						"rng": GunRange.of(res.weapon_class, s, res.fire),
						"rl": float(s.get(&"reload_time", 0.0)),
						"mag": float(s.get(&"mag_size", 0.0)),
						"crit": float(s.get(&"crit_mult", 0.0)),
					}
					for k in row:
						lo[k] = minf(float(lo.get(k, INF)), row[k])
						hi[k] = maxf(float(hi.get(k, -INF)), row[k])
				md.append("| %s | %s | %s | %s | %s | %s | %s | %s | %s | %s | %s | %s |" % [
					kname, Rarity.NAMES[r - 1],
					_span(lo.dmg, hi.dmg, "%.1f"), _span(lo.fr, hi.fr, "%.2f"), _span(lo.dps, hi.dps, "%.0f"),
					_span(lo.acc * 100.0, hi.acc * 100.0, "%.0f%%"),
					_span(hi.hip, lo.hip, "%.2f°"), _span(hi.ads, lo.ads, "%.2f°"),
					_span(lo.rng, hi.rng, "%.0f"), _span(hi.rl, lo.rl, "%.2f"),
					_span(lo.mag, hi.mag, "%.0f"), _span(lo.crit, hi.crit, "%.2f")])
		md.append("")

	md.append("#### Ordnance")
	md.append("")
	md.append("| Class | Rarity | Damage | Cooldown s | Charges | Blast m |")
	md.append("|---|---|---|---|---|---|")
	for cls in ORDNANCE:
		var wc := WeaponClass.builtin(cls)
		for r in [1, 6]:
			var lo := {}
			var hi := {}
			for i in n:
				var s := GunGenerator.generate(lib, 200000 + i * 7919 + r * 31, wc, 1, r).stats
				var row := {"dmg": float(s.get(&"damage", 0.0)), "cd": float(s.get(&"cooldown", 0.0)),
						"ch": float(s.get(&"mag_size", 0.0)), "bl": float(s.get(&"blast_radius", 0.0))}
				for k in row:
					lo[k] = minf(float(lo.get(k, INF)), row[k])
					hi[k] = maxf(float(hi.get(k, -INF)), row[k])
			md.append("| %s | %s | %s | %s | %s | %s |" % [String(cls).capitalize(), Rarity.NAMES[r - 1],
					_span(lo.dmg, hi.dmg, "%.0f"), _span(hi.cd, lo.cd, "%.2f"), _span(lo.ch, hi.ch, "%.0f"),
					_span(lo.bl, hi.bl, "%.1f")])
	md.append("")

	var f := FileAccess.open(out, FileAccess.WRITE)
	f.store_string("\n".join(md))
	f.close()
	print("gun stat table: %s (%d rolls a row)" % [out, n])
	quit(0)


## "worst – best", the worst first.
static func _span(worst: float, best: float, fmt: String) -> String:
	var w := fmt % worst
	var b := fmt % best
	return w if w == b else "%s – %s" % [w, b]
