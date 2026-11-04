shader_type spatial;
// A ring or a belt from afar (Docs/Planets.md 11.12 step 6): an annulus on a
// plane, banded by a few sines of the radius. Near, RockField's rocks.
render_mode unshaded, blend_mix, cull_disabled, depth_draw_never, shadows_disabled;

uniform float inner = 0.6;    // of the outer radius
uniform vec3 tint : source_color = vec3(0.5, 0.46, 0.42);
uniform float density = 0.7;
uniform float grain = 60.0;
uniform float near_from = 1500.0;
uniform float near_to = 6000.0;
// Its planet's shadow across it (Docs/Lighting.md 2a): the sun's way in the
// ring's frame, and the planet's radius and the disc's, in its metres.
uniform vec3 sun_local = vec3(0.0, 1.0, 0.0);
uniform float body_r = 0.0;
uniform float outer_m = 1.0;

#include "res://shaders/ring_band.gdshaderinc"

varying vec3 v_q;

void vertex() {
	v_q = VERTEX;
}

void fragment() {
	float r = length(UV * 2.0 - 1.0);
	if (r > 1.0 || r < inner) discard;
	float band = ring_band(r, grain);
	ALBEDO = tint * (0.8 + 0.4 * band);
	if (body_r > 0.0) {
		vec3 q = vec3(v_q.x, 0.0, v_q.z) / outer_m;
		float along = dot(q, sun_local);
		if (along < 0.0) {
			float d = length(q - sun_local * along);
			ALBEDO *= mix(0.08, 1.0, smoothstep(body_r * 0.97, body_r * 1.03, d));
		}
	}
	// Near the camera it is rocks (RockField's near tier), not a surface.
	float clear = smoothstep(near_from, near_to, length(VERTEX));
	ALPHA = ring_alpha(r, inner, density, grain) * clear;
}
