class_name MenuScreen
extends Control
## The base of every front-end screen: a full-window Control with its own
## backdrop, built in code like the HUD. A screen is dumb on purpose: it shows
## what it was given and says what the player chose through signals; the App
## decides what happens next, so every screen can be built and tested alone.
##
## Esc is Back here (InputBindings.CANCEL, the same action the pause menu uses):
## a subclass overrides _cancel() to say what Back means on it, and returns
## false to let the key pass. A subclass builds its contents in its setup() (or
## its own _init when it needs no data), and says in _focus_default() which
## control the keyboard starts on, because these are menus: Enter and the arrow
## keys have to work.
##
## A pad works every screen the same way (Phase 11): the D-pad or left stick
## moves focus, A presses (ui_accept), B is Back (CANCEL's pad binding), and the
## right stick scrolls the screen's scroll box (a briefing's text, a list), for
## text with no button in it to move focus through.

## Pixels a second the right stick scrolls at full tilt.
const PAD_SCROLL_SPEED: float = 900.0

## The opaque backdrop of a whole screen, or the dim of an overlay (Settings and
## the confirm dialog show over something else).
var _backdrop_is_opaque: bool = true


## `opaque` false makes an overlay: a dim layer over whatever is beneath rather
## than a backdrop that hides it.
func _init(opaque: bool = true) -> void:
	_backdrop_is_opaque = opaque
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	if opaque:
		add_child(MenuKit.backdrop())
	else:
		add_child(MenuKit.dim())


func _ready() -> void:
	InputBindings.install()
	_focus_default()


func _process(delta: float) -> void:
	if not is_visible_in_tree():
		return
	var push: float = Input.get_axis(InputBindings.PAD_PAN_FORWARD, InputBindings.PAD_PAN_BACK)
	if push == 0.0:
		return
	var scroller: ScrollContainer = scroll_box()
	if scroller != null:
		scroller.scroll_vertical += roundi(push * PAD_SCROLL_SPEED * delta)


## The scroll box the pad's right stick scrolls: the one holding focus, else
## the first visible one on the screen; null if there is none.
func scroll_box() -> ScrollContainer:
	var focus: Control = get_viewport().gui_get_focus_owner() if is_inside_tree() else null
	var node: Node = focus
	while node != null and node != self:
		if node is ScrollContainer:
			return node as ScrollContainer
		node = node.get_parent()
	var stack: Array[Node] = [self]
	while not stack.is_empty():
		var next: Node = stack.pop_front()
		if next is ScrollContainer and (next as ScrollContainer).is_visible_in_tree():
			return next as ScrollContainer
		var children: Array[Node] = next.get_children()
		stack.append_array(children)
	return null


## True for a screen that hides what is under it, false for an overlay.
func is_opaque() -> bool:
	return _backdrop_is_opaque


## Where the keyboard starts. Overridden by each screen; called when the screen
## enters the tree and again by a setup() that fills it afterwards.
func _focus_default() -> void:
	pass


## What Esc does. Return true if it did something (the key is then consumed).
func _cancel() -> bool:
	return false


func _unhandled_input(event: InputEvent) -> void:
	if not is_visible_in_tree() or not event.is_action_pressed(InputBindings.CANCEL):
		return
	# Taken first: answering may remove this screen from the tree (a dialog
	# its owner closes), after which it has no viewport.
	var viewport: Viewport = get_viewport()
	if _cancel():
		viewport.set_input_as_handled()


# Puts the keyboard on this control once the screen is in the tree.
func _focus(control: Control) -> void:
	if control != null and control.is_inside_tree() and control.is_visible_in_tree():
		control.grab_focus()
