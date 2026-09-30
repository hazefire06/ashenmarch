class_name PngCodec
extends RefCounted
## Minimal PNG reader and writer for exact integer map data.
##
## Godot's own PNG loader converts 16-bit images to 8-bit (libpng's
## PNG_FORMAT_FLAG_LINEAR is masked out in png_driver_common.cpp), which would
## terrace a heightmap into ~16 cm steps. So the sim parses PNGs itself.
## Supports 8- and 16-bit gray, gray+alpha, RGB, and RGBA, non-interlaced,
## all five row filters. Palette images, sub-8-bit depths, and Adam7 are
## rejected with an error. zlib comes from PackedByteArray's DEFLATE mode,
## which is a zlib stream (window bits 15), the same format as PNG IDAT.

enum Filter { NONE = 0, SUB = 1, UP = 2, AVERAGE = 3, PAETH = 4 }

## Encoder option: use filter (row % 5) on each row, so every decode path is
## exercised. For tests.
const FILTER_CYCLE: int = -1
## Largest image accepted, in unfiltered bytes (4096x4096 RGB8 fits). A
## corrupt header must not be able to make the decoder allocate gigabytes.
const MAX_IMAGE_BYTES: int = 64 * 1024 * 1024
## deflate can't expand data by more than about 1032:1, so an IDAT smaller
## than expected / this ratio can't be a real image of the stated size.
const MAX_DEFLATE_RATIO: int = 1032
const SIGNATURE: Array[int] = [137, 80, 78, 71, 13, 10, 26, 10]
const CHANNELS_BY_COLOR_TYPE: Dictionary[int, int] = {0: 1, 2: 3, 4: 2, 6: 4}
const COLOR_TYPE_BY_CHANNELS: Dictionary[int, int] = {1: 0, 2: 4, 3: 2, 4: 6}
const COLOR_TYPE_PALETTE: int = 3

static var _crc_table: PackedInt64Array = PackedInt64Array()


## Decodes PNG file bytes. Check the result's ok() before using it.
static func decode(bytes: PackedByteArray) -> PngRaster:
	if bytes.size() < SIGNATURE.size():
		return PngRaster.failed("not a PNG: too short")
	for i: int in SIGNATURE.size():
		if bytes[i] != SIGNATURE[i]:
			return PngRaster.failed("not a PNG: bad signature")

	var raster: PngRaster = null
	var idat: PackedByteArray = PackedByteArray()
	var seen_iend: bool = false
	var pos: int = SIGNATURE.size()
	while pos < bytes.size() and not seen_iend:
		if pos + 12 > bytes.size():
			return PngRaster.failed("truncated chunk header at byte %d" % pos)
		var length: int = _read_u32(bytes, pos)
		var type: String = bytes.slice(pos + 4, pos + 8).get_string_from_ascii()
		var data_start: int = pos + 8
		var data_end: int = data_start + length
		if data_end + 4 > bytes.size():
			return PngRaster.failed("truncated %s chunk" % type)
		if crc32(bytes, pos + 4, data_end) != _read_u32(bytes, data_end):
			return PngRaster.failed("CRC mismatch in %s chunk" % type)
		pos = data_end + 4

		if raster == null and type != "IHDR":
			return PngRaster.failed("first chunk is %s, not IHDR" % type)
		if type == "IHDR":
			if raster != null:
				return PngRaster.failed("duplicate IHDR")
			raster = _parse_ihdr(bytes.slice(data_start, data_end))
			if not raster.ok():
				return raster
		elif type == "IDAT":
			idat.append_array(bytes.slice(data_start, data_end))
		elif type == "IEND":
			seen_iend = true
		elif type != "PLTE" and _is_critical(type):
			# Ancillary chunks (lowercase first letter) are safe to skip. An
			# unknown critical chunk changes how the pixels must be read.
			# PLTE is legal (a suggested palette) in non-palette images.
			return PngRaster.failed("unsupported critical chunk %s" % type)

	if raster == null:
		return PngRaster.failed("no IHDR chunk")
	if not seen_iend:
		return PngRaster.failed("missing IEND chunk")
	if idat.is_empty():
		return PngRaster.failed("no IDAT chunk")
	return _decode_pixels(raster, idat)


## Encodes a raster as PNG file bytes, applying one filter to every row (or
## FILTER_CYCLE). Returns an empty array if the raster is malformed.
static func encode(raster: PngRaster, filter: int = Filter.UP) -> PackedByteArray:
	if not COLOR_TYPE_BY_CHANNELS.has(raster.channels):
		push_error("PngCodec.encode: %d channels" % raster.channels)
		return PackedByteArray()
	if raster.bit_depth != 8 and raster.bit_depth != 16:
		push_error("PngCodec.encode: bit depth %d" % raster.bit_depth)
		return PackedByteArray()
	if raster.width <= 0 or raster.height <= 0:
		push_error("PngCodec.encode: size %dx%d" % [raster.width, raster.height])
		return PackedByteArray()
	if raster.samples.size() != raster.width * raster.height * raster.channels:
		push_error("PngCodec.encode: sample count does not match size")
		return PackedByteArray()

	var bpp: int = raster.channels * raster.bit_depth / 8
	var stride: int = raster.width * bpp
	var raw: PackedByteArray = _samples_to_bytes(raster)
	var filtered: PackedByteArray = PackedByteArray()
	filtered.resize(raster.height * (stride + 1))
	for y: int in raster.height:
		var row_filter: int = y % 5 if filter == FILTER_CYCLE else filter
		var src: int = y * stride
		var dst: int = y * (stride + 1)
		filtered[dst] = row_filter
		for i: int in stride:
			var a: int = raw[src + i - bpp] if i >= bpp else 0
			var b: int = raw[src + i - stride] if y > 0 else 0
			var c: int = raw[src + i - stride - bpp] if y > 0 and i >= bpp else 0
			filtered[dst + 1 + i] = (raw[src + i] - _predict(row_filter, a, b, c)) & 0xFF

	var ihdr: PackedByteArray = PackedByteArray()
	_append_u32(ihdr, raster.width)
	_append_u32(ihdr, raster.height)
	ihdr.append_array(
		PackedByteArray([raster.bit_depth, COLOR_TYPE_BY_CHANNELS[raster.channels], 0, 0, 0])
	)

	var out: PackedByteArray = PackedByteArray(SIGNATURE)
	_append_chunk(out, "IHDR", ihdr)
	_append_chunk(out, "IDAT", filtered.compress(FileAccess.COMPRESSION_DEFLATE))
	_append_chunk(out, "IEND", PackedByteArray())
	return out


static func _parse_ihdr(data: PackedByteArray) -> PngRaster:
	if data.size() != 13:
		return PngRaster.failed("IHDR is %d bytes, expected 13" % data.size())
	var w: int = _read_u32(data, 0)
	var h: int = _read_u32(data, 4)
	var depth: int = data[8]
	var color_type: int = data[9]
	if w <= 0 or h <= 0:
		return PngRaster.failed("invalid size %dx%d" % [w, h])
	if color_type == COLOR_TYPE_PALETTE:
		return PngRaster.failed("palette PNGs are not supported; save as grayscale or RGB")
	if not CHANNELS_BY_COLOR_TYPE.has(color_type):
		return PngRaster.failed("invalid color type %d" % color_type)
	if depth != 8 and depth != 16:
		return PngRaster.failed("bit depth %d is not supported; use 8 or 16" % depth)
	if data[10] != 0 or data[11] != 0:
		return PngRaster.failed("unknown compression or filter method")
	if data[12] != 0:
		return PngRaster.failed("interlaced PNGs are not supported")
	var channels: int = CHANNELS_BY_COLOR_TYPE[color_type]
	# Bound each side first so the product below can't overflow.
	if w > MAX_IMAGE_BYTES or h > MAX_IMAGE_BYTES or w * h * channels * depth / 8 > MAX_IMAGE_BYTES:
		return PngRaster.failed("image %dx%d is larger than the supported maximum" % [w, h])
	# Header only: samples are allocated once the pixel data checks out.
	var raster: PngRaster = PngRaster.new()
	raster.width = w
	raster.height = h
	raster.channels = channels
	raster.bit_depth = depth
	return raster


## Inflates IDAT, reverses the per-row filters, and unpacks samples. The
## filter loops are split per type because this runs over every byte of a
## map at load time.
static func _decode_pixels(raster: PngRaster, idat: PackedByteArray) -> PngRaster:
	var bpp: int = raster.channels * raster.bit_depth / 8
	var stride: int = raster.width * bpp
	var expected: int = raster.height * (stride + 1)
	if idat.size() * MAX_DEFLATE_RATIO < expected:
		return PngRaster.failed(
			"image data is %d bytes, too small for a %dx%d image"
			% [idat.size(), raster.width, raster.height]
		)
	# zlib header check (RFC 1950): deflate method, and CMF/FLG divisible by
	# 31. Catches garbage before decompress(), which reports failures as
	# engine errors. A well-formed stream that inflates to the wrong size
	# still gets a clean error below, plus an engine error from decompress().
	if idat.size() < 2 or (idat[0] & 0x0F) != 8 or ((idat[0] << 8) | idat[1]) % 31 != 0:
		return PngRaster.failed("image data is not a zlib stream")
	var filtered: PackedByteArray = idat.decompress(expected, FileAccess.COMPRESSION_DEFLATE)
	if filtered.size() != expected:
		return PngRaster.failed(
			"image data inflated to %d bytes, expected %d" % [filtered.size(), expected]
		)

	var recon: PackedByteArray = PackedByteArray()
	recon.resize(raster.height * stride)
	for y: int in raster.height:
		var src: int = y * (stride + 1) + 1
		var dst: int = y * stride
		var prior: int = dst - stride
		var row_filter: int = filtered[src - 1]
		if row_filter == Filter.NONE:
			for i: int in stride:
				recon[dst + i] = filtered[src + i]
		elif row_filter == Filter.SUB:
			for i: int in stride:
				var a: int = recon[dst + i - bpp] if i >= bpp else 0
				recon[dst + i] = (filtered[src + i] + a) & 0xFF
		elif row_filter == Filter.UP:
			if y == 0:
				for i: int in stride:
					recon[dst + i] = filtered[src + i]
			else:
				for i: int in stride:
					recon[dst + i] = (filtered[src + i] + recon[prior + i]) & 0xFF
		elif row_filter == Filter.AVERAGE:
			for i: int in stride:
				var a: int = recon[dst + i - bpp] if i >= bpp else 0
				var b: int = recon[prior + i] if y > 0 else 0
				recon[dst + i] = (filtered[src + i] + ((a + b) >> 1)) & 0xFF
		elif row_filter == Filter.PAETH:
			for i: int in stride:
				var a: int = recon[dst + i - bpp] if i >= bpp else 0
				var b: int = recon[prior + i] if y > 0 else 0
				var c: int = recon[prior + i - bpp] if y > 0 and i >= bpp else 0
				var p: int = a + b - c
				var pa: int = absi(p - a)
				var pb: int = absi(p - b)
				var pc: int = absi(p - c)
				var predicted: int = c
				if pa <= pb and pa <= pc:
					predicted = a
				elif pb <= pc:
					predicted = b
				recon[dst + i] = (filtered[src + i] + predicted) & 0xFF
		else:
			return PngRaster.failed("row %d has invalid filter type %d" % [y, row_filter])

	var count: int = raster.width * raster.height * raster.channels
	var samples: PackedInt32Array = PackedInt32Array()
	samples.resize(count)
	if raster.bit_depth == 16:
		for i: int in count:
			samples[i] = (recon[2 * i] << 8) | recon[2 * i + 1]
	else:
		for i: int in count:
			samples[i] = recon[i]
	raster.samples = samples
	return raster


static func _samples_to_bytes(raster: PngRaster) -> PackedByteArray:
	var count: int = raster.samples.size()
	var raw: PackedByteArray = PackedByteArray()
	if raster.bit_depth == 16:
		raw.resize(count * 2)
		for i: int in count:
			var value: int = raster.samples[i]
			raw[2 * i] = (value >> 8) & 0xFF
			raw[2 * i + 1] = value & 0xFF
	else:
		raw.resize(count)
		for i: int in count:
			raw[i] = raster.samples[i] & 0xFF
	return raw


static func _predict(filter: int, a: int, b: int, c: int) -> int:
	match filter:
		Filter.SUB:
			return a
		Filter.UP:
			return b
		Filter.AVERAGE:
			return (a + b) >> 1
		Filter.PAETH:
			var p: int = a + b - c
			var pa: int = absi(p - a)
			var pb: int = absi(p - b)
			var pc: int = absi(p - c)
			if pa <= pb and pa <= pc:
				return a
			if pb <= pc:
				return b
			return c
	return 0


static func _is_critical(type: String) -> bool:
	var first: int = type.unicode_at(0) if not type.is_empty() else 0
	return first >= 65 and first <= 90


static func _read_u32(bytes: PackedByteArray, offset: int) -> int:
	return (
		(bytes[offset] << 24)
		| (bytes[offset + 1] << 16)
		| (bytes[offset + 2] << 8)
		| bytes[offset + 3]
	)


static func _append_u32(out: PackedByteArray, value: int) -> void:
	out.append_array(
		PackedByteArray([(value >> 24) & 0xFF, (value >> 16) & 0xFF, (value >> 8) & 0xFF, value & 0xFF])
	)


static func _append_chunk(out: PackedByteArray, type: String, data: PackedByteArray) -> void:
	var body: PackedByteArray = type.to_ascii_buffer()
	body.append_array(data)
	_append_u32(out, data.size())
	out.append_array(body)
	_append_u32(out, crc32(body, 0, body.size()))


## CRC-32 (ISO 3309, as PNG specifies) over bytes[from, to).
static func crc32(bytes: PackedByteArray, from: int, to: int) -> int:
	if _crc_table.is_empty():
		_crc_table = _build_crc_table()
	var crc: int = 0xFFFFFFFF
	for i: int in range(from, to):
		crc = _crc_table[(crc ^ bytes[i]) & 0xFF] ^ (crc >> 8)
	return crc ^ 0xFFFFFFFF


static func _build_crc_table() -> PackedInt64Array:
	var table: PackedInt64Array = PackedInt64Array()
	table.resize(256)
	for n: int in 256:
		var c: int = n
		for k: int in 8:
			c = (0xEDB88320 ^ (c >> 1)) if c & 1 else (c >> 1)
		table[n] = c
	return table
