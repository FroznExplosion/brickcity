shader_type spatial;
// Ice shards (VfxPool.spawn_shatter, Docs/GpuOffload.md 2.7): a frozen enemy's
// burst, worked out HERE from what each shard was thrown with, so the CPU
// writes a burst once when it starts and then only its age, a frame at a time.
// Each shard falls, bounces on the enemy's floor (up to BOUNCES times, giving
// keeping `keep_y` of its upward speed and `keep` of all of it), then lies there;
// the burst shrinks away over its last 40%.
//
// Per instance, written by VfxPool.spawn_shatter:
//   transform        the shard's size, and where it starts (world)
//   INSTANCE_CUSTOM  the velocity it starts with (m/s)
//   COLOR            rgb: its spin axis, a: its rate (rad/s)
render_mode skip_vertex_transform;

#define BOUNCES 6

uniform float age = 0.0;            // seconds since the burst
uniform float max_life = 1.6;
uniform vec3 fall = vec3(0.0, -14.7, 0.0);  // m/s^2
uniform float floor_y = 0.0;        // the floor, + the 5 cm a shard rests at
uniform float keep_y = 0.35;
uniform float keep = 0.7;
uniform vec3 ice : source_color = vec3(0.72, 0.86, 1.0);

mat3 axis_angle(vec3 a, float ang) {
	float c = cos(ang);
	float s = sin(ang);
	float k = 1.0 - c;
	return mat3(
			vec3(c + a.x * a.x * k, a.y * a.x * k + a.z * s, a.z * a.x * k - a.y * s),
			vec3(a.x * a.y * k - a.z * s, c + a.y * a.y * k, a.z * a.y * k + a.x * s),
			vec3(a.x * a.z * k + a.y * s, a.y * a.z * k - a.x * s, c + a.z * a.z * k));
}

// When a shard at height y going up at vy (fall's y g) next reaches the
// floor; -1 when it never does.
float to_floor(float y, float vy, float g) {
	float h = y - floor_y;
	if (h <= 0.0 && vy <= 0.0) {
		return 0.0;
	}
	if (g >= 0.0) {
		return -1.0;
	}
	// h + vy t + g t^2 / 2 = 0, the later root (on the floor going up: the
	// hop's length).
	h = max(h, 0.0);
	return (-vy - sqrt(vy * vy - 2.0 * g * h)) / g;
}

void vertex() {
	vec3 p = MODEL_MATRIX[3].xyz;
	vec3 v = INSTANCE_CUSTOM.xyz;
	float left = age;
	int i = 0;
	for (; i < BOUNCES; i++) {
		float t = to_floor(p.y, v.y, fall.y);
		if (t < 0.0 || t >= left) {
			break;
		}
		p += v * t + 0.5 * fall * t * t;
		p.y = floor_y;
		v += fall * t;
		v.y *= -keep_y;
		v *= keep;
		left -= t;
	}
	if (i < BOUNCES) {
		p += v * left + 0.5 * fall * left * left;
		p.y = max(p.y, floor_y);
	}
	// Else bounced out: what is left of its hops is a few millimetres, and it
	// lies where it is.
	float s = 1.0 - smoothstep(0.6, 1.0, age / max_life);
	mat3 b = axis_angle(normalize(COLOR.rgb), COLOR.a * age) * mat3(MODEL_MATRIX);
	vec3 world = p + b * (VERTEX * max(s, 0.01));
	VERTEX = (VIEW_MATRIX * vec4(world, 1.0)).xyz;
	NORMAL = normalize(mat3(VIEW_MATRIX) * (b * NORMAL));
}

void fragment() {
	// Flat faces, a cut crystal's.
	NORMAL = normalize(cross(dFdx(VERTEX), dFdy(VERTEX)));
	ALBEDO = ice;
	ROUGHNESS = 0.12;
	SPECULAR = 0.7;
	RIM = 0.4;
	RIM_TINT = 0.6;
}
