extends GutTest
## Pathing must find walkable, smoothed, deterministic paths per mobility:
## straight when nothing is in the way, around walls without cutting corners,
## through Riverside's ford for living units and straight across the creek
## for undead, and to the nearest reachable point when the goal isn't.

const M: int = 1000
const LIVING: Terrain.Mobility = Terrain.Mobility.LIVING
const UNDEAD: Terrain.Mobility = Terrain.Mobility.UNDEAD
## Riverside's ford: sample column of its center (scripts/gen_riverside.gd
## FORD_X_M) and a half-width covering it plus its ramps.
const FORD_X: int = 300 * M
const FORD_ZONE_HALF: int = 12 * M
## Smoothing may clip the shallow shoulder beside the ford when cutting its
## corner, so wading is allowed this close to the ford, and nowhere else.
const FORD_APPROACH_HALF: int = 20 * M

var _riverside: Terrain
var _riverside_pathing: Pathing


func before_all() -> void:
	_riverside = TestTerrains.riverside()
	_riverside_pathing = Pathing.new(_riverside)


func test_open_ground_is_a_single_straight_leg() -> void:
	var p: Pathing = Pathing.new(TestTerrains.flat(64, 64))
	var path: PackedInt64Array = p.find_path(5_300, 5_700, 50_100, 40_900, LIVING)
	assert_eq(path, PackedInt64Array([50_100, 40_900]))


func test_goes_around_a_wall_through_its_gap() -> void:
	var rows: Array[String] = []
	for j: int in 40:
		var row: String = ".".repeat(40)
		if j < 30:
			row = row.substr(0, 20) + "#" + row.substr(21)
		rows.append(row)
	var t: Terrain = TestTerrains.from_ascii(rows)
	var p: Pathing = Pathing.new(t)
	var path: PackedInt64Array = p.find_path(5 * M, 5 * M, 35 * M, 5 * M, LIVING)
	assert_false(path.is_empty())
	assert_eq([path[path.size() - 2], path[path.size() - 1]], [35 * M, 5 * M], "ends on the goal")
	var deepest: int = 0
	for k: int in path.size() / 2:
		deepest = maxi(deepest, path[k * 2 + 1])
	assert_gte(deepest, 30 * M, "detours down to the gap below the wall")
	_assert_walkable(p, 5 * M, 5 * M, path, LIVING)
	assert_lte(path.size() / 2, 4, "smoothed to a few corners: %s" % [path])


func test_smoothing_keeps_the_dry_detour_around_a_wade() -> void:
	# Depth-2 water (weight 3) blocks the straight line; walking around it
	# through the dry gap below is cheaper, and smoothing must not undo that.
	var rows: Array[String] = []
	for j: int in 15:
		var row: String = ".".repeat(30)
		if j < 10:
			row = row.substr(0, 12) + "222222" + row.substr(18)
		rows.append(row)
	var t: Terrain = TestTerrains.from_ascii(rows)
	var p: Pathing = Pathing.new(t)
	assert_false(p.can_walk_straight(5 * M, 5 * M, 25 * M, 5 * M, LIVING), "the line wades")
	var path: PackedInt64Array = p.find_path(5 * M, 5 * M, 25 * M, 5 * M, LIVING)
	_assert_walkable(p, 5 * M, 5 * M, path, LIVING)
	var wet: Array[Vector2i] = []
	for point: Vector2i in _points_along(5 * M, 5 * M, path, 100):
		if t.water_depth_at(point.x, point.y) > 0:
			wet.append(point)
	assert_eq(wet.size(), 0, "path wades at %s" % [wet])


func test_line_of_sight_never_squeezes_between_diagonal_blocks() -> void:
	var rows: Array[String] = [
		"....",
		".#..",
		"..#.",
		"....",
	]
	var p: Pathing = Pathing.new(TestTerrains.from_ascii(rows))
	# Center of (1, 2) to center of (2, 1): exactly through the corner that
	# the two blocked samples touch at.
	assert_false(p.has_line_of_sight(1 * M, 2 * M, 2 * M, 1 * M, LIVING))
	var path: PackedInt64Array = p.find_path(1 * M, 2 * M, 2 * M, 1 * M, LIVING)
	_assert_walkable(p, 1 * M, 2 * M, path, LIVING)
	assert_gt(path.size(), 2, "must go around, not through the corner")


func test_line_of_sight_matches_fine_sampling() -> void:
	var gen: RandomNumberGenerator = RandomNumberGenerator.new()
	gen.seed = 4242
	var rows: Array[String] = []
	for j: int in 24:
		var row: String = ""
		for i: int in 24:
			row += "#" if gen.randi_range(0, 99) < 12 else "."
		rows.append(row)
	var t: Terrain = TestTerrains.from_ascii(rows)
	var p: Pathing = Pathing.new(t)
	var mismatches: Array[String] = []
	for n: int in 400:
		# Odd offsets keep segments off exact cell corners, where the fast
		# walk is deliberately stricter than point sampling.
		var ax: int = gen.randi_range(0, 23_000) | 1
		var az: int = gen.randi_range(0, 23_000) | 1
		var bx: int = gen.randi_range(0, 23_000) | 1
		var bz: int = gen.randi_range(0, 23_000) | 1
		var fast: bool = p.has_line_of_sight(ax, az, bx, bz, LIVING)
		var slow: bool = _sampled_line_of_sight(t, ax, az, bx, bz)
		if fast != slow:
			mismatches.append("(%d,%d)->(%d,%d) fast=%s" % [ax, az, bx, bz, fast])
	assert_eq(mismatches.size(), 0, "LOS disagrees with sampling: %s" % [mismatches])


func test_unreachable_goal_snaps_to_nearest_reachable_point() -> void:
	var rows: Array[String] = []
	for j: int in 20:
		# Columns 10..14 are deep water: impassable to living units.
		rows.append("..........33333.....")
	var t: Terrain = TestTerrains.from_ascii(rows)
	var p: Pathing = Pathing.new(t)
	var path: PackedInt64Array = p.find_path(2 * M, 10 * M, 12 * M, 10 * M, LIVING)
	assert_eq([path[path.size() - 2], path[path.size() - 1]], [9 * M, 10 * M],
		"stops at the near bank")
	# Undead walk into the deep water.
	var undead: PackedInt64Array = p.find_path(2 * M, 10 * M, 12 * M, 10 * M, UNDEAD)
	assert_eq(undead, PackedInt64Array([12 * M, 10 * M]))


func test_goal_across_a_barrier_snaps_to_the_start_side() -> void:
	# The deep channel splits the map; the far bank is another component.
	var rows: Array[String] = []
	for j: int in 20:
		rows.append("..........3.........")
	var p: Pathing = Pathing.new(TestTerrains.from_ascii(rows))
	var path: PackedInt64Array = p.find_path(2 * M, 10 * M, 15 * M, 10 * M, LIVING)
	assert_eq([path[path.size() - 2], path[path.size() - 1]], [9 * M, 10 * M])


func test_components_split_by_walls_and_water() -> void:
	var rows: Array[String] = [
		"..#..",
		"..#..",
		"..3..",
		"..#..",
	]
	var p: Pathing = Pathing.new(TestTerrains.from_ascii(rows))
	var west: int = p.component_at(0, 0, LIVING)
	var east: int = p.component_at(4 * M, 0, LIVING)
	assert_ne(west, PathLayer.NO_COMPONENT)
	assert_ne(west, east, "living units can't cross")
	assert_eq(p.component_at(2 * M, 0, LIVING), PathLayer.NO_COMPONENT, "wall")
	assert_eq(p.component_at(0, 0, UNDEAD), p.component_at(4 * M, 0, UNDEAD),
		"undead wade the depth-3 gap")


func test_astar_settings_are_pinned_for_determinism() -> void:
	# See PathLayer's class comment: only Chebyshev (or Manhattan) heuristics
	# and whole-number weights keep float A* scores exact on every platform.
	var rows: Array[String] = ["..12", "...."]
	var l: PathLayer = Pathing.new(TestTerrains.from_ascii(rows)).layer(LIVING)
	assert_eq(l.astar.default_compute_heuristic, AStarGrid2D.HEURISTIC_CHEBYSHEV)
	assert_eq(l.astar.default_estimate_heuristic, AStarGrid2D.HEURISTIC_CHEBYSHEV)
	assert_eq(l.astar.diagonal_mode, AStarGrid2D.DIAGONAL_MODE_ONLY_IF_NO_OBSTACLES)
	assert_false(l.astar.jumping_enabled)
	for k: int in PathLayer.LIVING_WATER_WEIGHTS.size():
		var w: int = PathLayer.LIVING_WATER_WEIGHTS[k]
		assert_gte(w, 1)
	assert_eq(l.astar.get_point_weight_scale(Vector2i(2, 0)), 2.0)
	assert_eq(l.astar.get_point_weight_scale(Vector2i(3, 0)), 3.0)
	assert_eq(l.astar.get_point_weight_scale(Vector2i(0, 0)), 1.0)


func test_no_shipped_map_can_reach_an_inexact_astar_score() -> void:
	# AStarGrid2D sums scores in float32, exact for integers below 2^24. The
	# worst path visits every cell once at the heaviest weight; the estimate
	# adds at most the map's diagonal, which is smaller than that.
	var heaviest: int = 0
	for w: int in PathLayer.LIVING_WATER_WEIGHTS:
		heaviest = maxi(heaviest, w)
	for path: String in [
		"res://maps/riverside/riverside.tres", "res://maps/the_ford/the_ford.tres",
		"res://maps/old_mill/old_mill.tres",
	]:
		var info: MapInfo = load(path) as MapInfo
		var file: FileAccess = FileAccess.open(info.heightmap_path, FileAccess.READ)
		assert_not_null(file, path)
		if file == null:
			continue
		# A PNG's width and height are big-endian at bytes 16 and 20.
		file.big_endian = true
		file.seek(16)
		var cells: int = file.get_32() * file.get_32()
		assert_lt(cells * heaviest * 2, 1 << 24, "%s: %d cells" % [path, cells])


func test_riverside_living_path_crosses_at_the_ford() -> void:
	var from: Vector2i = Vector2i(150 * M, 200 * M)
	var to: Vector2i = Vector2i(150 * M, 360 * M)
	var started: int = Time.get_ticks_usec()
	var path: PackedInt64Array = _riverside_pathing.find_path(from.x, from.y, to.x, to.y, LIVING)
	gut.p("Riverside creek detour: %d us including first-use grid build, %d corners" % [
		Time.get_ticks_usec() - started, path.size() / 2
	])
	assert_eq([path[path.size() - 2], path[path.size() - 1]], [to.x, to.y])
	_assert_walkable(_riverside_pathing, from.x, from.y, path, LIVING)
	var wet_in_ford: int = 0
	var wet_away_from_ford: Array[Vector2i] = []
	for point: Vector2i in _points_along(from.x, from.y, path, 250):
		if _riverside.water_depth_at(point.x, point.y) == 0:
			continue
		var off: int = absi(point.x - FORD_X)
		if off <= FORD_ZONE_HALF:
			wet_in_ford += 1
		elif off > FORD_APPROACH_HALF:
			wet_away_from_ford.append(point)
	assert_gt(wet_in_ford, 0, "wades the ford")
	assert_eq(wet_away_from_ford.size(), 0, "wades away from the ford at %s" % [wet_away_from_ford])


func test_riverside_undead_path_walks_straight_through_the_creek() -> void:
	var path: PackedInt64Array = _riverside_pathing.find_path(150 * M, 200 * M, 150 * M, 360 * M, UNDEAD)
	assert_eq(path, PackedInt64Array([150 * M, 360 * M]))


func test_riverside_path_is_deterministic() -> void:
	var a: PackedInt64Array = _riverside_pathing.find_path(150 * M, 200 * M, 400 * M, 330 * M, LIVING)
	var b: PackedInt64Array = Pathing.new(_riverside).find_path(150 * M, 200 * M, 400 * M, 330 * M, LIVING)
	assert_eq(a, b)


# Every point along the path, at step spacing, stands on a passable sample.
func _assert_walkable(
	p: Pathing, from_x: int, from_z: int, path: PackedInt64Array, mobility: Terrain.Mobility
) -> void:
	var bad: Array[Vector2i] = []
	for point: Vector2i in _points_along(from_x, from_z, path, 100):
		if not p.terrain.is_passable(point.x, point.y, mobility):
			bad.append(point)
	assert_eq(bad.size(), 0, "path crosses impassable ground at %s" % [bad])


func _points_along(from_x: int, from_z: int, path: PackedInt64Array, step: int) -> Array[Vector2i]:
	var points: Array[Vector2i] = []
	var ax: int = from_x
	var az: int = from_z
	for k: int in path.size() / 2:
		var bx: int = path[k * 2]
		var bz: int = path[k * 2 + 1]
		var n: int = maxi(1, FixedMath.length(bx - ax, bz - az) / step)
		for s: int in n + 1:
			points.append(Vector2i(ax + (bx - ax) * s / n, az + (bz - az) * s / n))
		ax = bx
		az = bz
	return points


func _sampled_line_of_sight(t: Terrain, ax: int, az: int, bx: int, bz: int) -> bool:
	var n: int = maxi(1, FixedMath.length(bx - ax, bz - az) / 5)
	for s: int in n + 1:
		if not t.is_passable(ax + (bx - ax) * s / n, az + (bz - az) * s / n, LIVING):
			return false
	return true
