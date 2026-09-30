class_name CraterMesh
extends RefCounted
## Builds the dark disc the view lays over a crater or a scorch mark: a fan of
## RINGS rings of SEGMENTS vertices around a center vertex, every vertex
## standing on the terrain's current height (craters included, so build it
## after the scar) plus a small lift so it doesn't z-fight the ground. A
## terrain-conforming mesh rather than a Decal, because the Compatibility
## renderer can't draw Decals.
##
## Vertex color is white with an alpha that is 1 at the center and 0 at the
## rim, so the edge fades into the ground. Tint it, and cap how opaque it is,
## with the material's albedo color (vertex_color_use_as_albedo). Vertices are
## in world meters.

const RINGS: int = 4
const SEGMENTS: int = 16
## Meters above the ground the disc floats by default.
const DEFAULT_LIFT: float = 0.03


## A disc of radius (milli-units) centered on (x, z) in milli-units. An empty
## mesh for a radius that isn't positive.
static func build(
	terrain: Terrain, x: int, z: int, radius: int, lift: float = DEFAULT_LIFT
) -> ArrayMesh:
	var mesh: ArrayMesh = ArrayMesh.new()
	if radius <= 0:
		return mesh
	var vertices: PackedVector3Array = PackedVector3Array()
	var colors: PackedColorArray = PackedColorArray()
	vertices.resize(1 + RINGS * SEGMENTS)
	colors.resize(vertices.size())
	vertices[0] = _vertex(terrain, x, z, lift)
	colors[0] = _color(0)
	for ring: int in range(1, RINGS + 1):
		var reach: float = float(radius) * ring / RINGS
		for segment: int in SEGMENTS:
			var angle: float = TAU * segment / SEGMENTS
			var n: int = _index(ring, segment)
			# Whole milli-units, so the vertex's height is exactly height_at's.
			vertices[n] = _vertex(
				terrain, x + roundi(cos(angle) * reach), z + roundi(sin(angle) * reach), lift
			)
			colors[n] = _color(ring)

	var arrays: Array = []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = vertices
	arrays[Mesh.ARRAY_COLOR] = colors
	arrays[Mesh.ARRAY_INDEX] = _indices()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	return mesh


# Vertex for ring (0 is the center) and segment.
static func _index(ring: int, segment: int) -> int:
	return 0 if ring == 0 else 1 + (ring - 1) * SEGMENTS + segment % SEGMENTS


static func _vertex(terrain: Terrain, x: int, z: int, lift: float) -> Vector3:
	var mm: float = float(World.UNITS_PER_METER)
	return Vector3(x / mm, terrain.height_at(x, z) / mm + lift, z / mm)


# White, opaque at the center and fading to clear at the outermost ring.
static func _color(ring: int) -> Color:
	return Color(1.0, 1.0, 1.0, 1.0 - float(ring) / RINGS)


# Clockwise (front face) seen from above, like the terrain mesh: a fan from
# the center to ring 1, then two triangles per segment of each ring band.
static func _indices() -> PackedInt32Array:
	var indices: PackedInt32Array = PackedInt32Array()
	for segment: int in SEGMENTS:
		indices.append_array(PackedInt32Array([
			0, _index(1, segment), _index(1, segment + 1)
		]))
	for ring: int in range(1, RINGS):
		for segment: int in SEGMENTS:
			var inner: int = _index(ring, segment)
			var inner_next: int = _index(ring, segment + 1)
			var outer: int = _index(ring + 1, segment)
			var outer_next: int = _index(ring + 1, segment + 1)
			indices.append_array(PackedInt32Array([
				inner, outer, outer_next, inner, outer_next, inner_next
			]))
	return indices
