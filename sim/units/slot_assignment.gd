class_name SlotAssignment
extends RefCounted
## Decides which unit walks to which formation slot, so a move order sends the
## group to its shape with the least total walking and with paths that don't
## cross needlessly.
##
## The cost is straight-line distance, not path length. Path length would need
## a pathing solve per unit-slot pair, N^2 of them for one order. On the open
## ground formations are used on, the straight line is close enough, and terrain
## detours are pathing's job after the slot is chosen.

## Larger than any real cost sum. Not named INF: that is a GDScript float
## constant, and shadowing it invites a float slipping in.
const COST_INF: int = 1 << 60


## result[i] is the slot index for unit i. Minimizes the total straight-line
## distance (Hungarian algorithm, Kuhn-Munkres with potentials, O(n^2 * m)).
## Needs at least as many slots as units; extra slots stay empty. Ties go to
## whichever assignment the fixed loop order below finds first.
static func assign(units: Array[Vector2i], slots: Array[Vector2i]) -> PackedInt32Array:
	var n: int = units.size()
	var m: int = slots.size()
	assert(n <= m, "need at least as many slots as units")
	var result: PackedInt32Array = PackedInt32Array()
	result.resize(n)
	if n == 0:
		return result

	# The inner loop reads each cost many times, so compute the matrix once.
	# cost[i * m + j] is unit i to slot j, 0-based.
	var cost: PackedInt64Array = PackedInt64Array()
	cost.resize(n * m)
	for i: int in n:
		for j: int in m:
			cost[i * m + j] = _distance(units[i], slots[j])

	# Rows and columns are 1-based below; index 0 is a virtual start.
	# u, v: potentials. p[j]: the row matched to column j (0 = none). way[j]:
	# the previous column on the alternating path to column j.
	var u: PackedInt64Array = PackedInt64Array()
	u.resize(n + 1)
	var v: PackedInt64Array = PackedInt64Array()
	v.resize(m + 1)
	var p: PackedInt32Array = PackedInt32Array()
	p.resize(m + 1)
	var way: PackedInt32Array = PackedInt32Array()
	way.resize(m + 1)
	var minv: PackedInt64Array = PackedInt64Array()
	minv.resize(m + 1)
	var used: PackedByteArray = PackedByteArray()
	used.resize(m + 1)

	for i: int in range(1, n + 1):
		p[0] = i
		var j0: int = 0
		minv.fill(COST_INF)
		used.fill(0)
		# Grow the alternating tree until it reaches a free column.
		while true:
			used[j0] = 1
			var i0: int = p[j0]
			var delta: int = COST_INF
			var j1: int = 0
			for j: int in range(1, m + 1):
				if used[j] == 1:
					continue
				var cur: int = cost[(i0 - 1) * m + (j - 1)] - u[i0] - v[j]
				if cur < minv[j]:
					minv[j] = cur
					way[j] = j0
				if minv[j] < delta:
					delta = minv[j]
					j1 = j
			for j: int in range(0, m + 1):
				if used[j] == 1:
					u[p[j]] += delta
					v[j] -= delta
				else:
					minv[j] -= delta
			j0 = j1
			if p[j0] == 0:
				break
		# Flip the matching along the path back to the start.
		while j0 != 0:
			var j1: int = way[j0]
			p[j0] = p[j1]
			j0 = j1

	for j: int in range(1, m + 1):
		if p[j] != 0:
			result[p[j] - 1] = j - 1
	return result


## Sum of straight-line distances from each unit to its assigned slot.
static func total_cost(
	units: Array[Vector2i], slots: Array[Vector2i], assignment: PackedInt32Array
) -> int:
	var total: int = 0
	for i: int in units.size():
		total += _distance(units[i], slots[assignment[i]])
	return total


static func _distance(a: Vector2i, b: Vector2i) -> int:
	return FixedMath.length(a.x - b.x, a.y - b.y)
