class_name TestTerrains
extends RefCounted
## Small synthetic terrains for sim tests. 1 m cells unless stated.

const CELL: int = 1000
const WALKABLE_SLOPE: int = 1000


## Flat ground at height 0 from an ASCII map, one character per sample, row 0
## at z = 0: '.' dry ground, '#' blocked, '1'..'4' water of that depth.
static func from_ascii(rows: Array[String]) -> Terrain:
	var size_z: int = rows.size()
	var size_x: int = rows[0].length()
	var heights: PackedInt32Array = PackedInt32Array()
	var water: PackedByteArray = PackedByteArray()
	var blocked: PackedByteArray = PackedByteArray()
	heights.resize(size_x * size_z)
	water.resize(size_x * size_z)
	blocked.resize(size_x * size_z)
	for j: int in size_z:
		assert(rows[j].length() == size_x, "row %d has the wrong width" % j)
		for i: int in size_x:
			var c: String = rows[j][i]
			var k: int = j * size_x + i
			if c == "#":
				blocked[k] = 1
			elif c >= "1" and c <= "4":
				water[k] = int(c)
	return Terrain.new(size_x, size_z, CELL, heights, water, blocked, WALKABLE_SLOPE)


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
