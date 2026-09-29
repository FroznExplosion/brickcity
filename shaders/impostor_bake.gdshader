shader_type spatial;
// ImpostorBaker's two passes over the grid of turned copies (scripts/impostor_baker.gd):
//   mode 0  the colour, unlit, from the vertex colour a brick mesh carries;
//   mode 1  the normal in the OBJECT's own space, as 0..1.
// NORMAL in vertex() is before the model matrix, so a copy turned to face
// the camera still writes the normal of the object it is a copy of.
render_mode unshaded, cull_back;

uniform int mode = 0;

varying vec3 v_normal;

void vertex() {
    v_normal = NORMAL;
}

void fragment() {
    ALBEDO = mode == 0 ? COLOR.rgb : normalize(v_normal) * 0.5 + 0.5;
}
