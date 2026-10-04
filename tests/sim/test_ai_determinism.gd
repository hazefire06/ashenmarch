extends GutTest
## Phase 7's determinism proof: the whole AI and trigger stack on the real
## Riverside map with the shipped units. Two worlds fed the same seed, the
## same script, and the same commands make the same AI decisions, tick for
## tick, and stay hash-identical; a different seed fights differently. The
## script has a patrolling Husk squad, a Husk ambush lying in the creek, a
## Ripper flank group that a timer spawns, a hunting group with a Stormcaller
## and a Blightbag, and the triggers that spring the ambush, bring the rain,
## and decide the mission. Also the cost per tick, for docs/architecture.md.
##
## The runs go one world at a time, seed 7, then seed 8, then seed 7 again, so
## the second seed-7 world is built after another world has already played the
## same MissionScript instance: a world that mutated the shared specs or
## triggers would make that run differ from the first.

const M: int = 1000
const LIGHT: UnitType.Faction = UnitType.Faction.LIGHT
const DARK: UnitType.Faction = UnitType.Faction.DARK
const TICKS: int = 1500
const HASH_EVERY: int = 100
## How many hashes a run takes: one every HASH_EVERY ticks, the last at the end.
const HASH_COUNT: int = 15
const SEED: int = 7
const OTHER_SEED: int = 8
## The ford on Riverside (scripts/gen_riverside.gd FORD_X_M) and the middle of
## its crossing, between the banks.
const FORD_X: int = 300
const FORD_Z: int = 227
## How far around the ambush's spot (m) the water must be depth 3 or more.
const DEEP_MARGIN: int = 3

var _terrain: Terrain
var _catalog: UnitCatalog
var _mission: MissionScript
## Where the ambush lies in depth-3 water west of the ford, in metres.
var _ambush_at: Vector2i = Vector2i(-1, -1)
## The first seed-7 run, the other seed-7 run, and the seed-8 run, each as
## _run() returns it.
var _first: Dictionary = {}
var _second: Dictionary = {}
var _other: Dictionary = {}


func before_all() -> void:
	_terrain = TestTerrains.riverside()
	_catalog = TestTerrains.catalog()
	_ambush_at = _find_deep_water()
	_mission = _build_mission()
	_first = _run(SEED)
	_other = _run(OTHER_SEED)
	_second = _run(SEED)
	gut.p("AI + triggers on Riverside: %.2f / %.2f / %.2f ms/tick per world (seed %d, seed %d, seed %d), %d ticks each" % [
		_ms_per_tick(_first), _ms_per_tick(_other), _ms_per_tick(_second), SEED, OTHER_SEED, SEED, TICKS,
	])


func test_the_script_is_valid_and_the_ambush_spot_is_deep_water() -> void:
	assert_eq(_mission.validate(_catalog), PackedStringArray(), "the script validates clean")
	assert_ne(_ambush_at, Vector2i(-1, -1), "a depth-3 sample was found west of the ford")
	assert_gte(_terrain.water_depth_at(_ambush_at.x * M, _ambush_at.y * M), 3)
	var to_ford: Vector2i = _ambush_at - Vector2i(FORD_X, FORD_Z)
	assert_lt(to_ford.length_squared(), 25 * 25, "the ambush lies within 25 m of the ford")


func test_same_seed_gives_the_same_ai_decisions_every_tick() -> void:
	var log_a: Array[PackedInt64Array] = _first["log"]
	var log_b: Array[PackedInt64Array] = _second["log"]
	var mismatches: Array[int] = []
	for t: int in TICKS:
		if log_a[t] != log_b[t]:
			mismatches.append(t)
	assert_eq(log_a.size(), TICKS)
	assert_eq(log_b.size(), TICKS)
	assert_eq(mismatches.size(), 0, "ai and mission events differ at ticks %s" % [mismatches.slice(0, 10)])


func test_same_seed_gives_the_same_state_hash() -> void:
	var hashes_a: PackedStringArray = _first["hashes"]
	var hashes_b: PackedStringArray = _second["hashes"]
	var mismatches: Array[int] = []
	for i: int in hashes_a.size():
		if hashes_a[i] != hashes_b[i]:
			mismatches.append((i + 1) * HASH_EVERY)
	assert_eq(hashes_a.size(), HASH_COUNT)
	assert_eq(hashes_b.size(), HASH_COUNT)
	assert_eq(mismatches.size(), 0, "state hashes differ at ticks %s" % [mismatches])
	assert_eq(_first["final"], _second["final"], "the final hashes match")


func test_a_different_seed_plays_differently() -> void:
	# The seed is part of state_hash(), so the hashes differ from the first
	# hash on; the event log is what shows the seed changing the fight.
	var log_a: Array[PackedInt64Array] = _first["log"]
	var log_c: Array[PackedInt64Array] = _other["log"]
	var first_difference: int = -1
	for t: int in TICKS:
		if log_a[t] != log_c[t]:
			first_difference = t
			break
	assert_ne(first_difference, -1, "seed %d made the same decisions as seed %d" % [OTHER_SEED, SEED])
	assert_ne(_first["final"], _other["final"], "the final hashes differ")


func test_the_log_is_not_trivial() -> void:
	var ai: Array[int] = _first["ai_kinds"]
	var mission: Array[int] = _first["mission_kinds"]
	assert_gt(ai[AiEvent.Kind.SPAWNED], 0, "a group spawned")
	assert_gt(ai[AiEvent.Kind.ORDER], 0, "the AI ordered units around")
	assert_gt(
		ai[AiEvent.Kind.WAYPOINT_REACHED] + ai[AiEvent.Kind.WAYPOINT_FAILED], 0,
		"a patrol reached or failed a waypoint"
	)
	assert_gt(ai[AiEvent.Kind.AMBUSH_SPRUNG], 0, "the ambush sprang")
	assert_gt(mission[MissionEvent.Kind.TRIGGER_FIRED], 0, "a trigger fired")


func test_the_scenario_does_what_it_was_built_for() -> void:
	# The Light squad reached the ford, both timers ran, and the fight was real
	# enough that units died.
	var fired: PackedInt64Array = _first["fired_tick"]
	assert_gte(fired[_mission.trigger_index(&"ford")], 0, "the ford trigger fired")
	assert_gte(fired[_mission.trigger_index(&"flankers")], 0, "the flank group's timer fired")
	assert_gte(fired[_mission.trigger_index(&"rain")], 0, "the rain timer fired")
	assert_gt(_first["dead"], 0, "someone died")


# --- the run ----------------------------------------------------------------


# Steps one fresh world TICKS ticks with the scenario's commands. Returns the
# per-tick event log (the ai and mission events as to_array() lists, each
# prefixed with its count), the state hash after every HASH_EVERY ticks, the
# final hash, the event-kind counts, the microseconds spent in step(), the
# tick each trigger fired on, and how many units died.
func _run(world_seed: int) -> Dictionary:
	var world: World = World.new(world_seed, _terrain, _catalog)
	assert_true(world.start_mission(_mission, 0), "the script is accepted")
	var light_ids: PackedInt32Array = _enqueue_light_squad(world)
	var event_log: Array[PackedInt64Array] = []
	var hashes: PackedStringArray = PackedStringArray()
	var ai_kinds: Array[int] = []
	ai_kinds.resize(AiEvent.Kind.size())
	ai_kinds.fill(0)
	var mission_kinds: Array[int] = []
	mission_kinds.resize(MissionEvent.Kind.size())
	mission_kinds.fill(0)
	var spent_us: int = 0
	for t: int in TICKS:
		var started: int = Time.get_ticks_usec()
		world.step()
		spent_us += Time.get_ticks_usec() - started
		event_log.append(_tick_log(world, ai_kinds, mission_kinds))
		if t == 0:
			_check_ids(world, light_ids)
		if (t + 1) % HASH_EVERY == 0:
			hashes.append(world.state_hash())
	var dead: int = 0
	for unit: Unit in world.units:
		if not unit.is_alive():
			dead += 1
	return {
		"log": event_log,
		"hashes": hashes,
		"final": world.state_hash(),
		"ai_kinds": ai_kinds,
		"mission_kinds": mission_kinds,
		"us": spent_us,
		"fired_tick": world.mission.fired_tick,
		"dead": dead,
	}


# This tick's events, flattened: ai count, each ai event, mission count, each
# mission event. Also tallies the kinds.
func _tick_log(world: World, ai_kinds: Array[int], mission_kinds: Array[int]) -> PackedInt64Array:
	var out: PackedInt64Array = PackedInt64Array([world.ai_events.size()])
	for e: AiEvent in world.ai_events:
		out.append_array(e.to_array())
		ai_kinds[e.kind] += 1
	out.append(world.mission_events.size())
	for e: MissionEvent in world.mission_events:
		out.append_array(e.to_array())
		mission_kinds[e.kind] += 1
	return out


func _ms_per_tick(run: Dictionary) -> float:
	return float(run["us"]) / 1000.0 / TICKS


# --- the Light squad ----------------------------------------------------------


# 6 Shieldmen, 2 Longbows, a Sapper, and a Warden north of the ford, spawned at
# tick 0 and sent across it at tick 30. Spawn commands apply in order before
# anything else spawns, so the squad's ids are 1..10 (_check_ids confirms it
# after tick 0).
func _enqueue_light_squad(world: World) -> PackedInt32Array:
	var ids: PackedInt32Array = PackedInt32Array()
	var spawn: Callable = func(type_id: StringName, x: int, z: int) -> void:
		world.enqueue(SpawnUnitCommand.new(0, type_id, LIGHT, x * M, z * M))
		ids.append(ids.size() + 1)
	for row: int in 2:
		for col: int in 3:
			spawn.call(&"shieldman", 294 + col * 3, 196 + row * 2)
	for i: int in 2:
		spawn.call(&"longbow", 296 + i * 4, 190)
	spawn.call(&"sapper", 297, 186)
	spawn.call(&"warden", 301, 187)
	world.enqueue(AttackMoveCommand.new(30, ids, FORD_X * M, 250 * M, Formations.Kind.LOOSE_LINE))
	return ids


func _check_ids(world: World, light_ids: PackedInt32Array) -> void:
	var found: PackedInt32Array = PackedInt32Array()
	for unit: Unit in world.units:
		if unit.faction == LIGHT:
			found.append(unit.id)
	assert_eq(found, light_ids, "the squad's ids are the ones the move order names")


# --- the mission --------------------------------------------------------------


# The first sample, scanning x from 280 m down to 260 m and z from north to
# south across the creek, with water depth 3 or more all around it (within
# DEEP_MARGIN), so a whole group laid out there is in water deep enough to hide
# in. (-1, -1) if there is none.
func _find_deep_water() -> Vector2i:
	for x: int in range(280, 259, -1):
		for z: int in range(200, 260):
			if _deep_around(x, z):
				return Vector2i(x, z)
	return Vector2i(-1, -1)


func _deep_around(x: int, z: int) -> bool:
	for dz: int in range(-DEEP_MARGIN, DEEP_MARGIN + 1):
		for dx: int in range(-DEEP_MARGIN, DEEP_MARGIN + 1):
			if _terrain.water_depth_at((x + dx) * M, (z + dz) * M) < 3:
				return false
	return true


func _build_mission() -> MissionScript:
	var mission: MissionScript = MissionScript.new()
	# South bank Husks walking a loop; they hunt anything within 20 m.
	var patrol: AiGroupSpec = _group(&"patrol", [[&"husk", 4]], 312, 248, AiGroupSpec.Behavior.PATROL)
	patrol.waypoints = PackedInt32Array([312 * M, 248 * M, 336 * M, 248 * M, 336 * M, 268 * M, 312 * M, 268 * M])
	patrol.alert_radius = 20 * M
	# Husks lying in deep water west of the ford. The radius is small so the
	# ford trigger is what brings them up.
	var ambush: AiGroupSpec = _group(
		&"ambush", [[&"husk", 4]], _ambush_at.x, _ambush_at.y, AiGroupSpec.Behavior.AMBUSH
	)
	ambush.alert_radius = 5 * M
	# Rippers that arrive late, spawned by a timer, and go for the ranged units.
	var flankers: AiGroupSpec = _group(
		&"flankers", [[&"ripper", 3]], 262, 262, AiGroupSpec.Behavior.FLANK, false
	)
	# A marching column with a caster and a walking bomb among the Husks.
	var column: AiGroupSpec = _group(
		&"column", [[&"husk", 4], [&"stormcaller", 1], [&"blightbag", 1]], 285, 268, AiGroupSpec.Behavior.HUNT
	)
	mission.groups = [patrol, ambush, flankers, column]
	var ford: TriggerSpec = _trigger(&"ford", TriggerSpec.Condition.AREA_ENTERED)
	ford.area = PackedInt32Array([FORD_X * M, FORD_Z * M, 10 * M])
	ford.actions = [
		_objective("Hold the south bank."),
		_set_behavior(&"ambush", AiGroupSpec.Behavior.HUNT),
	]
	var flank_timer: TriggerSpec = _trigger(&"flankers", TriggerSpec.Condition.TIMER)
	flank_timer.ticks = PackedInt32Array([300])
	flank_timer.actions = [_spawn(&"flankers")]
	var rain: TriggerSpec = _trigger(&"rain", TriggerSpec.Condition.TIMER)
	rain.ticks = PackedInt32Array([600])
	var downpour: WeatherChange = WeatherChange.new()
	downpour.rain = 700
	downpour.ramp_ticks = 90
	var weather: TriggerAction = TriggerAction.new()
	weather.kind = TriggerAction.Kind.SET_WEATHER
	weather.weather = downpour
	rain.actions = [weather]
	var dark_down: TriggerSpec = _trigger(&"dark_down", TriggerSpec.Condition.FACTION_ELIMINATED)
	dark_down.faction = DARK
	dark_down.actions = [_end(TriggerAction.Kind.WIN)]
	var light_down: TriggerSpec = _trigger(&"light_down", TriggerSpec.Condition.FACTION_ELIMINATED)
	light_down.faction = LIGHT
	light_down.actions = [_end(TriggerAction.Kind.LOSE)]
	mission.triggers = [ford, flank_timer, rain, dark_down, light_down]
	return mission


# A Dark group of the listed [type id, count] pairs at (x, z) metres.
func _group(
	group_name: StringName, entries: Array, x: int, z: int, behavior: AiGroupSpec.Behavior,
	at_start: bool = true
) -> AiGroupSpec:
	var g: AiGroupSpec = AiGroupSpec.new()
	g.name = group_name
	for pair: Array in entries:
		var entry: AiUnitEntry = AiUnitEntry.new()
		entry.type_id = pair[0]
		entry.counts = PackedInt32Array([pair[1]])
		g.units.append(entry)
	g.spawns = PackedInt32Array([x * M, z * M])
	g.behavior = behavior
	g.spawn_at_start = at_start
	return g


func _trigger(trigger_name: StringName, condition: TriggerSpec.Condition) -> TriggerSpec:
	var t: TriggerSpec = TriggerSpec.new()
	t.name = trigger_name
	t.condition = condition
	return t


func _spawn(group_name: StringName) -> TriggerAction:
	var a: TriggerAction = TriggerAction.new()
	a.kind = TriggerAction.Kind.SPAWN_GROUP
	a.group = group_name
	return a


func _set_behavior(group_name: StringName, behavior: AiGroupSpec.Behavior) -> TriggerAction:
	var a: TriggerAction = TriggerAction.new()
	a.kind = TriggerAction.Kind.SET_BEHAVIOR
	a.group = group_name
	a.behavior = behavior
	return a


func _objective(text: String) -> TriggerAction:
	var a: TriggerAction = TriggerAction.new()
	a.kind = TriggerAction.Kind.SET_OBJECTIVE
	a.text = text
	return a


func _end(kind: TriggerAction.Kind) -> TriggerAction:
	var a: TriggerAction = TriggerAction.new()
	a.kind = kind
	return a
