// Shadows of other bodies (Docs/Lighting.md 2a): each a sphere (xyz its
// centre, w its radius, in this body's radii and frame); how much of the star's
// disc, `star_ang` its angular radius, a point `p` on this body still sees.
uniform int shadower_count = 0;
uniform vec4 shadowers[4];
uniform float star_ang = 0.01;

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
