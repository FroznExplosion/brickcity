shader_type spatial;
#include "res://shaders/weather.gdshaderinc"
// An octahedral impostor card (scripts/impostor_baker.gd, Docs/Impostors.md 3.3).
//
// One instance of a unit quad per object, in a MultiMesh; the instance
// transform is the OBJECT's (position, turn, scale), and the card is built
// here: centred on the object, facing the camera, 2R across. The four baked
// views nearest the direction it is seen from are blended.
//
// Each view is read where the VIEW RAY meets that view's own plane, per pixel.
// Reading it where the pixel lies on the card's plane instead (linear, per
// vertex, which is what this did first) put every view's features in a
// slightly different place, and as the camera moved they slid: the card swam.
//
// Near the mesh-to-card range (`lod_near`, over +-`lod_band`) the card fades
// in with a screen-space dither while the instanced mesh fades out on exactly
// the other pixels (ImpostorLod's fading brick material uses the same noise
// and the same distance), so the switch is a blend, not a pop.
//
// In the shadow pass the "camera" is the light, so the card turns to the sun
// and casts the silhouette the sun would see.
render_mode world_vertex_coords, cull_disabled, diffuse_burley, specular_schlick_ggx;

uniform sampler2D albedo_atlas : source_color, filter_linear_mipmap, repeat_disable;
uniform sampler2D normal_atlas : filter_linear_mipmap, repeat_disable;
uniform float grid = 8.0;
uniform float radius = 1.0;
uniform vec3 centre = vec3(0.0);
// Negative: no mesh tier to fade against.
uniform float lod_near = -1.0;
uniform float lod_band = 5.0;

varying flat vec2 v_f0;
varying flat vec4 v_w;
varying flat vec3 v_c;         // the object's centre, world
varying flat float v_s;        // its scale
varying flat float v_fade;     // how far through the band, 0 mesh .. 1 card
varying mat3 v_rot;

vec2 encode(vec3 d) {
    d.y = max(d.y, 0.0);
    d /= (abs(d.x) + abs(d.y) + abs(d.z));
    return vec2(d.x + d.z, d.x - d.z) * 0.5 + 0.5;
}

vec3 decode(vec2 uv) {
    vec2 p = uv * 2.0 - 1.0;
    float x = (p.x + p.y) * 0.5;
    float z = (p.x - p.y) * 0.5;
    return normalize(vec3(x, 1.0 - abs(x) - abs(z), z));
}

// Where the ray from `cam` along `dir` (world) meets view f's plane -- through
// the object's centre, facing that view's direction -- in the atlas.
vec2 tile_uv(vec2 f, vec3 cam, vec3 dir) {
    vec3 d = decode(f / (grid - 1.0));
    vec3 right = abs(d.y) > 0.999 ? vec3(1.0, 0.0, 0.0) : normalize(cross(vec3(0.0, 1.0, 0.0), d));
    vec3 up = cross(d, right);
    vec3 dw = v_rot * d;
    float den = dot(dir, dw);
    float t = abs(den) > 1e-4 ? dot(v_c - cam, dw) / den : 0.0;
    vec3 p = transpose(v_rot) * (cam + dir * t - v_c) / v_s;
    vec2 uv = vec2(0.5 + dot(p, right) / (2.0 * radius), 0.5 - dot(p, up) / (2.0 * radius));
    uv = clamp(uv, vec2(0.002), vec2(0.998));
    return (f + uv) / grid;
}

// Interleaved gradient noise, the same function the fading mesh uses.
float ign(vec2 px) {
    return fract(52.9829189 * fract(dot(px, vec2(0.06711056, 0.00583715))));
}

void vertex() {
    vec3 sx = MODEL_MATRIX[0].xyz;
    vec3 sy = MODEL_MATRIX[1].xyz;
    vec3 sz = MODEL_MATRIX[2].xyz;
    float s = length(sx);
    mat3 rot = mat3(sx / s, sy / length(sy), sz / length(sz));
    vec3 c = (MODEL_MATRIX * vec4(centre, 1.0)).xyz;
    vec3 to_cam = normalize(CAMERA_POSITION_WORLD - c);
    // The card, from the quad's UV rather than its vertex: in world space
    // before this runs, and a card is not where the quad was.
    vec2 corner = vec2(UV.x * 2.0 - 1.0, 1.0 - UV.y * 2.0);
    vec3 right = abs(to_cam.y) > 0.999 ? INV_VIEW_MATRIX[0].xyz : normalize(cross(vec3(0.0, 1.0, 0.0), to_cam));
    vec3 up = cross(to_cam, right);
    vec3 world = c + (corner.x * right + corner.y * up) * radius * s;
    // The shadow pass (orthographic: the sun's) turns the card to the light,
    // and that card would shadow the camera-facing one across itself. Pushed
    // back along the light by the radius it stays behind the object, and a
    // shift along the light moves nothing on the ground.
    if (PROJECTION_MATRIX[3][3] > 0.5) {
        world -= to_cam * radius * s;
    }
    VERTEX = world;
    NORMAL = to_cam;
    TANGENT = right;
    BINORMAL = up;

    // The views to blend: the grid cell the view direction falls in.
    vec3 d_obj = transpose(rot) * to_cam;
    vec2 g = encode(d_obj) * (grid - 1.0);
    vec2 f0 = clamp(floor(g), vec2(0.0), vec2(grid - 2.0));
    vec2 w = clamp(g - f0, 0.0, 1.0);
    v_f0 = f0;
    v_w = vec4((1.0 - w.x) * (1.0 - w.y), w.x * (1.0 - w.y), (1.0 - w.x) * w.y, w.x * w.y);
    v_c = c;
    v_s = s;
    v_rot = rot;
    // The band, measured to the instance's origin -- as the mesh measures it.
    v_fade = 1.0;
    if (lod_near > 0.0) {
        float d = distance(MODEL_MATRIX[3].xyz, CAMERA_POSITION_WORLD);
        v_fade = clamp((d - (lod_near - lod_band)) / (2.0 * lod_band), 0.0, 1.0);
    }
}

vec3 srgb_to_linear(vec3 c) {
    return mix(c / 12.92, pow((c + 0.055) / 1.055, vec3(2.4)), step(vec3(0.04045), c));
}

void fragment() {
    vec3 cam = (INV_VIEW_MATRIX * vec4(0.0, 0.0, 0.0, 1.0)).xyz;
    vec3 here = (INV_VIEW_MATRIX * vec4(VERTEX, 1.0)).xyz;
    // A perspective camera looks from a point; the sun's shadow camera along
    // a direction.
    vec3 dir = PROJECTION_MATRIX[3][3] > 0.5 ? -INV_VIEW_MATRIX[2].xyz : normalize(here - cam);
    if (PROJECTION_MATRIX[3][3] > 0.5) {
        cam = here - dir * radius * v_s * 4.0;
    }
    vec2 uv0 = tile_uv(v_f0, cam, dir);
    vec2 uv1 = tile_uv(v_f0 + vec2(1.0, 0.0), cam, dir);
    vec2 uv2 = tile_uv(v_f0 + vec2(0.0, 1.0), cam, dir);
    vec2 uv3 = tile_uv(v_f0 + vec2(1.0, 1.0), cam, dir);
    vec4 a = texture(albedo_atlas, uv0) * v_w.x + texture(albedo_atlas, uv1) * v_w.y
            + texture(albedo_atlas, uv2) * v_w.z + texture(albedo_atlas, uv3) * v_w.w;
    vec4 n = texture(normal_atlas, uv0) * v_w.x + texture(normal_atlas, uv1) * v_w.y
            + texture(normal_atlas, uv2) * v_w.z + texture(normal_atlas, uv3) * v_w.w;
    float cover = a.a;
    // In the band, only on the pixels the fading mesh has left. Not in the
    // shadow pass: there both cast in full, and their shadows are one shape.
    if (v_fade < 1.0 && PROJECTION_MATRIX[3][3] < 0.5 && ign(FRAGCOORD.xy) >= v_fade) {
        cover = 0.0;
    }
    // Premultiplied by coverage in the bake: divide it back out.
    vec3 albedo = a.rgb / max(a.a, 1e-3);
    vec3 nobj = srgb_to_linear(n.rgb / max(n.a, 1e-3)) * 2.0 - 1.0;
    vec3 nworld = normalize(v_rot * nobj);
    NORMAL = normalize((VIEW_MATRIX * vec4(nworld, 0.0)).xyz);
    float out_rough = 0.42;
    float out_spec = 0.55;
    weather_wet_surface(albedo, out_rough, out_spec, NORMAL, INV_VIEW_MATRIX, 0.14);
    ALBEDO = albedo;
    ALPHA = cover;
    ALPHA_SCISSOR_THRESHOLD = 0.5;
    ROUGHNESS = out_rough;
    SPECULAR = out_spec;
}
