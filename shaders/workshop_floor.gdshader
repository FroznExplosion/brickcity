// The building workshop's floor: one quad the size of the build area, its studs drawn
// (Docs/BuildTools.md section 15). A floor of real plates would be remeshed on every edit.
shader_type spatial;

uniform vec3 plate_colour : source_color = vec3(0.30, 0.33, 0.36);
const float PITCH = 0.35;
const float STUD = 0.26;   // across, over the pitch: 0.7

varying vec2 at;

void vertex() {
	at = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xz / PITCH;
}

void fragment() {
	vec2 cell = fract(at) - 0.5;
	float r = length(cell) / (STUD / PITCH * 0.5);
	float px = max(fwidth(at.x), fwidth(at.y));
	// Gone by the time a stud is a few pixels across: past that they only shimmer.
	float near = 1.0 - smoothstep(0.08, 0.3, px);
	float disc = (1.0 - smoothstep(1.0 - px * 2.0, 1.0 + px * 2.0, r)) * near;
	float rim = smoothstep(0.7, 1.0, r) * disc;
	ALBEDO = plate_colour * (1.0 + 0.1 * disc);
	ROUGHNESS = 0.55;
	NORMAL = normalize(NORMAL + (VIEW_MATRIX * vec4(cell.x, 0.0, cell.y, 0.0)).xyz * rim * 2.0);
}
