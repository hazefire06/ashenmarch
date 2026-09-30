extends GutTest
## FixedMath.isqrt must return the exact floor square root for every input.


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
