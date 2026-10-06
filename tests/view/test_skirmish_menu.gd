extends GutTest
## The skirmish setup and army builder, built alone from the shipped catalogs:
## the radio rows, the army grid and its +/- and Fill buttons, the points and
## the unit count against the cap, when Start is on, the enemy choices that
## follow the side, and what is remembered and what is refused of it. The App's
## wiring of it is test_app.

const DIR: String = "user://test_skirmish_menu"
const LIGHT: UnitType.Faction = UnitType.Faction.LIGHT
const DARK: UnitType.Faction = UnitType.Faction.DARK

var _catalog: UnitCatalog
var _skirmish: SkirmishCatalog


func before_all() -> void:
	_catalog = MenuFixtures.catalog()
	_skirmish = load("res://data/skirmish/skirmish.tres") as SkirmishCatalog


func after_each() -> void:
	await get_tree().process_frame
	if DirAccess.dir_exists_absolute(DIR):
		for file_name: String in DirAccess.get_files_at(DIR):
			DirAccess.remove_absolute(DIR + "/" + file_name)
		DirAccess.remove_absolute(DIR)


# --- helpers ------------------------------------------------------------------


func _menu(remembered: Dictionary = {}, catalog: SkirmishCatalog = null) -> SkirmishMenu:
	var menu: SkirmishMenu = SkirmishMenu.new()
	menu.setup(catalog if catalog != null else _skirmish, _catalog, remembered)
	add_child_autofree(menu)
	return menu


func _press(menu: SkirmishMenu, button_name: String, times: int = 1) -> void:
	for i: int in times:
		MenuFixtures.press(menu, button_name)


func _button(menu: SkirmishMenu, button_name: String) -> Button:
	return MenuFixtures.named(menu, button_name) as Button


func _text(menu: SkirmishMenu, label_name: String) -> String:
	var label: Label = MenuFixtures.named(menu, label_name) as Label
	return label.text if label != null else "<no label %s>" % label_name


## The side's buyable types, in catalog order.
func _buyable(side: int) -> Array[UnitType]:
	var out: Array[UnitType] = []
	for type: UnitType in _catalog.types:
		if type.faction == side and type.cost > 0:
			out.append(type)
	return out


func _template_army(template_id: StringName, budget: int) -> Army:
	return _skirmish.template(template_id).fill(budget, _catalog)


func _counts(army: Army) -> Dictionary:
	return army.counts.duplicate()


## True if only this button of the row is on.
func _only_on(menu: SkirmishMenu, on: String, others: Array[String]) -> bool:
	if not _button(menu, on).button_pressed:
		return false
	for other: String in others:
		if _button(menu, other).button_pressed:
			return false
	return true


func _button_names(menu: SkirmishMenu, prefix: String) -> PackedStringArray:
	var out: PackedStringArray = PackedStringArray()
	for node: Node in menu.find_children(prefix + "*", "Button", true, false):
		out.append(String(node.name))
	out.sort()
	return out


func _remembered(overrides: Dictionary = {}) -> Dictionary:
	var choice: Dictionary = {
		"map": "the_ford", "mode": 2, "minutes": 20, "budget": 1500, "side": 1, "start": 1,
		"ai_choice": "light_siege", "army": "husk:30,ripper:10", "army_side": 1,
	}
	choice.merge(overrides, true)
	return choice


# --- the first look -------------------------------------------------------------


func test_it_opens_on_the_catalogs_defaults_with_the_balanced_light_army() -> void:
	var menu: SkirmishMenu = _menu()
	var choice: Dictionary = menu.current_choice()
	assert_eq(choice["map"], String(_skirmish.maps[0].id), "the first map")
	assert_eq(choice["mode"], SkirmishRules.Mode.BODY_COUNT)
	assert_eq(choice["minutes"], _skirmish.default_time_limit_minutes)
	assert_eq(choice["budget"], _skirmish.default_budget)
	assert_eq(choice["side"], LIGHT)
	assert_eq(choice["start"], 0)
	assert_eq(choice["ai_choice"], "random")
	assert_eq(menu.army().counts, _template_army(&"light_balanced", 1000).counts)
	assert_true(menu.can_start())
	assert_false(_button(menu, "Start").disabled)


func test_the_screen_is_a_whole_screen_that_starts_on_start() -> void:
	var menu: SkirmishMenu = _menu()
	assert_true(menu.is_opaque())
	await get_tree().process_frame
	assert_eq(get_viewport().gui_get_focus_owner(), _button(menu, "Start"))


func test_every_choice_row_comes_from_the_catalog() -> void:
	var menu: SkirmishMenu = _menu()
	assert_eq(_button_names(menu, "Map_"), PackedStringArray(["Map_old_mill", "Map_riverside", "Map_the_ford"]))
	assert_eq(_button(menu, "Map_riverside").text, "Riverside")
	assert_eq(_button_names(menu, "Mode"), PackedStringArray(["Mode0", "Mode1", "Mode2"]))
	assert_eq([_button(menu, "Mode0").text, _button(menu, "Mode1").text, _button(menu, "Mode2").text],
		["Body Count", "King of the Hill", "Capture the Flags"])
	assert_eq(_button_names(menu, "Time"), PackedStringArray(["Time10", "Time15", "Time20", "Time5"]))
	assert_eq(_button(menu, "Time5").text, "5 min")
	assert_eq(_button_names(menu, "Budget"), PackedStringArray(["Budget1000", "Budget1500", "Budget600"]))
	assert_eq([_button(menu, "Side0").text, _button(menu, "Side1").text], ["Light", "Dark"])
	assert_eq([_button(menu, "Spawn0").text, _button(menu, "Spawn1").text], ["A", "B"])


func test_a_catalog_with_other_budgets_and_times_changes_the_rows() -> void:
	var custom: SkirmishCatalog = SkirmishCatalog.new()
	custom.maps = [ViewFixtures.skirmish_map()]
	custom.templates = _skirmish.templates
	custom.budgets = PackedInt32Array([500, 900])
	custom.default_budget = 900
	custom.time_limits_minutes = PackedInt32Array([3, 7])
	custom.default_time_limit_minutes = 3
	var menu: SkirmishMenu = _menu({}, custom)
	assert_eq(_button_names(menu, "Budget"), PackedStringArray(["Budget500", "Budget900"]))
	assert_eq(_button_names(menu, "Time"), PackedStringArray(["Time3", "Time7"]))
	assert_eq(menu.current_choice()["budget"], 900)
	assert_eq(menu.current_choice()["minutes"], 3)
	assert_eq(menu.current_choice()["map"], "test_flat")
	assert_eq(menu.army().counts, _template_army(&"light_balanced", 900).counts, "filled at that budget")


func test_the_chosen_buttons_are_the_ones_on() -> void:
	var menu: SkirmishMenu = _menu()
	assert_true(_only_on(menu, "Map_riverside", ["Map_the_ford", "Map_old_mill"]))
	assert_true(_only_on(menu, "Mode0", ["Mode1", "Mode2"]))
	assert_true(_only_on(menu, "Time10", ["Time5", "Time15", "Time20"]))
	assert_true(_only_on(menu, "Budget1000", ["Budget600", "Budget1500"]))
	assert_true(_only_on(menu, "Side0", ["Side1"]))
	assert_true(_only_on(menu, "Spawn0", ["Spawn1"]))
	assert_true(_only_on(menu, "Ai_random", [
		"Ai_dark_balanced", "Ai_dark_horde", "Ai_dark_raiders", "Ai_dark_storm",
	]))


# --- the radio rows ---------------------------------------------------------------


func test_picking_a_choice_changes_it_and_moves_the_mark() -> void:
	var menu: SkirmishMenu = _menu()
	_press(menu, "Map_old_mill")
	_press(menu, "Mode2")
	_press(menu, "Time15")
	_press(menu, "Budget600")
	_press(menu, "Spawn1")
	var choice: Dictionary = menu.current_choice()
	assert_eq(choice["map"], "old_mill")
	assert_eq(choice["mode"], SkirmishRules.Mode.CAPTURE_THE_FLAGS)
	assert_eq(choice["minutes"], 15)
	assert_eq(choice["budget"], 600)
	assert_eq(choice["start"], 1)
	assert_true(_only_on(menu, "Map_old_mill", ["Map_riverside", "Map_the_ford"]))
	assert_true(_only_on(menu, "Mode2", ["Mode0", "Mode1"]))
	assert_true(_only_on(menu, "Time15", ["Time5", "Time10", "Time20"]))
	assert_true(_only_on(menu, "Budget600", ["Budget1000", "Budget1500"]))
	assert_true(_only_on(menu, "Spawn1", ["Spawn0"]))


func test_a_button_pressed_twice_stays_on() -> void:
	var menu: SkirmishMenu = _menu()
	_press(menu, "Mode1", 2)
	assert_eq(menu.current_choice()["mode"], SkirmishRules.Mode.KING_OF_THE_HILL)
	assert_true(_button(menu, "Mode1").button_pressed)


func test_a_real_click_on_a_button_that_is_on_leaves_it_on() -> void:
	var menu: SkirmishMenu = _menu()
	var mode: Button = _button(menu, "Mode0")
	assert_true(mode.button_pressed)
	# A click flips a toggle button off, then sends `pressed`.
	mode.button_pressed = false
	mode.pressed.emit()
	assert_true(mode.button_pressed, "the row always has one on")


func test_the_mode_note_says_what_each_mode_scores() -> void:
	var menu: SkirmishMenu = _menu()
	assert_string_contains(_text(menu, "ModeNote"), "killed")
	_press(menu, "Mode1")
	assert_string_contains(_text(menu, "ModeNote"), "hill")
	_press(menu, "Mode2")
	assert_string_contains(_text(menu, "ModeNote"), "flags")
	assert_string_contains(_text(menu, "EliminationNote"), "loses at once", "elimination ends it in every mode")


# --- the army grid ----------------------------------------------------------------


func test_the_grid_lists_what_the_side_can_buy_in_catalog_order() -> void:
	var menu: SkirmishMenu = _menu()
	var cells: PackedStringArray = MenuFixtures.texts(MenuFixtures.named(menu, "ArmyGrid"))
	var types: Array[UnitType] = _buyable(LIGHT)
	assert_eq(types.size(), 5)
	var header: int = SkirmishMenu.COLUMNS
	# Per row the labels are name, role, hp, cost, count, total.
	for i: int in types.size():
		var at: int = header + i * 6
		assert_eq(cells[at], types[i].display_name)
		assert_eq(cells[at + 1], SkirmishMenu.ROLE_NAMES[types[i].role])
		assert_eq(cells[at + 2], str(types[i].max_hp))
		assert_eq(cells[at + 3], str(types[i].cost))
	assert_eq(cells.size(), header + types.size() * 6, "nothing else is listed")
	assert_null(_button(menu, "Plus_villager"), "a unit with no cost can't be bought")
	assert_null(_button(menu, "Plus_husk"), "and the other side's are not offered")
	assert_eq(_text(menu, "ArmyHeading"), "Your army: Light")


func test_the_counts_and_subtotals_show_the_filled_army() -> void:
	var menu: SkirmishMenu = _menu()
	var army: Army = _template_army(&"light_balanced", 1000)
	for type: UnitType in _buyable(LIGHT):
		assert_eq(_text(menu, "Count_%s" % type.id), str(army.count_of(type.id)))
		assert_eq(_text(menu, "Subtotal_%s" % type.id), str(army.count_of(type.id) * type.cost))


func test_plus_and_minus_change_one_count_and_the_totals() -> void:
	var menu: SkirmishMenu = _menu()
	_press(menu, "Clear")
	assert_eq(menu.army().size(), 0)
	_press(menu, "Plus_shieldman", 2)
	_press(menu, "Plus_longbow")
	assert_eq(_text(menu, "Count_shieldman"), "2")
	assert_eq(_text(menu, "Subtotal_shieldman"), "60")
	assert_eq(_text(menu, "Count_longbow"), "1")
	assert_eq(_text(menu, "Subtotal_longbow"), "45")
	assert_eq(_text(menu, "PointsLeft"), "Points left: 895")
	assert_eq(_text(menu, "UnitCount"), "Units: 3 / 60")
	assert_eq(menu.points_left(), 895)
	_press(menu, "Minus_shieldman")
	assert_eq(_text(menu, "Count_shieldman"), "1")
	assert_eq(_text(menu, "PointsLeft"), "Points left: 925")
	assert_eq(menu.army().counts, {&"shieldman": 1, &"longbow": 1} as Dictionary[StringName, int])


func test_minus_never_goes_below_none_and_is_greyed_at_none() -> void:
	var menu: SkirmishMenu = _menu()
	_press(menu, "Clear")
	assert_true(_button(menu, "Minus_shieldman").disabled)
	_press(menu, "Minus_shieldman")
	assert_eq(_text(menu, "Count_shieldman"), "0")
	assert_eq(menu.army().size(), 0)
	_press(menu, "Plus_shieldman")
	assert_false(_button(menu, "Minus_shieldman").disabled)


func test_a_minus_that_runs_out_hands_the_keyboard_to_the_plus_beside_it() -> void:
	var menu: SkirmishMenu = _menu()
	_press(menu, "Clear")
	_press(menu, "Plus_warden")
	_button(menu, "Minus_warden").grab_focus()
	_press(menu, "Minus_warden")
	assert_true(_button(menu, "Minus_warden").disabled)
	assert_eq(get_viewport().gui_get_focus_owner(), _button(menu, "Plus_warden"))


func test_going_over_the_budget_turns_the_points_red_and_start_off() -> void:
	var menu: SkirmishMenu = _menu()
	_press(menu, "Clear")
	# 19 Sappers are 1045 points on a budget of 1000.
	_press(menu, "Plus_sapper", 19)
	assert_eq(menu.points_left(), -45)
	assert_eq(_text(menu, "PointsLeft"), "Points left: -45")
	var points: Label = MenuFixtures.named(menu, "PointsLeft") as Label
	assert_eq(points.get_theme_color("font_color"), MenuKit.BAD_COLOR)
	assert_true(_button(menu, "Start").disabled)
	assert_false(menu.can_start())
	assert_string_contains(_text(menu, "StartHint"), "over the budget")
	_press(menu, "Minus_sapper")
	assert_eq(_text(menu, "PointsLeft"), "Points left: 10")
	assert_eq(points.get_theme_color("font_color"), MenuKit.TEXT_COLOR)
	assert_false(_button(menu, "Start").disabled)
	assert_eq(_text(menu, "StartHint"), "")


func test_an_empty_army_cannot_start() -> void:
	var menu: SkirmishMenu = _menu()
	_press(menu, "Clear")
	assert_eq(_text(menu, "PointsLeft"), "Points left: 1000")
	assert_eq(_text(menu, "UnitCount"), "Units: 0 / 60")
	assert_true(_button(menu, "Start").disabled)
	assert_string_contains(_text(menu, "StartHint"), "at least one unit")
	watch_signals(menu)
	_press(menu, "Start")
	assert_signal_not_emitted(menu, "start_pressed", "a press that bypasses `disabled` is refused too")


func test_more_than_sixty_units_cannot_start_even_inside_the_budget() -> void:
	var menu: SkirmishMenu = _menu()
	# Dark Husks cost 20: 61 of them are 1220 points, inside 1500.
	_press(menu, "Side1")
	_press(menu, "Budget1500")
	_press(menu, "Clear")
	_press(menu, "Plus_husk", Army.MAX_UNITS)
	assert_eq(_text(menu, "UnitCount"), "Units: 60 / 60")
	assert_true(menu.can_start(), "sixty is the cap, not over it")
	_press(menu, "Plus_husk")
	assert_eq(_text(menu, "UnitCount"), "Units: 61 / 60")
	var units: Label = MenuFixtures.named(menu, "UnitCount") as Label
	assert_eq(units.get_theme_color("font_color"), MenuKit.BAD_COLOR)
	assert_eq(menu.points_left(), 1500 - 61 * 20, "inside the budget")
	assert_true(_button(menu, "Start").disabled)
	assert_string_contains(_text(menu, "StartHint"), "at most 60")
	_press(menu, "Minus_husk")
	assert_false(_button(menu, "Start").disabled)


# --- Fill and Clear -----------------------------------------------------------------


func test_there_is_a_fill_button_for_each_template_of_the_side() -> void:
	var menu: SkirmishMenu = _menu()
	assert_eq(_button_names(menu, "Fill_"), PackedStringArray([
		"Fill_light_balanced", "Fill_light_shield_wall", "Fill_light_shock", "Fill_light_siege",
	]))
	assert_eq(_button(menu, "Fill_light_balanced").text, "Fill: Balanced")
	assert_eq(_button(menu, "Fill_light_shield_wall").text, "Fill: Shield Wall")


func test_fill_replaces_the_army_with_the_template_at_the_current_budget() -> void:
	var menu: SkirmishMenu = _menu()
	_press(menu, "Fill_light_shock")
	assert_eq(menu.army().counts, _template_army(&"light_shock", 1000).counts)
	_press(menu, "Plus_warden", 3)
	_press(menu, "Budget1500")
	_press(menu, "Fill_light_siege")
	assert_eq(menu.army().counts, _template_army(&"light_siege", 1500).counts, "the edits are replaced, at 1500")
	assert_eq(_text(menu, "Count_sapper"), str(menu.army().count_of(&"sapper")))
	assert_false(_button(menu, "Start").disabled)


func test_fill_after_clear_makes_the_army_startable_again() -> void:
	var menu: SkirmishMenu = _menu()
	_press(menu, "Clear")
	assert_true(_button(menu, "Start").disabled)
	_press(menu, "Fill_light_shield_wall")
	assert_false(_button(menu, "Start").disabled)
	assert_gt(menu.army().size(), 0)


func test_clear_empties_every_row() -> void:
	var menu: SkirmishMenu = _menu()
	_press(menu, "Clear")
	for type: UnitType in _buyable(LIGHT):
		assert_eq(_text(menu, "Count_%s" % type.id), "0")
		assert_eq(_text(menu, "Subtotal_%s" % type.id), "0")


# --- the budget -----------------------------------------------------------------------


func test_changing_the_budget_keeps_the_counts_and_may_turn_start_off() -> void:
	var menu: SkirmishMenu = _menu()
	var before: Dictionary = _counts(menu.army())
	_press(menu, "Budget600")
	assert_eq(_counts(menu.army()), before, "the army is kept")
	assert_lt(menu.points_left(), 0)
	assert_true(_button(menu, "Start").disabled)
	assert_string_contains(_text(menu, "StartHint"), "over the budget")
	_press(menu, "Budget1500")
	assert_eq(_counts(menu.army()), before)
	assert_false(_button(menu, "Start").disabled)
	assert_eq(menu.points_left(), 1500 - menu.army().cost(_catalog))


# --- the side ---------------------------------------------------------------------------


func test_the_other_side_has_its_own_units_and_the_balanced_army() -> void:
	var menu: SkirmishMenu = _menu()
	_press(menu, "Budget1500")
	_press(menu, "Plus_shieldman", 4)
	_press(menu, "Side1")
	assert_eq(menu.current_choice()["side"], DARK)
	assert_true(_only_on(menu, "Side1", ["Side0"]))
	var cells: PackedStringArray = MenuFixtures.texts(MenuFixtures.named(menu, "ArmyGrid"))
	var types: Array[UnitType] = _buyable(DARK)
	assert_eq(types.size(), 5)
	for i: int in types.size():
		assert_eq(cells[SkirmishMenu.COLUMNS + i * 6], types[i].display_name)
	assert_null(_button(menu, "Plus_shieldman"), "Light's units are gone")
	assert_not_null(_button(menu, "Plus_husk"))
	assert_eq(_text(menu, "ArmyHeading"), "Your army: Dark")
	assert_eq(menu.army().counts, _template_army(&"dark_balanced", 1500).counts, "at the current budget")
	assert_eq(menu.army().faction, DARK)
	assert_eq(_text(menu, "PointsLeft"), "Points left: %d" % (1500 - menu.army().cost(_catalog)))
	assert_eq(_button_names(menu, "Fill_"), PackedStringArray([
		"Fill_dark_balanced", "Fill_dark_horde", "Fill_dark_raiders", "Fill_dark_storm",
	]))
	assert_true(menu.can_start())


func test_going_back_to_light_gives_the_light_balanced_army_not_the_old_edits() -> void:
	var menu: SkirmishMenu = _menu()
	_press(menu, "Plus_warden", 5)
	_press(menu, "Side1")
	_press(menu, "Side0")
	assert_eq(menu.army().counts, _template_army(&"light_balanced", 1000).counts)
	assert_eq(menu.army().faction, LIGHT)


func test_choosing_the_side_already_chosen_keeps_the_army() -> void:
	var menu: SkirmishMenu = _menu()
	_press(menu, "Clear")
	_press(menu, "Plus_reaver", 2)
	_press(menu, "Side0")
	assert_eq(menu.army().counts, {&"reaver": 2} as Dictionary[StringName, int])
	assert_true(_button(menu, "Side0").button_pressed)


func test_the_side_swap_works_at_any_budget_and_start_follows() -> void:
	var menu: SkirmishMenu = _menu()
	_press(menu, "Budget600")
	_press(menu, "Side1")
	assert_eq(menu.army().counts, _template_army(&"dark_balanced", 600).counts)
	assert_true(menu.can_start(), "a template is filled to fit its budget")


# --- the enemy's army -----------------------------------------------------------------------


func test_the_enemy_choices_are_random_and_the_other_sides_templates() -> void:
	var menu: SkirmishMenu = _menu()
	assert_eq(_button_names(menu, "Ai_"), PackedStringArray([
		"Ai_dark_balanced", "Ai_dark_horde", "Ai_dark_raiders", "Ai_dark_storm", "Ai_random",
	]))
	assert_eq(_button(menu, "Ai_random").text, "Random")
	assert_eq(_button(menu, "Ai_dark_horde").text, "Horde")
	assert_eq(_button(menu, "Ai_dark_balanced").text, "Balanced")
	_press(menu, "Side1")
	assert_eq(_button_names(menu, "Ai_"), PackedStringArray([
		"Ai_light_balanced", "Ai_light_shield_wall", "Ai_light_shock", "Ai_light_siege", "Ai_random",
	]))
	assert_eq(_button(menu, "Ai_light_shield_wall").text, "Shield Wall")
	assert_null(_button(menu, "Ai_dark_horde"), "Light is the enemy now")


func test_picking_an_enemy_army_and_swapping_the_side_resets_it_to_random() -> void:
	var menu: SkirmishMenu = _menu()
	_press(menu, "Ai_dark_raiders")
	assert_eq(menu.current_choice()["ai_choice"], "dark_raiders")
	assert_true(_only_on(menu, "Ai_dark_raiders", ["Ai_random", "Ai_dark_balanced", "Ai_dark_horde", "Ai_dark_storm"]))
	_press(menu, "Ai_random")
	assert_eq(menu.current_choice()["ai_choice"], "random")
	_press(menu, "Ai_dark_storm")
	_press(menu, "Side1")
	assert_eq(menu.current_choice()["ai_choice"], "random", "Dark's templates are not the enemy's now")
	assert_true(_button(menu, "Ai_random").button_pressed)
	_press(menu, "Ai_light_siege")
	assert_eq(menu.current_choice()["ai_choice"], "light_siege")


# --- Start and Back -----------------------------------------------------------------------------


func test_start_hands_over_the_players_half_of_the_setup_and_the_enemy_choice() -> void:
	var menu: SkirmishMenu = _menu()
	_press(menu, "Map_the_ford")
	_press(menu, "Mode1")
	_press(menu, "Time15")
	_press(menu, "Budget1500")
	_press(menu, "Spawn1")
	_press(menu, "Ai_dark_horde")
	_press(menu, "Fill_light_shock")
	watch_signals(menu)
	_press(menu, "Start")
	assert_signal_emit_count(menu, "start_pressed", 1)
	var args: Array = get_signal_parameters(menu, "start_pressed")
	var made: SkirmishSetup = args[0] as SkirmishSetup
	assert_eq(args[1], &"dark_horde")
	assert_eq(made.map, _skirmish.skirmish_map(&"the_ford"))
	assert_eq(made.rules.mode, SkirmishRules.Mode.KING_OF_THE_HILL)
	assert_eq(made.rules.time_limit_ticks, 15 * 60 * World.TICK_RATE)
	assert_eq(made.rules.player_faction, LIGHT)
	assert_eq(made.budget, 1500)
	assert_eq(made.player_spawn, 1)
	assert_eq(made.armies.size(), 2)
	assert_eq(made.armies[0].counts, _template_army(&"light_shock", 1500).counts)
	assert_eq(made.armies[0].faction, LIGHT)
	assert_null(made.armies[1], "the App makes the enemy's army")


func test_a_random_enemy_is_handed_over_as_random() -> void:
	var menu: SkirmishMenu = _menu()
	watch_signals(menu)
	_press(menu, "Start")
	assert_eq(get_signal_parameters(menu, "start_pressed")[1], SkirmishMenu.RANDOM_AI)


func test_the_army_handed_over_is_a_copy() -> void:
	var menu: SkirmishMenu = _menu()
	watch_signals(menu)
	_press(menu, "Start")
	var made: SkirmishSetup = get_signal_parameters(menu, "start_pressed")[0] as SkirmishSetup
	var size_then: int = made.armies[0].size()
	_press(menu, "Plus_shieldman", 3)
	assert_eq(made.armies[0].size(), size_then, "later edits don't reach it")


func test_a_dark_player_starts_as_dark() -> void:
	var menu: SkirmishMenu = _menu()
	_press(menu, "Side1")
	watch_signals(menu)
	_press(menu, "Start")
	var made: SkirmishSetup = get_signal_parameters(menu, "start_pressed")[0] as SkirmishSetup
	assert_eq(made.rules.player_faction, DARK)
	assert_eq(made.player_faction(), DARK)
	assert_eq(made.armies[0].faction, DARK)
	assert_eq(made.ai_faction(), LIGHT)


func test_back_and_esc_leave() -> void:
	var menu: SkirmishMenu = _menu()
	watch_signals(menu)
	_press(menu, "Back")
	assert_signal_emit_count(menu, "back_pressed", 1)
	var event: InputEventKey = InputEventKey.new()
	event.physical_keycode = KEY_ESCAPE
	event.pressed = true
	get_viewport().push_input(event)
	assert_signal_emit_count(menu, "back_pressed", 2)


# --- what is remembered -----------------------------------------------------------------------------


func test_a_remembered_choice_is_what_the_screen_opens_on() -> void:
	var menu: SkirmishMenu = _menu(_remembered())
	var army: Army = Army.new(DARK)
	army.set_count(&"husk", 30)
	army.set_count(&"ripper", 10)
	assert_eq(
		menu.current_choice(), _remembered({"army": SkirmishMenu.army_to_text(army, _catalog)}),
		"as remembered, the army written in catalog order"
	)
	assert_eq(menu.army().counts, army.counts)
	assert_true(_only_on(menu, "Map_the_ford", ["Map_riverside", "Map_old_mill"]))
	assert_true(_only_on(menu, "Mode2", ["Mode0", "Mode1"]))
	assert_true(_only_on(menu, "Time20", ["Time5", "Time10", "Time15"]))
	assert_true(_only_on(menu, "Budget1500", ["Budget600", "Budget1000"]))
	assert_true(_only_on(menu, "Side1", ["Side0"]))
	assert_true(_only_on(menu, "Spawn1", ["Spawn0"]))
	assert_true(_only_on(menu, "Ai_light_siege", ["Ai_random", "Ai_light_balanced", "Ai_light_shield_wall", "Ai_light_shock"]))
	assert_eq(_text(menu, "Count_husk"), "30")
	assert_eq(_text(menu, "Count_ripper"), "10")
	assert_eq(_text(menu, "ArmyHeading"), "Your army: Dark")
	assert_eq(_text(menu, "PointsLeft"), "Points left: %d" % (1500 - 30 * 20 - 10 * 35))


func test_the_choice_survives_a_round_trip_through_the_settings_file() -> void:
	var path: String = DIR + "/settings.cfg"
	var first: SkirmishMenu = _menu()
	_press(first, "Map_old_mill")
	_press(first, "Mode1")
	_press(first, "Time5")
	_press(first, "Budget1500")
	_press(first, "Side1")
	_press(first, "Spawn1")
	_press(first, "Ai_light_shock")
	_press(first, "Clear")
	_press(first, "Plus_husk", 5)
	_press(first, "Plus_stormcaller", 2)
	assert_eq(GameSettings.set_skirmish_choice(first.current_choice(), path), OK)
	var second: SkirmishMenu = _menu(GameSettings.skirmish_choice(path))
	assert_eq(second.current_choice(), first.current_choice())
	assert_eq(second.army().counts, first.army().counts)
	assert_eq(second.army().size(), 7, "the edited army, not the Balanced one")


func test_an_empty_memory_is_the_defaults() -> void:
	var fresh: Dictionary = _menu().current_choice()
	assert_eq(_menu({}).current_choice(), fresh)
	assert_eq(_menu(GameSettings.skirmish_choice(DIR + "/missing.cfg")).current_choice(), fresh)


func test_a_choice_that_no_longer_fits_is_ignored_value_by_value() -> void:
	var defaults: Dictionary = _menu().current_choice()
	var menu: SkirmishMenu = _menu(_remembered({
		"map": "gone_map", "mode": 9, "minutes": 7, "budget": 123, "side": 5, "start": 2,
	}))
	var choice: Dictionary = menu.current_choice()
	assert_eq(choice["map"], defaults["map"], "an unknown map")
	assert_eq(choice["mode"], defaults["mode"], "a mode that doesn't exist")
	assert_eq(choice["minutes"], defaults["minutes"], "a time that isn't offered")
	assert_eq(choice["budget"], defaults["budget"], "a budget that isn't offered")
	assert_eq(choice["side"], LIGHT, "a side that doesn't exist")
	assert_eq(choice["start"], 0, "a start that doesn't exist")
	assert_eq(choice["ai_choice"], "random", "light_siege is the wrong side's for a Light player")
	assert_eq(menu.army().counts, _template_army(&"light_balanced", 1000).counts, "the Dark army is not Light's")


func test_wrongly_typed_values_are_ignored() -> void:
	var menu: SkirmishMenu = _menu({
		"map": 3, "mode": "two", "minutes": "ten", "budget": [], "side": "dark", "start": null,
		"ai_choice": 4, "army": 7, "army_side": "light",
	})
	assert_eq(menu.current_choice(), _menu().current_choice())


func test_an_army_that_does_not_fit_is_replaced_by_the_balanced_one() -> void:
	var bad: Array[Dictionary] = [
		{"army": "husk:30,ripper:10", "army_side": 0},
		{"army": "ghost:3", "army_side": 1},
		{"army": "husk:80", "army_side": 1},
		{"army": "husk:70,ripper:30", "army_side": 1},
		{"army": "villager:2", "army_side": 1},
		{"army": "husk:abc", "army_side": 1},
		{"army": "husk:-3", "army_side": 1},
		{"army": "husk:0", "army_side": 1},
		{"army": "husk:3,husk:4", "army_side": 1},
		{"army": "husk:3:4", "army_side": 1},
		{"army": "husk", "army_side": 1},
		{"army": ":3", "army_side": 1},
		{"army": "", "army_side": 1},
		{"army": "shieldman:5", "army_side": 1},
	]
	var balanced: Dictionary = _template_army(&"dark_balanced", 1500).counts
	for override: Dictionary in bad:
		var menu: SkirmishMenu = _menu(_remembered(override))
		assert_eq(menu.army().counts, balanced, "%s is refused" % override["army"])
		assert_eq(menu.current_choice()["side"], DARK, "the rest is kept")
		assert_eq(menu.current_choice()["budget"], 1500)


func test_an_army_is_judged_against_the_remembered_budget() -> void:
	# 30 Husks and 10 Rippers (950 points) fit 1500 and 1000, not 600.
	var fits: SkirmishMenu = _menu(_remembered({"budget": 1000}))
	assert_eq(fits.army().count_of(&"husk"), 30)
	var too_dear: SkirmishMenu = _menu(_remembered({"budget": 600}))
	assert_eq(too_dear.army().counts, _template_army(&"dark_balanced", 600).counts)


func test_a_remembered_enemy_choice_must_be_a_template_of_the_enemy_side() -> void:
	assert_eq(_menu(_remembered({"side": 0, "army_side": 0, "army": "shieldman:5", "ai_choice": "dark_storm"})).current_choice()["ai_choice"], "dark_storm")
	assert_eq(_menu(_remembered({"ai_choice": "dark_storm"})).current_choice()["ai_choice"], "random", "Dark is the player's here")
	assert_eq(_menu(_remembered({"ai_choice": "no_such_template"})).current_choice()["ai_choice"], "random")
	assert_eq(_menu(_remembered({"ai_choice": "random"})).current_choice()["ai_choice"], "random")


# --- the army as text -----------------------------------------------------------------------------


func test_an_army_is_written_in_catalog_order() -> void:
	var army: Army = Army.new(LIGHT)
	army.set_count(&"warden", 1)
	army.set_count(&"shieldman", 10)
	army.set_count(&"longbow", 4)
	var text: String = SkirmishMenu.army_to_text(army, _catalog)
	var order: Array[String] = []
	for type: UnitType in _catalog.types:
		if army.count_of(type.id) > 0:
			order.append("%s:%d" % [type.id, army.count_of(type.id)])
	assert_eq(text, ",".join(PackedStringArray(order)))
	assert_string_contains(text, "shieldman:10")
	assert_string_contains(text, "longbow:4")
	assert_eq(SkirmishMenu.army_to_text(Army.new(LIGHT), _catalog), "")


func test_an_army_reads_back_from_its_text() -> void:
	var army: Army = Army.new(DARK)
	army.set_count(&"husk", 12)
	army.set_count(&"blightbag", 3)
	var back: Army = SkirmishMenu.army_from_text(SkirmishMenu.army_to_text(army, _catalog), DARK)
	assert_eq(back.counts, army.counts)
	assert_eq(back.faction, DARK)
	assert_eq(SkirmishMenu.army_from_text(" husk:2 , ripper:1 ", DARK).counts.size(), 2, "spaces are allowed")
	assert_eq(SkirmishMenu.army_from_text("", LIGHT).size(), 0, "no text is an army with no one in it")
	assert_null(SkirmishMenu.army_from_text("husk:x", DARK))
	assert_null(SkirmishMenu.army_from_text("husk:1,husk:2", DARK))


func test_a_type_the_catalog_does_not_know_is_written_and_so_refused_on_reading() -> void:
	var army: Army = Army.new(LIGHT)
	army.set_count(&"shieldman", 2)
	army.set_count(&"ghost", 1)
	var text: String = SkirmishMenu.army_to_text(army, _catalog)
	assert_string_contains(text, "ghost:1")
	var back: Army = SkirmishMenu.army_from_text(text, LIGHT)
	assert_false(back.validate(_catalog, 1000).is_empty(), "Army.validate names the unknown type")


func test_choice_of_a_setup_is_what_the_screen_would_have_said() -> void:
	var menu: SkirmishMenu = _menu()
	_press(menu, "Mode2")
	_press(menu, "Time5")
	_press(menu, "Spawn1")
	_press(menu, "Ai_dark_storm")
	watch_signals(menu)
	_press(menu, "Start")
	var args: Array = get_signal_parameters(menu, "start_pressed")
	assert_eq(SkirmishMenu.choice_of(args[0] as SkirmishSetup, args[1] as StringName, _catalog), menu.current_choice())


func test_the_mode_and_side_names() -> void:
	assert_eq(SkirmishMenu.mode_name(SkirmishRules.Mode.CAPTURE_THE_FLAGS), "Capture the Flags")
	assert_eq(SkirmishMenu.side_name(DARK), "Dark")
	assert_eq(SkirmishMenu.side_name(7), "Side 7")
