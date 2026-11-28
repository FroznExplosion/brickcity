class_name WiringLinks
extends RefCounted
## WIRELESS LINKS AND WIRE BRICKS of the mine world's wiring
## (Docs/MineWiring.md 3.3, 12, 20): stage 7. MineWiring keeps the two link
## devices in its DEVICES table and the wire bricks' cells in `wires`, and
## calls these at a few hooks (links, the side nets, the tick, check, the
## look, the readout, saving). Never names MineWiring (two class_name scripts
## typing each other leak at exit): `w` is the wiring, untyped.
##
##   wire transmitter  a brick with two round antennas on top: their two
##                     colours are its CHANNEL (8 x 8 = 64; Create's Redstone
##                     Link pair). It reads the level at its sides.
##   wire receiver     the same look; it gives the highest level of every
##                     transmitter on its channel out of every side, a tick
##                     later. Range: every link the wiring has (the loaded
##                     world), no distance limit. RMB steps the first
##                     antenna's colour, shift + RMB the second.
##   wire brick        a terrain material (MAT_WIRE_BRICK): a placed brick the
##                     builder lays, bonded, shot and dug like any brick, that
##                     carries the signal through itself -- wire inside a wall
##                     and up it, no riser. A stud of a course of it is one
##                     node of a net (`wires`, keyed by its bottom plate
##                     cell): it joins the wire bricks beside, over and under
##                     it, a cable on its top or at its side, and the devices
##                     at its sides. Found and lost by `scan` over every edit's
##                     box (read on the CPU: solid_at), so a shot, a pickaxe, a
##                     blast or a piston moving it changes the net. Drawn
##                     with a copper band round its middle that glows while
##                     its net is on.

const SIDES: Array[Vector3i] = [Vector3i(1, 0, 0), Vector3i(-1, 0, 0), Vector3i(0, 0, 1), Vector3i(0, 0, -1)]
const COURSE := 3
const N := 8
const COLOURS := [Color(0.72, 0.13, 0.13), Color(0.13, 0.35, 0.68), Color(0.93, 0.75, 0.10), Color(0.20, 0.55, 0.24),
		Color(0.92, 0.92, 0.90), Color(0.10, 0.10, 0.11), Color(0.87, 0.42, 0.09), Color(0.55, 0.25, 0.65)]
const COLOUR_NAMES := ["red", "blue", "yellow", "green", "white", "black", "orange", "purple"]
const COL_COPPER := Color(0.72, 0.40, 0.18, 0.0)
const COL_LIT := Color(1.0, 0.32, 0.12, 1.0)
## A scan bigger than this many course-studs is skipped (a whole-world check).
const SCAN_MAX := 400000

static var _wire_mat := -2


static func kind(item: StringName) -> String:
	return "transmitter" if item == &"wire_transmitter" else ("receiver" if item == &"wire_receiver" else "")


static func is_link(item: StringName) -> bool:
	return kind(item) != ""


## The channel's two colours, as names: "red + blue".
static func channel_name(setting: int) -> String:
	@warning_ignore("integer_division")
	var a := clampi(setting / N, 0, N - 1)
	return "%s + %s" % [COLOUR_NAMES[a], COLOUR_NAMES[posmod(setting, N)]]


## RMB steps the first antenna's colour, shift + RMB ("use2") the second.
static func use(w, c: Vector3i, d: Dictionary, how: String) -> bool:
	@warning_ignore("integer_division")
	var a := int(d.setting) / N
	var b := posmod(int(d.setting), N)
	if how == "use2":
		b = (b + 1) % N
	else:
		a = (a + 1) % N
	d.setting = a * N + b
	w._show_device(c)
	return true


## What a transmitter reads at its sides: the nets there and the devices'
## outputs toward it -- but a receiver of its own channel, or it would hold
## itself on for ever.
static func read(w, c: Vector3i, d: Dictionary) -> int:
	var lvl := 0
	var own := _own_receivers(w, int(d.setting))
	for s in SIDES:
		for id in w.side_nets(c, s):
			lvl = maxi(lvl, int(w.nets[id].level) if own.is_empty() else net_level_without(w, id, own))
		for n in w.side_devices(c, s):
			var nd: Dictionary = w.devices[n]
			if kind(nd.item) == "receiver" and int(nd.setting) == int(d.setting):
				continue
			lvl = maxi(lvl, int(w.output_toward(n, -s)))
	return lvl


## The receivers on a channel.
static func _own_receivers(w, setting: int) -> Dictionary:
	var out := {}
	for n in w.devices:
		var nd: Dictionary = w.devices[n]
		if kind(nd.item) == "receiver" and int(nd.setting) == setting:
			out[n] = true
	return out


## A net's level with the devices in `skip` left out: what a transmitter
## reads from a wire its own channel's receivers also drive -- or a receiver
## wired back to its transmitter would hold itself on for ever.
static func net_level_without(w, id: int, skip: Dictionary) -> int:
	var lvl := 0
	for n in w.devices:
		if skip.has(n):
			continue
		var o := int(w.devices[n].out)
		if o <= lvl:
			continue
		for s in w._drive_sides(n):
			if w.side_nets(n, s).has(id):
				lvl = o
				break
	return lvl


## The tick: the highest level per channel from every transmitter, then every
## receiver's output (it drives the nets next tick, as a gate's does).
static func evaluate(w) -> void:
	var chan := {}
	var any := false
	for c in w.devices:
		var d: Dictionary = w.devices[c]
		var k := kind(d.item)
		if k == "":
			continue
		any = true
		if k != "transmitter":
			continue
		var lvl := read(w, c, d)
		chan[int(d.setting)] = maxi(int(chan.get(int(d.setting), 0)), lvl)
		if (lvl > 0) != bool(d.lit):
			d.lit = lvl > 0
			w._show_device(c)
	if not any:
		return
	for c in w.devices:
		var d: Dictionary = w.devices[c]
		if kind(d.item) != "receiver":
			continue
		var lvl := int(chan.get(int(d.setting), 0))
		if lvl != int(d.out):
			d.out = lvl
			w._show_device(c)
			w._logic_dirty = true


# --- wire bricks ---------------------------------------------------------------

static func wire_material() -> int:
	if _wire_mat == -2:
		_wire_mat = Array(BrickTerrain.material_names()).find("wire brick")
	return _wire_mat


## The wire-brick node holding plate cell `p`: its course's bottom cell.
static func key(p: Vector3i) -> Vector3i:
	return Vector3i(p.x, floori(float(p.y) / COURSE) * COURSE, p.z)


static func is_wire(w, k: Vector3i) -> bool:
	var m := wire_material()
	if m < 0:
		return false
	for p in COURSE:
		if int(w.solid_fn.call(k.x, k.y + p, k.z)) != m:
			return false
	return true


## The ground changed in lo..hi (plate cells): the wire bricks found or gone
## there join or leave the nets (next tick's rebuild).
static func scan(w, lo: Vector3i, hi: Vector3i) -> void:
	var m := wire_material()
	if m < 0:
		return
	var y0 := floori(float(lo.y) / COURSE) * COURSE
	@warning_ignore("integer_division")
	var n := (hi.x - lo.x + 1) * (hi.z - lo.z + 1) * ((hi.y - y0) / COURSE + 1)
	if n <= 0 or n > SCAN_MAX:
		return
	var changed := false
	for x in range(lo.x, hi.x + 1):
		for z in range(lo.z, hi.z + 1):
			for y in range(y0, hi.y + 1, COURSE):
				var k := Vector3i(x, y, z)
				var now := is_wire(w, k)
				if now == w.wires.has(k):
					continue
				if now:
					w.wires[k] = true
				else:
					w.wires.erase(k)
				w._changed_cells.append(k)
				changed = true
	if changed:
		w._changed()


## The net links of node `c` (a cable cell or a wire-brick node) to wire
## bricks, appended to `out`. A wire brick links to the wire bricks at its
## sides, over and under it, the cable on its top and the cables at its sides
## (at any of its plates); a cable to the wire brick it lies on and those at
## its sides.
static func links(w, c: Vector3i, out: Array[Vector3i]) -> void:
	if w.wires.has(c):
		for s in SIDES:
			if w.wires.has(c + s):
				out.append(c + s)
			for dy in COURSE:
				if w.cables.has(c + s + Vector3i(0, dy, 0)):
					out.append(c + s + Vector3i(0, dy, 0))
		for v in [Vector3i(0, COURSE, 0), Vector3i(0, -COURSE, 0)]:
			if w.wires.has(c + v):
				out.append(c + v)
		if w.cables.has(c + Vector3i(0, COURSE, 0)):
			out.append(c + Vector3i(0, COURSE, 0))
		return
	var under := key(c + Vector3i.DOWN)
	if under.y + COURSE == c.y and w.wires.has(under):
		out.append(under)
	for s in SIDES:
		var k := key(c + s)
		if w.wires.has(k):
			out.append(k)


## The nets of the wire bricks at side `s` of a device `h` plates tall at `c`.
## With `under`, also the wire brick it stands on (its top plate right under
## `c`): a lever on a wire wall drives it, a lamp on one is lit by it. Gates
## and observers never take it -- their inputs and output have sides.
static func side_nets(w, c: Vector3i, s: Vector3i, h: int, out: Array, under := false) -> void:
	for dy in h:
		var k := key(c + s + Vector3i(0, dy, 0))
		if w.wires.has(k) and w.net_of.has(k) and not out.has(w.net_of[k]):
			out.append(w.net_of[k])
	if under:
		var u := key(c + Vector3i.DOWN)
		if u.y + COURSE == c.y and w.wires.has(u) and w.net_of.has(u) and not out.has(w.net_of[u]):
			out.append(w.net_of[u])


## Every wire brick's copper band: dull, or glowing while its net is on.
static func draw(w, mm: MultiMesh) -> void:
	var stud: float = w._stud
	var plate: float = w._plate
	mm.instance_count = w.wires.size()
	var i := 0
	for k: Vector3i in w.wires:
		var mid := Vector3((k.x + 0.5) * stud, (k.y + 1.5) * plate, (k.z + 0.5) * stud)
		mm.set_instance_transform(i, Transform3D(Basis.from_scale(Vector3(stud * 1.012, plate * 0.55, stud * 1.012)), mid))
		mm.set_instance_color(i, COL_LIT if w.level_at(k) > 0 else COL_COPPER)
		i += 1


# --- the look and the readout -------------------------------------------------

## A brick (a collider: found and shot), two round antennas on top in the
## channel's colours, a light on its front face.
static func build(w, root: Node3D, k: String, box: AABB) -> void:
	var stud: float = w._stud
	var plate: float = w._plate
	var body := StaticBody3D.new()
	body.collision_layer = Layers.WORLD
	body.collision_mask = 0
	var shape := CollisionShape3D.new()
	var bs := BoxShape3D.new()
	bs.size = box.size
	shape.shape = bs
	shape.position = Vector3(0, box.size.y * 0.5, 0)
	body.add_child(shape)
	root.add_child(body)
	var col := Color(0.24, 0.26, 0.31) if k == "transmitter" else Color(0.42, 0.44, 0.48)
	w._add_box(root, Vector3(stud * 0.96, plate * 2.9, stud * 0.96), Vector3(0, plate * 1.45, 0), w._mat(col, 0.5))
	for i in 2:
		var cyl := CylinderMesh.new()
		cyl.top_radius = stud * 0.13
		cyl.bottom_radius = stud * 0.13
		cyl.height = plate * (1.6 if i == 0 else 1.1)
		var ant := MeshInstance3D.new()
		ant.name = "Ant%d" % i
		ant.mesh = cyl
		ant.material_override = w._mat(COLOURS[0], 0.4)
		ant.position = Vector3((i - 0.5) * stud * 0.42, plate * 2.9 + cyl.height * 0.5, 0)
		root.add_child(ant)
	var glow: StandardMaterial3D = w._mat(Color(0.3, 0.9, 0.4) if k == "transmitter" else Color(1.0, 0.6, 0.15), 0.3)
	glow.emission_enabled = true
	glow.emission = glow.albedo_color
	glow.emission_energy_multiplier = 0.0
	var dot: MeshInstance3D = w._add_box(root, Vector3(stud * 0.3, plate * 0.4, stud * 0.3), Vector3(0, plate * 2.92, stud * 0.3), glow)
	dot.name = "Glow"


static func show(w, d: Dictionary, node: Node3D) -> void:
	@warning_ignore("integer_division")
	var a := clampi(int(d.setting) / N, 0, N - 1)
	var b := posmod(int(d.setting), N)
	for i in 2:
		var ant := node.get_node_or_null("Ant%d" % i) as MeshInstance3D
		if ant != null:
			w.set_colour(ant, COLOURS[a if i == 0 else b])   # either material (sky light, MineWiring.md 22)
	var g := node.get_node_or_null("Glow") as MeshInstance3D
	if g != null:
		var on := bool(d.lit) if kind(d.item) == "transmitter" else int(d.out) > 0
		w.set_glow(g, 3.0 if on else 0.0)


static func readout(w, c: Vector3i, d: Dictionary) -> Array[String]:
	var out: Array[String] = []
	match kind(d.item):
		"transmitter":
			out.append("channel %s (RMB first, shift+RMB second)" % channel_name(int(d.setting)))
			out.append("sends %d" % read(w, c, d))
		"receiver":
			out.append("channel %s (RMB first, shift+RMB second)" % channel_name(int(d.setting)))
			out.append("gets %d" % int(d.out))
	return out
