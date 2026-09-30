class_name MainView
extends Node3D
## Entry scene: loads the map, owns the World, and advances it one tick per
## physics frame. The terrain view, camera, and overhead map read the World's
## terrain; none of them write to the sim.

const WORLD_SEED: int = 1
const MAP_PATH: String = "res://maps/riverside/riverside.tres"

var world: World

@onready var _terrain_view: TerrainView = $TerrainView
@onready var _camera: RtsCamera = $CameraRig
@onready var _overhead_map: OverheadMap = $Hud/OverheadMap
@onready var _stats_label: Label = $Hud/StatsLabel


func _ready() -> void:
	# One physics frame is one sim tick, so the physics rate is the tick rate.
	Engine.physics_ticks_per_second = World.TICK_RATE
	InputBindings.install()

	var started_ms: int = Time.get_ticks_msec()
	var terrain: Terrain = Terrain.load_map(load(MAP_PATH) as MapInfo)
	world = World.new(WORLD_SEED, terrain)
	if terrain == null:
		push_error("MainView: could not load %s" % MAP_PATH)
		return
	var loaded_ms: int = Time.get_ticks_msec()
	_terrain_view.build(terrain)
	_camera.setup(terrain)
	_overhead_map.setup(terrain, _camera)
	print(
		"terrain loaded %dx%d in %d ms; meshes and overhead map built in %d ms"
		% [terrain.size_x, terrain.size_z, loaded_ms - started_ms, Time.get_ticks_msec() - loaded_ms]
	)


func _physics_process(_delta: float) -> void:
	world.step()


func _process(_delta: float) -> void:
	_stats_label.text = "tick %d   %d fps   %d draw calls" % [
		world.tick,
		Performance.get_monitor(Performance.TIME_FPS),
		Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME),
	]
