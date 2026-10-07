class_name UnitsView
extends Node3D
## Draws every sim unit as a UnitSprite. The sim moves in 30 Hz steps, so
## each sprite is drawn between its last two tick positions by the physics
## interpolation fraction, which keeps motion smooth at any frame rate. Reads
## the World; never writes it. MainView calls after_step() after each
## World.step(), so it sees every tick's combat events: hits and blocks flash
## the target, and a kill lays the body down away from where the blow came
## from (an attacker, an arrow's approach, a blast's center), or bursts it into
## gibs when the overkill is large enough. A ground attack a unit can't carry
## out floats "Can't reach" over it and greys the marker. Status effects tint
## a sprite and name themselves over it; a heal flashes it green.
##
## Only what the watching side sees is drawn (Visibility.seen_by): a Husk
## lying in deep water stays out of sight, and out of picking and hovering,
## until one of the viewer's units comes close or it surfaces. The viewer is
## the side the mouse commands (set_viewer, which F9 switches).
##
## Types with art (setup's UnitArtCatalog) are drawn with it: each tick the
## sprite's UnitAnimator gets the unit's state, and each frame the sprite
## shows the direction it faces relative to the camera. set_art_enabled
## (F10) rebuilds every sprite as a placeholder or back, keeping the dead
## dead and the gibbed gone.

## What an order marker says, which sets its color.
enum MarkerKind {
	MOVE,
	ATTACK_MOVE,
	GROUND_ATTACK,
	## A ground attack that can't be carried out.
	BLOCKED,
}

## Seconds the move-order marker takes to fade.
const MARKER_LIFETIME: float = 0.7
const MARKER_COLOR: Color = Color(0.45, 1.0, 0.45)
const ATTACK_MARKER_COLOR: Color = Color(1.0, 0.3, 0.25)
const GROUND_ATTACK_MARKER_COLOR: Color = Color(1.0, 0.6, 0.15)
const BLOCKED_MARKER_COLOR: Color = Color(0.6, 0.6, 0.6)
const CANT_REACH_TEXT: String = "Can't reach"

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
var _viewer: UnitType.Faction = UnitType.Faction.LIGHT
var _arts: UnitArtCatalog = UnitArtCatalog.new()
var _art_enabled: bool = true
## The camera's horizontal forward (ground x, z), kept from the last frame
## that had one.
var _camera_forward: Vector2 = Vector2(0.0, -1.0)
## Units whose bodies burst into gibs, so a rebuilt sprite stays hidden.
var _gibbed: Dictionary[int, bool] = {}
## True while the sim isn't stepping (paused, or the mission is decided): the
## sprites stand at the latest tick instead of interpolating toward a next one
## that never comes, which the physics frames' fraction would otherwise swing
## them back and forth to. Art bodies hold their frame meanwhile, so nothing
## walks or swings in place.
var frozen: bool = false
## frozen as _process last saw it: whether the sprites are held.
var _held: bool = false


## gibs may be null, in which case bodies are never destroyed. arts may be
## null, in which case every unit is a placeholder.
func setup(world: World, selection: UnitSelection, gibs: Gibs, arts: UnitArtCatalog = null) -> void:
	_world = world
	_selection = selection
	_gibs = gibs
	if arts != null:
		_arts = arts
	_selection.changed.connect(_refresh_selection)
	_build_marker()
	after_step()


## Picks up the tick just simulated: new units get sprites, despawned ones
## lose them, every sprite's interpolation window moves forward a tick, and
## the tick's combat events play out.
func after_step() -> void:
	var blows: Dictionary[int, Vector2] = _react_to_combat()
	var launched: Dictionary[int, bool] = _launches()
	var seen: Dictionary[int, bool] = {}
	for unit: Unit in _world.units:
		seen[unit.id] = true
		var sprite: UnitSprite = _sprite_for(unit)
		_previous[unit.id] = _current[unit.id]
		_current[unit.id] = _position_of(unit)
		sprite.set_facing(unit.facing_x, unit.facing_z)
		sprite.set_hp(unit.hp, unit.type.max_hp)
		sprite.set_statuses(
			StatusEffects.paralyzed(_world, unit), StatusEffects.confused(_world, unit),
			StatusEffects.has(_world, unit, StatusEffects.Kind.BURNING)
		)
		sprite.visible = Visibility.seen_by(_world, unit, _viewer)
		# The sprite still standing is what marks a death as new: the body
		# lies down on this tick and never again.
		if not unit.is_alive() and not sprite.is_dead():
			sprite.set_dead(true, blows.get(unit.id, Vector2.ZERO), _ground_normal(unit))
		if sprite.has_art():
			sprite.animate(_animator_input(unit, launched))
	_react_to_projectile_events()
	for unit_id: int in _sprites.keys():
		if not seen.has(unit_id):
			_sprites[unit_id].queue_free()
			_sprites.erase(unit_id)
			_previous.erase(unit_id)
			_current.erase(unit_id)


## Where the unit's sprite stands now (meters), for markers.
func sprite_position(unit_id: int) -> Vector3:
	var sprite: UnitSprite = _sprites.get(unit_id)
	return sprite.position if sprite != null else Vector3.ZERO


## Every sprite the viewer can see, for screen-space picking and hovering.
func sprites() -> Array[UnitSprite]:
	var out: Array[UnitSprite] = []
	for sprite: UnitSprite in _sprites.values():
		if sprite.visible:
			out.append(sprite)
	return out


## Draws what this side sees from now on.
func set_viewer(side: UnitType.Faction) -> void:
	_viewer = side
	for unit: Unit in _world.units:
		if _sprites.has(unit.id):
			_sprites[unit.id].visible = Visibility.seen_by(_world, unit, _viewer)


## Draws units with their art (true) or as placeholders (false), rebuilding
## every sprite. A debug aid (F10): compare the art against the placeholder,
## or rule it out. The dead stay dead and the gibbed stay gone.
func set_art_enabled(enabled: bool) -> void:
	if enabled == _art_enabled:
		return
	_art_enabled = enabled
	for unit_id: int in _sprites:
		_sprites[unit_id].queue_free()
	_sprites.clear()
	for unit: Unit in _world.units:
		var sprite: UnitSprite = _sprite_for(unit)
		sprite.position = _current[unit.id]
		sprite.set_hp(unit.hp, unit.type.max_hp)
		sprite.set_statuses(
			StatusEffects.paralyzed(_world, unit), StatusEffects.confused(_world, unit),
			StatusEffects.has(_world, unit, StatusEffects.Kind.BURNING)
		)
		sprite.visible = Visibility.seen_by(_world, unit, _viewer)
		if not unit.is_alive():
			sprite.set_dead(true, Vector2.ZERO, _ground_normal(unit))
			sprite.skip_to_corpse()
		if _gibbed.has(unit.id):
			sprite.set_gibbed()


func art_enabled() -> bool:
	return _art_enabled


## Flashes a ring on the ground where an order was given: green for a move,
## red for an attack-move.
func show_move_marker(point: Vector3, attack: bool = false) -> void:
	show_marker(point, MarkerKind.ATTACK_MOVE if attack else MarkerKind.MOVE)


## Flashes a ring on the ground, colored by what it marks. There is one
## marker, so a new one replaces the one fading.
func show_marker(point: Vector3, kind: MarkerKind) -> void:
	_marker.position = point + Vector3(0.0, 0.05, 0.0)
	_marker_color = _marker_color_of(kind)
	_marker_age = 0.0
	_marker.visible = true


func _process(delta: float) -> void:
	# Out of the tree (a test driving _process by hand) there is no viewport.
	var camera: Camera3D = get_viewport().get_camera_3d() if is_inside_tree() else null
	if camera != null:
		var forward: Vector3 = -camera.global_basis.z
		# Straight down has no horizontal forward; keep the last one.
		if not Vector2(forward.x, forward.z).is_zero_approx():
			_camera_forward = Vector2(forward.x, forward.z)
	var hold_changed: bool = frozen != _held
	_held = frozen
	var alpha: float = 1.0 if frozen else Engine.get_physics_interpolation_fraction()
	for unit_id: int in _sprites:
		var sprite: UnitSprite = _sprites[unit_id]
		sprite.position = _previous[unit_id].lerp(_current[unit_id], alpha)
		if hold_changed:
			sprite.hold(_held)
		sprite.face_camera(_camera_forward)
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
			CombatEvent.Kind.HIT, CombatEvent.Kind.BLOCK, CombatEvent.Kind.HEAL:
				_sprite_for(target).flash(event.kind)
			CombatEvent.Kind.KILL:
				var blow: Vector2 = _blow_direction(event, target)
				blows[target.id] = blow
				if _gibs != null and Gibs.should_gib(event.overkill, target.type.max_hp):
					_burst(target, blow)
	return blows


# Ground orders a unit couldn't carry out: its notice, and a grey marker where
# it was told to shoot.
func _react_to_projectile_events() -> void:
	for event: ProjectileEvent in _world.projectile_events:
		if event.kind != ProjectileEvent.Kind.CANT_REACH:
			continue
		var unit: Unit = _world.get_unit(event.unit_id)
		if unit == null:
			continue
		_sprite_for(unit).show_notice(CANT_REACH_TEXT)
		show_marker(Vector3(event.x, event.y, event.z) / float(World.UNITS_PER_METER), MarkerKind.BLOCKED)


# Units that launched a projectile this tick.
func _launches() -> Dictionary[int, bool]:
	var out: Dictionary[int, bool] = {}
	for event: ProjectileEvent in _world.projectile_events:
		if event.kind == ProjectileEvent.Kind.LAUNCH:
			out[event.unit_id] = true
	return out


# What the unit's animator needs from the sim this tick. Ground speed comes
# from the tick's interpolation window, so it is what the unit actually
# covered: water and slopes included.
func _animator_input(unit: Unit, launched: Dictionary[int, bool]) -> UnitAnimator.AnimInput:
	var input: UnitAnimator.AnimInput = UnitAnimator.AnimInput.new()
	input.alive = unit.is_alive()
	input.moving = unit.state == Unit.State.MOVING
	var step: Vector3 = _current[unit.id] - _previous[unit.id]
	input.ground_speed = Vector2(step.x, step.z).length() * World.TICK_RATE
	input.windup_left = unit.windup_left
	input.aim_left = unit.aim_left
	input.act_left = unit.act_left
	input.launched = launched.has(unit.id)
	input.paralyzed = StatusEffects.paralyzed(_world, unit)
	return input


func _art_for(unit: Unit) -> UnitArt:
	return _arts.find(unit.type.id) if _art_enabled else null


# Replaces the body with gibs thrown along the blow, from chest height.
func _burst(target: Unit, blow: Vector2) -> void:
	var chest: Vector3 = _position_of(target) + Vector3(
		0.0, target.type.body_height * 0.5 / float(World.UNITS_PER_METER), 0.0
	)
	_gibs.spawn(chest, Vector3(blow.x, 0.0, blow.y), _sprite_for(target).gib_color())
	_sprite_for(target).set_gibbed()
	_gibbed[target.id] = true


# Ground direction from where the blow came from to the target, or zero if
# the target is exactly there. The sim reports the source with the event (the
# attacker, a blast's center, an arrow's approach), so it works when the
# attacker is dead or was never a unit.
static func _blow_direction(event: CombatEvent, target: Unit) -> Vector2:
	return Vector2(target.x - event.source_x, target.z - event.source_z).normalized()


# The unit's sprite, made on first use.
func _sprite_for(unit: Unit) -> UnitSprite:
	var sprite: UnitSprite = _sprites.get(unit.id)
	if sprite == null:
		sprite = UnitSprite.new()
		add_child(sprite)
		sprite.setup(unit, _art_for(unit))
		sprite.set_selected(_selection.is_selected(unit.id))
		# Made while the sim isn't stepping: it stands still like the rest.
		sprite.hold(frozen)
		_sprites[unit.id] = sprite
		_current[unit.id] = _position_of(unit)
	return sprite


static func _marker_color_of(kind: MarkerKind) -> Color:
	match kind:
		MarkerKind.ATTACK_MOVE:
			return ATTACK_MARKER_COLOR
		MarkerKind.GROUND_ATTACK:
			return GROUND_ATTACK_MARKER_COLOR
		MarkerKind.BLOCKED:
			return BLOCKED_MARKER_COLOR
	return MARKER_COLOR


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
