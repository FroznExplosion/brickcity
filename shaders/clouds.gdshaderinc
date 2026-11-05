// Clouds (Docs/Lighting.md 2b): one cover function, shared by the cloud
// layer (clouds.gdshader) and every surface that takes the sun, which it
// darkens where a cloud stands between it and the sun -- faked, not shadow-
// mapped (Godot's sun has no light cookie). CloudLayer sets the globals each
// frame; with cloud_sun.w 0 (no clouds, or night) nothing is darkened and
// nothing is worked out past one branch.
//
//   cloud_from_world  world -> the clouds' frame: a planet's own (they turn
//                     with it, its centre the origin), or the city's world
//   cloud_sun         xyz the way to the sun (world), w how much a full
//                     cloud takes from what it shades (0 none)
//   cloud_shape       x the layer's radius about the frame's origin (a
//                     planet); 0: flat, a plane at height y. z cover (0..1),
//                     w the size of a cloud in metres
//   cloud_drift       the wind's offset so far, frame metres
global uniform mat4 cloud_from_world;
global uniform vec4 cloud_sun;
global uniform vec4 cloud_shape;
global uniform vec3 cloud_drift;

float cloud_hash3(vec3 p) {
    p = fract(p * 0.3183099 + 0.1);
    p *= 17.0;
    return fract(p.x * p.y * p.z * (p.x + p.y + p.z));
}

float cloud_noise3(vec3 p) {
    vec3 i = floor(p);
    vec3 f = fract(p);
    f = f * f * (3.0 - 2.0 * f);
    return mix(mix(mix(cloud_hash3(i), cloud_hash3(i + vec3(1, 0, 0)), f.x),
                   mix(cloud_hash3(i + vec3(0, 1, 0)), cloud_hash3(i + vec3(1, 1, 0)), f.x), f.y),
               mix(mix(cloud_hash3(i + vec3(0, 0, 1)), cloud_hash3(i + vec3(1, 0, 1)), f.x),
                   mix(cloud_hash3(i + vec3(0, 1, 1)), cloud_hash3(i + vec3(1, 1, 1)), f.x), f.y), f.z);
}

// How thick the cloud is (0 clear .. 1) at `q`, a point of the layer in the
// clouds' frame. Four octaves; the cover moves the threshold.
float cloud_density(vec3 q) {
    vec3 p = (q + cloud_drift) / max(cloud_shape.w, 1.0);
    float n = 0.5 * cloud_noise3(p) + 0.25 * cloud_noise3(p * 2.03 + 11.7)
            + 0.125 * cloud_noise3(p * 4.01 + 3.1) + 0.0625 * cloud_noise3(p * 8.07 + 7.9);
    n /= 0.9375;
    float edge = 1.0 - cloud_shape.z;
    return smoothstep(edge - 0.06, edge + 0.16, n);
}

// Where the sun's ray from `world` meets the layer, in the clouds' frame.
vec3 cloud_hit(vec3 world) {
    vec3 p = (cloud_from_world * vec4(world, 1.0)).xyz;
    vec3 s = normalize((cloud_from_world * vec4(cloud_sun.xyz, 0.0)).xyz);
    if (cloud_shape.x <= 0.0) {
        float t = (cloud_shape.y - p.y) / max(s.y, 0.05);
        return p + s * max(t, 0.0);
    }
    // Out of the sphere of radius cloud_shape.x from inside it.
    float b = dot(p, s);
    float c = dot(p, p) - cloud_shape.x * cloud_shape.x;
    float t = -b + sqrt(max(b * b - c, 0.0));
    return p + s * max(t, 0.0);
}

// What of the sun reaches `world` through the clouds: multiply the albedo of
// a sunlit surface by it (1 under a clear sky).
float cloud_shade(vec3 world) {
    if (cloud_sun.w <= 0.0) {
        return 1.0;
    }
    return 1.0 - cloud_sun.w * cloud_density(cloud_hit(world));
}
