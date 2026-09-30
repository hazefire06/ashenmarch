extends GutTest
## UnitsView's reactions to the events the sim reports: bodies fall away from
## where the blow came from (an attacker, an arrow's approach, a blast's
## center: CombatEvent.source_x/z), a ground attack nobody can carry out shows
## "Can't reach" over the unit and a grey marker, and the order markers take
## their kind's color.

const M: int = 1000
const LIGHT: UnitType.Faction = UnitType.Faction.LIGHT
const DARK: UnitType.Faction = UnitType.Faction.DARK

var _catalog: UnitCatalog
var _world: World
var _view: UnitsView
var _victim: Unit
var _archer: Unit


func before_each() -> void:
	_catalog = TestTerrains.catalog()
	_world = World.new(1, TestTerrains.flat(60, 60), _catalog)
	_victim = _world.spawn_unit(_catalog.index_of(&"shieldman"), LIGHT, 30 * M, 30 * M, 0, 1)
	_archer = _world.spawn_unit(_catalog.index_of(&"longbow"), LIGHT, 20 * M, 40 * M, 0, -1)
	_view = UnitsView.new()
	add_child_autofree(_view)
	_view.setup(_world, UnitSelection.new(), null)


# The ground direction the lying body's head points: from its feet-end
# corners to its head-end corners.
func _head_direction(unit: Unit) -> Vector2:
	var sprite: UnitSprite = null
	for s: UnitSprite in _view.sprites():
		if s.unit_id == unit.id:
			sprite = s
	var corners: PackedVector3Array = sprite.lying_corners()
	var feet: Vector3 = (corners[0] + corners[1]) * 0.5
	var head: Vector3 = (corners[2] + corners[3]) * 0.5
	return Vector2(head.x - feet.x, head.z - feet.z).normalized()


func _kill_from(source_x: int, source_z: int, attacker: int = 0) -> void:
	var event: CombatEvent = CombatEvent.new(CombatEvent.Kind.KILL, attacker, _victim.id)
	event.source_x = source_x
	event.source_z = source_z
	_victim.kill()
	_world.combat_events.append(event)
	_view.after_step()


func test_a_body_falls_away_from_the_blow_source() -> void:
	# A blast 5 m to the west throws it east.
	_kill_from(25 * M, 30 * M)
	var head: Vector2 = _head_direction(_victim)
	assert_almost_eq(head.x, 1.0, 0.05, "head to the east")
	assert_almost_eq(head.y, 0.0, 0.05)


func test_the_direction_comes_from_the_event_not_from_the_attacker() -> void:
	# The attacker id names a unit standing south of the victim, but the
	# event says the blow came from the east, so the body falls west.
	_kill_from(35 * M, 30 * M, _archer.id)
	var head: Vector2 = _head_direction(_victim)
	assert_almost_eq(head.x, -1.0, 0.05, "head to the west")


func test_a_source_that_is_not_a_unit_still_throws_the_body() -> void:
	# An explosion has no attacker standing at its center, and a dead shooter
	# is gone; the old look-up-the-attacker code gave up and fell "backward".
	_kill_from(30 * M, 25 * M, 0)
	var head: Vector2 = _head_direction(_victim)
	assert_almost_eq(head.y, 1.0, 0.05, "head to the south, away from a blow from the north")


func test_a_blow_from_exactly_the_victim_falls_back_to_the_facing() -> void:
	_kill_from(30 * M, 30 * M)
	var head: Vector2 = _head_direction(_victim)
	assert_almost_eq(head.length(), 1.0, 0.01, "some direction, not a blank")
	assert_almost_eq(head.y, -1.0, 0.05, "backward from where the unit faced (south)")


func test_cant_reach_floats_a_notice_over_the_unit_and_greys_the_marker() -> void:
	var event: ProjectileEvent = ProjectileEvent.new(ProjectileEvent.Kind.CANT_REACH, 50 * M, 0, 10 * M)
	event.unit_id = _archer.id
	_world.projectile_events.append(event)
	_view.after_step()
	var sprite: UnitSprite = _sprite_of(_archer)
	assert_eq(sprite.notice_text(), "Can't reach")
	assert_eq(_sprite_of(_victim).notice_text(), "", "only the unit that couldn't")
	assert_eq(_view._marker_color, UnitsView.BLOCKED_MARKER_COLOR)
	assert_true(_view._marker.visible)
	assert_eq(_view._marker.position, Vector3(50.0, 0.05, 10.0), "at the target it couldn't reach")


func test_the_notice_goes_after_about_a_second() -> void:
	var event: ProjectileEvent = ProjectileEvent.new(ProjectileEvent.Kind.CANT_REACH, 50 * M, 0, 10 * M)
	event.unit_id = _archer.id
	_world.projectile_events.append(event)
	_view.after_step()
	var sprite: UnitSprite = _sprite_of(_archer)
	assert_almost_eq(UnitSprite.NOTICE_TIME, 1.0, 0.25)
	sprite._process(UnitSprite.NOTICE_TIME * 0.5)
	assert_eq(sprite.notice_text(), "Can't reach", "still showing halfway")
	sprite._process(UnitSprite.NOTICE_TIME * 0.6)
	assert_eq(sprite.notice_text(), "", "gone")
	assert_false(sprite.is_processing(), "and the sprite stops spending frames on it")


func test_a_repeated_notice_restarts_the_clock_without_stacking_labels() -> void:
	var sprite: UnitSprite = _sprite_of(_archer)
	var labels: int = 0
	for child: Node in sprite.get_children():
		if child is Label3D:
			labels += 1
	sprite.show_notice("Can't reach")
	sprite._process(0.8)
	sprite.show_notice("Can't reach")
	sprite._process(0.8)
	assert_eq(sprite.notice_text(), "Can't reach", "0.8 s into the second")
	var after: int = 0
	for child: Node in sprite.get_children():
		if child is Label3D:
			after += 1
	assert_eq(after, labels + 1, "one notice label, reused")


func test_a_dead_unit_shows_no_notice() -> void:
	var sprite: UnitSprite = _sprite_of(_archer)
	sprite.show_notice("Can't reach")
	sprite.set_dead(true)
	assert_eq(sprite.notice_text(), "")


func test_marker_colors_by_kind() -> void:
	var point: Vector3 = Vector3(5.0, 1.0, 5.0)
	_view.show_marker(point, UnitsView.MarkerKind.MOVE)
	assert_eq(_view._marker_color, UnitsView.MARKER_COLOR)
	_view.show_marker(point, UnitsView.MarkerKind.ATTACK_MOVE)
	assert_eq(_view._marker_color, UnitsView.ATTACK_MARKER_COLOR)
	_view.show_marker(point, UnitsView.MarkerKind.GROUND_ATTACK)
	assert_eq(_view._marker_color, UnitsView.GROUND_ATTACK_MARKER_COLOR)
	_view.show_marker(point, UnitsView.MarkerKind.BLOCKED)
	assert_eq(_view._marker_color, UnitsView.BLOCKED_MARKER_COLOR)
	var colors: Dictionary[Color, bool] = {}
	for color: Color in [
		UnitsView.MARKER_COLOR, UnitsView.ATTACK_MARKER_COLOR,
		UnitsView.GROUND_ATTACK_MARKER_COLOR, UnitsView.BLOCKED_MARKER_COLOR
	]:
		colors[color] = true
	assert_eq(colors.size(), 4, "all four are distinct")
	var orange: Color = UnitsView.GROUND_ATTACK_MARKER_COLOR
	assert_true(orange.r > 0.9 and orange.g > 0.4 and orange.g < 0.75 and orange.b < 0.3, "orange")


func test_the_old_marker_call_still_works() -> void:
	_view.show_move_marker(Vector3.ZERO)
	assert_eq(_view._marker_color, UnitsView.MARKER_COLOR)
	_view.show_move_marker(Vector3.ZERO, true)
	assert_eq(_view._marker_color, UnitsView.ATTACK_MARKER_COLOR)


func _sprite_of(unit: Unit) -> UnitSprite:
	for s: UnitSprite in _view.sprites():
		if s.unit_id == unit.id:
			return s
	return null
