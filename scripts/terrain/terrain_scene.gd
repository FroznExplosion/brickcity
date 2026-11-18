extends Node3D

## The terrain test: the Minecraft-like mine world by default
## (mine_world.gd, Docs/MineWorld.md), the old fixed-field destruction bench
## with `-- --bench` (terrain_bench.gd, Docs/Terrain.md).
##
##     godot --path . scenes/terrain_test.tscn
##     godot --path . scenes/terrain_test.tscn -- --gate
##     godot --path . scenes/terrain_test.tscn -- --bench [--shot]
##
## Preloaded by path: a new class_name is not in the class cache until the
## editor rescans.

const MineWorld := preload("res://scripts/terrain/mine_world.gd")
const Bench := preload("res://scripts/terrain/terrain_bench.gd")


var _world: Node3D = null


func _ready() -> void:
	var bench := "--bench" in OS.get_cmdline_user_args()
	var node: Node3D = Bench.new() if bench else MineWorld.new()
	node.name = "Bench" if bench else "MineWorld"
	add_child(node)
	if not bench:
		_world = node


# The pause menu's scene hooks (BrickcityMenuHost): the mine world answers;
# the bench keeps its own Escape and never pauses.

func pause_allowed() -> bool:
	return _world != null and bool(_world.call("pause_allowed"))


func pause_menu_entries() -> Array:
	return _world.call("pause_menu_entries") if _world != null else []


func pause_closed() -> void:
	if _world != null:
		_world.call("pause_closed")
