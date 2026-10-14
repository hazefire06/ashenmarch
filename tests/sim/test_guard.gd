extends GutTest
## Guard (G, Phase 11), after Myth II's Hold: a melee guard holds its spot
## and walks back to it; a ranged guard fires at anything in range, steps
## back from a melee enemy before it is in contact, never strays past the
## leash, fights once a fight is joined, and goes home when it is clear.

const M: int = 1000
const LIGHT: UnitType.Faction = UnitType.Faction.LIGHT
const DARK: UnitType.Faction = UnitType.Faction.DARK
const BRAWLER: int = 0
const ARCHER: int = 1
const PLODDER: int = 2

var _catalog: UnitCatalog


func before_all() -> void:
	_catalog = TestUnits.catalog([
		TestUnits.melee(&"brawler"),
		TestUnits.ranged(&"archer"),
		# Slow and tough: closes in on an archer without killing it fast.
		TestUnits.melee(&"plodder", {"move_speed": 1000, "max_hp": 100_000, "melee_damage": 1}),
	])


func test_guard_keeps_the_spot_and_the_facing() -> void:
	var world: World = _world()
	var unit: Unit = world.spawn_unit(BRAWLER, LIGHT, 20 * M, 20 * M, 1000, 0)
	world.enqueue(GuardCommand.new(0, PackedInt32Array([unit.id])))
	world.step()
	assert_eq(unit.order, Unit.Order.GUARD)
	assert_eq([unit.order_x, unit.order_z], [unit.x, unit.z])
	assert_eq([unit.order_facing_x, unit.order_facing_z], [1000, 0])


func test_a_displaced_guard_walks_home_and_a_holding_unit_does_not() -> void:
	var world: World = _world()
	var guard: Unit = world.spawn_unit(BRAWLER, LIGHT, 10 * M, 10 * M, 1000, 0)
	var holder: Unit = world.spawn_unit(BRAWLER, LIGHT, 30 * M, 10 * M, 1000, 0)
	world.enqueue(GuardCommand.new(0, PackedInt32Array([guard.id])))
	world.step()
	# Something (a blast, a fight) has carried both 3 m off their spots.
	guard.z += 3 * M
	holder.z += 3 * M
	_run(world, 5 * 30)
	assert_lt(FixedMath.length(guard.x - 10 * M, guard.z - 10 * M), Guard.HOME_RADIUS + 300, "the guard went home")
	assert_eq([guard.facing_x, guard.facing_z], [1000, 0], "and faces its way again")
	assert_eq(guard.order, Unit.Order.GUARD, "still on guard")
	assert_eq(holder.z, 13 * M, "a unit merely holding stays put")


func test_a_ranged_guard_steps_back_from_a_melee_enemy_and_shoots_again() -> void:
	var world: World = _world()
	var archer: Unit = world.spawn_unit(ARCHER, LIGHT, 25 * M, 20 * M, 1000, 0)
	var plodder: Unit = world.spawn_unit(PLODDER, DARK, 33 * M, 20 * M, -1000, 0)
	world.enqueue(GuardCommand.new(0, PackedInt32Array([archer.id])))
	world.enqueue(AttackMoveCommand.new(0, PackedInt32Array([plodder.id]), 10 * M, 20 * M, Formations.Kind.SHORT_LINE))
	var stepped_back: bool = false
	var shot_after_step: bool = false
	var farthest: int = 0
	for t: int in 30 * 30:
		var shots_before: int = _shots(world)
		world.step()
		if archer.state == Unit.State.MOVING and archer.order == Unit.Order.GUARD and archer.x < 25 * M - 2 * M:
			stepped_back = true
		if stepped_back and _shots(world) > shots_before:
			shot_after_step = true
		farthest = maxi(farthest, FixedMath.length(archer.x - 25 * M, archer.z - 20 * M))
	assert_true(stepped_back, "the archer stepped back from the melee enemy")
	assert_true(shot_after_step, "and opened fire again from there")
	assert_lt(farthest, Guard.GUARD_LEASH + 500, "never past the leash")
	assert_eq(archer.order, Unit.Order.GUARD, "still on guard")


func test_a_holding_archer_does_not_step_back() -> void:
	var world: World = _world()
	var archer: Unit = world.spawn_unit(ARCHER, LIGHT, 25 * M, 20 * M, 1000, 0)
	var plodder: Unit = world.spawn_unit(PLODDER, DARK, 33 * M, 20 * M, -1000, 0)
	world.enqueue(AttackMoveCommand.new(0, PackedInt32Array([plodder.id]), 10 * M, 20 * M, Formations.Kind.SHORT_LINE))
	for t: int in 15 * 30:
		world.step()
		assert_true(archer.x >= 25 * M - 1500, "tick %d: a holding archer only steps aside" % world.tick)


func test_a_ranged_guard_already_in_contact_fights() -> void:
	var world: World = _world()
	var archer: Unit = world.spawn_unit(ARCHER, LIGHT, 20 * M, 20 * M, 1000, 0)
	var brawler: Unit = world.spawn_unit(BRAWLER, DARK, 20 * M + 1200, 20 * M, -1000, 0)
	world.enqueue(GuardCommand.new(0, PackedInt32Array([archer.id])))
	for t: int in 30:
		world.step()
		assert_ne(archer.state, Unit.State.MOVING, "tick %d: in contact, the archer doesn't run" % world.tick)
	assert_eq(archer.target_id, brawler.id, "it fights hand to hand")


func test_a_ranged_guard_goes_home_once_the_threat_is_gone() -> void:
	var world: World = _world()
	var archer: Unit = world.spawn_unit(ARCHER, LIGHT, 25 * M, 20 * M, 1000, 0)
	var plodder: Unit = world.spawn_unit(PLODDER, DARK, 33 * M, 20 * M, -1000, 0)
	world.enqueue(GuardCommand.new(0, PackedInt32Array([archer.id])))
	world.enqueue(AttackMoveCommand.new(0, PackedInt32Array([plodder.id]), 10 * M, 20 * M, Formations.Kind.SHORT_LINE))
	for t: int in 20 * 30:
		world.step()
		if FixedMath.length(archer.x - 25 * M, archer.z - 20 * M) > 3 * M:
			break
	assert_gt(FixedMath.length(archer.x - 25 * M, archer.z - 20 * M), 3 * M, "the archer stepped away")
	plodder.kill()
	_run(world, 15 * 30)
	assert_lt(FixedMath.length(archer.x - 25 * M, archer.z - 20 * M), Guard.HOME_RADIUS + 300, "back home")


func test_a_confused_guard_resumes_guarding() -> void:
	var world: World = _world()
	var unit: Unit = world.spawn_unit(BRAWLER, LIGHT, 20 * M, 20 * M, 1000, 0)
	world.enqueue(GuardCommand.new(0, PackedInt32Array([unit.id])))
	world.enqueue(ApplyStatusCommand.new(1, PackedInt32Array([unit.id]), StatusEffects.Kind.CONFUSION, 30))
	_run(world, 60)
	assert_eq(unit.order, Unit.Order.GUARD)
	assert_eq([unit.order_x, unit.order_z], [20 * M, 20 * M], "the same spot")


func _world() -> World:
	return World.new(1, TestTerrains.flat(40, 40), _catalog)


func _run(world: World, ticks: int) -> void:
	for t: int in ticks:
		world.step()


func _shots(world: World) -> int:
	return world.projectiles.size()


func test_a_guard_whose_spot_is_taken_settles_beside_it() -> void:
	var world: World = _world()
	var guard: Unit = world.spawn_unit(BRAWLER, LIGHT, 20 * M, 20 * M, 1000, 0)
	world.enqueue(GuardCommand.new(0, PackedInt32Array([guard.id])))
	world.step()
	# Friends crowd the spot, so the nearest the guard can stand is between 1
	# and 2 m off it, and it has been pushed 4 m away.
	for dx: int in [-900, 0, 900]:
		for dz: int in [-900, 0, 900]:
			world.spawn_unit(BRAWLER, LIGHT, 20 * M + dx, 20 * M + dz, 1000, 0)
	guard.z += 4 * M
	_run(world, 10 * 30)
	var walks: int = 0
	var was_moving: bool = false
	for t: int in 10 * 30:
		world.step()
		if guard.state == Unit.State.MOVING and not was_moving:
			walks += 1
		was_moving = guard.state == Unit.State.MOVING
	assert_eq(walks, 0, "settled near the spot, it doesn't set out again")
	assert_lt(FixedMath.length(guard.x - 20 * M, guard.z - 20 * M), Guard.HOME_RADIUS + 1)
