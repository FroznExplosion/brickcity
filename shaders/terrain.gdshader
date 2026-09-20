shader_type spatial;
render_mode cull_back, diffuse_burley, specular_schlick_ggx;

// Brick ground. brick.gdshader's seam, plus the two things terrain adds:
// painted studs and their faked contact shadow.
//
// The contract from the mesher is the same one brick.gdshader already defines:
//
//   UV   = position within the PIECE's face rectangle, in metres
//   UV2  = that rectangle's size, in metres
//
// so a 2x4 plate carries UV2 = (0.70, 1.40) and gets ONE outline around the
// whole 2x4 — not a grid of eight 1x1s. That is the difference between a floor
// that reads as laid brick and one that reads as a moulded baseplate, and it
// is why the mesher packs (Docs/Terrain.md section 6.2) instead of greedy-
// merging.
//
//   COLOR.rgb = the piece's filament colour, jittered per piece
//   COLOR.a   = 1 where the piece takes studs, 0 where it does not
//
// A piece never spans the plate/non-plate boundary, because the packer forces
// a cut there, so one flag per piece is exact.

group_uniforms seams;
uniform bool seams_enabled = true;
uniform float seam_width : hint_range(0.0, 0.05) = 0.010;
uniform float seam_darken : hint_range(0.0, 1.0) = 0.55;
uniform float seam_fade_begin = 30.0;
uniform float seam_fade_end = 90.0;

group_uniforms studs;
// Docs/Terrain.md section 7.2 tier 1: the cheapest stud there is. A dome
// normal inside each stud cell, in a fragment shader the ground is already
// paying for. No geometry, no memory, ~15 ALU.
uniform bool studs_enabled = true;
uniform float stud_pitch = 0.35;     // one stud
uniform float stud_radius = 0.105;   // 4.8 mm contact diameter at 1:43.75
uniform float stud_height = 0.074;
uniform float stud_dome : hint_range(0.0, 1.0) = 0.75;
// The painted dome fades IN across the same band the geometry tier fades
// OUT over (TerrainTile.STUD_RANGE = 18 m, margin 6 m), so the two tiers hand
// over instead of both drawing. Before this the geometry simply occluded the
// paint underneath it -- right to look at, but paid for twice.
uniform float stud_near_begin = 18.0;
uniform float stud_near_end = 24.0;
uniform float stud_fade_begin = 45.0;
uniform float stud_fade_end = 70.0;

group_uniforms stud_shadow;
// Section 7.4. Studs never cast: 8.3k instances through two cascades is ~365k
// depth-only triangles a frame, to draw a shadow 0.07 m long. The SURFACE
// draws it instead, analytically, from the same cell maths the dome uses --
// which also means it is still there under tier 1, where no stud geometry
// exists at all.
uniform bool stud_shadows_enabled = true;
uniform vec3 sun_dir = vec3(0.55, 0.72, 0.42);  // surface -> light, world space
uniform float contact_darken : hint_range(0.0, 1.0) = 0.72;

group_uniforms surface;
uniform float surface_roughness : hint_range(0.0, 1.0) = 0.9;

varying vec2 v_uv;
varying vec2 v_face;
varying vec3 v_world;
varying float v_studded;
varying vec3 v_flat_normal;

void vertex() {
    v_uv = UV;
    v_face = UV2;
    v_world = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
    v_studded = COLOR.a;
    v_flat_normal = normalize(NORMAL);
}

// Distance from p to the segment a..b. The stud's shadow is its disc swept
// along the light's horizontal offset, which is a stadium, and a stadium is
// one segment distance and one radius compare.
float seg_dist(vec2 p, vec2 a, vec2 b) {
    vec2 ab = b - a;
    float len2 = max(dot(ab, ab), 1e-8);
    float t = clamp(dot(p - a, ab) / len2, 0.0, 1.0);
    return length(p - (a + ab * t));
}

void fragment() {
    vec3 albedo = COLOR.rgb;
    float dist = length(VERTEX);

    if (seams_enabled) {
        // UV is wrapped by UV2 first. For a real piece UV never leaves
        // [0, UV2), so this changes nothing -- but it lets a coarse LOD hand
        // over a merged quad with a piece-sized UV2 and still get outlines.
        vec2 cell = mod(v_uv, v_face);
        vec2 to_edge = min(cell, v_face - cell);
        float d = min(to_edge.x, to_edge.y);
        float aa = max(fwidth(d), 1e-5);
        float w = max(seam_width, aa);
        float seam = 1.0 - smoothstep(w, w + aa, d);
        float fade = 1.0 - smoothstep(seam_fade_begin, seam_fade_end, dist);
        albedo *= mix(1.0, seam_darken, seam * fade);
    }

    // Studs only exist on up-facing surfaces. A skirt and a ramp are not
    // plates, and the mesher has already said so through COLOR.a -- but the
    // normal test costs nothing and catches the skirt of a studded piece.
    float up = clamp(v_flat_normal.y, 0.0, 1.0);
    float has_stud = v_studded * step(0.95, up);

    if (has_stud > 0.5) {
        // The stud cell this fragment is in, in world XZ, so studs line up
        // across piece boundaries and across tile boundaries -- they are on
        // the global lattice, like everything else (D5).
        vec2 c = (floor(v_world.xz / stud_pitch) + 0.5) * stud_pitch;
        vec2 rel = v_world.xz - c;
        float r = length(rel);

        if (stud_shadows_enabled) {
            // Where the top of the stud's shadow lands. Clamped to one cell so
            // a low sun never needs more than the two taps below; the error at
            // sunset hides inside the building shadows that dominate anyway.
            vec2 off = -sun_dir.xz / max(sun_dir.y, 0.2) * stud_height;
            float m = length(off);
            if (m > stud_pitch) {
                off *= stud_pitch / m;
            }
            // This cell, and the one the shadow could be reaching in from.
            vec2 c2 = (floor((v_world.xz - off) / stud_pitch) + 0.5) * stud_pitch;
            float t1 = seg_dist(v_world.xz, c, c + off);
            float t2 = seg_dist(v_world.xz, c2, c2 + off);
            float t = min(t1, t2);
            float aa = max(fwidth(t), 1e-5);
            float shade = 1.0 - smoothstep(stud_radius, stud_radius + aa + 0.01, t);
            albedo *= mix(1.0, contact_darken, shade);
        }

        if (studs_enabled) {
            float aa = max(fwidth(r), 1e-5);
            float disc = 1.0 - smoothstep(stud_radius - aa, stud_radius, r);
            // Fade out where the geometry tier has taken over, and again at
            // range where a stud is under a pixel and the pattern would
            // shimmer -- the same reason spec section 2 gives for layer lines.
            float fade = smoothstep(stud_near_begin, stud_near_end, dist)
                    * (1.0 - smoothstep(stud_fade_begin, stud_fade_end, dist));
            float k = disc * fade * stud_dome;
            // A dome: tilt the normal radially outward, strongest at the rim.
            float rn = clamp(r / max(stud_radius, 1e-4), 0.0, 1.0);
            vec3 dome = normalize(vec3(rel.x, stud_radius * (1.0 - rn * rn) + 0.02, rel.y));
            NORMAL = normalize(mix(NORMAL, normalize(mix(NORMAL, dome, 0.85)), k));
            // A touch of rim darkening so the disc reads even head-on, where
            // a normal perturbation alone does almost nothing.
            albedo *= mix(1.0, 0.94, k * smoothstep(0.55, 1.0, rn));
        }
    }

    ALBEDO = albedo;
    ROUGHNESS = surface_roughness;
}
