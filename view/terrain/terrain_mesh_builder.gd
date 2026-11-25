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


## Mesh for one chunk, with smooth per-vertex normals. Pass grid_indices() for
## the chunk's size to reuse an index array across chunks; an empty array
## builds one. view_heights maps a sample index to a height in milli-units
## that replaces the sim's, so the view can draw the ground under a structure
## (MapStructures.view_heights); empty draws the sim's heights.
static func build_chunk(
	terrain: Terrain,
	chunk_x: int,
	chunk_z: int,
	indices: PackedInt32Array = PackedInt32Array(),
	view_heights: Dictionary[int, int] = {}
) -> ArrayMesh:
	var cells: Vector2i = chunk_cells(terrain, chunk_x, chunk_z)
	var i0: int = chunk_x * CHUNK_CELLS
	var j0: int = chunk_z * CHUNK_CELLS
	var meters_per_cell: float = float(terrain.cell_size) / World.UNITS_PER_METER
	var vertices: PackedVector3Array = PackedVector3Array()
	vertices.resize((cells.x + 1) * (cells.y + 1))
	var normals: PackedVector3Array = PackedVector3Array()
	normals.resize(vertices.size())
	var n: int = 0
	for j: int in range(j0, j0 + cells.y + 1):
		var row_start: int = j * terrain.size_x
		for i: int in range(i0, i0 + cells.x + 1):
			vertices[n] = Vector3(
				i * meters_per_cell,
				_effective_height(terrain, row_start + i, view_heights) / float(World.UNITS_PER_METER),
				j * meters_per_cell
			)
			normals[n] = sample_normal(terrain, i, j, view_heights)
			n += 1

	var arrays: Array = []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = vertices
	arrays[Mesh.ARRAY_NORMAL] = normals
	arrays[Mesh.ARRAY_INDEX] = indices if not indices.is_empty() else grid_indices(cells.x, cells.y)
	var mesh: ArrayMesh = ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	return mesh


## Unit surface normal at sample (i, j), by central differences on the
## effective heights, one-sided at the map's edge. It reads neighbours from the
## whole terrain, so chunks that share an edge agree.
static func sample_normal(
	terrain: Terrain, i: int, j: int, view_heights: Dictionary[int, int]
) -> Vector3:
	var meters_per_cell: float = float(terrain.cell_size) / World.UNITS_PER_METER
	var i0: int = maxi(i - 1, 0)
	var i1: int = mini(i + 1, terrain.size_x - 1)
	var j0: int = maxi(j - 1, 0)
	var j1: int = mini(j + 1, terrain.size_z - 1)
	var row: int = j * terrain.size_x
	var dx: float = float(
		_effective_height(terrain, row + i1, view_heights)
		- _effective_height(terrain, row + i0, view_heights)
	) / World.UNITS_PER_METER / ((i1 - i0) * meters_per_cell)
	var dz: float = float(
		_effective_height(terrain, j1 * terrain.size_x + i, view_heights)
		- _effective_height(terrain, j0 * terrain.size_x + i, view_heights)
	) / World.UNITS_PER_METER / ((j1 - j0) * meters_per_cell)
	return Vector3(-dx, 1.0, -dz).normalized()


static func _effective_height(terrain: Terrain, k: int, view_heights: Dictionary[int, int]) -> int:
	return view_heights.get(k, terrain.heights[k])
