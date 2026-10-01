extends GutTest
## PrecipitationView: clear weather draws nothing, rain and snow each show a
## share of their instances that follows their own intensity, the wind reaches
## the shaders in m/s, and the box around the camera focus follows it. The
## shaders themselves can't be checked headless (the dummy renderer compiles
## nothing); what a drop does on screen was checked by eye.

const MAP_SIZE: int = 120

var _world: World
var _camera: RtsCamera
var _view: PrecipitationView


func before_each() -> void:
	_world = World.new(1, TestTerrains.flat(MAP_SIZE, MAP_SIZE), TestTerrains.catalog())
	_camera = RtsCamera.new()
	add_child_autofree(_camera)
	_camera.setup(_world.terrain)
	_camera.set_pose(Vector2(60.0, 60.0), 0.0, 40.0)
	_view = PrecipitationView.new()
	add_child_autofree(_view)
	_view.setup(_world, _camera)


func _rain_node() -> MultiMeshInstance3D:
	return _view.get_node("Rain") as MultiMeshInstance3D


func _snow_node() -> MultiMeshInstance3D:
	return _view.get_node("Snow") as MultiMeshInstance3D


# Sets the weather outright, as the sim would have it at some tick, and lets
# the view read it.
func _set_weather(rain: int, snow: int, wind_x: int = 0, wind_z: int = 0) -> void:
	_world.weather.rain = rain
	_world.weather.snow = snow
	_world.weather.wind_x = wind_x
	_world.weather.wind_z = wind_z
	_view._process(0.0)


func _param(node: MultiMeshInstance3D, uniform: StringName) -> Variant:
	return (node.material_override as ShaderMaterial).get_shader_parameter(uniform)


# --- pure helpers ---


func test_visible_count_scales_with_intensity() -> void:
	assert_eq(PrecipitationView.visible_count(6000, 0), 0)
	assert_eq(PrecipitationView.visible_count(6000, 500), 3000)
	assert_eq(PrecipitationView.visible_count(6000, 1000), 6000)
	assert_eq(PrecipitationView.visible_count(4000, 250), 1000)


func test_visible_count_rounds_down_and_clamps() -> void:
	assert_eq(PrecipitationView.visible_count(4000, 1), 4, "1 permille of 4000")
	assert_eq(PrecipitationView.visible_count(100, 9), 0, "under one instance's share is none")
	assert_eq(PrecipitationView.visible_count(6000, -50), 0, "negative intensity")
	assert_eq(PrecipitationView.visible_count(6000, 4000), 6000, "never more than the max")


func test_instance_buffer_places_every_drop_in_the_box() -> void:
	var count: int = 2000
	var buffer: PackedFloat32Array = PrecipitationView.instance_buffer(count, 5)
	assert_eq(buffer.size(), count * PrecipitationView.INSTANCE_FLOATS)
	var sums: Array[float] = [0.0, 0.0, 0.0, 0.0]
	for n: int in count:
		var at: int = n * PrecipitationView.INSTANCE_FLOATS
		assert_eq(buffer[at], 1.0, "identity transform")
		assert_eq(buffer[at + 5], 1.0)
		assert_eq(buffer[at + 10], 1.0)
		for axis: int in 4:
			var value: float = buffer[at + 12 + axis]
			assert_true(value >= 0.0 and value < 1.0, "custom %d of %d in 0..1: %f" % [axis, n, value])
			sums[axis] += value
	for axis: int in 4:
		assert_almost_eq(sums[axis] / count, 0.5, 0.05, "custom %d is spread over the range" % axis)


func test_instance_buffer_is_the_same_for_the_same_seed_only() -> void:
	assert_eq(PrecipitationView.instance_buffer(50, 3), PrecipitationView.instance_buffer(50, 3))
	assert_ne(PrecipitationView.instance_buffer(50, 3), PrecipitationView.instance_buffer(50, 4))


# --- the view ---


func test_clear_weather_draws_nothing() -> void:
	assert_eq(_view.rain_count(), 0)
	assert_eq(_view.snow_count(), 0)
	assert_false(_rain_node().visible, "rain hidden")
	assert_false(_snow_node().visible, "snow hidden")


func test_every_layer_is_allocated_up_front() -> void:
	assert_eq(_rain_node().multimesh.instance_count, PrecipitationView.RAIN_MAX)
	assert_eq(_snow_node().multimesh.instance_count, PrecipitationView.SNOW_MAX)
	assert_true(_rain_node().multimesh.use_custom_data)
	assert_not_null((_rain_node().material_override as ShaderMaterial).shader)
	assert_true(_param(_snow_node(), &"snow") as bool, "the snow layer is the flake look")
	assert_false(_param(_rain_node(), &"snow") as bool)


func test_rain_count_follows_intensity() -> void:
	_set_weather(0, 0)
	assert_eq(_view.rain_count(), 0)
	assert_false(_rain_node().visible)
	_set_weather(500, 0)
	assert_eq(_view.rain_count(), roundi(PrecipitationView.RAIN_MAX * 0.5))
	assert_true(_rain_node().visible)
	_set_weather(1000, 0)
	assert_eq(_view.rain_count(), PrecipitationView.RAIN_MAX)
	_set_weather(0, 0)
	assert_eq(_view.rain_count(), 0, "and back to nothing")
	assert_false(_rain_node().visible)


func test_snow_count_follows_intensity() -> void:
	_set_weather(0, 500)
	assert_eq(_view.snow_count(), roundi(PrecipitationView.SNOW_MAX * 0.5))
	assert_true(_snow_node().visible)
	_set_weather(0, 1000)
	assert_eq(_view.snow_count(), PrecipitationView.SNOW_MAX)
	_set_weather(0, 0)
	assert_eq(_view.snow_count(), 0)
	assert_false(_snow_node().visible)


func test_rain_and_snow_are_independent() -> void:
	_set_weather(1000, 0)
	assert_eq(_view.rain_count(), PrecipitationView.RAIN_MAX)
	assert_eq(_view.snow_count(), 0, "rain alone leaves the snow out")
	assert_false(_snow_node().visible)
	_set_weather(0, 1000)
	assert_eq(_view.rain_count(), 0, "snow alone leaves the rain out")
	assert_false(_rain_node().visible)
	assert_eq(_view.snow_count(), PrecipitationView.SNOW_MAX)
	_set_weather(300, 800)
	assert_eq(_view.rain_count(), PrecipitationView.visible_count(PrecipitationView.RAIN_MAX, 300))
	assert_eq(_view.snow_count(), PrecipitationView.visible_count(PrecipitationView.SNOW_MAX, 800))


func test_sim_weather_reaches_the_view() -> void:
	# Through the sim's own command and ramp, not set by hand.
	_world.enqueue(SetWeatherCommand.new(_world.tick, 800, 0, 2000, 0, 0))
	_world.step()
	_view._process(0.0)
	assert_eq(_view.rain_count(), PrecipitationView.visible_count(PrecipitationView.RAIN_MAX, 800))
	assert_eq(_view.snow_count(), 0)


func test_wind_reaches_the_shaders_in_meters_per_second() -> void:
	_set_weather(600, 600, 4500, -2500)
	assert_eq(_view.wind(), Vector2(4.5, -2.5))
	assert_eq(_param(_rain_node(), &"wind"), Vector2(4.5, -2.5), "rain uniform")
	assert_eq(_param(_snow_node(), &"wind"), Vector2(4.5, -2.5), "snow uniform")


func test_calm_air_gives_no_wind() -> void:
	_set_weather(600, 0)
	assert_eq(_view.wind(), Vector2.ZERO)


func test_drift_adds_up_the_wind_over_time() -> void:
	_set_weather(1000, 1000, 5000, -2000)
	_view._process(2.0)
	# 5 m/s for 2 s along x. -2 m/s for 2 s along z is -4 m, which is 56 m
	# into the next repeat of the 60 m box.
	assert_eq(_param(_rain_node(), &"drift"), Vector2(10.0, 56.0), "rain drift")
	assert_eq(_param(_snow_node(), &"drift"), Vector2(10.0, 56.0), "snow drift")


func test_drift_holds_when_the_wind_drops() -> void:
	_set_weather(1000, 0, 5000, 0)
	_view._process(2.0)
	_set_weather(1000, 0, 0, 0)
	_view._process(30.0)
	assert_eq(_param(_rain_node(), &"drift"), Vector2(10.0, 0.0), "calm air carries nothing further")


func test_drift_stays_inside_one_box() -> void:
	_set_weather(1000, 0, 30000, 0)
	# 90 m of drift in a 60 m box is 30 m.
	_view._process(3.0)
	assert_almost_eq((_param(_rain_node(), &"drift") as Vector2).x, 30.0, 0.001)


func test_box_stands_on_the_camera_focus() -> void:
	_set_weather(1000, 1000)
	var half_x: float = PrecipitationView.BOX_SIZE.x * 0.5
	var half_z: float = PrecipitationView.BOX_SIZE.z * 0.5
	var focus: Vector3 = _camera.focus
	var origin: Vector3 = _view.box_origin()
	assert_almost_eq(origin.x, focus.x - half_x, 0.001, "centered on the focus in x")
	assert_almost_eq(origin.z, focus.z - half_z, 0.001, "and in z")
	assert_almost_eq(origin.y, focus.y - PrecipitationView.BOX_BELOW, 0.001, "reaching a little below the ground")


func test_box_follows_the_camera_when_it_moves() -> void:
	_set_weather(1000, 1000)
	_camera.set_pose(Vector2(25.0, 90.0), 0.0, 40.0)
	_view._process(0.0)
	var focus: Vector3 = _camera.focus
	assert_eq(focus.x, 25.0, "the camera did move")
	var expected: Vector3 = Vector3(
		focus.x - PrecipitationView.BOX_SIZE.x * 0.5,
		focus.y - PrecipitationView.BOX_BELOW,
		focus.z - PrecipitationView.BOX_SIZE.z * 0.5
	)
	assert_eq(_view.box_origin(), expected)
	assert_eq(_param(_rain_node(), &"box_origin"), expected, "rain shader")
	assert_eq(_param(_snow_node(), &"box_origin"), expected, "snow shader")


func test_culling_box_covers_the_weather_box() -> void:
	_set_weather(1000, 1000)
	_camera.set_pose(Vector2(25.0, 90.0), 0.0, 40.0)
	_view._process(0.0)
	var weather_box: AABB = AABB(_view.box_origin(), PrecipitationView.BOX_SIZE)
	assert_true(_rain_node().multimesh.custom_aabb.encloses(weather_box), "rain not culled while its box is in view")
	assert_true(_snow_node().multimesh.custom_aabb.encloses(weather_box), "snow likewise")


func test_instances_are_top_level_so_the_view_may_sit_anywhere() -> void:
	assert_true(_rain_node().top_level)
	assert_true(_snow_node().top_level)


func test_setup_again_replaces_the_layers() -> void:
	_set_weather(1000, 1000)
	_view.setup(_world, _camera)
	# The old nodes are freed at the end of the frame; what counts is that the
	# view answers for the new ones.
	assert_eq(_view.rain_count(), PrecipitationView.RAIN_MAX)
	await get_tree().process_frame
	assert_eq(_view.get_child_count(), 2, "one rain layer and one snow layer")
