class_name Terrain
extends RefCounted
## Heightfield plus a water-depth and passability grid. All queries are pure
## integer functions of milli-unit coordinates.
##
## Samples sit at grid vertices: sample (i, j) is at x = i * cell_size,
## z = j * cell_size, so the map spans (size_x - 1) * cell_size by
## (size_z - 1) * cell_size. i is the image column (x), j the image row (z),
## and the top image row is z = 0.
##
## Heights interpolate bilinearly between samples. Water depth, the blocked
## flag, and passability use the nearest sample, so a point query agrees with
## the sample grid that pathing runs on.
##
## Slopes are permille: millimetres of rise per metre of run (1000 = 45 deg).
##
## Mask PNG encoding (8-bit RGB or RGBA):
## - R: water depth level * MASK_DEPTH_STEP (0, 60, 120, 180, 240), so levels
##   are visible in an image editor. Decoded to the nearest level.
## - G: reserved for ground type (fire spread, Phase 5).
## - B: >= MASK_BLOCKED_THRESHOLD means blocked for every unit.

## How a unit type moves over terrain. Phase 2's UnitType carries one.
enum Mobility {
	## Refuses water of LIVING_IMPASSABLE_DEPTH or deeper and steep slopes.
	LIVING,
	## Crosses any water depth. Refuses steep slopes.
	UNDEAD,
	## Ignores water and slope (Drifter). Still stopped by blocked samples.
	FLOATING,
}

const MAX_WATER_DEPTH: int = 4
const LIVING_IMPASSABLE_DEPTH: int = 3
## Milli-units: the deepest explosions can dig any sample below the map's
## own height, however many land on it.
const MAX_SCAR_DEPTH: int = 1000
const MASK_DEPTH_STEP: int = 60
const MASK_BLOCKED_THRESHOLD: int = 128
const PERMILLE: int = 1000

var size_x: int
var size_z: int
## Milli-units between adjacent samples.
var cell_size: int
## Permille. Walking mobilities can't stand on a steeper sample.
var max_walkable_slope: int
## Milli-units, row-major (index j * size_x + i). May go negative once
## explosions scar the ground; height_at rounds correctly either way.
var heights: PackedInt32Array
## Water depth level 0..MAX_WATER_DEPTH per sample.
var water: PackedByteArray
## 1 where impassable to every mobility, else 0.
var blocked: PackedByteArray
## Per-sample slope in permille: along each axis, the steeper of the edges to
## the two neighbors, combined into a magnitude. Taking the steeper edge
## (not a central difference) keeps a one-cell cliff from averaging down to
## walkable. Used for passability, which is decided per sample. Computed
## from the map as loaded and never updated: craters change heights but not
## where anyone can walk, so pathing never has to be rebuilt mid-mission.
var sample_slopes: PackedInt32Array
## Crater scars: sample index -> milli-units dug below the map's own height,
## at most MAX_SCAR_DEPTH. Sparse; part of World.state_hash().
var scars: Dictionary[int, int] = {}


## precomputed_slopes skips the slope pass; copy_for_world() passes its own.
func _init(
	samples_x: int,
	samples_z: int,
	spacing: int,
	sample_heights: PackedInt32Array,
	sample_water: PackedByteArray,
	sample_blocked: PackedByteArray,
	walkable_slope: int,
	precomputed_slopes: PackedInt32Array = PackedInt32Array()
) -> void:
	assert(samples_x >= 2 and samples_z >= 2, "terrain needs at least 2x2 samples")
	assert(spacing > 0, "cell_size must be positive")
	var count: int = samples_x * samples_z
	assert(sample_heights.size() == count and sample_water.size() == count)
	assert(sample_blocked.size() == count)
	size_x = samples_x
	size_z = samples_z
	cell_size = spacing
	max_walkable_slope = walkable_slope
	heights = sample_heights
	water = sample_water
	blocked = sample_blocked
	sample_slopes = precomputed_slopes if precomputed_slopes.size() == count else _compute_sample_slopes()


## Reads the heightmap and mask named by a MapInfo. Returns null (after
## push_error) if either file is missing or invalid.
static func load_map(info: MapInfo) -> Terrain:
	if info.cell_size <= 0 or info.max_height <= 0 or info.max_walkable_slope <= 0:
		push_error(
			"Terrain: map %s needs positive cell_size, max_height, and max_walkable_slope"
			% info.resource_path
		)
		return null
	var height_bytes: PackedByteArray = _read_file(info.heightmap_path)
	var mask_bytes: PackedByteArray = _read_file(info.mask_path)
	if height_bytes.is_empty() or mask_bytes.is_empty():
		return null
	return from_png(
		height_bytes, mask_bytes, info.cell_size, info.max_height, info.max_walkable_slope
	)


## Builds a terrain from PNG file bytes. The heightmap is 8- or 16-bit
## grayscale; its maximum raw value maps to max_height milli-units. The mask
## is 8-bit RGB or RGBA of the same size. Returns null (after push_error) on
## invalid input.
static func from_png(
	height_png: PackedByteArray,
	mask_png: PackedByteArray,
	spacing: int,
	max_height: int,
	walkable_slope: int
) -> Terrain:
	var height_raster: PngRaster = PngCodec.decode(height_png)
	if not height_raster.ok():
		push_error("Terrain heightmap: %s" % height_raster.error)
		return null
	if height_raster.channels != 1:
		push_error("Terrain heightmap must be grayscale, got %d channels" % height_raster.channels)
		return null
	var mask_raster: PngRaster = PngCodec.decode(mask_png)
	if not mask_raster.ok():
		push_error("Terrain mask: %s" % mask_raster.error)
		return null
	if mask_raster.channels < 3 or mask_raster.bit_depth != 8:
		push_error("Terrain mask must be 8-bit RGB or RGBA")
		return null
	var w: int = height_raster.width
	var h: int = height_raster.height
	if mask_raster.width != w or mask_raster.height != h:
		push_error(
			"Terrain mask is %dx%d but heightmap is %dx%d"
			% [mask_raster.width, mask_raster.height, w, h]
		)
		return null
	if w < 2 or h < 2:
		push_error("Terrain needs at least 2x2 samples, got %dx%d" % [w, h])
		return null

	var count: int = w * h
	var raw_max: int = (1 << height_raster.bit_depth) - 1
	var raw_heights: PackedInt32Array = height_raster.samples
	var mask: PackedInt32Array = mask_raster.samples
	var stride: int = mask_raster.channels
	var sample_heights: PackedInt32Array = PackedInt32Array()
	var sample_water: PackedByteArray = PackedByteArray()
	var sample_blocked: PackedByteArray = PackedByteArray()
	sample_heights.resize(count)
	sample_water.resize(count)
	sample_blocked.resize(count)
	for k: int in count:
		sample_heights[k] = (raw_heights[k] * max_height + raw_max / 2) / raw_max
		sample_water[k] = depth_from_mask(mask[k * stride])
		sample_blocked[k] = 1 if mask[k * stride + 2] >= MASK_BLOCKED_THRESHOLD else 0
	return Terrain.new(w, h, spacing, sample_heights, sample_water, sample_blocked, walkable_slope)


## A terrain for one World to own: the same map with its own heights, so two
## worlds built from one loaded map (lockstep tests, replays) can't scar each
## other. Packed arrays are shared by reference in Godot 4, so the heights
## are duplicated (one native copy); water, blocked, and slopes are never
## written after loading and stay shared.
func copy_for_world() -> Terrain:
	var copy: Terrain = Terrain.new(
		size_x, size_z, cell_size, heights.duplicate(), water, blocked, max_walkable_slope, sample_slopes
	)
	copy.scars = scars.duplicate()
	return copy


## Digs a bowl-shaped crater centered on (x, z): depth at the center, easing
## to nothing at radius. A sample's total scar never exceeds MAX_SCAR_DEPTH.
## Returns the grid rectangle of samples that changed (empty if none), for
## the view to re-mesh.
func scar(x: int, z: int, radius: int, depth: int) -> Rect2i:
	if radius <= 0 or depth <= 0:
		return Rect2i()
	var r2: int = radius * radius
	var i0: int = maxi(0, FixedMath.div_floor(x - radius, cell_size) + 1)
	var i1: int = mini(size_x - 1, FixedMath.div_floor(x + radius, cell_size))
	var j0: int = maxi(0, FixedMath.div_floor(z - radius, cell_size) + 1)
	var j1: int = mini(size_z - 1, FixedMath.div_floor(z + radius, cell_size))
	var changed: Rect2i = Rect2i()
	for j: int in range(j0, j1 + 1):
		for i: int in range(i0, i1 + 1):
			var dx: int = i * cell_size - x
			var dz: int = j * cell_size - z
			var d2: int = dx * dx + dz * dz
			if d2 >= r2:
				continue
			var k: int = j * size_x + i
			var before: int = scars.get(k, 0)
			var after: int = mini(MAX_SCAR_DEPTH, before + depth * (r2 - d2) / r2)
			if after == before:
				continue
			scars[k] = after
			heights[k] -= after - before
			var cell: Rect2i = Rect2i(i, j, 1, 1)
			changed = cell if changed.size == Vector2i.ZERO else changed.merge(cell)
	return changed


## The scars in sample order, for World.state_hash().
func scar_hash_fields() -> PackedInt64Array:
	var keys: Array[int] = []
	keys.assign(scars.keys())
	keys.sort()
	var fields: PackedInt64Array = PackedInt64Array([keys.size()])
	for k: int in keys:
		fields.append(k)
		fields.append(scars[k])
	return fields


## Mask R value for a water depth level.
static func mask_from_depth(level: int) -> int:
	return clampi(level, 0, MAX_WATER_DEPTH) * MASK_DEPTH_STEP


## Water depth level for a mask R value, rounded to the nearest level.
static func depth_from_mask(red: int) -> int:
	return mini((red + MASK_DEPTH_STEP / 2) / MASK_DEPTH_STEP, MAX_WATER_DEPTH)


func extent_x() -> int:
	return (size_x - 1) * cell_size


func extent_z() -> int:
	return (size_z - 1) * cell_size


## True if (x, z) lies on the map, edges included.
func contains(x: int, z: int) -> bool:
	return x >= 0 and z >= 0 and x <= extent_x() and z <= extent_z()


## Terrain height at (x, z), bilinear between the four surrounding samples,
## rounded to the nearest milli-unit (halves round up, negative heights
## included). Points off the map clamp to the edge.
func height_at(x: int, z: int) -> int:
	var cs: int = cell_size
	var cx: int = clampi(x, 0, extent_x())
	var cz: int = clampi(z, 0, extent_z())
	var i: int = mini(cx / cs, size_x - 2)
	var j: int = mini(cz / cs, size_z - 2)
	var fx: int = cx - i * cs
	var fz: int = cz - j * cs
	var k: int = j * size_x + i
	var weighted: int = (
		heights[k] * (cs - fx) * (cs - fz)
		+ heights[k + 1] * fx * (cs - fz)
		+ heights[k + size_x] * (cs - fx) * fz
		+ heights[k + size_x + 1] * fx * fz
	)
	var area: int = cs * cs
	return FixedMath.div_floor(weighted + area / 2, area)


## Uphill direction and steepness at (x, z): the exact derivative of the
## bilinear surface, (dh/dx, dh/dz) in permille. Uses the cell containing the
## point (cells are half-open, so a point on a cell edge uses the cell on its
## +x/+z side). Division truncates toward zero. Off the map, height_at is
## constant along any clamped axis, so that component is 0 there.
func gradient_at(x: int, z: int) -> Vector2i:
	var cs: int = cell_size
	var cx: int = clampi(x, 0, extent_x())
	var cz: int = clampi(z, 0, extent_z())
	var i: int = mini(cx / cs, size_x - 2)
	var j: int = mini(cz / cs, size_z - 2)
	var fx: int = cx - i * cs
	var fz: int = cz - j * cs
	var k: int = j * size_x + i
	var h00: int = heights[k]
	var h10: int = heights[k + 1]
	var h01: int = heights[k + size_x]
	var h11: int = heights[k + size_x + 1]
	var area: int = cs * cs
	var dx: int = 0
	var dz: int = 0
	if x == cx:
		dx = ((h10 - h00) * (cs - fz) + (h11 - h01) * fz) * PERMILLE / area
	if z == cz:
		dz = ((h01 - h00) * (cs - fx) + (h11 - h10) * fx) * PERMILLE / area
	return Vector2i(dx, dz)


## Steepness at (x, z) in permille: the magnitude of gradient_at().
func slope_at(x: int, z: int) -> int:
	var g: Vector2i = gradient_at(x, z)
	var gx: int = g.x
	var gz: int = g.y
	return FixedMath.isqrt(gx * gx + gz * gz)


## Water depth level 0..MAX_WATER_DEPTH at the nearest sample.
func water_depth_at(x: int, z: int) -> int:
	return water[_nearest_index(x, z)]


## Whether a unit with this mobility may stand at (x, z). Decided at the
## nearest sample; always false off the map.
func is_passable(x: int, z: int, mobility: Mobility) -> bool:
	if not contains(x, z):
		return false
	var k: int = _nearest_index(x, z)
	return is_sample_passable(k % size_x, k / size_x, mobility)


## Grid form of is_passable() for pathing.
func is_sample_passable(i: int, j: int, mobility: Mobility) -> bool:
	if i < 0 or j < 0 or i >= size_x or j >= size_z:
		return false
	var k: int = j * size_x + i
	if blocked[k] != 0:
		return false
	if mobility == Mobility.FLOATING:
		return true
	if sample_slopes[k] > max_walkable_slope:
		return false
	return mobility != Mobility.LIVING or water[k] < LIVING_IMPASSABLE_DEPTH


## Grid coordinates (i, j) of the sample nearest (x, z), clamped to the map.
## Every nearest-sample query (water, passability, pathing) uses this.
func nearest_sample(x: int, z: int) -> Vector2i:
	var k: int = _nearest_index(x, z)
	return Vector2i(k % size_x, k / size_x)


func sample_height(i: int, j: int) -> int:
	return heights[j * size_x + i]


func sample_water_depth(i: int, j: int) -> int:
	return water[j * size_x + i]


func sample_slope(i: int, j: int) -> int:
	return sample_slopes[j * size_x + i]


func _nearest_index(x: int, z: int) -> int:
	var half: int = cell_size / 2
	var i: int = (clampi(x, 0, extent_x()) + half) / cell_size
	var j: int = (clampi(z, 0, extent_z()) + half) / cell_size
	return j * size_x + i


func _compute_sample_slopes() -> PackedInt32Array:
	var slopes: PackedInt32Array = PackedInt32Array()
	slopes.resize(size_x * size_z)
	for j: int in size_z:
		var j0: int = maxi(j - 1, 0)
		var j1: int = mini(j + 1, size_z - 1)
		for i: int in size_x:
			var i0: int = maxi(i - 1, 0)
			var i1: int = mini(i + 1, size_x - 1)
			var k: int = j * size_x + i
			var h: int = heights[k]
			var rise_x: int = maxi(absi(heights[j * size_x + i1] - h), absi(h - heights[j * size_x + i0]))
			var rise_z: int = maxi(absi(heights[j1 * size_x + i] - h), absi(h - heights[j0 * size_x + i]))
			var gx: int = rise_x * PERMILLE / cell_size
			var gz: int = rise_z * PERMILLE / cell_size
			slopes[k] = FixedMath.isqrt(gx * gx + gz * gz)
	return slopes


static func _read_file(path: String) -> PackedByteArray:
	if not FileAccess.file_exists(path):
		push_error("Terrain: cannot read %s (file not found)" % path)
		return PackedByteArray()
	var bytes: PackedByteArray = FileAccess.get_file_as_bytes(path)
	if bytes.is_empty():
		push_error("Terrain: cannot read %s (%s)" % [path, error_string(FileAccess.get_open_error())])
	return bytes
