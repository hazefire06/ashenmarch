extends GutTest
## UnitsView.frozen (Phase 8): while the sim isn't stepping (paused, or the
## mission is decided) the sprites stand at the latest tick. Otherwise they
## are drawn between the last two ticks by the physics frame's fraction, and
## with no new tick coming that fraction would swing a moving unit back and
## forth between them.

const M: int = 1000

var _world: World
var _view: UnitsView
var _unit: Unit


func before_each() -> void:
	var catalog: UnitCatalog = TestTerrains.catalog()
	_world = World.new(1, TestTerrains.flat(60, 60), catalog)
	_unit = _world.spawn_unit(catalog.index_of(&"shieldman"), UnitType.Faction.LIGHT, 30 * M, 30 * M, 0, 1)
	_view = UnitsView.new()
	add_child_autofree(_view)
	_view.setup(_world, UnitSelection.new(), null)


# The unit has moved a tick, so its last two positions differ.
func _move_a_tick() -> void:
	_unit.x += 500
	_view.after_step()


func test_a_frozen_view_draws_the_latest_tick() -> void:
	_move_a_tick()
	_view.frozen = true
	for fraction_probe: int in 3:
		_view._process(0.0)
		assert_almost_eq(_view.sprite_position(_unit.id).x, _unit.x / float(M), 0.0001, "at the latest tick, whatever the fraction")


func test_a_view_that_is_not_frozen_interpolates() -> void:
	_move_a_tick()
	_view.frozen = false
	# Between the last two ticks by the physics fraction: with none of a frame
	# elapsed in a test that is the previous tick, not the latest.
	_view._process(0.0)
	var drawn: float = _view.sprite_position(_unit.id).x
	var fraction: float = Engine.get_physics_interpolation_fraction()
	var expected: float = lerpf((_unit.x - 500) / float(M), _unit.x / float(M), fraction)
	assert_almost_eq(drawn, expected, 0.0001)


func test_it_is_off_by_default() -> void:
	assert_false(_view.frozen)
	assert_false((autofree(ProjectilesView.new()) as ProjectilesView).frozen)
