class_name MapImage
extends RefCounted
## The heightmap as a flat picture, shared by the Tab map (OverheadMap) and
## the corner map (Minimap): a banded height color, ground and water tints,
## and a hillshade, built once per map load. Also the north-up placement both
## maps use: map +x is screen right and map +z is screen down, so z = 0 is the
## top edge. Texel (i, j) is sample (i, j), so texel centers sit on the sample
## points and the image spans half a cell beyond the map on every side.

## Hillshade light: from the north-west (-x, -z) and 45 degrees above.
const LIGHT_DIRECTION: Vector3 = Vector3(-0.5, 0.70710678, -0.5)
## Lambert 0..1 maps to this shade range; a flat surface lands near 1.0.
const SHADE_DARK: float = 0.65
const SHADE_LIGHT: float = 1.15


## The largest rectangle with the terrain's sample aspect ratio that fits in a
## box of `box_side` square, centered in `area`.
static func fit_rect(area: Vector2, box_side: float, terrain: Terrain) -> Rect2:
	var texel: float = minf(box_side / terrain.size_x, box_side / terrain.size_z)
	var rect_size: Vector2 = Vector2(terrain.size_x, terrain.size_z) * texel
	return Rect2((area - rect_size) * 0.5, rect_size)


## A map point (x, z in meters) in `rect`, the rectangle the image is drawn in.
static func map_to_rect(map_xz: Vector2, rect: Rect2, terrain: Terrain) -> Vector2:
	var cell: float = terrain.cell_size / float(World.UNITS_PER_METER)
	var uv: Vector2 = map_xz / cell + Vector2(0.5, 0.5)
	return rect.position + uv / Vector2(terrain.size_x, terrain.size_z) * rect.size


## The inverse of map_to_rect.
static func rect_to_map(point: Vector2, rect: Rect2, terrain: Terrain) -> Vector2:
	var cell: float = terrain.cell_size / float(World.UNITS_PER_METER)
	var uv: Vector2 = (point - rect.position) / rect.size
	return (uv * Vector2(terrain.size_x, terrain.size_z) - Vector2(0.5, 0.5)) * cell


## Builds an RGB8 image with texel (i, j) = sample (i, j): banded height color,
## ground tint, water tint, and a hillshade from the neighboring heights. The
## colors depend only on the height band, ground type, and water depth, so
## they are looked up from a small table built through TerrainPalette instead
## of called per texel.
static func build(terrain: Terrain) -> Image:
	var width: int = terrain.size_x
	var height: int = terrain.size_z
	var heights: PackedInt32Array = terrain.heights
	var water: PackedByteArray = terrain.water
	var ground: PackedByteArray = terrain.ground
	var min_h: int = heights[0]
	var max_h: int = heights[0]
	for k: int in heights.size():
		min_h = mini(min_h, heights[k])
		max_h = maxi(max_h, heights[k])
	var h_range: int = maxi(max_h - min_h, 1)

	var palette: Array[Color] = []
	for depth: int in Terrain.MAX_WATER_DEPTH + 1:
		for kind: int in Terrain.GROUND_COUNT:
			for band: int in TerrainPalette.BANDS:
				palette.append(TerrainPalette.ground_color((band + 0.5) / TerrainPalette.BANDS, depth, kind))

	# Heights and cell_size are both milli-units, so the ratio is the same
	# dimensionless slope as rise over run in meters.
	var cell: int = terrain.cell_size
	var light: Vector3 = LIGHT_DIRECTION.normalized()
	var data: PackedByteArray = PackedByteArray()
	data.resize(width * height * 3)
	for j: int in height:
		var j0: int = maxi(j - 1, 0)
		var j1: int = mini(j + 1, height - 1)
		for i: int in width:
			var i0: int = maxi(i - 1, 0)
			var i1: int = mini(i + 1, width - 1)
			var k: int = j * width + i
			var dhdx: float = float(heights[j * width + i1] - heights[j * width + i0]) / ((i1 - i0) * cell)
			var dhdz: float = float(heights[j1 * width + i] - heights[j0 * width + i]) / ((j1 - j0) * cell)
			var lambert: float = maxf(Vector3(-dhdx, 1.0, -dhdz).normalized().dot(light), 0.0)
			var shade: float = lerpf(SHADE_DARK, SHADE_LIGHT, lambert)
			var t: float = clampf(float(heights[k] - min_h) / h_range, 0.0, 0.9999)
			var band: int = int(t * TerrainPalette.BANDS)
			var depth: int = mini(water[k], Terrain.MAX_WATER_DEPTH)
			var color: Color = palette[(depth * Terrain.GROUND_COUNT + ground[k]) * TerrainPalette.BANDS + band]
			var o: int = k * 3
			data[o] = clampi(int(color.r * shade * 255.0 + 0.5), 0, 255)
			data[o + 1] = clampi(int(color.g * shade * 255.0 + 0.5), 0, 255)
			data[o + 2] = clampi(int(color.b * shade * 255.0 + 0.5), 0, 255)
	return Image.create_from_data(width, height, false, Image.FORMAT_RGB8, data)
