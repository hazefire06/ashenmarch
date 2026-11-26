class_name MapClick
extends RefCounted
## How a click on a map (the Tab map, the corner map) is read and what it
## does, shared so the two can't drift apart. A left click moves the camera;
## the order button (right click, or Option + click) sends the selection there
## as a move in its formation, Cmd/Ctrl making it an attack-move and Shift a
## route point, as in Myth II. With an order armed from the bar (a move,
## attack-move, ground attack or route point), any click places that order
## there instead and disarms it, as a click on the ground does.

## True to send the selection; false to move the camera.
var send: bool = false
var attack: bool = false
var queue: bool = false


func _init(send_it: bool = false, attack_move: bool = false, route_point: bool = false) -> void:
	send = send_it
	attack = attack_move
	queue = route_point


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
	return MapClick.new(sends, click.is_action(InputBindings.ATTACK_MOVE), click.shift_pressed)


## Does it at `point` (x, z in meters): the armed order is placed there, or
## the camera's focus goes there, or the selection is sent there through
## `orders` (nothing, without one).
func perform(point: Vector2, terrain: Terrain, camera: RtsCamera, orders: SelectionController) -> void:
	var y: float = terrain.height_at(roundi(point.x * World.UNITS_PER_METER), roundi(point.y * World.UNITS_PER_METER))
	var ground: Vector3 = Vector3(point.x, y / World.UNITS_PER_METER, point.y)
	if orders != null and orders.place_armed_world(ground):
		return
	if not send:
		if camera != null:
			camera.focus_on(point)
		return
	if orders != null:
		orders.order_world(ground, attack, queue)
