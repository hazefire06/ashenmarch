class_name StructurePlacer
extends RefCounted
## Fits kit pieces to a map's structures (pure, static). The sim's blocked
## samples win over the generator's nominal rectangle: a house fills the
## samples it covers, a wall runs along its polyline, and each is scaled to
## its height so a model's top is where the sim stops a projectile.
##
## A piece's native bounds are centred on its origin in x and z and start at
## y = 0 (KitPiece); every transform here puts that origin on the ground.

## The four axes a house may face, x and z.
const AXES: Array[Vector2i] = [Vector2i(0, 1), Vector2i(1, 0), Vector2i(0, -1), Vector2i(-1, 0)]
## House pieces whose shape fits within this much of the best (the log of
## their aspect ratio over the footprint's) are equally good, and the seed
## picks among them.
const SHAPE_TOLERANCE: float = 0.05
## Open stretches of wall shorter than this, metres, get no piece.
const MIN_SPAN_M: float = 0.001


## The structure's blocked samples' bounding box grown by half a cell on each
## side, metres, in x and z.
static func footprint_rect(record: StructureRecord, terrain: Terrain) -> Rect2:
	var lo: Vector2i = Vector2i(terrain.size_x, terrain.size_z)
	var hi: Vector2i = Vector2i(-1, -1)
	for k: int in record.samples:
		var at: Vector2i = Vector2i(k % terrain.size_x, k / terrain.size_x)
		lo = Vector2i(mini(lo.x, at.x), mini(lo.y, at.y))
		hi = Vector2i(maxi(hi.x, at.x), maxi(hi.y, at.y))
	var cell_m: float = _cell_m(terrain)
	return Rect2((Vector2(lo) - Vector2(0.5, 0.5)) * cell_m, Vector2(hi - lo + Vector2i.ONE) * cell_m)


## The axis the house's door faces: its record's, or one chosen by a seed from
## its position when the record has none, the same every time.
static func facing_of(record: StructureRecord) -> Vector2i:
	if record.facing != Vector2i.ZERO:
		return record.facing
	return AXES[posmod(hash(record.center_m), AXES.size())]


## The house piece whose shape, turned to face the door, best matches the
## footprint; among equally good ones, the seed from its position chooses.
## Null for no houses.
static func house_piece(record: StructureRecord, houses: Array[KitPiece], terrain: Terrain) -> KitPiece:
	if houses.is_empty():
		return null
	var rect: Rect2 = footprint_rect(record, terrain)
	var mismatch: PackedFloat32Array = PackedFloat32Array()
	for piece: KitPiece in houses:
		var extents: Vector2 = _native_extents(rect, _turn(piece.door, facing_of(record)))
		mismatch.append(absf(log((piece.size_m.x / piece.size_m.z) / (extents.x / extents.y))))
	var best: float = INF
	for m: float in mismatch:
		best = minf(best, m)
	var candidates: Array[KitPiece] = []
	for n: int in houses.size():
		if mismatch[n] <= best + SHAPE_TOLERANCE:
			candidates.append(houses[n])
	return candidates[posmod(hash(record.center_m), candidates.size())]


## The house's piece on its footprint: turned so its door faces the record's
## facing, scaled in x and z to fill footprint_rect and in y to stand from
## base_m to base_m + height_m.
static func house_transform(record: StructureRecord, piece: KitPiece, terrain: Terrain) -> Transform3D:
	var rect: Rect2 = footprint_rect(record, terrain)
	var turn: Basis = _turn(piece.door, facing_of(record))
	var extents: Vector2 = _native_extents(rect, turn)
	var scale: Vector3 = Vector3(extents.x, record.height_m, extents.y) / piece.size_m
	var centre: Vector2 = rect.get_center()
	return Transform3D(turn * Basis.from_scale(scale), Vector3(centre.x, record.base_m, centre.y))


## A wall's pieces: along each segment of its polyline, outside its gaps,
## ceil(length / piece width) of them stretched to divide each open stretch
## evenly, as thick as the wall, height_m tall, each standing on the ground
## under its centre.
static func wall_transforms(record: StructureRecord, piece: KitPiece, terrain: Terrain) -> Array[Transform3D]:
	var covered: Dictionary[int, bool] = _covered(record)
	var placed: Array[Transform3D] = []
	var start: float = 0.0
	for s: int in record.points_m.size() - 1:
		var a: Vector2 = record.points_m[s]
		var b: Vector2 = record.points_m[s + 1]
		var length: float = a.distance_to(b)
		if length <= 0.0:
			continue
		var direction: Vector2 = (b - a) / length
		for span: Vector2 in _open_spans(start, start + length, record.gaps_m):
			var count: int = ceili((span.y - span.x) / piece.size_m.x)
			var each: float = (span.y - span.x) / count
			for n: int in count:
				var centre: Vector2 = a + direction * (span.x + each * (n + 0.5) - start)
				placed.append(_run_transform(record, piece, terrain, covered, centre, direction, each))
		start += length
	return placed


## One gatehouse per gap, spanning it from the point on the polyline where the
## gap starts to where it ends, as thick and tall as the wall, on the open
## ground in the gap.
static func gate_transforms(record: StructureRecord, piece: KitPiece, terrain: Terrain) -> Array[Transform3D]:
	var covered: Dictionary[int, bool] = _covered(record)
	var placed: Array[Transform3D] = []
	for gap: Vector2 in record.gaps_m:
		var from: Vector2 = _point_along(record.points_m, gap.x)
		var to: Vector2 = _point_along(record.points_m, gap.y)
		var width: float = from.distance_to(to)
		if width < MIN_SPAN_M:
			continue
		placed.append(_run_transform(record, piece, terrain, covered, (from + to) / 2.0, (to - from) / width, width))
	return placed


static func _cell_m(terrain: Terrain) -> float:
	return terrain.cell_size / float(World.UNITS_PER_METER)


## The rotation about y, in exact quarter turns, that takes door to facing.
static func _turn(door: Vector2i, facing: Vector2i) -> Basis:
	var x: Vector2i = Vector2i(1, 0)
	var z: Vector2i = Vector2i(0, 1)
	var d: Vector2i = door
	for _quarter: int in AXES.size():
		if d == facing:
			break
		# A quarter turn about +y: (x, z) to (z, -x).
		d = Vector2i(d.y, -d.x)
		x = Vector2i(x.y, -x.x)
		z = Vector2i(z.y, -z.x)
	return Basis(Vector3(x.x, 0, x.y), Vector3.UP, Vector3(z.x, 0, z.y))


## The rectangle's extents along the world axes the piece's native x and z
## end up on after turn.
static func _native_extents(rect: Rect2, turn: Basis) -> Vector2:
	if absf(turn.x.x) > 0.5:
		return rect.size
	return Vector2(rect.size.y, rect.size.x)


static func _covered(record: StructureRecord) -> Dictionary[int, bool]:
	var covered: Dictionary[int, bool] = {}
	for k: int in record.samples:
		covered[k] = true
	return covered


## A piece along direction, length long, centred on centre, standing on the
## view's ground there: the nearest sample's height, less the wall's own where
## the wall raised it.
static func _run_transform(
	record: StructureRecord, piece: KitPiece, terrain: Terrain, covered: Dictionary[int, bool],
	centre: Vector2, direction: Vector2, length: float
) -> Transform3D:
	var mm: float = float(World.UNITS_PER_METER)
	var at: Vector2i = terrain.nearest_sample(roundi(centre.x * mm), roundi(centre.y * mm))
	var ground_mm: int = terrain.sample_height(at.x, at.y)
	if covered.has(at.y * terrain.size_x + at.x):
		ground_mm -= roundi(record.height_m * mm)
	var along: Vector3 = Vector3(direction.x, 0.0, direction.y)
	# Right-handed: x cross y is z.
	var across: Vector3 = along.cross(Vector3.UP)
	var basis: Basis = Basis(
		along * (length / piece.size_m.x),
		Vector3.UP * (record.height_m / piece.size_m.y),
		across * (record.thickness_m / piece.size_m.z)
	)
	return Transform3D(basis, Vector3(centre.x, ground_mm / mm, centre.y))


## The parts of [from, to], metres along the polyline, outside every gap.
static func _open_spans(from: float, to: float, gaps: PackedVector2Array) -> Array[Vector2]:
	var spans: Array[Vector2] = [Vector2(from, to)]
	for gap: Vector2 in gaps:
		var kept: Array[Vector2] = []
		for span: Vector2 in spans:
			if gap.y <= span.x or gap.x >= span.y:
				kept.append(span)
				continue
			if gap.x > span.x:
				kept.append(Vector2(span.x, gap.x))
			if gap.y < span.y:
				kept.append(Vector2(gap.y, span.y))
		spans = kept
	var open: Array[Vector2] = []
	for span: Vector2 in spans:
		if span.y - span.x >= MIN_SPAN_M:
			open.append(span)
	return open


## The point along metres along the polyline from its first point.
static func _point_along(points: PackedVector2Array, along: float) -> Vector2:
	var start: float = 0.0
	for s: int in points.size() - 1:
		var length: float = points[s].distance_to(points[s + 1])
		if length > 0.0 and along <= start + length:
			return points[s].lerp(points[s + 1], (along - start) / length)
		start += length
	return points[points.size() - 1]
