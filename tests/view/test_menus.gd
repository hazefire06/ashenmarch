extends GutTest
## The small front-end screens: the main menu, the campaign menu (Continue, the
## difficulty select, the replace-your-save question), the Settings overlay, and
## the yes/no dialog. Each is built alone from fixtures; the App's wiring of
## them is test_app. (The skirmish screens have their own files.)

const SETTINGS_DIR: String = "user://test_menus"

var _campaign: CampaignDef


func before_all() -> void:
	_campaign = MenuFixtures.campaign()


func after_each() -> void:
	# A dialog its owner closed is queue_free'd; let the frame free it.
	await get_tree().process_frame
	if DirAccess.dir_exists_absolute(SETTINGS_DIR):
		for file_name: String in DirAccess.get_files_at(SETTINGS_DIR):
			DirAccess.remove_absolute(SETTINGS_DIR + "/" + file_name)
		DirAccess.remove_absolute(SETTINGS_DIR)


func _key(keycode: Key) -> void:
	var event: InputEventKey = InputEventKey.new()
	event.physical_keycode = keycode
	event.pressed = true
	get_viewport().push_input(event)


func _button(root: Node, button_name: String) -> Button:
	return MenuFixtures.named(root, button_name) as Button


# --- main menu ----------------------------------------------------------------


func _main_menu() -> MainMenu:
	var menu: MainMenu = MainMenu.new()
	add_child_autofree(menu)
	return menu


func test_the_main_menu_shows_the_title_and_four_buttons() -> void:
	var menu: MainMenu = _main_menu()
	assert_true(MenuFixtures.says(menu, "Ashenmarch"))
	for pair: Array in [["CampaignButton", "Campaign"], ["SkirmishButton", "Skirmish"], ["SettingsButton", "Settings"], ["QuitButton", "Quit"]]:
		assert_eq(_button(menu, pair[0]).text, pair[1])
		assert_true(_button(menu, pair[0]).visible)


func test_campaign_skirmish_settings_and_quit_are_signals() -> void:
	var menu: MainMenu = _main_menu()
	watch_signals(menu)
	MenuFixtures.press(menu, "CampaignButton")
	MenuFixtures.press(menu, "SkirmishButton")
	MenuFixtures.press(menu, "SettingsButton")
	MenuFixtures.press(menu, "QuitButton")
	assert_signal_emit_count(menu, "campaign_pressed", 1)
	assert_signal_emit_count(menu, "skirmish_pressed", 1)
	assert_signal_emit_count(menu, "settings_pressed", 1)
	assert_signal_emit_count(menu, "quit_pressed", 1)


func test_skirmish_is_a_signal_for_the_app_and_opens_nothing_in_place() -> void:
	var menu: MainMenu = _main_menu()
	MenuFixtures.press(menu, "SkirmishButton")
	assert_true(_button(menu, "CampaignButton").is_visible_in_tree(), "the buttons stay: the App changes the screen")
	assert_null(MenuFixtures.named(menu, "SkirmishPanel"), "the Phase 8 stub note is gone")
	assert_false(MenuFixtures.mentions(menu, "Phase 9"))


func test_esc_on_the_main_menu_does_nothing_and_never_quits() -> void:
	var menu: MainMenu = _main_menu()
	watch_signals(menu)
	_key(KEY_ESCAPE)
	assert_signal_not_emitted(menu, "quit_pressed", "Esc never quits")
	assert_signal_not_emitted(menu, "campaign_pressed")
	assert_signal_not_emitted(menu, "skirmish_pressed")
	assert_true(_button(menu, "CampaignButton").is_visible_in_tree())


func test_the_main_menu_hides_what_is_under_it_and_starts_on_campaign() -> void:
	var menu: MainMenu = _main_menu()
	assert_true(menu.is_opaque())
	await get_tree().process_frame
	assert_eq(get_viewport().gui_get_focus_owner(), _button(menu, "CampaignButton"))


# --- confirm dialog -----------------------------------------------------------


func _dialog() -> ConfirmDialog:
	var dialog: ConfirmDialog = ConfirmDialog.new()
	dialog.setup("Really?", "Do it", "Never mind")
	add_child_autofree(dialog)
	return dialog


func test_the_dialog_asks_and_its_buttons_answer() -> void:
	var dialog: ConfirmDialog = _dialog()
	assert_eq((MenuFixtures.named(dialog, "Question") as Label).text, "Really?")
	assert_eq(_button(dialog, "ConfirmButton").text, "Do it")
	assert_eq(_button(dialog, "CancelButton").text, "Never mind")
	assert_false(dialog.is_opaque(), "it shows over what is beneath")
	watch_signals(dialog)
	MenuFixtures.press(dialog, "ConfirmButton")
	MenuFixtures.press(dialog, "CancelButton")
	assert_signal_emit_count(dialog, "confirmed", 1)
	assert_signal_emit_count(dialog, "cancelled", 1)


func test_the_dialog_starts_on_the_safe_answer_and_esc_is_that_answer() -> void:
	var dialog: ConfirmDialog = _dialog()
	await get_tree().process_frame
	assert_eq(get_viewport().gui_get_focus_owner(), _button(dialog, "CancelButton"))
	watch_signals(dialog)
	_key(KEY_ESCAPE)
	assert_signal_emit_count(dialog, "cancelled", 1)
	assert_signal_not_emitted(dialog, "confirmed")


# --- settings -----------------------------------------------------------------


func _settings(path: String) -> SettingsMenu:
	var menu: SettingsMenu = SettingsMenu.new()
	menu.setup(path)
	add_child_autofree(menu)
	return menu


func test_settings_shows_the_saved_choices() -> void:
	var path: String = SETTINGS_DIR + "/settings.cfg"
	GameSettings.set_fullscreen(true, path)
	var menu: SettingsMenu = _settings(path)
	assert_true((MenuFixtures.named(menu, "FullscreenCheck") as CheckBox).button_pressed)
	assert_false((MenuFixtures.named(menu, "EdgeScrollCheck") as CheckBox).button_pressed)
	assert_eq((MenuFixtures.named(menu, "FullscreenCheck") as CheckBox).text, "Fullscreen")
	assert_eq((MenuFixtures.named(menu, "EdgeScrollCheck") as CheckBox).text, "Edge scroll")


func test_a_toggle_is_saved_at_once_and_announced() -> void:
	var path: String = SETTINGS_DIR + "/settings.cfg"
	var menu: SettingsMenu = _settings(path)
	watch_signals(menu)
	(MenuFixtures.named(menu, "EdgeScrollCheck") as CheckBox).button_pressed = true
	assert_true(GameSettings.edge_scroll(path), "in the file already")
	assert_false(GameSettings.fullscreen(path))
	assert_signal_emit_count(menu, "changed", 1)
	(MenuFixtures.named(menu, "FullscreenCheck") as CheckBox).button_pressed = true
	assert_true(GameSettings.fullscreen(path))
	assert_signal_emit_count(menu, "changed", 2)
	(MenuFixtures.named(menu, "EdgeScrollCheck") as CheckBox).button_pressed = false
	assert_false(GameSettings.edge_scroll(path))


func test_settings_back_and_esc_close_it() -> void:
	var menu: SettingsMenu = _settings(SETTINGS_DIR + "/settings.cfg")
	assert_false(menu.is_opaque(), "an overlay, so it can sit over a paused mission")
	watch_signals(menu)
	MenuFixtures.press(menu, "BackButton")
	_key(KEY_ESCAPE)
	assert_signal_emit_count(menu, "closed", 2)


func test_a_failed_save_is_told_and_the_choice_is_not_applied() -> void:
	# A file where the directory should be, so the write fails.
	DirAccess.make_dir_recursive_absolute(SETTINGS_DIR)
	var blocker: FileAccess = FileAccess.open(SETTINGS_DIR + "/blocker", FileAccess.WRITE)
	blocker.store_string("x")
	blocker.close()
	var path: String = SETTINGS_DIR + "/blocker/settings.cfg"
	var menu: SettingsMenu = _settings(path)
	watch_signals(menu)
	var edge: CheckBox = MenuFixtures.named(menu, "EdgeScrollCheck") as CheckBox
	edge.button_pressed = true
	var error: Label = MenuFixtures.named(menu, "SaveError") as Label
	assert_true(error.visible)
	assert_string_contains(error.text, "not applied")
	assert_false(error.text.contains("until you quit"), "the old, untrue promise is gone")
	assert_signal_emit_count(menu, "changed", 0, "nothing changed, so nothing is applied")
	assert_false(edge.button_pressed, "the box shows what is in force: unchanged")
	assert_false(GameSettings.edge_scroll(path), "and what the App would read")
	# The same for Fullscreen, and a good save afterwards clears the message.
	var full: CheckBox = MenuFixtures.named(menu, "FullscreenCheck") as CheckBox
	full.button_pressed = true
	assert_false(full.button_pressed)
	assert_signal_emit_count(menu, "changed", 0)


func test_a_good_save_after_a_failed_one_clears_the_message() -> void:
	DirAccess.make_dir_recursive_absolute(SETTINGS_DIR)
	var menu: SettingsMenu = _settings(SETTINGS_DIR + "/settings.cfg")
	var error: Label = MenuFixtures.named(menu, "SaveError") as Label
	error.visible = true
	(MenuFixtures.named(menu, "EdgeScrollCheck") as CheckBox).button_pressed = true
	assert_false(error.visible)


# --- campaign menu ------------------------------------------------------------


func _campaign_menu(saved: CampaignState, file_exists: bool, problem: String = "") -> CampaignMenu:
	var menu: CampaignMenu = CampaignMenu.new()
	menu.setup(_campaign, saved, file_exists, problem)
	add_child_autofree(menu)
	return menu


func _detail(menu: CampaignMenu) -> String:
	return (MenuFixtures.named(menu, "ContinueDetail") as Label).text


func test_continue_is_off_without_a_save() -> void:
	var menu: CampaignMenu = _campaign_menu(null, false)
	assert_true(_button(menu, "ContinueButton").disabled)
	assert_eq(_detail(menu), "No saved campaign.")


func test_continue_shows_the_next_mission_and_difficulty() -> void:
	var saved: CampaignState = CampaignState.new_campaign(1, 2)
	var menu: CampaignMenu = _campaign_menu(saved, true)
	assert_false(_button(menu, "ContinueButton").disabled)
	assert_eq(_detail(menu), "Next: Riverside (Normal)")
	saved.mission_index = 1
	saved.tier = 4
	assert_eq(_detail(_campaign_menu(saved, true)), "Next: The Ford (Brutal)")


func test_a_finished_campaign_can_still_be_continued_to_its_roll() -> void:
	var saved: CampaignState = CampaignState.new_campaign(1, 3)
	saved.mission_index = _campaign.missions.size()
	var menu: CampaignMenu = _campaign_menu(saved, true)
	assert_false(_button(menu, "ContinueButton").disabled)
	assert_eq(_detail(menu), "Campaign complete (Hard)")


func test_a_save_that_cannot_be_used_turns_continue_off_and_says_why() -> void:
	var menu: CampaignMenu = _campaign_menu(null, true, "unsupported save version (this build reads version 1)")
	assert_true(_button(menu, "ContinueButton").disabled)
	assert_string_contains(_detail(menu), "unsupported save version")


func test_continue_and_back_are_signals() -> void:
	var menu: CampaignMenu = _campaign_menu(CampaignState.new_campaign(1, 2), true)
	watch_signals(menu)
	MenuFixtures.press(menu, "ContinueButton")
	MenuFixtures.press(menu, "BackButton")
	assert_signal_emit_count(menu, "continue_pressed", 1)
	assert_signal_emit_count(menu, "back_pressed", 1)


func test_esc_goes_back_from_the_menu() -> void:
	var menu: CampaignMenu = _campaign_menu(null, false)
	watch_signals(menu)
	_key(KEY_ESCAPE)
	assert_signal_emit_count(menu, "back_pressed", 1)


func test_new_campaign_opens_the_five_tiers_with_normal_chosen() -> void:
	var menu: CampaignMenu = _campaign_menu(null, false)
	assert_false(menu.is_difficulty_open())
	MenuFixtures.press(menu, "NewCampaignButton")
	assert_true(menu.is_difficulty_open())
	var names: Array[String] = []
	for tier: int in 5:
		names.append(_button(menu, "Tier%d" % tier).text)
	assert_eq(names, ["Easy", "Moderate", "Normal", "Hard", "Brutal"])
	assert_eq(menu.selected_tier(), 2, "Normal is tier 2 and the default")
	assert_true(_button(menu, "Tier2").button_pressed)
	assert_false(_button(menu, "Tier0").button_pressed)


func test_choosing_a_tier_and_beginning_requests_that_campaign() -> void:
	var menu: CampaignMenu = _campaign_menu(null, false)
	MenuFixtures.press(menu, "NewCampaignButton")
	watch_signals(menu)
	MenuFixtures.press(menu, "BeginButton")
	assert_signal_emit_count(menu, "new_campaign_requested", 1)
	assert_eq(get_signal_parameters(menu, "new_campaign_requested"), [2], "Normal by default")
	_button(menu, "Tier4").button_pressed = true
	assert_eq(menu.selected_tier(), 4)
	assert_false(_button(menu, "Tier2").button_pressed, "one tier at a time")
	MenuFixtures.press(menu, "BeginButton")
	assert_eq(get_signal_parameters(menu, "new_campaign_requested"), [4])


func test_with_a_save_beginning_asks_first_and_names_what_is_replaced() -> void:
	var menu: CampaignMenu = _campaign_menu(CampaignState.new_campaign(1, 3), true)
	MenuFixtures.press(menu, "NewCampaignButton")
	watch_signals(menu)
	MenuFixtures.press(menu, "BeginButton")
	assert_true(menu.is_confirming())
	assert_signal_not_emitted(menu, "new_campaign_requested", "not until the question is answered yes")
	var question: Label = MenuFixtures.named(menu, "Question") as Label
	assert_string_contains(question.text, "Riverside (Hard)")
	MenuFixtures.press(menu, "ConfirmButton")
	assert_false(menu.is_confirming())
	assert_signal_emit_count(menu, "new_campaign_requested", 1)
	assert_eq(get_signal_parameters(menu, "new_campaign_requested"), [2])


func test_declining_the_replacement_keeps_the_difficulty_select_and_requests_nothing() -> void:
	var menu: CampaignMenu = _campaign_menu(CampaignState.new_campaign(1, 3), true)
	MenuFixtures.press(menu, "NewCampaignButton")
	watch_signals(menu)
	MenuFixtures.press(menu, "BeginButton")
	MenuFixtures.press(menu, "CancelButton")
	assert_false(menu.is_confirming())
	assert_true(menu.is_difficulty_open())
	assert_signal_not_emitted(menu, "new_campaign_requested")


func test_esc_answers_the_replacement_question_no_and_then_closes_the_select() -> void:
	var menu: CampaignMenu = _campaign_menu(CampaignState.new_campaign(1, 3), true)
	MenuFixtures.press(menu, "NewCampaignButton")
	watch_signals(menu)
	MenuFixtures.press(menu, "BeginButton")
	_key(KEY_ESCAPE)
	assert_false(menu.is_confirming(), "Esc is the safe answer")
	assert_true(menu.is_difficulty_open())
	_key(KEY_ESCAPE)
	assert_false(menu.is_difficulty_open())
	assert_signal_not_emitted(menu, "new_campaign_requested")
	assert_signal_not_emitted(menu, "back_pressed", "the first Esc only leaves the select")


func test_an_unreadable_save_is_asked_about_too_and_a_finished_one_is_named() -> void:
	var broken: CampaignMenu = _campaign_menu(null, true, "the save is not valid JSON")
	MenuFixtures.press(broken, "NewCampaignButton")
	MenuFixtures.press(broken, "BeginButton")
	assert_true(broken.is_confirming(), "the file would still be overwritten")
	assert_string_contains((MenuFixtures.named(broken, "Question") as Label).text, "can't be read")
	var finished: CampaignState = CampaignState.new_campaign(1, 1)
	finished.mission_index = _campaign.missions.size()
	var menu: CampaignMenu = _campaign_menu(finished, true)
	MenuFixtures.press(menu, "NewCampaignButton")
	MenuFixtures.press(menu, "BeginButton")
	assert_string_contains((MenuFixtures.named(menu, "Question") as Label).text, "finished campaign (Moderate)")


func test_the_keyboard_starts_on_continue_or_new_campaign() -> void:
	var with_save: CampaignMenu = _campaign_menu(CampaignState.new_campaign(1, 2), true)
	await get_tree().process_frame
	assert_eq(get_viewport().gui_get_focus_owner(), _button(with_save, "ContinueButton"))
	var without: CampaignMenu = _campaign_menu(null, false)
	await get_tree().process_frame
	assert_eq(get_viewport().gui_get_focus_owner(), _button(without, "NewCampaignButton"), "Continue is off")
