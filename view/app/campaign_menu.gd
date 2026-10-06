class_name CampaignMenu
extends MenuScreen
## Campaign: Continue, New Campaign, Back.
## - Continue is on only if there is a save that can be read and still fits this
##   campaign, and says what it would play next (mission and difficulty).
##   A save that is there but can't be used says why instead.
## - New Campaign opens the difficulty select in place: the five tiers as a
##   radio row, Normal chosen. Beginning asks first if a save exists, since it
##   is replaced.
## It reads nothing itself: the App hands it the save (already loaded) and says
## whether a file exists, so the menu can be built from a fixture.

## Continue was pressed: load the save and go to the next mission's briefing.
signal continue_pressed
## A difficulty was chosen (and the replacement confirmed, if there was a save).
signal new_campaign_requested(tier: int)
## Back or Esc (from the menu; from the difficulty select Esc only closes it).
signal back_pressed

var _campaign: CampaignDef
var _saved: CampaignState
var _file_exists: bool = false
var _main: VBoxContainer
var _difficulty: VBoxContainer
var _continue: Button
var _new_campaign: Button
var _tier_buttons: Array[Button] = []
var _begin: Button
var _confirm: ConfirmDialog


## Builds the menu. `saved` is the loaded save or null; `file_exists` says
## whether a file is there at all (a replace needs asking about even when the
## file is unreadable); `problem` is why a file that exists couldn't be used.
func setup(campaign: CampaignDef, saved: CampaignState, file_exists: bool, problem: String = "") -> void:
	_campaign = campaign
	_saved = saved
	_file_exists = file_exists
	var center: CenterContainer = CenterContainer.new()
	center.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(center)
	var column: VBoxContainer = VBoxContainer.new()
	column.add_theme_constant_override("separation", 24)
	center.add_child(column)
	var heading: Label = MenuKit.title("Campaign")
	heading.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	column.add_child(heading)
	_main = VBoxContainer.new()
	_main.add_theme_constant_override("separation", 10)
	column.add_child(_main)
	_build_main(problem)
	_difficulty = VBoxContainer.new()
	_difficulty.name = "DifficultyPanel"
	_difficulty.add_theme_constant_override("separation", 10)
	_difficulty.visible = false
	column.add_child(_difficulty)
	_build_difficulty()
	if is_inside_tree():
		_focus_default()


## True while the difficulty select is showing.
func is_difficulty_open() -> bool:
	return _difficulty != null and _difficulty.visible


## True while the "replace your save?" question is up.
func is_confirming() -> bool:
	return _confirm != null


## The tier whose radio button is on: Normal until the player picks another.
func selected_tier() -> int:
	for i: int in _tier_buttons.size():
		if _tier_buttons[i].button_pressed:
			return i
	return MenuKit.DEFAULT_TIER


func _focus_default() -> void:
	if _confirm != null:
		return
	if is_difficulty_open():
		_focus(_tier_buttons[selected_tier()])
	else:
		_focus(_continue if not _continue.disabled else _new_campaign)


func _cancel() -> bool:
	if is_difficulty_open():
		_show_difficulty(false)
	else:
		back_pressed.emit()
	return true


func _build_main(problem: String) -> void:
	_continue = MenuKit.button("ContinueButton", "Continue")
	_continue.disabled = _saved == null
	_continue.pressed.connect(func() -> void: continue_pressed.emit())
	_main.add_child(_continue)
	var detail: Label = MenuKit.paragraph(_continue_detail(problem), 14, MenuKit.MUTED_COLOR)
	detail.name = "ContinueDetail"
	detail.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	detail.custom_minimum_size.x = MenuKit.BUTTON_WIDTH
	if _saved == null and problem != "":
		detail.add_theme_color_override("font_color", MenuKit.WARN_COLOR)
	_main.add_child(detail)
	_new_campaign = MenuKit.button("NewCampaignButton", "New Campaign")
	_new_campaign.pressed.connect(_show_difficulty.bind(true))
	_main.add_child(_new_campaign)
	var back: Button = MenuKit.button("BackButton", "Back")
	back.pressed.connect(func() -> void: back_pressed.emit())
	_main.add_child(back)


# What Continue would do, in words.
func _continue_detail(problem: String) -> String:
	if _saved == null:
		if problem != "":
			return "The saved campaign can't be used: %s." % problem
		return "No saved campaign."
	var tier: String = MenuKit.tier_name(_saved.tier)
	if _saved.is_complete(_campaign):
		return "Campaign complete (%s)" % tier
	return "Next: %s (%s)" % [_campaign.missions[_saved.mission_index].display_name, tier]


func _build_difficulty() -> void:
	var heading: Label = MenuKit.label("Difficulty", MenuKit.HEADING_SIZE, MenuKit.TEXT_COLOR)
	heading.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_difficulty.add_child(heading)
	var group: ButtonGroup = ButtonGroup.new()
	for tier: int in Difficulty.TIERS:
		var b: Button = MenuKit.button("Tier%d" % tier, MenuKit.tier_name(tier))
		b.toggle_mode = true
		b.button_group = group
		b.button_pressed = tier == MenuKit.DEFAULT_TIER
		MenuKit.style_selected(b)
		_tier_buttons.append(b)
		_difficulty.add_child(b)
	var hint: Label = MenuKit.paragraph(
		"Harder tiers bring more enemies, in different places, on shorter timers. It holds for the whole campaign.",
		14, MenuKit.MUTED_COLOR
	)
	hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	hint.custom_minimum_size.x = MenuKit.BUTTON_WIDTH
	_difficulty.add_child(hint)
	_begin = MenuKit.button("BeginButton", "Begin campaign")
	_begin.pressed.connect(_begin_pressed)
	_difficulty.add_child(_begin)
	var back: Button = MenuKit.button("DifficultyBackButton", "Back")
	back.pressed.connect(_show_difficulty.bind(false))
	_difficulty.add_child(back)


func _show_difficulty(shown: bool) -> void:
	_difficulty.visible = shown
	_main.visible = not shown
	_focus_default()


func _begin_pressed() -> void:
	if not _file_exists:
		new_campaign_requested.emit(selected_tier())
		return
	_confirm = ConfirmDialog.new()
	_confirm.name = "ReplaceConfirm"
	add_child(_confirm)
	_confirm.setup(_replace_question(), "Replace it", "Keep it")
	_confirm.confirmed.connect(func() -> void:
		_close_confirm()
		new_campaign_requested.emit(selected_tier())
	)
	_confirm.cancelled.connect(func() -> void:
		_close_confirm()
		_focus_default()
	)


func _replace_question() -> String:
	if _saved == null:
		return "Start a new campaign?\nThe saved campaign can't be read and will be replaced."
	if _saved.is_complete(_campaign):
		return "Start a new campaign?\nThis replaces your finished campaign (%s)." % MenuKit.tier_name(_saved.tier)
	return "Start a new campaign?\nThis replaces your saved campaign: %s (%s)." % [
		_campaign.missions[_saved.mission_index].display_name, MenuKit.tier_name(_saved.tier)
	]


func _close_confirm() -> void:
	if _confirm == null:
		return
	remove_child(_confirm)
	_confirm.queue_free()
	_confirm = null
