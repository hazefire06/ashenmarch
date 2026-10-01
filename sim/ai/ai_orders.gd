class_name AiOrders
extends RefCounted
## How the AI hands out orders: who may be given one, where to send them,
## and when to leave them alone. Static helpers over a World and an AiGroup;
## the only state is what AiGroup records (ordered_x/z/target/attack).
##
## The AI orders units the way a player does, through UnitOrders.move. A new
## move drops whatever the unit was in the middle of, so the AI only re-orders
## a free member (is_free) unless a behavior overrides that on purpose, and
## only when its plan for that member changed: the recorded goal or objective
## differs from the new one. Members are ordered in buckets, one move per
## bucket: a bucket is the members of one tactic and type standing in one
## pathing component. Per type, so a fast type isn't held to a slow one's pace
## (UnitOrders.move caps a group at its slowest member); per component, so a
## bucket's leader can walk wherever the rest of it can.
##
## engage fights each bucket by its type's UnitType.AiTactic:
## - ASSAULT: the bucket attack-moves at one objective, and goes first for an
##   enemy that has come within PROTECT_RADIUS of one of the group's STANDOFF
##   members (the bodyguard rule), so the casters can keep casting.
## - STANDOFF, member by member: holds where it can shoot from at range with
##   a clear line (StandoffSpot), walks to such a spot when it can't, and gets
##   out when an enemy comes inside its dead zone, busy or not.
## - CLUSTER, member by member: walks at the thickest knot of enemies
##   (ClusterFinder) without stopping for anything on the way, and
##   attack-moves into it once it is close.

## Least drift (milli-units) of an objective from where a member was sent
## before the member is re-sent after it. See _should_reorder.
const REORDER_MIN: int = 4000
## Milli-units (center to center) from a STANDOFF member of the group within
## which an enemy is a threat to it, and the group's ASSAULT members go for
## that enemy first: the bodyguard rule.
const PROTECT_RADIUS: int = 10000
## Milli-units short of a march's goal its STANDOFF members stop, behind the
## rest, along the way the group came.
const STANDOFF_BEHIND: int = 6000
## Milli-units a STANDOFF member's new spot must be from the one it is
## walking to, or from where it stands, before it is sent there.
const SPOT_SLACK: int = 2000
## Milli-units a CLUSTER member's knot must drift from where it was sent
## before it is sent again.
const CLUSTER_SLACK: int = 3000
## A bucket key holds the tactic above the type index, which takes this many
## bits; both sit above the pathing component (offset so NO_COMPONENT is 0),
## which takes the low _COMPONENT_BITS.
const _TYPE_BITS: int = 16
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
## go; with force, every living member in units goes, busy or not (a retry, a
## recall). One UnitOrders.move and one ORDER event per bucket, and each
## member's goal is recorded as (x, z) with no objective. STANDOFF members
## stop STANDOFF_BEHIND short, on the line from the group's centroid to
## (x, z), so they arrive behind the rest; their recorded goal is still (x, z),
## so a leg sees them as sent there. A group with no one else marches them
## to (x, z) itself: there is nobody to stand behind.
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
	var keys: PackedInt64Array = _bucket_keys(world, picked)
	if keys.is_empty():
		return
	var behind: Vector2i = _behind(world, group, x, z)
	for key: int in keys:
		var bucket: Array[Unit] = _bucket(world, picked, key)
		var to: Vector2i = behind if _is_standoff(bucket[0]) else Vector2i(x, z)
		_order(world, group, bucket, to.x, to.y, attack, 0, x, z)


## The units among units that aren't STANDOFF, or all of them if every one
## is: whose centroid says where a group stands, since its STANDOFF members
## stop short of where it marches.
static func front(units: Array[Unit]) -> Array[Unit]:
	var out: Array[Unit] = []
	for unit: Unit in units:
		if not _is_standoff(unit):
			out.append(unit)
	return out if not out.is_empty() else units


## Sends members among units after objectives picked from candidates, each
## bucket by its tactic (see the class doc). Busy members are left alone,
## except a STANDOFF member with an enemy inside its dead zone. Members the
## plan hasn't changed for keep their orders. Returns true if any member or
## bucket had something to go after, whether or not anyone needed a new
## order; false if none could get at any candidate (or no member was free).
##
## An ASSAULT bucket's lowest-id member leads: the objective is the
## candidate the leader ranks best (Targeting.pick: preferred roles, then the
## nearest, then the lower id) among those it can walk to or already reach,
## unless one of those threatens a STANDOFF member of the group (within
## PROTECT_RADIUS of it, center to center): then the threat it ranks best.
## Members not already after that objective (_should_reorder) attack-move to
## it in one move.
static func engage(world: World, group: AiGroup, units: Array[Unit], candidates: Array[Unit]) -> bool:
	var picked: Array[Unit] = []
	for unit: Unit in units:
		if is_free(world, unit) or (unit.is_alive() and _is_standoff(unit)):
			picked.append(unit)
	var threats: Array[Unit] = _threats(world, group)
	var any_objective: bool = false
	for key: int in _bucket_keys(world, picked):
		var bucket: Array[Unit] = _bucket(world, picked, key)
		match bucket[0].type.ai_tactic:
			UnitType.AiTactic.STANDOFF:
				for member: Unit in bucket:
					any_objective = _standoff(world, group, member, candidates) or any_objective
			UnitType.AiTactic.CLUSTER:
				for member: Unit in bucket:
					any_objective = _cluster(world, group, member, candidates) or any_objective
			_:
				any_objective = _assault(world, group, bucket, candidates, threats) or any_objective
	return any_objective


# ASSAULT: one objective for the bucket (see engage). Returns true if it had
# one.
static func _assault(
	world: World, group: AiGroup, bucket: Array[Unit], candidates: Array[Unit], threats: Array[Unit]
) -> bool:
	var leader: Unit = bucket[0]
	var objective: Unit = Targeting.pick(leader, _reachable(world, leader, threats))
	if objective == null:
		objective = Targeting.pick(leader, _reachable(world, leader, candidates))
	if objective == null:
		return false
	var sent: Array[Unit] = []
	for member: Unit in bucket:
		if _should_reorder(member, objective, group):
			sent.append(member)
	if not sent.is_empty():
		_order(world, group, sent, objective.x, objective.z, true, objective.id, objective.x, objective.z)
	return true


# STANDOFF: one member, busy or not. Its objective is the candidate it ranks
# best, wherever it stands (a bolt crosses water a walk can't). Returns true
# if it had one.
# - An enemy inside its dead zone: it is sent to a spot, busy or not (a
#   draw or a fight is dropped); with no spot, it stays.
# - Otherwise a busy member (drawing, shooting, fighting) is left alone.
# - Where it stands will do: left alone. One attack-moving is stopped there
#   so RangedCombat shoots; one walking a plain move (to a spot, or out of
#   its dead zone) is left to arrive: stopped the moment where it stands
#   would do, an escaping member would stop at the edge of its dead zone,
#   with the enemy it fled a step behind.
# - Otherwise it is sent to a spot. With none, it attack-moves toward the
#   objective (RangedCombat halts it in range), unless it holds with an enemy
#   in range already. It is sent again only for a new objective or one that
#   drifted (_drifted), not for having stopped: one penned in away from its
#   objective would be sent at the same wall at every think.
static func _standoff(world: World, group: AiGroup, member: Unit, candidates: Array[Unit]) -> bool:
	var objective: Unit = Targeting.pick(member, candidates)
	if objective == null:
		return false
	if StandoffSpot.threatened(world, member):
		if not StatusEffects.confused(world, member):
			var escape: PackedInt64Array = StandoffSpot.find(world, member, objective)
			if not escape.is_empty():
				_to_spot(world, group, member, escape, objective)
		return true
	if not is_free(world, member):
		return true
	if StandoffSpot.holds(world, member, objective):
		if member.order != Unit.Order.NONE and member.order != Unit.Order.MOVE:
			UnitOrders.stop(world, PackedInt32Array([member.id]))
		return true
	var spot: PackedInt64Array = StandoffSpot.find(world, member, objective)
	if not spot.is_empty():
		_to_spot(world, group, member, spot, objective)
		return true
	if member.order == Unit.Order.NONE and _has_shot(world, member):
		return true
	var i: int = group.member_index(member.id)
	var sent: bool = group.ordered_attack[i] == 1 and group.ordered_target[i] == objective.id
	if not sent or _drifted(member, objective, group):
		var one: Array[Unit] = [member]
		_order(world, group, one, objective.x, objective.z, true, objective.id, objective.x, objective.z)
	return true


# Sends a STANDOFF member to spot (single-unit plain move, recorded with the
# objective, a STANDOFF event) unless it is walking a plain move to within
# SPOT_SLACK of it already, or, not walking one, stands within SPOT_SLACK of
# it.
static func _to_spot(
	world: World, group: AiGroup, member: Unit, spot: PackedInt64Array, objective: Unit
) -> void:
	var x: int = spot[0]
	var z: int = spot[1]
	var i: int = group.member_index(member.id)
	if member.order == Unit.Order.MOVE:
		if FixedMath.length(x - group.ordered_x[i], z - group.ordered_z[i]) <= SPOT_SLACK:
			return
	elif FixedMath.length(x - member.x, z - member.z) <= SPOT_SLACK:
		return
	UnitOrders.move(world, PackedInt32Array([member.id]), x, z, group.spec.formation, false)
	group.record_order(member.id, x, z, objective.id, false)
	world.ai_events.append(AiEvent.new(AiEvent.Kind.STANDOFF, group.id, x, z, 0, member.id))


# CLUSTER: one free member goes for the thickest knot of the candidates in
# its component. Farther from it than its acquire radius, a plain move, so
# nothing on the way stops it, re-sent only when the knot drifts more than
# CLUSTER_SLACK from where it was sent, or the member stopped short. Within
# it, an attack-move, once: MeleeCombat picks a body in the knot and the
# blow (a burst) does the rest. Returns true if there was a knot.
static func _cluster(world: World, group: AiGroup, member: Unit, candidates: Array[Unit]) -> bool:
	var knot: PackedInt64Array = ClusterFinder.densest(
		_reachable(world, member, candidates), ClusterFinder.CLUSTER_RADIUS, member.x, member.z
	)
	if knot.is_empty():
		return false
	var x: int = knot[0]
	var z: int = knot[1]
	var i: int = group.member_index(member.id)
	var attack: bool = FixedMath.length(x - member.x, z - member.z) <= member.type.acquire_radius
	var same: bool = (
		(group.ordered_attack[i] == 1) == attack
		and FixedMath.length(x - group.ordered_x[i], z - group.ordered_z[i]) <= CLUSTER_SLACK
	)
	if same and (attack or not is_done(member)):
		return true
	var one: Array[Unit] = [member]
	_order(world, group, one, x, z, attack, 0, x, z)
	return true


# One UnitOrders.move for units (non-empty, ascending id) to (x, z) after
# objective_id (0 for none), recorded per member as sent to (goal_x, goal_z)
# (the group's goal, which a march's STANDOFF members stop short of), and
# reported as one ORDER event at (x, z) naming the lowest id.
static func _order(
	world: World, group: AiGroup, units: Array[Unit], x: int, z: int, attack: bool, objective_id: int,
	goal_x: int, goal_z: int
) -> void:
	var ids: PackedInt32Array = PackedInt32Array()
	for unit: Unit in units:
		ids.append(unit.id)
	UnitOrders.move(world, ids, x, z, group.spec.formation, attack)
	for unit_id: int in ids:
		group.record_order(unit_id, goal_x, goal_z, objective_id, attack)
	world.ai_events.append(AiEvent.new(AiEvent.Kind.ORDER, group.id, x, z, 1 if attack else 0, ids[0]))


# Where a march sends STANDOFF members: STANDOFF_BEHIND short of (x, z) on
# the line from the group's centroid, or (x, z) itself when the centroid is
# there or the group has nobody but STANDOFF members.
static func _behind(world: World, group: AiGroup, x: int, z: int) -> Vector2i:
	var living: Array[Unit] = group.living(world)
	if front(living).size() == living.size():
		return Vector2i(x, z)
	var c: Vector2i = centroid(living)
	var back: Vector2i = FixedMath.normalize(x - c.x, z - c.y, STANDOFF_BEHIND)
	return Vector2i(x - back.x, z - back.y)


# The visible enemies within PROTECT_RADIUS (center to center) of any
# living STANDOFF member of group, in ascending id.
static func _threats(world: World, group: AiGroup) -> Array[Unit]:
	var guarded: Array[Unit] = []
	for unit: Unit in group.living(world):
		if _is_standoff(unit):
			guarded.append(unit)
	var out: Array[Unit] = []
	if guarded.is_empty():
		return out
	for enemy: Unit in enemies(world, group.faction):
		for unit: Unit in guarded:
			if FixedMath.length(enemy.x - unit.x, enemy.z - unit.z) <= PROTECT_RADIUS:
				out.append(enemy)
				break
	return out


# True if a visible enemy is where the unit could shoot it from where it
# stands: between its minimum range and its range, shortened uphill (as
# RangedCombat picks targets, before it checks the line).
static func _has_shot(world: World, unit: Unit) -> bool:
	for enemy: Unit in enemies(world, unit.faction):
		var dist: int = FixedMath.length(enemy.x - unit.x, enemy.z - unit.z)
		var rise: int = enemy.y - unit.y - unit.type.ranged_launch_height
		if dist >= unit.type.ranged_min_range and dist <= RangedCombat.effective_max_range(unit, rise, dist):
			return true
	return false


static func _is_standoff(unit: Unit) -> bool:
	return unit.type.ai_tactic == UnitType.AiTactic.STANDOFF


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
	return _drifted(member, objective, group)


# True if objective has drifted from where member was last sent by more than
# a quarter of the member's distance to it, and at least REORDER_MIN.
static func _drifted(member: Unit, objective: Unit, group: AiGroup) -> bool:
	var i: int = group.member_index(member.id)
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


# Which bucket a member is ordered in: its type's tactic, its type, then the
# pathing component it stands in for its mobility. The one place buckets are
# defined. Keys ascend by tactic first, so ASSAULT buckets are ordered before
# STANDOFF and CLUSTER members. Members of one bucket move as one formation
# at the slowest one's pace, and its leader picks objectives every one of
# them can walk to: a member across a river from its leader would otherwise
# be sent at something it can never reach, stop on its own bank, and be sent
# again at every think.
static func _bucket_key(world: World, unit: Unit) -> int:
	var component: int = world.pathing.component_at(unit.x, unit.z, unit.type.mobility)
	var kind: int = (unit.type.ai_tactic << _TYPE_BITS) | unit.type_index
	return (kind << _COMPONENT_BITS) | (component - PathLayer.NO_COMPONENT)


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
