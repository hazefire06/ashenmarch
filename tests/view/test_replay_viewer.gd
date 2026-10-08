extends GutTest
## Recording and watching in the view. A skirmish on a shipped map records the
## player's orders and stamps how it ended, and the recording plays back; the
## sandbox and maps built in code record nothing. A replay is watched without
## orders, at speed, to its end, with no results sent; its bar and the pause
## menu drive it. The App saves every game it leaves into its replays folder,
## lists them, plays one, deletes one, and turns a damaged one away.

const DIR: String = "user://test_replay_viewer"
const GOLDEN_SKIRMISH: String = "res://data/replays/golden/skirmish_ctf.amr"
const CTF: SkirmishRules.Mode = SkirmishRules.Mode.CAPTURE_THE_FLAGS


func before_each() -> void:
	_clean()


func after_each() -> void:
	_clean()
	await get_tree().process_frame


func _clean() -> void:
	if DirAccess.dir_exists_absolute(DIR):
		for file_name: String in DirAccess.get_files_at(DIR):
			DirAccess.remove_absolute(DIR + "/" + file_name)
		DirAccess.remove_absolute(DIR)


# A small skirmish on Old Mill, a shipped map, so it can be replayed.
func _real_skirmish_launch() -> MissionLaunch:
	var runner: SkirmishRunner = SkirmishRunner.new(
		TestTerrains.catalog(), load("res://data/skirmish/skirmish.tres") as SkirmishCatalog
	)
	return MissionLaunch.for_skirmish(runner.make_setup(
		&"old_mill", CTF, 5, 300, &"light_balanced", &"dark_balanced", 0, 77, false
	))


func _main(launch: MissionLaunch) -> MainView:
	var main: MainView = (load("res://view/main.tscn") as PackedScene).instantiate() as MainView
	main.launch = launch
	main.end_delay = 0.0
	add_child_autofree(main)
	return main


func _step(main: MainView, frames: int = 1) -> void:
	for i: int in frames:
		main._physics_process(1.0 / World.TICK_RATE)


func _watch_golden() -> MainView:
	var replay: Replay = ReplayStore.load_file(GOLDEN_SKIRMISH)
	assert_not_null(replay)
	return _main(MissionLaunch.for_replay(replay))


func test_a_played_skirmish_records_its_orders_and_how_it_ended() -> void:
	var main: MainView = _main(_real_skirmish_launch())
	assert_not_null(main.recording)
	assert_null(main.finished_replay(), "nothing played yet")
	_step(main, 5)
	main.world.enqueue(StopUnitsCommand.new(main.world.tick, PackedInt32Array([1, 2])))
	_step(main, 10)
	var replay: Replay = main.finished_replay()
	assert_not_null(replay)
	assert_eq(replay.end_tick, 15)
	assert_eq(replay.commands.size(), 1, "only the player's order, not the setup's")
	assert_eq(replay.summary["title"], "Old Mill")
	assert_eq(replay.summary["mode"], "Capture The Flags")
	assert_eq(replay.summary["outcome"], "NONE")
	assert_gt(replay.summary["recorded_at"], 0)
	assert_eq(replay.game_version, ProjectSettings.get_setting("application/config/version"))
	var player: ReplayPlayer = ReplayPlayer.new(Replay.from_dict(replay.to_dict()), TestTerrains.catalog())
	player.advance(100)
	assert_true(player.verified(), "and it plays back")


func test_the_sandbox_and_maps_built_in_code_record_nothing() -> void:
	assert_null(_main(ViewFixtures.skirmish_launch()).recording, "a code-built map")
	assert_null(_main(null).recording, "the sandbox")


func test_a_replay_is_watched_without_orders_at_speed_to_its_end() -> void:
	var main: MainView = _watch_golden()
	assert_true(main.is_replay())
	assert_null(main.recording, "watching records nothing")
	assert_true(main._selection.paused, "nobody takes orders")
	var bar: ReplayBar = main.find_child("ReplayBar", true, false) as ReplayBar
	assert_not_null(bar)
	watch_signals(main)
	main.set_replay_speed(8)
	_step(main)
	assert_eq(main.world.tick, 8, "eight ticks a frame")
	var guard: int = 0
	while not main.is_frozen() and guard < 1000:
		_step(main)
		guard += 1
	assert_true(main.is_frozen())
	assert_eq(main.world.tick, main.launch.replay.end_tick)
	assert_true(main._replay_player.verified(), "the view played it exactly")
	main._process(5.0)
	assert_signal_not_emitted(main, "skirmish_ended", "no results after a replay")
	assert_eq((bar.find_child("Note", true, false) as Label).text, "End of replay")
	assert_true(main.pause_menu().enabled, "the menu stays, to leave by")


func test_the_bar_and_the_pause_menu_drive_the_replay() -> void:
	var main: MainView = _watch_golden()
	var bar: ReplayBar = main.find_child("ReplayBar", true, false) as ReplayBar
	bar.speed_chosen.emit(4)
	assert_eq(main.replay_speed(), 4)
	bar.pause_pressed.emit()
	assert_true(main.paused)
	_step(main, 3)
	assert_eq(main.world.tick, 0, "paused means paused")
	bar.pause_pressed.emit()
	_step(main)
	assert_eq(main.world.tick, 4)
	watch_signals(main)
	bar.restart_pressed.emit()
	assert_signal_emitted(main, "restart_requested")
	bar.exit_pressed.emit()
	assert_signal_emitted(main, "quit_requested")
	var menu: PauseMenu = main.pause_menu()
	menu.open()
	assert_eq((MenuFixtures.named(menu, "RestartButton") as Button).text, "Watch again")
	assert_eq((MenuFixtures.named(menu, "QuitButton") as Button).text, "Back to replays")
	watch_signals(menu)
	MenuFixtures.press(menu, "QuitButton")
	assert_signal_emitted(menu, "quit_requested", "no question: nothing is lost")


func test_a_replay_of_something_this_build_lacks_has_no_launch() -> void:
	var replay: Replay = ReplayStore.load_file(GOLDEN_SKIRMISH)
	replay.setup["map"] = "res://maps/nowhere/skirmish.tres"
	assert_null(MissionLaunch.for_replay(replay))
	var mission: Replay = ReplayStore.load_file("res://data/replays/golden/riverside_t2.amr")
	assert_not_null(MissionLaunch.for_replay(mission))
	mission.setup["mission"] = "res://data/missions/nowhere.tres"
	assert_null(MissionLaunch.for_replay(mission))


func test_the_app_saves_a_game_it_leaves_then_lists_plays_and_deletes_it() -> void:
	var app: App = _app()
	MenuFixtures.press(app.current_screen(), "SkirmishButton")
	MenuFixtures.press(app.current_screen(), "Start")
	var main: MainView = app.current_screen() as MainView
	assert_not_null(main, "a skirmish is on")
	_step(main, 20)
	main.quit_requested.emit()
	assert_true(app.current_screen() is MainMenu)
	var saved: PackedStringArray = ReplayStore.list(DIR)
	assert_eq(saved.size(), 1, "leaving saved its replay")
	MenuFixtures.press(app.current_screen(), "ReplaysButton")
	assert_true(app.current_screen() is ReplaysMenu)
	MenuFixtures.press(app.current_screen(), "Watch")
	var watching: MainView = app.current_screen() as MainView
	assert_not_null(watching)
	assert_true(watching.is_replay())
	_step(watching, 20)
	assert_true(watching._replay_player.verified(), "the saved game plays back")
	watching.restart_requested.emit()
	assert_true((app.current_screen() as MainView).is_replay(), "Watch again")
	(app.current_screen() as MainView).quit_requested.emit()
	assert_true(app.current_screen() is ReplaysMenu, "back to the list")
	assert_eq(ReplayStore.list(DIR).size(), 1, "watching saved nothing new")
	MenuFixtures.press(app.current_screen(), "Delete")
	MenuFixtures.press(app.current_overlay(), "ConfirmButton")
	assert_eq(ReplayStore.list(DIR).size(), 0)
	assert_true(app.current_screen() is ReplaysMenu)


func test_a_damaged_replay_gets_a_notice_and_the_list() -> void:
	var app: App = _app()
	DirAccess.make_dir_recursive_absolute(DIR)
	var junk: FileAccess = FileAccess.open(DIR + "/9_junk.amr", FileAccess.WRITE)
	junk.store_string("junk")
	junk.close()
	app.watch_replay(DIR + "/9_junk.amr")
	assert_true(app.current_screen() is ReplaysMenu)
	var notice: Label = app.find_child("NoticeLabel", true, false) as Label
	assert_true(notice.visible)
	assert_string_contains(notice.text, "can't be played")


func test_the_list_describes_each_replay() -> void:
	var replay: Replay = ReplayStore.load_file("res://data/replays/golden/riverside_t2.amr")
	replay.summary["recorded_at"] = 0
	assert_eq(
		ReplaysMenu.describe(replay),
		"Riverside (tier 2)   ·   Campaign   ·   Victory   ·   %s" % MenuKit.clock(replay.seconds())
	)


func _app() -> App:
	var app: App = (load("res://view/app/app.tscn") as PackedScene).instantiate() as App
	app.store = CampaignStore.new(DIR + "/campaign.json")
	app.settings_path = DIR + "/settings.cfg"
	app.replays_dir = DIR
	add_child_autofree(app)
	return app
