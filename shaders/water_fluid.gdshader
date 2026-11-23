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
render_mode cull_disabled, diffuse_burley, specular_schlick_ggx;

// SKY LIGHT (Docs/MineWorld.md 19): the mesher writes each water vertex's
// sky level into COLOR.b (brick::sky_levels_into); with `sky_light` on (the
// mine world's sky light) a cave pool takes it as the ground does -- the
// ambient (AO), the sky's reflections (SPECULAR) and the sun (light(), the
// shared sky_lit.gdshaderinc) scaled by its brightness. Lava keeps its glow.
#include "res://shaders/sky_lit.gdshaderinc"
uniform bool sky_light = false;

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
// THE REAL SEA (MineWater.md 11.9): sea tops near ground carry CUSTOM0.y
// = 1 and in .z how open the water is (0 against ground, 1 four studs out).
// They ride the sea's own waves (sea_wave.gdshaderinc, the tiers' numbers),
// so where the tiers take over the two are one surface; water against ground
// keeps a third of the wave and laps up it. Drawn only: the water stays level.
// Water over ground the field calls land (a channel dug inland) stays level.
// THE SEA'S LOOK for all water (the user: the band and the sea must not
// differ): water.gdshader's colours, crest by the wave, darker with depth.
// Copied from the sea's material by MineWater when there is a sea.
uniform vec4 trough_colour : source_color = vec4(0.09, 0.26, 0.40, 1.0);
uniform vec4 crest_colour : source_color = vec4(0.42, 0.72, 0.78, 1.0);
uniform vec4 deep_tint : source_color = vec4(0.10, 0.28, 0.40, 1.0);
uniform float absorption_depth = 6.0;
uniform float water_roughness = 0.22;
// The tiers' piece look (water.gdshader): the stud grid, the print lines,
// whitecaps. Copied from the sea's material by MineWater.
uniform bool grid_lines = true;
uniform float grid_line_width = 0.012;
uniform float grid_line_darken = 0.35;
uniform bool print_lines_enabled = true;
uniform float layer_height = 0.020;
uniform float bead_width = 0.024;
uniform float bead_groove = 0.17;
uniform float layer_darken = 0.92;
uniform float resolve_begin = 0.30;
uniform float resolve_end = 0.75;
uniform float print_fade_begin = 7.0;
uniform float print_fade_end = 22.0;
uniform float foam_at = 0.80;
uniform float step_m = 0.42;
uniform vec3 sea_foam : source_color = vec3(0.92, 0.95, 0.96);
uniform bool debug_band = false;     // tint the band's pieces (the sea gate's check)
varying float v_sea;
varying float v_amp;
varying vec2 v_cell;
varying float v_top;
varying float v_h01;
// The mesher's own normal, world space. With cull_disabled Godot flips
// NORMAL on a face seen from its back, and the tops are wound so that from
// above is their back: they were lit as if facing down -- the dark water,
// darker than the sea next to it.
varying vec3 v_nrm;
varying float v_depth;

#include "res://shaders/sea_wave.gdshaderinc"

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
	v_h01 = 0.5;
	v_sea = 0.0;
	v_amp = 0.0;
	v_cell = vec2(0.0);
	v_top = 0.0;
	v_nrm = (MODEL_MATRIX * vec4(NORMAL, 0.0)).xyz;
	// COLOR.r: the water's depth over 12 plates (0.14 m each), from the mesher.
	v_depth = COLOR.r * 12.0 * 0.14;
	if (CUSTOM0.y > 0.5) {
		// A real sea piece (MineWater.md 11.9): the whole piece rides the
		// sea's wave at its stud's middle, exactly as the tiers' pieces do.
		v_sea = 1.0;
		vec3 w0 = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
		vec2 mid = w0.xz + vec2(CUSTOM0.x, CUSTOM0.w) * stud * 0.5;
		float ground = lattice_ground(mid);
		float raw = ground < sea_level ? surface_offset(mid, wave_time, 1.0, 0.0) : 0.0;
		VERTEX.y += raw;
		float amp = 0.0;
		for (int i = 0; i < wave_count; i++) {
			amp += waves[i * 2].x;
		}
		v_amp = amp;
		v_h01 = clamp(raw / max(amp, 1e-4) * 0.5 + 0.5, 0.0, 1.0);
		v_depth = max(sea_level - ground, 0.0);
		v_cell = w0.xz - (mid - vec2(stud * 0.5));
		v_top = sea_level + raw;
	} else {
		float k = clamp((now_s - swap_s) / max(ease_s, 0.001), 0.0, 1.0);
		VERTEX.y += CUSTOM0.x * (1.0 - k);
	}
	wpos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	kind = COLOR.g;
}

// This fragment's sky light: AO, SPECULAR and the sun's share (light()).
// A macro, as AO and SPECULAR are fragment() outputs.
#define water_light_level(spec) { 		float wb = sky_light ? sky_lit_raw(15.0 * clamp(COLOR.b, 0.0, 1.0)) : 1.0; 		AO = mix(sky_light ? sky_light_floor : 1.0, 1.0, wb); 		AO_LIGHT_AFFECT = 0.0; 		SPECULAR = spec * sqrt(AO); 		sl_sun = pow(wb, sky_sun_power); 		sl_spec = spec; 		sl_rim = 0.0; 		sl_metal = 0.0; 	}

void fragment() {
	NORMAL = normalize((VIEW_MATRIX * vec4(v_nrm, 0.0)).xyz);
	vec3 wn = normalize(v_nrm);
	bool side = abs(wn.y) < 0.5;
	// World-space texture coordinates: tops in x, z; sides along the face
	// (x + z) and up, a fall's moving down.
	vec2 uv = side ? vec2(wpos.x + wpos.z, wpos.y) / stud : wpos.xz / stud;
	if (side && kind > 0.75) {
		uv.y += TIME * fall_speed;
	}
	if (!lava && v_sea > 0.5) {
		// The tiers' piece look (water.gdshader fragment), restated.
		bool up = !side;
		if (!up) {
			// The tiers' pieces are wound inside out, so their shader's
			// un-flip leaves a riser's normal pointing INTO the piece before
			// it leans it up: risers come out darker than tops and every
			// step between pieces shows. Lit like tops (as these were), the
			// band's steps vanished and it read as one smooth slope (the
			// user, 2026-11-21). The same lean, from the inside.
			vec3 up_view = normalize((VIEW_MATRIX * vec4(0.0, 1.0, 0.0, 0.0)).xyz);
			NORMAL = normalize(mix(-NORMAL, up_view, 0.85));
		}
		vec3 albedo = mix(trough_colour.rgb, crest_colour.rgb, v_h01);
		if (v_h01 > foam_at) {
			float whitecaps = clamp((v_amp - step_m * 0.5) / step_m, 0.0, 1.0);
			albedo = mix(albedo, sea_foam, smoothstep(foam_at, 1.0, v_h01) * whitecaps * (up ? 1.0 : 0.75));
		}
		albedo = mix(albedo, deep_tint.rgb, clamp(v_depth / absorption_depth, 0.0, 0.75));
		if (print_lines_enabled) {
			float pfade = 1.0 - smoothstep(print_fade_begin, print_fade_end, length(VERTEX));
			if (pfade > 0.0) {
				float pt = up ? (min(min(v_cell.x, stud - v_cell.x), min(v_cell.y, stud - v_cell.y)) / bead_width)
						: ((v_top - wpos.y) / layer_height);
				float pph = fract(pt);
				float paa = max(fwidth(pt), 1e-5);
				float pres = 1.0 - smoothstep(resolve_begin, resolve_end, paa);
				float pgroove = max(paa * 1.4, bead_groove);
				float pink = (1.0 - smoothstep(0.0, pgroove, abs(pph - 0.5))) * pres;
				albedo *= mix(1.0, layer_darken, pink * pfade);
			}
		}
		if (grid_lines) {
			vec2 g = wpos.xz / stud;
			vec2 fw = max(fwidth(g), vec2(1e-5));
			vec2 dist_to = min(fract(g), 1.0 - fract(g));
			vec2 w = grid_line_width / stud / fw;
			vec2 line = 1.0 - smoothstep(w * 0.5, w * 0.5 + 1.0, dist_to / fw);
			float fade = 1.0 - smoothstep(0.06, 0.16, max(fw.x, fw.y));
			albedo *= 1.0 - max(line.x, line.y) * fade * grid_line_darken;
		}
		if (debug_band) {
			albedo = mix(albedo, vec3(0.9, 0.15, 0.1), 0.6);
		}
		ALBEDO = albedo;
		ROUGHNESS = water_roughness;
		METALLIC = 0.0;
		SPECULAR = 0.7;
		water_light_level(0.7);
	} else if (lava) {
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
		sl_sun = 1.0;
		sl_spec = 0.5;
		sl_rim = 0.0;
		sl_metal = 0.0;
	} else {
		// Ripples that move the same way everywhere, slowly; the light
		// catches them; the stud grid over it all, as on the sea.
		float r = noise(uv * 0.9 + vec2(0.11, 0.07) * TIME) * 0.6 + noise(uv * 2.7 - vec2(0.05, 0.13) * TIME) * 0.4;
		vec3 c = mix(trough_colour.rgb, crest_colour.rgb, v_h01);
		c = mix(c, deep_tint.rgb, clamp(v_depth / absorption_depth, 0.0, 0.75));
		c = mix(c, c * 1.12, smoothstep(0.55, 0.95, r) * 0.35);
		if (!side) {
			vec2 g = abs(fract(uv) - 0.5);
			float line = 1.0 - smoothstep(0.5 - grid_line, 0.5, max(g.x, g.y));
			c *= mix(0.88, 1.0, line);
		}
		float foam = kind > 0.75 ? 0.3 * smoothstep(0.4, 0.9, r) : 0.0;
		ALBEDO = mix(c, foam_colour, foam);
		// Not a mirror: under a dark sky a glossy top read as black.
		ROUGHNESS = water_roughness + foam * 0.5;
		SPECULAR = 0.7;
		water_light_level(0.7);
		// Ripples tilt the normal a little, the same way everywhere.
		vec2 e = vec2(0.15, 0.0);
		float rx = noise((uv + e.xy) * 0.9 + vec2(0.11, 0.07) * TIME) - noise((uv - e.xy) * 0.9 + vec2(0.11, 0.07) * TIME);
		float rz = noise((uv + e.yx) * 0.9 + vec2(0.11, 0.07) * TIME) - noise((uv - e.yx) * 0.9 + vec2(0.11, 0.07) * TIME);
		if (!side) {
			NORMAL = normalize(NORMAL + (VIEW_MATRIX * vec4(rx * 0.25, 0.0, rz * 0.25, 0.0)).xyz);
		}
	}
}
