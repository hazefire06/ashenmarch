class_name HerbPlantsView
extends Node3D
## Draws the World's herb plants: a green bush with a label, which turns
## brown and shrinks once it has been struck and has nothing left to give.
## plant_at() picks one on screen, for right-click orders and the tooltip.
## Reads the World; never writes it.

const LEAF_COLOR: Color = Color(0.3, 0.75, 0.3)
const SPENT_COLOR: Color = Color(0.45, 0.35, 0.2)
const SPENT_SCALE: float = 0.6
## Meters: the bush's size.
const BUSH_RADIUS: float = 0.45
const BUSH_HEIGHT: float = 0.8
const LABEL: String = "Herb plant"
const LABEL_RANGE: float = 35.0
## Pixels around a bush's center that still count as pointing at it.
const PICK_RADIUS: float = 18.0

var _world: World
var _bushes: Dictionary[int, Node3D] = {}
var _spent: Dictionary[int, bool] = {}
var _leaf: StandardMaterial3D
var _withered: StandardMaterial3D


func setup(world: World) -> void:
	_world = world
	_leaf = _material(LEAF_COLOR)
	_withered = _material(SPENT_COLOR)
	after_step()


## New plants get a bush; a struck plant withers.
func after_step() -> void:
	for plant: HerbPlant in _world.herb_plants:
		var bush: Node3D = _bushes.get(plant.id)
		if bush == null:
			bush = _make_bush(plant)
		if plant.spent and not _spent.get(plant.id, false):
			_spent[plant.id] = true
			(bush.get_node("Leaves") as MeshInstance3D).material_override = _withered
			bush.scale = Vector3.ONE * SPENT_SCALE


## Plants drawn.
func plant_count() -> int:
	return _bushes.size()


## True if the plant's bush is drawn withered.
func is_withered(plant_id: int) -> bool:
	return _spent.get(plant_id, false)


## The id of the plant whose bush is under the screen point (the nearest the
## camera if several), or -1.
func plant_at(camera: Camera3D, at: Vector2) -> int:
	var best: int = -1
	var best_distance: float = INF
	for plant_id: int in _bushes:
		var center: Vector3 = _bushes[plant_id].global_position + Vector3(0.0, BUSH_HEIGHT * 0.5, 0.0)
		if camera.is_position_behind(center):
			continue
		if camera.unproject_position(center).distance_to(at) > PICK_RADIUS:
			continue
		var d: float = camera.global_position.distance_to(center)
		if d < best_distance:
			best = plant_id
			best_distance = d
	return best


func _make_bush(plant: HerbPlant) -> Node3D:
	var root: Node3D = Node3D.new()
	root.name = "Plant_%d" % plant.id
	var sphere: SphereMesh = SphereMesh.new()
	sphere.radius = BUSH_RADIUS
	sphere.height = BUSH_HEIGHT
	sphere.radial_segments = 10
	sphere.rings = 5
	var leaves: MeshInstance3D = MeshInstance3D.new()
	leaves.name = "Leaves"
	leaves.mesh = sphere
	leaves.material_override = _leaf
	leaves.position.y = BUSH_HEIGHT * 0.5
	root.add_child(leaves)
	var label: Label3D = Label3D.new()
	label.text = LABEL
	label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	label.pixel_size = 0.006
	label.font_size = 32
	label.outline_size = 8
	label.no_depth_test = true
	label.position.y = BUSH_HEIGHT + 0.3
	label.visibility_range_end = LABEL_RANGE
	root.add_child(label)
	root.position = Vector3(plant.x, plant.y, plant.z) / float(World.UNITS_PER_METER)
	add_child(root)
	_bushes[plant.id] = root
	return root


static func _material(color: Color) -> StandardMaterial3D:
	var material: StandardMaterial3D = StandardMaterial3D.new()
	material.albedo_color = color
	return material
