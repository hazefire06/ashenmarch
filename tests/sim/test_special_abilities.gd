extends GutTest
## T: a Sapper drops satchel charges at its feet (four per mission), a
## Longbow nocks its one fire arrow; nothing happens with none left; a
## dying Sapper drops the charges it still carries.

const M: int = 1000
const LIGHT: UnitType.Faction = UnitType.Faction.LIGHT
const DARK: UnitType.Faction = UnitType.Faction.DARK


func test_t_drops_a_satchel_at_the_sappers_feet_four_times() -> void:
	var world: World = _world([TestUnits.thrower(&"sapper")])
	var sapper: Unit = world.spawn_unit(0, LIGHT, 20 * M, 20 * M, 1, 0)
	var drops: int = 0
	for press: int in 5:
		world.enqueue(UseSpecialCommand.new(world.tick, PackedInt32Array([sapper.id])))
		world.step()
		for e: ProjectileEvent in world.projectile_events:
			drops += 1 if e.kind == ProjectileEvent.Kind.DROP else 0
	assert_eq(drops, 4, "four charges, then nothing")
	assert_eq(sapper.special_left, 0)
	assert_eq(world.projectiles.size(), 4)
	for p: Projectile in world.projectiles:
		assert_eq(p.type.id, &"satchel")
		assert_eq(p.motion, Projectile.Motion.RESTING)
		assert_almost_eq(p.x, sapper.x, 100, "at its feet")
		assert_eq(p.owner_id, sapper.id)
		assert_eq(p.fuse_left, 0, "a charge never goes off by itself")


func test_t_nocks_the_fire_arrow_and_the_next_shot_is_it() -> void:
	var archer: UnitType = TestUnits.ranged(&"archer", {
		"special_ability": UnitType.Special.FIRE_ARROW, "special_charges": 1,
		"special_projectile": &"fire_arrow",
	})
	var world: World = _world([archer, TestUnits.dummy(&"target", {"max_hp": 1000})])
	var unit: Unit = world.spawn_unit(0, LIGHT, 10 * M, 20 * M, 1, 0)
	world.enqueue(UseSpecialCommand.new(0, PackedInt32Array([unit.id])))
	world.spawn_unit(1, DARK, 30 * M, 20 * M, -1, 0)
	var launched: Array[StringName] = []
	var ignited: Array[ProjectileEvent] = []
	for _t: int in 5 * World.TICK_RATE:
		world.step()
		for e: ProjectileEvent in world.projectile_events:
			if e.kind == ProjectileEvent.Kind.LAUNCH:
				launched.append(world.catalog.projectile_types[e.type_index].id)
			elif e.kind == ProjectileEvent.Kind.IGNITE:
				ignited.append(e)
	assert_gte(launched.size(), 2)
	assert_eq(launched[0], &"fire_arrow", "the nocked arrow goes first")
	assert_eq(launched[1], &"arrow", "and only once")
	assert_eq(unit.special_left, 0)
	assert_false(unit.fire_nocked)
	assert_eq(ignited.size(), 1, "one fire, lit where it struck")
	assert_almost_eq(ignited[0].x, 30 * M, 1000)
	assert_eq(ignited[0].unit_id, unit.id, "credited to the archer")


func test_t_with_nothing_left_does_nothing() -> void:
	var world: World = _world([TestUnits.thrower(&"sapper", {"special_charges": 1}), TestUnits.dummy(&"dummy")])
	var sapper: Unit = world.spawn_unit(0, LIGHT, 20 * M, 20 * M, 1, 0)
	var dummy: Unit = world.spawn_unit(1, LIGHT, 25 * M, 20 * M, 1, 0)
	for _press: int in 3:
		world.enqueue(UseSpecialCommand.new(world.tick, PackedInt32Array([sapper.id, dummy.id])))
		world.step()
	assert_eq(world.projectiles.size(), 1, "one charge, and the dummy has none")


func test_a_dying_sapper_drops_the_satchels_it_still_carries() -> void:
	var world: World = _world([TestUnits.thrower(&"sapper")])
	var sapper: Unit = world.spawn_unit(0, LIGHT, 20 * M, 20 * M, 1, 0)
	world.enqueue(UseSpecialCommand.new(0, PackedInt32Array([sapper.id])))
	world.step()
	Damage.apply(world, sapper, 1000, 0, 0, 0)
	assert_false(sapper.is_alive())
	assert_eq(sapper.special_left, 0)
	assert_eq(world.projectiles.size(), 4, "the one it dropped and the three it carried")
	for p: Projectile in world.projectiles:
		assert_eq(p.motion, Projectile.Motion.RESTING)
		assert_lte(FixedMath.length(p.x - sapper.x, p.z - sapper.z), Damage.DROP_SPREAD + 1)


func test_ground_attack_is_ignored_by_units_without_a_ranged_attack() -> void:
	var world: World = _world([TestUnits.melee(&"swordsman")])
	var unit: Unit = world.spawn_unit(0, LIGHT, 20 * M, 20 * M, 1, 0)
	world.enqueue(GroundAttackCommand.new(0, PackedInt32Array([unit.id]), 30 * M, 20 * M))
	world.step()
	assert_eq(unit.order, Unit.Order.NONE)


func _world(types: Array[UnitType]) -> World:
	return World.new(1, TestTerrains.flat(60, 40), TestUnits.catalog(types))
