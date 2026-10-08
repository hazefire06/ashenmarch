class_name OrdersDrill
extends RefCounted
## Every order Phase 11 added, given to one side's units on a fixed schedule:
## a move with a facing and the same move rotated (the arrow keys re-issue it
## that way), guard, scatter, retreat, a three-point loop for everyone, then
## a back-and-forth with attack legs for half of them, an attack-move, and
## guard again. The golden riverside_orders_t2 is recorded from it
## (scripts/make_golden_replays.gd) and tests/sim/test_replay.gd records and
## replays it.
##
## It reads only the World's integers (positions, ids, sides) to place its
## orders, unlike the playtest pilot, so the same world gives the same
## commands on any platform. It doesn't try to win.

const M: int = 1000
## Ticks at which orders(world, side) gives something.
const SCHEDULE: Array[int] = [30, 150, 450, 750, 1050, 1350, 1360, 1370, 1380, 2700, 2710, 2720, 3600, 4500]
## The binary angle (1024 to a turn) a rotated move turns by: 22.5 degrees,
## the arrow keys' step.
const ROTATE_STEP: int = 64


## The commands for world.tick, stamped with it; empty on most ticks.
static func orders(world: World, side: UnitType.Faction) -> Array[SimCommand]:
	var out: Array[SimCommand] = []
	var tick: int = world.tick
	if not SCHEDULE.has(tick):
		return out
	var mine: PackedInt32Array = side_units(world, side)
	if mine.is_empty():
		return out
	var center: Vector2i = _centroid(world, mine)
	var ahead: Vector2i = _toward_enemy(world, side, center)
	var right: Vector2i = Vector2i(-ahead.y, ahead.x)
	match tick:
		30:
			var target: Vector2i = center + ahead * 20
			out.append(MoveUnitsCommand.new(tick, mine, target.x, target.y, Formations.Kind.LONG_LINE, right.x, right.y))
		150:
			var target: Vector2i = _centroid_of_orders(world, mine)
			var turned: Vector2i = _rotate(right, ROTATE_STEP)
			out.append(MoveUnitsCommand.new(tick, mine, target.x, target.y, Formations.Kind.LONG_LINE, turned.x, turned.y))
		450:
			out.append(GuardCommand.new(tick, mine))
		750:
			out.append(ScatterCommand.new(tick, mine))
		1050:
			out.append(RetreatCommand.new(tick, mine, Formations.Kind.WEDGE))
		1350, 1360, 1370:
			var offsets: Dictionary[int, Vector2i] = {1350: right * 15, 1360: right * 15 + ahead * 15, 1370: ahead * 15}
			var p: Vector2i = center + offsets[tick]
			out.append(RoutePointCommand.new(tick, mine, p.x, p.y, Formations.Kind.BOX, false))
		1380:
			out.append(PatrolCommand.new(tick, mine, UnitRoute.Mode.LOOP))
		2700, 2710:
			var half: PackedInt32Array = mine.slice(0, maxi(1, mine.size() / 2))
			var p: Vector2i = center + (ahead * 12 if tick == 2700 else -right * 12)
			out.append(RoutePointCommand.new(tick, half, p.x, p.y, Formations.Kind.SHORT_LINE, true))
		2720:
			out.append(PatrolCommand.new(tick, mine.slice(0, maxi(1, mine.size() / 2)), UnitRoute.Mode.BACK_AND_FORTH))
		3600:
			var target: Vector2i = center + ahead * 30
			out.append(AttackMoveCommand.new(tick, mine, target.x, target.y, Formations.Kind.STAGGERED_LINE))
		4500:
			out.append(GuardCommand.new(tick, mine))
	return out


## The living units of `side` that the player commands (not one an AI group
## leads), in id order.
static func side_units(world: World, side: UnitType.Faction) -> PackedInt32Array:
	var ids: PackedInt32Array = PackedInt32Array()
	for unit: Unit in world.units:
		if unit.is_alive() and unit.faction == side and not world.ai.controls(unit.id):
			ids.append(unit.id)
	return ids


static func _centroid(world: World, ids: PackedInt32Array) -> Vector2i:
	var sum: Vector2i = Vector2i.ZERO
	for unit_id: int in ids:
		var unit: Unit = world.get_unit(unit_id)
		sum += Vector2i(unit.x, unit.z)
	return Vector2i(FixedMath.div_round(sum.x, ids.size()), FixedMath.div_round(sum.y, ids.size()))


# Where the units are headed, on average: their orders' spots.
static func _centroid_of_orders(world: World, ids: PackedInt32Array) -> Vector2i:
	var sum: Vector2i = Vector2i.ZERO
	for unit_id: int in ids:
		var unit: Unit = world.get_unit(unit_id)
		sum += Vector2i(unit.order_x, unit.order_z)
	return Vector2i(FixedMath.div_round(sum.x, ids.size()), FixedMath.div_round(sum.y, ids.size()))


# A metre-long step (milli-units) toward the enemy nearest `center`, or north.
static func _toward_enemy(world: World, side: UnitType.Faction, center: Vector2i) -> Vector2i:
	var best: Unit = null
	var best_d: int = 0
	for unit: Unit in world.units:
		if not unit.is_alive() or unit.faction == side or Visibility.is_submerged(world.terrain, unit):
			continue
		var d: int = FixedMath.length(unit.x - center.x, unit.z - center.y)
		if best == null or d < best_d:
			best = unit
			best_d = d
	if best == null:
		return Vector2i(0, -M)
	var dir: Vector2i = FixedMath.normalize(best.x - center.x, best.z - center.y, M)
	return dir if dir != Vector2i.ZERO else Vector2i(0, -M)


# v (length M) turned by a binary angle.
static func _rotate(v: Vector2i, angle: int) -> Vector2i:
	var s: int = FixedMath.sin_b(angle)
	var c: int = FixedMath.cos_b(angle)
	return Vector2i(
		FixedMath.div_round(v.x * c - v.y * s, FixedMath.TRIG_ONE),
		FixedMath.div_round(v.x * s + v.y * c, FixedMath.TRIG_ONE)
	)
