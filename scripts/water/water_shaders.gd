class_name WaterShaders
## See-through water (Docs/MineWater.md 7.4). Only the mine world asks for
## it; every other scene draws its water opaque, as before.
##
## A see-through material is the shader with `#define SEE_THROUGH` in front,
## over a next pass with `#define SEE_DEPTH` drawn first (render priority -1)
## that writes only depth, a hair behind the surface: so the colour pass shows
## the nearest water surface and none of the faces behind it (Godot's own
## depth_prepass_alpha only keeps nearly opaque pixels, and an alpha scissor
## makes the water opaque). Both passes must move their vertices alike, so
## `sync_all()` copies the colour material's uniforms to its depth pass each
## frame (MineWater calls it). CPU-side values only, no read-back.

static var _made := {}            ## "path|define" -> Shader
static var _names := {}           ## Shader -> PackedStringArray of uniform names
static var _pairs: Array = []     ## WeakRef of colour materials


static func _variant(path: String, define: String) -> Shader:
	var k := path + "|" + define
	if not _made.has(k):
		var code: String = (load(path) as Shader).code
		var at := code.find("\n") + 1
		var s := Shader.new()
		s.code = code.insert(at, "#define %s\n" % define)
		_made[k] = s
	return _made[k]


## A material of `path`: plain, or see-through with its depth pass.
static func material(path: String, see_through: bool) -> ShaderMaterial:
	var m := ShaderMaterial.new()
	if not see_through:
		m.shader = load(path)
		return m
	m.shader = _variant(path, "SEE_THROUGH")
	var d := ShaderMaterial.new()
	d.shader = _variant(path, "SEE_DEPTH")
	d.render_priority = -1
	m.next_pass = d
	_pairs.append(weakref(m))
	return m


## The uniforms of every see-through material onto its depth pass.
static func sync_all() -> void:
	var i := 0
	while i < _pairs.size():
		var m: ShaderMaterial = (_pairs[i] as WeakRef).get_ref()
		if m == null:
			_pairs.remove_at(i)
			continue
		i += 1
		var d := m.next_pass as ShaderMaterial
		if d == null:
			continue
		for n in _uniforms(m.shader):
			d.set_shader_parameter(n, m.get_shader_parameter(n))


## Debug: every see-through material draws its alpha (sea tiers orange,
## fluid water blue; brighter is more opaque).
static func set_debug(on: bool) -> void:
	for w in _pairs:
		var m: ShaderMaterial = (w as WeakRef).get_ref()
		if m != null:
			m.set_shader_parameter("see_debug", on)


static func _uniforms(s: Shader) -> PackedStringArray:
	if not _names.has(s):
		var out := PackedStringArray()
		for u in s.get_shader_uniform_list(true):
			if int(u.get("usage", 0)) & (PROPERTY_USAGE_GROUP | PROPERTY_USAGE_SUBGROUP):
				continue
			out.append(String(u.name))
		_names[s] = out
	return _names[s]
