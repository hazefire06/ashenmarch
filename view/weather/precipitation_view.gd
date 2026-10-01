class_name PrecipitationView
extends Node3D
## Rain and snow falling around the camera's focus, drawn from the World's
## weather. Reads the World; never writes it. MainView calls setup() once and
## the view updates itself every frame: the weather only changes once per
## tick, but reading it per frame costs nothing and keeps the wind smooth.
##
## Each of the two kinds is one MultiMeshInstance3D of RAIN_MAX or SNOW_MAX
## quads that precipitation.gdshader moves on the GPU (the "thousands of
## fish" pattern; no particle nodes, which the Compatibility renderer on Web
## handles poorly). Every instance is given a random place in a box and a
## random phase once, here, and never touched again. Intensity (permille) then
## only picks how many of them are drawn: more rain just reveals more of the
## same drops.
##
## The box is BOX_SIZE meters, centered on the camera's focus horizontally and
## standing on the ground there. The shader wraps drops in world space, so
## moving the camera slides the box over weather that stays where it is.
## Wind is passed in m/s for the tilt of the rain, and its drift is
## integrated here, because TIME times a changing wind would jerk every drop.
##
## View-side randomness (the placement) is fine: nothing here is sim state.
## The instance nodes are top-level, so wherever this node sits they are in
## world space, which is what the shader assumes.

const SHADER: Shader = preload("res://view/weather/precipitation.gdshader")
## Most instances of each kind, shown at full intensity (1000 permille).
const RAIN_MAX: int = 6000
const SNOW_MAX: int = 4000
## The box around the camera focus, meters: x and z wide, y tall.
const BOX_SIZE: Vector3 = Vector3(60.0, 30.0, 60.0)
## How far the box reaches below the focus, so drops land in the ground
## instead of ending in the air above it.
const BOX_BELOW: float = 3.0
## Meters per second, straight down. Each drop is up to 25% off.
const RAIN_FALL_SPEED: float = 9.0
const SNOW_FALL_SPEED: float = 1.2
const RAIN_COLOR: Color = Color(0.72, 0.8, 0.92, 0.5)
const SNOW_COLOR: Color = Color(1.0, 1.0, 1.0, 0.9)
## A rain streak's width and length, and a flake's size (in x), meters, up
## close. Farther away the shader keeps them a few pixels big.
const RAIN_SIZE: Vector2 = Vector2(0.03, 0.9)
const SNOW_SIZE: Vector2 = Vector2(0.07, 0.07)
## Seeds for where the instances sit: fixed, so the weather looks the same
## every run, and different so the rain and the snow aren't the same lattice.
const RAIN_SEED: int = 1
const SNOW_SEED: int = 2
## Floats per instance in the MultiMesh buffer: a 3x4 transform, then custom
## data (a vec4).
const INSTANCE_FLOATS: int = 16

var _world: World
var _camera: RtsCamera
var _rain: MultiMeshInstance3D
var _snow: MultiMeshInstance3D
## Wind, m/s, as last read from the weather.
var _wind: Vector2 = Vector2.ZERO
## Meters the wind has carried everything, kept in 0..BOX_SIZE since the
## pattern repeats every box.
var _drift: Vector2 = Vector2.ZERO
var _box_origin: Vector3 = Vector3.ZERO


## Starts following the world's weather and the camera's focus. Replaces what
## a previous setup made.
func setup(world: World, camera: RtsCamera) -> void:
	_world = world
	_camera = camera
	for child: Node in get_children():
		remove_child(child)
		child.queue_free()
	_rain = _make_layer("Rain", RAIN_MAX, RAIN_SEED, false)
	_snow = _make_layer("Snow", SNOW_MAX, SNOW_SEED, true)
	_update(0.0)


## How many of max_count instances show at this intensity (permille, 0..1000;
## out-of-range values are clamped). Rounds down, so anything below one
## instance's share is none.
static func visible_count(max_count: int, intensity_permille: int) -> int:
	return floori(max_count * clampi(intensity_permille, 0, 1000) / 1000.0)


## The MultiMesh buffer for count instances: every one an identity transform
## (the shader ignores it, but it must be a valid one) with INSTANCE_CUSTOM
## set to a random place in the box (xyz, each 0..1) and a random phase (w,
## 0..1). The same seed gives the same weather.
static func instance_buffer(count: int, rng_seed: int) -> PackedFloat32Array:
	var rng: RandomNumberGenerator = RandomNumberGenerator.new()
	rng.seed = rng_seed
	# Zero-filled, so every origin is 0.
	var buffer: PackedFloat32Array = PackedFloat32Array()
	buffer.resize(count * INSTANCE_FLOATS)
	for n: int in count:
		var at: int = n * INSTANCE_FLOATS
		buffer[at] = 1.0
		buffer[at + 5] = 1.0
		buffer[at + 10] = 1.0
		for axis: int in 4:
			buffer[at + 12 + axis] = rng.randf()
	return buffer


## Rain streaks currently drawn.
func rain_count() -> int:
	return _rain.multimesh.visible_instance_count


## Snow flakes currently drawn.
func snow_count() -> int:
	return _snow.multimesh.visible_instance_count


## The wind the shader is given, m/s along x and z.
func wind() -> Vector2:
	return _wind


## The lowest corner of the box, world meters. Its x and z are half a box
## either side of the camera's focus.
func box_origin() -> Vector3:
	return _box_origin


func _process(delta: float) -> void:
	_update(delta)


# Reads the weather and the camera, and hands the shaders what they need.
func _update(delta: float) -> void:
	if _world == null:
		return
	var weather: Weather = _world.weather
	_wind = Vector2(weather.wind_x, weather.wind_z) / float(World.UNITS_PER_METER)
	_drift = Vector2(
		fposmod(_drift.x + _wind.x * delta, BOX_SIZE.x),
		fposmod(_drift.y + _wind.y * delta, BOX_SIZE.z)
	)
	if _camera != null:
		var focus: Vector3 = _camera.focus
		_box_origin = Vector3(focus.x - BOX_SIZE.x * 0.5, focus.y - BOX_BELOW, focus.z - BOX_SIZE.z * 0.5)
	_update_layer(_rain, RAIN_MAX, weather.rain)
	_update_layer(_snow, SNOW_MAX, weather.snow)


# Shows the share of a layer that the intensity calls for, hiding the whole
# node at zero, and keeps its shader and culling box on the weather and the
# camera.
func _update_layer(layer: MultiMeshInstance3D, max_count: int, intensity: int) -> void:
	var count: int = visible_count(max_count, intensity)
	layer.multimesh.visible_instance_count = count
	layer.visible = count > 0
	if count == 0:
		return
	var material: ShaderMaterial = layer.material_override as ShaderMaterial
	material.set_shader_parameter("box_origin", _box_origin)
	material.set_shader_parameter("wind", _wind)
	material.set_shader_parameter("drift", _drift)
	# The shader places everything itself, so the instances' own bounds are
	# meaningless. Streaks stick out of the box a little at its faces.
	layer.multimesh.custom_aabb = AABB(_box_origin - Vector3.ONE * 2.0, BOX_SIZE + Vector3.ONE * 4.0)


# One kind of precipitation: count instances, none showing yet.
func _make_layer(
	layer_name: String, count: int, rng_seed: int, is_snow: bool
) -> MultiMeshInstance3D:
	var quad: QuadMesh = QuadMesh.new()
	quad.size = Vector2.ONE
	var multimesh: MultiMesh = MultiMesh.new()
	multimesh.transform_format = MultiMesh.TRANSFORM_3D
	# Both are set while there are no instances: they can't change after.
	multimesh.use_custom_data = true
	multimesh.mesh = quad
	multimesh.instance_count = count
	multimesh.buffer = instance_buffer(count, rng_seed)
	multimesh.visible_instance_count = 0
	var material: ShaderMaterial = ShaderMaterial.new()
	material.shader = SHADER
	material.set_shader_parameter("snow", is_snow)
	material.set_shader_parameter("box_size", BOX_SIZE)
	material.set_shader_parameter("fall_speed", SNOW_FALL_SPEED if is_snow else RAIN_FALL_SPEED)
	material.set_shader_parameter("tint", SNOW_COLOR if is_snow else RAIN_COLOR)
	material.set_shader_parameter("size", SNOW_SIZE if is_snow else RAIN_SIZE)
	var layer: MultiMeshInstance3D = MultiMeshInstance3D.new()
	layer.name = layer_name
	layer.multimesh = multimesh
	layer.material_override = material
	layer.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	layer.top_level = true
	layer.visible = false
	add_child(layer)
	return layer
