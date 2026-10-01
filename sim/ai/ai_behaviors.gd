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
##   the leash (STANDOFF members excepted while there are intruders).
## - HUNT: goes after every enemy it can see.
## - AMBUSH: lies still, held where it stands, until it is disturbed: an enemy
##   within alert_radius of any member, a member hurt, or a member fighting.
##   Then it springs into on_alert.
## - FLANK, RETREAT: not built yet; a group given one stands as it is.

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
## attack, and reports how far it got. Every call sends the members that are
## free and haven't been sent there yet; a busy member (mid-fight, mid-swing,
## on an errand) keeps at it and is sent once it is free. A member already
## sent there is there or on its way. The first call for a goal starts the
## leg. Once every member has finished, is free, and was last sent to (x, z),
## the leg looks at where they ended up: near the goal, ARRIVED; far from it,
## one retry, sending everyone again (a WAYPOINT_FAILED event with value -1),
## and then FAILED. A finished leg is inactive, so calling again for the same
## goal starts a new one. Where they ended up is the centroid of the members
## that aren't STANDOFF (AiTactics.front): those stop short of the goal on
## purpose. A caller that must pull busy members away (a retreat) forces its
## own march first.
static func leg(
	world: World, group: AiGroup, units: Array[Unit], x: int, z: int, attack: bool
) -> LegResult:
	if not group.leg_active or group.leg_x != x or group.leg_z != z:
		group.leg_active = true
		group.leg_x = x
		group.leg_z = z
		group.leg_retried = false
		AiOrders.march(world, group, units, x, z, attack)
		return LegResult.RUNNING
	AiOrders.march(world, group, units, x, z, attack)
	if not _leg_done(world, group, units, x, z):
		return LegResult.RUNNING
	var c: Vector2i = AiOrders.centroid(AiTactics.front(units))
	if FixedMath.length(c.x - x, c.y - z) <= LEG_ARRIVE_RADIUS:
		group.leg_active = false
		return LegResult.ARRIVED
	if not group.leg_retried:
		group.leg_retried = true
		# Everyone is done and free here, and was last sent to (x, z), so only
		# a forced march sends them again.
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


# GUARD: members walking home from a recall are left alone until they get
# there. The rest: busy members farther from the anchor than
# GUARD_LEASH_PERMILLE of the radius are called back with a plain move,
# busy or not, except STANDOFF members while there are intruders: a spot
# far enough out to shoot from is often past the leash, and one is busy
# there because it is shooting, not because a chase dragged it off. Then,
# if enemies are inside the radius of the anchor (center to center), the
# others engage the ones they can get at, the bodyguard rule counting only
# threats within the leash (a threat to a STANDOFF member out past it would
# drag its bodyguards out to be called back and sent again); if there are
# none, or none they can reach, free members outside the radius attack-move
# back to the anchor, STANDOFF members included.
static func _guard(world: World, group: AiGroup, units: Array[Unit]) -> void:
	var radius: int = group.spec.guard_radius if group.spec.guard_radius > 0 else DEFAULT_GUARD_RADIUS
	var leash: int = radius * GUARD_LEASH_PERMILLE / 1000
	var ax: int = group.anchor_x
	var az: int = group.anchor_z
	var intruders: Array[Unit] = []
	for enemy: Unit in AiOrders.enemies(world, group.faction):
		if _distance(enemy, ax, az) <= radius:
			intruders.append(enemy)
	var recalled: Array[Unit] = []
	var others: Array[Unit] = []
	for unit: Unit in units:
		if _walking_home(group, unit):
			continue
		var shooting_in: bool = AiTactics.is_standoff(unit) and not intruders.is_empty()
		if not AiOrders.is_free(world, unit) and _distance(unit, ax, az) > leash and not shooting_in:
			recalled.append(unit)
		else:
			others.append(unit)
	if not recalled.is_empty():
		AiOrders.march(world, group, recalled, ax, az, false, true)
	if not intruders.is_empty() and AiOrders.engage(world, group, others, intruders, leash):
		return
	var strays: Array[Unit] = []
	for unit: Unit in others:
		if AiOrders.is_free(world, unit) and _distance(unit, ax, az) > radius:
			strays.append(unit)
	AiOrders.march(world, group, strays, ax, az, true)


# True if the member is on a recall: a plain move to the anchor that hasn't
# ended yet (MeleeCombat turns it into NONE on arrival, and a give-up ends it
# too). Such a member is left to finish the walk. Engaging it on the way
# would let its attack-move pick up the nearest enemy again, often the one
# outside the radius it was called back from, and it would swing at the
# leash for as long as both enemies stood.
static func _walking_home(group: AiGroup, unit: Unit) -> bool:
	var i: int = group.member_index(unit.id)
	return (
		unit.order == Unit.Order.MOVE
		and group.ordered_x[i] == group.anchor_x and group.ordered_z[i] == group.anchor_z
	)


# HUNT: every enemy the group can see is a candidate. Members with nothing
# they can get at stay as they are.
static func _hunt(world: World, group: AiGroup, units: Array[Unit]) -> void:
	AiOrders.engage(world, group, units, AiOrders.enemies(world, group.faction))


# FLANK: does nothing yet; the group keeps whatever orders it has.
static func _flank(_world: World, _group: AiGroup, _units: Array[Unit]) -> void:
	pass


# AMBUSH: a disturbed group switches to on_alert, which springs it
# (AiDirector.set_behavior) and plans under the new behavior at once. A quiet
# one tells any free member that isn't holding to hold where it stands, so a
# member that wandered off, or was sent off, goes back to lying still. A busy
# member is left alone: that is a disturbance already.
static func _ambush(world: World, group: AiGroup, units: Array[Unit]) -> void:
	if _disturbed(world, group, units):
		switch_to(world, group, group.spec.on_alert)
		return
	var restless: PackedInt32Array = PackedInt32Array()
	for unit: Unit in units:
		if unit.order != Unit.Order.NONE and AiOrders.is_free(world, unit):
			restless.append(unit.id)
	if not restless.is_empty():
		UnitOrders.stop(world, restless)


# True if an ambush has been found: its members have lost hit points since the
# last think (blasts and arrows reach units under the water), one is fighting
# (an enemy walked into it), or an enemy it can see is within alert_radius of
# any member, center to center.
static func _disturbed(world: World, group: AiGroup, units: Array[Unit]) -> bool:
	if AiOrders.hp_sum(units) < group.last_hp:
		return true
	for unit: Unit in units:
		if unit.target_id != 0 or unit.state == Unit.State.ATTACKING:
			return true
	return _enemy_within(world, group.faction, units, group.spec.alert_radius)


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
