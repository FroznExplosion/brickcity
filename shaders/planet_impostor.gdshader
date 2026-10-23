shader_type spatial;
// The planet from far away (Docs/Planets.md 11.1): one sphere displaced by a
// heightmap baked from the SAME relief the voxels are made of, coloured by a
// map baked from the ground shader's rules, lit by its own sun so day and night
// hold at any distance. After STA's shaders/impostor.gdshader. `fade` cross-fades
// it with the voxel ground by altitude (a dither: no sorting, no pop).
render_mode unshaded, cull_back;

uniform sampler2D heightmap : repeat_enable, filter_linear;
uniform sampler2D color_map : source_color, repeat_enable, filter_linear;
uniform float amplitude = 60.0;
uniform float sink = 0.0;               // metres under the ground, while the voxels show
uniform vec3 atmo_color : source_color = vec3(0.45, 0.65, 1.0);
uniform vec3 sun_color : source_color = vec3(1.0, 0.96, 0.90);
uniform vec3 sun_dir = vec3(0.4, 0.6, 0.3);   // planet-local, surface -> sun
uniform float ambient = 0.16;
uniform float fade = 1.0;

varying vec3 v_dir;

vec2 dir_to_equirect(vec3 d) {
	return vec2(0.5 + atan(d.x, d.z) / (2.0 * PI), 0.5 - asin(clamp(d.y, -1.0, 1.0)) / PI);
}

void vertex() {
	vec3 d = normalize(VERTEX);
	float h = textureLod(heightmap, dir_to_equirect(d), 0.0).r;
	VERTEX += d * ((h * 2.0 - 1.0) * amplitude - sink);
	v_dir = d;
}

float bayer4(vec2 p) {
	ivec2 q = ivec2(mod(p, 4.0));
	int m[16] = int[](0, 8, 2, 10, 12, 4, 14, 6, 3, 11, 1, 9, 15, 7, 13, 5);
	return (float(m[q.y * 4 + q.x]) + 0.5) / 16.0;
}

void fragment() {
	if (fade < 0.999 && bayer4(FRAGCOORD.xy) > fade) discard;
	vec3 base = texture(color_map, dir_to_equirect(normalize(v_dir))).rgb;
	float ndl = max(dot(normalize(v_dir), normalize(sun_dir)), 0.0);
	vec3 lit = base * (ndl * sun_color + ambient);
	float rim = pow(1.0 - clamp(dot(normalize(VIEW), NORMAL), 0.0, 1.0), 4.0);
	ALBEDO = lit + atmo_color * rim * 0.5 * (0.3 + ndl);
}
