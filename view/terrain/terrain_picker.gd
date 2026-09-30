class_name TerrainPicker
extends RefCounted
## Finds where a ray (the mouse ray, in float meters) meets the ground, using
## the sim's own height_at, so a click lands exactly where the sim says the
## ground is. There are no physics colliders to raycast against: Godot physics
## is reserved for cosmetic debris.
##
## The ray is marched in fixed steps from where it first drops below the
## highest point of the map, then bisected. A ridge thinner than STEP could be
## skipped at a grazing angle, which only matters for picking.

const STEP: float = 0.5
const BISECTIONS: int = 16
const MAX_DISTANCE: float = 3000.0

var _terrain: Terrain
var _top: float
var _bottom: float
var _extent_x: float
var _extent_z: float


func _init(terrain: Terrain) -> void:
	_terrain = terrain
	var highest: int = terrain.heights[0]
	var lowest: int = terrain.heights[0]
	for h: int in terrain.heights:
		highest = maxi(highest, h)
		lowest = mini(lowest, h)
	_top = highest / float(World.UNITS_PER_METER)
	_bottom = lowest / float(World.UNITS_PER_METER)
	_extent_x = terrain.extent_x() / float(World.UNITS_PER_METER)
	_extent_z = terrain.extent_z() / float(World.UNITS_PER_METER)


## The ground point hit by the ray from origin along direction, or
## Vector3.INF if it misses the map.
func pick(origin: Vector3, direction: Vector3) -> Vector3:
	var dir: Vector3 = direction.normalized()
	var t: float = 0.0
	if origin.y > _top:
		if dir.y >= 0.0:
			return Vector3.INF
		t = (origin.y - _top) / -dir.y
	var previous: float = t
	while t <= MAX_DISTANCE:
		var p: Vector3 = origin + dir * t
		if _on_map(p) and p.y <= ground_height(p.x, p.z):
			return _refine(origin, dir, previous, t)
		if (dir.y >= 0.0 and p.y > _top) or p.y < _bottom:
			# Rising above everything, or already below the lowest ground
			# without hitting it (off the edge of the map).
			return Vector3.INF
		previous = t
		t += STEP
	return Vector3.INF


## Ground height in meters at (x, z) meters.
func ground_height(x: float, z: float) -> float:
	var h: int = _terrain.height_at(roundi(x * World.UNITS_PER_METER), roundi(z * World.UNITS_PER_METER))
	return h / float(World.UNITS_PER_METER)


func _refine(origin: Vector3, dir: Vector3, above: float, below: float) -> Vector3:
	var lo: float = above
	var hi: float = below
	for i: int in BISECTIONS:
		var mid: float = (lo + hi) * 0.5
		var p: Vector3 = origin + dir * mid
		if p.y <= ground_height(p.x, p.z):
			hi = mid
		else:
			lo = mid
	var hit: Vector3 = origin + dir * hi
	return Vector3(hit.x, ground_height(hit.x, hit.z), hit.z)


func _on_map(p: Vector3) -> bool:
	return p.x >= 0.0 and p.z >= 0.0 and p.x <= _extent_x and p.z <= _extent_z
