extends GutTest
## The App: the main scene, one screen at a time, and the campaign flow wired
## through MainView's signals. The screens are tested alone elsewhere; here the
## walk is: MainMenu -> CampaignMenu -> Briefing -> mission -> Results -> next
## Briefing or CampaignComplete, with Retry after a defeat, Settings over a
## paused mission, and the saves written at the right moments. Missions are the
## tiny TIMER-0 fixtures (ViewFixtures): decided on their first step, so no test
## plays a real one; the menus walk the shipped campaign.
## Every file is under a directory of this test's own.

const DIR: String = "user://test_app"
const SHIELDMAN: StringName = &"shieldman"
const WON: MissionRuntime.Outcome = MissionRuntime.Outcome.WON
const LOST: MissionRuntime.Outcome = MissionRuntime.Outcome.LOST

var _physics_rate: int = 0


func before_all() -> void:
	# MainView sets the global physics rate to the sim's; put it back after.
	_physics_rate = Engine.physics_ticks_per_second


func after_all() -> void:
	Engine.physics_ticks_per_second = _physics_rate
	ViewFixtures.cleanup()
	_clean()


func before_each() -> void:
	_clean()


func after_each() -> void:
	_clean()
	# The screens the App replaced are queue_free'd; let the frame free them, so
	# they aren't reported as orphans.
	await get_tree().process_frame


func _clean() -> void:
	if DirAccess.dir_exists_absolute(DIR):
		for file_name: String in DirAccess.get_files_at(DIR):
			DirAccess.remove_absolute(DIR + "/" + file_name)
		DirAccess.remove_absolute(DIR)


# --- helpers ------------------------------------------------------------------


func _store() -> CampaignStore:
	return CampaignStore.new(DIR + "/campaign.json")


func _settings_path() -> String:
	return DIR + "/settings.cfg"


func _app(def: CampaignDef = null, rng_seed: int = 12345) -> App:
	var app: App = (load("res://view/app/app.tscn") as PackedScene).instantiate() as App
	app.store = _store()
	app.settings_path = _settings_path()
	app.campaign = def
	app.rng.seed = rng_seed
	add_child_autofree(app)
	return app


## One mission on the tiny map that is won on its first step, or lost on it.
func _mission(outcome: MissionRuntime.Outcome = WON, mission_id: StringName = &"test_flat") -> MissionDef:
	var def: MissionDef = ViewFixtures.mission(0)
	def.id = mission_id
	def.display_name = String(mission_id)
	if outcome == LOST:
		def.rules.triggers[0].actions = [MissionFixtures.action(TriggerAction.Kind.LOSE)]
	return def


## A campaign of those: the first decided as `first` says on its first step, the
## rest (if `second`) never decided inside a test.
func _tiny(first: MissionRuntime.Outcome = WON, second: bool = false) -> CampaignDef:
	var missions: Array[MissionDef] = [_mission(first)]
	if second:
		var later: MissionDef = ViewFixtures.mission()
		later.id = &"second"
		later.display_name = "Second"
		missions.append(later)
	return CampaignFixtures.campaign(missions)


func _press(app: App, button_name: String) -> void:
	MenuFixtures.press(app.current_screen(), button_name)


## From the main menu through New Campaign at this tier to the briefing.
func _begin_campaign(app: App, tier: int = 2) -> void:
	_press(app, "CampaignButton")
	_press(app, "NewCampaignButton")
	(MenuFixtures.named(app.current_screen(), "Tier%d" % tier) as Button).button_pressed = true
	_press(app, "BeginButton")


## Decides the mission in play: its first step, then the end of the delay.
func _decide(app: App) -> void:
	var main: MainView = app.current_screen() as MainView
	main.end_delay = 0.0
	main._physics_process(1.0 / World.TICK_RATE)
	main._process(0.1)


func _file(path: String) -> String:
	return FileAccess.get_file_as_string(path)


func _key(keycode: Key) -> void:
	var event: InputEventKey = InputEventKey.new()
	event.physical_keycode = keycode
	event.pressed = true
	get_viewport().push_input(event)


func _roster_size(mission: MissionDef, tier: int) -> int:
	var total: int = 0
	for entry: RosterEntry in mission.roster:
		total += Difficulty.pick(entry.counts, tier)
	return total


## The App at its briefing for the tiny campaign's first mission, then into the
## mission: the MainView.
func _into_the_mission(app: App) -> MainView:
	_begin_campaign(app)
	_press(app, "StartButton")
	return app.current_screen() as MainView


# --- booting ------------------------------------------------------------------


func test_the_app_is_the_projects_main_scene() -> void:
	assert_eq(ProjectSettings.get_setting("application/run/main_scene"), "res://view/app/app.tscn")


func test_the_app_boots_to_the_main_menu() -> void:
	var app: App = _app()
	assert_true(app.current_screen() is MainMenu)
	assert_null(app.current_overlay())
	assert_null(app.state, "no campaign until one is begun or continued")
	assert_not_null(app.campaign)
	assert_eq(app.campaign.missions.size(), 3)


func test_a_saved_fullscreen_choice_is_applied_at_boot_without_a_window() -> void:
	GameSettings.set_fullscreen(true, _settings_path())
	var before: DisplayServer.WindowMode = DisplayServer.window_get_mode()
	var app: App = _app()
	assert_true(app.current_screen() is MainMenu)
	assert_eq(DisplayServer.window_get_mode(), before, "headless: the window mode is never touched")


func test_the_main_menu_opens_the_campaign_menu_and_back() -> void:
	var app: App = _app()
	_press(app, "CampaignButton")
	assert_true(app.current_screen() is CampaignMenu)
	_press(app, "BackButton")
	assert_true(app.current_screen() is MainMenu)


func test_only_one_screen_stands_at_a_time() -> void:
	var app: App = _app()
	_press(app, "CampaignButton")
	var screens: int = 0
	for child: Node in app.get_children():
		if child is MenuScreen:
			screens += 1
	assert_eq(screens, 1, "the main menu was removed, not hidden")


# --- new campaign, continue ---------------------------------------------------


func test_new_campaign_normal_shows_riversides_roster_at_that_tier() -> void:
	var app: App = _app()
	_begin_campaign(app)
	var briefing: Briefing = app.current_screen() as Briefing
	assert_not_null(briefing)
	var riverside: MissionDef = app.campaign.missions[0]
	assert_eq(app.state.tier, 2, "Normal")
	assert_eq(app.state.mission_index, 0)
	assert_eq(briefing.plan().size(), _roster_size(riverside, 2))
	assert_eq(briefing.plan().recruits.size(), _roster_size(riverside, 2), "all recruits in the first mission")
	assert_true(MenuFixtures.says(briefing, "Riverside"))
	assert_true(MenuFixtures.says(briefing, "Difficulty: Normal"))
	for entry: RosterEntry in riverside.roster:
		var shown: int = 0
		for text: String in MenuFixtures.texts(MenuFixtures.named(briefing, "RosterGrid")):
			if text == app.catalog.find(entry.type_id).display_name:
				shown += 1
		assert_eq(shown, Difficulty.pick(entry.counts, 2), "%s slots" % entry.type_id)


func test_new_campaign_takes_the_chosen_tier() -> void:
	for tier: int in [0, 4]:
		_store().delete()
		var app: App = _app()
		_begin_campaign(app, tier)
		assert_eq(app.state.tier, tier)
		assert_eq(_store().load().tier, tier, "saved with it")


func test_new_campaign_autosaves_at_once() -> void:
	var app: App = _app()
	assert_false(_store().exists())
	_begin_campaign(app)
	var saved: CampaignState = _store().load()
	assert_not_null(saved)
	assert_eq(saved.to_dict(), app.state.to_dict(), "the save is the new campaign as it stands")


func test_the_new_seed_comes_from_the_views_rng_and_is_not_negative() -> void:
	# Each begins afresh: with a save around, the menu would ask before replacing.
	var one: App = _app(null, 1)
	_begin_campaign(one)
	_store().delete()
	var again: App = _app(null, 1)
	_begin_campaign(again)
	_store().delete()
	var other: App = _app(null, 2)
	_begin_campaign(other)
	assert_eq(one.state.campaign_seed, again.state.campaign_seed, "the same dice, the same campaign")
	assert_ne(one.state.campaign_seed, other.state.campaign_seed)
	assert_gte(one.state.campaign_seed, 0)
	assert_gte(other.state.campaign_seed, 0)


func test_continue_resumes_the_saved_mission_at_its_difficulty() -> void:
	var saved: CampaignState = CampaignState.new_campaign(99, 3)
	saved.mission_index = 1
	_store().save(saved)
	var app: App = _app()
	_press(app, "CampaignButton")
	var detail: Label = MenuFixtures.named(app.current_screen(), "ContinueDetail") as Label
	assert_eq(detail.text, "Next: The Ford (Hard)")
	_press(app, "ContinueButton")
	var briefing: Briefing = app.current_screen() as Briefing
	assert_not_null(briefing)
	assert_true(MenuFixtures.says(briefing, "The Ford"))
	assert_eq(app.state.campaign_seed, 99)
	assert_eq(app.state.mission_index, 1)
	assert_eq(app.state.tier, 3)


func test_continue_is_off_with_no_save_and_new_campaign_does_not_ask() -> void:
	var app: App = _app()
	_press(app, "CampaignButton")
	assert_true((MenuFixtures.named(app.current_screen(), "ContinueButton") as Button).disabled)
	_press(app, "NewCampaignButton")
	_press(app, "BeginButton")
	assert_true(app.current_screen() is Briefing, "no save, no question")


func test_continue_on_a_finished_campaign_shows_the_roll() -> void:
	var saved: CampaignState = CampaignState.new_campaign(5, 1)
	saved.mission_index = 3
	_store().save(saved)
	var app: App = _app()
	_press(app, "CampaignButton")
	_press(app, "ContinueButton")
	assert_true(app.current_screen() is CampaignComplete)


func test_a_damaged_save_turns_continue_off_with_the_reason() -> void:
	DirAccess.make_dir_recursive_absolute(DIR)
	var file: FileAccess = FileAccess.open(_store().path, FileAccess.WRITE)
	file.store_string("{\"version\": 1, \"tier\":")
	file.close()
	var app: App = _app()
	_press(app, "CampaignButton")
	var menu: Node = app.current_screen()
	assert_true((MenuFixtures.named(menu, "ContinueButton") as Button).disabled)
	assert_string_contains((MenuFixtures.named(menu, "ContinueDetail") as Label).text, "not valid JSON")
	_press(app, "NewCampaignButton")
	_press(app, "BeginButton")
	assert_not_null(MenuFixtures.named(menu, "ReplaceConfirm"), "the damaged file would still be overwritten")


func test_a_save_from_a_longer_campaign_cannot_be_continued() -> void:
	var saved: CampaignState = CampaignState.new_campaign(5, 1)
	saved.mission_index = 99
	_store().save(saved)
	var app: App = _app()
	_press(app, "CampaignButton")
	var menu: Node = app.current_screen()
	assert_true((MenuFixtures.named(menu, "ContinueButton") as Button).disabled)
	assert_string_contains((MenuFixtures.named(menu, "ContinueDetail") as Label).text, "past the end")


func test_replacing_a_save_asks_and_yes_replaces_it() -> void:
	var old: CampaignState = CampaignState.new_campaign(111, 4)
	_store().save(old)
	var app: App = _app()
	_press(app, "CampaignButton")
	_press(app, "NewCampaignButton")
	_press(app, "BeginButton")
	assert_true(app.current_screen() is CampaignMenu, "not yet: the question is up")
	assert_eq(_store().load().campaign_seed, 111, "the old save is still there")
	_press(app, "ConfirmButton")
	assert_true(app.current_screen() is Briefing)
	assert_eq(app.state.tier, 2, "Normal, the default")
	assert_ne(_store().load().campaign_seed, 111, "replaced")


func test_declining_leaves_the_save_alone() -> void:
	_store().save(CampaignState.new_campaign(111, 4))
	var before: String = _file(_store().path)
	var app: App = _app()
	_press(app, "CampaignButton")
	_press(app, "NewCampaignButton")
	_press(app, "BeginButton")
	_press(app, "CancelButton")
	assert_true(app.current_screen() is CampaignMenu)
	assert_eq(_file(_store().path), before)


func test_the_briefing_goes_back_to_the_campaign_menu_where_continue_now_works() -> void:
	var app: App = _app()
	_begin_campaign(app)
	_press(app, "BackButton")
	assert_true(app.current_screen() is CampaignMenu)
	assert_false((MenuFixtures.named(app.current_screen(), "ContinueButton") as Button).disabled)


func test_a_save_that_fails_is_told_but_the_campaign_goes_on() -> void:
	# A file where the save's directory should be.
	DirAccess.make_dir_recursive_absolute(DIR)
	var blocker: FileAccess = FileAccess.open(DIR + "/blocker", FileAccess.WRITE)
	blocker.store_string("x")
	blocker.close()
	var app: App = (load("res://view/app/app.tscn") as PackedScene).instantiate() as App
	app.store = CampaignStore.new(DIR + "/blocker/campaign.json")
	app.settings_path = _settings_path()
	add_child_autofree(app)
	_begin_campaign(app)
	assert_true(app.current_screen() is Briefing, "the player isn't stopped")
	var notice: Label = app.find_child("NoticeLabel", true, false) as Label
	assert_true(notice.visible)
	assert_string_contains(notice.text, "Could not save your progress")


# --- the mission --------------------------------------------------------------


func test_start_builds_the_mission_from_the_state_exactly() -> void:
	var app: App = _app(_tiny())
	_begin_campaign(app)
	var briefing: Briefing = app.current_screen() as Briefing
	var plan: DeployPlan = briefing.plan()
	_press(app, "StartButton")
	var main: MainView = app.current_screen() as MainView
	assert_not_null(main, "the mission screen")
	var launch: MissionLaunch = main.launch
	var mission: MissionDef = app.campaign.missions[0]
	assert_eq(launch.mission, mission)
	assert_eq(launch.world_seed, app.state.mission_seed(0), "seed = state.mission_seed(mission_index)")
	assert_eq(launch.tier, app.state.tier)
	assert_true(launch.campaign_mode)
	assert_eq(app.current_plan(), plan, "the briefing's own plan")
	var expected: DeployCommand = plan.command(0, mission)
	assert_eq(launch.deploy.type_ids, expected.type_ids)
	assert_eq(launch.deploy.soldier_ids, expected.soldier_ids)
	assert_eq(launch.deploy.kills, expected.kills)
	assert_eq(launch.deploy.hp, expected.hp)
	assert_eq(launch.deploy.tick, 0)


func test_edge_scroll_comes_from_the_settings_when_a_mission_starts() -> void:
	GameSettings.set_edge_scroll(true, _settings_path())
	var app: App = _app(_tiny())
	var main: MainView = _into_the_mission(app)
	assert_true(main.edge_scroll)
	assert_true((main.get_node("CameraRig") as RtsCamera).edge_scroll)


func test_edge_scroll_is_off_by_default() -> void:
	var app: App = _app(_tiny())
	assert_false(_into_the_mission(app).edge_scroll)


func test_a_mission_leaves_one_screen_not_two() -> void:
	var app: App = _app(_tiny())
	_into_the_mission(app)
	var screens: int = 0
	for child: Node in app.get_children():
		if child is MenuScreen:
			screens += 1
	assert_eq(screens, 0, "the briefing is gone while the mission plays")


# --- victory ------------------------------------------------------------------


func test_a_victory_is_applied_and_saved_as_results_appear() -> void:
	var app: App = _app(_tiny(WON, true))
	_into_the_mission(app)
	var saved_before: String = _file(_store().path)
	_decide(app)
	var results: Results = app.current_screen() as Results
	assert_not_null(results)
	assert_true(results.is_victory())
	assert_eq(app.state.mission_index, 1, "applied before the player leaves Results")
	assert_eq(app.state.soldiers.size(), 1, "the recruit joined the roll")
	assert_ne(_file(_store().path), saved_before, "and saved: closing the game here loses nothing")
	assert_eq(_store().load().to_dict(), app.state.to_dict())


func test_continue_after_the_victory_was_applied_does_not_apply_it_again() -> void:
	var app: App = _app(_tiny(WON, true))
	_into_the_mission(app)
	_decide(app)
	var saved_on_results: String = _file(_store().path)
	_press(app, "ContinueButton")
	assert_eq(app.state.mission_index, 1, "once")
	assert_eq(app.state.history.size(), 1)
	assert_eq(app.state.soldiers.size(), 1)
	assert_eq(_file(_store().path), saved_on_results, "no second save")
	assert_true(app.current_screen() is Briefing)


func test_continue_applies_the_victory_saves_and_goes_to_the_next_briefing() -> void:
	var app: App = _app(_tiny(WON, true))
	_into_the_mission(app)
	_decide(app)
	_press(app, "ContinueButton")
	assert_eq(app.state.mission_index, 1)
	assert_eq(app.state.soldiers.size(), 1, "the recruit survived and joined the roll")
	assert_eq(app.state.soldiers[0].missions, 1)
	assert_eq(app.state.history.size(), 1)
	assert_eq(app.state.history[0]["id"], "test_flat")
	var saved: CampaignState = _store().load()
	assert_eq(saved.to_dict(), app.state.to_dict(), "autosaved after the apply")
	var briefing: Briefing = app.current_screen() as Briefing
	assert_not_null(briefing)
	assert_true(MenuFixtures.says(briefing, "Second"))
	assert_true(MenuFixtures.says(briefing, "Mission 2 of 2"))
	assert_eq(briefing.plan().soldier_ids[0], 1, "the survivor goes on to the next mission")
	assert_false(briefing.plan().is_recruit[0])


func test_continue_after_the_last_mission_shows_the_campaign_complete_screen() -> void:
	var app: App = _app(_tiny())
	_into_the_mission(app)
	_decide(app)
	_press(app, "ContinueButton")
	assert_true(app.current_screen() is CampaignComplete)
	assert_true(app.state.is_complete(app.campaign))
	assert_eq(_store().load().mission_index, 1)
	assert_true(MenuFixtures.says(app.current_screen(), "Survivors: 1"))


func test_continue_pressed_twice_applies_once() -> void:
	var app: App = _app(_tiny(WON, true))
	_into_the_mission(app)
	_decide(app)
	var results: Results = app.current_screen() as Results
	results.continue_pressed.emit()
	results.continue_pressed.emit()
	assert_eq(app.state.mission_index, 1)
	assert_eq(app.state.soldiers.size(), 1, "the recruit joined once")
	assert_eq(app.state.history.size(), 1)


func test_main_menu_after_a_victory_applies_and_saves_too() -> void:
	var app: App = _app(_tiny(WON, true))
	_into_the_mission(app)
	_decide(app)
	_press(app, "MainMenuButton")
	assert_true(app.current_screen() is MainMenu)
	assert_eq(app.state.mission_index, 1)
	var saved: CampaignState = _store().load()
	assert_eq(saved.mission_index, 1, "applied once, saved")
	assert_eq(saved.soldiers.size(), 1)


func test_the_finished_campaign_can_be_continued_from_the_menu_after_leaving_it() -> void:
	var app: App = _app(_tiny())
	_into_the_mission(app)
	_decide(app)
	_press(app, "MainMenuButton")
	_press(app, "CampaignButton")
	var detail: Label = MenuFixtures.named(app.current_screen(), "ContinueDetail") as Label
	assert_eq(detail.text, "Campaign complete (Normal)")
	_press(app, "ContinueButton")
	assert_true(app.current_screen() is CampaignComplete)


# --- defeat -------------------------------------------------------------------


func test_a_defeat_shows_results_and_changes_nothing() -> void:
	var app: App = _app(_tiny(LOST))
	_into_the_mission(app)
	var saved_before: String = _file(_store().path)
	var state_before: Dictionary = app.state.to_dict()
	_decide(app)
	var results: Results = app.current_screen() as Results
	assert_not_null(results)
	assert_false(results.is_victory())
	assert_not_null(MenuFixtures.named(results, "RetryButton"))
	assert_eq(app.state.to_dict(), state_before)
	assert_eq(_file(_store().path), saved_before)


func test_retry_leaves_the_save_unchanged_and_replays_with_the_same_seed() -> void:
	var app: App = _app(_tiny(LOST))
	var first: MainView = _into_the_mission(app)
	var seed_before: int = first.launch.world_seed
	var saved_before: String = _file(_store().path)
	_decide(app)
	_press(app, "RetryButton")
	assert_eq(_file(_store().path), saved_before, "the save is exactly as it was")
	assert_eq(app.state.mission_index, 0)
	assert_eq(app.state.soldiers.size(), 0, "nothing from the failed attempt")
	assert_eq(app.state.next_soldier_id, 1)
	var briefing: Briefing = app.current_screen() as Briefing
	assert_not_null(briefing, "back to the briefing of the same mission")
	_press(app, "StartButton")
	var second: MainView = app.current_screen() as MainView
	assert_ne(second, first)
	assert_eq(second.launch.world_seed, seed_before, "the same waves")
	assert_eq(second.launch.deploy.soldier_ids, first.launch.deploy.soldier_ids)


func test_retry_reloads_the_save() -> void:
	var app: App = _app(_tiny(LOST))
	_into_the_mission(app)
	_decide(app)
	# The save as the pre-mission state: put a veteran in it, as if it had been
	# saved with one, and see that Retry shows what the file says.
	var edited: CampaignState = _store().load()
	edited.soldiers.append(CampaignFixtures.soldier(1, SHIELDMAN, 7))
	edited.next_soldier_id = 2
	_store().save(edited)
	_press(app, "RetryButton")
	assert_eq(app.state.soldiers.size(), 1, "read from the file")
	var briefing: Briefing = app.current_screen() as Briefing
	assert_eq(briefing.plan().soldier_ids[0], 1)
	assert_false(briefing.plan().is_recruit[0], "the veteran from the file is fielded")


func test_retry_with_the_save_gone_writes_the_unchanged_state_back() -> void:
	var app: App = _app(_tiny(LOST))
	_into_the_mission(app)
	_decide(app)
	_store().delete()
	_press(app, "RetryButton")
	assert_true(app.current_screen() is Briefing)
	assert_true(_store().exists(), "mended")
	assert_eq(_store().load().to_dict(), app.state.to_dict())


func test_retry_keeps_who_was_benched() -> void:
	var app: App = _app(_tiny(LOST))
	app.state = CampaignFixtures.state([
		CampaignFixtures.soldier(1, SHIELDMAN, 5), CampaignFixtures.soldier(2, SHIELDMAN, 2),
	], 2)
	_store().save(app.state)
	app.show_briefing()
	var briefing: Briefing = app.current_screen() as Briefing
	assert_eq(briefing.plan().soldier_ids, PackedInt32Array([1]), "the better veteran goes")
	(MenuFixtures.named(briefing, "Bench1") as CheckBox).button_pressed = true
	_press(app, "StartButton")
	assert_eq((app.current_screen() as MainView).launch.deploy.soldier_ids, PackedInt32Array([2]))
	_decide(app)
	_press(app, "RetryButton")
	var again: Briefing = app.current_screen() as Briefing
	assert_eq(again.benched(), PackedInt32Array([1]))
	assert_eq(again.plan().soldier_ids, PackedInt32Array([2]))


## Two missions: the first is won, the second is lost, each on its first step.
func _won_then_lost() -> CampaignDef:
	var missions: Array[MissionDef] = [_mission(WON), _mission(LOST, &"second")]
	return CampaignFixtures.campaign(missions)


func test_retry_does_not_trust_another_campaigns_save() -> void:
	# A New Campaign whose autosave failed leaves the file as an older campaign's.
	var app: App = _app(_tiny(LOST))
	_into_the_mission(app)
	_decide(app)
	var seed_before: int = app.state.campaign_seed
	var elsewhere: CampaignState = CampaignState.new_campaign(seed_before + 1, 2)
	elsewhere.soldiers.append(CampaignFixtures.soldier(1, SHIELDMAN, 9))
	elsewhere.next_soldier_id = 2
	_store().save(elsewhere)
	_press(app, "RetryButton")
	assert_eq(app.state.campaign_seed, seed_before, "the player's own campaign")
	assert_eq(app.state.soldiers.size(), 0, "not the other one's roster")
	assert_true(app.current_screen() is Briefing)
	var rewritten: CampaignState = _store().load()
	assert_eq(rewritten.campaign_seed, seed_before, "the file is made good")
	assert_eq(rewritten.to_dict(), app.state.to_dict())


func test_retry_does_not_roll_back_to_an_older_point_of_the_same_campaign() -> void:
	# A victory whose autosave failed leaves the file one mission behind.
	var app: App = _app(_won_then_lost())
	_into_the_mission(app)
	_decide(app)
	var old_file: CampaignState = _store().load()
	assert_eq(old_file.mission_index, 0, "the file as it stands before the first victory")
	_press(app, "ContinueButton")
	assert_eq(app.state.mission_index, 1)
	assert_eq(app.state.soldiers.size(), 1)
	_press(app, "StartButton")
	_decide(app)
	assert_false((app.current_screen() as Results).is_victory(), "the second mission is lost")
	_store().save(old_file)
	_press(app, "RetryButton")
	assert_eq(app.state.mission_index, 1, "still at the second mission")
	assert_eq(app.state.soldiers.size(), 1, "and the survivor is still on the roll")
	assert_eq(_store().load().mission_index, 1, "the file is brought forward again")
	var briefing: Briefing = app.current_screen() as Briefing
	assert_true(MenuFixtures.says(briefing, "Mission 2 of 2"))


func test_retry_with_a_save_that_has_gone_past_the_end_uses_the_state_in_memory() -> void:
	var app: App = _app(_tiny(LOST))
	_into_the_mission(app)
	_decide(app)
	var finished: CampaignState = CampaignState.new_campaign(1, 2)
	finished.mission_index = app.campaign.missions.size()
	_store().save(finished)
	_press(app, "RetryButton")
	assert_true(app.current_screen() is Briefing, "no briefing for a mission that doesn't exist")
	assert_eq(app.state.mission_index, 0)
	assert_eq(_store().load().mission_index, 0, "and the file is made good")


func test_main_menu_after_a_defeat_changes_nothing() -> void:
	var app: App = _app(_tiny(LOST))
	_into_the_mission(app)
	var saved_before: String = _file(_store().path)
	_press(app, "MainMenuButton")
	assert_true(app.current_screen() is MainMenu)
	assert_eq(_file(_store().path), saved_before)
	assert_eq(app.state.mission_index, 0)
	assert_eq(app.state.soldiers.size(), 0)


# --- pause menu: restart, quit, settings ---------------------------------------
	_decide(app)
	assert_eq(app.state.mission_index, 1, "applied as Results appeared")


func test_restart_asks_and_keep_playing_keeps_the_mission() -> void:
	var app: App = _app(_tiny())
	var main: MainView = _into_the_mission(app)
	main.restart_requested.emit()
	var dialog: ConfirmDialog = app.current_overlay() as ConfirmDialog
	assert_not_null(dialog, "a question first: the attempt would be lost")
	assert_eq(app.current_screen(), main)
	MenuFixtures.press(dialog, "CancelButton")
	assert_null(app.current_overlay())
	assert_eq(app.current_screen(), main, "the same mission goes on")


func test_restart_builds_a_fresh_mission_from_the_same_plan_and_seed() -> void:
	var app: App = _app(_tiny())
	var first: MainView = _into_the_mission(app)
	var plan: DeployPlan = app.current_plan()
	var saved_before: String = _file(_store().path)
	first.restart_requested.emit()
	MenuFixtures.press(app.current_overlay(), "ConfirmButton")
	var second: MainView = app.current_screen() as MainView
	assert_not_null(second)
	assert_ne(second, first)
	assert_null(app.current_overlay())
	assert_eq(second.launch.world_seed, first.launch.world_seed)
	assert_eq(app.current_plan(), plan, "the same roster")
	assert_eq(second.launch.deploy.soldier_ids, first.launch.deploy.soldier_ids)
	assert_eq(second.world.tick, 0, "a fresh world")
	assert_eq(_file(_store().path), saved_before, "restarting changes nothing saved")


func test_quit_to_the_main_menu_leaves_the_save_alone() -> void:
	var app: App = _app(_tiny())
	var main: MainView = _into_the_mission(app)
	var saved_before: String = _file(_store().path)
	main.quit_requested.emit()
	assert_true(app.current_screen() is MainMenu)
	assert_eq(_file(_store().path), saved_before)
	assert_eq(app.state.mission_index, 0)


func test_settings_over_the_paused_mission_sits_above_the_pause_menu_and_holds_the_mission() -> void:
	GameSettings.set_edge_scroll(true, _settings_path())
	var app: App = _app(_tiny())
	var main: MainView = _into_the_mission(app)
	assert_true(main.edge_scroll)
	main.pause_menu().open()
	assert_true(main.paused)
	main.settings_requested.emit()
	var settings: SettingsMenu = app.current_overlay() as SettingsMenu
	assert_not_null(settings)
	assert_gt((settings.get_parent() as CanvasLayer).layer, PauseMenu.MENU_LAYER, "over the pause menu's layer")
	assert_false(main.pause_menu().enabled, "its Esc must not close the menu behind Settings")
	assert_false(main.edge_scroll, "the camera mustn't pan behind the overlay")
	assert_false((main.get_node("CameraRig") as RtsCamera).edge_scroll)
	assert_true(main.paused, "still paused")


func test_esc_closes_settings_not_the_pause_menu_behind_it() -> void:
	GameSettings.set_edge_scroll(true, _settings_path())
	var app: App = _app(_tiny())
	var main: MainView = _into_the_mission(app)
	main.pause_menu().open()
	main.settings_requested.emit()
	_key(KEY_ESCAPE)
	assert_null(app.current_overlay(), "Settings closed")
	assert_true(main.pause_menu().is_open(), "the pause menu is still up")
	assert_true(main.paused)
	assert_true(main.pause_menu().enabled, "and works again")
	assert_true(main.edge_scroll, "edge scroll is back as the settings say")


func test_settings_closed_with_back_restores_the_mission_too() -> void:
	var app: App = _app(_tiny())
	var main: MainView = _into_the_mission(app)
	main.pause_menu().open()
	main.settings_requested.emit()
	MenuFixtures.press(app.current_overlay(), "BackButton")
	assert_null(app.current_overlay())
	assert_true(main.pause_menu().enabled)
	assert_true(main.pause_menu().is_open())


func test_edge_scroll_turned_on_in_settings_reaches_the_live_mission_on_close() -> void:
	var app: App = _app(_tiny())
	var main: MainView = _into_the_mission(app)
	main.pause_menu().open()
	main.settings_requested.emit()
	(MenuFixtures.named(app.current_overlay(), "EdgeScrollCheck") as CheckBox).button_pressed = true
	assert_false(main.edge_scroll, "not while the overlay is up")
	MenuFixtures.press(app.current_overlay(), "BackButton")
	assert_true(main.edge_scroll)
	assert_true(GameSettings.edge_scroll(_settings_path()), "and it was saved")


func test_a_mission_decided_with_settings_open_hands_over_to_the_results_and_closes_it() -> void:
	var app: App = _app(_tiny())
	var main: MainView = _into_the_mission(app)
	main.settings_requested.emit()
	_decide(app)
	assert_true(app.current_screen() is Results, "the results replaced the mission, and closed Settings")
	assert_null(app.current_overlay())


func test_the_main_menu_opens_settings_as_an_overlay() -> void:
	var app: App = _app()
	var menu: Node = app.current_screen()
	_press(app, "SettingsButton")
	assert_true(app.current_overlay() is SettingsMenu)
	assert_eq(app.current_screen(), menu, "the main menu stays beneath")
	(MenuFixtures.named(app.current_overlay(), "FullscreenCheck") as CheckBox).button_pressed = true
	assert_true(GameSettings.fullscreen(_settings_path()))
	MenuFixtures.press(app.current_overlay(), "BackButton")
	assert_null(app.current_overlay())


func test_changing_the_screen_closes_an_open_overlay() -> void:
	var app: App = _app()
	app.open_settings()
	assert_not_null(app.current_overlay())
	app.show_campaign_menu()
	assert_null(app.current_overlay())


## An App whose window mode is recorded instead of applied: the list of what it
## was asked for, in order.
func _recording_app(calls: Array[bool]) -> App:
	var app: App = (load("res://view/app/app.tscn") as PackedScene).instantiate() as App
	app.store = _store()
	app.settings_path = _settings_path()
	app.apply_window_mode = func(enabled: bool) -> void: calls.append(enabled)
	add_child_autofree(app)
	return app


func _tick(app: App, check_name: String, on: bool) -> void:
	(MenuFixtures.named(app.current_overlay(), check_name) as CheckBox).button_pressed = on


func test_the_window_mode_changes_only_when_fullscreen_itself_is_flipped() -> void:
	var calls: Array[bool] = []
	var app: App = _recording_app(calls)
	assert_eq(calls, [] as Array[bool], "windowed at boot: nothing to apply")
	app.open_settings()
	_tick(app, "EdgeScrollCheck", true)
	_tick(app, "EdgeScrollCheck", false)
	assert_eq(calls, [] as Array[bool], "Edge scroll never touches the window")
	_tick(app, "FullscreenCheck", true)
	assert_eq(calls, [true] as Array[bool])
	_tick(app, "EdgeScrollCheck", true)
	assert_eq(calls, [true] as Array[bool], "and flipping it in fullscreen doesn't drop out of it")
	_tick(app, "FullscreenCheck", false)
	assert_eq(calls, [true, false] as Array[bool])


func test_a_saved_fullscreen_choice_is_applied_once_at_boot_and_edge_scroll_leaves_it_be() -> void:
	GameSettings.set_fullscreen(true, _settings_path())
	var calls: Array[bool] = []
	var app: App = _recording_app(calls)
	assert_eq(calls, [true] as Array[bool], "put in fullscreen at boot")
	app.open_settings()
	_tick(app, "EdgeScrollCheck", true)
	assert_eq(calls, [true] as Array[bool], "still only the one call")


func test_a_notice_shows_then_goes_when_its_time_is_up() -> void:
	var app: App = _app()
	app.notice_seconds = 0.1
	var notice: Label = app.find_child("NoticeLabel", true, false) as Label
	assert_false(notice.visible)
	app.show_notice("Something happened")
	assert_true(notice.visible)
	assert_eq(notice.text, "Something happened")
	await get_tree().create_timer(0.3).timeout
	assert_false(notice.visible, "gone after its time")


func test_an_older_notices_timer_does_not_hide_a_newer_notice() -> void:
	var app: App = _app()
	app.notice_seconds = 0.3
	var notice: Label = app.find_child("NoticeLabel", true, false) as Label
	app.show_notice("First")
	await get_tree().create_timer(0.2).timeout
	app.show_notice("Second")
	await get_tree().create_timer(0.2).timeout
	assert_true(notice.visible, "the first one's timer ran out, the second's hasn't")
	assert_eq(notice.text, "Second")
	await get_tree().create_timer(0.3).timeout
	assert_false(notice.visible)
