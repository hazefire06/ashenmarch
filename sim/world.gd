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
##
## The world owns its own copy of the terrain (Terrain.copy_for_world), so
## craters in one world never appear in another built from the same map.

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
## The map's ground, this world's own copy. Null for terrain-less tests.
## Explosions scar it; the scars are part of state_hash().
var terrain: Terrain
## Unit types by id and index. Null in worlds without units.
var catalog: UnitCatalog
## Null without a terrain.
var pathing: Pathing
## Every unit, alive or dead, in ascending id order (a subset of entities).
var units: Array[Unit] = []
## Every arrow, grenade, and charge in the world, in ascending id order (a
## subset of entities). Removed ones stay flagged until the end of the tick.
var projectiles: Array[Projectile] = []
var statuses: StatusEffects = StatusEffects.new()
var combat: MeleeCombat = MeleeCombat.new()
var ranged: RangedCombat = RangedCombat.new()
var movement: UnitMovement = UnitMovement.new()
var projectile_system: ProjectileSystem = ProjectileSystem.new()
var explosions: Explosions = Explosions.new()
## Rain, snow, wind, snow cover, and wetness; changed by SetWeatherCommand.
var weather: Weather = Weather.new()
## Brush fire on the terrain's samples. Null without a terrain.
var fire: Fire
## What happened in fights during the last step, for the view. Output only:
## cleared at the start of each step and not part of state_hash().
var combat_events: Array[CombatEvent] = []
## What projectiles did during the last step, for the view. Output only,
## like combat_events.
var projectile_events: Array[ProjectileEvent] = []

var _next_entity_id: int = 1
var _pending: Array[SimCommand] = []


func _init(world_seed: int, world_terrain: Terrain = null, unit_catalog: UnitCatalog = null) -> void:
	rng_seed = world_seed
	rng.seed = world_seed
	terrain = world_terrain.copy_for_world() if world_terrain != null else null
	catalog = unit_catalog
	if terrain != null:
		pathing = Pathing.new(terrain)
		fire = Fire.new(terrain)


## Queues a command to apply at the start of command.tick. Returns false if
## that tick has already been simulated: a late command can't be applied
## identically on every peer, so it is rejected rather than applied late.
func enqueue(command: SimCommand) -> bool:
	if command.tick < tick:
		return false
	_pending.append(command)
	return true


## Simulates one tick:
## 1. apply this tick's commands in enqueue order;
## 2. advance the weather (ramps, snow cover, wetness);
## 3. status effects (wear-offs, water putting out the burning, burns);
## 4. melee (targets, chases, blows, deaths);
## 5. ranged (targets, draws, shots leaving);
## 6. steer the units, which sets their velocities (knockback included);
## 7. integrate the units;
## 8. move the projectiles against the units' new positions: hits, bounces,
##    fuses, fire arrows lighting fires;
## 9. resolve the explosions that brings;
## 10. burn: fires go out, spread, burn out, set units alight, and catch
##     explosives;
## 11. drop removed projectiles.
func step() -> void:
	combat_events.clear()
	projectile_events.clear()
	if fire != null:
		fire.changed.clear()
	_apply_commands()
	weather.update(tick)
	if terrain != null:
		statuses.update(self)
		combat.update(self)
		ranged.update(self)
		movement.update(self)
	_integrate()
	if terrain != null and catalog != null:
		projectile_system.update(self)
		explosions.resolve(self, projectile_system.grid)
		fire.update(self)
		_drop_removed_projectiles()
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
		_next_entity_id, at.x, terrain.height_at(at.x, at.y) + unit_type.hover_height, at.y,
		unit_type, type_index, side
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


## Creates a projectile of catalog type type_index in flight, launched by
## owner_id (0 for none). Returns null for a bad index.
func spawn_projectile(type_index: int, flight: FlightState, owner_id: int) -> Projectile:
	if catalog == null or type_index < 0 or type_index >= catalog.projectile_types.size():
		return null
	var p: Projectile = Projectile.new(
		_next_entity_id, catalog.projectile_types[type_index], type_index, flight, owner_id
	)
	_register(p)
	projectiles.append(p)
	return p


## Lays unit's special charge on the ground at (x, z), at rest. It never
## goes off by itself: a blast sets it off. Null if the unit has none.
func drop_charge(unit: Unit, x: int, z: int) -> Projectile:
	var index: int = catalog.projectile_index_of(unit.type.special_projectile)
	if index < 0:
		return null
	var radius: int = catalog.projectile_types[index].radius
	var cx: int = clampi(x, 0, terrain.extent_x())
	var cz: int = clampi(z, 0, terrain.extent_z())
	var p: Projectile = spawn_projectile(
		index, FlightState.at_mm(cx, terrain.height_at(cx, cz) + radius, cz, 0, 0, 0), unit.id
	)
	p.motion = Projectile.Motion.RESTING
	var e: ProjectileEvent = ProjectileEvent.about(ProjectileEvent.Kind.DROP, p)
	e.unit_id = unit.id
	projectile_events.append(e)
	return p


## Flags a projectile for removal at the end of this tick. Loops over
## projectiles skip flagged ones; the array itself doesn't change mid-tick.
func remove_projectile(p: Projectile) -> void:
	p.removed = true


## Lights the ground at (x, z) (a fire arrow landing), credited to
## instigator_id, and tells the view. False if it can't burn there: sand,
## rock, water, or already burning or burnt.
func ignite(x: int, z: int, instigator_id: int) -> bool:
	if not fire.ignite(x, z, instigator_id, tick):
		return false
	var e: ProjectileEvent = ProjectileEvent.new(ProjectileEvent.Kind.IGNITE, x, terrain.height_at(x, z), z)
	e.unit_id = instigator_id
	projectile_events.append(e)
	return true


func despawn_entity(entity_id: int) -> void:
	var entity: SimEntity = get_entity(entity_id)
	if entity is Unit:
		units.erase(entity)
	elif entity is Projectile:
		projectiles.erase(entity)
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
		[tick, rng_seed, rng.state, _next_entity_id, _pending.size(), explosions.queued()]
	)
	ctx.update(header.to_byte_array())
	ctx.update(movement.hash_fields().to_byte_array())
	ctx.update(weather.hash_fields().to_byte_array())
	if terrain != null:
		ctx.update(terrain.scar_hash_fields().to_byte_array())
	if fire != null:
		ctx.update(fire.hash_fields().to_byte_array())
		if not fire.state.is_empty():
			# HashingContext rejects an empty buffer.
			ctx.update(fire.state)
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
		entity.integrate()


func _drop_removed_projectiles() -> void:
	var kept: Array[Projectile] = []
	for p: Projectile in projectiles:
		if p.removed:
			entities.erase(p.id)
		else:
			kept.append(p)
	projectiles = kept
