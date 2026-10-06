// How every printed part in the world is finished. Two switches, and they are
// CONSTANTS, not uniforms: BrickMaterials.set_look rewrites this file's code in
// memory, and Godot recompiles every shader that includes it -- the bricks,
// their studs, the scatter, the see-through pass -- whoever made the material.
// A uniform would have to be set on each material, and the workshop's, the
// sandbox's and every impostor copy would each have to be found. A constant
// also costs nothing: the branches it decides are compiled out.
//
// What is written here is the default, what a fresh install sees. Keep the
// two lines in this exact form; BrickMaterials writes them back the same way.
//
// PRINT_FINISH  0 printed (layer lines, dull sides, bed-finish bottoms)
//               1 injection moulded (one glossy skin, no lines)
// PRINT_BED     what the bottom face was printed on:
//               0 glass (mirror-smooth), 1 smooth PEI (satin),
//               2 textured PEI (matte powder-coat grain)

const int PRINT_FINISH = 0;
const int PRINT_BED = 0;
