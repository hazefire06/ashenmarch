extends GutTest
## Every front-end screen is reachable with a pad alone (Phase 11), from
## synthetic pad events sent as a real pad's are (PadEvents): the D-pad moves
## focus, A presses, B is Back, the shoulder buttons turn Settings' tabs, and
## the right stick scrolls a screen's scroll box.

const SETTINGS_DIR: String = "user://test_pad_menus"
const FRAME: float = 1.0 / 60.0

var _window_size: Vector2i


# Focus moves by where controls are on screen: the headless window's 64
# pixels square would pile the buttons up.
func before_all() -> void:
	_window_size = get_window().size
	get_window().size = Vector2i(1280, 720)


func after_all() -> void:
	get_window().size = _window_size


func before_each() -> void:
	InputBindings.install()
	InputBindings.reset(InputBindings.Preset.MODERN)


func after_each() -> void:
	PadEvents.release_all()
	await get_tree().process_frame
	if DirAccess.dir_exists_absolute(SETTINGS_DIR):
		for file_name: String in DirAccess.get_files_at(SETTINGS_DIR):
			DirAccess.remove_absolute(SETTINGS_DIR + "/" + file_name)
		DirAccess.remove_absolute(SETTINGS_DIR)


func test_the_main_menu_is_walked_with_the_d_pad_and_a() -> void:
	var menu: MainMenu = MainMenu.new()
	add_child_autofree(menu)
	await get_tree().process_frame  # the containers lay the buttons out
	watch_signals(menu)
	assert_eq(_focused().name, "CampaignButton", "focus starts on Campaign")
	PadEvents.tap(JOY_BUTTON_DPAD_DOWN)
	assert_eq(_focused().name, "SkirmishButton")
	PadEvents.tap(JOY_BUTTON_A)
	assert_signal_emitted(menu, "skirmish_pressed")


func test_the_left_stick_moves_focus_too() -> void:
	var menu: MainMenu = MainMenu.new()
	add_child_autofree(menu)
	await get_tree().process_frame
	PadEvents.left_stick(Vector2(0.0, 1.0))
	PadEvents.left_stick(Vector2.ZERO)
	assert_eq(_focused().name, "SkirmishButton")


func test_b_is_back_in_settings() -> void:
	var settings: SettingsMenu = SettingsMenu.new()
	settings.setup(SETTINGS_DIR + "/settings.cfg")
	add_child_autofree(settings)
	watch_signals(settings)
	PadEvents.tap(JOY_BUTTON_B)
	assert_signal_emitted(settings, "closed")


func test_the_shoulder_buttons_turn_settings_tabs() -> void:
	var settings: SettingsMenu = SettingsMenu.new()
	settings.setup(SETTINGS_DIR + "/settings.cfg")
	add_child_autofree(settings)
	var tabs: TabContainer = MenuFixtures.named(settings, "Tabs") as TabContainer
	assert_eq(tabs.current_tab, 0)
	PadEvents.tap(JOY_BUTTON_RIGHT_SHOULDER)
	assert_eq(tabs.current_tab, 1)
	assert_true(tabs.get_current_tab_control().is_ancestor_of(_focused()), "focus went into the new tab")
	PadEvents.tap(JOY_BUTTON_LEFT_SHOULDER)
	PadEvents.tap(JOY_BUTTON_LEFT_SHOULDER)
	assert_eq(tabs.current_tab, tabs.get_tab_count() - 1, "and wrap round")


func test_an_option_button_opens_with_a_and_closes_with_b() -> void:
	var settings: SettingsMenu = SettingsMenu.new()
	settings.setup(SETTINGS_DIR + "/settings.cfg")
	add_child_autofree(settings)
	var choice: OptionButton = MenuFixtures.named(settings, "MaxFps") as OptionButton
	choice.grab_focus()
	PadEvents.tap(JOY_BUTTON_A)
	await get_tree().process_frame
	assert_true(choice.get_popup().visible, "A opens it")
	PadEvents.tap(JOY_BUTTON_B)
	await get_tree().process_frame
	assert_false(choice.get_popup().visible, "B closes it")


func test_the_right_stick_scrolls_a_screens_scroll_box() -> void:
	var settings: SettingsMenu = SettingsMenu.new()
	settings.setup(SETTINGS_DIR + "/settings.cfg")
	add_child_autofree(settings)
	var tabs: TabContainer = MenuFixtures.named(settings, "Tabs") as TabContainer
	tabs.current_tab = tabs.get_tab_count() - 1  # Controls: a long list
	await get_tree().process_frame
	var scroller: ScrollContainer = settings.scroll_box()
	assert_not_null(scroller)
	PadEvents.right_stick(Vector2(0.0, 1.0))
	for i: int in 10:
		settings._process(FRAME)
	PadEvents.right_stick(Vector2.ZERO)
	assert_gt(scroller.scroll_vertical, 0, "down the list")


func _focused() -> Control:
	return get_viewport().gui_get_focus_owner()
