class_name UnitMovement
extends RefCounted
## Per-tick unit locomotion, run by World.step() between commands and
## integration. Sets each unit's velocity; World._integrate() moves it.
##
## Each tick:
## 1. Solve up to MAX_PATH_SOLVES_PER_TICK queued A* requests, oldest first.
##    The cap is a count, not a time budget, so every peer solves the same
##    requests on the same tick.
## 2. Advance waypoints, detect arrival and being stuck (state changes).
## 3. Steer: every velocity is computed from start-of-tick positions and the
##    states fixed in step 2, so the result doesn't depend on update order.
##
## Steering is a walk toward the next waypoint at the unit's effective speed,
## with any component heading into a nearby body removed (so units slide
## around each other instead of through), plus a separation push that
## resolves overlap that happened anyway. The result is clipped so the unit
## never steps onto a sample its mobility can't stand on. That clip is what
## keeps living units out of depth 3+ water.

const MAX_PATH_SOLVES_PER_TICK: int = 6
## Milli-units within which an intermediate waypoint counts as reached.
const WAYPOINT_RADIUS: int = 500
## Milli-units within which the final waypoint counts as reached.
const ARRIVE_RADIUS: int = 250
## A unit this close to its goal that stops making progress settles there;
## its slot is probably occupied.
const NEAR_GOAL_RADIUS: int = 2000
const SETTLE_NEAR_GOAL_TICKS: int = 30
## Without progress, re-path every REPATH_TICKS and give up at GIVE_UP_TICKS.
const REPATH_TICKS: int = 60
const GIVE_UP_TICKS: int = 180
## Milli-units a unit must gain on its waypoint to count as progress.
const PROGRESS_EPSILON: int = 100
## Spatial hash bucket edge. Must be at least the largest separation distance.
const BUCKET_SIZE: int = 4000
## Extra milli-units kept between bodies.
const SEPARATION_MARGIN: int = 100
## Fraction of overlap resolved per tick, in permille, split between the two.
const SEPARATION_RATE_PERMILLE: int = 250
## An idle unit is pushed by moving ones at this weight, so a unit walking
## past a standing formation goes around it instead of scattering it.
const IDLE_YIELD_PERMILLE: int = 250
const MAX_PUSH_PER_TICK: int = 60
## Climbing never slows a unit below this, in permille.
const MIN_UPHILL_PERMILLE: int = 250
## Speed (mm/s) x water (permille) x slope (permille) per milli-unit per tick.
const STEP_DIVISOR: int = 1000 * 1000 * World.TICK_RATE

## Ids of units waiting for an A* solve, oldest first. May hold stale ids
## (units re-ordered or stopped since); those are skipped.
var _path_queue: Array[int] = []


## Sends the unit to (x, z), to face (face_x, face_z) on arrival, no faster
## than speed_cap mm/s (0 for no cap). Walks straight there if nothing is in
## the way; otherwise queues an A* solve. Ignored for dead units.
func order_move(
	world: World, unit: Unit, x: int, z: int, face_x: int, face_z: int, cap: int
) -> void:
	if not unit.is_alive():
		return
	unit.clear_order()
	unit.goal_x = x
	unit.goal_z = z
	var facing: Vector2i = FixedMath.normalize(face_x, face_z, FixedMath.DIR_ONE)
	if facing != Vector2i.ZERO:
		unit.goal_facing_x = facing.x
		unit.goal_facing_z = facing.y
	unit.speed_cap = cap
	unit.transition_to(Unit.State.MOVING)
	if world.pathing.can_walk_straight(unit.x, unit.z, x, z, unit.type.mobility):
		_set_path(unit, PackedInt64Array([x, z]))
	else:
		_request_path(unit)


## Halts the unit where it stands.
func order_stop(unit: Unit) -> void:
	if not unit.is_alive():
		return
	unit.clear_order()
	unit.goal_x = unit.x
	unit.goal_z = unit.z
	unit.transition_to(Unit.State.IDLE)


func update(world: World) -> void:
	_solve_paths(world)
	for unit: Unit in world.units:
		if unit.state == Unit.State.MOVING:
			_advance(unit)
	var buckets: Dictionary[int, Array] = _bucket(world.units)
	for unit: Unit in world.units:
		_steer(world, unit, buckets)


## The path queue, for World.state_hash().
func hash_fields() -> PackedInt64Array:
	var fields: PackedInt64Array = PackedInt64Array([_path_queue.size()])
	fields.append_array(PackedInt64Array(_path_queue))
	return fields


## Pending A* requests, for tests and the HUD.
func queued_paths() -> int:
	return _path_queue.size()


func _request_path(unit: Unit) -> void:
	unit.path = PackedInt64Array()
	unit.path_index = 0
	if not unit.path_pending:
		unit.path_pending = true
		_path_queue.append(unit.id)


func _set_path(unit: Unit, path: PackedInt64Array) -> void:
	unit.path = path
	unit.path_index = 0
	unit.path_pending = false
	unit.goal_x = path[path.size() - 2]
	unit.goal_z = path[path.size() - 1]
	unit.best_waypoint_distance = FixedMath.length(unit.waypoint_x() - unit.x, unit.waypoint_z() - unit.z)


func _solve_paths(world: World) -> void:
	var solved: int = 0
	while solved < MAX_PATH_SOLVES_PER_TICK and not _path_queue.is_empty():
		var unit: Unit = world.get_unit(_path_queue.pop_front())
		if unit == null or not unit.is_alive() or not unit.path_pending:
			continue
		solved += 1
		var path: PackedInt64Array = world.pathing.find_path(
			unit.x, unit.z, unit.goal_x, unit.goal_z, unit.type.mobility
		)
		if path.is_empty():
			unit.path_pending = false
			_settle(unit, false)
		else:
			_set_path(unit, path)


# Waypoint advance, arrival, and stuck handling for a MOVING unit.
func _advance(unit: Unit) -> void:
	if unit.path_pending:
		return
	if not unit.has_path():
		_settle(unit, false)
		return
	while not unit.is_last_waypoint() and _waypoint_distance(unit) <= WAYPOINT_RADIUS:
		unit.path_index += 1
		unit.best_waypoint_distance = _waypoint_distance(unit)
		unit.stuck_ticks = 0
	var d: int = _waypoint_distance(unit)
	if unit.is_last_waypoint() and d <= ARRIVE_RADIUS:
		_settle(unit, true)
		return
	if d + PROGRESS_EPSILON <= unit.best_waypoint_distance:
		unit.best_waypoint_distance = d
		unit.stuck_ticks = 0
		return
	unit.stuck_ticks += 1
	var to_goal: int = FixedMath.length(unit.goal_x - unit.x, unit.goal_z - unit.z)
	if unit.stuck_ticks >= SETTLE_NEAR_GOAL_TICKS and to_goal <= NEAR_GOAL_RADIUS:
		_settle(unit, true)
	elif unit.stuck_ticks >= GIVE_UP_TICKS:
		_settle(unit, false)
	elif unit.stuck_ticks % REPATH_TICKS == 0:
		_request_path(unit)


# Ends the order: IDLE, optionally turning to the order's facing.
func _settle(unit: Unit, face_goal: bool) -> void:
	unit.clear_order()
	unit.transition_to(Unit.State.IDLE)
	if face_goal:
		unit.facing_x = unit.goal_facing_x
		unit.facing_z = unit.goal_facing_z


func _steer(world: World, unit: Unit, buckets: Dictionary[int, Array]) -> void:
	if not unit.is_alive():
		unit.vx = 0
		unit.vy = 0
		unit.vz = 0
		return
	var near: Array[Unit] = _neighbors(world.units, unit, buckets)
	var vx: int = 0
	var vz: int = 0
	if unit.state == Unit.State.MOVING and not unit.path_pending and unit.has_path():
		var dx: int = unit.waypoint_x() - unit.x
		var dz: int = unit.waypoint_z() - unit.z
		var d: int = FixedMath.length(dx, dz)
		if d > 0:
			var dir: Vector2i = FixedMath.normalize(dx, dz, FixedMath.DIR_ONE)
			var travel: int = mini(_step_length(world.terrain, unit, dir), d)
			var v: Vector2i = _avoid(unit, Vector2i(
				FixedMath.div_round(dir.x * travel, FixedMath.DIR_ONE),
				FixedMath.div_round(dir.y * travel, FixedMath.DIR_ONE)
			), near)
			vx = v.x
			vz = v.y
			unit.facing_x = dir.x
			unit.facing_z = dir.y
	var push: Vector2i = _separation(unit, near)
	vx += push.x
	vz += push.y
	var terrain: Terrain = world.terrain
	var mobility: Terrain.Mobility = unit.type.mobility
	if (vx != 0 or vz != 0) and not terrain.is_passable(unit.x + vx, unit.z + vz, mobility):
		# Slide along whichever axis is still open.
		if vx != 0 and terrain.is_passable(unit.x + vx, unit.z, mobility):
			vz = 0
		elif vz != 0 and terrain.is_passable(unit.x, unit.z + vz, mobility):
			vx = 0
		else:
			vx = 0
			vz = 0
	unit.vx = vx
	unit.vz = vz
	unit.vy = terrain.height_at(unit.x + vx, unit.z + vz) - unit.y


# Milli-units this unit walks this tick heading along dir: base speed (capped
# by the order), times the water-depth multiplier, times the uphill factor.
# The integer remainder carries to the next tick in move_carry.
func _step_length(terrain: Terrain, unit: Unit, dir: Vector2i) -> int:
	var speed: int = unit.type.move_speed
	if unit.speed_cap > 0:
		speed = mini(speed, unit.speed_cap)
	var water: int = unit.type.water_speed_permille[terrain.water_depth_at(unit.x, unit.z)]
	var gradient: Vector2i = terrain.gradient_at(unit.x, unit.z)
	# Grade along the heading in permille; positive is uphill.
	var grade: int = FixedMath.div_floor(gradient.x * dir.x + gradient.y * dir.y, FixedMath.DIR_ONE)
	var slope: int = 1000
	if grade > 0:
		slope = maxi(MIN_UPHILL_PERMILLE, 1000 - grade * unit.type.uphill_slowdown_permille / 1000)
	var total: int = speed * water * slope + unit.move_carry
	unit.move_carry = total % STEP_DIVISOR
	return total / STEP_DIVISOR


# Living units other than this one whose bodies could touch it this tick,
# in a fixed order (bucket scan order, then id order within a bucket).
func _neighbors(units: Array[Unit], unit: Unit, buckets: Dictionary[int, Array]) -> Array[Unit]:
	var near: Array[Unit] = []
	var bi: int = FixedMath.div_floor(unit.x, BUCKET_SIZE)
	var bj: int = FixedMath.div_floor(unit.z, BUCKET_SIZE)
	for dj: int in range(-1, 2):
		for di: int in range(-1, 2):
			var key: int = _bucket_key(bi + di, bj + dj)
			if not buckets.has(key):
				continue
			for index: int in buckets[key]:
				var other: Unit = units[index]
				if other != unit and other.is_alive():
					near.append(other)
	return near


# Removes the part of velocity v that heads into a body it would touch this
# tick, so the unit slides along it. Head-on, where little velocity is left
# after that, it sidesteps to its right (so two units meeting head-on pass
# each other, both keeping right). Never faster than v was.
func _avoid(unit: Unit, v: Vector2i, near: Array[Unit]) -> Vector2i:
	var speed: int = FixedMath.length(v.x, v.y)
	var vx: int = v.x
	var vz: int = v.y
	for other: Unit in near:
		var dx: int = other.x - unit.x
		var dz: int = other.z - unit.z
		var reach: int = unit.type.body_radius + other.type.body_radius + SEPARATION_MARGIN + speed
		if absi(dx) >= reach or absi(dz) >= reach or dx * dx + dz * dz >= reach * reach:
			continue
		var n: Vector2i = FixedMath.normalize(dx, dz, FixedMath.DIR_ONE)
		if n == Vector2i.ZERO:
			continue
		var approach: int = FixedMath.div_round(vx * n.x + vz * n.y, FixedMath.DIR_ONE)
		if approach <= 0:
			continue
		vx -= FixedMath.div_round(n.x * approach, FixedMath.DIR_ONE)
		vz -= FixedMath.div_round(n.y * approach, FixedMath.DIR_ONE)
		if FixedMath.length(vx, vz) * 2 < approach:
			# Right of the direction to the other body: (-n.z, n.x).
			vx += FixedMath.div_round(-n.y * approach, 2 * FixedMath.DIR_ONE)
			vz += FixedMath.div_round(n.x * approach, 2 * FixedMath.DIR_ONE)
	var new_speed: int = FixedMath.length(vx, vz)
	if new_speed > speed:
		vx = FixedMath.div_round(vx * speed, new_speed)
		vz = FixedMath.div_round(vz * speed, new_speed)
	return Vector2i(vx, vz)


# Push away from every neighbor this unit overlaps, each pair resolving
# SEPARATION_RATE_PERMILLE of its overlap per tick.
func _separation(unit: Unit, near: Array[Unit]) -> Vector2i:
	var px: int = 0
	var pz: int = 0
	for other: Unit in near:
		var dx: int = unit.x - other.x
		var dz: int = unit.z - other.z
		var min_d: int = unit.type.body_radius + other.type.body_radius + SEPARATION_MARGIN
		if absi(dx) >= min_d or absi(dz) >= min_d or dx * dx + dz * dz >= min_d * min_d:
			continue
		var d: int = FixedMath.length(dx, dz)
		var dir: Vector2i = FixedMath.normalize(dx, dz, FixedMath.DIR_ONE)
		if dir == Vector2i.ZERO:
			dir = _tie_break_direction(unit.id, other.id)
		var weight: int = 1000
		if unit.state != Unit.State.MOVING and other.state == Unit.State.MOVING:
			weight = IDLE_YIELD_PERMILLE
		var magnitude: int = (min_d - d) * SEPARATION_RATE_PERMILLE * weight / 2_000_000
		px += FixedMath.div_round(dir.x * magnitude, FixedMath.DIR_ONE)
		pz += FixedMath.div_round(dir.y * magnitude, FixedMath.DIR_ONE)
	var push_length: int = FixedMath.length(px, pz)
	if push_length > MAX_PUSH_PER_TICK:
		px = FixedMath.div_round(px * MAX_PUSH_PER_TICK, push_length)
		pz = FixedMath.div_round(pz * MAX_PUSH_PER_TICK, push_length)
	return Vector2i(px, pz)


# Two units exactly on top of each other have no direction apart. Derive one
# from their ids: opposite for the two, the same on every peer.
static func _tie_break_direction(unit_id: int, other_id: int) -> Vector2i:
	var low: int = mini(unit_id, other_id)
	var high: int = maxi(unit_id, other_id)
	var angle: int = (low * 97 + high * 31) % FixedMath.ANGLE_FULL
	var dir: Vector2i = Vector2i(
		FixedMath.sin_b(angle) * FixedMath.DIR_ONE / FixedMath.TRIG_ONE,
		FixedMath.cos_b(angle) * FixedMath.DIR_ONE / FixedMath.TRIG_ONE
	)
	return dir if unit_id < other_id else -dir


func _bucket(units: Array[Unit]) -> Dictionary[int, Array]:
	var buckets: Dictionary[int, Array] = {}
	for index: int in units.size():
		var unit: Unit = units[index]
		if not unit.is_alive():
			continue
		var key: int = _bucket_key(
			FixedMath.div_floor(unit.x, BUCKET_SIZE), FixedMath.div_floor(unit.z, BUCKET_SIZE)
		)
		if not buckets.has(key):
			buckets[key] = []
		buckets[key].append(index)
	return buckets


static func _bucket_key(bi: int, bj: int) -> int:
	return bi * 65536 + bj


static func _waypoint_distance(unit: Unit) -> int:
	return FixedMath.length(unit.waypoint_x() - unit.x, unit.waypoint_z() - unit.z)
