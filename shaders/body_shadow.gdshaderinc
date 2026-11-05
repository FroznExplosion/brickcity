// Shadows of other bodies (Docs/Lighting.md 2a): each a sphere (xyz its
// centre, w its radius, in this body's radii and frame); how much of the star's
// disc, `star_ang` its angular radius, a point `p` on this body still sees.
uniform int shadower_count = 0;
uniform vec4 shadowers[4];
uniform float star_ang = 0.01;
// Its own ring's shadow: the ring's axis (this body's frame), its inner and
// outer radius in this body's radii (outer 0: none), as its disc draws it.
uniform vec3 ring_axis = vec3(0.0, 1.0, 0.0);
uniform vec2 ring_span = vec2(0.0);
uniform float ring_density = 0.7;
uniform float ring_grain = 60.0;
// How much of the sun the thickest of it takes (RockField.SHADE).
const float RING_SHADE = 0.85;

#include "res://shaders/ring_band.gdshaderinc"

// The sun left at `p` (this body's radii) through its ring, toward `sd`.
float ring_shadow(vec3 p, vec3 sd) {
	if (ring_span.y <= 0.0) return 1.0;
	float dn = dot(sd, ring_axis);
	if (abs(dn) < 1e-4) return 1.0;
	float t = -dot(p, ring_axis) / dn;
	if (t <= 0.0) return 1.0;
	float r = length(p + sd * t) / ring_span.y;
	return 1.0 - RING_SHADE * ring_alpha(r, ring_span.x / ring_span.y, ring_density, ring_grain);
}

float body_shadow(vec3 p, vec3 sd) {
	float seen = 1.0;
	for (int i = 0; i < 4; i++) {
		if (i >= shadower_count) break;
		vec3 to_o = shadowers[i].xyz - p;
		float d = length(to_o);
		if (dot(to_o, sd) <= 0.0) continue;
		float a_o = asin(clamp(shadowers[i].w / d, 0.0, 1.0));
		float theta = acos(clamp(dot(to_o / d, sd), -1.0, 1.0));
		seen = min(seen, clamp((theta - (a_o - star_ang)) / (2.0 * star_ang), 0.0, 1.0));
	}
	return seen;
}
