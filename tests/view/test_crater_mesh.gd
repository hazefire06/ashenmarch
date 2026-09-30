extends GutTest
## CraterMesh: a disc that hugs the terrain. Every vertex stands on
## height_at (scarred ground included) plus the lift, the color fades from
## opaque at the center to clear at the rim, and the triangles cover the disc
## facing up.

const M: int = 1000


func _arrays(mesh: ArrayMesh) -> Array:
	return mesh.surface_get_arrays(0)


func test_vertex_count_and_extent() -> void:
	var terrain: Terrain = TestTerrains.flat(40, 40)
	var mesh: ArrayMesh = CraterMesh.build(terrain, 20 * M, 20 * M, 3 * M)
	var vertices: PackedVector3Array = _arrays(mesh)[Mesh.ARRAY_VERTEX]
	assert_eq(vertices.size(), 1 + CraterMesh.RINGS * CraterMesh.SEGMENTS)
	assert_eq(vertices[0].x, 20.0, "the first vertex is the center")
	assert_eq(vertices[0].z, 20.0)
	var farthest: float = 0.0
	for v: Vector3 in vertices:
		farthest = maxf(farthest, Vector2(v.x - 20.0, v.z - 20.0).length())
	assert_almost_eq(farthest, 3.0, 0.001, "the outer ring is at the radius")


func test_vertices_stand_on_the_terrain_plus_lift() -> void:
	var terrain: Terrain = TestTerrains.ramp_x(40, 40, 500)
	var mesh: ArrayMesh = CraterMesh.build(terrain, 20 * M, 20 * M, 4 * M, 0.05)
	var vertices: PackedVector3Array = _arrays(mesh)[Mesh.ARRAY_VERTEX]
	for v: Vector3 in vertices:
		var expected: float = terrain.height_at(roundi(v.x * M), roundi(v.z * M)) / float(M) + 0.05
		assert_almost_eq(v.y, expected, 0.0001)
	# The ramp rises along +x, so the disc is tilted, not flat: the outer
	# ring's first vertex is 4 m east of the center, 2 m higher.
	assert_almost_eq(vertices[1 + (CraterMesh.RINGS - 1) * CraterMesh.SEGMENTS].y, vertices[0].y + 2.0, 0.001)


func test_default_lift() -> void:
	var terrain: Terrain = TestTerrains.flat(40, 40)
	var vertices: PackedVector3Array = _arrays(CraterMesh.build(terrain, 20 * M, 20 * M, 2 * M))[Mesh.ARRAY_VERTEX]
	assert_almost_eq(vertices[0].y, CraterMesh.DEFAULT_LIFT, 0.0001)


func test_follows_scarred_ground() -> void:
	var terrain: Terrain = TestTerrains.flat(40, 40)
	terrain.scar(20 * M, 20 * M, 3 * M, 400)
	assert_lt(terrain.height_at(20 * M, 20 * M), 0, "the scar lowered the center")
	var mesh: ArrayMesh = CraterMesh.build(terrain, 20 * M, 20 * M, 3 * M)
	var vertices: PackedVector3Array = _arrays(mesh)[Mesh.ARRAY_VERTEX]
	assert_almost_eq(vertices[0].y, terrain.height_at(20 * M, 20 * M) / float(M) + CraterMesh.DEFAULT_LIFT, 0.0001)
	assert_lt(vertices[0].y, 0.0, "the center sits in the bowl")
	for v: Vector3 in vertices:
		var expected: float = terrain.height_at(roundi(v.x * M), roundi(v.z * M)) / float(M) + CraterMesh.DEFAULT_LIFT
		assert_almost_eq(v.y, expected, 0.0001)


func test_alpha_is_opaque_at_the_center_and_clear_at_the_rim() -> void:
	var terrain: Terrain = TestTerrains.flat(40, 40)
	var arrays: Array = _arrays(CraterMesh.build(terrain, 20 * M, 20 * M, 3 * M))
	var vertices: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	var colors: PackedColorArray = arrays[Mesh.ARRAY_COLOR]
	assert_eq(colors.size(), vertices.size())
	assert_eq(colors[0].a, 1.0, "center")
	var previous: float = 1.0
	for ring: int in range(1, CraterMesh.RINGS + 1):
		var first: int = 1 + (ring - 1) * CraterMesh.SEGMENTS
		var alpha: float = colors[first].a
		assert_lt(alpha, previous, "ring %d is fainter than the one inside" % ring)
		previous = alpha
		for segment: int in CraterMesh.SEGMENTS:
			assert_eq(colors[first + segment].a, alpha, "a ring has one alpha")
	assert_eq(previous, 0.0, "the outermost ring is fully clear")
	for c: Color in colors:
		assert_eq(Color(c.r, c.g, c.b), Color.WHITE, "tinting is the material's job")


func test_triangles_face_up_and_stay_inside_the_vertex_list() -> void:
	var terrain: Terrain = TestTerrains.flat(40, 40)
	var arrays: Array = _arrays(CraterMesh.build(terrain, 20 * M, 20 * M, 3 * M))
	var vertices: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	var indices: PackedInt32Array = arrays[Mesh.ARRAY_INDEX]
	# A fan of SEGMENTS triangles plus two per segment for each further ring.
	assert_eq(indices.size(), 3 * CraterMesh.SEGMENTS * (1 + 2 * (CraterMesh.RINGS - 1)))
	var area: float = 0.0
	for t: int in indices.size() / 3:
		var a: Vector3 = vertices[indices[t * 3]]
		var b: Vector3 = vertices[indices[t * 3 + 1]]
		var c: Vector3 = vertices[indices[t * 3 + 2]]
		# Godot's front face is clockwise seen from the front, so a
		# triangle seen from above has the normal (c - a) x (b - a) pointing up.
		var normal: Vector3 = (c - a).cross(b - a)
		assert_gt(normal.y, 0.0, "triangle %d faces up" % t)
		area += normal.length() * 0.5
	# The polygon inscribed in the circle: slightly under the full disc.
	assert_between(area, PI * 9.0 * 0.96, PI * 9.0, "covers the disc")


func test_no_radius_makes_an_empty_mesh() -> void:
	var terrain: Terrain = TestTerrains.flat(10, 10)
	assert_eq(CraterMesh.build(terrain, 5 * M, 5 * M, 0).get_surface_count(), 0)
	assert_eq(CraterMesh.build(terrain, 5 * M, 5 * M, -1).get_surface_count(), 0)


func test_a_disc_off_the_map_edge_still_builds() -> void:
	var terrain: Terrain = TestTerrains.flat(10, 10)
	var mesh: ArrayMesh = CraterMesh.build(terrain, 0, 0, 3 * M)
	assert_eq(mesh.get_surface_count(), 1)
	var vertices: PackedVector3Array = _arrays(mesh)[Mesh.ARRAY_VERTEX]
	for v: Vector3 in vertices:
		assert_almost_eq(v.y, CraterMesh.DEFAULT_LIFT, 0.0001, "height_at clamps to the edge")
