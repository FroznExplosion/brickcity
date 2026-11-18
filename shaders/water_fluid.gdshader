shader_type spatial;
// Water and lava on the brick grid (Docs/MineWater.md 7.1): the meshes
// BrickFluid builds per terrain tile. Opaque; thin water (a tile or two deep)
// is dithered so the ground shows through a shallow stream and there is
// nothing to sort.
//
// Vertex colour, from the mesher (brick_fluid.cpp mesh_tile):
//   r  depth of the column, tiles / 12
//   g  kind: 0 still or source, 0.5 flowing, 1 falling
//   b, a  flow direction x, z, * 0.5 + 0.5
render_mode cull_disabled;

uniform bool lava = false;
uniform vec3 shallow_colour : source_color = vec3(0.22, 0.52, 0.78);
uniform vec3 deep_colour : source_color = vec3(0.03, 0.15, 0.36);
uniform vec3 foam_colour : source_color = vec3(0.86, 0.93, 0.97);
uniform vec3 lava_dark : source_color = vec3(0.45, 0.06, 0.0);
uniform vec3 lava_hot : source_color = vec3(1.0, 0.55, 0.08);
uniform float lava_glow = 2.5;
uniform vec3 lava_crust : source_color = vec3(0.12, 0.07, 0.06);
uniform float flow_speed = 1.4;     // studs a second along the flow
uniform float fall_speed = 3.0;     // studs a second down a fall
uniform float stud = 0.35;

varying vec3 wpos;
varying vec4 info;

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

// 4x4 Bayer threshold: the dither for thin water.
float bayer(vec2 frag) {
	ivec2 p = ivec2(mod(frag, 4.0));
	int i = p.x + p.y * 4;
	int m[16] = int[](0, 8, 2, 10, 12, 4, 14, 6, 3, 11, 1, 9, 15, 7, 13, 5);
	return (float(m[i]) + 0.5) / 16.0;
}

void vertex() {
	wpos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	info = COLOR;
}

void fragment() {
	float tiles = info.r * 12.0;
	float kind = info.g;
	vec2 flow = info.ba * 2.0 - 1.0;
	vec3 wn = (INV_VIEW_MATRIX * vec4(NORMAL, 0.0)).xyz;
	bool side = abs(wn.y) < 0.5;
	// Ripple space: along the flow on tops, down the face on a fall's sides.
	vec2 uv;
	if (side) {
		uv = vec2(wpos.x + wpos.z, wpos.y) / stud;
		uv.y += TIME * (kind > 0.75 ? fall_speed : 0.3);
	} else {
		uv = wpos.xz / stud - flow * TIME * flow_speed * (lava ? 0.15 : 1.0);
	}
	float n = noise(uv * 1.3) * 0.6 + noise(uv * 3.1 + TIME * 0.25) * 0.4;
	if (lava) {
		// A crust of cooled plates drifting slowly over the melt, bright
		// cracks between them, the whole thing breathing (4.6).
		vec2 cu = wpos.xz / stud * 0.55 - flow * TIME * 0.06;
		float plates = noise(cu) * 0.65 + noise(cu * 2.3 + 7.1) * 0.35;
		float crust = smoothstep(0.42, 0.58, plates);
		float crack = 1.0 - smoothstep(0.0, 0.08, abs(plates - 0.5));
		float pulse = 0.85 + 0.15 * sin(TIME * 1.3 + plates * 6.0);
		float heat = smoothstep(0.35, 0.8, n) * (1.0 - crust) + crack;
		ALBEDO = mix(lava_hot, lava_crust, crust);
		EMISSION = (mix(lava_dark, lava_hot, clamp(heat, 0.0, 1.0)) * (1.0 - crust * 0.85)
				+ lava_hot * crack * 0.8) * lava_glow * pulse;
		ROUGHNESS = mix(0.5, 0.95, crust);
	} else {
		vec3 c = mix(shallow_colour, deep_colour, smoothstep(1.0, 9.0, tiles));
		c += (n - 0.5) * 0.07;
		float foam = 0.0;
		if (kind > 0.75) {
			foam = 0.35 * n;            // a fall
		} else if (kind > 0.25) {
			foam = 0.10 * smoothstep(0.6, 0.9, n);   // running water
		}
		ALBEDO = mix(c, foam_colour, foam);
		ROUGHNESS = 0.06 + foam * 0.5;
		SPECULAR = 0.55;
		// Thin water shows the ground: a tile 55 %, two tiles 78 %.
		float cover = tiles < 1.5 ? 0.55 : (tiles < 2.5 ? 0.78 : 1.0);
		if (cover < 1.0 && cover < bayer(FRAGCOORD.xy)) {
			discard;
		}
	}
}
