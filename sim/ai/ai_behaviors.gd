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
##   it to on_alert (into GUARD, at the post where it was alerted).
## - GUARD: chases enemies inside its radius of the anchor, comes back to the
##   anchor when none are left, and calls back any member a chase drags past
##   the leash (STANDOFF members excepted while there are intruders). Hurt
##   from outside the radius, it switches to on_alert, unless it has
##   retreated or on_alert is GUARD.
## - HUNT: goes after every enemy it can see.
## - AMBUSH: lies still, held where it stands, until it is disturbed: an enemy
##   within alert_radius of any member, a member hurt, or a member fighting.
##   Then it springs into on_alert.
## - FLANK: goes after a ranged or support unit (the spec's flank_roles),
##   walking round the end of any enemy melee screening it first (AiFlank).
## - RETREAT: a group that is losing badly, to enemies near any member or
##   to anyone fighting or shooting a member, falls back, once, to its
##   retreat point (or its spawn point) and then guards it. think() sends it:
##   see _should_retreat.
## - ESCORT: walks its waypoints (plain moves, so it never stops to fight)
##   only while one of the player's units is near, and waits where it stands
##   while the friend is far or a visible enemy is close (a villager led
##   across a river).

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
## How far from the nearest member of a group a visible enemy may stand and
## still count against it in a retreat, in milli-units (center to center). An
## enemy fighting or shooting a member counts wherever it stands.
const RETREAT_THREAT_RADIUS: int = 20000
## An escort's radii give a little at the margin, so a friend or an enemy
## standing right at one doesn't make it stop and set off every think: a
## walking group allows the friend this much beyond escort_radius, and a
## waiting one needs the enemy this much beyond alert_radius, before it
## changes its mind. Milli-units.
const ESCORT_HYSTERESIS: int = 2000


## Plans the group's next step under its behavior and notes its members'
## hit points (last_hp). A group with no living members does nothing. A group
## that should fall back (_should_retreat) is given RETREAT first, whatever it
## was doing, and plans its retreat at once: the RETREAT event is reported
## after the behavior change and before the march it orders.
static func think(world: World, group: AiGroup) -> void:
	var units: Array[Unit] = group.living(world)
	if units.is_empty():
		return
	if _should_retreat(world, group, units):
		group.retreated = true
		world.ai.set_behavior(world, group, AiGroupSpec.Behavior.RETREAT)
		var goal: Vector2i = _retreat_goal(group)
		world.ai_events.append(AiEvent.new(AiEvent.Kind.RETREAT, group.id, goal.x, goal.y))
		group.think_now = false
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
		AiGroupSpec.Behavior.ESCORT:
			_escort(world, group, units)


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
# switches the group to on_alert. An alert into GUARD first makes the
# members' centroid the anchor, so the group guards where it was alerted
# rather than walking back to its spawn point to do it. Otherwise it walks
# the current leg; when the leg ends, it reports the waypoint reached or
# failed, advances, and starts the next leg at once.
static func _patrol(world: World, group: AiGroup, units: Array[Unit]) -> void:
	var spec: AiGroupSpec = group.spec
	if spec.alert_radius > 0 and _enemy_within(world, group.faction, units, spec.alert_radius):
		if spec.on_alert == AiGroupSpec.Behavior.GUARD:
			var c: Vector2i = AiOrders.centroid(units)
			group.anchor_x = c.x
			group.anchor_z = c.y
		switch_to(world, group, spec.on_alert)
		return
	if _leg_to_waypoint(world, group, units, true) == LegResult.RUNNING:
		return
	_advance_waypoint(group)
	var next: Vector2i = _waypoint(spec, group.waypoint_index)
	leg(world, group, units, next.x, next.y, true)


# The point of waypoint i of the spec's route, in milli-units.
static func _waypoint(spec: AiGroupSpec, i: int) -> Vector2i:
	return Vector2i(spec.waypoints[2 * i], spec.waypoints[2 * i + 1])


# One think's walk along a route (PATROL, ESCORT): the leg to the group's
# current waypoint, attack-moving if attack. When the leg ends, ARRIVED or
# FAILED, it reports WAYPOINT_REACHED or WAYPOINT_FAILED for the waypoint (its
# index as the value) and returns the result for the caller to advance on.
# RUNNING reports nothing.
static func _leg_to_waypoint(world: World, group: AiGroup, units: Array[Unit], attack: bool) -> LegResult:
	var i: int = group.waypoint_index
	var at: Vector2i = _waypoint(group.spec, i)
	var result: LegResult = leg(world, group, units, at.x, at.y, attack)
	if result == LegResult.RUNNING:
		return result
	var kind: AiEvent.Kind = (
		AiEvent.Kind.WAYPOINT_REACHED if result == LegResult.ARRIVED else AiEvent.Kind.WAYPOINT_FAILED
	)
	world.ai_events.append(AiEvent.new(kind, group.id, at.x, at.y, i))
	return result


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


# GUARD: hurt since the last think (hit points lost, a member dying counts)
# with no intruder inside the radius, now or at that think, the group is
# being hit from outside it, by archers say, where holding the post would
# only let it bleed: it switches to on_alert, one way, like an ambush
# springing. Not a group that has retreated (it fell back to hold its post),
# and not one whose on_alert is GUARD itself (it stays as it is). The think
# before must have had no intruder too (phase 0; phase 1 records that it
# had), or a guard whose intruder landed a blow and died between two thinks
# would read as hit from outside and walk off its post. Otherwise members
# walking home from a recall are left alone until they get there. The rest: busy members farther
# from the anchor than
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
	var hit_from_outside: bool = (
		intruders.is_empty() and group.phase == 0 and AiOrders.hp_sum(units) < group.last_hp
	)
	group.phase = 0 if intruders.is_empty() else 1
	var on_alert: AiGroupSpec.Behavior = group.spec.on_alert
	if hit_from_outside and not group.retreated and on_alert != AiGroupSpec.Behavior.GUARD:
		switch_to(world, group, on_alert)
		return
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


# FLANK: see AiFlank.
static func _flank(world: World, group: AiGroup, units: Array[Unit]) -> void:
	AiFlank.think(world, group, units)


# AMBUSH: a disturbed group switches to on_alert, which springs it
# (AiDirector.set_behavior) and plans under the new behavior at once. A quiet
# one tells any free member that isn't holding to hold where it stands, so a
# member that wandered off, or was sent off, goes back to lying still. A busy
# member is left alone. Only fighting (a target, or ATTACKING) disturbs the
# ambush; one that is confused, on an errand, waiting on a path, or drawing
# is left to finish, and is told to hold once it is free.
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
# last think (a blast reaches units under the water; arrows and blows can't
# target them), one is fighting (an enemy walked into it), or an enemy it can
# see is within alert_radius of any member, center to center.
static func _disturbed(world: World, group: AiGroup, units: Array[Unit]) -> bool:
	if AiOrders.hp_sum(units) < group.last_hp:
		return true
	for unit: Unit in units:
		if unit.target_id != 0 or unit.state == Unit.State.ATTACKING:
			return true
	return _enemy_within(world, group.faction, units, group.spec.alert_radius)


# True if the group should fall back now: it has not retreated before, its
# spec sets a threshold, its members' hit points are below that share of what
# it spawned with, and the enemies against it (_threat) have more hit points
# between them than it has left. A group losing to nothing in particular
# stands. An escort never falls back: it would be abandoning what it escorts,
# and a spec that starts as one has no threshold (AiGroupSpec.validate), so
# this is for a group a trigger switched to ESCORT that does.
static func _should_retreat(world: World, group: AiGroup, units: Array[Unit]) -> bool:
	if group.behavior == AiGroupSpec.Behavior.RETREAT or group.behavior == AiGroupSpec.Behavior.ESCORT:
		return false
	if group.retreated:
		return false
	var permille: int = group.spec.retreat_below_permille
	if permille <= 0:
		return false
	var own: int = AiOrders.hp_sum(units)
	if own * 1000 >= group.start_hp * permille:
		return false
	return _threat(world, group, units) > own


# The summed hit points of the enemies against a group with units (its living
# members), each counted once: a visible enemy within RETREAT_THREAT_RADIUS of
# any member, and any living enemy, seen or not, whose melee target or shot
# target is a member. Near any member rather than the centroid, and the
# shooters wherever they stand, because a group can be losing to archers, or
# be down to casters standing 36 m off, with no enemy anywhere near its
# middle.
static func _threat(world: World, group: AiGroup, units: Array[Unit]) -> int:
	var ids: PackedInt32Array = PackedInt32Array()
	for unit: Unit in units:
		ids.append(unit.id)
	var threat: int = 0
	for enemy: Unit in world.units:
		if not enemy.is_alive() or enemy.faction == group.faction:
			continue
		var against: bool = ids.has(enemy.target_id) or ids.has(enemy.shot_target_id)
		if not against and not Visibility.is_submerged(world.terrain, enemy):
			for unit: Unit in units:
				if _distance(unit, enemy.x, enemy.z) <= RETREAT_THREAT_RADIUS:
					against = true
					break
		if against:
			threat += enemy.hp
	return threat


# Where a retreat falls back to: the spec's retreat point, else where the
# group spawned.
static func _retreat_goal(group: AiGroup) -> Vector2i:
	var point: PackedInt32Array = group.spec.retreat_point
	if point.size() == 2:
		return Vector2i(point[0], point[1])
	return Vector2i(group.spawn_x, group.spawn_z)


# RETREAT: the first think orders every member to the goal, busy or not (that
# is the point of retreating: it drops the fights it is in), as a plain move,
# since a retreat isn't looking for a fight on the way. After that it walks the
# leg like any march. Whether it got there or not, it makes the goal its post
# and guards it.
static func _retreat(world: World, group: AiGroup, units: Array[Unit]) -> void:
	var goal: Vector2i = _retreat_goal(group)
	if group.phase == 0:
		group.phase = 1
		AiOrders.march(world, group, units, goal.x, goal.y, false, true)
	if leg(world, group, units, goal.x, goal.y, false) == LegResult.RUNNING:
		return
	group.anchor_x = goal.x
	group.anchor_z = goal.y
	world.ai.set_behavior(world, group, AiGroupSpec.Behavior.GUARD)


# ESCORT, in AiGroup.phase: 0 walking, 1 waiting, 2 arrived (the members hold).
# Walking, it waits if no friend is within escort_radius of any member, or a
# visible enemy is within alert_radius of any member (0: never). It stops the
# members where they stand (UnitOrders.stop) and reports ESCORT_WAIT. Each
# member's recorded order is reset to where it stands too: AiOrders.march skips
# a member already sent to the leg's goal, so without that the next leg, to
# the same waypoint, would send nobody. A waiting group walks again once a
# friend is within escort_radius and no enemy is within alert_radius, and
# reports ESCORT_GO. The pause ended the old leg, retry and all, so the leg
# that follows starts afresh. Each limit gives way a little once the group is
# in the state it would leave (ESCORT_HYSTERESIS): a walking group tolerates a
# friend that far past escort_radius, and a waiting one wants the enemy that
# far past alert_radius. Walking is a plain-move leg to the current waypoint,
# so nothing on the way stops it to fight. ARRIVED reports the waypoint and
# goes on to the next, or after the last arrives and holds, the index staying
# on the last waypoint. FAILED reports it and does not advance: the next think
# starts a new leg at the same waypoint, because skipping one could send the
# group the long way round whatever it was led to cross.
static func _escort(world: World, group: AiGroup, units: Array[Unit]) -> void:
	if group.phase == 2:
		return
	var spec: AiGroupSpec = group.spec
	var waiting: bool = group.phase == 1
	var friend_radius: int = spec.escort_radius + (0 if waiting else ESCORT_HYSTERESIS)
	var enemy_radius: int = spec.alert_radius + (ESCORT_HYSTERESIS if waiting else 0)
	var held_up: bool = (
		not _friend_within(world, group, units, friend_radius)
		or (spec.alert_radius > 0 and _enemy_within(world, group.faction, units, enemy_radius))
	)
	var i: int = group.waypoint_index
	if waiting:
		if held_up:
			return
		group.phase = 0
		var to: Vector2i = _waypoint(spec, i)
		world.ai_events.append(AiEvent.new(AiEvent.Kind.ESCORT_GO, group.id, to.x, to.y, i))
	elif held_up:
		var ids: PackedInt32Array = PackedInt32Array()
		for unit: Unit in units:
			ids.append(unit.id)
			group.record_order(unit.id, unit.x, unit.z, 0)
		UnitOrders.stop(world, ids)
		group.leg_active = false
		group.phase = 1
		var c: Vector2i = AiOrders.centroid(units)
		world.ai_events.append(AiEvent.new(AiEvent.Kind.ESCORT_WAIT, group.id, c.x, c.y, i))
		return
	var result: LegResult = _leg_to_waypoint(world, group, units, false)
	if result != LegResult.ARRIVED:
		return
	if i + 1 >= spec.waypoints.size() >> 1:
		group.phase = 2
		return
	group.waypoint_index = i + 1
	var next: Vector2i = _waypoint(spec, i + 1)
	leg(world, group, units, next.x, next.y, false)


# True if a friend stands within radius (center to center) of any of units: a
# living unit on the group's side that the AI doesn't drive, so one of the
# player's. The group's own members and every other AI unit are driven, so
# controls() already leaves them out.
static func _friend_within(world: World, group: AiGroup, units: Array[Unit], radius: int) -> bool:
	for friend: Unit in world.units:
		if not friend.is_alive() or friend.faction != group.faction or world.ai.controls(friend.id):
			continue
		for unit: Unit in units:
			if _distance(unit, friend.x, friend.z) <= radius:
				return true
	return false


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
