extends GutTest
## TerrainView.set_grade: a mission's look for the ground and water, passed to
## the terrain shader as uniforms. Unset, every one is "no change" (white tint,
## no desaturation, no recolor, no water blend), so sandbox and every other
## view renders as it did before the grade existed; set, it survives a rebuild
## and shows each sample's ground type to the shader. The shader's own math is
## checked by eye (the headless renderer compiles nothing).

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
	for wanted: String in ["grade_tint", "grade_desaturation", "ground_recolor", "water_grade", "ground_kind"]:
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


func test_the_shader_is_told_each_samples_ground_type() -> void:
	var terrain: Terrain = TestTerrains.from_ascii([
		"..bw",
		"sr.#",
	])
	var view: TerrainView = _view(terrain)
	var kind: Image = (view.shader_parameter(&"ground_kind") as ImageTexture).get_image()
	assert_eq(kind.get_width(), 4)
	assert_eq(kind.get_height(), 2)
	assert_eq(kind.get_pixel(0, 0).r8, Terrain.Ground.GRASS)
	assert_eq(kind.get_pixel(2, 0).r8, Terrain.Ground.BRUSH)
	assert_eq(kind.get_pixel(3, 0).r8, Terrain.Ground.WOOD)
	assert_eq(kind.get_pixel(0, 1).r8, Terrain.Ground.SAND)
	assert_eq(kind.get_pixel(1, 1).r8, Terrain.Ground.ROCK)


func test_the_ground_texture_holds_every_type_the_terrain_has() -> void:
	var shipped: Terrain = TestTerrains.riverside()
	var view: TerrainView = _view(shipped)
	var kind: Image = (view.shader_parameter(&"ground_kind") as ImageTexture).get_image()
	var seen: Dictionary[int, bool] = {}
	for j: int in shipped.size_z:
		for i: int in shipped.size_x:
			seen[kind.get_pixel(i, j).r8] = true
	assert_true(seen.has(Terrain.Ground.GRASS))
	for ground: int in seen:
		assert_lt(ground, Terrain.GROUND_COUNT)


func test_a_recolor_of_the_wrong_size_is_refused() -> void:
	var view: TerrainView = _view()
	view.set_grade(Color.WHITE, 0.0, [Color.RED], Color(0, 0, 0, 0))
	assert_push_error("recolor needs 5 colors")
	var recolor: PackedColorArray = view.shader_parameter(&"ground_recolor")
	assert_eq(recolor.size(), Terrain.GROUND_COUNT)
	assert_eq(recolor[0].a, 0.0, "it is left at none")
