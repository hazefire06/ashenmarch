extends GutTest
## AiDebugView, the F7 overlay: hidden until toggled, then one label per
## group with living members at its centroid and a line set drawn from the
## world's AI state (patrol routes, guard and ambush circles, flank routes,
## area triggers). It redraws after a step only while shown, and never
## changes the World.

const M: int = 1000
const DARK: UnitType.Faction = UnitType.Faction.DARK
const GRAY_BEFORE: Color = AiDebugView.TRIGGER_IDLE_COLOR
const GREEN_AFTER: Color = AiDebugView.TRIGGER_FIRED_COLOR

var _catalog: UnitCatalog
var _world: World
var _view: AiDebugView


func before_each() -> void:
	_catalog = TestTerrains.catalog()
	_world = World.new(1, TestTerrains.flat(80, 80), _catalog)
	_view = AiDebugView.new()
	add_child_autofree(_view)
	_view.setup(_world)


# --- pure helpers -------------------------------------------------------------


func test_a_group_is_labelled_with_its_name_and_behavior() -> void:
	var spec: AiGroupSpec = _spec(&"south_patrol", AiGroupSpec.Behavior.PATROL)
	var group: AiGroup = AiGroup.new(1, 0, spec, DARK, 0, 0)
	assert_eq(AiDebugView.group_label(group), "south_patrol: PATROL")
	group.behavior = AiGroupSpec.Behavior.HUNT
	assert_eq(AiDebugView.group_label(group), "south_patrol: HUNT")


func test_a_circle_is_evenly_spaced_points_on_the_radius() -> void:
	var center: Vector2 = Vector2(10.0, 20.0)
	var ring: PackedVector2Array = AiDebugView.circle(center, 5.0)
	assert_eq(ring.size(), AiDebugView.CIRCLE_SEGMENTS)
	assert_eq(AiDebugView.CIRCLE_SEGMENTS, 32)
	for point: Vector2 in ring:
		assert_almost_eq(point.distance_to(center), 5.0, 0.001)
	assert_almost_eq(ring[0].distance_to(ring[1]), ring[7].distance_to(ring[8]), 0.001, "even steps")


func test_a_fired_trigger_is_green_and_an_unfired_one_gray() -> void:
	var idle: Color = AiDebugView.trigger_color(false)
	var fired: Color = AiDebugView.trigger_color(true)
	assert_eq(idle, GRAY_BEFORE)
	assert_eq(fired, GREEN_AFTER)
	assert_almost_eq(idle.r, idle.g, 0.05, "gray has no hue")
	assert_gt(fired.g, fired.r + 0.3, "green is green")


# --- the overlay --------------------------------------------------------------


func test_it_starts_hidden_and_draws_nothing_while_hidden() -> void:
	_spawn(_spec(&"lurkers", AiGroupSpec.Behavior.AMBUSH, {"alert_radius": 8 * M}), 20, 20)
	assert_false(_view.visible)
	_world.step()
	_view.after_step()
	assert_eq(_view.label_texts(), PackedStringArray())
	assert_eq(_view.line_count(), 0)


func test_toggling_shows_a_label_per_group_with_members_at_its_centroid() -> void:
	_spawn(_spec(&"lurkers", AiGroupSpec.Behavior.AMBUSH, {"alert_radius": 8 * M}), 20, 20)
	_spawn(_spec(&"post", AiGroupSpec.Behavior.GUARD, {"guard_radius": 6 * M}), 50, 50)
	_view.toggle()
	assert_true(_view.visible)
	assert_eq(_view.label_texts(), PackedStringArray(["lurkers: AMBUSH", "post: GUARD"]))
	var at: Vector3 = _view.label_position(0)
	assert_almost_eq(at.x, 20.0, 0.01)
	assert_almost_eq(at.z, 20.0, 0.01)
	assert_gt(at.y, 0.0, "above the ground")
	_view.toggle()
	assert_false(_view.visible)


func test_a_group_with_no_living_members_has_no_label() -> void:
	var group: AiGroup = _spawn(_spec(&"lurkers", AiGroupSpec.Behavior.AMBUSH, {"alert_radius": 8 * M}), 20, 20)
	_view.toggle()
	assert_eq(_view.label_texts().size(), 1)
	for unit: Unit in group.living(_world):
		unit.state = Unit.State.DEAD
	_view.after_step()
	assert_eq(_view.label_texts(), PackedStringArray())


func test_an_ambush_and_a_guard_post_get_a_circle_each() -> void:
	_spawn(_spec(&"lurkers", AiGroupSpec.Behavior.AMBUSH, {"alert_radius": 8 * M}), 20, 20)
	_view.toggle()
	assert_eq(_view.line_count(), AiDebugView.CIRCLE_SEGMENTS)
	_spawn(_spec(&"post", AiGroupSpec.Behavior.GUARD, {"guard_radius": 6 * M}), 50, 50)
	_view.after_step()
	assert_eq(_view.line_count(), 2 * AiDebugView.CIRCLE_SEGMENTS)


func test_a_guard_without_a_radius_draws_the_default_one() -> void:
	_spawn(_spec(&"post", AiGroupSpec.Behavior.GUARD), 40, 40)
	_view.toggle()
	assert_eq(_view.line_count(), AiDebugView.CIRCLE_SEGMENTS)


func test_a_loop_patrol_closes_its_route_and_a_ping_pong_does_not() -> void:
	var waypoints: PackedInt32Array = PackedInt32Array([4 * M, 4 * M, 24 * M, 4 * M, 24 * M, 24 * M])
	_spawn(_spec(&"loop", AiGroupSpec.Behavior.PATROL, {"waypoints": waypoints}), 4, 4)
	_view.toggle()
	# Two 20 m legs, and the 28.3 m leg back, in pieces of at most STEP_LENGTH.
	assert_eq(_view.line_count(), 5 + 5 + 8)
	var other: World = World.new(1, TestTerrains.flat(80, 80), _catalog)
	var ping_pong: AiDebugView = AiDebugView.new()
	add_child_autofree(ping_pong)
	ping_pong.setup(other)
	var spec: AiGroupSpec = _spec(
		&"pong", AiGroupSpec.Behavior.PATROL, {"waypoints": waypoints, "patrol_mode": AiGroupSpec.PatrolMode.PING_PONG}
	)
	spec.spawns = PackedInt32Array([4 * M, 4 * M])
	other.ai.spawn_group(other, spec, 0, 0)
	ping_pong.toggle()
	assert_eq(ping_pong.line_count(), 5 + 5)


func test_a_patrol_that_turned_to_hunting_no_longer_shows_its_route() -> void:
	var waypoints: PackedInt32Array = PackedInt32Array([4 * M, 4 * M, 24 * M, 4 * M])
	var group: AiGroup = _spawn(_spec(&"loop", AiGroupSpec.Behavior.PATROL, {"waypoints": waypoints}), 4, 4)
	group.behavior = AiGroupSpec.Behavior.HUNT
	_view.toggle()
	assert_eq(_view.line_count(), 0)
	assert_eq(_view.label_texts(), PackedStringArray(["loop: HUNT"]))


func test_a_flank_group_shows_the_part_of_its_route_still_to_walk() -> void:
	var group: AiGroup = _spawn(_spec(&"raiders", AiGroupSpec.Behavior.FLANK), 10, 10)
	group.route = PackedInt64Array([10 * M, 30 * M, 30 * M, 30 * M])
	_view.toggle()
	# From the group's centroid (10, 10) to (10, 30) to (30, 30): 20 m twice.
	assert_eq(_view.line_count(), 5 + 5)
	group.route_index = 1
	_view.after_step()
	# From (10, 10) straight to (30, 30): 28.3 m.
	assert_eq(_view.line_count(), 8)
	group.route = PackedInt64Array()
	_view.after_step()
	assert_eq(_view.line_count(), 0, "no route planned, nothing to draw")


func test_area_triggers_are_gray_until_they_fire_then_green() -> void:
	var script: MissionScript = MissionScript.new()
	var ford: TriggerSpec = TriggerSpec.new()
	ford.name = &"ford"
	ford.condition = TriggerSpec.Condition.AREA_ENTERED
	ford.area = PackedInt32Array([40 * M, 40 * M, 15 * M])
	var timer: TriggerSpec = TriggerSpec.new()
	timer.name = &"timer"
	timer.condition = TriggerSpec.Condition.TIMER
	timer.ticks = PackedInt32Array([100000])
	script.triggers = [ford, timer]
	assert_true(_world.start_mission(script, 0))
	_view.toggle()
	assert_eq(_view.line_count(), AiDebugView.CIRCLE_SEGMENTS, "only the area trigger is drawn")
	for color: Color in _view.line_colors():
		assert_eq(color, GRAY_BEFORE)
	_world.mission.fired_tick[0] = 10
	_view.after_step()
	for color: Color in _view.line_colors():
		assert_eq(color, GREEN_AFTER)


func test_it_redraws_after_a_step_only_while_shown() -> void:
	var group: AiGroup = _spawn(_spec(&"lurkers", AiGroupSpec.Behavior.AMBUSH, {"alert_radius": 8 * M}), 20, 20)
	_view.toggle()
	assert_eq(_view.line_count(), AiDebugView.CIRCLE_SEGMENTS)
	_view.toggle()
	group.behavior = AiGroupSpec.Behavior.HUNT
	_view.after_step()
	assert_eq(_view.line_count(), AiDebugView.CIRCLE_SEGMENTS, "hidden: nothing was redrawn")
	_view.toggle()
	assert_eq(_view.line_count(), 0, "shown again: it draws what is there now")


func test_f7_toggles_it() -> void:
	var event: InputEventKey = InputEventKey.new()
	event.physical_keycode = KEY_F7
	event.pressed = true
	_view._unhandled_input(event)
	assert_true(_view.visible)
	_view._unhandled_input(event)
	assert_false(_view.visible)


func test_drawing_does_not_change_the_world() -> void:
	_spawn(_spec(&"lurkers", AiGroupSpec.Behavior.AMBUSH, {"alert_radius": 8 * M}), 20, 20)
	var before: String = _world.state_hash()
	_view.toggle()
	_view.after_step()
	assert_eq(_world.state_hash(), before)


# --- helpers ------------------------------------------------------------------


# A Dark Husk group spec; fields sets the rest by name.
func _spec(group_name: StringName, behavior: AiGroupSpec.Behavior, fields: Dictionary = {}) -> AiGroupSpec:
	var spec: AiGroupSpec = AiGroupSpec.new()
	spec.name = group_name
	var entry: AiUnitEntry = AiUnitEntry.new()
	entry.type_id = &"husk"
	entry.counts = PackedInt32Array([1])
	spec.units = [entry]
	spec.behavior = behavior
	for field: String in fields:
		spec.set(field, fields[field])
	return spec


# Spawns the spec's group at (x, z) metres and returns it. The group's spec
# index is the number of groups so far, which the overlay doesn't read.
func _spawn(spec: AiGroupSpec, x: int, z: int) -> AiGroup:
	spec.spawns = PackedInt32Array([x * M, z * M])
	return _world.ai.spawn_group(_world, spec, _world.ai.groups.size(), 0)
