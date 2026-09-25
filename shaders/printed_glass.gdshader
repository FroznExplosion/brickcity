shader_type spatial;
render_mode blend_mix, cull_back, depth_draw_opaque, diffuse_burley, specular_schlick_ggx;

// The studs of see-through bricks: printed.gdshader's second pass, the way
// brick_glass.gdshader is the brick shader's (see there for why two passes).
// The instance colour carries the material in its alpha, as on the bricks.

#include "res://shaders/brick_materials.gdshaderinc"

uniform float glass_alpha : hint_range(0.0, 1.0) = 0.42;
uniform float edge_alpha : hint_range(0.0, 1.0) = 0.9;
uniform vec4 tint : source_color = vec4(1.0, 1.0, 1.0, 1.0);

void vertex() {
    if (MAT_TRANSLUCENT[brick_material_id(COLOR.a)] < 0.5) {
        VERTEX = vec3(0.0);
    }
}

void fragment() {
    vec3 col = COLOR.rgb * tint.rgb;
    float fres = pow(1.0 - clamp(dot(NORMAL, VIEW), 0.0, 1.0), 2.0);
    ALBEDO = col * mix(1.0, 0.75, fres);
    ALPHA = clamp(mix(glass_alpha, edge_alpha, fres), 0.0, 1.0);
    ROUGHNESS = 0.08;
    SPECULAR = 0.75;
    EMISSION = col * 0.12;
}
