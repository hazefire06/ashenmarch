class_name ClusterFinder
extends RefCounted
## Where enemies stand thickest: what a CLUSTER unit (a Blightbag) walks at,
## so one burst catches as many as it can. Static and pure.

## Milli-units (center to center) within which units count as one knot:
## about the reach of a Blightbag's burst and its gas.
const CLUSTER_RADIUS: int = 5000


## The middle of the thickest knot among units, [x, z] in milli-units, or
## empty if there are none. The knot is the unit with the most units within
## radius of it, itself included; a tie goes to the one nearer (from_x,
## from_z), then to the lower id. Its middle is the mean position of those
## units, rounded.
static func densest(units: Array[Unit], radius: int, from_x: int, from_z: int) -> PackedInt64Array:
	var best: Unit = null
	var best_count: int = 0
	var best_distance: int = 0
	for unit: Unit in units:
		var count: int = 0
		for other: Unit in units:
			if FixedMath.length(other.x - unit.x, other.z - unit.z) <= radius:
				count += 1
		var distance: int = FixedMath.length(unit.x - from_x, unit.z - from_z)
		if best == null or count > best_count or (
			count == best_count
			and (distance < best_distance or (distance == best_distance and unit.id < best.id))
		):
			best = unit
			best_count = count
			best_distance = distance
	if best == null:
		return PackedInt64Array()
	var sum_x: int = 0
	var sum_z: int = 0
	for other: Unit in units:
		if FixedMath.length(other.x - best.x, other.z - best.z) <= radius:
			sum_x += other.x
			sum_z += other.z
	return PackedInt64Array([FixedMath.div_round(sum_x, best_count), FixedMath.div_round(sum_z, best_count)])
