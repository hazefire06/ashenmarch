extends GutTest
## StructurePlacer fits kit pieces to the committed maps' structures: every
## model edge within 0.5 m of its blocked samples, a house's top at the sim's
## height, its door toward its facing, a wall's pieces along its polyline but
## never across a gate.

const MAPS: Array[String] = [
	"res://maps/riverside/riverside.tres",
	"res://maps/the_ford/the_ford.tres",
	"res://maps/old_mill/old_mill.tres",
]
const FIT_M: float = 0.5


class Loaded:
	var terrain: Terrain
	var structures: MapStructures


func _load(path: String) -> Loaded:
	var info: MapInfo = load(path) as MapInfo
	var loaded: Loaded = Loaded.new()
	loaded.terrain = Terrain.load_map(info)
	loaded.structures = MapStructures.load_beside(info.heightmap_path)
	return loaded


static func _piece(size: Vector3, door: Vector2i = Vector2i(0, 1)) -> KitPiece:
	var piece: KitPiece = KitPiece.new()
	piece.size_m = size
	piece.door = door
	return piece


## The piece's native bounds (centred on its origin in x and z, from y = 0)
## where the transform puts them.
static func _placed(t: Transform3D, piece: KitPiece) -> AABB:
	var s: Vector3 = piece.size_m
	return t * AABB(Vector3(-s.x / 2.0, 0.0, -s.z / 2.0), s)


func _houses(loaded: Loaded) -> Array[StructureRecord]:
	var out: Array[StructureRecord] = []
	for record: StructureRecord in loaded.structures.records:
		if record.kind == &"house":
			out.append(record)
	return out


func test_every_house_fits_its_footprint_within_half_a_metre() -> void:
	var piece: KitPiece = _piece(Vector3(4, 3, 5))
	var checked: int = 0
	for path: String in MAPS:
		var loaded: Loaded = _load(path)
		for record: StructureRecord in _houses(loaded):
			var rect: Rect2 = StructurePlacer.footprint_rect(record, loaded.terrain)
			var box: AABB = _placed(StructurePlacer.house_transform(record, piece, loaded.terrain), piece)
			var at: String = "%s house at %s" % [path, record.center_m]
			assert_almost_eq(box.position.x, rect.position.x, FIT_M, at + " west")
			assert_almost_eq(box.end.x, rect.end.x, FIT_M, at + " east")
			assert_almost_eq(box.position.z, rect.position.y, FIT_M, at + " north")
			assert_almost_eq(box.end.z, rect.end.y, FIT_M, at + " south")
			checked += 1
	assert_eq(checked, 14, "8 + 5 + the mill")


func test_the_footprint_is_the_blocked_samples_grown_by_half_a_cell() -> void:
	var loaded: Loaded = _load(MAPS[0])
	var record: StructureRecord = _houses(loaded)[0]
	# Riverside's first house covers samples x 444..450, z 352..357.
	assert_eq(StructurePlacer.footprint_rect(record, loaded.terrain), Rect2(443.5, 351.5, 7, 6))


func test_a_house_top_is_its_sim_height() -> void:
	var piece: KitPiece = _piece(Vector3(4, 3, 5))
	for path: String in MAPS:
		var loaded: Loaded = _load(path)
		for record: StructureRecord in _houses(loaded):
			var box: AABB = _placed(StructurePlacer.house_transform(record, piece, loaded.terrain), piece)
			var at: String = "%s house at %s" % [path, record.center_m]
			assert_almost_eq(box.end.y, record.base_m + record.height_m, 0.01, at + " top")
			assert_almost_eq(box.position.y, record.base_m, 0.01, at + " base")
			# The record's top is the sim's: an arrow stopped by the slab stops at the roof.
			var top_mm: int = roundi((record.base_m + record.height_m) * 1000.0)
			for k: int in record.samples:
				assert_lte(absi(loaded.terrain.heights[k] - top_mm), 1, "%s sample %d" % [at, k])


func test_a_house_door_faces_its_facing() -> void:
	for door: Vector2i in [Vector2i(0, 1), Vector2i(1, 0), Vector2i(0, -1)]:
		var piece: KitPiece = _piece(Vector3(4, 3, 5), door)
		for path: String in MAPS:
			var loaded: Loaded = _load(path)
			for record: StructureRecord in _houses(loaded):
				var t: Transform3D = StructurePlacer.house_transform(record, piece, loaded.terrain)
				var turned: Vector3 = (t.basis * Vector3(door.x, 0, door.y)).normalized()
				assert_eq(Vector2i(roundi(turned.x), roundi(turned.z)), record.facing,
					"%s house at %s, door %s" % [path, record.center_m, door])


func test_a_house_with_no_facing_takes_a_stable_axis() -> void:
	var loaded: Loaded = _load(MAPS[0])
	var record: StructureRecord = _houses(loaded)[0].duplicate() as StructureRecord
	record.facing = Vector2i.ZERO
	var piece: KitPiece = _piece(Vector3(4, 3, 5))
	var t: Transform3D = StructurePlacer.house_transform(record, piece, loaded.terrain)
	var turned: Vector3 = (t.basis * Vector3(0, 0, 1)).normalized()
	var axis: Vector2i = Vector2i(roundi(turned.x), roundi(turned.z))
	assert_eq(absi(axis.x) + absi(axis.y), 1, "an axis")
	assert_eq(StructurePlacer.house_transform(record, piece, loaded.terrain), t, "the same every time")


func test_the_mill_is_ten_by_ten_and_six_tall() -> void:
	var loaded: Loaded = _load(MAPS[2])
	var mill: StructureRecord = null
	for record: StructureRecord in loaded.structures.records:
		if record.model == &"mill":
			mill = record
	var piece: KitPiece = _piece(Vector3(9, 5, 11))
	var box: AABB = _placed(StructurePlacer.house_transform(mill, piece, loaded.terrain), piece)
	assert_almost_eq(box.size.x, 10.0, 0.01)
	assert_almost_eq(box.size.z, 10.0, 0.01)
	assert_almost_eq(box.size.y, 6.0, 0.01)
	assert_almost_eq(box.end.y, 18.0, 0.01, "on the plateau, the sim's 18 m top")


func test_a_house_takes_the_piece_of_its_shape() -> void:
	var loaded: Loaded = _load(MAPS[0])
	# Doors on +z: wide has its door on a long side, deep on a short one.
	var square: KitPiece = _piece(Vector3(5, 3, 5))
	var wide: KitPiece = _piece(Vector3(6, 3, 4))
	var deep: KitPiece = _piece(Vector3(4, 3, 6))
	var houses: Array[KitPiece] = [square, wide, deep]
	for record: StructureRecord in _houses(loaded):
		var rect: Rect2 = StructurePlacer.footprint_rect(record, loaded.terrain)
		var across: float = rect.size.y if record.facing.x != 0 else rect.size.x
		var along: float = rect.size.x if record.facing.x != 0 else rect.size.y
		var wanted: KitPiece = wide if across > along else deep
		if maxf(across, along) / minf(across, along) < 1.25:
			wanted = square
		assert_eq(StructurePlacer.house_piece(record, houses, loaded.terrain), wanted,
			"house at %s, %s facing %s" % [record.center_m, rect.size, record.facing])
	assert_null(StructurePlacer.house_piece(_houses(loaded)[0], [] as Array[KitPiece], loaded.terrain))


## Metres along the polyline to the point there.
static func _point_at(points: PackedVector2Array, along: float) -> Vector2:
	var start: float = 0.0
	for s: int in points.size() - 1:
		var length: float = points[s].distance_to(points[s + 1])
		if along <= start + length:
			return points[s].lerp(points[s + 1], (along - start) / length)
		start += length
	return points[points.size() - 1]


## Whether p lies in the piece's footprint (its x/z rectangle) grown by grow.
static func _in_piece(p: Vector2, t: Transform3D, piece: KitPiece, grow: float) -> bool:
	var along: Vector3 = t.basis.x
	var across: Vector3 = t.basis.z
	var d: Vector2 = p - Vector2(t.origin.x, t.origin.z)
	var a2: Vector2 = Vector2(along.x, along.z)
	var c2: Vector2 = Vector2(across.x, across.z)
	var half_len: float = a2.length() * piece.size_m.x / 2.0
	var half_thick: float = c2.length() * piece.size_m.z / 2.0
	return absf(d.dot(a2.normalized())) <= half_len + grow and absf(d.dot(c2.normalized())) <= half_thick + grow


func test_the_fords_palisade_is_covered_and_fits() -> void:
	var loaded: Loaded = _load(MAPS[1])
	var wall: StructureRecord = null
	for record: StructureRecord in loaded.structures.records:
		if record.kind == &"wall":
			wall = record
	var terrain: Terrain = loaded.terrain
	var piece: KitPiece = _piece(Vector3(2.5, 2, 0.6))
	var placed: Array[Transform3D] = StructurePlacer.wall_transforms(wall, piece, terrain)
	assert_gt(placed.size(), 50)
	var cell_m: float = terrain.cell_size / 1000.0
	var sample_at: Callable = func(k: int) -> Vector2:
		return Vector2(k % terrain.size_x, k / terrain.size_x) * cell_m
	for k: int in wall.samples:
		var p: Vector2 = sample_at.call(k)
		var covered: bool = false
		for t: Transform3D in placed:
			if _in_piece(p, t, piece, FIT_M):
				covered = true
				break
		assert_true(covered, "wall sample %s is under a piece" % p)
	var reach: float = wall.thickness_m / 2.0 + FIT_M
	for t: Transform3D in placed:
		var centre: Vector2 = Vector2(t.origin.x, t.origin.z)
		var nearest: float = INF
		for k: int in wall.samples:
			nearest = minf(nearest, centre.distance_to(sample_at.call(k)))
		assert_lte(nearest, reach, "piece at %s stands on the wall" % centre)
		# On the ground under the wall: the sim's raised height less the wall's.
		var at: Vector2i = terrain.nearest_sample(roundi(centre.x * 1000.0), roundi(centre.y * 1000.0))
		var ground: float = (terrain.sample_height(at.x, at.y) - 3000) / 1000.0
		assert_almost_eq(t.origin.y, ground, 0.001, "piece at %s base" % centre)
		assert_almost_eq((t.basis.y * piece.size_m.y).length(), wall.height_m, 0.001, "piece at %s height" % centre)
	var gap: Vector2 = wall.gaps_m[0]
	var along: float = gap.x + 0.05
	while along < gap.y - 0.05:
		var p: Vector2 = _point_at(wall.points_m, along)
		for t: Transform3D in placed:
			assert_false(_in_piece(p, t, piece, -0.01), "a piece at %s spans the gate (%.2f m along)" % [Vector2(t.origin.x, t.origin.z), along])
		along += 0.25


func test_each_gap_gets_one_gate_spanning_it() -> void:
	var loaded: Loaded = _load(MAPS[1])
	var wall: StructureRecord = null
	for record: StructureRecord in loaded.structures.records:
		if record.kind == &"wall":
			wall = record
	var piece: KitPiece = _piece(Vector3(5, 4, 1))
	var gates: Array[Transform3D] = StructurePlacer.gate_transforms(wall, piece, loaded.terrain)
	assert_eq(gates.size(), 1)
	var gap: Vector2 = wall.gaps_m[0]
	var from: Vector2 = _point_at(wall.points_m, gap.x)
	var to: Vector2 = _point_at(wall.points_m, gap.y)
	var t: Transform3D = gates[0]
	assert_almost_eq(Vector2(t.origin.x, t.origin.z).distance_to((from + to) / 2.0), 0.0, 0.001, "centred in the gap")
	assert_almost_eq((t.basis.x * piece.size_m.x).length(), from.distance_to(to), 0.001, "as wide as the gap")
	assert_almost_eq((t.basis.y * piece.size_m.y).length(), wall.height_m, 0.001, "as tall as the wall")
	var at: Vector2i = loaded.terrain.nearest_sample(roundi(t.origin.x * 1000.0), roundi(t.origin.z * 1000.0))
	assert_almost_eq(t.origin.y, loaded.terrain.sample_height(at.x, at.y) / 1000.0, 0.001, "on the open ground of the gap")
