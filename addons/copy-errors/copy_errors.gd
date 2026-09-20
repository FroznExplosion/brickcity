@tool
extends EditorPlugin

var _update_timer: Timer
const SINGLE_BTN_NAME = "CustomCopyErrorsBtn"
const ALL_BTN_NAME = "CustomCopyAllSessionsErrorsBtn"

func _enter_tree() -> void:
	_update_timer = Timer.new()
	_update_timer.wait_time = 0.5
	_update_timer.autostart = true
	_update_timer.timeout.connect(_scan_and_inject)
	add_child(_update_timer)
	_scan_and_inject()

func _exit_tree() -> void:
	if is_instance_valid(_update_timer):
		_update_timer.stop()
		_update_timer.queue_free()
	_remove_injected_buttons()

func _scan_and_inject() -> void:
	var error_containers = _find_all_error_containers()
	var session_count = error_containers.size()

	for entry in error_containers:
		var toolbar: HBoxContainer = entry["toolbar"]
		var tree: Tree = entry["tree"]
		var collapse_btn: Button = entry["collapse_btn"]

		# 1. Single-session "Copy All" button
		var single_btn: Button = toolbar.get_node_or_null(SINGLE_BTN_NAME)
		if not single_btn:
			single_btn = Button.new()
			single_btn.name = SINGLE_BTN_NAME
			single_btn.text = "Copy All"
			single_btn.tooltip_text = "Copy all error messages from this session to the clipboard."
			single_btn.pressed.connect(_on_copy_single_pressed.bind(tree))
			toolbar.add_child(single_btn)
			toolbar.move_child(single_btn, collapse_btn.get_index() + 1)

		# 2. Multi-session "Copy All Sessions" button
		var all_btn: Button = toolbar.get_node_or_null(ALL_BTN_NAME)
		if not all_btn:
			all_btn = Button.new()
			all_btn.name = ALL_BTN_NAME
			all_btn.text = "Copy All Sessions"
			all_btn.tooltip_text = "Copy all error messages across all active sessions to the clipboard."
			all_btn.pressed.connect(_on_copy_all_sessions_pressed)
			toolbar.add_child(all_btn)
			toolbar.move_child(all_btn, single_btn.get_index() + 1)

		all_btn.visible = (session_count > 1)

func _find_all_error_containers() -> Array[Dictionary]:
	var results: Array[Dictionary] = []
	var base_control = EditorInterface.get_base_control()
	if not base_control:
		return results

	_recursive_search_error_panels(base_control, results)
	return results

func _recursive_search_error_panels(node: Node, results: Array[Dictionary]) -> void:
	if node is HBoxContainer:
		var expand_btn: Button = null
		var collapse_btn: Button = null

		for child in node.get_children():
			if child is Button:
				if child.text == "Expand All":
					expand_btn = child
				elif child.text == "Collapse All":
					collapse_btn = child

		if expand_btn and collapse_btn:
			var parent = node.get_parent()
			var tree: Tree = null
			if parent:
				for sibling in parent.get_children():
					if sibling is Tree:
						tree = sibling
						break

			if tree:
				results.append({
					"toolbar": node,
					"tree": tree,
					"collapse_btn": collapse_btn
				})
				return

	for child in node.get_children():
		_recursive_search_error_panels(child, results)

func _on_copy_single_pressed(tree: Tree) -> void:
	var text = _extract_text_from_tree(tree)
	if text.is_empty():
		text = "[No errors in this session]"
	DisplayServer.clipboard_set(text)

func _on_copy_all_sessions_pressed() -> void:
	var containers = _find_all_error_containers()
	var outputs: Array[String] = []

	for i in range(containers.size()):
		var tree: Tree = containers[i]["tree"]
		var session_title = _resolve_session_title(tree, i + 1)
		var text = _extract_text_from_tree(tree)
		
		if text.is_empty():
			text = "(No errors)"
			
		outputs.append("=== %s ===\n%s" % [session_title, text])

	DisplayServer.clipboard_set("\n\n".join(outputs))

func _extract_text_from_tree(tree: Tree) -> String:
	if not is_instance_valid(tree):
		return ""
	var root = tree.get_root()
	if not root:
		return ""

	var entries: Array[String] = []
	for item in root.get_children():
		var item_text = _extract_item_recursive(item, 0)
		if not item_text.is_empty():
			entries.append(item_text)

	return "\n\n".join(entries)

func _extract_item_recursive(item: TreeItem, depth: int) -> String:
	var indent = "  ".repeat(depth)
	var lines: Array[String] = []

	var text = item.get_text(0).strip_edges()
	var tooltip = item.get_tooltip_text(0).strip_edges()
	var meta = item.get_metadata(0)

	# 1. Main header line
	if not text.is_empty():
		lines.append(indent + text)

	# 2. Detailed message from tooltip (contains full description, C++ condition, file & line)
	if not tooltip.is_empty() and tooltip != text:
		for t_line in tooltip.split("\n"):
			var trimmed = t_line.strip_edges()
			if not trimmed.is_empty() and trimmed != text and not text.contains(trimmed):
				lines.append(indent + "    " + trimmed)

	# 3. Extra metadata if attached directly by the engine
	if meta is Dictionary and not meta.is_empty():
		for k in meta:
			var val_str = str(meta[k]).strip_edges()
			if not val_str.is_empty() and not tooltip.contains(val_str) and not text.contains(val_str):
				lines.append(indent + "    %s: %s" % [str(k), val_str])
	elif meta is String and not meta.is_empty():
		if not tooltip.contains(meta) and not text.contains(meta):
			lines.append(indent + "    " + meta)

	# 4. Recursively collect child entries (call stacks, sub-errors)
	for child in item.get_children():
		var child_text = _extract_item_recursive(child, depth + 1)
		if not child_text.is_empty():
			lines.append(child_text)

	return "\n".join(lines)

func _resolve_session_title(tree: Tree, fallback_index: int) -> String:
	var curr: Node = tree
	while curr and curr != EditorInterface.get_base_control():
		var parent = curr.get_parent()
		if parent is TabContainer:
			var title = parent.get_tab_title(curr.get_index())
			if not title.is_empty():
				return title
		curr = parent
	return "Session %d" % fallback_index

func _remove_injected_buttons() -> void:
	var base_control = EditorInterface.get_base_control()
	if not base_control:
		return
	_recursive_remove(base_control)

func _recursive_remove(node: Node) -> void:
	for child in node.get_children():
		if child.name in [SINGLE_BTN_NAME, ALL_BTN_NAME]:
			child.queue_free()
		else:
			_recursive_remove(child)