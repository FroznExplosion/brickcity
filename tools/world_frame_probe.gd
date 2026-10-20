extends SceneTree

## WorldFrame (Docs/Planets.md 9.6): world positions go out in the body's
## frame and come back in the scene's, and grid coordinates are left alone.
## The origin is zero in the game today, so only a probe with it moved shows
## whether the conversion is in the right places.
##
##     godot --headless --path . --script tools/world_frame_probe.gd

var failures := 0


func _ok(label: String, cond: bool, detail := "") -> void:
	print("  %s  %s  %s" % ["ok  " if cond else "FAIL", label, detail])
	if not cond:
		failures += 1


func _init() -> void:
	WorldFrame.origin = Vector3(1000.0, 0.0, -500.0)

	var blast := DamageLog.Entry.new()
	blast.kind = DamageLog.Kind.BLAST
	blast.point = Vector3(1.0, 2.0, 3.0)
	var a := blast.to_array()
	_ok("a hit point goes out in the body's frame", a[3] == Vector3(1001.0, 2.0, -497.0), str(a[3]))
	var back := DamageLog.Entry.from_array(a)
	_ok("and comes back where it was", back.point == blast.point, str(back.point))

	var piece := DamageLog.Entry.new()
	piece.kind = DamageLog.Kind.PIECE_BLAST
	piece.point = Vector3(4.0, 5.0, 6.0)
	_ok("a piece command's grid point is not moved", piece.to_array()[3] == piece.point)

	var rest := DamageLog.Entry.new()
	rest.kind = DamageLog.Kind.PIECE_REST
	rest.points = DamageLog.rest_points(Transform3D(Basis(), Vector3(7.0, 8.0, 9.0)))
	var ra := rest.to_array()
	_ok("a resting piece's origin goes out in the body's frame",
		(ra[11] as PackedVector3Array)[0] == Vector3(1007.0, 8.0, -491.0))
	_ok("its basis is not moved", (ra[11] as PackedVector3Array)[1] == Vector3(1, 0, 0))
	_ok("and it comes back", DamageLog.rest_transform(DamageLog.Entry.from_array(ra)).origin
		== Vector3(7.0, 8.0, 9.0))
	_ok("the entry itself is not changed by writing it", rest.points[0] == Vector3(7.0, 8.0, 9.0))

	var t := Transform3D(Basis(Vector3.UP, 0.5), Vector3(-3.0, 1.0, 2.0))
	_ok("a transform round-trips", WorldFrame.xform_from_body(WorldFrame.xform_to_body(t)) == t)

	WorldFrame.origin = Vector3.ZERO
	print("[probe] %s" % ("PASS" if failures == 0 else "FAIL — %d" % failures))
	quit(1 if failures > 0 else 0)
