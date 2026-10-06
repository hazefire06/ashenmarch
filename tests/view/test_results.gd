extends GutTest
## The results screen, built from a finished mission played out in a fixture
## world (no real mission is run): Victory or Defeat, the mission and its time,
## enemies killed by type, Light losses by name, friendly-fire deaths, the
## objectives' final states, a table with every soldier who deployed, and the
## buttons each outcome offers. The screen only shows and signals; applying the
## victory is the App's (see test_app).

const SHIELDMAN: StringName = &"shieldman"
const LONGBOW: StringName = &"longbow"
const WON: MissionRuntime.Outcome = MissionRuntime.Outcome.WON
const LOST: MissionRuntime.Outcome = MissionRuntime.Outcome.LOST

var _catalog: UnitCatalog
var _mission: MissionDef
var _plan: DeployPlan
var _stats: MissionStats
var _world: World


func before_all() -> void:
	_catalog = MenuFixtures.catalog()


## Two Shieldmen and a Longbow deploy: veteran 1 (3 kills, 40 hp), recruit 2
## (Bram) and recruit 3 (Cole, the Longbow). The mission: veteran 1 made 5
## kills and ends on 55 hp, Bram died (to friendly fire), Cole made 1 kill;
## four Husks died; it took 2:05.
func before_each() -> void:
	_mission = CampaignFixtures.mission(
		&"m1", [CampaignFixtures.entry(SHIELDMAN, PackedInt32Array([2])), CampaignFixtures.entry(LONGBOW)]
	)
	var state: CampaignState = CampaignFixtures.state([CampaignFixtures.soldier(1, SHIELDMAN, 3, 40)])
	_plan = state.plan_deploy(_mission, PackedInt32Array(), CampaignFixtures.names())
	_stats = MissionStats.new()
	_world = MenuFixtures.play_out(
		_plan, _mission, _stats, [2], {1: 5, 3: 1} as Dictionary[int, int], 4, {1: 55} as Dictionary[int, int]
	)
	_stats.end_tick = (2 * 60 + 5) * World.TICK_RATE
	_stats.friendly_fire.append(2)


func _screen(outcome: MissionRuntime.Outcome = WON) -> Results:
	var screen: Results = Results.new()
	screen.setup(outcome, _stats, _mission, _plan, _world, _catalog)
	add_child_autofree(screen)
	return screen


func _row(screen: Results, soldier_name: String) -> PackedStringArray:
	var cells: PackedStringArray = MenuFixtures.texts(MenuFixtures.named(screen, "SoldierGrid"))
	var at: int = cells.find(soldier_name)
	assert_gt(at, -1, "%s has a row" % soldier_name)
	return cells.slice(at, at + Results.COLUMNS)


func test_a_victory_says_so_with_the_mission_and_its_time() -> void:
	var screen: Results = _screen()
	assert_true(screen.is_victory())
	assert_eq((MenuFixtures.named(screen, "Outcome") as Label).text, "Victory")
	assert_eq((MenuFixtures.named(screen, "MissionLine") as Label).text, "%s   -   Time 2:05" % _mission.display_name)


func test_a_defeat_says_so_and_that_nothing_is_kept() -> void:
	var screen: Results = _screen(LOST)
	assert_false(screen.is_victory())
	assert_eq((MenuFixtures.named(screen, "Outcome") as Label).text, "Defeat")
	assert_eq((MenuFixtures.named(screen, "Note") as Label).text, Results.DEFEAT_NOTE)
	assert_string_contains(Results.DEFEAT_NOTE, "Nothing from this attempt is kept")


func test_the_time_is_minutes_and_seconds() -> void:
	for pair: Array in [[0, "0:00"], [59, "0:59"], [60, "1:00"], [605, "10:05"]]:
		_stats.end_tick = (pair[0] as int) * World.TICK_RATE
		var screen: Results = _screen()
		assert_eq((MenuFixtures.named(screen, "MissionLine") as Label).text, "%s   -   Time %s" % [_mission.display_name, pair[1]])


func test_enemies_killed_are_counted_by_type() -> void:
	var screen: Results = _screen()
	assert_true(MenuFixtures.says(screen, "Enemies killed: 4"))
	assert_eq(MenuFixtures.texts(MenuFixtures.named(screen, "EnemiesKilled")), PackedStringArray(["Husk: 4"]))


func test_several_enemy_types_are_listed_most_first() -> void:
	_stats.enemy_dead = {&"husk": 3, &"ripper": 5, &"drifter": 3} as Dictionary[StringName, int]
	var screen: Results = _screen()
	assert_eq(
		MenuFixtures.texts(MenuFixtures.named(screen, "EnemiesKilled")),
		PackedStringArray(["Ripper: 5", "Drifter: 3", "Husk: 3"]), "most first, ties by id"
	)
	assert_true(MenuFixtures.says(screen, "Enemies killed: 11"))


func test_light_losses_are_named_with_their_type() -> void:
	var screen: Results = _screen()
	assert_true(MenuFixtures.says(screen, "Light losses: 1"))
	assert_eq(MenuFixtures.texts(MenuFixtures.named(screen, "Losses")), PackedStringArray(["Bram (Shieldman)"]))


func test_no_losses_says_none() -> void:
	_stats.lost = PackedInt32Array()
	_stats.friendly_fire = PackedInt32Array()
	var screen: Results = _screen()
	assert_true(MenuFixtures.says(screen, "Light losses: 0"))
	assert_eq(MenuFixtures.texts(MenuFixtures.named(screen, "Losses")), PackedStringArray(["None"]))
	assert_true(MenuFixtures.says(screen, "Lost to friendly fire: 0"))
	assert_eq(MenuFixtures.texts(MenuFixtures.named(screen, "FriendlyFire")).size(), 0)


func test_friendly_fire_deaths_are_listed_by_name() -> void:
	var screen: Results = _screen()
	assert_true(MenuFixtures.says(screen, "Lost to friendly fire: 1"))
	assert_eq(MenuFixtures.texts(MenuFixtures.named(screen, "FriendlyFire")), PackedStringArray(["Bram (Shieldman)"]))


func test_a_veteran_row_shows_this_missions_kills_the_total_the_bonuses_and_his_health() -> void:
	var screen: Results = _screen()
	# Kills 5 this mission + 3 he had = 8. Shieldman caps: accuracy 120 and
	# attack rate 250, no speed: bonus = cap * 8 / (8 + 4).
	assert_eq(
		_row(screen, "Soldier 1"),
		PackedStringArray(["Soldier 1", "Shieldman", "5", "8", "+8%", "+16.6%", "-", "55/100", "Survived"])
	)


func test_a_recruit_who_lived_says_recruit_and_a_fallen_one_says_fallen() -> void:
	var screen: Results = _screen()
	# Cole, the Longbow recruit: 1 kill; caps 300 and 250 over 1 + 4.
	assert_eq(
		_row(screen, "Cole"), PackedStringArray(["Cole", "Longbow", "1", "1", "+6%", "+5%", "-", "70/70", "Recruit"])
	)
	# Bram died: no health to show, status Fallen.
	assert_eq(
		_row(screen, "Bram"), PackedStringArray(["Bram", "Shieldman", "0", "0", "+0%", "+0%", "-", "-", "Fallen"])
	)


func test_every_soldier_who_deployed_has_a_row() -> void:
	var grid: GridContainer = MenuFixtures.named(_screen(), "SoldierGrid") as GridContainer
	@warning_ignore("integer_division")
	var rows: int = grid.get_child_count() / Results.COLUMNS - 1
	assert_eq(rows, _plan.size())


func test_objectives_show_their_final_states() -> void:
	var script: MissionScript = MissionFixtures.script([], [], [
		MissionFixtures.objective(&"clear", "Clear the village"),
		MissionFixtures.objective(&"bridge", "Hold the bridge"),
		MissionFixtures.objective(&"herbs", "Gather herbs", true),
		MissionFixtures.objective(&"secret", "A surprise", false, false),
	])
	var runtime: MissionRuntime = MissionRuntime.new(script, 2, 0, PackedInt32Array())
	runtime.objective_states[0] = MissionRuntime.ObjectiveState.DONE
	runtime.objective_states[1] = MissionRuntime.ObjectiveState.FAILED
	runtime.objective_states[2] = MissionRuntime.ObjectiveState.ACTIVE
	_world.mission = runtime
	var list: VBoxContainer = MenuFixtures.named(_screen(), "Objectives") as VBoxContainer
	assert_eq(
		MenuFixtures.texts(list),
		PackedStringArray([
			"Done", "Clear the village", "Failed", "Hold the bridge", "Not done", "Gather herbs (optional)",
		]),
		"the hidden objective is left out"
	)


func test_no_mission_in_the_world_means_no_objectives_section() -> void:
	assert_null(_world.mission)
	assert_null(MenuFixtures.named(_screen(), "Objectives"))


func test_a_victory_offers_continue_and_main_menu_not_retry() -> void:
	var screen: Results = _screen()
	assert_not_null(MenuFixtures.named(screen, "ContinueButton"))
	assert_not_null(MenuFixtures.named(screen, "MainMenuButton"))
	assert_null(MenuFixtures.named(screen, "RetryButton"))
	watch_signals(screen)
	MenuFixtures.press(screen, "ContinueButton")
	MenuFixtures.press(screen, "MainMenuButton")
	assert_signal_emit_count(screen, "continue_pressed", 1)
	assert_signal_emit_count(screen, "main_menu_pressed", 1)
	assert_signal_not_emitted(screen, "retry_pressed")


func test_a_defeat_offers_retry_and_main_menu_not_continue() -> void:
	var screen: Results = _screen(LOST)
	assert_not_null(MenuFixtures.named(screen, "RetryButton"))
	assert_not_null(MenuFixtures.named(screen, "MainMenuButton"))
	assert_null(MenuFixtures.named(screen, "ContinueButton"))
	watch_signals(screen)
	MenuFixtures.press(screen, "RetryButton")
	MenuFixtures.press(screen, "MainMenuButton")
	assert_signal_emit_count(screen, "retry_pressed", 1)
	assert_signal_emit_count(screen, "main_menu_pressed", 1)
	assert_signal_not_emitted(screen, "continue_pressed")


func test_esc_does_nothing_here() -> void:
	var screen: Results = _screen()
	watch_signals(screen)
	var key: InputEventKey = InputEventKey.new()
	key.physical_keycode = KEY_ESCAPE
	key.pressed = true
	get_viewport().push_input(key)
	assert_signal_not_emitted(screen, "continue_pressed")
	assert_signal_not_emitted(screen, "main_menu_pressed")


func test_the_keyboard_starts_on_the_way_forward() -> void:
	var won: Results = _screen()
	await get_tree().process_frame
	assert_eq(get_viewport().gui_get_focus_owner(), MenuFixtures.named(won, "ContinueButton"))
	var lost: Results = _screen(LOST)
	await get_tree().process_frame
	assert_eq(get_viewport().gui_get_focus_owner(), MenuFixtures.named(lost, "RetryButton"))
