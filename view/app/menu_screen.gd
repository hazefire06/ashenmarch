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
