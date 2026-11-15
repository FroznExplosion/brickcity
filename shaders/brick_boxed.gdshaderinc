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

// Up close the box is a BEVELLED one (BrickNear.bevel_box_mesh): the same
// instances, another mesh. Each of its corners says in UV.x which axes the
// bevel draws it in along (bits: x 1, y 2, z 4) and in UV.y whether it is a
// corner of a bevel's facet. The bevel is 13 mm whatever the brick's size, so
// it is taken off here, in metres, not in the mesh. The plain box has no UV:
// nothing drawn in, no facets.
const float BRICK_BOX_BEVEL = 0.013;

vec3 brick_box_inset(float bb_mask, vec3 bb_size) {
    int bb_m = int(bb_mask + 0.5);
    vec3 bb_on = vec3(float(bb_m & 1), float((bb_m >> 1) & 1), float((bb_m >> 2) & 1));
    return bb_on * min(vec3(BRICK_BOX_BEVEL), bb_size * 0.25);
}

// xy: UV, zw: UV2. `bb_at`: the point, in metres from the brick's middle.
vec4 brick_box_uv(vec3 bb_size, vec3 bb_at, vec3 bb_normal) {
    vec3 bb_p = bb_at + 0.5 * bb_size;
    if (abs(bb_normal.x) > 0.5) {
        return vec4(bb_p.zy, bb_size.zy);
    }
    if (abs(bb_normal.y) > 0.5) {
        return vec4(bb_p.xz, bb_size.xz);
    }
    return vec4(bb_p.xy, bb_size.xy);
}
