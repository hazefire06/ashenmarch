class_name App
extends Node
## The game's front end and its main scene: it holds one screen at a time and
## walks the player through the campaign:
##   MainMenu -> CampaignMenu -> Briefing -> the mission (MainView) -> Results
##   -> the next Briefing, or CampaignComplete after the last mission.
## A defeat goes Results -> Retry (the saved campaign, the same seed: the
## failed attempt changes nothing) or Main menu. Settings is an overlay, over
## the main menu or over a paused mission; so is the Restart question.
## A skirmish is a shorter walk: MainMenu -> SkirmishMenu -> the skirmish
## (MainView with a MissionLaunch.for_skirmish) -> SkirmishResults -> Rematch,
## Change army (the setup again, as it was) or Main menu. Nothing about a
## skirmish is saved but the setup the player last chose (GameSettings).
##
## The App owns the campaign in play (`state`) and the plan the mission was
## built from; the screens only show and ask. Everything that changes the
## campaign goes through here:
## - New Campaign makes a CampaignState and saves it (the first autosave).
## - A mission is built from the state exactly: seed = state.mission_seed
##   (mission_index), deploy = the plan's command, tier = state.tier.
## - A victory is applied with the SAME plan that built the deploy
##   (CampaignState.apply_victory refuses a stale one), then saved (the second
##   autosave), the moment Results appears, so closing the window on that
##   screen loses nothing; Continue and Main menu then only navigate. A defeat
##   is never applied.
## - Retry reloads the save (which is the state before the mission) and shows
##   that mission's briefing again, with the same soldiers benched, so the
##   player can change the roster or just press Start; the seed is the same, so
##   the waves come the same. A file that isn't that same campaign at that same
##   point (a failed autosave left it so) is not trusted: the state in memory is
##   written back instead. The pause menu's Restart mission, which skips the
##   briefing, replays the same launch at once.
##
## MainView's signals are wired here: mission_ended (skirmish_ended in a
## skirmish) -> Results, restart_requested -> the question then a fresh
## MainView, settings_requested -> the Settings overlay (with the pause menu and
## edge scroll switched off behind it), quit_requested -> the main menu (the
## pause menu already asked), build_failed (the mission couldn't be built) ->
## the main menu with a notice.
##
## The skirmish's dice are the App's too, and drawn in a fixed order: when the
## enemy's army is left to chance its template first (App.rng.randi_range), then
## the world's seed; a chosen template draws only the seed. The same
## App.rng.seed therefore gives the same skirmish. A Rematch keeps both armies
## and draws a new seed; the pause menu's Restart keeps the seed too.

## The campaign's data and the unit catalog it plays with.
const CAMPAIGN_PATH: String = "res://data/campaign/campaign.tres"
## The unit catalog the roster and the missions are checked against.
const CATALOG_PATH: String = "res://data/units/catalog.tres"
## The skirmish's maps, army templates, budgets and time limits.
const SKIRMISH_PATH: String = "res://data/skirmish/skirmish.tres"
## The mission screen. A preload, so its scripts are compiled with this one.
const MAIN_SCENE: PackedScene = preload("res://view/main.tscn")
## Overlays sit above the pause menu's layer (PauseMenu.MENU_LAYER, 10), which
## is where they open over a paused mission.
const OVERLAY_LAYER: int = PauseMenu.MENU_LAYER + 10
## The notice line sits above everything.
const NOTICE_LAYER: int = OVERLAY_LAYER + 10
## How long a notice stays up.
const NOTICE_SECONDS: float = 6.0

## What the player is playing: set before the App enters the tree to use
## another campaign (a test's), else the shipped one is loaded.
var campaign: CampaignDef
## The unit catalog; loaded unless set first.
var catalog: UnitCatalog
## What the skirmish screen offers; loaded unless set first (a test's).
var skirmish: SkirmishCatalog
## Where the campaign is saved; set before the App enters the tree to use
## another file.
var store: CampaignStore
## Where the settings are kept; likewise.
var settings_path: String = GameSettings.DEFAULT_PATH
## How long a notice stays up, in real seconds; public so a test can shorten it.
var notice_seconds: float = NOTICE_SECONDS
## What puts the window in or out of fullscreen; GameSettings' by default. A
## seam so a test can see when it is called (headless there is no window).
var apply_window_mode: Callable = GameSettings.apply_window_mode
## The view's own dice, for a new campaign's seed (the sim never sees this).
var rng: RandomNumberGenerator = RandomNumberGenerator.new()
## The campaign in play: loaded by Continue, made by New Campaign, advanced by a
## victory. Null until one of those.
var state: CampaignState

# The screen on show: a MenuScreen, or the MainView during a mission.
var _screen: Node
var _overlay_layer: CanvasLayer
var _overlay: MenuScreen
var _notice_layer: CanvasLayer
var _notice: Label
var _notice_serial: int = 0
# The fullscreen choice the window was last put in line with, so Settings only
# touches the window when that choice itself changes (flipping Edge scroll must
# not drop the player out of fullscreen).
var _fullscreen_applied: bool = false
# Where the keyboard was when an overlay opened, so closing it puts it back.
var _focus_before_overlay: Control
# The roster the current mission was launched with, and who is benched in it:
# what apply_victory must be given, and what a Retry's briefing starts from.
var _plan: DeployPlan
var _benched: PackedInt32Array = PackedInt32Array()
# A finished mission, held while its Results are up (a victory is applied and
# dropped at once; a defeat is dropped when the player leaves).
var _result_outcome: MissionRuntime.Outcome = MissionRuntime.Outcome.NONE
var _result_stats: MissionStats
var _result_world: World
# The skirmish in play (or just played): what Restart and Rematch relaunch and
# Change army reopens the setup screen on, and what the player chose for the
# enemy (a template id or "random"), which the setup's own AI army no longer
# says once it is filled.
var _skirmish_setup: SkirmishSetup
var _skirmish_ai_choice: StringName = SkirmishMenu.RANDOM_AI


func _ready() -> void:
	InputBindings.install()
	if campaign == null:
		campaign = load(CAMPAIGN_PATH) as CampaignDef
	if catalog == null:
		catalog = load(CATALOG_PATH) as UnitCatalog
	if skirmish == null:
		skirmish = load(SKIRMISH_PATH) as SkirmishCatalog
	if store == null:
		store = CampaignStore.new()
	_overlay_layer = CanvasLayer.new()
	_overlay_layer.name = "Overlays"
	_overlay_layer.layer = OVERLAY_LAYER
	add_child(_overlay_layer)
	_build_notice()
	# Only fullscreen needs asking for: the window starts windowed, and a
	# command-line --fullscreen shouldn't be undone by a default.
	_fullscreen_applied = GameSettings.fullscreen(settings_path)
	if _fullscreen_applied:
		apply_window_mode.call(true)
	show_main_menu()


## The screen on show: a MenuScreen, or the MainView while a mission is played.
func current_screen() -> Node:
	return _screen


## The overlay on show (Settings or a question), or null.
func current_overlay() -> MenuScreen:
	return _overlay


## The roster the mission in play (or about to be) was built from.
func current_plan() -> DeployPlan:
	return _plan


## Puts `screen` in place of the current one, which is removed and freed. The
## screen goes first among the children, so an overlay (later in the tree, so
## first to see a key) can consume Esc before a mission's pause menu does.
func show_screen(screen: Node) -> void:
	_close_overlay()
	if _screen != null:
		remove_child(_screen)
		_screen.queue_free()
	_screen = screen
	if screen != null:
		add_child(screen)
		move_child(screen, 0)


## The title screen.
func show_main_menu() -> void:
	var menu: MainMenu = MainMenu.new()
	menu.campaign_pressed.connect(show_campaign_menu)
	menu.skirmish_pressed.connect(show_skirmish_menu)
	menu.settings_pressed.connect(open_settings)
	menu.quit_pressed.connect(quit_game)
	show_screen(menu)


## The campaign menu, built from the save as it is on disk right now.
func show_campaign_menu() -> void:
	var saved: CampaignState = null
	var problem: String = ""
	var file_exists: bool = store.exists()
	if file_exists:
		saved = store.load()
		if saved == null:
			problem = store.last_error
		elif not _fits(saved):
			problem = "it is past the end of this campaign"
			saved = null
	var menu: CampaignMenu = CampaignMenu.new()
	menu.setup(campaign, saved, file_exists, problem)
	menu.continue_pressed.connect(_on_continue)
	menu.new_campaign_requested.connect(_on_new_campaign)
	menu.back_pressed.connect(show_main_menu)
	show_screen(menu)


## The briefing for the campaign's next mission, from `state`.
func show_briefing() -> void:
	var briefing: Briefing = Briefing.new()
	briefing.setup(campaign, state, catalog, _benched)
	briefing.start_pressed.connect(_on_briefing_start)
	briefing.back_pressed.connect(show_campaign_menu)
	show_screen(briefing)


## Plays the campaign's next mission with `plan` (what the briefing chose).
func start_mission(plan: DeployPlan, benched: PackedInt32Array) -> void:
	_plan = plan
	_benched = benched
	_launch_mission()


## The results of a mission that just ended. A victory is applied and saved
## here, after the screen is built (it is built from the state as it stood
## before), so the player can't lose it by closing the game on this screen;
## the result is dropped once applied, so the buttons never apply it again. A
## defeat is kept only until the player leaves (Retry needs nothing from it).
func show_results(outcome: MissionRuntime.Outcome, stats: MissionStats, world: World) -> void:
	_result_outcome = outcome
	_result_stats = stats
	_result_world = world
	var results: Results = Results.new()
	results.setup(outcome, stats, campaign.missions[state.mission_index], _plan, world, catalog)
	results.continue_pressed.connect(_on_results_continue)
	results.retry_pressed.connect(_on_results_retry)
	results.main_menu_pressed.connect(_on_results_main_menu)
	show_screen(results)
	_commit_victory()


## The end of the campaign, from `state`.
func show_complete() -> void:
	var screen: CampaignComplete = CampaignComplete.new()
	screen.setup(campaign, state, catalog)
	screen.main_menu_pressed.connect(show_main_menu)
	show_screen(screen)


## The skirmish setup screen. It opens on `remembered` if that has anything in
## it (Change army passes the setup that was just played), else on what
## GameSettings remembers of the last skirmish; whatever no longer fits is
## ignored by the screen.
func show_skirmish_menu(remembered: Dictionary = {}) -> void:
	var menu: SkirmishMenu = SkirmishMenu.new()
	menu.setup(
		skirmish, catalog,
		remembered if not remembered.is_empty() else GameSettings.skirmish_choice(settings_path)
	)
	menu.start_pressed.connect(start_skirmish)
	menu.back_pressed.connect(show_main_menu)
	show_screen(menu)


## Plays a skirmish. `setup` is the player's half (what the setup screen
## makes); this resolves the enemy's army from `ai_choice` (a template id, or
## SkirmishMenu.RANDOM_AI to draw one of the enemy side's templates with
## `rng`), fills it at the setup's budget, draws the world's seed, remembers
## the choice for next time and launches. A choice that names no template of
## the enemy's side is taken as random.
func start_skirmish(setup: SkirmishSetup, ai_choice: StringName) -> void:
	var offered: Array[ArmyTemplate] = skirmish.templates_for(setup.ai_faction())
	if offered.is_empty():
		push_error("App.start_skirmish: no army template for the enemy's side")
		show_notice("The skirmish could not be started. See the log.")
		return
	var template: ArmyTemplate = skirmish.template(ai_choice)
	if template == null or template.faction != setup.ai_faction():
		template = offered[rng.randi_range(0, offered.size() - 1)]
	setup.armies = [setup.armies[0], template.fill(setup.budget, catalog)]
	setup.ai_template_id = template.id
	setup.world_seed = _new_seed()
	_skirmish_setup = setup
	_skirmish_ai_choice = ai_choice
	# Remembering is a convenience: a write that fails is not worth a notice.
	GameSettings.set_skirmish_choice(SkirmishMenu.choice_of(setup, ai_choice, catalog), settings_path)
	_launch_skirmish()


## The results of a skirmish that just ended: the setup that was played, the
## finished world and the outcome from the player's side. Nothing is applied or
## saved: a skirmish changes nothing but the choice remembered when it began.
func show_skirmish_results(outcome: MissionRuntime.Outcome, world: World) -> void:
	var results: SkirmishResults = SkirmishResults.new()
	results.setup(_skirmish_setup, world, outcome, skirmish)
	results.rematch_pressed.connect(_on_skirmish_rematch)
	results.change_army_pressed.connect(_on_skirmish_change_army)
	results.main_menu_pressed.connect(_on_results_main_menu)
	show_screen(results)


## Opens Settings over whatever is showing. Over a mission, the mission can't
## be reached while it is up: the pause menu is switched off (its Esc would
## close it behind Settings) and so is edge scroll (which pans behind any
## overlay that isn't a button).
func open_settings() -> void:
	var settings: SettingsMenu = SettingsMenu.new()
	settings.setup(settings_path)
	settings.changed.connect(_on_settings_changed)
	settings.closed.connect(_close_overlay)
	_open_overlay(settings)


## Asks yes or no over whatever is showing; `on_yes` runs if the answer is yes.
func ask(question: String, yes_text: String, no_text: String, on_yes: Callable) -> void:
	var dialog: ConfirmDialog = ConfirmDialog.new()
	dialog.setup(question, yes_text, no_text)
	dialog.confirmed.connect(func() -> void:
		_close_overlay()
		on_yes.call()
	)
	dialog.cancelled.connect(_close_overlay)
	_open_overlay(dialog)


## Shows a line at the bottom of the screen for a few seconds: for what
## can't be put on the screen it concerns (a save that failed).
func show_notice(text: String) -> void:
	_notice_serial += 1
	var serial: int = _notice_serial
	_notice.text = text
	_notice.visible = true
	get_tree().create_timer(notice_seconds).timeout.connect(func() -> void:
		if serial == _notice_serial:
			_notice.visible = false
	)


## Closes the game (Quit on the main menu).
func quit_game() -> void:
	get_tree().quit()


# --- the campaign ---------------------------------------------------------------


func _on_new_campaign(tier: int) -> void:
	state = CampaignState.new_campaign(_new_seed(), tier)
	_benched = PackedInt32Array()
	_plan = null
	_autosave()
	show_briefing()


func _on_continue() -> void:
	var loaded: CampaignState = store.load()
	if loaded == null or not _fits(loaded):
		# The menu was built from a save that has since gone; say so, and
		# rebuild it from what is there now.
		show_notice("The saved campaign can't be used: %s." % (
			store.last_error if loaded == null else "it is past the end of this campaign"
		))
		show_campaign_menu()
		return
	state = loaded
	_benched = PackedInt32Array()
	_plan = null
	if state.is_complete(campaign):
		show_complete()
	else:
		show_briefing()


func _on_briefing_start(plan: DeployPlan, benched: PackedInt32Array) -> void:
	start_mission(plan, benched)


# The mission, built from the state exactly: its seed, its roster, its tier.
func _launch_mission() -> void:
	var mission: MissionDef = campaign.missions[state.mission_index]
	var launch: MissionLaunch = MissionLaunch.new(
		mission, state.tier, state.mission_seed(state.mission_index), _plan.command(0, mission), true
	)
	var main: MainView = MAIN_SCENE.instantiate() as MainView
	main.launch = launch
	main.edge_scroll = GameSettings.edge_scroll(settings_path)
	main.mission_ended.connect(_on_mission_ended)
	main.restart_requested.connect(_on_restart_requested)
	main.settings_requested.connect(open_settings)
	main.quit_requested.connect(_on_quit_to_menu)
	main.build_failed.connect(_on_mission_build_failed.bind(main))
	show_screen(main)


func _on_mission_ended(outcome: MissionRuntime.Outcome, stats: MissionStats) -> void:
	var main: MainView = _screen as MainView
	if main == null:
		return
	# Read the world now: the screen is freed when the results replace it.
	show_results(outcome, stats, main.world)


# The mission couldn't be built (MissionSetup has said why): there is nothing to
# play, so say so and go to the main menu. The campaign is as it was, so
# Campaign > Continue offers the same mission again. Ignored if the screen has
# already changed (the signal is deferred).
func _on_mission_build_failed(failed: MainView) -> void:
	if _screen != failed:
		return
	_drop_result()
	_plan = null
	show_main_menu()
	show_notice("The mission could not be started. See the log.")


func _on_restart_requested() -> void:
	ask("Restart this mission?\nProgress in it is lost.", "Restart", "Keep playing", _launch_mission)


func _on_quit_to_menu() -> void:
	_drop_result()
	_plan = null
	_skirmish_setup = null
	show_main_menu()


func _on_results_continue() -> void:
	if state.is_complete(campaign):
		show_complete()
	else:
		show_briefing()


func _on_results_retry() -> void:
	_drop_result()
	# The save should be the state as it stood before the mission: a defeat is
	# never applied, and a mission never changes `state`. Reload it, as the
	# brief has it, but only if it IS that: the same campaign at the same point.
	# A failed autosave (the App carries on after one) can leave the file
	# older (a victory not recorded) or another campaign's (a New Campaign that
	# couldn't replace it); reloading that would roll the player back or swap
	# his campaign. Then the state in memory, which is right, is written back.
	var saved: CampaignState = store.load()
	if saved != null and saved.campaign_seed == state.campaign_seed \
			and saved.tier == state.tier and saved.mission_index == state.mission_index:
		state = saved
	else:
		_autosave()
	show_briefing()


func _on_results_main_menu() -> void:
	_drop_result()
	_skirmish_setup = null
	show_main_menu()


# Applies the won mission to the campaign, with the plan that built it, and
# saves. Run as the victory's Results appear. Does nothing for a defeat or a
# second time: the result is dropped once applied (or refused).
func _commit_victory() -> void:
	if _result_world == null or _result_outcome != MissionRuntime.Outcome.WON:
		return
	var mission: MissionDef = campaign.missions[state.mission_index]
	var before: int = state.mission_index
	state.apply_victory(mission, _plan, _result_world, _result_stats)
	_drop_result()
	if state.mission_index == before:
		# apply_victory has said why (push_error); don't pretend it advanced.
		show_notice("The victory could not be recorded.")
		return
	_benched = PackedInt32Array()
	_plan = null
	_autosave()


func _drop_result() -> void:
	_result_outcome = MissionRuntime.Outcome.NONE
	_result_stats = null
	_result_world = null


func _autosave() -> void:
	if store.save(state) != OK:
		show_notice("Could not save your progress: %s." % store.last_error)


# True if a loaded state's next mission exists in this campaign (or it has
# finished it): a save from a longer campaign can't be played.
func _fits(candidate: CampaignState) -> bool:
	return candidate.mission_index <= campaign.missions.size()


# A fresh 63-bit seed: two 32-bit halves, the top bit left clear.
func _new_seed() -> int:
	return ((rng.randi() & 0x7FFFFFFF) << 32) | rng.randi()


# --- the skirmish ---------------------------------------------------------------


# The skirmish, built from _skirmish_setup exactly: its seed is whatever the
# setup holds (a Restart replays the same one, a Rematch has already drawn a
# new one).
func _launch_skirmish() -> void:
	var main: MainView = MAIN_SCENE.instantiate() as MainView
	main.launch = MissionLaunch.for_skirmish(_skirmish_setup)
	main.edge_scroll = GameSettings.edge_scroll(settings_path)
	main.skirmish_ended.connect(_on_skirmish_ended)
	main.restart_requested.connect(_on_skirmish_restart_requested)
	main.settings_requested.connect(open_settings)
	main.quit_requested.connect(_on_quit_to_menu)
	main.build_failed.connect(_on_skirmish_build_failed.bind(main))
	show_screen(main)


func _on_skirmish_ended(outcome: MissionRuntime.Outcome) -> void:
	var main: MainView = _screen as MainView
	if main == null:
		return
	# Read the world now: the screen is freed when the results replace it.
	show_skirmish_results(outcome, main.world)


# The skirmish couldn't be built (SkirmishSetup has said why): there is nothing
# to play. Ignored if the screen has already changed (the signal is deferred).
func _on_skirmish_build_failed(failed: MainView) -> void:
	if _screen != failed:
		return
	_skirmish_setup = null
	show_main_menu()
	show_notice("The skirmish could not be started. See the log.")


func _on_skirmish_restart_requested() -> void:
	ask("Restart this skirmish?\nProgress in it is lost.", "Restart", "Keep playing", _launch_skirmish)


# The same armies, map and rules on a new seed.
func _on_skirmish_rematch() -> void:
	_skirmish_setup = _reseeded(_skirmish_setup)
	_launch_skirmish()


func _on_skirmish_change_army() -> void:
	show_skirmish_menu(SkirmishMenu.choice_of(_skirmish_setup, _skirmish_ai_choice, catalog))


# A copy of a setup with a fresh seed, so the setup the finished skirmish was
# played from (still held by its MainView's launch) is never changed.
func _reseeded(setup: SkirmishSetup) -> SkirmishSetup:
	var again: SkirmishSetup = SkirmishSetup.new()
	again.map = setup.map
	again.rules = setup.rules
	again.budget = setup.budget
	again.armies = [setup.armies[0].copy(), setup.armies[1].copy()]
	again.player_spawn = setup.player_spawn
	again.ai_template_id = setup.ai_template_id
	again.player_is_ai = setup.player_is_ai
	again.world_seed = _new_seed()
	return again


# --- overlays -------------------------------------------------------------------


func _open_overlay(overlay: MenuScreen) -> void:
	_close_overlay()
	_focus_before_overlay = get_viewport().gui_get_focus_owner()
	_overlay = overlay
	_overlay_layer.add_child(overlay)
	_hold_mission(true)


func _close_overlay() -> void:
	if _overlay == null:
		return
	_overlay_layer.remove_child(_overlay)
	_overlay.queue_free()
	_overlay = null
	_hold_mission(false)
	if _focus_before_overlay != null and is_instance_valid(_focus_before_overlay) \
			and _focus_before_overlay.is_visible_in_tree():
		_focus_before_overlay.grab_focus()
	_focus_before_overlay = null


# While an overlay is up over a mission it can't be reached: the pause menu
# would take Esc, and the camera would pan behind the dim layer.
func _hold_mission(held: bool) -> void:
	var main: MainView = _screen as MainView
	if main == null:
		return
	main.pause_menu().enabled = not held and not main.is_frozen()
	main.edge_scroll = not held and GameSettings.edge_scroll(settings_path)


func _on_settings_changed() -> void:
	var wanted: bool = GameSettings.fullscreen(settings_path)
	if wanted == _fullscreen_applied:
		return
	_fullscreen_applied = wanted
	apply_window_mode.call(wanted)


func _build_notice() -> void:
	_notice_layer = CanvasLayer.new()
	_notice_layer.name = "Notice"
	_notice_layer.layer = NOTICE_LAYER
	add_child(_notice_layer)
	_notice = MenuKit.title("", 18, MenuKit.WARN_COLOR)
	_notice.name = "NoticeLabel"
	_notice.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_notice.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_notice.set_anchors_and_offsets_preset(Control.PRESET_BOTTOM_WIDE)
	_notice.offset_top = -48.0
	_notice.offset_bottom = -16.0
	_notice.visible = false
	_notice_layer.add_child(_notice)
