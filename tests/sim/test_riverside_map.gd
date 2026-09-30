extends GutTest
## The shipped Riverside map has the features CLAUDE.md describes: a creek
## that splits the map north from south, deep (depth 3) sections living units
## can't cross, and a ford at depth 1. Proven by flood fill over the samples
## from the top row (z = 0) toward the bottom row.

const MAP_PATH: String = "res://maps/riverside/riverside.tres"
## Sample column of the ford (scripts/gen_riverside.gd FORD_X_M at 1 m cells)
## and a half-width covering it plus its ramps.
const FORD_X: int = 300
const FORD_ZONE_HALF: int = 12

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


## True if the bottom row is reachable from the top row through samples with
## water depth <= max_depth.
func _reaches_south(max_depth: int) -> bool:
	var t: Terrain = _terrain
	return _flood(func(i: int, j: int) -> bool: return t.sample_water_depth(i, j) <= max_depth)


## 4-connected flood fill from every open sample in the top row. True if it
## reaches the bottom row.
func _flood(is_open: Callable) -> bool:
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
		for step: Vector2i in [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]:
			var ni: int = i + step.x
			var nj: int = j + step.y
			if ni < 0 or nj < 0 or ni >= w or nj >= h:
				continue
			var nk: int = nj * w + ni
			if seen[nk] == 0 and is_open.call(ni, nj):
				seen[nk] = 1
				queue.append(nk)
	return false
