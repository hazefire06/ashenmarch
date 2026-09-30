class_name Pathing
extends RefCounted
## Grid pathfinding on the terrain's sample grid, one PathLayer per Mobility,
## built on first use. All inputs and outputs are milli-unit positions; a
## position belongs to its nearest sample, the same rule Terrain.is_passable
## uses, so a path never disagrees with what movement will allow.
##
## find_path() tries a straight line first and only runs A* when it is
## blocked. A* paths are then string-pulled so units walk straight lines
## between corners instead of grid steps.

## How many raw A* steps ahead string-pulling looks for a visible waypoint.
## Bounds the cost of smoothing; a second pass over the corners joins
## straight runs longer than this.
const SMOOTH_LOOKAHEAD: int = 48
const SECOND_PASS_LOOKAHEAD: int = 8

var terrain: Terrain
var _layers: Dictionary[int, PathLayer] = {}


func _init(world_terrain: Terrain) -> void:
	terrain = world_terrain


## The pathing data for a mobility, built the first time it is asked for.
func layer(mobility: Terrain.Mobility) -> PathLayer:
	if not _layers.has(mobility):
		_layers[mobility] = PathLayer.new(terrain, mobility)
	return _layers[mobility]


## Component id of the sample nearest (x, z), or PathLayer.NO_COMPONENT.
func component_at(x: int, z: int, mobility: Terrain.Mobility) -> int:
	if not terrain.contains(x, z):
		return PathLayer.NO_COMPONENT
	var s: Vector2i = terrain.nearest_sample(x, z)
	return layer(mobility).component_at(s.x, s.y)


## (x, z) itself if its nearest sample is in the component, else the center of
## the nearest sample that is. Pass PathLayer.NO_COMPONENT to accept any
## passable sample. Returns (x, z) unchanged if nothing qualifies.
func snap_to_component(x: int, z: int, mobility: Terrain.Mobility, component: int) -> Vector2i:
	var l: PathLayer = layer(mobility)
	var cs: int = terrain.cell_size
	var center: Vector2i = terrain.nearest_sample(x, z)
	if terrain.contains(x, z) and _accepts(l, center.x, center.y, component):
		return Vector2i(x, z)
	# Ring search outward. A sample on ring r is at least (r - 1/2) cells from
	# (x, z), so stop once that exceeds the best distance found.
	var best: Vector2i = Vector2i(-1, -1)
	var best_d2: int = -1
	var max_ring: int = maxi(terrain.size_x, terrain.size_z)
	for r: int in range(0, max_ring + 1):
		var near: int = (2 * r - 1) * cs
		if best_d2 >= 0 and near > 0 and near * near > 4 * best_d2:
			break
		for s: Vector2i in _ring(center, r):
			if not _accepts(l, s.x, s.y, component):
				continue
			var dx: int = s.x * cs - x
			var dz: int = s.y * cs - z
			var d2: int = dx * dx + dz * dz
			if best_d2 < 0 or d2 < best_d2:
				best_d2 = d2
				best = s
	if best_d2 < 0:
		return Vector2i(x, z)
	return Vector2i(best.x * cs, best.y * cs)


## True if a unit of this mobility should walk straight from a to b rather
## than path: the line is walkable and never crosses ground costlier than its
## two ends (so it won't wade through water A* would have walked around).
func can_walk_straight(ax: int, az: int, bx: int, bz: int, mobility: Terrain.Mobility) -> bool:
	var l: PathLayer = layer(mobility)
	var a: Vector2i = terrain.nearest_sample(ax, az)
	var b: Vector2i = terrain.nearest_sample(bx, bz)
	var max_weight: int = maxi(l.weight_at(a.x, a.y), l.weight_at(b.x, b.y))
	return has_line_of_sight(ax, az, bx, bz, mobility, max_weight)


## True if a unit of this mobility can walk the straight segment from a to b:
## every sample cell the segment passes through is passable (and, if
## max_weight > 0, no heavier than max_weight), and where it crosses exactly
## through a cell corner, both cells beside the corner are too (no squeezing
## diagonally between two obstacles).
func has_line_of_sight(
	ax: int, az: int, bx: int, bz: int, mobility: Terrain.Mobility, max_weight: int = 0
) -> bool:
	if not terrain.contains(ax, az) or not terrain.contains(bx, bz):
		return false
	var l: PathLayer = layer(mobility)
	var cs: int = terrain.cell_size
	# Shift by half a cell so sample (i, j) owns [i*cs, (i+1)*cs) on each axis:
	# the cell of the nearest sample.
	var half: int = cs / 2
	var x0: int = ax + half
	var z0: int = az + half
	var x1: int = bx + half
	var z1: int = bz + half
	var i: int = x0 / cs
	var j: int = z0 / cs
	var i_end: int = x1 / cs
	var j_end: int = z1 / cs
	var limit: int = max_weight if max_weight > 0 else 255
	if not _walkable(l, i, j, limit):
		return false
	var dx: int = x1 - x0
	var dz: int = z1 - z0
	var si: int = signi(dx)
	var sj: int = signi(dz)
	var adx: int = absi(dx)
	var adz: int = absi(dz)
	# Distance along each axis to the next cell boundary. Comparing
	# ex / adx with ez / adz (cross-multiplied) says which is crossed first.
	var ex: int = (i + 1) * cs - x0 if si > 0 else x0 - i * cs
	var ez: int = (j + 1) * cs - z0 if sj > 0 else z0 - j * cs
	while i != i_end or j != j_end:
		if i == i_end:
			j += sj
			ez += cs
		elif j == j_end:
			i += si
			ex += cs
		else:
			var tx: int = ex * adz
			var tz: int = ez * adx
			if tx < tz:
				i += si
				ex += cs
			elif tz < tx:
				j += sj
				ez += cs
			else:
				if not _walkable(l, i + si, j, limit) or not _walkable(l, i, j + sj, limit):
					return false
				i += si
				j += sj
				ex += cs
				ez += cs
		if not _walkable(l, i, j, limit):
			return false
	return true


## Waypoints from (from_x, from_z) toward (to_x, to_z) as x, z pairs in
## milli-units, excluding the start. The last waypoint is the goal, or the
## nearest point reachable from the start if the goal isn't. Empty if the
## start itself is impassable.
func find_path(from_x: int, from_z: int, to_x: int, to_z: int, mobility: Terrain.Mobility) -> PackedInt64Array:
	var l: PathLayer = layer(mobility)
	var start: Vector2i = terrain.nearest_sample(from_x, from_z)
	var component: int = l.component_at(start.x, start.y)
	if component == PathLayer.NO_COMPONENT or not terrain.contains(from_x, from_z):
		return PackedInt64Array()
	var goal: Vector2i = snap_to_component(to_x, to_z, mobility, component)
	if can_walk_straight(from_x, from_z, goal.x, goal.y, mobility):
		return PackedInt64Array([goal.x, goal.y])
	var goal_sample: Vector2i = terrain.nearest_sample(goal.x, goal.y)
	var cells: Array[Vector2i] = l.astar.get_id_path(start, goal_sample)
	if cells.is_empty():
		return PackedInt64Array()
	# Raw corners: every A* cell after the start, the last replaced by the
	# exact goal (which lies inside that cell).
	var cs: int = terrain.cell_size
	var raw: PackedInt64Array = PackedInt64Array()
	for k: int in range(1, cells.size()):
		raw.append(cells[k].x * cs)
		raw.append(cells[k].y * cs)
	if raw.is_empty():
		raw.append_array(PackedInt64Array([goal.x, goal.y]))
	raw[raw.size() - 2] = goal.x
	raw[raw.size() - 1] = goal.y
	var once: PackedInt64Array = _string_pull(from_x, from_z, raw, SMOOTH_LOOKAHEAD, mobility)
	return _string_pull(from_x, from_z, once, SECOND_PASS_LOOKAHEAD, mobility)


# Greedy string-pulling: from the current anchor, keep the farthest of the
# next `lookahead` waypoints that is in straight-line reach, then continue
# from it. A shortcut may not cross ground heavier than the heaviest point
# it replaces, so smoothing never trades A*'s dry detour for a wade.
# Consecutive waypoints of the input must already be mutually reachable,
# which A* neighbors (and a previous pass's output) are.
func _string_pull(
	from_x: int, from_z: int, points: PackedInt64Array, lookahead: int, mobility: Terrain.Mobility
) -> PackedInt64Array:
	var l: PathLayer = layer(mobility)
	var out: PackedInt64Array = PackedInt64Array()
	var n: int = points.size() / 2
	var ax: int = from_x
	var az: int = from_z
	var i: int = 0
	while i < n:
		var far: int = i
		var limit: int = mini(n - 1, i + lookahead)
		var anchor: Vector2i = terrain.nearest_sample(ax, az)
		var heaviest: int = maxi(l.weight_at(anchor.x, anchor.y), _point_weight(l, points, i))
		var k: int = i + 1
		while k <= limit:
			heaviest = maxi(heaviest, _point_weight(l, points, k))
			if not has_line_of_sight(ax, az, points[k * 2], points[k * 2 + 1], mobility, heaviest):
				break
			far = k
			k += 1
		ax = points[far * 2]
		az = points[far * 2 + 1]
		out.append(ax)
		out.append(az)
		i = far + 1
	return out


func _point_weight(l: PathLayer, points: PackedInt64Array, k: int) -> int:
	var s: Vector2i = terrain.nearest_sample(points[k * 2], points[k * 2 + 1])
	return l.weight_at(s.x, s.y)


static func _walkable(l: PathLayer, i: int, j: int, max_weight: int) -> bool:
	var w: int = l.weight_at(i, j)
	return w > 0 and w <= max_weight


func _accepts(l: PathLayer, i: int, j: int, component: int) -> bool:
	if component == PathLayer.NO_COMPONENT:
		return l.is_passable(i, j)
	return l.component_at(i, j) == component


# Samples at Chebyshev distance r from center, in a fixed order: top and
# bottom rows left to right, then the left and right columns top to bottom.
# Samples off the map are skipped.
func _ring(center: Vector2i, r: int) -> Array[Vector2i]:
	var cells: Array[Vector2i] = []
	if r == 0:
		cells.append(center)
		return cells
	for i: int in range(center.x - r, center.x + r + 1):
		cells.append(Vector2i(i, center.y - r))
		cells.append(Vector2i(i, center.y + r))
	for j: int in range(center.y - r + 1, center.y + r):
		cells.append(Vector2i(center.x - r, j))
		cells.append(Vector2i(center.x + r, j))
	var on_map: Array[Vector2i] = []
	for c: Vector2i in cells:
		if c.x >= 0 and c.y >= 0 and c.x < terrain.size_x and c.y < terrain.size_z:
			on_map.append(c)
	return on_map
