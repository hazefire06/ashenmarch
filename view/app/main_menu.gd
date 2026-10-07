class_name MainMenu
extends MenuScreen
## The first screen: the title and four buttons. Each is a signal for the App,
## which decides what opens next: the campaign menu, the skirmish setup, the
## Settings overlay, or the end of the game.
## Quit is left off the Web build, where a page can't close itself.

## Campaign was pressed.
signal campaign_pressed
## Skirmish was pressed: the App shows the skirmish setup.
signal skirmish_pressed
## Settings was pressed: the App shows the overlay.
signal settings_pressed
## Quit was pressed: the App closes the game.
signal quit_pressed

const TITLE: String = "Ashenmarch"
const TITLE_SIZE: int = 72

var _campaign: Button


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
	var settings: Button = _add_button(buttons, "SettingsButton", "Settings")
	settings.pressed.connect(func() -> void: settings_pressed.emit())
	var quit: Button = _add_button(buttons, "QuitButton", "Quit")
	quit.pressed.connect(func() -> void: quit_pressed.emit())
	quit.visible = not OS.has_feature("web")


func _focus_default() -> void:
	_focus(_campaign)


static func _add_button(parent: Control, button_name: String, text: String) -> Button:
	var b: Button = MenuKit.button(button_name, text)
	parent.add_child(b)
	return b
