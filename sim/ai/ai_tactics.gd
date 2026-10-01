class_name AiTactics
extends RefCounted
## How the AI fights with each UnitType.AiTactic beyond attack-moving at an
## objective. Static, like AiOrders, which buckets a group's members and
## hands STANDOFF and CLUSTER members here one by one; the only state is what
## AiGroup records.
##
## - STANDOFF (Stormcallers, Drifters): holds where it can shoot from at range
##   with a clear line (StandoffSpot), walks to such a spot when it can't, and
##   gets out when an enemy comes inside its dead zone, busy or not. A march
##   stops it short of the goal, behind the rest (behind).
## - CLUSTER (Blightbags): walks at the thickest knot of enemies
##   (ClusterFinder) without stopping for anything on the way, and
##   attack-moves into it once it is close.
## - ASSAULT: AiOrders fights these; here is only which enemies count as
##   threats to the group's STANDOFF members, which they go for first (the
##   bodyguard rule).

## Milli-units (center to center) from a STANDOFF member of the group within
## which an enemy is a threat to it, and the group's ASSAULT members go for
## that enemy first: the bodyguard rule.
const PROTECT_RADIUS: int = 10000
## Milli-units short of a march's goal its STANDOFF members stop, behind the
## rest, along the way the group came.
const STANDOFF_BEHIND: int = 6000
## Milli-units a STANDOFF member's new spot must be from the one it is
## walking to before it is sent to the new one.
const SPOT_SLACK: int = 2000
## Milli-units a CLUSTER member's knot must drift from where it was sent
## before it is sent again.
const CLUSTER_SLACK: int = 3000


## True if the unit's type stands off (UnitType.AiTactic.STANDOFF).
static func is_standoff(unit: Unit) -> bool:
	return unit.type.ai_tactic == UnitType.AiTactic.STANDOFF


## The units among units that aren't STANDOFF, or all of them if every one
## is: whose centroid says where a group stands, since its STANDOFF members
## stop short of where it marches.
static func front(units: Array[Unit]) -> Array[Unit]:
	var out: Array[Unit] = []
	for unit: Unit in units:
		if not is_standoff(unit):
			out.append(unit)
	return out if not out.is_empty() else units


## Where a march to (x, z) sends group's STANDOFF members: STANDOFF_BEHIND
## short of it on the line from the group's centroid, or (x, z) itself when
## the centroid is there or the group has nobody but STANDOFF members (there
## is no one to stand behind).
static func behind(world: World, group: AiGroup, x: int, z: int) -> Vector2i:
	var living: Array[Unit] = group.living(world)
	if front(living).size() == living.size():
		return Vector2i(x, z)
	var c: Vector2i = AiOrders.centroid(living)
	var back: Vector2i = FixedMath.normalize(x - c.x, z - c.y, STANDOFF_BEHIND)
	return Vector2i(x - back.x, z - back.y)


## The visible enemies within PROTECT_RADIUS (center to center) of any
## living STANDOFF member of group, in ascending id: what its ASSAULT
## members go for first.
static func threats(world: World, group: AiGroup) -> Array[Unit]:
	var guarded: Array[Unit] = []
	for unit: Unit in group.living(world):
		if is_standoff(unit):
			guarded.append(unit)
	var out: Array[Unit] = []
	if guarded.is_empty():
		return out
	for enemy: Unit in AiOrders.enemies(world, group.faction):
		for unit: Unit in guarded:
			if FixedMath.length(enemy.x - unit.x, enemy.z - unit.z) <= PROTECT_RADIUS:
				out.append(enemy)
				break
	return out


## STANDOFF: one member of group, busy or not. Its objective is the candidate
## it ranks best, wherever it stands (a bolt crosses water a walk can't).
## Returns true if it had one.
## - An enemy inside its dead zone: it is sent to a spot, busy or not (a
##   draw or a fight is dropped); with no spot, it stays.
## - Otherwise a busy member (drawing, shooting, fighting) is left alone.
## - Where it stands will do: left alone. One attack-moving is stopped there
##   so RangedCombat shoots; one walking a plain move (to a spot, or out of
##   its dead zone) is left to arrive: stopped the moment where it stands
##   would do, an escaping member would stop at the edge of its dead zone,
##   with the enemy it fled a step behind.
## - Otherwise it is sent to a spot. With none, it attack-moves toward the
##   objective (RangedCombat halts it in range), unless it holds with an enemy
##   in range already. It is sent again only for a new objective or one that
##   drifted (AiOrders.drifted), not for having stopped: one penned in away
##   from its objective would be sent at the same wall at every think.
static func standoff(world: World, group: AiGroup, member: Unit, candidates: Array[Unit]) -> bool:
	var objective: Unit = Targeting.pick(member, candidates)
	if objective == null:
		return false
	if StandoffSpot.threatened(world, member):
		if not StatusEffects.confused(world, member):
			var escape: PackedInt64Array = StandoffSpot.find(world, member, objective)
			if not escape.is_empty():
				_to_spot(world, group, member, escape, objective)
		return true
	if not AiOrders.is_free(world, member):
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
	if not sent or AiOrders.drifted(member, objective, group):
		var one: Array[Unit] = [member]
		var ox: int = objective.x
		var oz: int = objective.z
		AiOrders.send(world, group, one, ox, oz, true, objective.id, ox, oz)
	return true


## CLUSTER: one free member of group goes for the thickest knot of the
## candidates in its component. Farther from it than its acquire radius, a
## plain move, so nothing on the way stops it, re-sent only when the knot
## drifts more than CLUSTER_SLACK from where it was sent, or the member
## stopped short. Within it, an attack-move, once: MeleeCombat picks a body
## in the knot and the blow (a burst) does the rest. Returns true if there
## was a knot.
static func cluster(world: World, group: AiGroup, member: Unit, candidates: Array[Unit]) -> bool:
	var knot: PackedInt64Array = ClusterFinder.densest(
		AiOrders.reachable(world, member, candidates), ClusterFinder.CLUSTER_RADIUS, member.x, member.z
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
	if same and (attack or not AiOrders.is_done(member)):
		return true
	var one: Array[Unit] = [member]
	AiOrders.send(world, group, one, x, z, attack, 0, x, z)
	return true


# Sends a STANDOFF member to spot (a single-unit plain move, recorded with
# the spot and the objective, reported as a STANDOFF event) unless it is
# walking a plain move to within SPOT_SLACK of it already. One that isn't is
# sent however close it stands: it is only asked to move because where it
# stands won't do, and a step can be all the difference.
static func _to_spot(
	world: World, group: AiGroup, member: Unit, spot: PackedInt64Array, objective: Unit
) -> void:
	var x: int = spot[0]
	var z: int = spot[1]
	var i: int = group.member_index(member.id)
	if (
		member.order == Unit.Order.MOVE
		and FixedMath.length(x - group.ordered_x[i], z - group.ordered_z[i]) <= SPOT_SLACK
	):
		return
	var one: Array[Unit] = [member]
	AiOrders.send(world, group, one, x, z, false, objective.id, x, z, AiEvent.Kind.STANDOFF)


# True if a visible enemy is where the unit could shoot it from where it
# stands: between its minimum range and its range, shortened uphill (as
# RangedCombat picks targets, before it checks the line).
static func _has_shot(world: World, unit: Unit) -> bool:
	for enemy: Unit in AiOrders.enemies(world, unit.faction):
		var dist: int = FixedMath.length(enemy.x - unit.x, enemy.z - unit.z)
		var rise: int = enemy.y - unit.y - unit.type.ranged_launch_height
		if dist >= unit.type.ranged_min_range and dist <= RangedCombat.effective_max_range(unit, rise, dist):
			return true
	return false
