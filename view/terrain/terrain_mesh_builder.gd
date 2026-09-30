class_name TerrainMeshBuilder
extends RefCounted
## Builds render meshes for a Terrain, one per chunk of CHUNK_CELLS x
## CHUNK_CELLS cells, so the camera frustum culls whole chunks. Vertices sit
## exactly on the sim's sample heights, in world meters. The last chunk in
## each direction may be smaller when the cell count isn't a multiple of
## CHUNK_CELLS.
##
## Each cell splits into two triangles along its (i, j)-(i+1, j+1) diagonal.
## The sim's height_at is bilinear, so inside a cell it can differ from these
## flat triangles by up to |h00 - h10 - h01 + h11| / 4 (docs/architecture.md).

const CHUNK_CELLS: int = 64


## Number of chunks along x and z.
static func chunk_counts(terrain: Terrain) -> Vector2i:
	return Vector2i(
		ceili(float(terrain.size_x - 1) / CHUNK_CELLS),
		ceili(float(terrain.size_z - 1) / CHUNK_CELLS)
	)


## Cells covered by chunk (chunk_x, chunk_z) along x and z.
static func chunk_cells(terrain: Terrain, chunk_x: int, chunk_z: int) -> Vector2i:
	return Vector2i(
		mini(CHUNK_CELLS, terrain.size_x - 1 - chunk_x * CHUNK_CELLS),
		mini(CHUNK_CELLS, terrain.size_z - 1 - chunk_z * CHUNK_CELLS)
	)


## Triangle indices for a grid of cells_x by cells_z cells, clockwise (front
## face) seen from above. Full-size chunks all share one of these.
static func grid_indices(cells_x: int, cells_z: int) -> PackedInt32Array:
	var row: int = cells_x + 1
	var indices: PackedInt32Array = PackedInt32Array()
	indices.resize(cells_x * cells_z * 6)
	var n: int = 0
	for cz: int in cells_z:
		for cx: int in cells_x:
			var v00: int = cz * row + cx
			var v10: int = v00 + 1
			var v01: int = v00 + row
			var v11: int = v01 + 1
			indices[n] = v00
			indices[n + 1] = v10
			indices[n + 2] = v11
			indices[n + 3] = v00
			indices[n + 4] = v11
			indices[n + 5] = v01
			n += 6
	return indices


## Mesh for one chunk. Pass grid_indices() for the chunk's size to reuse an
## index array across chunks; an empty array builds one.
static func build_chunk(
	terrain: Terrain,
	chunk_x: int,
	chunk_z: int,
	indices: PackedInt32Array = PackedInt32Array()
) -> ArrayMesh:
	var cells: Vector2i = chunk_cells(terrain, chunk_x, chunk_z)
	var i0: int = chunk_x * CHUNK_CELLS
	var j0: int = chunk_z * CHUNK_CELLS
	var meters_per_cell: float = float(terrain.cell_size) / World.UNITS_PER_METER
	var vertices: PackedVector3Array = PackedVector3Array()
	vertices.resize((cells.x + 1) * (cells.y + 1))
	var n: int = 0
	for j: int in range(j0, j0 + cells.y + 1):
		var row_start: int = j * terrain.size_x
		for i: int in range(i0, i0 + cells.x + 1):
			vertices[n] = Vector3(
				i * meters_per_cell,
				terrain.heights[row_start + i] / float(World.UNITS_PER_METER),
				j * meters_per_cell
			)
			n += 1

	var arrays: Array = []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = vertices
	arrays[Mesh.ARRAY_INDEX] = indices if not indices.is_empty() else grid_indices(cells.x, cells.y)
	var mesh: ArrayMesh = ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	return mesh
