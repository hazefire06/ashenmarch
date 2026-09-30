class_name UnitsView
extends Node3D
## Draws every sim unit as a UnitSprite. The sim moves in 30 Hz steps, so
## each sprite is drawn between its last two tick positions by the physics
## interpolation fraction, which keeps motion smooth at any frame rate. Reads
## the World; never writes it. MainView calls after_step() after each
## World.step(), so it sees every tick's combat events: hits and blocks flash
## the target, and a kill lays the body down away from the blow, or bursts it
## into gibs when the overkill is large enough.

## Seconds the move-order marker takes to fade.
const MARKER_LIFETIME: float = 0.7
const MARKER_COLOR: Color = Color(0.45, 1.0, 0.45)
const ATTACK_MARKER_COLOR: Color = Color(1.0, 0.3, 0.25)

var _world: World
var _selection: UnitSelection
var _gibs: Gibs
var _sprites: Dictionary[int, UnitSprite] = {}
var _previous: Dictionary[int, Vector3] = {}
var _current: Dictionary[int, Vector3] = {}
var _marker: MeshInstance3D
var _marker_material: StandardMaterial3D
var _marker_color: Color = MARKER_COLOR
var _marker_age: float = MARKER_LIFETIME


## gibs may be null, in which case bodies are never destroyed.
func setup(world: World, selection: UnitSelection, gibs: Gibs) -> void:
	_world = world
	_selection = selection
	_gibs = gibs
	_selection.changed.connect(_refresh_selection)
	_build_marker()
	after_step()


## Picks up the tick just simulated: new units get sprites, despawned ones
## lose them, every sprite's interpolation window moves forward a tick, and
## the tick's combat events play out.
func after_step() -> void:
	var blows: Dictionary[int, Vector2] = _react_to_combat()
	var seen: Dictionary[int, bool] = {}
	for unit: Unit in _world.units:
		seen[unit.id] = true
		var sprite: UnitSprite = _sprite_for(unit)
		_previous[unit.id] = _current[unit.id]
		_current[unit.id] = _position_of(unit)
		sprite.set_facing(unit.facing_x, unit.facing_z)
		sprite.set_hp(unit.hp, unit.type.max_hp)
		# The sprite still standing is what marks a death as new: the body
		# lies down on this tick and never again.
		if not unit.is_alive() and not sprite.is_dead():
			sprite.set_dead(true, blows.get(unit.id, Vector2.ZERO), _ground_normal(unit))
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


## Flashes a ring on the ground where an order was given: green for a move,
## red for an attack-move.
func show_move_marker(point: Vector3, attack: bool = false) -> void:
	_marker.position = point + Vector3(0.0, 0.05, 0.0)
	_marker_color = ATTACK_MARKER_COLOR if attack else MARKER_COLOR
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
		_marker_material.albedo_color = Color(_marker_color, 1.0 - t)
		_marker.visible = t < 1.0


func _refresh_selection() -> void:
	for unit_id: int in _sprites:
		_sprites[unit_id].set_selected(_selection.is_selected(unit_id))


# Plays this tick's combat events. Returns, for each unit killed, the ground
# direction (x, z) of the blow that killed it, so its body can fall that way.
func _react_to_combat() -> Dictionary[int, Vector2]:
	var blows: Dictionary[int, Vector2] = {}
	for event: CombatEvent in _world.combat_events:
		var target: Unit = _world.get_unit(event.target_id)
		if target == null:
			continue
		match event.kind:
			CombatEvent.Kind.HIT, CombatEvent.Kind.BLOCK:
				_sprite_for(target).flash(event.kind)
			CombatEvent.Kind.KILL:
				var blow: Vector2 = _blow_direction(event.attacker_id, target)
				blows[target.id] = blow
				if _gibs != null and Gibs.should_gib(event.overkill, target.type.max_hp):
					_burst(target, blow)
	return blows


# Replaces the body with gibs thrown along the blow, from chest height.
func _burst(target: Unit, blow: Vector2) -> void:
	var chest: Vector3 = _position_of(target) + Vector3(
		0.0, target.type.body_height * 0.5 / float(World.UNITS_PER_METER), 0.0
	)
	_gibs.spawn(chest, Vector3(blow.x, 0.0, blow.y), target.type.placeholder_color)
	_sprite_for(target).set_gibbed()


# Ground direction from the attacker to the target, or zero if the attacker
# is gone or standing exactly on it.
func _blow_direction(attacker_id: int, target: Unit) -> Vector2:
	var attacker: Unit = _world.get_unit(attacker_id)
	if attacker == null:
		return Vector2.ZERO
	return Vector2(target.x - attacker.x, target.z - attacker.z).normalized()


# The unit's sprite, made on first use.
func _sprite_for(unit: Unit) -> UnitSprite:
	var sprite: UnitSprite = _sprites.get(unit.id)
	if sprite == null:
		sprite = UnitSprite.new()
		add_child(sprite)
		sprite.setup(unit)
		sprite.set_selected(_selection.is_selected(unit.id))
		_sprites[unit.id] = sprite
		_current[unit.id] = _position_of(unit)
	return sprite


static func _position_of(unit: Unit) -> Vector3:
	return Vector3(unit.x, unit.y, unit.z) / float(World.UNITS_PER_METER)


# Surface normal of the ground under the unit, from the sim's own gradient
# (permille rise per meter), so a body lies flat on a slope.
func _ground_normal(unit: Unit) -> Vector3:
	if _world.terrain == null:
		return Vector3.UP
	var slope: Vector2i = _world.terrain.gradient_at(unit.x, unit.z)
	return Vector3(-slope.x, float(World.UNITS_PER_METER), -slope.y).normalized()


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
