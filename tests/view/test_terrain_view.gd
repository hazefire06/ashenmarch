extends GutTest
## TerrainView.rebuild_region: after a scar, only the chunks whose samples
## changed (plus a one-sample margin) get new meshes, in place, keeping their
## names and the shared material; the rest are untouched. build() still makes
## one named chunk per 64 x 64 cells. The shared material carries per-sample
## weights for the six textured ground layers (A5), a fire texture the sim's fire keeps current
## (burning cells glow, burnt ones are scorched), and the weather's wetness
## and snow cover.

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


func test_a_scar_under_a_structure_keeps_its_ground_hidden() -> void:
	var terrain: Terrain = _terrain()
	var house: StructureRecord = StructureRecord.new()
	house.kind = &"house"
	house.center_m = Vector2(72.0, 12.0)
	house.size_m = Vector2(6.0, 6.0)
	house.base_m = 0.25
	var covered: PackedInt32Array = PackedInt32Array()
	for j: int in range(9, 15):
		for i: int in range(69, 75):
			covered.append(j * terrain.size_x + i)
			terrain.heights[j * terrain.size_x + i] = 4 * M
	house.samples = covered
	var structures: MapStructures = MapStructures.new()
	structures.records = [house]
	var view: TerrainView = TerrainView.new()
	add_child_autofree(view)
	view.build(terrain, structures)
	view.rebuild_region(terrain, terrain.scar(72 * M, 12 * M, 2 * M, 300))
	var vertices: PackedVector3Array = _chunk(view, 1, 0).mesh.surface_get_arrays(0)[Mesh.ARRAY_VERTEX]
	var checked: int = 0
	for v: Vector3 in vertices:
		var i: int = roundi(v.x)
		var j: int = roundi(v.z)
		if i >= 69 and i <= 74 and j >= 9 and j <= 14:
			checked += 1
			assert_almost_eq(v.y, 0.25, 0.0001, "vertex (%d, %d)" % [i, j])
	assert_eq(checked, 36)


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


func _weights(view: TerrainView, uniform: StringName) -> Image:
	return (view.shader_parameter(uniform) as ImageTexture).get_image()


func test_each_sample_weights_its_own_ground_layer() -> void:
	var terrain: Terrain = TestTerrains.from_ascii([".bws", "r..."] as Array[String])
	var view: TerrainView = _view_of(terrain)
	var a: Image = _weights(view, &"ground_weights_a")
	var b: Image = _weights(view, &"ground_weights_b")
	assert_eq(a.get_size(), Vector2i(4, 2), "a texel per sample")
	assert_eq(b.get_size(), Vector2i(4, 2))
	assert_eq(a.get_pixel(0, 0).r8, 255, "grass")
	assert_eq(a.get_pixel(1, 0).g8, 255, "brush")
	assert_eq(a.get_pixel(2, 0).b8, 255, "wood, the forest layer")
	assert_eq(a.get_pixel(3, 0).a8, 255, "sand")
	assert_eq(b.get_pixel(0, 1).r8, 255, "rock")
	assert_eq(a.get_pixel(0, 1).to_rgba32(), 0, "and nothing else there")


func test_ground_weights_sum_to_one_on_every_sample() -> void:
	var terrain: Terrain = TestTerrains.from_ascii([
		"..bbww..ss",
		".1bb2wwss.",
		"rr33.ssrr.",
		"rr..4.bb..",
		"..ww..rr1.",
	] as Array[String])
	var view: TerrainView = _view_of(terrain)
	var a: Image = _weights(view, &"ground_weights_a")
	var b: Image = _weights(view, &"ground_weights_b")
	for j: int in terrain.size_z:
		for i: int in terrain.size_x:
			var wa: Color = a.get_pixel(i, j)
			var wb: Color = b.get_pixel(i, j)
			assert_almost_eq(wa.r + wa.g + wa.b + wa.a + wb.r + wb.g, 1.0, 0.01, "sample (%d, %d)" % [i, j])


func test_mud_is_weighted_at_the_shore() -> void:
	var terrain: Terrain = TestTerrains.from_ascii(["1.........", "1.........", "1........."] as Array[String])
	var mud: Image = _weights(_view_of(terrain), &"ground_weights_b")
	assert_gt(mud.get_pixel(2, 1).g8, 0, "2 m from the water")
	assert_gt(mud.get_pixel(1, 1).g8, mud.get_pixel(2, 1).g8, "more nearer it")
	assert_eq(mud.get_pixel(5, 1).g8, 0, "none 5 m away")
	assert_eq(mud.get_pixel(9, 1).g8, 0)


func test_covered_samples_skip_the_blocked_darkening() -> void:
	var terrain: Terrain = TestTerrains.from_ascii(["......", ".##.#.", ".##...", "......"] as Array[String])
	var house: StructureRecord = StructureRecord.new()
	house.samples = PackedInt32Array([7, 8, 13, 14])
	var structures: MapStructures = MapStructures.new()
	structures.records = [house]
	var view: TerrainView = TerrainView.new()
	add_child_autofree(view)
	view.build(terrain, structures)
	var b: Image = _weights(view, &"ground_weights_b")
	for j: int in terrain.size_z:
		for i: int in terrain.size_x:
			var expected: int = 255 if house.samples.has(j * terrain.size_x + i) else 0
			assert_eq(b.get_pixel(i, j).b8, expected, "sample (%d, %d)" % [i, j])
	assert_eq(b.get_pixel(4, 1).b8, 0, "a blocked sample no structure covers keeps its darkening")


func test_the_textured_ground_receives_every_kept_uniform() -> void:
	var world: World = World.new(1, _terrain(), TestTerrains.catalog())
	var view: TerrainView = _view_of(world.terrain)
	world.ignite(10 * M, 10 * M, 0)
	view.update_fire(world.fire)
	world.weather.wetness_ppm = 400_000
	world.weather.snow_cover_ppm = 750_000
	view.set_weather(world.weather)
	var recolor: Array[Color] = []
	for ground: int in Terrain.GROUND_COUNT:
		recolor.append(Color(0.1 * ground, 0.2, 0.3, 0.5))
	view.set_grade(Color(0.8, 0.6, 0.5), 0.4, recolor, Color(0.1, 0.1, 0.1, 0.7))
	var declared: Array[String] = []
	for uniform: Dictionary in _material(view).shader.get_shader_uniform_list():
		declared.append(uniform["name"])
	var kept: Array[String] = [
		"water_tint", "blocked_map", "blocked_tint", "fire_state", "wetness", "snow_cover",
		"grade_tint", "grade_desaturation", "ground_recolor", "water_grade", "cell_size", "sample_count",
	]
	var textured: Array[String] = [
		"ground_albedo", "ground_normal", "ground_weights_a", "ground_weights_b", "detail_noise",
		"tile_m", "border_jitter", "rock_normal_y", "rock_band",
	]
	for name: String in kept + textured:
		assert_has(declared, name, "set_shader_parameter would silently ignore a missing uniform")
		assert_not_null(view.shader_parameter(StringName(name)), name)
	assert_true(view.shader_parameter(&"water_tint") is ImageTexture)
	assert_true(view.shader_parameter(&"blocked_map") is ImageTexture)
	assert_eq(
		view.shader_parameter(&"blocked_tint"),
		Vector2(TerrainPalette.BLOCKED_DARKEN, TerrainPalette.BLOCKED_DESATURATE)
	)
	assert_true(view.shader_parameter(&"fire_state") is ImageTexture)
	assert_eq(view.fire_texel(10, 10), TerrainView.FIRE_TEXEL[Fire.Cell.BURNING], "the fire as the sim has it")
	assert_almost_eq(view.shader_parameter(&"wetness") as float, 0.4, 0.0001)
	assert_almost_eq(view.shader_parameter(&"snow_cover") as float, 0.75, 0.0001)
	assert_eq(view.shader_parameter(&"grade_tint"), Color(0.8, 0.6, 0.5))
	assert_eq(view.shader_parameter(&"grade_desaturation"), 0.4)
	assert_eq(view.shader_parameter(&"ground_recolor"), PackedColorArray(recolor))
	assert_eq(view.shader_parameter(&"water_grade"), Color(0.1, 0.1, 0.1, 0.7))
	assert_almost_eq(view.shader_parameter(&"cell_size") as float, 1.0, 0.0001)
	assert_eq(view.shader_parameter(&"sample_count"), Vector2(150, 70))
	assert_same(view.shader_parameter(&"ground_albedo"), WorldTextures.albedo())
	assert_same(view.shader_parameter(&"ground_normal"), WorldTextures.normal())
	assert_same(view.shader_parameter(&"detail_noise"), WorldTextures.detail_noise())
	assert_almost_eq(view.shader_parameter(&"tile_m") as float, 3.0, 0.0001)
	assert_almost_eq(view.shader_parameter(&"border_jitter") as float, 0.35, 0.0001)
	assert_almost_eq(view.shader_parameter(&"rock_normal_y") as float, 0.707, 0.0001)
	assert_almost_eq(view.shader_parameter(&"rock_band") as float, 0.1, 0.0001)


func test_the_flat_colored_uniforms_are_gone() -> void:
	var declared: Array[String] = []
	for uniform: Dictionary in _material(_view_of(_terrain())).shader.get_shader_uniform_list():
		declared.append(uniform["name"])
	for gone: String in ["height_ramp", "ground_tint", "ground_kind", "height_min", "height_max"]:
		assert_does_not_have(declared, gone)


func test_world_textures_fall_back_without_assets() -> void:
	assert_eq(WorldTextures.LAYERS.size(), 6)
	assert_eq(WorldTextures.albedo().get_layers(), 6)
	assert_eq(WorldTextures.normal().get_layers(), 6)
	assert_same(WorldTextures.albedo(), WorldTextures.albedo(), "made once")
	var noise: Texture2D = WorldTextures.detail_noise()
	assert_eq(noise.get_size(), Vector2(256, 256))
	assert_same(WorldTextures.detail_noise(), noise, "made once")


func test_detail_noise_has_four_independent_channels() -> void:
	# The ground shader takes four noise values from one read; the water
	# shader reads R alone.
	var image: Image = (WorldTextures.detail_noise() as ImageTexture).get_image()
	assert_eq(image.get_format(), Image.FORMAT_RGBA8)
	var differ: Array[int] = [0, 0, 0]
	var count: int = 0
	for j: int in range(0, WorldTextures.NOISE_SIZE, 16):
		for i: int in range(0, WorldTextures.NOISE_SIZE, 16):
			var c: Color = image.get_pixel(i, j)
			differ[0] += 1 if absf(c.r - c.g) > 0.05 else 0
			differ[1] += 1 if absf(c.r - c.b) > 0.05 else 0
			differ[2] += 1 if absf(c.g - c.a) > 0.05 else 0
			count += 1
	for d: int in differ:
		assert_gt(d, count / 2, "each channel is its own noise")


func test_the_ground_look_knobs_are_uniforms() -> void:
	# So they can be tuned live; each has a default in the shader.
	var declared: Array[String] = []
	for uniform: Dictionary in _material(_view_of(_terrain())).shader.get_shader_uniform_list():
		declared.append(uniform["name"])
	for knob: String in [
		"far_scale", "far_angle", "far_near_m", "far_far_m", "far_share", "far_noise",
		"macro_m", "macro_value", "macro_hue", "macro_saturation",
		"border_width", "bend_large", "bend_large_m", "bend_fine", "height_blend",
	]:
		assert_has(declared, knob)


func test_the_fallback_layers_are_the_flat_ground_colors() -> void:
	# The headless renderer keeps no layer data, so the colors are checked
	# before they become the array.
	var colors: Array[Color] = WorldTextures.fallback_colors()
	assert_eq(colors.size(), WorldTextures.LAYERS.size())
	assert_eq(
		colors[WorldTextures.LAYERS.find(&"sand")],
		TerrainPalette.ground_color(WorldTextures.FALLBACK_HEIGHT, 0, Terrain.Ground.SAND),
		"the overhead map's sand"
	)
	assert_eq(colors[WorldTextures.LAYERS.find(&"mud")], WorldTextures.MUD_COLOR)
	for layer: int in colors.size():
		assert_gt(colors[layer].get_luminance(), 0.05, "%s is not black" % WorldTextures.LAYERS[layer])
		for other: int in range(layer + 1, colors.size()):
			assert_ne(colors[layer], colors[other], "%s and %s differ" % [WorldTextures.LAYERS[layer], WorldTextures.LAYERS[other]])


func test_the_shader_parses() -> void:
	var shader: Shader = TerrainView.TERRAIN_SHADER
	assert_gt(shader.get_shader_uniform_list().size(), 0, "a shader that fails to parse lists no uniforms")


func test_the_fire_texture_follows_the_fire() -> void:
	var rows: Array[String] = []
	for j: int in 11:
		rows.append("sssss" + ("." if j == 5 else "s") + "sssss")
	var world: World = World.new(1, TestTerrains.from_ascii(rows), TestTerrains.catalog())
	var view: TerrainView = _view_of(world.terrain)
	assert_eq(view.fire_texel(5, 5), TerrainView.FIRE_TEXEL[Fire.Cell.UNBURNT])
	world.ignite(5 * M, 5 * M, 0)
	view.update_fire(world.fire)
	assert_eq(view.fire_texel(5, 5), TerrainView.FIRE_TEXEL[Fire.Cell.BURNING])
	assert_eq(view.fire_texel(4, 5), TerrainView.FIRE_TEXEL[Fire.Cell.UNBURNT])
	for _t: int in Fire.BURN_TICKS[Terrain.Ground.GRASS] + 1:
		world.step()
		view.update_fire(world.fire)
	assert_eq(view.fire_texel(5, 5), TerrainView.FIRE_TEXEL[Fire.Cell.SCORCHED])


func test_the_fire_glow_is_its_own_channel() -> void:
	# The shader filters fire_state between samples. Filtering R alone from
	# unburnt (0) to scorched (255) would pass through "burning" and ring
	# every scorched patch with embers, so G holds the burning cells alone.
	var rows: Array[String] = []
	for j: int in 11:
		rows.append("sssss" + ("." if j == 5 else "s") + "sssss")
	var world: World = World.new(1, TestTerrains.from_ascii(rows), TestTerrains.catalog())
	var view: TerrainView = _view_of(world.terrain)
	world.ignite(5 * M, 5 * M, 0)
	view.update_fire(world.fire)
	assert_eq(view.fire_glow_texel(5, 5), 255, "burning")
	assert_eq(view.fire_glow_texel(4, 5), 0, "unburnt")
	for _t: int in Fire.BURN_TICKS[Terrain.Ground.GRASS] + 1:
		world.step()
		view.update_fire(world.fire)
	assert_eq(view.fire_texel(5, 5), TerrainView.FIRE_TEXEL[Fire.Cell.SCORCHED])
	assert_eq(view.fire_glow_texel(5, 5), 0, "scorched no longer glows")


func test_dry_samples_carry_the_shallow_water_color() -> void:
	# The shader filters water_tint between samples. A dry texel is the
	# shallow water's color at alpha 0, so a bank fades the water out
	# instead of darkening it toward black.
	var terrain: Terrain = TestTerrains.from_ascii(["..12", "..34"] as Array[String])
	var image: Image = (_view_of(terrain).shader_parameter(&"water_tint") as ImageTexture).get_image()
	var shallow: Color = TerrainPalette.water_color(1)
	var dry: Color = image.get_pixel(0, 0)
	assert_eq(dry.a8, 0, "no tint on dry ground")
	assert_eq(Color(dry.r, dry.g, dry.b).to_rgba32(), Color(shallow.r, shallow.g, shallow.b).to_rgba32())
	for depth: int in range(1, Terrain.MAX_WATER_DEPTH + 1):
		var at: Vector2i = Vector2i(2 + (depth - 1) % 2, (depth - 1) / 2)
		assert_eq(image.get_pixel(at.x, at.y).to_rgba32(), TerrainPalette.water_color(depth).to_rgba32(), "depth %d" % depth)


func test_the_weather_reaches_the_shader() -> void:
	var world: World = World.new(1, _terrain(), TestTerrains.catalog())
	var view: TerrainView = _view_of(world.terrain)
	assert_eq(_material(view).get_shader_parameter("wetness"), 0.0)
	world.weather.wetness_ppm = 400_000
	world.weather.snow_cover_ppm = 750_000
	view.set_weather(world.weather)
	assert_almost_eq(_material(view).get_shader_parameter("wetness") as float, 0.4, 0.0001)
	assert_almost_eq(_material(view).get_shader_parameter("snow_cover") as float, 0.75, 0.0001)


func test_a_rebuild_keeps_the_fire_and_weather() -> void:
	var world: World = World.new(1, _terrain(), TestTerrains.catalog())
	var view: TerrainView = _view_of(world.terrain)
	world.ignite(10 * M, 10 * M, 0)
	view.update_fire(world.fire)
	view.rebuild_region(world.terrain, world.terrain.scar(72 * M, 12 * M, 2 * M, 300))
	assert_eq(view.fire_texel(10, 10), TerrainView.FIRE_TEXEL[Fire.Cell.BURNING], "the material is shared and kept")


func _material(view: TerrainView) -> ShaderMaterial:
	return _chunk(view, 0, 0).material_override as ShaderMaterial


func test_the_overhead_map_colors_blend_ground_then_water() -> void:
	var t: float = 0.5
	assert_eq(TerrainPalette.ground_color(t, 0, Terrain.Ground.GRASS), TerrainPalette.height_color(t), "grass is the bands")
	var sand: Color = TerrainPalette.ground_tint(Terrain.Ground.SAND)
	assert_eq(
		TerrainPalette.ground_color(t, 0, Terrain.Ground.SAND),
		TerrainPalette.height_color(t).lerp(Color(sand.r, sand.g, sand.b), sand.a)
	)
	var deep: Color = TerrainPalette.water_color(3)
	assert_eq(
		TerrainPalette.ground_color(t, 3, Terrain.Ground.SAND),
		TerrainPalette.ground_color(t, 0, Terrain.Ground.SAND).lerp(Color(deep.r, deep.g, deep.b), deep.a),
		"water over the ground"
	)


func test_a_cell_lit_between_steps_still_shows() -> void:
	# The next step clears fire.changed before the view reads it, so a cell
	# lit outside a step (a test, a debug tool) is caught by the count.
	var rows: Array[String] = []
	for j: int in 11:
		rows.append("sssss" + ("." if j == 5 else "s") + "sssss")
	var world: World = World.new(1, TestTerrains.from_ascii(rows), TestTerrains.catalog())
	var view: TerrainView = _view_of(world.terrain)
	world.ignite(5 * M, 5 * M, 0)
	world.step()
	view.update_fire(world.fire)
	assert_eq(view.fire_texel(5, 5), TerrainView.FIRE_TEXEL[Fire.Cell.BURNING])


func test_trails_are_baked_and_reach_the_shader() -> void:
	var record: TrailRecord = TrailRecord.new()
	record.points_m = PackedVector2Array([Vector2(10, 20), Vector2(120, 40)])
	record.width_m = 3.4
	var trails: MapTrails = MapTrails.new()
	trails.records = [record]
	var view: TerrainView = TerrainView.new()
	add_child_autofree(view)
	view.build(_terrain(), null, trails)
	var mask: TrailMask = view.trail_mask()
	assert_false(mask.is_empty())
	assert_gt(mask.wear_at(65.0, 30.0), 0.9, "worn along the route")
	var declared: Array[String] = []
	for uniform: Dictionary in _material(view).shader.get_shader_uniform_list():
		declared.append(uniform["name"])
	for knob: String in [
		"trail_mask", "trail_origin", "trail_size", "trail_strength", "trail_edge_low", "trail_edge_high",
		"trail_breakup", "trail_noise_m", "trail_sand", "trail_tint", "trail_rut_dark",
	]:
		assert_has(declared, knob)
	assert_same(view.shader_parameter(&"trail_mask"), mask.texture())
	assert_eq(view.shader_parameter(&"trail_origin"), mask.origin_m())
	assert_eq(view.shader_parameter(&"trail_size"), mask.size_m())


func test_without_trails_the_mask_is_empty() -> void:
	var view: TerrainView = _view_of(_terrain())
	assert_true(view.trail_mask().is_empty())
	assert_not_null(view.shader_parameter(&"trail_mask"), "the shader still gets a (clear) texture")


func test_the_shore_is_weighted_out_to_its_reach() -> void:
	# B's alpha: how near the water a sample is, for sand to show only on the
	# banks (the mostly-grass palette).
	var terrain: Terrain = TestTerrains.from_ascii(["1.........", "1.........", "1........."] as Array[String])
	var b: Image = _weights(_view_of(terrain), &"ground_weights_b")
	assert_eq(b.get_pixel(0, 1).a8, 255, "the water itself")
	assert_gt(b.get_pixel(4, 1).a8, 0, "4 m up the bank")
	assert_gt(b.get_pixel(2, 1).a8, b.get_pixel(4, 1).a8, "more nearer the water")
	assert_eq(b.get_pixel(int(TerrainView.SHORE_REACH_M) + 1, 1).a8, 0, "none past the reach")


func test_the_mostly_grass_knobs_are_uniforms() -> void:
	var declared: Array[String] = []
	for uniform: Dictionary in _material(_view_of(_terrain())).shader.get_shader_uniform_list():
		declared.append(uniform["name"])
	for knob: String in [
		"grass_tint", "brush_tint", "brush_detail", "forest_tint", "forest_detail", "undergrowth_tint",
		"dry_tint", "sand_shore_low", "sand_shore_high", "sand_shore_share", "rock_flat", "rock_grass_tint", "bed_tint",
	]:
		assert_has(declared, knob)
