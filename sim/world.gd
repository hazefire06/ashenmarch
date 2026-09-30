class_name World
extends RefCounted
## Deterministic fixed-tick simulation root.
##
## Owns the seeded RNG, the entity registry, and the command queue. Contains
## no Nodes and never reads the wall clock, so the same seed plus the same
## command stream always produces the same state. The view advances it by
## calling step() once per physics frame.

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

var _next_entity_id: int = 1
var _pending: Array[SimCommand] = []


func _init(world_seed: int) -> void:
	rng_seed = world_seed
	rng.seed = world_seed


## Queues a command to apply at the start of command.tick. Returns false if
## that tick has already been simulated: a late command can't be applied
## identically on every peer, so it is rejected rather than applied late.
func enqueue(command: SimCommand) -> bool:
	if command.tick < tick:
		return false
	_pending.append(command)
	return true


## Simulates one tick: apply this tick's commands in enqueue order, then
## integrate every entity.
func step() -> void:
	_apply_commands()
	_integrate()
	tick += 1


func spawn_entity(x: int, y: int, z: int) -> SimEntity:
	var entity: SimEntity = SimEntity.new(_next_entity_id, x, y, z)
	entities[entity.id] = entity
	_next_entity_id += 1
	return entity


func despawn_entity(entity_id: int) -> void:
	entities.erase(entity_id)


func get_entity(entity_id: int) -> SimEntity:
	if entities.has(entity_id):
		return entities[entity_id]
	return null


## SHA-256 over everything that defines the simulation state. Two worlds with
## equal hashes are in the same state.
func state_hash() -> String:
	var ctx: HashingContext = HashingContext.new()
	ctx.start(HashingContext.HASH_SHA256)
	var header: PackedInt64Array = PackedInt64Array(
		[tick, rng_seed, rng.state, _next_entity_id, _pending.size()]
	)
	ctx.update(header.to_byte_array())
	var ids: Array[int] = []
	ids.assign(entities.keys())
	ids.sort()
	for entity_id: int in ids:
		var e: SimEntity = entities[entity_id]
		var fields: PackedInt64Array = PackedInt64Array([e.id, e.x, e.y, e.z, e.vx, e.vy, e.vz])
		ctx.update(fields.to_byte_array())
	return ctx.finish().hex_encode()


func _apply_commands() -> void:
	var queued: Array[SimCommand] = _pending
	_pending = []
	for command: SimCommand in queued:
		if command.tick == tick:
			command.apply(self)
		else:
			_pending.append(command)


func _integrate() -> void:
	for entity: SimEntity in entities.values():
		entity.x += entity.vx
		entity.y += entity.vy
		entity.z += entity.vz
