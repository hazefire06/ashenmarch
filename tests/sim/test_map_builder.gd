extends GutTest
## MapBuilder (scripts/mapgen/map_builder.gd), the shared offline map
## generator: each stamp does what its doc says on a small synthetic map, read
## back through the PNG codec and Terrain.from_png the way the game loads a
## map. Then the shipped Riverside village (Phase 8): its houses, its open
## square, its lanes, and that nothing outside its zone moved.

const M: int = 1000
const SIZE: int = 64
const MAX_HEIGHT_M: float = 40.0
const SLOPE_LIMIT: int = 1000
const LIVING: Terrain.Mobility = Terrain.Mobility.LIVING
const GENERATOR_PATH: String = "res://scripts/gen_riverside.gd"
const MAP_PATH: String = "res://maps/riverside/riverside.tres"
## The ground Riverside had before the village (Phase 7): SHA-256 over the
## heights, water, blocked flags, and ground types of every sample outside the
## village's zone (the box its houses stand in, and the corridor of the road
## toward the ford). Taken from the committed Phase 7 PNGs (git show
## 73befd1:maps/riverside/height.png and mask.png). Moving the generator's
## FORD_ROAD changes which samples count as outside, so this needs retaking
## from those PNGs, with the new corridor.
const PHASE_7_OUTSIDE_VILLAGE_HASH: String = "8df9a5635f83b2a10bfe6c56bbc7417529fa628f177712a9abfa3f8a73f444e3"
## The village's box: x 405..485 m, z 335..415 m.
const VILLAGE_BOX: Rect2 = Rect2(405.0, 335.0, 80.0, 80.0)
## Samples within this many meters of the road's centerline are the road's
## (its half-width plus margin).
const ROAD_CORRIDOR_M: float = 3.0
## Where earlier tests pin Riverside (meters): the village keeps 10 m clear.
const PINNED_SPOTS: Array[Vector2] = [
	Vector2(250.0, 275.0), Vector2(250.0, 290.0), Vector2(250.0, 305.0),
	Vector2(340.0, 320.0), Vector2(380.0, 440.0), Vector2(380.0, 404.0),
	Vector2(390.0, 120.0), Vector2(392.0, 122.0), Vector2(392.0, 162.0),
	Vector2(110.0, 160.0), Vector2(150.0, 400.0), Vector2(150.0, 430.0),
	Vector2(442.0, 271.0),
]
## Every point data/missions/riverside_ai.tres puts on the map (spawns,
## waypoints, retreat point, trigger area), in meters.
const MISSION_SPOTS: Array[Vector2] = [
	Vector2(296.0, 248.0), Vector2(330.0, 252.0), Vector2(314.0, 264.0), Vector2(284.0, 222.0),
	Vector2(340.0, 272.0), Vector2(250.0, 275.0), Vector2(250.0, 305.0), Vector2(270.0, 262.0),
	Vector2(246.0, 232.0), Vector2(262.0, 238.0), Vector2(278.0, 242.0), Vector2(300.0, 227.0),
]


## A flat grass map at height_m with no water.
func _flat(height_m: float = 10.0) -> MapBuilder:
	return _sloped(height_m, 0.0)


## Grass ground rising slope m per m along +x, from height_m at x = 0.
func _sloped(height_m: float, slope: float) -> MapBuilder:
	var map: MapBuilder = MapBuilder.new(SIZE, SIZE, M, MAX_HEIGHT_M, SLOPE_LIMIT)
	map.fill(
		func(x: float, _z: float) -> Vector2: return Vector2(height_m + slope * x, 0.0),
		func(_x: float, _z: float, _h: float, _s: float) -> int: return Terrain.Ground.GRASS
	)
	return map


## The map as the game would load it: through the PNG encoder and decoder.
func _load(map: MapBuilder) -> Terrain:
	var t: Terrain = Terrain.from_png(
		PngCodec.encode(map.height_raster()), PngCodec.encode(map.mask_raster()),
		map.cell_size, roundi(map.max_height_m * M), map.max_walkable_slope
	)
	assert_not_null(t, "the PNGs load")
	return t


## A flat map with one house on it.
func _with_house(cx: float, cz: float, w: float, d: float) -> MapBuilder:
	var map: MapBuilder = _flat(10.0)
	map.house(cx, cz, w, d)
	return map


func _walkable(t: Terrain, i: int, j: int) -> bool:
	return t.is_sample_passable(i, j, LIVING)


## True if a LIVING unit can walk from sample a to sample b (4-connected),
## treating the samples in avoid as impassable.
func _connected(t: Terrain, a: Vector2i, b: Vector2i, avoid: Rect2i = Rect2i()) -> bool:
	if not _walkable(t, a.x, a.y) or not _walkable(t, b.x, b.y):
		return false
	var seen: PackedByteArray = PackedByteArray()
	seen.resize(t.size_x * t.size_z)
	var queue: Array[Vector2i] = [a]
	seen[a.y * t.size_x + a.x] = 1
	var head: int = 0
	while head < queue.size():
		var at: Vector2i = queue[head]
		head += 1
		if at == b:
			return true
		for step: Vector2i in [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]:
			var next: Vector2i = at + step
			if next.x < 0 or next.y < 0 or next.x >= t.size_x or next.y >= t.size_z:
				continue
			var k: int = next.y * t.size_x + next.x
			if seen[k] == 0 and not avoid.has_point(next) and _walkable(t, next.x, next.y):
				seen[k] = 1
				queue.append(next)
	return false


# ---- the base fill ----

func test_fill_asks_for_the_slope_once_every_height_is_known() -> void:
	var seen: Dictionary[String, float] = {}
	var map: MapBuilder = MapBuilder.new(SIZE, SIZE, M, MAX_HEIGHT_M, SLOPE_LIMIT)
	map.fill(
		func(x: float, _z: float) -> Vector2: return Vector2(0.5 * x, 0.0),
		func(x: float, z: float, h: float, s: float) -> int:
			if x == 20.0 and z == 5.0:
				seen["h"] = h
				seen["s"] = s
			return Terrain.Ground.GRASS
	)
	assert_eq(seen["h"], 10.0, "the height pass ran first")
	assert_almost_eq(seen["s"], 0.5, 0.0001, "so the slope is known: 0.5 m per m")


func test_water_depth_becomes_a_level_by_the_thresholds() -> void:
	var map: MapBuilder = MapBuilder.new(SIZE, SIZE, M, MAX_HEIGHT_M, SLOPE_LIMIT)
	assert_eq(map.level(0.0), 0)
	assert_eq(map.level(0.05), 1)
	assert_eq(map.level(0.79), 1)
	assert_eq(map.level(0.8), 2)
	assert_eq(map.level(1.35), 3)
	map.level_depths_m = [1.0, 2.0, 3.0] as Array[float]
	assert_eq(map.level(0.9), 0, "a map can set its own thresholds")
	assert_eq(map.level(3.5), 3)


func test_the_rasters_round_trip_through_terrain_from_png() -> void:
	var map: MapBuilder = MapBuilder.new(SIZE, SIZE, M, MAX_HEIGHT_M, SLOPE_LIMIT)
	map.fill(
		func(x: float, z: float) -> Vector2: return Vector2(5.0 + 0.1 * x + 0.05 * z, 0.0 if x < 32.0 else 1.0),
		func(x: float, z: float, _h: float, _s: float) -> int: return int(x + z) % Terrain.GROUND_COUNT
	)
	map.house(16.0, 40.0, 4.0, 4.0)
	var t: Terrain = _load(map)
	assert_eq([t.size_x, t.size_z], [SIZE, SIZE])
	for k: int in SIZE * SIZE:
		assert_lte(absi(t.heights[k] - roundi(map.heights_m[k] * M)), 1, "height %d within a millimeter" % k)
		assert_eq(t.water[k], map.levels[k], "water %d" % k)
		assert_eq(t.ground[k], map.grounds[k], "ground %d" % k)
		assert_eq(t.blocked[k], map.blocked[k], "blocked %d" % k)
	assert_gt(t.blocked.count(1), 0)
	assert_gt(t.water.count(2), 0, "the depth got through")


func test_save_writes_the_map_and_its_keep_importers() -> void:
	var dir: String = "user://map_builder_test/"
	var map: MapBuilder = _flat()
	map.house(30.0, 30.0, 6.0, 6.0)
	var info: MapInfo = map.save(dir, "tiny", "Tiny", PackedInt32Array([5000, 6000]))
	assert_not_null(info)
	assert_eq(info.display_name, "Tiny")
	assert_eq(info.herb_plants, PackedInt32Array([5000, 6000]))
	for file: String in ["height.png.import", "mask.png.import"]:
		assert_eq(FileAccess.get_file_as_string(dir + file), "[remap]\n\nimporter=\"keep\"\n", file)
	var loaded: MapInfo = ResourceLoader.load(dir + "tiny.tres", "", ResourceLoader.CACHE_MODE_IGNORE) as MapInfo
	assert_not_null(loaded, "the .tres loads")
	var t: Terrain = Terrain.load_map(loaded)
	assert_not_null(t, "and names PNGs that load")
	assert_eq(t.blocked.count(1), 36)
	assert_eq(t.max_walkable_slope, SLOPE_LIMIT)
	for file: String in DirAccess.get_files_at(dir):
		DirAccess.remove_absolute(dir + file)
	DirAccess.remove_absolute(dir)


# ---- house ----

func test_a_house_is_raised_blocked_and_wood() -> void:
	var map: MapBuilder = _sloped(10.0, 0.1)
	var raised: int = map.house(30.0, 20.0, 6.0, 4.0)
	assert_eq(raised, 24, "6 by 4 samples")
	var t: Terrain = _load(map)
	# The footprint is x 27..32, z 18..21. The highest ground under it is at
	# x = 32: 10 + 3.2 = 13.2, so the roof is 16.2 m, flat.
	for j: int in range(18, 22):
		for i: int in range(27, 33):
			assert_eq(t.blocked[j * SIZE + i], 1, "(%d, %d) blocked" % [i, j])
			assert_eq(t.sample_ground(i, j), Terrain.Ground.WOOD, "(%d, %d) wood" % [i, j])
			assert_almost_eq(t.sample_height(i, j) / 1000.0, 16.2, 0.002, "(%d, %d) roof" % [i, j])
	assert_eq(t.blocked.count(1), 24, "and nothing else")
	assert_eq(t.sample_ground(26, 20), Terrain.Ground.GRASS, "the ground beside it is untouched")
	assert_almost_eq(t.sample_height(26, 20) / 1000.0, 12.6, 0.002)


func test_a_house_stops_a_shot_because_it_is_in_the_height_field() -> void:
	var t: Terrain = _load(_with_house(32.0, 32.0, 6.0, 6.0))
	assert_almost_eq(t.height_at(32 * M, 32 * M) / 1000.0, 13.0, 0.002, "the roof is 3 m up")
	assert_almost_eq(t.height_at(20 * M, 32 * M) / 1000.0, 10.0, 0.002, "the ground is not")
	assert_false(t.is_passable(32 * M, 32 * M, LIVING))
	assert_false(t.is_passable(32 * M, 32 * M, Terrain.Mobility.FLOATING), "solid even to the Drifter")


func test_the_ring_around_a_house_is_steep_and_the_ground_past_it_is_walkable() -> void:
	var t: Terrain = _load(_with_house(32.0, 32.0, 6.0, 6.0))
	assert_false(_walkable(t, 28, 32), "beside the wall: a 3 m step to its neighbor")
	assert_true(_walkable(t, 26, 32), "two samples out")
	assert_true(_connected(t, Vector2i(5, 5), Vector2i(58, 58)), "you can walk round it")


# ---- wall ----

func _walled(gaps: Array) -> Terrain:
	var map: MapBuilder = _flat(10.0)
	map.wall(PackedVector2Array([Vector2(0.0, 32.0), Vector2(63.0, 32.0)]), 2.0, 3.0, gaps)
	return _load(map)


func test_a_wall_is_raised_blocked_and_rock() -> void:
	var t: Terrain = _walled([])
	for i: int in [5, 30, 60]:
		assert_eq(t.blocked[32 * SIZE + i], 1, "wall at x = %d" % i)
		assert_eq(t.sample_ground(i, 32), Terrain.Ground.ROCK)
		assert_almost_eq(t.sample_height(i, 32) / 1000.0, 13.0, 0.002, "3 m above the ground")
	assert_eq(t.blocked[20 * SIZE + 30], 0, "away from the wall")
	assert_false(_connected(t, Vector2i(30, 10), Vector2i(30, 50)), "a wall with no gate is a wall")


func test_a_wall_follows_the_land() -> void:
	var map: MapBuilder = _sloped(10.0, 0.1)
	map.wall(PackedVector2Array([Vector2(0.0, 32.0), Vector2(63.0, 32.0)]), 2.0, 3.0)
	var t: Terrain = _load(map)
	assert_almost_eq(t.sample_height(10, 32) / 1000.0, 14.0, 0.002)
	assert_almost_eq(t.sample_height(50, 32) / 1000.0, 18.0, 0.002)


func test_a_corner_is_not_raised_twice() -> void:
	var map: MapBuilder = _flat(10.0)
	map.wall(PackedVector2Array([Vector2(10.0, 10.0), Vector2(30.0, 10.0), Vector2(30.0, 30.0)]), 2.0, 3.0)
	var t: Terrain = _load(map)
	assert_almost_eq(t.sample_height(30, 10) / 1000.0, 13.0, 0.002, "the joint is one wall high")


func test_a_gap_in_a_wall_stays_open() -> void:
	var t: Terrain = _walled([Vector2(26.0, 34.0)])
	assert_eq(t.blocked[32 * SIZE + 30], 0, "the gate's middle")
	assert_true(_walkable(t, 30, 32), "walkable")
	assert_eq(t.blocked[32 * SIZE + 20], 1, "the wall on either side")
	assert_eq(t.blocked[32 * SIZE + 40], 1)
	assert_true(_connected(t, Vector2i(30, 10), Vector2i(30, 50)), "and it is the way through")
	assert_true(_connected(t, Vector2i(20, 10), Vector2i(20, 50)), "for a unit that walks along the wall to it")
	var gate: Rect2i = Rect2i(26, 28, 9, 9)
	assert_false(_connected(t, Vector2i(20, 10), Vector2i(20, 50), gate), "the only way: close it and there is none")


func test_gaps_are_measured_along_a_bent_wall() -> void:
	var map: MapBuilder = _flat(10.0)
	# 20 m east, then south: the gap at 30..38 m is on the second leg, z 20..28.
	map.wall(PackedVector2Array([Vector2(10.0, 10.0), Vector2(30.0, 10.0), Vector2(30.0, 50.0)]), 2.0, 3.0, [Vector2(30.0, 38.0)])
	var t: Terrain = _load(map)
	assert_eq(t.blocked[10 * SIZE + 30], 1, "the first leg, and the corner, are solid")
	assert_eq(t.blocked[24 * SIZE + 30], 0, "the gap, 24 m along the second leg")
	assert_eq(t.blocked[40 * SIZE + 30], 1, "past it")


# ---- plateau ----

const PLATEAU_CENTER: Vector2 = Vector2(32.0, 32.0)


## A plateau 6 m above 10 m ground: top at 16 within 10 m of the center, a 2 m
## cliff band, and (optionally) a ramp 14 m long from the east, meeting the top
## at its edge (x = 42).
func _plateau(ramp: bool) -> Terrain:
	var map: MapBuilder = _flat(10.0)
	var ramps: Array = []
	if ramp:
		ramps.append({"from": Vector2(56.0, 32.0), "to": Vector2(42.0, 32.0), "width_m": 5.0})
	map.plateau(PLATEAU_CENTER, 10.0, 16.0, 2.0, ramps)
	return _load(map)


func test_a_plateau_top_is_raised_flat_and_walkable() -> void:
	var t: Terrain = _plateau(false)
	for p: Vector2i in [Vector2i(32, 32), Vector2i(36, 30), Vector2i(26, 38)]:
		assert_almost_eq(t.sample_height(p.x, p.y) / 1000.0, 16.0, 0.002)
		assert_true(_walkable(t, p.x, p.y), "top at %s" % p)
	assert_almost_eq(t.sample_height(5, 5) / 1000.0, 10.0, 0.002, "the ground is the ground")


func test_a_plateau_cliff_is_too_steep_to_walk_and_is_rock() -> void:
	var t: Terrain = _plateau(false)
	# Every direction round the rim: a sample in the band.
	for degrees: int in range(0, 360, 15):
		var at: Vector2 = PLATEAU_CENTER + Vector2.from_angle(deg_to_rad(degrees)) * 11.0
		var i: int = roundi(at.x)
		var j: int = roundi(at.y)
		assert_false(_walkable(t, i, j), "cliff at %d degrees (%d, %d)" % [degrees, i, j])
		assert_gt(t.sample_slope(i, j), SLOPE_LIMIT)
		assert_eq(t.sample_ground(i, j), Terrain.Ground.ROCK)
	assert_false(_connected(t, Vector2i(5, 5), Vector2i(32, 32)), "no way up without a ramp")


func test_a_ramp_is_a_walkable_way_up() -> void:
	var t: Terrain = _plateau(true)
	for x: int in range(42, 57):
		assert_true(_walkable(t, x, 32), "ramp at x = %d" % x)
		assert_lt(t.sample_slope(x, 32), SLOPE_LIMIT / 2, "well under the limit at x = %d" % x)
	assert_almost_eq(t.sample_height(56, 32) / 1000.0, 10.0, 0.002, "foot on the ground")
	assert_true(_connected(t, Vector2i(60, 32), Vector2i(32, 32)), "and it leads to the top")
	assert_false(_walkable(t, 40, 40), "away from the ramp the cliff still holds")
	assert_false(_walkable(t, 49, 30), "the ramp's own edge is steep: its walkable core is narrower than it")
	assert_true(_walkable(t, 49, 31), "and the core starts one sample in")


func test_a_lumpy_plateau_takes_its_radius_from_a_function() -> void:
	var map: MapBuilder = _flat(10.0)
	map.plateau(PLATEAU_CENTER, func(angle: float) -> float: return 8.0 if cos(angle) > 0.0 else 14.0, 16.0, 2.0)
	var t: Terrain = _load(map)
	assert_almost_eq(t.sample_height(38, 32) / 1000.0, 16.0, 0.002, "east: 6 m out, inside 8")
	assert_almost_eq(t.sample_height(44, 32) / 1000.0, 10.0, 0.002, "east: 12 m out, outside 8 + 2")
	assert_almost_eq(t.sample_height(22, 32) / 1000.0, 16.0, 0.002, "west: 10 m out, inside 14")


func test_a_polygon_plateau() -> void:
	var map: MapBuilder = _flat(10.0)
	map.plateau_polygon(
		PackedVector2Array([Vector2(20.0, 20.0), Vector2(44.0, 20.0), Vector2(44.0, 44.0), Vector2(20.0, 44.0)]),
		16.0, 2.0
	)
	var t: Terrain = _load(map)
	assert_almost_eq(t.sample_height(32, 32) / 1000.0, 16.0, 0.002)
	assert_almost_eq(t.sample_height(21, 21) / 1000.0, 16.0, 0.002)
	assert_false(_walkable(t, 45, 32), "the cliff beside the east edge")
	assert_almost_eq(t.sample_height(48, 32) / 1000.0, 10.0, 0.002, "and ground past it")
	assert_almost_eq(t.sample_height(10, 10) / 1000.0, 10.0, 0.002)


# ---- road ----

func test_a_road_is_sand_and_changes_nothing_else() -> void:
	var map: MapBuilder = _sloped(10.0, 0.1)
	map.road(PackedVector2Array([Vector2(4.0, 10.0), Vector2(60.0, 10.0)]), 3.0)
	var t: Terrain = _load(map)
	for i: int in [4, 30, 60]:
		for j: int in [9, 10, 11]:
			assert_eq(t.sample_ground(i, j), Terrain.Ground.SAND, "(%d, %d)" % [i, j])
	assert_eq(t.sample_ground(30, 8), Terrain.Ground.GRASS, "beside it")
	assert_eq(t.sample_ground(30, 12), Terrain.Ground.GRASS)
	assert_eq(t.ground.count(Terrain.Ground.SAND), 3 * 57 + 6, "3 samples wide from 4 to 60, plus a round cap at each end")
	assert_almost_eq(t.sample_height(30, 10) / 1000.0, 13.0, 0.002, "heights are left alone")
	assert_true(_walkable(t, 30, 10))


func test_a_road_does_not_paint_over_a_house() -> void:
	var map: MapBuilder = _flat(10.0)
	map.house(30.0, 10.0, 6.0, 6.0)
	map.road(PackedVector2Array([Vector2(4.0, 10.0), Vector2(60.0, 10.0)]), 3.0)
	var t: Terrain = _load(map)
	assert_eq(t.sample_ground(30, 10), Terrain.Ground.WOOD)
	assert_eq(t.sample_ground(20, 10), Terrain.Ground.SAND)


# ---- patches ----

func test_a_patch_takes_a_ground_type_only_where_its_noise_is_high_and_it_is_free() -> void:
	var map: MapBuilder = _flat(10.0)
	map.house(30.0, 30.0, 4.0, 4.0)
	var noise: FastNoiseLite = MapBuilder.patches(7, 1.0 / 10.0)
	map.patch(Vector2(30.0, 30.0), 12.0, noise, -2.0, Terrain.Ground.BRUSH)
	var t: Terrain = _load(map)
	assert_eq(t.sample_ground(40, 30), Terrain.Ground.BRUSH, "everywhere in reach when the threshold is low")
	assert_eq(t.sample_ground(30, 30), Terrain.Ground.WOOD, "but not over the house")
	assert_eq(t.sample_ground(50, 30), Terrain.Ground.GRASS, "nor out of reach")
	map.patch(Vector2(10.0, 10.0), 5.0, noise, 2.0, Terrain.Ground.WOOD)
	assert_eq(_load(map).sample_ground(10, 10), Terrain.Ground.GRASS, "a threshold above the noise takes nothing")


# ---- the Riverside village (Phase 8) ----

var _riverside: Terrain
var _pathing: Pathing
var _generator: Dictionary


func _load_riverside() -> void:
	if _riverside != null:
		return
	_riverside = Terrain.load_map(load(MAP_PATH) as MapInfo)
	_pathing = Pathing.new(_riverside)
	_generator = (load(GENERATOR_PATH) as GDScript).get_script_constant_map()


## The generator's house rows: (center x, center z, width, depth) in meters.
func _houses() -> Array[Vector4]:
	_load_riverside()
	var houses: Array[Vector4] = []
	houses.assign(_generator["VILLAGE_HOUSES"])
	return houses


## The samples a house covers, by MapBuilder.house()'s documented rule: those
## whose position lies in [center - size / 2, center + size / 2).
func _footprint(h: Vector4) -> Rect2i:
	var i0: int = ceili(h.x - h.z / 2.0)
	var j0: int = ceili(h.y - h.w / 2.0)
	return Rect2i(i0, j0, ceili(h.x + h.z / 2.0) - i0, ceili(h.y + h.w / 2.0) - j0)


## Meters from sample (i, j) to the nearest point of a footprint.
func _gap_to(rect: Rect2i, i: int, j: int) -> float:
	var dx: float = maxf(maxf(rect.position.x - i, i - (rect.end.x - 1)), 0.0)
	var dz: float = maxf(maxf(rect.position.y - j, j - (rect.end.y - 1)), 0.0)
	return Vector2(dx, dz).length()


func test_the_village_has_seven_to_nine_houses_of_five_to_eight_meters() -> void:
	var houses: Array[Vector4] = _houses()
	assert_between(houses.size(), 7, 9)
	for h: Vector4 in houses:
		assert_between(h.z, 5.0, 8.0, "width of the house at (%d, %d)" % [h.x, h.y])
		assert_between(h.w, 5.0, 8.0, "depth")
		assert_true(VILLAGE_BOX.encloses(Rect2(h.x - h.z / 2.0, h.y - h.w / 2.0, h.z, h.w)), "inside the box")
	assert_eq(_generator["VILLAGE_HOUSE_HEIGHT_M"], 3.0)


func test_every_house_is_blocked_wood_and_three_meters_tall() -> void:
	var covered: int = 0
	for h: Vector4 in _houses():
		var rect: Rect2i = _footprint(h)
		assert_gte(rect.size.x, 5, "house at (%d, %d)" % [h.x, h.y])
		assert_gte(rect.size.y, 5)
		var roof: float = _riverside.sample_height(rect.position.x, rect.position.y) / 1000.0
		for j: int in range(rect.position.y, rect.end.y):
			for i: int in range(rect.position.x, rect.end.x):
				covered += 1
				assert_eq(_riverside.blocked[j * _riverside.size_x + i], 1, "house at (%d, %d): (%d, %d) blocked" % [h.x, h.y, i, j])
				assert_eq(_riverside.sample_ground(i, j), Terrain.Ground.WOOD, "wood at (%d, %d)" % [i, j])
				assert_almost_eq(_riverside.sample_height(i, j) / 1000.0, roof, 0.002, "flat roof at (%d, %d)" % [i, j])
		# The ground two samples out all round is open. The roof is 3 m over
		# the highest ground under the house, so it stands 3 m over the highest
		# ground round it, less what the slope climbs in the sample between,
		# and higher over the low side.
		var highest: float = -INF
		var lowest: float = INF
		for j: int in range(rect.position.y - 2, rect.end.y + 2):
			for i: int in range(rect.position.x - 2, rect.end.x + 2):
				if rect.grow(2).has_point(Vector2i(i, j)) and not rect.grow(1).has_point(Vector2i(i, j)):
					assert_eq(_riverside.blocked[j * _riverside.size_x + i], 0, "open ground beside the house at (%d, %d)" % [h.x, h.y])
					var ground: float = _riverside.sample_height(i, j) / 1000.0
					highest = maxf(highest, ground)
					lowest = minf(lowest, ground)
		assert_between(roof - highest, 2.0, 3.5, "the house at (%d, %d) stands 3 m over its high side" % [h.x, h.y])
		assert_lt(roof - lowest, 7.0, "and not absurdly over its low side")
	assert_eq(_riverside.blocked.count(1), covered, "and nothing else on the map is blocked")


func test_no_house_is_within_25_meters_of_water() -> void:
	for h: Vector4 in _houses():
		var rect: Rect2i = _footprint(h)
		var near: Rect2i = rect.grow(26).intersection(Rect2i(0, 0, _riverside.size_x, _riverside.size_z))
		var nearest: float = INF
		for j: int in range(near.position.y, near.end.y):
			for i: int in range(near.position.x, near.end.x):
				if _riverside.sample_water_depth(i, j) > 0:
					nearest = minf(nearest, _gap_to(rect, i, j))
		assert_gte(nearest, 25.0, "house at (%d, %d): water is %.1f m away" % [h.x, h.y, nearest])


func test_the_square_is_open_and_walkable() -> void:
	_load_riverside()
	var center: Vector2 = _generator["VILLAGE_SQUARE"]
	var radius: float = _generator["VILLAGE_SQUARE_RADIUS_M"]
	assert_gte(radius, 12.0)
	assert_lt(center.distance_to(Vector2(445.0, 375.0)), 5.0, "near (445, 375)")
	var open: int = 0
	for j: int in range(floori(center.y - radius), ceili(center.y + radius) + 1):
		for i: int in range(floori(center.x - radius), ceili(center.x + radius) + 1):
			if Vector2(i, j).distance_to(center) > radius:
				continue
			open += 1
			assert_true(_walkable(_riverside, i, j), "(%d, %d) is walkable" % [i, j])
			assert_eq(_riverside.sample_water_depth(i, j), 0, "and dry")
	assert_gt(open, 500, "a real square")


func test_the_square_joins_the_north_bank_through_the_ford() -> void:
	_load_riverside()
	var center: Vector2 = _generator["VILLAGE_SQUARE"]
	var target: Vector2i = Vector2i(roundi(center.x * M), roundi(center.y * M))
	var deploy: int = _pathing.component_at(290 * M, 180 * M, LIVING)
	assert_ne(deploy, PathLayer.NO_COMPONENT, "the north bank deploy point is walkable")
	assert_eq(_pathing.component_at(target.x, target.y, LIVING), deploy, "same LIVING component as the square")
	var path: PackedInt64Array = _pathing.find_path(290 * M, 180 * M, target.x, target.y, LIVING)
	assert_eq([path[path.size() - 2], path[path.size() - 1]], [target.x, target.y], "and a path reaches it")
	# Walk the path a meter at a time: it is wet only at the ford.
	var at: Vector2 = Vector2(290.0, 180.0)
	var wet: int = 0
	var wet_away_from_the_ford: int = 0
	for k: int in range(0, path.size(), 2):
		var to: Vector2 = Vector2(path[k] / float(M), path[k + 1] / float(M))
		for step: int in ceili(at.distance_to(to)):
			var p: Vector2 = at.move_toward(to, step)
			if _riverside.water_depth_at(roundi(p.x) * M, roundi(p.y) * M) > 0:
				wet += 1
				wet_away_from_the_ford += 1 if absf(p.x - 300.0) > 12.0 else 0
		at = to
	assert_gt(wet, 0, "the path wades")
	assert_eq(wet_away_from_the_ford, 0, "only at the ford")


func test_each_house_can_be_reached_on_foot() -> void:
	_load_riverside()
	var center: Vector2 = _generator["VILLAGE_SQUARE"]
	var home: int = _pathing.component_at(roundi(center.x * M), roundi(center.y * M), LIVING)
	for h: Vector4 in _houses():
		var rect: Rect2i = _footprint(h)
		var reachable: bool = false
		for j: int in range(rect.position.y - 3, rect.end.y + 3):
			for i: int in range(rect.position.x - 3, rect.end.x + 3):
				if _gap_to(rect, i, j) < 4.0 and _pathing.component_at(i * M, j * M, LIVING) == home:
					reachable = true
		assert_true(reachable, "a walkable way to the house at (%d, %d)" % [h.x, h.y])


func test_the_lanes_are_open_sand() -> void:
	_load_riverside()
	var lanes: Array = _generator["VILLAGE_LANES"]
	assert_gte(lanes.size(), 4)
	for lane: PackedVector2Array in lanes:
		for k: int in lane.size() - 1:
			for step: int in ceili(lane[k].distance_to(lane[k + 1])) + 1:
				var p: Vector2 = lane[k].move_toward(lane[k + 1], step)
				var i: int = roundi(p.x)
				var j: int = roundi(p.y)
				assert_eq(_riverside.sample_ground(i, j), Terrain.Ground.SAND, "lane at %s is sand" % p)
				assert_true(_walkable(_riverside, i, j), "and open at %s" % p)


func test_the_plaza_is_sand_at_the_squares_heart() -> void:
	_load_riverside()
	var center: Vector2 = _generator["VILLAGE_SQUARE"]
	var radius: float = _generator["VILLAGE_PLAZA_RADIUS_M"]
	assert_lt(radius, _generator["VILLAGE_SQUARE_RADIUS_M"])
	for angle: int in range(0, 360, 20):
		var p: Vector2 = center + Vector2.from_angle(deg_to_rad(angle)) * (radius - 1.0)
		assert_eq(_riverside.sample_ground(roundi(p.x), roundi(p.y)), Terrain.Ground.SAND, "plaza at %d degrees" % angle)


func test_the_road_runs_from_the_village_back_toward_the_ford() -> void:
	_load_riverside()
	var road: PackedVector2Array = _generator["FORD_ROAD"]
	var lanes: Array = _generator["VILLAGE_LANES"]
	var main: PackedVector2Array = lanes[0]
	assert_lt(road[road.size() - 1].distance_to(main[0]), 1.0, "it ends where the main lane starts")
	assert_lt(road[0].x, 360.0, "and heads back toward the ford (x = 300)")
	for k: int in road.size() - 1:
		for step: int in ceili(road[k].distance_to(road[k + 1])) + 1:
			var p: Vector2 = road[k].move_toward(road[k + 1], step)
			assert_eq(_riverside.sample_ground(roundi(p.x), roundi(p.y)), Terrain.Ground.SAND, "road at %s" % p)
			assert_eq(_riverside.sample_water_depth(roundi(p.x), roundi(p.y)), 0, "dry")


## Meters from p to the village's zone: its box, or the road's corridor.
func _distance_to_zone(p: Vector2) -> float:
	var gap: Vector2 = Vector2(
		maxf(maxf(VILLAGE_BOX.position.x - p.x, p.x - VILLAGE_BOX.end.x), 0.0),
		maxf(maxf(VILLAGE_BOX.position.y - p.y, p.y - VILLAGE_BOX.end.y), 0.0)
	)
	var nearest: float = gap.length()
	var road: PackedVector2Array = _generator["FORD_ROAD"]
	for k: int in road.size() - 1:
		var closest: Vector2 = Geometry2D.get_closest_point_to_segment(p, road[k], road[k + 1])
		nearest = minf(nearest, p.distance_to(closest))
	return nearest


func test_nothing_outside_the_village_zone_changed() -> void:
	_load_riverside()
	var ctx: HashingContext = HashingContext.new()
	ctx.start(HashingContext.HASH_SHA256)
	var kept: int = 0
	for j: int in _riverside.size_z:
		for i: int in _riverside.size_x:
			if _distance_to_zone(Vector2(i, j)) <= ROAD_CORRIDOR_M:
				continue
			var k: int = j * _riverside.size_x + i
			ctx.update(PackedInt32Array([_riverside.heights[k]]).to_byte_array())
			ctx.update(PackedByteArray([_riverside.water[k], _riverside.blocked[k], _riverside.ground[k]]))
			kept += 1
	gut.p("%d samples outside the village zone" % kept)
	assert_gt(kept, 250000, "the zone is a small part of the map")
	assert_eq(ctx.finish().hex_encode(), PHASE_7_OUTSIDE_VILLAGE_HASH, "the creek, the ford, and the rest are as Phase 7 left them")


func test_the_village_keeps_ten_meters_from_the_pinned_and_mission_spots() -> void:
	_load_riverside()
	for spot: Vector2 in PINNED_SPOTS + MISSION_SPOTS:
		assert_gte(_distance_to_zone(spot), 10.0, "spot %s" % spot)


func test_the_road_changes_ground_only() -> void:
	_load_riverside()
	# Heights, water, and blocked samples differ from Phase 7 only inside the
	# box: the hash above covers the rest, and the road cannot move any of them.
	var road: PackedVector2Array = _generator["FORD_ROAD"]
	for k: int in road.size() - 1:
		var mid: Vector2 = road[k].lerp(road[k + 1], 0.5)
		if VILLAGE_BOX.has_point(mid):
			continue
		assert_true(_walkable(_riverside, roundi(mid.x), roundi(mid.y)), "road at %s is plain walkable ground" % mid)
		assert_eq(_riverside.blocked[roundi(mid.y) * _riverside.size_x + roundi(mid.x)], 0)
