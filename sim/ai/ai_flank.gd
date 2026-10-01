class_name AiFlank
extends RefCounted
## FLANK, for AiBehaviors: a group (Rippers, typically) goes after an enemy
## of a role in its spec's flank_roles (the focus), and if enemy melee screens
## the focus, it walks round the end of the screen before it strikes, so it
## hits the focus from the side instead of fighting through the line. Static,
## like AiBehaviors; the progress is AiGroup's focus_id, route, route_index,
## plan_x/plan_z and phase:
##
## - 0, fresh: plans (FlankRoute). Nothing in the way: strike. Otherwise the
##   route round the screen's nearer end, or round the other end if the
##   nearer one leaves the map or the group's pathing component: approach.
##   Neither works: strike.
## - 1, approach: walks the route one leg per waypoint with plain moves, so
##   nothing on the way stops it to fight. It strikes at once when found out:
##   a member lost hit points since the last think, or an enemy is within
##   CONTACT of a member. A focus that moves more than REPLAN_DRIFT from
##   where it stood at planning gets a new plan. After the last waypoint:
##   strike.
## - 2, strike: engages every enemy it can see, its ASSAULT members going for
##   the focus first (AiOrders.engage).
##
## The focus is kept while it stays a target (see _focus); when it changes, a
## new plan starts from phase 0. With no focus, the group hunts that think.

## Milli-units (center to center) from the focus within which an enemy melee
## unit is part of its screen.
const SCREEN_RADIUS: int = 30000
## Milli-units (edge to edge) from a member within which an enemy cuts an
## approach short: the flank is found out, so it strikes. A route passes the
## screen's end far enough out (FlankRoute.SIDE_MARGIN) that rounding it
## doesn't count.
const CONTACT: int = 3000
## Milli-units the focus may move from where it stood when the route was
## planned before the route is planned again.
const REPLAN_DRIFT: int = 8000


## One think of a FLANK group with units, its living members.
static func think(world: World, group: AiGroup, units: Array[Unit]) -> void:
	var enemies: Array[Unit] = AiOrders.enemies(world, group.faction)
	var focus: Unit = _focus(world, group, units, enemies)
	if focus == null:
		group.focus_id = 0
		group.phase = 0
		AiOrders.engage(world, group, units, enemies)
		return
	if focus.id != group.focus_id:
		group.focus_id = focus.id
		group.phase = 0
	if group.phase == 1:
		if _found_out(group, units, enemies):
			group.phase = 2
		elif FixedMath.length(focus.x - group.plan_x, focus.z - group.plan_z) > REPLAN_DRIFT:
			group.phase = 0
	if group.phase == 0:
		_plan(world, group, units, focus, enemies)
	if group.phase == 1:
		_approach(world, group, units)
	if group.phase == 2:
		AiOrders.engage(world, group, units, enemies, 0, focus)


# The group's focus this think, or null for none. The one it has is kept
# while it is still a target: alive, seen (among enemies), of a role in
# flank_roles, and one some member can walk to or already reach. Otherwise
# the one of those nearest the members' centroid (center to center, then the
# lower id) that the leader, the lowest-id member, can walk to or reach.
static func _focus(world: World, group: AiGroup, units: Array[Unit], enemies: Array[Unit]) -> Unit:
	var roles: int = group.spec.flank_roles
	var kept: Unit = world.get_unit(group.focus_id) if group.focus_id != 0 else null
	if kept != null and enemies.has(kept) and _flankable(kept, roles):
		var one: Array[Unit] = [kept]
		for unit: Unit in units:
			if not AiOrders.reachable(world, unit, one).is_empty():
				return kept
	var c: Vector2i = AiOrders.centroid(units)
	var best: Unit = null
	var best_distance: int = 0
	for enemy: Unit in AiOrders.reachable(world, units[0], enemies):
		if not _flankable(enemy, roles):
			continue
		var distance: int = FixedMath.length(enemy.x - c.x, enemy.z - c.y)
		if best == null or distance < best_distance:
			best = enemy
			best_distance = distance
	return best


# True if unit's role is among roles (bits 1 << UnitType.Role, as
# AiGroupSpec.flank_roles).
static func _flankable(unit: Unit, roles: int) -> bool:
	return roles & (1 << unit.type.role) != 0


# Phase 0: plans the way to focus from the members' centroid (see the class
# doc) and moves to phase 1 with a route, or phase 2 without. A route is
# reported as one FLANK_WAYPOINT per waypoint, valued by its index.
static func _plan(
	world: World, group: AiGroup, units: Array[Unit], focus: Unit, enemies: Array[Unit]
) -> void:
	var from: Vector2i = AiOrders.centroid(units)
	var target: Vector2i = Vector2i(focus.x, focus.z)
	var screen: Array[Vector2i] = _screen(focus, enemies)
	group.route = PackedInt64Array()
	group.route_index = 0
	group.phase = 2
	if not FlankRoute.blocked(from, target, screen):
		return
	var leader: Unit = units[0]
	var mobility: Terrain.Mobility = leader.type.mobility
	var component: int = world.pathing.component_at(leader.x, leader.z, mobility)
	if component == PathLayer.NO_COMPONENT:
		return
	var plus: int = FlankRoute.lateral_reach(from, target, screen, 1)
	var minus: int = FlankRoute.lateral_reach(from, target, screen, -1)
	var first: int = 1 if plus <= minus else -1
	for side: int in [first, -first]:
		var route: PackedInt64Array = _on_map(world.terrain, FlankRoute.route(from, target, screen, side))
		var walkable: bool = true
		for k: int in route.size() >> 1:
			var at: int = world.pathing.component_at(route[2 * k], route[2 * k + 1], mobility)
			walkable = walkable and at == component
		if not walkable:
			continue
		group.route = route
		group.plan_x = focus.x
		group.plan_z = focus.z
		group.leg_active = false
		group.phase = 1
		for k: int in route.size() >> 1:
			world.ai_events.append(
				AiEvent.new(AiEvent.Kind.FLANK_WAYPOINT, group.id, route[2 * k], route[2 * k + 1], k)
			)
		return


# The positions of the seen enemy melee units other than focus within
# SCREEN_RADIUS of it, in ascending id.
static func _screen(focus: Unit, enemies: Array[Unit]) -> Array[Vector2i]:
	var out: Array[Vector2i] = []
	for enemy: Unit in enemies:
		if (
			enemy != focus and enemy.type.role == UnitType.Role.MELEE
			and FixedMath.length(enemy.x - focus.x, enemy.z - focus.z) <= SCREEN_RADIUS
		):
			out.append(Vector2i(enemy.x, enemy.z))
	return out


# route with every point clamped onto the map.
static func _on_map(terrain: Terrain, route: PackedInt64Array) -> PackedInt64Array:
	var out: PackedInt64Array = PackedInt64Array()
	for k: int in route.size() >> 1:
		out.append(clampi(route[2 * k], 0, terrain.extent_x()))
		out.append(clampi(route[2 * k + 1], 0, terrain.extent_z()))
	return out


# True if an approach is found out: a member lost hit points since the last
# think, or a seen enemy is within CONTACT (edge to edge) of a member.
static func _found_out(group: AiGroup, units: Array[Unit], enemies: Array[Unit]) -> bool:
	if AiOrders.hp_sum(units) < group.last_hp:
		return true
	for enemy: Unit in enemies:
		for unit: Unit in units:
			if Targeting.edge_distance(unit, enemy) <= CONTACT:
				return true
	return false


# Phase 1: walks the route one leg per waypoint with plain moves
# (AiBehaviors.leg). A leg that arrives or fails moves on to the next
# waypoint at once; after the last, phase 2.
static func _approach(world: World, group: AiGroup, units: Array[Unit]) -> void:
	while group.route_index < group.route.size() >> 1:
		var i: int = group.route_index
		var result: AiBehaviors.LegResult = AiBehaviors.leg(
			world, group, units, group.route[2 * i], group.route[2 * i + 1], false
		)
		if result == AiBehaviors.LegResult.RUNNING:
			return
		group.route_index += 1
	group.phase = 2
