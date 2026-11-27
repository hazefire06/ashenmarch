class_name MapClick
extends RefCounted
## How a click on a map (the Tab map, the corner map) is read and what it
## does, shared so the two can't drift apart. A left click moves the camera;
## the order button (right click, or Option + click) sends the selection there
## as a move in its formation, Cmd/Ctrl making it an attack-move and Shift a
## route point, as in Myth II. With an order armed from the bar (a move,
## attack-move, ground attack or route point), a left click (or the pad's X)
## places that order there and disarms it, and the order button cancels it,
## as on the ground. A left click with nothing that can be given now (paused,
## nobody selected, an armed heal, which needs a unit) moves the camera.

## True to send the selection; false to move the camera.
var send: bool = false
var attack: bool = false
var queue: bool = false
## True for the mouse's order button (right click, or Option + click), which
## cancels an armed order instead of placing it.
var order_button: bool = false


func _init(
	send_it: bool = false, attack_move: bool = false, route_point: bool = false, by_order_button: bool = false
) -> void:
	send = send_it
	attack = attack_move
	queue = route_point
	order_button = by_order_button


## What a mouse button press on a map asks for, or null if it asks for nothing
## (a release, the wheel, another button).
static func from_event(click: InputEventMouseButton) -> MapClick:
	if click == null or not click.pressed:
		return null
	# The modified buttons first: Godot matches a mouse action whenever at
	# least its modifiers are held.
	var sends: bool = (
		click.is_action(InputBindings.ATTACK_MOVE) or click.is_action(InputBindings.COMMAND_ALT)
		or click.is_action(InputBindings.COMMAND)
	)
	if not sends and click.button_index != MOUSE_BUTTON_LEFT:
		return null
	var attack_move: bool = click.is_action(InputBindings.ATTACK_MOVE)
	return MapClick.new(sends, attack_move, click.shift_pressed, sends and not attack_move)


## Does it at `point` (x, z in meters): the armed order is placed there, or
## the camera's focus goes there, or the selection is sent there through
## `orders` (nothing, without one).
func perform(point: Vector2, terrain: Terrain, camera: RtsCamera, orders: SelectionController) -> void:
	var y: float = terrain.height_at(roundi(point.x * World.UNITS_PER_METER), roundi(point.y * World.UNITS_PER_METER))
	var ground: Vector3 = Vector3(point.x, y / World.UNITS_PER_METER, point.y)
	if orders != null and orders.armed_order != SelectionController.ArmedOrder.NONE:
		if order_button:
			orders.arm(SelectionController.ArmedOrder.NONE)
			return
		# An attack-move click gives its own order, as on the ground.
		if not (send and attack) and orders.place_armed_world(ground):
			return
	if not send:
		if camera != null:
			camera.focus_on(point)
		return
	if orders != null:
		orders.order_world(ground, attack, queue)
