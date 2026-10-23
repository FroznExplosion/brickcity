shader_type spatial;
// The sea (Docs/Planets.md 11.1): ONE shell at sea level, waves in the shader
// and nowhere else. The ground never changes, so there is no water simulation,
// no flow and no lakes -- not STA's WaterSystem, only the idea of its far shell.
// Gerstner-style ripples bend the normal (the shell's vertices are metres
// apart); colour deepens with the depth of water over the ground, read from the
// depth buffer; the far side fades to the sky's colour by fresnel.
render_mode cull_back, depth_draw_always, specular_schlick_ggx;

uniform float time_s = 0.0;
uniform vec4 shallow : source_color = vec4(0.18, 0.52, 0.58, 0.55);
uniform vec4 deep : source_color = vec4(0.03, 0.14, 0.26, 0.93);
uniform float depth_fade = 10.0;
uniform float ripple_scale = 0.11;   // 1/m
uniform sampler2D depth_tex : hint_depth_texture, filter_linear;

varying vec3 v_obj;

vec3 ripple_normal(vec3 p, vec3 up, float t) {
	// Three crossing waves in the tangent plane at p.
	vec3 e1 = normalize(cross(up, abs(up.y) < 0.9 ? vec3(0, 1, 0) : vec3(1, 0, 0)));
	vec3 e2 = cross(up, e1);
	vec2 q = vec2(dot(p, e1), dot(p, e2)) * ripple_scale;
	vec2 g = vec2(0.0);
	g += vec2(1.0, 0.3) * cos(dot(q, vec2(1.0, 0.3)) * 3.1 + t * 1.3) * 0.06;
	g += vec2(-0.4, 1.0) * cos(dot(q, vec2(-0.4, 1.0)) * 4.7 + t * 1.9) * 0.04;
	g += vec2(0.7, -0.8) * cos(dot(q, vec2(0.7, -0.8)) * 9.3 + t * 2.7) * 0.02;
	return normalize(up - e1 * g.x - e2 * g.y);
}

void vertex() {
	v_obj = VERTEX;
}

void fragment() {
	vec3 up = normalize(v_obj);
	vec3 n_obj = ripple_normal(v_obj, up, time_s);
	NORMAL = normalize((VIEW_MATRIX * (MODEL_MATRIX * vec4(n_obj, 0.0))).xyz);
	float scene_depth = textureLod(depth_tex, SCREEN_UV, 0.0).r;
	vec4 ndc = vec4(SCREEN_UV * 2.0 - 1.0, scene_depth, 1.0);
	vec4 vpos = INV_PROJECTION_MATRIX * ndc;
	vpos.xyz /= vpos.w;
	float water_depth = max(length(vpos.xyz) - length(VERTEX), 0.0);
	float k = clamp(water_depth / depth_fade, 0.0, 1.0);
	vec4 c = mix(shallow, deep, k);
	ALBEDO = c.rgb;
	ALPHA = c.a;
	ROUGHNESS = 0.05;
	METALLIC = 0.0;
	SPECULAR = 0.6;
}
