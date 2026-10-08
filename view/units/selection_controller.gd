class_name SelectionController
extends Control
## Turns mouse and keys into selection changes and sim commands:
## - Left click selects the unit under the cursor; shift-click toggles it.
## - Left drag box-selects; shift adds.
## - Double-click selects every unit of that type on screen; shift adds.
## - Right click moves the selection to the ground under the cursor, in the
##   current formation. On a herb plant, a loose object, or a body that one of
##   the selection can do something with (strike it, pick it up, tear a part
##   off it), it sends that unit instead (InteractCommand).
## - Cmd/Ctrl + right click attack-moves there instead: the selection fights
##   whatever it meets on the way.
## - Cmd/Ctrl + left click orders a ground attack: the selection's ranged
##   units bombard that spot. It doesn't select anything. (On macOS Ctrl +
##   click arrives as a right click, so Cmd is the Mac key.)
## - The control bar's Move, Attack-move and Ground attack buttons arm that
##   order for the next left click on the ground, once, so a one-button mouse
##   or a trackpad can give every order. Right click, Esc, pressing the button
##   again, or losing the selection cancels it.
## - T uses the selection's special ability (the bar's Ability button too).
##   With a Warden that has herbs in the selection it also arms Heal: the
##   next left click on a unit sends the nearest such Warden to heal it (or,
##   if it is undead, kill it).
## - 1..0 pick the formation for the next move order. Cmd/Ctrl+1..0 save a
##   group; Option/Alt+1..0 recall it. H stops. F9 (debug) switches sides.
##   F8 (debug) paralyzes, confuses, or sets alight the selection, in turn.
##
## Only living units of the controlled side can be selected, and a Light unit
## the AI drives is never the player's to order (the Ford's villager, led by an
## ESCORT group). The gate is for Light only: in the sandbox every Dark unit is
## the AI's, and F9 must still let the mouse command them. Selection is view state; orders go to the sim as
## commands for the next tick, the same stream multiplayer will send. unit_at()
## also picks units that can't be selected (either side, dead or alive), for the
## hover tooltip. This node covers the screen to draw the drag box but ignores
## the mouse, so HUD controls above it get clicks first.
##
## While `paused` the sim isn't stepping, so no order is given: selection,
## formations, and groups still work, but nothing is enqueued and nothing can
## be armed. Esc cancels an armed order and is consumed doing it; with none
## armed it passes on, which is how the pause menu (earlier in the HUD's
## tree, so later in the unhandled input order) gets it.

signal formation_changed(kind: Formations.Kind)
signal side_changed(side: UnitType.Faction)
signal armed_order_changed(order: ArmedOrder)
## An order was sent for the selection (move, attack-move, ground attack,
## stop, special, heal, interact), for the acknowledgement sound.
signal order_given

## An order from the control bar waiting for a left click on the ground.
enum ArmedOrder {
	NONE,
	MOVE,
	ATTACK_MOVE,
	GROUND_ATTACK,
	## Wait for a click on a unit to heal (HealCommand).
	HEAL,
}

## Pixels the mouse must move while held before a click becomes a drag.
const DRAG_THRESHOLD: float = 6.0
## Extra pixels around a sprite that still count as clicking it.
const PICK_SLOP: float = 3.0
const BOX_FILL: Color = Color(1.0, 0.92, 0.35, 0.12)
const BOX_EDGE: Color = Color(1.0, 0.92, 0.35, 0.9)
## F8: how long each debug status lasts, and the order they come in.
const DEBUG_STATUS_TICKS: int = 5 * World.TICK_RATE
const DEBUG_STATUSES: Array[StatusEffects.Kind] = [
	StatusEffects.Kind.PARALYSIS, StatusEffects.Kind.CONFUSION, StatusEffects.Kind.BURNING,
]

var selection: UnitSelection = UnitSelection.new()
var formation: Formations.Kind = Formations.Kind.SHORT_LINE
var side: UnitType.Faction = UnitType.Faction.LIGHT
## The order the next left click places, if any. It clears itself once the
## order is given. Change it with arm().
var armed_order: ArmedOrder = ArmedOrder.NONE
## True while the game is paused (MainView sets it). Giving an order does
## nothing and arming one is refused; pausing drops an armed order.
var paused: bool = false:
	set(value):
		paused = value
		if paused and armed_order != ArmedOrder.NONE:
			arm(ArmedOrder.NONE)
## Whether the debug keys work: F9 (and switch_side()) hands the mouse to the
## other side, and F8 (and cycle_debug_status()) paralyzes, confuses, or sets
## alight the selection. The campaign turns both off: they are cheats, F8 could
## burn a soldier who carries over for good, and the control bar hides its
## Switch side button.
var debug_keys_enabled: bool = true

var _world: World
var _units: UnitsView
var _camera: Camera3D
var _picker: TerrainPicker
var _projectiles: ProjectilesView
var _plants: HerbPlantsView
var _debug_status: int = 0
var _pressing: bool = false
var _dragging: bool = false
var _press_at: Vector2
var _drag_to: Vector2


func _ready() -> void:
	InputBindings.install()
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	focus_mode = Control.FOCUS_NONE
	selection.changed.connect(_on_selection_changed)


## projectiles and plants may be null; then right click never lands on a loose
## object or a herb plant.
func setup(
	world: World, units: UnitsView, camera: Camera3D, picker: TerrainPicker,
	projectiles: ProjectilesView = null, plants: HerbPlantsView = null
) -> void:
	_world = world
	_units = units
	_camera = camera
	_picker = picker
	_projectiles = projectiles
	_plants = plants


func set_formation(kind: Formations.Kind) -> void:
	formation = kind
	formation_changed.emit(kind)


## Arms an order for the next left click on the ground, or disarms with
## NONE. With nothing selected there is nothing to order, so it stays
## disarmed. Always emits armed_order_changed, so a bar button pressed with
## nothing selected pops back up. The cursor is a crosshair while armed.
func arm(order: ArmedOrder) -> void:
	if selection.is_empty() or paused:
		order = ArmedOrder.NONE
	armed_order = order
	Input.set_default_cursor_shape(
		Input.CURSOR_ARROW if order == ArmedOrder.NONE else Input.CURSOR_CROSS
	)
	armed_order_changed.emit(order)


func save_group(slot: int) -> void:
	selection.save_group(slot)


func recall_group(slot: int) -> void:
	selection.recall_group(slot)


func stop_selected() -> void:
	if not selection.is_empty() and not paused:
		_world.enqueue(StopUnitsCommand.new(_world.tick, selection.ids()))
		order_given.emit()


## Each selected unit uses its special: Sappers drop a charge, Longbows nock
## their fire arrow, Blightbags burst. Units with nothing left ignore it. A
## Warden's needs a patient, so with one that has herbs selected this arms
## Heal for the next click on a unit.
func use_special_selected() -> void:
	if selection.is_empty() or paused:
		return
	_world.enqueue(UseSpecialCommand.new(_world.tick, selection.ids()))
	order_given.emit()
	if _has_healer():
		arm(ArmedOrder.HEAL)


## Debug (F8): the next of paralysis, confusion, and burning on the selection,
## for DEBUG_STATUS_TICKS.
func cycle_debug_status() -> void:
	if selection.is_empty() or paused or not debug_keys_enabled:
		return
	var kind: StatusEffects.Kind = DEBUG_STATUSES[_debug_status]
	_debug_status = (_debug_status + 1) % DEBUG_STATUSES.size()
	_world.enqueue(ApplyStatusCommand.new(_world.tick, selection.ids(), kind, DEBUG_STATUS_TICKS))


## Debug: hands the mouse to the other side. Clears the selection. Does
## nothing where debug_keys_enabled is false.
func switch_side() -> void:
	if not debug_keys_enabled:
		return
	side = UnitType.Faction.DARK if side == UnitType.Faction.LIGHT else UnitType.Faction.LIGHT
	selection.clear()
	side_changed.emit(side)


func _process(_delta: float) -> void:
	if _world == null:
		return
	# Units that died or were despawned leave the selection and every group.
	selection.prune(func(unit_id: int) -> bool:
		var unit: Unit = _world.get_unit(unit_id)
		return unit != null and unit.is_alive())


func _unhandled_input(event: InputEvent) -> void:
	if _world == null:
		return
	var button: InputEventMouseButton = event as InputEventMouseButton
	if button != null and button.pressed:
		# Godot matches a mouse action even with extra modifiers held, so
		# Cmd/Ctrl + left click is asked for exactly, before the plain select.
		# It never starts a press, so it can't select or drag.
		if event.is_action(InputBindings.GROUND_ATTACK, true):
			_order_ground_attack(button.position)
			get_viewport().set_input_as_handled()
		elif event.is_action(InputBindings.SELECT):
			if armed_order != ArmedOrder.NONE:
				# This click places the order armed from the bar; it selects nothing.
				_place_armed_order(button.position)
			elif button.double_click:
				_select_type_at(button.position, button.shift_pressed)
			else:
				_pressing = true
				_dragging = false
				_press_at = button.position
				_drag_to = button.position
			get_viewport().set_input_as_handled()
		# Likewise Cmd/Ctrl + right click, before the plain one.
		elif event.is_action(InputBindings.ATTACK_MOVE, true):
			_order_move(button.position, true)
			get_viewport().set_input_as_handled()
		elif event.is_action(InputBindings.COMMAND):
			if armed_order != ArmedOrder.NONE:
				arm(ArmedOrder.NONE)
			elif not _order_interact(button.position):
				_order_move(button.position, false)
			get_viewport().set_input_as_handled()
		return
	if _handle_keys(event):
		get_viewport().set_input_as_handled()


# Mouse motion and release are watched here, before the GUI, so a drag that
# ends over the control bar still completes.
func _input(event: InputEvent) -> void:
	if not _pressing:
		return
	var motion: InputEventMouseMotion = event as InputEventMouseMotion
	if motion != null:
		_drag_to = motion.position
		if not _dragging and _press_at.distance_to(_drag_to) > DRAG_THRESHOLD:
			_dragging = true
		if _dragging:
			queue_redraw()
		return
	var button: InputEventMouseButton = event as InputEventMouseButton
	if button != null and not button.pressed and event.is_action(InputBindings.SELECT):
		_pressing = false
		if _dragging:
			_box_select(_drag_rect(), button.shift_pressed)
			_dragging = false
			queue_redraw()
		else:
			_click_select(button.position, button.shift_pressed)


func _draw() -> void:
	if _dragging:
		var rect: Rect2 = _drag_rect()
		draw_rect(rect, BOX_FILL)
		draw_rect(rect, BOX_EDGE, false, 1.0)


func _handle_keys(event: InputEvent) -> bool:
	# Exact matching: Cmd+1 must not also count as plain 1.
	for i: int in InputBindings.FORMATIONS.size():
		if event.is_action_pressed(InputBindings.GROUP_SAVES[i], false, true):
			save_group(i)
			return true
		if event.is_action_pressed(InputBindings.GROUP_RECALLS[i], false, true):
			recall_group(i)
			return true
		if event.is_action_pressed(InputBindings.FORMATIONS[i], false, true):
			set_formation(i as Formations.Kind)
			return true
	if event.is_action_pressed(InputBindings.CANCEL) and armed_order != ArmedOrder.NONE:
		arm(ArmedOrder.NONE)
		return true
	if event.is_action_pressed(InputBindings.STOP):
		stop_selected()
		return true
	# Exact, so Cmd+T isn't T. Key repeat is ignored: holding T uses the
	# special once.
	if event.is_action_pressed(InputBindings.ABILITY, false, true):
		use_special_selected()
		return true
	if debug_keys_enabled and event.is_action_pressed(InputBindings.SWITCH_SIDE):
		switch_side()
		return true
	if debug_keys_enabled and event.is_action_pressed(InputBindings.CYCLE_STATUS):
		cycle_debug_status()
		return true
	return false


# Nothing selected means nothing to order, so an armed order lapses.
func _on_selection_changed() -> void:
	if selection.is_empty() and armed_order != ArmedOrder.NONE:
		arm(ArmedOrder.NONE)


func _click_select(at: Vector2, additive: bool) -> void:
	var unit_id: int = unit_at(at)
	if unit_id < 0:
		if not additive:
			selection.clear()
	elif additive:
		selection.toggle(unit_id)
	else:
		selection.select(PackedInt32Array([unit_id]))


func _box_select(rect: Rect2, additive: bool) -> void:
	var ids: PackedInt32Array = PackedInt32Array()
	for sprite: UnitSprite in _units.sprites():
		if not _selectable(sprite.unit_id) or _camera.is_position_behind(sprite.global_position):
			continue
		if rect.has_point(_screen_rect(sprite).get_center()):
			ids.append(sprite.unit_id)
	if additive:
		selection.add(ids)
	else:
		selection.select(ids)


func _select_type_at(at: Vector2, additive: bool) -> void:
	var clicked: int = unit_at(at)
	if clicked < 0:
		return
	var type_index: int = _world.get_unit(clicked).type_index
	var screen: Rect2 = get_viewport().get_visible_rect()
	var ids: PackedInt32Array = PackedInt32Array()
	for sprite: UnitSprite in _units.sprites():
		if sprite.type_index != type_index or not _selectable(sprite.unit_id):
			continue
		if _camera.is_position_behind(sprite.global_position):
			continue
		if screen.has_point(_screen_rect(sprite).get_center()):
			ids.append(sprite.unit_id)
	if additive:
		selection.add(ids)
	else:
		selection.select(ids)


# Gives the armed order at the screen point. Only ever called while one is armed.
func _place_armed_order(at: Vector2) -> void:
	match armed_order:
		ArmedOrder.MOVE:
			_order_move(at, false)
		ArmedOrder.ATTACK_MOVE:
			_order_move(at, true)
		ArmedOrder.GROUND_ATTACK:
			_order_ground_attack(at)
		ArmedOrder.HEAL:
			_order_heal(at)


# Moves the selection to the ground under the screen point, or attack-moves it
# there. Giving an order disarms any armed order; a click that gives none
# (nothing selected, or off the map) leaves it armed.
func _order_move(at: Vector2, attack: bool) -> void:
	if paused:
		return
	var hit: Vector3 = _pick_ground(at)
	if hit == Vector3.INF:
		return
	var x: int = _to_milli(hit.x)
	var z: int = _to_milli(hit.z)
	if attack:
		_world.enqueue(AttackMoveCommand.new(_world.tick, selection.ids(), x, z, formation))
	else:
		_world.enqueue(MoveUnitsCommand.new(_world.tick, selection.ids(), x, z, formation))
	if not selection.is_empty():
		order_given.emit()
	_units.show_marker(
		hit, UnitsView.MarkerKind.ATTACK_MOVE if attack else UnitsView.MarkerKind.MOVE
	)
	if armed_order != ArmedOrder.NONE:
		arm(ArmedOrder.NONE)


# Orders the selection's ranged units to bombard the ground under the screen
# point. Disarms like _order_move.
func _order_ground_attack(at: Vector2) -> void:
	if paused:
		return
	var hit: Vector3 = _pick_ground(at)
	if hit == Vector3.INF:
		return
	_world.enqueue(GroundAttackCommand.new(
		_world.tick, selection.ids(), _to_milli(hit.x), _to_milli(hit.z)
	))
	if not selection.is_empty():
		order_given.emit()
	_units.show_marker(hit, UnitsView.MarkerKind.GROUND_ATTACK)
	if armed_order != ArmedOrder.NONE:
		arm(ArmedOrder.NONE)


# Sends the nearest selected Warden with herbs to heal the living unit under
# the screen point, either side. A click on no one leaves Heal armed.
func _order_heal(at: Vector2) -> void:
	if paused:
		return
	var target_id: int = unit_at(at, false)
	var target: Unit = _world.get_unit(target_id) if target_id >= 0 else null
	if target == null or not target.is_alive():
		return
	_world.enqueue(HealCommand.new(_world.tick, selection.ids(), target_id))
	order_given.emit()
	_units.show_marker(_units.sprite_position(target_id), UnitsView.MarkerKind.MOVE)
	arm(ArmedOrder.NONE)


# Right click on something that isn't ground: a herb plant, a loose object,
# or a body that someone selected can do something with. Sends that order
# and returns true; false if there is no such thing under the point.
func _order_interact(at: Vector2) -> bool:
	if selection.is_empty() or paused:
		return false
	var target_id: int = -1
	if _plants != null:
		target_id = _plants.plant_at(_camera, at)
	if target_id < 0 and _projectiles != null:
		target_id = _projectiles.object_at(_camera, at)
	if target_id < 0:
		var unit_id: int = unit_at(at, false)
		var body: Unit = _world.get_unit(unit_id) if unit_id >= 0 else null
		if body != null and not body.is_alive():
			target_id = unit_id
	if target_id < 0 or not _someone_can(target_id):
		return false
	_world.enqueue(InteractCommand.new(_world.tick, selection.ids(), target_id))
	order_given.emit()
	var target: SimEntity = _world.get_entity(target_id)
	_units.show_marker(Vector3(target.x, target.y, target.z) / float(World.UNITS_PER_METER), UnitsView.MarkerKind.MOVE)
	return true


# True if a selected unit could act on the entity (Interactions.action_for).
func _someone_can(entity_id: int) -> bool:
	var target: SimEntity = _world.get_entity(entity_id)
	if target == null:
		return false
	for unit_id: int in selection.ids():
		var unit: Unit = _world.get_unit(unit_id)
		if unit != null and unit.is_alive() and Interactions.action_for(_world, unit, target) != Interactions.Action.NONE:
			return true
	return false


# True if a selected unit is a healer with a herb left.
func _has_healer() -> bool:
	for unit_id: int in selection.ids():
		var unit: Unit = _world.get_unit(unit_id)
		if unit != null and unit.is_alive() and unit.type.special_ability == UnitType.Special.HEAL and unit.special_left > 0:
			return true
	return false


# The ground point under the screen point, or Vector3.INF if nothing is
# selected to order or the ray misses the map.
func _pick_ground(at: Vector2) -> Vector3:
	if selection.is_empty():
		return Vector3.INF
	return _picker.pick(_camera.project_ray_origin(at), _camera.project_ray_normal(at))


static func _to_milli(meters: float) -> int:
	return roundi(meters * float(World.UNITS_PER_METER))


## The unit whose sprite is under the screen point, nearest the camera if
## several overlap; -1 if none. With selectable_only, only living units of
## the controlled side count. Without it, any unit does, either side and dead
## or alive, except gibbed ones, which have nothing left to point at. A body
## is picked by the ground it covers, and a standing unit wins over a body
## under it.
func unit_at(at: Vector2, selectable_only: bool = true) -> int:
	var best: int = -1
	var best_distance: float = INF
	var best_is_body: bool = true
	for sprite: UnitSprite in _units.sprites():
		var unit: Unit = _world.get_unit(sprite.unit_id)
		if unit == null or not sprite.is_pickable() or _camera.is_position_behind(sprite.global_position):
			continue
		if selectable_only and not _selectable(sprite.unit_id):
			continue
		if not _screen_rect(sprite).grow(PICK_SLOP).has_point(at):
			continue
		var is_body: bool = not unit.is_alive()
		var d: float = _camera.global_position.distance_to(sprite.global_position)
		if best < 0 or (best_is_body and not is_body) or (is_body == best_is_body and d < best_distance):
			best_distance = d
			best = sprite.unit_id
			best_is_body = is_body
	return best


# Screen rectangle the sprite's quad covers. A standing quad is a billboard
# along the camera's up axis, not world up. A dead one lies on the ground, so
# the rectangle is the box around its projected corners.
func _screen_rect(sprite: UnitSprite) -> Rect2:
	if sprite.is_dead():
		var corners: PackedVector3Array = sprite.lying_corners()
		var rect: Rect2 = Rect2(_camera.unproject_position(corners[0]), Vector2.ZERO)
		for i: int in range(1, corners.size()):
			rect = rect.expand(_camera.unproject_position(corners[i]))
		return rect
	var up: Vector3 = _camera.global_transform.basis.y
	var feet: Vector2 = _camera.unproject_position(sprite.global_position)
	var head: Vector2 = _camera.unproject_position(sprite.global_position + up * sprite.height)
	var h: float = maxf(feet.y - head.y, 1.0)
	var w: float = h * sprite.half_width * 2.0 / sprite.height
	return Rect2(Vector2(feet.x - w * 0.5, head.y), Vector2(w, h))


func _selectable(unit_id: int) -> bool:
	var unit: Unit = _world.get_unit(unit_id)
	if unit == null or not unit.is_alive() or unit.faction != side:
		return false
	# A Light unit a group leads is the mission's, not the player's. (Dark units
	# are always the AI's, so the gate can't apply to them: the debug side
	# switch commands them.)
	return unit.faction != UnitType.Faction.LIGHT or not _world.ai.controls(unit_id)


func _drag_rect() -> Rect2:
	return Rect2(_press_at, _drag_to - _press_at).abs()
