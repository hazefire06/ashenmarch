class_name PathLayer
extends RefCounted
## Everything pathing needs for one Mobility, derived once from the Terrain:
## per-sample passability, connected components, and the A* grid.
##
## Determinism: the A* grid is Godot's AStarGrid2D, which scores paths with
## real_t (float32). It is exact here, and so identical on every platform and
## compiler, because every score is a sum of small integers: Chebyshev compute
## and estimate heuristics return whole cell counts, and weight scales are
## whole numbers, so g and f stay integer-valued floats far below 2^24 and no
## rounding (or FMA contraction) can occur. Octile and Euclidean multiply by
## sqrt(2) and would break this; tests/sim/test_pathing.gd pins the settings.
## The open list orders by f, then g, never by pointer, so ties resolve the
## same way everywhere.

## A* weight per water depth for LIVING units, so paths prefer dry ground and
## shallow fords. Whole numbers only (see above). Depth 3+ is impassable to
## LIVING anyway; UNDEAD and FLOATING aren't slowed by water, so they use 1.
const LIVING_WATER_WEIGHTS: Array[int] = [1, 2, 3, 1, 1]
const NO_COMPONENT: int = -1

var mobility: Terrain.Mobility
var size_x: int
var size_z: int
## 1 where a unit of this mobility may stand, row-major (j * size_x + i).
var passable: PackedByteArray
## A* weight per sample (0 where impassable). Smoothing also uses it, so a
## straightened path never wades deeper than the path it replaces.
var weights: PackedByteArray
## Connected-component id per sample, or NO_COMPONENT where impassable. Ids
## count up in row-major order of each component's first sample.
var components: PackedInt32Array
var astar: AStarGrid2D


func _init(terrain: Terrain, layer_mobility: Terrain.Mobility) -> void:
	mobility = layer_mobility
	size_x = terrain.size_x
	size_z = terrain.size_z
	passable = PackedByteArray()
	passable.resize(size_x * size_z)
	weights = PackedByteArray()
	weights.resize(size_x * size_z)
	for j: int in size_z:
		for i: int in size_x:
			if terrain.is_sample_passable(i, j, mobility):
				passable[j * size_x + i] = 1
				weights[j * size_x + i] = _weight_of(terrain, i, j)
	components = _label_components()
	astar = _build_astar()


func is_passable(i: int, j: int) -> bool:
	if i < 0 or j < 0 or i >= size_x or j >= size_z:
		return false
	return passable[j * size_x + i] != 0


func component_at(i: int, j: int) -> int:
	if i < 0 or j < 0 or i >= size_x or j >= size_z:
		return NO_COMPONENT
	return components[j * size_x + i]


## A* weight of sample (i, j); 0 if impassable or off the map.
func weight_at(i: int, j: int) -> int:
	if i < 0 or j < 0 or i >= size_x or j >= size_z:
		return 0
	return weights[j * size_x + i]


func _weight_of(terrain: Terrain, i: int, j: int) -> int:
	if mobility != Terrain.Mobility.LIVING:
		return 1
	return LIVING_WATER_WEIGHTS[terrain.sample_water_depth(i, j)]


# Labels 4-connected components with union-find over horizontal runs of
# passable samples, which is far cheaper than a per-sample flood fill. A*
# moves diagonally only when both orthogonal neighbors are passable, so its
# connectivity equals 4-connectivity.
func _label_components() -> PackedInt32Array:
	var run_start: PackedInt32Array = PackedInt32Array()
	var run_end: PackedInt32Array = PackedInt32Array()
	var run_row: PackedInt32Array = PackedInt32Array()
	var parent: PackedInt32Array = PackedInt32Array()
	var prev_first: int = 0
	var prev_last: int = -1
	for j: int in size_z:
		var row_first: int = run_start.size()
		var q: int = prev_first
		var i: int = 0
		var base: int = j * size_x
		while i < size_x:
			if passable[base + i] == 0:
				i += 1
				continue
			var a: int = i
			while i < size_x and passable[base + i] != 0:
				i += 1
			var b: int = i - 1
			var r: int = run_start.size()
			run_start.append(a)
			run_end.append(b)
			run_row.append(j)
			parent.append(r)
			# Previous-row runs are sorted by start; skip those ending before
			# this one begins, then union every one that overlaps it.
			while q <= prev_last and run_end[q] < a:
				q += 1
			var t: int = q
			while t <= prev_last and run_start[t] <= b:
				_union(parent, r, t)
				t += 1
		prev_first = row_first
		prev_last = run_start.size() - 1

	var labels: PackedInt32Array = PackedInt32Array()
	labels.resize(size_x * size_z)
	labels.fill(NO_COMPONENT)
	var id_by_root: Dictionary[int, int] = {}
	for r: int in run_start.size():
		var root: int = _find(parent, r)
		if not id_by_root.has(root):
			id_by_root[root] = id_by_root.size()
		var label: int = id_by_root[root]
		var base: int = run_row[r] * size_x
		for i: int in range(run_start[r], run_end[r] + 1):
			labels[base + i] = label
	return labels


func _build_astar() -> AStarGrid2D:
	var grid: AStarGrid2D = AStarGrid2D.new()
	grid.region = Rect2i(0, 0, size_x, size_z)
	grid.diagonal_mode = AStarGrid2D.DIAGONAL_MODE_ONLY_IF_NO_OBSTACLES
	grid.default_compute_heuristic = AStarGrid2D.HEURISTIC_CHEBYSHEV
	grid.default_estimate_heuristic = AStarGrid2D.HEURISTIC_CHEBYSHEV
	grid.jumping_enabled = false
	grid.update()
	# Fill solid cells and weights one horizontal run at a time: far fewer
	# engine calls than one per sample.
	for j: int in size_z:
		var i: int = 0
		while i < size_x:
			var a: int = i
			var solid: bool = passable[j * size_x + i] == 0
			var weight: int = weights[j * size_x + i]
			i += 1
			while i < size_x and weights[j * size_x + i] == weight:
				i += 1
			var run: Rect2i = Rect2i(a, j, i - a, 1)
			if solid:
				grid.fill_solid_region(run, true)
			elif weight != 1:
				grid.fill_weight_scale_region(run, float(weight))
	return grid


static func _find(parent: PackedInt32Array, r: int) -> int:
	var root: int = r
	while parent[root] != root:
		root = parent[root]
	# Path compression.
	var n: int = r
	while parent[n] != root:
		var next: int = parent[n]
		parent[n] = root
		n = next
	return root


static func _union(parent: PackedInt32Array, a: int, b: int) -> void:
	var ra: int = _find(parent, a)
	var rb: int = _find(parent, b)
	if ra == rb:
		return
	# Keep the smaller index as root so labeling doesn't depend on union order.
	if ra < rb:
		parent[rb] = ra
	else:
		parent[ra] = rb
