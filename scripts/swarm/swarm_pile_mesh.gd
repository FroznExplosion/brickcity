class_name SwarmPileMesh
extends Node3D
## Turns each corpse pile into a mound of ground instead of a scatter of bodies.
##
## The pile's shape is a lattice, and a cone's upper layers are single rings — a hollow shell.
## Drawn as individual bodies that reads, from the side, as corpses floating in an arc with air
## between them. The bulk of a heap is not something you can see anyway; what you can see is its
## *surface*.
##
## So: build a heightfield over the pile's cells, smooth it, and mesh it — the same technique as
## a terrain system, scoped to a few metres. Terrain3D itself is an editor-sculpt GDExtension and
## ceramicedge's ForgeTerrain is welded to Forge's story/bake/stream pipeline; neither wants to
## be a runtime prop that appears, grows and gets blown apart mid-fight. The technique ports, the
## dependency does not.
##
## The core then draws only the bodies on the crest (`set_pile_mesh_mode(true)`), so what you see
## is a mound of dead with a layer of actual corpses lying over it. The mesh doubles as the
## collider, so the mound is climbable — by the horde and by the player.

const CELL := 0.34          ## heightfield resolution, metres
const PAD := 0.8            ## margin around the pile's footprint, so the mound has skirts
const BUMP_RADIUS := 0.85   ## how far one body's mass spreads
const BUMP_HEIGHT := 0.80   ## how far it stands above its own cell. Must clear the offset the
                            ## core draws a prone body at (~0.57) plus SINK, or the crest bodies
                            ## hover above a surface that stops short of them
const SMOOTH_PASSES := 3
const MIN_HEIGHT := 0.26    ## below this the mound is not drawn — trims the flat fringe
                            ## that smoothing spreads out around the base
const SINK := 0.22          ## drop the whole mound this far into the ground, so its cut edge is
                            ## buried and you see a heap rising out of the floor, not a shell
                            ## sitting on it
const PEAK_KEEP := 0.90     ## how much of the unblurred dome to restore after smoothing
const LUMP := 0.13          ## height of the random lumpiness on the heap, metres
const LIMBS_PER_BODY := 1.6 ## protruding arms/legs scattered per corpse in the pile
const LIMB_LEN := 0.40

## Ground height under a point, for when this project gets a real terrain (the ceramicedge
## level editor is the plan). Leave unset and everything sits on y = 0 as it does today; set it
## to `func(x, z) -> float` and the piles heap on whatever the ground is actually doing —
## nothing else in here assumes a flat world.
var ground_height: Callable = Callable()

var swarm: SwarmCore
var _rev := -1
var _bodies := {}           ## group id -> StaticBody3D carrying the mound mesh + collider
var _mat: StandardMaterial3D
var _limb_mat: StandardMaterial3D


func setup(core: SwarmCore) -> void:
	swarm = core
	_mat = StandardMaterial3D.new()
	_mat.albedo_color = Color(0.30, 0.26, 0.24)
	_mat.roughness = 0.95
	_limb_mat = StandardMaterial3D.new()
	_limb_mat.albedo_color = Color(0.42, 0.38, 0.36)
	_limb_mat.roughness = 0.9
	swarm.set_pile_mesh_mode(true)


func _process(_delta: float) -> void:
	if swarm == null:
		return
	# Piles change on an event — a body freezes, or an explosion takes a bite out of one — not
	# every frame. Rebuild only when the core says the corpse set actually moved.
	var rev: int = swarm.get_corpse_revision()
	if rev == _rev:
		return
	_rev = rev
	_rebuild()


func _rebuild() -> void:
	var seen := {}
	for f in swarm.get_pile_fields():
		var g: int = f["group"]
		seen[g] = true
		_build_group(g, f["points"])
	# A pile that got blown out of existence takes its mound with it.
	for g in _bodies.keys():
		if not seen.has(g):
			(_bodies[g] as Node).queue_free()
			_bodies.erase(g)


func _build_group(g: int, pts: PackedVector3Array) -> void:
	if pts.size() < 3:
		return
	var lo := Vector2(INF, INF)
	var hi := Vector2(-INF, -INF)
	for p in pts:
		lo.x = minf(lo.x, p.x); lo.y = minf(lo.y, p.z)
		hi.x = maxf(hi.x, p.x); hi.y = maxf(hi.y, p.z)
	lo -= Vector2(PAD, PAD)
	hi += Vector2(PAD, PAD)

	var nx := int((hi.x - lo.x) / CELL) + 1
	var nz := int((hi.y - lo.y) / CELL) + 1
	if nx < 2 or nz < 2 or nx * nz > 40000:
		return

	# Each body raises a smooth bump; the pile's surface is their upper envelope, not their sum,
	# so a dense cluster reads as one mound rather than piling to the moon.
	# Sample the ground once per cell; the mound is built as absolute world height so it drapes
	# over terrain rather than assuming a flat floor.
	var ground := PackedFloat32Array()
	ground.resize(nx * nz)
	var solid := PackedByteArray()
	solid.resize(nx * nz)
	var has_ground := ground_height.is_valid()
	for z in nz:
		for x in nx:
			var wx := lo.x + x * CELL
			var wz := lo.y + z * CELL
			var gy := float(ground_height.call(wx, wz)) if has_ground else 0.0
			ground[z * nx + x] = gy
			# Cells inside an obstacle are not part of the mound. Without this the heap grows
			# through the wall it is piled against and shows on the far side.
			solid[z * nx + x] = 1 if swarm.is_solid_at(Vector3(wx, 0.0, wz)) else 0

	var h := PackedFloat32Array()
	h.resize(nx * nz)
	for i in h.size():
		h[i] = ground[i]
	var rad_cells := int(BUMP_RADIUS / CELL) + 1
	for p in pts:
		var cx := int((p.x - lo.x) / CELL)
		var cz := int((p.z - lo.y) / CELL)
		for dz in range(-rad_cells, rad_cells + 1):
			var iz := cz + dz
			if iz < 0 or iz >= nz:
				continue
			for dx in range(-rad_cells, rad_cells + 1):
				var ix := cx + dx
				if ix < 0 or ix >= nx:
					continue
				var d := Vector2(float(dx), float(dz)).length() * CELL
				if d > BUMP_RADIUS:
					continue
				var t := 1.0 - d / BUMP_RADIUS
				var v: float = p.y + BUMP_HEIGHT * t * t * (3.0 - 2.0 * t)  # smoothstep dome
				var idx := iz * nx + ix
				if v > h[idx]:
					h[idx] = v

	var raw := h.duplicate()
	for pass_i in SMOOTH_PASSES:
		h = _blur(h, nx, nz)
	# Blurring rounds the heap off but also eats its peaks, which left the crest bodies hovering
	# above a surface that had sagged away beneath them. Pull the summits back toward the
	# unblurred field so the top of the mound meets the corpses lying on it.
	for i in h.size():
		h[i] = maxf(h[i], lerpf(ground[i], raw[i], PEAK_KEEP))

	# Bodies do not stack into a smooth dune. Deterministic per-cell noise, scaled by how much
	# heap is under it, so the flanks stay put and the mass above them goes lumpy.
	var peak := 0.001
	for i in h.size():
		peak = maxf(peak, h[i] - ground[i])
	for z in nz:
		for x in nx:
			var i := z * nx + x
			var amt := (h[i] - ground[i]) / peak
			h[i] += LUMP * amt * (_hash01(x * 73856093 ^ z * 19349663 ^ g * 83492791) - 0.4)

	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var any := false
	for z in nz - 1:
		for x in nx - 1:
			var i00 := z * nx + x
			var i10 := i00 + 1
			var i01 := i00 + nx
			var i11 := i01 + 1
			# Cull only where the whole quad is inside the obstacle. Dropping a quad when *any*
			# corner is solid eats a cell-wide strip along every wall, and the heap ends up
			# standing off the very thing it is piled against.
			if solid[i00] == 1 and solid[i10] == 1 and solid[i01] == 1 and solid[i11] == 1:
				continue
			if h[i00] - ground[i00] < MIN_HEIGHT and h[i10] - ground[i10] < MIN_HEIGHT 					and h[i01] - ground[i01] < MIN_HEIGHT and h[i11] - ground[i11] < MIN_HEIGHT:
				continue
			var p00 := Vector3(lo.x + x * CELL, h[i00] - SINK, lo.y + z * CELL)
			var p10 := Vector3(lo.x + (x + 1) * CELL, h[i10] - SINK, lo.y + z * CELL)
			var p01 := Vector3(lo.x + x * CELL, h[i01] - SINK, lo.y + (z + 1) * CELL)
			var p11 := Vector3(lo.x + (x + 1) * CELL, h[i11] - SINK, lo.y + (z + 1) * CELL)
			# Wound so the FRONT face points up. Getting this backwards culls the whole mound
			# and leaves you looking straight through it at the corpses inside.
			_tri(st, p00, p11, p01)
			_tri(st, p00, p10, p11)
			any = true
	if not any:
		return
	st.generate_normals()
	var mesh := st.commit()

	var body: StaticBody3D = _bodies.get(g)
	if body == null:
		body = StaticBody3D.new()
		body.name = "PileMound%d" % g
		var mi := MeshInstance3D.new()
		mi.name = "Mesh"
		mi.material_override = _mat
		body.add_child(mi)
		var cs := CollisionShape3D.new()
		cs.name = "Shape"
		body.add_child(cs)
		add_child(body)
		_bodies[g] = body
	(body.get_node("Mesh") as MeshInstance3D).mesh = mesh
	# The mound is real ground: the horde walks up it and so can the player.
	(body.get_node("Shape") as CollisionShape3D).shape = mesh.create_trimesh_shape()
	_scatter_limbs(body, g, pts.size(), lo, nx, nz, h, ground)


## Arms and legs jutting out of the heap. Placed by reading the height field that just built the
## surface, so a limb is always bedded in the mound — there is no second source of truth to
## disagree with and nothing that can end up hanging in the air.
func _scatter_limbs(body: StaticBody3D, g: int, bodies: int, lo: Vector2, nx: int, nz: int,
		h: PackedFloat32Array, ground: PackedFloat32Array) -> void:
	var mmi: MultiMeshInstance3D = body.get_node_or_null("Limbs")
	if mmi == null:
		mmi = MultiMeshInstance3D.new()
		mmi.name = "Limbs"
		var mm := MultiMesh.new()
		mm.transform_format = MultiMesh.TRANSFORM_3D
		var cap := CapsuleMesh.new()
		cap.radius = 0.085
		cap.height = LIMB_LEN
		cap.radial_segments = 6
		cap.rings = 2
		cap.surface_set_material(0, _limb_mat)
		mm.mesh = cap
		mmi.multimesh = mm
		body.add_child(mmi)
	var mm2: MultiMesh = mmi.multimesh
	var want := int(bodies * LIMBS_PER_BODY)
	mm2.instance_count = maxi(want, 1)
	var placed := 0
	var tries := 0
	while placed < want and tries < want * 24:
		tries += 1
		var seed_i := g * 9176 + tries * 2654435761
		var x := int(_hash01(seed_i) * float(nx - 1))
		var z := int(_hash01(seed_i ^ 0x5bf03635) * float(nz - 1))
		var i := z * nx + x
		var rise := h[i] - ground[i]
		if rise < 0.25:
			continue   # the flanks are bare ground, not heap
		var wx := lo.x + x * CELL
		var wz := lo.y + z * CELL
		# Sunk to a random depth so some read as a whole limb and some as just a hand.
		var depth: float = lerpf(0.05, 0.28, _hash01(seed_i ^ 0x1b873593))
		var pos := Vector3(wx, h[i] - SINK - depth, wz)
		var b := Basis(Vector3(0, 1, 0), _hash01(seed_i ^ 0x27d4eb2f) * TAU)
		b = b * Basis(Vector3(1, 0, 0), lerpf(0.3, 1.5, _hash01(seed_i ^ 0x165667b1)))
		mm2.set_instance_transform(placed, Transform3D(b, pos))
		placed += 1
	mm2.visible_instance_count = placed


func _hash01(v: int) -> float:
	var x := int(v) & 0x7fffffff
	x = (x ^ (x >> 16)) * 0x45d9f3b
	x = (x ^ (x >> 16)) * 0x45d9f3b
	x = x ^ (x >> 16)
	return float(x & 0xffff) / 65535.0


func _tri(st: SurfaceTool, a: Vector3, b: Vector3, c: Vector3) -> void:
	st.add_vertex(a)
	st.add_vertex(b)
	st.add_vertex(c)


## Blur toward the 3x3 average — the same "Smooth" brush a terrain editor gives you, and what
## turns a field of separate domes into one continuous heap.
func _blur(src: PackedFloat32Array, nx: int, nz: int) -> PackedFloat32Array:
	var dst := PackedFloat32Array()
	dst.resize(src.size())
	for z in nz:
		for x in nx:
			var sum := 0.0
			var n := 0
			for dz in range(-1, 2):
				var iz := z + dz
				if iz < 0 or iz >= nz:
					continue
				for dx in range(-1, 2):
					var ix := x + dx
					if ix < 0 or ix >= nx:
						continue
					sum += src[iz * nx + ix]
					n += 1
			dst[z * nx + x] = sum / float(n)
	return dst
