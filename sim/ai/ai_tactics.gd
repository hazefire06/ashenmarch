class_name AiTactics
extends RefCounted
## How the AI fights with each UnitType.AiTactic beyond attack-moving at an
## objective. Static, like AiOrders, which buckets a group's members and
## hands STANDOFF and CLUSTER members here one by one; the only state is what
## AiGroup records.
##
## - STANDOFF (Stormcallers, Drifters): holds where it can shoot from at range
##   with a clear line (StandoffSpot), walks to such a spot when it can't, and
##   gets out when an enemy comes inside its dead zone, busy or not. An
##   attack march stops it short of the goal, behind the rest (behind).
## - CLUSTER (Blightbags): walks at the thickest knot of enemies
##   (ClusterFinder) without stopping for anything on the way, and
##   attack-moves into it once it is close.
## - MEDIC (Wardens): while it has herbs, heals the group's side's most
##   wounded nearby, kills an undead enemy that comes close with a herb, and
##   otherwise stands behind the group (medic). Without herbs it fights as
##   ASSAULT.
## - ASSAULT: AiOrders fights these; here is only which enemies count as
##   threats to the group's STANDOFF members, which they go for first (the
##   bodyguard rule).

## Milli-units (center to center) from a STANDOFF member of the group within
## which an enemy is a threat to it, and the group's ASSAULT members go for
## that enemy first: the bodyguard rule.
const PROTECT_RADIUS: int = 10000
## Milli-units short of an attack march's goal its STANDOFF members stop,
## behind the rest, along the way the marched members came.
const STANDOFF_BEHIND: int = 6000
## Milli-units a STANDOFF member's new spot must be from the one it is
## walking to before it is sent to the new one.
const SPOT_SLACK: int = 2000
## Milli-units a CLUSTER member's knot must drift from where it was sent
## before it is sent again.
const CLUSTER_SLACK: int = 3000
## Milli-units (center to center) within which a MEDIC looks for a friend to
## heal.
const MEDIC_RADIUS: int = 20000
## A friend is worth a herb below this share of its health, in permille.
const MEDIC_WOUNDED_PERMILLE: int = 600
## Milli-units (center to center) within which a MEDIC uses a herb on an
## undead enemy, which kills it.
const MEDIC_KILL_RADIUS: int = 8000


## True if the unit's type stands off (UnitType.AiTactic.STANDOFF).
static func is_standoff(unit: Unit) -> bool:
	return unit.type.ai_tactic == UnitType.AiTactic.STANDOFF


## True if the unit keeps behind the rest of group: a STANDOFF member always,
## and in a group whose spec sets ranged_behind (a skirmish commander's) any
## ranged or support member and any MEDIC too. These stop short of an attack
## march's goal (behind), are left out of where the group is said to stand
## (front), and are who the melee guards (threats).
static func is_back(group: AiGroup, unit: Unit) -> bool:
	if is_standoff(unit):
		return true
	if group == null or not group.spec.ranged_behind:
		return false
	return unit.type.role != UnitType.Role.MELEE or unit.type.ai_tactic == UnitType.AiTactic.MEDIC


## The units among units that don't keep behind (is_back; without a group,
## those that aren't STANDOFF), or all of them if every one does: whose
## centroid says where a group stands, since the others stop short of where
## it marches.
static func front(units: Array[Unit], group: AiGroup = null) -> Array[Unit]:
	var out: Array[Unit] = []
	for unit: Unit in units:
		if not is_back(group, unit):
			out.append(unit)
	return out if not out.is_empty() else units


## Where a march of marched (members of group) to (x, z) sends the members
## that keep behind (is_back: STANDOFF members, and in a ranged_behind group
## its ranged and support). An attack march stops them STANDOFF_BEHIND short
## of it, on the
## line from the centroid of marched, so they come up behind the rest and
## shoot over them. A plain move (a retreat, a recall, a flank's approach)
## sends them to (x, z) itself: nobody is fighting there to stand behind, and
## during a retreat the side the group came from is the enemy's. (x, z)
## itself too when the group has nobody but STANDOFF members (there is no
## one to stand behind), or the centroid is at (x, z) (no way to be short of
## it). The centroid is of marched, not of the whole group: members marched
## on their own (one freed from a fight, a recall) would otherwise stop on
## whatever side the rest of the group happens to be.
static func behind(
	world: World, group: AiGroup, marched: Array[Unit], x: int, z: int, attack: bool
) -> Vector2i:
	var living: Array[Unit] = group.living(world)
	if not attack or front(living, group).size() == living.size():
		return Vector2i(x, z)
	var c: Vector2i = AiOrders.centroid(marched)
	var back: Vector2i = FixedMath.normalize(x - c.x, z - c.y, STANDOFF_BEHIND)
	return Vector2i(x - back.x, z - back.y)


## The visible enemies within PROTECT_RADIUS (center to center) of any
## living member of group that keeps behind (is_back: a STANDOFF member, or
## in a ranged_behind group any ranged or support one), in ascending id: what
## its ASSAULT members go for first.
static func threats(world: World, group: AiGroup) -> Array[Unit]:
	var guarded: Array[Unit] = []
	for unit: Unit in group.living(world):
		if is_back(group, unit):
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


## MEDIC: one free member of group. Returns false if it has no herbs left, so
## the caller fights with it as ASSAULT; true otherwise.
## - A living unit of its side within MEDIC_RADIUS (center to center) below
##   MEDIC_WOUNDED_PERMILLE of its health, the most wounded first (then the
##   nearer, then the lower id), that no other MEDIC of the group is already on
##   its way to: it goes and heals it (Interactions, as a HealCommand would).
## - Otherwise a visible undead enemy within MEDIC_KILL_RADIUS: it goes and
##   uses a herb on it, which kills it.
## - Otherwise it stands behind the rest of the group: STANDOFF_BEHIND from the
##   centroid of the members in front (front), on its own side of it, sent
##   only when it has finished its last order farther than SPOT_SLACK from
##   that point, so it trails the group without being re-sent every think.
## Each errand is reported as a HEAL event.
static func medic(world: World, group: AiGroup, member: Unit) -> bool:
	if member.special_left <= 0:
		return false
	if medic_errand(world, group, member):
		return true
	var others: Array[Unit] = front(group.living(world), group)
	if others.has(member):
		return true
	var c: Vector2i = AiOrders.centroid(others)
	var back: Vector2i = FixedMath.normalize(member.x - c.x, member.z - c.y, STANDOFF_BEHIND)
	if back == Vector2i.ZERO:
		back = Vector2i(0, STANDOFF_BEHIND)
	var x: int = c.x + back.x
	var z: int = c.y + back.y
	if not AiOrders.is_done(member) or FixedMath.length(member.x - x, member.z - z) <= SPOT_SLACK:
		return true
	var one: Array[Unit] = [member]
	AiOrders.send(world, group, one, x, z, false, 0, x, z)
	return true


## The errand half of medic, for a free MEDIC member with herbs: sends it to
## heal the friend it should (or to kill a near undead enemy) and returns
## true, or returns false with nothing to do. A behavior that marches its
## group (ADVANCE) calls this every think, so the wounded are tended between
## fights too; engage calls medic.
static func medic_errand(world: World, group: AiGroup, member: Unit) -> bool:
	if member.special_left <= 0 or member.type.ai_tactic != UnitType.AiTactic.MEDIC:
		return false
	var patient: Unit = _patient(world, group, member)
	if patient == null:
		patient = _undead_near(world, member)
	if patient == null:
		return false
	Interactions.order(world, PackedInt32Array([member.id]), patient.id, Interactions.Action.HEAL)
	if member.order != Unit.Order.INTERACT:
		return false
	group.record_order(member.id, patient.x, patient.z, patient.id)
	world.ai_events.append(AiEvent.new(AiEvent.Kind.HEAL, group.id, patient.x, patient.z, patient.id, member.id))
	return true


# The friend a MEDIC member heals next, or null (see medic).
static func _patient(world: World, group: AiGroup, member: Unit) -> Unit:
	var claimed: PackedInt32Array = PackedInt32Array()
	for other: Unit in group.living(world):
		if other != member and other.order == Unit.Order.INTERACT:
			claimed.append(other.interact_id)
	var best: Unit = null
	var best_permille: int = 0
	var best_d: int = 0
	for friend: Unit in world.units:
		if not friend.is_alive() or friend.faction != member.faction or friend == member:
			continue
		if friend.type.nature != UnitType.Nature.LIVING or claimed.has(friend.id):
			continue
		var permille: int = friend.hp * 1000 / friend.type.max_hp
		if permille >= MEDIC_WOUNDED_PERMILLE:
			continue
		var d: int = FixedMath.length(friend.x - member.x, friend.z - member.z)
		if d > MEDIC_RADIUS:
			continue
		if best == null or permille < best_permille or (
			permille == best_permille and (d < best_d or (d == best_d and friend.id < best.id))
		):
			best = friend
			best_permille = permille
			best_d = d
	return best


# The nearest visible undead enemy within MEDIC_KILL_RADIUS, or null.
static func _undead_near(world: World, member: Unit) -> Unit:
	var best: Unit = null
	var best_d: int = 0
	for enemy: Unit in AiOrders.enemies(world, member.faction):
		if enemy.type.nature != UnitType.Nature.UNDEAD:
			continue
		var d: int = FixedMath.length(enemy.x - member.x, enemy.z - member.z)
		if d <= MEDIC_KILL_RADIUS and (best == null or d < best_d):
			best = enemy
			best_d = d
	return best


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
