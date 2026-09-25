## component_cache.gd
## Cached component lookup on an entity root.
##
## `find_child()` is O(subtree) and `DamageSystem.resolve()` ran it TWICE per hit
## (HealthPool + StatusManager). With one gun that is invisible. With a melee sweep
## hitting a dozen enemies per swing (ProceduralCombat §3), or a horde eating splash,
## it is not. This caches the resolved component in the entity root's metadata, so the
## subtree walk happens once per entity instead of once per hit.
##
## POSITIVE results only. A negative result is deliberately NOT cached: components can
## be added after spawn (a pooled enemy gets its HealthPool on reuse, a swarm agent
## promoted to a node entity gets one on promotion), and a sticky "no HealthPool here"
## would be permanent, silent, and unfindable. Misses stay exactly as expensive as they
## were — they are the rare case.
##
## Meta keys are namespaced `_cc_*` and owned by the caller, so two systems caching
## different components on the same root never collide.
class_name ComponentCache
extends Object


## Resolve `node_name` under `root`, caching the hit. Returns null if absent.
static func find(root: Node, node_name: StringName, meta_key: StringName) -> Node:
	if root == null:
		return null

	if root.has_meta(meta_key):
		var cached: Variant = root.get_meta(meta_key)
		# typeof() before is_instance_valid() before `as`: the `is`/`as` operators both
		# ERROR on a previously-freed instance ("Left operand of 'is' is a previously
		# freed instance"), and a stale entry is exactly the case this branch exists for.
		if typeof(cached) == TYPE_OBJECT and is_instance_valid(cached):
			var node: Node = cached as Node
			if node != null:
				return node
		# Freed, or someone stored a non-Node under our key — re-resolve.
		root.remove_meta(meta_key)

	var found: Node = root.find_child(String(node_name), true, false)
	if found != null:
		root.set_meta(meta_key, found)
	return found


## Drop a cached entry. Call after swapping or reparenting a component on a LIVE
## entity; freed components self-heal via the is_instance_valid check above.
static func invalidate(root: Node, meta_key: StringName) -> void:
	if root != null and root.has_meta(meta_key):
		root.remove_meta(meta_key)
