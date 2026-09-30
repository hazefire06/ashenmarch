class_name TerrainView
extends Node3D
## Draws a Terrain as chunked, flat-shaded placeholder meshes colored by
## height and water depth. Reads the terrain once in build(); never writes it.

const TERRAIN_SHADER: Shader = preload("res://view/terrain/terrain.gdshader")


## Replaces any existing chunks with meshes for this terrain.
func build(terrain: Terrain) -> void:
	for child: Node in get_children():
		child.queue_free()
	var material: ShaderMaterial = _make_material(terrain)
	var full: Vector2i = Vector2i(TerrainMeshBuilder.CHUNK_CELLS, TerrainMeshBuilder.CHUNK_CELLS)
	var shared_indices: PackedInt32Array = TerrainMeshBuilder.grid_indices(full.x, full.y)
	var counts: Vector2i = TerrainMeshBuilder.chunk_counts(terrain)
	for cz: int in counts.y:
		for cx: int in counts.x:
			var is_full: bool = TerrainMeshBuilder.chunk_cells(terrain, cx, cz) == full
			var chunk: MeshInstance3D = MeshInstance3D.new()
			chunk.name = "Chunk_%d_%d" % [cx, cz]
			chunk.mesh = TerrainMeshBuilder.build_chunk(
				terrain, cx, cz, shared_indices if is_full else PackedInt32Array()
			)
			chunk.material_override = material
			add_child(chunk)


func _make_material(terrain: Terrain) -> ShaderMaterial:
	var lowest: int = terrain.heights[0]
	var highest: int = terrain.heights[0]
	for h: int in terrain.heights:
		lowest = mini(lowest, h)
		highest = maxi(highest, h)
	var mm_per_m: float = float(World.UNITS_PER_METER)
	var material: ShaderMaterial = ShaderMaterial.new()
	material.shader = TERRAIN_SHADER
	material.set_shader_parameter(
		"height_ramp", ImageTexture.create_from_image(TerrainPalette.height_ramp_image())
	)
	material.set_shader_parameter("water_tint", ImageTexture.create_from_image(_water_tint_image(terrain)))
	material.set_shader_parameter("height_min", lowest / mm_per_m)
	material.set_shader_parameter("height_max", highest / mm_per_m)
	material.set_shader_parameter("cell_size", terrain.cell_size / mm_per_m)
	material.set_shader_parameter("sample_count", Vector2(terrain.size_x, terrain.size_z))
	return material


## RGBA8, one texel per sample: TerrainPalette.water_color of its depth.
func _water_tint_image(terrain: Terrain) -> Image:
	var by_depth: Array[PackedByteArray] = []
	for depth: int in Terrain.MAX_WATER_DEPTH + 1:
		var c: Color = TerrainPalette.water_color(depth)
		by_depth.append(PackedByteArray([c.r8, c.g8, c.b8, c.a8]))
	var count: int = terrain.size_x * terrain.size_z
	var data: PackedByteArray = PackedByteArray()
	data.resize(count * 4)
	for k: int in count:
		var texel: PackedByteArray = by_depth[terrain.water[k]]
		data[k * 4] = texel[0]
		data[k * 4 + 1] = texel[1]
		data[k * 4 + 2] = texel[2]
		data[k * 4 + 3] = texel[3]
	return Image.create_from_data(terrain.size_x, terrain.size_z, false, Image.FORMAT_RGBA8, data)
