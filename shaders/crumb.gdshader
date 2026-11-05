shader_type spatial;
// Crumbs (IslandManager, Docs/GpuOffload.md 2.1): the bricks a small piece
// breaks into, falling, landing and shrinking away, worked out HERE from what
// each was thrown with, so the CPU writes a crumb when something happens to it
// -- thrown, bounced, landed -- and not every tick. The path is the CPU's own
// step written out in closed form (semi-implicit Euler, a physics tick at a
// time), so where the CPU says a crumb is and where it is drawn agree at every
// tick; between ticks it moves smoothly.
//
// Per instance, written by IslandManager._crumb_write:
//   transform        the crumb's turn when it came loose, and where this
//                    stretch of its fall starts
//   INSTANCE_CUSTOM  the velocity it starts with (m/s), and the tick it starts
//   COLOR            r: its colour, 8 bits a channel in one integer
//                    g: its spin, an axis (octahedral, 8 + 8 bits) and a rate
//                       (8 bits over +-CRUMB_SPIN)
//                    b: the tick it stops -- lands, or reaches its floor and
//                       waits for the CPU to say what happens next
//                    a: the tick it came loose
// All whole numbers under 2^24, exact in a float. Ticks are physics ticks.
//
// A planet's crumbs (PlanetCrumbs) set `radial`: the instances are written
// planet-local and drawn through the planet (`frame`, its world transform, the
// MultiMesh's own too), the velocity and spin axis turned by it, and down is
// toward its centre from where the stretch starts -- over a few metres of fall,
// a straight line. And `fade_from_stop`: a crumb lies `full` ticks from when it
// stops, then shrinks away by `life`, however long it fell.
render_mode skip_vertex_transform;

// Physics ticks since the start, with the fraction since the last one
// (IslandManager._process).
global uniform float crumb_clock;

uniform float tick_s = 0.0166667;   // a tick's seconds
uniform float gravity = 9.8;        // m/s^2, down -Y
uniform float spin_max = 5.0;       // IslandManager.CRUMB_SPIN
// How it goes away (IslandManager): shrinking from `full` ticks to `life` --
// or, while bricks are kept (BrickHeap), fading over the last `fade` of
// `fall_max`, for one that never landed.
uniform bool keep = false;
uniform float life = 84.0;
uniform float full = 21.0;
uniform float fall_max = 360.0;
uniform float fade = 36.0;
uniform float roughness_v = 0.85;
uniform bool radial = false;
uniform mat4 frame = mat4(1.0);
uniform bool fade_from_stop = false;

varying vec3 v_colour;

vec3 crumb_rgb(float f) {
	uint u = uint(f);
	return vec3(float((u >> 16u) & 255u), float((u >> 8u) & 255u), float(u & 255u)) / 255.0;
}

vec3 crumb_axis(float f) {
	uint u = uint(f);
	vec2 e = vec2(float((u >> 16u) & 255u), float((u >> 8u) & 255u)) / 255.0 * 2.0 - 1.0;
	vec3 n = vec3(e, 1.0 - abs(e.x) - abs(e.y));
	float t = max(-n.z, 0.0);
	n.x += n.x >= 0.0 ? -t : t;
	n.y += n.y >= 0.0 ? -t : t;
	return normalize(n);
}

float crumb_rate(float f) {
	uint u = uint(f);
	return (float(u & 255u) / 255.0 * 2.0 - 1.0) * spin_max;
}

mat3 axis_angle(vec3 a, float ang) {
	float c = cos(ang);
	float s = sin(ang);
	float k = 1.0 - c;
	return mat3(
			vec3(c + a.x * a.x * k, a.y * a.x * k + a.z * s, a.z * a.x * k - a.y * s),
			vec3(a.x * a.y * k - a.z * s, c + a.y * a.y * k, a.z * a.y * k + a.x * s),
			vec3(a.x * a.z * k + a.y * s, a.y * a.z * k - a.x * s, c + a.z * a.z * k));
}

void vertex() {
	mat3 turn = mat3(frame);
	vec3 v0 = turn * INSTANCE_CUSTOM.xyz;
	float t0 = INSTANCE_CUSTOM.w;
	float t_end = COLOR.b;
	float born = COLOR.a;
	// Ticks into this stretch of the fall, held at its end until the CPU
	// moves it on.
	float n = clamp(crumb_clock - t0, 0.0, max(t_end - t0, 0.0));
	vec3 p0 = MODEL_MATRIX[3].xyz;
	vec3 down = radial ? normalize(frame[3].xyz - p0) : vec3(0.0, -1.0, 0.0);
	vec3 p = p0 + v0 * (n * tick_s);
	p += down * (gravity * tick_s * tick_s * n * (n + 1.0) * 0.5);
	// It turns from when it came loose until it stops.
	float turned = clamp(crumb_clock, born, max(t_end, born)) - born;
	mat3 spin = axis_angle(turn * crumb_axis(COLOR.g), crumb_rate(COLOR.g) * turned * tick_s);
	float age = crumb_clock - (fade_from_stop ? t_end : born);
	float s = 1.0;
	if (keep) {
		if (age > fall_max - fade) {
			s = max((fall_max - age) / fade, 0.01);
		}
	} else if (age > full) {
		s = max(1.0 - (age - full) / (life - full), 0.01);
	}
	mat3 b = spin * mat3(MODEL_MATRIX);
	vec3 world = p + b * (VERTEX * s);
	VERTEX = (VIEW_MATRIX * vec4(world, 1.0)).xyz;
	NORMAL = normalize(mat3(VIEW_MATRIX) * (b * NORMAL));
	v_colour = crumb_rgb(COLOR.r);
}

void fragment() {
	ALBEDO = v_colour;
	ROUGHNESS = roughness_v;
}
