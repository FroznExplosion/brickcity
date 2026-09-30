shader_type spatial;
// The far city: every recipe building the shell ladder does not draw, as one
// instance of a unit box in one MultiMesh (Docs/Impostors.md, Stages 1-3).
//
// The box is the building's true shape -- a recipe tower IS a box -- and the
// facade is drawn from the recipe's own rules, the same ones TowerRecipe lays
// bricks by and BuildingShell builds shells by:
//
//   base slab (1 plate), then storeys of six 3-plate courses and a 1-plate slab;
//   course k of every storey in COURSE_COLOURS[k];
//   windows WINDOW_WIDE studs every WINDOW_PITCH from WINDOW_INSET, on courses
//   2-4 of a storey that has a slab over it.
//
// Damage is BuildingShell's segment mask: per band, per side, 32 bits, bit i
// standing over [i, i+1) * span / 32 along that side. It lives in damage_tex,
// one row per damaged building, one texel per (band, side) whose four bytes
// are the mask. A segment that is gone is cut out, and through the hole the
// inside of the box is drawn dark.
//
// Cut with ALPHA_SCISSOR_THRESHOLD, not `discard`. With a raw discard, the
// moment damage_tex was bound the whole MultiMesh stopped drawing -- every
// building, intact ones included -- on the Radeon iGPU this was built on, with
// no error printed. The scissor path draws correctly.
//
// Lit the way brick.gdshader lights PLA (material 0) once its seams and print
// lines have faded, so the swap from a shell has no colour step.
//
//   INSTANCE_CUSTOM.x = courses
//   INSTANCE_CUSTOM.y = damage row, or -1 for an intact building
//   INSTANCE_CUSTOM.z = window seed (the building id)
//   INSTANCE_CUSTOM.w = 1 while a banded shell fades out over this box
//                       (Stage 5). Godot fades a shell by alpha-BLENDING it,
//                       so the box is drawn whole under it, a few centimetres
//                       inside so the blended shell is always in front:
//                       alpha * shell + (1 - alpha) * box, a real crossfade.
render_mode cull_disabled, diffuse_burley, specular_schlick_ggx;

const float STUD = 0.35;
const float PLATE = 0.14;
const float STOREY_PLATES = 19.0;   // six courses of three, and a slab
const float WINDOW_INSET = 4.0;
const float WINDOW_WIDE = 4.0;
const float WINDOW_PITCH = 8.0;

uniform vec3 course_colours[6];
uniform vec3 base_colour = vec3(0.3);
uniform vec3 slab_colour = vec3(0.5);
// What a window reads as from outside: the painted room behind the glass.
uniform vec3 window_colour = vec3(0.42, 0.36, 0.30);
uniform vec3 interior_colour = vec3(0.12, 0.11, 0.10);
uniform sampler2D damage_tex : filter_nearest, repeat_disable;
// Under a fading shell, drawn this far inside it (metres).
uniform float fade_inset = 0.06;

varying vec3 v_local;      // metres, box corner at the origin
varying vec3 v_size;       // metres
varying vec3 v_normal;     // model space, axis aligned
varying flat vec3 v_custom;

void vertex() {
    v_size = vec3(length(MODEL_MATRIX[0].xyz), length(MODEL_MATRIX[1].xyz),
            length(MODEL_MATRIX[2].xyz));
    v_local = VERTEX * v_size;
    v_normal = NORMAL;
    v_custom = INSTANCE_CUSTOM.xyz;
    if (INSTANCE_CUSTOM.w > 0.5) {
        // Inside the fading shell, so its blend is always drawn over this.
        vec3 inset = fade_inset / max(v_size, vec3(0.01));
        VERTEX = 0.5 + (VERTEX - 0.5) * (1.0 - 2.0 * inset);
    }
}

float hash(vec3 p) {
    p = fract(p * vec3(0.1031, 0.1030, 0.0973));
    p += dot(p, p.yxz + 33.33);
    return fract((p.x + p.y) * p.z);
}

// Everything below is drawn box-filtered: a pixel shows the AVERAGE of what
// lies under it, from running integrals of the pattern, so a course or a
// window thinner than a pixel blends into its neighbours instead of
// shimmering, at every distance, with no LOD switch.

// Colour integrated over the first x plates of a storey.
vec3 storey_integral(float x) {
    vec3 s = vec3(0.0);
    for (int k = 0; k < 6; k++) {
        s += course_colours[k] * clamp(x - 3.0 * float(k), 0.0, 3.0);
    }
    return s + slab_colour * clamp(x - 18.0, 0.0, 1.0);
}

// Colour integrated from the ground up to p plates.
vec3 wall_integral(float p) {
    vec3 s = base_colour * clamp(p, 0.0, 1.0);
    float q = max(p - 1.0, 0.0);
    float n = floor(q / STOREY_PLATES);
    return s + n * storey_integral(STOREY_PLATES) + storey_integral(q - n * STOREY_PLATES);
}

// How much of [0, x) plates above the base is window height: courses 2-4 of
// every storey, [6, 15) of its 19 plates.
float window_rows_integral(float x) {
    x = max(x, 0.0);
    float n = floor(x / STOREY_PLATES);
    return n * 9.0 + clamp(x - n * STOREY_PLATES - 6.0, 0.0, 9.0);
}

// How much of [0, u) studs along a wall of `span` studs is window width.
float window_cols_integral(float u, float span) {
    float count = floor((span - 2.0 * WINDOW_INSET - WINDOW_WIDE) / WINDOW_PITCH) + 1.0;
    if (count < 1.0) {
        return 0.0;
    }
    float x = clamp(u - WINDOW_INSET, 0.0, (count - 1.0) * WINDOW_PITCH + WINDOW_WIDE);
    float n = floor(x / WINDOW_PITCH);
    return n * WINDOW_WIDE + clamp(x - n * WINDOW_PITCH, 0.0, WINDOW_WIDE);
}

// The segment mask of one side of one band. Every bit set when intact.
uint band_mask(int band, int side, int row) {
    if (row < 0) {
        return 0xFFFFFFFFu;
    }
    vec4 t = texelFetch(damage_tex, ivec2(band * 4 + side, row), 0);
    uvec4 b = uvec4(round(t * 255.0));
    return b.r | (b.g << 8u) | (b.b << 16u) | (b.a << 24u);
}

void fragment() {
    // A segment shot away (see the note at the top about alpha scissor).
    bool gone = false;
    int courses = int(v_custom.x + 0.5);
    int row = int(floor(v_custom.y + 0.5));
    float seed = v_custom.z;
    vec3 lp = v_local;

    // Which face, and where along it. Sides in BuildingShell's SIDE_* order.
    int side = -1;
    float along = 0.0;
    float span = 1.0;
    if (v_normal.z < -0.5) { side = 0; along = lp.x; span = v_size.x; }
    else if (v_normal.z > 0.5) { side = 1; along = lp.x; span = v_size.x; }
    else if (v_normal.x < -0.5) { side = 2; along = lp.z; span = v_size.z; }
    else if (v_normal.x > 0.5) { side = 3; along = lp.z; span = v_size.z; }

    vec3 col;
    if (side < 0) {
        // The roof: the top course, gone on every side, takes the roof with it.
        int storeys = courses / 6;
        int top_band = courses + storeys;   // the last course, counting the base as 0
        if (courses % 6 == 0) {
            top_band -= 1;
        }
        uint roof = band_mask(top_band, 0, row) | band_mask(top_band, 1, row)
                | band_mask(top_band, 2, row) | band_mask(top_band, 3, row);
        if (roof == 0u) {
            gone = true;
        }
        col = slab_colour;
    } else {
        // The band this height is in, as TowerRecipe.layout counts them,
        // for the damage lookup.
        float p = lp.y / PLATE;
        int band = 0;
        int storey = 0;
        if (p >= 1.0) {
            float q = p - 1.0;
            storey = int(floor(q / STOREY_PLATES));
            float within = q - float(storey) * STOREY_PLATES;
            band = 1 + storey * 7 + min(int(floor(within / 3.0)), 6);
        }

        uint mask = band_mask(band, side, row);
        int seg = clamp(int(along / span * 32.0), 0, 31);
        if (((mask >> uint(seg)) & 1u) == 0u) {
            gone = true;
        }

        // The wall, averaged over the plates this pixel covers.
        float hp = max(0.5 * fwidth(p), 1e-3);
        col = (wall_integral(p + hp) - wall_integral(p - hp)) / (2.0 * hp);

        // The windows, as the fraction of this pixel that is glass. Not in a
        // storey with no slab over it, which has none, and not in a storey
        // whose window courses are damaged ANYWHERE, on any side: that is the
        // rule BuildingShell.build_window_mesh puts glass by, so the two tiers
        // agree across the swap.
        float u = along / STUD;
        bool storey_has_slab = (storey + 1) * 6 <= courses;
        bool glazed = storey_has_slab && p >= 1.0;
        if (glazed && row >= 0) {
            for (int k = 2; k <= 4 && glazed; k++) {
                for (int sd = 0; sd < 4; sd++) {
                    if (band_mask(1 + storey * 7 + k, sd, row) != 0xFFFFFFFFu) {
                        glazed = false;
                        break;
                    }
                }
            }
        }
        if (glazed) {
            float hu = max(0.5 * fwidth(u), 1e-3);
            float s = span / STUD;
            float cov_u = (window_cols_integral(u + hu, s) - window_cols_integral(u - hu, s)) / (2.0 * hu);
            float cov_v = (window_rows_integral(p - 1.0 + hp) - window_rows_integral(p - 1.0 - hp)) / (2.0 * hp);
            float idx = floor((u - WINDOW_INSET) / WINDOW_PITCH);
            float lit = hash(vec3(seed, float(storey) * 4.0 + float(side), idx));
            col = mix(col, window_colour * mix(0.55, 1.25, lit), cov_u * cov_v);
        }
    }

    if (!FRONT_FACING) {
        // The inside of a wall, seen through a hole in another.
        col = interior_colour;
    }
    ALBEDO = col;
    ALPHA = gone ? 0.0 : 1.0;
    ALPHA_SCISSOR_THRESHOLD = 0.5;
    ROUGHNESS = 0.42;
    SPECULAR = 0.55;
    METALLIC = 0.0;
    RIM = 0.35;
    RIM_TINT = 0.4;
}
