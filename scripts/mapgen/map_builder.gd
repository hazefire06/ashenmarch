class_name MapBuilder
extends RefCounted
## Shared tool code for the offline map generators (scripts/gen_*.gd). It owns
## the height and mask rasters and the float working arrays behind them, runs
## the two-pass base fill, applies structure stamps (house, wall, plateau,
## road), and writes the PNGs, their keep-importer files, and the MapInfo.
##
## Offline only: floats, trig, and FastNoiseLite are fine here because none of
## it ever runs in the sim. What it writes is the source of truth, committed.
##
## Usage: fill() once, then any stamps, then save() and report().
##
## Stamps work on the working arrays, so each one sees the ones before it:
## the order is part of a map's recipe. A raised, blocked sample is solid to
## pathing and stops projectiles (their contact test reads the height field),
## and the sim's per-sample slope counts a step to a neighbor as a cliff. So
## the ring of samples around any raised structure is steep too, and a gap or
## ramp needs a few samples of width to keep a walkable core.

## Minimum water depth in meters for levels 1, 2, 3. Set before fill() if a
## map wants other thresholds.
var level_depths_m: Array[float] = [0.05, 0.8, 1.35]

var size_x: int
var size_z: int
## Milli-units between samples (MapInfo.cell_size).
var cell_size: int
## Meters between samples.
var cell_m: float
## Height of the heightmap's maximum raw value, in meters.
var max_height_m: float
## Permille (MapInfo.max_walkable_slope).
var max_walkable_slope: int
## Ground height in meters per sample, row-major (j * size_x + i). Stored as
## 32-bit floats, the same precision a Vector2 returned by the fill carries.
var heights_m: PackedFloat32Array = PackedFloat32Array()
## Water depth level 0..Terrain.MAX_WATER_DEPTH per sample.
var levels: PackedByteArray = PackedByteArray()
## Ground type (Terrain.Ground) per sample.
var grounds: PackedByteArray = PackedByteArray()
## 1 where a structure makes the sample solid, else 0.
var blocked: PackedByteArray = PackedByteArray()


func _init(
	samples_x: int, samples_z: int, spacing: int, height_range_m: float, walkable_slope: int
) -> void:
	size_x = samples_x
	size_z = samples_z
	cell_size = spacing
	cell_m = float(spacing) / World.UNITS_PER_METER
	max_height_m = height_range_m
	max_walkable_slope = walkable_slope
	var count: int = samples_x * samples_z
	heights_m.resize(count)
	levels.resize(count)
	grounds.resize(count)
	blocked.resize(count)


## Fills the whole map in two passes, because ground types need the slope,
## which needs every height first.
## - height_and_depth(x_m: float, z_m: float) -> Vector2: (ground height, water
##   depth) in meters. The depth becomes a level through level().
## - ground_type(x_m: float, z_m: float, height_m: float, slope: float) -> int:
##   a Terrain.Ground, given the sample's height and its slope (m per m).
func fill(height_and_depth: Callable, ground_type: Callable) -> void:
	for j: int in size_z:
		for i: int in size_x:
			var sample: Vector2 = height_and_depth.call(i * cell_m, j * cell_m)
			var k: int = j * size_x + i
			heights_m[k] = sample.x
			levels[k] = level(sample.y)
	for j: int in size_z:
		for i: int in size_x:
			var k: int = j * size_x + i
			grounds[k] = ground_type.call(i * cell_m, j * cell_m, heights_m[k], slope_at(i, j))


## Water depth level for a depth in meters (level_depths_m).
func level(depth_m: float) -> int:
	var result: int = 0
	for threshold: float in level_depths_m:
		if depth_m >= threshold:
			result += 1
	return result


## Steepness at sample (i, j), m per m, by central differences (one-sided at
## the edges). The sim's own passability slope takes the steeper edge instead,
## so a generator's number is a little kinder than the sim's.
func slope_at(i: int, j: int) -> float:
	var i0: int = maxi(i - 1, 0)
	var i1: int = mini(i + 1, size_x - 1)
	var j0: int = maxi(j - 1, 0)
	var j1: int = mini(j + 1, size_z - 1)
	var gx: float = (heights_m[j * size_x + i1] - heights_m[j * size_x + i0]) / ((i1 - i0) * cell_m)
	var gz: float = (heights_m[j1 * size_x + i] - heights_m[j0 * size_x + i]) / ((j1 - j0) * cell_m)
	return sqrt(gx * gx + gz * gz)


## Layered FBM simplex noise for wood copses and brush patches: sample it with
## get_noise_2d and compare to a threshold.
static func patches(noise_seed: int, frequency: float) -> FastNoiseLite:
	var n: FastNoiseLite = FastNoiseLite.new()
	n.seed = noise_seed
	n.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	n.frequency = frequency
	n.fractal_type = FastNoiseLite.FRACTAL_FBM
	n.fractal_octaves = 3
	return n


## A house: the footprint, w_m by d_m centered on (cx_m, cz_m), is raised to
## the highest ground under it plus height_m (a flat roof), blocked, and made
## WOOD, so it burns and stops projectiles. A sample belongs to the footprint
## if its position lies in [center - size / 2, center + size / 2), so a 6 m
## house covers 6 samples a side. Returns the number of samples stamped.
func house(cx_m: float, cz_m: float, w_m: float, d_m: float, height_m: float = 3.0) -> int:
	var rect: Rect2i = _footprint(cx_m - w_m / 2.0, cz_m - d_m / 2.0, cx_m + w_m / 2.0, cz_m + d_m / 2.0)
	if rect.get_area() == 0:
		return 0
	var top: float = -INF
	for j: int in range(rect.position.y, rect.end.y):
		for i: int in range(rect.position.x, rect.end.x):
			top = maxf(top, heights_m[j * size_x + i])
	top += height_m
	var wet: int = 0
	for j: int in range(rect.position.y, rect.end.y):
		for i: int in range(rect.position.x, rect.end.x):
			var k: int = j * size_x + i
			wet += 1 if levels[k] != 0 else 0
			heights_m[k] = top
			blocked[k] = 1
			grounds[k] = Terrain.Ground.WOOD
	_warn_if_wet(wet, "house at (%.1f, %.1f)" % [cx_m, cz_m])
	return rect.get_area()


## A wall along a polyline, height_m above the ground under each sample (so it
## follows the land), blocked, ROCK. A sample is in it if it lies within
## thickness_m / 2 of the line, so a line along a sample row is 1 sample thick
## at 1 m, 3 at 2 or 3 m, 5 at 4 or 5 m. gaps are open stretches (gates), each
## a Vector2(start_m, end_m) measured along the polyline from its first point.
## Keep a gate at least 4 m wide: the samples beside a wall end are steep, so a
## narrower one leaves no walkable core.
func wall(points_m: PackedVector2Array, thickness_m: float, height_m: float, gaps: Array = []) -> void:
	for gap: Vector2 in gaps:
		if gap.y - gap.x < 4.0:
			push_warning("wall gap %s is under 4 m wide; it has no walkable core" % gap)
	var reach: float = thickness_m / 2.0
	var start: float = 0.0
	# Each sample once, so a corner shared by two segments isn't raised twice.
	var solid: Dictionary[int, bool] = {}
	for s: int in points_m.size() - 1:
		var a: Vector2 = points_m[s]
		var b: Vector2 = points_m[s + 1]
		for k: int in _samples_near(a, b, reach):
			var p: Vector2 = Vector2((k % size_x) * cell_m, (k / size_x) * cell_m)
			if not _in_gap(start + a.distance_to(_closest_on_segment(p, a, b)), gaps):
				solid[k] = true
		start += a.distance_to(b)
	var wet: int = 0
	for k: int in solid:
		wet += 1 if levels[k] != 0 else 0
		heights_m[k] += height_m
		blocked[k] = 1
		grounds[k] = Terrain.Ground.ROCK
	_warn_if_wet(wet, "wall from %s" % points_m[0])


## A raised area: a flat top at top_height_m out to radius_m of center_m, then
## a cliff band cliff_width_m wide falling back to the ground, made ROCK.
## radius_m is a float (a circle) or a Callable taking the bearing in radians
## and returning the radius there (a lumpy hill). The band is steeper than the
## sim allows walking on when (top - ground) / cliff_width_m exceeds
## max_walkable_slope / 1000; a warning says so if it isn't.
## ramps are the ways up: each a Dictionary {from: Vector2 (the foot, meters),
## to: Vector2 (where it meets the top, on the top's edge, meters), width_m:
## float}. A ramp is a straight strip graded from the ground at its foot to
## top_height_m at its end, cut or filled as needed, with the ground it had
## before; the top itself is left alone. Keep it at least 4 m wide (the sim
## counts the strip's edge samples as steep) and no steeper than 70% of the
## walkable limit; both are checked. End it on the edge: a ramp that stops short
## leaves a step, and one that runs deeper is shallower than it looks.
func plateau(
	center_m: Vector2, radius_m: Variant, top_height_m: float, cliff_width_m: float, ramps: Array = []
) -> void:
	var radius_at: Callable
	if radius_m is Callable:
		radius_at = radius_m
	else:
		var fixed: float = radius_m
		radius_at = func(_angle: float) -> float: return fixed
	var widest: float = 0.0
	for degrees: int in 360:
		var r: float = radius_at.call(deg_to_rad(degrees))
		widest = maxf(widest, r)
	var inside: Callable = func(x: float, z: float) -> float:
		var d: Vector2 = Vector2(x, z) - center_m
		var r: float = radius_at.call(atan2(d.y, d.x))
		return d.length() - r
	var reach: Vector2 = Vector2.ONE * (widest + cliff_width_m)
	_raise(inside, top_height_m, cliff_width_m, ramps, center_m - reach, center_m + reach)


## Like plateau(), but the top is the area inside a closed polygon (points in
## meters, any winding; the last point joins the first).
func plateau_polygon(
	points_m: PackedVector2Array, top_height_m: float, cliff_width_m: float, ramps: Array = []
) -> void:
	var lo: Vector2 = points_m[0]
	var hi: Vector2 = points_m[0]
	for p: Vector2 in points_m:
		lo = Vector2(minf(lo.x, p.x), minf(lo.y, p.y))
		hi = Vector2(maxf(hi.x, p.x), maxf(hi.y, p.y))
	var inside: Callable = func(x: float, z: float) -> float:
		return _polygon_signed_distance(Vector2(x, z), points_m)
	_raise(inside, top_height_m, cliff_width_m, ramps, lo - Vector2.ONE * cliff_width_m, hi + Vector2.ONE * cliff_width_m)


## A road: every unblocked sample within width_m / 2 of the polyline becomes
## SAND, which cannot burn, so a road is also a firebreak.
func road(points_m: PackedVector2Array, width_m: float) -> void:
	for s: int in points_m.size() - 1:
		for k: int in _samples_near(points_m[s], points_m[s + 1], width_m / 2.0):
			if blocked[k] == 0:
				grounds[k] = Terrain.Ground.SAND


## Patches of one ground type: every unblocked, dry sample whose noise exceeds
## threshold within radius_m of center_m takes this type. For a few brush or
## wood patches by hand around a structure.
func patch(center_m: Vector2, radius_m: float, noise: FastNoiseLite, threshold: float, type: int) -> void:
	var rect: Rect2i = _footprint(
		center_m.x - radius_m, center_m.y - radius_m, center_m.x + radius_m + cell_m, center_m.y + radius_m + cell_m
	)
	for j: int in range(rect.position.y, rect.end.y):
		for i: int in range(rect.position.x, rect.end.x):
			var k: int = j * size_x + i
			var p: Vector2 = Vector2(i * cell_m, j * cell_m)
			if p.distance_to(center_m) > radius_m or blocked[k] != 0 or levels[k] != 0:
				continue
			if noise.get_noise_2d(p.x, p.y) > threshold:
				grounds[k] = type


## The height PNG: 16-bit gray, the working heights scaled onto 0..65535 over
## 0..max_height_m.
func height_raster() -> PngRaster:
	var raster: PngRaster = PngRaster.create(size_x, size_z, 1, 16)
	for j: int in size_z:
		for i: int in size_x:
			var raw: int = clampi(roundi(heights_m[j * size_x + i] / max_height_m * 65535.0), 0, 65535)
			raster.set_sample(i, j, 0, raw)
	return raster


## The mask PNG, RGB8: R depth level, G ground type, B 255 where blocked.
func mask_raster() -> PngRaster:
	var raster: PngRaster = PngRaster.create(size_x, size_z, 3, 8)
	for k: int in size_x * size_z:
		var i: int = k % size_x
		var j: int = k / size_x
		raster.set_sample(i, j, 0, Terrain.mask_from_depth(levels[k]))
		raster.set_sample(i, j, 1, Terrain.mask_from_ground(grounds[k]))
		raster.set_sample(i, j, 2, 255 if blocked[k] != 0 else 0)
	return raster


## Writes <out_dir>/height.png, mask.png, and <name>.tres (a MapInfo), plus
## each PNG's keep-importer file, which has to exist before Godot first scans
## the PNG (otherwise it imports it as a texture, and an export drops the
## file). out_dir ends in a slash, like "res://maps/riverside/". Returns the
## MapInfo, or null if anything failed to write.
func save(out_dir: String, name: String, display_name: String, herb_plants: PackedInt32Array = PackedInt32Array()) -> MapInfo:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(out_dir))
	var ok: bool = true
	for file: String in ["height.png", "mask.png"]:
		ok = _write_text(out_dir + file + ".import", "[remap]\n\nimporter=\"keep\"\n") and ok
	ok = _write_bytes(out_dir + "height.png", PngCodec.encode(height_raster())) and ok
	ok = _write_bytes(out_dir + "mask.png", PngCodec.encode(mask_raster())) and ok
	var info: MapInfo = MapInfo.new()
	info.display_name = display_name
	info.heightmap_path = out_dir + "height.png"
	info.mask_path = out_dir + "mask.png"
	info.cell_size = cell_size
	info.max_height = roundi(max_height_m * World.UNITS_PER_METER)
	info.max_walkable_slope = max_walkable_slope
	info.herb_plants = herb_plants
	var err: Error = ResourceSaver.save(info, out_dir + name + ".tres")
	if err != OK:
		push_error("saving %s.tres: %s" % [name, error_string(err)])
		ok = false
	return info if ok else null


## Reloads the written map through the sim and prints what it contains.
func report(info: MapInfo) -> void:
	var terrain: Terrain = Terrain.load_map(info)
	if terrain == null:
		return
	var water: Array[int] = [0, 0, 0, 0, 0]
	var grounds_seen: Array[int] = [0, 0, 0, 0, 0]
	var steep: int = 0
	var solid: int = 0
	var max_slope: int = 0
	for k: int in terrain.heights.size():
		water[terrain.water[k]] += 1
		grounds_seen[terrain.ground[k]] += 1
		solid += terrain.blocked[k]
		max_slope = maxi(max_slope, terrain.sample_slopes[k])
		if terrain.sample_slopes[k] > terrain.max_walkable_slope:
			steep += 1
	var heights: Array = Array(terrain.heights)
	print("terrain %dx%d, heights %d..%d mm" % [
		terrain.size_x, terrain.size_z, heights.min(), heights.max()
	])
	print("water samples by depth level 0..4: %s" % [water])
	print("samples by ground (grass, brush, wood, sand, rock): %s" % [grounds_seen])
	print("max sample slope %d permille; %d samples steeper than %d; %d blocked" % [
		max_slope, steep, terrain.max_walkable_slope, solid
	])


# The samples a footprint [x0, x1) by [z0, z1) in meters covers, as a grid
# rectangle clamped to the map: those whose position lies inside it.
func _footprint(x0: float, z0: float, x1: float, z1: float) -> Rect2i:
	var i0: int = clampi(ceili(x0 / cell_m), 0, size_x)
	var j0: int = clampi(ceili(z0 / cell_m), 0, size_z)
	var i1: int = clampi(ceili(x1 / cell_m), 0, size_x)
	var j1: int = clampi(ceili(z1 / cell_m), 0, size_z)
	return Rect2i(i0, j0, maxi(i1 - i0, 0), maxi(j1 - j0, 0))


# Indices of the samples within reach_m of the segment a-b (end caps round).
func _samples_near(a: Vector2, b: Vector2, reach_m: float) -> PackedInt32Array:
	var found: PackedInt32Array = PackedInt32Array()
	var rect: Rect2i = _footprint(
		minf(a.x, b.x) - reach_m, minf(a.y, b.y) - reach_m,
		maxf(a.x, b.x) + reach_m + cell_m, maxf(a.y, b.y) + reach_m + cell_m
	)
	for j: int in range(rect.position.y, rect.end.y):
		for i: int in range(rect.position.x, rect.end.x):
			var p: Vector2 = Vector2(i * cell_m, j * cell_m)
			if p.distance_to(_closest_on_segment(p, a, b)) <= reach_m:
				found.append(j * size_x + i)
	return found


static func _closest_on_segment(p: Vector2, a: Vector2, b: Vector2) -> Vector2:
	var ab: Vector2 = b - a
	var length_sq: float = ab.length_squared()
	if length_sq == 0.0:
		return a
	return a + ab * clampf((p - a).dot(ab) / length_sq, 0.0, 1.0)


static func _in_gap(along_m: float, gaps: Array) -> bool:
	for gap: Vector2 in gaps:
		if along_m >= gap.x and along_m <= gap.y:
			return true
	return false


# Signed distance in meters from p to a polygon's edge: negative inside.
static func _polygon_signed_distance(p: Vector2, polygon: PackedVector2Array) -> float:
	var nearest: float = INF
	for k: int in polygon.size():
		var a: Vector2 = polygon[k]
		var b: Vector2 = polygon[(k + 1) % polygon.size()]
		nearest = minf(nearest, p.distance_to(_closest_on_segment(p, a, b)))
	return -nearest if Geometry2D.is_point_in_polygon(p, polygon) else nearest


# Shared body of the plateaus. distance(x_m, z_m) is the signed distance in
# meters from the top's edge (negative on the top); samples inside the box
# from lo to hi (meters) are considered.
func _raise(
	distance: Callable, top_m: float, cliff_width_m: float, ramps: Array, lo: Vector2, hi: Vector2
) -> void:
	var rect: Rect2i = _footprint(lo.x, lo.y, hi.x + cell_m, hi.y + cell_m)
	var before_heights: PackedFloat32Array = heights_m.duplicate()
	var before_grounds: PackedByteArray = grounds.duplicate()
	var on_top: PackedByteArray = PackedByteArray()
	on_top.resize(size_x * size_z)
	var gentlest_rise: float = INF
	var wet: int = 0
	for j: int in range(rect.position.y, rect.end.y):
		for i: int in range(rect.position.x, rect.end.x):
			var d: float = distance.call(i * cell_m, j * cell_m)
			if d > cliff_width_m:
				continue
			var k: int = j * size_x + i
			wet += 1 if levels[k] != 0 else 0
			if d <= 0.0:
				heights_m[k] = top_m
				on_top[k] = 1
			else:
				heights_m[k] = lerpf(top_m, heights_m[k], d / cliff_width_m)
				grounds[k] = Terrain.Ground.ROCK
				gentlest_rise = minf(gentlest_rise, (top_m - before_heights[k]) / cliff_width_m)
	_warn_if_wet(wet, "plateau")
	if gentlest_rise <= max_walkable_slope / 1000.0:
		push_warning(
			"plateau cliff is only %.2f m per m at its gentlest; the walkable limit is %.2f"
			% [gentlest_rise, max_walkable_slope / 1000.0]
		)
	for ramp: Dictionary in ramps:
		_ramp(ramp, top_m, before_heights, before_grounds, on_top)


# One ramp: graded from the ground height at its foot (before the plateau was
# raised) to top_m at its end, over the strip width_m wide around the line.
# The top itself (on_top) is left alone, so a ramp that runs on past the edge
# doesn't cut a trench into it.
func _ramp(
	ramp: Dictionary, top_m: float, before_heights: PackedFloat32Array,
	before_grounds: PackedByteArray, on_top: PackedByteArray
) -> void:
	var from: Vector2 = ramp["from"]
	var to: Vector2 = ramp["to"]
	var width_m: float = ramp["width_m"]
	var foot: Vector2i = Vector2i(roundi(from.x / cell_m), roundi(from.y / cell_m))
	var foot_m: float = before_heights[clampi(foot.y, 0, size_z - 1) * size_x + clampi(foot.x, 0, size_x - 1)]
	var length: float = from.distance_to(to)
	var grade: float = (top_m - foot_m) / length
	if width_m < 4.0:
		push_warning("ramp from %s is %.1f m wide; under 4 m has no walkable core" % [from, width_m])
	if absf(grade) > 0.7 * max_walkable_slope / 1000.0:
		push_warning(
			"ramp from %s climbs %.2f m per m; over 70%% of the walkable limit" % [from, grade]
		)
	var ab: Vector2 = to - from
	for k: int in _samples_near(from, to, width_m / 2.0):
		var p: Vector2 = Vector2((k % size_x) * cell_m, (k / size_x) * cell_m)
		var t: float = (p - from).dot(ab) / ab.length_squared()
		if t < 0.0 or t > 1.0 or on_top[k] != 0:
			continue
		heights_m[k] = lerpf(foot_m, top_m, t)
		grounds[k] = before_grounds[k]


# A structure belongs on dry land: water depth is independent of height, so a
# stamp on water leaves a house standing in the creek.
func _warn_if_wet(wet_samples: int, what: String) -> void:
	if wet_samples > 0:
		push_warning("%s stands on %d samples of water" % [what, wet_samples])


func _write_text(path: String, text: String) -> bool:
	return _write_bytes(path, text.to_utf8_buffer())


func _write_bytes(path: String, bytes: PackedByteArray) -> bool:
	var file: FileAccess = FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		push_error("writing %s: %s" % [path, error_string(FileAccess.get_open_error())])
		return false
	file.store_buffer(bytes)
	print("wrote %s (%d bytes)" % [path, bytes.size()])
	return true
