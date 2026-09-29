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

	var verts := PackedVector3Array()
	var normals := PackedVector3Array()
	var colours := PackedColorArray()
	var uvs := PackedVector2Array()
	var uv2s := PackedVector2Array()
	var indices := PackedInt32Array()
	var stud := PieceMeshes.stud().surface_get_arrays(0)
	for f in asm.frames:
		var xf: Transform3D = shift * w.get_chunk_transform(f)
		var arrays := w.build_chunk_mesh(f)
		if arrays.size() > 0:
			_append(arrays, xf, Color(-1, 0, 0), verts, normals, colours, uvs, uv2s, indices)
		var studs: PackedFloat32Array = w.get_chunk_studs(f)
		@warning_ignore("integer_division")
		for s in studs.size() / 16:
			var o := s * 16
			var basis := Basis(Vector3(studs[o], studs[o + 4], studs[o + 8]),
					Vector3(studs[o + 1], studs[o + 5], studs[o + 9]),
					Vector3(studs[o + 2], studs[o + 6], studs[o + 10]))
			var sx := Transform3D(basis, Vector3(studs[o + 3], studs[o + 7], studs[o + 11]))
			_append(stud, xf * sx, Color(studs[o + 12], studs[o + 13], studs[o + 14], studs[o + 15]),
					verts, normals, colours, uvs, uv2s, indices)
	for f in asm.frames:
		w.release_chunk(f)
	var mesh := ArrayMesh.new()
	if verts.is_empty():
		return mesh
	var out := []
	out.resize(Mesh.ARRAY_MAX)
	out[Mesh.ARRAY_VERTEX] = verts
	out[Mesh.ARRAY_NORMAL] = normals
	out[Mesh.ARRAY_COLOR] = colours
	out[Mesh.ARRAY_TEX_UV] = uvs
	out[Mesh.ARRAY_TEX_UV2] = uv2s
	out[Mesh.ARRAY_INDEX] = indices
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, out)
	if key != "":
		_cache[key] = mesh
	return mesh


## Append one surface's arrays, transformed. `colour` overrides the vertex
## colour unless its red is negative. Missing UVs are given a whole brick face,
## so the seam shader draws nothing odd on them. Degenerate triangles (a brick
## mesh keeps its hidden faces as zero-area slots) are dropped.
static func _append(arrays: Array, xf: Transform3D, colour: Color,
		verts: PackedVector3Array, normals: PackedVector3Array, colours: PackedColorArray,
		uvs: PackedVector2Array, uv2s: PackedVector2Array, indices: PackedInt32Array) -> void:
	var v: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	if v.is_empty():
		return
	var n = arrays[Mesh.ARRAY_NORMAL]
	var c = arrays[Mesh.ARRAY_COLOR]
	var u = arrays[Mesh.ARRAY_TEX_UV]
	var u2 = arrays[Mesh.ARRAY_TEX_UV2]
	var idx = arrays[Mesh.ARRAY_INDEX]
	var base := verts.size()
	for i in v.size():
		verts.append(xf * v[i])
		normals.append((xf.basis * (n[i] as Vector3)).normalized() if n != null and i < (n as PackedVector3Array).size() else Vector3.UP)
		if colour.r >= 0.0:
			colours.append(colour)
		else:
			colours.append((c as PackedColorArray)[i] if c != null and i < (c as PackedColorArray).size() else Color.WHITE)
		uvs.append((u as PackedVector2Array)[i] if u != null and i < (u as PackedVector2Array).size() else Vector2.ZERO)
		uv2s.append((u2 as PackedVector2Array)[i] if u2 != null and i < (u2 as PackedVector2Array).size() else Vector2(0.7, 0.42))
	if idx == null or (idx as PackedInt32Array).is_empty():
		for i in v.size():
			indices.append(base + i)
		return
	var ix: PackedInt32Array = idx
	for t in range(0, ix.size() - 2, 3):
		var a := ix[t]
		var b := ix[t + 1]
		var d := ix[t + 2]
		if a == b or b == d or a == d:
			continue
		indices.append(base + a)
		indices.append(base + b)
		indices.append(base + d)
