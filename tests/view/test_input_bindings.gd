extends GutTest
## InputBindings' rebinding layer: the defaults (Space stops, H centers), text
## that round-trips every kind of event, labels as the player reads them,
## apply/reset, conflicts, and the group modifiers. Every test leaves the
## InputMap on its defaults: it is global, and the other tests expect them.


func before_each() -> void:
	InputBindings.install()
	InputBindings.reset()


func after_each() -> void:
	InputBindings.reset()


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
	InputBindings.reset()
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
	var listed: int = 0
	for section: String in InputBindings.REBINDABLE:
		for action: StringName in InputBindings.REBINDABLE[section]:
			listed += 1
			assert_true(InputBindings.ACTION_NAMES.has(action), String(action))
			assert_true(defaults.has(action), String(action))
	assert_eq(listed, InputBindings.ACTION_NAMES.size(), "every named action is listed")
