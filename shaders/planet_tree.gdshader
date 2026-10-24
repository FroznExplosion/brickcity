shader_type spatial;
// The planet's trees (Docs/Planets.md 11.10; PlanetTrees): vertex coloured
// boxes, faded in by a dither between fade_far and fade_near metres from the
// camera -- the far buildings' way, so a forest grows in rather than pops.

uniform float fade_near = 450.0;
uniform float fade_far = 600.0;

varying float v_keep;

void vertex() {
	vec3 root = (MODEL_MATRIX * vec4(0.0, 0.0, 0.0, 1.0)).xyz;
	v_keep = 1.0 - smoothstep(fade_near, fade_far, distance(root, CAMERA_POSITION_WORLD));
}

float bayer4(vec2 p) {
	ivec2 q = ivec2(mod(p, 4.0));
	int i = q.x + q.y * 4;
	int m[16] = int[](0, 8, 2, 10, 12, 4, 14, 6, 3, 11, 1, 9, 15, 7, 13, 5);
	return (float(m[i]) + 0.5) / 16.0;
}

void fragment() {
	if (v_keep < bayer4(FRAGCOORD.xy)) {
		discard;
	}
	// The colours are written as the ground's are, in sRGB.
	ALBEDO = pow(COLOR.rgb, vec3(2.2));
	ROUGHNESS = 0.9;
}
