extends GutTest
## RtsCamera.edge_scroll: with it on, the mouse within 12 px of a window edge
## pans the camera that way, like WASD. Off by default. edge_direction is the
## pure part: which way a mouse position asks to pan.

const SIZE: Vector2 = Vector2(1000.0, 600.0)


func test_the_middle_of_the_window_asks_for_nothing() -> void:
	assert_eq(RtsCamera.edge_direction(Vector2(500.0, 300.0), SIZE), Vector2.ZERO)


func test_each_edge_pans_its_way() -> void:
	assert_eq(RtsCamera.edge_direction(Vector2(5.0, 300.0), SIZE), Vector2(-1.0, 0.0), "left")
	assert_eq(RtsCamera.edge_direction(Vector2(995.0, 300.0), SIZE), Vector2(1.0, 0.0), "right")
	assert_eq(RtsCamera.edge_direction(Vector2(500.0, 5.0), SIZE), Vector2(0.0, 1.0), "the top is forward")
	assert_eq(RtsCamera.edge_direction(Vector2(500.0, 595.0), SIZE), Vector2(0.0, -1.0), "the bottom is back")


func test_a_corner_asks_for_both() -> void:
	assert_eq(RtsCamera.edge_direction(Vector2(2.0, 2.0), SIZE), Vector2(-1.0, 1.0))
	assert_eq(RtsCamera.edge_direction(Vector2(998.0, 598.0), SIZE), Vector2(1.0, -1.0))


func test_the_zone_is_12_pixels_wide() -> void:
	assert_eq(RtsCamera.EDGE_SCROLL_MARGIN, 12.0)
	assert_eq(RtsCamera.edge_direction(Vector2(11.9, 300.0), SIZE).x, -1.0)
	assert_eq(RtsCamera.edge_direction(Vector2(12.0, 300.0), SIZE).x, 0.0, "12 px in is clear of it")
	assert_eq(RtsCamera.edge_direction(Vector2(988.1, 300.0), SIZE).x, 1.0)
	assert_eq(RtsCamera.edge_direction(Vector2(988.0, 300.0), SIZE).x, 0.0)


func test_a_mouse_outside_the_window_asks_for_nothing() -> void:
	assert_eq(RtsCamera.edge_direction(Vector2(-3.0, 300.0), SIZE), Vector2.ZERO)
	assert_eq(RtsCamera.edge_direction(Vector2(500.0, 700.0), SIZE), Vector2.ZERO)
	assert_eq(RtsCamera.edge_direction(Vector2(1000.0, 300.0), SIZE), Vector2.ZERO, "the far edge is outside")


func test_it_is_off_by_default() -> void:
	assert_false(_camera().edge_scroll)


func test_with_it_off_the_camera_does_not_pan_to_the_edge() -> void:
	var camera: MouseCamera = _camera()
	var before: Vector3 = camera.focus
	camera.edge_scroll = false
	camera.mouse = Vector2(1.0, 1.0)
	camera._process(0.5)
	assert_eq(camera.focus.x, before.x)
	assert_eq(camera.focus.z, before.z)


func test_with_it_on_the_camera_pans_when_the_mouse_is_at_the_edge() -> void:
	var camera: MouseCamera = _camera()
	var before: Vector3 = camera.focus
	camera.edge_scroll = true
	camera.mouse = Vector2(1.0, 1.0)
	camera._process(0.5)
	assert_ne(Vector2(camera.focus.x, camera.focus.z), Vector2(before.x, before.z), "it moved")


func test_the_top_edge_pans_forward_and_the_bottom_edge_back() -> void:
	var camera: MouseCamera = _camera()
	camera.edge_scroll = true
	var size: Vector2 = get_viewport().get_visible_rect().size
	var start: float = camera.focus.z
	camera.mouse = Vector2(size.x * 0.5, 1.0)
	camera._process(0.5)
	assert_lt(camera.focus.z, start, "forward is north, toward -z, at yaw 0")
	var north: float = camera.focus.z
	camera.mouse = Vector2(size.x * 0.5, size.y - 1.0)
	camera._process(0.5)
	assert_gt(camera.focus.z, north, "and back is south")


func test_with_it_on_the_camera_stays_put_with_the_mouse_in_the_middle() -> void:
	var camera: MouseCamera = _camera()
	var before: Vector3 = camera.focus
	camera.edge_scroll = true
	camera.mouse = get_viewport().get_visible_rect().size * 0.5
	camera._process(0.5)
	assert_eq(camera.focus.x, before.x)
	assert_eq(camera.focus.z, before.z)


func test_a_mouse_that_left_the_window_stops_the_pan() -> void:
	var camera: MouseCamera = _camera()
	var before: Vector3 = camera.focus
	camera.edge_scroll = true
	camera.mouse = Vector2(1.0, 1.0)
	camera.notification(Node.NOTIFICATION_WM_MOUSE_EXIT)
	camera._process(0.5)
	assert_eq(camera.focus.x, before.x)
	assert_eq(camera.focus.z, before.z)
	camera.notification(Node.NOTIFICATION_WM_MOUSE_ENTER)
	camera._process(0.5)
	assert_ne(Vector2(camera.focus.x, camera.focus.z), Vector2(before.x, before.z), "and it resumes when it is back")


func test_a_button_under_the_mouse_stops_the_pan() -> void:
	# Reaching for the control bar's buttons mustn't drag the map.
	var camera: MouseCamera = _camera()
	var before: Vector3 = camera.focus
	camera.edge_scroll = true
	camera.mouse = Vector2(1.0, 1.0)
	camera.over_button = true
	camera._process(0.5)
	assert_eq(camera.focus.x, before.x)
	assert_eq(camera.focus.z, before.z)


func test_the_bottom_strip_scrolls_unless_a_button_is_in_it() -> void:
	var camera: MouseCamera = _camera()
	camera.edge_scroll = true
	var size: Vector2 = get_viewport().get_visible_rect().size
	camera.mouse = Vector2(size.x * 0.5, size.y - 2.0)
	var start: float = camera.focus.z
	camera._process(0.5)
	assert_gt(camera.focus.z, start, "the bottom 12 px pan the camera back (south, +z at yaw 0)")
	var panned: float = camera.focus.z
	camera.over_button = true
	camera._process(0.5)
	assert_eq(camera.focus.z, panned, "but not over a button")


func test_the_real_mouse_is_over_no_button_in_an_empty_window() -> void:
	assert_false(_camera()._mouse_over_button())


func test_the_control_bar_keeps_the_bottom_edge_strip_free_of_buttons() -> void:
	var catalog: UnitCatalog = TestTerrains.catalog()
	var world: World = World.new(1, TestTerrains.flat(40, 40), catalog)
	var controller: SelectionController = SelectionController.new()
	add_child_autofree(controller)
	var bar: ControlBar = ControlBar.new()
	add_child_autofree(bar)
	bar.setup(controller, world)
	assert_gte(
		bar.get_theme_stylebox("panel").content_margin_bottom, RtsCamera.EDGE_SCROLL_MARGIN,
		"as much padding under the last row as the edge zone is deep"
	)
	await wait_process_frames(3)  # the bar lays itself out
	var bottom: float = bar.get_global_rect().end.y
	var lowest: float = 0.0
	for node: Node in bar.find_children("*", "BaseButton", true, false):
		lowest = maxf(lowest, (node as Control).get_global_rect().end.y)
	assert_gt(lowest, 0.0, "the harness: the buttons have been laid out")
	assert_lte(lowest, bottom - RtsCamera.EDGE_SCROLL_MARGIN, "no button reaches into the bottom edge zone")


func test_wasd_still_works_with_edge_scroll_on() -> void:
	# The keys and the edge add together, then the sum is limited to full speed.
	var camera: MouseCamera = _camera()
	camera.edge_scroll = true
	camera.mouse = get_viewport().get_visible_rect().size * 0.5
	Input.action_press(InputBindings.CAM_FORWARD)
	var start: float = camera.focus.z
	camera._process(0.5)
	Input.action_release(InputBindings.CAM_FORWARD)
	assert_lt(camera.focus.z, start)


# A camera that is told where the mouse is.
class MouseCamera extends RtsCamera:
	var mouse: Vector2 = Vector2(-100.0, -100.0)
	var over_button: bool = false

	func _mouse_position() -> Vector2:
		return mouse

	func _mouse_over_button() -> bool:
		return over_button


func _camera() -> MouseCamera:
	var terrain: Terrain = TestTerrains.flat(200, 200)
	var camera: MouseCamera = MouseCamera.new()
	add_child_autofree(camera)
	camera.setup(terrain)
	camera.set_pose(Vector2(100.0, 100.0), 0.0, 50.0)
	return camera


# --- the corner camera (Phase 11) -------------------------------------------------


func test_corners_turn_at_the_top_and_orbit_at_the_bottom() -> void:
	var size: Vector2 = Vector2(1000, 600)
	assert_eq(RtsCamera.corner_turn(Vector2(10, 10), size), Vector2(-1, 0), "top left turns left")
	assert_eq(RtsCamera.corner_turn(Vector2(990, 10), size), Vector2(1, 0), "top right turns right")
	assert_eq(RtsCamera.corner_turn(Vector2(10, 590), size), Vector2(0, -1), "bottom left orbits left")
	assert_eq(RtsCamera.corner_turn(Vector2(990, 590), size), Vector2(0, 1), "bottom right orbits right")
	assert_eq(RtsCamera.corner_turn(Vector2(500, 5), size), Vector2.ZERO, "an edge isn't a corner")
	assert_eq(RtsCamera.corner_turn(Vector2(-5, 5), size), Vector2.ZERO, "outside the window, nothing")


func test_the_corner_camera_turns_instead_of_panning() -> void:
	var camera: MouseCamera = _corner_camera(Vector2(2, 2))
	var focus: Vector3 = camera.focus
	var yaw: float = camera.yaw
	camera._process(0.5)
	assert_gt(camera.yaw, yaw, "it turned left")
	assert_ne(camera.focus, focus, "turning in place swings the focus")
	var off: MouseCamera = _corner_camera(Vector2(2, 2))
	off.corner_camera = false
	var off_yaw: float = off.yaw
	off._process(0.5)
	assert_eq(off.yaw, off_yaw, "off by default")


func test_the_pad_pans_orbits_and_zooms_the_camera() -> void:
	var camera: MouseCamera = _corner_camera(Vector2(300, 300))
	camera.corner_camera = false
	var focus: Vector3 = camera.focus
	camera.pad_pan = Vector2(0.0, 1.0)
	camera.pad_orbit = 1.0
	camera.pad_zoom = 1.0
	var yaw: float = camera.yaw
	var distance: float = camera.distance
	camera._process(0.5)
	assert_ne(camera.focus, focus, "panned")
	assert_gt(camera.yaw, yaw, "orbited right, as E does")
	assert_lt(camera.distance, distance, "zoomed in")


func _corner_camera(mouse: Vector2) -> MouseCamera:
	var camera: MouseCamera = MouseCamera.new()
	add_child_autofree(camera)
	camera.setup(TestTerrains.flat(200, 200))
	camera.corner_camera = true
	camera.mouse = mouse
	return camera
