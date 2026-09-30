extends GutTest
## Terrain queries: bilinear height, gradient and slope, nearest-sample water
## depth and passability, and building from PNG bytes.

const CS: int = 1000
const LIVING: Terrain.Mobility = Terrain.Mobility.LIVING
const UNDEAD: Terrain.Mobility = Terrain.Mobility.UNDEAD
const FLOATING: Terrain.Mobility = Terrain.Mobility.FLOATING


func test_height_exact_at_samples() -> void:
	var t: Terrain = _terrain(3, 3, [10, 20, 30, 40, 50, 60, 70, 80, 90])
	for j: int in 3:
		for i: int in 3:
			assert_eq(t.height_at(i * CS, j * CS), 10 + 10 * (j * 3 + i), "sample (%d, %d)" % [i, j])


func test_height_cell_center_is_corner_average() -> void:
	var t: Terrain = _terrain(2, 2, [0, 1000, 2000, 4000])
	assert_eq(t.height_at(500, 500), 1750)


func test_height_interpolates_linearly_along_edges() -> void:
	var t: Terrain = _terrain(2, 2, [0, 1000, 2000, 4000])
	assert_eq(t.height_at(250, 0), 250)
	assert_eq(t.height_at(0, 750), 1500)
	assert_eq(t.height_at(1000, 500), 2500)


func test_height_rounds_half_up() -> void:
	var t: Terrain = _terrain(2, 2, [0, 1, 0, 0])
	assert_eq(t.height_at(500, 0), 1, "0.5 rounds up")
	assert_eq(t.height_at(500, 500), 0, "0.25 rounds down")


func test_height_rounds_negative_heights_correctly() -> void:
	var t: Terrain = _terrain(2, 2, [0, -3400, 0, 0])
	assert_eq(t.height_at(500, 0), -1700, "exact midpoint")
	assert_eq(t.height_at(1000, 0), -3400)
	var u: Terrain = _terrain(2, 2, [0, -1, 0, 0])
	assert_eq(u.height_at(500, 0), 0, "-0.5 rounds half up, to 0")
	assert_eq(u.height_at(750, 0), -1, "-0.75 rounds to -1")


func test_height_clamps_off_map() -> void:
	var t: Terrain = _terrain(2, 2, [5, 6, 7, 8])
	assert_eq(t.height_at(-5000, -5000), 5)
	assert_eq(t.height_at(99_000, 99_000), 8)
	assert_eq(t.height_at(99_000, -1), 6)


func test_height_at_far_edge_is_last_sample() -> void:
	var t: Terrain = _terrain(3, 2, [0, 0, 900, 0, 0, 300])
	assert_eq(t.height_at(t.extent_x(), 0), 900)
	assert_eq(t.height_at(t.extent_x(), t.extent_z()), 300)


func test_flat_terrain_has_zero_gradient_and_slope() -> void:
	var t: Terrain = _terrain(3, 3, [500, 500, 500, 500, 500, 500, 500, 500, 500])
	assert_eq(t.gradient_at(1234, 567), Vector2i.ZERO)
	assert_eq(t.slope_at(1234, 567), 0)
	assert_eq(t.sample_slope(1, 1), 0)


func test_45_degree_plane_has_slope_1000() -> void:
	# h = x: one milli-unit of rise per milli-unit of run.
	var t: Terrain = _terrain(3, 2, [0, 1000, 2000, 0, 1000, 2000])
	assert_eq(t.gradient_at(700, 300), Vector2i(1000, 0))
	assert_eq(t.slope_at(700, 300), 1000)
	assert_eq(t.sample_slope(1, 0), 1000)
	assert_eq(t.sample_slope(0, 1), 1000, "one-sided difference at the edge")


func test_gradient_points_uphill() -> void:
	# Height falls as z grows.
	var t: Terrain = _terrain(2, 2, [2000, 2000, 1000, 1000])
	assert_eq(t.gradient_at(500, 500), Vector2i(0, -1000))


func test_gradient_and_slope_of_tilted_plane() -> void:
	# h = 0.3x + 0.4z, so the slope magnitude is 0.5.
	var t: Terrain = _terrain(2, 2, [0, 300, 400, 700])
	assert_eq(t.gradient_at(100, 900), Vector2i(300, 400))
	assert_eq(t.slope_at(100, 900), 500)


func test_gradient_is_exact_bilinear_derivative() -> void:
	# Twisted cell: dh/dx varies with z.
	var t: Terrain = _terrain(2, 2, [0, 1000, 0, 3000])
	assert_eq(t.gradient_at(0, 0).x, 1000)
	assert_eq(t.gradient_at(0, 500).x, 2000)
	assert_eq(t.gradient_at(0, 1000).x, 3000)


func test_gradient_is_zero_along_clamped_axes_off_map() -> void:
	# h = x. Off the map height_at is flat along a clamped axis.
	var t: Terrain = _terrain(3, 2, [0, 1000, 2000, 0, 1000, 2000])
	assert_eq(t.height_at(5000, 300), t.height_at(6000, 300))
	assert_eq(t.gradient_at(5500, 300), Vector2i.ZERO)
	assert_eq(t.gradient_at(-10, 300), Vector2i.ZERO)
	assert_eq(t.gradient_at(700, -5), Vector2i(1000, 0), "only the clamped axis is zeroed")


func test_one_cell_cliff_blocks_walkers_on_both_sides() -> void:
	# A 2 m step between samples 1 and 2 at 1 m spacing is 63 degrees.
	var t: Terrain = _terrain(4, 2, [0, 0, 2000, 2000, 0, 0, 2000, 2000])
	assert_eq(t.sample_slope(1, 0), 2000)
	assert_eq(t.sample_slope(2, 0), 2000)
	assert_false(t.is_sample_passable(1, 0, LIVING))
	assert_false(t.is_sample_passable(2, 0, UNDEAD))
	assert_true(t.is_sample_passable(0, 0, LIVING), "flat ground next to the cliff")
	assert_true(t.is_sample_passable(2, 0, FLOATING))


func test_water_depth_uses_nearest_sample() -> void:
	var t: Terrain = _terrain(3, 2, [0, 0, 0, 0, 0, 0], [0, 2, 4, 0, 0, 0])
	assert_eq(t.water_depth_at(499, 0), 0)
	assert_eq(t.water_depth_at(500, 0), 2, "exact half rounds to the higher sample")
	assert_eq(t.water_depth_at(1600, 400), 4)
	assert_eq(t.water_depth_at(1600, 500), 0)
	assert_eq(t.water_depth_at(-10_000, 0), 0, "clamps off the map")


func test_passability_by_water_depth() -> void:
	for depth: int in range(0, Terrain.MAX_WATER_DEPTH + 1):
		var t: Terrain = _terrain(2, 2, [0, 0, 0, 0], [depth, depth, depth, depth])
		assert_eq(t.is_passable(500, 500, LIVING), depth < 3, "living at depth %d" % depth)
		assert_true(t.is_passable(500, 500, UNDEAD), "undead at depth %d" % depth)
		assert_true(t.is_passable(500, 500, FLOATING), "floating at depth %d" % depth)


func test_blocked_stops_every_mobility() -> void:
	var t: Terrain = _terrain(2, 2, [0, 0, 0, 0], [], [1, 1, 1, 1])
	for mobility: Terrain.Mobility in [LIVING, UNDEAD, FLOATING]:
		assert_false(t.is_passable(500, 500, mobility), "mobility %d" % mobility)


func test_steep_slope_stops_walkers_only() -> void:
	# 2000 permille, above the 1000 limit.
	var t: Terrain = _terrain(3, 2, [0, 2000, 4000, 0, 2000, 4000])
	assert_false(t.is_passable(1000, 0, LIVING))
	assert_false(t.is_passable(1000, 0, UNDEAD))
	assert_true(t.is_passable(1000, 0, FLOATING))


func test_slope_at_limit_is_walkable() -> void:
	var t: Terrain = _terrain(3, 2, [0, 1000, 2000, 0, 1000, 2000])
	assert_true(t.is_passable(1000, 0, LIVING))


func test_off_map_is_impassable() -> void:
	var t: Terrain = _terrain(2, 2, [0, 0, 0, 0])
	for mobility: Terrain.Mobility in [LIVING, UNDEAD, FLOATING]:
		assert_false(t.is_passable(-1, 0, mobility))
		assert_false(t.is_passable(0, 1001, mobility))
		assert_true(t.is_passable(1000, 1000, mobility), "far corner is on the map")
	assert_false(t.is_sample_passable(2, 0, LIVING))
	assert_false(t.is_sample_passable(0, -1, LIVING))


func test_point_passability_matches_nearest_sample() -> void:
	var t: Terrain = _terrain(2, 2, [0, 0, 0, 0], [0, 3, 0, 3])
	assert_true(t.is_passable(499, 0, LIVING))
	assert_false(t.is_passable(500, 0, LIVING))


func test_mask_depth_encoding_round_trips() -> void:
	for level: int in range(0, Terrain.MAX_WATER_DEPTH + 1):
		assert_eq(Terrain.depth_from_mask(Terrain.mask_from_depth(level)), level)
	assert_eq(Terrain.depth_from_mask(125), 2, "tolerates editor rounding")
	assert_eq(Terrain.depth_from_mask(255), Terrain.MAX_WATER_DEPTH)


func test_from_png_scales_heights_and_decodes_mask() -> void:
	var height: PngRaster = PngRaster.create(3, 2, 1, 16)
	height.samples = PackedInt32Array([0, 65535, 32768, 1, 100, 65534])
	var mask: PngRaster = PngRaster.create(3, 2, 3, 8)
	mask.samples = PackedInt32Array([
		0, 0, 0,   60, 0, 0,   125, 0, 0,
		180, 0, 0,   255, 0, 0,   0, 0, 200,
	])
	var t: Terrain = Terrain.from_png(PngCodec.encode(height), PngCodec.encode(mask), CS, 40000, 1000)
	assert_not_null(t)
	assert_eq(t.heights, PackedInt32Array([0, 40000, 20000, 1, 61, 39999]))
	assert_eq(t.water, PackedByteArray([0, 1, 2, 3, 4, 0]))
	assert_eq(t.blocked, PackedByteArray([0, 0, 0, 0, 0, 1]))
	assert_eq([t.size_x, t.size_z, t.cell_size, t.max_walkable_slope], [3, 2, CS, 1000])


func test_from_png_accepts_8bit_heightmap_and_rgba_mask() -> void:
	var height: PngRaster = PngRaster.create(2, 2, 1, 8)
	height.samples = PackedInt32Array([0, 255, 128, 64])
	var mask: PngRaster = PngRaster.create(2, 2, 4, 8)
	mask.samples = PackedInt32Array([0, 0, 0, 255, 120, 0, 0, 255, 0, 0, 255, 255, 0, 0, 0, 0])
	var t: Terrain = Terrain.from_png(PngCodec.encode(height), PngCodec.encode(mask), CS, 25500, 1000)
	assert_eq(t.heights, PackedInt32Array([0, 25500, 12800, 6400]))
	assert_eq(t.water, PackedByteArray([0, 2, 0, 0]))
	assert_eq(t.blocked, PackedByteArray([0, 0, 1, 0]))


func test_from_png_rejects_size_mismatch() -> void:
	var height: PngRaster = PngRaster.create(3, 2, 1, 16)
	var mask: PngRaster = PngRaster.create(2, 2, 3, 8)
	assert_null(Terrain.from_png(PngCodec.encode(height), PngCodec.encode(mask), CS, 1000, 1000))
	assert_push_error("mask is 2x2 but heightmap is 3x2")


func test_from_png_rejects_color_heightmap() -> void:
	var height: PngRaster = PngRaster.create(2, 2, 3, 16)
	var mask: PngRaster = PngRaster.create(2, 2, 3, 8)
	assert_null(Terrain.from_png(PngCodec.encode(height), PngCodec.encode(mask), CS, 1000, 1000))
	assert_push_error("must be grayscale")


func test_from_png_rejects_gray_mask() -> void:
	var height: PngRaster = PngRaster.create(2, 2, 1, 16)
	var mask: PngRaster = PngRaster.create(2, 2, 1, 8)
	assert_null(Terrain.from_png(PngCodec.encode(height), PngCodec.encode(mask), CS, 1000, 1000))
	assert_push_error("8-bit RGB or RGBA")


func test_from_png_rejects_garbage() -> void:
	var mask: PngRaster = PngRaster.create(2, 2, 3, 8)
	assert_null(Terrain.from_png(PackedByteArray([1, 2, 3]), PngCodec.encode(mask), CS, 1000, 1000))
	assert_push_error("heightmap: not a PNG")


func test_load_map_rejects_unset_scale() -> void:
	var info: MapInfo = MapInfo.new()
	info.heightmap_path = "res://maps/riverside/height.png"
	info.mask_path = "res://maps/riverside/mask.png"
	assert_null(Terrain.load_map(info))
	assert_push_error("needs positive cell_size")


func test_load_map_reports_missing_file() -> void:
	var info: MapInfo = MapInfo.new()
	info.cell_size = CS
	info.max_height = 1000
	info.max_walkable_slope = 1000
	info.heightmap_path = "res://maps/does_not_exist/height.png"
	info.mask_path = "res://maps/does_not_exist/mask.png"
	assert_null(Terrain.load_map(info))
	assert_push_error("cannot read res://maps/does_not_exist/height.png")
	assert_push_error("cannot read res://maps/does_not_exist/mask.png")


func test_world_holds_its_own_copy_of_the_terrain() -> void:
	var t: Terrain = _terrain(2, 2, [0, 0, 0, 0])
	var world: World = World.new(1, t)
	assert_not_same(world.terrain, t, "a copy, so craters stay in this world")
	assert_eq(world.terrain.heights, t.heights)
	assert_null(World.new(1).terrain)


func test_scarring_one_worlds_terrain_leaves_the_map_and_other_worlds_alone() -> void:
	var t: Terrain = _terrain(5, 5, [
		0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
	])
	var a: World = World.new(1, t)
	var b: World = World.new(1, t)
	var changed: Rect2i = a.terrain.scar(2000, 2000, 1500, 400)
	assert_eq(changed, Rect2i(1, 1, 3, 3))
	assert_eq(a.terrain.sample_height(2, 2), -400, "the center sinks the full depth")
	assert_eq(t.sample_height(2, 2), 0, "the loaded map is untouched")
	assert_eq(b.terrain.sample_height(2, 2), 0, "and so is the other world")


func test_scars_ease_out_and_stop_at_the_cap() -> void:
	var heights: Array[int] = []
	heights.resize(81)
	heights.fill(5000)
	var t: Terrain = _terrain(9, 9, heights)
	t.scar(4000, 4000, 2000, 400)
	assert_eq(t.sample_height(4, 4), 4600)
	assert_eq(t.sample_height(5, 4), 4700, "1 m out of 2: three quarters of the depth")
	assert_eq(t.sample_height(6, 4), 5000, "the rim is untouched")
	for _i: int in 10:
		t.scar(4000, 4000, 2000, 400)
	assert_eq(t.sample_height(4, 4), 5000 - Terrain.MAX_SCAR_DEPTH, "never deeper than the cap")
	assert_eq(t.scars[4 * 9 + 4], Terrain.MAX_SCAR_DEPTH)


func test_scars_do_not_change_passability() -> void:
	var t: Terrain = TestTerrains.flat(9, 9)
	var slopes: PackedInt32Array = t.sample_slopes.duplicate()
	for _i: int in 5:
		t.scar(4000, 4000, 2000, 400)
	assert_eq(t.sample_slopes, slopes, "slopes stay as loaded")
	assert_true(t.is_passable(4000, 4000, Terrain.Mobility.LIVING))


## Builds a terrain from plain arrays. Missing water/blocked default to 0.
func _terrain(
	samples_x: int,
	samples_z: int,
	sample_heights: Array,
	sample_water: Array = [],
	sample_blocked: Array = [],
	walkable_slope: int = 1000
) -> Terrain:
	var count: int = samples_x * samples_z
	var water: PackedByteArray = PackedByteArray(sample_water)
	var blocked: PackedByteArray = PackedByteArray(sample_blocked)
	water.resize(count)
	blocked.resize(count)
	return Terrain.new(
		samples_x, samples_z, CS, PackedInt32Array(sample_heights), water, blocked, walkable_slope
	)


func test_max_height_in_bounds_every_height_in_the_rectangle() -> void:
	var t: Terrain = TestTerrains.riverside()
	var rng: RandomNumberGenerator = RandomNumberGenerator.new()
	rng.seed = 5
	for _k: int in 200:
		var x0: int = rng.randi_range(-5000, t.extent_x() + 5000)
		var z0: int = rng.randi_range(-5000, t.extent_z() + 5000)
		var x1: int = x0 + rng.randi_range(0, 3000)
		var z1: int = z0 + rng.randi_range(0, 3000)
		var bound: int = t.max_height_in(x0, z0, x1, z1)
		for x: int in range(x0, x1 + 1, 250):
			for z: int in range(z0, z1 + 1, 250):
				assert_lte(t.height_at(x, z), bound)
	# It is tight enough to be useful: flat ground reads as flat.
	var flat: Terrain = TestTerrains.flat(40, 40)
	assert_eq(flat.max_height_in(5000, 5000, 9000, 9000), 0)
