extends GutTest
## AiDebugView's ESCORT case (Phase 8): the overlay gives an ESCORT group its
## own color and draws the part of its route still to walk, like a PATROL's
## waypoints and a FLANK's route, so the Ford's villager can be followed. The
## route shrinks as the group goes, and an arrived group has none.

const M: int = 1000
const LIGHT: UnitType.Faction = UnitType.Faction.LIGHT

var _world: World
var _view: AiDebugView


func before_each() -> void:
	_world = World.new(1, TestTerrains.flat(80, 80), TestTerrains.catalog())
	_view = AiDebugView.new()
	add_child_autofree(_view)
	_view.setup(_world)


# A Light villager group walking (10, 10) -> (20, 10) -> (40, 10), spawned at
# (10, 10), plus its escort-specific fields.
func _escort() -> AiGroup:
	var entry: AiUnitEntry = AiUnitEntry.new()
	entry.type_id = &"villager"
	entry.counts = PackedInt32Array([1])
	var spec: AiGroupSpec = AiGroupSpec.new()
	spec.name = &"convoy"
	spec.faction = LIGHT
	spec.behavior = AiGroupSpec.Behavior.ESCORT
	spec.units = [entry]
	spec.waypoints = PackedInt32Array([20 * M, 10 * M, 40 * M, 10 * M])
	spec.escort_radius = 12 * M
	spec.spawns = PackedInt32Array([10 * M, 10 * M])
	return _world.ai.spawn_group(_world, spec, 0, 0)


func test_an_escort_has_a_color_of_its_own() -> void:
	var color: Color = AiDebugView.behavior_color(AiGroupSpec.Behavior.ESCORT)
	assert_eq(color, AiDebugView.ESCORT_COLOR)
	for other: AiGroupSpec.Behavior in AiGroupSpec.Behavior.values():
		if other != AiGroupSpec.Behavior.ESCORT:
			assert_ne(color, AiDebugView.behavior_color(other), "%s" % AiGroupSpec.Behavior.find_key(other))


func test_an_escort_is_labelled_with_its_behavior() -> void:
	_escort()
	_view.toggle()
	assert_eq(_view.label_texts(), PackedStringArray(["convoy: ESCORT"]))


func test_an_escort_draws_the_route_left_to_walk() -> void:
	_escort()
	_view.toggle()
	# From the group at (10, 10) to the first waypoint (20, 10): 10 m, then 20 m
	# on to (40, 10), in pieces of at most STEP_LENGTH.
	assert_eq(_view.line_count(), 3 + 5)
	for color: Color in _view.line_colors():
		assert_eq(color, AiDebugView.ESCORT_COLOR)


func test_the_route_shrinks_as_waypoints_are_reached() -> void:
	var group: AiGroup = _escort()
	_view.toggle()
	group.waypoint_index = 1
	_view.after_step()
	# From (10, 10) straight to the last waypoint (40, 10): 30 m.
	assert_eq(_view.line_count(), 8)


func test_an_escort_that_has_arrived_draws_nothing() -> void:
	var group: AiGroup = _escort()
	group.waypoint_index = 1
	group.phase = 2
	_view.toggle()
	assert_eq(_view.line_count(), 0)
	assert_eq(_view.label_texts(), PackedStringArray(["convoy: ESCORT"]), "but it still has its label")


func test_a_waiting_escort_still_shows_where_it_is_going() -> void:
	var group: AiGroup = _escort()
	group.phase = 1
	_view.toggle()
	assert_eq(_view.line_count(), 3 + 5)


func test_an_escort_that_is_not_one_any_more_draws_no_escort_route() -> void:
	var group: AiGroup = _escort()
	group.behavior = AiGroupSpec.Behavior.HUNT
	_view.toggle()
	assert_eq(_view.line_count(), 0)


func test_drawing_does_not_change_the_world() -> void:
	_escort()
	var before: String = _world.state_hash()
	_view.toggle()
	_view.after_step()
	assert_eq(_world.state_hash(), before)
