class_name Targeting
extends RefCounted
## How a unit ranks the enemies it could fight. Pure functions of the units
## passed in: MeleeCombat decides who is eligible (side, visibility, reach,
## leash) and these decide who is best, so the choice never depends on scan
## order.
##
## Rank: a role the unit prefers (UnitType.preferred_target_roles) first,
## then the nearest body edge, then the lower id.

## While still approaching, a unit only abandons its target for another of
## the same preference if that one is at least this much nearer (milli-units).
## Without it, two enemies at nearly equal range would flip the chase back
## and forth and reset its path every tick.
const RETARGET_MARGIN: int = 1000


## Milli-units between the two bodies' edges; negative if they overlap.
static func edge_distance(a: Unit, b: Unit) -> int:
	return FixedMath.length(b.x - a.x, b.z - a.z) - a.type.body_radius - b.type.body_radius


## True if b is within a's melee reach, plus slack milli-units.
static func in_reach(a: Unit, b: Unit, slack: int = 0) -> bool:
	return edge_distance(a, b) <= a.type.melee_reach + slack


## True if unit's type prefers targets with other's role.
static func prefers(unit: Unit, other: Unit) -> bool:
	return unit.type.preferred_target_roles & (1 << other.type.role) != 0


## True if a ranks strictly ahead of b as a target for unit.
static func ranks_before(unit: Unit, a: Unit, b: Unit) -> bool:
	var prefers_a: bool = prefers(unit, a)
	if prefers_a != prefers(unit, b):
		return prefers_a
	var da: int = edge_distance(unit, a)
	var db: int = edge_distance(unit, b)
	if da != db:
		return da < db
	return a.id < b.id


## The best-ranked of candidates for unit, or null if there are none.
static func pick(unit: Unit, candidates: Array[Unit]) -> Unit:
	var best: Unit = null
	for other: Unit in candidates:
		if best == null or ranks_before(unit, other, best):
			best = other
	return best


## True if a unit approaching current should chase candidate instead: a
## preferred role beats a non-preferred one outright; otherwise candidate
## must be RETARGET_MARGIN nearer.
static func worth_switching(unit: Unit, current: Unit, candidate: Unit) -> bool:
	if candidate == current:
		return false
	var prefers_candidate: bool = prefers(unit, candidate)
	if prefers_candidate != prefers(unit, current):
		return prefers_candidate
	return edge_distance(unit, candidate) + RETARGET_MARGIN <= edge_distance(unit, current)
