shader_type spatial;
// Water and lava on the brick grid (Docs/MineWater.md 7.1): the meshes
// BrickFluid builds per terrain tile.
//
// ONE look across a body of fluid (the user, 2026-11-19): one colour, the
// sea's, whatever the depth; a texture laid in WORLD space, the same way up
// everywhere (it used to scroll along each cell's own flow, so neighbouring
// cells slid in different directions and the surface read as a mess); no
// dithering of thin water. Falls scroll down their faces, all the same way.
//
// MOVEMENT: each vertex carries in CUSTOM0.x how far it moved since its
// tile's last mesh (metres). The mesh is swapped ten times a second; from the
// swap (`swap_s`, per instance) the vertex eases from where it was to where
// it is over `ease_s`, so a rising pond or a running front glides instead of
// stepping like a slide show.
//
// Vertex colour, from the mesher (brick_fluid.cpp mesh_tile):
//   g  kind: 0 still or source, 0.5 flowing, 1 falling
render_mode cull_disabled;

uniform bool lava = false;
// The sea's water (water.gdshader trough_colour .. crest_colour).
uniform vec3 water_colour : source_color = vec3(0.34, 0.60, 0.67);
uniform vec3 water_light : source_color = vec3(0.50, 0.76, 0.82);
uniform vec3 foam_colour : source_color = vec3(0.86, 0.93, 0.97);
uniform vec3 lava_dark : source_color = vec3(0.45, 0.06, 0.0);
uniform vec3 lava_hot : source_color = vec3(1.0, 0.55, 0.08);
uniform vec3 lava_crust : source_color = vec3(0.12, 0.07, 0.06);
uniform float lava_glow = 2.5;
uniform float fall_speed = 3.0;     // studs a second down a fall
uniform float stud = 0.35;
// The same thin line on every stud boundary the sea has (its tile grid).
uniform float grid_line = 0.035;
// The easing clock: `now_s` is the script's clock (MineWater sets it every
// frame), `swap_s` the instance's last mesh swap on the same clock.
uniform float now_s = 0.0;
uniform float ease_s = 0.1;
instance uniform float swap_s = -100.0;
// THE REAL SEA (MineWater.md 11.8): sea tops near the player carry CUSTOM0.y
// = 1 and in .z how open the water is (0 against ground, 1 four studs out).
// Open water swells a little, water against ground laps up it; both fade to
// flat at the edge of the real square (`real_rect`, this mesh's own metres:
// x0, z0, x1, z1), where the wave tiers' sea, calmed to flat there too, takes
// over. Drawn only: the water itself stays level.
uniform vec4 real_rect = vec4(0.0);
uniform float sea_swell = 0.10;
uniform float sea_lap = 0.07;

varying vec3 wpos;
varying float kind;

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
	float k = clamp((now_s - swap_s) / max(ease_s, 0.001), 0.0, 1.0);
	VERTEX.y += CUSTOM0.x * (1.0 - k);
	if (CUSTOM0.y > 0.5) {
		vec2 p = VERTEX.xz;
		float e = min(min(p.x - real_rect.x, real_rect.z - p.x), min(p.y - real_rect.y, real_rect.w - p.y));
		float fade = smoothstep(0.0, 12.0, e);
		float open = CUSTOM0.z;
		float swell = sin(dot(p, vec2(0.21, 0.13)) - 1.1 * TIME) * 0.6
				+ sin(dot(p, vec2(-0.09, 0.27)) - 0.8 * TIME + 1.7) * 0.4;
		float lap = 0.5 + 0.5 * sin(1.7 * TIME + dot(p, vec2(0.9, 0.7)));
		VERTEX.y += fade * (sea_swell * open * swell + sea_lap * (1.0 - open) * lap);
	}
	wpos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	kind = COLOR.g;
}

void fragment() {
	vec3 wn = (INV_VIEW_MATRIX * vec4(NORMAL, 0.0)).xyz;
	bool side = abs(wn.y) < 0.5;
	// World-space texture coordinates: tops in x, z; sides along the face
	// (x + z) and up, a fall's moving down.
	vec2 uv = side ? vec2(wpos.x + wpos.z, wpos.y) / stud : wpos.xz / stud;
	if (side && kind > 0.75) {
		uv.y += TIME * fall_speed;
	}
	if (lava) {
		// Crust plates drifting one way over the whole melt, bright cracks
		// between them, breathing.
		vec2 cu = uv * 0.55 + vec2(0.03, 0.02) * TIME;
		float plates = noise(cu) * 0.65 + noise(cu * 2.3 + 7.1) * 0.35;
		float crust = smoothstep(0.42, 0.58, plates);
		float crack = 1.0 - smoothstep(0.0, 0.08, abs(plates - 0.5));
		float pulse = 0.85 + 0.15 * sin(TIME * 1.3 + plates * 6.0);
		float n = noise(uv * 1.3 + TIME * 0.05);
		float heat = smoothstep(0.35, 0.8, n) * (1.0 - crust) + crack;
		ALBEDO = mix(lava_hot, lava_crust, crust);
		EMISSION = (mix(lava_dark, lava_hot, clamp(heat, 0.0, 1.0)) * (1.0 - crust * 0.85)
				+ lava_hot * crack * 0.8) * lava_glow * pulse;
		ROUGHNESS = mix(0.5, 0.95, crust);
	} else {
		// Ripples that move the same way everywhere, slowly; the light
		// catches them; the stud grid over it all, as on the sea.
		float r = noise(uv * 0.9 + vec2(0.11, 0.07) * TIME) * 0.6 + noise(uv * 2.7 - vec2(0.05, 0.13) * TIME) * 0.4;
		vec3 c = mix(water_colour, water_light, smoothstep(0.55, 0.95, r) * 0.35);
		if (!side) {
			vec2 g = abs(fract(uv) - 0.5);
			float line = 1.0 - smoothstep(0.5 - grid_line, 0.5, max(g.x, g.y));
			c *= mix(0.88, 1.0, line);
		}
		float foam = kind > 0.75 ? 0.3 * smoothstep(0.4, 0.9, r) : 0.0;
		ALBEDO = mix(c, foam_colour, foam);
		// Not a mirror: under a dark sky a glossy top read as black.
		ROUGHNESS = 0.22 + foam * 0.5;
		SPECULAR = 0.4;
		// Ripples tilt the normal a little, the same way everywhere.
		vec2 e = vec2(0.15, 0.0);
		float rx = noise((uv + e.xy) * 0.9 + vec2(0.11, 0.07) * TIME) - noise((uv - e.xy) * 0.9 + vec2(0.11, 0.07) * TIME);
		float rz = noise((uv + e.yx) * 0.9 + vec2(0.11, 0.07) * TIME) - noise((uv - e.yx) * 0.9 + vec2(0.11, 0.07) * TIME);
		if (!side) {
			NORMAL = normalize(NORMAL + (VIEW_MATRIX * vec4(rx * 0.25, 0.0, rz * 0.25, 0.0)).xyz);
		}
	}
}
