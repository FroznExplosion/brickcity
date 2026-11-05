class_name InstanceParams

## Instance shader parameters that code copies from one node to another (a
## band's to its chamfered stand-in, a building's grain to its stand-in), kept
## on the node as well as set. GeometryInstance3D.get_instance_shader_parameter
## asks the renderer, which with the renderer on a thread of its own waits for
## it (CLAUDE.md "Where new code runs"; Docs/WhereWorkRuns.md 3.1 a). So a
## parameter that is ever read back during play is set with put and read with
## of. Gates may still ask the renderer: that is what they are checking.


## Sets it on the node, and keeps it for of().
static func put(node: GeometryInstance3D, param: StringName, value: Variant) -> void:
	node.set_instance_shader_parameter(param, value)
	node.set_meta(_key(param), value)


## What put last set on the node, or null if it never did.
static func of(node: GeometryInstance3D, param: StringName) -> Variant:
	return node.get_meta(_key(param), null)


static func _key(param: StringName) -> StringName:
	return StringName("ip_" + param)
