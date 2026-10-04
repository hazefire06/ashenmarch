extends SceneTree
## Generates The Ford (campaign mission 2, an escort) in maps/the_ford/:
## - a gentle rolling plain, 3 to 10 m, further into the blight than
##   Riverside: more sand, rock, and dead brush, and less green
## - a river across the full width, west to east, 44 m of water: depth 4 in
##   the core, 3, 2, and 1 out to the banks, with sand banks
## - the ford, the only crossing a living unit has: a gravel bar where the
##   depth is capped at 2 across the whole channel and at 1 in its middle
## - two deep pools beside the ford, where the Husks lurk
## - a sand road from the deploy area north across the ford and on to a
##   hamlet, whose circular palisade has a gate on the side the road reaches
## - the east woods, where the Rippers come from
##
## Run with `make maps`. The PNGs it writes are the source of truth and are
## committed. Floats, trig, and FastNoiseLite are fine here because this runs
## offline, never inside the sim; every noise has a fixed seed, so a rerun
## writes the same bytes. The rasters, stamps, and file writing are
## MapBuilder's (scripts/mapgen/map_builder.gd).
##
## Coordinates are meters; z grows southward, so "north" is -z. The constants
## below are the layout the mission data and tests are written against.

const OUT_DIR: String = "res://maps/the_ford/"
const SIZE: int = 384
const CELL_SIZE: int = 1000
const MAX_HEIGHT_M: float = 30.0
const MAX_WALKABLE_SLOPE: int = 1000
## Minimum water depth in meters for levels 1 to 4 (Riverside's three, and a
## fourth for the river's core).
const LEVEL_DEPTHS_M: Array[float] = [0.05, 0.8, 1.35, 2.2]
## Herb plants (x, z milli-units): two on each bank, a few meters off the road.
const HERB_PLANTS: PackedInt32Array = [
	196000, 240000, 188000, 262000, 196000, 154000, 188000, 136000,
]

const HILLS_SEED: int = 2101
const HILLS_FREQUENCY: float = 1.0 / 190.0
const PLAIN_BASE_M: float = 6.5
const PLAIN_AMPLITUDE_M: float = 5.5
const PLAIN_MIN_M: float = 3.0
const PLAIN_MAX_M: float = 10.0

## The river: its centerline is z = RIVER_Z_M + RIVER_SWING_M * sin(2 pi x /
## RIVER_PERIOD_M), and the water reaches RIVER_HALF_M either side of it.
const RIVER_Z_M: float = 192.0
const RIVER_SWING_M: float = 8.0
const RIVER_PERIOD_M: float = 300.0
const RIVER_HALF_M: float = 22.0
## Depth in meters by distance from the centerline, (distance, depth). The
## keys sit 5 mm inside the level thresholds, so depth level 4 runs to 6 m
## out, 3 to 11, 2 to 16, and 1 to 22, and the bed is smooth (under 0.2 m per
## m), which undead units crossing it need.
const BED_PROFILE: Array[Vector2] = [
	Vector2(0.0, 3.0), Vector2(6.0, 2.205), Vector2(11.0, 1.355),
	Vector2(16.0, 0.805), Vector2(22.0, 0.055),
]
## The water surface falls this far from the west edge to the east edge.
const WATER_WEST_M: float = 5.0
const WATER_EAST_M: float = 4.2
## Sand runs this far beyond the water on both banks.
const SAND_BANK_M: float = 4.0
## The bank rises BANK_HEIGHT_M over the first BANK_M past the water, and the
## valley blends into the plain over VALLEY_M.
const BANK_M: float = 4.0
const BANK_HEIGHT_M: float = 0.6
const VALLEY_M: float = 50.0

## The ford: x of its center. Across x +- FORD_FLAT_M the bed is held to depth
## level 1 (FORD_SHALLOW_M of water at most), across x +- FORD_BAR_M to level 2,
## and the cap relaxes to the full depth by x +- FORD_EDGE_M, so no step is
## steeper than a unit can walk. The whole channel is held, not just the
## middle: that is what makes it the only way across for living units.
const FORD_X_M: float = 192.0
const FORD_FLAT_M: float = 3.0
const FORD_BAR_M: float = 6.0
const FORD_EDGE_M: float = 12.0
## Deepest water at the ford: 0.75 m is level 1 (under 0.8), 1.3 m level 2
## (under 1.35); FORD_FREE_M is deeper than any bed, so the cap lets go.
const FORD_SHALLOW_M: float = 0.75
const FORD_DEEPEST_M: float = 1.3
const FORD_FREE_M: float = 4.0
## (distance from FORD_X_M, deepest water allowed there).
const FORD_CAP: Array[Vector2] = [
	Vector2(FORD_FLAT_M, FORD_SHALLOW_M), Vector2(FORD_BAR_M, FORD_DEEPEST_M),
	Vector2(FORD_EDGE_M, FORD_FREE_M),
]
## The two ambush pools, one each side of the ford and a few meters off the
## river's center line toward its banks (west pool south, east pool north),
## so each deepens a shoulder as well as the core. Within POOL_CORE_RADIUS_M
## of a center the water is depth level 4; the bed shelves back to dry at
## POOL_RADIUS_M.
const POOLS: Array[Vector2] = [Vector2(166.0, 196.0), Vector2(218.0, 178.0)]
const POOL_CORE_RADIUS_M: float = 7.0
const POOL_RADIUS_M: float = 14.0
const POOL_PROFILE: Array[Vector2] = [
	Vector2(0.0, 3.6), Vector2(7.0, 2.205), Vector2(14.0, 0.0),
]

## The road (sand, 4 m): from the deploy area straight north across the ford
## to the landing, then bending north-east to the gate, and on to the
## hamlet's square.
const DEPLOY: Vector2 = Vector2(192.0, 300.0)
const ROAD: PackedVector2Array = [
	DEPLOY, Vector2(192.0, 140.0), Vector2(200.0, 130.0), Vector2(211.0, 117.0),
	Vector2(222.0, 104.0), Vector2(231.0, 93.0), Vector2(237.0, 84.5), GATE_AREA_CENTER,
	Vector2(247.0, 70.0), HAMLET_CENTER,
]
const ROAD_WIDTH_M: float = 4.0
const HAMLET_PLAZA_RADIUS_M: float = 4.0

## The hamlet: a palisade circle, 2 m thick and 3 m tall, ROCK, blocked,
## with a gate gap on its south-west side, the one the road reaches. The
## gate's bearing is atan2(dz, dx) in degrees (z southward).
const HAMLET_CENTER: Vector2 = Vector2(255.0, 60.0)
const HAMLET_RADIUS_M: float = 30.0
const PALISADE_THICKNESS_M: float = 2.0
const PALISADE_HEIGHT_M: float = 3.0
const GATE_BEARING_DEG: float = 128.0
const GATE_WIDTH_M: float = 7.0
## The middle of the gate gap on the wall line: hamlet center + 30 m at the
## gate's bearing.
const GATE_GAP_CENTER: Vector2 = Vector2(236.5, 83.6)
## The gate area, where the escort ends: 4 m inside the gap on its axis (26 m
## from the hamlet's center), radius GATE_AREA_RADIUS_M. It reaches out
## through the gap, so the villager is "at the gate" as it comes through.
const GATE_AREA_CENTER: Vector2 = Vector2(239.0, 80.5)
const GATE_AREA_RADIUS_M: float = 7.0
## The ground inside the palisade is a flat pad out to this radius, so the
## wall stands level, blending into the plain by HAMLET_PAD_BLEND_M.
const HAMLET_PAD_RADIUS_M: float = 34.0
const HAMLET_PAD_BLEND_M: float = 14.0
## Houses as (center x, center z, width, depth) in meters, 3 m tall, ringed
## 15 m from the hamlet's center with the gate's side left open.
const HAMLET_HOUSES: Array[Vector4] = [
	Vector4(243.0, 51.0, 7.0, 6.0),
	Vector4(256.0, 45.0, 6.0, 6.0),
	Vector4(269.0, 54.0, 7.0, 6.0),
	Vector4(267.0, 69.0, 6.0, 7.0),
	Vector4(256.0, 75.0, 7.0, 6.0),
]
const HOUSE_HEIGHT_M: float = 3.0

## The east woods: wood and dead brush over this box, x 280 to 360, z 100 to
## 185, with a ragged edge. The Rippers come out of it.
const WOODS_BOX: Rect2 = Rect2(280.0, 100.0, 80.0, 85.0)
const WOODS_EDGE_M: float = 10.0

## What the mission data and tests are written against.
## The villager starts 7 m from the deploy point, so it is escorted from the
## first tick (it walks only while a soldier is within 12 m).
const VILLAGER_START: Vector2 = Vector2(186.0, 304.0)
## South to north: the deploy area, the middle of the south bank, the ford
## (the river is at z 164 to 208 there), the landing, a bend of the road, and
## the gate area.
const ESCORT_WAYPOINTS: Array[Vector2] = [
	Vector2(192.0, 272.0), Vector2(192.0, 226.0), Vector2(192.0, 160.0),
	Vector2(200.0, 130.0), Vector2(222.0, 104.0), Vector2(239.0, 80.0),
]
const LANDING_GUARD: Vector2 = Vector2(192.0, 145.0)
## Drifter patrols along the river, west and east of the ford.
const DRIFTER_WEST: Array[Vector2] = [Vector2(110.0, 192.0), Vector2(150.0, 190.0)]
const DRIFTER_EAST: Array[Vector2] = [Vector2(240.0, 195.0), Vector2(300.0, 200.0)]
const RIPPER_SPAWN: Vector2 = Vector2(330.0, 140.0)
const CAMERA_START: Vector2 = Vector2(192.0, 255.0)

## Ground types: noise layers and where each one takes over.
const WOOD_SEED: int = 2102
const WOOD_FREQUENCY: float = 1.0 / 55.0
const BRUSH_SEED: int = 2103
const BRUSH_FREQUENCY: float = 1.0 / 32.0
const ROCK_SEED: int = 2104
const ROCK_FREQUENCY: float = 1.0 / 40.0
const SAND_SEED: int = 2105
const SAND_FREQUENCY: float = 1.0 / 60.0
const EDGE_SEED: int = 2106
const EDGE_FREQUENCY: float = 1.0 / 25.0
const ROCK_THRESHOLD: float = 0.46
const SAND_THRESHOLD: float = 0.40
const BRUSH_THRESHOLD: float = 0.14
const COPSE_THRESHOLD: float = 0.45
const WOODS_WOOD_THRESHOLD: float = -0.30
const WOODS_BRUSH_THRESHOLD: float = -0.80

var _hills: FastNoiseLite
var _wood: FastNoiseLite
var _brush: FastNoiseLite
var _rock: FastNoiseLite
var _sand: FastNoiseLite
var _edge: FastNoiseLite
var _pad_height_m: float


func _initialize() -> void:
	_hills = MapBuilder.patches(HILLS_SEED, HILLS_FREQUENCY)
	_wood = MapBuilder.patches(WOOD_SEED, WOOD_FREQUENCY)
	_brush = MapBuilder.patches(BRUSH_SEED, BRUSH_FREQUENCY)
	_rock = MapBuilder.patches(ROCK_SEED, ROCK_FREQUENCY)
	_sand = MapBuilder.patches(SAND_SEED, SAND_FREQUENCY)
	_edge = MapBuilder.patches(EDGE_SEED, EDGE_FREQUENCY)
	_pad_height_m = _plain_raw(HAMLET_CENTER.x, HAMLET_CENTER.y)

	var map: MapBuilder = MapBuilder.new(SIZE, SIZE, CELL_SIZE, MAX_HEIGHT_M, MAX_WALKABLE_SLOPE)
	map.level_depths_m = LEVEL_DEPTHS_M
	map.fill(
		func(x: float, z: float) -> Vector2: return _ground(x, z),
		func(x: float, z: float, height_m: float, slope: float) -> int:
			return _ground_type(x, z, height_m, slope)
	)
	_sand_the_banks(map)
	_build_hamlet(map)
	map.road(ROAD, ROAD_WIDTH_M)
	map.road(PackedVector2Array([HAMLET_CENTER, HAMLET_CENTER]), HAMLET_PLAZA_RADIUS_M * 2.0)

	var info: MapInfo = map.save(_out_dir(), "the_ford", "The Ford", HERB_PLANTS)
	if info == null:
		quit(1)
		return
	if Terrain.load_map(info) == null:
		push_error("the written map does not load")
		quit(1)
		return
	map.report(info)
	quit(0)


## Where the map is written: OUT_DIR, or the directory a `-- --out=<dir>`
## argument names, which is how the tests regenerate the map into a scratch
## directory to prove the committed files are what this script writes.
func _out_dir() -> String:
	for arg: String in OS.get_cmdline_user_args():
		if arg.begins_with("--out="):
			return arg.trim_prefix("--out=")
	return OUT_DIR


## Every dry sample within SAND_BANK_M of water becomes sand. The ground pass
## already sands the banks by distance from the center line, which is only
## approximate on a bend; this makes the 4 m exact.
func _sand_the_banks(map: MapBuilder) -> void:
	var reach: int = ceili(SAND_BANK_M)
	for j: int in map.size_z:
		for i: int in map.size_x:
			if map.levels[j * map.size_x + i] == 0:
				continue
			for dj: int in range(-reach, reach + 1):
				for di: int in range(-reach, reach + 1):
					var x: int = i + di
					var z: int = j + dj
					if x < 0 or z < 0 or x >= map.size_x or z >= map.size_z:
						continue
					if Vector2(di, dj).length() <= SAND_BANK_M:
						map.grounds[z * map.size_x + x] = Terrain.Ground.SAND


## The palisade, then the houses (the road is stamped after both, so it
## skips their blocked samples).
func _build_hamlet(map: MapBuilder) -> void:
	# The wall is a closed polygon starting opposite the gate, so its seam is
	# far from the gap, which sits at half its length.
	var points: PackedVector2Array = PackedVector2Array()
	var steps: int = 96
	var start_deg: float = GATE_BEARING_DEG + 180.0
	for k: int in steps + 1:
		var angle: float = deg_to_rad(start_deg + 360.0 * k / steps)
		points.append(HAMLET_CENTER + Vector2.from_angle(angle) * HAMLET_RADIUS_M)
	var length: float = 0.0
	for k: int in steps:
		length += points[k].distance_to(points[k + 1])
	var gap: Vector2 = Vector2(length / 2.0 - GATE_WIDTH_M / 2.0, length / 2.0 + GATE_WIDTH_M / 2.0)
	map.wall(points, PALISADE_THICKNESS_M, PALISADE_HEIGHT_M, [gap])
	for house: Vector4 in HAMLET_HOUSES:
		map.house(house.x, house.y, house.z, house.w, HOUSE_HEIGHT_M)


## (ground height, water depth) in meters at (x, z) meters.
func _ground(x: float, z: float) -> Vector2:
	var extent_m: float = (SIZE - 1) * float(CELL_SIZE) / World.UNITS_PER_METER
	var water_m: float = lerpf(WATER_WEST_M, WATER_EAST_M, x / extent_m)
	var d: float = _river_distance(x, z)
	var depth: float = _water_depth(x, z, d)
	if depth > 0.0:
		return Vector2(water_m - depth, depth)
	var bank: float = smoothstep(RIVER_HALF_M, RIVER_HALF_M + BANK_M, d)
	var valley_start: float = RIVER_HALF_M + BANK_M * 0.5
	var valley: float = smoothstep(valley_start, valley_start + VALLEY_M, d)
	return Vector2(lerpf(water_m + BANK_HEIGHT_M * bank, _plain(x, z), valley), 0.0)


## Water depth in meters at (x, z), d meters from the river's center line: the
## river's bed profile, deepened by the pools, held down over the ford.
func _water_depth(x: float, z: float, d: float) -> float:
	var depth: float = 0.0
	if d < RIVER_HALF_M:
		depth = MapBuilder.profile(BED_PROFILE, d)
	for pool: Vector2 in POOLS:
		var r: float = Vector2(x, z).distance_to(pool)
		if r < POOL_RADIUS_M:
			depth = maxf(depth, MapBuilder.profile(POOL_PROFILE, r))
	return minf(depth, _ford_cap(x))


## The deepest the water may be at x: the ford's gravel bar, relaxing to the
## river's own depth by FORD_EDGE_M either side of the ford.
func _ford_cap(x: float) -> float:
	return MapBuilder.profile(FORD_CAP, absf(x - FORD_X_M))


## The plain's height with the hamlet's flat pad worked in.
func _plain(x: float, z: float) -> float:
	var h: float = _plain_raw(x, z)
	var r: float = Vector2(x, z).distance_to(HAMLET_CENTER)
	if r >= HAMLET_PAD_RADIUS_M + HAMLET_PAD_BLEND_M:
		return h
	return lerpf(_pad_height_m, h, smoothstep(HAMLET_PAD_RADIUS_M, HAMLET_PAD_RADIUS_M + HAMLET_PAD_BLEND_M, r))


func _plain_raw(x: float, z: float) -> float:
	return clampf(PLAIN_BASE_M + PLAIN_AMPLITUDE_M * _hills.get_noise_2d(x, z), PLAIN_MIN_M, PLAIN_MAX_M)


## Ground type at (x, z) meters, given its height and slope (m per m).
func _ground_type(x: float, z: float, height_m: float, slope: float) -> int:
	var d: float = _river_distance(x, z)
	if d < RIVER_HALF_M + SAND_BANK_M:
		return Terrain.Ground.SAND
	if Vector2(x, z).distance_to(HAMLET_CENTER) < HAMLET_PAD_RADIUS_M:
		return Terrain.Ground.GRASS
	if _in_woods(x, z):
		if _wood.get_noise_2d(x, z) > WOODS_WOOD_THRESHOLD:
			return Terrain.Ground.WOOD
		if _brush.get_noise_2d(x, z) > WOODS_BRUSH_THRESHOLD:
			return Terrain.Ground.BRUSH
		return Terrain.Ground.GRASS
	if height_m > PLAIN_MAX_M - 1.0 or slope > 0.35 or _rock.get_noise_2d(x, z) > ROCK_THRESHOLD:
		return Terrain.Ground.ROCK
	if _sand.get_noise_2d(x, z) > SAND_THRESHOLD:
		return Terrain.Ground.SAND
	if _wood.get_noise_2d(x, z) > COPSE_THRESHOLD:
		return Terrain.Ground.WOOD
	if _brush.get_noise_2d(x, z) > BRUSH_THRESHOLD:
		return Terrain.Ground.BRUSH
	return Terrain.Ground.GRASS


## Whether (x, z) is in the east woods: the box, with an edge that wanders by
## up to WOODS_EDGE_M so it does not read as a rectangle.
func _in_woods(x: float, z: float) -> bool:
	var outside: float = maxf(
		maxf(WOODS_BOX.position.x - x, x - WOODS_BOX.end.x),
		maxf(WOODS_BOX.position.y - z, z - WOODS_BOX.end.y)
	)
	return outside + WOODS_EDGE_M * _edge.get_noise_2d(x, z) < 0.0


## Distance in meters from (x, z) to the river's center line, corrected for
## its slope.
func _river_distance(x: float, z: float) -> float:
	var slope: float = RIVER_SWING_M * TAU / RIVER_PERIOD_M * cos(TAU * x / RIVER_PERIOD_M)
	return absf(z - _river_z(x)) / sqrt(1.0 + slope * slope)


func _river_z(x: float) -> float:
	return RIVER_Z_M + RIVER_SWING_M * sin(TAU * x / RIVER_PERIOD_M)
