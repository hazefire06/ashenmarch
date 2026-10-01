extends GutTest
## Carrying and throwing (Rippers): a carrier picks up a loose object, by
## order or on its own when it has nothing better to do, or tears a part off
## a body (two at most). What it holds rides in its hand, stays there through
## a blast, goes off in its hand if a blast catches it, and falls at its feet
## when it dies. It throws at the roles it hunts: a gas packet bursts where it
## lands, a body part wounds whom it hits. Scavengers share out what lies
## about, leave alone what lies in gas or across water, and go back to their
## orders afterwards.

const M: int = 1000
const LIGHT: UnitType.Faction = UnitType.Faction.LIGHT
const DARK: UnitType.Faction = UnitType.Faction.DARK

## Catalog indices of the synthetic types.
const SCAV: int = 0
const DUMMY: int = 1
const ARCHER: int = 2
const STURDY_SCAV: int = 3

var _catalog: UnitCatalog


func before_all() -> void:
	var types: Array[UnitType] = [
		TestUnits.scavenger(&"scav"),
		TestUnits.dummy(&"dummy"),
		TestUnits.dummy(&"archer_dummy", {"role": UnitType.Role.RANGED}),
		TestUnits.scavenger(&"sturdy_scav", {"max_hp": 100_000}),
	]
	_catalog = TestUnits.catalog(types)


func test_an_ordered_pickup_puts_it_in_hand_and_it_rides_there() -> void:
	var world: World = _world()
	var scav: Unit = world.spawn_unit(SCAV, DARK, 10 * M, 20 * M, 1, 0)
	var satchel: Projectile = _lay(world, &"satchel", 14 * M, 20 * M)
	world.enqueue(InteractCommand.new(0, PackedInt32Array([scav.id]), satchel.id))
	_run(world, 3 * World.TICK_RATE)
	assert_eq(satchel.motion, Projectile.Motion.CARRIED)
	assert_eq(satchel.carrier_id, scav.id)
	assert_eq(scav.carried_id, satchel.id)
	assert_true(scav.fights_at_range())
	world.enqueue(MoveUnitsCommand.new(world.tick, PackedInt32Array([scav.id]), 30 * M, 20 * M, 0))
	_run(world, 12 * World.TICK_RATE)
	assert_almost_eq(scav.x, 30 * M, 300)
	assert_eq(satchel.x, scav.x, "it went where the carrier went")
	assert_eq(satchel.z, scav.z)
	assert_eq(satchel.y, Interactions.hand_y(scav))


func test_it_throws_at_the_role_it_hunts() -> void:
	var world: World = _world()
	var scav: Unit = world.spawn_unit(SCAV, DARK, 10 * M, 20 * M, 1, 0)
	world.spawn_unit(DUMMY, LIGHT, 20 * M, 20 * M, -1, 0)
	var archer: Unit = world.spawn_unit(ARCHER, LIGHT, 20 * M, 26 * M, -1, 0)
	var satchel: Projectile = _lay(world, &"satchel", 10 * M, 20 * M)
	Interactions.take(world, scav, satchel)
	var launched: bool = false
	for _t: int in 6 * World.TICK_RATE:
		world.step()
		for e: ProjectileEvent in world.projectile_events:
			launched = launched or (e.kind == ProjectileEvent.Kind.LAUNCH and e.projectile_id == satchel.id)
	assert_true(launched)
	assert_eq(scav.carried_id, 0, "empty-handed")
	assert_false(scav.fights_at_range(), "and back to melee")
	assert_eq(satchel.owner_id, scav.id)
	assert_eq(satchel.instigator_id, scav.id)
	assert_eq(satchel.motion, Projectile.Motion.RESTING)
	assert_lt(FixedMath.length(satchel.x - archer.x, satchel.z - archer.z), 2500, "at the archer's feet")


func test_a_thrown_gas_packet_bursts_where_it_lands() -> void:
	var world: World = _world()
	var scav: Unit = world.spawn_unit(SCAV, DARK, 10 * M, 20 * M, 1, 0)
	var enemy: Unit = world.spawn_unit(ARCHER, LIGHT, 22 * M, 20 * M, -1, 0)
	var packet: Projectile = _lay(world, &"gas_packet", 10 * M, 20 * M)
	Interactions.take(world, scav, packet)
	var burst: bool = false
	for _t: int in 6 * World.TICK_RATE:
		world.step()
		for e: ProjectileEvent in world.projectile_events:
			burst = burst or (e.kind == ProjectileEvent.Kind.EXPLODE and e.projectile_id == packet.id)
		if burst:
			break
	assert_true(burst)
	assert_eq(world.clouds.size(), 1)
	assert_lt(FixedMath.length(world.clouds[0].x - enemy.x, world.clouds[0].z - enemy.z), 2000)
	world.step()
	assert_true(StatusEffects.paralyzed(world, enemy), "caught in the gas")
	assert_false(StatusEffects.paralyzed(world, scav), "the thrower stood clear of it")


func test_it_tears_a_part_off_a_body_and_the_part_wounds() -> void:
	var world: World = _world()
	var scav: Unit = world.spawn_unit(SCAV, DARK, 10 * M, 20 * M, 1, 0)
	var body: Unit = world.spawn_unit(DUMMY, LIGHT, 12 * M, 20 * M, 1, 0)
	Damage.apply(world, body, 1_000_000, 0, 0, 0)
	var enemy: Unit = world.spawn_unit(ARCHER, LIGHT, 22 * M, 20 * M, -1, 0)
	_run(world, 6 * World.TICK_RATE)
	assert_eq(body.parts_taken, 1)
	assert_eq(enemy.hp, enemy.type.max_hp - _catalog.find_projectile(&"body_part").impact_damage, "struck once")


func test_a_body_gives_two_parts_at_most() -> void:
	var world: World = _world()
	var scav: Unit = world.spawn_unit(SCAV, DARK, 10 * M, 20 * M, 1, 0)
	var body: Unit = world.spawn_unit(DUMMY, LIGHT, 12 * M, 20 * M, 1, 0)
	Damage.apply(world, body, 1_000_000, 0, 0, 0)
	body.parts_taken = Interactions.PARTS_PER_BODY
	world.enqueue(InteractCommand.new(0, PackedInt32Array([scav.id]), body.id))
	_run(world, 3 * World.TICK_RATE)
	assert_eq(scav.carried_id, 0)
	assert_eq(scav.order, Unit.Order.NONE)


func test_a_dying_carrier_drops_what_it_holds() -> void:
	var world: World = _world()
	var scav: Unit = world.spawn_unit(SCAV, DARK, 10 * M, 20 * M, 1, 0)
	var satchel: Projectile = _lay(world, &"satchel", 10 * M, 20 * M)
	Interactions.take(world, scav, satchel)
	Damage.apply(world, scav, 1_000_000, 0, 0, 0)
	assert_eq(satchel.motion, Projectile.Motion.RESTING)
	assert_eq(satchel.carrier_id, 0)
	assert_eq(satchel.x, scav.x)
	assert_eq(satchel.y, world.terrain.height_at(scav.x, scav.z) + satchel.type.radius, "on the ground")


func test_a_blast_sets_off_what_it_holds_in_its_hand() -> void:
	var world: World = _world()
	var scav: Unit = world.spawn_unit(STURDY_SCAV, DARK, 10 * M, 20 * M, 1, 0)
	var satchel: Projectile = _lay(world, &"satchel", 10 * M, 20 * M)
	Interactions.take(world, scav, satchel)
	var grenade: Projectile = _lay(world, &"grenade", 13 * M, 20 * M)
	world.explosions.detonate(world, grenade)
	world.step()
	assert_true(satchel.detonating, "caught by the blast")
	assert_eq(satchel.motion, Projectile.Motion.CARRIED, "and not knocked out of its hand")
	_run(world, Explosions.CHAIN_DELAY_TICKS + 1)
	assert_true(satchel.removed or not world.projectiles.has(satchel), "gone off in its hand")
	assert_eq(scav.carried_id, 0)
	assert_false(scav.fights_at_range())


func test_a_scavenger_goes_for_the_nearest_thing_on_its_own() -> void:
	var world: World = _world()
	var scav: Unit = world.spawn_unit(SCAV, DARK, 10 * M, 20 * M, 1, 0)
	var near: Projectile = _lay(world, &"satchel", 14 * M, 20 * M)
	var farther: Projectile = _lay(world, &"gas_packet", 16 * M, 20 * M)
	var beyond: Projectile = _lay(world, &"satchel", 25 * M, 20 * M)
	_run(world, 4 * World.TICK_RATE)
	assert_eq(scav.carried_id, near.id)
	assert_eq(farther.motion, Projectile.Motion.RESTING)
	assert_eq(beyond.motion, Projectile.Motion.RESTING)
	assert_eq(scav.order, Unit.Order.NONE, "and holds where it picked it up")


func test_two_scavengers_dont_go_for_the_same_thing() -> void:
	var world: World = _world()
	var a: Unit = world.spawn_unit(SCAV, DARK, 10 * M, 20 * M, 1, 0)
	var b: Unit = world.spawn_unit(SCAV, DARK, 10 * M, 22 * M, 1, 0)
	var satchel: Projectile = _lay(world, &"satchel", 14 * M, 21 * M)
	_run(world, 4 * World.TICK_RATE)
	assert_eq(satchel.motion, Projectile.Motion.CARRIED)
	assert_ne(a.carried_id == satchel.id, b.carried_id == satchel.id, "exactly one has it")
	assert_ne(a.order, Unit.Order.INTERACT)
	assert_ne(b.order, Unit.Order.INTERACT)


func test_a_scavenger_leaves_what_lies_in_gas_alone() -> void:
	var world: World = _world()
	var scav: Unit = world.spawn_unit(SCAV, DARK, 10 * M, 20 * M, 1, 0)
	var packet: Projectile = _lay(world, &"gas_packet", 16 * M, 20 * M)
	world.spawn_cloud(17 * M, 0, 20 * M, _catalog.find_projectile(&"gas_packet"), 0)
	_run(world, 3 * World.TICK_RATE)
	assert_eq(packet.motion, Projectile.Motion.RESTING)
	assert_eq(scav.order, Unit.Order.NONE)


func test_no_scavenging_across_water_it_cant_cross() -> void:
	var rows: Array[String] = []
	for j: int in 40:
		rows.append(".".repeat(12) + "3".repeat(3) + ".".repeat(25))
	var world: World = World.new(1, TestTerrains.from_ascii(rows), _catalog)
	var scav: Unit = world.spawn_unit(SCAV, DARK, 10 * M, 20 * M, 1, 0)
	var satchel: Projectile = _lay(world, &"satchel", 17 * M, 20 * M)
	_run(world, 3 * World.TICK_RATE)
	assert_eq(satchel.motion, Projectile.Motion.RESTING)
	assert_eq(scav.order, Unit.Order.NONE)


func test_an_attack_mover_picks_up_on_the_way_and_marches_on() -> void:
	var world: World = _world()
	var scav: Unit = world.spawn_unit(SCAV, DARK, 5 * M, 20 * M, 1, 0)
	var satchel: Projectile = _lay(world, &"satchel", 15 * M, 22 * M)
	world.enqueue(AttackMoveCommand.new(0, PackedInt32Array([scav.id]), 35 * M, 20 * M, 0))
	_run(world, 25 * World.TICK_RATE)
	assert_eq(scav.carried_id, satchel.id, "picked up on the way")
	assert_almost_eq(scav.x, 35 * M, 500, "and got where it was going")
	assert_eq(scav.order, Unit.Order.NONE, "the march ended there")


func test_carrying_is_hashed() -> void:
	var a: World = _world()
	var b: World = _world()
	for w: World in [a, b]:
		w.spawn_unit(SCAV, DARK, 10 * M, 20 * M, 1, 0)
		_lay(w, &"satchel", 10 * M, 20 * M)
	assert_eq(a.state_hash(), b.state_hash())
	Interactions.take(a, a.units[0], a.projectiles[0])
	assert_ne(a.state_hash(), b.state_hash())


# --- helpers

func _world() -> World:
	return World.new(1, TestTerrains.flat(40, 40), _catalog)


func _run(world: World, ticks: int) -> void:
	for _t: int in ticks:
		world.step()


func _lay(world: World, id: StringName, x: int, z: int) -> Projectile:
	return world.drop_object(world.catalog.projectile_index_of(id), x, z, 0)
