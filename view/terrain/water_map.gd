class_name WaterMap
extends RefCounted
## The water surface height per sample, from water.png beside a map's
## height.png (written by MapBuilder.save). View only: the sim reads depth
## levels from the mask and never this.


## Surface height in metres per sample, 0.0 where dry. Empty when water.png is
## absent or does not match the terrain's size. max_height is the map's
## MapInfo.max_height (milli-units), the scale water.png shares with height.png.
static func load_beside(heightmap_path: String, terrain: Terrain, max_height: int) -> PackedFloat32Array:
	var result: PackedFloat32Array = PackedFloat32Array()
	var path: String = heightmap_path.get_base_dir().path_join("water.png")
	if not FileAccess.file_exists(path):
		return result
	var raster: PngRaster = PngCodec.decode(FileAccess.get_file_as_bytes(path))
	if not raster.ok() or raster.channels != 1:
		push_error("WaterMap %s: not a grayscale PNG (%s)" % [path, raster.error])
		return result
	if raster.width != terrain.size_x or raster.height != terrain.size_z:
		push_error("WaterMap %s: size does not match the terrain" % path)
		return result
	var raw_max: int = (1 << raster.bit_depth) - 1
	result.resize(raster.samples.size())
	for k: int in raster.samples.size():
		# The same rounding Terrain.from_png applies to heights.
		var milli: int = (raster.samples[k] * max_height + raw_max / 2) / raw_max
		result[k] = milli / 1000.0
	return result
