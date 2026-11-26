extends GutTest
## ScatterView: the placer's layout as chunked MultiMeshInstance3Ds with the
## scatter shader, graded, weathered and lit by the terrain's fire texture,
## and following the ground when an explosion scars it. What the shader does
## with its parameters is checked by eye (make capture).


static func _rows(size_x: int, size_z: int, letter: String) -> Array[String]:
	var rows: Array[String] = []
	for j: int in size_z:
		rows.append(letter.repeat(size_x))
	return rows


func _view(terrain: Terrain, fire: Texture2D = null, density: float = 1.0) -> ScatterView:
	var view: ScatterView = ScatterView.new()
	add_child_autofree(view)
	view.build(terrain, null, PackedFloat32Array(), "test", fire, ScatterSet.shared(), density)
	return view


func _instances(view: ScatterView) -> Array[MultiMeshInstance3D]:
	var found: Array[MultiMeshInstance3D] = []
	for child: Node in view.get_children():
		found.append(child as MultiMeshInstance3D)
	return found


func test_every_placed_item_is_drawn_once_per_mesh() -> void:
	var terrain: Terrain = TestTerrains.from_ascii(_rows(70, 40, "b"))
	var view: ScatterView = _view(terrain)
	var layout: ScatterLayout = ScatterPlacer.place(
		terrain, {}, PackedFloat32Array(), null, ScatterSet.shared().native_heights(), ScatterPlacer.seed_for("test")
	)
	assert_eq(view.instance_count(), layout.size())
	var drawn: int = 0
	for instance: MultiMeshInstance3D in _instances(view):
		assert_not_null(instance, "only multimeshes")
		drawn += instance.multimesh.instance_count
		assert_true(instance.multimesh.use_custom_data, "the custom data carries the ground")
	assert_eq(drawn, layout.size(), "every model in the set has one mesh")


func test_chunks_hold_only_their_own_square() -> void:
	var terrain: Terrain = TestTerrains.from_ascii(_rows(70, 40, "."))
	var view: ScatterView = _view(terrain)
	var instances: Array[MultiMeshInstance3D] = _instances(view)
	assert_gt(instances.size(), 4, "several chunks and models")
	var origins: Array[PackedVector3Array] = view.drawn_origins()
	assert_eq(origins.size(), instances.size())
	for c: int in instances.size():
		var instance: MultiMeshInstance3D = instances[c]
		var centre: Vector3 = instance.position
		assert_gt(instance.visibility_range_end, 0.0, "each chunk stops drawing far away")
		assert_eq(instance.multimesh.instance_count, origins[c].size())
		for at: Vector3 in origins[c]:
			assert_lte(absf(at.x - centre.x), ScatterView.CHUNK_M * 0.5 + 1.0, "%s within its chunk" % instance.name)
			assert_lte(absf(at.z - centre.z), ScatterView.CHUNK_M * 0.5 + 1.0, "%s within its chunk" % instance.name)


func test_every_surface_uses_the_scatter_shader_with_the_fire() -> void:
	var terrain_view: TerrainView = TerrainView.new()
	add_child_autofree(terrain_view)
	var terrain: Terrain = TestTerrains.from_ascii(_rows(40, 40, "b"))
	terrain_view.build(terrain)
	var view: ScatterView = _view(terrain, terrain_view.fire_texture())
	assert_gt(view.materials().size(), 3)
	for material: ShaderMaterial in view.materials():
		assert_eq(material.shader, ScatterView.SCATTER_SHADER)
		assert_eq(material.get_shader_parameter(&"fire_state"), terrain_view.fire_texture())
		assert_eq(material.get_shader_parameter(&"sample_count"), Vector2(40, 40))
	for instance: MultiMeshInstance3D in _instances(view):
		var mesh: Mesh = instance.multimesh.mesh
		for i: int in mesh.get_surface_count():
			assert_true(view.materials().has(mesh.surface_get_material(i)), "%s surface %d" % [instance.name, i])


func test_leaves_are_cut_out_and_grass_blades_are_solid() -> void:
	var view: ScatterView = _view(TestTerrains.from_ascii(_rows(40, 40, "b")))
	var cut: int = 0
	var solid: int = 0
	for material: ShaderMaterial in view.materials():
		if material.get_shader_parameter(&"alpha_cutoff") > 0.0:
			cut += 1
		else:
			solid += 1
	assert_gt(cut, 0, "the leaf cards are alpha-scissored")
	assert_gt(solid, 0, "the grass blades are not")


func test_grade_and_weather_reach_every_material_and_survive_a_rebuild() -> void:
	var terrain: Terrain = TestTerrains.from_ascii(_rows(40, 40, "b"))
	var view: ScatterView = _view(terrain)
	var recolor: Array[Color] = [Color.RED, Color.GREEN, Color.BLUE, Color.WHITE, Color.BLACK]
	view.set_grade(Color(0.5, 0.6, 0.7), 0.4, recolor)
	var weather: Weather = Weather.new()
	weather.wetness_ppm = 500_000
	weather.snow_cover_ppm = 250_000
	view.set_weather(weather)
	view.build(terrain, null, PackedFloat32Array(), "test", null, ScatterSet.shared(), 1.0)
	for material: ShaderMaterial in view.materials():
		assert_eq(material.get_shader_parameter(&"grade_tint"), Color(0.5, 0.6, 0.7))
		assert_eq(material.get_shader_parameter(&"grade_desaturation"), 0.4)
		assert_eq(material.get_shader_parameter(&"ground_recolor"), PackedColorArray(recolor))
		assert_almost_eq(material.get_shader_parameter(&"wetness"), weather.wetness() / 1000.0, 0.0001)
		assert_almost_eq(material.get_shader_parameter(&"snow_cover"), weather.snow_cover() / 1000.0, 0.0001)
	assert_gt(weather.wetness(), 0, "the weather is not dry")


func test_the_density_knob_reaches_the_placer() -> void:
	var terrain: Terrain = TestTerrains.from_ascii(_rows(40, 40, "."))
	var full: int = _view(terrain).instance_count()
	var web: int = _view(terrain, null, ScatterPlacer.DENSITY_SCALE_WEB).instance_count()
	assert_almost_eq(float(web) / full, ScatterPlacer.DENSITY_SCALE_WEB, 0.1)


func test_items_follow_the_ground_after_a_scar() -> void:
	var terrain: Terrain = TestTerrains.from_ascii(_rows(40, 40, "b"))
	var terrain_view: TerrainView = TerrainView.new()
	add_child_autofree(terrain_view)
	terrain_view.build(terrain)
	var view: ScatterView = _view(terrain)
	terrain_view.region_rebuilt.connect(view.rebuild_region)
	var before: float = _height_near(view, Vector2(20.0, 20.0))
	assert_almost_eq(before, 0.0, 0.1, "flat ground before")
	var cells: Rect2i = terrain.scar(20000, 20000, 4000, 800)
	assert_true(cells.has_area())
	terrain_view.rebuild_region(terrain, cells)
	var heights: PackedInt32Array = ScatterPlacer.view_height_array(terrain, {})
	var checked: int = 0
	for origins: PackedVector3Array in view.drawn_origins():
		for at: Vector3 in origins:
			if absf(at.x - 20.0) > 4.0 or absf(at.z - 20.0) > 4.0:
				continue
			assert_almost_eq(at.y, ScatterPlacer.ground_height_m(terrain, heights, at.x, at.z), 0.01, "%s" % at)
			checked += 1
	assert_gt(checked, 3, "some items stand in the crater")
	assert_lt(_height_near(view, Vector2(20.0, 20.0)), -0.1, "and they sank with it")


## The lowest item within 2.5 m of at.
func _height_near(view: ScatterView, at: Vector2) -> float:
	var lowest: float = INF
	for origins: PackedVector3Array in view.drawn_origins():
		for spot: Vector3 in origins:
			if Vector2(spot.x, spot.z).distance_to(at) < 2.5:
				lowest = minf(lowest, spot.y)
	return lowest


func test_nothing_is_drawn_without_a_scatter_set() -> void:
	var view: ScatterView = ScatterView.new()
	add_child_autofree(view)
	view.build(TestTerrains.flat(20, 20), null, PackedFloat32Array(), "test", null, ScatterSet.new())
	assert_eq(view.instance_count(), 0)
	assert_eq(view.get_child_count(), 0)


func test_the_scatter_shader_declares_its_uniforms() -> void:
	var names: Array[String] = []
	for uniform: Dictionary in ScatterView.SCATTER_SHADER.get_shader_uniform_list():
		names.append(uniform["name"])
	for wanted: String in [
		"albedo_texture", "albedo_color", "alpha_cutoff", "grade_tint", "grade_desaturation", "ground_recolor",
		"wetness", "snow_cover", "fire_state", "cell_size", "sample_count", "burn_mode", "wind",
		"fade_end", "fade_margin", "normal_up",
	]:
		assert_has(names, wanted, "set_shader_parameter would silently ignore a missing uniform")
