// THE OPEN UNDERSIDE OF A PRINTED BRICK, shared: print_surface (the parts'
// shaders, brick.gdshader) and terrain.gdshader (a cave roof or overhang is the
// bottoms of the bricks over it, Docs/MineWorld.md 20) both include it. The
// uniforms and the distance to the rim and ribs; ps_underside (print_surface)
// and the terrain's own copy of it turn that into how solid.

group_uniforms underside;
// The underside of a printed part is OPEN: a brick is a shell, and what the
// bed side shows is its rim, the ribs that stand in for tubes, and the
// hollow between them. Sliced: a 1x1 has a rim alone; a 1xN a rim and solid
// pins between the studs; a 2xN and up a lattice of diamonds -- one round
// every inside corner of the stud grid, its points half a stud out -- with
// ribs along the grid lines from the diamonds to the rim (ps_underside).
uniform bool underside_hollow = true;
uniform float under_rim = 0.057;        // 1.3 mm of wall
uniform float under_rib = 0.020;        // half a rib: two 0.45 mm loops
uniform float under_pin = 0.072;        // a 1xN's pin, radius (1.65 mm)
// The hollow (brick.gdshader): upright walls and a flat roof `under_depth`
// up (metres: between a plate's hollow, 0.1, and a brick's, 0.37). How much
// sky (ambient occlusion) its roof sees, and its walls' foot; past
// under_depth_range, the average of the two.
uniform float under_cavity : hint_range(0.0, 1.0) = 0.75;
uniform float under_wall : hint_range(0.0, 1.0) = 0.85;
uniform float under_depth = 0.16;
uniform float under_depth_range = 25.0;
// Metres: inside it the hollow has real depth (parallax, brick.gdshader).
uniform float under_parallax_range = 10.0;

group_uniforms;

const float PU_STUD = 0.35;    // brick_grid.h STUD_M (print_surface's PS_STUD)
const float PU_BEVEL = 0.013;  // BrickNear.BEVEL (print_surface's PS_BEVEL)

// The signed distance to the rim and ribs of a bottom face (< 0 inside them),
// metres. `uv` is the point on the bottom face, `fsize` the face, both in
// metres. No derivatives in it: it is sampled beside itself for the slope of
// the hollow's roof (brick.gdshader, terrain.gdshader).
float ps_under_sd(vec2 uv, vec2 fsize) {
    vec2 n = max(floor(fsize / PU_STUD + 0.5), vec2(1.0));
    float edge = -PU_BEVEL + (min(min(uv.x, fsize.x - uv.x), min(uv.y, fsize.y - uv.y)));
    float sd = edge - under_rim;                  // < 0: in the rim
    vec2 p = uv / PU_STUD;
    if (min(n.x, n.y) < 1.5) {
        // 1xN: pins down the middle, between the studs.
        if (max(n.x, n.y) > 1.5) {
            bool along_x = n.x > n.y;
            float l = along_x ? p.x : p.y;
            float k = clamp(floor(l + 0.5), 1.0, max(n.x, n.y) - 1.0);
            vec2 c = along_x ? vec2(k, 0.5) : vec2(0.5, k);
            sd = min(sd, length(p - c) * PU_STUD - under_pin);
        }
    } else {
        // A diamond round the nearest inside corner of the stud grid...
        vec2 v = clamp(floor(p + 0.5), vec2(1.0), n - 1.0);
        vec2 q = p - v;
        float m = abs(q.x) + abs(q.y);
        sd = min(sd, abs(m - 0.5) * 0.7071 * PU_STUD - under_rib);
        // ...and the grid lines out from it, outside it.
        if (m > 0.5) {
            vec2 g = clamp(floor(p + 0.5), vec2(1.0), n - 1.0);
            float dl = min(abs(p.x - g.x), abs(p.y - g.y)) * PU_STUD;
            sd = min(sd, dl - under_rib);
        }
    }
    return sd;
}
