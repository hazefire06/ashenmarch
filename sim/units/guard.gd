class_name Guard
extends RefCounted
## Order.GUARD (G): hold a spot, as Myth II's Hold does. The spot and the
## facing there are the unit's order_x/z and order_facing, set when the order
## is given (UnitOrders.guard). MeleeCombat asks decide() first, every tick,
## for every unit on guard that isn't confused.
##
## - A melee unit holds like Order.NONE: it fights what comes within
##   HOLD_LEASH of the spot. Unlike NONE, it walks back to the spot afterwards.
## - A ranged unit fires at anything in range, as a holding one does. When an
##   enemy that fights hand to hand closes within GUARD_THREAT, and before it
##   is in contact, the unit steps GUARD_STEP back from it (straight back, or
##   swung 22.5 then 45 degrees either way, the first that is on its ground
##   and within GUARD_LEASH of the spot) to open fire again. Once a fight is
##   joined it fights: running from a faster enemy only hands it free blows
##   on the back.
## - Walking (stepping back or going home), a guard takes on in melee only an
##   enemy already in reach (MeleeCombat._acquire_radius) and doesn't shoot
##   (RangedCombat).
## - Back home: a guard that is idle, not fighting, not shooting and not
##   threatened, with no enemy near enough to fight (a ranged one: none
##   within its range), walks back to the spot and turns to its facing.
##
## Static and pure apart from the orders it gives; no state of its own, so it
## adds nothing to the hash beyond the order and spot the unit already has.

## Milli-units a ranged guard may end up from its spot.
const GUARD_LEASH: int = 10000
## Milli-units a ranged guard steps back each time it is threatened.
const GUARD_STEP: int = 6000
## A ranged guard is threatened by a melee enemy this far (edge to edge)
## beyond its minimum range, and never less than THREAT_FLOOR.
const THREAT_MARGIN: int = 2000
const THREAT_FLOOR: int = 5000
## Milli-units from the spot that count as home.
const HOME_RADIUS: int = 1000
## A ranged guard looks for targets before going home only every this many
## ticks (staggered by id), since the look reaches across its whole range.
const RANGED_HOME_CHECK_TICKS: int = 6
## Binary angles (1024 to a turn) a step back is swung by, in the order
## tried: straight back, 22.5 degrees each way, then 45.
const STEP_ANGLES: Array[int] = [0, 64, -64, 128, -128]


## The guard's decision for this tick, before MeleeCombat's own. Returns true
## if it gave the unit a walk this tick (MeleeCombat then does nothing more
## with it); false to let MeleeCombat carry on as usual.
static func decide(world: World, unit: Unit, grid: UnitGrid, largest_radius: int) -> bool:
	if unit.target_id != 0 or unit.windup_left > 0 or unit.state == Unit.State.ATTACKING:
		return false
	if unit.state == Unit.State.MOVING:
		return false
	if unit.fights_at_range():
		var threat: Unit = _threat(world, unit, grid, largest_radius)
		if threat != null:
			if _in_contact(unit, threat):
				return false
			return _step_back(world, unit, threat)
		if unit.state != Unit.State.IDLE or unit.shot_target_id != 0:
			return false
		if (world.tick + unit.id) % RANGED_HOME_CHECK_TICKS != 0:
			return false
		var reach: int = unit.type.ranged_max_range
		if _enemy_within(world, unit, grid, reach, largest_radius):
			return false
	elif _enemy_within(world, unit, grid, unit.type.melee_reach + MeleeCombat.ADJACENT_SLACK, largest_radius):
		return false
	return _go_home(world, unit)


## How far from its spot the unit on guard takes on enemies hand to hand.
static func leash(unit: Unit) -> int:
	return GUARD_LEASH if unit.fights_at_range() else MeleeCombat.HOLD_LEASH


## Edge distance within which a melee enemy threatens a ranged guard.
static func threat_radius(unit: Unit) -> int:
	return maxi(unit.type.ranged_min_range + THREAT_MARGIN, THREAT_FLOOR)


# The nearest visible enemy that fights hand to hand within the threat
# radius, or null.
static func _threat(world: World, unit: Unit, grid: UnitGrid, largest_radius: int) -> Unit:
	var radius: int = threat_radius(unit)
	var best: Unit = null
	var best_distance: int = 0
	for other: Unit in grid.near(unit.x, unit.z, radius + unit.type.body_radius + largest_radius, unit):
		if not _is_enemy(world, unit, other) or other.fights_at_range() or not other.type.has_melee():
			continue
		var d: int = Targeting.edge_distance(unit, other)
		if d > radius:
			continue
		if best == null or d < best_distance or (d == best_distance and other.id < best.id):
			best = other
			best_distance = d
	return best


# True once a fight is as good as joined: the enemy is within its own reach
# of the unit, plus the slack an idle unit closes to strike.
static func _in_contact(unit: Unit, enemy: Unit) -> bool:
	var reach: int = maxi(enemy.type.melee_reach, unit.type.melee_reach) + MeleeCombat.ADJACENT_SLACK
	return Targeting.edge_distance(unit, enemy) <= reach


# True if a visible enemy is within radius (edge to edge).
static func _enemy_within(world: World, unit: Unit, grid: UnitGrid, radius: int, largest_radius: int) -> bool:
	for other: Unit in grid.near(unit.x, unit.z, radius + unit.type.body_radius + largest_radius, unit):
		if _is_enemy(world, unit, other) and Targeting.edge_distance(unit, other) <= radius:
			return true
	return false


static func _is_enemy(world: World, unit: Unit, other: Unit) -> bool:
	return (
		other.is_alive() and other.faction != unit.faction
		and not Visibility.is_submerged(world.terrain, other)
	)


# Walks the unit GUARD_STEP away from the threat, facing it, to the first
# spot that will do. False (stand and fight) if none will.
static func _step_back(world: World, unit: Unit, threat: Unit) -> bool:
	var away: Vector2i = FixedMath.normalize(unit.x - threat.x, unit.z - threat.z, FixedMath.DIR_ONE)
	if away == Vector2i.ZERO:
		away = Vector2i(-unit.facing_x, -unit.facing_z)
	var mobility: Terrain.Mobility = unit.type.mobility
	var component: int = world.pathing.component_at(unit.x, unit.z, mobility)
	if component == PathLayer.NO_COMPONENT:
		return false
	for angle: int in STEP_ANGLES:
		var offset: Vector2i = FixedMath.rotate_local(
			FixedMath.div_round(GUARD_STEP * FixedMath.sin_b(angle), FixedMath.TRIG_ONE),
			FixedMath.div_round(GUARD_STEP * FixedMath.cos_b(angle), FixedMath.TRIG_ONE),
			away.x, away.y
		)
		var x: int = unit.x + offset.x
		var z: int = unit.z + offset.y
		if FixedMath.length(x - unit.order_x, z - unit.order_z) > GUARD_LEASH:
			continue
		if world.pathing.component_at(x, z, mobility) != component:
			continue
		unit.clear_shot()
		world.movement.order_move(world, unit, x, z, threat.x - x, threat.z - z, 0)
		return true
	return false


# Walks the unit back to its spot, to face the order's way there. False if
# it is already home.
static func _go_home(world: World, unit: Unit) -> bool:
	if FixedMath.length(unit.order_x - unit.x, unit.order_z - unit.z) <= HOME_RADIUS:
		return false
	unit.clear_shot()
	world.movement.order_move(
		world, unit, unit.order_x, unit.order_z, unit.order_facing_x, unit.order_facing_z, 0
	)
	return true
