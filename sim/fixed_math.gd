class_name FixedMath
extends RefCounted
## Integer math helpers for sim code. Results are exact integers, so they are
## identical on every platform.


## Floor of the square root of n, for 0 <= n < 2^62. Negative input returns 0.
static func isqrt(n: int) -> int:
	if n <= 0:
		return 0
	# The float root is only a starting guess. The loops correct it to the
	# exact floor, so the result never depends on float rounding.
	var r: int = int(sqrt(float(n)))
	while r * r > n:
		r -= 1
	while (r + 1) * (r + 1) <= n:
		r += 1
	return r
