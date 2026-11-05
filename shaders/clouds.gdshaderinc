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
//   cloud_here        what of the sun reaches the camera (1 clear): the sun
//                     itself is dimmed by it (CloudLayer), so a surface's
//                     share is its own over this -- what moves (figures, the
//                     gun) takes the camera's, and nothing is darkened twice
global uniform mat4 cloud_from_world;
global uniform vec4 cloud_sun;
global uniform vec4 cloud_shape;
global uniform vec3 cloud_drift;
global uniform float cloud_here;

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

// How thick the cloud is (0 clear .. 1) at `q`, a point of the layer in its
// frame, for a layer drifted by `drift`, of `cover`, its clouds `size`
// metres. Four octaves and a swell; the cover moves the threshold.
float cloud_density_of(vec3 q, vec3 drift, float cover, float size) {
    vec3 p = (q + drift) / max(size, 1.0);
    float n = 0.5 * cloud_noise3(p) + 0.25 * cloud_noise3(p * 2.03 + 11.7)
            + 0.125 * cloud_noise3(p * 4.01 + 3.1) + 0.0625 * cloud_noise3(p * 8.07 + 7.9);
    n /= 0.9375;
    // Weather systems: a slow swell six clouds across, so cloud gathers in
    // fronts with clear sky between, not evenly everywhere.
    n = n * 0.7 + cloud_noise3(p * 0.16 + 5.3) * 0.3;
    float edge = 1.0 - cover;
    return smoothstep(edge - 0.06, edge + 0.16, n);
}

// The live layer's (the globals').
float cloud_density(vec3 q) {
    return cloud_density_of(q, cloud_drift, cloud_shape.z, cloud_shape.w);
}

// Where a ray from `p` along unit `s` leaves the sphere of radius `r` about
// the origin, `p` inside it.
vec3 cloud_sphere_exit(vec3 p, vec3 s, float r) {
    float b = dot(p, s);
    float c = dot(p, p) - r * r;
    return p + s * max(-b + sqrt(max(b * b - c, 0.0)), 0.0);
}

// Where the sun's ray from `world` meets the layer, in the clouds' frame.
vec3 cloud_hit(vec3 world) {
    vec3 p = (cloud_from_world * vec4(world, 1.0)).xyz;
    vec3 s = normalize((cloud_from_world * vec4(cloud_sun.xyz, 0.0)).xyz);
    if (cloud_shape.x <= 0.0) {
        float t = (cloud_shape.y - p.y) / max(s.y, 0.05);
        return p + s * max(t, 0.0);
    }
    return cloud_sphere_exit(p, s, cloud_shape.x);
}

// What of the sun reaches `world` through the clouds, against what reaches
// the camera (the sun is dimmed by that already): multiply the albedo of a
// sunlit surface by it. 1 under a clear sky; over 1 in the sun when the
// camera is in a cloud's shadow, a little (the ambient is lifted with it).
float cloud_shade(vec3 world) {
    if (cloud_sun.w <= 0.0) {
        return 1.0;
    }
    float here = clamp(cloud_here, 0.3, 1.0);
    return min((1.0 - cloud_sun.w * cloud_density(cloud_hit(world))) / here, 1.5);
}
