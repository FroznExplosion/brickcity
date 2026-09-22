shader_type canvas_item;

// The workshop's aim dot: one flat colour that stands out from whatever is
// under the middle of the screen.
//
// The inverse of what is underneath, so a red brick gets a cyan dot -- except
// where inverting changes nothing you can see: a mid grey inverts to itself.
// There it goes to black or white, whichever is further from what is under it.

// The screen as drawn before the HUD: the bricks, the ghost, the sky.
uniform sampler2D screen_texture : hint_screen_texture, filter_linear_mipmap;
// The dot's size in pixels, so the middle of it can be found from any pixel.
uniform float size_px = 8.0;

void fragment() {
	vec2 d = UV - vec2(0.5);
	float r = length(d) * 2.0;
	if (r > 1.0) {
		discard;
	}
	// Sampled once for the whole dot, at its centre, a little blurred: a dot
	// that took each pixel's own inverse would be a picture of the stud edge
	// under it rather than a dot.
	vec2 centre = SCREEN_UV - d * size_px * SCREEN_PIXEL_SIZE;
	vec3 under = textureLod(screen_texture, centre, 2.0).rgb;
	vec3 inv = vec3(1.0) - under;
	const vec3 LUMA = vec3(0.2126, 0.7152, 0.0722);
	float lu = dot(under, LUMA);
	vec3 c = abs(lu - dot(inv, LUMA)) < 0.35 ? vec3(lu > 0.5 ? 0.0 : 1.0) : inv;
	COLOR = vec4(c, 1.0 - smoothstep(0.8, 1.0, r));
}
