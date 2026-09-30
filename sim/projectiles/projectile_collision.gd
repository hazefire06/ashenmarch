class_name ProjectileCollision
extends RefCounted
## Swept contact tests for projectiles, shared by the live flight
## (ProjectileSystem) and the aiming solver's clear-path check (Ballistics),
## so a shot the solver calls clear flies clear.
##
## Contacts are reported as a fraction of the segment in 1/FRACTION_ONE. The
## ground test takes micrometre points (the flight's own precision); the
## body test works in milli-units, where its quadratic terms stay far inside
## 64 bits.

const FRACTION_ONE: int = 65536
## Longest stretch (milli-units) checked against the ground in one piece. A
## 1 m cell can bend the ground by a few cm between checks, so a fast arrow
## can't skip through a thin ridge.
const SWEEP_STEP: int = 250
## Halvings from a bracketing pair of checks to the contact point: 250 mm /
## 2^8 is about 1 mm.
const BISECT_STEPS: int = 8
const NO_CONTACT: int = -1


## First point along the segment a -> b (micrometres) where a ball of radius
## radius_mm touches the ground, as a fraction of the segment; NO_CONTACT if
## it stays clear. A segment starting below ground contacts at 0.
static func ground_contact(
	terrain: Terrain, ax: int, ay: int, az: int, bx: int, by: int, bz: int, radius_mm: int
) -> int:
	# Anything flying above the highest ground around it can't touch it.
	var lowest: int = FlightState.to_mm(mini(ay, by)) - radius_mm
	if lowest > terrain.max_height_in(
		FlightState.to_mm(ax), FlightState.to_mm(az), FlightState.to_mm(bx), FlightState.to_mm(bz)
	):
		return NO_CONTACT
	if _below_ground(terrain, ax, ay, az, radius_mm):
		return 0
	var length_mm: int = FixedMath.isqrt(
		(bx - ax) * (bx - ax) + (by - ay) * (by - ay) + (bz - az) * (bz - az)
	) / FlightState.SUB
	var pieces: int = maxi(1, (length_mm + SWEEP_STEP - 1) / SWEEP_STEP)
	var above: int = 0
	for k: int in range(1, pieces + 1):
		var frac: int = k * FRACTION_ONE / pieces
		if not _below_ground(
			terrain, _lerp(ax, bx, frac), _lerp(ay, by, frac), _lerp(az, bz, frac), radius_mm
		):
			above = frac
			continue
		var below: int = frac
		for _i: int in BISECT_STEPS:
			var mid: int = (above + below) / 2
			if mid == above:
				break
			if _below_ground(terrain, _lerp(ax, bx, mid), _lerp(ay, by, mid), _lerp(az, bz, mid), radius_mm):
				below = mid
			else:
				above = mid
		return below
	return NO_CONTACT


## First point along the segment a -> b (milli-units) where a ball of radius
## ball_r meets an upright cylinder of radius cyl_r around (cx, cz) from
## height y0 to y1, as a fraction of the segment; NO_CONTACT if it misses.
## Starting inside counts as contact at 0.
static func cylinder_contact(
	ax: int, ay: int, az: int, bx: int, by: int, bz: int, ball_r: int,
	cx: int, cz: int, cyl_r: int, y0: int, y1: int
) -> int:
	# Horizontal: |f + t d|^2 <= r^2 on t in [0, 1], f = a - c, d = b - a.
	var r: int = cyl_r + ball_r
	var dx: int = bx - ax
	var dz: int = bz - az
	var fx: int = ax - cx
	var fz: int = az - cz
	var a: int = dx * dx + dz * dz
	var half_b: int = fx * dx + fz * dz
	var c: int = fx * fx + fz * fz - r * r
	var h_lo: int = 0
	var h_hi: int = FRACTION_ONE
	if a == 0:
		if c > 0:
			return NO_CONTACT
	else:
		var disc: int = half_b * half_b - a * c
		if disc < 0:
			return NO_CONTACT
		var root: int = FixedMath.isqrt(disc)
		# The entry fraction rounds up and the exit down, so a graze that
		# rounding would widen is not reported.
		h_lo = maxi(0, _div_ceil((-half_b - root) * FRACTION_ONE, a))
		h_hi = mini(FRACTION_ONE, _div_floor((-half_b + root) * FRACTION_ONE, a))
		if h_lo > h_hi:
			return NO_CONTACT
	# Vertical: y0 - ball_r <= ay + t (by - ay) <= y1 + ball_r.
	var bottom: int = y0 - ball_r
	var top: int = y1 + ball_r
	var v_lo: int = 0
	var v_hi: int = FRACTION_ONE
	var dy: int = by - ay
	if dy == 0:
		if ay < bottom or ay > top:
			return NO_CONTACT
	elif dy > 0:
		# Rising: enters through the bottom, leaves through the top.
		v_lo = maxi(0, _div_ceil((bottom - ay) * FRACTION_ONE, dy))
		v_hi = mini(FRACTION_ONE, _div_floor((top - ay) * FRACTION_ONE, dy))
	else:
		# Falling: enters through the top, leaves through the bottom.
		v_lo = maxi(0, _div_ceil((top - ay) * FRACTION_ONE, dy))
		v_hi = mini(FRACTION_ONE, _div_floor((bottom - ay) * FRACTION_ONE, dy))
	var lo: int = maxi(h_lo, v_lo)
	var hi: int = mini(h_hi, v_hi)
	return lo if lo <= hi else NO_CONTACT


## a + (b - a) * frac / FRACTION_ONE, rounded toward negative infinity.
static func _lerp(a: int, b: int, frac: int) -> int:
	return a + FixedMath.div_floor((b - a) * frac, FRACTION_ONE)


static func _below_ground(terrain: Terrain, x: int, y: int, z: int, radius_mm: int) -> bool:
	var ground: int = terrain.height_at(FlightState.to_mm(x), FlightState.to_mm(z))
	return y - radius_mm * FlightState.SUB < ground * FlightState.SUB


# a / b rounded toward negative infinity, for any signs, b != 0.
static func _div_floor(a: int, b: int) -> int:
	if b < 0:
		return FixedMath.div_floor(-a, -b)
	return FixedMath.div_floor(a, b)


# a / b rounded toward positive infinity, for any signs, b != 0.
static func _div_ceil(a: int, b: int) -> int:
	return -_div_floor(-a, b)
