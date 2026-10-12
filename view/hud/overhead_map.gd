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
## North-up: map +x is screen right and map +z is screen down, so z = 0 is the
## top edge. Texel (i, j) is sample (i, j), so texel centers sit on the sample
## points and the image spans half a cell beyond the map on every side.

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
## Hillshade light: from the north-west (-x, -z) and 45 degrees above.
const LIGHT_DIRECTION: Vector3 = Vector3(-0.5, 0.70710678, -0.5)
## Lambert 0..1 maps to this shade range; a flat surface lands near 1.0.
const SHADE_DARK: float = 0.65
const SHADE_LIGHT: float = 1.15

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
	_texture = ImageTexture.create_from_image(_build_image(terrain))
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
	if click == null or not click.pressed:
		return
	# The modified buttons first: Godot matches a mouse action whenever at
	# least its modifiers are held.
	var send: bool = (
		click.is_action(InputBindings.ATTACK_MOVE) or click.is_action(InputBindings.COMMAND_ALT)
		or click.is_action(InputBindings.COMMAND)
	)
	if not send and click.button_index != MOUSE_BUTTON_LEFT:
		return
	if click_at(click.position, send, click.is_action(InputBindings.ATTACK_MOVE), click.shift_pressed):
		accept_event()


## A click on the map at a screen point: moves the camera there, or (send)
## sends the selection there, attack-moving or as a route point if asked.
## False if the point is off the map.
func click_at(at: Vector2, send: bool, attack: bool = false, queue: bool = false) -> bool:
	if _terrain == null or _camera == null or not _map_rect().has_point(at):
		return false
	var point: Vector2 = _screen_to_world(at)
	if not send:
		_camera.focus_on(point)
	elif _orders != null:
		var y: float = _terrain.height_at(roundi(point.x * World.UNITS_PER_METER), roundi(point.y * World.UNITS_PER_METER))
		_orders.order_world(Vector3(point.x, y / World.UNITS_PER_METER, point.y), attack, queue)
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
	if _world == null or _world.skirmish == null or _terrain == null:
		return marks
	var runtime: SkirmishRuntime = _world.skirmish
	var flash: int = FlagsView.flash_side(Time.get_ticks_msec() / 1000.0)
	var mm: float = float(World.UNITS_PER_METER)
	for flag: int in FlagsView.shown_flags(runtime.rules):
		var at: Vector2 = _world_to_screen(
			Vector2(runtime.rules.flags[2 * flag], runtime.rules.flags[2 * flag + 1]) / mm
		)
		marks.append({"flag": flag, "at": at, "color": FlagsView.flag_color(runtime, flag, flash)})
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
	var box: float = minf(size.x, size.y) * SCREEN_FRACTION
	var texel: float = minf(box / _terrain.size_x, box / _terrain.size_z)
	var rect_size: Vector2 = Vector2(_terrain.size_x, _terrain.size_z) * texel
	return Rect2((size - rect_size) * 0.5, rect_size)


func _world_to_screen(world_xz: Vector2) -> Vector2:
	var rect: Rect2 = _map_rect()
	var cell: float = _terrain.cell_size / float(World.UNITS_PER_METER)
	var uv: Vector2 = world_xz / cell + Vector2(0.5, 0.5)
	return rect.position + uv / Vector2(_terrain.size_x, _terrain.size_z) * rect.size


func _screen_to_world(screen: Vector2) -> Vector2:
	var rect: Rect2 = _map_rect()
	var cell: float = _terrain.cell_size / float(World.UNITS_PER_METER)
	var uv: Vector2 = (screen - rect.position) / rect.size
	return (uv * Vector2(_terrain.size_x, _terrain.size_z) - Vector2(0.5, 0.5)) * cell


# Builds an RGB8 image with texel (i, j) = sample (i, j): banded height color,
# ground tint, water tint, and a hillshade from the neighboring heights. The
# colors depend only on the height band, ground type, and water depth, so
# they are looked up from a small table built through TerrainPalette instead
# of called per texel.
static func _build_image(terrain: Terrain) -> Image:
	var width: int = terrain.size_x
	var height: int = terrain.size_z
	var heights: PackedInt32Array = terrain.heights
	var water: PackedByteArray = terrain.water
	var ground: PackedByteArray = terrain.ground
	var min_h: int = heights[0]
	var max_h: int = heights[0]
	for k: int in heights.size():
		min_h = mini(min_h, heights[k])
		max_h = maxi(max_h, heights[k])
	var h_range: int = maxi(max_h - min_h, 1)

	var palette: Array[Color] = []
	for depth: int in Terrain.MAX_WATER_DEPTH + 1:
		for kind: int in Terrain.GROUND_COUNT:
			for band: int in TerrainPalette.BANDS:
				palette.append(TerrainPalette.ground_color((band + 0.5) / TerrainPalette.BANDS, depth, kind))

	# Heights and cell_size are both milli-units, so the ratio is the same
	# dimensionless slope as rise over run in meters.
	var cell: int = terrain.cell_size
	var light: Vector3 = LIGHT_DIRECTION.normalized()
	var data: PackedByteArray = PackedByteArray()
	data.resize(width * height * 3)
	for j: int in height:
		var j0: int = maxi(j - 1, 0)
		var j1: int = mini(j + 1, height - 1)
		for i: int in width:
			var i0: int = maxi(i - 1, 0)
			var i1: int = mini(i + 1, width - 1)
			var k: int = j * width + i
			var dhdx: float = float(heights[j * width + i1] - heights[j * width + i0]) / ((i1 - i0) * cell)
			var dhdz: float = float(heights[j1 * width + i] - heights[j0 * width + i]) / ((j1 - j0) * cell)
			var lambert: float = maxf(Vector3(-dhdx, 1.0, -dhdz).normalized().dot(light), 0.0)
			var shade: float = lerpf(SHADE_DARK, SHADE_LIGHT, lambert)
			var t: float = clampf(float(heights[k] - min_h) / h_range, 0.0, 0.9999)
			var band: int = int(t * TerrainPalette.BANDS)
			var depth: int = mini(water[k], Terrain.MAX_WATER_DEPTH)
			var color: Color = palette[(depth * Terrain.GROUND_COUNT + ground[k]) * TerrainPalette.BANDS + band]
			var o: int = k * 3
			data[o] = clampi(int(color.r * shade * 255.0 + 0.5), 0, 255)
			data[o + 1] = clampi(int(color.g * shade * 255.0 + 0.5), 0, 255)
			data[o + 2] = clampi(int(color.b * shade * 255.0 + 0.5), 0, 255)
	return Image.create_from_data(width, height, false, Image.FORMAT_RGB8, data)
