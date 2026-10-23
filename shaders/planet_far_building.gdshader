shader_type spatial;
// The far tier of the planet's buildings (Docs/Planets.md 11.3-11.4): every
// building one instance of a unit box (base at the origin, Y up) in one
// MultiMesh, scaled to its footprint and height in its tangent frame. Storeys
// of windows by its own size; faded by a dither so nothing pops.
//   INSTANCE_CUSTOM: r = fade (0..1), gba = width, height, depth (m)
//   COLOR: the facade's colour; a = 1 for a landmark (lit windows at night side)
render_mode cull_back;

uniform float storey_m = 2.94;
uniform float bay_m = 1.75;
uniform vec3 glass : source_color = vec3(0.18, 0.24, 0.30);
uniform vec3 sun_dir = vec3(0.4, 0.6, 0.3);

varying vec3 v_local;      // metres, in the building's box
varying float v_fade;
varying vec3 v_size;
varying vec4 v_col;

void vertex() {
	v_fade = INSTANCE_CUSTOM.r;
	v_size = INSTANCE_CUSTOM.gba;
	v_local = VERTEX * v_size;
	v_col = COLOR;
}

float bayer4(vec2 p) {
	ivec2 q = ivec2(mod(p, 4.0));
	int m[16] = int[](0, 8, 2, 10, 12, 4, 14, 6, 3, 11, 1, 9, 15, 7, 13, 5);
	return (float(m[q.y * 4 + q.x]) + 0.5) / 16.0;
}

void fragment() {
	if (v_fade < 0.999 && bayer4(FRAGCOORD.xy) > v_fade) discard;
	vec3 c = v_col.rgb;
	// On a wall (not the roof): a window per bay per storey.
	float on_wall = step(abs(NORMAL.y), 0.5);
	float along = abs(NORMAL.x) > 0.5 ? v_local.z : v_local.x;
	vec2 cell = fract(vec2(along / bay_m, v_local.y / storey_m));
	float win = step(0.2, cell.x) * step(cell.x, 0.8) * step(0.35, cell.y) * step(cell.y, 0.85);
	win *= on_wall * step(0.6, v_local.y);
	c = mix(c, glass, win * 0.85);
	ALBEDO = c;
	ROUGHNESS = mix(0.9, 0.2, win);
	METALLIC = 0.0;
}
