extends SceneTree

## Pictures of a beach hole filling from the sea (Docs/Water.md 12).
##
##     godot --path . --script res://tools/pools_shot.gd -- --no-trees
##
## Digs a hole into the beach nearest the origin, through to the sea, and
## photographs it just after, while it fills, and once it is still:
## shots/pool_0.png, then pool_10/25/50/100.png at 1, 2.5, 5 and 10 s.

var _plate := 0.14
var _stud := 0.35
var _sea := 0.0


func _initialize() -> void:
	_run.call_deferred()


func _bare(x: int, z: int) -> float:
	return float(BrickTerrain.generated_plate(x, z) + 1) * _plate


## The beach column nearest the origin with the sea one stud east of it.
func _find_beach() -> Vector2i:
	var best := Vector2i(1 << 30, 0)
	var best_d := INF
	for z in range(-1400, 1400, 13):
		for x in range(-1400, 1400, 24):
			if _bare(x, z) < _sea or _bare(x + 24, z) >= _sea:
				continue
			var w := x
			while w < x + 24 and _bare(w + 1, z) >= _sea:
				w += 1
			var g := _bare(w, z)
			if g < _sea + 0.15 or g > _sea + 1.0 or _bare(w + 4, z) > _sea - 0.4:
				continue
			var d := Vector2(w, z).length()
			if d < best_d:
				best_d = d
				best = Vector2i(w, z)
	return best


func _shot(name: String) -> void:
	await RenderingServer.frame_post_draw
	root.get_viewport().get_texture().get_image().save_png("res://shots/%s.png" % name)
	print("[pools] shot %s  (%.2f m3 in pools, %d ticked)"
			% [name, BrickPools.total_volume(), BrickPools.active_count()])


func _run() -> void:
	var scene: Node3D = load("res://scenes/heightfield_test.tscn").instantiate()
	root.add_child(scene)
	for i in 10:
		await process_frame
	_plate = BrickWorld.get_plate_metres()
	_stud = BrickWorld.get_stud_metres()
	_sea = BrickWave.get_sea_level()
	var beach := _find_beach()
	print("[pools] sea %.2f m, beach at %s" % [_sea, beach])
	if beach.x >= (1 << 29):
		quit(1)
		return
	var tile := BrickTerrain.get_tile_studs()
	var hole := Rect2i(beach.x - 9, beach.y - 4, 10, 9)
	var centre := Vector3((hole.get_center().x) * _stud, _sea, hole.get_center().y * _stud)
	var cam: Camera3D = scene._camera
	# Over the land side, looking down across the hole to the sea.
	var land := float(BrickTerrain.surface_plate(hole.position.x - 12, hole.get_center().y) + 1) * _plate
	cam.global_position = Vector3(centre.x - 4.0, maxf(land, _sea) + 3.0, centre.z + 3.0)
	cam.look_at(centre + Vector3(2.5, -1.0, -0.5))
	scene._streamer.settle(Vector2(centre.x, centre.z))
	for i in 30:
		await process_frame
	await _shot("pool_before")
	# Dig it, as the editor's brush would: the sculpt layer, then the scene
	# told the field changed there.
	var t0 := Vector2i(floori(float(hole.position.x) / tile), floori(float(hole.position.y) / tile))
	var t1 := Vector2i(floori(float(hole.end.x - 1) / tile), floori(float(hole.end.y - 1) / tile))
	for tz in range(t0.y, t1.y + 1):
		for tx in range(t0.x, t1.x + 1):
			var arr: PackedFloat32Array = BrickTerrain.get_sculpt_tile(tx, tz)
			if arr.size() != tile * tile:
				arr = PackedFloat32Array()
				arr.resize(tile * tile)
			for lz in tile:
				for lx in tile:
					var p := Vector2i(tx * tile + lx, tz * tile + lz)
					if hole.has_point(p):
						# Deeper in the middle, a crater rather than a box.
						var dx := absf(p.x - hole.get_center().x) / (hole.size.x * 0.5)
						var dz := absf(p.y - hole.get_center().y) / (hole.size.y * 0.5)
						arr[lz * tile + lx] = -(1.0 + 1.4 * (1.0 - maxf(dx, dz)))
			BrickTerrain.set_sculpt_tile(tx, tz, arr)
	scene._streamer.invalidate(Rect2i(t0, t1 - t0 + Vector2i.ONE))
	scene.terrain_changed(hole)
	scene._streamer.settle(Vector2(centre.x, centre.z))
	await _shot("pool_0")
	var t := 0.0
	for k in [1.0, 2.5, 5.0, 10.0]:
		await create_timer(k - t).timeout
		t = k
		await _shot("pool_%d" % int(k * 10))
	# Leave the world file as it was: the sculpt was only for the pictures.
	BrickTerrain.clear_sculpt()
	quit(0)
