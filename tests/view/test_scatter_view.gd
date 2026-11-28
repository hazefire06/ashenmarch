extends GutTest
## ScatterView: the placer's layout as one MultiMeshInstance3D per model mesh,
## given only the items near the focus, with the scatter shaders, graded, weathered and lit by the terrain's fire texture,
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


func test_one_multimesh_per_model_mesh_holding_every_item() -> void:
	var terrain: Terrain = TestTerrains.from_ascii(_rows(70, 40, "b"))
	var view: ScatterView = _view(terrain)
	var layout: ScatterLayout = ScatterPlacer.place(
		terrain, {}, PackedFloat32Array(), null, ScatterSet.shared().native_sizes(), ScatterPlacer.seed_for("test")
	)
	assert_eq(view.instance_count(), layout.size())
	var names: Dictionary[String, int] = {}
	for instance: MultiMeshInstance3D in _instances(view):
		assert_not_null(instance, "only multimeshes")
		assert_true(instance.multimesh.use_custom_data, "the custom data carries the ground")
		names[String(instance.name)] = names.get(String(instance.name), 0) + 1
	assert_eq(names.size(), _instances(view).size(), "one draw per model mesh: no chunks")
	var held: int = 0
	for origins: PackedVector3Array in view.drawn_origins():
		held += origins.size()
	assert_gte(held, layout.size(), "every item is held (a model with two meshes holds it twice)")
	view.set_focus(Vector3(35.0, 0.0, 20.0))
	var submitted: int = 0
	for instance: MultiMeshInstance3D in _instances(view):
		submitted += instance.multimesh.instance_count
	assert_eq(submitted, held, "a focus in the middle of a small map submits everything")


func test_only_items_near_the_focus_are_submitted() -> void:
	var terrain: Terrain = TestTerrains.from_ascii(_rows(400, 60, "b"))
	var view: ScatterView = _view(terrain)
	for instance: MultiMeshInstance3D in _instances(view):
		assert_eq(instance.multimesh.instance_count, 0, "nothing before the first focus")
	view.set_focus(Vector3(30.0, 0.0, 30.0))
	var instances: Array[MultiMeshInstance3D] = _instances(view)
	var submitted: Array[PackedVector3Array] = view.submitted_origins()
	var all: Array[PackedVector3Array] = view.drawn_origins()
	var diagonal: float = ScatterView.BUCKET_M * sqrt(2.0)
	var total: int = 0
	for g: int in instances.size():
		var model: String = String(instances[g].name).trim_prefix("Scatter_")
		var reach: float = ScatterView.FADE_END_M[ScatterPlacer.KINDS[StringName(model)]]
		assert_eq(instances[g].multimesh.instance_count, submitted[g].size(), "%s: the buffer holds what was chosen" % model)
		for at: Vector3 in submitted[g]:
			assert_lt(Vector2(at.x - 30.0, at.z - 30.0).length(), reach + diagonal, "%s at %s is beyond reach" % [model, at])
		var within: int = 0
		for at: Vector3 in all[g]:
			if Vector2(at.x - 30.0, at.z - 30.0).length() < reach:
				within += 1
		assert_gte(submitted[g].size(), within, "%s: everything in reach is submitted" % model)
		assert_lt(submitted[g].size(), all[g].size(), "%s: the far end of the map is not" % model)
		total += submitted[g].size()
	assert_gt(total, 0)


func test_every_surface_uses_the_scatter_shader_with_the_fire() -> void:
	var terrain_view: TerrainView = TerrainView.new()
	add_child_autofree(terrain_view)
	var terrain: Terrain = TestTerrains.from_ascii(_rows(40, 40, "b"))
	terrain_view.build(terrain)
	var view: ScatterView = _view(terrain, terrain_view.fire_texture())
	assert_gt(view.materials().size(), 3)
	for material: ShaderMaterial in view.materials():
		assert_has([ScatterView.OPAQUE_SHADER, ScatterView.CUTOUT_SHADER], material.shader)
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
		if material.shader == ScatterView.CUTOUT_SHADER:
			assert_gt(material.get_shader_parameter(&"alpha_cutoff"), 0.0, "the kit's own cutoff")
			cut += 1
		else:
			assert_eq(material.shader, ScatterView.OPAQUE_SHADER)
			solid += 1
	assert_gt(cut, 0, "the leaf cards are alpha-scissored")
	assert_gt(solid, 0, "the grass blades are not")


func test_only_the_cutout_shader_can_discard() -> void:
	var opaque: Array[String] = []
	for uniform: Dictionary in ScatterView.OPAQUE_SHADER.get_shader_uniform_list():
		opaque.append(uniform["name"])
	var cutout: Array[String] = []
	for uniform: Dictionary in ScatterView.CUTOUT_SHADER.get_shader_uniform_list():
		cutout.append(uniform["name"])
	assert_does_not_have(opaque, "alpha_cutoff", "the opaque shader writes no alpha scissor")
	assert_has(cutout, "alpha_cutoff")
	assert_string_contains(ScatterView.CUTOUT_SHADER.code, "#define CUTOUT")
	assert_false(ScatterView.OPAQUE_SHADER.code.contains("CUTOUT"))


func test_each_kind_burns_its_own_way() -> void:
	var view: ScatterView = _view(TestTerrains.from_ascii(_rows(60, 60, "b")))
	var seen: Dictionary[int, bool] = {}
	for instance: MultiMeshInstance3D in _instances(view):
		var model: String = String(instance.name).trim_prefix("Scatter_")
		var kind: int = ScatterPlacer.KINDS[StringName(model)]
		var mesh: Mesh = instance.multimesh.mesh
		for i: int in mesh.get_surface_count():
			var material: ShaderMaterial = mesh.surface_get_material(i) as ShaderMaterial
			assert_eq(material.get_shader_parameter(&"burn_mode"), ScatterView.BURN_MODE[kind], "%s burns as its kind" % model)
		seen[kind] = true
	assert_true(seen.has(ScatterPlacer.Kind.GRASS) and seen.has(ScatterPlacer.Kind.BUSH), "grass and bushes both checked")
	assert_eq(ScatterView.BURN_MODE[ScatterPlacer.Kind.GRASS], 1, "scorched grass is gone")
	assert_eq(ScatterView.BURN_MODE[ScatterPlacer.Kind.PLANT], 1, "scorched plants are gone")
	assert_eq(ScatterView.BURN_MODE[ScatterPlacer.Kind.BUSH], 2, "a scorched bush is a charred stump")
	assert_eq(ScatterView.BURN_MODE[ScatterPlacer.Kind.PEBBLE], 0, "pebbles don't burn")


func test_the_sims_fire_reaches_the_scatters_fire_texture() -> void:
	var rows: Array[String] = []
	for j: int in 11:
		rows.append("sssss" + ("." if j == 5 else "s") + "sssss")
	var world: World = World.new(1, TestTerrains.from_ascii(rows), TestTerrains.catalog())
	var terrain_view: TerrainView = TerrainView.new()
	add_child_autofree(terrain_view)
	terrain_view.build(world.terrain)
	var view: ScatterView = _view(world.terrain, terrain_view.fire_texture())
	assert_gt(view.materials().size(), 0)
	world.ignite(5000, 5000, 0)
	terrain_view.update_fire(world.fire)
	# The headless renderer keeps no texture data, so the check is that every
	# material holds the very texture TerrainView updates, and that it updated.
	assert_eq(terrain_view.fire_texel(5, 5), TerrainView.FIRE_TEXEL[Fire.Cell.BURNING])
	assert_eq(terrain_view.fire_glow_texel(5, 5), TerrainView.FIRE_GLOW_TEXEL)
	for material: ShaderMaterial in view.materials():
		assert_same(material.get_shader_parameter(&"fire_state"), terrain_view.fire_texture(), "the scatter reads the live fire")


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


func test_the_focus_reaches_every_material_and_moves_the_submission() -> void:
	var terrain: Terrain = TestTerrains.from_ascii(_rows(400, 60, "b"))
	var view: ScatterView = _view(terrain)
	view.set_focus(Vector3(20.0, 0.0, 30.0))
	for material: ShaderMaterial in view.materials():
		assert_eq(material.get_shader_parameter(&"fade_centre"), Vector3(20.0, 0.0, 30.0))
	var near_start: Array[PackedVector3Array] = view.submitted_origins()
	view.set_focus(Vector3(21.0, 0.0, 30.0))
	assert_eq(view.submitted_origins(), near_start, "a step under REFRESH_M moves only the fade")
	assert_eq(view.materials()[0].get_shader_parameter(&"fade_centre"), Vector3(21.0, 0.0, 30.0))
	view.set_focus(Vector3(380.0, 0.0, 30.0))
	for origins: PackedVector3Array in view.submitted_origins():
		for at: Vector3 in origins:
			assert_gt(at.x, 380.0 - ScatterView.FADE_END_M.max() - ScatterView.BUCKET_M * 1.5, "the far end once the focus moves")


func test_the_look_point_is_where_the_camera_ray_meets_the_ground() -> void:
	var terrain: Terrain = TestTerrains.ramp_x(100, 100, 200)
	var view: ScatterView = _view(terrain)
	var down: Transform3D = Transform3D(Basis(Vector3.RIGHT, -PI / 2.0), Vector3(40.0, 50.0, 40.0))
	var below: Vector3 = view.look_point(down)
	assert_almost_eq(below.x, 40.0, 0.01)
	assert_almost_eq(below.z, 40.0, 0.01)
	assert_almost_eq(below.y, 8.0, 0.01, "on the ramp, 0.2 m up per metre")
	var tilted: Transform3D = Transform3D.IDENTITY.looking_at(Vector3(0.0, -1.0, -1.0), Vector3.UP)
	tilted.origin = Vector3(50.0, 40.0, 80.0)
	var hit: Vector3 = view.look_point(tilted)
	assert_almost_eq(hit.y, ScatterPlacer.ground_height_m(terrain, ScatterPlacer.view_height_array(terrain, {}), hit.x, hit.z), 0.05, "on the ground")
	assert_almost_eq(hit.x, 50.0, 0.01, "straight ahead")
	assert_lt(hit.z, 80.0, "in front of the camera")


func test_nothing_is_drawn_without_a_scatter_set() -> void:
	var view: ScatterView = ScatterView.new()
	add_child_autofree(view)
	view.build(TestTerrains.flat(20, 20), null, PackedFloat32Array(), "test", null, ScatterSet.new())
	assert_eq(view.instance_count(), 0)
	assert_eq(view.get_child_count(), 0)


func test_the_scatter_shaders_declare_their_uniforms() -> void:
	for shader: Shader in [ScatterView.OPAQUE_SHADER, ScatterView.CUTOUT_SHADER]:
		var names: Array[String] = []
		for uniform: Dictionary in shader.get_shader_uniform_list():
			names.append(uniform["name"])
		for wanted: String in [
			"albedo_texture", "albedo_color", "grade_tint", "grade_desaturation", "ground_recolor", "kit_tint",
			"kit_desaturation", "wetness", "snow_cover", "fire_state", "cell_size", "sample_count", "burn_mode",
			"wind", "fade_centre", "fade_end", "fade_margin", "normal_up",
		]:
			assert_has(names, wanted, "%s: set_shader_parameter would silently ignore a missing uniform" % shader.resource_path)
