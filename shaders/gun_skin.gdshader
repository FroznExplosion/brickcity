// Seamless cross-part gun skin. Pattern is triplanar-projected in GUN-LOCAL
// space using each part's rest transform (frozen at assembly), so it flows
// across part seams and sticks to animated parts. See SPEC_gun_skin_system.md.
shader_type spatial;
render_mode cull_back, depth_draw_opaque;

// --- Per-instance: part rest transform relative to gun root. -----------------
// Instance uniforms can't be mat4, so: xyz = basis column, w = origin component.
instance uniform vec4 part_to_gun_c0 = vec4(1.0, 0.0, 0.0, 0.0);
instance uniform vec4 part_to_gun_c1 = vec4(0.0, 1.0, 0.0, 0.0);
instance uniform vec4 part_to_gun_c2 = vec4(0.0, 0.0, 1.0, 0.0);

// --- Skin (set per material by GunSkinApplier). ------------------------------
// RGB = secondary/tertiary/accent masks, A = emission mask.
// Defaults to black => solid palette_primary (manufacturer tint mode).
uniform sampler2D pattern : source_color, hint_default_black, filter_linear_mipmap, repeat_enable;
uniform float pattern_scale : hint_range(0.1, 32.0) = 3.0;   // tiles per meter
uniform float blend_sharpness : hint_range(1.0, 32.0) = 8.0;

uniform vec4 palette_primary : source_color = vec4(0.30, 0.30, 0.33, 1.0);
uniform vec4 palette_secondary : source_color = vec4(0.60, 0.55, 0.45, 1.0);
uniform vec4 palette_tertiary : source_color = vec4(0.12, 0.12, 0.14, 1.0);
uniform vec4 palette_accent : source_color = vec4(0.85, 0.35, 0.10, 1.0);

uniform float roughness_value : hint_range(0.0, 1.0) = 0.55;
uniform float metallic_value : hint_range(0.0, 1.0) = 0.15;
uniform vec4 emission_color : source_color = vec4(0.0, 0.0, 0.0, 1.0);
uniform float emission_strength : hint_range(0.0, 16.0) = 0.0;

// --- Per-part detail, forwarded from the part's original material. -----------
uniform sampler2D detail_normal : hint_normal;
uniform float detail_normal_strength : hint_range(0.0, 2.0) = 0.0; // 0 = off

varying vec3 gun_pos;
varying vec3 gun_nrm;

void vertex() {
	mat3 to_gun = mat3(part_to_gun_c0.xyz, part_to_gun_c1.xyz, part_to_gun_c2.xyz);
	vec3 origin = vec3(part_to_gun_c0.w, part_to_gun_c1.w, part_to_gun_c2.w);
	gun_pos = to_gun * VERTEX + origin;
	gun_nrm = to_gun * NORMAL; // parts are rigid + uniform scale; fine as-is
}

void fragment() {
	// Triplanar weights in gun space.
	vec3 w = pow(abs(normalize(gun_nrm)), vec3(blend_sharpness));
	w /= (w.x + w.y + w.z);

	vec3 p = gun_pos * pattern_scale;
	vec4 m = texture(pattern, p.zy) * w.x
		+ texture(pattern, p.xz) * w.y
		+ texture(pattern, p.xy) * w.z;

	vec3 col = palette_primary.rgb;
	col = mix(col, palette_secondary.rgb, clamp(m.r, 0.0, 1.0));
	col = mix(col, palette_tertiary.rgb, clamp(m.g, 0.0, 1.0));
	col = mix(col, palette_accent.rgb, clamp(m.b, 0.0, 1.0));

	ALBEDO = col;
	ROUGHNESS = roughness_value;
	METALLIC = metallic_value;
	EMISSION = emission_color.rgb * emission_strength * clamp(m.a, 0.0, 1.0);

	// Part-level baked detail (uses the part's own UVs — the one place UVs
	// still matter). Strength 0 when the part had no normal map.
	NORMAL_MAP = texture(detail_normal, UV).rgb;
	NORMAL_MAP_DEPTH = detail_normal_strength;
}
