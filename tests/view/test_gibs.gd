extends GutTest
## Gibs: which kills burst a body (overkill of at least a quarter of max hp),
## and that the burst behaves: 5-7 chunks, at most MAX_LIVE_CHUNKS simulating
## with the oldest frozen first, and chunks that land on the terrain height
## they were dropped over (which checks the ground collider's offset and axes),
## never leave the map, and never end under the ground.


func test_should_gib_at_a_quarter_of_max_hp() -> void:
	assert_eq(Gibs.GIB_OVERKILL_PERMILLE, 250)
	assert_false(Gibs.should_gib(24, 100), "just below 25%")
	assert_true(Gibs.should_gib(25, 100), "exactly 25%")
	assert_true(Gibs.should_gib(26, 100), "just above 25%")
	assert_true(Gibs.should_gib(500, 100), "far above")


func test_should_gib_scales_with_max_hp() -> void:
	assert_false(Gibs.should_gib(22, 90), "22 / 90 is 24.4%")
	assert_true(Gibs.should_gib(23, 90), "23 / 90 is 25.6%")
	assert_false(Gibs.should_gib(249, 1000))
	assert_true(Gibs.should_gib(250, 1000))


func test_no_overkill_never_gibs() -> void:
	assert_false(Gibs.should_gib(0, 100))
	assert_false(Gibs.should_gib(-5, 100))
	assert_false(Gibs.should_gib(0, 0), "zero overkill never gibs, even at zero max hp")
	assert_false(Gibs.should_gib(-1, 0))


func test_a_burst_is_five_to_seven_chunks() -> void:
	var gibs: Gibs = _gibs_over(TestTerrains.flat(8, 8))
	for burst: int in 20:
		var before: int = _chunks(gibs).size()
		gibs.spawn(Vector3(4.0, 30.0, 4.0), Vector3(1.0, 0.0, 0.0), Color.RED)
		var made: int = _chunks(gibs).size() - before
		assert_between(made, Gibs.MIN_CHUNKS, Gibs.MAX_CHUNKS, "burst %d" % burst)


func test_chunks_use_their_own_layers() -> void:
	var gibs: Gibs = _gibs_over(TestTerrains.flat(8, 8))
	gibs.spawn(Vector3(4.0, 30.0, 4.0), Vector3.ZERO, Color.RED)
	for chunk: RigidBody3D in _chunks(gibs):
		assert_eq(chunk.collision_layer, Gibs.GIB_LAYER)
		assert_eq(chunk.collision_mask, Gibs.GROUND_LAYER | Gibs.GIB_LAYER, "the ground and other gibs only")
	var ground: StaticBody3D = gibs.get_node("Ground") as StaticBody3D
	assert_eq(ground.collision_layer, Gibs.GROUND_LAYER)
	assert_eq(ground.collision_mask, 0, "the ground collides with nothing itself")


func test_live_chunks_are_capped_and_the_oldest_freeze_first() -> void:
	var gibs: Gibs = _gibs_over(TestTerrains.flat(8, 8))
	# High enough that nothing lands, so only the cap can freeze a chunk.
	for burst: int in 40:
		gibs.spawn(Vector3(4.0, 400.0, 4.0), Vector3.ZERO, Color.RED)
	var chunks: Array[RigidBody3D] = _chunks(gibs)
	assert_gt(chunks.size(), Gibs.MAX_LIVE_CHUNKS, "enough chunks to overflow")
	assert_eq(gibs.live_chunk_count(), Gibs.MAX_LIVE_CHUNKS)
	assert_true(chunks[0].freeze, "the oldest is frozen")
	assert_eq(chunks[0].freeze_mode, RigidBody3D.FREEZE_MODE_STATIC)
	assert_false(chunks[chunks.size() - 1].freeze, "the newest still simulates")


func test_chunks_land_on_the_ground_under_them_and_stay() -> void:
	# Four 8 m quadrants at different heights, so a swapped axis or a wrong
	# offset lands chunks on the wrong plateau.
	var gibs: Gibs = _gibs_over(_quadrant_terrain())
	var spots: Array[Vector2] = [Vector2(3.5, 3.5), Vector2(12.5, 3.5), Vector2(3.5, 12.5), Vector2(12.5, 12.5)]
	var heights: Array[float] = [0.0, 5.0, 3.0, 8.0]
	for k: int in spots.size():
		gibs.spawn(Vector3(spots[k].x, heights[k] + 1.0, spots[k].y), Vector3.ZERO, Color.RED)
	var settled: bool = await wait_until(
		func() -> bool: return gibs.live_chunk_count() == 0, Gibs.SETTLE_SECONDS + 3.0
	)
	assert_true(settled, "every chunk froze, by sleeping or by timing out")
	var by_quadrant: Array[Array] = [[], [], [], []]
	for chunk: RigidBody3D in _chunks(gibs):
		assert_true(chunk.freeze, "frozen, and still in the world")
		var p: Vector3 = chunk.global_position
		var k: int = (1 if p.x > 8.0 else 0) + (2 if p.z > 8.0 else 0)
		by_quadrant[k].append(p.y)
	for k: int in spots.size():
		assert_gt(by_quadrant[k].size(), 0, "chunks stayed over quadrant %d" % k)
		for y: float in by_quadrant[k]:
			# Resting on the ground, perhaps on a neighbor: not through it, not
			# floating. Quadrants are 2+ m apart, so a wrong plateau fails this.
			assert_between(y, heights[k] - 0.05, heights[k] + 1.0, "quadrant %d" % k)


func test_chunks_thrown_at_the_map_edge_stay_on_the_map() -> void:
	# The heightmap ends at the map's edge, and nothing is past it: a chunk
	# that crossed it would fall out of the world. A burst at each edge, thrown
	# outward, puts nearly every chunk over the edge within a second.
	var terrain: Terrain = TestTerrains.flat(8, 8)
	var gibs: Gibs = _gibs_over(terrain)
	var extent: float = terrain.extent_x() / 1000.0
	gibs.spawn(Vector3(0.3, 1.0, 3.5), Vector3.LEFT, Color.RED)
	gibs.spawn(Vector3(extent - 0.3, 1.0, 3.5), Vector3.RIGHT, Color.RED)
	gibs.spawn(Vector3(3.5, 1.0, 0.3), Vector3.FORWARD, Color.RED)
	gibs.spawn(Vector3(3.5, 1.0, extent - 0.3), Vector3.BACK, Color.RED)
	await wait_physics_frames(60)
	for chunk: RigidBody3D in _chunks(gibs):
		var p: Vector3 = chunk.global_position
		assert_between(p.x, 0.0, extent, "over the map in x: %s" % p)
		assert_between(p.z, 0.0, extent, "over the map in z: %s" % p)
		assert_gt(p.y, -0.05, "over the ground, not under it: %s" % p)


func test_a_chunk_sunk_into_the_ground_is_put_back_on_top() -> void:
	# What Godot physics can do to a chunk that lands hard: it sinks until its
	# center is under the heightmap's surface, which has no thickness and pushes
	# a body out of whichever side is nearer, so the bottom. Sink every chunk of
	# a burst like that, still falling.
	var gibs: Gibs = _gibs_over(TestTerrains.flat(8, 8))
	gibs.spawn(Vector3(3.5, 1.0, 3.5), Vector3.ZERO, Color.RED)
	for chunk: RigidBody3D in _chunks(gibs):
		chunk.global_position.y = -0.05
		chunk.linear_velocity = Vector3(0.0, -3.0, 0.0)
	await wait_physics_frames(30)
	for chunk: RigidBody3D in _chunks(gibs):
		assert_gt(chunk.global_position.y, 0.0, "back on top of the ground: %s" % chunk.global_position)


func test_update_heights_refreshes_the_whole_ground_shape() -> void:
	var terrain: Terrain = TestTerrains.flat(16, 16)
	var gibs: Gibs = _gibs_over(terrain)
	terrain.scar(8000, 8000, 4000, 600)
	assert_eq(_ground_heights(gibs)[8 * 16 + 8], 0.0, "the shape is a copy: it doesn't know yet")
	gibs.update_heights(terrain)
	var data: PackedFloat32Array = _ground_heights(gibs)
	assert_eq(data.size(), 16 * 16)
	for k: int in data.size():
		assert_almost_eq(data[k], terrain.heights[k] / 1000.0, 0.0001, "sample %d" % k)
	assert_almost_eq(data[8 * 16 + 8], -0.6, 0.0001, "the crater's bottom")


func test_update_heights_in_refreshes_only_the_region() -> void:
	var terrain: Terrain = TestTerrains.flat(16, 16)
	var gibs: Gibs = _gibs_over(terrain)
	var cells: Rect2i = terrain.scar(8000, 8000, 3000, 600)
	# Scar something else too, which the region update must not pick up.
	terrain.scar(2000, 2000, 1500, 600)
	gibs.update_heights_in(terrain, cells)
	var data: PackedFloat32Array = _ground_heights(gibs)
	assert_almost_eq(data[8 * 16 + 8], -0.6, 0.0001, "inside the region")
	assert_eq(data[2 * 16 + 2], 0.0, "outside it: still the old ground")
	for j: int in range(cells.position.y, cells.end.y):
		for i: int in range(cells.position.x, cells.end.x):
			assert_almost_eq(data[j * 16 + i], terrain.heights[j * 16 + i] / 1000.0, 0.0001)


func test_update_heights_in_an_empty_region_changes_nothing() -> void:
	var terrain: Terrain = TestTerrains.flat(16, 16)
	var gibs: Gibs = _gibs_over(terrain)
	terrain.scar(8000, 8000, 3000, 600)
	gibs.update_heights_in(terrain, Rect2i())
	assert_eq(_ground_heights(gibs)[8 * 16 + 8], 0.0)


func test_chunks_land_in_a_crater_once_the_ground_is_updated() -> void:
	var terrain: Terrain = TestTerrains.flat(16, 16)
	var gibs: Gibs = _gibs_over(terrain)
	var cells: Rect2i = terrain.scar(8000, 8000, 6000, Terrain.MAX_SCAR_DEPTH)
	gibs.update_heights_in(terrain, cells)
	gibs.spawn(Vector3(8.0, 1.5, 8.0), Vector3.ZERO, Color.RED)
	var settled: bool = await wait_until(
		func() -> bool: return gibs.live_chunk_count() == 0, Gibs.SETTLE_SECONDS + 3.0
	)
	assert_true(settled)
	var lowest: float = INF
	for chunk: RigidBody3D in _chunks(gibs):
		lowest = minf(lowest, chunk.global_position.y)
	# The bowl is a meter deep at its center; flat ground would hold them at 0.
	assert_lt(lowest, -0.3, "some came to rest down in the crater")


func _ground_heights(gibs: Gibs) -> PackedFloat32Array:
	var collider: CollisionShape3D = gibs.get_node("Ground").get_child(0) as CollisionShape3D
	return (collider.shape as HeightMapShape3D).map_data


func _gibs_over(terrain: Terrain) -> Gibs:
	var gibs: Gibs = Gibs.new()
	add_child_autofree(gibs)
	gibs.setup(terrain)
	return gibs


static func _chunks(gibs: Gibs) -> Array[RigidBody3D]:
	var out: Array[RigidBody3D] = []
	for child: Node in gibs.get_children():
		if child is RigidBody3D:
			out.append(child as RigidBody3D)
	return out


# 16 x 16 samples at 1 m: height 0 for x < 8 and z < 8, plus 5 m for x >= 8 and
# 3 m for z >= 8. Even and square, which every physics backend accepts.
static func _quadrant_terrain() -> Terrain:
	var size: int = 16
	var heights: PackedInt32Array = PackedInt32Array()
	heights.resize(size * size)
	for j: int in size:
		for i: int in size:
			heights[j * size + i] = (5000 if i >= 8 else 0) + (3000 if j >= 8 else 0)
	var water: PackedByteArray = PackedByteArray()
	water.resize(size * size)
	var blocked: PackedByteArray = PackedByteArray()
	blocked.resize(size * size)
	return Terrain.new(size, size, TestTerrains.CELL, heights, water, blocked, TestTerrains.WALKABLE_SLOPE)
