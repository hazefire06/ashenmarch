class_name MainView
extends Node3D
## Entry scene: loads the map and unit catalog, owns the World, and advances
## it one tick per physics frame. The terrain view, camera, overhead map, and
## unit, projectile, explosion, fire, and weather views read the World; only
## commands change it. Everything that draws the ground is built from the World's own terrain,
## not the one loaded from the map: explosions scar the World's copy.

const WORLD_SEED: int = 1
const MAP_PATH: String = "res://maps/riverside/riverside.tres"
const CATALOG_PATH: String = "res://data/units/catalog.tres"
## Test weather until Phase 8's missions: showers from about 45 s, a downpour
## at 2 min, clearing at 3 min. F6 changes it until the schedule's next
## change (DebugWeather).
const WEATHER_PATH: String = "res://data/weather/riverside_showers.tres"
## Test setup until Phase 8's mission data: two 5x4 blocks at 2 m spacing,
## Shieldmen on the north bank by the ford, Husks across the creek. A row of
## five Reavers stands behind the Shieldmen and a row of five Rippers behind
## the Husks, on the side away from the enemy. Phase 4 adds a row of six
## Longbows and a row of three Sappers behind the Shieldmen and Reavers, and a
## row of six Drifters behind the Husks and Rippers.
const TEST_SQUAD_SIZE: int = 20
const SHIELDMEN_ORIGIN: Vector2i = Vector2i(290_000, 185_000)
const HUSKS_ORIGIN: Vector2i = Vector2i(250_000, 275_000)
const TEST_SQUAD_COLUMNS: int = 5
const TEST_SQUAD_SPACING: int = 2_000
const TEST_SHOCK_ROW_SIZE: int = 5
const TEST_LONGBOW_COUNT: int = 6
const TEST_SAPPER_COUNT: int = 3
const TEST_DRIFTER_COUNT: int = 6
## Where the camera starts: between the two squads, looking north.
const CAMERA_START: Vector2 = Vector2(285.0, 245.0)
const CAMERA_START_DISTANCE: float = 75.0
## Weight of the newest sample in the sim-time moving average.
const SIM_TIME_SMOOTHING: float = 0.05

var world: World

var _sim_ms: float = 0.0
## The DebugWeather preset F6 last picked.
var _weather_preset: int = 0

@onready var _terrain_view: TerrainView = $TerrainView
@onready var _units_view: UnitsView = $Units
@onready var _gibs: Gibs = $Gibs
@onready var _projectiles_view: ProjectilesView = $Projectiles
@onready var _explosions_view: ExplosionsView = $Explosions
@onready var _fire_view: FireView = $Fire
@onready var _precipitation: PrecipitationView = $Precipitation
@onready var _camera: RtsCamera = $CameraRig
@onready var _selection: SelectionController = $Hud/Selection
@onready var _control_bar: ControlBar = $Hud/ControlBar
@onready var _overhead_map: OverheadMap = $Hud/OverheadMap
@onready var _tooltip: UnitTooltip = $Hud/UnitTooltip
@onready var _stats_label: Label = $Hud/StatsLabel


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
	_schedule_weather()
	_units_view.setup(world, _selection.selection, _gibs)
	_projectiles_view.setup(world)
	_explosions_view.setup(world, _terrain_view, _gibs)
	_fire_view.setup(world)
	_precipitation.setup(world, _camera)
	_selection.setup(world, _units_view, _camera.get_camera(), TerrainPicker.new(terrain))
	_selection.side_changed.connect(_units_view.set_viewer)
	_control_bar.setup(_selection, world)
	_tooltip.setup(_selection, world)
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
	_stats_label.text = "tick %d   %d fps   %d draw calls   sim %.2f ms/tick   %d units   %d projectiles   %d paths queued\nrain %d%%   snow %d%%   wet %d%%   snow cover %d%%   %d cells burning   (F6 weather)" % [
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


# The schedule's changes go in as commands now, like the spawns, so the
# weather is part of the command stream a replay records.
func _schedule_weather() -> void:
	var schedule: WeatherSchedule = load(WEATHER_PATH) as WeatherSchedule
	var errors: PackedStringArray = schedule.validate()
	if not errors.is_empty():
		push_error("MainView: invalid weather schedule: %s" % [errors])
		return
	for command: SetWeatherCommand in schedule.commands():
		world.enqueue(command)


# Enqueued as tick-0 commands, not spawned directly, so the setup is part of
# the same command stream a replay would record.
func _spawn_test_squads() -> void:
	for i: int in TEST_SQUAD_SIZE:
		var offset: Vector2i = Vector2i(
			(i % TEST_SQUAD_COLUMNS) * TEST_SQUAD_SPACING, (i / TEST_SQUAD_COLUMNS) * TEST_SQUAD_SPACING
		)
		var shieldman: Vector2i = SHIELDMEN_ORIGIN + offset
		var husk: Vector2i = HUSKS_ORIGIN + offset
		# Each side faces the other across the creek.
		world.enqueue(SpawnUnitCommand.new(
			world.tick, &"shieldman", UnitType.Faction.LIGHT, shieldman.x, shieldman.y, 0, 1
		))
		world.enqueue(SpawnUnitCommand.new(
			world.tick, &"husk", UnitType.Faction.DARK, husk.x, husk.y, 0, -1
		))
	var block_rows: int = TEST_SQUAD_SIZE / TEST_SQUAD_COLUMNS
	for i: int in TEST_SHOCK_ROW_SIZE:
		var x_offset: int = i * TEST_SQUAD_SPACING
		# Behind the Shieldmen is north of their block, behind the Husks south.
		var reaver: Vector2i = SHIELDMEN_ORIGIN + Vector2i(x_offset, -TEST_SQUAD_SPACING)
		var ripper: Vector2i = HUSKS_ORIGIN + Vector2i(x_offset, block_rows * TEST_SQUAD_SPACING)
		world.enqueue(SpawnUnitCommand.new(
			world.tick, &"reaver", UnitType.Faction.LIGHT, reaver.x, reaver.y, 0, 1
		))
		world.enqueue(SpawnUnitCommand.new(
			world.tick, &"ripper", UnitType.Faction.DARK, ripper.x, ripper.y, 0, -1
		))
	# Phase 4: archers and grenadiers behind the Light block, Drifters behind
	# the Dark one. Rows of their own, two and three spacings behind the
	# Reavers' and Rippers'.
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
	for i: int in TEST_DRIFTER_COUNT:
		var drifter: Vector2i = HUSKS_ORIGIN + Vector2i(i * TEST_SQUAD_SPACING, (block_rows + 1) * TEST_SQUAD_SPACING)
		world.enqueue(SpawnUnitCommand.new(
			world.tick, &"drifter", UnitType.Faction.DARK, drifter.x, drifter.y, 0, -1
		))
