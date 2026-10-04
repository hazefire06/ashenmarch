class_name App
extends Node
## The game's front end and its main scene: it holds one screen at a time and
## walks the player through the campaign:
##   MainMenu -> CampaignMenu -> Briefing -> the mission (MainView) -> Results
##   -> the next Briefing, or CampaignComplete after the last mission.
## A defeat goes Results -> Retry (the saved campaign, the same seed: the
## failed attempt changes nothing) or Main menu. Settings is an overlay, over
## the main menu or over a paused mission; so is the Restart question.
##
## The App owns the campaign in play (`state`) and the plan the mission was
## built from; the screens only show and ask. Everything that changes the
## campaign goes through here:
## - New Campaign makes a CampaignState and saves it (the first autosave).
## - A mission is built from the state exactly: seed = state.mission_seed
##   (mission_index), deploy = the plan's command, tier = state.tier.
## - A victory is applied with the SAME plan that built the deploy
##   (CampaignState.apply_victory refuses a stale one), then saved (the second
##   autosave), when the player leaves Results by Continue or by Main menu, so
##   progress is never lost. A defeat is never applied.
## - Retry reloads the save (which is the state before the mission) and shows
##   that mission's briefing again, with the same soldiers benched, so the
##   player can change the roster or just press Start; the seed is the same, so
##   the waves come the same. The pause menu's Restart mission, which skips the
##   briefing, replays the same launch at once.
##
## MainView's signals are wired here: mission_ended -> Results, restart_requested
## -> the question then a fresh MainView, settings_requested -> the Settings
## overlay (with the pause menu and edge scroll switched off behind it),
## quit_requested -> the main menu (the pause menu already asked).

## The campaign's data and the unit catalog it plays with.
const CAMPAIGN_PATH: String = "res://data/campaign/campaign.tres"
## The unit catalog the roster and the missions are checked against.
const CATALOG_PATH: String = "res://data/units/catalog.tres"
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
## Where the campaign is saved; set before the App enters the tree to use
## another file.
var store: CampaignStore
## Where the settings are kept; likewise.
var settings_path: String = GameSettings.DEFAULT_PATH
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
# Where the keyboard was when an overlay opened, so closing it puts it back.
var _focus_before_overlay: Control
# The roster the current mission was launched with, and who is benched in it:
# what apply_victory must be given, and what a Retry's briefing starts from.
var _plan: DeployPlan
var _benched: PackedInt32Array = PackedInt32Array()
# A finished mission waiting for the player to leave Results.
var _result_outcome: MissionRuntime.Outcome = MissionRuntime.Outcome.NONE
var _result_stats: MissionStats
var _result_world: World


func _ready() -> void:
	InputBindings.install()
	if campaign == null:
		campaign = load(CAMPAIGN_PATH) as CampaignDef
	if catalog == null:
		catalog = load(CATALOG_PATH) as UnitCatalog
	if store == null:
		store = CampaignStore.new()
	_overlay_layer = CanvasLayer.new()
	_overlay_layer.name = "Overlays"
	_overlay_layer.layer = OVERLAY_LAYER
	add_child(_overlay_layer)
	_build_notice()
	# Only fullscreen needs asking for: the window starts windowed, and a
	# command-line --fullscreen shouldn't be undone by a default.
	if GameSettings.fullscreen(settings_path):
		GameSettings.apply_window_mode(true)
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


## The results of a mission that just ended. Kept until the player leaves them:
## a victory is applied then, not before.
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


## The end of the campaign, from `state`.
func show_complete() -> void:
	var screen: CampaignComplete = CampaignComplete.new()
	screen.setup(campaign, state, catalog)
	screen.main_menu_pressed.connect(show_main_menu)
	show_screen(screen)


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
	get_tree().create_timer(NOTICE_SECONDS).timeout.connect(func() -> void:
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
	show_screen(main)


func _on_mission_ended(outcome: MissionRuntime.Outcome, stats: MissionStats) -> void:
	var main: MainView = _screen as MainView
	if main == null:
		return
	# Read the world now: the screen is freed when the results replace it.
	show_results(outcome, stats, main.world)


func _on_restart_requested() -> void:
	ask("Restart this mission?\nProgress in it is lost.", "Restart", "Keep playing", _launch_mission)


func _on_quit_to_menu() -> void:
	_drop_result()
	_plan = null
	show_main_menu()


func _on_results_continue() -> void:
	_commit_victory()
	if state.is_complete(campaign):
		show_complete()
	else:
		show_briefing()


func _on_results_retry() -> void:
	_drop_result()
	# The save is the state as it stood before the mission: a defeat is never
	# applied. Reload it, as the brief has it; if it can't be read, the state in
	# memory is the same by construction, so write it back and carry on.
	var saved: CampaignState = store.load()
	if saved != null and saved.mission_index < campaign.missions.size():
		state = saved
	else:
		_autosave()
	show_briefing()


func _on_results_main_menu() -> void:
	if _result_outcome == MissionRuntime.Outcome.WON:
		_commit_victory()
	else:
		_drop_result()
	show_main_menu()


# Applies the won mission to the campaign, with the plan that built it, and
# saves. Does nothing a second time: the result is dropped once applied.
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
	GameSettings.apply_window_mode(GameSettings.fullscreen(settings_path))


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
