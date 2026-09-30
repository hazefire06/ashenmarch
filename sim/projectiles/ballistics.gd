class_name Ballistics
extends RefCounted
## Aiming: the launch velocity that sends a projectile through a target
## point, found by flying the real integrator (FlightState.advance), so the
## aim and the flight agree to the micrometre. Everything is integer.
##
## A launch is a direction and a speed. The direction is the horizontal
## bearing to the target plus a grade t = tan(elevation) in 1/T_ONE, so no
## trig is needed: v = speed * (h, t) / sqrt(1 + t^2).
##
## Two ways to solve, one per UnitType.AimStyle:
## - DIRECT (archers): full speed, find the grade. Of the two arcs that reach
##   a point, the flatter one.
## - LOB (throwers): fixed grade, find the speed, up to the unit's maximum.
##   A lob comes down steeply and stays near where it lands; a full-speed
##   flat throw would skip far past the target.
## Callers try the unit's own style, then the other if it fails or its path
## isn't clear (is_clear).
##
## Both are a bracketed root-find (Illinois) on "how far above the target
## does the flight pass", seeded by the exact no-drag answer. Drag and the
## discrete step only ever shorten a flight, so no no-drag solution means no
## solution at all: a free early out for anything out of reach.
##
## perturb() spreads a solved launch into the unit's aim cone with exactly
## two RNG draws.

const T_ONE: int = 65536
## Horizontal bearings are unit vectors of this length. 1000 would put up to
## 5 cm of sideways error on a 50 m shot.
const H_ONE: int = 65536
## Perpendicular unit vectors in perturb().
const P_ONE: int = 65536
## Flights longer than this (10 s) are treated as never arriving.
const MAX_FLIGHT_TICKS: int = 300
## A falling flight this far (um) below the target has missed it.
const GIVE_UP_BELOW: int = 30_000_000
## Micrometres: close enough to stop refining.
const AIM_TOLERANCE: int = 5_000
## Micrometres: the best launch found must pass at least this close. Only
## shots at the very edge of reach end up between this and AIM_TOLERANCE.
const AIM_REJECT: int = 100_000
## Flights per solve, including the bracket search.
const MAX_FLIGHTS: int = 16
## Steepest grades a direct shot considers, up and down: about 76 degrees
## (a unit on a cliff edge can shoot at the foot of it).
const MAX_GRADE: int = 4 * T_ONE
const MIN_GRADE: int = -MAX_GRADE
## Targets closer than this (um, horizontal) have no bearing to aim along.
const MIN_REACH: int = 100_000
## Targets farther than this (um, horizontal: 1 km) are never solved; it
## keeps the no-drag guess inside 64 bits.
const MAX_REACH: int = 1_000_000_000
## The clear-path check forgives ground contact this close (um) to the
## target distance: that is the shot landing, not an obstacle.
const CLEAR_MARGIN: int = 1_000_000
## Miss reported for a flight that never reached the target distance.
const SHORT: int = -(1 << 40)
## g as the ratio 109/10 milli-units per tick^2, for the no-drag guess.
const G_NUM: int = 109
const G_DEN: int = 10

# Evaluation results: [reached (0/1), height at the target distance (um),
# ticks, vx, vy, vz].
const _REACHED: int = 0
const _Y: int = 1
const _TICKS: int = 2


## Solves with the given style; see solve_direct() and solve_lob().
static func solve(
	style: UnitType.AimStyle, from: FlightState, tx: int, ty: int, tz: int,
	max_speed: int, lob_grade_permille: int, drag: int
) -> AimSolution:
	if style == UnitType.AimStyle.LOB:
		return solve_lob(from, tx, ty, tz, lob_grade_permille, max_speed, drag)
	return solve_direct(from, tx, ty, tz, max_speed, drag)


## The flattest launch at max_speed (um/tick) from the launch point (from's
## position, um) through (tx, ty, tz) (um).
static func solve_direct(
	from: FlightState, tx: int, ty: int, tz: int, max_speed: int, drag: int
) -> AimSolution:
	var dx: int = tx - from.px
	var dz: int = tz - from.pz
	var reach: int = FixedMath.isqrt(dx * dx + dz * dz)
	if reach < MIN_REACH or reach > MAX_REACH or max_speed <= 0:
		return AimSolution.failed()
	var hx: int = FixedMath.div_round(dx * H_ONE, reach)
	var hz: int = FixedMath.div_round(dz * H_ONE, reach)
	var bounds: PackedInt64Array = _direct_guess(reach, ty - from.py, max_speed)
	if bounds.is_empty():
		return AimSolution.failed()
	var peak: int = clampi(bounds[1], MIN_GRADE, MAX_GRADE)
	var guess: int = clampi(bounds[0], MIN_GRADE, peak)
	var flight: Callable = func(grade: int) -> PackedInt64Array:
		var v: PackedInt64Array = launch_velocity(grade, max_speed, hx, hz)
		return _fly_to_reach(from, v, hx, hz, reach, drag, ty - GIVE_UP_BELOW)
	return _root(flight, guess, T_ONE / 64, MIN_GRADE, peak, ty)


## The launch at a fixed grade (lob_grade_permille, rise per 1000 of run)
## and the lowest speed up to max_speed that passes through the target.
static func solve_lob(
	from: FlightState, tx: int, ty: int, tz: int, lob_grade_permille: int, max_speed: int, drag: int
) -> AimSolution:
	var dx: int = tx - from.px
	var dz: int = tz - from.pz
	var reach: int = FixedMath.isqrt(dx * dx + dz * dz)
	if reach < MIN_REACH or reach > MAX_REACH or max_speed <= 0 or lob_grade_permille <= 0:
		return AimSolution.failed()
	var hx: int = FixedMath.div_round(dx * H_ONE, reach)
	var hz: int = FixedMath.div_round(dz * H_ONE, reach)
	var grade: int = lob_grade_permille * T_ONE / 1000
	var guess: int = _lob_guess(reach, ty - from.py, grade)
	if guess <= 0:
		return AimSolution.failed()
	guess = mini(guess, max_speed)
	var flight: Callable = func(speed: int) -> PackedInt64Array:
		var v: PackedInt64Array = launch_velocity(grade, speed, hx, hz)
		return _fly_to_reach(from, v, hx, hz, reach, drag, ty - GIVE_UP_BELOW)
	return _root(flight, guess, maxi(guess / 16, 1000), 1, max_speed, ty)


## Launch velocity (um/tick) at a grade (tan of elevation, 1/T_ONE) and
## speed along a horizontal bearing (hx, hz) of length H_ONE.
static func launch_velocity(grade: int, speed: int, hx: int, hz: int) -> PackedInt64Array:
	var norm: int = FixedMath.isqrt(T_ONE * T_ONE + grade * grade)
	var horizontal: int = FixedMath.div_round(speed * T_ONE, norm)
	return PackedInt64Array([
		FixedMath.div_round(horizontal * hx, H_ONE),
		FixedMath.div_round(speed * grade, norm),
		FixedMath.div_round(horizontal * hz, H_ONE),
	])


## Spreads a launch velocity into a cone of half-width spread_permille
## (tan x 1000), uniformly over the cone's cross-section, keeping its speed.
## Always draws exactly twice from rng (a bearing, then a radius), even
## with no spread, so the RNG stream doesn't depend on unit stats.
static func perturb(
	vx: int, vy: int, vz: int, spread_permille: int, rng: RandomNumberGenerator
) -> PackedInt64Array:
	var bearing: int = rng.randi_range(0, FixedMath.ANGLE_FULL - 1)
	var u: int = rng.randi_range(0, 1_000_000)
	# sqrt of a uniform draw: uniform over the disc, not bunched at its center.
	var r: int = spread_permille * FixedMath.isqrt(u) / 1000
	var speed: int = FixedMath.isqrt(vx * vx + vy * vy + vz * vz)
	if r == 0 or speed == 0:
		return PackedInt64Array([vx, vy, vz])
	var horizontal: int = FixedMath.isqrt(vx * vx + vz * vz)
	# Two unit vectors square to v: one level (sideways), one in the plane of
	# v and the vertical (up and down).
	var ax: int = P_ONE
	var az: int = 0
	var bx: int = 0
	var by: int = 0
	var bz: int = P_ONE
	if horizontal > 0:
		ax = FixedMath.div_round(-vz * P_ONE, horizontal)
		az = FixedMath.div_round(vx * P_ONE, horizontal)
		bx = FixedMath.div_round(FixedMath.div_round(vx * vy, horizontal) * P_ONE, speed)
		by = -FixedMath.div_round(horizontal * P_ONE, speed)
		bz = FixedMath.div_round(FixedMath.div_round(vz * vy, horizontal) * P_ONE, speed)
	var c: int = FixedMath.cos_b(bearing)
	var s: int = FixedMath.sin_b(bearing)
	var ox: int = FixedMath.div_round(c * ax + s * bx, FixedMath.TRIG_ONE)
	var oy: int = FixedMath.div_round(s * by, FixedMath.TRIG_ONE)
	var oz: int = FixedMath.div_round(c * az + s * bz, FixedMath.TRIG_ONE)
	var scale: int = 1000 * P_ONE
	var nx: int = vx + FixedMath.div_round(speed * r * ox, scale)
	var ny: int = vy + FixedMath.div_round(speed * r * oy, scale)
	var nz: int = vz + FixedMath.div_round(speed * r * oz, scale)
	var new_speed: int = FixedMath.isqrt(nx * nx + ny * ny + nz * nz)
	return PackedInt64Array([
		FixedMath.div_round(nx * speed, new_speed),
		FixedMath.div_round(ny * speed, new_speed),
		FixedMath.div_round(nz * speed, new_speed),
	])


## Re-flies a solved launch from `from` and checks nothing is in its way
## before it reaches the target distance: no ground (beyond CLEAR_MARGIN
## short of the target, which is just the landing) and, if avoid is not
## empty, none of those units' bodies. `radius_mm` is the projectile's.
static func is_clear(
	terrain: Terrain, from: FlightState, solution: AimSolution, tx: int, tz: int,
	radius_mm: int, drag: int, avoid: Array[Unit]
) -> bool:
	var dx: int = tx - from.px
	var dz: int = tz - from.pz
	var reach: int = FixedMath.isqrt(dx * dx + dz * dz)
	if reach == 0:
		return true
	var hx: int = FixedMath.div_round(dx * H_ONE, reach)
	var hz: int = FixedMath.div_round(dz * H_ONE, reach)
	var f: FlightState = FlightState.new(from.px, from.py, from.pz, solution.vx, solution.vy, solution.vz)
	var before_u: int = 0
	for _n: int in solution.ticks:
		var ax: int = f.px
		var ay: int = f.py
		var az: int = f.pz
		f.advance(drag)
		var u: int = ((f.px - from.px) * hx + (f.pz - from.pz) * hz) / H_ONE
		var frac: int = ProjectileCollision.ground_contact(terrain, ax, ay, az, f.px, f.py, f.pz, radius_mm)
		if frac != ProjectileCollision.NO_CONTACT:
			var at: int = before_u + (u - before_u) * frac / ProjectileCollision.FRACTION_ONE
			return at >= reach - CLEAR_MARGIN
		for unit: Unit in avoid:
			if _crosses(unit, ax, ay, az, f, radius_mm):
				return false
		before_u = u
	return true


## Units in `units` whose bodies could stand in the path from the launch
## point to (tx, tz): every living one on `side` other than `except`, inside
## the box around the two points grown by `margin` milli-units.
static func bodies_near_path(
	units: Array[Unit], side: UnitType.Faction, except: Unit,
	from: FlightState, tx: int, tz: int, margin: int
) -> Array[Unit]:
	var x0: int = mini(FlightState.to_mm(from.px), FlightState.to_mm(tx)) - margin
	var x1: int = maxi(FlightState.to_mm(from.px), FlightState.to_mm(tx)) + margin
	var z0: int = mini(FlightState.to_mm(from.pz), FlightState.to_mm(tz)) - margin
	var z1: int = maxi(FlightState.to_mm(from.pz), FlightState.to_mm(tz)) + margin
	var out: Array[Unit] = []
	for unit: Unit in units:
		if unit == except or not unit.is_alive() or unit.faction != side:
			continue
		if unit.x >= x0 and unit.x <= x1 and unit.z >= z0 and unit.z <= z1:
			out.append(unit)
	return out


static func _crosses(unit: Unit, ax: int, ay: int, az: int, f: FlightState, radius_mm: int) -> bool:
	return ProjectileCollision.cylinder_contact(
		FlightState.to_mm(ax), FlightState.to_mm(ay), FlightState.to_mm(az),
		FlightState.to_mm(f.px), FlightState.to_mm(f.py), FlightState.to_mm(f.pz), radius_mm,
		unit.x, unit.z, unit.type.body_radius, unit.y, unit.y + unit.type.body_height
	) != ProjectileCollision.NO_CONTACT


# Flies launch velocity v from `from` until it has gone `reach` (um) along
# the bearing (hx, hz). Returns [reached, y at reach, ticks, vx, vy, vz],
# with y interpolated between the ticks either side of reach.
static func _fly_to_reach(
	from: FlightState, v: PackedInt64Array, hx: int, hz: int, reach: int, drag: int, floor_y: int
) -> PackedInt64Array:
	var f: FlightState = FlightState.new(from.px, from.py, from.pz, v[0], v[1], v[2])
	var before_u: int = 0
	var before_y: int = f.py
	for n: int in range(1, MAX_FLIGHT_TICKS + 1):
		f.advance(drag)
		var u: int = ((f.px - from.px) * hx + (f.pz - from.pz) * hz) / H_ONE
		if u >= reach:
			var y: int = before_y + FixedMath.div_round((f.py - before_y) * (reach - before_u), u - before_u)
			return PackedInt64Array([1, y, n, v[0], v[1], v[2]])
		if u <= before_u or (f.vy < 0 and f.py < floor_y):
			break
		before_u = u
		before_y = f.py
	return PackedInt64Array([0, 0, 0, v[0], v[1], v[2]])


# No-drag low-arc grade for reach and rise (um) at speed (um/tick), and the
# grade of the longest no-drag reach, as [guess, peak] in 1/T_ONE; empty if
# the target is out of no-drag reach, and so out of reach. Worked in
# milli-units with g = 109/10 mm/tick^2: a T^2 - R T + (a + h) = 0 with
# a = g R^2 / (2 v^2), T = tan(elevation).
static func _direct_guess(reach: int, rise: int, speed: int) -> PackedInt64Array:
	var r: int = reach / FlightState.SUB
	var h: int = FixedMath.div_round(rise, FlightState.SUB)
	if r <= 0:
		return PackedInt64Array()
	# a = G_NUM * r^2 * SUB^2 / (2 * G_DEN * speed^2), staged to stay small.
	var a: int = FixedMath.div_round(
		FixedMath.div_round(G_NUM * r * FlightState.SUB, speed) * r * FlightState.SUB,
		2 * G_DEN * speed
	)
	if a <= 0:
		# Too fast for gravity to matter over this distance: aim straight.
		var straight: int = FixedMath.div_round(h * T_ONE, r)
		return PackedInt64Array([straight, MAX_GRADE])
	if a > 2 * r + 2 * absi(h):
		# 4a(a + h) > r^2 for sure: no real root. Also keeps it in range.
		return PackedInt64Array()
	var disc: int = r * r - 4 * a * (a + h)
	if disc < 0:
		return PackedInt64Array()
	var low: int = FixedMath.div_round((r - FixedMath.isqrt(disc)) * T_ONE, 2 * a)
	var peak: int = FixedMath.div_round(r * T_ONE, 2 * a)
	return PackedInt64Array([low, peak])


# No-drag launch speed (um/tick) at grade (1/T_ONE) through a point reach
# away and rise above, or 0 if the grade passes below it:
# v^2 = g R^2 (1 + t^2) / (2 (R t - h)), in milli-units.
static func _lob_guess(reach: int, rise: int, grade: int) -> int:
	var r: int = reach / FlightState.SUB
	var h: int = FixedMath.div_round(rise, FlightState.SUB)
	var q: int = FixedMath.div_round(r * grade, T_ONE) - h
	if q <= 0 or r <= 0:
		return 0
	var a: int = FixedMath.div_round(G_NUM * r * r, 2 * G_DEN * q)
	# a * (1 + t^2), staged so a * t^2 can't overflow for a near-flat lob.
	var v2: int = a + FixedMath.div_round(FixedMath.div_round(a * grade, T_ONE) * grade, T_ONE)
	return FixedMath.isqrt(v2) * FlightState.SUB


# Bracketed root-find for the x (a grade or a speed) whose flight passes
# through target_y, on a flight function where a larger x passes higher.
# Starts at guess, walks out by doubling steps within [x_min, x_max] until
# the target is bracketed, then refines by Illinois false position.
static func _root(
	flight: Callable, guess: int, step: int, x_min: int, x_max: int, target_y: int
) -> AimSolution:
	var flights: int = 1
	var at_guess: PackedInt64Array = flight.call(guess)
	var best: PackedInt64Array = at_guess
	var best_miss: int = _miss(at_guess, target_y)
	if absi(best_miss) <= AIM_TOLERANCE:
		return _solution(best, best_miss)
	# Walk out from the guess, toward higher x if it passes low and lower x
	# if it passes high, until the miss changes sign.
	var lo: int = guess
	var hi: int = guess
	var miss_lo: int = best_miss
	var miss_hi: int = best_miss
	var direction: int = 1 if best_miss < 0 else -1
	var x: int = guess
	var stride: int = step
	while true:
		if (direction > 0 and x >= x_max) or (direction < 0 and x <= x_min) or flights >= MAX_FLIGHTS:
			return _solution(best, best_miss) if absi(best_miss) <= AIM_REJECT else AimSolution.failed()
		x = clampi(x + direction * stride, x_min, x_max)
		stride *= 2
		var result: PackedInt64Array = flight.call(x)
		flights += 1
		var miss: int = _miss(result, target_y)
		if absi(miss) < absi(best_miss):
			best = result
			best_miss = miss
		if (miss < 0) == (direction > 0):
			# Still on the same side: this is the new near end.
			if direction > 0:
				lo = x
				miss_lo = miss
			else:
				hi = x
				miss_hi = miss
			continue
		if direction > 0:
			hi = x
			miss_hi = miss
		else:
			lo = x
			miss_lo = miss
		break
	# Illinois: false position that halves the stale end's weight when the
	# same end moves twice, so it can't stall.
	var side: int = 0
	while flights < MAX_FLIGHTS and absi(best_miss) > AIM_TOLERANCE and hi - lo > 1:
		var mid: int
		if miss_lo == SHORT or miss_hi == SHORT:
			mid = lo + (hi - lo) / 2
		else:
			mid = lo + FixedMath.div_round((hi - lo) * -miss_lo, miss_hi - miss_lo)
		mid = clampi(mid, lo + 1, hi - 1)
		var result: PackedInt64Array = flight.call(mid)
		flights += 1
		var miss: int = _miss(result, target_y)
		if absi(miss) < absi(best_miss):
			best = result
			best_miss = miss
		if miss < 0:
			lo = mid
			miss_lo = miss
			if side < 0 and miss_hi != SHORT:
				miss_hi /= 2
			side = -1
		else:
			hi = mid
			miss_hi = miss
			if side > 0 and miss_lo != SHORT:
				miss_lo /= 2
			side = 1
	if absi(best_miss) > AIM_REJECT:
		return AimSolution.failed()
	return _solution(best, best_miss)


static func _miss(result: PackedInt64Array, target_y: int) -> int:
	return result[_Y] - target_y if result[_REACHED] == 1 else SHORT


static func _solution(result: PackedInt64Array, miss: int) -> AimSolution:
	var s: AimSolution = AimSolution.new()
	s.ok = result[_REACHED] == 1
	s.vx = result[3]
	s.vy = result[4]
	s.vz = result[5]
	s.ticks = result[_TICKS]
	s.miss = miss
	return s
