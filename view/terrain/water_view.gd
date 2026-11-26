class_name WaterView
extends Node3D
## Draws the water surface (A5): a translucent mesh over the wet samples of a
## map's water map, at the surface height the generator recorded. View only;
## the sim's depth levels (and what a Husk hides under) are untouched.
##
## Chunked like the terrain (TerrainMeshBuilder.CHUNK_CELLS), one MeshInstance3D
## per chunk that holds water. A cell gets a quad when it has a wet corner and
## no corner under a structure model. A dry corner of such a shore quad takes
## the surface height of its nearest wet sample, so the sheet meets the bank
## without a step. water.gdshader fades the sheet out toward the shore from a
## depth map (surface minus bed), as the Compatibility renderer has no depth
## texture.

const WATER_SHADER: Shader = preload("res://view/terrain/water.gdshader")
## Meters of depth the depth map's full range stands for.
const DEPTH_RANGE_M: float = 4.0
## Ripple strength with no rain, and in the heaviest rain.
const RIPPLE_CALM: float = 0.3
const RIPPLE_STORM: float = 1.2

var _material: ShaderMaterial
var _cell_count: int = 0
## The grade set_grade() last passed on; alpha 0 changes nothing.
var _grade: Color = Color(0.0, 0.0, 0.0, 0.0)
var _ripple_strength: float = RIPPLE_CALM


## Replaces any existing water with meshes for water_m, the surface height in
## metres per sample, 0.0 where dry (WaterMap.load_beside). Empty draws nothing.
## Samples a structure covers get no water.
func build(terrain: Terrain, water_m: PackedFloat32Array, structures: MapStructures = null) -> void:
	for child: Node in get_children():
		remove_child(child)
		child.free()
	_cell_count = 0
	_material = null
	if water_m.size() != terrain.size_x * terrain.size_z:
		return
	var covered: PackedByteArray = _covered(terrain, structures)
	_material = _make_material(terrain, water_m)
	var counts: Vector2i = TerrainMeshBuilder.chunk_counts(terrain)
	for cz: int in counts.y:
		for cx: int in counts.x:
			var mesh: ArrayMesh = _chunk_mesh(terrain, water_m, covered, cx, cz)
			if mesh == null:
				continue
			var chunk: MeshInstance3D = MeshInstance3D.new()
			chunk.name = "Water_%d_%d" % [cx, cz]
			chunk.mesh = mesh
			chunk.material_override = _material
			chunk.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
			add_child(chunk)


## Grades the water for the mission's look: water_grade is blended over its own
## color by its alpha, so alpha 0 changes nothing. Survives build().
func set_grade(water_grade: Color) -> void:
	_grade = water_grade
	if _material != null:
		_material.set_shader_parameter("water_grade", _grade)


## Rain roughens the ripples.
func set_weather(weather: Weather) -> void:
	_ripple_strength = lerpf(RIPPLE_CALM, RIPPLE_STORM, clampf(weather.rain / float(Weather.PERMILLE), 0.0, 1.0))
	if _material != null:
		_material.set_shader_parameter("ripple_strength", _ripple_strength)


## Quads drawn, for tests.
func cell_count() -> int:
	return _cell_count


## The shader parameter `uniform` as the material holds it, for tests. Null
## when nothing is drawn.
func shader_parameter(uniform: StringName) -> Variant:
	return null if _material == null else _material.get_shader_parameter(uniform)


## One byte per sample, 1 where a structure model covers it.
static func _covered(terrain: Terrain, structures: MapStructures) -> PackedByteArray:
	var covered: PackedByteArray = PackedByteArray()
	covered.resize(terrain.size_x * terrain.size_z)
	if structures != null:
		for record: StructureRecord in structures.records:
			for k: int in record.samples:
				covered[k] = 1
	return covered


## The chunk's mesh, or null when none of its cells gets water. Vertices are
## shared inside the chunk and made only where a quad uses them.
func _chunk_mesh(
	terrain: Terrain, water_m: PackedFloat32Array, covered: PackedByteArray, chunk_x: int, chunk_z: int
) -> ArrayMesh:
	var cells: Vector2i = TerrainMeshBuilder.chunk_cells(terrain, chunk_x, chunk_z)
	var i0: int = chunk_x * TerrainMeshBuilder.CHUNK_CELLS
	var j0: int = chunk_z * TerrainMeshBuilder.CHUNK_CELLS
	var meters_per_cell: float = float(terrain.cell_size) / World.UNITS_PER_METER
	var row: int = cells.x + 1
	var slot: PackedInt32Array = PackedInt32Array()
	slot.resize(row * (cells.y + 1))
	slot.fill(-1)
	var vertices: PackedVector3Array = PackedVector3Array()
	var indices: PackedInt32Array = PackedInt32Array()
	var quads: int = 0
	for cz: int in cells.y:
		for cx: int in cells.x:
			var k00: int = (j0 + cz) * terrain.size_x + i0 + cx
			var k10: int = k00 + 1
			var k01: int = k00 + terrain.size_x
			var k11: int = k01 + 1
			if covered[k00] + covered[k10] + covered[k01] + covered[k11] > 0:
				continue
			if water_m[k00] <= 0.0 and water_m[k10] <= 0.0 and water_m[k01] <= 0.0 and water_m[k11] <= 0.0:
				continue
			var v00: int = _vertex(terrain, water_m, vertices, slot, row, i0, j0, cx, cz, meters_per_cell)
			var v10: int = _vertex(terrain, water_m, vertices, slot, row, i0, j0, cx + 1, cz, meters_per_cell)
			var v01: int = _vertex(terrain, water_m, vertices, slot, row, i0, j0, cx, cz + 1, meters_per_cell)
			var v11: int = _vertex(terrain, water_m, vertices, slot, row, i0, j0, cx + 1, cz + 1, meters_per_cell)
			# The terrain's winding.
			indices.append_array(PackedInt32Array([v00, v10, v11, v00, v11, v01]))
			quads += 1
	if quads == 0:
		return null
	_cell_count += quads
	var normals: PackedVector3Array = PackedVector3Array()
	normals.resize(vertices.size())
	normals.fill(Vector3.UP)
	var arrays: Array = []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = vertices
	arrays[Mesh.ARRAY_NORMAL] = normals
	arrays[Mesh.ARRAY_INDEX] = indices
	var mesh: ArrayMesh = ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	return mesh


## Index of the chunk-local vertex (lx, lz), added when new.
func _vertex(
	terrain: Terrain, water_m: PackedFloat32Array, vertices: PackedVector3Array,
	slot: PackedInt32Array, row: int, i0: int, j0: int, lx: int, lz: int, meters_per_cell: float
) -> int:
	var at: int = lz * row + lx
	if slot[at] >= 0:
		return slot[at]
	var i: int = i0 + lx
	var j: int = j0 + lz
	slot[at] = vertices.size()
	vertices.append(Vector3(i * meters_per_cell, _surface(terrain, water_m, i, j), j * meters_per_cell))
	return slot[at]


## The surface height at sample (i, j): its own if wet, else the nearest wet
## neighbour's (beside before diagonal; the first found on a tie).
static func _surface(terrain: Terrain, water_m: PackedFloat32Array, i: int, j: int) -> float:
	var own: float = water_m[j * terrain.size_x + i]
	if own > 0.0:
		return own
	const AROUND: Array[Vector2i] = [
		Vector2i(-1, 0), Vector2i(1, 0), Vector2i(0, -1), Vector2i(0, 1),
		Vector2i(-1, -1), Vector2i(1, -1), Vector2i(-1, 1), Vector2i(1, 1),
	]
	for step: Vector2i in AROUND:
		var x: int = i + step.x
		var z: int = j + step.y
		if x < 0 or z < 0 or x >= terrain.size_x or z >= terrain.size_z:
			continue
		var neighbour: float = water_m[z * terrain.size_x + x]
		if neighbour > 0.0:
			return neighbour
	return 0.0


func _make_material(terrain: Terrain, water_m: PackedFloat32Array) -> ShaderMaterial:
	var material: ShaderMaterial = ShaderMaterial.new()
	material.shader = WATER_SHADER
	material.set_shader_parameter("depth_map", ImageTexture.create_from_image(_depth_image(terrain, water_m)))
	material.set_shader_parameter("detail_noise", WorldTextures.detail_noise())
	material.set_shader_parameter("sample_count", Vector2(terrain.size_x, terrain.size_z))
	material.set_shader_parameter("cell_size", terrain.cell_size / float(World.UNITS_PER_METER))
	material.set_shader_parameter("depth_range", DEPTH_RANGE_M)
	material.set_shader_parameter("deep_color", Color(0.04, 0.17, 0.24))
	material.set_shader_parameter("shallow_alpha", 0.25)
	material.set_shader_parameter("ripple_speed", 0.03)
	material.set_shader_parameter("ripple_strength", _ripple_strength)
	material.set_shader_parameter("water_grade", _grade)
	return material


## RH (half float, which WebGL2 filters), one texel per sample: surface minus
## bed in metres, 0..DEPTH_RANGE_M scaled to 0..1; dry samples are 0. Not R8:
## a ford is 5 to 20 cm deep, and 8 bits over 4 m steps by 1.6 cm, enough to
## show each sample's rounding as a grid through the shallow fade.
static func _depth_image(terrain: Terrain, water_m: PackedFloat32Array) -> Image:
	var image: Image = Image.create(terrain.size_x, terrain.size_z, false, Image.FORMAT_RH)
	for k: int in water_m.size():
		if water_m[k] > 0.0:
			var depth: float = water_m[k] - terrain.heights[k] / float(World.UNITS_PER_METER)
			image.set_pixel(k % terrain.size_x, k / terrain.size_x, Color(clampf(depth / DEPTH_RANGE_M, 0.0, 1.0), 0.0, 0.0))
	return image
