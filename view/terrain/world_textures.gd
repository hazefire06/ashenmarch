class_name WorldTextures
extends RefCounted
## The textures the world draws with (A5): the six ground layers, as albedo
## and normal arrays the terrain shader blends, and one tiling detail noise
## the ground and water shaders both read. Each is made once and shared.
##
## The ground arrays are imported by scripts/art/world_assets.py (six 1K layers
## stacked top to bottom, in LAYERS order). Until they are, each falls back to
## six small solid layers: the overhead map's flat ground colors (TerrainPalette)
## plus a mud brown, and a flat normal, so the ground still draws and reads.

## Layer order in both arrays. "forest" is the floor drawn for Terrain.Ground
## WOOD; mud has no Terrain.Ground, the view lays it along shores.
const LAYERS: Array[StringName] = [&"grass", &"brush", &"forest", &"sand", &"rock", &"mud"]
const ALBEDO_PATH: String = "res://assets/world/textures/ground_albedo.png"
const NORMAL_PATH: String = "res://assets/world/textures/ground_normal.png"
## The fallback's mud: a dark, wet-looking brown.
const MUD_COLOR: Color = Color(0.30, 0.24, 0.17)
## A normal-map texel pointing straight out of the surface.
const FLAT_NORMAL: Color = Color(0.5, 0.5, 1.0)
## The fallback layers' side, in texels.
const FALLBACK_SIZE: int = 4
## Height of the flat ground color the fallback takes for a layer, 0..1 over
## the map's range: the middle band, so no layer is the lowest or highest.
const FALLBACK_HEIGHT: float = 0.5
const NOISE_SIZE: int = 256
## Cycles of FastNoiseLite per texel: about five blobs across the image.
const NOISE_FREQUENCY: float = 0.02

static var _albedo: TextureLayered
static var _normal: TextureLayered
static var _noise: Texture2D


## The six albedo layers, imported or the fallback.
static func albedo() -> TextureLayered:
	if _albedo == null:
		_albedo = _load_or(ALBEDO_PATH, fallback_colors())
	return _albedo


## The six normal-map layers, imported or flat.
static func normal() -> TextureLayered:
	if _normal == null:
		var flat: Array[Color] = []
		flat.resize(LAYERS.size())
		flat.fill(FLAT_NORMAL)
		_normal = _load_or(NORMAL_PATH, flat)
	return _normal


## NOISE_SIZE square, seamless RGBA noise with mipmaps, for breaking up
## ground borders, tiling and flat tones. Each channel is its own noise (R
## seed 0, then 1, 2, 3), so one read gives four values; the water reads R.
static func detail_noise() -> Texture2D:
	if _noise == null:
		var channels: Array[PackedByteArray] = []
		for seed: int in 4:
			var noise: FastNoiseLite = FastNoiseLite.new()
			noise.seed = seed
			noise.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
			noise.frequency = NOISE_FREQUENCY
			noise.fractal_octaves = 3
			var grey: Image = noise.get_seamless_image(NOISE_SIZE, NOISE_SIZE)
			grey.convert(Image.FORMAT_L8)
			channels.append(grey.get_data())
		var data: PackedByteArray = PackedByteArray()
		data.resize(NOISE_SIZE * NOISE_SIZE * 4)
		for k: int in NOISE_SIZE * NOISE_SIZE:
			for c: int in 4:
				data[k * 4 + c] = channels[c][k]
		var image: Image = Image.create_from_data(NOISE_SIZE, NOISE_SIZE, false, Image.FORMAT_RGBA8, data)
		image.generate_mipmaps()
		_noise = ImageTexture.create_from_image(image)
	return _noise


static func _load_or(path: String, fallback: Array[Color]) -> TextureLayered:
	if ResourceLoader.exists(path):
		var imported: TextureLayered = load(path) as TextureLayered
		if imported != null and imported.get_layers() == LAYERS.size():
			return imported
		push_error("WorldTextures: %s is not a %d-layer texture array" % [path, LAYERS.size()])
	var images: Array[Image] = []
	for color: Color in fallback:
		var image: Image = Image.create(FALLBACK_SIZE, FALLBACK_SIZE, false, Image.FORMAT_RGB8)
		image.fill(color)
		# The shader samples with mipmap filtering.
		image.generate_mipmaps()
		images.append(image)
	var array: Texture2DArray = Texture2DArray.new()
	array.create_from_images(images)
	return array


## The fallback albedo's color per layer: TerrainPalette's flat ground color
## for the Terrain.Ground each layer draws, then the mud brown.
static func fallback_colors() -> Array[Color]:
	var colors: Array[Color] = []
	for ground: int in Terrain.GROUND_COUNT:
		colors.append(TerrainPalette.ground_color(FALLBACK_HEIGHT, 0, ground))
	colors.append(MUD_COLOR)
	return colors
