extends GutTest
## Target ranking: roles a type prefers come first (the Ripper hunts ranged
## and support units), then the nearest body edge, then the lower id. An
## approaching unit switches only for a preferred role or a clearly nearer
## enemy, so near-equal targets can't make it flip-flop.

const M: int = 1000
const LIGHT: UnitType.Faction = UnitType.Faction.LIGHT
const DARK: UnitType.Faction = UnitType.Faction.DARK

var _shieldman: UnitType
var _ripper: UnitType
var _archer: UnitType
var _healer: UnitType


func before_all() -> void:
	var shipped: UnitCatalog = TestTerrains.catalog()
	_shieldman = shipped.find(&"shieldman")
	_ripper = shipped.find(&"ripper")
	# Stand-ins until Phase 4 and 6 add the real Longbow and Warden.
	_archer = TestUnits.melee(&"archer", {"role": UnitType.Role.RANGED})
	_healer = TestUnits.melee(&"healer", {"role": UnitType.Role.SUPPORT})


func test_nearest_wins_then_lower_id() -> void:
	var me: Unit = _unit(1, _shieldman, 0, 0, LIGHT)
	var candidates: Array[Unit] = [
		_unit(5, _shieldman, 3 * M, 0, DARK),
		_unit(4, _shieldman, 0, 2 * M, DARK),
		_unit(3, _shieldman, -2 * M, 0, DARK),
	]
	assert_eq(Targeting.pick(me, candidates).id, 3)
	assert_null(Targeting.pick(me, [] as Array[Unit]))


func test_ripper_prefers_ranged_and_support_over_nearer_melee() -> void:
	var ripper: Unit = _unit(1, _ripper, 0, 0, DARK)
	var shieldman: Unit = _unit(2, _shieldman, 1500, 0, LIGHT)
	var archer: Unit = _unit(3, _archer, 8 * M, 0, LIGHT)
	var healer: Unit = _unit(4, _healer, 9 * M, 0, LIGHT)
	assert_eq(Targeting.pick(ripper, [shieldman, healer] as Array[Unit]), healer)
	assert_eq(Targeting.pick(ripper, [shieldman, healer, archer] as Array[Unit]), archer, "nearest preferred")
	assert_eq(Targeting.pick(ripper, [shieldman] as Array[Unit]), shieldman, "any enemy beats none")
	# A type with no preferences just takes the nearest.
	var me: Unit = _unit(5, _shieldman, 0, 0, LIGHT)
	assert_eq(Targeting.pick(me, [archer, _unit(6, _shieldman, 1500, 0, DARK)] as Array[Unit]).id, 6)


func test_switching_needs_a_clear_margin_or_a_preferred_role() -> void:
	var me: Unit = _unit(1, _shieldman, 0, 0, LIGHT)
	var current: Unit = _unit(2, _shieldman, 5800, 0, DARK)  # 5 m edge to edge
	assert_false(Targeting.worth_switching(me, current, _unit(3, _shieldman, 5300, 0, DARK)), "0.5 m nearer")
	assert_true(Targeting.worth_switching(me, current, _unit(4, _shieldman, 4800, 0, DARK)), "1 m nearer")
	assert_false(Targeting.worth_switching(me, current, current))
	var ripper: Unit = _unit(5, _ripper, 0, 0, DARK)
	var near_melee: Unit = _unit(6, _shieldman, 1000, 0, LIGHT)
	var far_archer: Unit = _unit(7, _archer, 9 * M, 0, LIGHT)
	assert_true(Targeting.worth_switching(ripper, near_melee, far_archer))
	assert_false(Targeting.worth_switching(ripper, far_archer, near_melee))


func test_attack_moving_ripper_runs_past_a_shieldman_for_the_archer() -> void:
	var catalog: UnitCatalog = TestUnits.catalog([_shieldman, _ripper, _archer] as Array[UnitType])
	var world: World = World.new(1, TestTerrains.flat(60, 60), catalog)
	var ripper: Unit = world.spawn_unit(1, DARK, 10 * M, 30 * M, 1, 0)
	var shieldman: Unit = world.spawn_unit(0, LIGHT, 12 * M, 27 * M, 0, 1)
	var archer: Unit = world.spawn_unit(2, LIGHT, 22 * M, 33 * M, -1, 0)
	world.enqueue(AttackMoveCommand.new(0, PackedInt32Array([ripper.id]), 50 * M, 30 * M, 0))
	world.step()
	assert_eq(ripper.target_id, archer.id, "the Shieldman is nearer; the archer is preferred")
	var first_swing: CombatEvent = null
	while first_swing == null and world.tick < 10 * 30:
		world.step()
		for event: CombatEvent in world.combat_events:
			if event.kind == CombatEvent.Kind.SWING and event.attacker_id == ripper.id:
				first_swing = event
	assert_not_null(first_swing)
	assert_eq(first_swing.target_id, archer.id)
	assert_eq(shieldman.hp, shieldman.type.max_hp)


func _unit(unit_id: int, type: UnitType, x: int, z: int, side: UnitType.Faction) -> Unit:
	return Unit.new(unit_id, x, 0, z, type, 0, side)
