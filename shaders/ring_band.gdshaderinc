// A ring's cover at radius `r` (of its outer radius): what its far disc draws
// (rock_disc.gdshader) and what its shadow takes from the sun
// (body_shadow.gdshaderinc). Mirrored by RockField.alpha_at for the camera.
float ring_band(float r, float g) {
	return 0.6 + 0.25 * sin(r * g) + 0.15 * sin(r * g * 2.7 + 1.3);
}

float ring_alpha(float r, float r_in, float dens, float g) {
	if (r > 1.0 || r < r_in) return 0.0;
	float t = (r - r_in) / (1.0 - r_in);
	float edge = smoothstep(0.0, 0.04, t) * smoothstep(1.0, 0.96, t);
	return clamp(dens * ring_band(r, g) * edge, 0.0, 1.0);
}
