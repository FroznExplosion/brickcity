shader_type spatial;

// What stands in a group of storeys (Docs/Interiors.md section 8.2): the
// interior pieces of every room in it as one MultiMesh, and its items as
// another. One drawing from arm's length to the edge of view.
//
// It is never switched on or off in one frame. Each box fades over the last
// `fade_band` metres of `fade_range` by its OWN distance from the camera, on
// the screen-door pattern the impostor ladder uses (ImpostorLod._fading,
// shaders/impostor.gdshader), so a storey group built or dropped at the edge
// of its range is built or dropped with nothing of it showing.
//
// Nor does it change shade in one step. Near, a piece is lit like the
// brickwork round it, shadows and all. Far off that is a dark box in a dark
// room behind a window a few pixels wide, so past `lit_near` it goes over,
// by `lit_far`, to a fixed shade per face that no light touches -- what the
// fake rung drew (shaders/fake_interior.gdshader), reached by a ramp instead
// of by a room changing rungs.
//
// The colour is the MultiMesh instance colour, which Godot multiplies into
// COLOR: the filament colour the same part has as a brick.
render_mode cull_back;

uniform float fade_range = 100.0;
uniform float fade_band = 15.0;
uniform float lit_near = 30.0;
uniform float lit_far = 60.0;
// A little darker than lit: a room seen from outside is lit from its windows.
uniform float far_dim = 0.8;
uniform float roughness = 0.75;

varying float v_dist;
varying vec3 v_world_normal;

float ign(vec2 px) {
	return fract(52.9829189 * fract(dot(px, vec2(0.06711056, 0.00583715))));
}

void vertex() {
	// The instance's origin: MODEL_MATRIX already holds the instance transform,
	// which scales the unit cube, so the normal wants normalising.
	v_dist = distance(MODEL_MATRIX[3].xyz, CAMERA_POSITION_WORLD);
	v_world_normal = normalize((MODEL_MATRIX * vec4(NORMAL, 0.0)).xyz);
}

void fragment() {
	float own = smoothstep(lit_near, lit_far, v_dist);
	// Tops brightest, the two side axes told apart, bottoms darkest.
	float shade = 0.55 + 0.35 * max(v_world_normal.y, 0.0) + 0.1 * abs(v_world_normal.x);
	ALBEDO = COLOR.rgb * (1.0 - own);
	EMISSION = COLOR.rgb * shade * far_dim * own;
	SPECULAR = 0.5 * (1.0 - own);
	ROUGHNESS = roughness;
	float t = clamp((v_dist - (fade_range - fade_band)) / fade_band, 0.0, 1.0);
	// Not in an orthographic pass: the sun's shadow map is drawn from the sun,
	// and a shadow with holes in it is worse than one that ends.
	bool gone = PROJECTION_MATRIX[3][3] < 0.5 && ign(FRAGCOORD.xy) < t;
	ALPHA = gone ? 0.0 : 1.0;
	ALPHA_SCISSOR_THRESHOLD = 0.5;
}
