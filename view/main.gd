class_name MainView
extends Node3D
## Entry scene: loads the map and unit catalog, owns the World, and advances
## it one tick per physics frame. The terrain view, camera, overhead map, and
## unit, projectile, explosion, fire, and weather views read the World; only
## commands change it. The gas cloud and herb plant views read it too, and so
## do the mission HUD, the objective panel, and the F5 AI overlay.
## Everything that draws the ground is built from the World's own terrain,
## not the one loaded from the map: explosions scar the World's copy.
##
## Two ways to run:
## - The sandbox, with no `launch` (the demos and `godot --path .` use it): the
##   Light side is a test setup the player commands; the Dark side is the
##   Riverside AI mission (data/missions/riverside_ai.tres), which spawns its
##   groups, drives them, and brings the rain, from its own triggers. It never
##   freezes, whatever the mission decides.
## - A campaign mission, with a MissionLaunch set before the scene enters the
##   tree: the world is built by MissionSetup (the roster, the map's herb
##   plants, the mission started), the camera and the look (Atmosphere) come
##   from the MissionDef, and MissionStats watch the stepping. Once the mission
##   is won or lost the sim stops stepping on that very tick, the view keeps
##   drawing, the banner shows, and after MISSION_END_DELAY real seconds
##   mission_ended says how it ended, for the App to put up the results.
## - A skirmish, with a MissionLaunch.for_skirmish: the same, but the world is
##   built by SkirmishSetup, the camera starts over the player's army looking
##   the way it faces, the look is the map's, the player may be either side,
##   there are no MissionStats (the skirmish keeps its own score), and the
##   end is skirmish_ended. It also has its own views: FlagsView in the world,
##   and SkirmishHud (the score line, and the F7 scoreboard) under the HUD.
##
## Pause stops the stepping and nothing else, so the sim, which never hears of
## it, stays deterministic: Esc opens the pause menu (unless an order is armed,
## which Esc cancels first), P pauses without it, and a campaign mission also
## pauses when the window loses focus. While paused the camera, selection,
## tooltip, and info panel work but no command is enqueued.

## How the mission ended, and its numbers (finished). Emitted once, a while
## after the outcome, so the banner is seen.
signal mission_ended(outcome: MissionRuntime.Outcome, stats: MissionStats)
## How a skirmish ended, from the player's side, once, a while after the
## outcome, like mission_ended. world.skirmish has the score, frozen.
signal skirmish_ended(outcome: MissionRuntime.Outcome)
## The pause menu's Restart mission, Settings and Quit (after its confirmation),
## passed on for the App. Resume is handled here.
signal restart_requested
signal settings_requested
signal quit_requested
## The mission could not be built (a missing map, a rules script that refuses):
## there is no world to show. Sent once, deferred, from _ready, so the App can
## replace this screen after it has finished entering the tree; MissionSetup has
## said why (push_error). Nothing listens in the sandbox.
signal build_failed

const WORLD_SEED: int = 1
const MAP_PATH: String = "res://maps/riverside/riverside.tres"
const CATALOG_PATH: String = "res://data/units/catalog.tres"
## The Dark side: its groups, AI behaviors, triggers, and weather. Played at
## the middle difficulty tier until Phase 8 adds a difficulty select.
const MISSION_PATH: String = "res://data/missions/riverside_ai.tres"
const MISSION_TIER: int = 2
## The Light side's test setup until Phase 8's rosters: a 5x4 block of
## Shieldmen at 2 m spacing on the north bank by the ford, with a row of five
## Reavers behind them. Phase 4 adds a row of six Longbows and a row of three
## Sappers behind the Shieldmen and Reavers, and Phase 6 three Wardens behind
## the Sappers, and plants the map's herb plants.
const TEST_SQUAD_SIZE: int = 20
const SHIELDMEN_ORIGIN: Vector2i = Vector2i(290_000, 185_000)
const TEST_SQUAD_COLUMNS: int = 5
const TEST_SQUAD_SPACING: int = 2_000
const TEST_SHOCK_ROW_SIZE: int = 5
const TEST_LONGBOW_COUNT: int = 6
const TEST_SAPPER_COUNT: int = 3
const TEST_WARDEN_COUNT: int = 3
## Where the camera starts: south of the squads at the ford, looking north.
const CAMERA_START: Vector2 = Vector2(285.0, 245.0)
const CAMERA_START_DISTANCE: float = 75.0
## How far ahead of the player's skirmish army the camera starts looking, in
## meters, so the block isn't under the control bar.
const SKIRMISH_CAMERA_LEAD: float = 15.0
## Weight of the newest sample in the sim-time moving average.
const SIM_TIME_SMOOTHING: float = 0.05
## Real seconds between the mission being decided and mission_ended: long
## enough to read the banner over the frozen field.
const MISSION_END_DELAY: float = 2.5

var world: World
## The campaign mission to play, or null for the sandbox. Set it before the
## scene enters the tree: _ready reads it.
var launch: MissionLaunch
## The numbers of the mission being played (what MissionStats says about it),
## null in the sandbox and in a skirmish. Finished once the mission is decided.
var stats: MissionStats
## Real seconds from the outcome to mission_ended. Public so a test can set it
## to 0.
var end_delay: float = MISSION_END_DELAY
## Whether the camera pans at the window's edges (RtsCamera.edge_scroll); the
## Settings toggle. Set it before the scene enters the tree or at any time
## after. The camera only pans while the pause menu is closed, whatever this
## says: the menu's dim layer isn't a button, so the camera would pan behind it.
var edge_scroll: bool = false:
	set(value):
		edge_scroll = value
		_apply_edge_scroll()
## True while the sim isn't being stepped. Pausing changes nothing in the sim:
## the view just stops calling World.step(). Set it directly, or with P or the
## menu. Ignored once the mission is decided.
var paused: bool = false:
	set(value):
		paused = value and not _frozen
		_apply_pause()
## The mission to start, a MissionScript resource path. Set it before the
## scene enters the tree: _ready reads it. Empty starts no mission, so a
## caller (the AI demo) can start its own on the fresh world with
## World.start_mission before the first step.
var mission_path: String = MISSION_PATH

var _sim_ms: float = 0.0
## The DebugWeather preset F6 last picked.
var _weather_preset: int = 0
## True once the mission is decided and the sim stopped for good, and once
## mission_ended has been sent.
var _frozen: bool = false
var _ended: bool = false
## Real seconds since the outcome.
var _since_outcome: float = 0.0
## False until the first step has run, after which stats.begin() is called.
var _stats_begun: bool = false
## A skirmish's flags in the world and its score line and scoreboard; null
## outside a skirmish.
var _flags_view: FlagsView
var _skirmish_hud: SkirmishHud

@onready var _terrain_view: TerrainView = $TerrainView
@onready var _units_view: UnitsView = $Units
@onready var _gibs: Gibs = $Gibs
@onready var _projectiles_view: ProjectilesView = $Projectiles
@onready var _explosions_view: ExplosionsView = $Explosions
@onready var _fire_view: FireView = $Fire
@onready var _gas_view: GasCloudsView = $GasClouds
@onready var _plants_view: HerbPlantsView = $HerbPlants
@onready var _precipitation: PrecipitationView = $Precipitation
@onready var _world_environment: WorldEnvironment = $WorldEnvironment
@onready var _sun: DirectionalLight3D = $Sun
@onready var _ai_debug: AiDebugView = $AiDebug
@onready var _camera: RtsCamera = $CameraRig
@onready var _selection: SelectionController = $Hud/Selection
@onready var _control_bar: ControlBar = $Hud/ControlBar
@onready var _overhead_map: OverheadMap = $Hud/OverheadMap
@onready var _tooltip: UnitTooltip = $Hud/UnitTooltip
@onready var _info_panel: UnitInfoPanel = $Hud/UnitInfoPanel
@onready var _stats_label: Label = $Hud/StatsLabel
@onready var _mission_hud: MissionHud = $Hud/MissionHud
@onready var _objectives: ObjectivePanel = $Hud/ObjectivePanel
@onready var _pause_menu: PauseMenu = $Hud/PauseMenu


func _ready() -> void:
	# One physics frame is one sim tick, so the physics rate is the tick rate.
	Engine.physics_ticks_per_second = World.TICK_RATE
	InputBindings.install()

	var started_ms: int = Time.get_ticks_msec()
	world = _create_world()
	if world == null:
		# Nothing to step or draw without a World.
		set_process(false)
		set_physics_process(false)
		build_failed.emit.call_deferred()
		return
	# The World's copy, which explosions scar. The views draw this one.
	var terrain: Terrain = world.terrain
	var loaded_ms: int = Time.get_ticks_msec()
	_terrain_view.build(terrain)
	_camera.setup(terrain)
	_place_camera()
	_overhead_map.setup(terrain, _camera, world)
	_gibs.setup(terrain)
	if launch == null:
		_spawn_test_squads()
		_plant_herbs(load(MAP_PATH) as MapInfo)
		_start_mission()
	elif not launch.is_skirmish():
		# MissionSetup queued the roster and the herb plants and started the mission.
		stats = MissionStats.new()
	_units_view.setup(world, _selection.selection, _gibs)
	_projectiles_view.setup(world)
	_explosions_view.setup(world, _terrain_view, _gibs)
	_fire_view.setup(world)
	_gas_view.setup(world)
	_plants_view.setup(world)
	_precipitation.setup(world, _camera)
	if launch != null:
		# After the views it grades exist: the terrain's material and the ash layer.
		var look: Atmosphere = (
			launch.skirmish.map.atmosphere if launch.is_skirmish() else launch.mission.atmosphere
		)
		AtmosphereView.new(_world_environment, _sun, _terrain_view, _precipitation).apply(look)
	_ai_debug.setup(world)
	_mission_hud.show_world(world)
	_objectives.show_world(world)
	if launch != null and launch.is_skirmish():
		_build_skirmish_views()
	_selection.setup(
		world, _units_view, _camera.get_camera(), TerrainPicker.new(terrain), _projectiles_view, _plants_view
	)
	_selection.side_changed.connect(_units_view.set_viewer)
	if launch != null and launch.is_skirmish():
		# The player may be Dark: they select, and see, from their own side.
		_selection.side = launch.player_faction()
		_units_view.set_viewer(launch.player_faction())
	_control_bar.setup(_selection, world)
	if launch != null and launch.is_skirmish():
		_control_bar.set_skirmish(launch.player_faction())
	_info_panel.setup(_selection, world, _control_bar)
	_tooltip.setup(_selection, world, _camera.get_camera(), _projectiles_view, _plants_view)
	_apply_edge_scroll()
	if _campaign():
		# The debug keys (side switch, status, weather) are cheats: not in the campaign.
		_selection.debug_keys_enabled = false
		_control_bar.set_switch_side_visible(false)
	# With no App around the menu (the sandbox) it can only resume.
	_pause_menu.set_app_buttons_visible(launch != null)
	_control_bar.menu_requested.connect(_pause_menu.open)
	_pause_menu.opened.connect(_on_pause_menu_opened)
	_pause_menu.closed.connect(_on_pause_menu_closed)
	_pause_menu.resume_requested.connect(_on_resume_requested)
	_pause_menu.restart_requested.connect(restart_requested.emit)
	_pause_menu.settings_requested.connect(settings_requested.emit)
	_pause_menu.quit_requested.connect(quit_requested.emit)
	_apply_pause()
	print(
		"terrain loaded %dx%d in %d ms; meshes and overhead map built in %d ms"
		% [terrain.size_x, terrain.size_z, loaded_ms - started_ms, Time.get_ticks_msec() - loaded_ms]
	)


func _physics_process(_delta: float) -> void:
	if paused or _frozen:
		return
	var started_us: int = Time.get_ticks_usec()
	world.step()
	var step_ms: float = (Time.get_ticks_usec() - started_us) / 1000.0
	_sim_ms = lerpf(_sim_ms, step_ms, SIM_TIME_SMOOTHING)
	if stats != null:
		# The first step applies the deploy, so the soldiers' starting kills are
		# read after it; every step's events are read as they happen.
		if not _stats_begun:
			stats.begin(world)
			_stats_begun = true
		stats.observe(world)
	_units_view.after_step()
	_projectiles_view.after_step()
	_explosions_view.after_step()
	_fire_view.after_step()
	_gas_view.after_step()
	_plants_view.after_step()
	_ai_debug.after_step()
	_mission_hud.show_world(world)
	_objectives.show_world(world)
	if _skirmish_hud != null:
		_flags_view.after_step()
		_skirmish_hud.show_world(world)
	_terrain_view.update_fire(world.fire)
	_terrain_view.set_weather(world.weather)
	# Only a launched mission freezes; the sandbox plays on whatever it decides.
	if launch != null and world.mission != null and world.mission.outcome != MissionRuntime.Outcome.NONE:
		_freeze()


## Pauses or resumes without the menu (P). Does nothing while the pause menu is
## up, which owns the pause then, or once the mission is decided.
func toggle_pause() -> void:
	if _frozen or _pause_menu.is_open():
		return
	paused = not paused


## True once the mission is decided and the sim has stopped for good.
func is_frozen() -> bool:
	return _frozen


## The pause menu, for the App to wire to or show over.
func pause_menu() -> PauseMenu:
	return _pause_menu


func _unhandled_input(event: InputEvent) -> void:
	if world == null:
		return
	if event.is_action_pressed(InputBindings.PAUSE):
		toggle_pause()
		get_viewport().set_input_as_handled()
	elif event.is_action_pressed(InputBindings.CYCLE_WEATHER) and not _campaign() and not paused:
		_weather_preset = DebugWeather.next(_weather_preset)
		world.enqueue(DebugWeather.command(_weather_preset, world.tick))
		print("weather: %s" % DebugWeather.name_of(_weather_preset))
		get_viewport().set_input_as_handled()


# A campaign mission pauses when the window loses focus, so alt-tabbing away
# mid-fight doesn't cost the squad. Coming back doesn't resume: that is P.
func _notification(what: int) -> void:
	if what == NOTIFICATION_APPLICATION_FOCUS_OUT and _campaign() and world != null:
		paused = true


func _process(delta: float) -> void:
	if _count_down_to_the_end(delta):
		# The App may free this scene in response; there is nothing left to draw.
		return
	var w: Weather = world.weather
	var hints: String = "(F5 AI overlay)" if _campaign() else "(F5 AI overlay, F6 weather)"
	if _skirmish_hud != null:
		hints = "(F5 AI overlay, F7 scoreboard)"
	_stats_label.text = "tick %d   %d fps   %d draw calls   sim %.2f ms/tick   %d units   %d projectiles   %d paths queued\nrain %d%%   snow %d%%   wet %d%%   snow cover %d%%   %d cells burning   %s" % [
		world.tick,
		Performance.get_monitor(Performance.TIME_FPS),
		Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME),
		_sim_ms,
		world.units.size(),
		world.projectiles.size(),
		world.movement.queued_paths(),
		w.rain / 10, w.snow / 10, w.wetness() / 10, w.snow_cover() / 10,
		world.fire.burn_end.size(),
		hints,
	]


# The world to play: the launch's mission, set up by MissionSetup, or the
# sandbox's bare world on Riverside. Null, after push_error, if it can't be made.
func _create_world() -> World:
	if launch != null and launch.is_skirmish():
		return SkirmishSetup.create_world(launch.skirmish, _load_catalog())
	if launch != null:
		return MissionSetup.create_world(
			launch.mission, launch.tier, launch.world_seed, launch.deploy, _load_catalog()
		)
	var map_terrain: Terrain = Terrain.load_map(load(MAP_PATH) as MapInfo)
	if map_terrain == null:
		push_error("MainView: could not load %s" % MAP_PATH)
		return null
	return World.new(WORLD_SEED, map_terrain, _load_catalog())


func _load_catalog() -> UnitCatalog:
	var catalog: UnitCatalog = load(CATALOG_PATH) as UnitCatalog
	var errors: PackedStringArray = catalog.validate()
	if not errors.is_empty():
		push_error("MainView: invalid unit catalog: %s" % [errors])
	return catalog


# The sandbox starts south of the squads at the ford, looking north; a mission
# starts where its MissionDef says (and the camera's own default, the middle of
# the map, if it says nothing).
func _place_camera() -> void:
	if launch == null:
		_camera.set_pose(CAMERA_START, 0.0, CAMERA_START_DISTANCE)
		return
	if launch.is_skirmish():
		_place_skirmish_camera()
		return
	var mission: MissionDef = launch.mission
	if mission.camera_start.size() != 2:
		return
	var mm: float = float(World.UNITS_PER_METER)
	_camera.set_pose(
		Vector2(mission.camera_start[0], mission.camera_start[1]) / mm, 0.0, mission.camera_distance / mm
	)


# A skirmish starts over the player's army, a little ahead of it, looking the
# way it faces: the camera sits on the +Z side of its focus at yaw 0, so it
# looks along (-sin yaw, -cos yaw).
func _place_skirmish_camera() -> void:
	var setup: SkirmishSetup = launch.skirmish
	var mm: float = float(World.UNITS_PER_METER)
	var at: Vector2i = setup.map.spawn(setup.player_spawn)
	var facing: Vector2 = Vector2(setup.map.facing(setup.player_spawn)).normalized()
	if facing == Vector2.ZERO:
		facing = Vector2(0.0, -1.0)
	var focus: Vector2 = Vector2(at) / mm + facing * SKIRMISH_CAMERA_LEAD
	_camera.set_pose(focus, atan2(-facing.x, -facing.y), setup.map.camera_distance / mm)


# A skirmish's own views: its flags in the world, and under the HUD its score
# line and scoreboard. Built after the units view and the others exist, so the
# flags draw over the ground, and shown the world as it is at tick 0.
func _build_skirmish_views() -> void:
	_flags_view = FlagsView.new()
	_flags_view.name = "Flags"
	add_child(_flags_view)
	_flags_view.setup(world)
	_skirmish_hud = SkirmishHud.new()
	_skirmish_hud.name = "SkirmishHud"
	$Hud.add_child(_skirmish_hud)
	# Beside the mission's own line, so the open overhead map (later in the tree)
	# dims the score line as it does that one.
	$Hud.move_child(_skirmish_hud, _mission_hud.get_index() + 1)
	_skirmish_hud.setup(world, launch.player_faction())


# True in a campaign mission: no debug cheats, and the window's focus matters.
func _campaign() -> bool:
	return launch != null and launch.campaign_mode


# The mission is decided and this was its last tick: the sim never steps again.
# The views keep drawing what the sim ended on, and the banner is up (the HUD
# was just shown the outcome).
func _freeze() -> void:
	_frozen = true
	if stats != null:
		stats.finish(world)
	# No pausing now: the end is on its way, and a menu with Restart and Quit on
	# it, opened by Esc or the bar's Menu button, would race mission_ended.
	_pause_menu.close()
	_pause_menu.enabled = false
	_control_bar.set_menu_enabled(false)
	# The setter brings the selection, the bar and the sprites in line with a
	# sim that has stopped for good.
	paused = false


# The end of the freeze: after end_delay real seconds, once, the results are
# due. True if that was just now.
func _count_down_to_the_end(delta: float) -> bool:
	if not _frozen or _ended:
		return false
	_since_outcome += delta
	if _since_outcome < end_delay:
		return false
	_ended = true
	if launch.is_skirmish():
		skirmish_ended.emit(world.mission.outcome)
	else:
		mission_ended.emit(world.mission.outcome, stats)
	return true


# Brings everything that depends on whether the sim is stepping in line with
# it: orders are refused (and greyed on the bar), the sprites hold still at the
# latest tick, and the small Paused label shows for a pause with no menu. A
# decided mission counts as not stepping too, without the label.
func _apply_pause() -> void:
	if _selection == null:
		return
	var still: bool = paused or _frozen
	_selection.paused = still
	_control_bar.set_paused(still)
	_units_view.frozen = still
	_projectiles_view.frozen = still
	_pause_menu.show_paused_label(paused)


func _on_pause_menu_opened() -> void:
	paused = true
	_apply_edge_scroll()


func _on_pause_menu_closed() -> void:
	_apply_pause()
	_apply_edge_scroll()


# The camera's edge scroll: the setting, held off while the pause menu is up.
func _apply_edge_scroll() -> void:
	if _camera == null:
		return
	_camera.edge_scroll = edge_scroll and not (_pause_menu != null and _pause_menu.is_open())


func _on_resume_requested() -> void:
	paused = false


# Before the first step, which spawns the mission's starting groups. Its
# triggers and AI act inside World.step(), not through commands, so there is
# nothing to enqueue.
func _start_mission() -> void:
	if mission_path.is_empty():
		return
	var mission_script: MissionScript = load(mission_path) as MissionScript
	if mission_script == null or not world.start_mission(mission_script, MISSION_TIER):
		push_error("MainView: could not start the mission %s" % mission_path)


# The Light side. Enqueued as tick-0 commands, not spawned directly, so the
# setup is part of the same command stream a replay would record. The Dark
# side is the mission's, and spawns inside World.step().
func _spawn_test_squads() -> void:
	for i: int in TEST_SQUAD_SIZE:
		var offset: Vector2i = Vector2i(
			(i % TEST_SQUAD_COLUMNS) * TEST_SQUAD_SPACING, (i / TEST_SQUAD_COLUMNS) * TEST_SQUAD_SPACING
		)
		var shieldman: Vector2i = SHIELDMEN_ORIGIN + offset
		# Facing south, across the creek.
		world.enqueue(SpawnUnitCommand.new(
			world.tick, &"shieldman", UnitType.Faction.LIGHT, shieldman.x, shieldman.y, 0, 1
		))
	for i: int in TEST_SHOCK_ROW_SIZE:
		# Behind the Shieldmen is north of their block.
		var reaver: Vector2i = SHIELDMEN_ORIGIN + Vector2i(i * TEST_SQUAD_SPACING, -TEST_SQUAD_SPACING)
		world.enqueue(SpawnUnitCommand.new(
			world.tick, &"reaver", UnitType.Faction.LIGHT, reaver.x, reaver.y, 0, 1
		))
	# Phase 4: archers and grenadiers behind the block, in rows of their own,
	# two and three spacings behind the Shieldmen.
	for i: int in TEST_LONGBOW_COUNT:
		var longbow: Vector2i = SHIELDMEN_ORIGIN + Vector2i(i * TEST_SQUAD_SPACING, -2 * TEST_SQUAD_SPACING)
		world.enqueue(SpawnUnitCommand.new(
			world.tick, &"longbow", UnitType.Faction.LIGHT, longbow.x, longbow.y, 0, 1
		))
	for i: int in TEST_SAPPER_COUNT:
		var sapper: Vector2i = SHIELDMEN_ORIGIN + Vector2i(i * TEST_SQUAD_SPACING, -3 * TEST_SQUAD_SPACING)
		world.enqueue(SpawnUnitCommand.new(
			world.tick, &"sapper", UnitType.Faction.LIGHT, sapper.x, sapper.y, 0, 1
		))
	# Phase 6: Wardens behind the Sappers.
	for i: int in TEST_WARDEN_COUNT:
		var warden: Vector2i = SHIELDMEN_ORIGIN + Vector2i(i * 3 * TEST_SQUAD_SPACING / 2, -4 * TEST_SQUAD_SPACING)
		world.enqueue(SpawnUnitCommand.new(
			world.tick, &"warden", UnitType.Faction.LIGHT, warden.x, warden.y, 0, 1
		))


# The map's herb plants, as tick-0 commands like the spawns.
func _plant_herbs(map: MapInfo) -> void:
	for k: int in range(0, map.herb_plants.size() - 1, 2):
		world.enqueue(SpawnHerbPlantCommand.new(world.tick, map.herb_plants[k], map.herb_plants[k + 1]))
