extends GutTest
## ClusterFinder.densest: the middle of the thickest knot of units, what a
## CLUSTER unit (a Blightbag) walks at. Ties go to the knot nearer the
## asker, then to the lower id. Pure calls; nothing steps.

const M: int = 1000
const LIGHT: UnitType.Faction = UnitType.Faction.LIGHT

var _catalog: UnitCatalog


func before_all() -> void:
	var types: Array[UnitType] = [TestUnits.dummy(&"dummy")]
	_catalog = TestUnits.catalog(types)


## Units at the given positions (milli-units, as x, z pairs), in id order.
func _units(world: World, points: Array[int]) -> Array[Unit]:
	var out: Array[Unit] = []
	for i: int in range(0, points.size(), 2):
		out.append(world.spawn_unit(0, LIGHT, points[i], points[i + 1], 0, 1))
	return out


func _world() -> World:
	return World.new(1, TestTerrains.flat(80, 60), _catalog)


## densest() at CLUSTER_RADIUS, asked from (x, z).
func _densest(units: Array[Unit], x: int, z: int) -> PackedInt64Array:
	return ClusterFinder.densest(units, ClusterFinder.CLUSTER_RADIUS, x, z)


func test_no_units_no_knot() -> void:
	var none: Array[Unit] = []
	assert_eq(_densest(none, 0, 0), PackedInt64Array())


func test_a_lone_unit_is_its_own_knot() -> void:
	var units: Array[Unit] = _units(_world(), [12 * M, 34 * M])
	assert_eq(_densest(units, 0, 0), PackedInt64Array([12 * M, 34 * M]))


func test_the_thickest_knot_wins_over_a_nearer_thinner_one() -> void:
	var units: Array[Unit] = _units(_world(), [
		# A pair right next to the asker.
		5 * M, 5 * M, 6 * M, 5 * M,
		# Three far off.
		50 * M, 40 * M, 52 * M, 40 * M, 51 * M, 42 * M,
	])
	# The three's middle: (153 / 3, 122 / 3) m = (51, 40.667) m.
	assert_eq(_densest(units, 0, 0), PackedInt64Array([51 * M, 40_667]))


func test_a_tie_goes_to_the_knot_nearer_the_asker() -> void:
	var units: Array[Unit] = _units(_world(), [
		50 * M, 40 * M, 52 * M, 40 * M,
		10 * M, 10 * M, 12 * M, 10 * M,
	])
	assert_eq(_densest(units, 0, 0), PackedInt64Array([11 * M, 10 * M]))
	assert_eq(_densest(units, 60 * M, 50 * M), PackedInt64Array([51 * M, 40 * M]))


func test_a_tie_at_the_same_distance_goes_to_the_lower_id() -> void:
	# Two pairs 4 m wide mirrored about x = 40 m, the asker on the mirror
	# line: both count 2, and each pair's inner member is 3 m from the asker.
	var west_first: Array[Unit] = _units(_world(), [
		33 * M, 30 * M, 37 * M, 30 * M,
		47 * M, 30 * M, 43 * M, 30 * M,
	])
	assert_eq(_densest(west_first, 40 * M, 30 * M), PackedInt64Array([35 * M, 30 * M]))
	var east_first: Array[Unit] = _units(_world(), [
		47 * M, 30 * M, 43 * M, 30 * M,
		33 * M, 30 * M, 37 * M, 30 * M,
	])
	assert_eq(_densest(east_first, 40 * M, 30 * M), PackedInt64Array([45 * M, 30 * M]))


func test_the_radius_counts_a_unit_exactly_on_it() -> void:
	var units: Array[Unit] = _units(_world(), [10 * M, 10 * M, 15 * M, 10 * M, 40 * M, 40 * M])
	assert_eq(ClusterFinder.densest(units, 5 * M, 40 * M, 40 * M), PackedInt64Array([12_500, 10 * M]), "one knot")
	assert_eq(ClusterFinder.densest(units, 4999, 40 * M, 40 * M), PackedInt64Array([40 * M, 40 * M]), "apart")
