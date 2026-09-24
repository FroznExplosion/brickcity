shader_type spatial;

// The FAKE rung of a room (Docs/Scale.md section 4.1): furniture seen through a
// window from further off than anybody could touch it. No collision anywhere
// and no lighting here -- unshaded, so it costs nothing per light and casts and
// takes no shadows -- with a fixed shade per face instead, so a box still reads
// as a box and not as a flat cut-out.
//
// The colour is the MultiMesh instance colour, which Godot multiplies into
// COLOR: the same filament colour the drawn and real rungs use, so nothing
// changes colour when a room moves up the ladder.
render_mode unshaded, cull_back;

// A little darker than the lit rungs: a room seen from outside is lit from its
// windows, not from the sun.
uniform float dim = 0.8;

varying vec3 world_normal;

void vertex() {
	// The instance transform scales the unit cube, so the normal wants
	// normalising; an axis-aligned box keeps it exact.
	world_normal = normalize((MODEL_MATRIX * vec4(NORMAL, 0.0)).xyz);
}

void fragment() {
	// Tops brightest, the two side axes told apart, bottoms darkest.
	float shade = 0.55 + 0.35 * max(world_normal.y, 0.0) + 0.1 * abs(world_normal.x);
	ALBEDO = COLOR.rgb * shade * dim;
}
