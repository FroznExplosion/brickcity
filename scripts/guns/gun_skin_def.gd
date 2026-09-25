class_name GunSkinDef
extends Resource
## One cosmetic skin. Pure data — works on any gun ever assembled because it
## never references part assets. Leave `pattern` empty for a solid tint
## (manufacturer-default mode).

@export var id: StringName
@export var display_name: String = ""

@export_group("Pattern")
## Tileable. RGB = secondary/tertiary/accent masks, A = emission mask.
@export var pattern: Texture2D
## Tiles per meter of gun length. Camo ~2-4, fine patterns 8+.
@export_range(0.1, 32.0) var pattern_scale: float = 3.0
@export_range(1.0, 32.0) var blend_sharpness: float = 8.0

@export_group("Palette")
@export var palette_primary := Color(0.30, 0.30, 0.33)
@export var palette_secondary := Color(0.60, 0.55, 0.45)
@export var palette_tertiary := Color(0.12, 0.12, 0.14)
@export var palette_accent := Color(0.85, 0.35, 0.10)

@export_group("Surface")
@export_range(0.0, 1.0) var roughness: float = 0.55
@export_range(0.0, 1.0) var metallic: float = 0.15
@export var emission_color := Color.BLACK
@export_range(0.0, 16.0) var emission_strength: float = 0.0

@export_group("Drops")
## Hooks for the loot system (model lives in the stats/rarity spec).
@export_range(1, 6) var min_rarity: int = 1
@export var tags: PackedStringArray = []
