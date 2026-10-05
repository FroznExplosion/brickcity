class_name RecipeMesh

## A recipe as ONE real-brick mesh: every brick as it would be drawn once
## materialised, studs included, in a single surface.
##
## For drawing many identical, intact copies of a small recipe -- a tree, an
## item -- as instances (ImpostorLod), and for baking its impostor. A brick
## building draws its studs as a separate MultiMesh (city_placer's ghost does
## the same); instancing wants one mesh, so here they are merged in.
##
## Built in a private BrickWorld, so any scene can use it, with or without a
## city. The mesh's origin is the recipe's min corner, as a placed build's is.

## Recipe name -> ArrayMesh, since a recipe is fixed once made.
static var _cache := {}
## One private world and palette for every mesh: baking the palette is most of
## what making one costs.
static var _w: BrickWorld = null
static var _pal := {}


static func build(recipe: BuildRecipe, key: String = "") -> ArrayMesh:
	if key != "" and _cache.has(key):
		return _cache[key]
	if _w == null:
		_w = BrickWorld.new()
		_pal = TowerRecipe.bake_palette(_w)
	var w := _w
	var pal := _pal
	var asm := Assembly.new(w, pal)
	recipe.build_into(asm, pal)
	var cell := BrickWorld.get_cell_size()
	var lo: Vector3i = recipe.origin()
	var shift := Transform3D(Basis(), -Vector3(lo.x * cell.x, lo.y * cell.y, lo.z * cell.z))

	# The merge, in C++ (MeshMerge): it was a GDScript loop a vertex, 900 ms
	# for the city's four tree kinds at startup.
	var merge := MeshMerge.new()
	var stud := PieceMeshes.stud().surface_get_arrays(0)
	for f in asm.frames:
		var xf: Transform3D = shift * w.get_chunk_transform(f)
		var arrays := w.build_chunk_mesh(f)
		if arrays.size() > 0:
			merge.add_surface(arrays, xf, Color(-1, 0, 0))
		merge.add_instances(stud, xf, w.get_chunk_studs(f))
	for f in asm.frames:
		w.release_chunk(f)
	var mesh := ArrayMesh.new()
	var out := merge.commit()
	if out.is_empty():
		return mesh
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, out)
	if key != "":
		_cache[key] = mesh
	return mesh
