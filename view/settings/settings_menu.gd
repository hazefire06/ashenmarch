class_name SettingsMenu
extends MenuScreen
## The Settings overlay: Fullscreen, Edge scroll, Back. Each toggle is saved
## to the settings file the moment it is flipped (GameSettings), then `changed`
## tells the App to apply it; Back (or Esc) emits `closed`, and the App removes
## the overlay. It is an overlay, not a screen, because it opens over the main
## menu and over a paused mission alike. Keybinds, volume and resolution are
## Phase 10's.

## A setting was flipped (and saved).
signal changed
## Back or Esc: the App should remove this overlay.
signal closed

const EDGE_SCROLL_HINT: String = "Pan the camera by pushing the mouse against the edge of the window."

var _path: String = GameSettings.DEFAULT_PATH
var _fullscreen: CheckBox
var _edge_scroll: CheckBox
var _back: Button
var _error: Label


func _init() -> void:
	super(false)


## Builds the screen from the settings file at `settings_path`.
func setup(settings_path: String = GameSettings.DEFAULT_PATH) -> void:
	_path = settings_path
	var center: CenterContainer = CenterContainer.new()
	center.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(center)
	var panel: PanelContainer = MenuKit.panel()
	center.add_child(panel)
	var column: VBoxContainer = VBoxContainer.new()
	column.add_theme_constant_override("separation", 14)
	panel.add_child(column)
	var heading: Label = MenuKit.title("Settings", 32)
	heading.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	column.add_child(heading)
	_fullscreen = _add_toggle(column, "FullscreenCheck", "Fullscreen", GameSettings.fullscreen(_path))
	_fullscreen.toggled.connect(_on_fullscreen_toggled)
	_edge_scroll = _add_toggle(column, "EdgeScrollCheck", "Edge scroll", GameSettings.edge_scroll(_path))
	_edge_scroll.toggled.connect(_on_edge_scroll_toggled)
	var hint: Label = MenuKit.paragraph(EDGE_SCROLL_HINT, 14, MenuKit.MUTED_COLOR)
	hint.custom_minimum_size.x = 340.0
	column.add_child(hint)
	_error = MenuKit.paragraph("", 14, MenuKit.BAD_COLOR)
	_error.name = "SaveError"
	_error.visible = false
	column.add_child(_error)
	_back = MenuKit.button("BackButton", "Back")
	_back.pressed.connect(func() -> void: closed.emit())
	column.add_child(_back)
	if is_inside_tree():
		_focus_default()


func _focus_default() -> void:
	_focus(_fullscreen)


func _cancel() -> bool:
	closed.emit()
	return true


func _on_fullscreen_toggled(on: bool) -> void:
	_saved(GameSettings.set_fullscreen(on, _path))


func _on_edge_scroll_toggled(on: bool) -> void:
	_saved(GameSettings.set_edge_scroll(on, _path))


# The choice is in force for this session either way; a failed write only means
# it won't be remembered, which the player is told.
func _saved(result: Error) -> void:
	_error.visible = result != OK
	if result != OK:
		_error.text = "Could not save the setting (%s); it applies until you quit." % error_string(result)
	changed.emit()


static func _add_toggle(parent: Control, toggle_name: String, text: String, on: bool) -> CheckBox:
	var box: CheckBox = CheckBox.new()
	box.name = toggle_name
	box.text = text
	box.set_pressed_no_signal(on)
	MenuKit.style_check(box)
	parent.add_child(box)
	return box
