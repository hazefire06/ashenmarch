extends GutTest
## The skirmish results screen, built from skirmishes played out in a real
## (tiny) world: Victory, Defeat or Draw, why it ended, the time, the mode and
## each side's score, and per side what it deployed and lost by unit type. The
## losses must come from the snapshot the sim froze at the decision, not from
## the units as they stand when the screen is built. The screen only shows and
## signals; Rematch, Change army and Main menu are the App's (see test_app).

const LIGHT: UnitType.Faction = UnitType.Faction.LIGHT
const DARK: UnitType.Faction = UnitType.Faction.DARK
const BC: SkirmishRules.Mode = SkirmishRules.Mode.BODY_COUNT
const KOTH: SkirmishRules.Mode = SkirmishRules.Mode.KING_OF_THE_HILL
const CTF: SkirmishRules.Mode = SkirmishRules.Mode.CAPTURE_THE_FLAGS
const WON: MissionRuntime.Outcome = MissionRuntime.Outcome.WON
const LOST: MissionRuntime.Outcome = MissionRuntime.Outcome.LOST
const DRAW: MissionRuntime.Outcome = MissionRuntime.Outcome.DRAW

var _catalog: UnitCatalog
var _skirmish: SkirmishCatalog


func before_all() -> void:
	_catalog = MenuFixtures.catalog()
	_skirmish = load("res://data/skirmish/skirmish.tres") as SkirmishCatalog


func after_all() -> void:
	ViewFixtures.cleanup()


func after_each() -> void:
	await get_tree().process_frame


# --- helpers ------------------------------------------------------------------


## The tiny skirmish with 3 Shieldmen and 2 Longbows against 4 Husks and a
## Ripper (or the mirror, for a Dark player), the AI's army from Balanced.
func _setup(mode: SkirmishRules.Mode = BC, side: UnitType.Faction = LIGHT) -> SkirmishSetup:
	var setup: SkirmishSetup = ViewFixtures.skirmish_setup(mode, side)
	var mine: Army = Army.new(side)
	var theirs: Army = Army.new(setup.ai_faction())
	if side == LIGHT:
		mine.set_count(&"shieldman", 3)
		mine.set_count(&"longbow", 2)
		theirs.set_count(&"husk", 4)
		theirs.set_count(&"ripper", 1)
	else:
		mine.set_count(&"husk", 3)
		mine.set_count(&"drifter", 2)
		theirs.set_count(&"shieldman", 4)
		theirs.set_count(&"reaver", 1)
	setup.armies = [mine, theirs]
	return setup


## The world of that setup after its first step: everyone deployed and the
## skirmish has recorded the two rosters.
func _world(setup: SkirmishSetup) -> World:
	var world: World = SkirmishSetup.create_world(setup, _catalog)
	assert_not_null(world, "the world is built")
	world.step()
	assert_eq(world.skirmish.roster_ids[0].size() + world.skirmish.roster_ids[1].size(), 10)
	return world


## Kills up to `n` living units of a type on a side (n < 0: all of them).
func _kill(world: World, side: UnitType.Faction, type_id: StringName, n: int = -1) -> void:
	var left: int = n
	for unit: Unit in world.units:
		if left == 0:
			break
		if unit.faction == side and unit.type.id == type_id and unit.is_alive():
			unit.state = Unit.State.DEAD
			left -= 1


func _kill_side(world: World, side: UnitType.Faction) -> void:
	for unit: Unit in world.units:
		if unit.faction == side:
			unit.state = Unit.State.DEAD


## Steps until the skirmish is decided (a few ticks at most) and returns the
## outcome from the player's side.
func _decide(world: World) -> MissionRuntime.Outcome:
	for i: int in 200:
		world.step()
		if world.skirmish.is_decided():
			break
	assert_true(world.skirmish.is_decided(), "the skirmish was decided")
	return world.mission.outcome


func _screen(
	setup: SkirmishSetup, world: World, outcome: MissionRuntime.Outcome, with_catalog: bool = true
) -> SkirmishResults:
	var screen: SkirmishResults = SkirmishResults.new()
	screen.setup(setup, world, outcome, _skirmish if with_catalog else null)
	add_child_autofree(screen)
	return screen


func _text(screen: SkirmishResults, label_name: String) -> String:
	var label: Label = MenuFixtures.named(screen, label_name) as Label
	return label.text if label != null else "<no label %s>" % label_name


func _color(screen: SkirmishResults, label_name: String) -> Color:
	return (MenuFixtures.named(screen, label_name) as Label).get_theme_color("font_color")


## A side's table as rows of [unit, deployed, lost], the totals row last.
func _rows(screen: SkirmishResults, side: int) -> Array[PackedStringArray]:
	var cells: PackedStringArray = MenuFixtures.texts(MenuFixtures.named(screen, "Table%d" % side))
	var rows: Array[PackedStringArray] = []
	for at: int in range(SkirmishResults.COLUMNS, cells.size(), SkirmishResults.COLUMNS):
		rows.append(cells.slice(at, at + SkirmishResults.COLUMNS))
	return rows


func _row_of(rows: Array[PackedStringArray], unit_name: String) -> PackedStringArray:
	for row: PackedStringArray in rows:
		if row[0] == unit_name:
			return row
	return PackedStringArray()


# --- the verdict ------------------------------------------------------------------


func test_a_win_by_elimination_says_victory_and_who_was_wiped_out() -> void:
	var setup: SkirmishSetup = _setup()
	var world: World = _world(setup)
	_kill_side(world, DARK)
	var outcome: MissionRuntime.Outcome = _decide(world)
	assert_eq(outcome, WON)
	var screen: SkirmishResults = _screen(setup, world, outcome)
	assert_true(screen.is_victory())
	assert_false(screen.is_draw())
	assert_eq(_text(screen, "Outcome"), "Victory")
	assert_eq(_color(screen, "Outcome"), MenuKit.GOOD_COLOR)
	assert_eq(_text(screen, "Reason"), "Dark was wiped out")


func test_a_loss_by_elimination_says_defeat_and_who_was_wiped_out() -> void:
	var setup: SkirmishSetup = _setup()
	var world: World = _world(setup)
	_kill_side(world, LIGHT)
	var outcome: MissionRuntime.Outcome = _decide(world)
	assert_eq(outcome, LOST)
	var screen: SkirmishResults = _screen(setup, world, outcome)
	assert_false(screen.is_victory())
	assert_eq(_text(screen, "Outcome"), "Defeat")
	assert_eq(_color(screen, "Outcome"), MenuKit.BAD_COLOR)
	assert_eq(_text(screen, "Reason"), "Light was wiped out")


func test_both_sides_wiped_out_at_once_is_a_draw() -> void:
	var setup: SkirmishSetup = _setup()
	var world: World = _world(setup)
	_kill_side(world, LIGHT)
	_kill_side(world, DARK)
	var outcome: MissionRuntime.Outcome = _decide(world)
	assert_eq(outcome, DRAW)
	var screen: SkirmishResults = _screen(setup, world, outcome)
	assert_true(screen.is_draw())
	assert_false(screen.is_victory())
	assert_eq(_text(screen, "Outcome"), "Draw")
	assert_eq(_color(screen, "Outcome"), MenuKit.WARN_COLOR)
	assert_eq(_text(screen, "Reason"), "Both sides were wiped out")


func test_a_dark_player_who_wipes_out_light_wins() -> void:
	var setup: SkirmishSetup = _setup(BC, DARK)
	var world: World = _world(setup)
	_kill_side(world, LIGHT)
	var outcome: MissionRuntime.Outcome = _decide(world)
	assert_eq(outcome, WON)
	var screen: SkirmishResults = _screen(setup, world, outcome)
	assert_eq(_text(screen, "Outcome"), "Victory")
	assert_eq(_text(screen, "Reason"), "Light was wiped out")


func test_the_time_limit_says_time_ran_out_whatever_the_result() -> void:
	# A short clock: the rules are the sim's to read, and a test may set them.
	var setup: SkirmishSetup = _setup(KOTH)
	setup.rules.time_limit_ticks = 60
	var world: World = _world(setup)
	# A Shieldman holds the hill alone: Light wins on the clock.
	for unit: Unit in world.units:
		if unit.faction == LIGHT and unit.type.id == &"shieldman":
			unit.x = 30 * ViewFixtures.M
			unit.z = 30 * ViewFixtures.M
			break
	var outcome: MissionRuntime.Outcome = _decide(world)
	assert_eq(world.skirmish.end_reason, SkirmishRuntime.EndReason.TIME)
	var screen: SkirmishResults = _screen(setup, world, outcome)
	assert_eq(outcome, WON)
	assert_eq(_text(screen, "Outcome"), "Victory")
	assert_eq(_text(screen, "Reason"), "Time ran out")


func test_nobody_ahead_at_the_limit_is_a_draw_that_says_time_ran_out() -> void:
	var setup: SkirmishSetup = _setup(KOTH)
	setup.rules.time_limit_ticks = 30
	var world: World = _world(setup)
	var outcome: MissionRuntime.Outcome = _decide(world)
	assert_eq(outcome, DRAW)
	var screen: SkirmishResults = _screen(setup, world, outcome)
	assert_eq(_text(screen, "Outcome"), "Draw")
	assert_eq(_text(screen, "Reason"), "Time ran out")


func test_the_title_follows_the_outcome_it_is_given() -> void:
	var setup: SkirmishSetup = _setup()
	var world: World = _world(setup)
	_kill_side(world, DARK)
	_decide(world)
	assert_eq(_text(_screen(setup, world, LOST), "Outcome"), "Defeat")
	assert_eq(_text(_screen(setup, world, DRAW), "Outcome"), "Draw")
	assert_eq(_text(_screen(setup, world, WON), "Outcome"), "Victory")


# --- the match line -----------------------------------------------------------------


func test_the_time_is_how_long_the_skirmish_ran() -> void:
	var setup: SkirmishSetup = _setup(KOTH)
	var world: World = _world(setup)
	_kill_side(world, DARK)
	_decide(world)
	world.skirmish.end_tick = world.skirmish.start_tick + (2 * 60 + 5) * World.TICK_RATE
	var screen: SkirmishResults = _screen(setup, world, WON)
	assert_eq(_text(screen, "MatchLine"), "King of the Hill   -   Test Flat   -   Time 2:05")


func test_the_time_is_counted_from_the_start_tick_not_from_tick_zero() -> void:
	var setup: SkirmishSetup = _setup(CTF)
	var world: World = _world(setup)
	_kill_side(world, DARK)
	_decide(world)
	world.skirmish.start_tick = 10 * World.TICK_RATE
	world.skirmish.end_tick = 70 * World.TICK_RATE
	assert_eq(_text(_screen(setup, world, WON), "MatchLine"), "Capture the Flags   -   Test Flat   -   Time 1:00")


func test_the_match_line_names_the_mode_and_the_map() -> void:
	for mode: SkirmishRules.Mode in [BC, KOTH, CTF]:
		var setup: SkirmishSetup = _setup(mode)
		var world: World = _world(setup)
		_kill_side(world, DARK)
		_decide(world)
		var line: String = _text(_screen(setup, world, WON), "MatchLine")
		assert_string_starts_with(line, SkirmishMenu.mode_name(mode))
		assert_string_contains(line, "Test Flat")


# --- the score ------------------------------------------------------------------------


func test_body_count_scores_are_the_enemy_deaths() -> void:
	var setup: SkirmishSetup = _setup(BC)
	var world: World = _world(setup)
	_kill(world, DARK, &"husk", 3)
	_kill(world, LIGHT, &"longbow", 1)
	_kill_side(world, DARK)
	_decide(world)
	var screen: SkirmishResults = _screen(setup, world, WON)
	assert_eq(_text(screen, "Score0"), "Kills: 5", "Light killed all five Dark units")
	assert_eq(_text(screen, "Score1"), "Kills: %d" % world.skirmish.deaths[0])


func test_king_of_the_hill_scores_are_the_time_on_the_hill() -> void:
	var setup: SkirmishSetup = _setup(KOTH)
	var world: World = _world(setup)
	_kill_side(world, DARK)
	_decide(world)
	world.skirmish.hold_ticks[0] = 83 * World.TICK_RATE
	world.skirmish.hold_ticks[1] = 9 * World.TICK_RATE + 20
	var screen: SkirmishResults = _screen(setup, world, WON)
	assert_eq(_text(screen, "Score0"), "Hill held: 1:23")
	assert_eq(_text(screen, "Score1"), "Hill held: 0:09")


func test_capture_the_flags_scores_are_the_flags_and_how_long_they_were_held() -> void:
	var setup: SkirmishSetup = _setup(CTF)
	var world: World = _world(setup)
	_kill_side(world, DARK)
	_decide(world)
	world.skirmish.flag_owner[0] = 0
	world.skirmish.flag_owner[1] = 0
	world.skirmish.flag_owner[2] = 1
	world.skirmish.owned_ticks[0] = 125 * World.TICK_RATE
	world.skirmish.owned_ticks[1] = 30 * World.TICK_RATE
	var screen: SkirmishResults = _screen(setup, world, WON)
	assert_eq(_text(screen, "Score0"), "Flags: 2 of 3 (held for 2:05)")
	assert_eq(_text(screen, "Score1"), "Flags: 1 of 3 (held for 0:30)")


func test_the_score_is_what_the_sim_froze_not_what_the_world_does_after() -> void:
	var setup: SkirmishSetup = _setup(BC)
	var world: World = _world(setup)
	_kill_side(world, DARK)
	_decide(world)
	var screen_then: SkirmishResults = _screen(setup, world, WON)
	var before: String = _text(screen_then, "Score0")
	# The world goes on after the decision; the runtime doesn't.
	_kill_side(world, LIGHT)
	for i: int in 5:
		world.step()
	assert_eq(_text(_screen(setup, world, WON), "Score0"), before)


# --- the tables ----------------------------------------------------------------------------


func test_each_side_is_headed_by_who_it_is() -> void:
	var setup: SkirmishSetup = _setup()
	var world: World = _world(setup)
	_kill_side(world, DARK)
	_decide(world)
	var screen: SkirmishResults = _screen(setup, world, WON)
	assert_eq(_text(screen, "Heading0"), "Light (you)")
	assert_eq(_text(screen, "Heading1"), "Dark (AI: Balanced)", "the template's name, from the catalog")
	var horde: SkirmishSetup = _setup()
	horde.ai_template_id = &"dark_horde"
	assert_eq(_text(_screen(horde, world, WON), "Heading1"), "Dark (AI: Horde)")


func test_without_the_catalog_the_enemys_template_is_shown_by_its_id() -> void:
	var setup: SkirmishSetup = _setup()
	var world: World = _world(setup)
	_kill_side(world, DARK)
	_decide(world)
	assert_eq(_text(_screen(setup, world, WON, false), "Heading1"), "Dark (AI: dark_balanced)")
	setup.ai_template_id = &""
	assert_eq(_text(_screen(setup, world, WON, false), "Heading1"), "Dark (AI)")


func test_a_dark_player_is_shown_first_and_the_ai_is_light() -> void:
	var setup: SkirmishSetup = _setup(BC, DARK)
	setup.ai_template_id = &"light_shock"
	var world: World = _world(setup)
	_kill_side(world, LIGHT)
	_decide(world)
	var screen: SkirmishResults = _screen(setup, world, WON)
	assert_eq(_text(screen, "Heading1"), "Dark (you)")
	assert_eq(_text(screen, "Heading0"), "Light (AI: Shock)")
	var sides: Array[Node] = screen.find_children("Side?", "VBoxContainer", true, false)
	assert_eq(sides.size(), 2)
	assert_eq(String(sides[0].name), "Side1", "the player's column first")
	assert_eq(String(sides[1].name), "Side0")


func test_each_table_counts_what_was_deployed_and_lost_by_type() -> void:
	var setup: SkirmishSetup = _setup()
	var world: World = _world(setup)
	_kill(world, LIGHT, &"shieldman", 2)
	_kill(world, LIGHT, &"longbow", 1)
	_kill(world, DARK, &"husk", 4)
	_kill(world, DARK, &"ripper", 1)
	_decide(world)
	var screen: SkirmishResults = _screen(setup, world, WON)
	var mine: Array[PackedStringArray] = _rows(screen, 0)
	assert_eq(_row_of(mine, "Shieldman"), PackedStringArray(["Shieldman", "3", "2"]))
	assert_eq(_row_of(mine, "Longbow"), PackedStringArray(["Longbow", "2", "1"]))
	assert_eq(mine.size(), 3, "two types and the totals")
	assert_eq(mine[mine.size() - 1], PackedStringArray(["Total", "5", "3"]))
	var theirs: Array[PackedStringArray] = _rows(screen, 1)
	assert_eq(_row_of(theirs, "Husk"), PackedStringArray(["Husk", "4", "4"]))
	assert_eq(_row_of(theirs, "Ripper"), PackedStringArray(["Ripper", "1", "1"]))
	assert_eq(theirs[theirs.size() - 1], PackedStringArray(["Total", "5", "5"]))


func test_a_side_that_lost_nothing_shows_zero_lost() -> void:
	var setup: SkirmishSetup = _setup()
	var world: World = _world(setup)
	_kill_side(world, DARK)
	_decide(world)
	var mine: Array[PackedStringArray] = _rows(_screen(setup, world, WON), 0)
	assert_eq(_row_of(mine, "Shieldman")[2], "0")
	assert_eq(mine[mine.size() - 1], PackedStringArray(["Total", "5", "0"]))


func test_the_tables_come_from_the_frozen_snapshot_not_the_units_now() -> void:
	var setup: SkirmishSetup = _setup()
	var world: World = _world(setup)
	_kill(world, LIGHT, &"shieldman", 1)
	_kill_side(world, DARK)
	_decide(world)
	var screen_then: SkirmishResults = _screen(setup, world, WON)
	var mine_then: Array[PackedStringArray] = _rows(screen_then, 0)
	var theirs_then: Array[PackedStringArray] = _rows(screen_then, 1)
	assert_eq(_row_of(mine_then, "Shieldman")[2], "1")
	# Afterwards the dead rise and the living fall: the table must not notice.
	for unit: Unit in world.units:
		unit.state = Unit.State.IDLE if unit.faction == DARK else Unit.State.DEAD
	var screen_now: SkirmishResults = _screen(setup, world, WON)
	assert_eq(_rows(screen_now, 0), mine_then)
	assert_eq(_rows(screen_now, 1), theirs_then)


func test_a_unit_that_changed_sides_counts_as_lost() -> void:
	var setup: SkirmishSetup = _setup()
	var world: World = _world(setup)
	# A converted Shieldman is no longer on its side: the sim counts it as lost,
	# though it is alive.
	var converted: Unit = null
	for unit: Unit in world.units:
		if unit.faction == LIGHT and unit.type.id == &"shieldman":
			converted = unit
			converted.faction = DARK
			break
	for unit: Unit in world.units:
		if unit.faction == DARK and unit != converted:
			unit.state = Unit.State.DEAD
	_decide(world)
	assert_true(converted.is_alive())
	var mine: Array[PackedStringArray] = _rows(_screen(setup, world, WON), 0)
	assert_eq(_row_of(mine, "Shieldman"), PackedStringArray(["Shieldman", "3", "1"]))


func test_the_rows_are_in_catalog_order() -> void:
	var setup: SkirmishSetup = _setup()
	var world: World = _world(setup)
	_kill_side(world, DARK)
	_decide(world)
	var rows: Array[PackedStringArray] = _rows(_screen(setup, world, WON), 1)
	var expected: Array[String] = []
	for type: UnitType in _catalog.types:
		if type.id == &"husk" or type.id == &"ripper":
			expected.append(type.display_name)
	assert_eq([rows[0][0], rows[1][0]], expected)


func test_a_dark_players_tables_use_its_own_types() -> void:
	var setup: SkirmishSetup = _setup(BC, DARK)
	var world: World = _world(setup)
	_kill(world, DARK, &"husk", 3)
	_kill_side(world, LIGHT)
	_decide(world)
	var screen: SkirmishResults = _screen(setup, world, WON)
	var mine: Array[PackedStringArray] = _rows(screen, 1)
	assert_eq(_row_of(mine, "Husk"), PackedStringArray(["Husk", "3", "3"]))
	assert_eq(_row_of(mine, "Drifter"), PackedStringArray(["Drifter", "2", "0"]), "these were not killed")
	var theirs: Array[PackedStringArray] = _rows(screen, 0)
	assert_eq(_row_of(theirs, "Shieldman"), PackedStringArray(["Shieldman", "4", "4"]))
	assert_eq(_row_of(theirs, "Reaver"), PackedStringArray(["Reaver", "1", "1"]))


# --- the buttons -------------------------------------------------------------------------------


func _finished_screen() -> SkirmishResults:
	var setup: SkirmishSetup = _setup()
	var world: World = _world(setup)
	_kill_side(world, DARK)
	return _screen(setup, world, _decide(world))


func test_the_three_buttons_are_signals() -> void:
	var screen: SkirmishResults = _finished_screen()
	watch_signals(screen)
	MenuFixtures.press(screen, "RematchButton")
	MenuFixtures.press(screen, "ChangeArmyButton")
	MenuFixtures.press(screen, "MainMenuButton")
	assert_signal_emit_count(screen, "rematch_pressed", 1)
	assert_signal_emit_count(screen, "change_army_pressed", 1)
	assert_signal_emit_count(screen, "main_menu_pressed", 1)
	assert_eq((MenuFixtures.named(screen, "RematchButton") as Button).text, "Rematch")
	assert_eq((MenuFixtures.named(screen, "ChangeArmyButton") as Button).text, "Change army")
	assert_eq((MenuFixtures.named(screen, "MainMenuButton") as Button).text, "Main menu")


func test_it_starts_on_rematch_and_hides_what_is_under_it() -> void:
	var screen: SkirmishResults = _finished_screen()
	assert_true(screen.is_opaque())
	await get_tree().process_frame
	assert_eq(get_viewport().gui_get_focus_owner(), MenuFixtures.named(screen, "RematchButton"))


func test_esc_does_nothing_here() -> void:
	var screen: SkirmishResults = _finished_screen()
	watch_signals(screen)
	var event: InputEventKey = InputEventKey.new()
	event.physical_keycode = KEY_ESCAPE
	event.pressed = true
	get_viewport().push_input(event)
	assert_signal_not_emitted(screen, "rematch_pressed")
	assert_signal_not_emitted(screen, "change_army_pressed")
	assert_signal_not_emitted(screen, "main_menu_pressed")


func test_a_world_with_no_skirmish_still_gets_a_screen_with_its_buttons() -> void:
	var setup: SkirmishSetup = _setup()
	var screen: SkirmishResults = _screen(setup, World.new(1), LOST)
	assert_eq(_text(screen, "Outcome"), "Defeat")
	assert_not_null(MenuFixtures.named(screen, "RematchButton"))
	assert_null(MenuFixtures.named(screen, "Table0"), "no tables without a skirmish to read")
