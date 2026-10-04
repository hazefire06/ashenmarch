extends SceneTree
## Generates the Riverside test map in maps/riverside/:
## - rolling hills
## - a creek meandering west to east across the full width, with a depth-3
##   core, depth-2 and depth-1 shoulders, and one depth-1 ford
## - ground types (Phase 5, the mask's G channel): sandy banks along the
##   creek, so it is a firebreak; rock on the high crests and steep ground;
##   copses of wood and patches of brush; grass everywhere else. The creek
##   bed is sand too, though water never burns anyway.
##
## Run with `make maps`. The PNGs it writes are the source of truth and are
## committed. Floats and FastNoiseLite are fine here because this runs
## offline, never inside the sim. The rasters, stamps, and file writing are
## MapBuilder's (scripts/mapgen/map_builder.gd); this script holds Riverside's
## own terrain.

const OUT_DIR: String = "res://maps/riverside/"
const SIZE: int = 512
const CELL_SIZE: int = 1000
const MAX_HEIGHT_M: float = 40.0
const MAX_WALKABLE_SLOPE: int = 1000
## Herb plants (x, z milli-units): two up the north bank behind the ford, two
## on the south side. Checked dry and walkable when placed.
const HERB_PLANTS: PackedInt32Array = [300000, 178000, 282000, 174000, 240000, 286000, 268000, 292000]
const NOISE_SEED: int = 1729
const NOISE_FREQUENCY: float = 1.0 / 210.0

const HILL_BASE_M: float = 15.0
const HILL_AMPLITUDE_M: float = 10.0
## Water surface height, falling west to east (the creek flows east).
const WATER_WEST_M: float = 6.0
const WATER_EAST_M: float = 4.0
## Channel half-width at the waterline and bed depth at its center.
const CHANNEL_HALF_M: float = 9.0
const CHANNEL_DEPTH_M: float = 1.8
## The bank rises BANK_HEIGHT_M above the water over BANK_M, then the valley
## side blends into the hills over VALLEY_M.
const BANK_M: float = 3.0
const BANK_HEIGHT_M: float = 0.6
const VALLEY_M: float = 45.0
## The ford: a gravel bar across the channel, FORD_DEPTH_M deep within
## FORD_HALF_M of FORD_X_M, ramping back to full depth over FORD_RAMP_M.
const FORD_X_M: float = 300.0
const FORD_HALF_M: float = 7.0
const FORD_RAMP_M: float = 3.0
const FORD_DEPTH_M: float = 0.4
## Minimum water depth in meters for levels 1, 2, 3.
const LEVEL_DEPTHS_M: Array[float] = [0.05, 0.8, 1.35]
## Sand runs this far beyond the channel's edge on both banks.
const SAND_BANK_M: float = 4.5
## Rock above this height, or steeper than this (m per m).
const ROCK_HEIGHT_M: float = 21.0
const ROCK_SLOPE: float = 0.55
## Wood copses and brush patches where their noise exceeds these.
const WOOD_SEED: int = 1730
const WOOD_FREQUENCY: float = 1.0 / 70.0
const WOOD_THRESHOLD: float = 0.32
const BRUSH_SEED: int = 1731
const BRUSH_FREQUENCY: float = 1.0 / 28.0
const BRUSH_THRESHOLD: float = 0.22


func _initialize() -> void:
	var noise: FastNoiseLite = FastNoiseLite.new()
	noise.seed = NOISE_SEED
	noise.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	noise.frequency = NOISE_FREQUENCY
	noise.fractal_type = FastNoiseLite.FRACTAL_FBM
	noise.fractal_octaves = 4

	var wood: FastNoiseLite = MapBuilder.patches(WOOD_SEED, WOOD_FREQUENCY)
	var brush: FastNoiseLite = MapBuilder.patches(BRUSH_SEED, BRUSH_FREQUENCY)

	var map: MapBuilder = MapBuilder.new(SIZE, SIZE, CELL_SIZE, MAX_HEIGHT_M, MAX_WALKABLE_SLOPE)
	map.level_depths_m = LEVEL_DEPTHS_M
	map.fill(
		func(x: float, z: float) -> Vector2: return _ground(noise, x, z),
		func(x: float, z: float, height_m: float, slope: float) -> int:
			return _ground_type(wood, brush, x, z, height_m, slope)
	)
	var info: MapInfo = map.save(OUT_DIR, "riverside", "Riverside", HERB_PLANTS)
	if info != null:
		map.report(info)
	quit(0 if info != null else 1)


## (ground height, water depth) in meters at (x, z) meters.
func _ground(noise: FastNoiseLite, x: float, z: float) -> Vector2:
	var extent_m: float = (SIZE - 1) * float(CELL_SIZE) / World.UNITS_PER_METER
	var water_m: float = lerpf(WATER_WEST_M, WATER_EAST_M, x / extent_m)
	var d: float = _creek_distance(x, z)
	if d < CHANNEL_HALF_M:
		var depth: float = CHANNEL_DEPTH_M * (1.0 - pow(d / CHANNEL_HALF_M, 2.0))
		depth = minf(depth, _ford_cap(x))
		return Vector2(water_m - depth, depth)

	var hills: float = HILL_BASE_M + HILL_AMPLITUDE_M * noise.get_noise_2d(x, z)
	# Keep dry ground above the creek's water line.
	hills = maxf(hills, water_m + BANK_HEIGHT_M + 0.2)
	var bank: float = smoothstep(CHANNEL_HALF_M, CHANNEL_HALF_M + BANK_M, d)
	var valley_start: float = CHANNEL_HALF_M + BANK_M * 0.5
	var valley: float = smoothstep(valley_start, valley_start + VALLEY_M, d)
	return Vector2(lerpf(water_m + BANK_HEIGHT_M * bank, hills, valley), 0.0)


## Ground type at (x, z) meters, given its height and slope (m per m).
func _ground_type(
	wood: FastNoiseLite, brush: FastNoiseLite, x: float, z: float, height_m: float, slope: float
) -> int:
	if _creek_distance(x, z) < CHANNEL_HALF_M + SAND_BANK_M:
		return Terrain.Ground.SAND
	if height_m > ROCK_HEIGHT_M or slope > ROCK_SLOPE:
		return Terrain.Ground.ROCK
	if wood.get_noise_2d(x, z) > WOOD_THRESHOLD:
		return Terrain.Ground.WOOD
	if brush.get_noise_2d(x, z) > BRUSH_THRESHOLD:
		return Terrain.Ground.BRUSH
	return Terrain.Ground.GRASS


## Perpendicular distance in meters from (x, z) to the creek's centerline,
## corrected for its slope.
func _creek_distance(x: float, z: float) -> float:
	var slope: float = _creek_dz(x)
	return absf(z - _creek_z(x)) / sqrt(1.0 + slope * slope)


func _creek_z(x: float) -> float:
	return 256.0 + 45.0 * sin(TAU * x / 420.0 + 0.6) + 12.0 * sin(TAU * x / 150.0 + 1.9)


func _creek_dz(x: float) -> float:
	return (
		45.0 * TAU / 420.0 * cos(TAU * x / 420.0 + 0.6)
		+ 12.0 * TAU / 150.0 * cos(TAU * x / 150.0 + 1.9)
	)


## Maximum channel depth at x: shallow over the ford, full depth elsewhere.
func _ford_cap(x: float) -> float:
	var along: float = absf(x - FORD_X_M)
	return lerpf(
		FORD_DEPTH_M,
		CHANNEL_DEPTH_M,
		smoothstep(FORD_HALF_M, FORD_HALF_M + FORD_RAMP_M, along)
	)
