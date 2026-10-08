extends GutTest
## Phase 10's settings: GameSettings' display, audio and controls keys (with
## their defaults and refusals of bad values), applying them to the engine,
## and the Settings overlay's tabs: rebinding by capture, a swap when the key
## is taken, a group key refused, the group modifiers, Reset all, and the
## display and audio controls saving as they move.

const DIR: String = "user://test_settings_tabs"

var _path: String = DIR + "/settings.cfg"


func before_each() -> void:
	_clean()
	InputBindings.install()
	InputBindings.reset()


func after_each() -> void:
	_clean()
	InputBindings.reset()
	GameSettings.apply_audio(DIR + "/none.cfg")
	get_window().content_scale_factor = 1.0
	get_window().scaling_3d_scale = 1.0
	Engine.max_fps = 0


func _clean() -> void:
	if DirAccess.dir_exists_absolute(DIR):
		for file_name: String in DirAccess.get_files_at(DIR):
			DirAccess.remove_absolute(DIR + "/" + file_name)
		DirAccess.remove_absolute(DIR)


func _write(text: String) -> void:
	DirAccess.make_dir_recursive_absolute(DIR)
	var file: FileAccess = FileAccess.open(_path, FileAccess.WRITE)
	file.store_string(text)
	file.close()


func _menu() -> SettingsMenu:
	var menu: SettingsMenu = SettingsMenu.new()
	menu.setup(_path)
	add_child_autofree(menu)
	return menu


func _key(keycode: Key) -> InputEventKey:
	var event: InputEventKey = InputEventKey.new()
	event.physical_keycode = keycode
	return event


func test_the_new_settings_default_sensibly() -> void:
	assert_eq(GameSettings.window_size(_path), GameSettings.WINDOW_SIZE_DEFAULT)
	assert_true(GameSettings.vsync(_path))
	assert_eq(GameSettings.max_fps(_path), 0)
	assert_eq(GameSettings.render_scale(_path), 100)
	assert_eq(GameSettings.ui_scale(_path), 0, "Auto")
	assert_eq(GameSettings.volume("Master", _path), 80)
	assert_eq(GameSettings.volume("Effects", _path), 100)
	assert_eq(GameSettings.keybinds(_path), {} as Dictionary[StringName, InputEvent])
	assert_eq(GameSettings.group_modifiers(_path), [0, 1] as Array[int])


func test_bad_values_read_as_the_defaults() -> void:
	_write("[display]\nwindow_size=99\nmax_fps=45\nrender_scale=10\nui_scale=\"big\"\n"
		+ "[audio]\nmaster=300\n[controls]\ngroup_save_modifier=1\ngroup_recall_modifier=1\n"
		+ "[keybinds]\nunit_ability=\"key:NoSuchKey\"\ndebug_toggle_ai=\"key:G\"\nunit_stop=\"key:K\"\n")
	assert_eq(GameSettings.window_size(_path), GameSettings.WINDOW_SIZE_DEFAULT)
	assert_eq(GameSettings.max_fps(_path), 0)
	assert_eq(GameSettings.render_scale(_path), 100)
	assert_eq(GameSettings.ui_scale(_path), 0)
	assert_eq(GameSettings.volume("Master", _path), 80)
	assert_eq(GameSettings.group_modifiers(_path), [0, 1] as Array[int], "equal modifiers fall back")
	var bound: Dictionary[StringName, InputEvent] = GameSettings.keybinds(_path)
	assert_eq(bound.keys(), [InputBindings.STOP], "only the good, rebindable line")


func test_controls_apply_and_clear() -> void:
	GameSettings.set_keybinds({InputBindings.ABILITY: _key(KEY_G)} as Dictionary[StringName, InputEvent], _path)
	GameSettings.set_group_modifiers(InputBindings.GroupModifier.SHIFT, InputBindings.GroupModifier.ALT, _path)
	GameSettings.apply_bindings(_path)
	assert_eq(InputBindings.label_for(InputBindings.ABILITY), "G")
	assert_eq(InputBindings.event_to_text(InputBindings.event_of(InputBindings.GROUP_SAVES[0])), "key:1+shift")
	GameSettings.set_edge_scroll(true, _path)
	assert_eq(GameSettings.clear_controls(_path), OK)
	GameSettings.apply_bindings(_path)
	assert_eq(InputBindings.label_for(InputBindings.ABILITY), "T")
	assert_true(GameSettings.edge_scroll(_path), "other settings survive a reset")


func test_display_and_audio_apply_to_the_engine() -> void:
	GameSettings.set_display(GameSettings.UI_SCALE, 150, _path)
	GameSettings.set_display(GameSettings.RENDER_SCALE, 70, _path)
	GameSettings.set_display(GameSettings.MAX_FPS, 60, _path)
	GameSettings.set_volume("Effects", 0, _path)
	GameSettings.set_volume("Master", 50, _path)
	GameSettings.apply_display(get_window(), false, _path)
	GameSettings.apply_audio(_path)
	assert_almost_eq(get_window().content_scale_factor, 1.5, 0.001)
	assert_almost_eq(get_window().scaling_3d_scale, 0.7, 0.001)
	assert_eq(Engine.max_fps, 60)
	assert_true(AudioServer.is_bus_mute(AudioServer.get_bus_index("Effects")), "0 % mutes")
	assert_almost_eq(AudioServer.get_bus_volume_db(AudioServer.get_bus_index("Master")), linear_to_db(0.5), 0.01)


func test_auto_interface_scale_is_the_screens() -> void:
	assert_eq(GameSettings.resolved_ui_scale(0), clampf(DisplayServer.screen_get_scale(), 1.0, 3.0))
	assert_eq(GameSettings.resolved_ui_scale(125), 1.25)


func test_the_bus_layout_has_the_four_buses() -> void:
	for bus: String in GameSettings.VOLUMES_DEFAULT:
		assert_gt(AudioServer.get_bus_index(bus), -1, bus)


func test_the_overlay_has_three_tabs_and_the_old_controls() -> void:
	var menu: SettingsMenu = _menu()
	var tabs: TabContainer = MenuFixtures.named(menu, "Tabs") as TabContainer
	assert_eq(tabs.get_tab_count(), 3)
	assert_not_null(MenuFixtures.named(menu, "FullscreenCheck"))
	assert_not_null(MenuFixtures.named(menu, "EdgeScrollCheck"))
	assert_eq((MenuFixtures.named(menu, "Bind_unit_stop") as Button).text, "Space")


func test_a_key_is_bound_by_pressing_it() -> void:
	var menu: SettingsMenu = _menu()
	watch_signals(menu)
	MenuFixtures.press(menu, "Bind_unit_ability")
	assert_true(menu.is_capturing())
	assert_eq((MenuFixtures.named(menu, "Bind_unit_ability") as Button).text, SettingsMenu.PRESS_A_KEY)
	var press: InputEventKey = _key(KEY_G)
	press.pressed = true
	menu._input(press)
	assert_false(menu.is_capturing())
	assert_eq(InputBindings.label_for(InputBindings.ABILITY), "G")
	assert_eq(GameSettings.keybinds(_path).get(InputBindings.ABILITY).physical_keycode, KEY_G, "saved")
	assert_signal_emitted(menu, "changed")
	assert_eq((MenuFixtures.named(menu, "Bind_unit_ability") as Button).text, "G")


func test_modifier_keys_alone_and_esc_do_not_bind() -> void:
	var menu: SettingsMenu = _menu()
	menu.capture(InputBindings.ABILITY)
	var shift: InputEventKey = _key(KEY_SHIFT)
	shift.pressed = true
	menu._input(shift)
	assert_true(menu.is_capturing(), "still waiting for the key itself")
	var esc: InputEventKey = _key(KEY_ESCAPE)
	esc.pressed = true
	menu._input(esc)
	assert_false(menu.is_capturing())
	assert_eq(InputBindings.label_for(InputBindings.ABILITY), "T", "unchanged")


func test_a_taken_key_swaps() -> void:
	var menu: SettingsMenu = _menu()
	menu.capture(InputBindings.ABILITY)
	menu.bind_captured(_key(KEY_SPACE))
	assert_eq(InputBindings.label_for(InputBindings.ABILITY), "Space")
	assert_eq(InputBindings.label_for(InputBindings.STOP), "T", "Stop took the old key")
	assert_string_contains((MenuFixtures.named(menu, "Note") as Label).text, "Stop")
	var saved: Dictionary[StringName, InputEvent] = GameSettings.keybinds(_path)
	assert_eq(saved.size(), 2, "both saved")


func test_a_group_key_is_refused() -> void:
	var menu: SettingsMenu = _menu()
	menu.capture(InputBindings.ABILITY)
	var cmd_one: InputEventKey = _key(KEY_1)
	cmd_one.command_or_control_autoremap = true
	menu.bind_captured(cmd_one)
	assert_eq(InputBindings.label_for(InputBindings.ABILITY), "T")
	assert_string_contains((MenuFixtures.named(menu, "Note") as Label).text, "group")
	assert_eq(GameSettings.keybinds(_path), {} as Dictionary[StringName, InputEvent])


func test_group_modifiers_must_differ_and_reset_all_restores() -> void:
	var menu: SettingsMenu = _menu()
	var save: OptionButton = MenuFixtures.named(menu, "SaveModifier") as OptionButton
	save.select(InputBindings.GroupModifier.ALT)
	save.item_selected.emit(InputBindings.GroupModifier.ALT)
	assert_eq(save.selected, InputBindings.GroupModifier.COMMAND_OR_CONTROL, "the same as recall is refused")
	save.select(InputBindings.GroupModifier.SHIFT)
	save.item_selected.emit(InputBindings.GroupModifier.SHIFT)
	assert_eq(GameSettings.group_modifiers(_path), [2, 1] as Array[int])
	assert_eq(InputBindings.event_to_text(InputBindings.event_of(InputBindings.GROUP_SAVES[4])), "key:5+shift")
	menu.capture(InputBindings.STOP)
	menu.bind_captured(_key(KEY_K))
	MenuFixtures.press(menu, "ResetControls")
	assert_eq(InputBindings.label_for(InputBindings.STOP), "Space")
	assert_eq(InputBindings.event_to_text(InputBindings.event_of(InputBindings.GROUP_SAVES[4])), "key:5+cmdorctrl")
	assert_eq(save.selected, InputBindings.GroupModifier.COMMAND_OR_CONTROL)
	assert_eq(GameSettings.keybinds(_path), {} as Dictionary[StringName, InputEvent])


func test_display_and_audio_controls_save_as_they_move() -> void:
	var menu: SettingsMenu = _menu()
	(MenuFixtures.named(menu, "RenderScale") as HSlider).value = 75
	assert_eq(GameSettings.render_scale(_path), 75)
	(MenuFixtures.named(menu, "EffectsVolume") as HSlider).value = 40
	assert_eq(GameSettings.volume("Effects", _path), 40)
	var cap: OptionButton = MenuFixtures.named(menu, "MaxFps") as OptionButton
	cap.select(2)
	cap.item_selected.emit(2)
	assert_eq(GameSettings.max_fps(_path), 60)
	var ui: OptionButton = MenuFixtures.named(menu, "UiScale") as OptionButton
	ui.select(4)
	ui.item_selected.emit(4)
	assert_eq(GameSettings.ui_scale(_path), 150)
