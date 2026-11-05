shader_type spatial;
// The cloud layer (Docs/Lighting.md 2b; CloudLayer): a planet's shell, or the
// city's plane, drawn with the cover its shadows come from
// (clouds.gdshaderinc). Lit by hand -- unshaded, from the sun's colour and
// the sky's -- so a cloud is white by day, grey underneath, rosy at sunset,
// and dark at night.
render_mode unshaded, blend_mix, cull_disabled, depth_draw_never, shadows_disabled, fog_disabled;

#include "res://shaders/clouds.gdshaderinc"

uniform vec3 sun_colour : source_color = vec3(1.0);
uniform vec3 sky_colour : source_color = vec3(0.55, 0.62, 0.72);
// The layer's up at a point: the planet's out, or +Y.
uniform bool shell = true;
// Flat: fade out to this far from the camera (the plane ends).
uniform float fade_far = 9000.0;
// The shell's share (0..1): it gives way to the planet's far look's clouds
// as the camera climbs past it (CloudLayer).
uniform float shell_fade = 1.0;
// Rain and snow cloud: greyer underneath (WeatherFx).
uniform float storm = 0.0;

varying vec3 v_world;

void vertex() {
    v_world = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
}

void fragment() {
    vec3 q = (cloud_from_world * vec4(v_world, 1.0)).xyz;
    float d = cloud_density(q);
    vec3 up = shell ? normalize(q) : vec3(0.0, 1.0, 0.0);
    vec3 s = normalize((cloud_from_world * vec4(cloud_sun.xyz, 0.0)).xyz);
    // Seen from under it: thicker is darker. From over it: lit.
    vec3 cam = (cloud_from_world * vec4(CAMERA_POSITION_WORLD, 1.0)).xyz;
    float below = shell ? step(length(cam), length(q)) : step(cam.y, q.y);
    float sun_up = clamp(dot(up, s) * 3.0 + 0.3, 0.0, 1.0);
    float lit = mix(1.0, mix(0.95, 0.55, d), below) * mix(1.0, 0.5, storm * below);
    vec3 col = sun_colour * lit * sun_up + sky_colour * 0.45;
    // Thin at a grazing look along the layer (the horizon): a haze, not a wall.
    float dist = length(CAMERA_POSITION_WORLD - v_world);
    float fade = shell ? shell_fade : 1.0 - smoothstep(fade_far * 0.6, fade_far, dist);
    ALBEDO = col;
    ALPHA = clamp(d * 0.92 * fade, 0.0, 1.0);
}
