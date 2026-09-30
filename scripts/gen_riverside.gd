extends SceneTree
## Generates the Riverside test map in maps/riverside/:
## - rolling hills
## - a creek meandering west to east across the full width, with a depth-3
##   core, depth-2 and depth-1 shoulders, and one depth-1 ford
##
## Run with `make maps`. The PNGs it writes are the source of truth and are
## committed. Floats and FastNoiseLite are fine here because this runs
## offline, never inside the sim.

const OUT_DIR: String = "res://maps/riverside/"
const SIZE: int = 512
const CELL_SIZE: int = 1000
const MAX_HEIGHT_M: float = 40.0
const MAX_WALKABLE_SLOPE: int = 1000
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


func _initialize() -> void:
	var noise: FastNoiseLite = FastNoiseLite.new()
	noise.seed = NOISE_SEED
	noise.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	noise.frequency = NOISE_FREQUENCY
	noise.fractal_type = FastNoiseLite.FRACTAL_FBM
	noise.fractal_octaves = 4

	var cell_m: float = float(CELL_SIZE) / World.UNITS_PER_METER
	var height: PngRaster = PngRaster.create(SIZE, SIZE, 1, 16)
	var mask: PngRaster = PngRaster.create(SIZE, SIZE, 3, 8)
	for j: int in SIZE:
		for i: int in SIZE:
			var ground: Vector2 = _ground(noise, i * cell_m, j * cell_m)
			var raw: int = clampi(roundi(ground.x / MAX_HEIGHT_M * 65535.0), 0, 65535)
			height.set_sample(i, j, 0, raw)
			mask.set_sample(i, j, 0, Terrain.mask_from_depth(_level(ground.y)))

	_write(OUT_DIR + "height.png", PngCodec.encode(height))
	_write(OUT_DIR + "mask.png", PngCodec.encode(mask))

	var info: MapInfo = MapInfo.new()
	info.display_name = "Riverside"
	info.heightmap_path = OUT_DIR + "height.png"
	info.mask_path = OUT_DIR + "mask.png"
	info.cell_size = CELL_SIZE
	info.max_height = roundi(MAX_HEIGHT_M * World.UNITS_PER_METER)
	info.max_walkable_slope = MAX_WALKABLE_SLOPE
	var err: Error = ResourceSaver.save(info, OUT_DIR + "riverside.tres")
	if err != OK:
		push_error("saving riverside.tres: %s" % error_string(err))
	_report(info)
	quit()


## (ground height, water depth) in meters at (x, z) meters.
func _ground(noise: FastNoiseLite, x: float, z: float) -> Vector2:
	var extent_m: float = (SIZE - 1) * float(CELL_SIZE) / World.UNITS_PER_METER
	var water_m: float = lerpf(WATER_WEST_M, WATER_EAST_M, x / extent_m)
	var slope: float = _creek_dz(x)
	# Perpendicular distance to the centerline, corrected for its slope.
	var d: float = absf(z - _creek_z(x)) / sqrt(1.0 + slope * slope)
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


func _level(depth_m: float) -> int:
	var level: int = 0
	for threshold: float in LEVEL_DEPTHS_M:
		if depth_m >= threshold:
			level += 1
	return level


func _write(path: String, bytes: PackedByteArray) -> void:
	var file: FileAccess = FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		push_error("writing %s: %s" % [path, error_string(FileAccess.get_open_error())])
		return
	file.store_buffer(bytes)
	print("wrote %s (%d bytes)" % [path, bytes.size()])


## Reloads the written map through the sim and prints what it contains.
func _report(info: MapInfo) -> void:
	var terrain: Terrain = Terrain.load_map(info)
	if terrain == null:
		return
	var levels: Array[int] = [0, 0, 0, 0, 0]
	var steep: int = 0
	var max_slope: int = 0
	for k: int in terrain.heights.size():
		levels[terrain.water[k]] += 1
		max_slope = maxi(max_slope, terrain.sample_slopes[k])
		if terrain.sample_slopes[k] > terrain.max_walkable_slope:
			steep += 1
	var heights: Array = Array(terrain.heights)
	print("terrain %dx%d, heights %d..%d mm" % [
		terrain.size_x, terrain.size_z, heights.min(), heights.max()
	])
	print("water samples by depth level 0..4: %s" % [levels])
	print("max sample slope %d permille; %d samples steeper than %d" % [
		max_slope, steep, terrain.max_walkable_slope
	])
