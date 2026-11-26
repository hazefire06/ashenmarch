class_name OverheadMap
extends Control
## The Tab overhead map: the heightmap drawn as a shaded, water-tinted image
## over a dimmed screen, with the camera's focus and facing marked and your
## units as dots. Click the map to move the camera there; the order button
## (right click, or Option + click) sends the selection there instead, as a
## move in its formation (Cmd/Ctrl: an attack-move; Shift: a route point), as
## in Myth II. The pad's cursor clicks it through click_at. In a skirmish the
## flags the mode uses are marked too, small discs in the color of whoever
## holds them.
##
## North-up, with the image and its placement from MapImage, and clicks read
## and done by MapClick, both shared with the corner map (Minimap).

const SCREEN_FRACTION: float = 0.8
const BACKDROP_COLOR: Color = Color(0.0, 0.0, 0.0, 0.65)
const BORDER_COLOR: Color = Color(0.92, 0.9, 0.82, 0.9)
const MARKER_FILL: Color = Color(1.0, 0.95, 0.6, 1.0)
const MARKER_OUTLINE: Color = Color(0.05, 0.05, 0.05, 0.9)
const WEDGE_COLOR: Color = Color(1.0, 0.95, 0.6, 0.35)
const MARKER_RADIUS: float = 5.0
const FLAG_MARK_RADIUS: float = 6.0
const UNIT_DOT_RADIUS: float = 2.5
const UNIT_DOT_COLOR: Color = Color(0.45, 1.0, 0.45, 1.0)
const SELECTED_DOT_COLOR: Color = Color(1.0, 1.0, 1.0, 1.0)
const WEDGE_LENGTH: float = 40.0
const WEDGE_HALF_ANGLE: float = deg_to_rad(30.0)

var _terrain: Terrain
var _camera: RtsCamera
var _world: World
var _orders: SelectionController
var _texture: ImageTexture


func _ready() -> void:
	InputBindings.install()
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	focus_mode = Control.FOCUS_NONE
	texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR
	visible = false
	visibility_changed.connect(_on_visibility_changed)
	_on_visibility_changed()


## Builds the map image once from the terrain. The camera supplies the focus
## marker and receives clicks. The world, if given, is read for a skirmish's
## flags; without one, or with a world that has no skirmish, none are drawn.
func setup(terrain: Terrain, camera: RtsCamera, world: World = null) -> void:
	_terrain = terrain
	_camera = camera
	_world = world
	_texture = ImageTexture.create_from_image(MapImage.build(terrain))
	queue_redraw()


## The controller the map sends the selection with, and whose side's units it
## draws. Without one the map only moves the camera.
func set_orders(orders: SelectionController) -> void:
	_orders = orders


## Shows the map if hidden, hides it if shown.
func toggle() -> void:
	visible = not visible


# Nodes receive unhandled input while hidden, which is how Tab reopens it.
func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed(InputBindings.TOGGLE_OVERHEAD_MAP):
		toggle()
		get_viewport().set_input_as_handled()


func _gui_input(event: InputEvent) -> void:
	var click: InputEventMouseButton = event as InputEventMouseButton
	var asked: MapClick = MapClick.from_event(click)
	if asked != null and click_at(click.position, asked.send, asked.attack, asked.queue):
		accept_event()


## A click on the map at a screen point: moves the camera there, or (send)
## sends the selection there, attack-moving or as a route point if asked.
## False if the point is off the map.
func click_at(at: Vector2, send: bool, attack: bool = false, queue: bool = false) -> bool:
	if _terrain == null or _camera == null or not _map_rect().has_point(at):
		return false
	MapClick.new(send, attack, queue).perform(_screen_to_world(at), _terrain, _camera, _orders)
	return true


func _process(_delta: float) -> void:
	queue_redraw()


func _draw() -> void:
	if _texture == null:
		return
	draw_rect(Rect2(Vector2.ZERO, size), BACKDROP_COLOR)
	var rect: Rect2 = _map_rect()
	draw_texture_rect(_texture, rect, false)
	draw_rect(rect, BORDER_COLOR, false, 1.0)
	_draw_units()
	if _camera != null:
		_draw_camera()
	for mark: Dictionary in flag_marks():
		var at: Vector2 = mark["at"]
		draw_circle(at, FLAG_MARK_RADIUS, mark["color"])
		draw_arc(at, FLAG_MARK_RADIUS, 0.0, TAU, 20, MARKER_OUTLINE, 1.0)


## The flags the map shows now, as {"flag": the rules index, "at": the screen
## position of its center, "color": what it is drawn in}: none outside a
## skirmish or in Body Count, the hill in King of the Hill, every flag in
## Capture the Flags (the same rule as the flags in the world, FlagsView). The
## contested hill flashes between the sides' colors in real time, view-only.
func flag_marks() -> Array[Dictionary]:
	var marks: Array[Dictionary] = []
	if _terrain == null:
		return marks
	for mark: Dictionary in FlagsView.map_marks(_world):
		marks.append({"flag": mark["flag"], "at": _world_to_screen(mark["position"]), "color": mark["color"]})
	return marks


# The side the player commands: a dot for each living unit, selected ones
# white.
func _draw_units() -> void:
	if _world == null or _orders == null:
		return
	var mm: float = float(World.UNITS_PER_METER)
	for unit: Unit in _world.units:
		if not unit.is_alive() or unit.faction != _orders.side:
			continue
		var color: Color = SELECTED_DOT_COLOR if _orders.selection.is_selected(unit.id) else UNIT_DOT_COLOR
		draw_circle(_world_to_screen(Vector2(unit.x, unit.z) / mm), UNIT_DOT_RADIUS, color)


# The camera's focus and the way it faces.
func _draw_camera() -> void:
	var center: Vector2 = _world_to_screen(Vector2(_camera.focus.x, _camera.focus.z))
	# Facing on the ground is -(sin yaw, cos yaw) in (x, z); screen y is z.
	var facing: Vector2 = Vector2(-sin(_camera.yaw), -cos(_camera.yaw))
	var wedge: PackedVector2Array = PackedVector2Array([
		center,
		center + facing.rotated(-WEDGE_HALF_ANGLE) * WEDGE_LENGTH,
		center + facing.rotated(WEDGE_HALF_ANGLE) * WEDGE_LENGTH,
	])
	draw_colored_polygon(wedge, WEDGE_COLOR)
	draw_circle(center, MARKER_RADIUS, MARKER_FILL)
	draw_arc(center, MARKER_RADIUS, 0.0, TAU, 20, MARKER_OUTLINE, 1.5)


func _on_visibility_changed() -> void:
	# STOP keeps the wheel from zooming the camera through the open map.
	mouse_filter = Control.MOUSE_FILTER_STOP if visible else Control.MOUSE_FILTER_IGNORE
	set_process(visible)
	if visible:
		queue_redraw()


# Screen rectangle of the map image: as large as fits in SCREEN_FRACTION of
# the smaller screen dimension, centered, keeping the sample aspect ratio.
func _map_rect() -> Rect2:
	return MapImage.fit_rect(size, minf(size.x, size.y) * SCREEN_FRACTION, _terrain)


func _world_to_screen(world_xz: Vector2) -> Vector2:
	return MapImage.map_to_rect(world_xz, _map_rect(), _terrain)


func _screen_to_world(screen: Vector2) -> Vector2:
	return MapImage.rect_to_map(screen, _map_rect(), _terrain)

