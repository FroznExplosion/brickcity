shader_type spatial;
render_mode cull_back, diffuse_burley, specular_schlick_ggx;

// printed.gdshader with the brick grid's light (Docs/Lighting.md 6.1): the
// near tier's studs (BrickNear.grid_stud_material), so a shut room's floor
// studs are as dark as its floor. Identical otherwise; see the include.

#define GRID_LIGHT
#include "res://shaders/printed_core.gdshaderinc"
