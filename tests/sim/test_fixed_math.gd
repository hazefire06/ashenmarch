extends GutTest
## FixedMath must be exact: isqrt is the true floor root, rounding helpers round
## the documented way, and the trig table matches sin() to within rounding.


func test_isqrt_small_values() -> void:
	var expected: Dictionary[int, int] = {
		0: 0, 1: 1, 2: 1, 3: 1, 4: 2, 8: 2, 9: 3, 15: 3, 16: 4, 24: 4, 25: 5, 99: 9, 100: 10,
	}
	for n: int in expected:
		assert_eq(FixedMath.isqrt(n), expected[n], "isqrt(%d)" % n)


func test_isqrt_negative_is_zero() -> void:
	assert_eq(FixedMath.isqrt(-1), 0)
	assert_eq(FixedMath.isqrt(-1_000_000), 0)


func test_isqrt_perfect_squares_and_neighbors() -> void:
	for r: int in [1_000, 65_535, 1_000_000, 2_147_483_647, 2_147_483_648, 2_147_483_649]:
		var square: int = r * r
		assert_eq(FixedMath.isqrt(square), r, "isqrt(%d^2)" % r)
		assert_eq(FixedMath.isqrt(square - 1), r - 1, "isqrt(%d^2 - 1)" % r)
		assert_eq(FixedMath.isqrt(square + 1), r, "isqrt(%d^2 + 1)" % r)


func test_isqrt_upper_limit() -> void:
	var n: int = (1 << 62) - 1
	var r: int = FixedMath.isqrt(n)
	assert_true(r * r <= n and (r + 1) * (r + 1) > n)


func test_isqrt_is_floor_for_many_values() -> void:
	var gen: RandomNumberGenerator = RandomNumberGenerator.new()
	gen.seed = 7
	var failures: Array[int] = []
	for i: int in 2000:
		# Keep n below 2^62: randi() is 32-bit, so halve both factors.
		var n: int = (gen.randi() >> 1) * (gen.randi() >> 1) + gen.randi_range(0, 1000)
		var r: int = FixedMath.isqrt(n)
		if not (r * r <= n and (r + 1) * (r + 1) > n):
			failures.append(n)
	assert_eq(failures.size(), 0, "inputs with a wrong root: %s" % [failures])


func test_div_floor_rounds_toward_negative_infinity() -> void:
	assert_eq(FixedMath.div_floor(7, 2), 3)
	assert_eq(FixedMath.div_floor(-7, 2), -4)
	assert_eq(FixedMath.div_floor(-8, 2), -4)
	assert_eq(FixedMath.div_floor(0, 5), 0)
	assert_eq(FixedMath.div_floor(-1, 1_000_000), -1)


func test_div_round_is_nearest_and_symmetric() -> void:
	assert_eq(FixedMath.div_round(7, 2), 4, "3.5 rounds away from zero")
	assert_eq(FixedMath.div_round(-7, 2), -4)
	assert_eq(FixedMath.div_round(5, 3), 2)
	assert_eq(FixedMath.div_round(-5, 3), -2)
	assert_eq(FixedMath.div_round(4, 3), 1)
	assert_eq(FixedMath.div_round(-4, 3), -1)
	assert_eq(FixedMath.div_round(0, 7), 0)


func test_sine_matches_float_sine_for_every_angle() -> void:
	var failures: Array[String] = []
	for a: int in FixedMath.ANGLE_FULL:
		var radians: float = a * TAU / FixedMath.ANGLE_FULL
		var want_sin: int = roundi(sin(radians) * FixedMath.TRIG_ONE)
		var want_cos: int = roundi(cos(radians) * FixedMath.TRIG_ONE)
		if absi(FixedMath.sin_b(a) - want_sin) > 1 or absi(FixedMath.cos_b(a) - want_cos) > 1:
			failures.append("%d: sin %d vs %d, cos %d vs %d" % [
				a, FixedMath.sin_b(a), want_sin, FixedMath.cos_b(a), want_cos
			])
	assert_eq(failures.size(), 0, "angles off by more than 1: %s" % [failures])


func test_sine_key_angles_are_exact() -> void:
	var one: int = FixedMath.TRIG_ONE
	var q: int = FixedMath.ANGLE_QUARTER
	assert_eq([FixedMath.sin_b(0), FixedMath.sin_b(q), FixedMath.sin_b(2 * q), FixedMath.sin_b(3 * q)],
		[0, one, 0, -one])
	assert_eq([FixedMath.cos_b(0), FixedMath.cos_b(q), FixedMath.cos_b(2 * q), FixedMath.cos_b(3 * q)],
		[one, 0, -one, 0])


func test_angles_wrap_including_negatives() -> void:
	for a: int in [-1, -300, 5, 700]:
		assert_eq(FixedMath.sin_b(a), FixedMath.sin_b(a + FixedMath.ANGLE_FULL), "sin(%d)" % a)
		assert_eq(FixedMath.sin_b(a), FixedMath.sin_b(a - 3 * FixedMath.ANGLE_FULL), "sin(%d)" % a)
		assert_eq(FixedMath.sin_b(-a), -FixedMath.sin_b(a), "sin is odd at %d" % a)
		assert_eq(FixedMath.cos_b(-a), FixedMath.cos_b(a), "cos is even at %d" % a)


func test_normalize_scales_to_length() -> void:
	assert_eq(FixedMath.normalize(0, 0, 1000), Vector2i.ZERO)
	assert_eq(FixedMath.normalize(3, 4, 1000), Vector2i(600, 800))
	assert_eq(FixedMath.normalize(-3, -4, 1000), Vector2i(-600, -800))
	assert_eq(FixedMath.normalize(0, -250_000, 1000), Vector2i(0, -1000))
	# Short vectors keep their direction despite isqrt flooring.
	assert_eq(FixedMath.normalize(1, 1, 1000), Vector2i(707, 707))
	assert_eq(FixedMath.normalize(3, -7, 1000), Vector2i(394, -919))
	var gen: RandomNumberGenerator = RandomNumberGenerator.new()
	gen.seed = 11
	for i: int in 200:
		var v: Vector2i = FixedMath.normalize(
			gen.randi_range(-600_000, 600_000), gen.randi_range(-600_000, 600_000), 1000
		)
		assert_almost_eq(FixedMath.length(v.x, v.y), 1000, 2)


func test_rotate_local_follows_facing() -> void:
	# Facing north (-z): right is east (+x), forward is -z.
	assert_eq(FixedMath.rotate_local(2000, 0, 0, -1000), Vector2i(2000, 0))
	assert_eq(FixedMath.rotate_local(0, 2000, 0, -1000), Vector2i(0, -2000))
	# Facing east (+x): right is south (+z).
	assert_eq(FixedMath.rotate_local(2000, 0, 1000, 0), Vector2i(0, 2000))
	assert_eq(FixedMath.rotate_local(0, 2000, 1000, 0), Vector2i(2000, 0))
	# Rotation keeps length.
	var facing: Vector2i = FixedMath.normalize(3, -7, FixedMath.DIR_ONE)
	var v: Vector2i = FixedMath.rotate_local(3000, 4000, facing.x, facing.y)
	assert_almost_eq(FixedMath.length(v.x, v.y), 5000, 5)
