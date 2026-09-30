class_name UnitGrid
extends RefCounted
## Spatial hash of the living units at one moment, for "who is near here"
## queries. Built fresh each tick from start-of-tick positions; it does not
## follow units that move afterwards.
##
## Query results come in a fixed order (bucket rows by z, then x, then the
## units' order in the source array), so any code that walks them in order
## does the same thing on every peer.

## Bucket edge in milli-units.
var bucket_size: int

var _units: Array[Unit]
var _buckets: Dictionary[int, Array] = {}


func _init(units: Array[Unit], edge: int) -> void:
	_units = units
	bucket_size = edge
	for index: int in units.size():
		var unit: Unit = units[index]
		if not unit.is_alive():
			continue
		var key: int = _key(
			FixedMath.div_floor(unit.x, bucket_size), FixedMath.div_floor(unit.z, bucket_size)
		)
		if not _buckets.has(key):
			_buckets[key] = []
		_buckets[key].append(index)


## Living units in every bucket that a circle of the given radius around
## (x, z) touches, except `exclude`. A superset of the units within radius:
## callers check the actual distance.
func near(x: int, z: int, radius: int, exclude: Unit = null) -> Array[Unit]:
	var out: Array[Unit] = []
	var i0: int = FixedMath.div_floor(x - radius, bucket_size)
	var i1: int = FixedMath.div_floor(x + radius, bucket_size)
	var j0: int = FixedMath.div_floor(z - radius, bucket_size)
	var j1: int = FixedMath.div_floor(z + radius, bucket_size)
	for j: int in range(j0, j1 + 1):
		for i: int in range(i0, i1 + 1):
			var key: int = _key(i, j)
			if not _buckets.has(key):
				continue
			for index: int in _buckets[key]:
				var other: Unit = _units[index]
				if other != exclude:
					out.append(other)
	return out


static func _key(bi: int, bj: int) -> int:
	return bi * 65536 + bj
