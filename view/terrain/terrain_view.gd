class_name TerrainView
extends Node3D
## Draws a Terrain as chunked, flat-shaded placeholder meshes colored by
## height, ground type, and water depth. build() reads the whole terrain;
## rebuild_region() re-reads the heights in part of it, after explosions scar
## the ground. Never writes the terrain.
##
## The environment (Phase 5) lives on the one material all chunks share:
## update_fire() keeps a texel per sample in step with the sim's fire
## (burning cells glow, burnt ones are charred), and set_weather() passes on
## how wet and snow-covered the ground is. Both survive rebuild_region().

const TERRAIN_SHADER: Shader = preload("res://view/terrain/terrain.gdshader")
## Fire texel value (R8) by Fire.Cell.
const FIRE_TEXEL: Array[int] = [0, 128, 255]

## Index array shared by every full-size chunk, made by build().
var _shared_indices: PackedInt32Array = PackedInt32Array()
var _material: ShaderMaterial
var _fire_image: Image
var _fire_texture: ImageTexture


## Replaces any existing chunks with meshes for this terrain.
func build(terrain: Terrain) -> void:
	for child: Node in get_children():
		# Out of the tree now, so a rebuild in the same frame can reuse the names.
		remove_child(child)
		child.queue_free()
	var material: ShaderMaterial = _make_material(terrain)
	_material = material
	_shared_indices = TerrainMeshBuilder.grid_indices(
		TerrainMeshBuilder.CHUNK_CELLS, TerrainMeshBuilder.CHUNK_CELLS
	)
	var counts: Vector2i = TerrainMeshBuilder.chunk_counts(terrain)
	for cz: int in counts.y:
		for cx: int in counts.x:
			var chunk: MeshInstance3D = MeshInstance3D.new()
			chunk.name = _chunk_name(cx, cz)
			chunk.mesh = _chunk_mesh(terrain, cx, cz)
			chunk.material_override = material
			add_child(chunk)


## Rebuilds the meshes of the chunks that touch cells, a rectangle of terrain
## samples (what Terrain.scar() returns), plus a margin of one sample, and
## leaves every other chunk alone. Each keeps its node and material. Does
## nothing for an empty rectangle.
func rebuild_region(terrain: Terrain, cells: Rect2i) -> void:
	if not cells.has_area():
		return
	var dirty: Rect2i = cells.grow(1)
	var counts: Vector2i = TerrainMeshBuilder.chunk_counts(terrain)
	for cz: int in counts.y:
		for cx: int in counts.x:
			var size: Vector2i = TerrainMeshBuilder.chunk_cells(terrain, cx, cz)
			# A chunk's samples include the edge it shares with the next chunk.
			var samples: Rect2i = Rect2i(
				cx * TerrainMeshBuilder.CHUNK_CELLS, cz * TerrainMeshBuilder.CHUNK_CELLS,
				size.x + 1, size.y + 1
			)
			if not samples.intersects(dirty):
				continue
			var chunk: MeshInstance3D = get_node_or_null(_chunk_name(cx, cz)) as MeshInstance3D
			if chunk != null:
				chunk.mesh = _chunk_mesh(terrain, cx, cz)


## Brings the fire texture up to date with the cells that changed this tick
## (fire.changed). Call it after each World.step().
func update_fire(fire: Fire) -> void:
	if fire == null or fire.changed.is_empty() or _fire_image == null:
		return
	var w: int = _fire_image.get_width()
	for k: int in fire.changed:
		var value: int = FIRE_TEXEL[fire.state[k]]
		_fire_image.set_pixel(k % w, k / w, Color8(value, 0, 0))
	_fire_texture.update(_fire_image)


## Passes the ground's wetness and snow cover on to the shader.
func set_weather(weather: Weather) -> void:
	if _material == null:
		return
	_material.set_shader_parameter("wetness", weather.wetness() / 1000.0)
	_material.set_shader_parameter("snow_cover", weather.snow_cover() / 1000.0)


## The fire texel (R8) at sample (i, j), for tests.
func fire_texel(i: int, j: int) -> int:
	return _fire_image.get_pixel(i, j).r8


static func _chunk_name(chunk_x: int, chunk_z: int) -> String:
	return "Chunk_%d_%d" % [chunk_x, chunk_z]


# Full chunks reuse one index array; the smaller ones at the far edges make
# their own.
func _chunk_mesh(terrain: Terrain, chunk_x: int, chunk_z: int) -> ArrayMesh:
	var full: Vector2i = Vector2i(TerrainMeshBuilder.CHUNK_CELLS, TerrainMeshBuilder.CHUNK_CELLS)
	var is_full: bool = TerrainMeshBuilder.chunk_cells(terrain, chunk_x, chunk_z) == full
	return TerrainMeshBuilder.build_chunk(
		terrain, chunk_x, chunk_z, _shared_indices if is_full else PackedInt32Array()
	)


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
	material.set_shader_parameter("ground_tint", ImageTexture.create_from_image(_ground_tint_image(terrain)))
	_fire_image = Image.create(terrain.size_x, terrain.size_z, false, Image.FORMAT_R8)
	_fire_texture = ImageTexture.create_from_image(_fire_image)
	material.set_shader_parameter("fire_state", _fire_texture)
	material.set_shader_parameter("wetness", 0.0)
	material.set_shader_parameter("snow_cover", 0.0)
	material.set_shader_parameter("height_min", lowest / mm_per_m)
	material.set_shader_parameter("height_max", highest / mm_per_m)
	material.set_shader_parameter("cell_size", terrain.cell_size / mm_per_m)
	material.set_shader_parameter("sample_count", Vector2(terrain.size_x, terrain.size_z))
	return material


## RGBA8, one texel per sample: TerrainPalette.ground_tint of its ground.
func _ground_tint_image(terrain: Terrain) -> Image:
	var by_ground: Array[PackedByteArray] = []
	for ground: int in Terrain.GROUND_COUNT:
		var c: Color = TerrainPalette.ground_tint(ground)
		by_ground.append(PackedByteArray([c.r8, c.g8, c.b8, c.a8]))
	var count: int = terrain.size_x * terrain.size_z
	var data: PackedByteArray = PackedByteArray()
	data.resize(count * 4)
	for k: int in count:
		var texel: PackedByteArray = by_ground[terrain.ground[k]]
		data[k * 4] = texel[0]
		data[k * 4 + 1] = texel[1]
		data[k * 4 + 2] = texel[2]
		data[k * 4 + 3] = texel[3]
	return Image.create_from_data(terrain.size_x, terrain.size_z, false, Image.FORMAT_RGBA8, data)


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
