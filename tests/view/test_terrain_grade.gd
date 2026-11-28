extends GutTest
## TerrainView.set_grade: a mission's look for the ground and water, passed to
## the terrain shader as uniforms. Unset, every one is "no change" (white tint,
## no desaturation, no recolor, no water blend), so sandbox and every other
## view renders as it did before the grade existed; set, it survives a rebuild.
## The textured ground (A5) recolors each layer by its per-sample weight, so
## the weights tell the shader each sample's ground type. The shader's own math
## is checked by eye (the headless renderer only parses it).

const M: int = 1000


func _view(terrain: Terrain = TestTerrains.flat(70, 70)) -> TerrainView:
	var view: TerrainView = TerrainView.new()
	add_child_autofree(view)
	view.build(terrain)
	return view


func _recolor() -> Array[Color]:
	var out: Array[Color] = []
	for ground: int in Terrain.GROUND_COUNT:
		out.append(Color(0.1 * ground, 0.2, 0.3, 0.5))
	return out


func test_the_shader_declares_every_grade_uniform() -> void:
	var names: Array[String] = []
	for uniform: Dictionary in _view().get_child(0).material_override.shader.get_shader_uniform_list():
		names.append(uniform["name"])
	for wanted: String in ["grade_tint", "grade_desaturation", "ground_recolor", "water_grade", "ground_weights_a", "ground_weights_b"]:
		assert_has(names, wanted, "set_shader_parameter would silently ignore a missing uniform")


func test_unset_the_grade_changes_nothing() -> void:
	var view: TerrainView = _view()
	assert_eq(view.shader_parameter(&"grade_tint"), Color.WHITE)
	assert_eq(view.shader_parameter(&"grade_desaturation"), 0.0)
	assert_eq(view.shader_parameter(&"water_grade").a, 0.0, "no water blend")
	var recolor: PackedColorArray = view.shader_parameter(&"ground_recolor")
	assert_eq(recolor.size(), Terrain.GROUND_COUNT)
	for color: Color in recolor:
		assert_eq(color.a, 0.0, "no recolor: every ground type's blend is 0")


func test_set_grade_reaches_the_shader() -> void:
	var view: TerrainView = _view()
	view.set_grade(Color(0.8, 0.6, 0.5), 0.4, _recolor(), Color(0.1, 0.1, 0.1, 0.7))
	assert_eq(view.shader_parameter(&"grade_tint"), Color(0.8, 0.6, 0.5))
	assert_eq(view.shader_parameter(&"grade_desaturation"), 0.4)
	assert_eq(view.shader_parameter(&"water_grade"), Color(0.1, 0.1, 0.1, 0.7))
	var recolor: PackedColorArray = view.shader_parameter(&"ground_recolor")
	assert_eq(recolor[Terrain.Ground.SAND], Color(0.3, 0.2, 0.3, 0.5))


func test_an_empty_recolor_means_none() -> void:
	var view: TerrainView = _view()
	view.set_grade(Color.WHITE, 0.0, _recolor(), Color(0, 0, 0, 0))
	view.set_grade(Color.WHITE, 0.0, [], Color(0, 0, 0, 0))
	var recolor: PackedColorArray = view.shader_parameter(&"ground_recolor")
	for color: Color in recolor:
		assert_eq(color.a, 0.0)


func test_the_grade_survives_a_rebuild_and_a_rebuilt_region() -> void:
	var terrain: Terrain = TestTerrains.flat(70, 70)
	var view: TerrainView = _view(terrain)
	view.set_grade(Color(0.8, 0.6, 0.5), 0.4, _recolor(), Color(0.1, 0.1, 0.1, 0.7))
	view.rebuild_region(terrain, terrain.scar(30 * M, 30 * M, 2 * M, 300))
	assert_eq(view.shader_parameter(&"grade_desaturation"), 0.4, "the material is kept")
	view.build(terrain)
	assert_eq(view.shader_parameter(&"grade_tint"), Color(0.8, 0.6, 0.5), "and a new one is given it")
	assert_eq(view.shader_parameter(&"grade_desaturation"), 0.4)


func _weight(view: TerrainView, i: int, j: int) -> PackedByteArray:
	var a: Color = (view.shader_parameter(&"ground_weights_a") as ImageTexture).get_image().get_pixel(i, j)
	var b: Color = (view.shader_parameter(&"ground_weights_b") as ImageTexture).get_image().get_pixel(i, j)
	# Terrain.Ground order: grass, brush, wood, sand, rock.
	return PackedByteArray([a.r8, a.g8, a.b8, a.a8, b.r8])


func test_the_shader_is_told_each_samples_ground_type() -> void:
	var terrain: Terrain = TestTerrains.from_ascii([
		"..bw",
		"sr.#",
	])
	var view: TerrainView = _view(terrain)
	var expected: Dictionary[Vector2i, int] = {
		Vector2i(0, 0): Terrain.Ground.GRASS,
		Vector2i(2, 0): Terrain.Ground.BRUSH,
		Vector2i(3, 0): Terrain.Ground.WOOD,
		Vector2i(0, 1): Terrain.Ground.SAND,
		Vector2i(1, 1): Terrain.Ground.ROCK,
	}
	for at: Vector2i in expected:
		var weights: PackedByteArray = _weight(view, at.x, at.y)
		for ground: int in Terrain.GROUND_COUNT:
			assert_eq(weights[ground], 255 if ground == expected[at] else 0, "sample %s, ground %d" % [at, ground])


func test_the_weights_hold_every_type_the_terrain_has() -> void:
	var shipped: Terrain = TestTerrains.riverside()
	var view: TerrainView = _view(shipped)
	var seen: Dictionary[int, bool] = {}
	for j: int in range(0, shipped.size_z, 4):
		for i: int in range(0, shipped.size_x, 4):
			var weights: PackedByteArray = _weight(view, i, j)
			for ground: int in Terrain.GROUND_COUNT:
				if weights[ground] > 0:
					seen[ground] = true
	assert_true(seen.has(Terrain.Ground.GRASS))


func test_a_recolor_of_the_wrong_size_is_refused() -> void:
	var view: TerrainView = _view()
	view.set_grade(Color.WHITE, 0.0, [Color.RED], Color(0, 0, 0, 0))
	assert_push_error("recolor needs 5 colors")
	var recolor: PackedColorArray = view.shader_parameter(&"ground_recolor")
	assert_eq(recolor.size(), Terrain.GROUND_COUNT)
	assert_eq(recolor[0].a, 0.0, "it is left at none")
