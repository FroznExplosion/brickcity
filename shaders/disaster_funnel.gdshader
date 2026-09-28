shader_type spatial;
render_mode blend_mix, depth_draw_never, cull_disabled, unshaded;

// The tornado's funnel: a tapered cylinder with bands of dust wound round it
// and scrolling up, thickest at the edges of the silhouette.

uniform vec4 dust_colour : source_color = vec4(0.36, 0.33, 0.29, 1.0);
uniform vec4 dark_colour : source_color = vec4(0.14, 0.13, 0.12, 1.0);
uniform float spin = 1.4;         // turns of the pattern per second
uniform float rise = 0.35;        // UV per second, upward
uniform float density = 0.8;
uniform float sway = 1.5;         // metres the top wanders

varying float v_height;

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
	v_height = UV.y;
	// The funnel leans and snakes a little, more at the top.
	float h = 1.0 - UV.y;
	VERTEX.x += sin(TIME * 0.7 + h * 3.0) * sway * h * h;
	VERTEX.z += cos(TIME * 0.5 + h * 2.3) * sway * h * h;
}

void fragment() {
	vec2 uv = vec2(UV.x + TIME * spin * 0.25, UV.y * 3.0 + TIME * rise);
	float n = noise(uv * vec2(14.0, 6.0)) * 0.6 + noise(uv * vec2(34.0, 15.0)) * 0.4;
	// Wound bands: a spiral stripe through the noise.
	float band = 0.5 + 0.5 * sin((UV.x * 6.0 + UV.y * 9.0 - TIME * spin * 3.0) * 6.2831);
	float edge = 1.0 - abs(dot(NORMAL, VIEW));
	float a = clamp((0.35 + n * 0.45 + band * 0.2) * density * (0.55 + edge * 0.8), 0.0, 1.0);
	// Thin at the very top, where it spreads into the cloud, and at the ground.
	a *= smoothstep(0.0, 0.12, UV.y) * smoothstep(1.0, 0.9, UV.y);
	ALBEDO = mix(dark_colour.rgb, dust_colour.rgb, n);
	ALPHA = a;
}
