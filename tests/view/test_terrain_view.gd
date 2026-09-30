extends GutTest
## TerrainView.rebuild_region: after a scar, only the chunks whose samples
## changed (plus a one-sample margin) get new meshes, in place, keeping their
## names and the shared material; the rest are untouched. build() still makes
## one named chunk per 64 x 64 cells.

const M: int = 1000
const CHUNK: int = TerrainMeshBuilder.CHUNK_CELLS


# 150 x 70 samples: 3 x 2 chunks, the last column and row partial.
func _terrain() -> Terrain:
	return TestTerrains.flat(150, 70)


func _view_of(terrain: Terrain) -> TerrainView:
	var view: TerrainView = TerrainView.new()
	add_child_autofree(view)
	view.build(terrain)
	return view


func _chunk(view: TerrainView, cx: int, cz: int) -> MeshInstance3D:
	return view.get_node("Chunk_%d_%d" % [cx, cz]) as MeshInstance3D


func _lowest_vertex_y(chunk: MeshInstance3D) -> float:
	var vertices: PackedVector3Array = chunk.mesh.surface_get_arrays(0)[Mesh.ARRAY_VERTEX]
	var lowest: float = INF
	for v: Vector3 in vertices:
		lowest = minf(lowest, v.y)
	return lowest


func test_build_makes_one_named_chunk_per_block_of_cells() -> void:
	var view: TerrainView = _view_of(_terrain())
	assert_eq(view.get_child_count(), 6)
	for cz: int in 2:
		for cx: int in 3:
			assert_not_null(_chunk(view, cx, cz), "Chunk_%d_%d" % [cx, cz])


func test_building_again_replaces_the_chunks() -> void:
	var terrain: Terrain = _terrain()
	var view: TerrainView = _view_of(terrain)
	view.build(terrain)
	assert_eq(view.get_child_count(), 6, "no duplicates, even in the same frame")
	assert_not_null(_chunk(view, 2, 1), "and the names are the same")


func test_rebuild_region_only_touches_the_chunks_the_scar_changed() -> void:
	var terrain: Terrain = _terrain()
	var view: TerrainView = _view_of(terrain)
	var before: Dictionary[String, Mesh] = {}
	for child: Node in view.get_children():
		before[child.name] = (child as MeshInstance3D).mesh
	# A crater in the middle of chunk (1, 0): samples 70..74 by 10..14.
	var cells: Rect2i = terrain.scar(72 * M, 12 * M, 2 * M, 300)
	assert_true(cells.has_area())
	view.rebuild_region(terrain, cells)
	for child: Node in view.get_children():
		var changed: bool = (child as MeshInstance3D).mesh != before[child.name]
		assert_eq(changed, child.name == &"Chunk_1_0", "%s" % child.name)
	assert_lt(_lowest_vertex_y(_chunk(view, 1, 0)), 0.0, "the new mesh has the bowl in it")
	assert_almost_eq(_lowest_vertex_y(_chunk(view, 0, 0)), 0.0, 0.0001, "the rest is flat")


func test_rebuilt_chunks_keep_their_node_and_material() -> void:
	var terrain: Terrain = _terrain()
	var view: TerrainView = _view_of(terrain)
	var node: MeshInstance3D = _chunk(view, 1, 0)
	var material: Material = node.material_override
	assert_not_null(material)
	view.rebuild_region(terrain, terrain.scar(72 * M, 12 * M, 2 * M, 300))
	assert_same(_chunk(view, 1, 0), node)
	assert_same(node.material_override, material)
	assert_eq(view.get_child_count(), 6)


func test_a_scar_on_a_chunk_edge_rebuilds_both_chunks() -> void:
	var terrain: Terrain = _terrain()
	var view: TerrainView = _view_of(terrain)
	var before: Dictionary[String, Mesh] = {}
	for child: Node in view.get_children():
		before[child.name] = (child as MeshInstance3D).mesh
	# Sample column 64 is the last of chunk 0 and the first of chunk 1.
	var cells: Rect2i = terrain.scar(64 * M, 12 * M, 2 * M, 300)
	view.rebuild_region(terrain, cells)
	assert_ne(_chunk(view, 0, 0).mesh, before["Chunk_0_0"])
	assert_ne(_chunk(view, 1, 0).mesh, before["Chunk_1_0"])
	assert_eq(_chunk(view, 2, 0).mesh, before["Chunk_2_0"])
	assert_eq(_chunk(view, 0, 1).mesh, before["Chunk_0_1"])
	assert_lt(_lowest_vertex_y(_chunk(view, 0, 0)), 0.0, "the edge sample moved in both")
	assert_lt(_lowest_vertex_y(_chunk(view, 1, 0)), 0.0)


func test_the_margin_reaches_a_chunk_one_sample_away() -> void:
	var terrain: Terrain = _terrain()
	var view: TerrainView = _view_of(terrain)
	var before: Mesh = _chunk(view, 1, 0).mesh
	# Samples 60..63 are all in chunk (0, 0). The one-sample margin takes in
	# sample 64, which chunk (1, 0) starts on, so it is rebuilt too.
	view.rebuild_region(terrain, Rect2i(60, 10, 4, 3))
	assert_ne(_chunk(view, 1, 0).mesh, before)


func test_an_empty_region_changes_nothing() -> void:
	var terrain: Terrain = _terrain()
	var view: TerrainView = _view_of(terrain)
	var before: Dictionary[String, Mesh] = {}
	for child: Node in view.get_children():
		before[child.name] = (child as MeshInstance3D).mesh
	view.rebuild_region(terrain, Rect2i())
	for child: Node in view.get_children():
		assert_eq((child as MeshInstance3D).mesh, before[child.name], "%s" % child.name)


func test_rebuilding_edge_chunks_keeps_their_smaller_size() -> void:
	var terrain: Terrain = _terrain()
	var view: TerrainView = _view_of(terrain)
	# The far corner chunk is 21 x 5 cells: 22 x 6 vertices.
	view.rebuild_region(terrain, terrain.scar(140 * M, 66 * M, 2 * M, 300))
	var vertices: PackedVector3Array = _chunk(view, 2, 1).mesh.surface_get_arrays(0)[Mesh.ARRAY_VERTEX]
	assert_eq(vertices.size(), (150 - 1 - 2 * CHUNK + 1) * (70 - 1 - CHUNK + 1))
	assert_lt(_lowest_vertex_y(_chunk(view, 2, 1)), 0.0)
