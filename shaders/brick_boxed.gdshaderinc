// A band drawn as a box a brick (CityDrawing.instanced_bands; the 2026-11-11
// audit's experiment): ONE unit box, instanced, each instance scaled to its
// brick. The box's mesh carries UV2 = (0, -1), which no baked face has (and a
// mesh with no UV2 at all reads (0, 0)). From the
// instance's scale this works out what a baked face hands the fragment stage:
// UV, the point's place in its face rectangle, and UV2, that rectangle's size,
// both in metres -- and the point in the chunk's own space (the instance's
// custom data is the brick's centre there), which the print lines, the grain
// and the grid's light are read at.

bool brick_boxed(vec2 bb_uv2) {
    return bb_uv2.x == 0.0 && bb_uv2.y == -1.0;
}

// The brick's size, from the model matrix (which has the instance's in it).
vec3 brick_box_size(mat4 bb_model) {
    return vec3(length(bb_model[0].xyz), length(bb_model[1].xyz), length(bb_model[2].xyz));
}

// xy: UV, zw: UV2.
vec4 brick_box_uv(vec3 bb_size, vec3 bb_unit, vec3 bb_normal) {
    vec3 bb_p = (bb_unit + 0.5) * bb_size;
    if (abs(bb_normal.x) > 0.5) {
        return vec4(bb_p.zy, bb_size.zy);
    }
    if (abs(bb_normal.y) > 0.5) {
        return vec4(bb_p.xz, bb_size.xz);
    }
    return vec4(bb_p.xy, bb_size.xy);
}
