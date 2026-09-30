class_name MainView
extends Node3D
## Entry scene: loads the map and unit catalog, owns the World, and advances
## it one tick per physics frame. The terrain view, camera, overhead map, and
## unit views read the World; only commands change it.

const WORLD_SEED: int = 1
const MAP_PATH: String = "res://maps/riverside/riverside.tres"
const CATALOG_PATH: String = "res://data/units/catalog.tres"
## Test setup until Phase 8's mission data: two 5x4 blocks at 2 m spacing,
## Shieldmen on the north bank by the ford, Husks across the creek. A row of
## five Reavers stands behind the Shieldmen and a row of five Rippers behind
## the Husks, on the side away from the enemy.
const TEST_SQUAD_SIZE: int = 20
const SHIELDMEN_ORIGIN: Vector2i = Vector2i(290_000, 185_000)
const HUSKS_ORIGIN: Vector2i = Vector2i(250_000, 275_000)
const TEST_SQUAD_COLUMNS: int = 5
const TEST_SQUAD_SPACING: int = 2_000
const TEST_SHOCK_ROW_SIZE: int = 5
## Where the camera starts: between the two squads, looking north.
const CAMERA_START: Vector2 = Vector2(285.0, 245.0)
const CAMERA_START_DISTANCE: float = 75.0
## Weight of the newest sample in the sim-time moving average.
const SIM_TIME_SMOOTHING: float = 0.05

var world: World

var _sim_ms: float = 0.0

@onready var _terrain_view: TerrainView = $TerrainView
@onready var _units_view: UnitsView = $Units
@onready var _gibs: Gibs = $Gibs
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
	var terrain: Terrain = Terrain.load_map(load(MAP_PATH) as MapInfo)
	var catalog: UnitCatalog = load(CATALOG_PATH) as UnitCatalog
	world = World.new(WORLD_SEED, terrain, catalog)
	if terrain == null:
		push_error("MainView: could not load %s" % MAP_PATH)
		return
	var errors: PackedStringArray = catalog.validate()
	if not errors.is_empty():
		push_error("MainView: invalid unit catalog: %s" % [errors])
	var loaded_ms: int = Time.get_ticks_msec()
	_terrain_view.build(terrain)
	_camera.setup(terrain)
	_camera.set_pose(CAMERA_START, 0.0, CAMERA_START_DISTANCE)
	_overhead_map.setup(terrain, _camera)
	_gibs.setup(terrain)
	_spawn_test_squads()
	_units_view.setup(world, _selection.selection, _gibs)
	_selection.setup(world, _units_view, _camera.get_camera(), TerrainPicker.new(terrain))
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


func _process(_delta: float) -> void:
	_stats_label.text = "tick %d   %d fps   %d draw calls   sim %.2f ms/tick   %d units   %d paths queued" % [
		world.tick,
		Performance.get_monitor(Performance.TIME_FPS),
		Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME),
		_sim_ms,
		world.units.size(),
		world.movement.queued_paths(),
	]


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
