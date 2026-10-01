class_name GasCloudsView
extends Node3D
## Draws every gas cloud in the World as a translucent, flattened dome as
## wide as the cloud, sitting where it burst. It fades in over FADE_IN, holds,
## and fades out over the cloud's last FADE_OUT_TICKS. Reads the World;
## never writes it. MainView calls after_step() after each World.step().

const COLOR: Color = Color(0.62, 0.78, 0.25)
## Peak opacity: thick enough to read, thin enough to see the units inside.
const ALPHA: float = 0.32
## Meters from the ground to the top of the dome.
const HEIGHT: float = 2.4
const FADE_IN: float = 0.3
const FADE_OUT_TICKS: int = 60

var _world: World
var _domes: Dictionary[int, MeshInstance3D] = {}
var _ages: Dictionary[int, float] = {}


func setup(world: World) -> void:
	_world = world
	after_step()


## New clouds get a dome, cleared ones lose theirs, and the rest fade with
## the ticks they have left.
func after_step() -> void:
	var seen: Dictionary[int, bool] = {}
	for cloud: GasCloud in _world.clouds:
		if cloud.removed:
			continue
		seen[cloud.id] = true
		var dome: MeshInstance3D = _domes.get(cloud.id)
		if dome == null:
			dome = _make_dome(cloud)
		_set_alpha(cloud.id, dome, cloud.ticks_left)
	for cloud_id: int in _domes.keys():
		if not seen.has(cloud_id):
			_domes[cloud_id].queue_free()
			_domes.erase(cloud_id)
			_ages.erase(cloud_id)


## Clouds drawn.
func cloud_count() -> int:
	return _domes.size()


## Opacity of a cloud's dome with this many ticks left, at full strength:
## fading out over its last FADE_OUT_TICKS.
static func alpha_for(ticks_left: int) -> float:
	return ALPHA * clampf(float(ticks_left) / FADE_OUT_TICKS, 0.0, 1.0)


func _process(delta: float) -> void:
	for cloud_id: int in _ages:
		_ages[cloud_id] += delta


func _make_dome(cloud: GasCloud) -> MeshInstance3D:
	var mm: float = float(World.UNITS_PER_METER)
	var sphere: SphereMesh = SphereMesh.new()
	sphere.radius = cloud.radius / mm
	sphere.height = HEIGHT * 2.0
	sphere.is_hemisphere = true
	sphere.radial_segments = 24
	sphere.rings = 6
	var material: StandardMaterial3D = StandardMaterial3D.new()
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	material.cull_mode = BaseMaterial3D.CULL_DISABLED
	material.albedo_color = Color(COLOR, 0.0)
	var dome: MeshInstance3D = MeshInstance3D.new()
	dome.name = "Cloud_%d" % cloud.id
	dome.mesh = sphere
	dome.material_override = material
	dome.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	dome.position = Vector3(cloud.x, cloud.y, cloud.z) / mm
	add_child(dome)
	_domes[cloud.id] = dome
	_ages[cloud.id] = 0.0
	return dome


func _set_alpha(cloud_id: int, dome: MeshInstance3D, ticks_left: int) -> void:
	var fade_in: float = clampf(_ages.get(cloud_id, 0.0) / FADE_IN, 0.0, 1.0)
	(dome.material_override as StandardMaterial3D).albedo_color.a = alpha_for(ticks_left) * fade_in
