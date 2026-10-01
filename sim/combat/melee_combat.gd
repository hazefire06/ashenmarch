class_name MeleeCombat
extends RefCounted
## Per-tick melee, run by World.step() after commands and before movement,
## so chases it starts are steered the same tick and units it kills don't
## move. Stats come from each UnitType; the rules below are the same for all.
##
## Each tick has two passes:
## 1. Decide, in ascending id order. Each unit updates only itself: drops a
##    target that died or got away, looks for one, starts or advances a
##    swing, and stands to fight or chases. It reads other units' positions,
##    which nothing changes before movement, so the order can't matter.
## 2. Strike. Every blow due this tick lands in attacker-id order, including
##    blows from units that die this tick (blows are simultaneous). A blow at
##    a target already killed this tick is wasted. RNG draws per blow, from
##    World.rng: hit roll, then a block roll if the blow comes from the front
##    at a shielded target, then damage variance.
##
## Engagement rules:
## - Order.NONE: fight enemies within reach + ADJACENT_SLACK, stepping in to
##   close that gap, but only enemies within HOLD_LEASH of the held spot.
## - Order.MOVE: no fighting until the unit arrives (it then holds, NONE).
## - Order.ATTACK_MOVE: fight enemies within the type's acquire_radius, chase
##   them up to ATTACK_MOVE_LEASH_PERMILLE of it, and resume the march after
##   each fight.
## - One target at a time. Once the target is in reach, or a swing is under
##   way, the unit keeps it until it dies or gets away, and doesn't turn to
##   face anyone else. Enemies on its flank or rear get free blows with the
##   aspect multiplier. That, plus shields covering only the front, is why
##   surrounding a unit matters more than the raw numbers.
## - Enemies hidden in deep water can't be picked until they surface to
##   fight, and an enemy the unit can't walk to (another pathing component)
##   is only fought if in reach.
## - Units with a ranged attack only fight in melee what comes adjacent
##   (reach + ADJACENT_SLACK), whatever their order, and never chase: their
##   fight is at range (RangedCombat). Taking up a melee fight abandons a
##   draw in progress.
## - A unit reeling from a blast's knockback does nothing but recover.

enum Aspect {
	FRONT,
	FLANK,
	REAR,
}

## Idle units take on enemies within reach plus this (milli-units, edge to
## edge), stepping in to strike...
const ADJACENT_SLACK: int = 1000
## ...but only enemies within this of the spot they hold, so an idle line
## can't be lured away one step at a time.
const HOLD_LEASH: int = 3000
## An attack-moving unit gives up a chase once the target is farther than
## this, in permille of its acquire radius.
const ATTACK_MOVE_LEASH_PERMILLE: int = 1500
## A chase re-paths when the target has moved this far from the chase goal.
const CHASE_REPATH_DISTANCE: int = 1000
## A blow still lands if the target is within reach plus this when the
## wind-up ends. Separation jostles bodies a few cm per tick; the tolerance
## keeps that from turning a blow at a target standing its ground into a miss.
const REACH_TOLERANCE: int = 250
## A blow is from the front if it comes within 60 degrees of the target's
## facing (cosine >= 0.5), from the rear beyond 120 degrees, else the flank.
const FRONT_ARC_COS_PERMILLE: int = 500
const REAR_ARC_COS_PERMILLE: int = -500
const FLANK_DAMAGE_PERMILLE: int = 1200
const REAR_DAMAGE_PERMILLE: int = 1400
## Damage varies uniformly by up to this much either way, in permille.
const DAMAGE_VARIANCE_PERMILLE: int = 100
## Bucket edge of the per-tick grid used to find enemies.
const GRID_BUCKET: int = 8000
const PERMILLE: int = 1000

## Largest body radius in the catalog, found on first use. Grid queries are
## by center, so they reach this much farther than any edge distance asked for.
var _largest_radius: int = -1


func update(world: World) -> void:
	if _largest_radius < 0:
		_largest_radius = 0
		for t: UnitType in world.catalog.types:
			_largest_radius = maxi(_largest_radius, t.body_radius)
	var grid: UnitGrid = UnitGrid.new(world.units, GRID_BUCKET)
	var striking: Array[Unit] = []
	for unit: Unit in world.units:
		if unit.is_alive() and _decide(world, unit, grid):
			striking.append(unit)
	for attacker: Unit in striking:
		_strike(world, attacker)


## Where a blow from (from_x, from_z) lands relative to the defender's facing.
static func aspect_of(defender: Unit, from_x: int, from_z: int) -> Aspect:
	var dir: Vector2i = FixedMath.normalize(from_x - defender.x, from_z - defender.z, FixedMath.DIR_ONE)
	if dir == Vector2i.ZERO:
		return Aspect.FRONT
	# Both vectors have length DIR_ONE, so this is the cosine in permille.
	var cosine: int = FixedMath.div_round(
		dir.x * defender.facing_x + dir.y * defender.facing_z, FixedMath.DIR_ONE * FixedMath.DIR_ONE / PERMILLE
	)
	if cosine >= FRONT_ARC_COS_PERMILLE:
		return Aspect.FRONT
	if cosine <= REAR_ARC_COS_PERMILLE:
		return Aspect.REAR
	return Aspect.FLANK


static func damage_multiplier(aspect: Aspect) -> int:
	match aspect:
		Aspect.FLANK:
			return FLANK_DAMAGE_PERMILLE
		Aspect.REAR:
			return REAR_DAMAGE_PERMILLE
	return PERMILLE


# One unit's decision for this tick. Returns true if its blow lands now.
func _decide(world: World, unit: Unit, grid: UnitGrid) -> bool:
	if unit.cooldown_left > 0:
		unit.cooldown_left -= 1
	if unit.is_reeling():
		return false
	if unit.order == Unit.Order.MOVE:
		if unit.state != Unit.State.IDLE:
			return false
		# Arrived: hold here from now on.
		UnitOrders.hold(unit)
	if unit.type.melee_damage <= 0:
		if unit.order == Unit.Order.ATTACK_MOVE and unit.state == Unit.State.IDLE:
			# No melee to fight with, but the march still ends on arrival.
			UnitOrders.hold(unit)
		return false
	var was_fighting: bool = unit.target_id != 0
	if unit.windup_left > 0:
		# A swing is committed: it lands (or whiffs, if the target got clear)
		# unless the target is already dead.
		var swinging_at: Unit = world.get_unit(unit.target_id)
		if swinging_at != null and swinging_at.is_alive():
			_face(unit, swinging_at)
			unit.windup_left -= 1
			return unit.windup_left == 0
		unit.clear_engagement()
	var target: Unit = _kept_target(world, unit)
	if target == null or not Targeting.in_reach(unit, target):
		target = _acquire(world, unit, grid, target)
	if target == null:
		if was_fighting or unit.state == Unit.State.ATTACKING:
			_resume(world, unit)
		elif unit.order == Unit.Order.ATTACK_MOVE and unit.state == Unit.State.IDLE:
			# Reached the end of the march with nothing left to fight.
			UnitOrders.hold(unit)
		return false
	if Targeting.in_reach(unit, target):
		_engage(unit, target)
		if unit.cooldown_left == 0:
			unit.windup_left = unit.type.melee_windup_ticks
			world.combat_events.append(CombatEvent.new(CombatEvent.Kind.SWING, unit.id, target.id))
	else:
		_chase(world, unit, target)
	return false


# The unit's current target if it may keep it; otherwise drops it (and any
# swing) and returns null.
func _kept_target(world: World, unit: Unit) -> Unit:
	if unit.target_id == 0:
		return null
	var target: Unit = world.get_unit(unit.target_id)
	if target == null or not target.is_alive() or not _in_leash(world, unit, target):
		unit.clear_engagement()
		return null
	return target


# The best enemy the unit may fight now, or current if no other is worth
# switching to. Null if there is none.
func _acquire(world: World, unit: Unit, grid: UnitGrid, current: Unit) -> Unit:
	var radius: int = _acquire_radius(unit)
	var component: int = world.pathing.component_at(unit.x, unit.z, unit.type.mobility)
	var candidates: Array[Unit] = []
	for other: Unit in grid.near(unit.x, unit.z, radius + unit.type.body_radius + _largest_radius, unit):
		if other.faction == unit.faction or Visibility.is_submerged(world.terrain, other):
			continue
		if Targeting.edge_distance(unit, other) > radius or not _within_hold(unit, other):
			continue
		if not Targeting.in_reach(unit, other) and not _can_walk_to(world, unit, component, other):
			continue
		candidates.append(other)
	var best: Unit = Targeting.pick(unit, candidates)
	if current != null and (best == null or not Targeting.worth_switching(unit, current, best)):
		return current
	return best


# Edge distance within which the unit picks up new enemies.
func _acquire_radius(unit: Unit) -> int:
	if unit.order == Unit.Order.ATTACK_MOVE and not unit.type.has_ranged():
		return unit.type.acquire_radius
	return unit.type.melee_reach + ADJACENT_SLACK


# True if the unit may keep fighting or chasing target.
func _in_leash(world: World, unit: Unit, target: Unit) -> bool:
	if Targeting.in_reach(unit, target):
		return true
	if Visibility.is_submerged(world.terrain, target):
		return false
	var limit: int = unit.type.melee_reach + ADJACENT_SLACK
	if unit.order == Unit.Order.ATTACK_MOVE and not unit.type.has_ranged():
		limit = unit.type.acquire_radius * ATTACK_MOVE_LEASH_PERMILLE / PERMILLE
	if Targeting.edge_distance(unit, target) > limit or not _within_hold(unit, target):
		return false
	var component: int = world.pathing.component_at(unit.x, unit.z, unit.type.mobility)
	return _can_walk_to(world, unit, component, target)


# Holding units (Order.NONE) only fight enemies near the spot they hold.
func _within_hold(unit: Unit, other: Unit) -> bool:
	if unit.order != Unit.Order.NONE:
		return true
	return FixedMath.length(other.x - unit.order_x, other.z - unit.order_z) <= HOLD_LEASH


func _can_walk_to(world: World, unit: Unit, component: int, other: Unit) -> bool:
	return (
		component != PathLayer.NO_COMPONENT
		and world.pathing.component_at(other.x, other.z, unit.type.mobility) == component
	)


# Target in reach: stand and face it.
func _engage(unit: Unit, target: Unit) -> void:
	unit.clear_shot()
	unit.target_id = target.id
	if unit.state == Unit.State.MOVING:
		unit.clear_order()
		unit.goal_x = unit.x
		unit.goal_z = unit.z
	unit.transition_to(Unit.State.ATTACKING)
	_face(unit, target)


# Target out of reach: walk at it, re-pathing only when it has moved away
# from where the chase was headed.
func _chase(world: World, unit: Unit, target: Unit) -> void:
	unit.clear_shot()
	var new_target: bool = unit.target_id != target.id
	unit.target_id = target.id
	var drift: int = FixedMath.length(target.x - unit.goal_x, target.z - unit.goal_z)
	if new_target or unit.state != Unit.State.MOVING or drift > CHASE_REPATH_DISTANCE:
		world.movement.order_move(
			world, unit, target.x, target.z, target.x - unit.x, target.z - unit.z, 0
		)


# The fight is over (or the target got away): march on, or stand. A ground
# attacker the fight interrupted gets to walk into range again.
func _resume(world: World, unit: Unit) -> void:
	unit.clear_engagement()
	unit.ground_walked = false
	if unit.order == Unit.Order.ATTACK_MOVE:
		world.movement.order_move(
			world, unit, unit.order_x, unit.order_z,
			unit.order_facing_x, unit.order_facing_z, unit.order_speed_cap
		)
	else:
		world.movement.order_stop(unit)


func _strike(world: World, attacker: Unit) -> void:
	attacker.cooldown_left = Veterancy.melee_cooldown(attacker)
	var target: Unit = world.get_unit(attacker.target_id)
	if target == null or not target.is_alive():
		return
	var aspect: Aspect = aspect_of(target, attacker.x, attacker.z)
	var miss: CombatEvent = CombatEvent.new(CombatEvent.Kind.MISS, attacker.id, target.id, aspect)
	if not Targeting.in_reach(attacker, target, REACH_TOLERANCE):
		world.combat_events.append(miss)
		return
	if world.rng.randi_range(0, PERMILLE - 1) >= Veterancy.melee_accuracy(attacker):
		world.combat_events.append(miss)
		return
	var block: int = target.type.shield_block_permille
	if aspect == Aspect.FRONT and block > 0 and world.rng.randi_range(0, PERMILLE - 1) < block:
		world.combat_events.append(CombatEvent.new(CombatEvent.Kind.BLOCK, attacker.id, target.id, aspect))
		return
	var variance: int = world.rng.randi_range(-DAMAGE_VARIANCE_PERMILLE, DAMAGE_VARIANCE_PERMILLE)
	var damage: int = maxi(1, FixedMath.div_round(
		attacker.type.melee_damage * (PERMILLE + variance) * damage_multiplier(aspect), PERMILLE * PERMILLE
	))
	Damage.apply(world, target, damage, attacker.x, attacker.z, attacker.id, aspect)


static func _face(unit: Unit, target: Unit) -> void:
	var dir: Vector2i = FixedMath.normalize(target.x - unit.x, target.z - unit.z, FixedMath.DIR_ONE)
	if dir != Vector2i.ZERO:
		unit.facing_x = dir.x
		unit.facing_z = dir.y
