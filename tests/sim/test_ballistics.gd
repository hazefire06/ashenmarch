extends GutTest
## The integrator and the aiming solver: flights follow the physics exactly,
## solved launches pass through their targets, reach and spread behave the
## way CLAUDE.md says (uphill costs a thrown charge far more than an arrow),
## and the RNG is drawn a fixed number of times per shot.

const M: int = 1000
const UM: int = 1_000_000
const ARROW_SPEED: int = 34_000
const THROW_SPEED: int = 17_500
const ARROW_DRAG: int = 5000
const GRENADE_DRAG: int = 2000
const LOB_45: int = 1000


func test_free_flight_is_exact_semi_implicit_euler() -> void:
	# With no drag every step is exact integer arithmetic: v_n = v0 - n g
	# and y_n = y0 + n v0 - g n (n + 1) / 2.
	var f: FlightState = FlightState.new(5 * UM, 2 * UM, 7 * UM, 300_000, 400_000, -100_000)
	for n: int in range(1, 91):
		f.advance(0)
		assert_eq(f.vy, 400_000 - n * FlightState.GRAVITY)
		assert_eq(f.py, 2 * UM + n * 400_000 - FlightState.GRAVITY * n * (n + 1) / 2)
		assert_eq(f.px, 5 * UM + n * 300_000)
		assert_eq(f.pz, 7 * UM - n * 100_000)


func test_gravity_is_9_81_m_per_s2() -> void:
	# 30 ticks of free fall from rest gain 9.81 m/s.
	var f: FlightState = FlightState.new()
	for _n: int in World.TICK_RATE:
		f.advance(0)
	assert_eq(-f.vy * World.TICK_RATE, 9_810_000, "micrometres per second")


func test_drag_bleeds_speed_and_shortens_flight() -> void:
	var still: FlightState = FlightState.new(0, 0, 0, 1_000_000, 300_000, 0)
	var dragged: FlightState = still.copy()
	var last_vx: int = dragged.vx
	while dragged.py >= 0:
		dragged.advance(ARROW_DRAG)
		still.advance(0)
		assert_lt(dragged.vx, last_vx, "horizontal speed only ever falls")
		last_vx = dragged.vx
	assert_lt(dragged.px, still.px, "the air shortens the flight")
	# 0.5% of speed per metre over about 55 m of flight: roughly a quarter.
	assert_between(dragged.vx, 750_000, 830_000)


func test_direct_shots_pass_through_their_targets() -> void:
	var speed: int = FlightState.speed_from_mm_per_s(ARROW_SPEED)
	var solved: int = 0
	for reach_m: int in [5, 10, 20, 35, 50]:
		for rise_m: int in [-10, -3, 0, 3, 10]:
			var from: FlightState = FlightState.at_mm(100 * M, 20 * M, 100 * M, 0, 0, 0)
			var tx: int = (100 * M + reach_m * 600) * FlightState.SUB
			var tz: int = (100 * M + reach_m * 800) * FlightState.SUB
			var ty: int = (20 + rise_m) * UM
			var s: AimSolution = Ballistics.solve_direct(from, tx, ty, tz, speed, ARROW_DRAG)
			assert_true(s.ok, "%d m out, %d m up" % [reach_m, rise_m])
			if not s.ok:
				continue
			solved += 1
			var passing: int = _height_passing(from, s, tx, tz, ARROW_DRAG)
			assert_almost_eq(passing, ty, 50_000, "within 5 cm at %d m, %+d m" % [reach_m, rise_m])
			assert_almost_eq(passing - ty, s.miss, 1000, "the solver reports its own miss")
			assert_almost_eq(_speed(s), speed, speed / 10_000, "a direct shot uses full speed")
	assert_eq(solved, 25)


func test_direct_shot_takes_the_flatter_arc() -> void:
	var speed: int = FlightState.speed_from_mm_per_s(ARROW_SPEED)
	var from: FlightState = FlightState.at_mm(0, 0, 0, 0, 0, 0)
	var s: AimSolution = Ballistics.solve_direct(from, 30 * UM, 0, 0, speed, ARROW_DRAG)
	assert_true(s.ok)
	# The low arc to 30 m at 34 m/s is about 7.5 degrees; the high one ~82.
	assert_lt(s.vy * 1000 / s.vx, 200, "grade under 0.2")
	assert_lt(s.ticks, 40, "about a second of flight, not six")


func test_lobs_pass_through_their_targets_at_or_under_max_speed() -> void:
	var max_speed: int = FlightState.speed_from_mm_per_s(THROW_SPEED)
	# Every point a 45 degree lob can reach at 17.5 m/s. Just under the 45
	# degree line (6 m out, 5 up) or far and high (25 out, 5 up) needs more;
	# those fall back to a direct throw.
	for reach_m: int in [6, 8, 14, 20, 25]:
		for rise_m: int in [-5, -2, 0, 2, 5]:
			if rise_m == 5 and (reach_m == 6 or reach_m == 25):
				continue
			var from: FlightState = FlightState.at_mm(50 * M, 10 * M, 50 * M, 0, 0, 0)
			var tx: int = (50 * M + reach_m * M) * FlightState.SUB
			var ty: int = (10 + rise_m) * UM
			var tz: int = 50 * UM
			var s: AimSolution = Ballistics.solve_lob(from, tx, ty, tz, LOB_45, max_speed, GRENADE_DRAG)
			assert_true(s.ok, "%d m out, %+d m up" % [reach_m, rise_m])
			if not s.ok:
				continue
			var passing: int = _height_passing(from, s, tx, tz, GRENADE_DRAG)
			# At the edge of reach the best a full-speed lob does may be a few
			# cm short; anywhere else it passes within 5 mm.
			assert_almost_eq(passing, ty, Ballistics.AIM_REJECT, "%d m out, %+d m up" % [reach_m, rise_m])
			assert_almost_eq(passing - ty, s.miss, 1000, "the solver reports its own miss")
			assert_lte(_speed(s), max_speed + max_speed / 10_000, "never faster than the arm allows")
			assert_almost_eq(s.vy, s.vx, s.vx / 100 + 2, "thrown at 45 degrees")


func test_short_lobs_are_gentle() -> void:
	# The reason throwers lob: a 6 m throw leaves slowly, not at full speed.
	var max_speed: int = FlightState.speed_from_mm_per_s(THROW_SPEED)
	var from: FlightState = FlightState.at_mm(0, 1500, 0, 0, 0, 0)
	var s: AimSolution = Ballistics.solve_lob(from, 6 * UM, 0, 0, LOB_45, max_speed, GRENADE_DRAG)
	assert_true(s.ok)
	assert_lt(_speed(s), max_speed / 2)


func test_out_of_reach_is_refused() -> void:
	var arrow: int = FlightState.speed_from_mm_per_s(ARROW_SPEED)
	var throw: int = FlightState.speed_from_mm_per_s(THROW_SPEED)
	var from: FlightState = FlightState.at_mm(0, 0, 0, 0, 0, 0)
	assert_false(Ballistics.solve_direct(from, 200 * UM, 0, 0, arrow, ARROW_DRAG).ok, "too far for a bow")
	assert_false(Ballistics.solve_lob(from, 45 * UM, 0, 0, LOB_45, throw, GRENADE_DRAG).ok, "too far to lob")
	assert_false(Ballistics.solve_direct(from, 45 * UM, 0, 0, throw, GRENADE_DRAG).ok, "too far to throw at all")
	assert_false(Ballistics.solve_direct(from, 5 * UM, 25 * UM, 0, throw, GRENADE_DRAG).ok, "too high")
	assert_false(Ballistics.solve_direct(from, 0, 0, 0, arrow, ARROW_DRAG).ok, "no bearing")


func test_lob_fails_when_the_target_is_above_its_line() -> void:
	# A 45 degree lob can't reach a point more than 45 degrees up.
	var throw: int = FlightState.speed_from_mm_per_s(THROW_SPEED)
	var from: FlightState = FlightState.at_mm(0, 0, 0, 0, 0, 0)
	assert_false(Ballistics.solve_lob(from, 4 * UM, 5 * UM, 0, LOB_45, throw, GRENADE_DRAG).ok)


func test_uphill_costs_a_throw_far_more_reach_than_an_arrow() -> void:
	var arrow: int = FlightState.speed_from_mm_per_s(ARROW_SPEED)
	var throw: int = FlightState.speed_from_mm_per_s(THROW_SPEED)
	var arrow_flat: int = _max_reach(arrow, 0, ARROW_DRAG)
	var arrow_up: int = _max_reach(arrow, 8, ARROW_DRAG)
	var throw_flat: int = _max_reach(throw, 0, GRENADE_DRAG)
	var throw_up: int = _max_reach(throw, 8, GRENADE_DRAG)
	gut.p("max reach (m) flat vs 8 m up: arrow %d -> %d, throw %d -> %d" % [arrow_flat, arrow_up, throw_flat, throw_up])
	var arrow_loss: int = (arrow_flat - arrow_up) * 1000 / arrow_flat
	var throw_loss: int = (throw_flat - throw_up) * 1000 / throw_flat
	assert_gt(throw_loss, 3 * arrow_loss, "thrown explosives suffer far more uphill")


func test_perturb_draws_exactly_twice_and_keeps_speed() -> void:
	for spread: int in [0, 25, 300]:
		var rng: RandomNumberGenerator = RandomNumberGenerator.new()
		rng.seed = 41
		var twin: RandomNumberGenerator = RandomNumberGenerator.new()
		twin.seed = 41
		var v: PackedInt64Array = Ballistics.perturb(800_000, 200_000, -300_000, spread, rng)
		twin.randi_range(0, 1)
		twin.randi_range(0, 1)
		assert_eq(rng.state, twin.state, "spread %d" % spread)
		var speed: int = FixedMath.isqrt(800_000 * 800_000 + 200_000 * 200_000 + 300_000 * 300_000)
		assert_almost_eq(FixedMath.isqrt(v[0] * v[0] + v[1] * v[1] + v[2] * v[2]), speed, 3)


func test_perturb_fills_the_cone_evenly() -> void:
	# Offsets are uniform over the cone's cross-section: none beyond the
	# spread, and the mean radius of a uniform disc is 2/3 of its edge.
	var rng: RandomNumberGenerator = RandomNumberGenerator.new()
	rng.seed = 7
	var spread: int = 50
	var total: int = 0
	var widest: int = 0
	var n: int = 3000
	var up: int = 0
	var right: int = 0
	for _i: int in n:
		var v: PackedInt64Array = Ballistics.perturb(1_000_000, 0, 0, spread, rng)
		# Straight along +x, so the offset is (vz, vy) over vx, as a grade.
		var off: int = FixedMath.isqrt(v[1] * v[1] + v[2] * v[2]) * 1000 / v[0]
		total += off
		widest = maxi(widest, off)
		up += 1 if v[1] > 0 else 0
		right += 1 if v[2] > 0 else 0
	assert_lte(widest, spread + 1)
	assert_almost_eq(total / n, spread * 2 / 3, 2)
	assert_almost_eq(up * 1000 / n, 500, 40, "as many high as low")
	assert_almost_eq(right * 1000 / n, 500, 40, "as many right as left")


func test_a_ridge_blocks_the_flat_shot_but_not_the_lob() -> void:
	# A 5 m wall halfway to a target on flat ground: taller than the arrow's
	# flat arc (about 3 m at the middle of 40 m), lower than a 31 degree lob.
	var terrain: Terrain = _ridge_terrain(60, 30, 5000)
	var from: FlightState = FlightState.at_mm(10 * M, 1500, 15 * M, 0, 0, 0)
	var tx: int = 50 * UM
	var tz: int = 15 * UM
	var ty: int = 900_000
	var speed: int = FlightState.speed_from_mm_per_s(ARROW_SPEED)
	var none: Array[Unit] = []
	var direct: AimSolution = Ballistics.solve_direct(from, tx, ty, tz, speed, ARROW_DRAG)
	assert_true(direct.ok)
	assert_false(Ballistics.is_clear(terrain, from, direct, tx, tz, 20, ARROW_DRAG, none))
	var lob: AimSolution = Ballistics.solve_lob(from, tx, ty, tz, 600, speed, ARROW_DRAG)
	assert_true(lob.ok)
	assert_true(Ballistics.is_clear(terrain, from, lob, tx, tz, 20, ARROW_DRAG, none))


func test_a_friend_in_front_blocks_the_flat_shot_but_not_the_lob() -> void:
	var t: UnitType = TestUnits.melee(&"friend")
	var world: World = World.new(1, TestTerrains.flat(60, 30), TestUnits.catalog([t]))
	var shooter: Unit = world.spawn_unit(0, TestUnits.LIGHT, 10 * M, 15 * M, 1, 0)
	world.spawn_unit(0, TestUnits.LIGHT, 13 * M, 15 * M, 1, 0)
	var from: FlightState = FlightState.at_mm(shooter.x, shooter.y + 1500, shooter.z, 0, 0, 0)
	var tx: int = 25 * UM
	var tz: int = 15 * UM
	var ty: int = 1_000_000
	var speed: int = FlightState.speed_from_mm_per_s(ARROW_SPEED)
	var friends: Array[Unit] = Ballistics.bodies_near_path(
		world.units, TestUnits.LIGHT, shooter, from, tx, tz, 3000
	)
	assert_eq(friends.size(), 1, "the shooter itself is left out")
	var direct: AimSolution = Ballistics.solve_direct(from, tx, ty, tz, speed, ARROW_DRAG)
	assert_false(Ballistics.is_clear(world.terrain, from, direct, tx, tz, 20, ARROW_DRAG, friends))
	var lob: AimSolution = Ballistics.solve_lob(from, tx, ty, tz, 600, speed, ARROW_DRAG)
	assert_true(Ballistics.is_clear(world.terrain, from, lob, tx, tz, 20, ARROW_DRAG, friends))


# Height (um) at which the solved launch passes the target's horizontal
# distance, flown independently of the solver.
func _height_passing(from: FlightState, s: AimSolution, tx: int, tz: int, drag: int) -> int:
	var f: FlightState = FlightState.new(from.px, from.py, from.pz, s.vx, s.vy, s.vz)
	var dx: int = tx - from.px
	var dz: int = tz - from.pz
	var reach: int = FixedMath.isqrt(dx * dx + dz * dz)
	var before_d: int = 0
	var before_y: int = f.py
	for _n: int in 400:
		f.advance(drag)
		var d: int = FixedMath.isqrt((f.px - from.px) * (f.px - from.px) + (f.pz - from.pz) * (f.pz - from.pz))
		if d >= reach:
			return before_y + (f.py - before_y) * (reach - before_d) / (d - before_d)
		before_d = d
		before_y = f.py
	return -(1 << 40)


func _speed(s: AimSolution) -> int:
	return FixedMath.isqrt(s.vx * s.vx + s.vy * s.vy + s.vz * s.vz)


# Farthest whole metre out a projectile can hit a point rise_m above its
# launch height, by lob (throwers) or direct fire, whichever reaches.
func _max_reach(speed: int, rise_m: int, drag: int) -> int:
	var from: FlightState = FlightState.at_mm(0, 0, 0, 0, 0, 0)
	var best: int = 0
	for reach_m: int in range(1, 200):
		var ty: int = rise_m * UM
		var lob: AimSolution = Ballistics.solve_lob(from, reach_m * UM, ty, 0, LOB_45, speed, drag)
		var direct: AimSolution = Ballistics.solve_direct(from, reach_m * UM, ty, 0, speed, drag)
		if lob.ok or direct.ok:
			best = reach_m
	return best


# Flat ground with a wall of the given height across x = 29..31 m.
func _ridge_terrain(size_x: int, size_z: int, wall_height: int) -> Terrain:
	var heights: PackedInt32Array = PackedInt32Array()
	var water: PackedByteArray = PackedByteArray()
	var blocked: PackedByteArray = PackedByteArray()
	heights.resize(size_x * size_z)
	water.resize(size_x * size_z)
	blocked.resize(size_x * size_z)
	for j: int in size_z:
		for i: int in range(29, 32):
			heights[j * size_x + i] = wall_height
	return Terrain.new(size_x, size_z, TestTerrains.CELL, heights, water, blocked, TestTerrains.WALKABLE_SLOPE)
