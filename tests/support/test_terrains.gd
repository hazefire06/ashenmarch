class_name TestTerrains
extends RefCounted
## Small synthetic terrains for sim tests. 1 m cells unless stated.

const CELL: int = 1000
const WALKABLE_SLOPE: int = 1000


## Dry ground types by ASCII letter; '.' and anything else is grass.
const GROUND_LETTERS: Dictionary[String, int] = {
	"b": Terrain.Ground.BRUSH,
	"w": Terrain.Ground.WOOD,
	"s": Terrain.Ground.SAND,
	"r": Terrain.Ground.ROCK,
}


## Flat ground at height 0 from an ASCII map, one character per sample, row 0
## at z = 0: '.' dry grass, 'b' brush, 'w' wood, 's' sand, 'r' rock, '#'
## blocked, '1'..'4' water of that depth.
static func from_ascii(rows: Array[String]) -> Terrain:
	if rows.is_empty():
		# Not assert(): under the debugger that hangs instead of failing the test.
		push_error("TestTerrains.from_ascii: no rows")
		return flat(2, 2)
	var size_z: int = rows.size()
	var size_x: int = rows[0].length()
	var heights: PackedInt32Array = PackedInt32Array()
	var water: PackedByteArray = PackedByteArray()
	var blocked: PackedByteArray = PackedByteArray()
	var ground: PackedByteArray = PackedByteArray()
	heights.resize(size_x * size_z)
	water.resize(size_x * size_z)
	blocked.resize(size_x * size_z)
	ground.resize(size_x * size_z)
	for j: int in size_z:
		if rows[j].length() != size_x:
			push_error("TestTerrains.from_ascii: row %d has the wrong width" % j)
		for i: int in size_x:
			# A short row reads as dry grass past its end, so nothing crashes.
			var c: String = rows[j][i] if i < rows[j].length() else "."
			var k: int = j * size_x + i
			if c == "#":
				blocked[k] = 1
			elif c >= "1" and c <= "4":
				water[k] = int(c)
			else:
				ground[k] = GROUND_LETTERS.get(c, Terrain.Ground.GRASS)
	return Terrain.new(
		size_x, size_z, CELL, heights, water, blocked, WALKABLE_SLOPE,
		PackedInt32Array(), PackedInt32Array(), ground
	)


## Flat, dry, open ground.
static func flat(size_x: int, size_z: int) -> Terrain:
	var row: String = ".".repeat(size_x)
	var rows: Array[String] = []
	for j: int in size_z:
		rows.append(row)
	return from_ascii(rows)


## Dry ground rising along +x at grade_permille (500 = 1 m up per 2 m).
static func ramp_x(size_x: int, size_z: int, grade_permille: int) -> Terrain:
	var heights: PackedInt32Array = PackedInt32Array()
	var water: PackedByteArray = PackedByteArray()
	var blocked: PackedByteArray = PackedByteArray()
	heights.resize(size_x * size_z)
	water.resize(size_x * size_z)
	blocked.resize(size_x * size_z)
	for j: int in size_z:
		for i: int in size_x:
			heights[j * size_x + i] = i * CELL * grade_permille / 1000
	return Terrain.new(size_x, size_z, CELL, heights, water, blocked, WALKABLE_SLOPE)


## The shipped Riverside map, loaded once per call.
static func riverside() -> Terrain:
	return Terrain.load_map(load("res://maps/riverside/riverside.tres") as MapInfo)


## The shipped unit catalog.
static func catalog() -> UnitCatalog:
	return load("res://data/units/catalog.tres") as UnitCatalog
