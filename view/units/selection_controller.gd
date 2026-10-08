class_name SelectionController
extends Control
## Turns pointer and keys into selection changes and sim commands.
##
## The work is done by pointer intents that take a screen point (select_at,
## box_select, select_type_at, order_at, the facing gesture begin_facing /
## update_facing / end_facing, ground_attack_at, place_armed) and by order
## and group methods. The mouse and keys below are one way in; the pad's
## cursor (PadController) and the overhead map (order_world) are others.
##
## Mouse and keys, Modern preset (the default):
## - Left click selects the unit under the cursor; shift-click toggles it.
## - Left drag box-selects; shift adds.
## - Double-click selects every unit of that type on screen; shift adds.
## - Right click moves the selection to the ground under the cursor, in the
##   current formation, when the button comes up. On a herb plant, a loose
##   object, or a body that one of the selection can do something with
##   (strike it, pick it up, tear a part off it), it sends that unit instead
##   (InteractCommand).
## - Right drag (or Option + left drag, for a one-button mouse) sets the
##   formation's facing: the order goes where the drag started, facing the
##   way it was dragged, with the slots shown as it goes. Starting on the one
##   unit selected, it turns that unit in place.
## - Shift + right click adds a route point (waypoints, up to four): on the
##   route's first point again it closes into a loop, on its last into a
##   back-and-forth (a patrol; patrols fight).
## - Cmd/Ctrl + right click attack-moves there instead: the selection fights
##   whatever it meets on the way. With shift, an attack-move route point.
## - Cmd/Ctrl + left click orders a ground attack: the selection's ranged
##   units bombard that spot. It doesn't select anything. (On macOS Ctrl +
##   click arrives as a right click, so Cmd is the Mac key.)
##
## Classic preset (InputBindings.orders_on_left): the left button gives
## orders too, as in Myth II. A left click on one of your units selects it
## (shift toggles it), and pressing it and dragging turns it to face the
## drag. A left click on the ground or an enemy gives the order there (shift:
## a route point); a left drag starting on the ground box-selects. Groups are
## saved by holding their key for GROUP_HOLD_SECONDS and recalled by tapping
## it (on release).
##
## Both presets:
## - The control bar's Move, Attack-move, Ground attack and Waypoints buttons
##   arm that order for the next left click on the ground (Waypoints: for
##   every click until the route closes or is ended), so a one-button mouse
##   or a trackpad can give every order. Right click, Esc, pressing the
##   button again, or losing the selection cancels it.
## - T uses the selection's special ability (the bar's Ability button too).
##   With a Warden that has herbs in the selection it also arms Heal: the
##   next left click on a unit sends the nearest such Warden to heal it (or,
##   if it is undead, kill it). In Classic a click on the ground instead drops
##   the heal and gives the order there.
## - G guards, B scatters, R retreats, Space stops. Left/Right arrow turn the
##   formation a step (ROTATE_STEP): the move the selection is still on,
##   given again facing the new way, or else the next move's.
## - 1..0 pick the formation for the next move order; Modern's Cmd/Ctrl+1..0
##   save a group and Option/Alt+1..0 recall it. F recalls the next saved
##   group (the camera follows), Delete clears the group the selection came
##   from, Enter selects all of your units on screen, ` selects none, F10 held
##   shows every health bar. F9 (debug) switches sides; F8 (debug) paralyzes,
##   confuses, or sets alight the selection, in turn.
##
## Only living units of the controlled side can be selected, and a Light unit
## the AI drives is never the player's to order (the Ford's villager, led by an
## ESCORT group). The gate is for Light only: in the sandbox every Dark unit is
## the AI's, and F9 must still let the mouse command them. Selection is view
## state; orders go to the sim as commands for the next tick, the same stream
## multiplayer will send. unit_at() also picks units that can't be selected
## (either side, dead or alive), for the hover tooltip. This node covers the
## screen to draw the drag box, the facing arrow and the route but ignores
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
## stop, special, heal, interact, guard, scatter, retreat, a route point),
## for the acknowledgement sound.
signal order_given
## The next move's turn from its automatic facing changed, in ROTATE_STEPs
## (0..ROTATE_STEPS-1), for the control bar.
signal rotation_changed(steps: int)
## The group slot the selection came from (recalled, cycled to, saved), or
## -1, for the control bar.
signal group_changed(slot: int)
## A short message for the player ("Group 3 saved", "Route full").
signal notice(text: String)
## The camera should go to the selection (a group was cycled to).
signal center_requested

## An order from the control bar waiting for a left click on the ground.
enum ArmedOrder {
	NONE,
	MOVE,
	ATTACK_MOVE,
	GROUND_ATTACK,
	## Wait for a click on a unit to heal (HealCommand).
	HEAL,
	## Every click adds a route point, until the route closes or is ended.
	WAYPOINT,
}

## Pixels the pointer must move while held before a click becomes a drag.
const DRAG_THRESHOLD: float = 6.0
## Pixels an order press must be dragged before it sets the facing.
const FACING_DRAG_THRESHOLD: float = 12.0
## Extra pixels around a sprite that still count as clicking it.
const PICK_SLOP: float = 3.0
const BOX_FILL: Color = Color(1.0, 0.92, 0.35, 0.12)
const BOX_EDGE: Color = Color(1.0, 0.92, 0.35, 0.9)
const GHOST_COLOR: Color = Color(0.45, 1.0, 0.45, 0.8)
const ROUTE_COLOR: Color = Color(0.55, 0.85, 1.0, 0.9)
## Turning the formation: this many steps to a turn (22.5 degrees each).
const ROTATE_STEPS: int = 16
## A turned move is given again at most this often (seconds) while the key
## repeats; the last turn always goes.
const REISSUE_INTERVAL: float = 0.2
## Seconds the turned formation's slots stay on screen after an arrow key.
const GHOST_SECONDS: float = 2.0
## Classic: seconds a group key is held to save the group.
const GROUP_HOLD_SECONDS: float = 0.8
## Meters from a route's first or last point that count as clicking it.
const ROUTE_CLOSE_RADIUS: float = 2.5
## Meters from the group within which the automatic facing is the group's own
## (UnitOrders.KEEP_FACING_RADIUS).
const KEEP_FACING_METERS: float = 2.0
## F8: how long each debug status lasts, and the order they come in.
const DEBUG_STATUS_TICKS: int = 5 * World.TICK_RATE
const DEBUG_STATUSES: Array[StatusEffects.Kind] = [
	StatusEffects.Kind.PARALYSIS, StatusEffects.Kind.CONFUSION, StatusEffects.Kind.BURNING,
]
const MODIFIER_KEYS: Array[Key] = [KEY_SHIFT, KEY_CTRL, KEY_ALT, KEY_META]

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
# A select press (left button): it becomes a click, or a box once dragged. In
# Classic it may instead be an order (on the ground, given on release if it
# never became a box) or a unit to turn (pressed on one of yours, dragged).
var _pressing: bool = false
var _dragging: bool = false
var _press_at: Vector2
var _drag_to: Vector2
var _press_orders: bool = false
var _press_queue: bool = false
var _press_unit: int = -1
# An order press (the facing gesture): where it started, whether it attack-
# moves or adds a route point, the unit it turns in place (or -1), the button
# that releases it, and whether it has been dragged far enough to face.
var _ordering: bool = false
var _order_at: Vector2
var _order_to: Vector2
var _order_attack: bool = false
var _order_queue: bool = false
var _order_unit: int = -1
var _order_button: MouseButton = MOUSE_BUTTON_RIGHT
var _facing: bool = false
# Turning: the pending turn for the next move, and the last move given, which
# the arrow keys give again facing the new way while the selection is on it.
var _pending_rotation: int = 0
var _last_order: Dictionary = {}
var _reissue_wait: float = 0.0
var _reissue_wanted: bool = false
var _ghost_left: float = 0.0
# Groups: the slot the selection came from; Classic's held group key.
var _current_group: int = -1
var _hold_slot: int = -1
var _hold_key: Key = KEY_NONE
var _hold_elapsed: float = 0.0
var _hold_done: bool = false
# The route points this view gave the selection, in meters (x, z), for drawing
# and for telling a click on its first or last point.
var _route_ids: PackedInt32Array = PackedInt32Array()
var _route_clicks: Array[Vector2] = []
# The bar's Health toggle; F10 shows the bars while held either way.
var _health_on: bool = false


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


# ---- groups ------------------------------------------------------------------


func save_group(slot: int) -> void:
	selection.save_group(slot)
	_set_current_group(slot)


func recall_group(slot: int) -> void:
	if selection.recall_group(slot):
		_set_current_group(slot)


## Recalls the next saved group after the current one (direction -1: the one
## before), wrapping, and asks for the camera to go to it. Nothing saved,
## nothing happens.
func cycle_group(direction: int = 1) -> void:
	var start: int = _current_group if _current_group >= 0 else (-1 if direction > 0 else 0)
	for step: int in range(1, UnitSelection.GROUP_COUNT + 1):
		var slot: int = posmod(start + step * direction, UnitSelection.GROUP_COUNT)
		if not selection.group(slot).is_empty():
			recall_group(slot)
			center_requested.emit()
			return


## Forgets the group the selection came from. The selection stays.
func clear_current_group() -> void:
	if _current_group < 0:
		return
	var slot: int = _current_group
	selection.clear_group(slot)
	_set_current_group(-1)
	notice.emit("Group %d cleared" % _slot_number(slot))


## The group slot the selection came from, or -1.
func current_group() -> int:
	return _current_group


# ---- orders ------------------------------------------------------------------


func stop_selected() -> void:
	if not selection.is_empty() and not paused:
		_world.enqueue(StopUnitsCommand.new(_world.tick, selection.ids()))
		order_given.emit()


func guard_selected() -> void:
	if not selection.is_empty() and not paused:
		_world.enqueue(GuardCommand.new(_world.tick, selection.ids()))
		order_given.emit()


func scatter_selected() -> void:
	if not selection.is_empty() and not paused:
		_world.enqueue(ScatterCommand.new(_world.tick, selection.ids()))
		order_given.emit()


func retreat_selected() -> void:
	if not selection.is_empty() and not paused:
		_world.enqueue(RetreatCommand.new(_world.tick, selection.ids(), formation))
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


## Turns the formation a step (direction +1 clockwise, -1 counter-clockwise):
## the move the selection is still on is given again facing the new way;
## otherwise the turn is kept for the next move and its slots shown.
func rotate_formation(direction: int) -> void:
	if _following_last_order():
		var facing: Vector2 = Vector2(_last_order["facing_x"], _last_order["facing_z"]) / float(FixedMath.DIR_ONE)
		facing = facing.rotated(direction * TAU / ROTATE_STEPS)
		_last_order["facing_x"] = roundi(facing.x * FixedMath.DIR_ONE)
		_last_order["facing_z"] = roundi(facing.y * FixedMath.DIR_ONE)
		_reissue_wanted = true
		if _reissue_wait <= 0.0:
			_reissue_last_order()
		return
	_pending_rotation = posmod(_pending_rotation + direction, ROTATE_STEPS)
	_ghost_left = GHOST_SECONDS
	rotation_changed.emit(_pending_rotation)
	queue_redraw()


## Shows every unit's health bar while on (the bar's Health toggle). F10
## shows them while held, whatever this says.
func set_health_bars(on: bool) -> void:
	_health_on = on
	if _units != null:
		_units.show_all_health = on


## The next move's pending turn, in ROTATE_STEPs.
func pending_rotation() -> int:
	return _pending_rotation


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


# ---- pointer intents ---------------------------------------------------------


## Selects the unit under the screen point, or (additive) toggles it. On no
## unit, a plain click clears the selection.
func select_at(at: Vector2, additive: bool) -> void:
	var unit_id: int = unit_at(at)
	if unit_id < 0:
		if not additive:
			selection.clear()
	elif additive:
		selection.toggle(unit_id)
	else:
		selection.select(PackedInt32Array([unit_id]))


## Selects (or, additive, adds) the units whose sprites' middles are in rect.
func box_select(rect: Rect2, additive: bool) -> void:
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


## Selects (or adds) every unit on screen of the type under the screen point.
func select_type_at(at: Vector2, additive: bool) -> void:
	var clicked: int = unit_at(at)
	if clicked < 0:
		return
	var type_index: int = _world.get_unit(clicked).type_index
	var ids: PackedInt32Array = PackedInt32Array()
	for unit_id: int in _visible_selectable():
		if _world.get_unit(unit_id).type_index == type_index:
			ids.append(unit_id)
	if additive:
		selection.add(ids)
	else:
		selection.select(ids)


## Enter: every unit of yours on screen.
func select_all_visible() -> void:
	selection.select(_visible_selectable())


## `: nothing.
func deselect() -> void:
	selection.clear()


## The order at a screen point, as a click gives it: a route point with
## queue, an attack-move with attack; otherwise an errand on something the
## selection can use there, or a move.
func order_at(at: Vector2, attack: bool, queue: bool) -> void:
	if not queue and not attack and _order_interact(at):
		return
	var hit: Vector3 = _pick_ground(at)
	if hit != Vector3.INF:
		order_world(hit, attack, queue)


## The order at a point on the ground (meters), facing `facing` (x, z; zero
## for automatic, turned by any pending turn): a route point with queue (or
## closing the route, on its first or last point), else a move or attack-move.
## The overhead map and the pad's cursor give orders here too.
func order_world(point: Vector3, attack: bool, queue: bool, facing: Vector2 = Vector2.ZERO) -> void:
	if paused or selection.is_empty():
		return
	if queue:
		_order_route_point(point, attack, facing)
		return
	if facing == Vector2.ZERO and _pending_rotation != 0:
		facing = _automatic_facing(point).rotated(_pending_rotation * TAU / ROTATE_STEPS)
		_pending_rotation = 0
		rotation_changed.emit(0)
	var x: int = _to_milli(point.x)
	var z: int = _to_milli(point.z)
	var fx: int = roundi(facing.x * FixedMath.DIR_ONE)
	var fz: int = roundi(facing.y * FixedMath.DIR_ONE)
	var ids: PackedInt32Array = selection.ids()
	if attack:
		_world.enqueue(AttackMoveCommand.new(_world.tick, ids, x, z, formation, fx, fz))
	else:
		_world.enqueue(MoveUnitsCommand.new(_world.tick, ids, x, z, formation, fx, fz))
	var recorded: Vector2 = facing if facing != Vector2.ZERO else _automatic_facing(point)
	_last_order = {
		"ids": ids, "x": x, "z": z, "formation": formation, "attack": attack,
		"facing_x": roundi(recorded.x * FixedMath.DIR_ONE), "facing_z": roundi(recorded.y * FixedMath.DIR_ONE),
	}
	order_given.emit()
	_units.show_marker(point, UnitsView.MarkerKind.ATTACK_MOVE if attack else UnitsView.MarkerKind.MOVE)
	if armed_order != ArmedOrder.NONE and armed_order != ArmedOrder.WAYPOINT:
		arm(ArmedOrder.NONE)


## Starts the facing gesture at a screen point: an order button pressed.
## The order is given when it ends (end_facing). Pressed on the one unit
## selected, it turns that unit in place.
func begin_facing(at: Vector2, attack: bool, queue: bool, button: MouseButton = MOUSE_BUTTON_RIGHT) -> void:
	_ordering = true
	_facing = false
	_order_at = at
	_order_to = at
	_order_attack = attack
	_order_queue = queue
	_order_button = button
	_order_unit = -1
	if selection.size() == 1 and unit_at(at) == selection.ids()[0]:
		_order_unit = selection.ids()[0]


## The gesture has moved to a screen point: past FACING_DRAG_THRESHOLD it is
## setting the facing, and the slots are drawn.
func update_facing(at: Vector2) -> void:
	if not _ordering:
		return
	_order_to = at
	if not _facing and _order_at.distance_to(at) > FACING_DRAG_THRESHOLD:
		_facing = true
	if _facing:
		queue_redraw()


## Ends the gesture at a screen point: the order, facing the way it was
## dragged if it was, else a plain click's order where it started.
func end_facing(at: Vector2) -> void:
	if not _ordering:
		return
	update_facing(at)
	_ordering = false
	var dragged: bool = _facing
	_facing = false
	queue_redraw()
	if not dragged:
		order_at(_order_at, _order_attack, _order_queue)
		return
	var from: Vector3 = _pick_ground(_order_at)
	var direction: Vector2 = _drag_direction()
	if from == Vector3.INF or direction == Vector2.ZERO:
		return
	if _order_unit >= 0:
		_turn_unit(_order_unit, direction)
		return
	order_world(from, _order_attack, _order_queue, direction)


## True while an order button is held (the facing gesture).
func is_facing_gesture() -> bool:
	return _ordering


## Drops a facing gesture without ordering.
func cancel_facing() -> void:
	_ordering = false
	_facing = false
	queue_redraw()


## The selection's ranged units bombard the ground under the screen point.
## Disarms like a move.
func ground_attack_at(at: Vector2) -> void:
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


## Gives the armed order at the screen point. Does nothing with none armed.
func place_armed(at: Vector2) -> void:
	match armed_order:
		ArmedOrder.MOVE:
			order_at(at, false, false)
		ArmedOrder.ATTACK_MOVE:
			order_at(at, true, false)
		ArmedOrder.GROUND_ATTACK:
			ground_attack_at(at)
		ArmedOrder.HEAL:
			_order_heal(at)
		ArmedOrder.WAYPOINT:
			order_at(at, false, true)


## The selection's route points as this view shows them (meters), first to
## last: where the player clicked, or, for a selection whose routes it didn't
## give, the middle of the units' points.
func route_points() -> Array[Vector3]:
	var out: Array[Vector3] = []
	if _world == null:
		return out
	var ids: PackedInt32Array = selection.ids()
	if ids == _route_ids and not _route_clicks.is_empty() and _has_route(ids):
		for p: Vector2 in _route_clicks:
			out.append(_ground(p))
		return out
	var sums: Array[Vector2] = []
	var counts: Array[int] = []
	for unit_id: int in ids:
		var unit: Unit = _world.get_unit(unit_id)
		if unit == null or not unit.is_alive():
			continue
		for i: int in UnitRoute.point_count(unit):
			if sums.size() <= i:
				sums.append(Vector2.ZERO)
				counts.append(0)
			var p: Vector2i = UnitRoute.point(unit, i)
			sums[i] += Vector2(p) / float(World.UNITS_PER_METER)
			counts[i] += 1
	for i: int in sums.size():
		out.append(_ground(sums[i] / counts[i]))
	return out


## The selection's route mode (UnitRoute.Mode), from its first unit with a
## route; OPEN with none.
func route_mode() -> UnitRoute.Mode:
	for unit_id: int in selection.ids():
		var unit: Unit = _world.get_unit(unit_id)
		if unit != null and unit.is_alive() and not unit.route.is_empty():
			return unit.route_mode as UnitRoute.Mode
	return UnitRoute.Mode.OPEN


# ---- frame and input ---------------------------------------------------------


func _process(delta: float) -> void:
	if _world == null:
		return
	# Units that died or were despawned leave the selection and every group.
	selection.prune(func(unit_id: int) -> bool:
		var unit: Unit = _world.get_unit(unit_id)
		return unit != null and unit.is_alive())
	if _reissue_wait > 0.0:
		_reissue_wait -= delta
		if _reissue_wait <= 0.0 and _reissue_wanted:
			_reissue_last_order()
	if _ghost_left > 0.0:
		_ghost_left -= delta
		queue_redraw()
	if _hold_slot >= 0 and not _hold_done:
		_hold_elapsed += delta
		if _hold_elapsed >= GROUP_HOLD_SECONDS:
			_hold_done = true
			save_group(_hold_slot)
			notice.emit("Group %d saved" % _slot_number(_hold_slot))
	if not selection.is_empty() and _has_route(selection.ids()):
		queue_redraw()


func _unhandled_input(event: InputEvent) -> void:
	if _world == null:
		return
	var button: InputEventMouseButton = event as InputEventMouseButton
	if button != null and button.pressed:
		if _mouse_press(button):
			get_viewport().set_input_as_handled()
		return
	if _handle_keys(event):
		get_viewport().set_input_as_handled()


# Mouse motion and release are watched here, before the GUI, so a drag that
# ends over the control bar still completes. So are the releases of Classic's
# held group key and of F10.
func _input(event: InputEvent) -> void:
	var key: InputEventKey = event as InputEventKey
	if key != null and not key.pressed:
		_key_released(key)
		return
	var motion: InputEventMouseMotion = event as InputEventMouseMotion
	if motion != null:
		if _ordering:
			update_facing(motion.position)
		if _pressing:
			_drag_to = motion.position
			if not _dragging and _press_at.distance_to(_drag_to) > DRAG_THRESHOLD:
				_dragging = true
				if _press_unit >= 0:
					selection.select(PackedInt32Array([_press_unit]))
			if _dragging:
				queue_redraw()
		return
	var button: InputEventMouseButton = event as InputEventMouseButton
	if button == null or button.pressed:
		return
	if _ordering and button.button_index == _order_button:
		end_facing(button.position)
		return
	if _pressing and button.button_index == MOUSE_BUTTON_LEFT:
		_end_press(button.position, button.shift_pressed)


# A mouse button pressed. Returns true if it was the controller's.
func _mouse_press(button: InputEventMouseButton) -> bool:
	var at: Vector2 = button.position
	# Godot matches a mouse action when at least its modifiers are held, so
	# the modified actions are asked for before the bare buttons.
	if button.is_action(InputBindings.GROUND_ATTACK):
		ground_attack_at(at)
		return true
	if button.is_action(InputBindings.COMMAND_ALT):
		if armed_order != ArmedOrder.NONE:
			arm(ArmedOrder.NONE)
		else:
			begin_facing(at, false, button.shift_pressed, MOUSE_BUTTON_LEFT)
		return true
	if button.is_action(InputBindings.SELECT):
		_select_press(button)
		return true
	if button.is_action(InputBindings.ATTACK_MOVE):
		begin_facing(at, true, button.shift_pressed, button.button_index)
		return true
	if button.is_action(InputBindings.COMMAND):
		if armed_order != ArmedOrder.NONE:
			arm(ArmedOrder.NONE)
		else:
			begin_facing(at, false, button.shift_pressed, button.button_index)
		return true
	return false


# The select button pressed: places an armed order, selects by type on a
# double click, or starts a press that becomes a click or a box (in Classic,
# perhaps an order or a unit to turn).
func _select_press(button: InputEventMouseButton) -> void:
	var at: Vector2 = button.position
	var classic: bool = InputBindings.orders_on_left()
	if armed_order != ArmedOrder.NONE:
		if classic and armed_order == ArmedOrder.HEAL and unit_at(at, false) < 0:
			# Classic: the click is an order on the ground, not a patient.
			arm(ArmedOrder.NONE)
		else:
			# This click places the order armed from the bar; it selects nothing.
			place_armed(at)
			return
	if button.double_click:
		select_type_at(at, button.shift_pressed)
		return
	_pressing = true
	_dragging = false
	_press_at = at
	_drag_to = at
	_press_orders = false
	_press_queue = button.shift_pressed
	_press_unit = -1
	if not classic:
		return
	var own: int = unit_at(at)
	if own >= 0:
		if not button.shift_pressed:
			_press_unit = own
	elif not selection.is_empty():
		_press_orders = true


# The select button released at a screen point.
func _end_press(at: Vector2, shift: bool) -> void:
	_pressing = false
	if _dragging:
		_dragging = false
		queue_redraw()
		if _press_unit >= 0:
			var direction: Vector2 = _ground_direction(_press_at, at)
			if direction != Vector2.ZERO:
				_turn_unit(_press_unit, direction)
		else:
			box_select(_drag_rect(), shift)
		return
	if _press_orders:
		order_at(_press_at, false, _press_queue)
		return
	select_at(at, shift)


func _draw() -> void:
	if _dragging and _press_unit < 0:
		var rect: Rect2 = _drag_rect()
		draw_rect(rect, BOX_FILL)
		draw_rect(rect, BOX_EDGE, false, 1.0)
	if _dragging and _press_unit >= 0:
		draw_line(_press_at, _drag_to, GHOST_COLOR, 2.0)
	if _camera == null or _world == null:
		return
	if _ordering and _facing:
		_draw_ghost(_pick_ground(_order_at), _drag_direction())
		draw_line(_order_at, _order_to, GHOST_COLOR, 2.0)
	elif _ghost_left > 0.0 and _pending_rotation != 0 and not selection.is_empty():
		var anchor: Vector3 = _pick_ground(get_viewport().get_mouse_position())
		if anchor != Vector3.INF:
			_draw_ghost(anchor, _automatic_facing(anchor).rotated(_pending_rotation * TAU / ROTATE_STEPS))
	_draw_route()


func _handle_keys(event: InputEvent) -> bool:
	# Exact matching: Cmd+1 must not also count as plain 1.
	for i: int in InputBindings.FORMATIONS.size():
		if event.is_action_pressed(InputBindings.GROUP_SAVES[i], false, true):
			save_group(i)
			return true
		if event.is_action_pressed(InputBindings.GROUP_RECALLS[i], false, true):
			if InputBindings.hold_to_save_groups():
				_start_group_hold(i, event as InputEventKey)
			else:
				recall_group(i)
			return true
		if event.is_action_pressed(InputBindings.FORMATIONS[i], false, true):
			set_formation(i as Formations.Kind)
			return true
	if event.is_action_pressed(InputBindings.CANCEL) and (armed_order != ArmedOrder.NONE or _ordering):
		arm(ArmedOrder.NONE)
		cancel_facing()
		return true
	if event.is_action_pressed(InputBindings.STOP):
		stop_selected()
		return true
	# Exact, so Cmd+T isn't T. Key repeat is ignored: holding T uses the
	# special once.
	if event.is_action_pressed(InputBindings.ABILITY, false, true):
		use_special_selected()
		return true
	if event.is_action_pressed(InputBindings.GUARD, false, true):
		guard_selected()
		return true
	if event.is_action_pressed(InputBindings.SCATTER, false, true):
		scatter_selected()
		return true
	if event.is_action_pressed(InputBindings.RETREAT, false, true):
		retreat_selected()
		return true
	# Key repeat turns on, a step at a time.
	if event.is_action_pressed(InputBindings.ROTATE_LEFT, true, true):
		rotate_formation(-1)
		return true
	if event.is_action_pressed(InputBindings.ROTATE_RIGHT, true, true):
		rotate_formation(1)
		return true
	if event.is_action_pressed(InputBindings.SELECT_ALL, false, true):
		select_all_visible()
		return true
	if event.is_action_pressed(InputBindings.DESELECT, false, true):
		deselect()
		return true
	if event.is_action_pressed(InputBindings.CYCLE_GROUPS, false, true):
		cycle_group(1)
		return true
	if event.is_action_pressed(InputBindings.CLEAR_GROUP, false, true):
		clear_current_group()
		return true
	if event.is_action_pressed(InputBindings.HEALTH_BARS, false, true):
		_units.show_all_health = true
		return true
	if debug_keys_enabled and event.is_action_pressed(InputBindings.SWITCH_SIDE):
		switch_side()
		return true
	if debug_keys_enabled and event.is_action_pressed(InputBindings.CYCLE_STATUS):
		cycle_debug_status()
		return true
	return false


# A key came up: F10 hides the health bars again; Classic's held group key,
# let go before it saved, recalls the group. Mac browsers drop the release
# of a key let go while Cmd is down, so letting go of a modifier counts too.
func _key_released(key: InputEventKey) -> void:
	if _units != null and key.is_action_released(InputBindings.HEALTH_BARS):
		_units.show_all_health = _health_on
	if _hold_slot < 0:
		return
	if key.physical_keycode != _hold_key and not MODIFIER_KEYS.has(key.physical_keycode):
		return
	var slot: int = _hold_slot
	_hold_slot = -1
	if not _hold_done:
		recall_group(slot)


func _start_group_hold(slot: int, key: InputEventKey) -> void:
	_hold_slot = slot
	_hold_key = key.physical_keycode if key != null else KEY_NONE
	_hold_elapsed = 0.0
	_hold_done = false


# Nothing selected means nothing to order, so an armed order lapses; a new
# selection isn't the group it came from.
func _on_selection_changed() -> void:
	if selection.is_empty() and armed_order != ArmedOrder.NONE:
		arm(ArmedOrder.NONE)
	if _current_group >= 0 and selection.ids() != selection.group(_current_group):
		_set_current_group(-1)


func _set_current_group(slot: int) -> void:
	_current_group = slot
	group_changed.emit(slot)


static func _slot_number(slot: int) -> int:
	return (slot + 1) % UnitSelection.GROUP_COUNT


# ---- order helpers -----------------------------------------------------------


# A route point at `point`, or the route closed if it is on its first or last
# point. A full open route takes no more.
func _order_route_point(point: Vector3, attack: bool, facing: Vector2) -> void:
	var ids: PackedInt32Array = selection.ids()
	var flat: Vector2 = Vector2(point.x, point.z)
	var shown: Array[Vector3] = route_points()
	var open: bool = route_mode() == UnitRoute.Mode.OPEN and _has_route(ids)
	if open and shown.size() >= 2:
		var mode: int = -1
		if Vector2(shown[0].x, shown[0].z).distance_to(flat) <= ROUTE_CLOSE_RADIUS:
			mode = UnitRoute.Mode.LOOP
		elif Vector2(shown[-1].x, shown[-1].z).distance_to(flat) <= ROUTE_CLOSE_RADIUS:
			mode = UnitRoute.Mode.BACK_AND_FORTH
		if mode >= 0:
			_world.enqueue(PatrolCommand.new(_world.tick, ids, mode as UnitRoute.Mode))
			order_given.emit()
			notice.emit("Patrol: loop" if mode == UnitRoute.Mode.LOOP else "Patrol: back and forth")
			if armed_order == ArmedOrder.WAYPOINT:
				arm(ArmedOrder.NONE)
			return
	if open and shown.size() >= UnitRoute.MAX_POINTS:
		notice.emit("Route full (%d points)" % UnitRoute.MAX_POINTS)
		return
	_world.enqueue(RoutePointCommand.new(
		_world.tick, ids, _to_milli(point.x), _to_milli(point.z), formation, attack,
		roundi(facing.x * FixedMath.DIR_ONE), roundi(facing.y * FixedMath.DIR_ONE)
	))
	order_given.emit()
	if not open or ids != _route_ids:
		_route_clicks.clear()
		# Points the selection already has (given before, or by another view)
		# stay in the drawing.
		if open:
			for p: Vector3 in shown:
				_route_clicks.append(Vector2(p.x, p.z))
	_route_ids = ids
	_route_clicks.append(flat)
	_units.show_marker(point, UnitsView.MarkerKind.ATTACK_MOVE if attack else UnitsView.MarkerKind.MOVE)


# Turns one unit in place to face `direction` (x, z): a move to where it
# stands.
func _turn_unit(unit_id: int, direction: Vector2) -> void:
	var unit: Unit = _world.get_unit(unit_id)
	if unit == null or not unit.is_alive() or paused:
		return
	_world.enqueue(MoveUnitsCommand.new(
		_world.tick, PackedInt32Array([unit_id]), unit.x, unit.z, formation,
		roundi(direction.x * FixedMath.DIR_ONE), roundi(direction.y * FixedMath.DIR_ONE)
	))
	order_given.emit()


# True if the selection is exactly the last move's units and some are still
# marching under it.
func _following_last_order() -> bool:
	if _last_order.is_empty() or selection.ids() != _last_order["ids"]:
		return false
	for unit_id: int in selection.ids():
		var unit: Unit = _world.get_unit(unit_id)
		if unit != null and unit.is_alive() and (unit.order == Unit.Order.MOVE or unit.order == Unit.Order.ATTACK_MOVE):
			return true
	return false


func _reissue_last_order() -> void:
	_reissue_wanted = false
	_reissue_wait = REISSUE_INTERVAL
	if paused or _last_order.is_empty():
		return
	var ids: PackedInt32Array = _last_order["ids"]
	var x: int = _last_order["x"]
	var z: int = _last_order["z"]
	var kind: int = _last_order["formation"]
	var fx: int = _last_order["facing_x"]
	var fz: int = _last_order["facing_z"]
	if _last_order["attack"]:
		_world.enqueue(AttackMoveCommand.new(_world.tick, ids, x, z, kind, fx, fz))
	else:
		_world.enqueue(MoveUnitsCommand.new(_world.tick, ids, x, z, kind, fx, fz))
	order_given.emit()


# The facing a move to `point` gets by itself (UnitOrders.order_facing): from
# the selection toward the point, or its mean facing when the point is close.
func _automatic_facing(point: Vector3) -> Vector2:
	var center: Vector2 = Vector2.ZERO
	var mean: Vector2 = Vector2.ZERO
	var count: int = 0
	for unit_id: int in selection.ids():
		var unit: Unit = _world.get_unit(unit_id)
		if unit == null or not unit.is_alive():
			continue
		center += Vector2(unit.x, unit.z) / float(World.UNITS_PER_METER)
		mean += Vector2(unit.facing_x, unit.facing_z)
		count += 1
	if count == 0:
		return Vector2(0.0, -1.0)
	center /= count
	var toward: Vector2 = Vector2(point.x, point.z) - center
	if toward.length() >= KEEP_FACING_METERS:
		return toward.normalized()
	return mean.normalized() if mean != Vector2.ZERO else Vector2(0.0, -1.0)


# The facing gesture's direction on the ground (x, z), or zero.
func _drag_direction() -> Vector2:
	return _ground_direction(_order_at, _order_to)


func _ground_direction(from_screen: Vector2, to_screen: Vector2) -> Vector2:
	var from: Vector3 = _pick_ground(from_screen, true)
	var to: Vector3 = _pick_ground(to_screen, true)
	if from == Vector3.INF or to == Vector3.INF:
		return Vector2.ZERO
	var d: Vector2 = Vector2(to.x - from.x, to.z - from.z)
	return d.normalized() if d.length() > 0.01 else Vector2.ZERO


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


# A click on something that isn't ground: a herb plant, a loose object, or a
# body that someone selected can do something with. Sends that order and
# returns true; false if there is no such thing under the point.
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
	if armed_order != ArmedOrder.NONE and armed_order != ArmedOrder.WAYPOINT:
		arm(ArmedOrder.NONE)
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


func _has_route(ids: PackedInt32Array) -> bool:
	for unit_id: int in ids:
		var unit: Unit = _world.get_unit(unit_id)
		if unit != null and unit.is_alive() and not unit.route.is_empty():
			return true
	return false


# ---- drawing -----------------------------------------------------------------


# The slots the selection would take at `anchor` facing `direction`, as dots.
func _draw_ghost(anchor: Vector3, direction: Vector2) -> void:
	if anchor == Vector3.INF or direction == Vector2.ZERO:
		return
	var ids: PackedInt32Array = selection.ids()
	var radius: int = 0
	for unit_id: int in ids:
		var unit: Unit = _world.get_unit(unit_id)
		if unit != null:
			radius = maxi(radius, unit.type.body_radius)
	if ids.is_empty() or radius == 0:
		return
	var slots: Array[FormationSlot] = Formations.slots(
		formation, ids.size(), _to_milli(anchor.x), _to_milli(anchor.z),
		roundi(direction.x * FixedMath.DIR_ONE), roundi(direction.y * FixedMath.DIR_ONE),
		Formations.spacing_for(radius)
	)
	for slot: FormationSlot in slots:
		var at: Vector3 = _ground(Vector2(slot.x, slot.z) / float(World.UNITS_PER_METER))
		if _camera.is_position_behind(at):
			continue
		draw_circle(_camera.unproject_position(at), 4.0, GHOST_COLOR)


# The selection's route: numbered points joined in order, back to the first
# for a loop.
func _draw_route() -> void:
	if selection.is_empty() or not _has_route(selection.ids()):
		return
	var points: Array[Vector3] = route_points()
	var screen: Array[Vector2] = []
	for p: Vector3 in points:
		if _camera.is_position_behind(p):
			return
		screen.append(_camera.unproject_position(p))
	var font: Font = get_theme_default_font()
	for i: int in screen.size():
		if i > 0:
			draw_line(screen[i - 1], screen[i], ROUTE_COLOR, 2.0)
		draw_circle(screen[i], 7.0, ROUTE_COLOR)
		draw_string(font, screen[i] + Vector2(-4.0, 5.0), str(i + 1), HORIZONTAL_ALIGNMENT_LEFT, -1, 12, Color.BLACK)
	if screen.size() > 2 and route_mode() == UnitRoute.Mode.LOOP:
		draw_line(screen[-1], screen[0], ROUTE_COLOR, 2.0)


# ---- picking -----------------------------------------------------------------


# The ground point under the screen point, or Vector3.INF if nothing is
# selected to order (unless `any`) or the ray misses the map.
func _pick_ground(at: Vector2, any: bool = false) -> Vector3:
	if selection.is_empty() and not any:
		return Vector3.INF
	return _picker.pick(_camera.project_ray_origin(at), _camera.project_ray_normal(at))


# A point on the ground (meters) at (x, z).
func _ground(p: Vector2) -> Vector3:
	var x: int = _to_milli(p.x)
	var z: int = _to_milli(p.y)
	var y: float = 0.0
	if _world != null and _world.terrain != null:
		y = _world.terrain.height_at(x, z) / float(World.UNITS_PER_METER)
	return Vector3(p.x, y, p.y)


static func _to_milli(meters: float) -> int:
	return roundi(meters * float(World.UNITS_PER_METER))


# Your units on screen that you may select.
func _visible_selectable() -> PackedInt32Array:
	var screen: Rect2 = get_viewport().get_visible_rect()
	var ids: PackedInt32Array = PackedInt32Array()
	for sprite: UnitSprite in _units.sprites():
		if not _selectable(sprite.unit_id) or _camera.is_position_behind(sprite.global_position):
			continue
		if screen.has_point(_screen_rect(sprite).get_center()):
			ids.append(sprite.unit_id)
	return ids


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


## The screen point of a unit's feet, for snapping a cursor to it; INF if it
## has no sprite or is behind the camera.
func screen_point_of(unit_id: int) -> Vector2:
	for sprite: UnitSprite in _units.sprites():
		if sprite.unit_id == unit_id:
			if _camera.is_position_behind(sprite.global_position):
				return Vector2.INF
			return _screen_rect(sprite).get_center()
	return Vector2.INF


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
