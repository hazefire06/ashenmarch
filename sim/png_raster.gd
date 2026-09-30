class_name PngRaster
extends RefCounted
## Decoded (or to-be-encoded) PNG pixels as exact integers. Samples are
## channel-interleaved, row-major, top row first: sample c of pixel (x, y) is
## samples[(y * width + x) * channels + c]. A non-empty error means decoding
## failed and the other fields are meaningless.

var width: int = 0
var height: int = 0
## 1 gray, 2 gray+alpha, 3 RGB, 4 RGBA.
var channels: int = 0
## 8 or 16. Samples range over 0..(1 << bit_depth) - 1.
var bit_depth: int = 0
var samples: PackedInt32Array = PackedInt32Array()
var error: String = ""


static func create(w: int, h: int, channel_count: int, depth: int) -> PngRaster:
	var raster: PngRaster = PngRaster.new()
	raster.width = w
	raster.height = h
	raster.channels = channel_count
	raster.bit_depth = depth
	raster.samples.resize(w * h * channel_count)
	return raster


static func failed(message: String) -> PngRaster:
	var raster: PngRaster = PngRaster.new()
	raster.error = message
	return raster


func ok() -> bool:
	return error.is_empty()


func get_sample(x: int, y: int, channel: int) -> int:
	return samples[(y * width + x) * channels + channel]


func set_sample(x: int, y: int, channel: int, value: int) -> void:
	samples[(y * width + x) * channels + channel] = value
