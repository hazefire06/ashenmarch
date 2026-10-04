extends GutTest
## AtmosphereView: applies an Atmosphere to the scene that draws it, the sky
## and ambient light and fog on the WorldEnvironment, the sun's color, energy,
## and rotation, the ground and water grade on the terrain shader, and the ash
## fall. The default Atmosphere reproduces the look main.tscn has on its own, so
## a mission with none leaves the scene as it was. What the shader does with its
## parameters can't be checked headless (the dummy renderer compiles nothing); it
## was checked by eye (see the Phase 8 captures).

var _environment: WorldEnvironment
var _sun: DirectionalLight3D
var _terrain: TerrainView
var _precipitation: PrecipitationView
var _view: AtmosphereView


func before_each() -> void:
	_environment = WorldEnvironment.new()
	_environment.environment = Environment.new()
	add_child_autofree(_environment)
	_sun = DirectionalLight3D.new()
	add_child_autofree(_sun)
	_terrain = TerrainView.new()
	add_child_autofree(_terrain)
	_terrain.build(TestTerrains.flat(40, 40))
	var world: World = World.new(1, TestTerrains.flat(40, 40), TestTerrains.catalog())
	var camera: RtsCamera = RtsCamera.new()
	add_child_autofree(camera)
	camera.setup(world.terrain)
	_precipitation = PrecipitationView.new()
	add_child_autofree(_precipitation)
	_precipitation.setup(world, camera)
	_view = AtmosphereView.new(_environment, _sun, _terrain, _precipitation)


func _look() -> Atmosphere:
	var a: Atmosphere = Atmosphere.new()
	a.background_color = Color(0.42, 0.2, 0.1)
	a.ambient_color = Color(0.45, 0.28, 0.22)
	a.ambient_energy = 0.32
	a.sun_color = Color(1.0, 0.55, 0.25)
	a.sun_energy = 0.75
	a.sun_pitch_degrees = -12.0
	a.sun_yaw_degrees = 40.0
	a.fog_enabled = true
	a.fog_color = Color(0.38, 0.18, 0.1)
	a.fog_density = 0.014
	a.terrain_tint = Color(0.85, 0.65, 0.55)
	a.terrain_desaturation = 0.55
	a.ground_recolor = [
		Color(0.16, 0.1, 0.07, 0.6), Color(0.1, 0.06, 0.04, 0.65), Color(0.08, 0.05, 0.04, 0.6),
		Color(0.28, 0.2, 0.15, 0.4), Color(0.2, 0.15, 0.13, 0.3),
	]
	a.water_tint = Color(0.03, 0.02, 0.03, 0.85)
	a.ash_fall = 0.6
	a.ash_color = Color(0.3, 0.26, 0.24)
	return a


func test_it_sets_the_sky_and_ambient_light() -> void:
	_view.apply(_look())
	var environment: Environment = _environment.environment
	assert_eq(environment.background_mode, Environment.BG_COLOR)
	assert_eq(environment.background_color, Color(0.42, 0.2, 0.1))
	assert_eq(environment.ambient_light_source, Environment.AMBIENT_SOURCE_COLOR)
	assert_eq(environment.ambient_light_color, Color(0.45, 0.28, 0.22))
	assert_almost_eq(environment.ambient_light_energy, 0.32, 0.00001)


func test_it_sets_the_fog() -> void:
	_view.apply(_look())
	var environment: Environment = _environment.environment
	assert_true(environment.fog_enabled)
	assert_eq(environment.fog_mode, Environment.FOG_MODE_EXPONENTIAL, "depth fog, which Compatibility draws")
	assert_eq(environment.fog_light_color, Color(0.38, 0.18, 0.1))
	assert_almost_eq(environment.fog_density, 0.014, 0.00001)


func test_a_look_without_fog_turns_it_off() -> void:
	_view.apply(_look())
	_view.apply(Atmosphere.new())
	assert_false(_environment.environment.fog_enabled)


func test_it_sets_the_sun() -> void:
	_view.apply(_look())
	assert_eq(_sun.light_color, Color(1.0, 0.55, 0.25))
	assert_almost_eq(_sun.light_energy, 0.75, 0.00001)
	assert_almost_eq(_sun.rotation_degrees.x, -12.0, 0.001, "pitch")
	assert_almost_eq(_sun.rotation_degrees.y, 40.0, 0.001, "yaw")
	assert_almost_eq(_sun.rotation_degrees.z, 0.0, 0.001)


func test_the_sun_shines_down_the_way_its_pitch_says() -> void:
	var a: Atmosphere = Atmosphere.new()
	a.sun_pitch_degrees = -90.0
	_view.apply(a)
	# A DirectionalLight3D shines along its -z axis.
	var direction: Vector3 = -_sun.global_transform.basis.z
	assert_almost_eq(direction.y, -1.0, 0.0001, "straight down")
	a.sun_pitch_degrees = 0.0
	_view.apply(a)
	assert_almost_eq((-_sun.global_transform.basis.z).y, 0.0, 0.0001, "along the ground")


func test_it_grades_the_terrain() -> void:
	_view.apply(_look())
	assert_eq(_terrain.shader_parameter(&"grade_tint"), Color(0.85, 0.65, 0.55))
	assert_eq(_terrain.shader_parameter(&"grade_desaturation"), 0.55)
	assert_eq(_terrain.shader_parameter(&"water_grade"), Color(0.03, 0.02, 0.03, 0.85))
	var recolor: PackedColorArray = _terrain.shader_parameter(&"ground_recolor")
	assert_eq(recolor.size(), Terrain.GROUND_COUNT)
	assert_eq(recolor[Terrain.Ground.BRUSH], Color(0.1, 0.06, 0.04, 0.65))
	assert_eq(recolor[Terrain.Ground.ROCK], Color(0.2, 0.15, 0.13, 0.3))


func test_it_starts_the_ash() -> void:
	assert_eq(_precipitation.ash_count(), 0)
	_view.apply(_look())
	assert_eq(_precipitation.ash_count(), PrecipitationView.visible_count(PrecipitationView.ASH_MAX, 600))


func test_applying_the_default_look_puts_the_scene_back() -> void:
	_view.apply(_look())
	_view.apply(Atmosphere.new())
	var environment: Environment = _environment.environment
	var fresh: Atmosphere = Atmosphere.new()
	assert_eq(environment.background_color, fresh.background_color)
	assert_eq(environment.ambient_light_energy, fresh.ambient_energy)
	assert_eq(_sun.light_energy, fresh.sun_energy)
	assert_eq(_terrain.shader_parameter(&"grade_desaturation"), 0.0)
	assert_eq(_precipitation.ash_count(), 0)


func test_a_null_atmosphere_changes_nothing() -> void:
	_view.apply(_look())
	_view.apply(null)
	assert_eq(_environment.environment.background_color, Color(0.42, 0.2, 0.1))
	assert_almost_eq(_sun.light_energy, 0.75, 0.00001)


func test_a_scene_without_an_environment_gets_one() -> void:
	_environment.environment = null
	_view.apply(_look())
	assert_not_null(_environment.environment)
	assert_eq(_environment.environment.background_color, Color(0.42, 0.2, 0.1))


func test_it_works_with_only_some_of_the_scene() -> void:
	var sky_only: AtmosphereView = AtmosphereView.new(_environment, null, null, null)
	sky_only.apply(_look())
	assert_eq(_environment.environment.background_color, Color(0.42, 0.2, 0.1))
	var nothing: AtmosphereView = AtmosphereView.new(null, null, null, null)
	nothing.apply(_look())
	pass_test("no node, no crash")


func test_the_shipped_atmospheres_apply() -> void:
	for path: String in [
		"res://data/atmospheres/riverside.tres", "res://data/atmospheres/the_ford.tres",
		"res://data/atmospheres/old_mill.tres",
	]:
		var atmosphere: Atmosphere = load(path) as Atmosphere
		assert_eq(atmosphere.validate(), PackedStringArray(), path)
		_view.apply(atmosphere)
		assert_eq(_environment.environment.background_color, atmosphere.background_color, path)
		assert_eq(_terrain.shader_parameter(&"grade_desaturation"), atmosphere.terrain_desaturation, path)
		assert_eq(
			_precipitation.ash_count(),
			PrecipitationView.visible_count(PrecipitationView.ASH_MAX, roundi(atmosphere.ash_fall * 1000.0)),
			path
		)
