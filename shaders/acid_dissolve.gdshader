// acid_dissolve.gdshader
// Replaces the enemy's BASE material while acid-melting (overlay can't punch
// holes in the mesh — only the base pass can discard fragments).
//
// Shared by all enemies: Synty characters typically share ONE texture atlas,
// so `albedo_tex` is set once on the shared material. Per-enemy progress is
// the `dissolve_amount` instance uniform.
//
// The inner skeleton_mesh (skinned to the same Skeleton3D, normally hidden)
// is shown by ElementalTarget.begin_dissolve() — as flesh pixels discard,
// the skeleton behind them appears. That IS the "melt to bone" effect.
shader_type spatial;
render_mode cull_back, depth_draw_opaque;

uniform sampler2D albedo_tex : source_color, filter_nearest;  // Synty atlas
uniform sampler2D noise_tex : hint_default_white, repeat_enable;
uniform vec4 acid_color : source_color = vec4(0.65, 1.0, 0.2, 1.0);
uniform float edge_width = 0.08;
uniform float noise_scale = 1.2;

instance uniform float dissolve_amount = 0.0;   // 0 intact .. 1 fully melted

varying vec3 world_pos;

void vertex() {
	world_pos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
}

void fragment() {
	vec3 base = texture(albedo_tex, UV).rgb;

	// World-space noise so the melt eats through in blotches, top-down biased
	// (acid pours over them): height term makes shoulders/head melt first.
	float n = texture(noise_tex, world_pos.xz * noise_scale).r * 0.7
			+ texture(noise_tex, world_pos.xy * noise_scale * 1.7).r * 0.3;
	float height_bias = clamp(1.0 - fract(world_pos.y * 0.3), 0.0, 1.0) * 0.25;
	float d = n - height_bias;

	float threshold = dissolve_amount * 1.15;   // overshoot so 1.0 = fully gone
	if (d < threshold - edge_width) {
		discard;                                // flesh eaten -> skeleton shows
	}

	// Glowing acid edge where the melt front currently is.
	float edge = 1.0 - smoothstep(threshold - edge_width, threshold + edge_width * 0.5, d);
	ALBEDO = mix(base, acid_color.rgb * 0.4, edge);
	EMISSION = acid_color.rgb * edge * 5.0;

	// Sickly green tint spreading ahead of the front.
	float tint = smoothstep(threshold + edge_width, threshold + 0.5, d);
	ALBEDO = mix(ALBEDO * vec3(0.75, 1.0, 0.7), ALBEDO, tint);
}
