class_name MainMenu
extends MenuScreen
## The first screen: the title and five buttons. Each is a signal for the App,
## which decides what opens next: the campaign menu, the skirmish setup, the
## recorded games, the Settings overlay, or the end of the game.
## Quit is left off the Web build, where a page can't close itself. On the
## web a browser shows a pad to the page only once a button is pressed on it,
## so until one is, a line at the foot says so (pad_hint_shown).

## Campaign was pressed.
signal campaign_pressed
## Skirmish was pressed: the App shows the skirmish setup.
signal skirmish_pressed
## Replays was pressed: the App lists the recorded games.
signal replays_pressed
## Settings was pressed: the App shows the overlay.
signal settings_pressed
## Quit was pressed: the App closes the game.
signal quit_pressed

const TITLE: String = "Ashenmarch"
const TITLE_SIZE: int = 72
const PAD_HINT: String = "Controller: press any button on it to start using it."

var _campaign: Button
var _pad_hint: Label


func _init() -> void:
	super(true)
	var center: CenterContainer = CenterContainer.new()
	center.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(center)
	var column: VBoxContainer = VBoxContainer.new()
	column.add_theme_constant_override("separation", 40)
	center.add_child(column)
	var title: Label = MenuKit.title(TITLE, TITLE_SIZE)
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	column.add_child(title)

	var buttons: VBoxContainer = VBoxContainer.new()
	buttons.add_theme_constant_override("separation", 10)
	column.add_child(buttons)
	_campaign = _add_button(buttons, "CampaignButton", "Campaign")
	_campaign.pressed.connect(func() -> void: campaign_pressed.emit())
	var skirmish: Button = _add_button(buttons, "SkirmishButton", "Skirmish")
	skirmish.pressed.connect(func() -> void: skirmish_pressed.emit())
	var replays: Button = _add_button(buttons, "ReplaysButton", "Replays")
	replays.pressed.connect(func() -> void: replays_pressed.emit())
	var settings: Button = _add_button(buttons, "SettingsButton", "Settings")
	settings.pressed.connect(func() -> void: settings_pressed.emit())
	var quit: Button = _add_button(buttons, "QuitButton", "Quit")
	quit.pressed.connect(func() -> void: quit_pressed.emit())
	quit.visible = not OS.has_feature("web")
	_pad_hint = MenuKit.paragraph(PAD_HINT, 14, MenuKit.MUTED_COLOR)
	_pad_hint.name = "PadHint"
	_pad_hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_pad_hint.set_anchors_and_offsets_preset(Control.PRESET_CENTER_BOTTOM)
	_pad_hint.grow_horizontal = Control.GROW_DIRECTION_BOTH
	_pad_hint.offset_top = -48.0
	_pad_hint.offset_bottom = -24.0
	add_child(_pad_hint)
	_pad_hint.visible = false


func _ready() -> void:
	super()
	InputDeviceTracker.tracker().pads_changed.connect(_refresh_pad_hint)
	_refresh_pad_hint()


## True while the "press any button" line is up: on the web, with no pad seen.
func pad_hint_shown() -> bool:
	return _pad_hint.visible


func _refresh_pad_hint() -> void:
	_pad_hint.visible = OS.has_feature("web") and not InputDeviceTracker.tracker().pad_connected()


func _focus_default() -> void:
	_focus(_campaign)


static func _add_button(parent: Control, button_name: String, text: String) -> Button:
	var b: Button = MenuKit.button(button_name, text)
	parent.add_child(b)
	return b
