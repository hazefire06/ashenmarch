class_name TerrainView
extends Node3D
## Draws a Terrain as chunked, smooth-shaded meshes textured by ground type
## (six blended layers, WorldTextures: each sample's ground, mud along
## shores, rock on steep faces), tinted by water depth, and darker where a
## structure blocks the sample but no structure model covers it. build() reads
## the whole terrain;
## rebuild_region() re-reads the heights in part of it, after explosions scar
## the ground. Never writes the terrain.
##
## The environment (Phase 5) lives on the one material all chunks share:
## update_fire() keeps a texel per sample in step with the sim's fire
## (burning cells glow, burnt ones are charred), and set_weather() passes on
## how wet and snow-covered the ground is. Both survive rebuild_region().
## set_grade() (Phase 8) passes on a mission's look for the ground and water;
## it survives build() and rebuild_region() too, and unset it changes nothing.

## After rebuild_region() redraws part of the ground (an explosion's scar),
## so the ground scatter can follow it.
signal region_rebuilt(terrain: Terrain, cells: Rect2i)

const TERRAIN_SHADER: Shader = preload("res://view/terrain/terrain.gdshader")
## Fire texel value (R8) by Fire.Cell.
const FIRE_TEXEL: Array[int] = [0, 128, 255]
## Fire texel G of a burning cell; any other is 0. The shader filters the
## fire between samples, and R alone would blend unburnt into scorched
## through "burning", so the glow has a channel of its own.
const FIRE_GLOW_TEXEL: int = 255
## Blocked texel value (R8) of a blocked sample; an open one is 0.
const BLOCKED_TEXEL: int = 255
## The texture settings the shader is given (terrain.gdshader explains each).
const TILE_M: float = 3.0
const BORDER_JITTER: float = 0.35
const ROCK_NORMAL_Y: float = 0.707
const ROCK_BAND: float = 0.1
## Mud lies on the riverbed and fades out over this many meters of dry bank.
const MUD_REACH_M: float = 3.0

## Index array shared by every full-size chunk, made by build().
var _shared_indices: PackedInt32Array = PackedInt32Array()
var _material: ShaderMaterial
## The worn trails build() baked (empty without any), shared with the scatter.
var _trail_mask: TrailMask = TrailMask.bake(null, Vector2.ZERO)
## Heights the view draws under structures (sample index to milli-units), kept
## by build() for rebuild_region(). Its keys are the samples a structure
## model covers.
var _view_heights: Dictionary[int, int] = {}
var _fire_image: Image
var _fire_texture: ImageTexture
## Cells burning at the last update_fire().
var _burning_seen: int = 0
## The grade set_grade() last passed on, kept so build() can give a new
## material the same one. The defaults are "no change".
var _grade_tint: Color = Color.WHITE
var _grade_desaturation: float = 0.0
var _grade_recolor: PackedColorArray = _no_recolor()
var _grade_water: Color = Color(0.0, 0.0, 0.0, 0.0)


## Replaces any existing chunks with meshes for this terrain. With structures,
## the samples under each are drawn at their natural ground height, so the
## sim's raised slab is never seen; the sim's heights are untouched. trails
## (the map's MapTrails, or null) are baked into a TrailMask and worn into the
## ground as dirt.
func build(terrain: Terrain, structures: MapStructures = null, trails: MapTrails = null) -> void:
	_view_heights = {}
	if structures != null:
		_view_heights = structures.view_heights(terrain)
	var mm_per_m: float = float(World.UNITS_PER_METER)
	_trail_mask = TrailMask.bake(trails, Vector2(terrain.extent_x(), terrain.extent_z()) / mm_per_m)
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
	region_rebuilt.emit(terrain, cells)


## Brings the fire texture up to date with the cells that changed this tick
## (fire.changed). Call it after each World.step(). A cell lit between steps
## never shows in changed (the next step clears it first), so a burning
## count that differs from last time also rewrites every burning cell.
func update_fire(fire: Fire) -> void:
	if fire == null or _fire_image == null:
		return
	var recount: bool = fire.burn_end.size() != _burning_seen
	if fire.changed.is_empty() and not recount:
		return
	_burning_seen = fire.burn_end.size()
	var w: int = _fire_image.get_width()
	var cells: Array = fire.burn_end.keys() if recount else []
	cells.append_array(Array(fire.changed))
	for k: int in cells:
		var cell: int = fire.state[k]
		var glow: int = FIRE_GLOW_TEXEL if cell == Fire.Cell.BURNING else 0
		_fire_image.set_pixel(k % w, k / w, Color8(FIRE_TEXEL[cell], glow, 0))
	_fire_texture.update(_fire_image)


## The fire texture update_fire() keeps (one RG8 texel per sample; see
## FIRE_TEXEL), for the ground scatter to read. Null before build().
func fire_texture() -> Texture2D:
	return _fire_texture


## The worn trails build() baked, for the ground scatter to keep off. Empty
## before build() or without trails.
func trail_mask() -> TrailMask:
	return _trail_mask


## Passes the ground's wetness and snow cover on to the shader.
func set_weather(weather: Weather) -> void:
	if _material == null:
		return
	_material.set_shader_parameter("wetness", weather.wetness() / 1000.0)
	_material.set_shader_parameter("snow_cover", weather.snow_cover() / 1000.0)


## Grades the ground and water for the mission's look (Atmosphere):
## - tint multiplies the ground color, so white changes nothing;
## - desaturation (0..1) drains it toward gray, 0 changes nothing;
## - recolor is a color per Terrain.Ground (Terrain.GROUND_COUNT of them, its
##   alpha how much it takes over), or empty for none;
## - water_grade is blended over the water's own tint by its alpha, so alpha 0
##   changes nothing.
## All of it reaches the shader in one go and applies to terrain built later
## too. The defaults, a white tint, 0, empty, and an alpha-0 color, are the
## ungraded look.
func set_grade(tint: Color, desaturation: float, recolor: Array[Color], water_grade: Color) -> void:
	_grade_tint = tint
	_grade_desaturation = desaturation
	_grade_recolor = _no_recolor()
	if recolor.size() == Terrain.GROUND_COUNT:
		_grade_recolor = PackedColorArray(recolor)
	elif not recolor.is_empty():
		push_error("TerrainView.set_grade: recolor needs %d colors, not %d" % [Terrain.GROUND_COUNT, recolor.size()])
	_grade_water = water_grade
	if _material != null:
		_apply_grade(_material)


## The shader parameter `uniform` as the shared material holds it, for tests.
## Null before build().
func shader_parameter(uniform: StringName) -> Variant:
	return null if _material == null else _material.get_shader_parameter(uniform)


## The fire texel's R (FIRE_TEXEL) at sample (i, j), for tests.
func fire_texel(i: int, j: int) -> int:
	return _fire_image.get_pixel(i, j).r8


## The fire texel's G (FIRE_GLOW_TEXEL while burning, else 0) at sample
## (i, j), for tests.
func fire_glow_texel(i: int, j: int) -> int:
	return _fire_image.get_pixel(i, j).g8


static func _chunk_name(chunk_x: int, chunk_z: int) -> String:
	return "Chunk_%d_%d" % [chunk_x, chunk_z]


# Full chunks reuse one index array; the smaller ones at the far edges make
# their own.
func _chunk_mesh(terrain: Terrain, chunk_x: int, chunk_z: int) -> ArrayMesh:
	var full: Vector2i = Vector2i(TerrainMeshBuilder.CHUNK_CELLS, TerrainMeshBuilder.CHUNK_CELLS)
	var is_full: bool = TerrainMeshBuilder.chunk_cells(terrain, chunk_x, chunk_z) == full
	return TerrainMeshBuilder.build_chunk(
		terrain, chunk_x, chunk_z,
		_shared_indices if is_full else PackedInt32Array(), _view_heights
	)


func _make_material(terrain: Terrain) -> ShaderMaterial:
	var mm_per_m: float = float(World.UNITS_PER_METER)
	var material: ShaderMaterial = ShaderMaterial.new()
	material.shader = TERRAIN_SHADER
	material.set_shader_parameter("ground_albedo", WorldTextures.albedo())
	material.set_shader_parameter("ground_normal", WorldTextures.normal())
	material.set_shader_parameter("detail_noise", WorldTextures.detail_noise())
	var weights: Array[Image] = _ground_weight_images(terrain)
	material.set_shader_parameter("ground_weights_a", ImageTexture.create_from_image(weights[0]))
	material.set_shader_parameter("ground_weights_b", ImageTexture.create_from_image(weights[1]))
	material.set_shader_parameter("tile_m", TILE_M)
	material.set_shader_parameter("border_jitter", BORDER_JITTER)
	material.set_shader_parameter("rock_normal_y", ROCK_NORMAL_Y)
	material.set_shader_parameter("rock_band", ROCK_BAND)
	material.set_shader_parameter("water_tint", ImageTexture.create_from_image(_water_tint_image(terrain)))
	material.set_shader_parameter("blocked_map", ImageTexture.create_from_image(_blocked_image(terrain)))
	material.set_shader_parameter("trail_mask", _trail_mask.texture())
	material.set_shader_parameter("trail_origin", _trail_mask.origin_m())
	material.set_shader_parameter("trail_size", _trail_mask.size_m())
	_apply_grade(material)
	material.set_shader_parameter(
		"blocked_tint", Vector2(TerrainPalette.BLOCKED_DARKEN, TerrainPalette.BLOCKED_DESATURATE)
	)
	_fire_image = Image.create(terrain.size_x, terrain.size_z, false, Image.FORMAT_RG8)
	_burning_seen = 0
	_fire_texture = ImageTexture.create_from_image(_fire_image)
	material.set_shader_parameter("fire_state", _fire_texture)
	material.set_shader_parameter("wetness", 0.0)
	material.set_shader_parameter("snow_cover", 0.0)
	material.set_shader_parameter("cell_size", terrain.cell_size / mm_per_m)
	material.set_shader_parameter("sample_count", Vector2(terrain.size_x, terrain.size_z))
	return material


func _apply_grade(material: ShaderMaterial) -> void:
	material.set_shader_parameter("grade_tint", _grade_tint)
	material.set_shader_parameter("grade_desaturation", _grade_desaturation)
	material.set_shader_parameter("ground_recolor", _grade_recolor)
	material.set_shader_parameter("water_grade", _grade_water)


## One transparent color per Terrain.Ground: the shader's "no recolor".
static func _no_recolor() -> PackedColorArray:
	var none: PackedColorArray = PackedColorArray()
	none.resize(Terrain.GROUND_COUNT)
	none.fill(Color(0.0, 0.0, 0.0, 0.0))
	return none


## Two RGBA8 images, one texel per sample, of the six layer weights (255 is
## all of it) and the samples a structure model covers; terrain.gdshader reads
## them as ground_weights_a and ground_weights_b. A sample weighs its own
## ground, less the mud laid on it near water; the six always sum to 255.
func _ground_weight_images(terrain: Terrain) -> Array[Image]:
	var mud: PackedFloat32Array = mud_weights(terrain)
	var count: int = terrain.size_x * terrain.size_z
	var a: PackedByteArray = PackedByteArray()
	var b: PackedByteArray = PackedByteArray()
	a.resize(count * 4)
	b.resize(count * 4)
	for k: int in count:
		var mud_byte: int = roundi(mud[k] * 255.0)
		# Grass, brush, wood and sand are a's four channels, rock is b's first:
		# the Terrain.Ground order.
		var ground: int = terrain.ground[k]
		if ground < Terrain.Ground.ROCK:
			a[k * 4 + ground] = 255 - mud_byte
		else:
			b[k * 4] = 255 - mud_byte
		b[k * 4 + 1] = mud_byte
		b[k * 4 + 2] = 255 if _view_heights.has(k) else 0
	return [
		Image.create_from_data(terrain.size_x, terrain.size_z, false, Image.FORMAT_RGBA8, a),
		Image.create_from_data(terrain.size_x, terrain.size_z, false, Image.FORMAT_RGBA8, b),
	]


## Mud per sample, 0..1: all of it under water, fading to none MUD_REACH_M
## from the nearest water sample. The nearest water to any dry sample is on the
## shore, so only shore samples spread it.
static func mud_weights(terrain: Terrain) -> PackedFloat32Array:
	var w: int = terrain.size_x
	var h: int = terrain.size_z
	var mud: PackedFloat32Array = PackedFloat32Array()
	mud.resize(w * h)
	var cell_m: float = terrain.cell_size / float(World.UNITS_PER_METER)
	var reach: int = ceili(MUD_REACH_M / cell_m)
	for j: int in h:
		for i: int in w:
			var k: int = j * w + i
			if terrain.water[k] == 0:
				continue
			mud[k] = 1.0
			if not _is_shore(terrain, i, j):
				continue
			for dj: int in range(-reach, reach + 1):
				for di: int in range(-reach, reach + 1):
					var x: int = i + di
					var z: int = j + dj
					if x < 0 or z < 0 or x >= w or z >= h:
						continue
					var near: float = 1.0 - sqrt(float(di * di + dj * dj)) * cell_m / MUD_REACH_M
					mud[z * w + x] = maxf(mud[z * w + x], near)
	return mud


## Whether water sample (i, j) has a dry sample beside it.
static func _is_shore(terrain: Terrain, i: int, j: int) -> bool:
	for step: Vector2i in [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]:
		var x: int = i + step.x
		var z: int = j + step.y
		if x >= 0 and z >= 0 and x < terrain.size_x and z < terrain.size_z and terrain.water[z * terrain.size_x + x] == 0:
			return true
	return false


## R8, one texel per sample: BLOCKED_TEXEL where a structure blocks it, so the
## shader can draw houses and walls as solid.
func _blocked_image(terrain: Terrain) -> Image:
	var data: PackedByteArray = PackedByteArray()
	data.resize(terrain.size_x * terrain.size_z)
	for k: int in data.size():
		data[k] = BLOCKED_TEXEL if terrain.blocked[k] != 0 else 0
	return Image.create_from_data(terrain.size_x, terrain.size_z, false, Image.FORMAT_R8, data)


## RGBA8, one texel per sample: TerrainPalette.water_color of its depth.
func _water_tint_image(terrain: Terrain) -> Image:
	var by_depth: Array[PackedByteArray] = []
	for depth: int in Terrain.MAX_WATER_DEPTH + 1:
		var c: Color = TerrainPalette.water_color(depth)
		by_depth.append(PackedByteArray([c.r8, c.g8, c.b8, c.a8]))
	# Dry ground: the shallow water's color, at no strength. The shader
	# filters between samples, so a bank fades the water's strength out
	# without darkening its color toward the dry texel's.
	var shallow: Color = TerrainPalette.water_color(1)
	by_depth[0] = PackedByteArray([shallow.r8, shallow.g8, shallow.b8, 0])
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
