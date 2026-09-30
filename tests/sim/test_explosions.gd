extends GutTest
## Blasts: damage falls off with distance and spares no one, knockback
## throws units and loose objects but never into water they can't stand in,
## charges chain, a Sapper caught in a blast cooks off its own satchels,
## craters dig the ground without changing where anyone walks, and a grenade
## thrown up a steep hill can roll back down onto its thrower.

const M: int = 1000
const LIGHT: UnitType.Faction = UnitType.Faction.LIGHT
const DARK: UnitType.Faction = UnitType.Faction.DARK


func test_damage_is_full_near_the_burst_and_falls_off_to_nothing() -> void:
	var grenade: ProjectileType = TestUnits.projectile(&"grenade")
	assert_eq(Explosions.falloff_permille(grenade, 0), 1000)
	assert_eq(Explosions.falloff_permille(grenade, grenade.blast_inner_radius), 1000)
	assert_eq(Explosions.falloff_permille(grenade, grenade.blast_radius), 0)
	var last: int = 1000
	for d: int in range(grenade.blast_inner_radius, grenade.blast_radius, 250):
		var share: int = Explosions.falloff_permille(grenade, d)
		assert_lte(share, last)
		last = share


func test_a_blast_hurts_friend_and_foe_by_distance() -> void:
	var world: World = _world(TestTerrains.flat(40, 40))
	var units: Array[Unit] = []
	for k: int in 5:
		# Alternating sides, 0.9 m farther out each (edge distances 0.1..3.7 m).
		var side: UnitType.Faction = LIGHT if k % 2 == 0 else DARK
		var angle: int = k * FixedMath.ANGLE_FULL / 5
		var r: int = 500 + k * 900
		units.append(world.spawn_unit(
			0, side, 20 * M + FixedMath.cos_b(angle) * r / FixedMath.TRIG_ONE,
			20 * M + FixedMath.sin_b(angle) * r / FixedMath.TRIG_ONE, 1, 0
		))
	_burst_at(world, &"grenade", 20 * M, 20 * M)
	var losses: Array[int] = []
	for u: Unit in units:
		losses.append(u.type.max_hp - u.hp)
	gut.p("hp lost by distance: %s" % [losses])
	assert_eq(losses[0], 60, "full damage right at the burst, and it's a friend")
	for k: int in range(1, 4):
		assert_lt(losses[k], losses[k - 1], "less farther out")
		assert_gt(losses[k], 0)
	assert_eq(losses[4], 0, "nothing beyond the blast radius")


func test_knockback_throws_units_away_and_they_reel() -> void:
	var world: World = _world(TestTerrains.flat(40, 40))
	var unit: Unit = world.spawn_unit(0, DARK, 22 * M, 20 * M, -1, 0)
	_burst_at(world, &"grenade", 20 * M, 20 * M)
	assert_gt(unit.knock_vx, 0, "thrown away from the burst")
	assert_true(unit.is_reeling())
	for _t: int in World.TICK_RATE:
		world.step()
	assert_false(unit.is_reeling(), "back on its feet within a second")
	assert_gt(unit.x, 22 * M + 300, "and it moved")


func test_knockback_cannot_throw_a_unit_into_deep_water() -> void:
	var rows: Array[String] = []
	for j: int in 20:
		rows.append("..........333333333")
	var world: World = World.new(1, TestTerrains.from_ascii(rows), TestUnits.catalog([TestUnits.dummy(&"dummy")]))
	var unit: Unit = world.spawn_unit(0, DARK, 8 * M, 10 * M, -1, 0)
	_burst_at(world, &"satchel", 6 * M, 10 * M)
	for _t: int in 2 * World.TICK_RATE:
		world.step()
		assert_lt(world.terrain.water_depth_at(unit.x, unit.z), Terrain.LIVING_IMPASSABLE_DEPTH)


func test_a_blast_throws_loose_objects_it_doesnt_set_off() -> void:
	var rock: ProjectileType = TestUnits.projectile(&"satchel", {
		"id": &"rock", "blast_radius": 0, "chain_detonates": false, "crater_radius": 0,
	})
	var grenade: ProjectileType = TestUnits.projectile(&"grenade")
	var world: World = World.new(1, TestTerrains.flat(40, 40), TestUnits.catalog([TestUnits.dummy(&"dummy")], [grenade, rock]))
	var stone: Projectile = world.spawn_projectile(1, FlightState.at_mm(24 * M, 120, 20 * M, 0, 0, 0), 0)
	stone.motion = Projectile.Motion.RESTING
	var g: Projectile = world.spawn_projectile(0, FlightState.at_mm(20 * M, 60, 20 * M, 0, 0, 0), 0)
	g.motion = Projectile.Motion.RESTING
	g.fuse_left = 1
	world.step()
	assert_eq(stone.motion, Projectile.Motion.FLYING)
	assert_gt(stone.flight.vx, 0, "outward")
	assert_gt(stone.flight.vy, 0, "and up")


func test_a_dud_lies_inert_until_a_blast_sets_it_off() -> void:
	var dud_maker: ProjectileType = TestUnits.projectile(&"grenade", {"fizzle_permille": 1000})
	var world: World = World.new(1, TestTerrains.flat(40, 40), TestUnits.catalog([TestUnits.dummy(&"dummy")], [dud_maker]))
	var dud: Projectile = _rest(world, 0, 20 * M, 20 * M)
	dud.fuse_left = 5
	for _t: int in 10 * World.TICK_RATE:
		world.step()
	assert_true(dud.dud)
	assert_false(dud.removed, "a dud stays in the world")
	# A second grenade goes off 2 m away and catches it.
	var live: Projectile = _rest(world, 0, 22 * M, 20 * M)
	world.explosions.detonate(world, live)
	var bursts: int = 0
	for _t: int in 10:
		world.step()
		bursts += _count(world, ProjectileEvent.Kind.EXPLODE)
	assert_eq(bursts, 2, "the live one, then the dud")
	assert_true(dud.removed or world.get_entity(dud.id) == null)


func test_one_grenade_sets_off_a_chain_of_five_satchels() -> void:
	# A Sapper ground-attacks the first of five satchels laid 3 m apart;
	# each satchel's 5 m blast catches the next. A sixth lies 8.5 m past
	# the last, beyond even the knockback, and survives.
	var grenade: ProjectileType = TestUnits.projectile(&"grenade", {"fizzle_permille": 0})
	var satchel: ProjectileType = TestUnits.projectile(&"satchel")
	var thrower: UnitType = TestUnits.thrower(&"sapper", {"ranged_ammo": 1})
	var world: World = World.new(3, TestTerrains.flat(80, 30), TestUnits.catalog([thrower], [grenade, satchel]))
	var sapper: Unit = world.spawn_unit(0, LIGHT, 15 * M, 15 * M, 1, 0)
	var chain: Array[Projectile] = []
	for k: int in 5:
		chain.append(_rest(world, 1, (30 + 3 * k) * M, 15 * M))
	var survivor: Projectile = _rest(world, 1, 50_500, 15 * M)
	world.enqueue(GroundAttackCommand.new(0, PackedInt32Array([sapper.id]), 30 * M, 15 * M))
	var burst_ticks: Array[int] = []
	for t: int in 10 * World.TICK_RATE:
		world.step()
		for e: ProjectileEvent in world.projectile_events:
			if e.kind == ProjectileEvent.Kind.EXPLODE:
				burst_ticks.append(t)
	gut.p("bursts at ticks %s" % [burst_ticks])
	assert_eq(burst_ticks.size(), 6, "the grenade and all five satchels, each once")
	for p: Projectile in chain:
		assert_null(world.get_entity(p.id), "every satchel in the chain went off")
	assert_not_null(world.get_entity(survivor.id), "the sixth is still there")
	assert_false(survivor.detonating)
	assert_eq(sapper.hp, sapper.type.max_hp, "the thrower was well clear")


func test_a_sapper_caught_in_a_blast_cooks_off_its_satchels() -> void:
	var grenade: ProjectileType = TestUnits.projectile(&"grenade")
	var satchel: ProjectileType = TestUnits.projectile(&"satchel")
	var thrower: UnitType = TestUnits.thrower(&"sapper", {"max_hp": 40})
	var world: World = World.new(1, TestTerrains.flat(40, 40), TestUnits.catalog([thrower], [grenade, satchel]))
	var sapper: Unit = world.spawn_unit(0, DARK, 20 * M, 20 * M, 1, 0)
	_burst_at(world, &"grenade", 20 * M, 20 * M, 0)
	assert_false(sapper.is_alive())
	var bursts: int = 1
	for _t: int in 20:
		world.step()
		bursts += _count(world, ProjectileEvent.Kind.EXPLODE)
	assert_eq(bursts, 5, "the grenade, then its four satchels")


func test_a_ground_burst_digs_a_crater_and_an_air_burst_does_not() -> void:
	var world: World = _world(TestTerrains.flat(40, 40))
	var before: int = world.terrain.height_at(20 * M, 20 * M)
	var hash_before: String = world.state_hash()
	var e: ProjectileEvent = _burst_at(world, &"grenade", 20 * M, 20 * M)
	assert_gt(e.crater, 0)
	assert_eq(world.terrain.height_at(20 * M, 20 * M), before - 150, "the full crater depth at the center")
	assert_true(world.terrain.is_passable(20 * M, 20 * M, Terrain.Mobility.LIVING), "still walkable")
	assert_ne(world.state_hash(), hash_before)
	var air: ProjectileEvent = _burst_at(world, &"grenade", 10 * M, 10 * M, 5000)
	assert_eq(air.crater, 0)
	assert_eq(world.terrain.height_at(10 * M, 10 * M), before)


func test_grenade_thrown_up_a_steep_hill_rolls_back_onto_its_thrower() -> void:
	# The Sapper stands on flat ground 2 m short of a 39 degree slope and
	# ground-attacks a spot 4.5 m up it (5.5 m out, just past its 5 m
	# minimum). The lob lands, the slope is too steep to hold a bottle, and
	# it rolls back down to the Sapper's feet before the fuse burns out.
	# Nothing here is random but the fuse length; five seeds try five.
	var foot: int = 20 * M
	var up_x: int = foot + 3510
	for world_seed: int in [1, 2, 3, 4, 5]:
		var world: World = _hill_world(world_seed, _ramp_up_from(60, 20, 20, 800))
		var sapper: Unit = world.spawn_unit(0, LIGHT, foot - 2 * M, 10 * M, 1, 0)
		world.enqueue(GroundAttackCommand.new(0, PackedInt32Array([sapper.id]), up_x, 10 * M))
		var landed_up: bool = false
		var burst: ProjectileEvent = null
		for _t: int in 8 * World.TICK_RATE:
			world.step()
			for p: Projectile in world.projectiles:
				landed_up = landed_up or (p.motion != Projectile.Motion.FLYING and p.x > foot + 1000)
			for e: ProjectileEvent in world.projectile_events:
				if e.kind == ProjectileEvent.Kind.EXPLODE:
					burst = e
			if burst != null:
				break
		assert_not_null(burst, "seed %d: it went off" % world_seed)
		if burst == null:
			continue
		gut.p("seed %d: landed up the slope %s, burst at x %.2f m, thrower at %.2f m, thrower hp %d/%d" % [
			world_seed, landed_up, burst.x / 1000.0, sapper.x / 1000.0, sapper.hp, sapper.type.max_hp
		])
		assert_true(landed_up, "seed %d: it came to ground up the slope" % world_seed)
		assert_lt(burst.x, foot, "seed %d: and rolled back down past the foot" % world_seed)
		assert_lt(sapper.hp, sapper.type.max_hp, "seed %d: onto the thrower" % world_seed)


func test_the_same_throw_on_level_ground_leaves_the_thrower_unhurt() -> void:
	for world_seed: int in [1, 2, 3, 4, 5]:
		var world: World = _hill_world(world_seed, TestTerrains.flat(60, 20))
		var sapper: Unit = world.spawn_unit(0, LIGHT, 18 * M, 10 * M, 1, 0)
		world.enqueue(GroundAttackCommand.new(0, PackedInt32Array([sapper.id]), 23_510, 10 * M))
		var bursts: int = 0
		for _t: int in 8 * World.TICK_RATE:
			world.step()
			bursts += _count(world, ProjectileEvent.Kind.EXPLODE)
		assert_eq(bursts, 1, "seed %d" % world_seed)
		assert_eq(sapper.hp, sapper.type.max_hp, "seed %d: it bounced and rolled away" % world_seed)


# --- helpers

func _world(terrain: Terrain) -> World:
	return World.new(1, terrain, TestUnits.catalog([TestUnits.dummy(&"dummy")]))


# A Sapper world for the hill test: zero spread (physics, not dice), one
# grenade, one that never fizzles; otherwise the shipped grenade.
func _hill_world(world_seed: int, terrain: Terrain) -> World:
	var grenade: ProjectileType = TestUnits.projectile(&"grenade", {"fizzle_permille": 0})
	var satchel: ProjectileType = TestUnits.projectile(&"satchel")
	var thrower: UnitType = TestUnits.thrower(&"sapper", {"ranged_ammo": 1, "special_charges": 1})
	return World.new(world_seed, terrain, TestUnits.catalog([thrower], [grenade, satchel]))


# Sets off a projectile of this id resting at (x, z), height above ground,
# right now (no tick runs). Returns its EXPLODE event.
func _burst_at(world: World, id: StringName, x: int, z: int, height: int = 0) -> ProjectileEvent:
	var index: int = world.catalog.projectile_index_of(id)
	var p: Projectile = _rest(world, index, x, z)
	p.flight.py += height * FlightState.SUB
	p.sync_position()
	world.projectile_events.clear()
	world.explosions.detonate(world, p)
	world.explosions.resolve(world, UnitGrid.new(world.units, ProjectileSystem.GRID_BUCKET))
	for e: ProjectileEvent in world.projectile_events:
		if e.kind == ProjectileEvent.Kind.EXPLODE and e.projectile_id == p.id:
			return e
	return null


func _rest(world: World, index: int, x: int, z: int) -> Projectile:
	var radius: int = world.catalog.projectile_types[index].radius
	var p: Projectile = world.spawn_projectile(
		index, FlightState.at_mm(x, world.terrain.height_at(x, z) + radius, z, 0, 0, 0), 0
	)
	p.motion = Projectile.Motion.RESTING
	return p


func _count(world: World, kind: ProjectileEvent.Kind) -> int:
	var n: int = 0
	for e: ProjectileEvent in world.projectile_events:
		n += 1 if e.kind == kind else 0
	return n


# Flat until i = foot_i, then rising toward +x at grade permille.
func _ramp_up_from(size_x: int, size_z: int, foot_i: int, grade: int) -> Terrain:
	var heights: PackedInt32Array = PackedInt32Array()
	var water: PackedByteArray = PackedByteArray()
	var blocked: PackedByteArray = PackedByteArray()
	heights.resize(size_x * size_z)
	water.resize(size_x * size_z)
	blocked.resize(size_x * size_z)
	for j: int in size_z:
		for i: int in size_x:
			heights[j * size_x + i] = maxi(0, i - foot_i) * grade
	return Terrain.new(size_x, size_z, TestTerrains.CELL, heights, water, blocked, TestTerrains.WALKABLE_SLOPE)
