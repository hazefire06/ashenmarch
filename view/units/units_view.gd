class_name UnitsView
extends Node3D
## Draws every sim unit as a UnitSprite. The sim moves in 30 Hz steps, so
## each sprite is drawn between its last two tick positions by the physics
## interpolation fraction, which keeps motion smooth at any frame rate. Reads
## the World; never writes it. MainView calls after_step() after each
## World.step().

## Seconds the move-order marker takes to fade.
const MARKER_LIFETIME: float = 0.7
const MARKER_COLOR: Color = Color(0.45, 1.0, 0.45)

var _world: World
var _selection: UnitSelection
var _sprites: Dictionary[int, UnitSprite] = {}
var _previous: Dictionary[int, Vector3] = {}
var _current: Dictionary[int, Vector3] = {}
var _marker: MeshInstance3D
var _marker_material: StandardMaterial3D
var _marker_age: float = MARKER_LIFETIME


func setup(world: World, selection: UnitSelection) -> void:
	_world = world
	_selection = selection
	_selection.changed.connect(_refresh_selection)
	_build_marker()
	after_step()


## Picks up the tick just simulated: new units get sprites, despawned ones
## lose them, and every sprite's interpolation window moves forward a tick.
func after_step() -> void:
	var seen: Dictionary[int, bool] = {}
	for unit: Unit in _world.units:
		seen[unit.id] = true
		var pos: Vector3 = Vector3(unit.x, unit.y, unit.z) / float(World.UNITS_PER_METER)
		var sprite: UnitSprite = _sprites.get(unit.id)
		if sprite == null:
			sprite = UnitSprite.new()
			add_child(sprite)
			sprite.setup(unit)
			sprite.set_selected(_selection.is_selected(unit.id))
			_sprites[unit.id] = sprite
			_current[unit.id] = pos
		_previous[unit.id] = _current[unit.id]
		_current[unit.id] = pos
		sprite.set_facing(unit.facing_x, unit.facing_z)
		sprite.set_dead(not unit.is_alive())
	for unit_id: int in _sprites.keys():
		if not seen.has(unit_id):
			_sprites[unit_id].queue_free()
			_sprites.erase(unit_id)
			_previous.erase(unit_id)
			_current.erase(unit_id)


## Every sprite, for screen-space picking.
func sprites() -> Array[UnitSprite]:
	var out: Array[UnitSprite] = []
	out.assign(_sprites.values())
	return out


## Flashes a ring on the ground where a move order was given.
func show_move_marker(point: Vector3) -> void:
	_marker.position = point + Vector3(0.0, 0.05, 0.0)
	_marker_age = 0.0
	_marker.visible = true


func _process(delta: float) -> void:
	var alpha: float = Engine.get_physics_interpolation_fraction()
	for unit_id: int in _sprites:
		_sprites[unit_id].position = _previous[unit_id].lerp(_current[unit_id], alpha)
	if _marker != null and _marker.visible:
		_marker_age += delta
		var t: float = clampf(_marker_age / MARKER_LIFETIME, 0.0, 1.0)
		_marker.scale = Vector3.ONE * lerpf(1.6, 0.6, t)
		_marker_material.albedo_color.a = 1.0 - t
		_marker.visible = t < 1.0


func _refresh_selection() -> void:
	for unit_id: int in _sprites:
		_sprites[unit_id].set_selected(_selection.is_selected(unit_id))


func _build_marker() -> void:
	var torus: TorusMesh = TorusMesh.new()
	torus.inner_radius = 0.8
	torus.outer_radius = 1.0
	torus.rings = 32
	torus.ring_segments = 4
	_marker_material = StandardMaterial3D.new()
	_marker_material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_marker_material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	_marker_material.no_depth_test = true
	_marker_material.albedo_color = MARKER_COLOR
	_marker = MeshInstance3D.new()
	_marker.mesh = torus
	_marker.material_override = _marker_material
	_marker.visible = false
	add_child(_marker)
