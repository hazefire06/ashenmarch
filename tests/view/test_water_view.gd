extends GutTest
## WaterView: a translucent surface over the wet samples of a water map, at the
## recorded height, chunked like the terrain. No surface without a water map or
## over a structure; dry corners of shore quads take the nearest wet height.

const M: int = 1000

## A 10 x 3 pool at samples x 2..11, z 2..4 in a 14 x 7 map.
const POOL: Array[String] = [
	"..............",
	"..............",
	"..2222222222..",
	"..2222222222..",
	"..2222222222..",
	"..............",
	"..............",
]


func _water_for(terrain: Terrain, surface: float) -> PackedFloat32Array:
	var water: PackedFloat32Array = PackedFloat32Array()
	water.resize(terrain.size_x * terrain.size_z)
	for k: int in water.size():
		if terrain.water[k] != 0:
			water[k] = surface
	return water


func _view(terrain: Terrain, water: PackedFloat32Array, structures: MapStructures = null) -> WaterView:
	var view: WaterView = WaterView.new()
	add_child_autofree(view)
	view.build(terrain, water, structures)
	return view


## Every vertex of every chunk, keyed by its sample (x, z) in metres.
func _vertices(view: WaterView) -> Dictionary[Vector2i, float]:
	var found: Dictionary[Vector2i, float] = {}
	for child: Node in view.get_children():
		var mesh: ArrayMesh = (child as MeshInstance3D).mesh as ArrayMesh
		for v: Vector3 in mesh.surface_get_arrays(0)[Mesh.ARRAY_VERTEX]:
			found[Vector2i(roundi(v.x), roundi(v.z))] = v.y
	return found


func test_water_covers_every_wet_cell() -> void:
	var terrain: Terrain = TestTerrains.from_ascii(POOL)
	var water: PackedFloat32Array = _water_for(terrain, 0.75)
	var view: WaterView = _view(terrain, water)
	assert_gte(view.cell_count(), 9 * 2, "at least the interior cells")
	var vertices: Dictionary[Vector2i, float] = _vertices(view)
	for k: int in water.size():
		if water[k] == 0.0:
			continue
		var at: Vector2i = Vector2i(k % terrain.size_x, k / terrain.size_x)
		assert_true(vertices.has(at), "a vertex at wet sample %s" % at)
		assert_almost_eq(vertices.get(at, -1.0), water[k], 0.0001, "height at %s" % at)


func test_no_water_without_a_water_map() -> void:
	var terrain: Terrain = TestTerrains.from_ascii(POOL)
	var view: WaterView = _view(terrain, PackedFloat32Array())
	assert_eq(view.cell_count(), 0)
	assert_eq(view.get_child_count(), 0)


func test_no_water_over_a_structure() -> void:
	var terrain: Terrain = TestTerrains.from_ascii(POOL)
	var water: PackedFloat32Array = _water_for(terrain, 0.75)
	var without: int = _view(terrain, water).cell_count()
	var pier: StructureRecord = StructureRecord.new()
	pier.kind = &"house"
	pier.samples = PackedInt32Array([3 * terrain.size_x + 6])
	var structures: MapStructures = MapStructures.new()
	structures.records = [pier]
	var view: WaterView = _view(terrain, water, structures)
	assert_eq(view.cell_count(), without - 4, "the four cells around the sample are gone")
	assert_false(_vertices(view).has(Vector2i(6, 3)), "nothing is drawn at the covered sample")
	assert_true(_vertices(view).has(Vector2i(5, 3)), "water beside it still is")


func test_shoreline_vertices_take_the_nearest_wet_surface() -> void:
	var terrain: Terrain = TestTerrains.from_ascii(POOL)
	var water: PackedFloat32Array = _water_for(terrain, 0.0)
	for k: int in water.size():
		if terrain.water[k] != 0:
			water[k] = 0.3 if k % terrain.size_x < 7 else 0.9
	var vertices: Dictionary[Vector2i, float] = _vertices(_view(terrain, water))
	assert_true(vertices.has(Vector2i(1, 1)), "the dry corner of the edge quad is drawn")
	assert_almost_eq(vertices.get(Vector2i(1, 1), -1.0), 0.3, 0.0001, "west shore")
	assert_almost_eq(vertices.get(Vector2i(12, 5), -1.0), 0.9, 0.0001, "east shore")
	assert_false(vertices.has(Vector2i(0, 0)), "dry ground away from water has none")


func test_water_is_chunked_like_the_terrain() -> void:
	var terrain: Terrain = TestTerrains.flat(150, 70)
	terrain.water[10 * 150 + 10] = 1
	terrain.water[10 * 150 + 140] = 1
	var view: WaterView = _view(terrain, _water_for(terrain, 0.5))
	assert_eq(view.get_child_count(), 2, "only the chunks that hold water get a mesh")
	assert_eq(view.cell_count(), 8)


func test_the_shader_gets_its_inputs() -> void:
	var terrain: Terrain = TestTerrains.from_ascii(POOL)
	var view: WaterView = _view(terrain, _water_for(terrain, 1.0))
	for uniform: StringName in [&"water_grade", &"deep_color", &"shallow_alpha", &"ripple_speed", &"depth_map"]:
		assert_not_null(view.shader_parameter(uniform), String(uniform))
	var shader: Shader = load("res://view/terrain/water.gdshader") as Shader
	var names: Array[String] = []
	for uniform: Dictionary in shader.get_shader_uniform_list():
		names.append(String(uniform["name"]))
	for uniform: String in ["water_grade", "deep_color", "shallow_alpha", "ripple_speed", "depth_map", "detail_noise"]:
		assert_has(names, uniform)


func test_depth_map_is_surface_minus_bed_over_four_metres() -> void:
	var terrain: Terrain = TestTerrains.from_ascii(POOL)
	terrain.heights[3 * terrain.size_x + 5] = -1 * M
	var view: WaterView = _view(terrain, _water_for(terrain, 1.0))
	var depth: Image = (view.shader_parameter(&"depth_map") as ImageTexture).get_image()
	assert_almost_eq(depth.get_pixel(5, 3).r, 0.5, 0.01, "2 m deep")
	assert_almost_eq(depth.get_pixel(6, 3).r, 0.25, 0.01, "1 m deep")
	assert_eq(depth.get_pixel(0, 0).r, 0.0, "dry")


func test_shallow_depths_keep_their_centimetres() -> void:
	# A ford's water is 5 to 20 cm deep. At 8 bits over 4 m a step is 1.6 cm,
	# a sixth of a 10 cm ford, which the shallow fade turned into a grid of
	# cells; half floats keep a shallow depth to well under a millimetre.
	var terrain: Terrain = TestTerrains.from_ascii(POOL)
	var water: PackedFloat32Array = _water_for(terrain, 0.1)
	water[3 * terrain.size_x + 6] = 0.107
	var depth: Image = (_view(terrain, water).shader_parameter(&"depth_map") as ImageTexture).get_image()
	assert_eq(depth.get_format(), Image.FORMAT_RH, "half float, filterable on WebGL2")
	assert_almost_eq(depth.get_pixel(5, 3).r * WaterView.DEPTH_RANGE_M, 0.1, 0.0005)
	assert_almost_eq(depth.get_pixel(6, 3).r * WaterView.DEPTH_RANGE_M, 0.107, 0.0005)


func test_the_water_shader_reads_the_depth_smoothly() -> void:
	var code: String = WaterView.WATER_SHADER.code
	assert_string_contains(code, "depth_spread", "the depth is averaged over a spread of reads, as the terrain's water tint is")
	var ground: String = (load("res://view/terrain/terrain.gdshader") as Shader).code
	assert_string_contains(ground, "NORMAL_MAP = mix(normal_map, FLAT_NORMAL, tint.a)", "the bed's bumps fade under the water tint")


func test_grade_and_rain_reach_the_shader() -> void:
	var terrain: Terrain = TestTerrains.from_ascii(POOL)
	var view: WaterView = _view(terrain, _water_for(terrain, 1.0))
	view.set_grade(Color(0.0, 0.0, 0.0, 0.8))
	assert_eq(view.shader_parameter(&"water_grade"), Color(0.0, 0.0, 0.0, 0.8))
	var calm: float = view.shader_parameter(&"ripple_strength")
	var weather: Weather = Weather.new()
	weather.rain = 1000
	view.set_weather(weather)
	assert_gt(float(view.shader_parameter(&"ripple_strength")), calm, "rain roughens the ripples")
	# A grade set before the next build still applies.
	view.build(terrain, _water_for(terrain, 1.0))
	assert_eq(view.shader_parameter(&"water_grade"), Color(0.0, 0.0, 0.0, 0.8))


func test_the_sky_reaches_the_shader_and_survives_a_build() -> void:
	var terrain: Terrain = TestTerrains.from_ascii(POOL)
	var view: WaterView = _view(terrain, _water_for(terrain, 1.0))
	view.set_sky(Color(0.5, 0.3, 0.2))
	assert_eq(view.shader_parameter(&"sky_color"), Color(0.5, 0.3, 0.2))
	view.build(terrain, _water_for(terrain, 1.0))
	assert_eq(view.shader_parameter(&"sky_color"), Color(0.5, 0.3, 0.2), "kept for the next build")


func test_the_dark_reflective_look_has_its_knobs() -> void:
	var terrain: Terrain = TestTerrains.from_ascii(POOL)
	var view: WaterView = _view(terrain, _water_for(terrain, 1.0))
	var declared: Array[String] = []
	for uniform: Dictionary in WaterView.WATER_SHADER.get_shader_uniform_list():
		declared.append(uniform["name"])
	for knob: String in ["sky_color", "fresnel_strength", "fresnel_power", "fresnel_floor", "sun_specular", "sun_roughness"]:
		assert_has(declared, knob)
	assert_not_null(view.shader_parameter(&"sky_color"), "set from the first build")
	assert_eq(view.shader_parameter(&"deep_color"), WaterView.DEEP_COLOR)
	assert_lt(WaterView.DEEP_COLOR.get_luminance(), 0.08, "deep water is dark")
