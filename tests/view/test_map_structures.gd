extends GutTest
## The structures and water surface the map generators record beside each map
## for the view (structures.tres, water.png): they agree with what the sim
## reads from the same map.

const MAPS: Array[String] = [
	"res://maps/riverside/riverside.tres",
	"res://maps/the_ford/the_ford.tres",
	"res://maps/old_mill/old_mill.tres",
]


func _info(path: String) -> MapInfo:
	return load(path) as MapInfo


func test_riverside_records_its_eight_houses() -> void:
	var info: MapInfo = _info(MAPS[0])
	var structures: MapStructures = MapStructures.load_beside(info.heightmap_path)
	assert_not_null(structures)
	var houses: int = 0
	for record: StructureRecord in structures.records:
		if record.kind == &"house":
			houses += 1
			assert_ne(record.facing, Vector2i.ZERO, "faces the square")
	assert_eq(houses, 8)
	assert_eq(structures.records.size(), 8)


func test_record_samples_are_exactly_the_blocked_samples() -> void:
	for path: String in MAPS:
		var info: MapInfo = _info(path)
		var terrain: Terrain = Terrain.load_map(info)
		var structures: MapStructures = MapStructures.load_beside(info.heightmap_path)
		var covered: Dictionary[int, bool] = {}
		for record: StructureRecord in structures.records:
			for k: int in record.samples:
				covered[k] = true
		for k: int in terrain.blocked.size():
			assert_eq(covered.has(k), terrain.blocked[k] == 1, "%s sample %d" % [path, k])


func test_old_mill_has_the_mill() -> void:
	var info: MapInfo = _info(MAPS[2])
	var structures: MapStructures = MapStructures.load_beside(info.heightmap_path)
	var mills: Array[StructureRecord] = []
	for record: StructureRecord in structures.records:
		if record.model == &"mill":
			mills.append(record)
	assert_eq(mills.size(), 1)
	assert_eq(mills[0].size_m, Vector2(10, 10))
	assert_eq(mills[0].height_m, 6.0)
	assert_eq(mills[0].facing, Vector2i(0, 1), "faces south")


func test_view_heights_put_a_house_on_its_base() -> void:
	for path: String in MAPS:
		var info: MapInfo = _info(path)
		var terrain: Terrain = Terrain.load_map(info)
		var structures: MapStructures = MapStructures.load_beside(info.heightmap_path)
		var view: Dictionary[int, int] = structures.view_heights(terrain)
		var seen: int = 0
		for record: StructureRecord in structures.records:
			for k: int in record.samples:
				seen += 1
				if record.kind == &"house":
					assert_eq(view[k], roundi(record.base_m * 1000.0))
				else:
					assert_eq(view[k], terrain.heights[k] - roundi(record.height_m * 1000.0))
		assert_gt(seen, 0, path)


func test_the_ford_has_a_wall_and_houses_facing_the_road() -> void:
	var info: MapInfo = _info(MAPS[1])
	var structures: MapStructures = MapStructures.load_beside(info.heightmap_path)
	var walls: int = 0
	for record: StructureRecord in structures.records:
		if record.kind == &"wall":
			walls += 1
			assert_gt(record.points_m.size(), 2)
			assert_eq(record.gaps_m.size(), 1)
		else:
			assert_ne(record.facing, Vector2i.ZERO)
	assert_eq(walls, 1)


func test_water_map_is_wet_exactly_where_the_sim_has_water() -> void:
	for path: String in MAPS:
		var info: MapInfo = _info(path)
		var terrain: Terrain = Terrain.load_map(info)
		var water: PackedFloat32Array = WaterMap.load_beside(info.heightmap_path, terrain, info.max_height)
		assert_eq(water.size(), terrain.heights.size(), path)
		var wet: int = 0
		for j: int in terrain.size_z:
			for i: int in terrain.size_x:
				var k: int = j * terrain.size_x + i
				assert_eq(water[k] > 0.0, terrain.sample_water_depth(i, j) >= 1, "%s (%d, %d)" % [path, i, j])
				if water[k] > 0.0:
					wet += 1
					assert_gte(water[k], terrain.heights[k] / 1000.0, "%s (%d, %d)" % [path, i, j])
		assert_gt(wet, 0, path)


func test_a_terrain_without_world_files_loads_none() -> void:
	var path: String = "res://tests/fixtures/png/height.png"
	assert_null(MapStructures.load_beside(path))
	var terrain: Terrain = TestTerrains.flat(4, 4)
	assert_true(WaterMap.load_beside(path, terrain, 1000).is_empty())
