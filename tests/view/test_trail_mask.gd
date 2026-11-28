extends GutTest
## TrailMask (A5, view only): a map's recorded trails baked into a wear mask
## the terrain shader draws as dirt and the scatter keeps off. Worn at the
## centre, soft and irregular at the edges, fading out at a route's ends, two
## ruts on a wide road, and read back (wear_at, rut_at) the way the GPU's
## linear filter reads the texture.

const EXTENT: Vector2 = Vector2(100.0, 100.0)


func _trails(records: Array[TrailRecord]) -> MapTrails:
	var trails: MapTrails = MapTrails.new()
	trails.records = records
	return trails


func _trail(points: PackedVector2Array, width_m: float, fade_ends: bool = true) -> TrailRecord:
	var record: TrailRecord = TrailRecord.new()
	record.points_m = points
	record.width_m = width_m
	record.fade_ends = fade_ends
	return record


## A straight east-west trail along z = 50 from x = 10 to x = 90.
func _straight(width_m: float = 2.4) -> TrailMask:
	return TrailMask.bake(_trails([_trail(PackedVector2Array([Vector2(10, 50), Vector2(90, 50)]), width_m)]), EXTENT)


func test_no_trails_bake_an_empty_mask() -> void:
	for trails: MapTrails in [null, _trails([])]:
		var mask: TrailMask = TrailMask.bake(trails, EXTENT)
		assert_true(mask.is_empty())
		assert_eq(mask.wear_at(50.0, 50.0), 0.0)
		assert_not_null(mask.texture(), "the shader still gets a texture")


func test_a_trail_is_worn_at_its_centre_and_not_beside_it() -> void:
	var mask: TrailMask = _straight()
	assert_false(mask.is_empty())
	assert_gt(mask.wear_at(50.0, 50.0), 0.95, "the centre")
	assert_gt(mask.wear_at(50.0, 50.4), 0.9, "the worn core")
	assert_eq(mask.wear_at(50.0, 54.0), 0.0, "grass a few metres off")
	assert_eq(mask.wear_at(50.0, 20.0), 0.0, "and far off, outside the baked area")


func test_its_edges_are_soft_and_irregular() -> void:
	var mask: TrailMask = _straight()
	var low: float = INF
	var high: float = -INF
	var between: int = 0
	for n: int in 121:
		var w: float = mask.wear_at(20.0 + n * 0.5, 51.25)
		low = minf(low, w)
		high = maxf(high, w)
		if w > 0.05 and w < 0.95:
			between += 1
	assert_gt(high - low, 0.3, "the edge wanders along the trail (%.2f..%.2f)" % [low, high])
	assert_gt(between, 30, "and is a gradient, not a step")


func test_a_route_fades_out_at_its_ends() -> void:
	var mask: TrailMask = _straight()
	assert_lt(mask.wear_at(10.5, 50.0), 0.3, "the first end")
	assert_lt(mask.wear_at(89.5, 50.0), 0.3, "the last end")
	var part: float = mask.wear_at(12.5, 50.0)
	assert_between(part, 0.2, 0.9, "partly worn on the way in")
	assert_gt(mask.wear_at(20.0, 50.0), 0.95, "fully worn past the fade")


func test_a_worn_disc_has_no_ends_to_fade() -> void:
	var mask: TrailMask = TrailMask.bake(_trails([_trail(PackedVector2Array([Vector2(40, 40)]), 12.0, false)]), EXTENT)
	assert_gt(mask.wear_at(40.0, 40.0), 0.95)
	assert_gt(mask.wear_at(42.0, 41.0), 0.95)
	assert_eq(mask.wear_at(40.0, 50.0), 0.0)


func test_a_wide_road_has_two_ruts_and_a_path_none() -> void:
	var road: TrailMask = _straight(3.6)
	var offset: float = TrailMask.rut_offset_m(3.6)
	assert_gt(road.rut_at(50.0, 50.0 + offset), 0.5, "a rut south of the centre")
	assert_gt(road.rut_at(50.0, 50.0 - offset), 0.5, "and one north")
	assert_lt(road.rut_at(50.0, 50.0), 0.2, "the crown between them")
	var path: TrailMask = _straight(2.0)
	for dz: float in [-1.0, -0.5, 0.0, 0.5, 1.0]:
		assert_eq(path.rut_at(50.0, 50.0 + dz), 0.0, "a narrow path has none")


func test_two_trails_wear_where_either_does() -> void:
	var mask: TrailMask = TrailMask.bake(_trails([
		_trail(PackedVector2Array([Vector2(10, 30), Vector2(90, 30)]), 2.4),
		_trail(PackedVector2Array([Vector2(50, 10), Vector2(50, 90)]), 2.4),
	]), EXTENT)
	assert_gt(mask.wear_at(50.0, 30.0), 0.95, "the crossing")
	assert_gt(mask.wear_at(30.0, 30.0), 0.95)
	assert_gt(mask.wear_at(50.0, 70.0), 0.95)


func test_it_is_sampled_like_the_linear_filter() -> void:
	var mask: TrailMask = _straight(3.6)
	var image: Image = mask.image()
	var texel: float = TrailMask.TEXEL_M
	var origin: Vector2 = mask.origin_m()
	# At a texel's centre, exactly the texel; halfway between two, their mean.
	var i: int = roundi((50.0 - origin.x) / texel)
	var j: int = roundi((50.7 - origin.y) / texel)
	var centre: Vector2 = origin + (Vector2(i, j) + Vector2(0.5, 0.5)) * texel
	assert_almost_eq(mask.wear_at(centre.x, centre.y), image.get_pixel(i, j).r, 0.0001)
	assert_almost_eq(mask.rut_at(centre.x, centre.y), image.get_pixel(i, j).g, 0.0001)
	var mid: float = (image.get_pixel(i, j).r + image.get_pixel(i, j + 1).r) / 2.0
	assert_almost_eq(mask.wear_at(centre.x, centre.y + texel / 2.0), mid, 0.0001)
	# The shader's uv for a world point is (p - origin) / size.
	var size: Vector2 = mask.size_m()
	assert_almost_eq(size.x, image.get_width() * texel, 0.0001)
	assert_almost_eq(size.y, image.get_height() * texel, 0.0001)


func test_the_baked_area_keeps_a_clear_border() -> void:
	# The texture clamps to its edge, so its outermost texels must be clear
	# or a trail's wear would smear across the rest of the map.
	var mask: TrailMask = TrailMask.bake(_trails([
		_trail(PackedVector2Array([Vector2(0, 50), Vector2(100, 50)]), 3.0),
	]), EXTENT)
	var image: Image = mask.image()
	for j: int in image.get_height():
		assert_eq(image.get_pixel(0, j).r, 0.0)
		assert_eq(image.get_pixel(image.get_width() - 1, j).r, 0.0)
	assert_lte(mask.origin_m().x, -TrailMask.TEXEL_M, "the border lies off the map")
