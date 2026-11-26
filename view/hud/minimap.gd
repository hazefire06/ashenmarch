class_name Minimap
extends Control
## The corner map (Phase 12): always on, top right, SIZE_PX square (the
## interface scale, the window's content scale, scales it like the rest of
## the HUD). The same shaded, water-tinted picture as the Tab map (MapImage,
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
## the order button sends the selection there; the pad's cursor clicks it
## through click_map.
##
## The viewer is the side the player commands (in a replay, the side it is
## watched from). MainView calls after_step after every tick; spotting is
## re-evaluated every REFRESH_TICKS ticks, which is also when the dots are
## redrawn, besides when the camera moves or the selection changes. Display
## only: it reads the World and never writes it, except through the orders
## a click gives, which go through SelectionController like any other.

const SIZE_PX: int = 220
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
const DOT_RADIUS: float = 2.0
const VIEW_COLOR: Color = Color(1.0, 0.95, 0.6, 0.85)
const FLAG_RADIUS: float = 4.0
const FLAG_OUTLINE: Color = OverheadMap.MARKER_OUTLINE
## How far, in meters, a screen corner's ray may reach before the outline
## stops it: a corner above the horizon never meets the ground.
const VIEW_REACH: float = 600.0

## What the viewer's troops have spotted. One per map, for one viewer.
var memory: SpottingMemory = SpottingMemory.new()
var viewer: UnitType.Faction = UnitType.Faction.LIGHT

var _terrain: Terrain
var _camera: RtsCamera
var _world: World
var _orders: SelectionController
var _texture: ImageTexture
## The camera pose and screen size last drawn, to redraw only on a change.
var _drawn_view: Transform3D
var _drawn_screen: Vector2


func _ready() -> void:
	InputBindings.install()
	set_anchors_and_offsets_preset(Control.PRESET_TOP_RIGHT)
	offset_left = -(SIZE_PX + MARGIN)
	offset_right = -MARGIN
	offset_top = MARGIN
	offset_bottom = MARGIN + SIZE_PX
	size = Vector2(SIZE_PX, SIZE_PX)
	focus_mode = Control.FOCUS_NONE
	# STOP: a click or the wheel on the map is the map's, not the ground's.
	mouse_filter = Control.MOUSE_FILTER_STOP
	clip_contents = true
	texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR


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
	queue_redraw()


## The controller the map sends the selection with, and whose selection it
## shows in white. Without one the map only moves the camera.
func set_orders(orders: SelectionController) -> void:
	_orders = orders
	orders.selection.changed.connect(queue_redraw)


## The side whose units and spotting the map shows. A new side forgets the
## old one's spotting.
func set_viewer(side: UnitType.Faction) -> void:
	if side != viewer:
		memory.clear()
	viewer = side
	queue_redraw()


## After every tick: every REFRESH_TICKS ticks, while shown, spotting is
## brought up to date and the map redrawn.
func after_step() -> void:
	if _world == null or not visible or _world.tick % REFRESH_TICKS != 0:
		return
	memory.update(_world, viewer)
	queue_redraw()


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


## The dots the map draws, in drawing order (marks, enemies, then the
## viewer's units on top), as {"at": local position, "color": Color}.
func dots() -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	if _world == null or _terrain == null:
		return out
	for mark: Dictionary in memory.marks():
		var faded: Color = MARK_COLOR
		faded.a *= mark["alpha"]
		out.append({"at": map_to_local(mark["position"]), "color": faded})
	var mm: float = float(World.UNITS_PER_METER)
	for id: int in memory.spotted():
		var enemy: Unit = _world.get_unit(id)
		if enemy != null and enemy.is_alive():
			out.append({"at": map_to_local(Vector2(enemy.x, enemy.z) / mm), "color": ENEMY_COLOR})
	for unit: Unit in _world.units:
		if not unit.is_alive() or unit.faction != viewer:
			continue
		var selected: bool = _orders != null and _orders.selection.is_selected(unit.id)
		out.append({"at": map_to_local(Vector2(unit.x, unit.z) / mm), "color": SELECTED_COLOR if selected else OWN_COLOR})
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


func _process(_delta: float) -> void:
	if _camera == null or _camera.get_camera() == null:
		return
	var view: Transform3D = _camera.get_camera().global_transform
	var screen: Vector2 = get_viewport_rect().size
	# A skirmish's contested hill flashes in real time.
	var flashing: bool = _world != null and _world.skirmish != null
	if flashing or view != _drawn_view or screen != _drawn_screen:
		_drawn_view = view
		_drawn_screen = screen
		queue_redraw()


func _gui_input(event: InputEvent) -> void:
	var click: InputEventMouseButton = event as InputEventMouseButton
	var asked: MapClick = MapClick.from_event(click)
	if asked != null and click_map(click.position, asked.send, asked.attack, asked.queue):
		accept_event()


func _draw() -> void:
	if _texture == null:
		return
	draw_rect(Rect2(Vector2.ZERO, size), BACKDROP_COLOR)
	var rect: Rect2 = _map_rect()
	draw_texture_rect(_texture, rect, false)
	for mark: Dictionary in FlagsView.map_marks(_world):
		var at: Vector2 = map_to_local(mark["position"])
		draw_circle(at, FLAG_RADIUS, mark["color"])
		draw_arc(at, FLAG_RADIUS, 0.0, TAU, 16, FLAG_OUTLINE, 1.0)
	for dot: Dictionary in dots():
		draw_circle(dot["at"], DOT_RADIUS, dot["color"])
	var footprint: PackedVector2Array = camera_footprint()
	if footprint.size() == 4:
		var outline: PackedVector2Array = PackedVector2Array()
		for p: Vector2 in footprint:
			outline.append(map_to_local(p))
		outline.append(outline[0])
		draw_polyline(outline, VIEW_COLOR, 1.0)
	draw_rect(Rect2(Vector2.ZERO, size).grow(-0.5), BORDER_COLOR, false, 1.0)


# The picture fills the square, keeping the sample aspect ratio, centered.
func _map_rect() -> Rect2:
	return MapImage.fit_rect(size, minf(size.x, size.y), _terrain)
