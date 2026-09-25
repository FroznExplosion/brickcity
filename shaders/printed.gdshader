shader_type spatial;
render_mode cull_back, diffuse_burley, specular_schlick_ggx;

// Printed plastic for INSTANCED pieces — studs, pebbles, tufts, debris.
//
// These used to run a StandardMaterial3D, which is why the studs were the one
// thing in the world with no layer lines on them at all: the ground shader
// prints itself and a standard material cannot. Everything the player can get
// close to is a printed object, so everything needs the same treatment.
//
// Evaluated in OBJECT space, not world. A stud is one shared mesh drawn
// 8,300 times, and a tumbling brick is the same mesh with a different
// transform — object space means the paths belong to the PART, so they turn
// with it instead of swimming through it. (The ground shader uses world space
// for the opposite reason: its pieces never move, and world space is what
// keeps the layers continuous across a seam.)

#include "res://shaders/printed_core.gdshaderinc"
