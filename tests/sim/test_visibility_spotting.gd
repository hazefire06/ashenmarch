extends GutTest
## Visibility.spotted_by and clear_sight: the display-only spotting the corner
## map uses. Terrain is a strip of 1 m samples whose height depends on x only.

const LIGHT: UnitType.Faction = UnitType.Faction.LIGHT
const DARK: UnitType.Faction = UnitType.Faction.DARK
const M: int = 1000
const WIDTH: int = 70
const DEPTH: int = 6

var _catalog: UnitCatalog


func before_all() -> void:
	var types: Array[UnitType] = [
		TestUnits.melee(&"scout", {"sight_radius": 30000}),
		TestUnits.dummy(&"foe"),
		TestUnits.undead(&"husk", {"hidden_in_deep_water": true, "reveal_radius": 3000}),
	]
	_catalog = TestUnits.catalog(types)


## heights_by_x: x sample index -> height (milli); water_by_x likewise; the
## rest is 0.
func _terrain(heights_by_x: Dictionary = {}, water_by_x: Dictionary = {}) -> Terrain:
	var heights: PackedInt32Array = PackedInt32Array()
	var water: PackedByteArray = PackedByteArray()
	var blocked: PackedByteArray = PackedByteArray()
	heights.resize(WIDTH * DEPTH)
	water.resize(WIDTH * DEPTH)
	blocked.resize(WIDTH * DEPTH)
	for j: int in DEPTH:
		for i: int in WIDTH:
			heights[j * WIDTH + i] = heights_by_x.get(i, 0)
			water[j * WIDTH + i] = water_by_x.get(i, 0)
	return Terrain.new(WIDTH, DEPTH, TestTerrains.CELL, heights, water, blocked, 100000)


## A unit of type_index at metre column x, standing on the ground there.
func _put(world: World, type_index: int, side: UnitType.Faction, x_m: int) -> Unit:
	var u: Unit = world.spawn_unit(type_index, side, x_m * M, 3 * M, 0, -1)
	u.x = x_m * M
	u.z = 3 * M
	u.y = world.terrain.height_at(u.x, u.z)
	return u


func _world(terrain: Terrain) -> World:
	return World.new(1, terrain, _catalog)


func test_in_range_and_clear_is_spotted() -> void:
	var w: World = _world(_terrain())
	_put(w, 0, LIGHT, 5)
	var foe: Unit = _put(w, 1, DARK, 25)
	assert_true(Visibility.spotted_by(w, foe, LIGHT))


func test_beyond_sight_radius_is_not_spotted() -> void:
	var w: World = _world(_terrain())
	_put(w, 0, LIGHT, 5)
	var foe: Unit = _put(w, 1, DARK, 40)
	assert_false(Visibility.spotted_by(w, foe, LIGHT))


func test_crest_between_blocks() -> void:
	var w: World = _world(_terrain({15: 6000, 14: 4000, 16: 4000}))
	_put(w, 0, LIGHT, 5)
	var foe: Unit = _put(w, 1, DARK, 25)
	assert_false(Visibility.spotted_by(w, foe, LIGHT))


func test_wall_slab_between_blocks() -> void:
	var slab: Dictionary = {}
	for i: int in range(14, 17):
		slab[i] = 8000
	var w: World = _world(_terrain(slab))
	_put(w, 0, LIGHT, 5)
	var foe: Unit = _put(w, 1, DARK, 25)
	assert_false(Visibility.spotted_by(w, foe, LIGHT))


func test_ridge_top_sees_over_a_lower_crest() -> void:
	var w: World = _world(_terrain({5: 8000, 4: 8000, 6: 8000, 15: 2000}))
	_put(w, 0, LIGHT, 5)
	var foe: Unit = _put(w, 1, DARK, 25)
	assert_true(Visibility.spotted_by(w, foe, LIGHT))


func test_submerged_husk_outside_reveal_radius_is_not_spotted() -> void:
	var w: World = _world(_terrain({}, {20: 3, 19: 3, 21: 3}))
	_put(w, 0, LIGHT, 10)
	var husk: Unit = _put(w, 2, DARK, 20)
	assert_false(Visibility.spotted_by(w, husk, LIGHT))
	_put(w, 0, LIGHT, 18)
	assert_true(Visibility.spotted_by(w, husk, LIGHT))


func test_own_units_are_always_spotted() -> void:
	var w: World = _world(_terrain())
	var mine: Unit = _put(w, 1, LIGHT, 60)
	assert_true(Visibility.spotted_by(w, mine, LIGHT))


func test_only_dead_viewers_spot_nothing() -> void:
	var w: World = _world(_terrain())
	var viewer: Unit = _put(w, 0, LIGHT, 5)
	var foe: Unit = _put(w, 1, DARK, 25)
	viewer.kill()
	assert_false(Visibility.spotted_by(w, foe, LIGHT))


func test_one_vertex_wide_wall_off_grid_blocks() -> void:
	# A 2 m wall on one column of vertices is a bilinear tent: a sample half a
	# cell off its peak sees only 1 m of it, under the sight line.
	var w: World = _world(_terrain({15: 2000}))
	var viewer: Unit = _put(w, 0, LIGHT, 5)
	var foe: Unit = _put(w, 1, DARK, 25)
	viewer.x = 5500
	foe.x = 25500
	viewer.y = w.terrain.height_at(viewer.x, viewer.z)
	foe.y = w.terrain.height_at(foe.x, foe.z)
	assert_false(Visibility.spotted_by(w, foe, LIGHT))


func test_a_clear_second_viewer_spots_what_a_blocked_one_cannot() -> void:
	var slab: Dictionary = {}
	for i: int in range(14, 17):
		slab[i] = 8000
	var w: World = _world(_terrain(slab))
	_put(w, 0, LIGHT, 5)
	_put(w, 0, LIGHT, 20)
	var foe: Unit = _put(w, 1, DARK, 25)
	assert_true(Visibility.spotted_by(w, foe, LIGHT))
