extends Node
## Loads the scripts named after `--` so their GDScript warnings print. A scene,
## not a --script, so the autoloads (MenuSettings, ...) the scripts name exist.
##   -d --headless --path . res://tools/warn_check.tscn -- scripts/a.gd ...


func _ready() -> void:
	for p in OS.get_cmdline_user_args():
		var s = load("res://" + p)
		print("[warn_check] %s %s" % [p, "loaded" if s != null else "FAILED"])
	get_tree().quit()
