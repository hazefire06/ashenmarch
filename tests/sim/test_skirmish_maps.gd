extends GutTest
## The three maps as skirmish maps (maps/<id>/skirmish.tres): the data
## validates, every start and flag is on ground both sides can reach, the
## flags stand clear of deep water, a full army fits at each start, and the
## layout is fair: each start is as far from the hill as the other, and as far
## from "its" flags as the other is from its own, for living and undead units,
## within FAIRNESS.

const SKIRMISH_CATALOG: String = "res://data/skirmish/skirmish.tres"
const MILL_GENERATOR: String = "res://scripts/gen_old_mill.gd"
const FORD_GENERATOR: String = "res://scripts/gen_the_ford.gd"
const LIVING: Terrain.Mobility = Terrain.Mobility.LIVING
const UNDEAD: Terrain.Mobility = Terrain.Mobility.UNDEAD
## Largest ratio, as permille over 1000, between two path lengths that a fair
## layout keeps equal (15%).
const FAIRNESS_PERMILLE: int = 150

var _skirmish: SkirmishCatalog
var _catalog: UnitCatalog
var _terrains: Dictionary[StringName, Terrain] = {}
var _pathing: Dictionary[StringName, Pathing] = {}
var _mill_gen: Dictionary
var _ford_gen: Dictionary


func before_all() -> void:
	_skirmish = load(SKIRMISH_CATALOG)
	_catalog = TestTerrains.catalog()
	for m: SkirmishMap in _skirmish.maps:
		var t: Terrain = Terrain.load_map(m.map)
		_terrains[m.id] = t
		_pathing[m.id] = Pathing.new(t)
	# Loaded here: the generators' integer-division warnings would fail a test
	# that compiled them.
	_mill_gen = (load(MILL_GENERATOR) as GDScript).get_script_constant_map()
	_ford_gen = (load(FORD_GENERATOR) as GDScript).get_script_constant_map()


# Path length in meters from a point to a flag, or -1 if the path doesn't end
# on the flag (find_path falls back to the nearest reachable point).
func _path_m(m: SkirmishMap, from: Vector2i, to: Vector2i, mobility: Terrain.Mobility) -> float:
	var path: PackedInt64Array = _pathing[m.id].find_path(from.x, from.y, to.x, to.y, mobility)
	if path.size() < 2 or Vector2i(path[path.size() - 2], path[path.size() - 1]) != to:
		return -1.0
	var total: float = 0.0
	var at: Vector2 = Vector2(from)
	for k: int in range(0, path.size(), 2):
		var next: Vector2 = Vector2(path[k], path[k + 1])
		total += at.distance_to(next)
		at = next
	return total / 1000.0


func _fair(a: float, b: float) -> bool:
	return a > 0.0 and b > 0.0 and maxf(a, b) * 1000.0 <= minf(a, b) * (1000.0 + FAIRNESS_PERMILLE)


func test_the_catalog_offers_the_three_maps_and_they_validate() -> void:
	var ids: Array[StringName] = []
	for m: SkirmishMap in _skirmish.maps:
		ids.append(m.id)
		assert_eq(m.validate(), PackedStringArray(), String(m.id))
		assert_eq(m.map.resource_path, "res://maps/%s/%s.tres" % [m.id, m.id], "the map beside it")
		assert_not_null(m.atmosphere, "%s reuses its mission's look" % m.id)
	assert_eq(ids, [&"riverside", &"the_ford", &"old_mill"] as Array[StringName])
	assert_eq(_skirmish.validate(_catalog), PackedStringArray())


func test_flag_counts_are_odd() -> void:
	assert_eq(_skirmish.skirmish_map(&"riverside").flag_count(), 5)
	assert_eq(_skirmish.skirmish_map(&"the_ford").flag_count(), 3)
	assert_eq(_skirmish.skirmish_map(&"old_mill").flag_count(), 3)


func test_starts_and_flags_are_passable_and_in_one_component_for_both_sides() -> void:
	for m: SkirmishMap in _skirmish.maps:
		var t: Terrain = _terrains[m.id]
		var p: Pathing = _pathing[m.id]
		var points: Array[Vector2i] = [m.spawn(0), m.spawn(1)]
		for i: int in m.flag_count():
			points.append(m.flag(i))
		for mobility: Terrain.Mobility in [LIVING, UNDEAD]:
			var component: int = p.component_at(points[0].x, points[0].y, mobility)
			assert_ne(component, PathLayer.NO_COMPONENT, "%s start A, mobility %d" % [m.id, mobility])
			for point: Vector2i in points:
				assert_true(t.is_passable(point.x, point.y, mobility), "%s %s" % [m.id, point])
				assert_eq(p.component_at(point.x, point.y, mobility), component, "%s %s mobility %d" % [m.id, point, mobility])


func test_no_flag_reaches_deep_water() -> void:
	# A Husk submerged in a flag's circle would hold it unseen; the runtime
	# doesn't count submerged units, but a flag the living can't stand all
	# over would favor the dead.
	for m: SkirmishMap in _skirmish.maps:
		var t: Terrain = _terrains[m.id]
		var r: int = m.flag_radius
		for i: int in m.flag_count():
			var f: Vector2i = m.flag(i)
			for dz: int in range(-r, r + 1, t.cell_size):
				for dx: int in range(-r, r + 1, t.cell_size):
					if dx * dx + dz * dz > r * r:
						continue
					assert_lt(
						t.water_depth_at(f.x + dx, f.y + dz), Terrain.LIVING_IMPASSABLE_DEPTH,
						"%s flag %d at %s" % [m.id, i, Vector2i(f.x + dx, f.y + dz)]
					)


func test_a_full_army_fits_at_each_start() -> void:
	var biggest: int = 0
	for t: UnitType in _catalog.types:
		biggest = maxi(biggest, t.body_radius)
	var spacing: int = Formations.spacing_for(biggest)
	for m: SkirmishMap in _skirmish.maps:
		for start: int in 2:
			var s: Vector2i = m.spawn(start)
			var f: Vector2i = m.facing(start)
			for slot: FormationSlot in Formations.slots(Formations.Kind.BOX, Army.MAX_UNITS, s.x, s.y, f.x, f.y, spacing):
				assert_true(_terrains[m.id].is_passable(slot.x, slot.z, LIVING), "%s start %d slot %d, %d" % [m.id, start, slot.x, slot.z])


func test_each_start_faces_the_other_side_of_the_map() -> void:
	for m: SkirmishMap in _skirmish.maps:
		for start: int in 2:
			var to_other: Vector2i = m.spawn(1 - start) - m.spawn(start)
			var f: Vector2i = m.facing(start)
			assert_gt(f.x * to_other.x + f.y * to_other.y, 0, "%s start %d faces away from the enemy" % [m.id, start])


func test_the_hill_is_as_far_from_either_start() -> void:
	for m: SkirmishMap in _skirmish.maps:
		var hill: Vector2i = m.flag(m.hill)
		for mobility: Terrain.Mobility in [LIVING, UNDEAD]:
			var a: float = _path_m(m, m.spawn(0), hill, mobility)
			var b: float = _path_m(m, m.spawn(1), hill, mobility)
			assert_true(_fair(a, b), "%s hill, mobility %d: %.0f m from A, %.0f m from B" % [m.id, mobility, a, b])


func test_the_other_flags_are_as_far_from_either_start() -> void:
	# Sorted, A's distances to the flags other than the hill match B's one
	# for one: each side has as near a flag, and as far a one, as the other.
	for m: SkirmishMap in _skirmish.maps:
		for mobility: Terrain.Mobility in [LIVING, UNDEAD]:
			var from_a: Array[float] = []
			var from_b: Array[float] = []
			for i: int in m.flag_count():
				if i == m.hill:
					continue
				from_a.append(_path_m(m, m.spawn(0), m.flag(i), mobility))
				from_b.append(_path_m(m, m.spawn(1), m.flag(i), mobility))
			from_a.sort()
			from_b.sort()
			for k: int in from_a.size():
				assert_true(
					_fair(from_a[k], from_b[k]),
					"%s, mobility %d, %d-th nearest flag: %.0f m from A, %.0f m from B" % [m.id, mobility, k, from_a[k], from_b[k]]
				)


func test_old_mills_hill_is_the_mill_yard() -> void:
	var yard: Vector2 = _mill_gen["YARD_CENTER"]
	var m: SkirmishMap = _skirmish.skirmish_map(&"old_mill")
	assert_eq(m.flag(m.hill), Vector2i(roundi(yard.x * 1000.0), roundi(yard.y * 1000.0)))


func test_the_fords_hill_is_the_ford() -> void:
	var m: SkirmishMap = _skirmish.skirmish_map(&"the_ford")
	assert_eq(m.flag(m.hill).x, roundi(float(_ford_gen["FORD_X_M"]) * 1000.0))


func test_validation_lists_every_problem() -> void:
	var m: SkirmishMap = SkirmishMap.new()
	m.spawns = PackedInt32Array([1, -2, 3])
	m.spawn_facing = PackedInt32Array([0, 1])
	m.flags = PackedInt32Array([0, 0, 5, 5, 1])
	m.hill = 4
	m.flag_radius = 0
	m.camera_distance = 0
	var text: String = "\n".join(m.validate())
	for expected: String in [
		"id is empty", "display_name is empty", "map is missing", "spawns must be two x, z pairs",
		"spawn_facing must be two direction pairs", "flags must be x, z pairs",
		"odd number of flags", "hill 4 is not a flag", "flag_radius must be positive",
		"camera_distance must be positive",
	]:
		assert_string_contains(text, expected)
	var even: SkirmishMap = SkirmishMap.new()
	even.flags = PackedInt32Array([0, 0, 1, 1, 2, 2, 3, 3])
	assert_string_contains("\n".join(even.validate()), "has 4")
