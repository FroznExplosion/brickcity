extends SceneTree

## Where a build comes apart, from its joints (StrengthTree, prototype).
## Docs/DestructionFirstPrinciples.md A5 and B3.1.
##
##     godot --headless --path . --script tools/strength_tree_probe.gd
##
## The question this answers before any game code changes: does a tree baked
## from stud joints find the break lines a brick model has, better than one
## seam per landing (IslandManager._weak_seam)? So it checks:
##
##   * the stud count of a joint (two bricks), and that it agrees with
##     BrickWorld.seam_studs wherever the tree cuts a clean course boundary;
##   * every node of the tree is one connected set of bricks (a piece can move
##     as one), and the roots cover every structural brick;
##   * the top of the tree is big parts, not single bricks falling off (the
##     reason merges are normalised by size; Score.PRODUCT);
##   * a long low wall (lying, to _weak_seam: no seam across it) parts across
##     its length, which one horizontal seam cannot do;
##   * a harder hit makes at least as many pieces, and pieces partition the
##     part they came from.
##
## And it prints, for the recipe tower and the shipped workshop builds, the
## first cuts (sizes, studs, height) beside seam_studs' counts, and the bake
## time -- in GDScript, so only an upper bound for the C++ bake it would become.

var _pass := 0
var _fail := 0
var _w: BrickWorld
var _palette: Dictionary


func _initialize() -> void:
	print("where a build comes apart, from its joints")
	_w = BrickWorld.new()
	_palette = TowerRecipe.bake_palette(_w)
	_two_bricks()
	_long_wall()
	_tower()
	for path in ["res://builds/cottage.json", "res://builds/watchtower.json",
			"res://builds/kiosk.json", "res://builds/garden_wall.json"]:
		_build(path)
	print("\nstrength_tree_probe: %d passed, %d failed" % [_pass, _fail])
	quit(1 if _fail > 0 else 0)


func _ok(what: String, cond: bool, detail := "") -> void:
	if cond:
		_pass += 1
		print("  ok   %s%s" % [what, ("  " + detail) if detail else ""])
	else:
		_fail += 1
		print("  FAIL %s%s" % [what, (" -- " + detail) if detail else ""])


# --- checks shared by every build ----------------------------------------------

## Every node a connected set: walk its leaves over the joints among them.
func _all_connected(t: StrengthTree, sample: int) -> int:
	var nbrs: Array = []
	nbrs.resize(t.blocks.size())
	for i in t.blocks.size():
		nbrs[i] = PackedInt32Array()
	for j in t.joint_a.size():
		nbrs[t.joint_a[j]].append(t.joint_b[j])
		nbrs[t.joint_b[j]].append(t.joint_a[j])
	var bad := 0
	var step := maxi(1, (t.node_count() - t.blocks.size()) / maxi(1, sample))
	var n := t.blocks.size()
	while n < t.node_count():
		var ls := t.leaves(n)
		var inside := {}
		for l in ls:
			inside[l] = true
		var seen := {ls[0]: true}
		var q := [ls[0]]
		while not q.is_empty():
			var x: int = q.pop_back()
			for y in nbrs[x]:
				if inside.has(y) and not seen.has(y):
					seen[y] = true
					q.append(y)
		if seen.size() != ls.size():
			bad += 1
		n += step
	return bad


func _covered(t: StrengthTree) -> bool:
	var total := 0
	for r in t.roots:
		total += t.size[r]
	return total == t.blocks.size()


func _biggest_root(t: StrengthTree) -> int:
	var best := t.roots[0]
	for r in t.roots:
		if t.size[r] > t.size[best]:
			best = r
	return best


## The first `count` cuts under `root`, top down (breadth first by merge order).
func _cuts_under(t: StrengthTree, root: int, count: int) -> PackedInt32Array:
	var out := PackedInt32Array()
	var open := [root]
	while not open.is_empty() and out.size() < count:
		# The latest merge among the open nodes is the next cut.
		open.sort()
		var n: int = open.pop_back()
		if t.is_leaf(n):
			continue
		out.append(n)
		open.append(t.left[n])
		open.append(t.right[n])
	return out


func _print_cuts(chunk: int, t: StrengthTree, root: int, count: int) -> void:
	print("    first cuts of the biggest part (%d bricks):" % t.size[root])
	print("      #   smaller  larger  studs  y plates     seam_studs at y [studs, through, through_studs]")
	var i := 0
	for n in _cuts_under(t, root, count):
		var yr := t.cut_y_range(n)
		var a: int = t.size[t.left[n]]
		var b: int = t.size[t.right[n]]
		var seam := ""
		if yr.x == yr.y:
			seam = str(_w.seam_studs(chunk, int(yr.x), int(yr.x)))
		print("      %-3d %-8d %-7d %-6d %-12s %s" % [i, mini(a, b), maxi(a, b), t.studs[n],
				("%d" % yr.x) if yr.x == yr.y else ("%d-%d" % [yr.x, yr.y]), seam])
		i += 1


## Where the tree cuts a whole course boundary cleanly, its count must be
## seam_studs' (nothing running through, every stud meeting there).
func _agrees_with_seams(chunk: int, t: StrengthTree, root: int, count: int) -> Array:
	var checked := 0
	var wrong := []
	for n in _cuts_under(t, root, count):
		var yr := t.cut_y_range(n)
		if yr.x != yr.y:
			continue
		var s: PackedInt32Array = _w.seam_studs(chunk, int(yr.x), int(yr.x))
		if s[1] != 0:
			continue
		# Only cuts that take the WHOLE boundary are seams; a cut of part of it
		# (one wall of a corner) has fewer.
		if t.studs[n] != s[0]:
			# Count the boundary's joints inside this node to tell the two apart.
			var inside := 0
			var in_node := {}
			for l in t.leaves(n):
				in_node[l] = true
			for j in t.joint_a.size():
				if t.joint_at[j].y == yr.x and in_node.has(t.joint_a[j]) and in_node.has(t.joint_b[j]):
					inside += t.joint_studs[j]
			if inside == s[0]:
				wrong.append("y %d: tree %d, seam %d" % [yr.x, t.studs[n], s[0]])
			continue
		checked += 1
	return [checked, wrong]


## Pieces made by hits of rising energy at `at`.
func _hits(t: StrengthTree, root: int, at: Vector3, label: String) -> void:
	var counts := PackedInt32Array()
	var partitions := true
	var line := ""
	for times in [0.25, 0.5, 1.0, 2.0, 4.0, 8.0, 16.0]:
		var e: float = float(t.studs[root]) * times
		var pieces := t.split(root, e, at, 2.0)
		var total := 0
		var sizes := PackedInt32Array()
		for p in pieces:
			total += t.size[p]
			sizes.append(t.size[p])
		if total != t.size[root]:
			partitions = false
		sizes.sort()
		sizes.reverse()
		var big := 0
		for s in sizes:
			if s > 8:
				big += 1
		counts.append(pieces.size())
		line += "\n      x%-5s %3d pieces, %2d over 8 bricks, biggest %s" % [times, pieces.size(),
				big, str(Array(sizes.slice(0, 5)))]
	print("    hits at %s (energy = root's studs x):%s" % [label, line])
	var rising := true
	for i in range(1, counts.size()):
		if counts[i] < counts[i - 1]:
			rising = false
	_ok("a harder hit makes at least as many pieces", rising, str(counts))
	_ok("the pieces are the part, every brick once", partitions)


func _common(chunk: int, t: StrengthTree, what: String) -> void:
	print("    %d bricks, %d joints, %d parts, bake %.1f ms (GDScript)" % [t.blocks.size(),
			t.joint_a.size(), t.roots.size(), t.bake_ms])
	_ok("%s: the roots cover every structural brick" % what, _covered(t))
	var bad := _all_connected(t, 400)
	_ok("%s: every node checked is one connected piece" % what, bad == 0, "%d not" % bad)


# --- builds ---------------------------------------------------------------------

func _two_bricks() -> void:
	print("\ntwo bricks")
	var c := _w.create_chunk(Vector3i.ZERO, Vector3i(16, 16, 16))
	_w.place_block(c, Vector3i(0, 0, 0), _palette["brick_2x4_x"], 4)
	_w.place_block(c, Vector3i(0, 3, 0), _palette["brick_2x4_x"], 5)
	var t := StrengthTree.bake(_w, c)
	_ok("one joint of eight studs", t.joint_a.size() == 1 and t.joint_studs[0] == 8,
			str(t.joint_studs))
	_ok("one root holding both, eight studs to part them",
			t.roots.size() == 1 and t.studs[t.roots[0]] == 8)
	var c2 := _w.create_chunk(Vector3i.ZERO, Vector3i(16, 16, 16))
	_w.place_block(c2, Vector3i(0, 0, 0), _palette["brick_2x4_x"], 4)
	_w.place_block(c2, Vector3i(2, 3, 0), _palette["brick_2x4_x"], 5)
	var t2 := StrengthTree.bake(_w, c2)
	_ok("half over the edge, four", t2.joint_studs.size() == 1 and t2.joint_studs[0] == 4,
			str(t2.joint_studs))
	_ok("matches seam_studs", t2.joint_studs.size() == 1
			and t2.joint_studs[0] == _w.seam_studs(c2, 3, 3)[0])


## 40 studs long, 2 deep, 10 courses, running bond: lying on its face, to
## _weak_seam it has no seam across its length. It should part across it.
func _long_wall() -> void:
	print("\na long low wall, running bond")
	var c := _w.create_chunk(Vector3i.ZERO, Vector3i(44, 40, 4))
	for course in 10:
		var x := 0 if course % 2 == 0 else 2
		if x == 2:
			_w.place_block(c, Vector3i(0, course * 3, 0), _palette["brick_2x2"], 4)
		while x + 4 <= 40:
			_w.place_block(c, Vector3i(x, course * 3, 0), _palette["brick_2x4_x"], 4)
			x += 4
		if x < 40:
			_w.place_block(c, Vector3i(x, course * 3, 0), _palette["brick_2x2"], 4)
	var t := StrengthTree.bake(_w, c)
	_common(c, t, "wall")
	var root := _biggest_root(t)
	_print_cuts(c, t, root, 6)
	var first := _cuts_under(t, root, 1)[0]
	var yr := t.cut_y_range(first)
	var cc := t.cut_centre(first)
	_ok("its first cut runs up the wall, not along a course", yr.y - yr.x >= 6.0,
			"y %s, at x %.1f" % [yr, cc.x])
	var small := mini(t.size[t.left[first]], t.size[t.right[first]])
	_ok("and parts it into two real halves, not a corner brick", small >= t.size[root] / 5,
			"%d of %d" % [small, t.size[root]])
	var h_studs: int = _w.seam_studs(c, 15, 15)[0]
	print("    a course boundary across the middle holds %d studs; the first cut %d" % [h_studs,
			t.studs[first]])
	_hits(t, root, Vector3(0.0, 0.0, 1.0), "one end, at the foot")


func _tower() -> void:
	print("\nthe recipe tower (28 x 16, 30 storeys)")
	var c := _w.create_chunk(Vector3i.ZERO, TowerRecipe.chunk_dims(28, 16, 30))
	TowerRecipe.build(_w, c, _palette, 28, 16, 30)
	var t := StrengthTree.bake(_w, c)
	_common(c, t, "tower")
	var root := _biggest_root(t)
	_print_cuts(c, t, root, 16)
	var r := _agrees_with_seams(c, t, root, 40)
	_ok("where it cuts a whole course boundary, its studs are seam_studs'",
			(r[1] as Array).is_empty(), "%d checked %s" % [r[0], r[1]])
	# A small part on very few studs IS the weakest thing and may come off
	# early (6 bricks on 4 studs at a storey line); what must not happen is the
	# top of the tree being only that. The first cut is a big part.
	var first := _cuts_under(t, root, 1)[0]
	var small := mini(t.size[t.left[first]], t.size[t.right[first]])
	_ok("its first cut parts big pieces, not a brick or two", small >= t.size[root] / 5,
			"%d of %d" % [small, t.size[root]])
	var tiny := 0
	for n in _cuts_under(t, root, 8):
		if mini(t.size[t.left[n]], t.size[t.right[n]]) < 20:
			tiny += 1
	print("    of its first eight cuts, %d take off under 20 bricks" % tiny)
	# Windows and storey lines near the bottom, as seam_probe reads them.
	var per: int = TowerRecipe.STOREY_PLATES
	var window_k := per + TowerRecipe.SLAB_PLATES + 3 * 3
	print("    seam_studs: storey line y %d %s, window row y %d %s" % [per,
			str(_w.seam_studs(c, per, per)), window_k, str(_w.seam_studs(c, window_k, window_k))])
	_hits(t, root, Vector3(0.0, float(per) * 2.0, 0.0), "a corner, second storey")


func _build(path: String) -> void:
	print("\n%s" % path.get_file())
	var r := BuildRecipe.load_from(path)
	if r == null:
		_ok("%s loads" % path.get_file(), false)
		return
	var c := _w.create_chunk(Vector3i.ZERO, r.chunk_dims())
	var placed := r.build(_w, c, _palette)
	if placed < r.size():
		print("    (placed %d of %d: the tower palette lacks some parts; the tree is of what was placed)"
				% [placed, r.size()])
	if placed == 0:
		return
	var t := StrengthTree.bake(_w, c)
	_common(c, t, path.get_file())
	var root := _biggest_root(t)
	_print_cuts(c, t, root, 8)
	var box := _w.get_blocks_box(c, t.node_blocks(root))
	var at := box.position / BrickWorld.get_cell_size()
	_hits(t, root, at, "a bottom corner")
