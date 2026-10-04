extends GutTest
## PrecipitationView's ash (Phase 8): a third kind of fall, set by a mission's
## Atmosphere and never by the sim. Its layer is made only when there is ash,
## so a world without any has the rain and snow layers it always had; its
## count follows ash_fall like rain follows its intensity; it is independent
## of the sim's snow; and it survives the view being set up again.

const MAP_SIZE: int = 80
## Half the ash instances: what an ash fall of 0.5 shows.
const HALF: int = PrecipitationView.ASH_MAX >> 1

var _world: World
var _camera: RtsCamera
var _view: PrecipitationView


func before_each() -> void:
	_world = World.new(1, TestTerrains.flat(MAP_SIZE, MAP_SIZE), TestTerrains.catalog())
	_camera = RtsCamera.new()
	add_child_autofree(_camera)
	_camera.setup(_world.terrain)
	_view = PrecipitationView.new()
	add_child_autofree(_view)
	_view.setup(_world, _camera)


func _ash_node() -> MultiMeshInstance3D:
	return _view.get_node_or_null("Ash") as MultiMeshInstance3D


func test_with_no_ash_there_is_no_ash_layer() -> void:
	assert_eq(_view.ash_count(), 0)
	assert_null(_ash_node())
	assert_eq(_view.get_child_count(), 2, "rain and snow, as before")


func test_ash_shows_a_share_of_its_instances() -> void:
	_view.set_ash(0.5, Color(0.3, 0.26, 0.24))
	assert_eq(_view.ash_count(), HALF)
	assert_true(_ash_node().visible)
	_view.set_ash(1.0, Color(0.3, 0.26, 0.24))
	assert_eq(_view.ash_count(), PrecipitationView.ASH_MAX)


func test_no_ash_hides_the_layer_again() -> void:
	_view.set_ash(0.6, Color.GRAY)
	_view.set_ash(0.0, Color.GRAY)
	assert_eq(_view.ash_count(), 0)
	assert_false(_ash_node().visible)


func test_ash_is_clamped_to_0_to_1() -> void:
	_view.set_ash(3.0, Color.GRAY)
	assert_eq(_view.ash_count(), PrecipitationView.ASH_MAX)
	_view.set_ash(-1.0, Color.GRAY)
	assert_eq(_view.ash_count(), 0)


func test_ash_has_its_own_color() -> void:
	_view.set_ash(0.4, Color(0.3, 0.26, 0.24))
	var material: ShaderMaterial = _ash_node().material_override as ShaderMaterial
	assert_eq(material.get_shader_parameter("tint"), Color(0.3, 0.26, 0.24))
	_view.set_ash(0.4, Color(0.5, 0.5, 0.5))
	assert_eq(material.get_shader_parameter("tint"), Color(0.5, 0.5, 0.5), "a new color reaches the same layer")


func test_ash_is_not_snow() -> void:
	_view.set_ash(0.6, Color.GRAY)
	assert_eq(_view.snow_count(), 0, "the sim's snow is untouched")
	assert_eq(_view.rain_count(), 0)
	_world.weather.snow = 1000
	_view._process(0.0)
	assert_eq(_view.snow_count(), PrecipitationView.SNOW_MAX)
	assert_eq(_view.ash_count(), PrecipitationView.visible_count(PrecipitationView.ASH_MAX, 600), "and so is the ash")


func test_ash_falls_whatever_the_weather() -> void:
	_world.weather.rain = 0
	_world.weather.snow = 0
	_view.set_ash(0.6, Color.GRAY)
	_view._process(0.0)
	assert_gt(_view.ash_count(), 0, "in clear weather")


func test_ash_set_before_setup_survives_it() -> void:
	var fresh: PrecipitationView = PrecipitationView.new()
	add_child_autofree(fresh)
	fresh.set_ash(0.5, Color.GRAY)
	assert_eq(fresh.ash_count(), 0, "nothing to draw it on yet")
	fresh.setup(_world, _camera)
	assert_eq(fresh.ash_count(), HALF)


func test_setup_again_keeps_the_ash() -> void:
	_view.set_ash(0.5, Color.GRAY)
	_view.setup(_world, _camera)
	assert_eq(_view.ash_count(), HALF)
	await get_tree().process_frame
	assert_eq(_view.get_child_count(), 3, "rain, snow, and ash, once each")


func test_the_ash_layer_is_top_level_like_the_others() -> void:
	_view.set_ash(0.5, Color.GRAY)
	assert_true(_ash_node().top_level)
