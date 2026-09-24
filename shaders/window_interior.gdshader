shader_type spatial;

// A shell's windows: glass with a room behind it that is not there.
//
// Interior mapping. The pane knows where on the glass this pixel is (UV, in
// metres) and how big the glass is (UV2). The view ray is carried through the
// glass into a box of a room -- floor, ceiling, back wall and the walls either
// side -- and whichever face it reaches first is what the pixel shows. A few
// boxes of furniture stand on the floor, chosen by the room's KIND, which the
// pane carries in its vertex colour alpha (BuildingShell._pane_colour): a
// storeroom's window shows crates, an office's a desk, and walking up to the
// building finds the same kind of room there.
//
// Unshaded, no shadows, no textures, no per-room data: the whole room is a
// handful of ray/box tests in the pixels that are glass.
render_mode unshaded, cull_back, shadows_disabled;

// The room around the glass, in metres. Set from the recipe by
// BuildingShell.window_material(), so they agree with the bricks.
uniform float sill = 0.84;     // room floor up to the bottom of the glass
uniform float head = 0.42;     // top of the glass up to the ceiling
uniform float side = 0.7;      // wall either side of the glass
uniform float depth = 3.5;     // glass back to the far wall

uniform vec3 wall_colour : source_color = vec3(0.80, 0.74, 0.64);
uniform vec3 floor_colour : source_color = vec3(0.48, 0.34, 0.22);
uniform vec3 ceiling_colour : source_color = vec3(0.90, 0.88, 0.84);
uniform vec3 sky_colour : source_color = vec3(0.62, 0.72, 0.84);
// The colour of the light in a lit room: warm, so a window reads as a room
// with the lights on and not as a grey panel.
uniform vec3 light_colour : source_color = vec3(1.05, 0.96, 0.82);
uniform float frame = 0.035;   // dark rim round the glass, metres

const vec3 PALETTE[6] = vec3[6](
		vec3(0.78, 0.22, 0.16), vec3(0.92, 0.55, 0.14), vec3(0.92, 0.80, 0.22),
		vec3(0.58, 0.42, 0.26), vec3(0.36, 0.38, 0.42), vec3(0.18, 0.36, 0.70));

// Entry distance of a ray into a box, or a very large number; `n` is the face
// it came in through.
float box_hit(vec3 o, vec3 d, vec3 lo, vec3 hi, out vec3 n) {
	vec3 t0 = (lo - o) / d;
	vec3 t1 = (hi - o) / d;
	vec3 tmin = min(t0, t1);
	vec3 tmax = max(t0, t1);
	float tn = max(max(tmin.x, tmin.y), tmin.z);
	float tf = min(min(tmax.x, tmax.y), tmax.z);
	n = vec3(0.0);
	if (tn > tf || tn < 0.0) {
		return 1e9;
	}
	if (tn == tmin.x) {
		n.x = d.x > 0.0 ? -1.0 : 1.0;
	} else if (tn == tmin.y) {
		n.y = d.y > 0.0 ? -1.0 : 1.0;
	} else {
		n.z = d.z > 0.0 ? -1.0 : 1.0;
	}
	return tn;
}

vec3 furniture_shade(vec3 base, vec3 n) {
	return base * (0.62 + 0.3 * max(n.y, 0.0) + 0.08 * abs(n.x));
}

void fragment() {
	vec2 size = UV2;
	// The ray from the eye through this pixel, in the glass's own frame:
	// x along the glass, y up, z into the building.
	vec3 ray = -VIEW;
	vec3 along = normalize(TANGENT);
	vec3 up = normalize((VIEW_MATRIX * vec4(0.0, 1.0, 0.0, 0.0)).xyz);
	vec3 into = -normalize(NORMAL);
	vec3 d = vec3(dot(ray, along), dot(ray, up), dot(ray, into));
	// No axis exactly zero, so every division below is finite.
	d = mix(min(d, vec3(-1e-4)), max(d, vec3(1e-4)), step(vec3(0.0), d));
	vec3 o = vec3(UV.x, UV.y, 0.0);

	// Where the ray leaves the room box, and through which face.
	vec3 lo = vec3(-side, -sill, 0.0);
	vec3 hi = vec3(size.x + side, size.y + head, depth);
	vec3 exit_at = vec3(d.x > 0.0 ? hi.x : lo.x, d.y > 0.0 ? hi.y : lo.y, hi.z);
	vec3 tf = (exit_at - o) / d;
	float t = min(min(tf.x, tf.y), tf.z);
	vec3 col;
	if (t == tf.z) {
		col = wall_colour;
	} else if (t == tf.y) {
		col = d.y > 0.0 ? ceiling_colour : floor_colour;
	} else {
		col = wall_colour * 0.82;
	}

	// Furniture, by the room's kind: Room.KINDS order.
	float kind = floor(COLOR.a * 4.0 + 0.5);
	float s1 = COLOR.r;
	float s2 = COLOR.b;
	float y0 = -sill;
	vec3 n;
	float tb;
	vec3 room_w = vec3(size.x + side * 2.0, 0.0, 0.0);
	if (kind < 0.5) {
		// Storeroom: two crates along the back, and a third stacked on the
		// first -- ON it, not floating wherever its own seed would put it.
		for (int i = 0; i < 3; i++) {
			float fi = float(i == 2 ? 0 : i);
			float x = -side + 0.15 + fract(s1 * (3.1 + fi * 1.7)) * (room_w.x - 1.0);
			float z = depth - 0.8 - fract(s2 * (2.3 + fi)) * 0.9;
			float h = i == 2 ? 0.7 : 0.0;
			vec3 blo = vec3(x, y0 + h, z);
			vec3 bhi = blo + vec3(0.7, 0.7, 0.7);
			tb = box_hit(o, d, blo, bhi, n);
			if (tb < t) {
				t = tb;
				col = furniture_shade(PALETTE[3], n);
			}
		}
	} else if (kind < 1.5) {
		// Office: a desk and a chair in front of it.
		float x = -side + 0.2 + s1 * max(room_w.x - 1.8, 0.1);
		float z = 1.2 + s2 * (depth - 2.2);
		tb = box_hit(o, d, vec3(x, y0, z), vec3(x + 1.4, y0 + 0.75, z + 0.7), n);
		if (tb < t) {
			t = tb;
			col = furniture_shade(PALETTE[int(s2 * 5.99)], n);
		}
		tb = box_hit(o, d, vec3(x + 0.45, y0, z - 0.6), vec3(x + 0.95, y0 + 0.5, z - 0.1), n);
		if (tb < t) {
			t = tb;
			col = furniture_shade(PALETTE[5], n);
		}
	} else if (kind < 2.5) {
		// Kitchen: a counter along the back wall and a table.
		tb = box_hit(o, d, vec3(-side, y0, depth - 0.6), vec3(size.x + side, y0 + 0.9, depth), n);
		if (tb < t) {
			t = tb;
			col = furniture_shade(PALETTE[4], n);
		}
		float x = -side + 0.3 + s1 * max(room_w.x - 1.6, 0.1);
		tb = box_hit(o, d, vec3(x, y0, 1.0), vec3(x + 1.0, y0 + 0.75, 2.0), n);
		if (tb < t) {
			t = tb;
			col = furniture_shade(PALETTE[int(s1 * 5.99)], n);
		}
	}

	// Lit from the window: darker the deeper the ray got, and by the room's
	// own light (some rooms have theirs off).
	vec3 p = o + d * t;
	col *= mix(1.0, 0.5, clamp(p.z / depth, 0.0, 1.0)) * COLOR.g * light_colour;

	// A dark rim where the glass meets the brick, and the sky in the glass,
	// more of it the flatter the glass is seen.
	vec2 edge = min(UV, size - UV);
	col = mix(col, vec3(0.14), step(min(edge.x, edge.y), frame));
	float fres = pow(1.0 - clamp(dot(normalize(VIEW), normalize(NORMAL)), 0.0, 1.0), 3.0);
	ALBEDO = mix(col, sky_colour, 0.06 + 0.4 * fres);
}
