class_name UnitOrders
extends RefCounted
## Turns group orders from commands into per-unit goals. A move order lays a
## formation at the target, assigns each unit a slot by minimum total travel,
## moves each slot to the nearest point that unit can actually reach, and
## hands the goals to UnitMovement.

## If the target is closer than this to the group's centroid, the group keeps
## its current mean facing instead of facing the (tiny) move direction.
const KEEP_FACING_RADIUS: int = 2000
## Scatter (B): how far each unit runs from the group's centroid.
const SCATTER_DISTANCE: int = 8000
## A unit standing on the centroid has no direction away from it; it takes
## one from its id, this many binary angles (of 1024) apart from the last id's:
## the golden angle, so neighbors' directions never bunch up.
const SCATTER_GOLDEN_ANGLE: int = 391
## Retreat (R): how far the group falls back, and how far from its centroid
## it looks for the enemy to fall back from.
const RETREAT_DISTANCE: int = 15000
const RETREAT_SCAN: int = 40000


## Orders the living units among unit_ids to (x, z) in a formation
## (Formations.Kind; out-of-range values mean SHORT_LINE). Duplicate, missing,
## and dead ids are ignored. The group marches at its slowest member's speed.
## A plain move ignores enemies on the way; with attack set, units fight
## what they meet (MeleeCombat) and resume toward their slot after each
## fight. Either way the new order drops the current fight.
##
## The formation faces (facing_x, facing_z), normalized here. A zero facing
## is the automatic one: from the group's centroid toward the target, or the
## group's mean facing when the target is too close to give a direction.
static func move(
	world: World, unit_ids: PackedInt32Array, x: int, z: int, formation: int, attack: bool = false,
	facing_x: int = 0, facing_z: int = 0
) -> void:
	var group: Array[Unit] = living_units(world, unit_ids)
	if group.is_empty() or world.terrain == null:
		return
	var n: int = group.size()
	var sum_x: int = 0
	var sum_z: int = 0
	var max_radius: int = 0
	var min_speed: int = Veterancy.move_speed(group[0])
	var unit_positions: Array[Vector2i] = []
	for unit: Unit in group:
		sum_x += unit.x
		sum_z += unit.z
		max_radius = maxi(max_radius, unit.type.body_radius)
		min_speed = mini(min_speed, Veterancy.move_speed(unit))
		unit_positions.append(Vector2i(unit.x, unit.z))
	var facing: Vector2i = FixedMath.normalize(facing_x, facing_z, FixedMath.DIR_ONE)
	if facing == Vector2i.ZERO:
		facing = order_facing(group, FixedMath.div_round(sum_x, n), FixedMath.div_round(sum_z, n), x, z)
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
		UnitRoute.clear(unit)
		unit.clear_engagement()
		unit.clear_shot()
		unit.ground_walked = false
		unit.order = Unit.Order.ATTACK_MOVE if attack else Unit.Order.MOVE
		unit.order_x = goal.x
		unit.order_z = goal.y
		unit.order_facing_x = slot.facing_x
		unit.order_facing_z = slot.facing_z
		unit.order_speed_cap = cap
		world.movement.order_move(world, unit, goal.x, goal.y, slot.facing_x, slot.facing_z, cap)


## Halts the living units among unit_ids where they stand. They hold that
## spot and fight enemies that come adjacent.
static func stop(world: World, unit_ids: PackedInt32Array) -> void:
	for unit: Unit in living_units(world, unit_ids):
		UnitRoute.clear(unit)
		hold(unit)
		world.movement.order_stop(unit)


## Orders the living ranged units among unit_ids to bombard the ground at
## (x, z) until told otherwise, walking into range first if they must.
## Units without a ranged attack ignore it. RangedCombat carries it out.
static func ground_attack(world: World, unit_ids: PackedInt32Array, x: int, z: int) -> void:
	for unit: Unit in living_units(world, unit_ids):
		if not unit.type.has_ranged():
			continue
		UnitRoute.clear(unit)
		hold(unit)
		unit.order = Unit.Order.GROUND_ATTACK
		unit.ground_x = x
		unit.ground_z = z
		world.movement.order_stop(unit)


## B: each living unit among unit_ids runs SCATTER_DISTANCE straight away
## from the group's centroid, at its own pace and ignoring enemies, then
## holds there facing outward: "flee in all directions away from the center"
## (Myth II). A unit on the centroid takes a direction from its id. No dice.
static func scatter(world: World, unit_ids: PackedInt32Array) -> void:
	var group: Array[Unit] = living_units(world, unit_ids)
	if group.is_empty() or world.terrain == null:
		return
	var center: Vector2i = _centroid(group)
	for unit: Unit in group:
		var away: Vector2i = FixedMath.normalize(unit.x - center.x, unit.z - center.y, FixedMath.DIR_ONE)
		if away == Vector2i.ZERO:
			var angle: int = (unit.id * SCATTER_GOLDEN_ANGLE) % FixedMath.ANGLE_FULL
			away = Vector2i(
				FixedMath.div_round(FixedMath.DIR_ONE * FixedMath.sin_b(angle), FixedMath.TRIG_ONE),
				-FixedMath.div_round(FixedMath.DIR_ONE * FixedMath.cos_b(angle), FixedMath.TRIG_ONE)
			)
		var x: int = unit.x + FixedMath.div_round(away.x * SCATTER_DISTANCE, FixedMath.DIR_ONE)
		var z: int = unit.z + FixedMath.div_round(away.y * SCATTER_DISTANCE, FixedMath.DIR_ONE)
		var mobility: Terrain.Mobility = unit.type.mobility
		var goal: Vector2i = world.pathing.snap_to_component(
			x, z, mobility, world.pathing.component_at(unit.x, unit.z, mobility)
		)
		UnitRoute.clear(unit)
		unit.clear_engagement()
		unit.clear_shot()
		unit.ground_walked = false
		unit.order = Unit.Order.MOVE
		unit.order_x = goal.x
		unit.order_z = goal.y
		unit.order_facing_x = away.x
		unit.order_facing_z = away.y
		unit.order_speed_cap = 0
		world.movement.order_move(world, unit, goal.x, goal.y, away.x, away.y, 0)


## R: the group falls back RETREAT_DISTANCE from the enemy nearest its
## centroid (within RETREAT_SCAN; not one hidden in deep water), in
## `formation` and at its slowest member's pace, ignoring enemies on the way,
## and ends facing that enemy: Myth II's "run from the nearest enemy", kept
## in good order. With no enemy in sight it backs off against its mean
## facing and keeps facing forward.
static func retreat(world: World, unit_ids: PackedInt32Array, formation: int) -> void:
	var group: Array[Unit] = living_units(world, unit_ids)
	if group.is_empty() or world.terrain == null:
		return
	var center: Vector2i = _centroid(group)
	var threat: Unit = _nearest_enemy(world, group[0].faction, center, RETREAT_SCAN)
	var away: Vector2i = Vector2i.ZERO
	if threat != null:
		away = FixedMath.normalize(center.x - threat.x, center.y - threat.z, FixedMath.DIR_ONE)
	var face: Vector2i = -away
	if away == Vector2i.ZERO:
		var fx: int = 0
		var fz: int = 0
		for unit: Unit in group:
			fx += unit.facing_x
			fz += unit.facing_z
		face = FixedMath.normalize(fx, fz, FixedMath.DIR_ONE)
		if face == Vector2i.ZERO:
			face = Formations.NORTH
		away = -face
	move(
		world, unit_ids,
		center.x + FixedMath.div_round(away.x * RETREAT_DISTANCE, FixedMath.DIR_ONE),
		center.y + FixedMath.div_round(away.y * RETREAT_DISTANCE, FixedMath.DIR_ONE),
		formation, false, face.x, face.y
	)


## G: each living unit among unit_ids guards the spot it stands on, facing
## the way it faces now (Guard). Drops whatever it was doing.
static func guard(world: World, unit_ids: PackedInt32Array) -> void:
	for unit: Unit in living_units(world, unit_ids):
		UnitRoute.clear(unit)
		hold(unit)
		unit.order = Unit.Order.GUARD
		world.movement.order_stop(unit)


## T: each living unit among unit_ids uses its special if it has one left.
## A Sapper drops a charge at its feet; a Longbow nocks its fire arrow (the
## charge is spent when the arrow leaves); a Blightbag bursts. A Warden's heal
## needs a patient, so it comes as a HealCommand instead.
static func use_special(world: World, unit_ids: PackedInt32Array) -> void:
	for unit: Unit in living_units(world, unit_ids):
		if unit.special_left <= 0:
			continue
		match unit.type.special_ability:
			UnitType.Special.SATCHEL:
				unit.special_left -= 1
				world.drop_charge(unit, unit.x, unit.z)
			UnitType.Special.FIRE_ARROW:
				unit.fire_nocked = true
			UnitType.Special.DETONATE:
				Damage.self_destruct(world, unit)


## Puts the unit back on its own order after something overrode it (a
## confusion wearing off): drops whatever it was fighting or shooting, then
## marches on to a move or attack-move's goal, stands at a ground attack (it
## walks into range again if it must), or holds where it stands.
static func resume(world: World, unit: Unit) -> void:
	unit.clear_engagement()
	unit.clear_shot()
	unit.ground_walked = false
	match unit.order:
		Unit.Order.MOVE, Unit.Order.ATTACK_MOVE:
			world.movement.order_move(
				world, unit, unit.order_x, unit.order_z,
				unit.order_facing_x, unit.order_facing_z, unit.order_speed_cap
			)
		Unit.Order.GROUND_ATTACK:
			world.movement.order_stop(unit)
		Unit.Order.INTERACT:
			Interactions.restart(world, unit)
		Unit.Order.GUARD:
			# Still on guard: Guard walks it home from wherever it stands.
			world.movement.order_stop(unit)
		_:
			hold(unit)
			world.movement.order_stop(unit)


## Gives the unit order NONE, holding where it stands now. Drops any fight.
static func hold(unit: Unit) -> void:
	unit.clear_engagement()
	unit.clear_shot()
	unit.ground_walked = false
	unit.order = Unit.Order.NONE
	unit.order_x = unit.x
	unit.order_z = unit.z
	unit.order_facing_x = unit.facing_x
	unit.order_facing_z = unit.facing_z
	unit.order_speed_cap = 0


## The living units named by unit_ids, deduplicated, in ascending id order, so
## the result doesn't depend on the order the player selected them in. Every
## group command starts from this.
static func living_units(world: World, unit_ids: PackedInt32Array) -> Array[Unit]:
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


static func _centroid(group: Array[Unit]) -> Vector2i:
	var sum_x: int = 0
	var sum_z: int = 0
	for unit: Unit in group:
		sum_x += unit.x
		sum_z += unit.z
	return Vector2i(FixedMath.div_round(sum_x, group.size()), FixedMath.div_round(sum_z, group.size()))


# The living, visible enemy of `side` nearest (x, z) within radius, or null.
# Ties go to the lower id.
static func _nearest_enemy(world: World, side: UnitType.Faction, at: Vector2i, radius: int) -> Unit:
	var best: Unit = null
	var best_d: int = 0
	for other: Unit in world.units:
		if not other.is_alive() or other.faction == side or Visibility.is_submerged(world.terrain, other):
			continue
		var d: int = FixedMath.length(other.x - at.x, other.z - at.y)
		if d > radius:
			continue
		if best == null or d < best_d:
			best = other
			best_d = d
	return best


## Facing for a formation laid at (x, z) by a group centered on (cx, cz):
## toward the target, or the group's mean facing when the target is too close
## to give a direction.
static func order_facing(group: Array[Unit], cx: int, cz: int, x: int, z: int) -> Vector2i:
	if FixedMath.length(x - cx, z - cz) >= KEEP_FACING_RADIUS:
		return FixedMath.normalize(x - cx, z - cz, FixedMath.DIR_ONE)
	var fx: int = 0
	var fz: int = 0
	for unit: Unit in group:
		fx += unit.facing_x
		fz += unit.facing_z
	var mean: Vector2i = FixedMath.normalize(fx, fz, FixedMath.DIR_ONE)
	return mean if mean != Vector2i.ZERO else Vector2i(0, -FixedMath.DIR_ONE)
