class_name Gibs
extends Node3D
## Cosmetic gore. A unit killed with enough overkill bursts into a handful of
## small chunks that fly along the blow, tumble, land on the ground, and stay
## there for the rest of the mission. This is the one place gameplay-adjacent
## objects use Godot physics, which is allowed because nothing here touches
## the sim: chunks never affect a unit and the sim never reads them.
##
## The ground is a StaticBody3D with a HeightMapShape3D built once from the
## sim's heights. Chunks collide only with that and with each other, on their
## own physics layers. A chunk freezes (becomes static) once it sleeps or
## after SETTLE_SECONDS, and at most MAX_LIVE_CHUNKS simulate at once, so a
## long fight costs nothing per frame once the gore has settled.

## A kill gibs the body when its overkill reaches this share of max hp, in
## permille.
const GIB_OVERKILL_PERMILLE: int = 250
## Physics layers, in bits. Deliberately far from layer 1, which a stray
## default body would use: the ground is layer 9 and gibs are layer 10.
const GROUND_LAYER: int = 1 << 8
const GIB_LAYER: int = 1 << 9
const MIN_CHUNKS: int = 5
const MAX_CHUNKS: int = 7
## Chunk edge lengths in meters.
const CHUNK_SIZE_MIN: float = 0.15
const CHUNK_SIZE_MAX: float = 0.3
## Launch speeds in m/s: along the blow, upward, sideways spread, and spin in
## rad/s.
const FLING_SPEED_MIN: float = 2.0
const FLING_SPEED_MAX: float = 5.0
const LAUNCH_UP_MIN: float = 2.0
const LAUNCH_UP_MAX: float = 4.5
const SPREAD_SPEED: float = 1.5
const SPIN_SPEED: float = 12.0
## Chunks start scattered within this many meters of the burst point, so they
## don't all begin inside one another.
const SPAWN_JITTER: float = 0.3
## Chance a chunk is blood-colored rather than the unit's color.
const BLOOD_CHANCE: float = 0.4
const BLOOD_COLOR: Color = Color(0.4, 0.04, 0.04)
const FRICTION: float = 0.8
const BOUNCE: float = 0.25
const LINEAR_DAMP: float = 0.2
const ANGULAR_DAMP: float = 2.0
## Seconds a chunk may keep simulating before it is frozen where it lies.
const SETTLE_SECONDS: float = 4.0
## Most chunks simulating at once. Past this the oldest are frozen.
const MAX_LIVE_CHUNKS: int = 150
## A chunk this far (meters) under the lowest ground has fallen out of the
## world and is frozen so it stops costing anything.
const FLOOR_MARGIN: float = 20.0

## Simulating chunks and their ages in seconds. Insertion order is spawn
## order, so the first key is the oldest.
var _live: Dictionary[RigidBody3D, float] = {}
var _ground: StaticBody3D
var _floor_y: float = 0.0
var _material: PhysicsMaterial
var _materials: Dictionary[Color, StandardMaterial3D] = {}


## Whether a kill that overshot the target's remaining hp by overkill (in
## hp) destroys the body. False when there was no overkill.
static func should_gib(overkill: int, max_hp: int) -> bool:
	return overkill > 0 and overkill * 1000 >= max_hp * GIB_OVERKILL_PERMILLE


## Builds the ground collider from the terrain, replacing any earlier one.
func setup(terrain: Terrain) -> void:
	if _ground != null:
		_ground.queue_free()
	var mm: float = float(World.UNITS_PER_METER)
	var shape: HeightMapShape3D = HeightMapShape3D.new()
	# Width and depth first: setting them resizes map_data.
	shape.map_width = terrain.size_x
	shape.map_depth = terrain.size_z
	shape.map_data = _height_data(terrain)
	var collider: CollisionShape3D = CollisionShape3D.new()
	collider.shape = shape
	# The shape's samples are always 1 unit apart, so scaling x and z by the
	# cell size in meters spaces them like the terrain's. It is 1 for 1 m
	# cells, which is Riverside.
	var cell: float = terrain.cell_size / mm
	collider.scale = Vector3(cell, 1.0, cell)
	_ground = StaticBody3D.new()
	_ground.name = "Ground"
	_ground.collision_layer = GROUND_LAYER
	_ground.collision_mask = 0
	# The shape is centered on its origin, but terrain sample (0, 0) is at the
	# world origin, so shift the body by half the map's extent.
	_ground.position = Vector3(terrain.extent_x(), 0.0, terrain.extent_z()) / mm * 0.5
	_ground.add_child(collider)
	add_child(_ground)
	_floor_y = terrain.heights[0] / mm
	for h: int in terrain.heights:
		_floor_y = minf(_floor_y, h / mm)
	_floor_y -= FLOOR_MARGIN
	_material = PhysicsMaterial.new()
	_material.friction = FRICTION
	_material.bounce = BOUNCE


## Bursts a body at `at` into chunks thrown along blow_dir (horizontal or not;
## zero throws them straight up). color is the unit's color.
func spawn(at: Vector3, blow_dir: Vector3, color: Color) -> void:
	var fling: Vector3 = blow_dir.normalized()
	for _i: int in randi_range(MIN_CHUNKS, MAX_CHUNKS):
		var chunk: RigidBody3D = _make_chunk(BLOOD_COLOR if randf() < BLOOD_CHANCE else color)
		add_child(chunk)
		chunk.global_position = at + _random_vector(SPAWN_JITTER)
		chunk.linear_velocity = (
			fling * randf_range(FLING_SPEED_MIN, FLING_SPEED_MAX)
			+ Vector3.UP * randf_range(LAUNCH_UP_MIN, LAUNCH_UP_MAX)
			+ Vector3(randf_range(-1.0, 1.0), 0.0, randf_range(-1.0, 1.0)) * SPREAD_SPEED
		)
		chunk.angular_velocity = _random_vector(SPIN_SPEED)
		_live[chunk] = 0.0
	# Oldest first: they are the likeliest to have landed already.
	var by_age: Array[RigidBody3D] = []
	by_age.assign(_live.keys())
	for i: int in maxi(by_age.size() - MAX_LIVE_CHUNKS, 0):
		_freeze(by_age[i])
	set_physics_process(not _live.is_empty())


## Chunks still simulating, not yet frozen.
func live_chunk_count() -> int:
	return _live.size()


func _physics_process(delta: float) -> void:
	var settled: Array[RigidBody3D] = []
	for chunk: RigidBody3D in _live:
		var age: float = _live[chunk] + delta
		_live[chunk] = age
		if chunk.sleeping or age >= SETTLE_SECONDS or chunk.global_position.y < _floor_y:
			settled.append(chunk)
	for chunk: RigidBody3D in settled:
		_freeze(chunk)


# Makes the chunk static, where it is. It stays in the world, and on the gib
# layer so later chunks still land on it.
func _freeze(chunk: RigidBody3D) -> void:
	if not _live.erase(chunk):
		return
	chunk.freeze_mode = RigidBody3D.FREEZE_MODE_STATIC
	chunk.freeze = true
	if _live.is_empty():
		set_physics_process(false)


func _make_chunk(color: Color) -> RigidBody3D:
	var size: Vector3 = Vector3(
		randf_range(CHUNK_SIZE_MIN, CHUNK_SIZE_MAX),
		randf_range(CHUNK_SIZE_MIN, CHUNK_SIZE_MAX),
		randf_range(CHUNK_SIZE_MIN, CHUNK_SIZE_MAX)
	)
	var box: BoxMesh = BoxMesh.new()
	box.size = size
	var mesh: MeshInstance3D = MeshInstance3D.new()
	mesh.mesh = box
	mesh.material_override = _chunk_material(color)
	var box_shape: BoxShape3D = BoxShape3D.new()
	box_shape.size = size
	var collider: CollisionShape3D = CollisionShape3D.new()
	collider.shape = box_shape
	var chunk: RigidBody3D = RigidBody3D.new()
	chunk.collision_layer = GIB_LAYER
	chunk.collision_mask = GROUND_LAYER | GIB_LAYER
	chunk.physics_material_override = _material
	chunk.linear_damp = LINEAR_DAMP
	chunk.angular_damp = ANGULAR_DAMP
	# Physics runs at the 30 Hz sim rate, and a chunk landing at a few m/s
	# moves more than its own thickness in one step.
	chunk.continuous_cd = true
	chunk.add_child(mesh)
	chunk.add_child(collider)
	return chunk


# One shared material per color.
func _chunk_material(color: Color) -> StandardMaterial3D:
	var material: StandardMaterial3D = _materials.get(color)
	if material == null:
		material = StandardMaterial3D.new()
		material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		material.albedo_color = color
		_materials[color] = material
	return material


# Each component uniform in -extent..extent.
static func _random_vector(extent: float) -> Vector3:
	return Vector3(
		randf_range(-extent, extent), randf_range(-extent, extent), randf_range(-extent, extent)
	)


# Sample heights in meters, row-major: index j * size_x + i, the layout both
# the terrain and HeightMapShape3D use.
static func _height_data(terrain: Terrain) -> PackedFloat32Array:
	var mm: float = float(World.UNITS_PER_METER)
	var data: PackedFloat32Array = PackedFloat32Array()
	data.resize(terrain.heights.size())
	for k: int in terrain.heights.size():
		data[k] = terrain.heights[k] / mm
	return data
