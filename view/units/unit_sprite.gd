class_name UnitSprite
extends Node3D
## Placeholder look for one unit until the art pass: a flat-colored quad that
## always faces the camera, pivoting on its feet at this node's origin, the
## type's name above it, a tick on the ground showing which way it faces, and
## a ring when selected. A full billboard (rather than one turning only about
## the vertical axis) keeps the quad a clean upright rectangle on screen at
## the steep RTS camera pitch, where a vertical quad would look squashed and
## lean with perspective.

const RING_COLOR: Color = Color(1.0, 0.92, 0.35)
const FACING_COLOR: Color = Color(0.08, 0.08, 0.08)
const DEAD_TINT: Color = Color(0.35, 0.35, 0.35)
## Labels farther than this from the camera are hidden: zoomed out, a
## formation's worth of names would bury the units under text.
const LABEL_RANGE: float = 35.0

var unit_id: int
var type_index: int
## Meters: quad height and half width, for screen-space picking.
var height: float
var half_width: float

var _color: Color
var _body_material: StandardMaterial3D
var _label: Label3D
var _ring: MeshInstance3D
var _facing_pivot: Node3D


func setup(unit: Unit) -> void:
	unit_id = unit.id
	type_index = unit.type_index
	var t: UnitType = unit.type
	var mm: float = float(World.UNITS_PER_METER)
	height = t.body_height / mm
	half_width = t.body_radius / mm + 0.05
	_color = t.placeholder_color
	name = "Unit_%d" % unit.id

	var quad: QuadMesh = QuadMesh.new()
	quad.size = Vector2(half_width * 2.0, height)
	quad.center_offset = Vector3(0.0, height * 0.5, 0.0)
	_body_material = _unshaded(_color)
	_body_material.billboard_mode = BaseMaterial3D.BILLBOARD_ENABLED
	_body_material.cull_mode = BaseMaterial3D.CULL_DISABLED
	var body: MeshInstance3D = MeshInstance3D.new()
	body.mesh = quad
	body.material_override = _body_material
	add_child(body)

	_label = Label3D.new()
	_label.text = t.display_name
	_label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	# About 0.25 m tall, so a name spans roughly one unit spacing.
	_label.pixel_size = 0.008
	_label.font_size = 32
	_label.outline_size = 8
	_label.no_depth_test = true
	_label.position = Vector3(0.0, height + 0.3, 0.0)
	_label.visibility_range_end = LABEL_RANGE
	add_child(_label)

	var torus: TorusMesh = TorusMesh.new()
	torus.inner_radius = half_width + 0.12
	torus.outer_radius = half_width + 0.24
	torus.rings = 24
	torus.ring_segments = 4
	var ring_material: StandardMaterial3D = _unshaded(RING_COLOR)
	# Drawn over the ground so slopes don't swallow half the ring.
	ring_material.no_depth_test = true
	_ring = MeshInstance3D.new()
	_ring.mesh = torus
	_ring.material_override = ring_material
	_ring.position.y = 0.05
	_ring.visible = false
	add_child(_ring)

	var tick: BoxMesh = BoxMesh.new()
	tick.size = Vector3(0.08, 0.04, 0.4)
	var tick_instance: MeshInstance3D = MeshInstance3D.new()
	tick_instance.mesh = tick
	tick_instance.material_override = _unshaded(FACING_COLOR)
	tick_instance.position = Vector3(0.0, 0.05, half_width + 0.25)
	_facing_pivot = Node3D.new()
	_facing_pivot.add_child(tick_instance)
	add_child(_facing_pivot)
	set_facing(unit.facing_x, unit.facing_z)


func set_selected(selected: bool) -> void:
	_ring.visible = selected


## Turns the ground tick toward (x, z), any length.
func set_facing(x: int, z: int) -> void:
	if x != 0 or z != 0:
		_facing_pivot.rotation.y = atan2(float(x), float(z))


func set_dead(dead: bool) -> void:
	_body_material.albedo_color = _color * DEAD_TINT if dead else _color
	_label.visible = not dead
	_facing_pivot.visible = not dead


static func _unshaded(color: Color) -> StandardMaterial3D:
	var material: StandardMaterial3D = StandardMaterial3D.new()
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.albedo_color = color
	return material
