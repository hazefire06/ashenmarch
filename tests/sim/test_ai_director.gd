extends GutTest
## AiDirector and AiGroup: spawning a group from its spec, tracking its
## members as they die or change sides, the per-member order record, and what
## the group hashes. Also the two event classes' determinism-log arrays.

const M: int = 1000
const LIGHT: UnitType.Faction = UnitType.Faction.LIGHT
const DARK: UnitType.Faction = UnitType.Faction.DARK

var _catalog: UnitCatalog


func before_all() -> void:
	var types: Array[UnitType] = [
		TestUnits.dummy(&"husk"),
		TestUnits.dummy(&"brute", {"body_radius": 600}),
	]
	_catalog = TestUnits.catalog(types)


func _spec(counts: PackedInt32Array = PackedInt32Array([4])) -> AiGroupSpec:
	var g: AiGroupSpec = AiGroupSpec.new()
	g.name = &"pack"
	var e: AiUnitEntry = AiUnitEntry.new()
	e.type_id = &"husk"
	e.counts = counts
	g.units.append(e)
	g.spawns = PackedInt32Array([20 * M, 20 * M])
	return g


func _world() -> World:
	return World.new(1, TestTerrains.flat(60, 60), _catalog)


## A world with one spawned 4-husk group.
func _with_group() -> World:
	var world: World = _world()
	world.ai.spawn_group(world, _spec(), 0, 0)
	return world


# --- events -----------------------------------------------------------------


func test_ai_event_array_is_kind_group_unit_x_z_value() -> void:
	var e: AiEvent = AiEvent.new(AiEvent.Kind.ORDER, 3, 1500, 2500, 7, 9)
	assert_eq(e.to_array(), PackedInt64Array([AiEvent.Kind.ORDER, 3, 9, 1500, 2500, 7]))
	var bare: AiEvent = AiEvent.new(AiEvent.Kind.BEHAVIOR, 2)
	assert_eq(bare.to_array(), PackedInt64Array([AiEvent.Kind.BEHAVIOR, 2, 0, 0, 0, 0]))


func test_mission_event_array_leaves_the_text_out() -> void:
	var e: MissionEvent = MissionEvent.new(MissionEvent.Kind.OBJECTIVE, 4, "Hold the mill")
	assert_eq(e.to_array(), PackedInt64Array([MissionEvent.Kind.OBJECTIVE, 4]))
	assert_eq(e.text, "Hold the mill")
	assert_eq(MissionEvent.new(MissionEvent.Kind.WON, 1).text, "")


# --- spawning ---------------------------------------------------------------


func test_spawn_group_numbers_groups_from_one_in_creation_order() -> void:
	var world: World = _world()
	var a: AiGroup = world.ai.spawn_group(world, _spec(), 0, 0)
	var b: AiGroup = world.ai.spawn_group(world, _spec(), 3, 0)
	assert_eq(a.id, 1)
	assert_eq(b.id, 2)
	assert_eq(b.spec_index, 3)
	assert_eq(world.ai.groups.size(), 2)
	assert_eq(world.ai.groups[1], b)


func test_a_spawned_group_records_its_members_and_their_positions() -> void:
	var world: World = _world()
	var spec: AiGroupSpec = _spec()
	spec.behavior = AiGroupSpec.Behavior.GUARD
	spec.guard_radius = 5 * M
	var group: AiGroup = world.ai.spawn_group(world, spec, 0, 0)
	assert_eq(group.spec, spec)
	assert_eq(group.faction, DARK)
	assert_eq(group.behavior, AiGroupSpec.Behavior.GUARD)
	assert_eq(group.members.size(), 4)
	assert_eq(group.spawned_ids, group.members)
	for i: int in 3:
		assert_lt(group.members[i], group.members[i + 1], "ascending ids")
	assert_eq(group.ordered_x.size(), 4)
	assert_eq(group.ordered_z.size(), 4)
	assert_eq(group.ordered_target.size(), 4)
	for i: int in 4:
		var unit: Unit = world.get_unit(group.members[i])
		assert_eq(group.ordered_x[i], unit.x, "starts at the unit's own spot")
		assert_eq(group.ordered_z[i], unit.z)
		assert_eq(group.ordered_target[i], 0)
	assert_eq(group.phase, 0)
	assert_false(group.think_now)
	assert_false(group.leg_active)
	assert_eq(group.waypoint_index, 0)
	assert_eq(group.waypoint_step, 1)
	assert_false(group.retreated)
	assert_eq(group.focus_id, 0)
	assert_true(group.route.is_empty())


func test_a_tier_with_no_units_still_makes_an_empty_group() -> void:
	var world: World = _world()
	var group: AiGroup = world.ai.spawn_group(world, _spec(PackedInt32Array([0, 0, 0, 0, 2])), 0, 0)
	assert_eq(world.ai.groups.size(), 1)
	assert_true(group.members.is_empty())
	assert_true(group.spawned_ids.is_empty())
	assert_eq(group.start_hp, 0)
	assert_eq(world.ai_events[0].kind, AiEvent.Kind.SPAWNED)
	assert_eq(world.ai_events[0].value, 0)


func test_groups_of_lists_the_instances_of_one_spec_in_order() -> void:
	var world: World = _world()
	var a: AiGroup = world.ai.spawn_group(world, _spec(), 0, 0)
	var b: AiGroup = world.ai.spawn_group(world, _spec(), 1, 0)
	var c: AiGroup = world.ai.spawn_group(world, _spec(), 0, 0)
	assert_eq(world.ai.groups_of(0), [a, c])
	assert_eq(world.ai.groups_of(1), [b])
	assert_true(world.ai.groups_of(2).is_empty())
	assert_true(world.ai.groups_of(-1).is_empty())


func test_a_wide_unit_widens_the_formation() -> void:
	var narrow_world: World = _world()
	var wide_world: World = _world()
	var wide: AiGroupSpec = _spec(PackedInt32Array([1]))
	var brute: AiUnitEntry = AiUnitEntry.new()
	brute.type_id = &"brute"
	brute.counts = PackedInt32Array([1])
	wide.units.append(brute)
	var narrow: AiGroup = narrow_world.ai.spawn_group(narrow_world, _spec(PackedInt32Array([2])), 0, 0)
	var broad: AiGroup = wide_world.ai.spawn_group(wide_world, wide, 0, 0)
	assert_almost_eq(_gap(narrow_world, narrow), float(Formations.spacing_for(400)), 2.0)
	assert_almost_eq(_gap(wide_world, broad), float(Formations.spacing_for(600)), 2.0)


## Distance between a two-unit group's members.
func _gap(world: World, group: AiGroup) -> float:
	var a: Unit = world.get_unit(group.members[0])
	var b: Unit = world.get_unit(group.members[1])
	return Vector2(a.x, a.z).distance_to(Vector2(b.x, b.z))


# --- set_behavior -----------------------------------------------------------


func test_set_behavior_clears_the_old_plan_and_asks_for_a_new_one() -> void:
	var world: World = _with_group()
	var group: AiGroup = world.ai.groups[0]
	group.phase = 3
	group.leg_active = true
	group.leg_retried = true
	group.focus_id = 7
	group.route = PackedInt64Array([1, 2, 3, 4])
	world.ai_events.clear()
	world.ai.set_behavior(world, group, AiGroupSpec.Behavior.HUNT)
	assert_eq(group.behavior, AiGroupSpec.Behavior.HUNT)
	assert_eq(group.phase, 0)
	assert_false(group.leg_active)
	assert_false(group.leg_retried)
	assert_eq(group.focus_id, 0)
	assert_true(group.route.is_empty())
	assert_true(group.think_now)
	assert_eq(world.ai_events.size(), 1)
	assert_eq(world.ai_events[0].to_array(), PackedInt64Array([
		AiEvent.Kind.BEHAVIOR, group.id, 0, 0, 0, AiGroupSpec.Behavior.HUNT
	]))


# --- membership -------------------------------------------------------------


func test_member_index_finds_members_only() -> void:
	var world: World = _with_group()
	var group: AiGroup = world.ai.groups[0]
	assert_eq(group.member_index(group.members[2]), 2)
	assert_eq(group.member_index(group.members[0]), 0)
	assert_eq(group.member_index(9999), -1)


func test_living_lists_member_units_in_id_order_and_skips_the_dead() -> void:
	var world: World = _with_group()
	var group: AiGroup = world.ai.groups[0]
	world.get_unit(group.members[1]).kill()
	var ids: Array[int] = []
	for unit: Unit in group.living(world):
		ids.append(unit.id)
	assert_eq(ids, [group.members[0], group.members[2], group.members[3]])


func test_prune_drops_the_dead_the_gone_and_the_turned_with_their_records() -> void:
	var world: World = _with_group()
	var group: AiGroup = world.ai.groups[0]
	for i: int in 4:
		group.record_order(group.members[i], 100 * (i + 1), 200 * (i + 1), 10 * (i + 1))
	var all_ids: PackedInt32Array = group.members.duplicate()
	world.get_unit(all_ids[0]).kill()
	world.despawn_entity(all_ids[1])
	world.get_unit(all_ids[2]).faction = LIGHT
	group.prune(world)
	assert_eq(group.members, PackedInt32Array([all_ids[3]]))
	assert_eq(group.ordered_x, PackedInt64Array([400]))
	assert_eq(group.ordered_z, PackedInt64Array([800]))
	assert_eq(group.ordered_target, PackedInt32Array([40]))
	assert_eq(group.spawned_ids, all_ids, "the record of who was ever in it stays")


func test_prune_keeps_a_group_that_is_whole() -> void:
	var world: World = _with_group()
	var group: AiGroup = world.ai.groups[0]
	var before: PackedInt64Array = group.hash_fields()
	group.prune(world)
	assert_eq(group.hash_fields(), before)


func test_director_update_prunes_every_group() -> void:
	var world: World = _world()
	var a: AiGroup = world.ai.spawn_group(world, _spec(), 0, 0)
	var b: AiGroup = world.ai.spawn_group(world, _spec(), 0, 0)
	world.get_unit(a.members[0]).kill()
	world.get_unit(b.members[3]).kill()
	world.ai.update(world)
	assert_eq(a.members.size(), 3)
	assert_eq(b.members.size(), 3)
	assert_eq(a.ordered_x.size(), 3)


func test_record_order_notes_the_goal_for_that_member_only() -> void:
	var world: World = _with_group()
	var group: AiGroup = world.ai.groups[0]
	var other_x: int = group.ordered_x[0]
	group.record_order(group.members[2], 5000, 6000, 42)
	assert_eq(group.ordered_x[2], 5000)
	assert_eq(group.ordered_z[2], 6000)
	assert_eq(group.ordered_target[2], 42)
	assert_eq(group.ordered_x[0], other_x)
	var before: PackedInt64Array = group.hash_fields()
	group.record_order(9999, 1, 2, 3)
	assert_eq(group.hash_fields(), before, "a stranger is ignored")


# --- hashing ----------------------------------------------------------------


func test_equal_directors_hash_equal_and_every_field_moves_the_hash() -> void:
	var baseline: PackedInt64Array = _with_group().ai.hash_fields()
	assert_eq(_with_group().ai.hash_fields(), baseline)
	var changes: Array[Callable] = [
		func(g: AiGroup) -> void: g.behavior = AiGroupSpec.Behavior.PATROL,
		func(g: AiGroup) -> void: g.phase = 2,
		func(g: AiGroup) -> void: g.think_now = true,
		func(g: AiGroup) -> void: g.anchor_x += 1,
		func(g: AiGroup) -> void: g.anchor_z += 1,
		func(g: AiGroup) -> void: g.waypoint_index = 1,
		func(g: AiGroup) -> void: g.waypoint_step = -1,
		func(g: AiGroup) -> void: g.leg_active = true,
		func(g: AiGroup) -> void: g.leg_x = 5,
		func(g: AiGroup) -> void: g.leg_z = 5,
		func(g: AiGroup) -> void: g.leg_retried = true,
		func(g: AiGroup) -> void: g.focus_id = 3,
		func(g: AiGroup) -> void: g.route = PackedInt64Array([1, 2]),
		func(g: AiGroup) -> void: g.route_index = 1,
		func(g: AiGroup) -> void: g.last_hp -= 1,
		func(g: AiGroup) -> void: g.start_hp -= 1,
		func(g: AiGroup) -> void: g.retreated = true,
		func(g: AiGroup) -> void: g.ordered_target[1] = 9,
		func(g: AiGroup) -> void: g.ordered_x[1] += 1,
		func(g: AiGroup) -> void: g.ordered_z[1] += 1,
		func(g: AiGroup) -> void: g.faction = LIGHT,
	]
	for i: int in changes.size():
		var world: World = _with_group()
		changes[i].call(world.ai.groups[0])
		assert_ne(world.ai.hash_fields(), baseline, "change %d" % i)
