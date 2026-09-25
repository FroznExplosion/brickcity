shader_type spatial;
render_mode blend_mix, cull_back, depth_draw_opaque, diffuse_burley, specular_schlick_ggx;

// See-through bricks: PETG. The second pass of the brick material
// (BrickMaterials.add_glass sets it as brick.gdshader's next_pass).
//
// Both passes draw the same chunk mesh. The opaque pass throws a translucent
// brick's faces away in its VERTEX shader (they collapse to a point, which
// costs nothing and keeps early depth for every other brick), and this pass
// does the opposite: it throws away everything opaque and blends what is
// left. The mesher keeps the opaque faces a see-through brick sits against
// (brick_material_hides), so what is behind the pane is there to be seen.
//
// A transparent pass casts no shadow, and neither does the collapsed opaque
// face: PETG throws none. Clear plastic throws a faint one, so that is the
// right side to be wrong on.

#include "res://shaders/brick_materials.gdshaderinc"

// How much of the brick's colour a face lets through, head on. Edges and
// grazing angles are denser, as a real clear part is.
uniform float glass_alpha : hint_range(0.0, 1.0) = 0.38;
uniform float edge_alpha : hint_range(0.0, 1.0) = 0.9;
// The outline along every block edge: where the part is seen through its
// own thickness, so it reads as a solid piece and not a tinted hole.
uniform float edge_width = 0.014;
uniform float edge_fade_begin = 30.0;
uniform float edge_fade_end = 75.0;
// PETG's layers, half melted away but still there on the sides.
uniform float layer_height = 0.020;
uniform float layer_fade_end = 14.0;

varying vec2 v_uv;
varying vec2 v_face;
varying float v_side;

void vertex() {
    v_uv = UV;
    v_face = UV2;
    v_side = abs(NORMAL.y) < 0.7 ? 1.0 : 0.0;
    if (MAT_TRANSLUCENT[brick_material_id(COLOR.a)] < 0.5) {
        VERTEX = vec3(0.0);
    }
}

void fragment() {
    vec3 col = COLOR.rgb;
    float dist = length(VERTEX);

    vec2 cell = mod(v_uv, v_face);
    vec2 to_edge = min(cell, v_face - cell);
    float d = min(to_edge.x, to_edge.y);
    float aa = max(fwidth(d), 1e-5);
    float edge = clamp((edge_width - d) / aa + 0.5, 0.0, 1.0)
            * (1.0 - smoothstep(edge_fade_begin, edge_fade_end, dist));

    float t = v_uv.y / layer_height;
    float taa = max(fwidth(t), 1e-5);
    float resolved = 1.0 - smoothstep(0.3, 0.75, taa);
    float line = (1.0 - smoothstep(0.0, max(taa, 0.12), abs(fract(t) - 0.5)))
            * resolved * v_side * (1.0 - smoothstep(4.0, layer_fade_end, dist));

    float fres = pow(1.0 - clamp(dot(NORMAL, VIEW), 0.0, 1.0), 3.0);

    ALBEDO = col * mix(1.0, 0.72, edge) * mix(1.0, 0.9, line);
    ALPHA = clamp(mix(glass_alpha, edge_alpha, max(edge, fres * 0.8)) + line * 0.08, 0.0, 1.0);
    ROUGHNESS = 0.08;
    SPECULAR = 0.75;
    // Light that came through the part: a clear brick glows a little of its
    // own colour even on its shaded side.
    EMISSION = col * 0.12;
}
