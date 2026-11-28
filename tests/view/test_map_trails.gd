extends GutTest
## The worn trails the map generators record beside each map for the view
## (trails.tres, A5): MapBuilder.trail() records a route without touching the
## sim's ground, save() writes it, and each campaign map's routes go where
## its people walk.

const M: int = 1000
const MAPS: Array[String] = [
	"res://maps/riverside/riverside.tres",
	"res://maps/the_ford/the_ford.tres",
	"res://maps/old_mill/old_mill.tres",
]


func _trails(index: int) -> MapTrails:
	var info: MapInfo = load(MAPS[index]) as MapInfo
	return MapTrails.load_beside(info.heightmap_path)


## A flat 64 m grass map.
func _flat() -> MapBuilder:
	var map: MapBuilder = MapBuilder.new(64, 64, M, 40.0, 1000)
	map.fill(
		func(_x: float, _z: float) -> Vector2: return Vector2(10.0, 0.0),
		func(_x: float, _z: float, _h: float, _s: float) -> int: return Terrain.Ground.GRASS
	)
	return map


func _remove(dir: String) -> void:
	for file: String in DirAccess.get_files_at(dir):
		DirAccess.remove_absolute(dir + file)
	DirAccess.remove_absolute(dir)


## Distance from p to the nearest point of any trail's centre line.
func _nearest(trails: MapTrails, p: Vector2) -> float:
	var best: float = INF
	for record: TrailRecord in trails.records:
		if record.points_m.size() == 1:
			best = minf(best, p.distance_to(record.points_m[0]))
		for s: int in record.points_m.size() - 1:
			var on: Vector2 = Geometry2D.get_closest_point_to_segment(p, record.points_m[s], record.points_m[s + 1])
			best = minf(best, p.distance_to(on))
	return best


func test_a_trail_is_recorded_with_its_width_and_saved_beside_the_map() -> void:
	var dir: String = "user://map_trails_test/"
	var map: MapBuilder = _flat()
	var route: PackedVector2Array = PackedVector2Array([Vector2(5, 5), Vector2(30, 20), Vector2(55, 50)])
	map.trail(route, 3.5)
	map.trail(PackedVector2Array([Vector2(20, 40)]), 8.0, false)
	assert_not_null(map.save(dir, "tiny", "Tiny"))
	var info: MapInfo = ResourceLoader.load(dir + "tiny.tres", "", ResourceLoader.CACHE_MODE_IGNORE) as MapInfo
	var trails: MapTrails = MapTrails.load_beside(info.heightmap_path)
	assert_not_null(trails, "trails.tres is written beside height.png")
	assert_eq(trails.records.size(), 2)
	assert_eq(trails.records[0].points_m, route)
	assert_eq(trails.records[0].width_m, 3.5)
	assert_true(trails.records[0].fade_ends, "a route fades out at its ends by default")
	assert_false(trails.records[1].fade_ends, "a worn yard does not")
	_remove(dir)


func test_a_trail_leaves_the_sim_files_byte_identical() -> void:
	var plain_dir: String = "user://map_trails_plain/"
	var trail_dir: String = "user://map_trails_with/"
	var plain: MapBuilder = _flat()
	plain.house(40.0, 40.0, 6.0, 6.0)
	var with_trail: MapBuilder = _flat()
	with_trail.house(40.0, 40.0, 6.0, 6.0)
	with_trail.trail(PackedVector2Array([Vector2(2, 2), Vector2(60, 60)]), 4.0)
	assert_not_null(plain.save(plain_dir, "tiny", "Tiny"))
	assert_not_null(with_trail.save(trail_dir, "tiny", "Tiny"))
	for file: String in ["height.png", "mask.png", "water.png"]:
		var a: PackedByteArray = FileAccess.get_file_as_bytes(plain_dir + file)
		var b: PackedByteArray = FileAccess.get_file_as_bytes(trail_dir + file)
		assert_gt(a.size(), 0, file)
		assert_true(a == b, "%s is the same with a trail" % file)
	_remove(plain_dir)
	_remove(trail_dir)


func test_a_map_without_trails_loads_none() -> void:
	assert_null(MapTrails.load_beside("res://tests/fixtures/png/height.png"))


func test_every_campaign_map_records_trails() -> void:
	for index: int in MAPS.size():
		var trails: MapTrails = _trails(index)
		assert_not_null(trails, MAPS[index])
		assert_gte(trails.records.size(), 3, MAPS[index])
		for record: TrailRecord in trails.records:
			assert_gt(record.width_m, 0.0)
			assert_gt(record.points_m.size(), 0)


func test_no_trail_runs_through_a_structure() -> void:
	# Its whole worn width keeps off every blocked sample: each half metre
	# along a route, at its centre and both edges; across a disc, its centre
	# and a ring at its radius.
	for index: int in MAPS.size():
		var info: MapInfo = load(MAPS[index]) as MapInfo
		var terrain: Terrain = Terrain.load_map(info)
		for record: TrailRecord in _trails(index).records:
			var half: float = record.width_m / 2.0
			var spots: PackedVector2Array = PackedVector2Array()
			if record.points_m.size() == 1:
				var centre: Vector2 = record.points_m[0]
				spots.append(centre)
				for step: int in 32:
					spots.append(centre + Vector2.from_angle(TAU * step / 32.0) * half)
			for s: int in record.points_m.size() - 1:
				var a: Vector2 = record.points_m[s]
				var b: Vector2 = record.points_m[s + 1]
				var across: Vector2 = (b - a).normalized().orthogonal() * half
				var steps: int = ceili(a.distance_to(b) * 2.0)
				for n: int in steps + 1:
					var p: Vector2 = a.lerp(b, float(n) / maxf(steps, 1))
					spots.append_array(PackedVector2Array([p, p + across, p - across]))
			for p: Vector2 in spots:
				var i: int = clampi(roundi(p.x), 0, terrain.size_x - 1)
				var j: int = clampi(roundi(p.y), 0, terrain.size_z - 1)
				assert_eq(terrain.blocked[j * terrain.size_x + i], 0, "%s %s" % [MAPS[index], p])


func test_riverside_walks_from_the_squad_through_the_ford_to_the_square() -> void:
	var trails: MapTrails = _trails(0)
	var mission: MissionDef = load("res://data/missions/riverside/mission.tres") as MissionDef
	var deploy: Vector2 = Vector2(mission.deploy[0], mission.deploy[1]) / M
	assert_lt(_nearest(trails, deploy), 6.0, "from the squad's start")
	assert_lt(_nearest(trails, Vector2(300.0, 226.0)), 2.0, "through the ford")
	assert_lt(_nearest(trails, Vector2(445.0, 375.0)), 1.0, "to the village square")
	# Between the houses: a path toward each of the eight.
	var houses: Array[Vector2] = []
	for record: StructureRecord in MapStructures.load_beside((load(MAPS[0]) as MapInfo).heightmap_path).records:
		houses.append(record.center_m)
	for house: Vector2 in houses:
		assert_lt(_nearest(trails, house), 9.0, "a path reaches the house at %s" % house)


func test_the_ford_walks_the_escort_route_through_the_gate() -> void:
	var trails: MapTrails = _trails(1)
	for point: Vector2 in [
		Vector2(192.0, 300.0), Vector2(192.0, 226.0), Vector2(192.0, 186.0), Vector2(192.0, 160.0),
		Vector2(222.0, 104.0), Vector2(236.5, 83.6), Vector2(255.0, 60.0),
	]:
		assert_lt(_nearest(trails, point), 2.0, "the route passes %s" % point)


func test_old_mill_climbs_both_ramps_and_comes_in_from_every_spawn() -> void:
	var trails: MapTrails = _trails(2)
	for point: Vector2 in [Vector2(122.0, 108.0), Vector2(198.0, 192.0), Vector2(166.0, 157.0)]:
		assert_lt(_nearest(trails, point), 3.0, "the way up passes %s" % point)
	for spawn: Vector2 in [Vector2(150.0, 14.0), Vector2(14.0, 170.0), Vector2(150.0, 306.0), Vector2(306.0, 210.0)]:
		assert_lt(_nearest(trails, spawn), 8.0, "a wave's approach starts near %s" % spawn)
