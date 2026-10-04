class_name MainView
extends Node3D
## Entry scene: loads the map and unit catalog, owns the World, and advances
## it one tick per physics frame. The terrain view, camera, overhead map, and
## unit, projectile, explosion, fire, and weather views read the World; only
## commands change it. The gas cloud and herb plant views read it too, and so
## do the mission HUD and the F5 AI overlay.
## Everything that draws the ground is built from the World's own terrain,
## not the one loaded from the map: explosions scar the World's copy.
##
## The Light side is a test setup the player commands; the Dark side is the
## Riverside AI mission (data/missions/riverside_ai.tres), which spawns its
## groups, drives them, and brings the rain, from its own triggers.

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
## Weight of the newest sample in the sim-time moving average.
const SIM_TIME_SMOOTHING: float = 0.05

var world: World
## The mission to start, a MissionScript resource path. Set it before the
## scene enters the tree: _ready reads it. Empty starts no mission, so a
## caller (the AI demo) can start its own on the fresh world with
## World.start_mission before the first step.
var mission_path: String = MISSION_PATH

var _sim_ms: float = 0.0
## The DebugWeather preset F6 last picked.
var _weather_preset: int = 0

@onready var _terrain_view: TerrainView = $TerrainView
@onready var _units_view: UnitsView = $Units
@onready var _gibs: Gibs = $Gibs
@onready var _projectiles_view: ProjectilesView = $Projectiles
@onready var _explosions_view: ExplosionsView = $Explosions
@onready var _fire_view: FireView = $Fire
@onready var _gas_view: GasCloudsView = $GasClouds
@onready var _plants_view: HerbPlantsView = $HerbPlants
@onready var _precipitation: PrecipitationView = $Precipitation
@onready var _ai_debug: AiDebugView = $AiDebug
@onready var _camera: RtsCamera = $CameraRig
@onready var _selection: SelectionController = $Hud/Selection
@onready var _control_bar: ControlBar = $Hud/ControlBar
@onready var _overhead_map: OverheadMap = $Hud/OverheadMap
@onready var _tooltip: UnitTooltip = $Hud/UnitTooltip
@onready var _info_panel: UnitInfoPanel = $Hud/UnitInfoPanel
@onready var _stats_label: Label = $Hud/StatsLabel
@onready var _mission_hud: MissionHud = $Hud/MissionHud


func _ready() -> void:
	# One physics frame is one sim tick, so the physics rate is the tick rate.
	Engine.physics_ticks_per_second = World.TICK_RATE
	InputBindings.install()

	var started_ms: int = Time.get_ticks_msec()
	var map_terrain: Terrain = Terrain.load_map(load(MAP_PATH) as MapInfo)
	if map_terrain == null:
		push_error("MainView: could not load %s" % MAP_PATH)
		# Nothing to step or draw without a World.
		set_process(false)
		set_physics_process(false)
		return
	var catalog: UnitCatalog = load(CATALOG_PATH) as UnitCatalog
	var errors: PackedStringArray = catalog.validate()
	if not errors.is_empty():
		push_error("MainView: invalid unit catalog: %s" % [errors])
	world = World.new(WORLD_SEED, map_terrain, catalog)
	# The World's copy, which explosions scar. The views draw this one.
	var terrain: Terrain = world.terrain
	var loaded_ms: int = Time.get_ticks_msec()
	_terrain_view.build(terrain)
	_camera.setup(terrain)
	_camera.set_pose(CAMERA_START, 0.0, CAMERA_START_DISTANCE)
	_overhead_map.setup(terrain, _camera)
	_gibs.setup(terrain)
	_spawn_test_squads()
	_plant_herbs(load(MAP_PATH) as MapInfo)
	_start_mission()
	_units_view.setup(world, _selection.selection, _gibs)
	_projectiles_view.setup(world)
	_explosions_view.setup(world, _terrain_view, _gibs)
	_fire_view.setup(world)
	_gas_view.setup(world)
	_plants_view.setup(world)
	_precipitation.setup(world, _camera)
	_ai_debug.setup(world)
	_mission_hud.show_world(world)
	_selection.setup(
		world, _units_view, _camera.get_camera(), TerrainPicker.new(terrain), _projectiles_view, _plants_view
	)
	_selection.side_changed.connect(_units_view.set_viewer)
	_control_bar.setup(_selection, world)
	_info_panel.setup(_selection, world, _control_bar)
	_tooltip.setup(_selection, world, _camera.get_camera(), _projectiles_view, _plants_view)
	print(
		"terrain loaded %dx%d in %d ms; meshes and overhead map built in %d ms"
		% [terrain.size_x, terrain.size_z, loaded_ms - started_ms, Time.get_ticks_msec() - loaded_ms]
	)


func _physics_process(_delta: float) -> void:
	var started_us: int = Time.get_ticks_usec()
	world.step()
	var step_ms: float = (Time.get_ticks_usec() - started_us) / 1000.0
	_sim_ms = lerpf(_sim_ms, step_ms, SIM_TIME_SMOOTHING)
	_units_view.after_step()
	_projectiles_view.after_step()
	_explosions_view.after_step()
	_fire_view.after_step()
	_gas_view.after_step()
	_plants_view.after_step()
	_ai_debug.after_step()
	_mission_hud.show_world(world)
	_terrain_view.update_fire(world.fire)
	_terrain_view.set_weather(world.weather)


func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed(InputBindings.CYCLE_WEATHER):
		_weather_preset = DebugWeather.next(_weather_preset)
		world.enqueue(DebugWeather.command(_weather_preset, world.tick))
		print("weather: %s" % DebugWeather.name_of(_weather_preset))
		get_viewport().set_input_as_handled()


func _process(_delta: float) -> void:
	var w: Weather = world.weather
	_stats_label.text = "tick %d   %d fps   %d draw calls   sim %.2f ms/tick   %d units   %d projectiles   %d paths queued\nrain %d%%   snow %d%%   wet %d%%   snow cover %d%%   %d cells burning   (F5 AI overlay, F6 weather)" % [
		world.tick,
		Performance.get_monitor(Performance.TIME_FPS),
		Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME),
		_sim_ms,
		world.units.size(),
		world.projectiles.size(),
		world.movement.queued_paths(),
		w.rain / 10, w.snow / 10, w.wetness() / 10, w.snow_cover() / 10,
		world.fire.burn_end.size(),
	]


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
