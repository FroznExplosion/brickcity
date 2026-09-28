shader_type spatial;
// The far city: every intact recipe building past SHELL_RANGE, as one instance
// of a unit box in one MultiMesh (Docs/Impostors.md, Stage 1).
//
// Lit the way brick.gdshader lights PLA (material 0) once its seams, chamfers
// and print lines have faded -- which they have, long before 260 m -- so the
// swap from a coarse shell to this box has no colour step.
//
//   instance COLOR = the wall colour
//   roof_colour    = the slab colour of every recipe roof (TowerRecipe.SLAB_COLOUR)
render_mode cull_back, diffuse_burley, specular_schlick_ggx;

uniform vec3 roof_colour = vec3(0.5);

varying float v_roof;

void vertex() {
    // Model space, before the instance transform: the box's top face.
    v_roof = step(0.5, NORMAL.y);
}

void fragment() {
    ALBEDO = mix(COLOR.rgb, roof_colour, v_roof);
    ROUGHNESS = 0.42;
    SPECULAR = 0.55;
    METALLIC = 0.0;
    RIM = 0.35;
    RIM_TINT = 0.4;
}
