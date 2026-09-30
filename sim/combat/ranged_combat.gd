class_name RangedCombat
extends RefCounted
## Per-tick ranged fighting, run by World.step() after MeleeCombat and
## before movement, so a unit melee took over this tick is left alone and a
## unit that stops to shoot doesn't walk. Stats come from each UnitType.
##
## Two passes, like melee:
## 1. Decide, in ascending id order. Each unit updates only itself: picks or
##    keeps a target, stands and faces it (state SHOOTING), draws, or walks
##    toward a ground target. It reads other units' positions, which nothing
##    changes before movement, so the order can't matter.
## 2. Loose, in ascending id order: every draw that finishes this tick is
##    re-aimed at where its target will be (leading a walker by the flight
##    time), spread by the aim cone, and launched. RNG per launch, from
##    World.rng: the two spread draws, then a fuse draw for a fused
##    projectile.
##
## Who shoots:
## - Not a unit melee owns (target_id set: engaged or chasing), not one
##   reeling from a blast, not one on a MOVE order, not one out of ammo.
## - Order NONE (holding) or ATTACK_MOVE: any visible enemy whose horizontal
##   distance is within [ranged_min_range, effective max range]. Ranked like
##   melee targets (Targeting), re-picked every RETARGET_TICKS (staggered by
##   id) or as soon as the target is gone. A target counts only if a launch
##   reaches it (Ballistics) along a path clear of the ground and of friendly
##   bodies. Throwers also skip a target with a friend (themselves included)
##   within the blast of where it would land, and archers one locked in
##   melee with a friend (within ARROW_FRIEND_MARGIN): an arrow a hand off
##   target would hit the friend. An attack-mover stops to shoot and marches
##   on when there is nothing left in range.
## - Order GROUND_ATTACK: the spot, again and again, until another order. Out
##   of reach, the unit walks toward it, looking again every
##   GROUND_RECHECK_TICKS. Friendly bodies in the way don't stop it: the
##   player chose the spot. If it gets there, or stops walking, and still
##   can't reach it, or the spot is inside its minimum range, it gives up
##   (CANT_REACH) and holds.
##
## Range: ranged_max_range on level ground, shortened uphill by
## uphill_range_permille. Aim: the unit's own AimStyle first, then the other
## if that fails or its path isn't clear. Arrows aim at the chest, throws at
## the feet.

## Ticks between target re-picks for a unit that has one.
const RETARGET_TICKS: int = 6
## Ticks between reach checks while walking toward a ground target.
const GROUND_RECHECK_TICKS: int = 10
## Most candidate targets a unit tries to aim at per re-pick, nearest first.
## Aiming flies the trajectory; this bounds the cost.
const MAX_AIM_TRIES: int = 3
## Throwers keep friends at least this far (milli-units) beyond the blast.
const FRIENDLY_BLAST_MARGIN: int = 1000
## Archers don't pick an enemy with a friend's body this close (milli-units,
## edge to edge): one locked in melee with it.
const ARROW_FRIEND_MARGIN: int = 1000
## Friendly bodies this far (milli-units) beyond their own radius from the
## line to the target count as possibly in the way: the projectile's radius
## and rounding, with room to spare.
const PATH_MARGIN: int = 200
## Arrows aim this far up the target's body, permille.
const CHEST_PERMILLE: int = 600
## Ticks a launched projectile passes through its launcher.
const LAUNCH_IGNORE_TICKS: int = ProjectileSystem.LAUNCH_IGNORE_TICKS
const PERMILLE: int = 1000


func update(world: World) -> void:
	if world.catalog == null:
		return
	var loosing: Array[Unit] = []
	for unit: Unit in world.units:
		if unit.is_alive() and unit.type.has_ranged() and _decide(world, unit):
			loosing.append(unit)
	for unit: Unit in loosing:
		_loose(world, unit)


## Longest horizontal distance (milli-units) unit may shoot at a point rise
## milli-units above its launch point, dist away: the level-ground range,
## shortened uphill.
static func effective_max_range(unit: Unit, rise: int, dist: int) -> int:
	var t: UnitType = unit.type
	if rise <= 0 or dist <= 0 or t.uphill_range_permille == 0:
		return t.ranged_max_range
	var grade: int = rise * PERMILLE / dist
	return t.ranged_max_range * PERMILLE / (PERMILLE + grade * t.uphill_range_permille / PERMILLE)


## Aim cone half-width (tan x 1000) for a shot rise milli-units up over dist:
## veterancy narrows it, shooting uphill widens it.
static func spread_for(unit: Unit, rise: int, dist: int) -> int:
	var spread: int = Veterancy.ranged_spread(unit)
	if rise <= 0 or dist <= 0:
		return spread
	var grade: int = rise * PERMILLE / dist
	return spread * (PERMILLE + grade * unit.type.uphill_spread_permille / PERMILLE) / PERMILLE


## Where unit's projectiles leave it, in micrometres (for Ballistics).
static func launch_point(unit: Unit) -> FlightState:
	return FlightState.at_mm(unit.x, unit.y + unit.type.ranged_launch_height, unit.z, 0, 0, 0)


## The projectile type unit fires next: the fire arrow when nocked.
static func next_projectile(world: World, unit: Unit) -> int:
	if unit.fire_nocked:
		return world.catalog.projectile_index_of(unit.type.special_projectile)
	return world.catalog.projectile_index_of(unit.type.ranged_projectile)


# One unit's decision for this tick. Returns true if its shot leaves now.
func _decide(world: World, unit: Unit) -> bool:
	if unit.shot_cooldown_left > 0:
		unit.shot_cooldown_left -= 1
	if unit.is_reeling() or unit.target_id != 0 or unit.state == Unit.State.ATTACKING:
		unit.clear_shot()
		return false
	if unit.order == Unit.Order.MOVE:
		return false
	if unit.ammo_left == 0:
		_stand_down(world, unit)
		return false
	if unit.order == Unit.Order.GROUND_ATTACK:
		return _ground(world, unit)
	return _hold_or_march(world, unit)


# Order NONE or ATTACK_MOVE: shoot what comes in range.
func _hold_or_march(world: World, unit: Unit) -> bool:
	if unit.state == Unit.State.MOVING and unit.order == Unit.Order.NONE:
		# A holding unit only moves to step aside; it shoots when it stops.
		return false
	var target: Unit = world.get_unit(unit.shot_target_id) if unit.shot_target_id != 0 else null
	var lost: bool = target != null and not _may_target(world, unit, target)
	if lost:
		target = null
	# Look again on this unit's own re-pick tick, or at once when the target
	# just went (died, out of range). A unit with nothing it can hit waits for
	# its re-pick tick rather than trying every tick.
	var due: bool = lost or (world.tick + unit.id) % RETARGET_TICKS == 0
	if unit.aim_left == 0 and due:
		target = _pick(world, unit, target)
	if target == null:
		_stand_down(world, unit)
		return false
	if target.id != unit.shot_target_id:
		unit.shot_target_id = target.id
		unit.aim_left = 0
	_stand(world, unit, target.x, target.z)
	return _draw(unit)


# Order GROUND_ATTACK.
func _ground(world: World, unit: Unit) -> bool:
	var dist: int = FixedMath.length(unit.ground_x - unit.x, unit.ground_z - unit.z)
	if dist < unit.type.ranged_min_range:
		_cant_reach(world, unit)
		return false
	if unit.state == Unit.State.MOVING:
		if (world.tick + unit.id) % GROUND_RECHECK_TICKS != 0 or not _reaches_ground(world, unit):
			return false
		_stand(world, unit, unit.ground_x, unit.ground_z)
		return _draw(unit)
	if unit.aim_left > 0:
		return _draw(unit)
	if _reaches_ground(world, unit):
		_stand(world, unit, unit.ground_x, unit.ground_z)
		return _draw(unit)
	if unit.ground_walked:
		# Walked as close as it could get and still can't reach.
		_cant_reach(world, unit)
		return false
	unit.ground_walked = true
	world.movement.order_move(
		world, unit, unit.ground_x, unit.ground_z, unit.ground_x - unit.x, unit.ground_z - unit.z, 0
	)
	return false


# Starts or continues a draw. Returns true when the shot leaves this tick.
func _draw(unit: Unit) -> bool:
	if unit.aim_left > 0:
		unit.aim_left -= 1
		return unit.aim_left == 0
	if unit.shot_cooldown_left > 0:
		return false
	if unit.type.ranged_windup_ticks == 0:
		return true
	unit.aim_left = unit.type.ranged_windup_ticks
	return false


# Stops where it is (if walking) and faces (x, z) to shoot.
func _stand(world: World, unit: Unit, x: int, z: int) -> void:
	if unit.state == Unit.State.MOVING:
		world.movement.order_stop(unit)
	unit.transition_to(Unit.State.SHOOTING)
	var dir: Vector2i = FixedMath.normalize(x - unit.x, z - unit.z, FixedMath.DIR_ONE)
	if dir != Vector2i.ZERO:
		unit.facing_x = dir.x
		unit.facing_z = dir.y


# Nothing to shoot: an attack-mover marches on, a holder stands.
func _stand_down(world: World, unit: Unit) -> void:
	var was_shooting: bool = unit.state == Unit.State.SHOOTING
	unit.clear_shot()
	if not was_shooting:
		return
	if unit.order == Unit.Order.ATTACK_MOVE:
		world.movement.order_move(
			world, unit, unit.order_x, unit.order_z,
			unit.order_facing_x, unit.order_facing_z, unit.order_speed_cap
		)
	else:
		world.movement.order_stop(unit)


func _cant_reach(world: World, unit: Unit) -> void:
	var e: ProjectileEvent = ProjectileEvent.new(
		ProjectileEvent.Kind.CANT_REACH, unit.ground_x,
		world.terrain.height_at(unit.ground_x, unit.ground_z), unit.ground_z
	)
	e.unit_id = unit.id
	world.projectile_events.append(e)
	UnitOrders.hold(unit)
	world.movement.order_stop(unit)


# The best target the unit can actually hit: the current one while no other
# is worth switching to (the shot itself re-aims, so it isn't re-checked
# here), else the first of the nearest few candidates a clear launch
# reaches; null if none.
func _pick(world: World, unit: Unit, current: Unit) -> Unit:
	var candidates: Array[Unit] = []
	for other: Unit in world.units:
		if other != current and _may_target(world, unit, other):
			candidates.append(other)
	candidates.sort_custom(func(a: Unit, b: Unit) -> bool: return Targeting.ranks_before(unit, a, b))
	var best: Unit = candidates[0] if not candidates.is_empty() else null
	if current != null and (best == null or not Targeting.worth_switching(unit, current, best)):
		return current
	for i: int in mini(MAX_AIM_TRIES, candidates.size()):
		if _aim_at_unit(world, unit, candidates[i], candidates[i].x, candidates[i].z).ok:
			return candidates[i]
	return null


# Alive, an enemy, visible, and within range as the crow flies.
func _may_target(world: World, unit: Unit, other: Unit) -> bool:
	if not other.is_alive() or other.faction == unit.faction or MeleeCombat.is_hidden(world.terrain, other):
		return false
	var dist: int = FixedMath.length(other.x - unit.x, other.z - unit.z)
	if dist < unit.type.ranged_min_range:
		return false
	var rise: int = other.y - unit.y - unit.type.ranged_launch_height
	return dist <= effective_max_range(unit, rise, dist)


func _reaches_ground(world: World, unit: Unit) -> bool:
	var gx: int = unit.ground_x
	var gz: int = unit.ground_z
	var dist: int = FixedMath.length(gx - unit.x, gz - unit.z)
	var rise: int = world.terrain.height_at(gx, gz) - unit.y - unit.type.ranged_launch_height
	if dist > effective_max_range(unit, rise, dist):
		return false
	return _aim_at_ground(world, unit, gx, gz).ok


# A clear launch at target, imagined standing at (x, z) (where it is now,
# or where it will be when the shot lands), avoiding friendly bodies and,
# for a thrower, friends in the blast.
func _aim_at_unit(world: World, unit: Unit, target: Unit, x: int, z: int) -> AimSolution:
	var type_index: int = next_projectile(world, unit)
	var p: ProjectileType = world.catalog.projectile_types[type_index]
	var ground: int = world.terrain.height_at(x, z)
	var y: int = ground
	if p.behavior == ProjectileType.Behavior.STICKS:
		# At the aim point, which is where a walker is led to: leading an enemy
		# into our own line would put the arrow on the line.
		if _friend_beside(world, unit, x, z, target.type.body_radius):
			return AimSolution.failed()
		y = ground + target.type.hover_height + target.type.body_height * CHEST_PERMILLE / PERMILLE
	elif p.is_explosive() and _friend_in_blast(world, unit, p, x, ground, z):
		return AimSolution.failed()
	return _aim(world, unit, p, x, y, z, true)


func _aim_at_ground(world: World, unit: Unit, x: int, z: int) -> AimSolution:
	var p: ProjectileType = world.catalog.projectile_types[next_projectile(world, unit)]
	return _aim(world, unit, p, x, world.terrain.height_at(x, z), z, false)


# The unit's own aim style, then the other, taking the first launch that
# reaches (x, y, z) (milli-units) along a clear path.
func _aim(
	world: World, unit: Unit, p: ProjectileType, x: int, y: int, z: int, avoid_friends: bool
) -> AimSolution:
	var t: UnitType = unit.type
	var from: FlightState = launch_point(unit)
	var tx: int = x * FlightState.SUB
	var ty: int = y * FlightState.SUB
	var tz: int = z * FlightState.SUB
	var speed: int = FlightState.speed_from_mm_per_s(t.ranged_launch_speed)
	var dist: int = FixedMath.length(x - unit.x, z - unit.z)
	var spread: int = spread_for(unit, y - FlightState.to_mm(from.py), dist)
	var avoid: Array[Unit] = []
	if avoid_friends:
		# The corridor is as wide as the aim cone at the target.
		var margin: int = PATH_MARGIN + spread * dist / PERMILLE
		avoid = Ballistics.bodies_near_path(world.units, unit.faction, unit, from, tx, tz, margin)
	var styles: Array[UnitType.AimStyle] = [t.ranged_aim]
	styles.append(UnitType.AimStyle.LOB if t.ranged_aim == UnitType.AimStyle.DIRECT else UnitType.AimStyle.DIRECT)
	for style: UnitType.AimStyle in styles:
		var s: AimSolution = Ballistics.solve(
			style, from, tx, ty, tz, speed, t.ranged_lob_grade_permille, p.drag_ppm_per_m
		)
		if s.ok and Ballistics.is_clear(world.terrain, from, s, tx, tz, p.radius, p.drag_ppm_per_m, avoid, spread):
			return s
	return AimSolution.failed()


# Ticks a shot from unit at target's chest (or feet, for a throw) takes to
# get there, from the unit's own aim style without the clear-path check;
# 0 if it can't reach.
func _flight_ticks(world: World, unit: Unit, target: Unit) -> int:
	var t: UnitType = unit.type
	var p: ProjectileType = world.catalog.projectile_types[next_projectile(world, unit)]
	var y: int = world.terrain.height_at(target.x, target.z)
	if p.behavior == ProjectileType.Behavior.STICKS:
		y += target.type.hover_height + target.type.body_height * CHEST_PERMILLE / PERMILLE
	var s: AimSolution = Ballistics.solve(
		t.ranged_aim, launch_point(unit), target.x * FlightState.SUB, y * FlightState.SUB,
		target.z * FlightState.SUB, FlightState.speed_from_mm_per_s(t.ranged_launch_speed),
		t.ranged_lob_grade_permille, p.drag_ppm_per_m
	)
	return s.ticks if s.ok else 0


# True if a friend of unit has its body within ARROW_FRIEND_MARGIN of a body
# of radius r at (x, z).
func _friend_beside(world: World, unit: Unit, x: int, z: int, r: int) -> bool:
	for other: Unit in world.units:
		if other != unit and other.is_alive() and other.faction == unit.faction:
			var gap: int = FixedMath.length(other.x - x, other.z - z) - other.type.body_radius - r
			if gap <= ARROW_FRIEND_MARGIN:
				return true
	return false


# True if a friend of unit (unit included) would be caught by p bursting at
# (x, y, z).
func _friend_in_blast(world: World, unit: Unit, p: ProjectileType, x: int, y: int, z: int) -> bool:
	var reach: int = p.blast_radius + FRIENDLY_BLAST_MARGIN
	for other: Unit in world.units:
		if other.is_alive() and other.faction == unit.faction:
			if Explosions.distance_to_body(other, x, y, z) < reach:
				return true
	return false


# The draw is done: aim again at where the target will be, spread, launch.
func _loose(world: World, unit: Unit) -> void:
	var solution: AimSolution
	var aim_x: int
	var aim_z: int
	if unit.order == Unit.Order.GROUND_ATTACK:
		aim_x = unit.ground_x
		aim_z = unit.ground_z
		solution = _aim_at_ground(world, unit, aim_x, aim_z)
	else:
		var target: Unit = world.get_unit(unit.shot_target_id)
		if target == null or not target.is_alive():
			unit.clear_shot()
			return
		aim_x = target.x
		aim_z = target.z
		if target.vx != 0 or target.vz != 0:
			# Lead a walker by the flight time: aim where it will be. The
			# flight time comes from an unchecked solve at where it is now.
			var ticks: int = _flight_ticks(world, unit, target)
			aim_x += target.vx * ticks
			aim_z += target.vz * ticks
		solution = _aim_at_unit(world, unit, target, aim_x, aim_z)
	if not solution.ok:
		# Lost the shot (the target moved out of reach, a friend stepped in
		# the way): pick again next tick.
		unit.clear_shot()
		return
	var type_index: int = next_projectile(world, unit)
	var p: ProjectileType = world.catalog.projectile_types[type_index]
	var from: FlightState = launch_point(unit)
	var dist: int = FixedMath.length(aim_x - unit.x, aim_z - unit.z)
	var rise: int = world.terrain.height_at(aim_x, aim_z) - FlightState.to_mm(from.py)
	var v: PackedInt64Array = Ballistics.perturb(
		solution.vx, solution.vy, solution.vz, spread_for(unit, rise, dist), world.rng
	)
	var shot: Projectile = world.spawn_projectile(
		type_index, FlightState.new(from.px, from.py, from.pz, v[0], v[1], v[2]), unit.id
	)
	shot.ignore_id = unit.id
	shot.ignore_ticks = LAUNCH_IGNORE_TICKS
	if p.fuse_ticks > 0:
		var variance: int = world.rng.randi_range(-p.fuse_variance_permille, p.fuse_variance_permille)
		shot.fuse_left = maxi(1, p.fuse_ticks + FixedMath.div_round(p.fuse_ticks * variance, PERMILLE))
	var e: ProjectileEvent = ProjectileEvent.about(ProjectileEvent.Kind.LAUNCH, shot)
	e.unit_id = unit.id
	world.projectile_events.append(e)
	unit.shot_cooldown_left = Veterancy.ranged_cooldown(unit)
	if unit.ammo_left > 0:
		unit.ammo_left -= 1
	if unit.fire_nocked:
		unit.fire_nocked = false
		unit.special_left -= 1
