extends GutTest
## Blocked samples (houses, walls) are raised in the height field but were not
## otherwise marked, so a house read as a bump. TerrainView gives the shader a
## per-sample texture, blocked_map, and the terrain shader draws the samples it
## flags darker and greyer (blocked_tint). Written once: the sim never
## unblocks anything.


func _view_of(terrain: Terrain) -> TerrainView:
	var view: TerrainView = TerrainView.new()
	add_child_autofree(view)
	view.build(terrain)
	return view


func _material(view: TerrainView) -> ShaderMaterial:
	return view.get_node("Chunk_0_0").material_override as ShaderMaterial


func _blocked_image(view: TerrainView) -> Image:
	return (_material(view).get_shader_parameter("blocked_map") as ImageTexture).get_image()


func test_a_blocked_samples_texel_differs_from_an_unblocked_ones() -> void:
	var terrain: Terrain = TestTerrains.from_ascii([".#.", "...", "#.."] as Array[String])
	var image: Image = _blocked_image(_view_of(terrain))
	assert_eq(image.get_size(), Vector2i(3, 3), "a texel per sample")
	assert_eq(image.get_pixel(1, 0).r8, TerrainView.BLOCKED_TEXEL, "a blocked sample")
	assert_eq(image.get_pixel(0, 2).r8, TerrainView.BLOCKED_TEXEL, "another")
	assert_ne(image.get_pixel(1, 0).r8, image.get_pixel(0, 0).r8, "an open one differs")
	for p: Vector2i in [Vector2i(0, 0), Vector2i(2, 0), Vector2i(1, 1), Vector2i(2, 2)]:
		assert_eq(image.get_pixel(p.x, p.y).r8, 0, "open sample %s" % p)


func test_the_shader_declares_what_the_view_sets() -> void:
	var view: TerrainView = _view_of(TestTerrains.flat(4, 4))
	var names: Array[String] = []
	for uniform: Dictionary in _material(view).shader.get_shader_uniform_list():
		names.append(uniform["name"])
	assert_has(names, "blocked_map", "set_shader_parameter would silently ignore a missing uniform")
	assert_has(names, "blocked_tint")
	assert_eq(
		_material(view).get_shader_parameter("blocked_tint"),
		Vector2(TerrainPalette.BLOCKED_DARKEN, TerrainPalette.BLOCKED_DESATURATE)
	)


func test_a_blocked_color_is_45_percent_darker_and_greyer() -> void:
	assert_almost_eq(TerrainPalette.BLOCKED_DARKEN, 0.45, 0.0001)
	for ground: Color in [Color(0.47, 0.53, 0.27), Color(0.80, 0.72, 0.50), Color(0.62, 0.60, 0.56), Color(0.23, 0.33, 0.17)]:
		var shown: Color = TerrainPalette.blocked_color(ground)
		assert_almost_eq(shown.get_luminance(), ground.get_luminance() * 0.55, 0.002, "45%% darker than %s" % ground)
		var chroma: float = maxf(ground.r, maxf(ground.g, ground.b)) - minf(ground.r, minf(ground.g, ground.b))
		var shown_chroma: float = maxf(shown.r, maxf(shown.g, shown.b)) - minf(shown.r, minf(shown.g, shown.b))
		assert_lt(shown_chroma / 0.55, chroma, "and with less color than %s once the darkening is undone" % ground)
		assert_gt(shown_chroma, 0.0, "though not drained of it")


func test_the_shipped_riverside_marks_exactly_its_blocked_samples() -> void:
	var terrain: Terrain = TestTerrains.riverside()
	var image: Image = _blocked_image(_view_of(terrain))
	var wrong: int = 0
	var marked: int = 0
	for k: int in terrain.blocked.size():
		var texel: int = image.get_pixel(k % terrain.size_x, k / terrain.size_x).r8
		marked += 1 if texel != 0 else 0
		wrong += 1 if (texel != 0) != (terrain.blocked[k] != 0) else 0
	gut.p("%d blocked samples marked" % marked)
	assert_eq(wrong, 0, "every blocked sample, and only those")
