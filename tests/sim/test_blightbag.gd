extends GutTest
## Blightbags and gas: a Blightbag bursts when it dies, whatever killed it
## (T, a blow, an arrow, fire, a blast), exactly Explosions.CHAIN_DELAY_TICKS
## after the death, and only once. Its blow is bursting on contact. The
## burst leaves a cloud that paralyzes everyone in it, either side, undead
## too, for a while after they leave, until it clears; and two gas packets
## that a later blast sets off. Gas alone sets nothing off.

const M: int = 1000
const LIGHT: UnitType.Faction = UnitType.Faction.LIGHT
const DARK: UnitType.Faction = UnitType.Faction.DARK
const DELAY: int = Explosions.CHAIN_DELAY_TICKS

## Catalog indices of the synthetic types.
const BOMB: int = 0
const DUMMY: int = 1
const BRAWLER: int = 2
const ARCHER: int = 3
const UNDEAD: int = 4
const HEALER: int = 5

var _catalog: UnitCatalog
var _burst: ProjectileType


func before_all() -> void:
	var types: Array[UnitType] = [
		TestUnits.bomb(&"bomb"),
		TestUnits.dummy(&"dummy"),
		TestUnits.melee(&"brawler"),
		TestUnits.ranged(&"archer"),
		TestUnits.undead(&"undead"),
		TestUnits.healer(&"healer"),
	]
	_catalog = TestUnits.catalog(types)
	_burst = _catalog.find_projectile(&"blight_burst")


func test_t_bursts_a_blightbag_four_ticks_later() -> void:
	var world: World = _world()
	var bomb: Unit = world.spawn_unit(BOMB, DARK, 20 * M, 20 * M, 0, 1)
	world.enqueue(UseSpecialCommand.new(0, PackedInt32Array([bomb.id])))
	world.step()
	assert_false(bomb.is_alive())
	assert_eq(bomb.kills, 0)
	var bursts: Array[int] = _burst_ticks(world, 20)
	assert_eq(bursts, [DELAY], "four ticks after the death in tick 0")
	assert_eq(world.clouds.size(), 1, "it left a cloud")


func test_every_kind_of_death_bursts_it_four_ticks_later() -> void:
	for how: String in ["blow", "arrow", "fire", "blast"]:
		var world: World = _world()
		var bomb: Unit = world.spawn_unit(BOMB, DARK, 20 * M, 20 * M, 0, 1)
		bomb.hp = 3
		match how:
			"blow":
				world.spawn_unit(BRAWLER, LIGHT, 20 * M, 19_100, 0, 1)
			"arrow":
				world.spawn_unit(ARCHER, LIGHT, 5 * M, 20 * M, 1, 0)
			"fire":
				world.enqueue(ApplyStatusCommand.new(3, PackedInt32Array([bomb.id]), StatusEffects.Kind.BURNING, 30))
			"blast":
				var satchel: Projectile = world.drop_object(
					world.catalog.projectile_index_of(&"satchel"), 22 * M, 20 * M, 0
				)
				world.explosions.detonate(world, satchel)
		var died: int = -1
		var burst: int = -1
		for _t: int in 5 * World.TICK_RATE:
			var at: int = world.tick
			world.step()
			if died < 0 and not bomb.is_alive():
				died = at
			for e: ProjectileEvent in world.projectile_events:
				if e.kind == ProjectileEvent.Kind.EXPLODE and _is_burst(e):
					burst = at
		assert_gte(died, 0, "%s killed it" % how)
		assert_eq(burst - died, DELAY, "%s: burst %d ticks after death" % [how, burst - died])


func test_a_blightbag_killed_as_its_own_blow_lands_bursts_once() -> void:
	# The brawler's blows land at ticks 5, 20, 35; the bomb's wind-up ends
	# at 20 too. The brawler (lower id) kills it first in that strike pass,
	# and the dead bomb's own blow is wasted.
	var world: World = _world()
	world.spawn_unit(BRAWLER, LIGHT, 20 * M, 19_150, 0, 1)
	var bomb: Unit = world.spawn_unit(BOMB, DARK, 20 * M, 20 * M, 0, -1)
	bomb.hp = 15
	var bursts: Array[int] = _burst_ticks(world, 60)
	assert_false(bomb.is_alive())
	assert_eq(bursts.size(), 1, "one burst: %s" % [bursts])


func test_its_blow_is_bursting_on_contact() -> void:
	var world: World = _world()
	var bomb: Unit = world.spawn_unit(BOMB, DARK, 14 * M, 20 * M, 1, 0)
	var enemy: Unit = world.spawn_unit(DUMMY, LIGHT, 20 * M, 20 * M, -1, 0)
	world.enqueue(AttackMoveCommand.new(0, PackedInt32Array([bomb.id]), 30 * M, 20 * M, 0))
	var bursts: Array[int] = _burst_ticks(world, 15 * World.TICK_RATE)
	assert_eq(bursts.size(), 1)
	assert_false(bomb.is_alive(), "it walked up and burst")
	assert_lt(enemy.hp, enemy.type.max_hp, "hurt by the blast")
	assert_eq(bomb.kills, 0)


func test_the_cloud_paralyzes_everyone_in_it_then_clears() -> void:
	var world: World = _world()
	var bomb: Unit = world.spawn_unit(BOMB, DARK, 20 * M, 20 * M, 0, 1)
	var friend: Unit = world.spawn_unit(DUMMY, LIGHT, 17 * M, 20 * M, 1, 0)
	var undead: Unit = world.spawn_unit(UNDEAD, DARK, 23 * M, 20 * M, -1, 0)
	var outside: Unit = world.spawn_unit(DUMMY, LIGHT, 20 * M, 28 * M, 0, -1)
	world.enqueue(UseSpecialCommand.new(0, PackedInt32Array([bomb.id])))
	_run(world, DELAY + 1)
	assert_eq(world.clouds.size(), 1)
	assert_false(StatusEffects.paralyzed(world, friend), "the cloud acts from the tick after the burst")
	world.step()
	assert_true(StatusEffects.paralyzed(world, friend), "either side")
	assert_true(StatusEffects.paralyzed(world, undead), "undead too")
	assert_false(StatusEffects.paralyzed(world, outside), "8 m off, clear of it")
	# It acts for gas_ticks ticks, from DELAY + 1, then is gone.
	_run(world, _burst.gas_ticks - 1)
	assert_true(world.clouds.is_empty(), "cleared")
	assert_true(StatusEffects.paralyzed(world, friend), "but the paralysis lasts a while longer")
	_run(world, _burst.gas_paralysis_ticks)
	assert_false(StatusEffects.paralyzed(world, friend))
	assert_false(StatusEffects.paralyzed(world, undead))


func test_a_burst_leaves_two_gas_packets_that_a_blast_sets_off() -> void:
	var world: World = _world()
	var bomb: Unit = world.spawn_unit(BOMB, DARK, 20 * M, 20 * M, 0, 1)
	world.enqueue(UseSpecialCommand.new(0, PackedInt32Array([bomb.id])))
	_run(world, DELAY + 1)
	var packets: Array[Projectile] = _packets(world)
	assert_eq(packets.size(), 2)
	for p: Projectile in packets:
		assert_eq(p.motion, Projectile.Motion.RESTING)
		assert_false(p.detonating, "its own burst doesn't set them off")
		assert_almost_eq(FixedMath.length(p.x - 20 * M, p.z - 20 * M), _burst.scatter_radius, 50)
	var satchel: Projectile = world.drop_object(
		world.catalog.projectile_index_of(&"satchel"), packets[0].x, packets[0].z + 1000, 0
	)
	world.explosions.detonate(world, satchel)
	_run(world, DELAY + 2)
	assert_true(packets[0].removed or not world.projectiles.has(packets[0]), "caught and burst")
	assert_eq(world.clouds.size(), 2, "a second cloud")


func test_gas_alone_sets_nothing_off() -> void:
	var world: World = _world()
	var packet: Projectile = world.drop_object(world.catalog.projectile_index_of(&"gas_packet"), 20 * M, 20 * M, 0)
	var satchel: Projectile = world.drop_object(world.catalog.projectile_index_of(&"satchel"), 21 * M, 20 * M, 0)
	world.explosions.detonate(world, packet)
	_run(world, 10)
	assert_eq(world.clouds.size(), 1)
	assert_false(satchel.detonating)


func test_healing_a_blightbag_kills_it_and_it_bursts_on_the_healer() -> void:
	var world: World = _world()
	var healer: Unit = world.spawn_unit(HEALER, LIGHT, 10 * M, 20 * M, 1, 0)
	var bomb: Unit = world.spawn_unit(BOMB, DARK, 11 * M, 20 * M, -1, 0)
	world.enqueue(HealCommand.new(0, PackedInt32Array([healer.id]), bomb.id))
	var bursts: Array[int] = _burst_ticks(world, 30)
	assert_false(bomb.is_alive())
	assert_eq(healer.kills, 1, "the herb killed it")
	assert_eq(bursts.size(), 1)
	assert_lt(healer.hp, healer.type.max_hp, "and it burst on the healer")
	assert_true(StatusEffects.paralyzed(world, healer))


func test_clouds_are_hashed() -> void:
	var a: World = _world()
	var b: World = _world()
	assert_eq(a.state_hash(), b.state_hash())
	a.spawn_cloud(5 * M, 0, 5 * M, _burst, 0)
	assert_ne(a.state_hash(), b.state_hash())


# --- helpers

func _world() -> World:
	return World.new(1, TestTerrains.flat(40, 40), _catalog)


func _run(world: World, ticks: int) -> void:
	for _t: int in ticks:
		world.step()


func _is_burst(e: ProjectileEvent) -> bool:
	return e.type_index == _catalog.projectile_index_of(&"blight_burst")


# Ticks on which a blight burst went off in the next ticks.
func _burst_ticks(world: World, ticks: int) -> Array[int]:
	var out: Array[int] = []
	for _t: int in ticks:
		var at: int = world.tick
		world.step()
		for e: ProjectileEvent in world.projectile_events:
			if e.kind == ProjectileEvent.Kind.EXPLODE and _is_burst(e):
				out.append(at)
	return out


func _packets(world: World) -> Array[Projectile]:
	var out: Array[Projectile] = []
	for p: Projectile in world.projectiles:
		if not p.removed and p.type.id == &"gas_packet":
			out.append(p)
	return out
