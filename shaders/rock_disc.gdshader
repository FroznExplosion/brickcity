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

void fragment() {
	float r = length(UV * 2.0 - 1.0);
	if (r > 1.0 || r < inner) discard;
	float t = (r - inner) / (1.0 - inner);
	float edge = smoothstep(0.0, 0.04, t) * smoothstep(1.0, 0.96, t);
	float band = 0.6 + 0.25 * sin(r * grain) + 0.15 * sin(r * grain * 2.7 + 1.3);
	ALBEDO = tint * (0.8 + 0.4 * band);
	// Near the camera it is rocks (RockField's near tier), not a surface.
	float clear = smoothstep(near_from, near_to, length(VERTEX));
	ALPHA = clamp(density * band * edge, 0.0, 1.0) * clear;
}
