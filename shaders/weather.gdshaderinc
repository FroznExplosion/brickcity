// Weather on surfaces (Docs/Disasters.md 19): wet in rain, and swaying in wind.
//
// Every uniform defaults to "no weather", so a shader that includes this and a
// material nobody sets draw exactly as they did. scripts/weather_fx.gd pushes
// the values into every registered material.
//
//   weather_wet    0 dry .. 1 soaked. Darker a little, far glossier, most on
//                  what faces the sky (rain lands on tops; walls stream).
//   weather_wind   the wind's direction times its strength, 0 .. ~1 (a gale).
//   weather_sway   PER INSTANCE (GeometryInstance3D.set_instance_shader_parameter):
//                  (height m, lean at the top per metre of height at wind 1,
//                  sway frequency Hz). 0 height: never sways -- a piece of
//                  debris, a chair. Set on trees and on standing buildings.
//
// Sway bends the object about its base: the lean grows with the square of the
// height, so a tree's crown moves and its trunk barely does, and a tower's top
// moves a few centimetres while its ground floor stays put. Visual only --
// collision does not sway.

uniform float weather_wet : hint_range(0.0, 1.0) = 0.0;
uniform vec3 weather_wind = vec3(0.0);
instance uniform vec3 weather_sway = vec3(0.0);

// `local` in model space with +Y up from the base. Returns it bent.
vec3 weather_sway_vertex(vec3 local, mat4 model, float t) {
    float s2 = dot(weather_wind, weather_wind);
    if (weather_sway.x <= 0.0 || s2 < 1e-6) {
        return local;
    }
    float s = sqrt(s2);
    float h = clamp(local.y / weather_sway.x, 0.0, 1.5);
    // Each object on its own phase, from where it stands.
    float phase = dot(model[3].xz, vec2(0.173, 0.291));
    float w = 6.28318530718 * weather_sway.z;
    // A steady lean downwind, a sway about it, and a faster flutter on top.
    float osc = 0.7 + 0.3 * sin(t * w + phase) + 0.1 * sin(t * w * 2.7 + phase * 1.7);
    float lean = weather_sway.y * weather_sway.x * s * osc * h * h;
    // The world wind into model space (rotation and scale both undone).
    mat3 m = mat3(model);
    vec3 dir = weather_wind / s;
    vec3 d_local = vec3(dot(m[0], dir) / max(dot(m[0], m[0]), 1e-6),
            0.0, dot(m[2], dir) / max(dot(m[2], m[2]), 1e-6));
    return local + d_local * lean;
}

// Wet surface: `darken` is how much this surface darkens soaked (porous 0.3,
// plastic 0.12, metal 0). `normal_view` is NORMAL in view space.
void weather_wet_surface(inout vec3 albedo, inout float roughness, inout float specular,
        vec3 normal_view, mat4 inv_view, float darken) {
    if (weather_wet <= 0.0) {
        return;
    }
    float up = dot((inv_view * vec4(normal_view, 0.0)).xyz, vec3(0.0, 1.0, 0.0));
    float w = weather_wet * (0.55 + 0.45 * clamp(up, 0.0, 1.0));
    albedo *= 1.0 - darken * w;
    roughness = mix(roughness, 0.07, w * 0.85);
    specular = mix(specular, 0.75, w);
}
