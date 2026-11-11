class_name ColourMatch

## Colours matched to a brick material's colours as the eye sees them
## (Docs/AssetWorkshop.md, "Colour from model to bricks").
##
## Distances are taken in Oklab (Bjorn Ottosson, 2020), not RGB: equal steps in it look
## equal, as CIE Lab's do (Sink My Bricks matches by CIE76, Reference/brick-games.md
## 1.1). SdfForm.cell_colours does the same in C++ for every brick cell at once; this
## is for single colours and for building the palette it votes from.
##
## A palette can be the whole material (every colour it has) or a list of its colour
## indices -- an area's palette (AreaPalette), so everything converted in a star system
## takes that system's colours.


## Oklab of an sRGB colour: L (lightness 0-1), a, b.
static func oklab(c: Color) -> Vector3:
	var r := _lin(c.r)
	var g := _lin(c.g)
	var b := _lin(c.b)
	var l := pow(0.4122214708 * r + 0.5363325363 * g + 0.0514459929 * b, 1.0 / 3.0)
	var m := pow(0.2119034982 * r + 0.6806995451 * g + 0.1073969566 * b, 1.0 / 3.0)
	var s := pow(0.0883024619 * r + 0.2817188376 * g + 0.6299787005 * b, 1.0 / 3.0)
	return Vector3(0.2104542553 * l + 0.7936177850 * m - 0.0040720468 * s,
			1.9779984951 * l - 2.4285922050 * m + 0.4505937099 * s,
			0.0259040371 * l + 0.7827717662 * m - 0.8086757660 * s)


static func _lin(v: float) -> float:
	return v / 12.92 if v <= 0.04045 else pow((v + 0.055) / 1.055, 2.4)


## How different two colours look (Oklab distance; about 0.02 is just noticeable).
static func difference(a: Color, b: Color) -> float:
	return oklab(a).distance_to(oklab(b))


## Material `material`'s colour indices to match against: `allowed` (an area's palette)
## where the material is a filament one and the list is not empty, else all it has.
static func indices(material: int, allowed: PackedInt32Array = PackedInt32Array()) -> PackedInt32Array:
	var n := BrickWorld.get_material_colour_count(material)
	var out := PackedInt32Array()
	if not allowed.is_empty() and BrickWorld.is_filament_material(material):
		for i in allowed:
			if i >= 0 and i < n:
				out.append(i)
	if out.is_empty():
		for i in n:
			out.append(i)
	return out


## The colours of those indices, as SdfForm.cell_colours takes them.
static func colours(material: int, idx: PackedInt32Array) -> PackedColorArray:
	var out := PackedColorArray()
	for i in idx:
		out.append(BrickWorld.get_material_colour(material, i))
	return out


## The colour index of `material` (within `allowed`, see `indices`) that looks most like `c`.
static func nearest(c: Color, material: int = 0, allowed: PackedInt32Array = PackedInt32Array()) -> int:
	var idx := indices(material, allowed)
	var q := oklab(c)
	var best := -1
	var bd := INF
	for i in idx:
		var d := oklab(BrickWorld.get_material_colour(material, i)).distance_squared_to(q)
		if d < bd:
			bd = d
			best = i
	return best
