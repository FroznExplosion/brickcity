// printed_plastic.gdshader — Godot 4.6
//
// FDM-print look for a minifig-scale brick world:
//   * Analytic layer-bead tracing (exact "POM" for a 1D periodic profile, no steps, no UVs)
//   * Micro self-shadowing from neighbouring beads, per light
//   * Fake bevels on brick / stud edges, faded by camera distance
//   * Top-skin diagonal lines on upward faces, smoother bed side on downward faces
//   * Three LOD tiers driven by on-screen layer size (trace -> normal only -> anisotropic sheen)
//
// Data contract (merged chunk meshes):
//   CUSTOM0 = (brick centre xyz in model space, mode)   mode: 0 = no bevel, 1 = box, 2 = stud cylinder
//   CUSTOM1 = box: (half extents xyz in model space, 0)  stud: (radius, half height, 0, 0)
//   COLOR   = per-brick tint (optional, multiplied with albedo_color)
//   Bricks inside a chunk only rotate in 90 degree steps about Y, so store the
//   already-rotated, axis-aligned extents. Untick use_vertex_brick_data to test on
//   a plain BoxMesh using the fallback box uniforms.
//
// Units: defaults assume 1 model unit = 1 stud pitch (8 mm). A brick body is 1.2
// units tall + 0.2125 stud = 11.3 mm; 57 layers -> layer_height ~= 0.02478 units.

shader_type spatial;
render_mode blend_mix, depth_draw_opaque, cull_back;

group_uniforms plastic;
uniform vec4 albedo_color : source_color = vec4(0.82, 0.10, 0.08, 1.0);
uniform float roughness_base : hint_range(0.05, 1.0) = 0.38;
uniform float layer_color_variation : hint_range(0.0, 0.1) = 0.015;

group_uniforms print;
uniform vec3 print_axis = vec3(0.0, 1.0, 0.0);          // model-space build direction
uniform float layer_height = 0.02478;                   // model units
uniform float groove_depth_ratio : hint_range(0.05, 0.5) = 0.35; // groove depth / layer height (0.5 = round beads)
uniform float cavity_strength : hint_range(0.0, 1.0) = 0.35;
uniform float micro_shadow_softness : hint_range(0.01, 0.3) = 0.08;
uniform float top_line_width = 0.056;                   // ~0.45 mm extrusion width
uniform float top_line_strength : hint_range(0.0, 0.5) = 0.12;
uniform float bed_side_roughness_scale : hint_range(0.2, 1.0) = 0.7;

group_uniforms bevel;
uniform bool use_vertex_brick_data = false;
uniform vec3 fallback_box_center = vec3(0.0);
uniform vec3 fallback_box_half_extents = vec3(1.0, 0.6, 0.5); // 2x1 brick body
uniform float bevel_width = 0.05;                       // model units, measured on the face
uniform float bevel_fade_start = 6.0;                   // camera distance (world units)
uniform float bevel_fade_end = 12.0;
uniform float bevel_min_pixels : hint_range(0.0, 4.0) = 0.0; // >0 keeps a thin highlight at any distance

group_uniforms lod;
// Measured in layers per pixel: 0.25 = each layer is 4 px tall on screen.
uniform float trace_lod_start = 0.12;
uniform float trace_lod_end = 0.25;
uniform float bump_lod_start = 0.3;
uniform float bump_lod_end = 0.6;
uniform int max_trace_beads : hint_range(1, 8) = 6;
uniform float far_aniso_strength : hint_range(0.0, 1.0) = 0.8;
uniform float far_roughness_across : hint_range(0.05, 1.0) = 0.6;

group_uniforms debug;
// 0 = off, 1 = LOD tiers (red trace / green bump / blue far), 2 = normals, 3 = bevel mask
uniform int debug_view : hint_range(0, 3) = 0;

// vertex -> fragment
varying vec3 v_pos_m;
varying vec3 v_nrm_m;
varying flat vec4 v_brick_a;
varying flat vec4 v_brick_b;
// fragment -> light
varying vec3 v_nb;     // view-space base normal (bevelled, before layer bumps)
varying vec3 v_ev;     // view-space tangent pointing "up the layers"
varying vec4 v_micro;  // x: hit depth 0..1, y: offset from bead centre -0.5..0.5, z: micro-shadow weight, w: anisotropy weight

void vertex() {
	v_pos_m = VERTEX;
	v_nrm_m = NORMAL;
	if (use_vertex_brick_data) {
		v_brick_a = CUSTOM0;
		v_brick_b = CUSTOM1;
	} else {
		v_brick_a = vec4(fallback_box_center, 1.0);
		v_brick_b = vec4(fallback_box_half_extents, 0.0);
	}
}

float hash11(float n) {
	return fract(sin(n * 12.9898) * 43758.5453);
}

// Fake bevel: normal bends toward the nearest edge of the brick's box (or stud
// cylinder) inside a band of width w. Continuous across faces: 45 deg at edges,
// corner-diagonal at corners.
vec3 fake_bevel_normal(vec3 p, vec3 n_geo, vec4 a, vec4 b, float w, out float mask) {
	mask = 0.0;
	int mode = int(a.w + 0.5);
	if (mode == 0 || w <= 0.0) {
		return n_geo;
	}
	vec3 q = p - a.xyz;
	vec3 d;
	if (mode == 1) {
		vec3 inner = max(b.xyz - vec3(w), vec3(0.0));
		d = q - clamp(q, -inner, inner);
	} else {
		float r = length(q.xz);
		float dr = max(r - max(b.x - w, 0.0), 0.0);
		float dy = max(q.y - max(b.y - w, 0.0), 0.0); // top rim only; the base is a concave joint
		vec2 radial = r > 1e-6 ? q.xz / r : vec2(0.0);
		d = vec3(radial.x * dr, dy, radial.y * dr);
	}
	vec3 t = clamp(abs(d) / w, 0.0, 1.0);
	t = t * t * (3.0 - 2.0 * t); // ease in: no visible crease where the bevel starts
	vec3 ds = sign(d) * t;
	float len = length(ds);
	if (len < 1e-4) {
		return n_geo;
	}
	vec3 nb = ds / len;
	if (dot(nb, n_geo) < 0.3) {
		return n_geo; // brick data doesn't describe this surface
	}
	mask = clamp((1.0 - dot(nb, n_geo)) * 4.0, 0.0, 1.0);
	return nb;
}

// Exact ray vs bead-stack intersection in the 2D slice (depth x, height y), both
// normalised so each bead is a circle of radius 0.5 centred at (0.5, k + 0.5).
// Returns (hit depth x, offset from bead centre yy, bead index k).
vec3 trace_beads(float y0, float M) {
	float kf = floor(y0);
	float dir = M >= 0.0 ? 1.0 : -1.0;
	float y_end = y0 + 0.5 * M;
	int n = min(int(abs(floor(y_end) - kf)) + 1, max_trace_beads);
	float a = 1.0 + M * M;
	for (int i = 0; i < 8; i++) {
		if (i >= n) {
			break;
		}
		float k = kf + dir * float(i);
		float Y = y0 - (k + 0.5);
		float b = 2.0 * Y * M - 1.0;
		float disc = b * b - 4.0 * a * Y * Y;
		if (disc >= 0.0) {
			float x = (-b - sqrt(disc)) / (2.0 * a);
			if (x >= -1e-4 && x <= 0.5 + 1e-4) {
				return vec3(max(x, 0.0), clamp(Y + M * x, -0.5, 0.5), k);
			}
		}
	}
	// Extreme grazing angle: fall back to the untraced surface point.
	float yy = fract(y0) - 0.5;
	return vec3(0.5 - sqrt(max(0.25 - yy * yy, 0.0)), yy, kf);
}

// Outward normal of the (elliptical) bead at slice point (x, yy).
vec3 bead_normal(float x, float yy, vec3 nb, vec3 ev) {
	return normalize((0.5 - x) / groove_depth_ratio * nb + 2.0 * yy * ev);
}

// Light ray from the hit point against the next beads it passes on its way out.
float micro_shadow(float x, float yy, vec3 L, vec3 nb, vec3 ev) {
	float Lu = dot(L, -nb); // inward component; < 0 when the light is in front of the wall
	if (Lu >= 0.0) {
		return 0.0;
	}
	vec2 d = vec2(Lu / (2.0 * groove_depth_ratio), dot(L, ev));
	vec2 P = vec2(x, yy);
	float t_exit = -x / d.x;
	float s = d.y >= 0.0 ? 1.0 : -1.0;
	float dd = max(dot(d, d), 1e-6);
	float lit = smoothstep(0.0, 0.05, -Lu);
	for (int j = 1; j <= 3; j++) {
		vec2 C = vec2(0.5, s * float(j));
		float t = clamp(dot(C - P, d) / dd, 0.0, t_exit);
		float dist = length(P + d * t - C);
		lit *= smoothstep(0.5 - micro_shadow_softness, 0.5, dist);
	}
	return lit;
}

void fragment() {
	mat3 m2v_dir = mat3(VIEW_MATRIX) * mat3(MODEL_MATRIX);
	mat3 m2v_nrm = mat3(VIEW_MATRIX) * MODEL_NORMAL_MATRIX;

	vec3 A_m = normalize(print_axis);
	vec3 n_geo_m = normalize(v_nrm_m);
	vec3 p = v_pos_m;

	// ---------- fake bevel ----------
	float pix = max(length(dFdx(p)), length(dFdy(p))); // model units per pixel
	float view_dist = length(VERTEX);
	float w = bevel_width;
	float bevel_fade;
	if (bevel_min_pixels > 0.0) {
		float max_w = 0.45 * min(min(v_brick_b.x, v_brick_b.y), max(v_brick_b.z, 1e-3));
		w = min(max(w, bevel_min_pixels * pix), max_w);
		bevel_fade = 1.0;
	} else {
		float dist_fade = 1.0 - smoothstep(bevel_fade_start, bevel_fade_end, view_dist);
		float aa_fade = smoothstep(0.75, 1.5, w / max(pix, 1e-6)); // drop it before it goes sub-pixel
		bevel_fade = dist_fade * aa_fade;
	}
	float bevel_mask = 0.0;
	vec3 nb_m = n_geo_m;
	if (bevel_fade > 0.001) {
		vec3 bev = fake_bevel_normal(p, n_geo_m, v_brick_a, v_brick_b, w, bevel_mask);
		nb_m = normalize(mix(n_geo_m, bev, bevel_fade));
		bevel_mask *= bevel_fade;
	}

	// ---------- frame ----------
	vec3 Nb = normalize(m2v_nrm * nb_m);
	vec3 A_v = normalize(m2v_dir * A_m);
	float s = dot(nb_m, A_m); // 0 on walls, +1 on tops, -1 on bed side
	vec3 ev = A_v - Nb * dot(A_v, Nb);
	float ev_len = length(ev);
	ev = ev_len > 1e-4 ? ev / ev_len : normalize(cross(Nb, vec3(1.0, 0.0, 0.0)));

	float wall_w = 1.0 - smoothstep(0.55, 0.9, abs(s));

	// ---------- layer lines ----------
	float y0 = dot(p, A_m) / layer_height;
	float lpp = fwidth(y0); // layers per pixel
	float w_trace = wall_w * (1.0 - smoothstep(trace_lod_start, trace_lod_end, lpp));
	float w_bump = wall_w * (1.0 - smoothstep(bump_lod_start, bump_lod_end, lpp));
	float far_w = wall_w * smoothstep(bump_lod_start, bump_lod_end, lpp);

	float yy0 = fract(y0) - 0.5;
	float x0 = 0.5 - sqrt(max(0.25 - yy0 * yy0, 0.0));
	vec3 n_layers = bead_normal(x0, yy0, Nb, ev);
	float x_hit = x0;
	float yy_hit = yy0;
	float k_hit = floor(y0);

	if (w_trace > 0.001) {
		vec3 dir_v = normalize(VERTEX);
		float du = max(dot(dir_v, -Nb), 0.05);
		float M = clamp(2.0 * groove_depth_ratio * dot(dir_v, ev) / du, -12.0, 12.0);
		vec3 hit = trace_beads(y0, M);
		vec3 n_t = bead_normal(hit.x, hit.y, Nb, ev);
		n_layers = normalize(mix(n_layers, n_t, w_trace));
		x_hit = mix(x0, hit.x, w_trace);
		yy_hit = hit.y;
		k_hit = hit.z;
	}

	vec3 n = normalize(mix(Nb, n_layers, w_bump));

	// ---------- top skin / bed side ----------
	vec3 T1 = normalize(cross(A_m, abs(A_m.x) < 0.9 ? vec3(1.0, 0.0, 0.0) : vec3(0.0, 0.0, 1.0)));
	vec3 T2 = cross(A_m, T1);
	vec3 diag_m = normalize(T1 + T2);
	float c = dot(p, diag_m) / top_line_width;
	float top_w = smoothstep(0.85, 0.97, s) * (1.0 - smoothstep(0.3, 0.6, fwidth(c)));
	vec3 diag_v = normalize(m2v_dir * diag_m);
	n = normalize(n + diag_v * (top_line_strength * sin(TAU * c) * top_w));

	float rough = roughness_base;
	rough *= mix(1.0, bed_side_roughness_scale, smoothstep(0.85, 0.97, -s));

	// ---------- outputs ----------
	float layer_tint = 1.0 + layer_color_variation * (hash11(k_hit) * 2.0 - 1.0) * w_bump;
	vec3 albedo = albedo_color.rgb * COLOR.rgb * layer_tint;
	float cavity = 1.0 - cavity_strength * smoothstep(0.15, 0.5, x_hit);

	NORMAL = n;
	ALBEDO = albedo;
	ROUGHNESS = rough;
	METALLIC = 0.0;
	AO = mix(1.0, cavity, w_bump);
	AO_LIGHT_AFFECT = 0.5 * (w_bump - w_trace); // mid tier has no micro-shadow, so let AO darken direct light

	v_nb = Nb;
	v_ev = ev;
	v_micro = vec4(x_hit, yy_hit, w_trace, far_w * far_aniso_strength);

	// Debug views are unlit (light() skips them) so the colours read cleanly.
	if (debug_view != 0) {
		ALBEDO = vec3(0.0);
		AO = 1.0;
		if (debug_view == 1) {
			EMISSION = vec3(w_trace, w_bump - w_trace, far_w);
		} else if (debug_view == 2) {
			EMISSION = n * 0.5 + 0.5;
		} else {
			EMISSION = vec3(bevel_mask);
		}
	}
}

// Anisotropic GGX (Filament formulation)
float d_ggx_aniso(float NoH, float ToH, float BoH, float at, float ab) {
	float a2 = at * ab;
	vec3 v = vec3(ab * ToH, at * BoH, a2 * NoH);
	float v2 = dot(v, v);
	float w2 = a2 / v2;
	return a2 * w2 * w2 / PI;
}

float v_smith_aniso(float at, float ab, float ToV, float BoV, float ToL, float BoL, float NoV, float NoL) {
	float lv = NoL * length(vec3(at * ToV, ab * BoV, NoV));
	float ll = NoV * length(vec3(at * ToL, ab * BoL, NoL));
	return 0.5 / max(lv + ll, 1e-5);
}

void light() {
	vec3 N = NORMAL;
	vec3 V = VIEW;
	vec3 L = LIGHT;
	float NoL = clamp(dot(N, L), 0.0, 1.0);
	// light() can't early-return, so everything lives inside this branch.
	if (debug_view == 0 && NoL > 0.0) {
		float ms = 1.0;
		if (v_micro.z > 0.001) {
			ms = mix(1.0, micro_shadow(v_micro.x, v_micro.y, L, v_nb, v_ev), v_micro.z);
		}

		// LIGHT_COLOR already includes a factor of PI.
		DIFFUSE_LIGHT += NoL * ATTENUATION * LIGHT_COLOR * ms / PI;

		vec3 B = v_ev - N * dot(N, v_ev); // across the layers
		float bl = length(B);
		B = bl > 1e-4 ? B / bl : normalize(cross(N, vec3(1.0, 0.0, 0.0)));
		vec3 T = cross(B, N);              // along the layers

		float alpha = max(ROUGHNESS * ROUGHNESS, 0.002);
		float across = max(far_roughness_across * far_roughness_across, alpha);
		float at = alpha;
		float ab = mix(alpha, across, v_micro.w);

		vec3 H = normalize(L + V);
		float NoV = max(dot(N, V), 1e-4);
		float NoH = clamp(dot(N, H), 0.0, 1.0);
		float VoH = clamp(dot(V, H), 0.0, 1.0);

		float D = d_ggx_aniso(NoH, dot(T, H), dot(B, H), at, ab);
		float Vis = v_smith_aniso(at, ab, dot(T, V), dot(B, V), dot(T, L), dot(B, L), NoV, NoL);
		float F = 0.04 + 0.96 * pow(1.0 - VoH, 5.0);

		SPECULAR_LIGHT += D * Vis * F * NoL * ATTENUATION * LIGHT_COLOR * SPECULAR_AMOUNT * ms;
	}
}
