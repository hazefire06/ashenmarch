class_name TerrainPalette
extends RefCounted
## Placeholder ground colors, shared by the 3D terrain shader and the
## overhead map so both read the same. Heights are banded like a contour map;
## ground types tint the bands so firebreaks (sand, rock) can be read.

## Number of flat color bands between the lowest and highest terrain.
const BANDS: int = 14
## Colors at evenly spaced normalized heights, low to high.
const HEIGHT_STOPS: Array[Color] = [
	Color(0.23, 0.33, 0.17),
	Color(0.33, 0.45, 0.21),
	Color(0.47, 0.53, 0.27),
	Color(0.56, 0.51, 0.33),
	Color(0.52, 0.44, 0.34),
	Color(0.62, 0.60, 0.56),
]
## Index = water depth level. Level 0 is dry ground (alpha 0: no tint).
const WATER_COLORS: Array[Color] = [
	Color(0.0, 0.0, 0.0, 0.0),
	Color(0.42, 0.62, 0.66, 0.75),
	Color(0.27, 0.49, 0.62, 0.85),
	Color(0.14, 0.31, 0.52, 0.92),
	Color(0.07, 0.18, 0.38, 0.95),
]
## Index = Terrain.Ground. Alpha is the blend strength over the height bands;
## grass is the bands themselves.
const GROUND_TINTS: Array[Color] = [
	Color(0.0, 0.0, 0.0, 0.0),
	Color(0.38, 0.40, 0.17, 0.45),
	Color(0.12, 0.25, 0.11, 0.65),
	Color(0.80, 0.72, 0.50, 0.75),
	Color(0.48, 0.47, 0.45, 0.70),
]
## Width of the height ramp texture the shader samples.
const RAMP_WIDTH: int = 256


## Ground color for a height normalized to 0..1 over the map's range.
static func height_color(t: float) -> Color:
	var band: float = floorf(clampf(t, 0.0, 0.9999) * BANDS) / (BANDS - 1)
	var scaled: float = band * (HEIGHT_STOPS.size() - 1)
	var i: int = mini(int(scaled), HEIGHT_STOPS.size() - 2)
	return HEIGHT_STOPS[i].lerp(HEIGHT_STOPS[i + 1], scaled - i)


## Tint for a water depth level; alpha is the blend strength.
static func water_color(depth: int) -> Color:
	return WATER_COLORS[clampi(depth, 0, WATER_COLORS.size() - 1)]


## Tint for a ground type (Terrain.Ground); alpha is the blend strength.
static func ground_tint(ground: int) -> Color:
	return GROUND_TINTS[clampi(ground, 0, GROUND_TINTS.size() - 1)]


## Height color with the ground type's tint, then the water tint for this
## depth, blended on top: what the terrain shader draws, before light.
static func ground_color(t: float, depth: int, ground: int = Terrain.Ground.GRASS) -> Color:
	var kind: Color = ground_tint(ground)
	var dry: Color = height_color(t).lerp(Color(kind.r, kind.g, kind.b), kind.a)
	var tint: Color = water_color(depth)
	return dry.lerp(Color(tint.r, tint.g, tint.b), tint.a)


## RAMP_WIDTH x 1 RGB8 image of height_color() for the terrain shader.
static func height_ramp_image() -> Image:
	var data: PackedByteArray = PackedByteArray()
	data.resize(RAMP_WIDTH * 3)
	for x: int in RAMP_WIDTH:
		var c: Color = height_color((x + 0.5) / RAMP_WIDTH)
		data[x * 3] = c.r8
		data[x * 3 + 1] = c.g8
		data[x * 3 + 2] = c.b8
	return Image.create_from_data(RAMP_WIDTH, 1, false, Image.FORMAT_RGB8, data)
