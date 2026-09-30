class_name UnitOrders
extends RefCounted
## Turns group orders from commands into per-unit goals. A move order lays a
## formation at the target, assigns each unit a slot by minimum total travel,
## moves each slot to the nearest point that unit can actually reach, and
## hands the goals to UnitMovement.

## If the target is closer than this to the group's centroid, the group keeps
## its current mean facing instead of facing the (tiny) move direction.
const KEEP_FACING_RADIUS: int = 2000


## Orders the living units among unit_ids to (x, z) in a formation
## (Formations.Kind; out-of-range values mean SHORT_LINE). Duplicate, missing,
## and dead ids are ignored. The group marches at its slowest member's speed.
static func move(world: World, unit_ids: PackedInt32Array, x: int, z: int, formation: int) -> void:
	var group: Array[Unit] = _living_units(world, unit_ids)
	if group.is_empty() or world.terrain == null:
		return
	var n: int = group.size()
	var sum_x: int = 0
	var sum_z: int = 0
	var max_radius: int = 0
	var min_speed: int = group[0].type.move_speed
	var unit_positions: Array[Vector2i] = []
	for unit: Unit in group:
		sum_x += unit.x
		sum_z += unit.z
		max_radius = maxi(max_radius, unit.type.body_radius)
		min_speed = mini(min_speed, unit.type.move_speed)
		unit_positions.append(Vector2i(unit.x, unit.z))
	var facing: Vector2i = _order_facing(
		group, FixedMath.div_round(sum_x, n), FixedMath.div_round(sum_z, n), x, z
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
	var assignment: PackedInt32Array = SlotAssignment.assign(unit_positions, slot_positions)
	var cap: int = min_speed if n > 1 else 0
	for i: int in n:
		var unit: Unit = group[i]
		var slot: FormationSlot = slots[assignment[i]]
		var mobility: Terrain.Mobility = unit.type.mobility
		var component: int = world.pathing.component_at(unit.x, unit.z, mobility)
		var goal: Vector2i = world.pathing.snap_to_component(slot.x, slot.z, mobility, component)
		world.movement.order_move(world, unit, goal.x, goal.y, slot.facing_x, slot.facing_z, cap)


## Halts the living units among unit_ids where they stand.
static func stop(world: World, unit_ids: PackedInt32Array) -> void:
	for unit: Unit in _living_units(world, unit_ids):
		world.movement.order_stop(unit)


## The living units named by unit_ids, deduplicated, in ascending id order, so
## the result doesn't depend on the order the player selected them in.
static func _living_units(world: World, unit_ids: PackedInt32Array) -> Array[Unit]:
	var ids: PackedInt32Array = unit_ids.duplicate()
	ids.sort()
	var group: Array[Unit] = []
	var previous: int = -1
	for unit_id: int in ids:
		if unit_id == previous:
			continue
		previous = unit_id
		var unit: Unit = world.get_unit(unit_id)
		if unit != null and unit.is_alive():
			group.append(unit)
	return group


# Facing for the formation: from the centroid toward the target, or the
# group's mean facing when the target is too close to give a direction.
static func _order_facing(group: Array[Unit], cx: int, cz: int, x: int, z: int) -> Vector2i:
	if FixedMath.length(x - cx, z - cz) >= KEEP_FACING_RADIUS:
		return FixedMath.normalize(x - cx, z - cz, FixedMath.DIR_ONE)
	var fx: int = 0
	var fz: int = 0
	for unit: Unit in group:
		fx += unit.facing_x
		fz += unit.facing_z
	var mean: Vector2i = FixedMath.normalize(fx, fz, FixedMath.DIR_ONE)
	return mean if mean != Vector2i.ZERO else Vector2i(0, -FixedMath.DIR_ONE)
