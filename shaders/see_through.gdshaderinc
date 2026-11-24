// SEE-THROUGH WATER (Docs/MineWater.md 7.4): the mine world draws its water
// with `#define SEE_THROUGH` in front of water.gdshader / water_fluid.gdshader
// (WaterShaders.see_through). How much shows through goes by how much water
// the eye looks through, from the opaque depth under it: a puddle shows its
// floor, a deep pool or the open sea goes to the water's own colour, and
// water with nothing behind it (sky) is opaque. Minecraft's water, on bricks.

uniform sampler2D see_depth : hint_depth_texture, filter_nearest;
/// Water this thick (metres) is about two thirds opaque.
uniform float see_clear_m = 1.0;
/// The least opaque water is, a film over its floor.
uniform float see_min_alpha = 0.45;

float see_alpha(vec2 suv, vec3 view_pos, mat4 inv_proj) {
	float d = texture(see_depth, suv).r;
	vec4 v = inv_proj * vec4(suv * 2.0 - 1.0, d, 1.0);
	float behind = -v.z / v.w;
	float thick = max(behind + view_pos.z, 0.0);
	return mix(see_min_alpha, 1.0, 1.0 - exp(-thick / see_clear_m));
}

