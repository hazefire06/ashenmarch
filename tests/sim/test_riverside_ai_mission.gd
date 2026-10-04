extends GutTest
## The shipped Riverside AI mission (data/missions/riverside_ai.tres), checked
## as data against the shipped catalog and the real map, and played briefly:
## it validates clean, every spawn point, waypoint, and retreat point is
## ground its group's units can stand on, the ambush lies where it can hide,
## and the starting groups and the triggers the player sets off do what the
## script says.

const M: int = 1000
const LIGHT: UnitType.Faction = UnitType.Faction.LIGHT
const DARK: UnitType.Faction = UnitType.Faction.DARK
const MISSION_PATH: String = "res://data/missions/riverside_ai.tres"
## The tier MainView plays it at.
const TIER: int = 2
## The ford on Riverside (scripts/gen_riverside.gd FORD_X_M) and the middle of
## its crossing, between the banks.
const FORD_X: int = 300
const FORD_Z: int = 227
## How far around the ambush's spot (m) the water must be depth 3 or more, so
## every member of a group laid out there is under water deep enough to hide.
const DEEP_MARGIN: int = 3
## Group and trigger names the script is expected to hold.
const GROUP_NAMES: Array[StringName] = [
	&"south_patrol", &"ford_ambush", &"raiders", &"storm", &"bags", &"drifters",
]
const TRIGGER_NAMES: Array[StringName] = [
	&"start", &"ford", &"raid", &"raid_over", &"win", &"lose",
]

var _terrain: Terrain
var _catalog: UnitCatalog
var _script: MissionScript


func before_all() -> void:
	_terrain = TestTerrains.riverside()
	_catalog = TestTerrains.catalog()
	_script = load(MISSION_PATH) as MissionScript


func test_the_script_loads_and_validates_against_the_shipped_catalog() -> void:
	assert_not_null(_script, "the mission loads as a MissionScript")
	assert_eq(_script.validate(_catalog), PackedStringArray(), "the script validates clean")


func test_it_holds_the_groups_and_triggers_the_design_names() -> void:
	for group_name: StringName in GROUP_NAMES:
		assert_gte(_script.group_index(group_name), 0, "group %s" % group_name)
	for trigger_name: StringName in TRIGGER_NAMES:
		assert_gte(_script.trigger_index(trigger_name), 0, "trigger %s" % trigger_name)
	assert_eq(_script.groups.size(), GROUP_NAMES.size())
	assert_eq(_script.triggers.size(), TRIGGER_NAMES.size())


func test_only_the_raiders_wait_for_a_trigger() -> void:
	for group: AiGroupSpec in _script.groups:
		assert_eq(group.spawn_at_start, group.name != &"raiders", "%s spawn_at_start" % group.name)


func test_every_spawn_waypoint_and_retreat_point_is_ground_its_units_can_stand_on() -> void:
	for group: AiGroupSpec in _script.groups:
		for point: Vector2i in _points_of(group):
			for mobility: Terrain.Mobility in _mobilities_of(group):
				assert_true(
					_terrain.is_passable(point.x, point.y, mobility),
					"%s: %s (milli-units) is not passable for mobility %d" % [group.name, point, mobility]
				)


func test_the_ambush_lies_in_water_deep_enough_to_hide_in() -> void:
	var ambush: AiGroupSpec = _script.groups[_script.group_index(&"ford_ambush")]
	assert_eq(ambush.behavior, AiGroupSpec.Behavior.AMBUSH)
	assert_eq(ambush.spawns.size(), 2, "one spawn point at every tier")
	assert_true(ambush.spawn_by_tier.is_empty())
	var spawn: Vector2i = ambush.spawn_point(TIER)
	var at: Vector2i = Vector2i(FixedMath.div_round(spawn.x, M), FixedMath.div_round(spawn.y, M))
	for dz: int in range(-DEEP_MARGIN, DEEP_MARGIN + 1):
		for dx: int in range(-DEEP_MARGIN, DEEP_MARGIN + 1):
			assert_gte(
				_terrain.water_depth_at((at.x + dx) * M, (at.y + dz) * M), 3,
				"(%d, %d) m is not depth 3" % [at.x + dx, at.y + dz]
			)
	var to_ford: Vector2i = at - Vector2i(FORD_X, FORD_Z)
	assert_gte(to_ford.length_squared(), 12 * 12, "at least 12 m from the ford")
	assert_lte(to_ford.length_squared(), 20 * 20, "at most 20 m from the ford")
	assert_lt(at.x, FORD_X, "west of the ford")


func test_the_ambush_counts_grow_with_the_tier() -> void:
	var ambush: AiGroupSpec = _script.groups[_script.group_index(&"ford_ambush")]
	for tier: int in Difficulty.TIERS:
		assert_eq(ambush.unit_count(tier), 4 + tier, "tier %d" % tier)


func test_trigger_areas_lie_on_the_map() -> void:
	var areas: int = 0
	for trigger: TriggerSpec in _script.triggers:
		if trigger.condition != TriggerSpec.Condition.AREA_ENTERED:
			continue
		areas += 1
		assert_true(_terrain.contains(trigger.area[0], trigger.area[1]), "%s: centre is on the map" % trigger.name)
		assert_true(
			_terrain.contains(trigger.area[0] - trigger.area[2], trigger.area[1] - trigger.area[2])
			and _terrain.contains(trigger.area[0] + trigger.area[2], trigger.area[1] + trigger.area[2]),
			"%s: the whole circle is on the map" % trigger.name
		)
	assert_gt(areas, 0, "there is an area trigger to check")


func test_the_starting_groups_spawn_with_the_tiers_counts_and_the_ambush_is_hidden() -> void:
	var world: World = _world()
	_light(world, &"shieldman", [Vector2i(290, 185), Vector2i(293, 185)])
	world.step()
	for i: int in _script.groups.size():
		var spec: AiGroupSpec = _script.groups[i]
		var spawned: Array[AiGroup] = world.ai.groups_of(i)
		if not spec.spawn_at_start:
			assert_eq(spawned.size(), 0, "%s waits for its trigger" % spec.name)
			continue
		assert_eq(spawned.size(), 1, "%s spawned once" % spec.name)
		assert_eq(spawned[0].members.size(), spec.unit_count(TIER), "%s has its tier's units" % spec.name)
		assert_eq(spawned[0].behavior, spec.behavior)
	var ambush: AiGroup = world.ai.groups_of(_script.group_index(&"ford_ambush"))[0]
	assert_eq(ambush.members.size(), 6, "tier 2 lies in wait with 6 Husks")
	for unit: Unit in ambush.living(world):
		assert_false(Visibility.seen_by(world, unit, LIGHT), "Husk %d is hidden" % unit.id)


func test_the_ford_trigger_fires_when_light_stands_in_its_area_and_springs_the_ambush() -> void:
	var near: World = _world()
	_light(near, &"shieldman", [Vector2i(298, 214), Vector2i(300, 214), Vector2i(302, 214)])
	var far: World = _world()
	_light(far, &"shieldman", [Vector2i(290, 185), Vector2i(293, 185), Vector2i(296, 185)])
	var ford: int = _script.trigger_index(&"ford")
	var ambush_spec: int = _script.group_index(&"ford_ambush")
	var sprung: bool = false
	for _t: int in 600:
		near.step()
		far.step()
		sprung = sprung or _has_event(near, AiEvent.Kind.AMBUSH_SPRUNG)
	assert_gte(near.mission.fired_tick[ford], 0, "the ford trigger fired for Light units in its area")
	assert_eq(near.mission.objective, "Hold the ford")
	assert_true(sprung, "the ambush sprang")
	assert_ne(near.ai.groups_of(ambush_spec)[0].behavior, AiGroupSpec.Behavior.AMBUSH, "and left AMBUSH")
	assert_eq(far.mission.fired_tick[ford], -1, "it did not fire for Light units 40 m away")
	assert_eq(far.mission.objective, "Cross the creek and clear the south bank")
	assert_eq(far.ai.groups_of(ambush_spec)[0].behavior, AiGroupSpec.Behavior.AMBUSH, "the ambush lies still")
	assert_eq(far.mission.outcome, MissionRuntime.Outcome.NONE)


func test_the_raid_timer_brings_the_rippers_the_rain_and_a_new_objective() -> void:
	# Light stands in the far north-west corner, out of reach of everything,
	# so the mission is still running when the timer fires.
	var world: World = _world()
	_light(world, &"shieldman", [Vector2i(60, 60), Vector2i(63, 60)])
	var raiders: int = _script.group_index(&"raiders")
	var raid: int = _script.trigger_index(&"raid")
	var timer: int = _script.triggers[raid].ticks[0]
	for _t: int in timer:
		world.step()
	assert_eq(world.ai.groups_of(raiders).size(), 0, "no raiders before the timer")
	assert_eq(world.weather.rain, 0, "clear before the timer")
	world.step()
	assert_eq(world.mission.fired_tick[raid], timer, "the timer fires %d ticks in" % timer)
	assert_eq(world.ai.groups_of(raiders).size(), 1, "the raiders spawned")
	assert_eq(world.ai.groups_of(raiders)[0].members.size(), 5, "5 Rippers")
	assert_eq(world.mission.objective, "Raiders on the flank")
	for _t: int in 200:
		world.step()
	assert_eq(world.weather.rain, 700, "the rain has ramped in")


func test_victory_waits_for_the_raid() -> void:
	var win: TriggerSpec = _script.triggers[_script.trigger_index(&"win")]
	assert_eq(win.after, &"raid", "win is gated on the raid")
	# Light wipes out every Dark unit at once, long before the raid's timer.
	var world: World = _world()
	_light(world, &"shieldman", [Vector2i(60, 60), Vector2i(63, 60)])
	world.step()
	for unit: Unit in world.units:
		if unit.faction == DARK:
			unit.kill()
	for _t: int in 60:
		world.step()
	assert_eq(world.mission.outcome, MissionRuntime.Outcome.NONE, "no victory before the raid")
	assert_eq(world.mission.fired_tick[_script.trigger_index(&"win")], -1)


# --- helpers ------------------------------------------------------------------


func _world() -> World:
	var world: World = World.new(1, _terrain, _catalog)
	assert_true(world.start_mission(_script, TIER), "the mission starts")
	return world


# Spawns Light units of type_id at the given points (metres) at tick 0.
func _light(world: World, type_id: StringName, points: Array[Vector2i]) -> void:
	for p: Vector2i in points:
		world.enqueue(SpawnUnitCommand.new(0, type_id, LIGHT, p.x * M, p.y * M))


func _has_event(world: World, kind: AiEvent.Kind) -> bool:
	for e: AiEvent in world.ai_events:
		if e.kind == kind:
			return true
	return false


# Every spawn point, waypoint, and retreat point of the group, in milli-units.
func _points_of(group: AiGroupSpec) -> Array[Vector2i]:
	var out: Array[Vector2i] = []
	for pairs: PackedInt32Array in [group.spawns, group.waypoints, group.retreat_point]:
		for k: int in range(0, pairs.size() - 1, 2):
			out.append(Vector2i(pairs[k], pairs[k + 1]))
	return out


# The distinct mobilities among the group's unit types.
func _mobilities_of(group: AiGroupSpec) -> Array[Terrain.Mobility]:
	var out: Array[Terrain.Mobility] = []
	for entry: AiUnitEntry in group.units:
		var mobility: Terrain.Mobility = _catalog.types[_catalog.index_of(entry.type_id)].mobility
		if not out.has(mobility):
			out.append(mobility)
	return out
