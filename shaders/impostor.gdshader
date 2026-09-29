shader_type spatial;
// An octahedral impostor card (scripts/impostor_baker.gd, Docs/Impostors.md 3.3).
//
// One instance of a unit quad per object, in a MultiMesh; the instance
// transform is the OBJECT's (position, turn, scale), and the card is built
// here: centred on the object, facing the camera, 2R across. The four baked
// views nearest the direction it is seen from are blended, each read where
// this pixel falls on that view's own plane -- which is linear across the
// card, so it is worked out per vertex.
//
// In the shadow pass the "camera" is the light, so the card turns to the sun
// and casts the silhouette the sun would see.
render_mode world_vertex_coords, cull_disabled, diffuse_burley, specular_schlick_ggx;

uniform sampler2D albedo_atlas : source_color, filter_linear_mipmap, repeat_disable;
uniform sampler2D normal_atlas : filter_linear_mipmap, repeat_disable;
uniform float grid = 8.0;
uniform float radius = 1.0;
uniform vec3 centre = vec3(0.0);

varying vec2 v_uv0;
varying vec2 v_uv1;
varying vec2 v_uv2;
varying vec2 v_uv3;
varying vec4 v_w;
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

// Where object-space point p lands in view (i, j) of the atlas.
vec2 tile_uv(vec2 f, vec3 p) {
    vec3 d = decode(f / (grid - 1.0));
    vec3 right = abs(d.y) > 0.999 ? vec3(1.0, 0.0, 0.0) : normalize(cross(vec3(0.0, 1.0, 0.0), d));
    vec3 up = cross(d, right);
    vec2 t = vec2(0.5 + dot(p, right) / (2.0 * radius), 0.5 - dot(p, up) / (2.0 * radius));
    t = clamp(t, vec2(0.002), vec2(0.998));
    return (f + t) / grid;
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
    v_w = vec4((1.0 - w.x) * (1.0 - w.y), w.x * (1.0 - w.y), (1.0 - w.x) * w.y, w.x * w.y);
    vec3 p = transpose(rot) * ((corner.x * right + corner.y * up) * radius * s) / s;
    v_uv0 = tile_uv(f0, p);
    v_uv1 = tile_uv(f0 + vec2(1.0, 0.0), p);
    v_uv2 = tile_uv(f0 + vec2(0.0, 1.0), p);
    v_uv3 = tile_uv(f0 + vec2(1.0, 1.0), p);
    v_rot = rot;
}

vec3 srgb_to_linear(vec3 c) {
    return mix(c / 12.92, pow((c + 0.055) / 1.055, vec3(2.4)), step(vec3(0.04045), c));
}

void fragment() {
    vec4 a = texture(albedo_atlas, v_uv0) * v_w.x + texture(albedo_atlas, v_uv1) * v_w.y
            + texture(albedo_atlas, v_uv2) * v_w.z + texture(albedo_atlas, v_uv3) * v_w.w;
    vec4 n = texture(normal_atlas, v_uv0) * v_w.x + texture(normal_atlas, v_uv1) * v_w.y
            + texture(normal_atlas, v_uv2) * v_w.z + texture(normal_atlas, v_uv3) * v_w.w;
    float cover = a.a;
    // Premultiplied by coverage in the bake: divide it back out.
    vec3 albedo = a.rgb / max(cover, 1e-3);
    vec3 nobj = srgb_to_linear(n.rgb / max(n.a, 1e-3)) * 2.0 - 1.0;
    vec3 nworld = normalize(v_rot * nobj);
    NORMAL = normalize((VIEW_MATRIX * vec4(nworld, 0.0)).xyz);
    ALBEDO = albedo;
    ALPHA = cover;
    ALPHA_SCISSOR_THRESHOLD = 0.5;
    ROUGHNESS = 0.42;
    SPECULAR = 0.55;
}
