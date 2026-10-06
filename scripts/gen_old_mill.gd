extends SceneTree
## Generates Old Mill (campaign mission 3, hold the line) in maps/old_mill/:
## - a low plain, 3 to 6 m, mostly grass, with wide fields of brush (the
##   wheat, which burns) in a ring round the plateau, broken by grass lanes,
##   and scorched patches of rock and sand (the blight)
## - a plateau 12 m up, irregular and about 28 m in radius, ringed by a cliff
##   band steeper than anyone can walk and climbed by two ramps, north-west
##   and south-east
## - the mill on it (blocked, wood) with an open yard to its south
## - a millstream down the east side, through a pond that is deep in the
##   middle, with sand banks; a living unit wades the stream, so it is a
##   hazard and a firebreak, not a wall
##
## Run with `make maps`. The PNGs it writes are the source of truth and are
## committed. Floats, trig, and FastNoiseLite are fine here because this runs
## offline, never inside the sim; every noise has a fixed seed, so a rerun
## writes the same bytes. The rasters, stamps, and file writing are
## MapBuilder's (scripts/mapgen/map_builder.gd).
##
## Coordinates are meters; z grows southward, so "north" is -z. The constants
## below are the layout the mission data and tests are written against.

const OUT_DIR: String = "res://maps/old_mill/"
const SIZE: int = 320
const CELL_SIZE: int = 1000
const MAX_HEIGHT_M: float = 30.0
const MAX_WALKABLE_SLOPE: int = 1000
## Minimum water depth in meters for levels 1 to 4 (the Ford's, so the two
## maps' water reads the same; Old Mill has no level 4).
const LEVEL_DEPTHS_M: Array[float] = [0.05, 0.8, 1.35, 2.2]
## Herb plants (x, z milli-units): two on the plateau, one at each ramp foot.
const HERB_PLANTS: PackedInt32Array = [
	148000, 140000, 176000, 162000, 119000, 110000, 201000, 194000,
]

const HILLS_SEED: int = 3101
const HILLS_FREQUENCY: float = 1.0 / 130.0
const PLAIN_BASE_M: float = 4.5
const PLAIN_AMPLITUDE_M: float = 2.4
const PLAIN_MIN_M: float = 3.0
const PLAIN_MAX_M: float = 6.0

## The plateau: its top is flat at PLATEAU_TOP_M, irregular (the radius wanders
## a few meters with the bearing), with a CLIFF_WIDTH_M band of ROCK cliff
## falling to the plain. Over the plain's top of 6 m that is 1.5 m per m at
## the gentlest, past the 1.0 a unit can walk.
const PLATEAU_CENTER: Vector2 = Vector2(160.0, 150.0)
const PLATEAU_TOP_M: float = 12.0
const PLATEAU_RADIUS_M: float = 28.0
const CLIFF_WIDTH_M: float = 4.0
## The ramps, each from its foot on the plain to the plateau's top edge on
## the same bearing from the center. 8 m wide, about 28 m long, so they
## climb 0.2 to 0.3 m per m.
const NW_RAMP_FOOT: Vector2 = Vector2(122.0, 108.0)
const SE_RAMP_FOOT: Vector2 = Vector2(198.0, 192.0)
const RAMP_WIDTH_M: float = 8.0

## The mill: a 10 by 10 m house, 6 m tall, WOOD, blocked. The yard is the open
## ground south of it; it starts a sample clear of the mill because the sim
## counts the ring of samples round a raised structure as too steep to walk.
const MILL_CENTER: Vector2 = Vector2(166.0, 144.0)
const MILL_SIZE_M: float = 10.0
const MILL_HEIGHT_M: float = 6.0
const YARD_CENTER: Vector2 = Vector2(166.0, 157.0)
const YARD_RADIUS_M: float = 7.0

## The millstream, a polyline from the north edge through the pond's center
## and out of the south edge. STREAM_HALF_M either side is water, depth level
## 2 in the middle and 1 at the edges, so it can be waded.
const STREAM: PackedVector2Array = [
	Vector2(232.0, 0.0), Vector2(237.0, 30.0), Vector2(230.0, 60.0), Vector2(235.0, 92.0),
	Vector2(232.0, 122.0), Vector2(232.0, 140.0), Vector2(232.0, 158.0), Vector2(238.0, 190.0),
	Vector2(246.0, 220.0), Vector2(240.0, 250.0), Vector2(245.0, 285.0), Vector2(240.0, 319.0),
]
const STREAM_HALF_M: float = 3.0
## Depth in meters by distance from the stream's center line, and from the
## pond's center. The keys sit 5 mm inside the level thresholds, so the stream
## is level 2 within 1.4 m of its middle and level 1 beyond, and the pond is
## level 3 within 7 m of its middle, 2 to 12, and 1 to its edge.
const STREAM_PROFILE: Array[Vector2] = [
	Vector2(0.0, 1.0), Vector2(1.4, 0.805), Vector2(3.0, 0.055),
]
const POND_CENTER: Vector2 = Vector2(232.0, 140.0)
const POND_RADIUS_M: float = 18.0
const POND_PROFILE: Array[Vector2] = [
	Vector2(0.0, 1.8), Vector2(7.0, 1.355), Vector2(12.0, 0.805), Vector2(18.0, 0.055),
]
## Sand runs this far beyond the water.
const SAND_BANK_M: float = 3.0

## The fields: BRUSH in a ring FIELD_INNER_M to FIELD_OUTER_M from the
## plateau's center (with a wavering edge), cut by grass lanes along these
## bearings (degrees, atan2(dz, dx)): the two ramps and the four directions.
## A lane is LANE_HALF_M either side of its bearing.
const FIELD_INNER_M: float = 35.0
const FIELD_OUTER_M: float = 75.0
const FIELD_EDGE_WAVER_M: float = 4.0
const LANE_BEARINGS_DEG: Array[float] = [-132.0, 48.0, 0.0, 90.0, 180.0, -90.0]
const LANE_HALF_M: float = 5.0

## What the mission data and tests are written against.
const DEPLOY: Vector2 = Vector2(156.0, 158.0)
const CAMERA_START: Vector2 = Vector2(160.0, 205.0)
## Edge spawn zones: north, west, south, east. The east one is across the
## millstream from the plateau.
const SPAWN_N: Vector2 = Vector2(150.0, 14.0)
const SPAWN_W: Vector2 = Vector2(14.0, 170.0)
const SPAWN_S: Vector2 = Vector2(150.0, 306.0)
const SPAWN_E: Vector2 = Vector2(306.0, 210.0)

## Noise layers and where each takes over.
const FIELD_SEED: int = 3102
const FIELD_FREQUENCY: float = 1.0 / 38.0
const EDGE_SEED: int = 3103
const EDGE_FREQUENCY: float = 1.0 / 30.0
const ROCK_SEED: int = 3104
const ROCK_FREQUENCY: float = 1.0 / 28.0
const SAND_SEED: int = 3105
const SAND_FREQUENCY: float = 1.0 / 34.0
const FIELD_THRESHOLD: float = -0.55
const ROCK_THRESHOLD: float = 0.44
const SAND_THRESHOLD: float = 0.40
## No scorch this close to the plateau's center, so the top and its cliff are
## clean ground and rock.
const SCORCH_CLEAR_M: float = 38.0

var _hills: FastNoiseLite
var _field: FastNoiseLite
var _edge: FastNoiseLite
var _rock: FastNoiseLite
var _sand: FastNoiseLite


func _initialize() -> void:
	_hills = MapBuilder.patches(HILLS_SEED, HILLS_FREQUENCY)
	_field = MapBuilder.patches(FIELD_SEED, FIELD_FREQUENCY)
	_edge = MapBuilder.patches(EDGE_SEED, EDGE_FREQUENCY)
	_rock = MapBuilder.patches(ROCK_SEED, ROCK_FREQUENCY)
	_sand = MapBuilder.patches(SAND_SEED, SAND_FREQUENCY)

	var map: MapBuilder = MapBuilder.new(SIZE, SIZE, CELL_SIZE, MAX_HEIGHT_M, MAX_WALKABLE_SLOPE)
	map.level_depths_m = LEVEL_DEPTHS_M
	map.fill(
		func(x: float, z: float) -> Vector2: return _ground(x, z),
		func(x: float, z: float, _height_m: float, _slope: float) -> int:
			return _ground_type(x, z)
	)
	map.plateau(
		PLATEAU_CENTER, top_radius, PLATEAU_TOP_M, CLIFF_WIDTH_M,
		[ramp(NW_RAMP_FOOT), ramp(SE_RAMP_FOOT)]
	)
	map.house(MILL_CENTER.x, MILL_CENTER.y, MILL_SIZE_M, MILL_SIZE_M, MILL_HEIGHT_M)

	var info: MapInfo = map.save(_out_dir(), "old_mill", "Old Mill", HERB_PLANTS)
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


## The plateau top's radius in meters at a bearing in radians (atan2(dz, dx)):
## PLATEAU_RADIUS_M wandering a few meters, so the top is a lumpy blob, 24.4
## to 30.2 m from its center. Public so the tests can find the edge.
static func top_radius(angle: float) -> float:
	return (
		PLATEAU_RADIUS_M + 1.8 * sin(2.0 * angle + 0.7)
		+ 1.2 * sin(3.0 * angle + 2.1) + 0.6 * sin(5.0 * angle + 4.0)
	)


## A ramp from a foot on the plain to the plateau's top edge on the same
## bearing from the center, in MapBuilder.plateau's format. Public for the
## tests.
static func ramp(foot: Vector2) -> Dictionary:
	var along: Vector2 = (foot - PLATEAU_CENTER).normalized()
	return {
		"from": foot,
		"to": PLATEAU_CENTER + along * top_radius(along.angle()),
		"width_m": RAMP_WIDTH_M,
	}


## (ground height, water depth) in meters at (x, z) meters: the plain, dug
## out where there is water.
func _ground(x: float, z: float) -> Vector2:
	var depth: float = _water_depth(x, z)
	return Vector2(_plain(x, z) - depth, depth)


func _plain(x: float, z: float) -> float:
	return clampf(PLAIN_BASE_M + PLAIN_AMPLITUDE_M * _hills.get_noise_2d(x, z), PLAIN_MIN_M, PLAIN_MAX_M)


## Water depth in meters at (x, z): the stream, or the pond.
func _water_depth(x: float, z: float) -> float:
	var depth: float = 0.0
	var to_pond: float = Vector2(x, z).distance_to(POND_CENTER)
	if to_pond < POND_RADIUS_M:
		depth = MapBuilder.profile(POND_PROFILE, to_pond)
	var to_stream: float = _stream_distance(x, z)
	if to_stream < STREAM_HALF_M:
		depth = maxf(depth, MapBuilder.profile(STREAM_PROFILE, to_stream))
	return depth


## Distance in meters from (x, z) to the stream's center line.
func _stream_distance(x: float, z: float) -> float:
	# The stream wanders between x 229 and 247; skip the polyline far from it.
	if absf(x - 238.0) > 40.0:
		return INF
	var nearest: float = INF
	var p: Vector2 = Vector2(x, z)
	for k: int in STREAM.size() - 1:
		nearest = minf(nearest, p.distance_to(Geometry2D.get_closest_point_to_segment(p, STREAM[k], STREAM[k + 1])))
	return nearest


## Ground type at (x, z) meters, from the water, the scorch, and the fields.
func _ground_type(x: float, z: float) -> int:
	var depth: float = _water_depth(x, z)
	var to_pond: float = Vector2(x, z).distance_to(POND_CENTER)
	if depth > 0.0 or to_pond < POND_RADIUS_M + SAND_BANK_M or _stream_distance(x, z) < STREAM_HALF_M + SAND_BANK_M:
		return Terrain.Ground.SAND
	var from_plateau: float = Vector2(x, z).distance_to(PLATEAU_CENTER)
	if from_plateau > SCORCH_CLEAR_M:
		if _rock.get_noise_2d(x, z) > ROCK_THRESHOLD:
			return Terrain.Ground.ROCK
		if _sand.get_noise_2d(x, z) > SAND_THRESHOLD:
			return Terrain.Ground.SAND
	if _in_field(x, z, from_plateau):
		return Terrain.Ground.BRUSH
	return Terrain.Ground.GRASS


## Whether (x, z) is wheat: inside the ring (its edges waver with noise), off
## the lanes, and where the field noise is not low (a few bare gaps).
func _in_field(x: float, z: float, from_plateau: float) -> bool:
	var wander: float = FIELD_EDGE_WAVER_M * _edge.get_noise_2d(x, z)
	if from_plateau < FIELD_INNER_M + wander or from_plateau > FIELD_OUTER_M + wander:
		return false
	var away: Vector2 = Vector2(x, z) - PLATEAU_CENTER
	for degrees: float in LANE_BEARINGS_DEG:
		var lane: Vector2 = Vector2.from_angle(deg_to_rad(degrees))
		# Across the lane's line, on the side the bearing points to.
		if away.dot(lane) > 0.0 and absf(away.cross(lane)) < LANE_HALF_M:
			return false
	return _field.get_noise_2d(x, z) > FIELD_THRESHOLD
