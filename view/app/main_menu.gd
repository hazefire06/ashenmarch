class_name MainMenu
extends MenuScreen
## The first screen: the title and four buttons. Campaign, Settings and Quit
## are signals for the App; Skirmish has nothing behind it until Phase 9, so it
## opens a small note panel in place (with a Back) instead of a dead button.
## Quit is left off the Web build, where a page can't close itself.

## Campaign was pressed.
signal campaign_pressed
## Settings was pressed: the App shows the overlay.
signal settings_pressed
## Quit was pressed: the App closes the game.
signal quit_pressed

const TITLE: String = "Ashenmarch"
const TITLE_SIZE: int = 72
const SKIRMISH_NOTE: String = "Skirmish arrives in Phase 9."

var _buttons: VBoxContainer
var _skirmish: VBoxContainer
var _campaign: Button
var _skirmish_back: Button


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

	_buttons = VBoxContainer.new()
	_buttons.add_theme_constant_override("separation", 10)
	column.add_child(_buttons)
	_campaign = _add_button(_buttons, "CampaignButton", "Campaign")
	_campaign.pressed.connect(func() -> void: campaign_pressed.emit())
	var skirmish: Button = _add_button(_buttons, "SkirmishButton", "Skirmish")
	skirmish.pressed.connect(_show_skirmish.bind(true))
	var settings: Button = _add_button(_buttons, "SettingsButton", "Settings")
	settings.pressed.connect(func() -> void: settings_pressed.emit())
	var quit: Button = _add_button(_buttons, "QuitButton", "Quit")
	quit.pressed.connect(func() -> void: quit_pressed.emit())
	quit.visible = not OS.has_feature("web")

	_skirmish = VBoxContainer.new()
	_skirmish.name = "SkirmishPanel"
	_skirmish.add_theme_constant_override("separation", 20)
	_skirmish.visible = false
	column.add_child(_skirmish)
	var note: Label = MenuKit.label(SKIRMISH_NOTE, MenuKit.HEADING_SIZE, MenuKit.TEXT_COLOR)
	note.name = "SkirmishNote"
	note.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_skirmish.add_child(note)
	_skirmish_back = _add_button(_skirmish, "SkirmishBackButton", "Back")
	_skirmish_back.pressed.connect(_show_skirmish.bind(false))


## True while the Skirmish note is showing in place of the buttons.
func is_skirmish_open() -> bool:
	return _skirmish.visible


func _focus_default() -> void:
	_focus(_skirmish_back if _skirmish.visible else _campaign)


# Esc closes the Skirmish note; on the buttons it does nothing (there is no
# screen behind the main menu to go back to).
func _cancel() -> bool:
	if _skirmish.visible:
		_show_skirmish(false)
		return true
	return false


func _show_skirmish(shown: bool) -> void:
	_skirmish.visible = shown
	_buttons.visible = not shown
	_focus_default()


static func _add_button(parent: Control, button_name: String, text: String) -> Button:
	var b: Button = MenuKit.button(button_name, text)
	parent.add_child(b)
	return b
