class_name World
extends RefCounted
## Deterministic fixed-tick simulation root.
##
## Owns the seeded RNG, the entity registry, and the command queue. Contains
## no Nodes and never reads the wall clock, so the same seed plus the same
## command stream always produces the same state. The view advances it by
## calling step() once per physics frame.
##
## Units need a terrain and a unit catalog; a world without them still runs
## plain entities (the Phase 0 determinism tests).

const TICK_RATE: int = 30
## Fixed-point scale: positions are integer milli-units, velocities are
## milli-units per tick.
const UNITS_PER_METER: int = 1000

## Index of the next tick step() will simulate.
var tick: int = 0
var rng_seed: int
## The only randomness gameplay code may use.
var rng: RandomNumberGenerator = RandomNumberGenerator.new()
## Keyed by entity id. Ids are assigned in increasing order and never reused,
## so insertion order is ascending id order.
var entities: Dictionary[int, SimEntity] = {}
## The map's ground. Null for terrain-less tests. Static for now, so it is not
## part of state_hash(); add it there once explosions scar the terrain.
var terrain: Terrain
## Unit types by id and index. Null in worlds without units.
var catalog: UnitCatalog
## Null without a terrain.
var pathing: Pathing
## Every unit, alive or dead, in ascending id order (a subset of entities).
var units: Array[Unit] = []
var combat: MeleeCombat = MeleeCombat.new()
var movement: UnitMovement = UnitMovement.new()
## What happened in fights during the last step, for the view. Output only:
## cleared at the start of each step and not part of state_hash().
var combat_events: Array[CombatEvent] = []

var _next_entity_id: int = 1
var _pending: Array[SimCommand] = []


func _init(world_seed: int, world_terrain: Terrain = null, unit_catalog: UnitCatalog = null) -> void:
	rng_seed = world_seed
	rng.seed = world_seed
	terrain = world_terrain
	catalog = unit_catalog
	if terrain != null:
		pathing = Pathing.new(terrain)


## Queues a command to apply at the start of command.tick. Returns false if
## that tick has already been simulated: a late command can't be applied
## identically on every peer, so it is rejected rather than applied late.
func enqueue(command: SimCommand) -> bool:
	if command.tick < tick:
		return false
	_pending.append(command)
	return true


## Simulates one tick: apply this tick's commands in enqueue order, resolve
## melee (targets, chases, blows, deaths), steer the units (which sets their
## velocities), then integrate every entity.
func step() -> void:
	combat_events.clear()
	_apply_commands()
	if terrain != null:
		combat.update(self)
		movement.update(self)
	_integrate()
	tick += 1


func spawn_entity(x: int, y: int, z: int) -> SimEntity:
	var entity: SimEntity = SimEntity.new(_next_entity_id, x, y, z)
	_register(entity)
	return entity


## Creates a unit standing on the ground at (x, z), moved to the nearest
## sample it can stand on if (x, z) isn't one. Facing is a direction; zero
## means north. Returns null without a terrain or for a bad catalog index.
func spawn_unit(
	type_index: int, side: UnitType.Faction, x: int, z: int, face_x: int, face_z: int
) -> Unit:
	if terrain == null or catalog == null or type_index < 0 or type_index >= catalog.types.size():
		return null
	var unit_type: UnitType = catalog.types[type_index]
	var at: Vector2i = pathing.snap_to_component(x, z, unit_type.mobility, PathLayer.NO_COMPONENT)
	var unit: Unit = Unit.new(
		_next_entity_id, at.x, terrain.height_at(at.x, at.y), at.y, unit_type, type_index, side
	)
	var facing: Vector2i = FixedMath.normalize(face_x, face_z, FixedMath.DIR_ONE)
	if facing != Vector2i.ZERO:
		unit.facing_x = facing.x
		unit.facing_z = facing.y
	unit.goal_x = unit.x
	unit.goal_z = unit.z
	unit.goal_facing_x = unit.facing_x
	unit.goal_facing_z = unit.facing_z
	unit.order_x = unit.x
	unit.order_z = unit.z
	unit.order_facing_x = unit.facing_x
	unit.order_facing_z = unit.facing_z
	_register(unit)
	units.append(unit)
	return unit


func despawn_entity(entity_id: int) -> void:
	var entity: SimEntity = get_entity(entity_id)
	if entity is Unit:
		units.erase(entity)
	entities.erase(entity_id)


func get_entity(entity_id: int) -> SimEntity:
	if entities.has(entity_id):
		return entities[entity_id]
	return null


## The unit with this id, or null if there is none (or it isn't a unit).
func get_unit(unit_id: int) -> Unit:
	return get_entity(unit_id) as Unit


## SHA-256 over everything that defines the simulation state. Two worlds with
## equal hashes are in the same state.
func state_hash() -> String:
	var ctx: HashingContext = HashingContext.new()
	ctx.start(HashingContext.HASH_SHA256)
	var header: PackedInt64Array = PackedInt64Array(
		[tick, rng_seed, rng.state, _next_entity_id, _pending.size()]
	)
	ctx.update(header.to_byte_array())
	ctx.update(movement.hash_fields().to_byte_array())
	var ids: Array[int] = []
	ids.assign(entities.keys())
	ids.sort()
	for entity_id: int in ids:
		ctx.update(entities[entity_id].hash_fields().to_byte_array())
	return ctx.finish().hex_encode()


func _apply_commands() -> void:
	var queued: Array[SimCommand] = _pending
	_pending = []
	for command: SimCommand in queued:
		if command.tick == tick:
			command.apply(self)
		else:
			_pending.append(command)


func _register(entity: SimEntity) -> void:
	entities[entity.id] = entity
	_next_entity_id += 1


func _integrate() -> void:
	for entity: SimEntity in entities.values():
		entity.x += entity.vx
		entity.y += entity.vy
		entity.z += entity.vz
