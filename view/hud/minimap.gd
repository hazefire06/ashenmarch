class_name Minimap
extends Control
## The corner map (Phase 12): always on, top right, SIZE_PX square (the
## interface scale, the window's content scale, scales it like the rest of
## the HUD), but never more than MAX_HEIGHT_SHARE of the screen's height or
## MAX_WIDTH_SHARE of its width, so a large interface scale leaves room for
## the rest. The same shaded, water-tinted picture as the Tab map (MapImage,
## built once per map load), north-up, with:
## - the viewer's living units as green dots, selected ones white;
## - enemies the viewer's troops have spotted as red dots, at where they are
##   now, and dim red marks where others were last seen, fading over 10 s
##   (SpottingMemory);
## - the camera's view as an outline: the four screen corners cast onto the
##   ground at the focus's height;
## - a skirmish's flags, as the Tab map marks them;
## - a thin border.
## Clicks work as on the Tab map (MapClick): a left click moves the camera,
## the order button sends the selection there, an armed order is placed there;
## the pad's cursor clicks it through click_map. The wheel passes through to
## the camera's zoom.
##
## The viewer is the side the player commands (in a replay, the side it is
## watched from). MainView calls after_step after every tick; spotting is
## re-evaluated every REFRESH_TICKS ticks. What is drawn (dots, flags, the
## camera outline) is worked out then, and when the camera moves, the
## selection changes or the contested hill's flash turns, into arrays that
## _draw only reads; nothing else redraws it. Hidden, it does no work. Display
## only: it reads the World and never writes it, except through the orders
## a click gives, which go through SelectionController like any other.

const SIZE_PX: int = 220
## The most of the screen's height and width the map may take: at 1280x720
## the height share still allows the full SIZE_PX.
const MAX_HEIGHT_SHARE: float = 0.31
const MAX_WIDTH_SHARE: float = 0.25
## Pixels from the top and right edges of the screen.
const MARGIN: float = 12.0
## Ticks between spotting updates (about 0.27 s).
const REFRESH_TICKS: int = 8
const BACKDROP_COLOR: Color = Color(0.0, 0.0, 0.0, 0.55)
const BORDER_COLOR: Color = OverheadMap.BORDER_COLOR
const OWN_COLOR: Color = OverheadMap.UNIT_DOT_COLOR
const SELECTED_COLOR: Color = OverheadMap.SELECTED_DOT_COLOR
const ENEMY_COLOR: Color = Color(1.0, 0.28, 0.22, 1.0)
## A last-seen mark's color at full strength; its alpha fades with the mark.
const MARK_COLOR: Color = Color(0.8, 0.2, 0.16, 0.6)
## Half the side of a unit dot, a square (draw_circle costs a draw call per dot).
const DOT_RADIUS: float = 2.0
const VIEW_COLOR: Color = Color(1.0, 0.95, 0.6, 0.85)
const FLAG_RADIUS: float = 4.0
const FLAG_OUTLINE: Color = OverheadMap.MARKER_OUTLINE
## How far, in meters, a screen corner's ray may reach before the outline
## stops it: a corner above the horizon never meets the ground.
const VIEW_REACH: float = 600.0

## The map's size or place changed (a new screen size or interface scale):
## whatever is laid out around it should follow.
signal placed

## Real seconds now, for the contested hill's flash; a test sets its own.
var clock: Callable = func() -> float: return Time.get_ticks_msec() / 1000.0
## What the viewer's troops have spotted. One per map, for one viewer.
var memory: SpottingMemory = SpottingMemory.new()
var viewer: UnitType.Faction = UnitType.Faction.LIGHT

var _terrain: Terrain
var _camera: RtsCamera
var _world: World
var _orders: SelectionController
var _texture: ImageTexture
## The camera pose, screen size and hill flash last drawn, to redraw only on a
## change.
var _drawn_view: Transform3D
var _drawn_screen: Vector2
var _drawn_flash: int = -1
## What _draw draws, worked out by _refresh: dots (positions and colors, in
## drawing order), flags (positions and colors), and the camera's outline
## (closed; empty without a camera).
var _dot_at: PackedVector2Array = PackedVector2Array()
var _dot_color: PackedColorArray = PackedColorArray()
var _flag_at: PackedVector2Array = PackedVector2Array()
var _flag_color: PackedColorArray = PackedColorArray()
var _outline: PackedVector2Array = PackedVector2Array()


func _ready() -> void:
	InputBindings.install()
	focus_mode = Control.FOCUS_NONE
	# A click on the map is the map's, not the ground's (_gui_input accepts
	# every button but the wheel, which goes on to the camera).
	mouse_filter = Control.MOUSE_FILTER_STOP
	clip_contents = true
	texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR
	fit(get_viewport_rect().size)
	get_viewport().size_changed.connect(func() -> void: fit(get_viewport_rect().size))
	visibility_changed.connect(_on_visibility_changed)
	set_process(visible)


## Sizes and places the map for a screen of `screen` (in interface units):
## SIZE_PX square, or less on a small or heavily scaled screen, MARGIN in from
## the top-right corner.
func fit(screen: Vector2) -> void:
	var side: float = minf(SIZE_PX, minf(screen.y * MAX_HEIGHT_SHARE, screen.x * MAX_WIDTH_SHARE))
	set_anchors_preset(Control.PRESET_TOP_RIGHT)
	offset_left = -(side + MARGIN)
	offset_right = -MARGIN
	offset_top = MARGIN
	offset_bottom = MARGIN + side
	_refresh()
	placed.emit()


## Builds the picture once from the terrain and forgets what was spotted (a
## new map is a new world, and the marks are keyed by unit id). The camera
## supplies the outline and is moved by clicks; the world is read for units,
## spotting and a skirmish's flags.
func setup(terrain: Terrain, camera: RtsCamera, world: World) -> void:
	_terrain = terrain
	_camera = camera
	_world = world
	_texture = ImageTexture.create_from_image(MapImage.build(terrain))
	memory.clear()
	_refresh()


## The controller the map sends the selection with, and whose selection it
## shows in white. Without one the map only moves the camera.
func set_orders(orders: SelectionController) -> void:
	_orders = orders
	orders.selection.changed.connect(_refresh)


## The side whose units and spotting the map shows. A new side forgets the
## old one's spotting.
func set_viewer(side: UnitType.Faction) -> void:
	if side != viewer:
		memory.clear()
	viewer = side
	_refresh()


## After every tick: every REFRESH_TICKS ticks, while shown, spotting is
## brought up to date and the map redrawn.
func after_step() -> void:
	if _world == null or not visible or _world.tick % REFRESH_TICKS != 0:
		return
	memory.update(_world, viewer)
	_refresh()


## A map point (x, z in meters) in this control's own coordinates.
func map_to_local(p: Vector2) -> Vector2:
	return MapImage.map_to_rect(p, _map_rect(), _terrain)


## A point in this control's own coordinates as a map point (x, z in meters).
func local_to_map(p: Vector2) -> Vector2:
	return MapImage.rect_to_map(p, _map_rect(), _terrain)


## A mouse button pressed at `local` with `mods` (KEY_MASK_* bits) held, read
## the same way as a real click on the map (and on the Tab map).
func click_at(local: Vector2, button: MouseButton, mods: int) -> void:
	var event: InputEventMouseButton = InputEventMouseButton.new()
	event.button_index = button
	event.pressed = true
	event.position = local
	event.shift_pressed = mods & KEY_MASK_SHIFT != 0
	event.alt_pressed = mods & KEY_MASK_ALT != 0
	event.ctrl_pressed = mods & KEY_MASK_CTRL != 0
	event.meta_pressed = mods & KEY_MASK_META != 0
	var asked: MapClick = MapClick.from_event(event)
	if asked != null:
		click_map(local, asked.send, asked.attack, asked.queue)


## A click at `local` already read: moves the camera there, or (send) sends
## the selection there, attack-moving or as a route point if asked. The pad's
## cursor clicks through this. False if the point is off the map.
func click_map(local: Vector2, send: bool, attack: bool = false, queue: bool = false) -> bool:
	if _terrain == null or not _map_rect().has_point(local):
		return false
	MapClick.new(send, attack, queue).perform(local_to_map(local), _terrain, _camera, _orders)
	return true


## The dots the map draws now, in drawing order (marks, enemies, then the
## viewer's units on top), as {"at": local position, "color": Color}. For
## tests; _draw reads the same arrays directly.
func dots() -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	for i: int in _dot_at.size():
		out.append({"at": _dot_at[i], "color": _dot_color[i]})
	return out


## The ground the screen shows, as the map points (x, z in meters) under its
## top-left, top-right, bottom-right and bottom-left corners: each corner's
## ray meets the plane at the focus's height, or, aimed above it, is stopped
## VIEW_REACH meters out. Empty without a camera.
func camera_footprint() -> PackedVector2Array:
	var corners: PackedVector2Array = PackedVector2Array()
	if _camera == null or _camera.get_camera() == null:
		return corners
	var eye: Camera3D = _camera.get_camera()
	var screen: Vector2 = eye.get_viewport().get_visible_rect().size
	var ground: float = _camera.focus.y
	for corner: Vector2 in [Vector2.ZERO, Vector2(screen.x, 0.0), screen, Vector2(0.0, screen.y)]:
		var origin: Vector3 = eye.project_ray_origin(corner)
		var ray: Vector3 = eye.project_ray_normal(corner)
		var flat: Vector2 = Vector2(ray.x, ray.z)
		var reach: float = VIEW_REACH
		if ray.y < 0.0:
			reach = minf((origin.y - ground) / -ray.y * flat.length(), VIEW_REACH)
		var along: Vector2 = flat.normalized() * reach if not flat.is_zero_approx() else Vector2.ZERO
		corners.append(Vector2(origin.x, origin.z) + along)
	return corners


# Only while shown (set_process follows visibility): redraws when the camera
# has moved, or the contested hill's flash has turned.
func _process(_delta: float) -> void:
	if _camera == null or _camera.get_camera() == null:
		return
	var view: Transform3D = _camera.get_camera().global_transform
	var screen: Vector2 = get_viewport_rect().size
	var flash: int = _contested_flash()
	if view != _drawn_view or screen != _drawn_screen or flash != _drawn_flash:
		_drawn_view = view
		_drawn_screen = screen
		_drawn_flash = flash
		_refresh()


# The side the contested hill shows now, or -1 when no hill is contested.
func _contested_flash() -> int:
	if _world == null or _world.skirmish == null:
		return -1
	var runtime: SkirmishRuntime = _world.skirmish
	if runtime.rules.mode != SkirmishRules.Mode.KING_OF_THE_HILL or runtime.hill_holder != SkirmishRuntime.CONTESTED:
		return -1
	return FlagsView.flash_side(clock.call())


# Every button press or release is the map's; the wheel goes on to the camera.
func _gui_input(event: InputEvent) -> void:
	var click: InputEventMouseButton = event as InputEventMouseButton
	if click == null or _is_wheel(click.button_index):
		return
	var asked: MapClick = MapClick.from_event(click)
	if asked != null:
		click_map(click.position, asked.send, asked.attack, asked.queue)
	accept_event()


static func _is_wheel(button: MouseButton) -> bool:
	return button in [MOUSE_BUTTON_WHEEL_UP, MOUSE_BUTTON_WHEEL_DOWN, MOUSE_BUTTON_WHEEL_LEFT, MOUSE_BUTTON_WHEEL_RIGHT]


# Works out what _draw draws from the world, the memory, the selection and
# the camera as they are now, and asks for a redraw.
func _refresh() -> void:
	_dot_at.clear()
	_dot_color.clear()
	_flag_at.clear()
	_flag_color.clear()
	_outline.clear()
	queue_redraw()
	if _terrain == null:
		return
	if _world != null:
		_collect_dots()
		for mark: Dictionary in FlagsView.map_marks(_world):
			_flag_at.append(map_to_local(mark["position"]))
			_flag_color.append(mark["color"])
	var footprint: PackedVector2Array = camera_footprint()
	if footprint.size() == 4:
		for p: Vector2 in footprint:
			_outline.append(map_to_local(p))
		_outline.append(_outline[0])


func _collect_dots() -> void:
	for mark: Dictionary in memory.marks():
		var faded: Color = MARK_COLOR
		faded.a *= mark["alpha"]
		_dot_at.append(map_to_local(mark["position"]))
		_dot_color.append(faded)
	var mm: float = float(World.UNITS_PER_METER)
	for id: int in memory.spotted():
		var enemy: Unit = _world.get_unit(id)
		if enemy != null and enemy.is_alive():
			_dot_at.append(map_to_local(Vector2(enemy.x, enemy.z) / mm))
			_dot_color.append(ENEMY_COLOR)
	for unit: Unit in _world.units:
		if not unit.is_alive() or unit.faction != viewer:
			continue
		var selected: bool = _orders != null and _orders.selection.is_selected(unit.id)
		_dot_at.append(map_to_local(Vector2(unit.x, unit.z) / mm))
		_dot_color.append(SELECTED_COLOR if selected else OWN_COLOR)


# Reads the arrays _refresh filled; allocates nothing.
func _draw() -> void:
	if _texture == null:
		return
	draw_rect(Rect2(Vector2.ZERO, size), BACKDROP_COLOR)
	draw_texture_rect(_texture, _map_rect(), false)
	for i: int in _flag_at.size():
		draw_circle(_flag_at[i], FLAG_RADIUS, _flag_color[i])
		draw_arc(_flag_at[i], FLAG_RADIUS, 0.0, TAU, 16, FLAG_OUTLINE, 1.0)
	for i: int in _dot_at.size():
		draw_rect(Rect2(_dot_at[i] - Vector2(DOT_RADIUS, DOT_RADIUS), Vector2(DOT_RADIUS, DOT_RADIUS) * 2.0), _dot_color[i])
	if not _outline.is_empty():
		draw_polyline(_outline, VIEW_COLOR, 1.0)
	draw_rect(Rect2(Vector2.ZERO, size).grow(-0.5), BORDER_COLOR, false, 1.0)


func _on_visibility_changed() -> void:
	set_process(visible)
	if visible:
		_refresh()


# The picture fills the square, keeping the sample aspect ratio, centered.
func _map_rect() -> Rect2:
	return MapImage.fit_rect(size, minf(size.x, size.y), _terrain)
