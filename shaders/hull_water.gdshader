// Water inside a hull (Docs/Hulls.md 8.2): the pools SpaceStation._draw_water
// builds, drawn as water rather than flat blue. Ripples from two crossing sine
// swells in the hull's own frame (it rides with the ship), a glassy shine, a
// see-through edge-on (fresnel), and foam where the mesh's COLOR.r says: along
// walls, at the brim of a step, and by a hole the sea comes in through.
// Cheap: no screen or depth reads.
shader_type spatial;
render_mode blend_mix, cull_disabled, depth_draw_opaque, specular_schlick_ggx;

uniform vec3 deep : source_color = vec3(0.07, 0.25, 0.38);
uniform vec3 shallow : source_color = vec3(0.22, 0.55, 0.66);
uniform vec3 foam_colour : source_color = vec3(0.92, 0.96, 1.0);
uniform float alpha = 0.72;
uniform float ripple = 0.18;
uniform float speed = 1.3;

varying vec3 local_p;
varying float foam;
varying float is_top;

float hash(vec2 p) {
	return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453);
}

float noise(vec2 p) {
	vec2 i = floor(p);
	vec2 f = fract(p);
	vec2 u = f * f * (3.0 - 2.0 * f);
	return mix(mix(hash(i), hash(i + vec2(1.0, 0.0)), u.x),
			mix(hash(i + vec2(0.0, 1.0)), hash(i + vec2(1.0, 1.0)), u.x), u.y);
}

void vertex() {
	local_p = VERTEX;
	foam = COLOR.r;
	// Tops ripple; a step's side stands and keeps its own normal.
	is_top = step(0.7, abs(NORMAL.y));
}

void fragment() {
	float t = TIME * speed;
	vec2 p = local_p.xz;
	// Two swells across each other, and a finer chop: the slope is the normal.
	vec2 g = vec2(cos(p.x * 2.1 + t) * 0.6 + cos(p.x * 5.3 - p.y * 3.1 + t * 1.7) * 0.25,
			cos(p.y * 2.4 - t * 0.8) * 0.6 + cos(p.y * 4.7 + p.x * 2.9 - t * 1.3) * 0.25);
	vec3 n_local = normalize(vec3(-g.x * ripple, 1.0, -g.y * ripple));
	NORMAL = normalize(mix(NORMAL, (VIEW_MATRIX * MODEL_MATRIX * vec4(n_local, 0.0)).xyz, 0.65 * is_top));
	float fres = pow(1.0 - clamp(abs(dot(NORMAL, VIEW)), 0.0, 1.0), 3.0);
	vec3 water = mix(deep, shallow, 0.35 + 0.35 * fres);
	// Foam: broken up by moving noise, thicker where COLOR.r is.
	float n = noise(p * 6.0 + vec2(t * 0.4, -t * 0.3)) * 0.6 + noise(p * 15.0 - vec2(t * 0.7)) * 0.4;
	float f = smoothstep(0.55, 0.9, foam * (0.65 + 0.7 * n));
	ALBEDO = mix(water, foam_colour, f);
	ROUGHNESS = mix(0.06, 0.8, f);
	METALLIC = 0.0;
	SPECULAR = 0.6;
	ALPHA = clamp(mix(alpha, 0.95, fres) + f * 0.3, 0.0, 1.0);
}
