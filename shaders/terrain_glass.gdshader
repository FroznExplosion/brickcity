// GLASS in the mine world's ground (Docs/TerrainBuildings.md 5b): the faces
// BrickTerrain splits out of a tile's mesh ("glass_mesh", material byte
// MAT_GLASS), drawn blended by TerrainTile's "SurfaceGlass" node. The tint is
// the vertex colour (the glass filament's); more opaque edge-on, as glass is.
shader_type spatial;
render_mode blend_mix, cull_back, depth_draw_opaque, diffuse_burley, specular_schlick_ggx;

uniform float base_alpha : hint_range(0.0, 1.0) = 0.22;
uniform float edge_alpha : hint_range(0.0, 1.0) = 0.65;
uniform float roughness_v : hint_range(0.0, 1.0) = 0.06;

void fragment() {
	float facing = clamp(dot(NORMAL, VIEW), 0.0, 1.0);
	float fres = pow(1.0 - facing, 4.0);
	ALBEDO = COLOR.rgb;
	ALPHA = mix(base_alpha, edge_alpha, fres);
	ROUGHNESS = roughness_v;
	SPECULAR = 0.7;
	METALLIC = 0.0;
}
