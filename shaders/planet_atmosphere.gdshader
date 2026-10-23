shader_type spatial;
// The planet's halo from space (Docs/Planets.md 11.1): a shell a little bigger
// than the planet, added where the view grazes the limb. After STA's
// shaders/atmosphere.gdshader. From inside it is culled: the sky takes over.
render_mode blend_add, cull_back, unshaded, depth_draw_never, shadows_disabled;

uniform vec3 atmo_color : source_color = vec3(0.45, 0.65, 1.0);
uniform vec3 sun_dir = vec3(0.4, 0.6, 0.3);   // planet-local
uniform float density = 1.3;
uniform float falloff = 3.0;

varying vec3 v_dir;

void vertex() {
	v_dir = normalize(VERTEX);
}

void fragment() {
	float rim = pow(1.0 - clamp(dot(normalize(VIEW), normalize(NORMAL)), 0.0, 1.0), falloff);
	float day = clamp(dot(v_dir, normalize(sun_dir)) * 0.8 + 0.4, 0.0, 1.0);
	ALBEDO = atmo_color * day;
	ALPHA = clamp(rim * density, 0.0, 1.0);
}
