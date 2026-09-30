extends GutTest
## The mouse ray must land where the sim says the ground is.


func test_hits_flat_ground_where_the_ray_crosses_it() -> void:
	var picker: TerrainPicker = TerrainPicker.new(TestTerrains.flat(64, 64))
	# From 30 m up at (10, 10), heading +x and down at 45 degrees.
	var hit: Vector3 = picker.pick(Vector3(10.0, 30.0, 10.0), Vector3(1.0, -1.0, 0.0))
	assert_almost_eq(hit.x, 40.0, 0.01)
	assert_almost_eq(hit.y, 0.0, 0.001)
	assert_almost_eq(hit.z, 10.0, 0.001)


func test_hits_a_slope_at_the_sim_height() -> void:
	var terrain: Terrain = TestTerrains.ramp_x(64, 64, 500)
	var picker: TerrainPicker = TerrainPicker.new(terrain)
	var hit: Vector3 = picker.pick(Vector3(20.0, 60.0, 30.0), Vector3(0.0, -1.0, 0.0))
	assert_almost_eq(hit.x, 20.0, 0.001)
	assert_almost_eq(hit.y, 10.0, 0.01, "ground is 0.5 m up per meter of x")
	assert_almost_eq(hit.y, picker.ground_height(hit.x, hit.z), 0.0001)


func test_misses_when_looking_up_or_off_the_map() -> void:
	var picker: TerrainPicker = TerrainPicker.new(TestTerrains.flat(64, 64))
	assert_eq(picker.pick(Vector3(10.0, 30.0, 10.0), Vector3(0.0, 1.0, 0.0)), Vector3.INF)
	assert_eq(picker.pick(Vector3(10.0, 30.0, 10.0), Vector3(-1.0, -0.2, 0.0)), Vector3.INF,
		"leaves the map before reaching the ground")


func test_ray_from_outside_the_map_can_still_hit_it() -> void:
	var picker: TerrainPicker = TerrainPicker.new(TestTerrains.flat(64, 64))
	var hit: Vector3 = picker.pick(Vector3(-20.0, 40.0, 30.0), Vector3(1.0, -1.0, 0.0))
	assert_almost_eq(hit.x, 20.0, 0.01)
