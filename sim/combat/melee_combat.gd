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
## - Order.INTERACT: no fighting either; the errand (Interactions) owns the
##   unit until it is done.
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
## - Units whose fight is at range (a ranged attack, or something in hand to
##   throw: Unit.fights_at_range) only fight in melee what comes adjacent
##   (reach + ADJACENT_SLACK), whatever their order, and never chase
##   (RangedCombat). Taking up a melee fight abandons a draw in progress.
## - A melee_detonates unit's blow is it bursting: when its wind-up ends with
##   the target in reach, it dies (Damage.self_destruct) and its burst goes
##   off. No dice.
## - A unit reeling from a blast's knockback does nothing but recover. A
##   paralyzed one does nothing at all, and loses a swing it was winding up.
## - A confused unit (StatusEffects) fights the nearest unit of either side
##   within its acquire radius, whatever its order, without role preferences
##   or its hold leash.
## - A paralyzed target can't block. A blow that lands spoils the target's
##   draw or cast in progress, and a type with melee_status_ticks also
##   inflicts its melee_status (a paralyzing touch).

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


## True if a blow (or an arrow) from aspect may meet the target's shield: it
## comes from the front, the target has one, and it isn't paralyzed. The
## caller rolls shield_block_permille only when this is true.
static func can_block(world: World, target: Unit, aspect: Aspect) -> bool:
	return (
		aspect == Aspect.FRONT and target.type.shield_block_permille > 0
		and not StatusEffects.paralyzed(world, target)
	)


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
	if StatusEffects.paralyzed(world, unit):
		unit.windup_left = 0
		return false
	# A confused unit's order waits until it wears off (UnitOrders.resume).
	var confused: bool = StatusEffects.confused(world, unit)
	if unit.order == Unit.Order.INTERACT and not confused:
		return false
	if unit.order == Unit.Order.MOVE and not confused:
		if unit.state != Unit.State.IDLE:
			return false
		# Arrived: hold here from now on.
		UnitOrders.hold(unit)
	if not unit.type.has_melee():
		if not confused and unit.order == Unit.Order.ATTACK_MOVE and unit.state == Unit.State.IDLE:
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
	var target: Unit = _kept_target(world, unit, confused)
	if target == null or not Targeting.in_reach(unit, target):
		target = _acquire(world, unit, grid, target, confused)
	if target == null:
		if was_fighting or unit.state == Unit.State.ATTACKING:
			_resume(world, unit)
		elif not confused and unit.order == Unit.Order.ATTACK_MOVE and unit.state == Unit.State.IDLE:
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
# swing) and returns null. A friend is only ever a target while confused.
func _kept_target(world: World, unit: Unit, confused: bool) -> Unit:
	if unit.target_id == 0:
		return null
	var target: Unit = world.get_unit(unit.target_id)
	if (
		target == null or not target.is_alive()
		or (target.faction == unit.faction and not confused)
		or not _in_leash(world, unit, target, confused)
	):
		unit.clear_engagement()
		return null
	return target


# The best enemy the unit may fight now, or current if no other is worth
# switching to. Null if there is none.
func _acquire(world: World, unit: Unit, grid: UnitGrid, current: Unit, confused: bool) -> Unit:
	var radius: int = _acquire_radius(unit, confused)
	var component: int = world.pathing.component_at(unit.x, unit.z, unit.type.mobility)
	var candidates: Array[Unit] = []
	for other: Unit in grid.near(unit.x, unit.z, radius + unit.type.body_radius + _largest_radius, unit):
		if (other.faction == unit.faction and not confused) or Visibility.is_submerged(world.terrain, other):
			continue
		if Targeting.edge_distance(unit, other) > radius or (not confused and not _within_hold(unit, other)):
			continue
		if not Targeting.in_reach(unit, other) and not _can_walk_to(world, unit, component, other):
			continue
		candidates.append(other)
	var best: Unit = Targeting.pick(unit, candidates, confused)
	if current != null and (best == null or not Targeting.worth_switching(unit, current, best, confused)):
		return current
	return best


# Edge distance within which the unit picks up new enemies: an attack-mover
# (or a confused unit) looks out to its acquire radius, anyone else only at
# what comes adjacent. Units whose fight is at range never look far.
func _acquire_radius(unit: Unit, confused: bool) -> int:
	if (unit.order == Unit.Order.ATTACK_MOVE or confused) and not unit.fights_at_range():
		return unit.type.acquire_radius
	return unit.type.melee_reach + ADJACENT_SLACK


# True if the unit may keep fighting or chasing target.
func _in_leash(world: World, unit: Unit, target: Unit, confused: bool) -> bool:
	if Targeting.in_reach(unit, target):
		return true
	if Visibility.is_submerged(world.terrain, target):
		return false
	var limit: int = unit.type.melee_reach + ADJACENT_SLACK
	if (unit.order == Unit.Order.ATTACK_MOVE or confused) and not unit.fights_at_range():
		limit = unit.type.acquire_radius * ATTACK_MOVE_LEASH_PERMILLE / PERMILLE
	if Targeting.edge_distance(unit, target) > limit or (not confused and not _within_hold(unit, target)):
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
	if attacker.type.melee_detonates:
		# A blow from a unit killed earlier this tick is wasted: it already
		# burst when it died.
		if attacker.is_alive():
			Damage.self_destruct(world, attacker)
		return
	if world.rng.randi_range(0, PERMILLE - 1) >= Veterancy.melee_accuracy(attacker):
		world.combat_events.append(miss)
		return
	if can_block(world, target, aspect) and world.rng.randi_range(0, PERMILLE - 1) < target.type.shield_block_permille:
		world.combat_events.append(CombatEvent.new(CombatEvent.Kind.BLOCK, attacker.id, target.id, aspect))
		return
	var variance: int = world.rng.randi_range(-DAMAGE_VARIANCE_PERMILLE, DAMAGE_VARIANCE_PERMILLE)
	var damage: int = maxi(1, FixedMath.div_round(
		attacker.type.melee_damage * (PERMILLE + variance) * damage_multiplier(aspect), PERMILLE * PERMILLE
	))
	if Damage.apply(world, target, damage, attacker.x, attacker.z, attacker.id, aspect):
		return
	# Struck, it loses the shot or spell it was drawing, or the herb it was
	# about to apply.
	target.clear_shot()
	target.act_left = 0
	if attacker.type.melee_status_ticks > 0:
		StatusEffects.apply(
			world, target, attacker.type.melee_status, attacker.type.melee_status_ticks, attacker.id
		)


static func _face(unit: Unit, target: Unit) -> void:
	var dir: Vector2i = FixedMath.normalize(target.x - unit.x, target.z - unit.z, FixedMath.DIR_ONE)
	if dir != Vector2i.ZERO:
		unit.facing_x = dir.x
		unit.facing_z = dir.y
