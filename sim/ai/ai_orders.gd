class_name AiOrders
extends RefCounted
## How the AI hands out orders: who may be given one, where to send them,
## and when to leave them alone. Static helpers over a World and an AiGroup;
## the only state is what AiGroup records (ordered_x/z/target).
##
## The AI orders units the way a player does, through UnitOrders.move. A new
## move drops whatever the unit was in the middle of, so the AI only re-orders
## a free member (is_free) unless a behavior overrides that on purpose, and
## only when its plan for that member changed: the recorded goal or objective
## differs from the new one. Members are ordered in buckets, one move per
## bucket: a bucket is the members of one type standing in one pathing
## component. Per type, so a fast type isn't held to a slow one's pace
## (UnitOrders.move caps a group at its slowest member); per component, so a
## bucket's leader can walk wherever the rest of it can.

## Least drift (milli-units) of an objective from where a member was sent
## before the member is re-sent after it. See _should_reorder.
const REORDER_MIN: int = 4000
## A bucket key holds the type index above this many bits and the pathing
## component (offset so NO_COMPONENT is 0) below them.
const _COMPONENT_BITS: int = 32


## True if the AI may give the unit a new order without spoiling what it is
## doing: it is alive, not confused, not on an errand, not fighting or
## chasing, not standing to fight or shoot, not drawing, swinging or acting,
## and not waiting for a path. UnitOrders.move drops fights, casts, swings and
## errands, and a path solve still in the queue would be thrown away.
static func is_free(world: World, unit: Unit) -> bool:
	return (
		unit.is_alive()
		and not StatusEffects.confused(world, unit)
		and unit.order != Unit.Order.INTERACT
		and unit.target_id == 0
		and unit.state != Unit.State.ATTACKING
		and unit.state != Unit.State.SHOOTING
		and unit.aim_left == 0
		and unit.windup_left == 0
		and unit.act_left == 0
		and not unit.path_pending
	)


## True if the unit has finished its last order: it holds (NONE), or it has
## stopped walking a move or attack-move, having arrived or given up.
## MeleeCombat turns the latter into NONE on its next tick.
static func is_done(unit: Unit) -> bool:
	if unit.order == Unit.Order.NONE:
		return true
	return (
		unit.state == Unit.State.IDLE
		and (unit.order == Unit.Order.MOVE or unit.order == Unit.Order.ATTACK_MOVE)
	)


## The living units of every side but faction that aren't hidden in deep
## water (Visibility.is_submerged), in ascending id order: what a group of
## that faction can see to fight.
static func enemies(world: World, faction: UnitType.Faction) -> Array[Unit]:
	var out: Array[Unit] = []
	for unit: Unit in world.units:
		if unit.is_alive() and unit.faction != faction and not Visibility.is_submerged(world.terrain, unit):
			out.append(unit)
	return out


## Total hit points of units.
static func hp_sum(units: Array[Unit]) -> int:
	var total: int = 0
	for unit: Unit in units:
		total += unit.hp
	return total


## Mean position of units, rounded to the nearest milli-unit; (0, 0) for none.
static func centroid(units: Array[Unit]) -> Vector2i:
	if units.is_empty():
		return Vector2i.ZERO
	var sum_x: int = 0
	var sum_z: int = 0
	for unit: Unit in units:
		sum_x += unit.x
		sum_z += unit.z
	return Vector2i(FixedMath.div_round(sum_x, units.size()), FixedMath.div_round(sum_z, units.size()))


## Sends members of group among units to (x, z) in the group's formation,
## attack-moving if attack. Normally only free members not already sent there
## go; with force, every living member in units goes, busy or not (a leg's
## start, a recall). One UnitOrders.move and one ORDER event per bucket, and
## each member's goal is recorded with no objective.
static func march(
	world: World, group: AiGroup, units: Array[Unit], x: int, z: int, attack: bool, force: bool = false
) -> void:
	var picked: Array[Unit] = []
	for unit: Unit in units:
		if not unit.is_alive():
			continue
		if not force:
			var i: int = group.member_index(unit.id)
			if not is_free(world, unit) or (group.ordered_x[i] == x and group.ordered_z[i] == z):
				continue
		picked.append(unit)
	for key: int in _bucket_keys(world, picked):
		_order(world, group, _bucket(world, picked, key), x, z, attack, 0)


## Sends the free members among units after an objective picked from
## candidates. Per bucket, its lowest-id member leads: the objective is the
## candidate the leader ranks best (Targeting.pick: preferred roles, then the
## nearest, then the lower id) among those it can walk to or already reach. A
## bucket with nothing to go after is left alone. Members the plan hasn't
## changed for keep their orders (_should_reorder); the rest attack-move to
## the objective in one move. Returns true if any bucket had an objective,
## whether or not anyone needed a new order; false if none could get at any
## candidate (or no member was free).
static func engage(world: World, group: AiGroup, units: Array[Unit], candidates: Array[Unit]) -> bool:
	var free: Array[Unit] = []
	for unit: Unit in units:
		if is_free(world, unit):
			free.append(unit)
	var any_objective: bool = false
	for key: int in _bucket_keys(world, free):
		var bucket: Array[Unit] = _bucket(world, free, key)
		var objective: Unit = Targeting.pick(bucket[0], _reachable(world, bucket[0], candidates))
		if objective == null:
			continue
		any_objective = true
		var sent: Array[Unit] = []
		for member: Unit in bucket:
			if _should_reorder(member, objective, group):
				sent.append(member)
		if not sent.is_empty():
			_order(world, group, sent, objective.x, objective.z, true, objective.id)
	return any_objective


# One UnitOrders.move for units (non-empty, ascending id) to (x, z) after
# objective_id (0 for none): recorded per member, reported as one ORDER
# event naming the lowest id.
static func _order(
	world: World, group: AiGroup, units: Array[Unit], x: int, z: int, attack: bool, objective_id: int
) -> void:
	var ids: PackedInt32Array = PackedInt32Array()
	for unit: Unit in units:
		ids.append(unit.id)
	UnitOrders.move(world, ids, x, z, group.spec.formation, attack)
	for unit_id: int in ids:
		group.record_order(unit_id, x, z, objective_id)
	world.ai_events.append(AiEvent.new(AiEvent.Kind.ORDER, group.id, x, z, 1 if attack else 0, ids[0]))


# Whether a free member already sent after objective should be sent again:
# - it was sent after something else;
# - it finished its order out of its acquire radius of the objective, so
#   melee won't pick it up from there;
# - or the objective has drifted from where the member was sent by more
#   than a quarter of the member's distance to it (at least REORDER_MIN).
# That last slack is the hysteresis: a far objective needs only a rough
# heading, and once the member is within its acquire radius MeleeCombat's own
# chase takes over and re-paths every metre of drift, so the AI doesn't.
static func _should_reorder(member: Unit, objective: Unit, group: AiGroup) -> bool:
	var i: int = group.member_index(member.id)
	if group.ordered_target[i] != objective.id:
		return true
	if is_done(member) and Targeting.edge_distance(member, objective) > member.type.acquire_radius:
		return true
	var drift: int = FixedMath.length(objective.x - group.ordered_x[i], objective.z - group.ordered_z[i])
	var slack: int = maxi(REORDER_MIN, FixedMath.length(objective.x - member.x, objective.z - member.z) / 4)
	return drift > slack


# The candidates leader could fight: those in its pathing component for its
# mobility, plus any already within its melee reach (across a ford, say), in
# the order given.
static func _reachable(world: World, leader: Unit, candidates: Array[Unit]) -> Array[Unit]:
	var mobility: Terrain.Mobility = leader.type.mobility
	var component: int = world.pathing.component_at(leader.x, leader.z, mobility)
	var out: Array[Unit] = []
	for other: Unit in candidates:
		var walkable: bool = (
			component != PathLayer.NO_COMPONENT
			and world.pathing.component_at(other.x, other.z, mobility) == component
		)
		if walkable or Targeting.in_reach(leader, other):
			out.append(other)
	return out


# Which bucket a member is ordered in: its type, then the pathing component
# it stands in for its mobility. The one place buckets are defined. Members
# of one bucket move as one formation at the slowest one's pace, and its
# leader picks objectives every one of them can walk to: a member across a
# river from its leader would otherwise be sent at something it can never
# reach, stop on its own bank, and be sent again at every think.
static func _bucket_key(world: World, unit: Unit) -> int:
	var component: int = world.pathing.component_at(unit.x, unit.z, unit.type.mobility)
	return (unit.type_index << _COMPONENT_BITS) | (component - PathLayer.NO_COMPONENT)


# The bucket keys among units, ascending: the order buckets are ordered in.
static func _bucket_keys(world: World, units: Array[Unit]) -> PackedInt64Array:
	var keys: PackedInt64Array = PackedInt64Array()
	for unit: Unit in units:
		var key: int = _bucket_key(world, unit)
		if not keys.has(key):
			keys.append(key)
	keys.sort()
	return keys


# The units in bucket key, in the order given (ascending id).
static func _bucket(world: World, units: Array[Unit], key: int) -> Array[Unit]:
	var out: Array[Unit] = []
	for unit: Unit in units:
		if _bucket_key(world, unit) == key:
			out.append(unit)
	return out
