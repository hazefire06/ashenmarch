class_name TrailMask
extends RefCounted
## A map's worn trails (MapTrails) baked into a mask (A5, view only): an RG8
## image, TEXEL_M a texel, over just the area the trails cover. R is the wear,
## 1 on the worn ground and 0 on grass, soft and irregular at the edges and
## fading out at a route's ends. G is the wheel ruts of a road at least
## RUT_MIN_WIDTH_M wide. Trails that meet wear where either does.
##
## The terrain shader draws the wear as dirt (texture(), origin_m(), size_m());
## the ground scatter keeps off it (wear_at()). Both read it the same way, the
## GPU's linear filter between texel centres. Pure functions of the trails:
## the same trails bake the same mask, with its own fixed-seed noise.

## Metres per texel.
const TEXEL_M: float = 0.5
## Clear texels round the baked area. The texture clamps to its edge, so the
## outermost texels must be clear.
const MARGIN_TEXELS: int = 2
## The worn core reaches CORE_SHARE of the half-width; from there the wear
## falls to none EDGE_SOFT_M past the half-width.
const CORE_SHARE: float = 0.45
const EDGE_SOFT_M: float = 0.45
## How far the edge wanders in and out (metres at full noise, less toward the
## centre line), and the noise's period: grass breaking into the dirt, not a
## ruled line.
const EDGE_WANDER_M: float = 0.55
const EDGE_NOISE_M: float = 3.0
## A route's wear fades in over this many metres from each end (or half its
## length, if shorter).
const FADE_M: float = 5.0
## Roads this wide or wider get two ruts, each RUT_HALF_M across its middle
## and soft for RUT_SOFT_M more.
const RUT_MIN_WIDTH_M: float = 3.0
const RUT_HALF_M: float = 0.15
const RUT_SOFT_M: float = 0.35
const NOISE_SEED: int = 7177

var _image: Image
## The image's bytes (RG8, row-major), read by _sample.
var _data: PackedByteArray = PackedByteArray()
var _origin_m: Vector2 = Vector2.ZERO
var _empty: bool = true
var _texture: ImageTexture


## The mask of trails (null or empty bakes an empty one) on a map extent_m
## across: the trails' area, clipped to the map, plus MARGIN_TEXELS.
static func bake(trails: MapTrails, extent_m: Vector2) -> TrailMask:
	var mask: TrailMask = TrailMask.new()
	if trails == null or trails.records.is_empty():
		mask._image = Image.create(1, 1, false, Image.FORMAT_RG8)
		return mask
	var lo: Vector2 = Vector2(INF, INF)
	var hi: Vector2 = Vector2(-INF, -INF)
	for record: TrailRecord in trails.records:
		var reach: Vector2 = Vector2.ONE * _reach(record)
		for p: Vector2 in record.points_m:
			lo = lo.min(p - reach)
			hi = hi.max(p + reach)
	lo = lo.max(Vector2.ZERO)
	hi = hi.min(extent_m)
	if lo.x >= hi.x or lo.y >= hi.y:
		mask._image = Image.create(1, 1, false, Image.FORMAT_RG8)
		return mask
	var first: Vector2i = Vector2i(floori(lo.x / TEXEL_M), floori(lo.y / TEXEL_M)) - Vector2i.ONE * MARGIN_TEXELS
	var last: Vector2i = Vector2i(ceili(hi.x / TEXEL_M), ceili(hi.y / TEXEL_M)) + Vector2i.ONE * MARGIN_TEXELS
	var size: Vector2i = last - first
	mask._origin_m = Vector2(first) * TEXEL_M
	var wear: PackedFloat32Array = PackedFloat32Array()
	var ruts: PackedFloat32Array = PackedFloat32Array()
	wear.resize(size.x * size.y)
	ruts.resize(size.x * size.y)
	var noise: FastNoiseLite = FastNoiseLite.new()
	noise.seed = NOISE_SEED
	noise.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	noise.frequency = 1.0 / EDGE_NOISE_M
	noise.fractal_octaves = 2
	for record: TrailRecord in trails.records:
		_stamp(mask, record, size, wear, ruts, noise)
	var data: PackedByteArray = PackedByteArray()
	data.resize(size.x * size.y * 2)
	for k: int in wear.size():
		data[k * 2] = clampi(roundi(wear[k] * 255.0), 0, 255)
		data[k * 2 + 1] = clampi(roundi(ruts[k] * 255.0), 0, 255)
	mask._image = Image.create_from_data(size.x, size.y, false, Image.FORMAT_RG8, data)
	mask._data = data
	mask._empty = false
	return mask


## Whether no trail is baked.
func is_empty() -> bool:
	return _empty


## The wear at (x_m, z_m), 0..1, as the shader reads it.
func wear_at(x_m: float, z_m: float) -> float:
	return _sample(x_m, z_m, 0)


## The ruts at (x_m, z_m), 0..1, as the shader reads it.
func rut_at(x_m: float, z_m: float) -> float:
	return _sample(x_m, z_m, 1)


## The baked image, for tests.
func image() -> Image:
	return _image


## World x, z of the baked area's corner, metres.
func origin_m() -> Vector2:
	return _origin_m


## The baked area's size, metres: the shader's uv is (p - origin_m) / size_m.
func size_m() -> Vector2:
	return Vector2(_image.get_width(), _image.get_height()) * TEXEL_M


## The mask as a texture (made once).
func texture() -> ImageTexture:
	if _texture == null:
		_texture = ImageTexture.create_from_image(_image)
	return _texture


## Metres from a road's centre line to the middle of each rut.
static func rut_offset_m(width_m: float) -> float:
	return minf(0.85, width_m * 0.24)


# How far a trail's wear can reach from its centre line.
static func _reach(record: TrailRecord) -> float:
	return record.width_m / 2.0 + EDGE_SOFT_M + EDGE_WANDER_M + TEXEL_M


# Wears one trail into wear and ruts (row-major over size), keeping the most
# of what is there and what this trail gives.
static func _stamp(
	mask: TrailMask, record: TrailRecord, size: Vector2i, wear: PackedFloat32Array, ruts: PackedFloat32Array,
	noise: FastNoiseLite
) -> void:
	var points: PackedVector2Array = record.points_m
	if points.size() == 1:
		points = PackedVector2Array([points[0], points[0]])
	var length: float = 0.0
	for s: int in points.size() - 1:
		length += points[s].distance_to(points[s + 1])
	var fade: float = minf(FADE_M, length / 2.0)
	var half: float = record.width_m / 2.0
	var reach: float = _reach(record)
	var has_ruts: bool = record.width_m >= RUT_MIN_WIDTH_M
	var rut_offset: float = rut_offset_m(record.width_m)
	var start: float = 0.0
	for s: int in points.size() - 1:
		var a: Vector2 = points[s]
		var b: Vector2 = points[s + 1]
		var seg: float = a.distance_to(b)
		var first: Vector2i = Vector2i(((a.min(b) - Vector2.ONE * reach) - mask._origin_m) / TEXEL_M)
		var last: Vector2i = Vector2i((((a.max(b) + Vector2.ONE * reach) - mask._origin_m) / TEXEL_M).ceil())
		for j: int in range(maxi(first.y, 0), mini(last.y, size.y - 1) + 1):
			for i: int in range(maxi(first.x, 0), mini(last.x, size.x - 1) + 1):
				var p: Vector2 = mask._origin_m + (Vector2(i, j) + Vector2(0.5, 0.5)) * TEXEL_M
				var on: Vector2 = Geometry2D.get_closest_point_to_segment(p, a, b)
				var d: float = p.distance_to(on)
				if d > reach:
					continue
				# The edge wanders; the worn middle stays worn.
				var edge: float = d + noise.get_noise_2d(p.x, p.y) * EDGE_WANDER_M * smoothstep(0.0, half, d)
				var w: float = 1.0 - smoothstep(half * CORE_SHARE, half + EDGE_SOFT_M, edge)
				if record.fade_ends and fade > 0.0:
					var along: float = start + a.distance_to(on)
					w *= smoothstep(0.0, fade, minf(along, length - along))
				elif record.fade_ends:
					w = 0.0
				if w <= 0.0:
					continue
				var k: int = j * size.x + i
				wear[k] = maxf(wear[k], w)
				if has_ruts:
					var r: float = 1.0 - smoothstep(RUT_HALF_M, RUT_HALF_M + RUT_SOFT_M, absf(d - rut_offset))
					ruts[k] = maxf(ruts[k], r * w)
		start += seg


# Bilinear between texel centres, clamped to the edge: the GPU's linear
# filter with repeat disabled. Outside the baked area (all clear) it is 0.
func _sample(x_m: float, z_m: float, channel: int) -> float:
	if _empty:
		return 0.0
	var w: int = _image.get_width()
	var h: int = _image.get_height()
	var fx: float = (x_m - _origin_m.x) / TEXEL_M - 0.5
	var fz: float = (z_m - _origin_m.y) / TEXEL_M - 0.5
	if fx < 0.0 or fz < 0.0 or fx > w - 1 or fz > h - 1:
		return 0.0
	var i0: int = floori(fx)
	var j0: int = floori(fz)
	var u: float = fx - i0
	var v: float = fz - j0
	var i1: int = mini(i0 + 1, w - 1)
	var j1: int = mini(j0 + 1, h - 1)
	var c00: int = _data[(j0 * w + i0) * 2 + channel]
	var c10: int = _data[(j0 * w + i1) * 2 + channel]
	var c01: int = _data[(j1 * w + i0) * 2 + channel]
	var c11: int = _data[(j1 * w + i1) * 2 + channel]
	return lerpf(lerpf(c00, c10, u), lerpf(c01, c11, u), v) / 255.0
