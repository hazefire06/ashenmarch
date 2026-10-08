extends GutTest
## InputBindings' rebinding layer: the defaults (Space stops, H centers), text
## that round-trips every kind of event, labels as the player reads them,
## apply/reset, conflicts, and the group modifiers. Phase 11: a pad slot beside
## the keyboard one, pad events from any pad mapping to their actions, the
## pad on the menus' accept and cancel, and the Classic preset. Every test
## leaves the InputMap on Modern's defaults: it is global, and the other tests
## expect them.


func before_each() -> void:
	InputBindings.install()
	InputBindings.reset(InputBindings.Preset.MODERN)


func after_each() -> void:
	InputBindings.reset(InputBindings.Preset.MODERN)


func _key(keycode: Key, mods: String = "") -> InputEventKey:
	var event: InputEventKey = InputEventKey.new()
	event.physical_keycode = keycode
	event.command_or_control_autoremap = mods.contains("c")
	event.alt_pressed = mods.contains("a")
	event.shift_pressed = mods.contains("s")
	return event


func test_space_stops_and_h_centers_by_default() -> void:
	assert_eq(InputBindings.event_to_text(InputBindings.event_of(InputBindings.STOP)), "key:Space")
	assert_eq(InputBindings.event_to_text(InputBindings.event_of(InputBindings.CAM_CENTER)), "key:H")
	assert_eq(InputBindings.label_for(InputBindings.STOP), "Space")
	assert_eq(InputBindings.label_for(InputBindings.CAM_CENTER), "H")


func test_every_default_binding_round_trips_through_text() -> void:
	var defaults: Dictionary[StringName, InputEvent] = InputBindings.defaults()
	for action: StringName in defaults:
		var text: String = InputBindings.event_to_text(defaults[action])
		assert_ne(text, "", "%s has text" % action)
		var back: InputEvent = InputBindings.text_to_event(text)
		assert_not_null(back, "%s: %s parses" % [action, text])
		if back != null:
			assert_eq(InputBindings.event_to_text(back), text, String(action))


func test_text_covers_modifiers_mice_and_pads() -> void:
	for text: String in [
		"key:T", "key:1+cmdorctrl", "key:F7+alt+shift", "key:Q+ctrl+meta", "mouse:2+cmdorctrl",
		"mouse:1", "joy_button:0", "joy_axis:1:minus", "joy_axis:4:plus",
	]:
		var event: InputEvent = InputBindings.text_to_event(text)
		assert_not_null(event, text)
		if event != null:
			assert_eq(InputBindings.event_to_text(event), text)


func test_text_that_is_not_an_event_is_null() -> void:
	for text: String in ["", "key:", "key:NoSuchKey", "mouse:0", "mouse:x", "pad:1", "key:T+hyper", "joy_axis:1", "joy_axis:1:+", "joy_button:1+shift"]:
		assert_null(InputBindings.text_to_event(text), text)


func test_labels_read_as_the_player_would() -> void:
	var mac: bool = OS.has_feature("macos")
	assert_eq(InputBindings.event_label(_key(KEY_T)), "T")
	assert_eq(InputBindings.event_label(_key(KEY_1, "c")), ("Cmd+1" if mac else "Ctrl+1"))
	assert_eq(InputBindings.event_label(_key(KEY_1, "a")), ("Option+1" if mac else "Alt+1"))
	assert_eq(InputBindings.label_for(InputBindings.COMMAND), "Right click")
	assert_eq(InputBindings.label_for(InputBindings.ATTACK_MOVE), ("Cmd+Right click" if mac else "Ctrl+Right click"))


func test_apply_rebinds_and_reset_restores() -> void:
	InputBindings.apply({InputBindings.ABILITY: _key(KEY_G)} as Dictionary[StringName, InputEvent])
	assert_eq(InputBindings.label_for(InputBindings.ABILITY), "G")
	var press: InputEventKey = _key(KEY_G)
	press.pressed = true
	assert_true(press.is_action_pressed(InputBindings.ABILITY, false, true))
	InputBindings.reset(InputBindings.Preset.MODERN)
	assert_eq(InputBindings.label_for(InputBindings.ABILITY), "T")


func test_debug_keys_cannot_be_rebound() -> void:
	InputBindings.apply({InputBindings.TOGGLE_AI_DEBUG: _key(KEY_G)} as Dictionary[StringName, InputEvent])
	assert_eq(InputBindings.label_for(InputBindings.TOGGLE_AI_DEBUG), "F5")
	assert_false(InputBindings.is_rebindable(InputBindings.CANCEL))


func test_install_leaves_a_rebinding_alone() -> void:
	InputBindings.apply({InputBindings.STOP: _key(KEY_K)} as Dictionary[StringName, InputEvent])
	InputBindings.install()
	assert_eq(InputBindings.label_for(InputBindings.STOP), "K")


func test_conflicts_name_the_actions_already_on_a_key() -> void:
	assert_eq(InputBindings.conflicts(InputBindings.ABILITY, _key(KEY_SPACE)), [InputBindings.STOP] as Array[StringName])
	assert_eq(InputBindings.conflicts(InputBindings.ABILITY, _key(KEY_K)), [] as Array[StringName])
	assert_eq(InputBindings.conflicts(InputBindings.STOP, _key(KEY_SPACE)), [] as Array[StringName], "not with itself")
	assert_has(InputBindings.conflicts(InputBindings.ABILITY, _key(KEY_3, "c")), InputBindings.GROUP_SAVES[2])


func test_group_modifiers_move_the_group_keys() -> void:
	assert_true(InputBindings.set_group_modifiers(InputBindings.GroupModifier.SHIFT, InputBindings.GroupModifier.ALT))
	assert_eq(InputBindings.event_to_text(InputBindings.event_of(InputBindings.GROUP_SAVES[0])), "key:1+shift")
	assert_eq(InputBindings.event_to_text(InputBindings.event_of(InputBindings.GROUP_RECALLS[9])), "key:0+alt")
	assert_false(InputBindings.set_group_modifiers(InputBindings.GroupModifier.ALT, InputBindings.GroupModifier.ALT), "equal ones are refused")
	assert_eq(InputBindings.event_to_text(InputBindings.event_of(InputBindings.GROUP_SAVES[0])), "key:1+shift", "and change nothing")


func test_every_rebindable_action_has_a_name_and_a_default() -> void:
	var defaults: Dictionary[StringName, InputEvent] = InputBindings.defaults()
	var pad: Dictionary[StringName, InputEvent] = InputBindings.pad_defaults()
	var listed: Array[StringName] = []
	for section: String in InputBindings.REBINDABLE:
		for action: StringName in InputBindings.REBINDABLE[section]:
			if not listed.has(action):
				listed.append(action)
			assert_true(InputBindings.ACTION_NAMES.has(action), String(action))
			assert_true(defaults.has(action), String(action))
	for section: String in InputBindings.PAD_REBINDABLE:
		for action: StringName in InputBindings.PAD_REBINDABLE[section]:
			if not listed.has(action):
				listed.append(action)
			assert_true(InputBindings.ACTION_NAMES.has(action), String(action))
			assert_true(pad.has(action), "%s has a pad default" % action)
	assert_eq(listed.size(), InputBindings.ACTION_NAMES.size(), "every named action is listed")


func test_the_phase_11_keys() -> void:
	var expected: Dictionary[StringName, String] = {
		InputBindings.GUARD: "key:G", InputBindings.SCATTER: "key:B", InputBindings.RETREAT: "key:R",
		InputBindings.ROTATE_LEFT: "key:Left", InputBindings.ROTATE_RIGHT: "key:Right",
		InputBindings.SELECT_ALL: "key:Enter", InputBindings.DESELECT: "key:QuoteLeft",
		InputBindings.CYCLE_GROUPS: "key:F", InputBindings.HEALTH_BARS: "key:F10",
		InputBindings.SPEED_DOWN: "key:F1", InputBindings.SPEED_UP: "key:F2",
		InputBindings.COMMAND_ALT: "mouse:1+alt",
	}
	for action: StringName in expected:
		assert_eq(InputBindings.event_to_text(InputBindings.event_of(action)), expected[action], String(action))
	var clear: String = InputBindings.event_to_text(InputBindings.event_of(InputBindings.CLEAR_GROUP))
	assert_eq(clear, "key:Backspace" if OS.has_feature("macos") else "key:Delete")
	assert_eq(InputBindings.label_for(InputBindings.DESELECT), "`")


func test_no_two_keyboard_actions_share_a_default() -> void:
	for preset: InputBindings.Preset in [InputBindings.Preset.MODERN, InputBindings.Preset.CLASSIC]:
		InputBindings.reset(preset)
		var seen: Dictionary[String, StringName] = {}
		for section: String in InputBindings.REBINDABLE:
			for action: StringName in InputBindings.REBINDABLE[section]:
				var text: String = InputBindings.event_to_text(InputBindings.event_of(action))
				assert_false(seen.has(text), "%s: %s is also %s" % [preset, text, seen.get(text)])
				seen[text] = action


func test_pad_events_from_any_pad_reach_their_actions() -> void:
	var cases: Array = [
		[_pad_button(JOY_BUTTON_A, 0), InputBindings.PAD_SELECT],
		[_pad_button(JOY_BUTTON_X, 2), InputBindings.PAD_ORDER],
		[_pad_button(JOY_BUTTON_B, 1), InputBindings.CANCEL],
		[_pad_button(JOY_BUTTON_Y, 3), InputBindings.ABILITY],
		[_pad_button(JOY_BUTTON_LEFT_SHOULDER, 0), InputBindings.PAD_FORMATION_WHEEL],
		[_pad_button(JOY_BUTTON_RIGHT_SHOULDER, 0), InputBindings.PAD_ORDER_WHEEL],
		[_pad_button(JOY_BUTTON_DPAD_LEFT, 0), InputBindings.PAD_GROUP_PREV],
		[_pad_button(JOY_BUTTON_DPAD_RIGHT, 0), InputBindings.PAD_GROUP_NEXT],
		[_pad_button(JOY_BUTTON_DPAD_UP, 0), InputBindings.PAD_GROUP_SAVE],
		[_pad_button(JOY_BUTTON_DPAD_DOWN, 0), InputBindings.PAD_GROUP_CLEAR],
		[_pad_button(JOY_BUTTON_BACK, 0), InputBindings.PAD_VIEW],
		[_pad_button(JOY_BUTTON_START, 0), InputBindings.OPEN_MENU],
		[_pad_button(JOY_BUTTON_LEFT_STICK, 0), InputBindings.PAD_BAR_FOCUS],
		[_pad_button(JOY_BUTTON_RIGHT_STICK, 0), InputBindings.PAD_CENTER],
		[_pad_axis(JOY_AXIS_LEFT_X, -0.8, 0), InputBindings.PAD_CURSOR_LEFT],
		[_pad_axis(JOY_AXIS_LEFT_Y, 0.8, 1), InputBindings.PAD_CURSOR_DOWN],
		[_pad_axis(JOY_AXIS_RIGHT_X, 0.8, 0), InputBindings.PAD_PAN_RIGHT],
		[_pad_axis(JOY_AXIS_RIGHT_Y, -0.8, 0), InputBindings.PAD_PAN_FORWARD],
		[_pad_axis(JOY_AXIS_TRIGGER_LEFT, 0.6, 0), InputBindings.PAD_ORBIT_LEFT],
		[_pad_axis(JOY_AXIS_TRIGGER_RIGHT, 0.6, 5), InputBindings.PAD_ORBIT_RIGHT],
	]
	for case: Array in cases:
		var event: InputEvent = case[0]
		assert_true(event.is_action_pressed(case[1]), "%s is %s" % [InputBindings.event_label(event), case[1]])


func test_a_light_touch_on_a_stick_still_counts() -> void:
	assert_true(_pad_axis(JOY_AXIS_LEFT_X, 0.3, 0).is_action_pressed(InputBindings.PAD_CURSOR_RIGHT))
	assert_false(_pad_axis(JOY_AXIS_LEFT_X, 0.1, 0).is_action_pressed(InputBindings.PAD_CURSOR_RIGHT), "drift doesn't")


func test_the_pad_drives_the_menus() -> void:
	assert_true(_pad_button(JOY_BUTTON_A, 0).is_action_pressed(&"ui_accept"))
	assert_true(_pad_button(JOY_BUTTON_B, 0).is_action_pressed(&"ui_cancel"))
	assert_true(_pad_button(JOY_BUTTON_DPAD_DOWN, 0).is_action_pressed(&"ui_down"))


func test_pad_labels_read_as_the_player_would() -> void:
	assert_eq(InputBindings.label_for(InputBindings.ABILITY, InputBindings.Device.PAD), "Y")
	assert_eq(InputBindings.label_for(InputBindings.ABILITY), "T", "the key slot is separate")
	assert_eq(InputBindings.label_for(InputBindings.PAD_CURSOR_LEFT, InputBindings.Device.PAD), "LS left")
	assert_eq(InputBindings.label_for(InputBindings.PAD_ORBIT_RIGHT, InputBindings.Device.PAD), "RT")
	assert_eq(InputBindings.label_for(InputBindings.PAD_VIEW, InputBindings.Device.PAD), "View")


func test_a_pad_rebinding_leaves_the_key_alone() -> void:
	InputBindings.apply({InputBindings.ABILITY: _pad_button(JOY_BUTTON_X, -1)} as Dictionary[StringName, InputEvent])
	assert_eq(InputBindings.label_for(InputBindings.ABILITY, InputBindings.Device.PAD), "X")
	assert_eq(InputBindings.label_for(InputBindings.ABILITY), "T")
	assert_eq(
		InputBindings.conflicts(InputBindings.ABILITY, _pad_button(JOY_BUTTON_A, -1)),
		[InputBindings.PAD_SELECT] as Array[StringName], "pad conflicts are among pad bindings"
	)


func test_a_binding_in_the_wrong_slot_is_ignored() -> void:
	InputBindings.apply({
		InputBindings.STOP: _pad_button(JOY_BUTTON_X, -1),
		InputBindings.PAD_SELECT: _key(KEY_K),
	} as Dictionary[StringName, InputEvent])
	assert_eq(InputBindings.label_for(InputBindings.STOP, InputBindings.Device.PAD), "")
	assert_eq(InputBindings.label_for(InputBindings.PAD_SELECT), "")
	assert_eq(InputBindings.label_for(InputBindings.PAD_SELECT, InputBindings.Device.PAD), "A")


func test_reserved_inputs_are_never_bound() -> void:
	InputBindings.apply({
		InputBindings.PAD_SELECT: InputBindings.text_to_event("joy_button:%d" % JOY_BUTTON_START),
		InputBindings.PAD_ORDER: InputBindings.text_to_event("joy_button:%d" % JOY_BUTTON_GUIDE),
		InputBindings.STOP: _key(KEY_ESCAPE),
	} as Dictionary[StringName, InputEvent])
	assert_eq(InputBindings.label_for(InputBindings.PAD_SELECT, InputBindings.Device.PAD), "A")
	assert_eq(InputBindings.label_for(InputBindings.PAD_ORDER, InputBindings.Device.PAD), "X")
	assert_eq(InputBindings.label_for(InputBindings.STOP), "Space")
	assert_null(InputBindings.text_to_event("mouse:99"), "no such mouse button")


func test_saved_pad_text_binds_every_pad() -> void:
	var event: InputEvent = InputBindings.text_to_event("joy_button:3")
	assert_eq(event.device, -1)
	assert_null(InputBindings.text_to_event("joy_button:99"), "no such button")
	assert_null(InputBindings.text_to_event("joy_axis:40:plus"), "no such axis")


func test_classic_turns_and_strafes_like_myth() -> void:
	InputBindings.reset(InputBindings.Preset.CLASSIC)
	assert_true(InputBindings.orders_on_left())
	assert_true(InputBindings.hold_to_save_groups())
	assert_eq(InputBindings.label_for(InputBindings.CAM_SWIVEL_LEFT), "A")
	assert_eq(InputBindings.label_for(InputBindings.CAM_SWIVEL_RIGHT), "D")
	assert_eq(InputBindings.label_for(InputBindings.CAM_LEFT), "Z")
	assert_eq(InputBindings.label_for(InputBindings.CAM_RIGHT), "X")
	assert_eq(InputBindings.label_for(InputBindings.CAM_ZOOM_IN), "C")
	assert_eq(InputBindings.label_for(InputBindings.CAM_ZOOM_OUT), "V")
	assert_eq(InputBindings.label_for(InputBindings.COMMAND), "Right click", "Move keeps its button")
	assert_null(InputBindings.event_of(InputBindings.GROUP_SAVES[0]), "no save key: holding recall saves")
	var recall: String = InputBindings.event_to_text(InputBindings.event_of(InputBindings.GROUP_RECALLS[0]))
	assert_eq(recall, "key:1+cmdorctrl" if OS.has_feature("macos") else "key:1+alt", "Cmd on a Mac, Alt elsewhere")
	InputBindings.reset(InputBindings.Preset.MODERN)
	assert_false(InputBindings.orders_on_left())
	assert_eq(InputBindings.label_for(InputBindings.CAM_SWIVEL_LEFT), "Z")
	assert_eq(InputBindings.event_to_text(InputBindings.event_of(InputBindings.GROUP_SAVES[0])), "key:1+cmdorctrl")


func test_modern_refuses_classics_group_key() -> void:
	assert_false(InputBindings.set_group_modifiers(InputBindings.GroupModifier.COMMAND_OR_ALT, InputBindings.GroupModifier.SHIFT))


func _pad_button(button: JoyButton, device: int) -> InputEventJoypadButton:
	var event: InputEventJoypadButton = InputEventJoypadButton.new()
	event.button_index = button
	event.pressed = true
	event.device = device
	return event


func _pad_axis(axis: JoyAxis, value: float, device: int) -> InputEventJoypadMotion:
	var event: InputEventJoypadMotion = InputEventJoypadMotion.new()
	event.axis = axis
	event.axis_value = value
	event.device = device
	return event
