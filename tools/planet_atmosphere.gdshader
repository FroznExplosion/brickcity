// Test 12 of the sphere-planet tests (Docs/Planets.md 10b): an atmosphere as
// a full-screen pass, to price it. Single scattering, Rayleigh and Mie, 12
// samples along the view ray (to the depth buffer or out of the shell) and 4
// toward the sun from each. Drawn on a quad that covers the screen.
shader_type spatial;
render_mode unshaded, depth_test_disabled, cull_disabled, blend_mix;

uniform sampler2D depth_tex : hint_depth_texture, filter_nearest;
uniform vec3 planet_centre = vec3(0.0, -10000.0, 0.0);
uniform float planet_r = 10000.0;
uniform float atmo_r = 12000.0;
uniform vec3 sun_dir = vec3(0.4, 0.6, 0.3);   // surface -> sun
uniform float strength = 1.0;

const int VIEW_STEPS = 12;
const int LIGHT_STEPS = 4;
const vec3 BETA_R = vec3(5.8e-4, 1.35e-3, 3.31e-3);   // per metre, scaled for a small planet
const float BETA_M = 2.1e-3;
const float H_R = 400.0;
const float H_M = 120.0;

void vertex() {
	POSITION = vec4(VERTEX.xy * 2.0, 1.0, 1.0);
}

vec2 ray_sphere(vec3 o, vec3 d, vec3 c, float r) {
	vec3 oc = o - c;
	float b = dot(oc, d);
	float q = dot(oc, oc) - r * r;
	float h = b * b - q;
	if (h < 0.0) return vec2(1e9, -1e9);
	h = sqrt(h);
	return vec2(-b - h, -b + h);
}

void fragment() {
	float depth = textureLod(depth_tex, SCREEN_UV, 0.0).r;
	vec4 ndc = vec4(SCREEN_UV * 2.0 - 1.0, depth, 1.0);
	vec4 view = INV_PROJECTION_MATRIX * ndc;
	view.xyz /= view.w;
	vec3 cam = (INV_VIEW_MATRIX * vec4(0.0, 0.0, 0.0, 1.0)).xyz;
	vec3 world = (INV_VIEW_MATRIX * vec4(view.xyz, 1.0)).xyz;
	vec3 dir = normalize(world - cam);
	float hit_t = length(world - cam);
	vec2 shell = ray_sphere(cam, dir, planet_centre, atmo_r);
	float t0 = max(shell.x, 0.0);
	float t1 = min(shell.y, hit_t);
	vec3 sum_r = vec3(0.0);
	vec3 sum_m = vec3(0.0);
	float od_r = 0.0;
	float od_m = 0.0;
	if (t1 > t0) {
		float ds = (t1 - t0) / float(VIEW_STEPS);
		for (int i = 0; i < VIEW_STEPS; i++) {
			vec3 p = cam + dir * (t0 + ds * (float(i) + 0.5));
			float h = length(p - planet_centre) - planet_r;
			float dr = exp(-h / H_R) * ds;
			float dm = exp(-h / H_M) * ds;
			od_r += dr;
			od_m += dm;
			vec2 ls = ray_sphere(p, sun_dir, planet_centre, atmo_r);
			float dl = ls.y / float(LIGHT_STEPS);
			float lr = 0.0;
			float lm = 0.0;
			for (int j = 0; j < LIGHT_STEPS; j++) {
				vec3 q = p + sun_dir * dl * (float(j) + 0.5);
				float hq = length(q - planet_centre) - planet_r;
				lr += exp(-hq / H_R) * dl;
				lm += exp(-hq / H_M) * dl;
			}
			vec3 tau = BETA_R * (od_r + lr) + BETA_M * 1.1 * (od_m + lm);
			vec3 att = exp(-tau);
			sum_r += dr * att;
			sum_m += dm * att;
		}
	}
	float mu = dot(dir, sun_dir);
	float pr = 3.0 / (16.0 * PI) * (1.0 + mu * mu);
	float g = 0.76;
	float pm = 3.0 / (8.0 * PI) * ((1.0 - g * g) * (1.0 + mu * mu)) / ((2.0 + g * g) * pow(1.0 + g * g - 2.0 * g * mu, 1.5));
	vec3 col = (sum_r * BETA_R * pr + sum_m * BETA_M * pm) * 20.0 * strength;
	vec3 trans = exp(-(BETA_R * od_r + BETA_M * 1.1 * od_m));
	ALBEDO = col;
	ALPHA = clamp(1.0 - dot(trans, vec3(0.333)), 0.0, 1.0);
}
