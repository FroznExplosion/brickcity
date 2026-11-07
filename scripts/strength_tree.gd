class_name StrengthTree
extends RefCounted

## Where a brick build comes apart: its bricks clustered by joint strength into
## a tree, baked once (Docs/DestructionFirstPrinciples.md A5, B3.1).
##
## PROTOTYPE, script only, for tools/strength_tree_probe.gd. Nothing in the game
## calls it yet. If the probe shows it finds better break lines than
## IslandManager._weak_seam, the bake moves into BrickWorld (C++, over the real
## JointCache) and _snap_across asks it where to cut.
##
## Bake: every live structural block starts as its own cluster; the two joined
## clusters with the most studs between them, per pair of blocks across, are
## merged, again and again, until no joined pair is left. Each merge is a node.
## Because clusters merge only across joints, every node is a connected set of
## bricks. A node's `studs` is the total of the joints between its two children:
## what it takes to pull them apart.
##
## Normalised, not total: a total-studs order would merge the last single brick
## on two studs after whole storeys, so the top of the tree would be "a brick
## falls off". Scored per block of the smaller side (Score.MIN) one cluster
## swallows single bricks first and the top of the tree peels ends off; scored
## per PAIR of blocks across (Score.PRODUCT, average linkage, the default) the
## top is balanced parts: a running-bond wall halves up its length, a tower
## parts into storeys. Measured in tools/strength_tree_probe.gd.
##
## Split: a hit of energy E at a point walks a node down from the top. A cut
## that the energy reaching it (E x falloff by distance) beats is made, its
## cost taken off, and both children are walked with what is left. A soft hit
## makes one or two pieces, a hard one several; nothing is special-cased.
##
## Studs here are footprint overlaps of two blocks one on the other (from their
## boxes), which is exact for box parts and an over-count for masked ones.

## Leaves are 0..n-1 (index into `blocks`); internal nodes follow, in merge order.
var blocks := PackedInt32Array()      ## leaf -> block id in the chunk
var left := PackedInt32Array()        ## -1 for a leaf
var right := PackedInt32Array()
var parent := PackedInt32Array()
var size := PackedInt32Array()        ## blocks under the node
var studs := PackedInt32Array()       ## joints between the two children, in studs
var cut_sum: Array[Vector3] = []      ## stud-weighted sum of those joints' centres, grid units
var roots := PackedInt32Array()       ## one per connected part of the build
var bake_ms := 0.0

## Joints, one entry each: blocks as leaf indices, studs, centre in grid units
## (x, z in studs, y in plates).
var joint_a := PackedInt32Array()
var joint_b := PackedInt32Array()
var joint_studs := PackedInt32Array()
var joint_at: Array[Vector3] = []

var _leaf_of := {}                    ## block id -> leaf index

## Heap of [score, tiebreak, a, b, version_a, version_b], max first.
var _heap: Array = []


static func bake(w: BrickWorld, chunk: int) -> StrengthTree:
	var t := StrengthTree.new()
	t._bake(w, chunk)
	return t


func node_count() -> int:
	return left.size()


func is_leaf(node: int) -> bool:
	return left[node] < 0


## The cut's centre in grid units (studs, plates, studs).
func cut_centre(node: int) -> Vector3:
	if is_leaf(node) or studs[node] <= 0:
		return Vector3.ZERO
	return cut_sum[node] / float(studs[node])


## Leaf indices under `node`.
func leaves(node: int) -> PackedInt32Array:
	var out := PackedInt32Array()
	var stack := [node]
	while not stack.is_empty():
		var n: int = stack.pop_back()
		if left[n] < 0:
			out.append(n)
		else:
			stack.append(left[n])
			stack.append(right[n])
	return out


## Block ids under `node`.
func node_blocks(node: int) -> PackedInt32Array:
	var out := PackedInt32Array()
	for l in leaves(node):
		out.append(blocks[l])
	return out


## Internal nodes from the top of the tree down: the last merges first, which
## are the first cuts a build makes.
func top_cuts(count: int) -> PackedInt32Array:
	var out := PackedInt32Array()
	var n := node_count() - 1
	while n >= blocks.size() and out.size() < count:
		out.append(n)
		n -= 1
	return out


## The y range (plates) of the joints `node` cuts: one value for a clean
## horizontal seam, a spread for a cut that steps or runs up the build.
func cut_y_range(node: int) -> Vector2:
	var in_left := {}
	for l in leaves(left[node]):
		in_left[l] = true
	var in_right := {}
	for l in leaves(right[node]):
		in_right[l] = true
	var lo := INF
	var hi := -INF
	for j in joint_a.size():
		var a := joint_a[j]
		var b := joint_b[j]
		if (in_left.has(a) and in_right.has(b)) or (in_left.has(b) and in_right.has(a)):
			lo = minf(lo, joint_at[j].y)
			hi = maxf(hi, joint_at[j].y)
	return Vector2(lo, hi)


## Pieces a hit makes of `node`: node ids whose blocks move as one each.
##
## `energy` is in stud-strengths: a cut of S studs costs S. `at` is in grid
## units (as cut_centre). `falloff_m`: the distance in metres at which half the
## energy still reaches a cut.
func split(node: int, energy: float, at: Vector3, falloff_m: float) -> PackedInt32Array:
	var cell := BrickWorld.get_cell_size()
	var at_m := at * cell
	var out := PackedInt32Array()
	var stack := [[node, energy]]
	while not stack.is_empty():
		var top: Array = stack.pop_back()
		var n: int = top[0]
		var e: float = top[1]
		if is_leaf(n):
			out.append(n)
			continue
		var d := (cut_centre(n) * cell).distance_to(at_m)
		var f := 1.0 / (1.0 + (d / falloff_m) * (d / falloff_m))
		var need := float(studs[n])
		if e * f <= need:
			out.append(n)
			continue
		# What is left is shared by size: energy is spent, not copied, so a
		# hit makes a few parts rather than cascading into many.
		var rest := e - need / f
		var share := float(size[left[n]]) / float(size[n])
		stack.append([left[n], rest * share])
		stack.append([right[n], rest * (1.0 - share)])
	return out


# --- bake ---------------------------------------------------------------------

func _bake(w: BrickWorld, chunk: int) -> void:
	var t0 := Time.get_ticks_usec()
	var cell := BrickWorld.get_cell_size()
	var lo_of: Array[Vector3i] = []
	var hi_of: Array[Vector3i] = []
	var live := PackedInt32Array()
	for g in w.get_components(chunk):
		live.append_array(g)
	live.sort()
	for id in live:
		if w.is_block_decorative(chunk, id):
			continue
		var box: AABB = w.get_blocks_box(chunk, PackedInt32Array([id]))
		_leaf_of[id] = blocks.size()
		blocks.append(id)
		lo_of.append(Vector3i((box.position / cell).round()))
		hi_of.append(Vector3i((box.end / cell).round()))
	var n := blocks.size()

	# Joints: get_block_neighbours is "one sits on the other, footprints overlap".
	for la in n:
		for nb in w.get_block_neighbours(chunk, blocks[la]):
			if not _leaf_of.has(nb):
				continue
			var lb: int = _leaf_of[nb]
			if lb <= la:
				continue
			var a_lo := lo_of[la]
			var a_hi := hi_of[la]
			var b_lo := lo_of[lb]
			var b_hi := hi_of[lb]
			var ox := mini(a_hi.x, b_hi.x) - maxi(a_lo.x, b_lo.x)
			var oz := mini(a_hi.z, b_hi.z) - maxi(a_lo.z, b_lo.z)
			if ox <= 0 or oz <= 0:
				continue
			var y := float(a_hi.y) if a_lo.y < b_lo.y else float(b_hi.y)
			joint_a.append(la)
			joint_b.append(lb)
			joint_studs.append(ox * oz)
			joint_at.append(Vector3(
					(maxi(a_lo.x, b_lo.x) + mini(a_hi.x, b_hi.x)) * 0.5, y,
					(maxi(a_lo.z, b_lo.z) + mini(a_hi.z, b_hi.z)) * 0.5))

	# Leaves.
	var adj: Array = []      ## node -> {other node: Vector4(sum x, sum y, sum z, studs)}
	var version := PackedInt32Array()
	for i in n:
		left.append(-1)
		right.append(-1)
		parent.append(-1)
		size.append(1)
		studs.append(0)
		cut_sum.append(Vector3.ZERO)
		adj.append({})
		version.append(0)
	for j in joint_a.size():
		var a := joint_a[j]
		var b := joint_b[j]
		var s := float(joint_studs[j])
		var v := Vector4(joint_at[j].x * s, joint_at[j].y * s, joint_at[j].z * s, s)
		adj[a][b] = adj[a].get(b, Vector4.ZERO) + v
		adj[b][a] = adj[b].get(a, Vector4.ZERO) + v
	for a in n:
		for b in adj[a]:
			if a < b:
				_push(_score(adj[a][b].w, 1, 1), a, b, 0, 0)

	# Merge.
	while not _heap.is_empty():
		var e: Array = _pop()
		var a: int = e[2]
		var b: int = e[3]
		if parent[a] >= 0 or parent[b] >= 0 or version[a] != e[4] or version[b] != e[5]:
			continue
		var between: Vector4 = adj[a][b]
		var c := left.size()
		left.append(a)
		right.append(b)
		parent.append(-1)
		parent[a] = c
		parent[b] = c
		size.append(size[a] + size[b])
		studs.append(int(round(between.w)))
		cut_sum.append(Vector3(between.x, between.y, between.z))
		version.append(0)
		# The bigger map is taken over, the smaller added into it.
		var big: Dictionary = adj[a] if adj[a].size() >= adj[b].size() else adj[b]
		var small: Dictionary = adj[b] if big == adj[a] else adj[a]
		big.erase(a)
		big.erase(b)
		for x in small:
			if x == a or x == b:
				continue
			big[x] = big.get(x, Vector4.ZERO) + small[x]
		adj[a] = {}
		adj[b] = {}
		adj.append(big)
		# Pairs not touching a or b keep their sizes and so their scores; the
		# ones that did are dead (parent set) and come back as pairs with c.
		for x in big:
			var nx: Dictionary = adj[x]
			nx.erase(a)
			nx.erase(b)
			nx[c] = big[x]
			_push(_score(big[x].w, size[c], size[x]), c, x, 0, 0)

	for i in node_count():
		if parent[i] < 0:
			roots.append(i)
	bake_ms = (Time.get_ticks_usec() - t0) / 1000.0


## How eagerly two joined clusters merge (higher first). MIN: studs per block
## of the smaller one. PRODUCT: studs per pair of blocks across (average
## linkage) -- a big cluster no longer swallows single bricks first, so the top
## of the tree is balanced parts. The probe compares them.
enum Score { MIN, PRODUCT }
static var score_mode := Score.PRODUCT


static func _score(s: float, size_a: int, size_b: int) -> float:
	if score_mode == Score.MIN:
		return s / float(mini(size_a, size_b))
	return s / (float(size_a) * float(size_b))


func _push(score: float, a: int, b: int, va: int, vb: int) -> void:
	var lo := mini(a, b)
	var hi := maxi(a, b)
	var item := [score, -(lo * 1000003 + hi), lo, hi,
			va if lo == a else vb, vb if lo == a else va]
	_heap.append(item)
	var i := _heap.size() - 1
	while i > 0:
		var p := (i - 1) >> 1
		if not _above(_heap[i], _heap[p]):
			break
		var tmp = _heap[p]
		_heap[p] = _heap[i]
		_heap[i] = tmp
		i = p


func _pop() -> Array:
	var top: Array = _heap[0]
	var last: Array = _heap.pop_back()
	if _heap.is_empty():
		return top
	_heap[0] = last
	var i := 0
	var count := _heap.size()
	while true:
		var l := i * 2 + 1
		var r := l + 1
		var best := i
		if l < count and _above(_heap[l], _heap[best]):
			best = l
		if r < count and _above(_heap[r], _heap[best]):
			best = r
		if best == i:
			break
		var tmp = _heap[best]
		_heap[best] = _heap[i]
		_heap[i] = tmp
		i = best
	return top


static func _above(x: Array, y: Array) -> bool:
	if x[0] != y[0]:
		return x[0] > y[0]
	return x[1] > y[1]
