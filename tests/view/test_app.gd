extends GutTest
## The App: the main scene, one screen at a time, and the campaign flow wired
## through MainView's signals. The screens are tested alone elsewhere; here the
## walk is: MainMenu -> CampaignMenu -> Briefing -> mission -> Results -> next
## Briefing or CampaignComplete, with Retry after a defeat, Settings over a
## paused mission, and the saves written at the right moments; then the skirmish
## flow: MainMenu -> SkirmishMenu -> the skirmish -> SkirmishResults -> Rematch,
## Change army or Main menu (a skirmish catalog over the tiny map is injected
## into every App here). Campaign missions are the tiny TIMER-0 fixtures
## (ViewFixtures): decided on their first step, so no test plays a real one; the
## menus walk the shipped campaign. A skirmish is decided by killing a side's
## units after one step.
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
	app.skirmish = _skirmish_catalog()
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


# --- a mission that can't be built --------------------------------------------


func test_a_mission_that_cannot_be_built_returns_to_the_main_menu_with_a_notice() -> void:
	var def: CampaignDef = _tiny()
	var app: App = _app(def)
	_begin_campaign(app)
	assert_true(app.current_screen() is Briefing)
	var saved_before: String = _file(_store().path)
	def.missions[0].map = null
	_press(app, "StartButton")
	assert_push_error("MissionSetup")
	# The failure is sent deferred, so the App changes screens after MainView
	# has finished entering the tree.
	await get_tree().process_frame
	assert_true(app.current_screen() is MainMenu, "not a blank mission screen")
	var notice: Label = app.find_child("NoticeLabel", true, false) as Label
	assert_true(notice.visible)
	assert_string_contains(notice.text, "could not be started")
	assert_eq(app.state.mission_index, 0, "the campaign is as it was")
	assert_eq(_file(_store().path), saved_before)
	assert_null(app.current_plan(), "no half-launched plan is kept")


func test_the_campaign_can_be_continued_after_a_mission_failed_to_build() -> void:
	var def: CampaignDef = _tiny()
	var app: App = _app(def)
	_begin_campaign(app)
	var map: MapInfo = def.missions[0].map
	def.missions[0].map = null
	_press(app, "StartButton")
	assert_push_error("MissionSetup")
	await get_tree().process_frame
	def.missions[0].map = map
	_press(app, "CampaignButton")
	_press(app, "ContinueButton")
	assert_true(app.current_screen() is Briefing, "the same mission again")
	_press(app, "StartButton")
	assert_true(app.current_screen() is MainView, "and now it builds")


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
	var old_file: CampaignState = _store().load()
	assert_eq(old_file.mission_index, 0, "the file as it stands before the first victory")
	_decide(app)
	assert_eq(app.state.mission_index, 1, "applied as Results appeared")
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
	_decide(app)
	_press(app, "MainMenuButton")
	assert_true(app.current_screen() is MainMenu)
	assert_eq(_file(_store().path), saved_before)
	assert_eq(app.state.mission_index, 0)
	assert_eq(app.state.soldiers.size(), 0)


# --- pause menu: restart, quit, settings ---------------------------------------


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
	assert_false((main.get_node("CameraRig") as RtsCamera).edge_scroll, "but the pause menu is still up, so the camera holds")


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
	# Real-time timers, so the checks sit in the middle of the gaps (0.25 s
	# from each timer running out) rather than near an edge: the first notice
	# runs out at 0.8 s, the second, shown at 0.5 s, at 1.3 s; look at 1.05 s.
	var app: App = _app()
	app.notice_seconds = 0.8
	var notice: Label = app.find_child("NoticeLabel", true, false) as Label
	app.show_notice("First")
	await get_tree().create_timer(0.5).timeout
	app.show_notice("Second")
	await get_tree().create_timer(0.55).timeout
	assert_true(notice.visible, "the first one's timer ran out, the second's hasn't")
	assert_eq(notice.text, "Second")
	await get_tree().create_timer(0.5).timeout
	assert_false(notice.visible, "the second one's has now")

# --- the skirmish -------------------------------------------------------------


const LIGHT: UnitType.Faction = UnitType.Faction.LIGHT
const DARK: UnitType.Faction = UnitType.Faction.DARK


## What the skirmish screen offers, over the tiny map: that one map, the
## shipped templates, budgets and time limits.
func _skirmish_catalog() -> SkirmishCatalog:
	var shipped: SkirmishCatalog = load("res://data/skirmish/skirmish.tres") as SkirmishCatalog
	var catalog: SkirmishCatalog = SkirmishCatalog.new()
	catalog.maps = [ViewFixtures.skirmish_map()]
	catalog.templates = shipped.templates
	catalog.budgets = shipped.budgets
	catalog.default_budget = shipped.default_budget
	catalog.time_limits_minutes = shipped.time_limits_minutes
	catalog.default_time_limit_minutes = shipped.default_time_limit_minutes
	return catalog


## From the main menu to the setup screen, `presses` (button names, in order),
## then the army cleared and two of the side's cheapest units bought so the
## world stays small, then Start. Returns the MainView.
func _into_the_skirmish(app: App, presses: Array[String] = [], side_unit: StringName = &"shieldman") -> MainView:
	_press(app, "SkirmishButton")
	for button_name: String in presses:
		_press(app, button_name)
	_press(app, "Clear")
	for i: int in 2:
		_press(app, "Plus_%s" % side_unit)
	_press(app, "Start")
	return app.current_screen() as MainView


## Plays the skirmish out: one step (the sim records both armies), `kill_ai`
## and `kill_player` kill a side, one more step decides it, and the end delay
## runs out so the results come up.
func _end_skirmish(app: App, kill_ai: bool, kill_player: bool = false) -> void:
	var main: MainView = app.current_screen() as MainView
	main.end_delay = 0.0
	main._physics_process(1.0 / World.TICK_RATE)
	var setup: SkirmishSetup = main.launch.skirmish
	for unit: Unit in main.world.units:
		if (kill_ai and unit.faction == setup.ai_faction()) \
				or (kill_player and unit.faction == setup.player_faction()):
			unit.state = Unit.State.DEAD
	main._physics_process(1.0 / World.TICK_RATE)
	main._process(0.1)


## What the App draws from its rng for a skirmish: the template's index (only
## when the enemy is left to chance), then the 63-bit seed.
func _expected_draw(rng_seed: int, templates: int, random_enemy: bool) -> Array[int]:
	var dice: RandomNumberGenerator = RandomNumberGenerator.new()
	dice.seed = rng_seed
	var index: int = dice.randi_range(0, templates - 1) if random_enemy else -1
	var world_seed: int = ((dice.randi() & 0x7FFFFFFF) << 32) | dice.randi()
	return [index, world_seed]


func _army_text(setup: SkirmishSetup, side: int) -> String:
	return SkirmishMenu.army_to_text(setup.armies[side], MenuFixtures.catalog())


func _screens(app: App) -> int:
	var n: int = 0
	for child: Node in app.get_children():
		if child is MenuScreen:
			n += 1
	return n


func test_the_main_menu_opens_the_skirmish_setup_and_back_returns() -> void:
	var app: App = _app()
	_press(app, "SkirmishButton")
	assert_true(app.current_screen() is SkirmishMenu)
	assert_eq(_screens(app), 1, "the main menu is replaced, not stacked")
	_press(app, "Back")
	assert_true(app.current_screen() is MainMenu)


func test_esc_on_the_skirmish_setup_goes_back_to_the_main_menu() -> void:
	var app: App = _app()
	_press(app, "SkirmishButton")
	_key(KEY_ESCAPE)
	assert_true(app.current_screen() is MainMenu)


func test_the_app_loads_the_shipped_skirmish_catalog_unless_given_one() -> void:
	var app: App = (load("res://view/app/app.tscn") as PackedScene).instantiate() as App
	app.store = _store()
	app.settings_path = _settings_path()
	add_child_autofree(app)
	assert_not_null(app.skirmish)
	assert_eq(app.skirmish.maps.size(), 3)
	assert_eq(app.skirmish.template(&"dark_balanced").display_name, "Balanced")


func test_the_setup_screen_opens_on_the_defaults_with_nothing_remembered() -> void:
	var app: App = _app()
	_press(app, "SkirmishButton")
	var menu: SkirmishMenu = app.current_screen() as SkirmishMenu
	var choice: Dictionary = menu.current_choice()
	assert_eq(choice["map"], "test_flat")
	assert_eq(choice["mode"], SkirmishRules.Mode.BODY_COUNT)
	assert_eq(choice["budget"], 1000)
	assert_eq(choice["side"], LIGHT)
	assert_eq(choice["ai_choice"], "random")


func test_the_setup_screen_opens_on_what_the_settings_remember() -> void:
	GameSettings.set_skirmish_choice({
		"map": "test_flat", "mode": 2, "minutes": 5, "budget": 600, "side": 1, "start": 1,
		"ai_choice": "light_shock", "army": "husk:10", "army_side": 1,
	}, _settings_path())
	var app: App = _app()
	_press(app, "SkirmishButton")
	var choice: Dictionary = (app.current_screen() as SkirmishMenu).current_choice()
	assert_eq(choice["mode"], SkirmishRules.Mode.CAPTURE_THE_FLAGS)
	assert_eq(choice["minutes"], 5)
	assert_eq(choice["budget"], 600)
	assert_eq(choice["side"], DARK)
	assert_eq(choice["start"], 1)
	assert_eq(choice["ai_choice"], "light_shock")
	assert_eq(choice["army"], "husk:10")


func test_start_launches_the_skirmish_in_the_main_view() -> void:
	var app: App = _app()
	var main: MainView = _into_the_skirmish(app, ["Mode1", "Time5", "Budget600", "Spawn1", "Ai_dark_horde"])
	assert_not_null(main, "the mission screen")
	var launch: MissionLaunch = main.launch
	assert_true(launch.is_skirmish())
	assert_true(launch.campaign_mode)
	assert_eq(launch.player_faction(), LIGHT)
	var setup: SkirmishSetup = launch.skirmish
	assert_eq(setup.map.id, &"test_flat")
	assert_eq(setup.rules.mode, SkirmishRules.Mode.KING_OF_THE_HILL)
	assert_eq(setup.rules.time_limit_ticks, 5 * 60 * World.TICK_RATE)
	assert_eq(setup.budget, 600)
	assert_eq(setup.player_spawn, 1)
	assert_eq(setup.armies[0].counts, {&"shieldman": 2} as Dictionary[StringName, int])
	assert_eq(setup.ai_template_id, &"dark_horde")
	assert_eq(setup.armies[1].counts, app.skirmish.template(&"dark_horde").fill(600, MenuFixtures.catalog()).counts)
	assert_eq(setup.armies[1].faction, DARK)
	assert_true(setup.validate(MenuFixtures.catalog()).is_empty(), "a setup the sim accepts")
	assert_eq(launch.world_seed, setup.world_seed)
	assert_not_null(main.world, "the world is built")
	assert_not_null(main.world.skirmish)
	assert_eq(main.world.skirmish.rules.mode, SkirmishRules.Mode.KING_OF_THE_HILL)
	assert_null(app.state, "a skirmish has no campaign")
	assert_false(FileAccess.file_exists(_store().path), "and saves none")


func test_a_dark_player_launches_as_dark_against_a_light_template() -> void:
	var app: App = _app()
	var main: MainView = _into_the_skirmish(app, ["Side1", "Ai_light_siege"], &"husk")
	var setup: SkirmishSetup = main.launch.skirmish
	assert_eq(main.launch.player_faction(), DARK)
	assert_eq(setup.armies[0].counts, {&"husk": 2} as Dictionary[StringName, int])
	assert_eq(setup.ai_template_id, &"light_siege")
	assert_eq(setup.armies[1].faction, LIGHT)


func test_the_world_has_both_armies_after_its_first_step() -> void:
	var app: App = _app()
	var main: MainView = _into_the_skirmish(app, ["Budget600", "Ai_dark_balanced"])
	main._physics_process(1.0 / World.TICK_RATE)
	var setup: SkirmishSetup = main.launch.skirmish
	var light: int = 0
	var dark: int = 0
	for unit: Unit in main.world.units:
		if unit.faction == LIGHT:
			light += 1
		else:
			dark += 1
	assert_eq(light, 2)
	assert_eq(dark, setup.armies[1].size())
	assert_gt(dark, 2, "a template's worth, not the fixture's two")


func test_edge_scroll_comes_from_the_settings_when_a_skirmish_starts() -> void:
	assert_false(_into_the_skirmish(_app()).edge_scroll, "off by default")
	GameSettings.set_edge_scroll(true, _settings_path())
	var main: MainView = _into_the_skirmish(_app())
	assert_true(main.edge_scroll)
	assert_true((main.get_node("CameraRig") as RtsCamera).edge_scroll)


func test_a_chosen_enemy_army_draws_only_the_seed() -> void:
	var app: App = _app(null, 77)
	var main: MainView = _into_the_skirmish(app, ["Ai_dark_storm"])
	var expected: Array[int] = _expected_draw(77, 4, false)
	assert_eq(main.launch.skirmish.ai_template_id, &"dark_storm")
	assert_eq(main.launch.world_seed, expected[1], "the first draw is the seed")
	assert_gte(main.launch.world_seed, 0, "63 bits, never negative")


func test_a_random_enemy_is_drawn_from_the_apps_rng_then_the_seed() -> void:
	var templates: Array[ArmyTemplate] = _skirmish_catalog().templates_for(DARK)
	assert_eq(templates.size(), 4)
	for rng_seed: int in [1, 2, 3, 12345]:
		var app: App = _app(null, rng_seed)
		var main: MainView = _into_the_skirmish(app)
		var expected: Array[int] = _expected_draw(rng_seed, templates.size(), true)
		assert_eq(main.launch.skirmish.ai_template_id, templates[expected[0]].id, "seed %d: the template" % rng_seed)
		assert_eq(main.launch.world_seed, expected[1], "seed %d: then the world's seed" % rng_seed)
		assert_gte(main.launch.world_seed, 0)
		assert_eq(
			main.launch.skirmish.armies[1].counts,
			templates[expected[0]].fill(1000, MenuFixtures.catalog()).counts
		)


func test_the_same_rng_seed_makes_the_same_skirmish() -> void:
	var first: SkirmishSetup = _into_the_skirmish(_app(null, 4242)).launch.skirmish
	var second: SkirmishSetup = _into_the_skirmish(_app(null, 4242)).launch.skirmish
	assert_eq(second.ai_template_id, first.ai_template_id)
	assert_eq(second.world_seed, first.world_seed)
	assert_eq(second.armies[1].counts, first.armies[1].counts)


func test_a_choice_that_names_no_template_of_the_enemys_side_is_taken_as_random() -> void:
	var app: App = _app(null, 99)
	var setup: SkirmishSetup = ViewFixtures.skirmish_setup()
	setup.armies = [setup.armies[0], null]
	# A Light template, for a Light player: the enemy is Dark.
	app.start_skirmish(setup, &"light_siege")
	var expected: Array[int] = _expected_draw(99, 4, true)
	var templates: Array[ArmyTemplate] = app.skirmish.templates_for(DARK)
	assert_eq(setup.ai_template_id, templates[expected[0]].id)
	assert_eq(setup.armies[1].faction, DARK)
	assert_true(app.current_screen() is MainView)
	var other: App = _app(null, 99)
	var again: SkirmishSetup = ViewFixtures.skirmish_setup()
	again.armies = [again.armies[0], null]
	other.start_skirmish(again, &"no_such_template")
	assert_eq(again.ai_template_id, setup.ai_template_id)


# --- remembering the setup ---------------------------------------------------


func test_the_setup_is_remembered_when_the_skirmish_starts() -> void:
	var app: App = _app()
	_into_the_skirmish(app, ["Mode2", "Time5", "Budget600", "Spawn1", "Ai_dark_storm"])
	var remembered: Dictionary = GameSettings.skirmish_choice(_settings_path())
	assert_eq(remembered["map"], "test_flat")
	assert_eq(remembered["mode"], SkirmishRules.Mode.CAPTURE_THE_FLAGS)
	assert_eq(remembered["minutes"], 5)
	assert_eq(remembered["budget"], 600)
	assert_eq(remembered["side"], LIGHT)
	assert_eq(remembered["start"], 1)
	assert_eq(remembered["ai_choice"], "dark_storm", "what was picked")
	assert_eq(remembered["army"], "shieldman:2")
	assert_eq(remembered["army_side"], LIGHT)


func test_a_random_enemy_is_remembered_as_random_not_as_the_template_it_drew() -> void:
	var app: App = _app()
	_into_the_skirmish(app)
	assert_eq(GameSettings.skirmish_choice(_settings_path())["ai_choice"], "random")


func test_the_next_visit_to_the_setup_opens_where_the_player_left_it() -> void:
	var app: App = _app()
	var main: MainView = _into_the_skirmish(app, ["Side1", "Mode1", "Time15", "Budget1500", "Spawn1", "Ai_light_shock"], &"husk")
	main.quit_requested.emit()
	assert_true(app.current_screen() is MainMenu)
	_press(app, "SkirmishButton")
	var choice: Dictionary = (app.current_screen() as SkirmishMenu).current_choice()
	assert_eq(choice["side"], DARK)
	assert_eq(choice["mode"], SkirmishRules.Mode.KING_OF_THE_HILL)
	assert_eq(choice["minutes"], 15)
	assert_eq(choice["budget"], 1500)
	assert_eq(choice["start"], 1)
	assert_eq(choice["ai_choice"], "light_shock")
	assert_eq(choice["army"], "husk:2")


func test_a_new_app_on_the_same_settings_file_remembers_too() -> void:
	_into_the_skirmish(_app(), ["Mode2", "Budget600"])
	var later: App = _app()
	_press(later, "SkirmishButton")
	var choice: Dictionary = (later.current_screen() as SkirmishMenu).current_choice()
	assert_eq(choice["mode"], SkirmishRules.Mode.CAPTURE_THE_FLAGS)
	assert_eq(choice["budget"], 600)
	assert_eq(choice["army"], "shieldman:2")


func test_a_setup_that_cannot_be_remembered_still_plays() -> void:
	# A directory where the file should be: the write fails, the skirmish goes on.
	var app: App = _app()
	DirAccess.make_dir_recursive_absolute(DIR + "/settings_is_a_folder.cfg")
	app.settings_path = DIR + "/settings_is_a_folder.cfg"
	var main: MainView = _into_the_skirmish(app)
	assert_true(main.launch.is_skirmish(), "not worth stopping for")
	DirAccess.remove_absolute(DIR + "/settings_is_a_folder.cfg")


# --- the end of a skirmish -------------------------------------------------------


func test_a_won_skirmish_shows_victory_with_both_armies_tallied() -> void:
	var app: App = _app()
	var main: MainView = _into_the_skirmish(app, ["Budget600", "Ai_dark_horde"])
	_end_skirmish(app, true)
	var results: SkirmishResults = app.current_screen() as SkirmishResults
	assert_not_null(results, "the results replaced the skirmish")
	assert_true(results.is_victory())
	assert_eq((MenuFixtures.named(results, "Outcome") as Label).text, "Victory")
	assert_eq((MenuFixtures.named(results, "Reason") as Label).text, "Dark was wiped out")
	assert_eq((MenuFixtures.named(results, "Heading1") as Label).text, "Dark (AI: Horde)")
	var theirs: PackedStringArray = MenuFixtures.texts(MenuFixtures.named(results, "Table1"))
	assert_true(theirs.has("Husk"), "the Horde's Husks, read from the finished world")
	assert_eq(theirs[theirs.size() - 1], theirs[theirs.size() - 2], "all of them lost")
	assert_false(app.get_children().has(main), "the mission screen is gone")


func test_a_lost_skirmish_shows_defeat() -> void:
	var app: App = _app()
	_into_the_skirmish(app)
	_end_skirmish(app, false, true)
	var results: SkirmishResults = app.current_screen() as SkirmishResults
	assert_not_null(results)
	assert_false(results.is_victory())
	assert_eq((MenuFixtures.named(results, "Outcome") as Label).text, "Defeat")
	assert_eq((MenuFixtures.named(results, "Reason") as Label).text, "Light was wiped out")


func test_a_drawn_skirmish_shows_draw() -> void:
	var app: App = _app()
	_into_the_skirmish(app)
	_end_skirmish(app, true, true)
	var results: SkirmishResults = app.current_screen() as SkirmishResults
	assert_not_null(results)
	assert_true(results.is_draw())
	assert_eq((MenuFixtures.named(results, "Outcome") as Label).text, "Draw")


func test_a_skirmish_changes_nothing_that_is_saved_but_the_choice() -> void:
	var app: App = _app()
	_into_the_skirmish(app)
	var remembered: Dictionary = GameSettings.skirmish_choice(_settings_path())
	_end_skirmish(app, true)
	assert_null(app.state)
	assert_false(FileAccess.file_exists(_store().path), "no campaign save")
	assert_eq(GameSettings.skirmish_choice(_settings_path()), remembered)


func test_main_menu_from_the_skirmish_results_goes_to_the_main_menu() -> void:
	var app: App = _app()
	_into_the_skirmish(app)
	_end_skirmish(app, true)
	_press(app, "MainMenuButton")
	assert_true(app.current_screen() is MainMenu)


# --- rematch and change army ----------------------------------------------------------


func test_rematch_plays_the_same_armies_on_a_new_seed() -> void:
	var app: App = _app()
	var first: MainView = _into_the_skirmish(app, ["Mode2", "Budget600", "Spawn1", "Ai_dark_raiders"])
	var before: SkirmishSetup = first.launch.skirmish
	var seed_before: int = before.world_seed
	var player_before: String = _army_text(before, 0)
	var ai_before: Dictionary = before.armies[1].counts.duplicate()
	_end_skirmish(app, true)
	_press(app, "RematchButton")
	var second: MainView = app.current_screen() as MainView
	assert_not_null(second, "a fresh skirmish")
	assert_ne(second, first)
	var after: SkirmishSetup = second.launch.skirmish
	assert_true(second.launch.is_skirmish())
	assert_ne(after.world_seed, seed_before, "a new seed")
	assert_gte(after.world_seed, 0)
	assert_eq(second.launch.world_seed, after.world_seed)
	assert_eq(_army_text(after, 0), player_before, "the player's army")
	assert_eq(after.armies[1].counts, ai_before, "the AI's army is not rebuilt")
	assert_eq(after.ai_template_id, &"dark_raiders")
	assert_eq(after.map, before.map)
	assert_eq(after.rules.mode, before.rules.mode)
	assert_eq(after.budget, 600)
	assert_eq(after.player_spawn, 1)
	assert_eq(before.world_seed, seed_before, "the setup that was played is left as it was")
	assert_eq(second.world.tick, 0, "a fresh world")


func test_a_rematch_with_a_random_enemy_keeps_the_template_it_drew() -> void:
	var app: App = _app(null, 31)
	var first: MainView = _into_the_skirmish(app)
	var template: StringName = first.launch.skirmish.ai_template_id
	_end_skirmish(app, true)
	_press(app, "RematchButton")
	var second: MainView = app.current_screen() as MainView
	assert_eq(second.launch.skirmish.ai_template_id, template, "the same enemy: a rematch, not a new draw")


func test_rematches_each_take_a_new_seed() -> void:
	var app: App = _app()
	var first: MainView = _into_the_skirmish(app)
	var seeds: Array[int] = [first.launch.world_seed]
	for i: int in 2:
		_end_skirmish(app, true)
		_press(app, "RematchButton")
		seeds.append((app.current_screen() as MainView).launch.world_seed)
	assert_ne(seeds[0], seeds[1])
	assert_ne(seeds[1], seeds[2])
	assert_ne(seeds[0], seeds[2])


func test_change_army_reopens_the_setup_as_it_was_played() -> void:
	var app: App = _app()
	_into_the_skirmish(app, ["Side1", "Mode1", "Time15", "Budget1500", "Spawn1", "Ai_light_shield_wall"], &"husk")
	# What the settings hold now must not matter: it is the played setup.
	GameSettings.set_skirmish_choice({
		"mode": 0, "budget": 600, "army": "shieldman:9", "army_side": 0, "side": 0,
	}, _settings_path())
	_end_skirmish(app, true)
	_press(app, "ChangeArmyButton")
	var menu: SkirmishMenu = app.current_screen() as SkirmishMenu
	assert_not_null(menu, "back to the setup")
	var choice: Dictionary = menu.current_choice()
	assert_eq(choice["map"], "test_flat")
	assert_eq(choice["side"], DARK)
	assert_eq(choice["mode"], SkirmishRules.Mode.KING_OF_THE_HILL)
	assert_eq(choice["minutes"], 15)
	assert_eq(choice["budget"], 1500)
	assert_eq(choice["start"], 1)
	assert_eq(choice["ai_choice"], "light_shield_wall")
	assert_eq(choice["army"], "husk:2")
	assert_true(menu.can_start())


func test_change_army_with_a_random_enemy_opens_on_random() -> void:
	var app: App = _app()
	_into_the_skirmish(app)
	_end_skirmish(app, true)
	_press(app, "ChangeArmyButton")
	assert_eq((app.current_screen() as SkirmishMenu).current_choice()["ai_choice"], "random")


func test_a_changed_army_starts_a_new_skirmish() -> void:
	var app: App = _app()
	_into_the_skirmish(app)
	_end_skirmish(app, true)
	_press(app, "ChangeArmyButton")
	_press(app, "Plus_longbow")
	_press(app, "Start")
	var main: MainView = app.current_screen() as MainView
	assert_not_null(main)
	assert_eq(main.launch.skirmish.armies[0].count_of(&"longbow"), 1)
	assert_eq(main.launch.skirmish.armies[0].count_of(&"shieldman"), 2)


func test_back_from_a_changed_army_goes_to_the_main_menu() -> void:
	var app: App = _app()
	_into_the_skirmish(app)
	_end_skirmish(app, true)
	_press(app, "ChangeArmyButton")
	_press(app, "Back")
	assert_true(app.current_screen() is MainMenu)


# --- the pause menu in a skirmish ---------------------------------------------------------


func test_restart_in_a_skirmish_asks_and_keep_playing_keeps_it() -> void:
	var app: App = _app()
	var main: MainView = _into_the_skirmish(app)
	main.restart_requested.emit()
	var dialog: ConfirmDialog = app.current_overlay() as ConfirmDialog
	assert_not_null(dialog, "a question first")
	assert_true(MenuFixtures.mentions(dialog, "Restart this skirmish?"))
	MenuFixtures.press(dialog, "CancelButton")
	assert_null(app.current_overlay())
	assert_eq(app.current_screen(), main, "the same skirmish goes on")


func test_restart_in_a_skirmish_relaunches_the_same_setup_and_seed() -> void:
	var app: App = _app(null, 5)
	var first: MainView = _into_the_skirmish(app, ["Mode2", "Ai_dark_horde"])
	var setup: SkirmishSetup = first.launch.skirmish
	var seed_before: int = setup.world_seed
	var ai_before: Dictionary = setup.armies[1].counts.duplicate()
	var remembered: Dictionary = GameSettings.skirmish_choice(_settings_path())
	first._physics_process(1.0 / World.TICK_RATE)
	first.restart_requested.emit()
	MenuFixtures.press(app.current_overlay(), "ConfirmButton")
	var second: MainView = app.current_screen() as MainView
	assert_not_null(second)
	assert_ne(second, first)
	assert_null(app.current_overlay())
	assert_true(second.launch.is_skirmish())
	assert_eq(second.launch.world_seed, seed_before, "the same seed")
	assert_eq(second.launch.skirmish.world_seed, seed_before)
	assert_eq(second.launch.skirmish.armies[1].counts, ai_before, "the same enemy")
	assert_eq(_army_text(second.launch.skirmish, 0), _army_text(setup, 0))
	assert_eq(second.launch.skirmish.rules.mode, SkirmishRules.Mode.CAPTURE_THE_FLAGS)
	assert_eq(second.world.tick, 0, "a fresh world")
	assert_eq(GameSettings.skirmish_choice(_settings_path()), remembered, "nothing is drawn or remembered again")


func test_quit_from_the_pause_menu_of_a_skirmish_goes_to_the_main_menu() -> void:
	var app: App = _app()
	var main: MainView = _into_the_skirmish(app)
	main.quit_requested.emit()
	assert_true(app.current_screen() is MainMenu)
	assert_false(FileAccess.file_exists(_store().path))


func test_settings_over_a_paused_skirmish_holds_it_and_gives_it_back() -> void:
	GameSettings.set_edge_scroll(true, _settings_path())
	var app: App = _app()
	var main: MainView = _into_the_skirmish(app)
	main.pause_menu().open()
	main.settings_requested.emit()
	assert_true(app.current_overlay() is SettingsMenu)
	assert_false(main.pause_menu().enabled, "its Esc must not close the menu behind Settings")
	assert_false(main.edge_scroll)
	MenuFixtures.press(app.current_overlay(), "BackButton")
	assert_null(app.current_overlay())
	assert_true(main.pause_menu().enabled)
	assert_true(main.edge_scroll)


func test_a_skirmish_decided_with_settings_open_closes_it_for_the_results() -> void:
	var app: App = _app()
	var main: MainView = _into_the_skirmish(app)
	main.settings_requested.emit()
	_end_skirmish(app, true)
	assert_true(app.current_screen() is SkirmishResults)
	assert_null(app.current_overlay())


func test_a_skirmish_that_cannot_be_built_returns_to_the_main_menu_with_a_notice() -> void:
	var app: App = _app()
	# The map names a heightmap that isn't there: the sim refuses to build it.
	app.skirmish.maps[0].map.heightmap_path = DIR + "/no_such_height.png"
	_into_the_skirmish(app)
	assert_push_error("Terrain: cannot read")
	assert_push_error("SkirmishSetup.create_world")
	await get_tree().process_frame
	assert_true(app.current_screen() is MainMenu, "not a blank mission screen")
	var notice: Label = app.find_child("NoticeLabel", true, false) as Label
	assert_true(notice.visible)
	assert_string_contains(notice.text, "skirmish could not be started")
