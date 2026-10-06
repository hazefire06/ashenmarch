extends GutTest
## The two campaign maps, The Ford and Old Mill (Phase 8), as the game loads
## them: through Terrain.load_map and Pathing, the same code the sim runs. They
## are acceptance tests over the committed PNGs and the layout constants in
## scripts/gen_the_ford.gd and scripts/gen_old_mill.gd (which the mission
## data is written against), so a regenerated map that breaks a promise fails
## here, not in a playtest.

const M: int = 1000
const LIVING: Terrain.Mobility = Terrain.Mobility.LIVING
const UNDEAD: Terrain.Mobility = Terrain.Mobility.UNDEAD
const FLOATING: Terrain.Mobility = Terrain.Mobility.FLOATING
const FORD_MAP: String = "res://maps/the_ford/the_ford.tres"
const FORD_GENERATOR: String = "res://scripts/gen_the_ford.gd"
const MILL_MAP: String = "res://maps/old_mill/old_mill.tres"
const MILL_GENERATOR: String = "res://scripts/gen_old_mill.gd"
const RIVERSIDE_MAP: String = "res://maps/riverside/riverside.tres"
const FOUR_WAYS: Array[Vector2i] = [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]

var _ford: Terrain
var _ford_pathing: Pathing
var _ford_gen: Dictionary
var _ford_script: GDScript
var _mill: Terrain
var _mill_pathing: Pathing
var _mill_gen: Dictionary
var _mill_script: GDScript
var _ford_info: MapInfo
var _mill_info: MapInfo


func before_all() -> void:
	_ford_info = load(FORD_MAP) as MapInfo
	_mill_info = load(MILL_MAP) as MapInfo
	_ford = Terrain.load_map(_ford_info)
	_mill = Terrain.load_map(_mill_info)
	_ford_pathing = Pathing.new(_ford)
	_mill_pathing = Pathing.new(_mill)
	_ford_script = load(FORD_GENERATOR) as GDScript
	_mill_script = load(MILL_GENERATOR) as GDScript
	_ford_gen = _ford_script.get_script_constant_map()
	_mill_gen = _mill_script.get_script_constant_map()


# ---- helpers ----

## The sample nearest a point in meters.
func _at(p: Vector2) -> Vector2i:
	return Vector2i(roundi(p.x), roundi(p.y))


func _walkable(t: Terrain, p: Vector2, mobility: Terrain.Mobility = LIVING) -> bool:
	return t.is_sample_passable(roundi(p.x), roundi(p.y), mobility)


func _level(t: Terrain, p: Vector2) -> int:
	return t.sample_water_depth(roundi(p.x), roundi(p.y))


func _ground(t: Terrain, p: Vector2) -> int:
	return t.sample_ground(roundi(p.x), roundi(p.y))


func _height_m(t: Terrain, p: Vector2) -> float:
	return t.sample_height(roundi(p.x), roundi(p.y)) / 1000.0


func _component(pathing: Pathing, p: Vector2, mobility: Terrain.Mobility = LIVING) -> int:
	return pathing.component_at(roundi(p.x) * M, roundi(p.y) * M, mobility)


## The samples a LIVING unit starting at `from` can reach moving in the four
## directions (the sim never squeezes through a corner), as 1 per sample.
## Samples where `shut` is non-zero are treated as impassable.
func _flood(t: Terrain, from: Vector2i, shut: PackedByteArray = PackedByteArray()) -> PackedByteArray:
	var seen: PackedByteArray = PackedByteArray()
	seen.resize(t.size_x * t.size_z)
	if not t.is_sample_passable(from.x, from.y, LIVING):
		return seen
	var queue: PackedInt32Array = PackedInt32Array([from.y * t.size_x + from.x])
	seen[queue[0]] = 1
	var head: int = 0
	while head < queue.size():
		var k: int = queue[head]
		head += 1
		var i: int = k % t.size_x
		var j: int = floori(k / float(t.size_x))
		for step: Vector2i in FOUR_WAYS:
			var ni: int = i + step.x
			var nj: int = j + step.y
			if ni < 0 or nj < 0 or ni >= t.size_x or nj >= t.size_z:
				continue
			var nk: int = nj * t.size_x + ni
			if seen[nk] != 0 or (not shut.is_empty() and shut[nk] != 0):
				continue
			if t.is_sample_passable(ni, nj, LIVING):
				seen[nk] = 1
				queue.append(nk)
	return seen


func _reached(t: Terrain, seen: PackedByteArray, p: Vector2) -> bool:
	return seen[roundi(p.y) * t.size_x + roundi(p.x)] != 0


## A mask shutting the samples within radius_m of a center.
func _shut_disc(t: Terrain, center: Vector2, radius_m: float) -> PackedByteArray:
	var shut: PackedByteArray = PackedByteArray()
	shut.resize(t.size_x * t.size_z)
	for j: int in range(floori(center.y - radius_m), ceili(center.y + radius_m) + 1):
		for i: int in range(floori(center.x - radius_m), ceili(center.x + radius_m) + 1):
			if Vector2(i, j).distance_to(center) <= radius_m:
				shut[j * t.size_x + i] = 1
	return shut


## A mask shutting the samples with x in [x0, x1] and z in [z0, z1].
func _shut_box(t: Terrain, x0: int, x1: int, z0: int, z1: int) -> PackedByteArray:
	var shut: PackedByteArray = PackedByteArray()
	shut.resize(t.size_x * t.size_z)
	for j: int in range(z0, z1 + 1):
		for i: int in range(x0, x1 + 1):
			shut[j * t.size_x + i] = 1
	return shut


## Meters from p to the nearest point of a polyline.
func _distance_to_line(p: Vector2, line: PackedVector2Array) -> float:
	var nearest: float = INF
	for k: int in line.size() - 1:
		nearest = minf(nearest, p.distance_to(Geometry2D.get_closest_point_to_segment(p, line[k], line[k + 1])))
	return nearest


## The fraction of the dry, open samples of a box (samples x0..x1, z0..z1)
## that have one of the ground types.
func _share(t: Terrain, box: Rect2i, types: Array[int]) -> float:
	var dry: int = 0
	var hits: int = 0
	for j: int in range(box.position.y, box.end.y):
		for i: int in range(box.position.x, box.end.x):
			if t.sample_water_depth(i, j) == 0:
				dry += 1
				hits += 1 if types.has(t.sample_ground(i, j)) else 0
	return float(hits) / maxf(dry, 1)


func _ground_counts(t: Terrain) -> Array[int]:
	var counts: Array[int] = [0, 0, 0, 0, 0]
	for k: int in t.ground.size():
		counts[t.ground[k]] += 1
	return counts


## The Ford's river centerline at x, meters.
func _river_z(x: float) -> float:
	return float(_ford_gen["RIVER_Z_M"]) + float(_ford_gen["RIVER_SWING_M"]) * sin(TAU * x / float(_ford_gen["RIVER_PERIOD_M"]))


# ---- the profile helper the generators use for beds ----

func test_a_profile_interpolates_between_its_keys_and_holds_the_ends() -> void:
	var keys: Array[Vector2] = [Vector2(0.0, 3.0), Vector2(10.0, 1.0), Vector2(20.0, 0.0)]
	assert_eq(MapBuilder.profile(keys, -5.0), 3.0, "before the first key")
	assert_eq(MapBuilder.profile(keys, 0.0), 3.0)
	assert_almost_eq(MapBuilder.profile(keys, 5.0), 2.0, 0.0001)
	assert_eq(MapBuilder.profile(keys, 10.0), 1.0)
	assert_almost_eq(MapBuilder.profile(keys, 15.0), 0.5, 0.0001)
	assert_eq(MapBuilder.profile(keys, 99.0), 0.0, "past the last key")


# ---- The Ford: the map and the river ----

func test_the_ford_loads_at_384_samples_a_side_at_one_meter() -> void:
	assert_not_null(_ford, "The Ford loads")
	assert_eq([_ford.size_x, _ford.size_z], [384, 384])
	assert_eq(_ford_info.cell_size, 1000)
	assert_eq(_ford_info.max_height, 30000)
	assert_eq(_ford_info.max_walkable_slope, 1000)
	assert_eq(_ford_info.display_name, "The Ford")


func test_the_ford_plain_is_gentle_rolling_ground_of_three_to_ten_meters() -> void:
	var lowest: float = INF
	var highest: float = -INF
	var counted: int = 0
	var hamlet: Vector2 = _ford_gen["HAMLET_CENTER"]
	for j: int in _ford.size_z:
		for i: int in _ford.size_x:
			# Far from the river, which has its own valley, and the hamlet's pad.
			if absf(j - _river_z(i)) < 80.0 or Vector2(i, j).distance_to(hamlet) < 55.0:
				continue
			var h: float = _ford.sample_height(i, j) / 1000.0
			lowest = minf(lowest, h)
			highest = maxf(highest, h)
			counted += 1
			assert_lt(_ford.sample_slope(i, j), 300, "gentle at (%d, %d)" % [i, j])
	assert_gt(counted, 50000)
	assert_gte(lowest, 2.99, "no lower than 3 m")
	assert_lte(highest, 10.01, "no higher than 10 m")
	assert_gt(highest - lowest, 4.0, "and it does roll")


func test_the_river_runs_the_full_width_with_depth_by_distance_from_its_centerline() -> void:
	# At x = 75 the centerline is at z = 200 and level, so distance is |z - 200|.
	assert_eq(_river_z(75.0), 200.0)
	var by_distance: Dictionary[int, int] = {2: 4, 5: 4, 8: 3, 10: 3, 13: 2, 15: 2, 18: 1, 21: 1, 24: 0, 30: 0}
	for d: int in by_distance:
		for side: int in [-1, 1]:
			assert_eq(_ford.sample_water_depth(75, 200 + side * d), by_distance[d], "depth level %d m %s of the centerline" % [d, "north" if side < 0 else "south"])
	# Across the whole width, the water is about 44 m across wherever it has not
	# been reshaped (the ford, the pools).
	for x: int in [0, 20, 60, 100, 140, 250, 290, 330, 383]:
		var wet: int = 0
		var deepest: int = 0
		for j: int in _ford.size_z:
			var level: int = _ford.sample_water_depth(x, j)
			wet += 1 if level > 0 else 0
			deepest = maxi(deepest, level)
		assert_between(wet, 43, 46, "the water is 44 m across at x = %d" % x)
		assert_eq(deepest, 4, "with a depth-4 core")


func test_the_banks_are_sand_within_four_meters_of_the_water() -> void:
	var checked: int = 0
	for j: int in _ford.size_z:
		for i: int in _ford.size_x:
			if _ford.sample_water_depth(i, j) == 0:
				continue
			for dj: int in range(-4, 5):
				for di: int in range(-4, 5):
					var x: int = i + di
					var z: int = j + dj
					if x < 0 or z < 0 or x >= _ford.size_x or z >= _ford.size_z or Vector2(di, dj).length() > 4.0:
						continue
					checked += 1
					if _ford.sample_ground(x, z) != Terrain.Ground.SAND:
						assert_eq(_ford.sample_ground(x, z), Terrain.Ground.SAND, "(%d, %d) is within 4 m of water" % [x, z])
						return
	assert_gt(checked, 100000)


# ---- The Ford: the crossing ----

func test_the_ford_is_shallow_across_the_whole_channel() -> void:
	# x 186..198: depth level 2 or less everywhere; x 189..195: level 1 or less.
	for x: int in range(186, 199):
		for z: int in range(150, 230):
			var level: int = _ford.sample_water_depth(x, z)
			assert_lte(level, 2, "level at (%d, %d)" % [x, z])
			if x >= 189 and x <= 195:
				assert_lte(level, 1, "level in the middle of the ford at (%d, %d)" % [x, z])
	# And it is real water: the middle of the river there is level 1.
	assert_eq(_ford.sample_water_depth(192, 186), 1)


func test_the_ford_is_the_only_crossing_for_living_units() -> void:
	var deploy: Vector2 = _ford_gen["DEPLOY"]
	var landing: Vector2 = _ford_gen["LANDING_GUARD"]
	var open: PackedByteArray = _flood(_ford, _at(deploy))
	assert_true(_reached(_ford, open, landing), "walking from the deploy area, the landing is reachable")
	# Shut the ford's columns across the whole river valley (it is z 160 to 215).
	var ford_shut: PackedByteArray = _shut_box(_ford, 180, 204, 150, 230)
	var shut_off: PackedByteArray = _flood(_ford, _at(deploy), ford_shut)
	var far_bank: int = 0
	for j: int in range(0, 160):
		for i: int in _ford.size_x:
			far_bank += shut_off[j * _ford.size_x + i]
	assert_eq(far_bank, 0, "with x 180 to 204 shut, no sample north of the river is reachable")
	assert_gt(shut_off.count(1), 30000, "though the south bank is, so the flood is not vacuous")


func test_a_path_over_the_river_wades_only_at_the_ford() -> void:
	var start: Vector2 = _ford_gen["VILLAGER_START"]
	var goal: Vector2 = _ford_gen["GATE_AREA_CENTER"]
	var path: PackedInt64Array = _ford_pathing.find_path(roundi(start.x) * M, roundi(start.y) * M, roundi(goal.x) * M, roundi(goal.y) * M, LIVING)
	assert_gt(path.size(), 4, "there is a path")
	var wet: int = 0
	var at: Vector2 = start
	for k: int in range(0, path.size(), 2):
		var to: Vector2 = Vector2(path[k] / float(M), path[k + 1] / float(M))
		for step: int in ceili(at.distance_to(to)):
			var p: Vector2 = at.move_toward(to, step)
			if _level(_ford, p) > 0:
				wet += 1
				assert_lte(absf(p.x - 192.0), 12.0, "wet only at the ford, not at %s" % p)
		at = to
	assert_gt(wet, 20, "and it does cross the river")


# ---- The Ford: the ambush pools ----

func test_the_ambush_pools_are_deep_all_round_their_centers() -> void:
	var pools: Array = _ford_gen["POOLS"]
	assert_eq(pools.size(), 2)
	var ford_x: float = _ford_gen["FORD_X_M"]
	assert_lt(float(pools[0].x), ford_x - 20.0, "one pool west of the ford")
	assert_gt(float(pools[1].x), ford_x + 20.0, "one east")
	var core: float = _ford_gen["POOL_CORE_RADIUS_M"]
	for pool: Vector2 in pools:
		assert_eq(_level(_ford, pool), 4, "the center of the pool at %s is depth 4" % pool)
		for dj: int in range(-3, 4):
			for di: int in range(-3, 4):
				assert_gte(_level(_ford, pool + Vector2(di, dj)), 3, "within 3 m of the center of the pool at %s" % pool)
		for dj: int in range(-8, 9):
			for di: int in range(-8, 9):
				if Vector2(di, dj).length() <= core:
					assert_eq(_level(_ford, pool + Vector2(di, dj)), 4, "forced to depth 4 within %d m of %s" % [core, pool])


func test_the_pools_are_deep_enough_to_drown_a_living_unit_and_open_to_the_undead() -> void:
	var landing: Vector2 = _ford_gen["LANDING_GUARD"]
	var undead_landing: int = _component(_ford_pathing, landing, UNDEAD)
	for pool: Vector2 in _ford_gen["POOLS"]:
		assert_false(_walkable(_ford, pool, LIVING), "no living unit stands in the pool at %s" % pool)
		assert_true(_walkable(_ford, pool, UNDEAD), "a Husk can lurk there")
		assert_eq(_component(_ford_pathing, pool, UNDEAD), undead_landing, "and come out at the landing")


# ---- The Ford: road, hamlet, gate ----

func test_the_road_is_sand_from_the_deploy_area_across_the_ford_to_the_gate() -> void:
	var road: PackedVector2Array = _ford_gen["ROAD"]
	assert_eq(road[0], _ford_gen["DEPLOY"], "it starts at the deploy area")
	assert_true(road.has(_ford_gen["GATE_AREA_CENTER"] as Vector2), "and passes the gate area's center")
	assert_eq(road[road.size() - 1], _ford_gen["HAMLET_CENTER"], "and ends at the hamlet's square")
	for k: int in road.size() - 1:
		for step: int in ceili(road[k].distance_to(road[k + 1])) + 1:
			var p: Vector2 = road[k].move_toward(road[k + 1], step)
			assert_eq(_ground(_ford, p), Terrain.Ground.SAND, "road at %s" % p)
			assert_eq(_ford.blocked[roundi(p.y) * _ford.size_x + roundi(p.x)], 0, "open at %s" % p)
	assert_eq(_ford_gen["ROAD_WIDTH_M"], 4.0)
	# 4 m wide: a sample 1.5 m off the line is sand too (on dry ground, away from the water).
	assert_eq(_ground(_ford, Vector2(193.0, 270.0)), Terrain.Ground.SAND)
	assert_eq(_ground(_ford, Vector2(191.0, 270.0)), Terrain.Ground.SAND)


func test_the_palisade_is_a_blocked_rock_wall_all_round_but_the_gate() -> void:
	var center: Vector2 = _ford_gen["HAMLET_CENTER"]
	var radius: float = _ford_gen["HAMLET_RADIUS_M"]
	var bearing: float = _ford_gen["GATE_BEARING_DEG"]
	var gate_arc: float = rad_to_deg(float(_ford_gen["GATE_WIDTH_M"]) / radius)
	var pad: float = _height_m(_ford, center)
	var walls: int = 0
	for degrees: int in range(0, 360, 2):
		if absf(wrapf(degrees - bearing + 180.0, 0.0, 360.0) - 180.0) < gate_arc / 2.0 + 4.0:
			continue
		var p: Vector2 = center + Vector2.from_angle(deg_to_rad(degrees)) * radius
		walls += 1
		assert_eq(_ford.blocked[roundi(p.y) * _ford.size_x + roundi(p.x)], 1, "wall at %d degrees is blocked" % degrees)
		assert_eq(_ground(_ford, p), Terrain.Ground.ROCK, "rock at %d degrees" % degrees)
		assert_between(_height_m(_ford, p) - pad, 2.8, 3.2, "3 m tall at %d degrees" % degrees)
	assert_gt(walls, 150)


func test_the_gate_gap_is_open_and_the_only_way_in() -> void:
	var center: Vector2 = _ford_gen["HAMLET_CENTER"]
	var gap: Vector2 = _ford_gen["GATE_GAP_CENTER"]
	var along: Vector2 = (gap - center).normalized()
	var across: Vector2 = along.orthogonal()
	assert_almost_eq(gap.distance_to(center), float(_ford_gen["HAMLET_RADIUS_M"]), 0.2, "the gap is on the wall line")
	assert_almost_eq(rad_to_deg(along.angle()), float(_ford_gen["GATE_BEARING_DEG"]), 0.5, "on the gate's bearing, south-west of the center")
	assert_true(along.x < 0.0 and along.y > 0.0, "south-west, toward the road")
	# Across the gap, at the wall line: a run of walkable samples at least 4 wide.
	var run: int = 0
	var longest: int = 0
	for t: int in range(-6, 7):
		if _walkable(_ford, gap + across * t):
			run += 1
			longest = maxi(longest, run)
		else:
			run = 0
	assert_gte(longest, 4, "a walkable core of at least 4 m through the gate")
	assert_lte(longest, 8, "and the gap is about 7 m, not a breach")
	# Through it, and nowhere else.
	var outside: Vector2 = _ford_gen["LANDING_GUARD"]
	var inside: Vector2 = center
	var open: PackedByteArray = _flood(_ford, _at(outside))
	assert_true(_reached(_ford, open, inside), "a living unit walks in from the road")
	assert_true(_reached(_ford, open, _ford_gen["GATE_AREA_CENTER"]))
	var shut: PackedByteArray = _shut_disc(_ford, gap, 6.5)
	var sealed: PackedByteArray = _flood(_ford, _at(outside), shut)
	assert_false(_reached(_ford, sealed, inside), "with the gate shut, the hamlet cannot be reached")
	assert_false(_reached(_ford, sealed, Vector2(255.0, 40.0)), "nor its far side")


func test_the_hamlet_has_four_or_five_houses_inside_the_wall() -> void:
	var houses: Array = _ford_gen["HAMLET_HOUSES"]
	assert_between(houses.size(), 4, 5)
	var center: Vector2 = _ford_gen["HAMLET_CENTER"]
	for h: Vector4 in houses:
		var corners: Array[Vector2] = [
			Vector2(h.x - h.z / 2.0, h.y - h.w / 2.0), Vector2(h.x + h.z / 2.0, h.y + h.w / 2.0),
			Vector2(h.x - h.z / 2.0, h.y + h.w / 2.0), Vector2(h.x + h.z / 2.0, h.y - h.w / 2.0),
		]
		for corner: Vector2 in corners:
			assert_lt(corner.distance_to(center), float(_ford_gen["HAMLET_RADIUS_M"]) - 6.0, "house at (%d, %d) is well inside the wall" % [h.x, h.y])
		var p: Vector2 = Vector2(h.x, h.y)
		assert_eq(_ford.blocked[roundi(p.y) * _ford.size_x + roundi(p.x)], 1, "house at %s is blocked" % p)
		assert_eq(_ground(_ford, p), Terrain.Ground.WOOD, "and wood")
		assert_between(_height_m(_ford, p) - _height_m(_ford, center), 2.5, 3.5, "and 3 m tall")
	for i: int in houses.size():
		for j: int in range(i + 1, houses.size()):
			assert_gt(Vector2(houses[i].x, houses[i].y).distance_to(Vector2(houses[j].x, houses[j].y)), 11.0, "houses do not touch")


# ---- The Ford: the escort ----

func test_the_escort_route_is_one_living_component_and_ends_in_the_gate_area() -> void:
	var start: Vector2 = _ford_gen["VILLAGER_START"]
	var waypoints: Array = _ford_gen["ESCORT_WAYPOINTS"]
	assert_eq(waypoints.size(), 6)
	assert_true(_walkable(_ford, start), "the villager starts on walkable ground")
	var home: int = _component(_ford_pathing, start)
	assert_ne(home, PathLayer.NO_COMPONENT)
	var north: float = INF
	for wp: Vector2 in waypoints:
		assert_true(_walkable(_ford, wp), "waypoint %s is walkable" % wp)
		assert_eq(_component(_ford_pathing, wp), home, "waypoint %s is in the villager's component" % wp)
		assert_eq(_ground(_ford, wp), Terrain.Ground.SAND, "and on the road")
		assert_lt(wp.y, north, "each leg heads north")
		north = wp.y
	var gate: Vector2 = _ford_gen["GATE_AREA_CENTER"]
	assert_lte(waypoints[waypoints.size() - 1].distance_to(gate), float(_ford_gen["GATE_AREA_RADIUS_M"]), "the last waypoint is inside the gate area")
	assert_eq(_ford_gen["GATE_AREA_RADIUS_M"], 7.0)
	# The gate area is just inside the gap: 22 to 28 m from the hamlet's center, within 6 m of the gap.
	var center: Vector2 = _ford_gen["HAMLET_CENTER"]
	assert_between(gate.distance_to(center), 22.0, 28.0, "inside the wall")
	assert_lt(gate.distance_to(_ford_gen["GATE_GAP_CENTER"]), 6.0, "close behind the gap")
	assert_true(_walkable(_ford, gate), "on walkable ground")


func test_every_leg_of_the_escort_has_a_path() -> void:
	var points: Array[Vector2] = [_ford_gen["VILLAGER_START"]]
	points.append_array(_ford_gen["ESCORT_WAYPOINTS"])
	for k: int in points.size() - 1:
		var a: Vector2 = points[k]
		var b: Vector2 = points[k + 1]
		var path: PackedInt64Array = _ford_pathing.find_path(roundi(a.x) * M, roundi(a.y) * M, roundi(b.x) * M, roundi(b.y) * M, LIVING)
		assert_gte(path.size(), 2, "a path from %s to %s" % [a, b])
		assert_eq([path[path.size() - 2], path[path.size() - 1]], [roundi(b.x) * M, roundi(b.y) * M], "that ends exactly at the waypoint")


func test_the_villager_starts_inside_the_escort_radius_of_the_deploy_point() -> void:
	var deploy: Vector2 = _ford_gen["DEPLOY"]
	var start: Vector2 = _ford_gen["VILLAGER_START"]
	assert_true(_walkable(_ford, deploy), "the deploy point is walkable")
	assert_eq(_component(_ford_pathing, deploy), _component(_ford_pathing, start), "in the villager's component")
	assert_lte(start.distance_to(deploy), 8.0, "within 8 m, so the villager starts escorted (12 m)")
	assert_ne(start, deploy, "but not on top of the deploy point")


func test_the_named_points_of_the_ford_are_where_the_mission_needs_them() -> void:
	var landing: Vector2 = _ford_gen["LANDING_GUARD"]
	assert_true(_walkable(_ford, landing))
	assert_eq(_level(_ford, landing), 0, "the landing guard stands on dry ground")
	assert_lt(landing.y, 160.0, "north of the river")
	var camera: Vector2 = _ford_gen["CAMERA_START"]
	assert_true(_walkable(_ford, camera))
	# Drifters (FLOATING) patrol the water: each patrol point is water, open to
	# them, and the two ends of a patrol are connected.
	for patrol: Array in [_ford_gen["DRIFTER_WEST"], _ford_gen["DRIFTER_EAST"]]:
		assert_eq(patrol.size(), 2)
		for p: Vector2 in patrol:
			assert_gte(_level(_ford, p), 3, "the Drifter point %s is over deep water" % p)
			assert_true(_walkable(_ford, p, FLOATING), "and open to a Drifter")
		assert_eq(_component(_ford_pathing, patrol[0], FLOATING), _component(_ford_pathing, patrol[1], FLOATING), "a patrol is one connected route")
	var west: Array = _ford_gen["DRIFTER_WEST"]
	var east: Array = _ford_gen["DRIFTER_EAST"]
	assert_lt(float(west[1].x), 192.0, "one patrol west of the ford")
	assert_gt(float(east[0].x), 192.0, "one east")


func test_the_east_woods_hold_the_ripper_spawn_and_it_reaches_the_landing() -> void:
	var spawn: Vector2 = _ford_gen["RIPPER_SPAWN"]
	var landing: Vector2 = _ford_gen["LANDING_GUARD"]
	assert_true(_walkable(_ford, spawn), "a Ripper can stand at its spawn")
	assert_true([Terrain.Ground.WOOD, Terrain.Ground.BRUSH].has(_ground(_ford, spawn)), "in the woods")
	assert_between(spawn.x, 280.0, 360.0)
	assert_between(spawn.y, 100.0, 185.0)
	assert_eq(_component(_ford_pathing, spawn), _component(_ford_pathing, landing), "and walks to the landing")
	# Without crossing the river: the whole route stays on the north bank.
	var path: PackedInt64Array = _ford_pathing.find_path(roundi(spawn.x) * M, roundi(spawn.y) * M, roundi(landing.x) * M, roundi(landing.y) * M, LIVING)
	for k: int in range(0, path.size(), 2):
		assert_lt(path[k + 1] / float(M), 165.0, "the Rippers' flank stays north of the river")
	# The woods are mostly wood and brush, well away from the sand of the bank.
	var in_woods: float = _share(_ford, Rect2i(292, 108, 56, 52), [Terrain.Ground.WOOD, Terrain.Ground.BRUSH])
	var elsewhere: float = _share(_ford, Rect2i(20, 270, 100, 80), [Terrain.Ground.WOOD, Terrain.Ground.BRUSH])
	assert_gt(in_woods, 0.7, "the east woods are wood and brush")
	assert_lt(elsewhere, in_woods - 0.2, "unlike the plain")
	var box: Rect2 = _ford_gen["WOODS_BOX"]
	assert_eq(box, Rect2(280.0, 100.0, 80.0, 85.0))


func test_the_ford_is_further_into_the_blight_than_riverside() -> void:
	var riverside: Terrain = Terrain.load_map(load(RIVERSIDE_MAP) as MapInfo)
	var here: Array[int] = _ground_counts(_ford)
	var there: Array[int] = _ground_counts(riverside)
	var here_total: float = _ford.ground.size()
	var there_total: float = riverside.ground.size()
	for type: int in [Terrain.Ground.SAND, Terrain.Ground.ROCK, Terrain.Ground.BRUSH]:
		assert_gt(here[type] / here_total, there[type] / there_total, "a larger share of ground type %d than Riverside" % type)
	assert_eq(here.find(here.max()), Terrain.Ground.GRASS, "though grass is still the commonest ground")
	for type: int in Terrain.GROUND_COUNT:
		assert_gt(here[type], 1000, "every ground type is on the map")


func test_the_ford_herb_plants_are_two_a_bank_dry_and_by_the_road() -> void:
	var plants: PackedInt32Array = _ford_info.herb_plants
	assert_eq(plants.size(), 8, "four plants, as x, z pairs")
	var south: int = 0
	var north: int = 0
	for k: int in range(0, plants.size(), 2):
		var p: Vector2 = Vector2(plants[k] / 1000.0, plants[k + 1] / 1000.0)
		assert_true(_walkable(_ford, p), "the plant at %s is on walkable ground" % p)
		assert_eq(_level(_ford, p), 0, "and dry")
		assert_lt(_distance_to_line(p, _ford_gen["ROAD"]), 12.0, "near the road")
		if p.y > _river_z(p.x):
			south += 1
		else:
			north += 1
	assert_eq([south, north], [2, 2], "two on each bank")


# ---- Old Mill: the map and the plateau ----

func test_old_mill_loads_at_320_samples_a_side_at_one_meter() -> void:
	assert_not_null(_mill, "Old Mill loads")
	assert_eq([_mill.size_x, _mill.size_z], [320, 320])
	assert_eq(_mill_info.cell_size, 1000)
	assert_eq(_mill_info.max_height, 30000)
	assert_eq(_mill_info.max_walkable_slope, 1000)
	assert_eq(_mill_info.display_name, "Old Mill")


func test_old_mill_plain_is_low_ground_of_three_to_six_meters() -> void:
	var center: Vector2 = _mill_gen["PLATEAU_CENTER"]
	var lowest: float = INF
	var highest: float = -INF
	var counted: int = 0
	for j: int in _mill.size_z:
		for i: int in _mill.size_x:
			# Off the plateau, its cliff, and its ramps, and out of the water.
			if Vector2(i, j).distance_to(center) < 40.0 or _mill.sample_water_depth(i, j) > 0:
				continue
			if _near_a_ramp(Vector2(i, j), 6.0):
				continue
			var h: float = _mill.sample_height(i, j) / 1000.0
			lowest = minf(lowest, h)
			highest = maxf(highest, h)
			counted += 1
	assert_gt(counted, 70000)
	assert_gte(lowest, 2.99)
	assert_lte(highest, 6.01)
	assert_gt(highest - lowest, 1.5, "with some roll to it")


func test_the_plateau_top_is_flat_at_twelve_meters() -> void:
	var center: Vector2 = _mill_gen["PLATEAU_CENTER"]
	var mill: Vector2 = _mill_gen["MILL_CENTER"]
	var size: float = _mill_gen["MILL_SIZE_M"]
	var seen: int = 0
	for j: int in _mill.size_z:
		for i: int in _mill.size_x:
			var p: Vector2 = Vector2(i, j)
			if p.distance_to(center) > 22.0 or absf(p.x - mill.x) < size / 2.0 + 2.0 and absf(p.y - mill.y) < size / 2.0 + 2.0:
				continue
			seen += 1
			assert_eq(_mill.sample_height(i, j), 12000, "the top at (%d, %d) is 12 m" % [i, j])
			assert_true(_mill.is_sample_passable(i, j, LIVING), "and walkable at (%d, %d)" % [i, j])
	assert_gt(seen, 1200, "a good open top beside the mill")
	# Its radius is about 28 m, irregular: it wanders a few meters round the compass.
	var radii: Array[float] = []
	for degrees: int in range(0, 360, 10):
		var angle: float = deg_to_rad(degrees)
		var edge: float = 0.0
		for tenth: int in range(200, 400):
			var p: Vector2 = center + Vector2.from_angle(angle) * (tenth / 10.0)
			if _mill.sample_height(roundi(p.x), roundi(p.y)) < 11500:
				break
			edge = tenth / 10.0
		radii.append(edge)
	assert_between(radii.min(), 22.0, 29.0)
	assert_between(radii.max(), 28.0, 34.0)
	assert_gt(radii.max() - radii.min(), 2.0, "irregular")


func _near_a_ramp(p: Vector2, reach_m: float) -> bool:
	for ramp: Dictionary in _ramp_defs():
		if p.distance_to(Geometry2D.get_closest_point_to_segment(p, ramp["from"], ramp["to"])) <= reach_m:
			return true
	return false


func _ramp_defs() -> Array[Dictionary]:
	var ramps: Array[Dictionary] = []
	for foot: Vector2 in [_mill_gen["NW_RAMP_FOOT"], _mill_gen["SE_RAMP_FOOT"]]:
		ramps.append(_mill_script.ramp(foot))
	return ramps


## A mask shutting every sample within the ramps' strips (width/2 + 1.5 m).
func _shut_ramps() -> PackedByteArray:
	var shut: PackedByteArray = PackedByteArray()
	shut.resize(_mill.size_x * _mill.size_z)
	for ramp: Dictionary in _ramp_defs():
		var from: Vector2 = ramp["from"]
		var to: Vector2 = ramp["to"]
		var reach: float = float(ramp["width_m"]) / 2.0 + 1.5
		for j: int in _mill.size_z:
			for i: int in _mill.size_x:
				if Vector2(i, j).distance_to(Geometry2D.get_closest_point_to_segment(Vector2(i, j), from, to)) <= reach:
					shut[j * _mill.size_x + i] = 1
	return shut


func test_the_plateau_is_reachable_only_through_the_two_ramps() -> void:
	var deploy: Vector2 = _mill_gen["DEPLOY"]
	var from_the_plain: Vector2i = _at(_mill_gen["SPAWN_S"])
	var open: PackedByteArray = _flood(_mill, from_the_plain)
	assert_true(_reached(_mill, open, deploy), "from the plain, the plateau is reachable")
	var shut: PackedByteArray = _shut_ramps()
	var no_ramps: PackedByteArray = _flood(_mill, from_the_plain, shut)
	var top: int = 0
	var center: Vector2 = _mill_gen["PLATEAU_CENTER"]
	for j: int in _mill.size_z:
		for i: int in _mill.size_x:
			if Vector2(i, j).distance_to(center) < 24.0:
				top += no_ramps[j * _mill.size_x + i]
	assert_eq(top, 0, "with both ramps shut, nothing on the plateau is reachable")
	assert_gt(no_ramps.count(1), 40000, "though the plain is, so the flood is not vacuous")
	# And each ramp alone is enough: shut only the other and the top is still reachable.
	for keep: int in 2:
		var one: PackedByteArray = PackedByteArray()
		one.resize(_mill.size_x * _mill.size_z)
		var other: Dictionary = _ramp_defs()[1 - keep]
		var reach: float = float(other["width_m"]) / 2.0 + 1.5
		for j: int in _mill.size_z:
			for i: int in _mill.size_x:
				if Vector2(i, j).distance_to(Geometry2D.get_closest_point_to_segment(Vector2(i, j), other["from"], other["to"])) <= reach:
					one[j * _mill.size_x + i] = 1
		assert_true(_reached(_mill, _flood(_mill, from_the_plain, one), deploy), "ramp %d reaches the top by itself" % keep)


func test_both_ramps_are_walkable_and_gentle() -> void:
	var ramps: Array[Dictionary] = _ramp_defs()
	assert_eq(ramps.size(), 2)
	for ramp: Dictionary in ramps:
		var from: Vector2 = ramp["from"]
		var to: Vector2 = ramp["to"]
		assert_eq(ramp["width_m"], 8.0)
		assert_gt(from.distance_to(to), 20.0, "a long, gentle ramp")
		var length: int = ceili(from.distance_to(to))
		var last_height: float = -1.0
		for step: int in length + 1:
			var p: Vector2 = from.move_toward(to, step)
			var i: int = roundi(p.x)
			var j: int = roundi(p.y)
			assert_true(_mill.is_sample_passable(i, j, LIVING), "ramp from %s walkable at %s" % [from, p])
			assert_lte(_mill.sample_slope(i, j), 400, "slope at %s" % p)
			var h: float = _mill.sample_height(i, j) / 1000.0
			assert_gte(h, last_height - 0.001, "a ramp only climbs, at %s" % p)
			last_height = h
		assert_almost_eq(last_height, 12.0, 0.6, "and it ends at the top")
		# The whole width of the strip is walkable down its middle (8 m wide, with
		# a steep ring of one sample at each edge).
		var across: Vector2 = (to - from).normalized().orthogonal()
		for t: int in range(-2, 3):
			var mid: Vector2 = from.lerp(to, 0.5) + across * t
			assert_true(_walkable(_mill, mid), "the ramp is at least 5 m of walkable ground across, at %s" % mid)


func test_the_cliffs_are_impassable_and_only_the_ramps_climb() -> void:
	# Any walkable sample part-way up (7 to 11 m, the plain being 6 at most and
	# the top 12) near the plateau must lie on a ramp's strip.
	var center: Vector2 = _mill_gen["PLATEAU_CENTER"]
	var ramps: Array[Dictionary] = _ramp_defs()
	var climbing: int = 0
	var cliff: int = 0
	for j: int in _mill.size_z:
		for i: int in _mill.size_x:
			var p: Vector2 = Vector2(i, j)
			if p.distance_to(center) > 45.0:
				continue
			var h: float = _mill.sample_height(i, j) / 1000.0
			if h < 7.0 or h > 11.0:
				continue
			cliff += 1
			if _mill.is_sample_passable(i, j, LIVING):
				climbing += 1
				var on_a_ramp: bool = false
				for ramp: Dictionary in ramps:
					var strip: float = p.distance_to(Geometry2D.get_closest_point_to_segment(p, ramp["from"], ramp["to"]))
					on_a_ramp = on_a_ramp or strip <= float(ramp["width_m"]) / 2.0
				assert_true(on_a_ramp, "walkable ground at height %.1f at %s is not on a ramp" % [h, p])
	assert_gt(cliff, 400, "there is a real cliff band")
	assert_gt(climbing, 20, "and the ramps climb through it")
	# Every cliff sample is rock, and steeper than the limit, all round the rim
	# (except through the ramp strips).
	var bands: int = 0
	for degrees: int in range(0, 360, 5):
		var angle: float = deg_to_rad(degrees)
		var on_ramp: bool = false
		for ramp: Dictionary in ramps:
			var near: Vector2 = center + Vector2.from_angle(angle) * 31.0
			on_ramp = on_ramp or near.distance_to(Geometry2D.get_closest_point_to_segment(near, ramp["from"], ramp["to"])) < 8.0
		if on_ramp:
			continue
		var edge: Vector2 = Vector2.ZERO
		for tenth: int in range(200, 420):
			var p: Vector2 = center + Vector2.from_angle(angle) * (tenth / 10.0)
			if _mill.sample_height(roundi(p.x), roundi(p.y)) < 11500:
				edge = p
				break
		assert_ne(edge, Vector2.ZERO, "the rim at %d degrees" % degrees)
		# The middle of the band, 2 m beyond the top.
		var mid: Vector2 = edge + Vector2.from_angle(angle) * 1.5
		assert_false(_walkable(_mill, mid), "the cliff at %d degrees is not walkable" % degrees)
		assert_eq(_ground(_mill, mid), Terrain.Ground.ROCK, "it is rock")
		bands += 1
	assert_gt(bands, 55)


# ---- Old Mill: the mill, the yard, the water ----

func test_the_mill_is_a_blocked_wood_house_six_meters_tall() -> void:
	var mill: Vector2 = _mill_gen["MILL_CENTER"]
	var size: float = _mill_gen["MILL_SIZE_M"]
	assert_eq(size, 10.0)
	assert_eq(mill, Vector2(166.0, 144.0))
	var covered: int = 0
	for j: int in range(floori(mill.y - size / 2.0), ceili(mill.y + size / 2.0)):
		for i: int in range(floori(mill.x - size / 2.0), ceili(mill.x + size / 2.0)):
			covered += 1
			assert_eq(_mill.blocked[j * _mill.size_x + i], 1, "the mill at (%d, %d) is blocked" % [i, j])
			assert_eq(_mill.sample_ground(i, j), Terrain.Ground.WOOD, "wood")
			assert_eq(_mill.sample_height(i, j), 18000, "6 m over the 12 m top")
	assert_eq(covered, 100)
	assert_eq(_mill.blocked.count(1), 100, "and nothing else on the map is blocked")


func test_the_mill_yard_is_open_walkable_ground_south_of_the_mill() -> void:
	var yard: Vector2 = _mill_gen["YARD_CENTER"]
	var radius: float = _mill_gen["YARD_RADIUS_M"]
	var mill: Vector2 = _mill_gen["MILL_CENTER"]
	assert_eq(radius, 7.0)
	assert_gt(yard.y - radius, mill.y + float(_mill_gen["MILL_SIZE_M"]) / 2.0, "the yard lies wholly south of the mill")
	assert_lt(absf(yard.x - mill.x), 4.0, "right below it")
	var open: int = 0
	for j: int in range(floori(yard.y - radius), ceili(yard.y + radius) + 1):
		for i: int in range(floori(yard.x - radius), ceili(yard.x + radius) + 1):
			if Vector2(i, j).distance_to(yard) > radius:
				continue
			open += 1
			assert_true(_mill.is_sample_passable(i, j, LIVING), "the yard at (%d, %d) is walkable" % [i, j])
			assert_eq(_mill.sample_water_depth(i, j), 0, "and dry")
	assert_gt(open, 140, "a real yard")
	assert_eq(_component(_mill_pathing, yard), _component(_mill_pathing, _mill_gen["DEPLOY"]), "joined to the deploy point")


func test_the_pond_is_deep_in_the_middle_and_clear_of_the_cliff() -> void:
	var pond: Vector2 = _mill_gen["POND_CENTER"]
	var radius: float = _mill_gen["POND_RADIUS_M"]
	assert_eq(radius, 18.0)
	assert_eq(_level(_mill, pond), 3, "depth 3 in the middle")
	assert_false(_walkable(_mill, pond), "which a living unit cannot cross")
	var deepest: int = 0
	var cliff_gap: float = INF
	var center: Vector2 = _mill_gen["PLATEAU_CENTER"]
	for j: int in _mill.size_z:
		for i: int in _mill.size_x:
			var p: Vector2 = Vector2(i, j)
			if p.distance_to(pond) <= radius - 0.5:
				deepest = maxi(deepest, _mill.sample_water_depth(i, j))
				assert_gt(_mill.sample_water_depth(i, j), 0, "the pond is wet at %s" % p)
			# The cliff: rock partway up the plateau.
			if p.distance_to(center) < 45.0 and _mill.sample_ground(i, j) == Terrain.Ground.ROCK and _mill.sample_height(i, j) > 6.5:
				cliff_gap = minf(cliff_gap, p.distance_to(pond) - radius)
	assert_eq(deepest, 3, "no deeper than 3")
	assert_gt(cliff_gap, 10.0, "the pond keeps well away from the cliff")
	# Its depth rises toward the rim: level 2 and 1 rings.
	assert_eq(_level(_mill, pond + Vector2(10.0, 0.0)), 2)
	assert_eq(_level(_mill, pond + Vector2(15.0, 0.0)), 1)
	assert_eq(_level(_mill, pond + Vector2(20.0, 5.0)), 0)
	assert_eq(_ground(_mill, pond + Vector2(20.0, 5.0)), Terrain.Ground.SAND, "sand banks")


func test_the_millstream_can_be_waded_from_edge_to_edge() -> void:
	var line: PackedVector2Array = _mill_gen["STREAM"]
	assert_eq(line[0], Vector2(232.0, 0.0), "it starts at the north edge")
	assert_eq(line[line.size() - 1], Vector2(240.0, 319.0), "and leaves by the south edge")
	var pond: Vector2 = _mill_gen["POND_CENTER"]
	var seen: int = 0
	for k: int in line.size() - 1:
		for step: int in ceili(line[k].distance_to(line[k + 1])) + 1:
			var p: Vector2 = line[k].move_toward(line[k + 1], step)
			if p.distance_to(pond) < 20.0:
				continue
			seen += 1
			var level: int = _level(_mill, p)
			assert_between(level, 1, 2, "the stream at %s is depth 1 or 2" % p)
			assert_true(_walkable(_mill, p), "and can be waded at %s" % p)
			assert_eq(_ground(_mill, p), Terrain.Ground.SAND, "its bed is sand")
	assert_gt(seen, 250)
	# About 6 m of water: 5 or 6 wet samples across it where it runs north-south.
	var wet: int = 0
	for i: int in range(220, 250):
		wet += 1 if _mill.sample_water_depth(i, 20) > 0 else 0
	assert_between(wet, 5, 8, "a stream 6 m wide")
	# Sand banks beyond the water.
	for i: int in range(220, 250):
		if _mill.sample_water_depth(i, 20) > 0 and _mill.sample_water_depth(i + 1, 20) == 0:
			assert_eq(_mill.sample_ground(i + 2, 20), Terrain.Ground.SAND, "sand bank")
			break


# ---- Old Mill: spawns, deploy, ground ----

func test_every_edge_spawn_zone_walks_to_the_plateau() -> void:
	var deploy: Vector2 = _mill_gen["DEPLOY"]
	var home: int = _component(_mill_pathing, deploy)
	assert_ne(home, PathLayer.NO_COMPONENT)
	assert_eq(_mill.sample_height(roundi(deploy.x), roundi(deploy.y)), 12000, "the deploy point is on the plateau top")
	var edges: Dictionary[String, Vector2] = {
		"N": _mill_gen["SPAWN_N"], "W": _mill_gen["SPAWN_W"],
		"S": _mill_gen["SPAWN_S"], "E": _mill_gen["SPAWN_E"],
	}
	assert_eq(edges["N"], Vector2(150.0, 14.0))
	assert_eq(edges["W"], Vector2(14.0, 170.0))
	assert_eq(edges["S"], Vector2(150.0, 306.0))
	assert_eq(edges["E"], Vector2(306.0, 210.0))
	for zone: String in edges:
		var spawn: Vector2 = edges[zone]
		for dj: int in range(-5, 6):
			for di: int in range(-5, 6):
				if Vector2(di, dj).length() <= 5.0:
					assert_true(_walkable(_mill, spawn + Vector2(di, dj)), "the %s spawn zone is walkable at %s" % [zone, spawn + Vector2(di, dj)])
		assert_eq(_component(_mill_pathing, spawn), home, "the %s spawn is in the plateau's component" % zone)
	# The east spawn is across the stream, so the walk wades it.
	var east: Vector2 = edges["E"]
	var path: PackedInt64Array = _mill_pathing.find_path(roundi(east.x) * M, roundi(east.y) * M, roundi(deploy.x) * M, roundi(deploy.y) * M, LIVING)
	var waded: bool = false
	var at: Vector2 = east
	for k: int in range(0, path.size(), 2):
		var to: Vector2 = Vector2(path[k] / float(M), path[k + 1] / float(M))
		for step: int in ceili(at.distance_to(to)):
			waded = waded or _level(_mill, at.move_toward(to, step)) > 0
		at = to
	assert_true(waded, "the east spawn wades the stream to reach the plateau")


func test_the_deploy_point_and_camera() -> void:
	var deploy: Vector2 = _mill_gen["DEPLOY"]
	var camera: Vector2 = _mill_gen["CAMERA_START"]
	assert_eq(deploy, Vector2(156.0, 158.0))
	assert_eq(camera, Vector2(160.0, 205.0))
	assert_true(_walkable(_mill, deploy))
	assert_true(_walkable(_mill, camera))
	# The deploy point is on the top, south-west of the mill, with room for a block.
	var center: Vector2 = _mill_gen["PLATEAU_CENTER"]
	assert_lt(deploy.distance_to(center), 15.0)
	for dj: int in range(-4, 5):
		for di: int in range(-4, 5):
			assert_true(_walkable(_mill, deploy + Vector2(di, dj)), "room to deploy at %s" % (deploy + Vector2(di, dj)))


func test_the_fields_ring_the_plateau_and_the_lanes_break_them() -> void:
	var center: Vector2 = _mill_gen["PLATEAU_CENTER"]
	var inner: float = _mill_gen["FIELD_INNER_M"]
	var outer: float = _mill_gen["FIELD_OUTER_M"]
	var in_ring: int = 0
	var brush_in_ring: int = 0
	var brush_out: int = 0
	var out: int = 0
	for j: int in _mill.size_z:
		for i: int in _mill.size_x:
			var r: float = Vector2(i, j).distance_to(center)
			if _mill.sample_water_depth(i, j) > 0:
				continue
			var is_brush: bool = _mill.sample_ground(i, j) == Terrain.Ground.BRUSH
			if r > inner + 6.0 and r < outer - 6.0:
				in_ring += 1
				brush_in_ring += 1 if is_brush else 0
			elif r > outer + 6.0 or r < inner - 6.0:
				out += 1
				brush_out += 1 if is_brush else 0
	assert_gt(float(brush_in_ring) / in_ring, 0.5, "the ring is mostly wheat")
	assert_gt(out, 50000, "plenty of ground beyond the ring")
	assert_eq(brush_out, 0, "and there is no brush outside it")
	# The lanes: down each bearing, across the ring, is grass.
	for degrees: float in _mill_gen["LANE_BEARINGS_DEG"]:
		for r: int in range(int(inner) + 8, int(outer) - 8, 2):
			var p: Vector2 = center + Vector2.from_angle(deg_to_rad(degrees)) * r
			if _level(_mill, p) == 0:
				assert_ne(_ground(_mill, p), Terrain.Ground.BRUSH, "lane at %d degrees is clear at %s" % [degrees, p])
	var counts: Array[int] = _ground_counts(_mill)
	assert_eq(counts.find(counts.max()), Terrain.Ground.GRASS, "grass is still the commonest ground")
	assert_gt(counts[Terrain.Ground.ROCK], 2000, "scorched rock")
	assert_gt(counts[Terrain.Ground.SAND], 5000, "scorched sand and banks")
	assert_gt(counts[Terrain.Ground.BRUSH], 5000, "wide fields")


func test_the_old_mill_herb_plants_are_two_on_top_and_one_at_each_ramp_foot() -> void:
	var plants: PackedInt32Array = _mill_info.herb_plants
	assert_eq(plants.size(), 8, "four plants, as x, z pairs")
	var on_top: int = 0
	var at_feet: int = 0
	var center: Vector2 = _mill_gen["PLATEAU_CENTER"]
	var feet: Array[Vector2] = [_mill_gen["NW_RAMP_FOOT"], _mill_gen["SE_RAMP_FOOT"]]
	var foot_has_one: Array[bool] = [false, false]
	for k: int in range(0, plants.size(), 2):
		var p: Vector2 = Vector2(plants[k] / 1000.0, plants[k + 1] / 1000.0)
		assert_true(_walkable(_mill, p), "the plant at %s is on walkable ground" % p)
		assert_eq(_level(_mill, p), 0, "and dry")
		if _height_m(_mill, p) > 11.9:
			on_top += 1
			assert_lt(p.distance_to(center), 24.0, "on top, well inside the cliff")
		else:
			for f: int in 2:
				if p.distance_to(feet[f]) < 6.0:
					at_feet += 1
					foot_has_one[f] = true
	assert_eq(on_top, 2, "two on top")
	assert_eq(at_feet, 2, "and two at the ramp feet")
	assert_eq(foot_has_one, [true, true], "one at each")


# ---- regeneration ----

## Runs a generator in a second Godot process, writing into a scratch
## directory, and compares its PNGs byte for byte with the committed ones: the
## committed maps are what the generator writes, and writing them is
## deterministic (every noise has a fixed seed).
func _assert_regenerates(generator: String, map_name: String) -> void:
	var scratch: String = "user://regenerated_%s/" % map_name
	var output: Array = []
	var code: int = OS.execute(
		OS.get_executable_path(),
		["--headless", "--path", ProjectSettings.globalize_path("res://"), "-s", generator, "--", "--out=" + scratch],
		output
	)
	assert_eq(code, 0, "%s runs and writes a map that loads" % generator)
	for file: String in ["height.png", "mask.png"]:
		var fresh: PackedByteArray = FileAccess.get_file_as_bytes(scratch + file)
		var committed: PackedByteArray = FileAccess.get_file_as_bytes("res://maps/%s/%s" % [map_name, file])
		assert_gt(fresh.size(), 5000, "%s was written" % file)
		# assert_true, not assert_eq: a failing assert_eq would print the bytes.
		assert_true(fresh == committed, "%s/%s regenerates byte for byte" % [map_name, file])
	for file: String in DirAccess.get_files_at(scratch):
		DirAccess.remove_absolute(scratch + file)
	DirAccess.remove_absolute(scratch)


func test_regenerating_the_ford_writes_the_committed_bytes() -> void:
	_assert_regenerates(FORD_GENERATOR, "the_ford")


func test_regenerating_old_mill_writes_the_committed_bytes() -> void:
	_assert_regenerates(MILL_GENERATOR, "old_mill")
