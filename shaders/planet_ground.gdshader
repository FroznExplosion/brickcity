shader_type spatial;
// The planet's smooth voxel ground (Docs/Planets.md 11.1). After STA's
// shaders/terrain.gdshader: Transvoxel's stitch in the vertex stage (REQUIRED:
// without it LOD borders show as thick seams), colour by height and slope in the
// fragment, from planet-local position: world position less the planet's
// centre (`planet_centre`, set every frame by PlanetBody -- a voxel block's own
// object space is the block's, not the planet's).
render_mode cull_disabled;

// Set by the voxel engine: which of the block's 6 sides border a coarser LOD.
uniform int u_transition_mask;

uniform float planet_radius = 10000.0;
uniform vec3 planet_centre = vec3(0.0);   // world
uniform float sea_level = -6.0;
uniform vec3 grass : source_color = vec3(0.36, 0.47, 0.27);
uniform vec3 dry : source_color = vec3(0.47, 0.50, 0.30);
uniform vec3 rock : source_color = vec3(0.46, 0.43, 0.40);
uniform vec3 sand : source_color = vec3(0.76, 0.70, 0.52);
uniform vec3 snow : source_color = vec3(0.92, 0.93, 0.96);
uniform float snow_line = 34.0;     // metres over the datum
uniform float cliff_deg = 34.0;
// Faceted: shade by the triangle's own normal, the low-poly look of our
// ground; off, the mesher's smooth normals.
uniform bool faceted = true;

varying vec3 v_obj;

float tv_secondary(int idata) {
	int transition_mask = u_transition_mask & 0xff;
	int cell_border_mask = (idata >> 0) & 63;
	int vertex_border_mask = (idata >> 8) & 63;
	int m = transition_mask & cell_border_mask;
	float t = float(m != 0);
	t *= float((vertex_border_mask & ~transition_mask) == 0);
	return t;
}

vec3 tv_position(vec3 vertex_pos, vec4 fdata) {
	int idata = floatBitsToInt(fdata.a);
	vec3 pos = mix(vertex_pos, fdata.xyz, tv_secondary(idata));
	int itransition = (idata >> 16) & 0xff;
	pos *= float(itransition == 0 || (itransition & u_transition_mask) != 0);
	return pos;
}

void vertex() {
	VERTEX = tv_position(VERTEX, CUSTOM0);
	v_obj = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz - planet_centre;
}

float hash2(vec2 p) {
	return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453);
}

void fragment() {
	vec3 up = normalize(v_obj);
	float h = length(v_obj) - planet_radius;
	vec3 n_view = faceted ? normalize(cross(dFdx(VERTEX), dFdy(VERTEX))) : NORMAL;
	if (dot(n_view, NORMAL) < 0.0) n_view = -n_view;
	// The planet never turns (its node only translates): world axes are its axes.
	vec3 n_obj = normalize((INV_VIEW_MATRIX * vec4(n_view, 0.0)).xyz);
	float slope = degrees(acos(clamp(dot(n_obj, up), -1.0, 1.0)));
	// A slow mottle of grass and dry grass, by direction (no seams on a sphere).
	vec3 q = up * planet_radius;
	float mot = 0.5 + 0.25 * sin(q.x * 0.013 + sin(q.z * 0.009)) * sin(q.z * 0.011 + sin(q.y * 0.007))
			+ 0.15 * sin(q.y * 0.031 + q.x * 0.017);
	vec3 c = mix(grass, dry, clamp(mot, 0.0, 1.0) * 0.55);
	c = mix(c, sand, smoothstep(sea_level + 2.0, sea_level + 0.5, h));
	c = mix(c, rock, smoothstep(cliff_deg - 5.0, cliff_deg + 5.0, slope));
	c = mix(c, snow, smoothstep(snow_line - 4.0, snow_line + 4.0, h) * (1.0 - smoothstep(40.0, 55.0, slope)));
	ALBEDO = c;
	NORMAL = n_view;
	ROUGHNESS = 0.95;
}
