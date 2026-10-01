extends GutTest
## The shipped Riverside map has the features CLAUDE.md describes: a creek
## that splits the map north from south, deep (depth 3) sections living units
## can't cross, and a ford at depth 1. Proven by flood fill over the samples
## from the top row (z = 0) toward the bottom row. Phase 5 adds ground types:
## sandy banks along the creek, so the creek is a firebreak, plus brush, wood,
## and rock among the grass.

const MAP_PATH: String = "res://maps/riverside/riverside.tres"
## Sample column of the ford (scripts/gen_riverside.gd FORD_X_M at 1 m cells)
## and a half-width covering it plus its ramps.
const FORD_X: int = 300
const FORD_ZONE_HALF: int = 12
## SHA-256 of the heights, water, and blocked samples as Phase 1 generated
## them. Regenerating the map for ground types must leave them alone.
const PHASE_1_SHAPE_HASH: String = "f7799cc4332a9cbbf706c0a51ef202e2eca8bb211a6770d4d49d2d0130bc3b34"

var _terrain: Terrain


func before_all() -> void:
	_terrain = Terrain.load_map(load(MAP_PATH) as MapInfo)


func test_loads_512_square() -> void:
	assert_not_null(_terrain)
	assert_eq([_terrain.size_x, _terrain.size_z], [512, 512])


func test_has_deep_water() -> void:
	assert_gt(_terrain.water.count(3), 0, "depth-3 samples")


func test_creek_separates_north_from_south() -> void:
	assert_false(_reaches_south(0), "dry ground alone must not connect the banks")


func test_ford_crosses_at_depth_1() -> void:
	assert_false(_reaches_south(0), "precondition: the creek blocks dry travel")
	assert_true(_reaches_south(1), "a crossing with no water deeper than 1")


func test_living_units_can_cross() -> void:
	var t: Terrain = _terrain
	var reached: bool = _flood(func(i: int, j: int) -> bool:
		return t.is_sample_passable(i, j, Terrain.Mobility.LIVING))
	assert_true(reached)


func test_living_units_cannot_cross_away_from_the_ford() -> void:
	var t: Terrain = _terrain
	var reached: bool = _flood(func(i: int, j: int) -> bool:
		var in_ford_zone: bool = absi(i - FORD_X) <= FORD_ZONE_HALF
		return not in_ford_zone and t.is_sample_passable(i, j, Terrain.Mobility.LIVING))
	assert_false(reached, "deep water must block living units everywhere but the ford")


func test_only_the_ford_is_shallow_enough_to_wade() -> void:
	var t: Terrain = _terrain
	var reached: bool = _flood(func(i: int, j: int) -> bool:
		return absi(i - FORD_X) > FORD_ZONE_HALF and t.sample_water_depth(i, j) <= 2)
	assert_false(reached, "no crossing at depth 2 or shallower away from the ford")


func test_the_shape_of_the_land_and_water_is_unchanged() -> void:
	var ctx: HashingContext = HashingContext.new()
	ctx.start(HashingContext.HASH_SHA256)
	ctx.update(_terrain.heights.to_byte_array())
	ctx.update(_terrain.water)
	ctx.update(_terrain.blocked)
	assert_eq(ctx.finish().hex_encode(), PHASE_1_SHAPE_HASH)


func test_has_every_ground_type_mostly_grass() -> void:
	var counts: Array[int] = []
	for ground: int in Terrain.GROUND_COUNT:
		counts.append(_terrain.ground.count(ground))
	gut.p("samples by ground (grass, brush, wood, sand, rock): %s" % [counts])
	for ground: int in Terrain.GROUND_COUNT:
		assert_gt(counts[ground], 1000, "ground %d" % ground)
	assert_gt(counts[Terrain.Ground.GRASS], _terrain.ground.size() / 2)


func test_dry_ground_beside_the_water_is_sand() -> void:
	var w: int = _terrain.size_x
	for j: int in range(1, _terrain.size_z - 1):
		for i: int in range(1, w - 1):
			if _terrain.sample_water_depth(i, j) > 0:
				continue
			var wet_beside: bool = false
			for step: Vector2i in EIGHT:
				wet_beside = wet_beside or _terrain.sample_water_depth(i + step.x, j + step.y) > 0
			if wet_beside and _terrain.sample_ground(i, j) != Terrain.Ground.SAND:
				fail_test("(%d, %d) is dry, beside water, and not sand" % [i, j])
				return
	pass_test("every bank sample is sand")


func test_fire_cannot_cross_the_creek() -> void:
	var t: Terrain = _terrain
	var reached: bool = _flood(func(i: int, j: int) -> bool:
		return t.sample_water_depth(i, j) == 0 and Fire.BURN_TICKS[t.sample_ground(i, j)] > 0, true)
	assert_false(reached, "no unbroken run of flammable ground from bank to bank, diagonals included")


## True if the bottom row is reachable from the top row through samples with
## water depth <= max_depth.
func _reaches_south(max_depth: int) -> bool:
	var t: Terrain = _terrain
	return _flood(func(i: int, j: int) -> bool: return t.sample_water_depth(i, j) <= max_depth)


const FOUR: Array[Vector2i] = [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]
const EIGHT: Array[Vector2i] = [
	Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1),
	Vector2i(1, 1), Vector2i(-1, 1), Vector2i(1, -1), Vector2i(-1, -1),
]


## Flood fill from every open sample in the top row, 4-connected (8 with
## diagonals, the way fire spreads). True if it reaches the bottom row.
func _flood(is_open: Callable, diagonals: bool = false) -> bool:
	var w: int = _terrain.size_x
	var h: int = _terrain.size_z
	var seen: PackedByteArray = PackedByteArray()
	seen.resize(w * h)
	var queue: PackedInt32Array = PackedInt32Array()
	for i: int in w:
		if is_open.call(i, 0):
			seen[i] = 1
			queue.append(i)
	var head: int = 0
	while head < queue.size():
		var k: int = queue[head]
		head += 1
		var i: int = k % w
		var j: int = k / w
		if j == h - 1:
			return true
		for step: Vector2i in (EIGHT if diagonals else FOUR):
			var ni: int = i + step.x
			var nj: int = j + step.y
			if ni < 0 or nj < 0 or ni >= w or nj >= h:
				continue
			var nk: int = nj * w + ni
			if seen[nk] == 0 and is_open.call(ni, nj):
				seen[nk] = 1
				queue.append(nk)
	return false


func test_herb_plants_stand_on_dry_walkable_ground() -> void:
	var info: MapInfo = load(MAP_PATH) as MapInfo
	var terrain: Terrain = TestTerrains.riverside()
	assert_eq(info.herb_plants.size() % 2, 0, "x, z pairs")
	assert_gt(info.herb_plants.size(), 0)
	for k: int in range(0, info.herb_plants.size(), 2):
		var x: int = info.herb_plants[k]
		var z: int = info.herb_plants[k + 1]
		assert_eq(terrain.water_depth_at(x, z), 0, "plant at (%d, %d) m is dry" % [x / 1000, z / 1000])
		assert_true(terrain.is_passable(x, z, Terrain.Mobility.LIVING), "and walkable")
