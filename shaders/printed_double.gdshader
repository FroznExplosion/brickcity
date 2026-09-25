shader_type spatial;
render_mode cull_disabled, diffuse_burley, specular_schlick_ggx;

// printed.gdshader for TWO-SIDED pieces -- the grass blades, which are single
// quads and have no back. Identical in every other respect; see the include.

#include "res://shaders/printed_core.gdshaderinc"
