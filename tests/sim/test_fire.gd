extends GutTest
## Fire: a cell (terrain sample) of grass, brush, or wood that a fire arrow
## lights burns for its ground's time (to the end of tick lit + BURN_TICKS),
## may spread to each unburnt flammable neighbor every tick, then lies
## scorched for good. Sand, rock, and water
## never burn. Rain puts burning cells out and, with wet or snowy ground,
## slows the spread. Fire hurts whoever stands in it, credited to whoever lit
## it, and sets off charges and duds. Spread is seeded, so the same seed
## burns the same ground.

const M: int = 1000
const LIGHT: UnitType.Faction = UnitType.Faction.LIGHT
const DARK: UnitType.Faction = UnitType.Faction.DARK
const FULL: int = 1000
const GRASS_TICKS: int = Fire.BURN_TICKS[Terrain.Ground.GRASS]


func test_a_lone_grass_cell_burns_for_its_time_then_is_scorched() -> void:
	var world: World = _world(_ringed("."))
	assert_true(world.ignite(5 * M, 5 * M, 0))
	assert_eq(world.fire.cell_at(5 * M, 5 * M), Fire.Cell.BURNING)
	_run(world, GRASS_TICKS)
	assert_eq(world.fire.cell_at(5 * M, 5 * M), Fire.Cell.BURNING, "lit in tick 0, burning through tick BURN_TICKS")
	_run(world, 1)
	assert_eq(world.fire.cell_at(5 * M, 5 * M), Fire.Cell.SCORCHED)
	assert_false(world.fire.is_burning())
	assert_eq(world.fire.cell_at(4 * M, 5 * M), Fire.Cell.UNBURNT, "the sand around it never caught")


func test_brush_and_wood_burn_longer_than_grass() -> void:
	assert_gt(Fire.BURN_TICKS[Terrain.Ground.BRUSH], GRASS_TICKS)
	assert_gt(Fire.BURN_TICKS[Terrain.Ground.WOOD], Fire.BURN_TICKS[Terrain.Ground.BRUSH])
	var world: World = _world(_ringed("w"))
	world.ignite(5 * M, 5 * M, 0)
	_run(world, Fire.BURN_TICKS[Terrain.Ground.WOOD])
	assert_eq(world.fire.cell_at(5 * M, 5 * M), Fire.Cell.BURNING)
	_run(world, 1)
	assert_eq(world.fire.cell_at(5 * M, 5 * M), Fire.Cell.SCORCHED)


func test_only_grass_brush_and_wood_catch() -> void:
	var world: World = _world(TestTerrains.from_ascii([".bwsr1#", "sssssss"] as Array[String]))
	var lit: Array[bool] = []
	for i: int in 7:
		lit.append(world.ignite(i * M, 0, 0))
	assert_eq(lit, [true, true, true, false, false, false, true], "a blocked sample is still its ground")


func test_a_burning_or_scorched_cell_cant_be_lit_again() -> void:
	var world: World = _world(_ringed("."))
	assert_true(world.ignite(5 * M, 5 * M, 0))
	assert_false(world.ignite(5 * M, 5 * M, 0), "already burning")
	_run(world, GRASS_TICKS + 1)
	assert_false(world.ignite(5 * M, 5 * M, 0), "nothing left to burn")


func test_fire_spreads_through_grass() -> void:
	var world: World = _world(TestTerrains.flat(30, 30))
	world.ignite(15 * M, 15 * M, 0)
	_run(world, 30 * World.TICK_RATE)
	var burnt: int = _count_cells(world, Fire.Cell.SCORCHED) + world.fire.burn_end.size()
	gut.p("%d cells burnt or burning after 30 s" % burnt)
	assert_gt(burnt, 300, "a grass fire runs")


func test_fire_never_crosses_sand_rock_or_water() -> void:
	for strip: String in ["s", "r", "1"]:
		var rows: Array[String] = []
		for j: int in 20:
			rows.append(".".repeat(9) + strip + ".".repeat(10))
		var world: World = _world(TestTerrains.from_ascii(rows))
		world.ignite(2 * M, 10 * M, 0)
		_run_until_out(world, 120 * World.TICK_RATE)
		var left: int = 0
		for j: int in 20:
			for i: int in 20:
				var cell: int = world.fire.cell_at(i * M, j * M)
				if i > 9:
					assert_eq(cell, Fire.Cell.UNBURNT, "'%s' strip: (%d, %d) is past the break" % [strip, i, j])
				elif i < 9 and cell == Fire.Cell.SCORCHED:
					left += 1
		assert_gt(left, 9 * 20 * 8 / 10, "'%s' strip: the near side burned" % strip)


func test_spread_is_deterministic_per_seed() -> void:
	var a: World = _world(_mixed(), 7)
	var b: World = _world(_mixed(), 7)
	var c: World = _world(_mixed(), 8)
	for w: World in [a, b, c]:
		w.ignite(20 * M, 20 * M, 0)
	var mismatches: Array[int] = []
	for t: int in 40 * World.TICK_RATE:
		a.step()
		b.step()
		c.step()
		if (t + 1) % 30 == 0 and a.state_hash() != b.state_hash():
			mismatches.append(t + 1)
	assert_eq(mismatches.size(), 0, "hashes differ at ticks %s" % [mismatches])
	assert_eq(a.fire.state, b.fire.state, "the same ground burned")
	assert_ne(a.fire.state, c.fire.state, "another seed burns differently")


func test_spreading_only_from_the_front_changes_nothing() -> void:
	# The optimization's claim: which cells are in the front changes how much
	# work a tick does, never what happens. A world whose front is every
	# burning cell, before every tick (brute force), must stay hash-identical
	# to the real one, through rain (douses) and snow cover.
	var rows: Array[String] = []
	for j: int in 40:
		rows.append(_mixed_row(j) if j % 9 != 4 else "1".repeat(40))
	for world_seed: int in [1, 2]:
		var real: World = _world(TestTerrains.from_ascii(rows), world_seed)
		var brute: World = _world(TestTerrains.from_ascii(rows), world_seed)
		for w: World in [real, brute]:
			w.ignite(20 * M, 20 * M, 0)
			w.ignite(5 * M, 30 * M, 0)
			w.enqueue(SetWeatherCommand.new(400, 300, 0, 0, 0, 30))
			w.enqueue(SetWeatherCommand.new(700, 0, 500, 0, 0, 30))
		var mismatches: Array[int] = []
		for t: int in 1000:
			# Reaching into the private front is the point of this test.
			for k: int in brute.fire.burn_end.keys():
				brute.fire._front[k] = true
			real.step()
			brute.step()
			if real.state_hash() != brute.state_hash():
				mismatches.append(t)
				break
		assert_eq(mismatches, [] as Array[int], "seed %d" % world_seed)
		assert_gt(real.fire.state.count(Fire.Cell.SCORCHED), 40, "seed %d: it burned for real" % world_seed)


func test_heavy_rain_puts_a_fire_out_sooner() -> void:
	var clear: World = _world(_brush(40), 3)
	var rainy: World = _world(_brush(40), 3)
	rainy.enqueue(SetWeatherCommand.new(0, FULL, 0, 0, 0, 0))
	clear.ignite(20 * M, 20 * M, 0)
	rainy.ignite(20 * M, 20 * M, 0)
	var clear_ticks: int = _run_until_out(clear, 300 * World.TICK_RATE)
	var rainy_ticks: int = _run_until_out(rainy, 300 * World.TICK_RATE)
	var clear_burnt: int = _count_cells(clear, Fire.Cell.SCORCHED)
	var rainy_burnt: int = _count_cells(rainy, Fire.Cell.SCORCHED)
	gut.p("brush fire: clear %d cells in %d ticks, heavy rain %d cells in %d ticks" % [
		clear_burnt, clear_ticks, rainy_burnt, rainy_ticks,
	])
	assert_lt(rainy_ticks, clear_ticks / 4)
	assert_lt(rainy_burnt, clear_burnt / 10)


func test_soaked_ground_slows_the_spread_with_no_rain_falling() -> void:
	var dry: World = _world(TestTerrains.flat(40, 40), 4)
	var wet: World = _world(TestTerrains.flat(40, 40), 4)
	wet.weather.wetness_ppm = Weather.PPM
	dry.ignite(20 * M, 20 * M, 0)
	wet.ignite(20 * M, 20 * M, 0)
	_run(dry, 20 * World.TICK_RATE)
	_run(wet, 20 * World.TICK_RATE)
	var dry_burnt: int = _count_cells(dry, Fire.Cell.SCORCHED) + dry.fire.burn_end.size()
	var wet_burnt: int = _count_cells(wet, Fire.Cell.SCORCHED) + wet.fire.burn_end.size()
	gut.p("after 20 s: dry ground %d cells, soaked ground %d" % [dry_burnt, wet_burnt])
	assert_gt(wet.weather.wetness(), 800, "still wet: it dries slowly")
	assert_lt(wet_burnt, dry_burnt / 2)


func test_snow_cover_slows_the_spread() -> void:
	assert_eq(Fire.spread_damping_permille(0, 0, 0), FULL)
	assert_eq(Fire.spread_damping_permille(FULL, 0, 0), FULL - Fire.RAIN_SPREAD_CUT)
	assert_eq(Fire.spread_damping_permille(0, 0, FULL), FULL - Fire.SNOW_SPREAD_CUT)
	assert_lt(Fire.spread_damping_permille(0, 500, 500), Fire.spread_damping_permille(0, 500, 0))


func test_a_unit_standing_in_fire_is_hurt_every_10_ticks() -> void:
	var world: World = _world(_ringed("."))
	var unit: Unit = world.spawn_unit(0, DARK, 5 * M, 5 * M, 0, 1)
	var by_sand: Unit = world.spawn_unit(0, DARK, 5 * M, 7 * M, 0, 1)
	world.ignite(5 * M, 5 * M, 0)
	var hits: Array[int] = []
	for t: int in 30:
		world.step()
		for e: CombatEvent in world.combat_events:
			if e.target_id == unit.id and e.kind == CombatEvent.Kind.HIT:
				hits.append(t)
				assert_eq(e.damage, Fire.DAMAGE)
	assert_eq(hits, [0, 10, 20])
	assert_eq(unit.hp, unit.type.max_hp - 3 * Fire.DAMAGE)
	assert_eq(by_sand.hp, by_sand.type.max_hp, "standing on sand two cells off, untouched")


func test_a_cell_hurts_through_its_last_tick() -> void:
	# Lit during tick 0, it burns until the end of tick GRASS_TICKS, a
	# multiple of the damage interval: that tick hurts too.
	assert_eq(GRASS_TICKS % Fire.DAMAGE_INTERVAL_TICKS, 0, "precondition")
	var world: World = _world(_ringed("."))
	var unit: Unit = world.spawn_unit(0, DARK, 5 * M, 5 * M, 0, 1)
	world.ignite(5 * M, 5 * M, 0)
	var last_hit: int = -1
	var hits: int = 0
	for t: int in GRASS_TICKS + 30:
		world.step()
		for e: CombatEvent in world.combat_events:
			if e.target_id == unit.id and e.kind == CombatEvent.Kind.HIT:
				last_hit = t
				hits += 1
	assert_eq(last_hit, GRASS_TICKS)
	assert_eq(hits, GRASS_TICKS / Fire.DAMAGE_INTERVAL_TICKS + 1)


func test_a_cell_sets_off_a_charge_in_its_last_tick() -> void:
	var world: World = _world(_ringed("."))
	world.ignite(5 * M, 5 * M, 0)
	_run(world, GRASS_TICKS)
	assert_eq(world.fire.cell_at(5 * M, 5 * M), Fire.Cell.BURNING)
	var satchel: Projectile = _lay(world, &"satchel", 5 * M, 5 * M)
	world.step()
	assert_true(satchel.detonating, "caught during tick GRASS_TICKS, before it burned out")
	assert_eq(world.fire.cell_at(5 * M, 5 * M), Fire.Cell.SCORCHED)


func test_a_live_grenade_lying_in_fire_goes_off_early() -> void:
	var world: World = _world(TestTerrains.flat(30, 30))
	var grenade: Projectile = _lay(world, &"grenade", 10 * M, 10 * M)
	grenade.fuse_left = 90
	world.ignite(10 * M, 10 * M, 0)
	var burst_at: int = -1
	for t: int in 30:
		world.step()
		for e: ProjectileEvent in world.projectile_events:
			if e.kind == ProjectileEvent.Kind.EXPLODE and e.projectile_id == grenade.id:
				burst_at = t
	assert_eq(burst_at, Explosions.CHAIN_DELAY_TICKS, "caught in tick 0, the chain delay later, long before its fuse")


func test_charges_a_burning_sapper_drops_are_caught_at_once() -> void:
	var sapper_type: UnitType = TestUnits.thrower(&"sapper", {"max_hp": Fire.DAMAGE, "special_charges": 4})
	var world: World = _world(_ringed("."), 1, [sapper_type])
	var sapper: Unit = world.spawn_unit(0, LIGHT, 5 * M, 5 * M, 0, 1)
	world.ignite(5 * M, 5 * M, 0)
	world.step()
	assert_false(sapper.is_alive())
	var charges: int = 0
	for p: Projectile in world.projectiles:
		if p.owner_id == sapper.id:
			charges += 1
			assert_true(p.detonating, "dropped into the fire it died in")
	assert_eq(charges, 4)


func test_a_fire_kill_is_credited_to_whoever_lit_it() -> void:
	var world: World = _world(_ringed("."), 1, [TestUnits.dummy(&"dummy", {"max_hp": Fire.DAMAGE})])
	var archer: Unit = world.spawn_unit(0, LIGHT, 1 * M, 1 * M, 0, 1)
	var enemy: Unit = world.spawn_unit(0, DARK, 5 * M, 5 * M, 0, 1)
	world.ignite(5 * M, 5 * M, archer.id)
	world.step()
	assert_false(enemy.is_alive())
	assert_eq(archer.kills, 1)


func test_fire_sets_off_a_charge_and_a_dud_lying_in_it() -> void:
	var world: World = _world(TestTerrains.flat(30, 30), 1, [TestUnits.dummy(&"dummy")])
	var lighter: Unit = world.spawn_unit(0, LIGHT, 1 * M, 1 * M, 0, 1)
	var satchel: Projectile = _lay(world, &"satchel", 10 * M, 10 * M)
	var dud: Projectile = _lay(world, &"grenade", 20 * M, 20 * M)
	dud.dud = true
	world.ignite(10 * M, 10 * M, lighter.id)
	world.ignite(20 * M, 20 * M, lighter.id)
	var bursts: Array[int] = []
	for _t: int in Explosions.CHAIN_DELAY_TICKS + 1:
		world.step()
		for e: ProjectileEvent in world.projectile_events:
			if e.kind == ProjectileEvent.Kind.EXPLODE:
				bursts.append(e.projectile_id)
	assert_has(bursts, satchel.id)
	assert_has(bursts, dud.id)
	assert_eq(satchel.instigator_id, lighter.id, "credited to whoever lit the fire")


func test_something_flying_over_fire_isnt_set_off() -> void:
	var world: World = _world(TestTerrains.flat(30, 30))
	var index: int = world.catalog.projectile_index_of(&"satchel")
	var p: Projectile = world.spawn_projectile(index, FlightState.at_mm(10 * M, 20 * M, 10 * M, 0, 0, 0), 0)
	world.ignite(10 * M, 10 * M, 0)
	world.step()
	assert_false(p.detonating)


func test_a_fire_arrow_lights_the_ground_where_it_lands() -> void:
	var world: World = _world(TestTerrains.flat(40, 40))
	var p: Projectile = _launch(world, &"fire_arrow", 10 * M, 2 * M, 20 * M, 20_000, 0, 0)
	p.instigator_id = 99
	var ignited: ProjectileEvent = null
	for _t: int in 30:
		world.step()
		for e: ProjectileEvent in world.projectile_events:
			if e.kind == ProjectileEvent.Kind.IGNITE:
				ignited = e
	assert_not_null(ignited)
	assert_eq(world.fire.cell_at(ignited.x, ignited.z) != Fire.Cell.UNBURNT, true)
	assert_eq(ignited.unit_id, 99, "lit by the archer")
	assert_eq(world.fire.lit_by.values().count(99), world.fire.burn_end.size(), "the spread is credited to them too")


func test_a_fire_arrow_landing_in_water_lights_nothing() -> void:
	var rows: Array[String] = []
	for j: int in 40:
		rows.append("1".repeat(40))
	var world: World = _world(TestTerrains.from_ascii(rows))
	_launch(world, &"fire_arrow", 10 * M, 2 * M, 20 * M, 20_000, 0, 0)
	for _t: int in 30:
		world.step()
		for e: ProjectileEvent in world.projectile_events:
			assert_ne(e.kind, ProjectileEvent.Kind.IGNITE)
	assert_true(not world.fire.is_burning())


func test_a_world_without_fire_carries_no_fire_grid() -> void:
	var world: World = _world(TestTerrains.flat(30, 30))
	_run(world, 10)
	assert_true(world.fire.state.is_empty(), "allocated on the first fire")


func test_fire_is_part_of_the_state_hash() -> void:
	var a: World = _world(TestTerrains.flat(30, 30))
	var b: World = _world(TestTerrains.flat(30, 30))
	var c: World = _world(TestTerrains.flat(30, 30))
	a.ignite(10 * M, 10 * M, 0)
	b.ignite(10 * M, 10 * M, 0)
	c.ignite(11 * M, 10 * M, 0)
	_run(a, 60)
	_run(b, 60)
	_run(c, 60)
	assert_eq(a.state_hash(), b.state_hash())
	assert_ne(a.state_hash(), c.state_hash())


func test_changed_lists_the_cells_that_changed_this_tick() -> void:
	var world: World = _world(_ringed("."))
	world.ignite(5 * M, 5 * M, 0)
	world.step()
	assert_true(world.fire.changed.is_empty(), "nothing changed on a tick it just burned")
	_run(world, GRASS_TICKS)
	assert_eq(world.fire.changed, PackedInt32Array([5 * 11 + 5]), "it burned out")


# --- helpers

func _world(terrain: Terrain, world_seed: int = 1, types: Array[UnitType] = []) -> World:
	if types.is_empty():
		types = [TestUnits.dummy(&"dummy")]
	return World.new(world_seed, terrain, TestUnits.catalog(types))


# 11 x 11 m of sand with one cell of `center` ground at (5, 5) m.
func _ringed(center: String) -> Terrain:
	var rows: Array[String] = []
	for j: int in 11:
		rows.append("sssss" + (center if j == 5 else "s") + "sssss")
	return TestTerrains.from_ascii(rows)


# size x size m of brush.
func _brush(size: int) -> Terrain:
	var rows: Array[String] = []
	for j: int in size:
		rows.append("b".repeat(size))
	return TestTerrains.from_ascii(rows)


# 40 x 40 m of grass, brush, and wood in bands, with a sand bar.
func _mixed() -> Terrain:
	var rows: Array[String] = []
	for j: int in 40:
		rows.append(_mixed_row(j))
	return TestTerrains.from_ascii(rows)


func _mixed_row(j: int) -> String:
	var row: String = ""
	for i: int in 40:
		if i == 30 and j < 20:
			row += "s"
		elif (i + j) % 13 < 3:
			row += "w"
		elif (i * 3 + j) % 7 < 2:
			row += "b"
		else:
			row += "."
	return row


func _run(world: World, ticks: int) -> void:
	for _t: int in ticks:
		world.step()


# Steps until nothing burns (or the limit). Returns the ticks it took.
func _run_until_out(world: World, limit: int) -> int:
	for t: int in limit:
		world.step()
		if not world.fire.is_burning():
			return t + 1
	return limit


func _count_cells(world: World, cell: Fire.Cell) -> int:
	return world.fire.state.count(cell)


func _launch(world: World, id: StringName, x: int, y: int, z: int, vx: int, vy: int, vz: int) -> Projectile:
	var index: int = world.catalog.projectile_index_of(id)
	return world.spawn_projectile(index, FlightState.at_mm(x, y, z, vx, vy, vz), 0)


# A projectile of this id at rest on the ground at (x, z).
func _lay(world: World, id: StringName, x: int, z: int) -> Projectile:
	var index: int = world.catalog.projectile_index_of(id)
	var radius: int = world.catalog.projectile_types[index].radius
	var p: Projectile = world.spawn_projectile(
		index, FlightState.at_mm(x, world.terrain.height_at(x, z) + radius, z, 0, 0, 0), 0
	)
	p.motion = Projectile.Motion.RESTING
	return p
