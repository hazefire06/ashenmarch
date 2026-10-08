class_name HudFocus
extends RefCounted
## The HUD's buttons never take focus while a mission is played (a focused
## button would take Space and Enter for itself); the pad's control-bar mode
## (L3) lets them, so the D-pad moves between them and A presses one.
##
## Godot finds a focus neighbor by geometry, which across a bar of buttons of
## every width skips some; so while focus is on, each row of buttons (an
## HBoxContainer) is linked left and right in order, wrapping, and up and down
## to the nearest button of the rows above and below.


## Lets every button under `root` take focus (on) or none (off), linking the
## rows as above. With on, returns the first visible, enabled one (for focus
## to start on), or null.
static func enable(root: Node, on: bool) -> Button:
	var first: Button = null
	var rows: Array[Array] = []
	var stack: Array[Node] = [root]
	while not stack.is_empty():
		var node: Node = stack.pop_front()
		if node is Button:
			var button: Button = node
			button.focus_mode = Control.FOCUS_ALL if on else Control.FOCUS_NONE
			if first == null and on and button.is_visible_in_tree() and not button.disabled:
				first = button
		if on and node is HBoxContainer:
			var row: Array[Button] = []
			for child: Node in node.get_children():
				if child is Button and (child as Button).is_visible_in_tree():
					row.append(child as Button)
			if not row.is_empty():
				rows.append(row)
		var children: Array[Node] = node.get_children()
		stack = children + stack
	if on:
		_link(rows)
	return first


## The visible button under a screen point inside `root`, or null.
static func button_at(root: Node, at: Vector2) -> Button:
	var stack: Array[Node] = [root]
	while not stack.is_empty():
		var node: Node = stack.pop_front()
		if node is Button:
			var button: Button = node
			if button.is_visible_in_tree() and button.get_global_rect().has_point(at):
				return button
		var children: Array[Node] = node.get_children()
		stack = children + stack
	return null


## Presses a button as a focused one is pressed (ui_accept, down and up), so a
## toggle toggles and a plain button fires, as a click would. Focus goes back
## to where it was.
static func press(button: Button) -> void:
	if button.disabled:
		return
	var viewport: Viewport = button.get_viewport()
	var before: Control = viewport.gui_get_focus_owner()
	var mode: Control.FocusMode = button.focus_mode
	button.focus_mode = Control.FOCUS_ALL
	button.grab_focus()
	for down: bool in [true, false]:
		var accept: InputEventAction = InputEventAction.new()
		accept.action = &"ui_accept"
		accept.pressed = down
		viewport.push_input(accept)
	button.focus_mode = mode
	if before != null and is_instance_valid(before):
		before.grab_focus()
	elif viewport.gui_get_focus_owner() == button:
		viewport.gui_release_focus()


static func _link(rows: Array[Array]) -> void:
	for r: int in rows.size():
		var row: Array = rows[r]
		for i: int in row.size():
			var button: Button = row[i]
			button.focus_neighbor_left = button.get_path_to(row[posmod(i - 1, row.size())])
			button.focus_neighbor_right = button.get_path_to(row[posmod(i + 1, row.size())])
			button.focus_previous = button.focus_neighbor_left
			button.focus_next = button.focus_neighbor_right
			var above: Button = _nearest(button, rows[r - 1] if r > 0 else [])
			var below: Button = _nearest(button, rows[r + 1] if r + 1 < rows.size() else [])
			button.focus_neighbor_top = button.get_path_to(above if above != null else button)
			button.focus_neighbor_bottom = button.get_path_to(below if below != null else button)


# The button in `row` whose middle is nearest `button`'s, across.
static func _nearest(button: Button, row: Array) -> Button:
	var best: Button = null
	var best_d: float = INF
	var x: float = button.get_global_rect().get_center().x
	for other: Button in row:
		var d: float = absf(other.get_global_rect().get_center().x - x)
		if d < best_d:
			best_d = d
			best = other
	return best
