class_name UnitRoute
extends RefCounted
## Waypoints and patrols (Phase 11): a route of up to MAX_POINTS points on
## each unit, walked one leg at a time. ("Waypoint" already means a point on
## an A* path, Unit.path; these are a route's points.)
##
## Shift+order gives a route point (add_point, RoutePointCommand). The group's
## formation is laid at the click, and each unit's slot there is its own
## point, so the group keeps its shape from point to point. A unit without a
## route starts one and sets out at once; a unit with an open route of fewer
## than MAX_POINTS points appends; a full one ignores the point, and a closed
## one (a patrol) is replaced by a new route. Shift+order on the route's first
## point again closes it into a loop, on its last point into a back-and-forth
## (close, PatrolCommand): those are patrols, and patrols fight, so their legs
## become attack-moves.
##
## A leg is an ordinary MOVE or ATTACK_MOVE order to the point (order_x/z, the
## point's facing, the route's pace in order_speed_cap), so everything that
## already puts a unit back on its order after a fight, an errand or a
## confusion marches it on along the leg it was on. Only arrival differs:
## where MeleeCombat would end the order (the unit holds), it asks advance()
## first, which sends the unit down the next leg instead. A leg the unit ends
## more than ROUTE_MISS short of (it gave up: the point is out of reach) ends
## the route, so a patrol can't re-run A* at an unreachable point forever.
##
## Any other order clears the route (clear()): moves, stop, ground attack,
## guard, scatter, retreat, an errand ordered by the player, death. An errand
## a unit takes on itself (a Ripper scavenging) and a special don't.

enum Mode {
	## Walk the points in order, then hold at the last.
	OPEN,
	## After the last point, the first again, for good.
	LOOP,
	## First to last and back again, for good.
	BACK_AND_FORTH,
}

const MAX_POINTS: int = 4
## Ints per point in Unit.route: x, z, facing_x, facing_z.
const STRIDE: int = 4
## A leg ended farther than this from its point means the point is out of
## reach: the route ends there.
const ROUTE_MISS: int = 4000


## Adds the point (x, z) to the routes of the living units among unit_ids,
## laying `formation` there, facing (facing_x, facing_z) or, if that is zero,
## from where the group's routes stand toward the point. With attack, a new
## route's legs are attack-moves. See the class comment.
static func add_point(
	world: World, unit_ids: PackedInt32Array, x: int, z: int, formation: int, attack: bool,
	facing_x: int = 0, facing_z: int = 0
) -> void:
	if world.terrain == null:
		return
	var members: Array[Unit] = []
	for unit: Unit in UnitOrders.living_units(world, unit_ids):
		if not is_full(unit):
			members.append(unit)
	if members.is_empty():
		return
	var n: int = members.size()
	var anchors: Array[Vector2i] = []
	var sum_x: int = 0
	var sum_z: int = 0
	var max_radius: int = 0
	var min_speed: int = Veterancy.move_speed(members[0])
	for unit: Unit in members:
		var anchor: Vector2i = last_point(unit) if extends_route(unit) else Vector2i(unit.x, unit.z)
		anchors.append(anchor)
		sum_x += anchor.x
		sum_z += anchor.y
		max_radius = maxi(max_radius, unit.type.body_radius)
		min_speed = mini(min_speed, Veterancy.move_speed(unit))
	var facing: Vector2i = FixedMath.normalize(facing_x, facing_z, FixedMath.DIR_ONE)
	if facing == Vector2i.ZERO:
		facing = UnitOrders.order_facing(
			members, FixedMath.div_round(sum_x, n), FixedMath.div_round(sum_z, n), x, z
		)
	var kind: Formations.Kind = Formations.Kind.SHORT_LINE
	if formation >= 0 and formation < Formations.Kind.size():
		kind = formation as Formations.Kind
	var slots: Array[FormationSlot] = Formations.slots(
		kind, n, x, z, facing.x, facing.y, Formations.spacing_for(max_radius)
	)
	var slot_positions: Array[Vector2i] = []
	for slot: FormationSlot in slots:
		slot_positions.append(Vector2i(slot.x, slot.z))
	var assignment: PackedInt32Array = SlotAssignment.assign(anchors, slot_positions)
	var cap: int = min_speed if n > 1 else 0
	for i: int in n:
		var unit: Unit = members[i]
		var slot: FormationSlot = slots[assignment[i]]
		var mobility: Terrain.Mobility = unit.type.mobility
		var component: int = world.pathing.component_at(unit.x, unit.z, mobility)
		var goal: Vector2i = world.pathing.snap_to_component(slot.x, slot.z, mobility, component)
		var entry: PackedInt32Array = PackedInt32Array([goal.x, goal.y, slot.facing_x, slot.facing_z])
		if extends_route(unit):
			unit.route.append_array(entry)
			continue
		clear(unit)
		unit.route = entry
		unit.route_attack = attack
		unit.order_speed_cap = cap
		_walk_leg(world, unit)


## Closes the routes of the living units among unit_ids that have an open
## route of at least two points into a patrol (Mode.LOOP or BACK_AND_FORTH).
## Patrols fight: the leg under way becomes an attack-move too.
static func close(world: World, unit_ids: PackedInt32Array, mode: Mode) -> void:
	if mode == Mode.OPEN:
		return
	for unit: Unit in UnitOrders.living_units(world, unit_ids):
		if unit.route_mode != Mode.OPEN or point_count(unit) < 2:
			continue
		unit.route_mode = mode
		unit.route_attack = true
		if unit.order == Unit.Order.MOVE:
			unit.order = Unit.Order.ATTACK_MOVE


## Called where the unit's MOVE or ATTACK_MOVE order has just ended (it
## arrived, or gave up). Sends it down its route's next leg and returns true;
## returns false, with the route cleared, if there is no route, it is done,
## or the leg ended too far from its point.
static func advance(world: World, unit: Unit) -> bool:
	if unit.route.is_empty():
		return false
	var at: int = unit.route_index * STRIDE
	if FixedMath.length(unit.route[at] - unit.x, unit.route[at + 1] - unit.z) > ROUTE_MISS:
		clear(unit)
		return false
	var count: int = point_count(unit)
	var next: int = unit.route_index + unit.route_step
	match unit.route_mode:
		Mode.OPEN:
			if next >= count:
				clear(unit)
				return false
		Mode.LOOP:
			next = posmod(next, count)
		Mode.BACK_AND_FORTH:
			if next < 0 or next >= count:
				unit.route_step = -unit.route_step
				next = unit.route_index + unit.route_step
	unit.route_index = next
	_walk_leg(world, unit)
	return true


## Forgets the unit's route. Leaves its order alone.
static func clear(unit: Unit) -> void:
	unit.route = PackedInt32Array()
	unit.route_index = 0
	unit.route_mode = Mode.OPEN
	unit.route_step = 1
	unit.route_attack = false


static func point_count(unit: Unit) -> int:
	return unit.route.size() / STRIDE


## Point i of the unit's route, (x, z).
static func point(unit: Unit, i: int) -> Vector2i:
	return Vector2i(unit.route[i * STRIDE], unit.route[i * STRIDE + 1])


static func last_point(unit: Unit) -> Vector2i:
	return point(unit, point_count(unit) - 1)


## True if a new point would be appended to the unit's route.
static func extends_route(unit: Unit) -> bool:
	return not unit.route.is_empty() and unit.route_mode == Mode.OPEN and point_count(unit) < MAX_POINTS


## True if a new point would be ignored: the open route has MAX_POINTS.
static func is_full(unit: Unit) -> bool:
	return unit.route_mode == Mode.OPEN and point_count(unit) >= MAX_POINTS


# Sends the unit to its route's current point.
static func _walk_leg(world: World, unit: Unit) -> void:
	var at: int = unit.route_index * STRIDE
	unit.clear_engagement()
	unit.clear_shot()
	unit.ground_walked = false
	unit.order = Unit.Order.ATTACK_MOVE if unit.route_attack else Unit.Order.MOVE
	unit.order_x = unit.route[at]
	unit.order_z = unit.route[at + 1]
	unit.order_facing_x = unit.route[at + 2]
	unit.order_facing_z = unit.route[at + 3]
	world.movement.order_move(
		world, unit, unit.order_x, unit.order_z,
		unit.order_facing_x, unit.order_facing_z, unit.order_speed_cap
	)
