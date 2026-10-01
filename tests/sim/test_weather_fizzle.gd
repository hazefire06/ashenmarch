extends GutTest
## Burning projectiles in bad weather and in water. A lit fuse or a fire
## arrow fizzles more in rain and snow, and a fuse more on snow-covered
## ground; the chances combine as independent ones. Water puts out a fuse the
## moment the grenade touches it, with no dice. In clear weather a fire arrow
## draws nothing a plain arrow doesn't, so the Phase 4 RNG streams are
## unchanged.

const M: int = 1000
const LIGHT: UnitType.Faction = UnitType.Faction.LIGHT
const DARK: UnitType.Faction = UnitType.Faction.DARK
const FULL: int = 1000


func test_the_chances_combine_as_independent_ones() -> void:
	var t: ProjectileType = TestUnits.projectile(&"grenade", {
		"fizzle_permille": 100, "rain_fizzle_permille": 500,
		"snow_fizzle_permille": 200, "snow_cover_fizzle_permille": 300,
	})
	var world: World = _world(TestTerrains.flat(20, 20), [t])
	var p: Projectile = _place(world, &"grenade", 10 * M, 10 * M)
	assert_eq(ProjectileSystem.fizzle_permille(world, p, true), 100, "clear: the type's own chance")
	_weather(world, FULL, 0, 0)
	assert_eq(ProjectileSystem.fizzle_permille(world, p, true), 550, "1 - 0.9 * 0.5")
	_weather(world, 500, 0, 0)
	assert_eq(ProjectileSystem.fizzle_permille(world, p, true), 325, "half the rain, half its chance: 1 - 0.9 * 0.75")
	_weather(world, 0, FULL, FULL)
	assert_eq(ProjectileSystem.fizzle_permille(world, p, true), 496, "snow and cover: 1 - 0.9 * 0.8 * 0.7")
	assert_eq(ProjectileSystem.fizzle_permille(world, p, false), 280, "in the air the cover doesn't count")


func test_something_that_doesnt_burn_never_fizzles() -> void:
	var world: World = _world(TestTerrains.flat(20, 20))
	var satchel: Projectile = _place(world, &"satchel", 10 * M, 10 * M)
	satchel.type.rain_fizzle_permille = 500
	_weather(world, FULL, FULL, FULL)
	assert_eq(ProjectileSystem.fizzle_permille(world, satchel, true), 0)


func test_100_grenades_in_heavy_rain_fizzle_at_the_configured_rate() -> void:
	# The shipped grenade, 10 m apart: beyond its blast and knock radii, so
	# none sets off or throws another.
	for world_seed: int in [1, 2, 3]:
		var world: World = World.new(world_seed, TestTerrains.flat(110, 110), TestUnits.catalog([TestUnits.dummy(&"dummy")]))
		world.enqueue(SetWeatherCommand.new(0, FULL, 0, 0, 0, 0))
		var grenades: Array[Projectile] = []
		for k: int in 100:
			var p: Projectile = _place(world, &"grenade", (10 + k % 10 * 10) * M, (10 + k / 10 * 10) * M)
			p.fuse_left = 3
			grenades.append(p)
		world.step()
		var expected: int = ProjectileSystem.fizzle_permille(world, grenades[0], true)
		var fizzled: int = 0
		var burst: int = 0
		for _t: int in 3:
			world.step()
			fizzled += _count(world, ProjectileEvent.Kind.FIZZLE)
			burst += _count(world, ProjectileEvent.Kind.EXPLODE)
		gut.p("seed %d: %d of 100 fizzled in heavy rain (configured %d permille)" % [world_seed, fizzled, expected])
		assert_gt(expected, grenades[0].type.fizzle_permille, "rain raises the chance")
		assert_eq(fizzled + burst, 100, "seed %d: every fuse ended" % world_seed)
		# 3 sigma of a binomial(100, 0.43) is about 15.
		assert_almost_eq(fizzled, expected / 10, 15, "seed %d" % world_seed)
		var duds: int = 0
		for p: Projectile in world.projectiles:
			duds += 1 if p.dud else 0
		assert_eq(duds, fizzled, "the fizzled ones stay, unexploded")


func test_snow_cover_counts_only_for_a_grenade_on_the_ground() -> void:
	var t: ProjectileType = TestUnits.projectile(&"grenade", {
		"fizzle_permille": 0, "snow_cover_fizzle_permille": FULL, "chain_detonates": false,
	})
	var world: World = _world(TestTerrains.flat(40, 40), [t])
	world.enqueue(SetWeatherCommand.new(0, 0, 0, 0, 0, 0, FULL))
	var lying: Projectile = _place(world, &"grenade", 10 * M, 10 * M)
	lying.fuse_left = 2
	var flying: Projectile = _launch(world, &"grenade", 30 * M, 20 * M, 30 * M, 0, 0, 0)
	flying.fuse_left = 2
	_run(world, 2)
	assert_true(lying.dud, "lying in the snow: certain to go out")
	assert_false(flying.dud, "in the air: the snow on the ground doesn't reach it")
	assert_true(flying.removed, "it burst")


func test_a_grenade_landing_in_water_goes_out_at_once_without_dice() -> void:
	var world: World = _world(_pond())
	var p: Projectile = _launch(world, &"grenade", 20 * M, 2 * M, 20 * M, 0, 0, 0)
	p.fuse_left = 60
	var state: int = world.rng.state
	var fizzle: ProjectileEvent = null
	var landed_at: int = -1
	for t: int in 40:
		world.step()
		if landed_at < 0 and _count(world, ProjectileEvent.Kind.BOUNCE) > 0:
			landed_at = t
		for e: ProjectileEvent in world.projectile_events:
			if e.kind == ProjectileEvent.Kind.FIZZLE and fizzle == null:
				fizzle = e
				assert_eq(t, landed_at, "the tick it touched the water")
	assert_not_null(fizzle)
	assert_true(p.dud)
	assert_eq(p.fuse_left, 0)
	assert_eq(world.rng.state, state, "no dice: water always puts it out")
	_run(world, 60)
	assert_false(p.removed, "it never goes off, and lies there unexploded")


func test_a_grenade_rolling_into_water_goes_out() -> void:
	var world: World = _world(_pond())
	var p: Projectile = _place(world, &"grenade", 10 * M, 20 * M)
	# Rolling resistance stops it about 12 m on, well past the shore at 15 m.
	p.flight.vx = FlightState.speed_from_mm_per_s(5000)
	p.fuse_left = 300
	var doused_x: int = -1
	for _t: int in 120:
		world.step()
		if _count(world, ProjectileEvent.Kind.FIZZLE) > 0:
			doused_x = p.x
	assert_true(p.dud)
	assert_gt(world.terrain.water_depth_at(doused_x, p.z), 0, "it went out where the water starts")
	assert_eq(world.terrain.water_depth_at(doused_x - 1000, p.z), 0)


func test_a_grenade_on_dry_ground_beside_water_still_bursts() -> void:
	var world: World = _world(_pond())
	var p: Projectile = _place(world, &"grenade", 10 * M, 20 * M)
	p.type.fizzle_permille = 0
	p.fuse_left = 10
	_run(world, 10)
	assert_true(p.removed)
	assert_false(p.dud)


func test_a_fire_arrow_in_clear_weather_draws_nothing_a_plain_arrow_doesnt() -> void:
	# On sand, so no fire starts and spreads (which draws its own dice).
	var fire: World = _world(_sand())
	var plain: World = _world(_sand())
	_launch(fire, &"fire_arrow", 10 * M, 2 * M, 20 * M, 20_000, 0, 0)
	_launch(plain, &"arrow", 10 * M, 2 * M, 20 * M, 20_000, 0, 0)
	_run(fire, 30)
	_run(plain, 30)
	assert_eq(fire.rng.state, plain.rng.state)
	var rainy: World = _world(_sand())
	rainy.enqueue(SetWeatherCommand.new(0, FULL, 0, 0, 0, 0))
	_launch(rainy, &"fire_arrow", 10 * M, 2 * M, 20 * M, 20_000, 0, 0)
	_run(rainy, 30)
	assert_ne(rainy.rng.state, plain.rng.state, "in rain it rolls once for its flame")


func test_a_fire_arrow_put_out_by_rain_lights_nothing_but_still_wounds() -> void:
	var t: ProjectileType = TestUnits.projectile(&"fire_arrow", {"rain_fizzle_permille": FULL})
	var world: World = _world(TestTerrains.flat(40, 40), [t, TestUnits.projectile(&"arrow")])
	world.enqueue(SetWeatherCommand.new(0, FULL, 0, 0, 0, 0))
	var dummy: Unit = world.spawn_unit(0, DARK, 15 * M, 20 * M, -1, 0)
	var p: Projectile = _launch(world, &"fire_arrow", 10 * M, 1500, 20 * M, 1_000_000, 0, 0)
	var events: Array[ProjectileEvent.Kind] = []
	for _t: int in 30:
		world.step()
		for e: ProjectileEvent in world.projectile_events:
			events.append(e.kind)
	assert_true(p.removed)
	assert_lt(dummy.hp, dummy.type.max_hp, "the arrow still hurts")
	assert_has(events, ProjectileEvent.Kind.FIZZLE)
	assert_does_not_have(events, ProjectileEvent.Kind.IGNITE, "its flame went out")


func test_a_fire_arrow_in_clear_weather_still_lights_a_fire() -> void:
	var world: World = _world(TestTerrains.flat(40, 40))
	_launch(world, &"fire_arrow", 10 * M, 2 * M, 20 * M, 20_000, 0, 0)
	var marked: int = 0
	for _t: int in 30:
		world.step()
		marked += _count(world, ProjectileEvent.Kind.IGNITE)
	assert_eq(marked, 1)


func test_weather_fizzle_chances_are_validated() -> void:
	var grenade: ProjectileType = TestUnits.projectile(&"grenade")
	grenade.snow_cover_fizzle_permille = 1001
	assert_eq(grenade.validate().size(), 1, str(grenade.validate()))
	grenade.snow_cover_fizzle_permille = 1000
	assert_eq(grenade.validate(), PackedStringArray())
	# A grenade with its fuse taken out (a test's inert ball) keeps its
	# numbers; they just never apply.
	var inert: ProjectileType = TestUnits.projectile(&"grenade", {"fuse_ticks": 0})
	assert_eq(inert.validate(), PackedStringArray())
	assert_false(inert.burns())


func test_what_burns() -> void:
	assert_true(TestUnits.projectile(&"fire_arrow").burns())
	assert_true(TestUnits.projectile(&"grenade").burns())
	assert_false(TestUnits.projectile(&"satchel").burns())
	assert_false(TestUnits.projectile(&"arrow").burns())


func test_a_thrower_wont_pick_an_enemy_standing_in_water() -> void:
	var wet: World = _thrower_world(20 * M)
	_run(wet, 90)
	assert_eq(_launches, 0, "the fuse would go out where it lands")
	var dry: World = _thrower_world(12 * M)
	_run(dry, 90)
	assert_gt(_launches, 0, "the same enemy on the dry bank draws fire")


func test_a_ground_attack_into_water_still_throws() -> void:
	var world: World = _thrower_world(20 * M)
	world.enqueue(GroundAttackCommand.new(0, PackedInt32Array([1]), 20 * M, 20 * M))
	_run(world, 90)
	assert_gt(_launches, 0, "the player chose the spot")


func test_the_shipped_burning_projectiles_fear_the_weather() -> void:
	for id: StringName in [&"grenade", &"fire_arrow"]:
		var t: ProjectileType = TestUnits.projectile(id)
		assert_gt(t.rain_fizzle_permille, 0, id)
		assert_gt(t.snow_fizzle_permille, 0, id)
		assert_gt(t.snow_cover_fizzle_permille, 0, id)


# --- helpers

var _launches: int = 0


# A thrower holding at (2, 20) m by the pond, facing an enemy dummy at
# (enemy_x, 20). Counts launches into _launches as it steps.
func _thrower_world(enemy_x: int) -> World:
	var world: World = World.new(1, _pond(), TestUnits.catalog([
		TestUnits.thrower(&"thrower"), TestUnits.dummy(&"dummy"),
	]))
	world.spawn_unit(0, LIGHT, 2 * M, 20 * M, 1, 0)
	world.spawn_unit(1, DARK, enemy_x, 20 * M, -1, 0)
	_launches = 0
	return world


func _world(terrain: Terrain, projectiles: Array[ProjectileType] = []) -> World:
	return World.new(1, terrain, TestUnits.catalog([TestUnits.dummy(&"dummy")], projectiles))


# Flat 40 x 40 m: dry west of x = 15 m, depth-1 water east of it.
func _pond() -> Terrain:
	var rows: Array[String] = []
	for j: int in 40:
		rows.append(".".repeat(15) + "1".repeat(25))
	return TestTerrains.from_ascii(rows)


# Flat 40 x 40 m of sand: nothing burns.
func _sand() -> Terrain:
	var rows: Array[String] = []
	for j: int in 40:
		rows.append("s".repeat(40))
	return TestTerrains.from_ascii(rows)


# Sets the weather outright, without a command, for the pure chance tests.
func _weather(world: World, rain: int, snow: int, cover: int) -> void:
	world.weather.rain = rain
	world.weather.snow = snow
	world.weather.snow_cover_ppm = cover * 1000


func _run(world: World, ticks: int) -> void:
	for _t: int in ticks:
		world.step()
		_launches += _count(world, ProjectileEvent.Kind.LAUNCH)


func _count(world: World, kind: ProjectileEvent.Kind) -> int:
	var n: int = 0
	for e: ProjectileEvent in world.projectile_events:
		if e.kind == kind:
			n += 1
	return n


# A projectile of this id flying from (x, y, z) mm at (vx, vy, vz) um/tick.
func _launch(world: World, id: StringName, x: int, y: int, z: int, vx: int, vy: int, vz: int) -> Projectile:
	var index: int = world.catalog.projectile_index_of(id)
	return world.spawn_projectile(index, FlightState.at_mm(x, y, z, vx, vy, vz), 0)


# A projectile of this id lying on the ground at (x, z), rolling from rest.
func _place(world: World, id: StringName, x: int, z: int) -> Projectile:
	var index: int = world.catalog.projectile_index_of(id)
	var radius: int = world.catalog.projectile_types[index].radius
	var p: Projectile = world.spawn_projectile(
		index, FlightState.at_mm(x, world.terrain.height_at(x, z) + radius, z, 0, 0, 0), 0
	)
	p.motion = Projectile.Motion.ROLLING
	return p
