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
// The biomes (Docs/Planets.md 11.9; PlanetBiomes): an equirect map baked with
// the impostor -- RGB the ground's base colour, A the sea-level temperature
// in t_range. No mipmaps: the date line's jump in u would draw a seam.
uniform sampler2D biome_map : source_color, filter_linear, repeat_enable;
uniform vec2 t_range = vec2(-30.0, 40.0);
uniform float lapse = 0.25;       // degrees C a metre up
uniform vec3 rock : source_color = vec3(0.46, 0.43, 0.40);
uniform vec3 sand : source_color = vec3(0.76, 0.70, 0.52);
uniform vec3 snow : source_color = vec3(0.92, 0.93, 0.96);
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
	// The biome's colour, the UV as PlanetBiomes.pixel_of_dir: the planet never
	// turns, so planet-local `up` is the map's direction.
	float lat = asin(clamp(up.y, -1.0, 1.0));
	float lon = atan(up.x, up.z);
	vec4 bm = texture(biome_map, vec2(lon / 6.2831853 + 0.5, 0.5 - lat / 3.14159265));
	// A fine mottle over it (the map's pixel is tens of metres), by direction.
	vec3 q = up * planet_radius;
	float mot = 0.25 * sin(q.x * 0.13 + sin(q.z * 0.09)) * sin(q.z * 0.11 + sin(q.y * 0.07))
			+ 0.15 * sin(q.y * 0.31 + q.x * 0.17);
	vec3 c = bm.rgb * (1.0 + 0.12 * mot);
	c = mix(c, sand, smoothstep(sea_level + 2.0, sea_level + 0.5, h));
	c = mix(c, rock, smoothstep(cliff_deg - 5.0, cliff_deg + 5.0, slope));
	// Snow where it is below freezing at this height, not on steep faces.
	float temp = mix(t_range.x, t_range.y, bm.a) - lapse * max(h, 0.0);
	c = mix(c, snow, smoothstep(1.5, -1.5, temp) * (1.0 - smoothstep(40.0, 55.0, slope)));
	ALBEDO = c;
	NORMAL = n_view;
	ROUGHNESS = 0.95;
}
