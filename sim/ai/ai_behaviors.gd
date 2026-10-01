class_name AiBehaviors
extends RefCounted
## What each AiGroupSpec.Behavior does when its group thinks. Static, like
## AiOrders: a group's progress lives in AiGroup (waypoint, leg, anchor, the
## order records), and a think only re-orders members its plan changed for.
## AiDirector.update calls think() every AiDirector.THINK_TICKS, or at once
## when asked.
##
## - IDLE: nothing; the members hold and fight what comes adjacent.
## - PATROL: walks the waypoints one leg at a time, attack-moving, so it
##   fights what it meets and walks on. An enemy within alert_radius switches
##   it to on_alert.
## - GUARD: chases enemies inside its radius of the anchor, comes back to the
##   anchor when none are left, and calls back any member a chase drags past
##   the leash.
## - HUNT: goes after every enemy it can see.
## - FLANK, AMBUSH, RETREAT: not built yet; a group given one stands as it is.

## What a leg (one march to one goal) came to.
enum LegResult {
	## Still on the way, or retrying.
	RUNNING,
	## The members have all finished and their centroid is near the goal.
	ARRIVED,
	## The members have finished twice and their centroid is still far off.
	FAILED,
}

## Milli-units from the members' centroid to a leg's goal within which the
## leg counts as reached. Formation slots spread about the goal, and units
## the slot can't hold settle near it, so this is a few body widths.
const LEG_ARRIVE_RADIUS: int = 4000
## How far a GUARD's busy members may chase from the anchor before they are
## called back, in permille of the guard radius.
const GUARD_LEASH_PERMILLE: int = 1500
## Guard radius for a GUARD group whose spec has none (a group sent to guard
## by the AI rather than by its spec).
const DEFAULT_GUARD_RADIUS: int = 10000


## Plans the group's next step under its behavior and notes its members'
## hit points (last_hp). A group with no living members does nothing.
static func think(world: World, group: AiGroup) -> void:
	var units: Array[Unit] = group.living(world)
	if units.is_empty():
		return
	_run(world, group, units)
	group.last_hp = AiOrders.hp_sum(units)


## Gives the group a new behavior (AiDirector.set_behavior) and plans under it
## at once, so an alert turns into orders on the tick it is raised. The plan
## is made here, so the group doesn't plan again at the next update.
static func switch_to(world: World, group: AiGroup, behavior: AiGroupSpec.Behavior) -> void:
	world.ai.set_behavior(world, group, behavior)
	var units: Array[Unit] = group.living(world)
	if not units.is_empty():
		_run(world, group, units)
	group.think_now = false


## Walks units (the group's living members) to (x, z), attack-moving if
## attack, and reports how far it got. The first call for a goal starts the
## leg: every member is sent, busy or not. Later calls send members that are
## free and haven't been sent there yet, and once every member has finished,
## is free, and was last sent to (x, z), check where they ended up: near the
## goal, ARRIVED; far from it, one retry (a WAYPOINT_FAILED event with value
## -1) and then FAILED. A finished leg is inactive, so calling again for the
## same goal starts a new one.
static func leg(
	world: World, group: AiGroup, units: Array[Unit], x: int, z: int, attack: bool
) -> LegResult:
	if not group.leg_active or group.leg_x != x or group.leg_z != z:
		group.leg_active = true
		group.leg_x = x
		group.leg_z = z
		group.leg_retried = false
		AiOrders.march(world, group, units, x, z, attack, true)
		return LegResult.RUNNING
	AiOrders.march(world, group, units, x, z, attack)
	if not _leg_done(world, group, units, x, z):
		return LegResult.RUNNING
	var c: Vector2i = AiOrders.centroid(units)
	if FixedMath.length(c.x - x, c.y - z) <= LEG_ARRIVE_RADIUS:
		group.leg_active = false
		return LegResult.ARRIVED
	if not group.leg_retried:
		group.leg_retried = true
		AiOrders.march(world, group, units, x, z, attack, true)
		world.ai_events.append(AiEvent.new(AiEvent.Kind.WAYPOINT_FAILED, group.id, x, z, -1))
		return LegResult.RUNNING
	group.leg_active = false
	return LegResult.FAILED


# One think under the group's current behavior. IDLE does nothing.
static func _run(world: World, group: AiGroup, units: Array[Unit]) -> void:
	match group.behavior:
		AiGroupSpec.Behavior.PATROL:
			_patrol(world, group, units)
		AiGroupSpec.Behavior.GUARD:
			_guard(world, group, units)
		AiGroupSpec.Behavior.HUNT:
			_hunt(world, group, units)
		AiGroupSpec.Behavior.FLANK:
			_flank(world, group, units)
		AiGroupSpec.Behavior.AMBUSH:
			_ambush(world, group, units)
		AiGroupSpec.Behavior.RETREAT:
			_retreat(world, group, units)


# Every member has finished, is free, and was last sent to (x, z).
static func _leg_done(world: World, group: AiGroup, units: Array[Unit], x: int, z: int) -> bool:
	for unit: Unit in units:
		var i: int = group.member_index(unit.id)
		if (
			not AiOrders.is_done(unit) or not AiOrders.is_free(world, unit)
			or group.ordered_x[i] != x or group.ordered_z[i] != z
		):
			return false
	return true


# PATROL: an enemy within alert_radius of any member (center to center)
# switches the group to on_alert. Otherwise it walks the current leg; when
# the leg ends, it reports the waypoint reached or failed, advances, and
# starts the next leg at once.
static func _patrol(world: World, group: AiGroup, units: Array[Unit]) -> void:
	var spec: AiGroupSpec = group.spec
	if spec.alert_radius > 0 and _enemy_within(world, group.faction, units, spec.alert_radius):
		switch_to(world, group, spec.on_alert)
		return
	var i: int = group.waypoint_index
	var result: LegResult = leg(world, group, units, spec.waypoints[2 * i], spec.waypoints[2 * i + 1], true)
	if result == LegResult.RUNNING:
		return
	var kind: AiEvent.Kind = (
		AiEvent.Kind.WAYPOINT_REACHED if result == LegResult.ARRIVED else AiEvent.Kind.WAYPOINT_FAILED
	)
	world.ai_events.append(AiEvent.new(kind, group.id, spec.waypoints[2 * i], spec.waypoints[2 * i + 1], i))
	_advance_waypoint(group)
	i = group.waypoint_index
	leg(world, group, units, spec.waypoints[2 * i], spec.waypoints[2 * i + 1], true)


# Moves waypoint_index on: LOOP wraps from the last waypoint to the first;
# PING_PONG turns back at either end.
static func _advance_waypoint(group: AiGroup) -> void:
	var count: int = group.spec.waypoints.size() >> 1
	if group.spec.patrol_mode == AiGroupSpec.PatrolMode.LOOP:
		group.waypoint_index = (group.waypoint_index + 1) % count
		return
	var next: int = group.waypoint_index + group.waypoint_step
	if next < 0 or next >= count:
		group.waypoint_step = -group.waypoint_step
		next = group.waypoint_index + group.waypoint_step
	group.waypoint_index = next


# GUARD: first the leash: busy members farther from the anchor than
# GUARD_LEASH_PERMILLE of the radius are called back with a plain move, busy
# or not, unless already walking home. Then, if enemies are inside the
# radius of the anchor (center to center), the others engage them;
# otherwise free members outside the radius attack-move back to the anchor.
static func _guard(world: World, group: AiGroup, units: Array[Unit]) -> void:
	var radius: int = group.spec.guard_radius if group.spec.guard_radius > 0 else DEFAULT_GUARD_RADIUS
	var leash: int = radius * GUARD_LEASH_PERMILLE / 1000
	var ax: int = group.anchor_x
	var az: int = group.anchor_z
	var recalled: Array[Unit] = []
	var others: Array[Unit] = []
	for unit: Unit in units:
		if (
			not AiOrders.is_free(world, unit) and _distance(unit, ax, az) > leash
			and not _walking_home(group, unit)
		):
			recalled.append(unit)
		else:
			others.append(unit)
	if not recalled.is_empty():
		AiOrders.march(world, group, recalled, ax, az, false, true)
	var intruders: Array[Unit] = []
	for enemy: Unit in AiOrders.enemies(world, group.faction):
		if _distance(enemy, ax, az) <= radius:
			intruders.append(enemy)
	if not intruders.is_empty():
		AiOrders.engage(world, group, others, intruders)
		return
	var strays: Array[Unit] = []
	for unit: Unit in others:
		if AiOrders.is_free(world, unit) and _distance(unit, ax, az) > radius:
			strays.append(unit)
	AiOrders.march(world, group, strays, ax, az, true)


# True if the member is already on a plain move back to the anchor (a
# recall whose path is still being solved, say), which nothing can lure off.
static func _walking_home(group: AiGroup, unit: Unit) -> bool:
	var i: int = group.member_index(unit.id)
	return (
		unit.order == Unit.Order.MOVE
		and group.ordered_x[i] == group.anchor_x and group.ordered_z[i] == group.anchor_z
	)


# HUNT: every enemy the group can see is a candidate.
static func _hunt(world: World, group: AiGroup, units: Array[Unit]) -> void:
	AiOrders.engage(world, group, units, AiOrders.enemies(world, group.faction))


# FLANK: does nothing yet; the group keeps whatever orders it has.
static func _flank(_world: World, _group: AiGroup, _units: Array[Unit]) -> void:
	pass


# AMBUSH: does nothing yet; the group keeps whatever orders it has.
static func _ambush(_world: World, _group: AiGroup, _units: Array[Unit]) -> void:
	pass


# RETREAT: does nothing yet; the group keeps whatever orders it has.
static func _retreat(_world: World, _group: AiGroup, _units: Array[Unit]) -> void:
	pass


# True if an enemy of faction stands within radius (center to center) of
# any of units.
static func _enemy_within(world: World, faction: UnitType.Faction, units: Array[Unit], radius: int) -> bool:
	for enemy: Unit in AiOrders.enemies(world, faction):
		for unit: Unit in units:
			if _distance(unit, enemy.x, enemy.z) <= radius:
				return true
	return false


static func _distance(unit: Unit, x: int, z: int) -> int:
	return FixedMath.length(unit.x - x, unit.z - z)
