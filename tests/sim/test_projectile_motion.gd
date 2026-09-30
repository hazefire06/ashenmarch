extends GutTest
## Projectiles as physical objects: arrows stick where they land and stop in
## the first body they meet; grenades and charges bounce, roll downhill, and
## come to rest; nothing tunnels through the ground or gains energy; fuses
## burn on time and fizzle at the configured rate.

const M: int = 1000
const UM: int = 1_000_000


func test_arrow_sticks_where_it_meets_the_ground() -> void:
	var world: World = _world(TestTerrains.flat(60, 20))
	var arrow: Projectile = _launch(world, &"arrow", 5 * M, 1500, 10 * M, 900_000, 100_000, 0)
	var stuck: ProjectileEvent = _run_until(world, ProjectileEvent.Kind.STICK, 150)
	assert_not_null(stuck)
	assert_true(arrow.removed or world.get_entity(arrow.id) == null, "the sim lets go of a stuck arrow")
	assert_eq(world.projectiles.size(), 0)
	# Its center stops one radius (20 mm) above flat ground, within a mm.
	assert_between(stuck.y, 19, 21)
	assert_lt(stuck.dir_y, 0, "it was coming down")


func test_fast_arrow_does_not_tunnel_through_a_narrow_ridge() -> void:
	# One sample raised 1 m: a ridge 2 m wide at the base, 1 m tall.
	var terrain: Terrain = _spike_terrain(60, 20, 30, 1000)
	var world: World = _world(terrain)
	# 39 m/s, 0.5 m up, 4 m short of the ridge: 3 cm of drop on the way.
	_launch(world, &"arrow", 25 * M, 500, 10 * M, 1_300_000, 0, 0)
	var stuck: ProjectileEvent = _run_until(world, ProjectileEvent.Kind.STICK, 90)
	assert_not_null(stuck)
	assert_between(stuck.x, 29 * M, 30 * M, "stopped on the near face of the ridge")


func test_grenade_rebounds_to_restitution_squared_of_its_drop() -> void:
	# No drag, straight down from 5 m: the rebound apex is e^2 of the drop.
	var grenade: ProjectileType = TestUnits.projectile(&"grenade", {"drag_ppm_per_m": 0, "fuse_ticks": 0, "fizzle_permille": 0})
	var world: World = _world(TestTerrains.flat(20, 20), [grenade])
	var p: Projectile = world.spawn_projectile(0, FlightState.at_mm(10 * M, 5060, 10 * M, 0, 0, 0), 0)
	var bounced: bool = false
	var apex: int = 0
	for _t: int in 120:
		world.step()
		for e: ProjectileEvent in world.projectile_events:
			if e.kind == ProjectileEvent.Kind.BOUNCE:
				if bounced:
					break
				bounced = true
		if bounced:
			apex = maxi(apex, p.y - 60)
		if bounced and p.flight.vy < 0 and apex > 0:
			break
	var e2: int = grenade.restitution_permille * grenade.restitution_permille / 1000
	gut.p("rebound apex %d mm from a 5000 mm drop (e^2 = %d permille)" % [apex, e2])
	assert_almost_eq(apex, 5000 * e2 / 1000, 5000 * e2 / 1000 / 8)


func test_grenade_rolls_down_into_a_valley_and_rests_there() -> void:
	var world: World = _world(_valley_terrain(60, 10, 20, 200))
	var p: Projectile = _place(world, &"grenade", 12 * M, 5 * M)
	for _t: int in 30 * World.TICK_RATE:
		world.step()
		if p.motion == Projectile.Motion.RESTING:
			break
	assert_eq(p.motion, Projectile.Motion.RESTING, "it settles")
	assert_between(p.x, 19 * M, 23 * M, "on the valley floor (x 19..23 m)")


func test_a_satchel_stays_on_a_slope_a_grenade_rolls_down() -> void:
	var world: World = _world(TestTerrains.ramp_x(40, 10, 300))
	var satchel: Projectile = _place(world, &"satchel", 20 * M, 5 * M)
	var grenade: Projectile = _place(world, &"grenade", 20 * M, 8 * M)
	for _t: int in 3 * World.TICK_RATE:
		world.step()
	assert_almost_eq(satchel.x, 20 * M, 100, "a sack stays put on 17 degrees")
	assert_lt(grenade.x, 17 * M, "a bottle rolls down it")


func test_rolling_and_bouncing_never_gain_energy() -> void:
	# Released from rest high on a ramp that runs out onto flat ground, with
	# no drag: kinetic plus potential energy only ever falls.
	var grenade: ProjectileType = TestUnits.projectile(&"grenade", {"drag_ppm_per_m": 0, "fuse_ticks": 0, "fizzle_permille": 0})
	var terrain: Terrain = _ramp_to_flat(60, 10, 30, 500)
	var world: World = _world(terrain, [grenade])
	var p: Projectile = world.spawn_projectile(0, FlightState.at_mm(8 * M, terrain.height_at(8 * M, 5 * M) + 400, 5 * M, 0, 0, 0), 0)
	var start: int = _energy(p)
	var highest: int = start
	for _t: int in 20 * World.TICK_RATE:
		world.step()
		highest = maxi(highest, _energy(p))
	gut.p("energy: start %d, highest %d, end %d (um^2/tick^2)" % [start, highest, _energy(p)])
	assert_lte(highest, start + start / 100, "never more than 1% above where it started")
	assert_lt(_energy(p), start / 2, "friction and bounces took most of it")


func test_arrow_stops_in_the_first_body_in_its_way() -> void:
	var dummy: UnitType = TestUnits.dummy(&"dummy")
	var world: World = _world(TestTerrains.flat(60, 20), [], [dummy])
	var near: Unit = world.spawn_unit(0, TestUnits.DARK, 20 * M, 10 * M, -1, 0)
	var far: Unit = world.spawn_unit(0, TestUnits.DARK, 30 * M, 10 * M, -1, 0)
	# 30 m/s at 1.2 m, 7.6 m from the first body: 30 cm of drop on the way.
	_launch(world, &"arrow", 12 * M, 1200, 10 * M, 1_000_000, 0, 0)
	var hit: ProjectileEvent = _run_until(world, ProjectileEvent.Kind.HIT, 60)
	assert_not_null(hit)
	assert_eq(hit.unit_id, near.id)
	assert_between(near.type.max_hp - near.hp, 16, 20, "18 damage, give or take 10%")
	assert_eq(far.hp, far.type.max_hp)
	assert_eq(world.projectiles.size(), 0)


func test_arrow_flies_over_a_body_below_its_path() -> void:
	var dummy: UnitType = TestUnits.dummy(&"dummy")
	var world: World = _world(TestTerrains.flat(60, 20), [], [dummy])
	var unit: Unit = world.spawn_unit(0, TestUnits.DARK, 12 * M, 10 * M, -1, 0)
	_launch(world, &"arrow", 5 * M, 3000, 10 * M, 1_000_000, 0, 0)
	assert_not_null(_run_until(world, ProjectileEvent.Kind.STICK, 90))
	assert_eq(unit.hp, unit.type.max_hp)


func test_a_launcher_is_not_hit_by_its_own_shot() -> void:
	var dummy: UnitType = TestUnits.dummy(&"dummy")
	var world: World = _world(TestTerrains.flat(60, 20), [], [dummy])
	var shooter: Unit = world.spawn_unit(0, TestUnits.LIGHT, 10 * M, 10 * M, 1, 0)
	var arrow: Projectile = _launch(world, &"arrow", 10 * M, 1500, 10 * M, 1_000_000, 50_000, 0)
	arrow.owner_id = shooter.id
	arrow.ignore_id = shooter.id
	arrow.ignore_ticks = ProjectileSystem.LAUNCH_IGNORE_TICKS
	assert_not_null(_run_until(world, ProjectileEvent.Kind.STICK, 90))
	assert_eq(shooter.hp, shooter.type.max_hp)


func test_grenade_glances_off_a_body_unharmed() -> void:
	var dummy: UnitType = TestUnits.dummy(&"dummy")
	var grenade: ProjectileType = TestUnits.projectile(&"grenade", {"fuse_ticks": 0, "fizzle_permille": 0})
	var world: World = _world(TestTerrains.flat(40, 20), [grenade], [dummy])
	var unit: Unit = world.spawn_unit(0, TestUnits.DARK, 20 * M, 10 * M, -1, 0)
	var p: Projectile = world.spawn_projectile(0, FlightState.at_mm(15 * M, 1000, 10 * M, 400_000, 60_000, 0), 0)
	for _t: int in 30:
		world.step()
	assert_eq(unit.hp, unit.type.max_hp, "no harm done")
	assert_lt(p.x, 20 * M - 400, "it came back off the body")


func test_arrow_shot_off_the_map_is_gone() -> void:
	var world: World = _world(TestTerrains.flat(20, 20))
	_launch(world, &"arrow", 15 * M, 1500, 10 * M, 1_000_000, 300_000, 0)
	for _t: int in 10 * World.TICK_RATE:
		world.step()
	assert_eq(world.projectiles.size(), 0)


func test_fuse_bursts_on_its_tick() -> void:
	var grenade: ProjectileType = TestUnits.projectile(&"grenade", {"fizzle_permille": 0})
	var world: World = _world(TestTerrains.flat(20, 20), [grenade])
	var p: Projectile = _place(world, &"grenade", 10 * M, 10 * M)
	p.fuse_left = 30
	var burst_at: int = -1
	for t: int in 60:
		world.step()
		for e: ProjectileEvent in world.projectile_events:
			if e.kind == ProjectileEvent.Kind.EXPLODE:
				burst_at = t + 1
	assert_eq(burst_at, 30)


func test_fuses_fizzle_at_the_configured_rate() -> void:
	# 1000 grenades that can't set each other off, each fizzling at 5%.
	var grenade: ProjectileType = TestUnits.projectile(&"grenade", {
		"fizzle_permille": 50, "chain_detonates": false, "crater_radius": 0, "knock_radius": 0,
	})
	var world: World = _world(TestTerrains.flat(60, 60), [grenade])
	for k: int in 1000:
		var p: Projectile = _place(world, &"grenade", (5 + k % 50) * M, (5 + k / 50 * 2) * M)
		p.fuse_left = 2
	var fizzled: int = 0
	var burst: int = 0
	for _t: int in 3:
		world.step()
		for e: ProjectileEvent in world.projectile_events:
			if e.kind == ProjectileEvent.Kind.FIZZLE:
				fizzled += 1
			elif e.kind == ProjectileEvent.Kind.EXPLODE:
				burst += 1
	gut.p("%d of 1000 fizzled" % fizzled)
	assert_eq(fizzled + burst, 1000)
	assert_between(fizzled, 30, 70)
	var duds: int = 0
	for p: Projectile in world.projectiles:
		duds += 1 if p.dud else 0
	assert_eq(duds, fizzled, "the fizzled ones stay, as duds")


# --- helpers

func _world(terrain: Terrain, projectiles: Array[ProjectileType] = [], types: Array[UnitType] = []) -> World:
	if types.is_empty():
		types = [TestUnits.dummy(&"dummy")]
	return World.new(1, terrain, TestUnits.catalog(types, projectiles))


# Spawns a projectile of this id flying from (x, y, z) mm at (vx, vy, vz)
# um/tick.
func _launch(world: World, id: StringName, x: int, y: int, z: int, vx: int, vy: int, vz: int) -> Projectile:
	var index: int = world.catalog.projectile_index_of(id)
	return world.spawn_projectile(index, FlightState.at_mm(x, y, z, vx, vy, vz), 0)


# Lays a projectile of this id on the ground at (x, z), rolling from rest.
func _place(world: World, id: StringName, x: int, z: int) -> Projectile:
	var index: int = world.catalog.projectile_index_of(id)
	var radius: int = world.catalog.projectile_types[index].radius
	var p: Projectile = world.spawn_projectile(
		index, FlightState.at_mm(x, world.terrain.height_at(x, z) + radius, z, 0, 0, 0), 0
	)
	p.motion = Projectile.Motion.ROLLING
	return p


func _run_until(world: World, kind: ProjectileEvent.Kind, ticks: int) -> ProjectileEvent:
	for _t: int in ticks:
		world.step()
		for e: ProjectileEvent in world.projectile_events:
			if e.kind == kind:
				return e
	return null


# Kinetic plus potential energy per unit mass, in um^2/tick^2.
func _energy(p: Projectile) -> int:
	var f: FlightState = p.flight
	return (f.vx * f.vx + f.vy * f.vy + f.vz * f.vz) / 2 + FlightState.GRAVITY * f.py


func _spike_terrain(size_x: int, size_z: int, at_i: int, height: int) -> Terrain:
	var heights: PackedInt32Array = PackedInt32Array()
	var water: PackedByteArray = PackedByteArray()
	var blocked: PackedByteArray = PackedByteArray()
	heights.resize(size_x * size_z)
	water.resize(size_x * size_z)
	blocked.resize(size_x * size_z)
	for j: int in size_z:
		heights[j * size_x + at_i] = height
	return Terrain.new(size_x, size_z, TestTerrains.CELL, heights, water, blocked, TestTerrains.WALKABLE_SLOPE)


# Walls falling at grade permille to a flat floor 3 m wide around i = floor_i.
func _valley_terrain(size_x: int, size_z: int, floor_i: int, grade: int) -> Terrain:
	var heights: PackedInt32Array = PackedInt32Array()
	var water: PackedByteArray = PackedByteArray()
	var blocked: PackedByteArray = PackedByteArray()
	heights.resize(size_x * size_z)
	water.resize(size_x * size_z)
	blocked.resize(size_x * size_z)
	for j: int in size_z:
		for i: int in size_x:
			heights[j * size_x + i] = maxi(0, absi(i - floor_i) - 1) * grade
	return Terrain.new(size_x, size_z, TestTerrains.CELL, heights, water, blocked, TestTerrains.WALKABLE_SLOPE)


# A ramp falling toward +x at grade permille until i = foot_i, then flat.
func _ramp_to_flat(size_x: int, size_z: int, foot_i: int, grade: int) -> Terrain:
	var heights: PackedInt32Array = PackedInt32Array()
	var water: PackedByteArray = PackedByteArray()
	var blocked: PackedByteArray = PackedByteArray()
	heights.resize(size_x * size_z)
	water.resize(size_x * size_z)
	blocked.resize(size_x * size_z)
	for j: int in size_z:
		for i: int in size_x:
			heights[j * size_x + i] = maxi(0, foot_i - i) * grade
	return Terrain.new(size_x, size_z, TestTerrains.CELL, heights, water, blocked, TestTerrains.WALKABLE_SLOPE)
