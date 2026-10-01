extends GutTest
## FireView: one flame per burning cell, standing on the ground at the cell;
## smoke over the (i + j) % 3 == 0 third of them; both tracking the sim's
## fire as it spreads and burns out, and capped. Worlds are real: fires are
## lit with World.ignite and spread by World.step. The shaders can't be
## checked headless (the dummy renderer compiles nothing); what a flame looks
## like was checked by eye.

const M: int = 1000

var _world: World
var _view: FireView


func before_each() -> void:
	_start(TestTerrains.flat(60, 60))


# Builds a world on this terrain, and a view of it.
func _start(terrain: Terrain) -> void:
	_world = World.new(1, terrain, TestTerrains.catalog())
	_view = FireView.new()
	add_child_autofree(_view)
	_view.setup(_world)


# Advances the sim one tick and the view with it, like MainView does.
func _tick() -> void:
	_world.step()
	_view.after_step()


# The (i + j) % 3 == 0 burning cells, from the sim's list, ascending.
func _expected_smoking() -> Array[int]:
	var out: Array[int] = []
	var keys: Array = _world.fire.burn_end.keys()
	keys.sort()
	for k: int in keys:
		var at: Vector2i = FireView.cell_of(k, _world.terrain.size_x)
		if (at.x + at.y) % 3 == 0:
			out.append(k)
	return out


func _smoking_cells() -> Array[int]:
	var out: Array[int] = []
	for n: int in _view.smoke_count():
		out.append(_view.smoke_cell(n))
	return out


# --- pure helpers ---


func test_flame_cells_are_ascending_and_capped() -> void:
	var burning: Array = [9, 4, 7, 1, 12]
	assert_eq(FireView.flame_cells(burning, 10), PackedInt32Array([1, 4, 7, 9, 12]), "all, sorted")
	assert_eq(FireView.flame_cells(burning, 3), PackedInt32Array([1, 4, 7]), "the first three by index")
	assert_eq(FireView.flame_cells(burning, 5), PackedInt32Array([1, 4, 7, 9, 12]), "exactly at the cap")
	assert_eq(FireView.flame_cells(burning, 0), PackedInt32Array(), "a zero cap")
	assert_eq(FireView.flame_cells([], 3), PackedInt32Array(), "nothing burning")


func test_smoke_cells_are_the_third_where_i_plus_j_divides_by_three() -> void:
	# 10 samples wide. Cells 0..29: (i, j) = (k % 10, k / 10).
	var cells: PackedInt32Array = PackedInt32Array()
	for k: int in 30:
		cells.append(k)
	var smoking: PackedInt32Array = FireView.smoke_cells(cells, 10, 100)
	for k: int in cells:
		var at: Vector2i = FireView.cell_of(k, 10)
		assert_eq(smoking.has(k), (at.x + at.y) % 3 == 0, "cell %d is (%d, %d)" % [k, at.x, at.y])
	assert_eq(smoking.size(), 10, "10 of 30")


func test_smoke_cells_cap_keeps_the_lowest_indices() -> void:
	var cells: PackedInt32Array = PackedInt32Array()
	for k: int in 60:
		cells.append(k)
	var all: PackedInt32Array = FireView.smoke_cells(cells, 10, 100)
	var capped: PackedInt32Array = FireView.smoke_cells(cells, 10, 4)
	assert_eq(capped.size(), 4)
	assert_eq(capped, all.slice(0, 4), "the first four of them")
	assert_eq(FireView.smoke_cells(cells, 10, 0), PackedInt32Array(), "a zero cap")


func test_cell_of_inverts_the_sample_index() -> void:
	assert_eq(FireView.cell_of(0, 7), Vector2i(0, 0))
	assert_eq(FireView.cell_of(6, 7), Vector2i(6, 0))
	assert_eq(FireView.cell_of(7, 7), Vector2i(0, 1))
	assert_eq(FireView.cell_of(7 * 5 + 3, 7), Vector2i(3, 5))


func test_variation_is_stable_per_cell_and_salt() -> void:
	assert_eq(FireView.variation(1234, 0), FireView.variation(1234, 0), "same cell, same values")
	assert_ne(FireView.variation(1234, 0), FireView.variation(1235, 0), "next cell differs")
	assert_ne(FireView.variation(1234, 0), FireView.variation(1234, FireView.SMOKE_SALT), "salt differs")


func test_variation_spreads_over_zero_to_one() -> void:
	var sums: Array[float] = [0.0, 0.0, 0.0, 0.0]
	var count: int = 4000
	for k: int in count:
		var roll: Vector4 = FireView.variation(k, 0)
		for axis: int in 4:
			assert_true(roll[axis] >= 0.0 and roll[axis] <= 1.0, "cell %d value %d is %f" % [k, axis, roll[axis]])
			sums[axis] += roll[axis]
	for axis: int in 4:
		assert_almost_eq(sums[axis] / count, 0.5, 0.03, "value %d averages the middle" % axis)


func test_variation_of_neighbors_is_unrelated() -> void:
	# Along a row, a flame's jitter shouldn't predict the next one's: the
	# mean step between neighbors is a third for independent uniform values,
	# and near zero for a smooth pattern.
	var total: float = 0.0
	var count: int = 2000
	for k: int in count:
		total += absf(FireView.variation(k, 0).x - FireView.variation(k + 1, 0).x)
	assert_almost_eq(total / count, 1.0 / 3.0, 0.03)


# --- the view ---


func test_nothing_is_drawn_before_any_fire() -> void:
	assert_eq(_view.flame_count(), 0)
	assert_eq(_view.smoke_count(), 0)
	for step: int in 5:
		_tick()
	assert_eq(_view.flame_count(), 0, "still nothing after ticks with no fire")
	assert_eq(_view.smoke_count(), 0)


func test_layers_are_allocated_up_front_and_start_empty() -> void:
	var flames: MultiMeshInstance3D = _view.get_node("Flames") as MultiMeshInstance3D
	var smoke: MultiMeshInstance3D = _view.get_node("Smoke") as MultiMeshInstance3D
	assert_eq(flames.multimesh.instance_count, FireView.FLAME_LIMIT)
	assert_eq(smoke.multimesh.instance_count, FireView.SMOKE_LIMIT)
	assert_eq(flames.multimesh.visible_instance_count, 0)
	assert_eq(smoke.multimesh.visible_instance_count, 0)
	assert_not_null((flames.material_override as ShaderMaterial).shader)
	assert_not_null((smoke.material_override as ShaderMaterial).shader)


func test_a_world_with_no_terrain_has_no_fire_and_draws_nothing() -> void:
	var bare: World = World.new(1)
	assert_null(bare.fire, "no terrain, no fire")
	var view: FireView = FireView.new()
	add_child_autofree(view)
	view.setup(bare)
	bare.step()
	view.after_step()
	view._process(0.0)
	assert_eq(view.flame_count(), 0)
	assert_eq(view.smoke_count(), 0)


func test_a_lit_cell_gets_a_flame_standing_on_it() -> void:
	assert_true(_world.ignite(20 * M, 30 * M, 0), "grass lights")
	_view.after_step()
	assert_eq(_view.flame_count(), 1)
	var at: Vector3 = _view.flame_position(0)
	assert_almost_eq(at.x, 20.0, FireView.JITTER + 0.001, "at its cell in x")
	assert_almost_eq(at.z, 30.0, FireView.JITTER + 0.001, "and in z")
	assert_almost_eq(at.y, 0.0, 0.001, "on the ground")
	assert_eq(_view.flame_cell(0), 30 * 60 + 20, "the cell's sample index")


func test_a_flame_stands_at_the_height_of_the_ground_under_it() -> void:
	_start(TestTerrains.ramp_x(60, 60, 500))
	# Rising 0.5 m per meter: the sample at x = 20 is 10 m up.
	assert_true(_world.ignite(20 * M, 30 * M, 0))
	_view.after_step()
	assert_eq(_view.flame_count(), 1)
	assert_almost_eq(_view.flame_position(0).y, 10.0, 0.001, "10 m up the ramp")


func test_a_cell_lit_during_a_step_shows_after_it() -> void:
	# World.ignite outside a step leaves the cell out of fire.changed, since
	# the next step clears that list before the view reads it. The view
	# must still draw it.
	_world.ignite(20 * M, 30 * M, 0)
	_tick()
	assert_eq(_view.flame_count(), _world.fire.burn_end.size())
	assert_gte(_view.flame_count(), 1, "the lit cell shows even though the step cleared its change")


func test_flames_are_jittered_off_the_grid() -> void:
	# A whole block alight: no two flames on the same spot, and the cells'
	# offsets from their sample points vary.
	for j: int in 10:
		for i: int in 10:
			_world.ignite((20 + i) * M, (20 + j) * M, 0)
	_view.after_step()
	assert_eq(_view.flame_count(), 100)
	var offsets: Dictionary[Vector2i, bool] = {}
	for n: int in 100:
		var at: Vector3 = _view.flame_position(n)
		var cell: Vector2i = FireView.cell_of(_view.flame_cell(n), 60)
		var offset: Vector2 = Vector2(at.x - cell.x, at.z - cell.y)
		assert_true(absf(offset.x) <= FireView.JITTER + 0.001 and absf(offset.y) <= FireView.JITTER + 0.001, "cell %d within the jitter" % n)
		offsets[Vector2i((offset * 100.0).round())] = true
	assert_gt(offsets.size(), 80, "nearly every flame has its own offset")


func test_a_flame_does_not_move_when_the_buffers_are_rebuilt() -> void:
	_world.ignite(30 * M, 30 * M, 0)
	_view.after_step()
	var first: Vector3 = _view.flame_position(0)
	# A cell with a lower index lights, so the first flame becomes flame 1.
	_world.ignite(10 * M, 10 * M, 0)
	_view.after_step()
	assert_eq(_view.flame_count(), 2)
	assert_eq(_view.flame_cell(1), 30 * 60 + 30)
	assert_eq(_view.flame_position(1), first, "the same flame in the same place")


func test_count_tracks_the_burning_cells_as_the_fire_spreads_and_burns_out() -> void:
	_world.ignite(30 * M, 30 * M, 0)
	_view.after_step()
	var peak: int = 0
	# Long enough for the first cell to burn out (grass: 300 ticks) and for
	# the fire to have spread a good way.
	for tick: int in 700:
		_tick()
		peak = maxi(peak, _world.fire.burn_end.size())
		assert_eq(_view.flame_count(), _world.fire.burn_end.size(), "flames at tick %d" % _world.tick)
	assert_gt(peak, 20, "the fire did spread, or this proved little")
	assert_true(_world.fire.is_burning(), "and was still going")


func test_flames_stand_on_exactly_the_burning_cells() -> void:
	_world.ignite(30 * M, 30 * M, 0)
	for tick: int in 500:
		_tick()
	var burning: Array = _world.fire.burn_end.keys()
	burning.sort()
	var drawn: Array = []
	for n: int in _view.flame_count():
		drawn.append(_view.flame_cell(n))
	assert_gt(burning.size(), 10, "a fire to compare")
	assert_eq(drawn, burning, "the same cells, in ascending order")


func test_smoke_is_the_third_of_the_burning_cells_where_i_plus_j_divides_by_three() -> void:
	_world.ignite(30 * M, 30 * M, 0)
	for tick: int in 500:
		_tick()
	var expected: Array[int] = _expected_smoking()
	assert_gt(expected.size(), 3, "a fire with smoke to compare")
	assert_eq(_smoking_cells(), expected)
	assert_lt(_view.smoke_count(), _view.flame_count(), "only some flames smoke")


func test_smoke_starts_on_the_ground_at_its_cell() -> void:
	_start(TestTerrains.ramp_x(60, 60, 500))
	# (i + j) % 3 == 0 at (21, 30): 51.
	assert_true(_world.ignite(21 * M, 30 * M, 0))
	_view.after_step()
	assert_eq(_view.smoke_count(), 1)
	var at: Vector3 = _view.smoke_position(0)
	assert_almost_eq(at.x, 21.0, FireView.JITTER + 0.001)
	assert_almost_eq(at.y, 10.5, 0.001, "at the height of its cell")
	assert_almost_eq(at.z, 30.0, FireView.JITTER + 0.001)


func test_a_cell_off_the_smoke_pattern_gets_a_flame_and_no_smoke() -> void:
	# (20, 30): 50 % 3 == 2.
	_world.ignite(20 * M, 30 * M, 0)
	_view.after_step()
	assert_eq(_view.flame_count(), 1)
	assert_eq(_view.smoke_count(), 0)


func test_everything_goes_when_the_fire_burns_out() -> void:
	# A single grass cell in a ring of sand can't spread.
	var rows: Array[String] = [
		"sssssss",
		"sssssss",
		"sssssss",
		"sss.sss",
		"sssssss",
		"sssssss",
		"sssssss",
	]
	_start(TestTerrains.from_ascii(rows))
	assert_true(_world.ignite(3 * M, 3 * M, 0))
	_view.after_step()
	assert_eq(_view.flame_count(), 1, "burning")
	assert_eq(_view.smoke_count(), 1, "(3 + 3) % 3 is 0, so it smokes")
	var guard: int = 0
	while _world.fire.is_burning() and guard < Fire.BURN_TICKS[Terrain.Ground.GRASS] + 50:
		_tick()
		guard += 1
	assert_false(_world.fire.is_burning(), "burnt out")
	assert_eq(_view.flame_count(), 0, "no flames left")
	assert_eq(_view.smoke_count(), 0, "no smoke left")
	assert_eq(
		(_view.get_node("Flames") as MultiMeshInstance3D).multimesh.visible_instance_count, 0,
		"nothing handed to the renderer either"
	)


func test_a_fire_that_is_already_burning_shows_on_setup() -> void:
	_world.ignite(30 * M, 30 * M, 0)
	for tick: int in 200:
		_world.step()
	var burning: int = _world.fire.burn_end.size()
	assert_gt(burning, 1)
	var late: FireView = FireView.new()
	add_child_autofree(late)
	late.setup(_world)
	assert_eq(late.flame_count(), burning, "a view made mid-fire catches up at once")


func test_the_flame_cap_holds_and_keeps_the_lowest_cells() -> void:
	_start(TestTerrains.flat(70, 70))
	# 60 rows of 70: 4200 cells, more than the limit.
	for j: int in 60:
		for i: int in 70:
			_world.ignite(i * M, j * M, 0)
	_view.after_step()
	assert_eq(_world.fire.burn_end.size(), 4200)
	assert_eq(_view.flame_count(), FireView.FLAME_LIMIT, "capped")
	assert_eq(_view.flame_cell(0), 0, "from the lowest index")
	assert_eq(_view.flame_cell(FireView.FLAME_LIMIT - 1), FireView.FLAME_LIMIT - 1, "up to the 4096th")
	assert_lte(_view.smoke_count(), FireView.SMOKE_LIMIT)
	assert_gt(_view.smoke_count(), 1000, "a third of 4096")


func test_smoke_follows_the_weather_wind() -> void:
	_world.weather.wind_x = 3000
	_world.weather.wind_z = -1500
	_view._process(0.0)
	var smoke: MultiMeshInstance3D = _view.get_node("Smoke") as MultiMeshInstance3D
	assert_eq((smoke.material_override as ShaderMaterial).get_shader_parameter("wind"), Vector2(3.0, -1.5), "m/s")
