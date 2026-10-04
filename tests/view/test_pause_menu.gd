extends GutTest
## PauseMenu: Resume, Restart mission, Settings, and Quit to main menu (which
## asks first), each a signal for whatever runs the game. Esc opens it, closes
## it, or takes the quit question back; it can be switched off; and a small
## "Paused" label stands in for it when the game is paused without the menu.
## Esc's place in the input order (before the selection controller) is tested
## with the whole scene in test_main_view.gd.

var _menu: PauseMenu


func before_each() -> void:
	InputBindings.install()
	_menu = PauseMenu.new()
	add_child_autofree(_menu)
	watch_signals(_menu)


func _esc() -> void:
	var event: InputEventKey = InputEventKey.new()
	event.physical_keycode = KEY_ESCAPE
	event.pressed = true
	_menu._unhandled_input(event)


func _button(button_name: String) -> Button:
	return _menu.find_child(button_name, true, false) as Button


func test_it_starts_shut() -> void:
	assert_false(_menu.is_open())
	assert_false(_menu.is_confirming())
	assert_false(_menu.is_paused_label_visible())


func test_opening_and_closing_say_so() -> void:
	_menu.open()
	assert_true(_menu.is_open())
	assert_signal_emit_count(_menu, "opened", 1)
	_menu.open()
	assert_signal_emit_count(_menu, "opened", 1, "already open")
	_menu.close()
	assert_false(_menu.is_open())
	assert_signal_emit_count(_menu, "closed", 1)
	_menu.close()
	assert_signal_emit_count(_menu, "closed", 1, "already shut")


func test_resume_closes_the_menu_and_asks_to_resume() -> void:
	_menu.open()
	_button("ResumeButton").pressed.emit()
	assert_false(_menu.is_open())
	assert_signal_emit_count(_menu, "resume_requested", 1)


func test_restart_and_settings_ask_and_leave_the_menu_up() -> void:
	_menu.open()
	_button("RestartButton").pressed.emit()
	assert_signal_emit_count(_menu, "restart_requested", 1)
	_button("SettingsButton").pressed.emit()
	assert_signal_emit_count(_menu, "settings_requested", 1)
	assert_true(_menu.is_open(), "the App shows Settings over it and the game stays paused")


func test_quit_asks_first() -> void:
	_menu.open()
	_button("QuitButton").pressed.emit()
	assert_true(_menu.is_confirming())
	assert_signal_not_emitted(_menu, "quit_requested")
	assert_false(_button("ResumeButton").is_visible_in_tree(), "the question replaces the buttons")
	assert_true(_button("ConfirmQuitButton").is_visible_in_tree())


func test_confirming_quits() -> void:
	_menu.open()
	_button("QuitButton").pressed.emit()
	_button("ConfirmQuitButton").pressed.emit()
	assert_signal_emit_count(_menu, "quit_requested", 1)


func test_keeping_playing_takes_the_question_back() -> void:
	_menu.open()
	_button("QuitButton").pressed.emit()
	_button("CancelQuitButton").pressed.emit()
	assert_false(_menu.is_confirming())
	assert_true(_menu.is_open(), "back at the menu, not out of it")
	assert_signal_not_emitted(_menu, "quit_requested")
	assert_true(_button("ResumeButton").is_visible_in_tree())


func test_esc_opens_the_menu_and_esc_again_resumes() -> void:
	_esc()
	assert_true(_menu.is_open())
	_esc()
	assert_false(_menu.is_open())
	assert_signal_emit_count(_menu, "resume_requested", 1, "Esc closing it is a Resume")


func test_esc_in_the_quit_question_takes_it_back_and_keeps_the_menu() -> void:
	_menu.open()
	_button("QuitButton").pressed.emit()
	_esc()
	assert_false(_menu.is_confirming())
	assert_true(_menu.is_open())
	assert_signal_not_emitted(_menu, "resume_requested")


func test_reopening_never_starts_on_the_quit_question() -> void:
	_menu.open()
	_button("QuitButton").pressed.emit()
	_menu.close()
	_menu.open()
	assert_false(_menu.is_confirming())


func test_a_menu_that_is_switched_off_ignores_esc() -> void:
	_menu.enabled = false
	_esc()
	assert_false(_menu.is_open())
	_menu.enabled = true
	_esc()
	assert_true(_menu.is_open())


func test_only_esc_opens_it() -> void:
	var event: InputEventKey = InputEventKey.new()
	event.physical_keycode = KEY_P
	event.pressed = true
	_menu._unhandled_input(event)
	assert_false(_menu.is_open())


func test_esc_reaches_it_through_the_viewport() -> void:
	var event: InputEventKey = InputEventKey.new()
	event.physical_keycode = KEY_ESCAPE
	event.pressed = true
	get_viewport().push_input(event)
	assert_true(_menu.is_open())


func test_the_paused_label_is_for_a_pause_with_no_menu() -> void:
	_menu.show_paused_label(true)
	assert_true(_menu.is_paused_label_visible())
	_menu.open()
	assert_false(_menu.is_paused_label_visible(), "the menu says it already")
	_menu.show_paused_label(true)
	assert_false(_menu.is_paused_label_visible(), "and can't be asked to say it twice")
	_menu.close()
	_menu.show_paused_label(true)
	assert_true(_menu.is_paused_label_visible())
	_menu.show_paused_label(false)
	assert_false(_menu.is_paused_label_visible())


func test_the_menu_takes_the_mouse_only_while_open() -> void:
	assert_eq(_menu.mouse_filter, Control.MOUSE_FILTER_IGNORE, "it never blocks a click itself")
	var overlay: Control = _menu.find_child("Overlay", true, false) as Control
	assert_false(overlay.visible)
	_menu.open()
	assert_true(overlay.visible)
	assert_eq(overlay.mouse_filter, Control.MOUSE_FILTER_STOP, "nothing under the menu is clicked")


func test_the_app_buttons_can_be_hidden_for_the_sandbox() -> void:
	_menu.set_app_buttons_visible(false)
	_menu.open()
	assert_true(_button("ResumeButton").visible)
	assert_false(_button("RestartButton").visible)
	assert_false(_button("SettingsButton").visible)
	assert_false(_button("QuitButton").visible)
	_menu.set_app_buttons_visible(true)
	assert_true(_button("QuitButton").visible)


func test_it_draws_above_the_rest_of_the_hud() -> void:
	# Tree order is draw order and click order, and the menu sits first in the
	# HUD's tree (for Esc), so its screens are on a layer above the HUD's.
	var layer: CanvasLayer = _menu.find_child("MenuLayer", true, false) as CanvasLayer
	assert_not_null(layer)
	assert_gt(layer.layer, 1, "the HUD's own CanvasLayer is 1")
	assert_true(_menu.find_child("Overlay", true, false).get_parent() == layer)
