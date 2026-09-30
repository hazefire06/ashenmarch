extends GutTest
## The render mesh must sit exactly on the sim's sample heights, and chunking
## must cover every cell exactly once.

const CHUNK: int = TerrainMeshBuilder.CHUNK_CELLS


func test_chunk_counts_for_512_map() -> void:
	# 512 samples = 511 cells: seven full chunks and one of 63 cells.
	var t: Terrain = _flat_terrain(512, 512)
	assert_eq(TerrainMeshBuilder.chunk_counts(t), Vector2i(8, 8))
	assert_eq(TerrainMeshBuilder.chunk_cells(t, 0, 0), Vector2i(CHUNK, CHUNK))
	assert_eq(TerrainMeshBuilder.chunk_cells(t, 7, 7), Vector2i(63, 63))
	assert_eq(TerrainMeshBuilder.chunk_cells(t, 7, 0), Vector2i(63, CHUNK))


func test_chunk_counts_for_exact_multiple() -> void:
	var t: Terrain = _flat_terrain(CHUNK * 2 + 1, CHUNK + 1)
	assert_eq(TerrainMeshBuilder.chunk_counts(t), Vector2i(2, 1))
	assert_eq(TerrainMeshBuilder.chunk_cells(t, 1, 0), Vector2i(CHUNK, CHUNK))


func test_chunks_cover_every_cell_once() -> void:
	var t: Terrain = _flat_terrain(150, 70)
	var counts: Vector2i = TerrainMeshBuilder.chunk_counts(t)
	var cells: int = 0
	for cz: int in counts.y:
		for cx: int in counts.x:
			var c: Vector2i = TerrainMeshBuilder.chunk_cells(t, cx, cz)
			cells += c.x * c.y
	assert_eq(cells, 149 * 69)


func test_vertices_match_sim_sample_heights() -> void:
	var size: int = CHUNK + 6
	var heights: PackedInt32Array = PackedInt32Array()
	for k: int in size * size:
		heights.append((k * 7919) % 30000)
	var t: Terrain = _terrain(size, size, heights, 2000)
	var mismatches: int = 0
	var counts: Vector2i = TerrainMeshBuilder.chunk_counts(t)
	for cz: int in counts.y:
		for cx: int in counts.x:
			var mesh: ArrayMesh = TerrainMeshBuilder.build_chunk(t, cx, cz)
			var vertices: PackedVector3Array = mesh.surface_get_arrays(0)[Mesh.ARRAY_VERTEX]
			for v: Vector3 in vertices:
				var i: int = roundi(v.x / 2.0)
				var j: int = roundi(v.z / 2.0)
				if not is_equal_approx(v.y, t.sample_height(i, j) / 1000.0):
					mismatches += 1
	assert_eq(mismatches, 0, "vertices off the sim's sample heights")


func test_chunk_mesh_sizes() -> void:
	var t: Terrain = _flat_terrain(CHUNK + 4, CHUNK + 1)
	var full: ArrayMesh = TerrainMeshBuilder.build_chunk(t, 0, 0)
	var ragged: ArrayMesh = TerrainMeshBuilder.build_chunk(t, 1, 0)
	var full_arrays: Array = full.surface_get_arrays(0)
	var ragged_arrays: Array = ragged.surface_get_arrays(0)
	assert_eq((full_arrays[Mesh.ARRAY_VERTEX] as PackedVector3Array).size(), (CHUNK + 1) * (CHUNK + 1))
	assert_eq((full_arrays[Mesh.ARRAY_INDEX] as PackedInt32Array).size(), CHUNK * CHUNK * 6)
	assert_eq((ragged_arrays[Mesh.ARRAY_VERTEX] as PackedVector3Array).size(), 4 * (CHUNK + 1))
	assert_eq((ragged_arrays[Mesh.ARRAY_INDEX] as PackedInt32Array).size(), 3 * CHUNK * 6)


func test_triangles_face_up() -> void:
	var t: Terrain = _flat_terrain(3, 3)
	var arrays: Array = TerrainMeshBuilder.build_chunk(t, 0, 0).surface_get_arrays(0)
	var vertices: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	var indices: PackedInt32Array = arrays[Mesh.ARRAY_INDEX]
	for n: int in range(0, indices.size(), 3):
		var a: Vector3 = vertices[indices[n]]
		var b: Vector3 = vertices[indices[n + 1]]
		var c: Vector3 = vertices[indices[n + 2]]
		# Godot's front faces are clockwise, so (c - a) x (b - a) is the outward normal.
		assert_gt((c - a).cross(b - a).y, 0.0, "triangle %d faces up" % (n / 3))


func _flat_terrain(samples_x: int, samples_z: int) -> Terrain:
	var heights: PackedInt32Array = PackedInt32Array()
	heights.resize(samples_x * samples_z)
	return _terrain(samples_x, samples_z, heights, 1000)


func _terrain(samples_x: int, samples_z: int, heights: PackedInt32Array, spacing: int) -> Terrain:
	var zeros: PackedByteArray = PackedByteArray()
	zeros.resize(samples_x * samples_z)
	return Terrain.new(samples_x, samples_z, spacing, heights, zeros, zeros.duplicate(), 1000)
