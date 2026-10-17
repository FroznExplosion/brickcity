shader_type spatial;
render_mode cull_disabled, diffuse_burley, specular_schlick_ggx;

// The FAR stud: two triangles, no print. Past BrickNear.stud_radius a stud is
// a dozen pixels or fewer; what reads at that size is that it is THERE -- a
// bump on every top, in the brick's colour -- not its shape. So it is a card
// that turns to face the camera (PieceMeshes.stud_card), sized every frame to
// the stud's own outline from where the camera is: as wide as the stud, and
// as tall as a cylinder of its height and radius looks from that angle --
// from the side its height, from straight above its diameter. Its foot is
// the stud's front edge, on the brick's top, so the brick never hides it.
//
// Shaded with a normal that turns round it across the card and faces up over
// its top, so the sun picks out one side and the top as it does a real one.
// The instance colour carries the material in its alpha, as the bricks'.

#include "res://shaders/brick_materials.gdshaderinc"

uniform float stud_radius = 0.105;   // PieceMeshes.STUD_R
uniform float stud_height = 0.074;   // PieceMeshes.STUD_H
uniform float surface_roughness : hint_range(0.0, 1.0) = 0.42;
uniform float surface_specular : hint_range(0.0, 1.0) = 0.55;

varying vec3 v_colour;
varying flat int v_mat;
varying float v_x;
varying float v_y;          // metres up the card
varying float v_side;       // ...where the side's outline gives way to the top
varying vec3 v_right;       // view space
varying vec3 v_front;
varying vec3 v_up;

void vertex() {
    v_colour = COLOR.rgb;
    v_mat = brick_material_id(COLOR.a);
    vec3 c = MODEL_MATRIX[3].xyz;
    vec3 up = normalize(MODEL_MATRIX[1].xyz);
    vec3 to_cam = CAMERA_POSITION_WORLD - c;
    vec3 v = to_cam / max(length(to_cam), 1e-4);
    float e = dot(up, v);
    vec3 front = v - up * e;
    float fl = length(front);
    front = fl > 1e-3 ? front / fl : normalize(MODEL_MATRIX[2].xyz);
    vec3 right = cross(up, front);
    // Up the screen, in the plane facing the camera.
    vec3 us = up - v * e;
    float ul = length(us);
    us = ul > 1e-3 ? us / ul : -front;
    float ae = abs(e);
    float side_h = stud_height * sqrt(max(1.0 - e * e, 0.0));
    float h = side_h + 2.0 * stud_radius * ae;
    vec3 world = c + front * stud_radius + right * (UV.x * stud_radius) + us * (UV.y * h);
    // A see-through stud is not drawn this far out.
    if (MAT_TRANSLUCENT[v_mat] > 0.5) {
        world = c;
    }
    // Back into the instance's own space: its basis is a rotation.
    VERTEX = transpose(mat3(MODEL_MATRIX)) * (world - c);
    NORMAL = transpose(mat3(MODEL_MATRIX)) * front;
    v_x = UV.x;
    v_y = UV.y * h;
    v_side = side_h;
    v_right = normalize(mat3(VIEW_MATRIX) * right);
    v_front = normalize(mat3(VIEW_MATRIX) * front);
    v_up = normalize(mat3(VIEW_MATRIX) * up);
}

void fragment() {
    float x = clamp(v_x, -1.0, 1.0);
    vec3 side_n = normalize(v_right * x + v_front * sqrt(max(1.0 - x * x, 0.0)));
    float top = smoothstep(v_side - 0.004, v_side + 0.004, v_y);
    NORMAL = normalize(mix(side_n, v_up, top));
    ALBEDO = v_colour;
    ROUGHNESS = clamp(MAT_ROUGH[v_mat] + (surface_roughness - MAT_ROUGH[0]), 0.0, 1.0);
    SPECULAR = clamp(MAT_SPEC[v_mat] + (surface_specular - MAT_SPEC[0]), 0.0, 1.0);
    METALLIC = MAT_METAL[v_mat];
}
