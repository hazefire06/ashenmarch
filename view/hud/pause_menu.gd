class_name PauseMenu
extends Control
## The pause menu, built in code like the rest of the HUD: Resume, Restart
## mission, Settings, and Quit to main menu (which asks first). It is only the
## menu: it says what the player chose through signals, and whatever runs the
## game (MainView for the pause itself, the App for restarting, settings, and
## leaving) acts on them.
## - resume_requested: Resume, or Esc with the menu open. The menu has already
##   closed itself.
## - restart_requested, settings_requested: the button. The menu stays up, so
##   the App can show Settings over it and come back to it.
## - quit_requested: Quit, after "Quit to the main menu?" was answered yes.
## - opened and closed: the menu appeared or went away, however it did, so the
##   game can pause with it.
##
## Esc opens the menu, or closes it (a Resume), and while the quit question is
## up it takes the question back. That only works if Esc reaches this node, and
## the SelectionController has first claim on it: it cancels an armed order and
## consumes the key. Later nodes see unhandled input first, so this node sits
## BEFORE the controller under the HUD (main.tscn); the controller consumes Esc
## while an order is armed and otherwise lets it through to here. Tree order is
## also draw order and click order for the HUD's controls, so what it shows lives
## on a CanvasLayer of its own, above the HUD's, where it draws over and takes
## clicks ahead of the control bar and the panels (a z_index would only draw
## over them: Godot picks the control under the mouse by tree order).
##
## While the menu is open a dim layer covers the screen and takes the mouse, so
## nothing under it is clicked. When the game is paused without the menu (P), a
## small "Paused (P to resume)" label stands in (show_paused_label). In the
## sandbox, with no App to restart or leave, those three buttons are hidden
## (set_app_buttons_visible).

signal resume_requested
signal restart_requested
signal settings_requested
signal quit_requested
signal opened
signal closed

const DIM_COLOR: Color = Color(0.0, 0.0, 0.0, 0.55)
const PANEL_COLOR: Color = Color(0.09, 0.09, 0.1, 0.96)
const TITLE_FONT_SIZE: int = 32
const BUTTON_WIDTH: float = 280.0
const PAUSED_FONT_SIZE: int = 40
const PAUSED_LABEL_TOP: float = 120.0
const OUTLINE_COLOR: Color = Color(0.05, 0.05, 0.05, 0.9)
const LABEL_COLOR: Color = Color(1.0, 0.95, 0.7)
## The HUD's CanvasLayer is 1; the menu's is above it.
const MENU_LAYER: int = 10
## The label for a pause with no menu: it says how to end it, since there is no
## Resume button to find.
const PAUSED_LABEL_TEXT: String = "Paused (P to resume)"
const QUIT_QUESTION: String = "Quit to the main menu?\nThis mission's progress is lost."

## While false the menu can't be opened, by Esc or open() (MainView turns it
## off once the mission is decided: the end is on its way, and a menu with
## Restart and Quit on it would race it).
var enabled: bool = true

var _layer: CanvasLayer
var _overlay: ColorRect
var _buttons: VBoxContainer
var _confirm: VBoxContainer
var _paused_label: Label
var _resume: Button
var _restart: Button
var _settings: Button
var _quit: Button
var _keep_playing: Button


func _ready() -> void:
	InputBindings.install()
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	focus_mode = Control.FOCUS_NONE
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_build()


## Shows the menu, unless it is up already or switched off (`enabled`): the
## bar's Menu button and Esc reach it the same way.
func open() -> void:
	if is_open() or not enabled:
		return
	_show_confirm(false)
	_overlay.visible = true
	_paused_label.visible = false
	_resume.grab_focus()
	opened.emit()


## Hides the menu without asking for anything; a no-op if it isn't up.
func close() -> void:
	if not is_open():
		return
	_overlay.visible = false
	_show_confirm(false)
	closed.emit()


## True while the menu is on screen.
func is_open() -> bool:
	return _overlay != null and _overlay.visible


## True while the menu is asking whether to quit.
func is_confirming() -> bool:
	return _confirm.visible


## Shows or hides the small "Paused (P to resume)" label, for a pause with no menu. Never
## shown with the menu open: the menu says it already.
func show_paused_label(shown: bool) -> void:
	_paused_label.visible = shown and not is_open()


## True if the "Paused" label is up.
func is_paused_label_visible() -> bool:
	return _paused_label.visible


## Shows or hides the buttons that need the App around them: Restart,
## Settings, and Quit. The sandbox has no App, and a button that does nothing
## is worse than none.
func set_app_buttons_visible(shown: bool) -> void:
	_restart.visible = shown
	_settings.visible = shown
	_quit.visible = shown


# Esc: open, close, or take back the quit question. The controller consumes it
# first while an order is armed (see the class comment).
func _unhandled_input(event: InputEvent) -> void:
	if not enabled or not event.is_action_pressed(InputBindings.CANCEL):
		return
	if is_confirming():
		_show_confirm(false)
	elif is_open():
		_resume_pressed()
	else:
		open()
	get_viewport().set_input_as_handled()


func _resume_pressed() -> void:
	close()
	resume_requested.emit()


func _show_confirm(asking: bool) -> void:
	_confirm.visible = asking
	_buttons.visible = not asking
	if is_open():
		# Keyboard focus moves with the question, to the safe answer.
		(_keep_playing if asking else _resume).grab_focus()


func _build() -> void:
	_layer = CanvasLayer.new()
	_layer.name = "MenuLayer"
	_layer.layer = MENU_LAYER
	add_child(_layer)
	_paused_label = Label.new()
	_paused_label.text = PAUSED_LABEL_TEXT
	_paused_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_paused_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_paused_label.set_anchors_and_offsets_preset(Control.PRESET_TOP_WIDE)
	_paused_label.offset_top = PAUSED_LABEL_TOP
	_paused_label.offset_bottom = PAUSED_LABEL_TOP + PAUSED_FONT_SIZE * 1.4
	_style_label(_paused_label, PAUSED_FONT_SIZE)
	_paused_label.visible = false
	_layer.add_child(_paused_label)

	_overlay = ColorRect.new()
	_overlay.name = "Overlay"
	_overlay.color = DIM_COLOR
	_overlay.mouse_filter = Control.MOUSE_FILTER_STOP
	_overlay.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_overlay.visible = false
	_layer.add_child(_overlay)
	var center: CenterContainer = CenterContainer.new()
	center.mouse_filter = Control.MOUSE_FILTER_IGNORE
	center.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_overlay.add_child(center)
	var panel: PanelContainer = PanelContainer.new()
	var style: StyleBoxFlat = StyleBoxFlat.new()
	style.bg_color = PANEL_COLOR
	style.set_content_margin_all(24.0)
	style.set_corner_radius_all(6)
	panel.add_theme_stylebox_override("panel", style)
	center.add_child(panel)
	var column: VBoxContainer = VBoxContainer.new()
	column.add_theme_constant_override("separation", 12)
	panel.add_child(column)
	var title: Label = Label.new()
	title.text = "Paused"
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_style_label(title, TITLE_FONT_SIZE)
	column.add_child(title)

	_buttons = VBoxContainer.new()
	_buttons.add_theme_constant_override("separation", 8)
	column.add_child(_buttons)
	_resume = _menu_button("ResumeButton", "Resume")
	_resume.pressed.connect(_resume_pressed)
	_restart = _menu_button("RestartButton", "Restart mission")
	_restart.pressed.connect(func() -> void: restart_requested.emit())
	_settings = _menu_button("SettingsButton", "Settings")
	_settings.pressed.connect(func() -> void: settings_requested.emit())
	_quit = _menu_button("QuitButton", "Quit to main menu")
	_quit.pressed.connect(func() -> void: _show_confirm(true))

	_confirm = VBoxContainer.new()
	_confirm.add_theme_constant_override("separation", 12)
	_confirm.visible = false
	column.add_child(_confirm)
	var question: Label = Label.new()
	question.text = QUIT_QUESTION
	question.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_confirm.add_child(question)
	var answers: VBoxContainer = VBoxContainer.new()
	answers.add_theme_constant_override("separation", 8)
	_confirm.add_child(answers)
	_keep_playing = _menu_button("CancelQuitButton", "Keep playing", answers)
	_keep_playing.pressed.connect(func() -> void: _show_confirm(false))
	var sure: Button = _menu_button("ConfirmQuitButton", "Quit", answers)
	sure.pressed.connect(func() -> void: quit_requested.emit())


# A full-width menu button. Unlike the battlefield's HUD buttons it takes
# keyboard focus: this is a menu, and Enter and the arrow keys should work.
func _menu_button(button_name: String, text: String, parent: Control = null) -> Button:
	var b: Button = Button.new()
	b.name = button_name
	b.text = text
	b.custom_minimum_size.x = BUTTON_WIDTH
	(_buttons if parent == null else parent).add_child(b)
	return b


static func _style_label(label: Label, font_size: int) -> void:
	label.add_theme_font_size_override("font_size", font_size)
	label.add_theme_color_override("font_color", LABEL_COLOR)
	label.add_theme_color_override("font_outline_color", OUTLINE_COLOR)
	label.add_theme_constant_override("outline_size", 8)
