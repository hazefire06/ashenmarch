extends GutTest
## Formation facing (Phase 11): a move order that names a facing lays its
## formation facing that way and leaves the units facing it; a zero facing is
## the automatic one, from the group toward the target, exactly as before.

const M: int = 1000
const LIGHT: UnitType.Faction = UnitType.Faction.LIGHT

var _catalog: UnitCatalog


func before_all() -> void:
	_catalog = TestUnits.catalog([TestUnits.melee(&"brawler")])


func test_a_named_facing_turns_the_line_that_way() -> void:
	var world: World = _world()
	var ids: PackedInt32Array = _line_of_four(world)
	# Marching east, but told to face south: the line must run east-west.
	world.enqueue(MoveUnitsCommand.new(0, ids, 30 * M, 20 * M, Formations.Kind.LONG_LINE, 0, 1000))
	_run(world, 20 * 30)
	var min_x: int = 1 << 30
	var max_x: int = -(1 << 30)
	var min_z: int = 1 << 30
	var max_z: int = -(1 << 30)
	for unit: Unit in world.units:
		assert_eq([unit.order_facing_x, unit.order_facing_z], [0, 1000], "unit %d's order faces south" % unit.id)
		assert_eq([unit.facing_x, unit.facing_z], [0, 1000], "unit %d ends facing south" % unit.id)
		min_x = mini(min_x, unit.x)
		max_x = maxi(max_x, unit.x)
		min_z = mini(min_z, unit.z)
		max_z = maxi(max_z, unit.z)
	assert_gt(max_x - min_x, 3 * M, "a line facing south spreads east to west")
	assert_lt(max_z - min_z, M, "one rank deep")


func test_the_facing_is_normalized() -> void:
	var world: World = _world()
	var ids: PackedInt32Array = _line_of_four(world)
	world.enqueue(MoveUnitsCommand.new(0, ids, 30 * M, 20 * M, Formations.Kind.SHORT_LINE, -7, 0))
	world.step()
	for unit: Unit in world.units:
		assert_eq([unit.order_facing_x, unit.order_facing_z], [-1000, 0])


func test_a_zero_facing_is_the_automatic_one() -> void:
	var named: World = _world()
	var plain: World = _world()
	var ids: PackedInt32Array = _line_of_four(named)
	_line_of_four(plain)
	# The automatic facing here is east, from the group toward the target.
	named.enqueue(AttackMoveCommand.new(0, ids, 30 * M, 20 * M, Formations.Kind.WEDGE, 0, 0))
	plain.enqueue(AttackMoveCommand.new(0, ids, 30 * M, 20 * M, Formations.Kind.WEDGE))
	_run(named, 300)
	_run(plain, 300)
	assert_eq(named.state_hash(), plain.state_hash())
	assert_eq([named.units[0].order_facing_x, named.units[0].order_facing_z], [1000, 0])


func test_an_attack_move_takes_a_facing_too() -> void:
	var world: World = _world()
	var ids: PackedInt32Array = _line_of_four(world)
	world.enqueue(AttackMoveCommand.new(0, ids, 30 * M, 20 * M, Formations.Kind.BOX, 0, -1000))
	world.step()
	for unit: Unit in world.units:
		assert_eq([unit.order_facing_x, unit.order_facing_z], [0, -1000])


func _world() -> World:
	return World.new(1, TestTerrains.flat(40, 40), _catalog)


# Four brawlers in a column at x = 10 m, facing east.
func _line_of_four(world: World) -> PackedInt32Array:
	var ids: PackedInt32Array = PackedInt32Array()
	for i: int in 4:
		ids.append(world.spawn_unit(0, LIGHT, 10 * M, (17 + 2 * i) * M, 1000, 0).id)
	return ids


func _run(world: World, ticks: int) -> void:
	for t: int in ticks:
		world.step()
