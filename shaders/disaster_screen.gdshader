shader_type canvas_item;

// The weather on the lens (Docs/Disasters.md 13): rain streaking past and a
// dust haze thick at the edges. Drawn over the 3D view, under the HUD. Both
// dials at 0 draw nothing.

uniform float rain : hint_range(0.0, 1.0) = 0.0;
uniform float dust : hint_range(0.0, 1.0) = 0.0;
uniform vec4 dust_colour : source_color = vec4(0.6, 0.55, 0.48, 1.0);
uniform vec4 rain_colour : source_color = vec4(0.78, 0.84, 0.92, 1.0);

float hash(vec2 p) {
	return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453);
}

// One layer of streaks: thin columns, a few lit, sliding down fast.
float streaks(vec2 uv, float columns, float speed, float seed) {
	vec2 g = vec2(uv.x * columns, uv.y * 3.0 - TIME * speed);
	vec2 id = floor(g);
	float r = hash(vec2(id.x, seed));
	float lit = step(0.93, r);
	float x = fract(g.x);
	float y = fract(g.y + r * 7.0);
	float line = smoothstep(0.12, 0.0, abs(x - 0.5));
	float along = smoothstep(0.0, 0.25, y) * smoothstep(1.0, 0.55, y);
	return lit * line * along;
}

void fragment() {
	vec2 uv = SCREEN_UV;
	vec2 slant = vec2(uv.x + uv.y * 0.08, uv.y);
	float s = streaks(slant, 110.0, 5.5, 1.0) * 0.6
			+ streaks(slant, 70.0, 4.0, 2.0) * 0.4
			+ streaks(slant, 160.0, 7.0, 3.0) * 0.3;
	float rain_a = clamp(s, 0.0, 1.0) * rain * 0.35;
	float edge = smoothstep(0.25, 0.95, length((uv - 0.5) * vec2(1.3, 1.0)));
	float low = smoothstep(0.55, 1.0, uv.y);
	// Rain darkens a little, all over; dust hazes, most at the edges and low.
	float gloom = rain * 0.12 * (0.6 + 0.4 * edge);
	float haze = dust * (0.18 + 0.4 * edge + 0.2 * low);
	float a = clamp(rain_a + gloom + haze, 0.0, 0.8);
	vec3 col = rain_a * rain_colour.rgb + haze * dust_colour.rgb;
	col /= max(rain_a + gloom + haze, 0.0001);
	COLOR = vec4(col, a);
}
