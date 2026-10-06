extends GutTest
## World.spawn_block (the formation layout AiDirector.spawn_group used to hold
## inline), DeployCommand (a campaign roster entering the world as one
## tick-0 command), Unit.soldier_id, and the Villager, the one unit the player
## never commands and that never fights.

const M: int = 1000
const LIGHT: UnitType.Faction = UnitType.Faction.LIGHT
const DARK: UnitType.Faction = UnitType.Faction.DARK

var _catalog: UnitCatalog
var _shieldman: int
var _reaver: int
var _longbow: int
var _husk: int
var _villager: int


func before_all() -> void:
	_catalog = TestTerrains.catalog()
	_shieldman = _catalog.index_of(&"shieldman")
	_reaver = _catalog.index_of(&"reaver")
	_longbow = _catalog.index_of(&"longbow")
	_husk = _catalog.index_of(&"husk")
	_villager = _catalog.index_of(&"villager")


# --- fixtures ---------------------------------------------------------------


func _world(world_seed: int = 1) -> World:
	return World.new(world_seed, TestTerrains.flat(120, 120), _catalog)


## A deploy command at tick 0 for these types, with soldier ids 101, 102, ...,
## no kills, and full health unless given.
func _deploy(
	type_ids: Array[StringName], kills: PackedInt32Array = PackedInt32Array(),
	hp: PackedInt32Array = PackedInt32Array(), formation: Formations.Kind = Formations.Kind.BOX
) -> DeployCommand:
	var ids: PackedInt32Array = PackedInt32Array()
	for i: int in type_ids.size():
		ids.append(101 + i)
	if kills.is_empty():
		kills.resize(type_ids.size())
	if hp.is_empty():
		hp.resize(type_ids.size())
	return DeployCommand.new(0, type_ids, ids, kills, hp, 60 * M, 60 * M, 1, 1, formation)


## What the layout code the AI used to hold inline gives for these catalog
## indices, worked out here from Formations directly: the pin that moving it
## into World.spawn_block changed nothing.
func _expected_slots(
	type_indices: Array[int], x: int, z: int, face_x: int, face_z: int, formation: Formations.Kind
) -> Array[FormationSlot]:
	var largest: int = 0
	for index: int in type_indices:
		largest = maxi(largest, _catalog.types[index].body_radius)
	return Formations.slots(
		formation, type_indices.size(), x, z, face_x, face_z, Formations.spacing_for(largest)
	)


func _group_spec(counts: Array[Array], formation: Formations.Kind) -> AiGroupSpec:
	var spec: AiGroupSpec = AiGroupSpec.new()
	spec.name = &"squad"
	spec.faction = LIGHT
	for pair: Array in counts:
		var entry: AiUnitEntry = AiUnitEntry.new()
		entry.type_id = pair[0]
		entry.counts = PackedInt32Array([pair[1]])
		spec.units.append(entry)
	spec.spawns = PackedInt32Array([60 * M, 60 * M])
	spec.facing_x = 1
	spec.facing_z = 1
	spec.formation = formation
	return spec


# --- spawn_block ------------------------------------------------------------


func test_spawn_block_lays_the_units_out_in_formation_in_list_order() -> void:
	var world: World = _world()
	var types: Array[int] = [_shieldman, _shieldman, _reaver, _longbow, _longbow]
	var units: Array[Unit] = world.spawn_block(types, LIGHT, 60 * M, 60 * M, 1, 1, Formations.Kind.WEDGE)
	var slots: Array[FormationSlot] = _expected_slots(types, 60 * M, 60 * M, 1, 1, Formations.Kind.WEDGE)
	assert_eq(units.size(), 5)
	for i: int in units.size():
		assert_eq(units[i].type_index, types[i], "unit %d is the type listed" % i)
		assert_eq(units[i].id, i + 1, "ids follow the list")
		assert_eq(units[i].faction, LIGHT)
		assert_eq(Vector2i(units[i].x, units[i].z), Vector2i(slots[i].x, slots[i].z), "unit %d on its slot" % i)
		assert_eq(
			Vector2i(units[i].facing_x, units[i].facing_z),
			FixedMath.normalize(slots[i].facing_x, slots[i].facing_z, FixedMath.DIR_ONE)
		)
		assert_true(world.units.has(units[i]), "registered with the world")


func test_spawn_block_spaces_by_the_largest_body_in_the_block() -> void:
	# A Shieldman and a bigger body: spacing follows the biggest.
	var big: UnitType = _catalog.types[_shieldman].duplicate()
	big.body_radius = 900
	var catalog: UnitCatalog = TestUnits.catalog([_catalog.types[_shieldman], big])
	var w: World = World.new(1, TestTerrains.flat(120, 120), catalog)
	var units: Array[Unit] = w.spawn_block([0, 1], LIGHT, 60 * M, 60 * M, 0, -1, Formations.Kind.SHORT_LINE)
	var gap: int = FixedMath.length(units[0].x - units[1].x, units[0].z - units[1].z)
	assert_eq(gap, Formations.spacing_for(900), "centers a big body's spacing apart")


func test_spawn_block_of_nothing_spawns_nothing_and_takes_no_ids() -> void:
	var world: World = _world()
	var none: Array[int] = []
	assert_eq(world.spawn_block(none, LIGHT, 60 * M, 60 * M, 0, -1, Formations.Kind.BOX).size(), 0)
	assert_eq(world.spawn_unit(_shieldman, LIGHT, 10 * M, 10 * M, 0, -1).id, 1)


func test_spawn_group_still_lays_its_units_out_exactly_as_it_did() -> void:
	var world: World = _world()
	var spec: AiGroupSpec = _group_spec([[&"shieldman", 3], [&"reaver", 2], [&"longbow", 2]], Formations.Kind.CIRCLE)
	var group: AiGroup = world.ai.spawn_group(world, spec, 0, 0)
	var types: Array[int] = [_shieldman, _shieldman, _shieldman, _reaver, _reaver, _longbow, _longbow]
	var slots: Array[FormationSlot] = _expected_slots(types, 60 * M, 60 * M, 1, 1, Formations.Kind.CIRCLE)
	assert_eq(group.members.size(), 7)
	assert_eq(world.units.size(), 7)
	for i: int in 7:
		var unit: Unit = world.units[i]
		assert_eq(unit.id, i + 1, "ids are 1..7 in list order")
		assert_eq(unit.type_index, types[i])
		assert_eq(Vector2i(unit.x, unit.z), Vector2i(slots[i].x, slots[i].z), "unit %d" % i)
		# spawn_unit normalizes the slot's facing once more.
		assert_eq(
			Vector2i(unit.facing_x, unit.facing_z),
			FixedMath.normalize(slots[i].facing_x, slots[i].facing_z, FixedMath.DIR_ONE)
		)
		assert_true(group.spawned_ids.has(unit.id))
		assert_true(world.ai.controls(unit.id))


# --- DeployCommand ----------------------------------------------------------


func test_a_deploy_lays_out_exactly_what_the_same_group_spawn_does() -> void:
	var by_group: World = _world()
	var spec: AiGroupSpec = _group_spec([[&"shieldman", 3], [&"reaver", 2], [&"longbow", 2]], Formations.Kind.WEDGE)
	by_group.ai.spawn_group(by_group, spec, 0, 0)
	var by_deploy: World = _world()
	var names: Array[StringName] = [
		&"shieldman", &"shieldman", &"shieldman", &"reaver", &"reaver", &"longbow", &"longbow"
	]
	by_deploy.enqueue(_deploy(names, PackedInt32Array(), PackedInt32Array(), Formations.Kind.WEDGE))
	by_deploy.step()
	assert_eq(by_deploy.units.size(), by_group.units.size())
	for i: int in by_group.units.size():
		var a: Unit = by_group.units[i]
		var b: Unit = by_deploy.units[i]
		assert_eq(b.id, a.id, "same ids")
		assert_eq(b.type_index, a.type_index)
		assert_eq(Vector2i(b.x, b.z), Vector2i(a.x, a.z), "unit %d stands where the group's does" % i)
		assert_eq(Vector2i(b.facing_x, b.facing_z), Vector2i(a.facing_x, a.facing_z))
		assert_eq(b.faction, LIGHT)


func test_a_deploy_sets_soldier_ids_kills_and_hit_points() -> void:
	var world: World = _world()
	var names: Array[StringName] = [&"shieldman", &"reaver", &"longbow"]
	var command: DeployCommand = DeployCommand.new(
		0, names, PackedInt32Array([7, 8, 9]), PackedInt32Array([3, 0, 12]),
		PackedInt32Array([40, 0, 25]), 60 * M, 60 * M, 0, 1
	)
	world.enqueue(command)
	world.step()
	assert_eq(world.units.size(), 3)
	var expect_soldier: Array[int] = [7, 8, 9]
	var expect_kills: Array[int] = [3, 0, 12]
	var expect_hp: Array[int] = [40, _catalog.types[_reaver].max_hp, 25]
	for i: int in 3:
		assert_eq(world.units[i].soldier_id, expect_soldier[i], "soldier id %d" % i)
		assert_eq(world.units[i].kills, expect_kills[i], "kills %d" % i)
		assert_eq(world.units[i].hp, expect_hp[i], "hp %d (0 means full)" % i)


func test_a_deploy_clamps_hit_points_and_kills() -> void:
	var world: World = _world()
	var names: Array[StringName] = [&"shieldman", &"shieldman", &"shieldman", &"shieldman"]
	var max_hp: int = _catalog.types[_shieldman].max_hp
	world.enqueue(_deploy(
		names, PackedInt32Array([-4, 0, 0, 0]), PackedInt32Array([-5, 1, max_hp + 50, max_hp])
	))
	world.step()
	assert_eq(world.units[0].hp, max_hp, "below 0 reads as full, like 0")
	assert_eq(world.units[0].kills, 0, "negative kills are none")
	assert_eq(world.units[1].hp, 1, "1 is the least a living soldier carries")
	assert_eq(world.units[2].hp, max_hp, "above the type's maximum is capped")
	assert_eq(world.units[3].hp, max_hp)


func test_a_deploy_drops_unknown_types_and_keeps_the_arrays_aligned() -> void:
	var world: World = _world()
	var names: Array[StringName] = [&"shieldman", &"nobody", &"reaver", &"nada", &"longbow"]
	var command: DeployCommand = DeployCommand.new(
		0, names, PackedInt32Array([11, 12, 13, 14, 15]), PackedInt32Array([1, 2, 3, 4, 5]),
		PackedInt32Array([30, 31, 32, 33, 34]), 60 * M, 60 * M, 1, 1
	)
	world.enqueue(command)
	world.step()
	assert_eq(world.units.size(), 3, "the two unknown types are skipped")
	var expect_type: Array[int] = [_shieldman, _reaver, _longbow]
	var expect_soldier: Array[int] = [11, 13, 15]
	var expect_kills: Array[int] = [1, 3, 5]
	var expect_hp: Array[int] = [30, 32, 34]
	for i: int in 3:
		assert_eq(world.units[i].type_index, expect_type[i])
		assert_eq(world.units[i].soldier_id, expect_soldier[i], "each kept entry keeps its own soldier")
		assert_eq(world.units[i].kills, expect_kills[i])
		assert_eq(world.units[i].hp, expect_hp[i])
	var slots: Array[FormationSlot] = _expected_slots(expect_type, 60 * M, 60 * M, 1, 1, Formations.Kind.BOX)
	for i: int in 3:
		var at: Vector2i = Vector2i(world.units[i].x, world.units[i].z)
		assert_eq(at, Vector2i(slots[i].x, slots[i].z), "laid out without the gaps")


func test_a_deploy_with_mismatched_arrays_does_nothing() -> void:
	var world: World = _world()
	var names: Array[StringName] = [&"shieldman", &"reaver"]
	world.enqueue(DeployCommand.new(
		0, names, PackedInt32Array([1, 2]), PackedInt32Array([0]), PackedInt32Array([0, 0]), 60 * M, 60 * M, 0, 1
	))
	world.step()
	assert_push_error("DeployCommand")
	assert_eq(world.units.size(), 0)
	world.enqueue(DeployCommand.new(
		1, names, PackedInt32Array([1]), PackedInt32Array([0, 0]), PackedInt32Array([0, 0]), 60 * M, 60 * M, 0, 1
	))
	world.step()
	assert_push_error("DeployCommand")
	assert_eq(world.units.size(), 0)


func test_a_deploy_copies_what_it_was_given() -> void:
	var world: World = _world()
	var names: Array[StringName] = [&"shieldman"]
	var soldiers: PackedInt32Array = PackedInt32Array([5])
	var command: DeployCommand = DeployCommand.new(
		0, names, soldiers, PackedInt32Array([2]), PackedInt32Array([0]), 60 * M, 60 * M, 0, 1
	)
	names.append(&"reaver")
	soldiers[0] = 99
	world.enqueue(command)
	world.step()
	assert_eq(world.units.size(), 1, "later changes to the caller's arrays don't reach a queued command")
	assert_eq(world.units[0].soldier_id, 5)


func test_a_deploy_defaults_to_the_light_side_and_can_name_another() -> void:
	var names: Array[StringName] = [&"husk"]
	var world: World = _world()
	var command: DeployCommand = _deploy(names)
	assert_eq(command.faction, LIGHT)
	command.faction = DARK
	world.enqueue(command)
	world.step()
	assert_eq(world.units[0].faction, DARK)


func test_deployed_veterancy_counts() -> void:
	var world: World = _world()
	var names: Array[StringName] = [&"shieldman", &"shieldman"]
	world.enqueue(_deploy(names, PackedInt32Array([0, 20])))
	world.step()
	var recruit: Unit = world.units[0]
	var veteran: Unit = world.units[1]
	assert_lt(Veterancy.melee_accuracy(recruit), Veterancy.melee_accuracy(veteran), "kills carried in make a veteran")


func test_a_deploy_then_a_missions_groups_number_entities_like_spawn_commands() -> void:
	var script: MissionScript = MissionFixtures.script(
		[MissionFixtures.group(&"wave", 3)], []
	)
	var types: Array[UnitType] = [TestUnits.dummy(&"husk"), TestUnits.dummy(&"walker")]
	var catalog: UnitCatalog = TestUnits.catalog(types)
	var deployed: World = World.new(1, TestTerrains.flat(60, 60), catalog)
	assert_true(deployed.start_mission(script, 0))
	var names: Array[StringName] = [&"walker", &"walker", &"walker", &"walker"]
	deployed.enqueue(DeployCommand.new(
		0, names, PackedInt32Array([1, 2, 3, 4]), PackedInt32Array([0, 0, 0, 0]),
		PackedInt32Array([0, 0, 0, 0]), 30 * M, 30 * M, 0, 1
	))
	var spawned: World = World.new(1, TestTerrains.flat(60, 60), catalog)
	assert_true(spawned.start_mission(script, 0))
	for i: int in 4:
		spawned.enqueue(SpawnUnitCommand.new(0, &"walker", LIGHT, (20 + 2 * i) * M, 30 * M))
	deployed.step()
	spawned.step()
	assert_eq(deployed.units.size(), 7)
	assert_eq(spawned.units.size(), 7)
	for i: int in 7:
		assert_eq(deployed.units[i].id, spawned.units[i].id, "entity %d" % i)
		assert_eq(deployed.units[i].type_index, spawned.units[i].type_index)
	assert_eq(deployed.ai.groups[0].spawned_ids, spawned.ai.groups[0].spawned_ids, "the same ids either way")
	assert_eq(deployed.ai.groups[0].spawned_ids, PackedInt32Array([5, 6, 7]), "5..7, after the four soldiers")


# --- soldier ids and the hash -----------------------------------------------


func test_a_units_soldier_id_is_part_of_the_state_hash() -> void:
	var names: Array[StringName] = [&"shieldman", &"reaver"]
	var a: World = _world()
	var b: World = _world()
	a.enqueue(_deploy(names))
	b.enqueue(_deploy(names))
	a.step()
	b.step()
	assert_eq(a.state_hash(), b.state_hash(), "the same roster hashes alike")
	b.units[1].soldier_id += 1
	assert_ne(a.state_hash(), b.state_hash(), "worlds differing only in one soldier id hash differently")


func test_a_unit_that_is_not_a_campaign_soldier_has_id_zero() -> void:
	var world: World = _world()
	var unit: Unit = world.spawn_unit(_shieldman, LIGHT, 10 * M, 10 * M, 0, -1)
	assert_eq(unit.soldier_id, 0)


# --- the villager -----------------------------------------------------------


func test_the_villager_is_the_last_catalog_entry_and_valid() -> void:
	assert_eq(_villager, 10, "appended, so no index moved")
	assert_eq(_catalog.types.size(), 11)
	assert_eq(_catalog.types[10].id, &"villager")
	assert_eq(_catalog.validate(), PackedStringArray())
	assert_eq(_catalog.types[_villager].validate(), PackedStringArray())
	assert_eq(_catalog.index_of(&"shieldman"), 0, "the first entries kept their places")
	assert_eq(_catalog.index_of(&"stormcaller"), 9)


func test_the_villager_is_a_slow_living_light_non_combatant() -> void:
	var t: UnitType = _catalog.types[_villager]
	assert_eq(t.display_name, "Villager")
	assert_eq(t.faction, LIGHT)
	assert_eq(t.nature, UnitType.Nature.LIVING)
	assert_eq(t.mobility, Terrain.Mobility.LIVING)
	assert_eq(t.role, UnitType.Role.SUPPORT)
	assert_eq(t.max_hp, 60)
	var shieldman: UnitType = _catalog.types[_shieldman]
	assert_eq(t.body_radius, shieldman.body_radius)
	assert_eq(t.body_height, shieldman.body_height)
	assert_eq(t.move_speed, 2200)
	assert_lt(t.move_speed, shieldman.move_speed, "slower than a Shieldman")
	assert_eq(t.water_speed_permille, PackedInt32Array([1000, 650, 400, 0, 0]))
	assert_eq(t.uphill_slowdown_permille, 500)
	assert_eq(t.melee_damage, 0, "never fights")
	assert_false(t.has_melee())
	assert_false(t.has_ranged())
	assert_eq(t.special_ability, UnitType.Special.NONE)
	assert_lt(t.move_speed, _catalog.find(&"ripper").move_speed, "and than the Ripper that hunts it")


func test_a_villager_never_picks_a_target_or_fights_even_with_a_husk_beside_it() -> void:
	var world: World = _world()
	var villager: Unit = world.spawn_unit(_villager, LIGHT, 60 * M, 60 * M, 0, -1)
	# A real Husk, close enough to swing at it from the first tick.
	var husk: Unit = world.spawn_unit(_husk, DARK, 60 * M + 1200, 60 * M, -1, 0)
	var swung_at: int = 0
	for _t: int in 400:
		world.step()
		if not villager.is_alive():
			break
		assert_eq(villager.target_id, 0, "no target at tick %d" % world.tick)
		assert_ne(villager.state, Unit.State.ATTACKING, "never attacking at tick %d" % world.tick)
		for e: CombatEvent in world.combat_events:
			if e.kind == CombatEvent.Kind.SWING and e.attacker_id == villager.id:
				swung_at += 1
	assert_eq(swung_at, 0, "it never swung")
	assert_lt(villager.hp, _catalog.types[_villager].max_hp, "the husk did hit it, so the test was a fight")
	assert_true(husk.is_alive(), "and the husk wasn't hurt by it")


func test_an_attack_moving_villager_still_picks_no_fight() -> void:
	var world: World = _world()
	var villager: Unit = world.spawn_unit(_villager, LIGHT, 40 * M, 60 * M, 1, 0)
	world.spawn_unit(_husk, DARK, 52 * M, 60 * M, -1, 0)
	var ids: PackedInt32Array = PackedInt32Array([villager.id])
	UnitOrders.move(world, ids, 90 * M, 60 * M, Formations.Kind.SHORT_LINE, true)
	for _t: int in 200:
		world.step()
		assert_eq(villager.target_id, 0)
		assert_ne(villager.state, Unit.State.ATTACKING)
