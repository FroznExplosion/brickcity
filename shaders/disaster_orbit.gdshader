shader_type spatial;

// Bricks caught in the funnel: each MultiMesh instance orbits the node's Y
// axis on the GPU. Cosmetic -- none of these are bodies.
//
// INSTANCE_CUSTOM: x = orbit radius (m), y = height (m), z = start angle
// (radians), w = angular speed (radians per second). Instance transforms are
// left at identity; this shader places each brick on its orbit.

uniform float rise = 3.0;          // m/s the bricks climb as they go round
uniform float column = 40.0;       // m, where a brick climbs to before it wraps

void vertex() {
	float r = INSTANCE_CUSTOM.x;
	float ang = INSTANCE_CUSTOM.z + TIME * INSTANCE_CUSTOM.w;
	float h = mod(INSTANCE_CUSTOM.y + TIME * rise * (0.6 + 0.4 * fract(INSTANCE_CUSTOM.z)), column);
	// Wider up high, as the funnel is.
	float rr = r * (0.55 + h / column);
	vec3 centre = vec3(cos(ang) * rr, h, sin(ang) * rr);
	// Tumble: spin the brick about its own axes with time.
	float t = TIME * (2.0 + INSTANCE_CUSTOM.w);
	mat3 tumble = mat3(vec3(cos(t), sin(t), 0.0), vec3(-sin(t), cos(t), 0.0), vec3(0.0, 0.0, 1.0));
	// Instance transforms are identity, so this is the brick's place about the
	// node's origin -- the funnel's foot.
	VERTEX = tumble * VERTEX + centre;
}

void fragment() {
	ALBEDO = COLOR.rgb;
	ROUGHNESS = 0.45;
}
