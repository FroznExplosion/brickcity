class_name GunSkinApplier
extends RefCounted
## Applies a GunSkinDef to an assembled gun model:
##  1. Per MeshInstance3D: freeze its REST transform relative to the gun root
##     into instance uniforms (basis columns, origin in .w) — this is what makes
##     the pattern seamless across parts and sticky on animated parts.
##  2. Per distinct source material: build one ShaderMaterial from the skin,
##     forwarding the part's baked normal map as a detail layer, and set it as
##     the surface override.
## Reapplying with another skin just replaces the overrides (idempotent).

const SHADER_PATH := "res://shaders/gun_skin.gdshader"


static func apply(model_root: Node3D, skin: GunSkinDef) -> void:
	if model_root == null or skin == null:
		return
	var shader := load(SHADER_PATH) as Shader
	if shader == null:
		push_error("GunSkinApplier: shader missing at %s." % SHADER_PATH)
		return

	# Source material -> skin material cache, so surfaces sharing a source
	# material share one override.
	var mat_cache: Dictionary[Material, ShaderMaterial] = {}
	var null_key_mat: ShaderMaterial = null

	for mi: MeshInstance3D in model_root.find_children("*", "MeshInstance3D", true, false):
		_write_rest_transform(mi, model_root)
		if mi.mesh == null:
			continue
		for s in mi.mesh.get_surface_count():
			var src := mi.get_active_material(s)
			var mat: ShaderMaterial
			if src == null:
				if null_key_mat == null:
					null_key_mat = _build_material(shader, skin, null)
				mat = null_key_mat
			else:
				if not mat_cache.has(src):
					mat_cache[src] = _build_material(shader, skin, src)
				mat = mat_cache[src]
			mi.set_surface_override_material(s, mat)


## Rest transform of `node` relative to `root`, composed from local transforms
## so it works before the gun enters the scene tree.
static func rest_transform_to_root(node: Node3D, root: Node3D) -> Transform3D:
	var t := Transform3D.IDENTITY
	var cur: Node = node
	while cur != null and cur != root:
		if cur is Node3D:
			t = (cur as Node3D).transform * t
		cur = cur.get_parent()
	if cur == null:
		push_warning("GunSkinApplier: %s is not under the gun root." % node.name)
	return t


static func _write_rest_transform(mi: MeshInstance3D, root: Node3D) -> void:
	var t := rest_transform_to_root(mi, root)
	var b := t.basis
	mi.set_instance_shader_parameter(&"part_to_gun_c0",
		Vector4(b.x.x, b.x.y, b.x.z, t.origin.x))
	mi.set_instance_shader_parameter(&"part_to_gun_c1",
		Vector4(b.y.x, b.y.y, b.y.z, t.origin.y))
	mi.set_instance_shader_parameter(&"part_to_gun_c2",
		Vector4(b.z.x, b.z.y, b.z.z, t.origin.z))


static func _build_material(shader: Shader, skin: GunSkinDef, src: Material) -> ShaderMaterial:
	var mat := ShaderMaterial.new()
	mat.shader = shader
	mat.set_shader_parameter(&"pattern", skin.pattern)
	mat.set_shader_parameter(&"pattern_scale", skin.pattern_scale)
	mat.set_shader_parameter(&"blend_sharpness", skin.blend_sharpness)
	mat.set_shader_parameter(&"palette_primary", skin.palette_primary)
	mat.set_shader_parameter(&"palette_secondary", skin.palette_secondary)
	mat.set_shader_parameter(&"palette_tertiary", skin.palette_tertiary)
	mat.set_shader_parameter(&"palette_accent", skin.palette_accent)
	mat.set_shader_parameter(&"roughness_value", skin.roughness)
	mat.set_shader_parameter(&"metallic_value", skin.metallic)
	mat.set_shader_parameter(&"emission_color", skin.emission_color)
	mat.set_shader_parameter(&"emission_strength", skin.emission_strength)

	# Carry the part's baked normal map through as the detail layer.
	if src is BaseMaterial3D:
		var base := src as BaseMaterial3D
		if base.normal_enabled and base.normal_texture != null:
			mat.set_shader_parameter(&"detail_normal", base.normal_texture)
			mat.set_shader_parameter(&"detail_normal_strength", base.normal_scale)
	return mat
