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
## Mixed into the world's seed to seed a mission's draw (roll_bindings), so the
## draw's stream isn't the one world.rng starts with. Any fixed 63-bit value
## would do: this is the xorshift* multiplier, chosen only because it is a
## well-mixed constant. Changing it re-rolls every mission's draw, so treat it
## as part of the save format.
const DRAW_SALT: int = 0x2545F4914F6CDD1D

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
## Herb plants on the map, in ascending id order (a subset of entities).
var herb_plants: Array[HerbPlant] = []
## Gas clouds hanging in the air, in ascending id order (a subset of
## entities). Spent ones stay flagged until the end of the tick.
var clouds: Array[GasCloud] = []
var statuses: StatusEffects = StatusEffects.new()
var combat: MeleeCombat = MeleeCombat.new()
var interactions: Interactions = Interactions.new()
var ranged: RangedCombat = RangedCombat.new()
var movement: UnitMovement = UnitMovement.new()
var projectile_system: ProjectileSystem = ProjectileSystem.new()
var explosions: Explosions = Explosions.new()
## Rain, snow, wind, snow cover, and wetness; changed by SetWeatherCommand.
var weather: Weather = Weather.new()
## Brush fire on the terrain's samples. Null without a terrain.
var fire: Fire
## The mission in progress: its triggers, objective, and outcome. Null in a
## world with no mission (start_mission).
var mission: MissionRuntime
## The skirmish in progress: its score, flags, clock, and winner. Null in a
## world that isn't a skirmish (start_skirmish).
var skirmish: SkirmishRuntime
## Every AI group in the world. Empty without a mission, or until one spawns.
var ai: AiDirector = AiDirector.new()
## What happened in fights during the last step, for the view. Output only:
## cleared at the start of each step and not part of state_hash().
var combat_events: Array[CombatEvent] = []
## What projectiles did during the last step, for the view. Output only,
## like combat_events.
var projectile_events: Array[ProjectileEvent] = []
## What the AI did during the last step (groups spawning, switching behavior),
## for the view and tests. Output only, like combat_events, and nothing in the
## sim may read it.
var ai_events: Array[AiEvent] = []
## What the mission did during the last step (triggers fired, objectives set,
## the outcome). Output only, like ai_events.
var mission_events: Array[MissionEvent] = []
## True from when ProjectileSystem starts in the current step to the end of
## it; false between ticks. Explosions.catch reads it to keep chain delays
## exact: the pass counts down what was there when it began, so a charge
## caught earlier in the tick is counted this tick, and one spawned during or
## after it isn't.
var projectile_pass_begun: bool = false

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
## 2. run the mission's triggers (which may spawn groups, start weather
##    changes, or end the mission);
##    2b. score a skirmish (which may end it);
## 3. update the AI groups;
## 4. advance the weather (ramps, snow cover, wetness);
## 5. status effects (wear-offs, water putting out the burning, burns);
## 6. melee (targets, chases, blows, deaths);
## 7. errands (heals, pick-ups, herb plants);
## 8. ranged (targets, draws, shots leaving);
## 9. steer the units, which sets their velocities (knockback included);
## 10. integrate the units;
## 11. move the projectiles against the units' new positions: hits, bounces,
##     fuses, fire arrows lighting fires, carried things following their
##     carriers;
## 12. resolve the explosions that brings;
## 13. burn: fires go out, spread, burn out, set units alight, and catch
##     explosives;
## 14. drop removed projectiles and spent clouds.
func step() -> void:
	combat_events.clear()
	projectile_events.clear()
	ai_events.clear()
	mission_events.clear()
	projectile_pass_begun = false
	if fire != null:
		fire.changed.clear()
	_apply_commands()
	if mission != null:
		mission.update(self)
	if skirmish != null:
		skirmish.update(self)
	if not ai.groups.is_empty():
		ai.update(self)
	weather.update(tick)
	if terrain != null:
		statuses.update(self)
		combat.update(self)
		interactions.update(self)
		ranged.update(self)
		movement.update(self)
	_integrate()
	if terrain != null and catalog != null:
		projectile_pass_begun = true
		projectile_system.update(self)
		explosions.resolve(self, projectile_system.grid)
		fire.update(self)
		_drop_removed_projectiles()
		_drop_spent_clouds()
	projectile_pass_begun = false
	tick += 1


## Starts a mission from mission_script at this tier (0..4, easiest to
## hardest). Only a world that hasn't stepped yet can start one, and only one:
## the starting groups spawn on the first step, and the script's draws are
## rolled now from the world's seed (roll_bindings). Returns false and says
## why if the world has no terrain or catalog, has already stepped or started
## a mission, the script is null, the tier is out of range, or the script
## doesn't validate against the catalog.
func start_mission(mission_script: MissionScript, tier: int) -> bool:
	var problem: String = ""
	if terrain == null or catalog == null:
		problem = "the world has no terrain or unit catalog"
	elif tick != 0:
		problem = "the world has already stepped"
	elif mission != null:
		problem = "a mission has already started"
	elif mission_script == null:
		problem = "there is no mission script"
	elif tier < 0 or tier >= Difficulty.TIERS:
		problem = "tier %d is not 0..%d" % [tier, Difficulty.TIERS - 1]
	else:
		var errors: PackedStringArray = mission_script.validate(catalog)
		if not errors.is_empty():
			problem = "the script is invalid: %s" % "; ".join(errors)
	if problem != "":
		push_error("World.start_mission: " + problem)
		return false
	mission = MissionRuntime.new(mission_script, tier, tick, roll_bindings(mission_script, rng_seed))
	return true


## Makes this world's mission a skirmish played by these rules: from the
## first step SkirmishRuntime scores it and decides its outcome. Call it after
## start_mission (the AI's army is the mission's starting groups) and before
## the first step. Returns false and says why if the world has no terrain or
## catalog, has already stepped, has no mission or already a skirmish, or the
## rules are null or don't validate.
func start_skirmish(rules: SkirmishRules) -> bool:
	var problem: String = ""
	if terrain == null or catalog == null:
		problem = "the world has no terrain or unit catalog"
	elif tick != 0:
		problem = "the world has already stepped"
	elif mission == null:
		problem = "there is no mission"
	elif skirmish != null:
		problem = "a skirmish has already started"
	elif rules == null:
		problem = "there are no rules"
	else:
		var errors: PackedStringArray = rules.validate()
		if not errors.is_empty():
			problem = "the rules are invalid: %s" % "; ".join(errors)
	if problem != "":
		push_error("World.start_skirmish: " + problem)
		return false
	skirmish = SkirmishRuntime.new(rules, tick)
	return true


## Rolls the script's draws: for each draw in order and each of its slots, the
## index of the pool group bound to it, all in one array (MissionRuntime.bindings).
## Each draw is a partial Fisher-Yates shuffle of its pool, taking `slots` picks;
## with `ordered`, the picks are then bound in ascending pool order instead of
## the order drawn.
##
## It uses a generator of its own, seeded from `roll_seed` and DRAW_SALT, and
## never touches `rng`, so a mission with draws consumes the same world random
## numbers as one without and the RNG draw-order tables in architecture.md
## still hold. (It lives here rather than in sim/missions, where nothing may
## mention the world's generator.) The same script and seed always roll the
## same bindings. The script must have passed validate().
static func roll_bindings(mission_script: MissionScript, roll_seed: int) -> PackedInt32Array:
	var generator: RandomNumberGenerator = RandomNumberGenerator.new()
	generator.seed = roll_seed ^ DRAW_SALT
	var bound: PackedInt32Array = PackedInt32Array()
	for draw: MissionDraw in mission_script.draws:
		var positions: Array[int] = []
		for i: int in draw.pool.size():
			positions.append(i)
		var picks: Array[int] = []
		for k: int in draw.slots.size():
			var j: int = generator.randi_range(k, positions.size() - 1)
			var picked: int = positions[j]
			positions[j] = positions[k]
			positions[k] = picked
			picks.append(picked)
		if draw.ordered:
			picks.sort()
		for position: int in picks:
			bound.append(mission_script.group_index(draw.pool[position]))
	return bound


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


## Spawns a block of units on one side laid out in a formation: type_indices
## (catalog indices, which must all be valid) in order, front to back, on the
## formation's slots centered on (x, z) and facing (facing_x, facing_z), zero
## meaning north. Spacing follows the largest body in the block
## (Formations.spacing_for), so a block of one type packs the same whoever
## spawns it. The units are returned in list order and numbered in it, so the
## layout and the entity ids are the same for an AI group (AiDirector) and for
## a campaign roster (DeployCommand). Spawns nothing without a terrain and a
## catalog, or for an empty list.
func spawn_block(
	type_indices: Array[int], side: UnitType.Faction, x: int, z: int, facing_x: int, facing_z: int,
	formation: Formations.Kind
) -> Array[Unit]:
	var block: Array[Unit] = []
	if terrain == null or catalog == null:
		return block
	var largest_radius: int = 0
	for type_index: int in type_indices:
		largest_radius = maxi(largest_radius, catalog.types[type_index].body_radius)
	var slots: Array[FormationSlot] = Formations.slots(
		formation, type_indices.size(), x, z, facing_x, facing_z, Formations.spacing_for(largest_radius)
	)
	for i: int in type_indices.size():
		var slot: FormationSlot = slots[i]
		block.append(spawn_unit(type_indices[i], side, slot.x, slot.z, slot.facing_x, slot.facing_z))
	return block


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
	return drop_object(catalog.projectile_index_of(unit.type.special_projectile), x, z, unit.id)


## Lays a projectile of catalog type type_index on the ground at (x, z)
## (clamped to the map), at rest, dropped by owner_id (0 for none): a charge,
## a herb, a gas packet. Null for a bad index.
func drop_object(type_index: int, x: int, z: int, owner_id: int) -> Projectile:
	if type_index < 0 or type_index >= catalog.projectile_types.size():
		return null
	var radius: int = catalog.projectile_types[type_index].radius
	var cx: int = clampi(x, 0, terrain.extent_x())
	var cz: int = clampi(z, 0, terrain.extent_z())
	var p: Projectile = spawn_projectile(
		type_index, FlightState.at_mm(cx, terrain.height_at(cx, cz) + radius, cz, 0, 0, 0), owner_id
	)
	p.motion = Projectile.Motion.RESTING
	var e: ProjectileEvent = ProjectileEvent.about(ProjectileEvent.Kind.DROP, p)
	e.unit_id = owner_id
	projectile_events.append(e)
	return p


## Leaves a gas cloud of type t's gas at (x, y, z), set off by
## instigator_id. It starts paralyzing next tick (StatusEffects).
func spawn_cloud(x: int, y: int, z: int, t: ProjectileType, instigator_id: int) -> GasCloud:
	var cloud: GasCloud = GasCloud.new(
		_next_entity_id, x, y, z, t.gas_radius, t.gas_ticks, t.gas_paralysis_ticks, instigator_id
	)
	_register(cloud)
	clouds.append(cloud)
	return cloud


## Puts a herb plant on the ground at (x, z), clamped to the map.
func spawn_herb_plant(x: int, z: int) -> HerbPlant:
	if terrain == null:
		return null
	var cx: int = clampi(x, 0, terrain.extent_x())
	var cz: int = clampi(z, 0, terrain.extent_z())
	var plant: HerbPlant = HerbPlant.new(_next_entity_id, cx, terrain.height_at(cx, cz), cz)
	_register(plant)
	herb_plants.append(plant)
	return plant


## Flags a projectile for removal at the end of this tick. Loops over
## projectiles skip flagged ones; the array itself doesn't change mid-tick.
## Something carried leaves its carrier's hand.
func remove_projectile(p: Projectile) -> void:
	p.removed = true
	release(p)


## Takes p out of its carrier's hand, if it is in one. The caller decides
## what happens to it next (thrown, dropped, gone).
func release(p: Projectile) -> void:
	if p.carrier_id == 0:
		return
	var carrier: Unit = get_unit(p.carrier_id)
	if carrier != null and carrier.carried_id == p.id:
		carrier.carried_id = 0
	p.carrier_id = 0


## What unit carries, or null: a carried_id whose object is gone (burst in
## its hand, despawned) counts as empty-handed.
func carried_by(unit: Unit) -> Projectile:
	if unit.carried_id == 0:
		return null
	var p: Projectile = get_entity(unit.carried_id) as Projectile
	if p == null or p.removed or p.carrier_id != unit.id:
		return null
	return p


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
		var p: Projectile = carried_by(entity as Unit)
		if p != null:
			# Its load falls where it stood.
			release(p)
			p.flight.vx = 0
			p.flight.vy = 0
			p.flight.vz = 0
			p.motion = Projectile.Motion.FLYING
		units.erase(entity)
	elif entity is Projectile:
		release(entity as Projectile)
		projectiles.erase(entity)
	elif entity is HerbPlant:
		herb_plants.erase(entity)
	elif entity is GasCloud:
		clouds.erase(entity)
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
	ctx.update(ai.hash_fields().to_byte_array())
	if mission != null:
		ctx.update(mission.hash_fields().to_byte_array())
	if skirmish != null:
		ctx.update(skirmish.hash_fields().to_byte_array())
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


func _drop_spent_clouds() -> void:
	if clouds.is_empty():
		return
	var kept: Array[GasCloud] = []
	for cloud: GasCloud in clouds:
		if cloud.removed:
			entities.erase(cloud.id)
		else:
			kept.append(cloud)
	clouds = kept


func _drop_removed_projectiles() -> void:
	var kept: Array[Projectile] = []
	for p: Projectile in projectiles:
		if p.removed:
			entities.erase(p.id)
		else:
			kept.append(p)
	projectiles = kept
