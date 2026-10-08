class_name RtsCamera
extends Node3D
## RTS camera rig. The rig node sits at the focus point and owns a Camera3D
## child that orbits it, so it must live under an untransformed parent. The
## rig reads the terrain and never writes to it.
##
## Everything here is in float meters, Y up, on the map's x/z plane. yaw 0
## puts the camera on the +Z side of the focus looking toward -Z (north, the
## top of the overhead map). Yaw grows counter-clockwise seen from above, so
## increasing yaw turns the view to the left.
##
## Pitch follows zoom: PITCH_NEAR above horizontal at MIN_DISTANCE, PITCH_FAR
## at MAX_DISTANCE.

const MIN_DISTANCE: float = 8.0
const MAX_DISTANCE: float = 250.0
const DEFAULT_DISTANCE: float = 90.0
const PITCH_NEAR: float = deg_to_rad(35.0)
const PITCH_FAR: float = deg_to_rad(65.0)
const NEAR_PLANE: float = 0.25
const FAR_PLANE: float = 2000.0
## Meters per second of pan, per meter of distance.
const MOVE_SPEED_PER_METER: float = 1.0
const ORBIT_SPEED: float = deg_to_rad(90.0)
const SWIVEL_SPEED: float = deg_to_rad(60.0)
## Distance multiplier per wheel notch (divide to zoom in).
const WHEEL_ZOOM_FACTOR: float = 1.15
## Distance multiplier per second while V or C is held.
const HELD_ZOOM_PER_SECOND: float = 2.0
const ZOOM_SMOOTH_RATE: float = 12.0
const HEIGHT_SMOOTH_RATE: float = 8.0
## The camera never sinks closer than this to the ground beneath it.
const MIN_CLEARANCE: float = 2.0
## Edge scroll: how close to a window edge (pixels) the mouse must be to pan.
const EDGE_SCROLL_MARGIN: float = 12.0
## Corner camera: how far into a corner (pixels each way) turns or orbits.
const CORNER_SIZE: float = 48.0
## How fast glide_to closes on its point, per second, and how close is there.
const GLIDE_RATE: float = 8.0
const GLIDE_DONE: float = 0.05

## Point the camera looks at. y is the smoothed terrain height beneath it.
var focus: Vector3 = Vector3.ZERO
## Radians. See the class comment for the convention.
var yaw: float = 0.0
## Meters from the focus to the camera.
var distance: float = DEFAULT_DISTANCE
## Whether the camera pans when the mouse is within EDGE_SCROLL_MARGIN pixels
## of a window edge, as WASD does (the Settings toggle), except while the mouse
## is over a button (reaching for the control bar's buttons mustn't drag the
## map; the bar keeps EDGE_SCROLL_MARGIN of padding under them, so the bottom
## edge itself still scrolls). Off by default: it needs a window the mouse can't stray out of,
## and a dev who drags a window around shouldn't lose the map.
var edge_scroll: bool = false
## Myth II's corner preference (Settings: Corner camera): the mouse in a top
## corner turns the camera in place toward that side, in a bottom corner
## orbits it, instead of panning. Like edge scroll, not over a button.
var corner_camera: bool = false
## The pad's share of the camera, set by PadController every frame: pan (x right, y forward, each -1..1, the right stick and the cursor
## pushed into an edge), orbit (-1 left .. 1 right, the triggers) and zoom
## (-1 out .. 1 in, R3 held with the right stick).
var pad_pan: Vector2 = Vector2.ZERO
var pad_orbit: float = 0.0
var pad_zoom: float = 0.0

var _terrain: Terrain
var _camera: Camera3D
var _target_distance: float = DEFAULT_DISTANCE
## False while the mouse is outside the window, so a cursor that left through
## the edge zone doesn't leave the camera panning there.
var _mouse_in_window: bool = true
# glide_to's destination, while gliding.
var _gliding: bool = false
var _glide_to: Vector2 = Vector2.ZERO


func _ready() -> void:
	InputBindings.install()
	_camera = Camera3D.new()
	_camera.near = NEAR_PLANE
	_camera.far = FAR_PLANE
	add_child(_camera)
	_camera.current = true
	_apply_transform()


## Binds the rig to a terrain and centers it on the map at the default zoom.
func setup(terrain: Terrain) -> void:
	_terrain = terrain
	if _terrain == null:
		return
	set_pose(
		Vector2(_extent_x_m() * 0.5, _extent_z_m() * 0.5), 0.0, DEFAULT_DISTANCE
	)


## The Camera3D this rig drives. Null until the rig has entered the tree.
func get_camera() -> Camera3D:
	return _camera


## Moves the focus to point (x, z in meters), clamped to the map. The focus
## height eases to the new ground level over the next frames.
func focus_on(point: Vector2) -> void:
	if _terrain == null:
		return
	var clamped: Vector2 = _clamp_to_map(point)
	focus.x = clamped.x
	focus.z = clamped.y


## Moves the focus smoothly to point (x, z in meters, clamped) over the next
## frames: the center-on-selection key. Moving the camera by hand stops it.
func glide_to(point: Vector2) -> void:
	if _terrain == null:
		return
	_glide_to = _clamp_to_map(point)
	_gliding = true


## True while glide_to is still on its way.
func is_gliding() -> bool:
	return _gliding


## Sets focus (x, z in meters, clamped), yaw and distance at once, snaps the
## focus height and updates the transform immediately, so a scripted capture
## needs no frames to settle.
func set_pose(point: Vector2, new_yaw: float, new_distance: float) -> void:
	if _terrain == null:
		push_error("RtsCamera.set_pose() called before setup()")
		return
	var clamped: Vector2 = _clamp_to_map(point)
	yaw = new_yaw
	distance = clampf(new_distance, MIN_DISTANCE, MAX_DISTANCE)
	_target_distance = distance
	focus = Vector3(clamped.x, _ground_height(clamped.x, clamped.y), clamped.y)
	_apply_transform()


func _notification(what: int) -> void:
	if what == NOTIFICATION_WM_MOUSE_EXIT:
		_mouse_in_window = false
	elif what == NOTIFICATION_WM_MOUSE_ENTER:
		_mouse_in_window = true


## What a mouse at `mouse` in a window `size` pixels across asks of the corner
## camera: (turn, orbit), each -1 (left), 1 (right) or 0. Top corners turn,
## bottom corners orbit; anywhere else, nothing.
static func corner_turn(mouse: Vector2, size: Vector2, corner: float = CORNER_SIZE) -> Vector2:
	if not Rect2(Vector2.ZERO, size).has_point(mouse):
		return Vector2.ZERO
	var side: float = 0.0
	if mouse.x < corner:
		side = -1.0
	elif mouse.x > size.x - corner:
		side = 1.0
	if side == 0.0:
		return Vector2.ZERO
	if mouse.y < corner:
		return Vector2(side, 0.0)
	if mouse.y > size.y - corner:
		return Vector2(0.0, side)
	return Vector2.ZERO


## The pan direction a mouse at `mouse` asks for when the window is `size`
## pixels across: x +1 right and -1 left, y +1 forward (the top edge) and -1
## back (the bottom edge), 0 away from the edges. A corner asks for both. A
## mouse outside the window (`size`'s rectangle) asks for nothing.
static func edge_direction(mouse: Vector2, size: Vector2, margin: float = EDGE_SCROLL_MARGIN) -> Vector2:
	if not Rect2(Vector2.ZERO, size).has_point(mouse):
		return Vector2.ZERO
	var out: Vector2 = Vector2.ZERO
	if mouse.x < margin:
		out.x -= 1.0
	elif mouse.x > size.x - margin:
		out.x += 1.0
	if mouse.y < margin:
		out.y += 1.0
	elif mouse.y > size.y - margin:
		out.y -= 1.0
	return out


func _process(delta: float) -> void:
	if _terrain == null:
		return
	_update_zoom(delta)
	# Q/E orbit the camera around the focus. Decreasing yaw swings the camera
	# toward its own left, so Q (the left key) lowers yaw.
	var orbit: float = Input.get_axis(InputBindings.CAM_ORBIT_LEFT, InputBindings.CAM_ORBIT_RIGHT) + pad_orbit
	# Z/X turn the camera in place; Z turns the view left (raises yaw).
	var swivel: float = Input.get_axis(InputBindings.CAM_SWIVEL_RIGHT, InputBindings.CAM_SWIVEL_LEFT)
	var corner: Vector2 = _corner()
	swivel -= corner.x
	orbit += corner.y
	yaw += clampf(orbit, -1.0, 1.0) * ORBIT_SPEED * delta
	_swivel(clampf(swivel, -1.0, 1.0) * SWIVEL_SPEED * delta)
	_move(delta)
	_glide(delta)
	var blend: float = 1.0 - exp(-HEIGHT_SMOOTH_RATE * delta)
	focus.y = lerpf(focus.y, _ground_height(focus.x, focus.z), blend)
	_apply_transform()


# Wheel notches arrive as an instant press and release, so polling in
# _process would miss them.
func _unhandled_input(event: InputEvent) -> void:
	if _terrain == null:
		return
	# Smooth-scrolling wheels report fractional notches in factor; 0 means one.
	var wheel: InputEventMouseButton = event as InputEventMouseButton
	var notches: float = wheel.factor if wheel != null and wheel.factor > 0.0 else 1.0
	if event.is_action_pressed(InputBindings.CAM_ZOOM_IN_STEP):
		_target_distance /= pow(WHEEL_ZOOM_FACTOR, notches)
	elif event.is_action_pressed(InputBindings.CAM_ZOOM_OUT_STEP):
		_target_distance *= pow(WHEEL_ZOOM_FACTOR, notches)
	else:
		return
	_target_distance = clampf(_target_distance, MIN_DISTANCE, MAX_DISTANCE)
	get_viewport().set_input_as_handled()


func _update_zoom(delta: float) -> void:
	var held: float = clampf(Input.get_axis(InputBindings.CAM_ZOOM_OUT, InputBindings.CAM_ZOOM_IN) + pad_zoom, -1.0, 1.0)
	if held != 0.0:
		var scale_factor: float = pow(HELD_ZOOM_PER_SECOND, -held * delta)
		_target_distance = clampf(_target_distance * scale_factor, MIN_DISTANCE, MAX_DISTANCE)
	distance = lerpf(distance, _target_distance, 1.0 - exp(-ZOOM_SMOOTH_RATE * delta))
	if absf(distance - _target_distance) < 0.001:
		distance = _target_distance


# Turns the camera in place: its x/z stays put and the focus swings around it.
func _swivel(dyaw: float) -> void:
	if dyaw == 0.0:
		return
	var reach: float = _horizontal_reach()
	var camera_xz: Vector2 = Vector2(focus.x, focus.z) + _offset_xz(reach)
	yaw += dyaw
	var new_focus: Vector2 = _clamp_to_map(camera_xz - _offset_xz(reach))
	focus.x = new_focus.x
	focus.z = new_focus.y


func _move(delta: float) -> void:
	var input: Vector2 = Vector2(
		Input.get_axis(InputBindings.CAM_LEFT, InputBindings.CAM_RIGHT),
		Input.get_axis(InputBindings.CAM_BACK, InputBindings.CAM_FORWARD),
	)
	# Not over a button: the control bar fills the bottom of the window, and
	# reaching for its buttons shouldn't drag the map. (Anything else under the
	# mouse, the bar's own padding included, still scrolls.)
	if edge_scroll and _mouse_in_window and not _mouse_over_button() and _corner() == Vector2.ZERO:
		input += edge_direction(_mouse_position(), get_viewport().get_visible_rect().size)
	input += pad_pan
	input = input.limit_length(1.0)
	if input == Vector2.ZERO:
		return
	_gliding = false
	var forward: Vector2 = -_offset_xz(1.0)
	var right: Vector2 = Vector2(-forward.y, forward.x)
	var step: Vector2 = (right * input.x + forward * input.y) * (distance * MOVE_SPEED_PER_METER * delta)
	focus.x += step.x
	focus.z += step.y
	var clamped: Vector2 = _clamp_to_map(Vector2(focus.x, focus.z))
	focus.x = clamped.x
	focus.z = clamped.y


func _glide(delta: float) -> void:
	if not _gliding:
		return
	var at: Vector2 = Vector2(focus.x, focus.z)
	var next: Vector2 = at.lerp(_glide_to, 1.0 - exp(-GLIDE_RATE * delta))
	if next.distance_to(_glide_to) < GLIDE_DONE:
		next = _glide_to
		_gliding = false
	focus.x = next.x
	focus.z = next.y


# What the corner camera asks for now: (turn, orbit), or zero when it is off,
# the mouse is out of the window or over a button.
func _corner() -> Vector2:
	if not corner_camera or not _mouse_in_window or _mouse_over_button():
		return Vector2.ZERO
	return corner_turn(_mouse_position(), get_viewport().get_visible_rect().size)


# Where the mouse is, and whether a button is under it. Methods of their own so
# a test can say where the mouse is: the headless window has none.
func _mouse_position() -> Vector2:
	return get_viewport().get_mouse_position()


func _mouse_over_button() -> bool:
	return get_viewport().gui_get_hovered_control() is BaseButton


func _apply_transform() -> void:
	if _camera == null or _terrain == null:
		return
	var pitch: float = _pitch()
	var reach: float = _horizontal_reach()
	var offset_xz: Vector2 = _offset_xz(reach)
	var offset: Vector3 = Vector3(offset_xz.x, distance * sin(pitch), offset_xz.y)
	var min_y: float = _ground_height(focus.x + offset.x, focus.z + offset.z) + MIN_CLEARANCE
	offset.y = maxf(offset.y, min_y - focus.y)
	position = focus
	var pose: Transform3D = Transform3D(Basis.IDENTITY, offset)
	# look_at needs a direction that isn't parallel to up; reach is never
	# near zero with the pitch limits, but a degenerate basis would poison the
	# whole transform, so guard anyway.
	if not offset.cross(Vector3.UP).is_zero_approx():
		pose = pose.looking_at(Vector3.ZERO, Vector3.UP)
	_camera.transform = pose


func _pitch() -> float:
	var t: float = clampf(inverse_lerp(MIN_DISTANCE, MAX_DISTANCE, distance), 0.0, 1.0)
	return lerpf(PITCH_NEAR, PITCH_FAR, t)


func _horizontal_reach() -> float:
	return distance * cos(_pitch())


# Horizontal offset from the focus to the camera: the +Z side at yaw 0.
func _offset_xz(reach: float) -> Vector2:
	return Vector2(sin(yaw), cos(yaw)) * reach


func _ground_height(x: float, z: float) -> float:
	var x_mm: int = int(roundf(x * World.UNITS_PER_METER))
	var z_mm: int = int(roundf(z * World.UNITS_PER_METER))
	return _terrain.height_at(x_mm, z_mm) / float(World.UNITS_PER_METER)


func _clamp_to_map(point: Vector2) -> Vector2:
	return Vector2(clampf(point.x, 0.0, _extent_x_m()), clampf(point.y, 0.0, _extent_z_m()))


func _extent_x_m() -> float:
	return _terrain.extent_x() / float(World.UNITS_PER_METER)


func _extent_z_m() -> float:
	return _terrain.extent_z() / float(World.UNITS_PER_METER)
