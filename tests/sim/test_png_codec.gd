extends GutTest
## PngCodec checked three ways: against fixtures from an independent encoder
## (tests/fixtures/png/make_png_fixtures.py), against Godot's libpng for 8-bit
## images, and against its own encoder in round trips.

const FIXTURE_DIR: String = "res://tests/fixtures/png/"
## Byte offset of the IHDR data (after signature, length, and type).
const IHDR_DATA: int = 16
const IHDR_DEPTH: int = IHDR_DATA + 8
const IHDR_COLOR_TYPE: int = IHDR_DATA + 9
const IHDR_INTERLACE: int = IHDR_DATA + 12


func test_decodes_gray16_fixture() -> void:
	_assert_fixture("gray16_filters.png", 37, 23, 1, 16)


func test_decodes_rgb8_fixture() -> void:
	_assert_fixture("rgb8_filters.png", 19, 11, 3, 8)


func test_decodes_rgba8_fixture() -> void:
	_assert_fixture("rgba8_filters.png", 13, 7, 4, 8)


func test_decodes_rgb16_fixture() -> void:
	_assert_fixture("rgb16_filters.png", 11, 9, 3, 16)


func test_matches_godot_libpng_rgb8() -> void:
	var data: PackedByteArray = PackedByteArray()
	for y: int in 29:
		for x: int in 41:
			data.append_array(PackedByteArray([(x * 37 + y * 11) % 256, (x * y) % 256, (x ^ y) * 5 % 256]))
	_assert_matches_libpng(Image.create_from_data(41, 29, false, Image.FORMAT_RGB8, data))


func test_matches_godot_libpng_gray8() -> void:
	var data: PackedByteArray = PackedByteArray()
	for y: int in 17:
		for x: int in 33:
			data.append((x * x + y * 7) % 256)
	_assert_matches_libpng(Image.create_from_data(33, 17, false, Image.FORMAT_L8, data))


func test_round_trips_every_format_size_and_filter() -> void:
	var filters: Array[int] = [
		PngCodec.Filter.NONE,
		PngCodec.Filter.SUB,
		PngCodec.Filter.UP,
		PngCodec.Filter.AVERAGE,
		PngCodec.Filter.PAETH,
		PngCodec.FILTER_CYCLE,
	]
	var sizes: Array[Vector2i] = [Vector2i(1, 1), Vector2i(3, 5), Vector2i(64, 33)]
	var failures: Array[String] = []
	for channels: int in [1, 2, 3, 4]:
		for depth: int in [8, 16]:
			for size: Vector2i in sizes:
				var raster: PngRaster = _pattern_raster(size.x, size.y, channels, depth)
				for filter: int in filters:
					var decoded: PngRaster = PngCodec.decode(PngCodec.encode(raster, filter))
					if not decoded.ok() or decoded.samples != raster.samples:
						failures.append(
							"%dch %dbit %dx%d filter %d: %s"
							% [channels, depth, size.x, size.y, filter, decoded.error]
						)
	assert_eq(failures.size(), 0, "failed round trips: %s" % [failures])


func test_round_trip_preserves_header_fields() -> void:
	var decoded: PngRaster = PngCodec.decode(PngCodec.encode(_pattern_raster(5, 3, 2, 16)))
	assert_eq([decoded.width, decoded.height, decoded.channels, decoded.bit_depth], [5, 3, 2, 16])


func test_rejects_bad_signature() -> void:
	var bytes: PackedByteArray = _valid_png()
	bytes[1] = 0
	assert_string_contains(PngCodec.decode(bytes).error, "signature")


func test_rejects_too_short() -> void:
	assert_string_contains(PngCodec.decode(PackedByteArray([137, 80])).error, "too short")


func test_rejects_crc_mismatch() -> void:
	var bytes: PackedByteArray = _valid_png()
	# Flip a bit inside the IDAT data (first byte after the IDAT header).
	bytes[IHDR_DATA + 13 + 4 + 8] ^= 1
	assert_string_contains(PngCodec.decode(bytes).error, "CRC mismatch in IDAT")


func test_rejects_palette() -> void:
	var bytes: PackedByteArray = _patched_ihdr(IHDR_COLOR_TYPE, 3)
	assert_string_contains(PngCodec.decode(bytes).error, "palette")


func test_rejects_interlaced() -> void:
	var bytes: PackedByteArray = _patched_ihdr(IHDR_INTERLACE, 1)
	assert_string_contains(PngCodec.decode(bytes).error, "interlaced")


func test_rejects_sub_byte_depth() -> void:
	var bytes: PackedByteArray = _patched_ihdr(IHDR_DEPTH, 4)
	assert_string_contains(PngCodec.decode(bytes).error, "bit depth 4")


func test_rejects_missing_iend() -> void:
	var bytes: PackedByteArray = _valid_png()
	bytes.resize(bytes.size() - 12)
	assert_string_contains(PngCodec.decode(bytes).error, "missing IEND")


func test_rejects_truncated_chunk() -> void:
	var bytes: PackedByteArray = _valid_png()
	bytes.resize(bytes.size() - 20)
	assert_string_contains(PngCodec.decode(bytes).error, "truncated")


func test_rejects_invalid_filter_type() -> void:
	var filtered: PackedByteArray = PackedByteArray([0, 1, 2, 5, 3, 4])
	var bytes: PackedByteArray = _raw_png(2, 2, 8, 0, filtered.compress(FileAccess.COMPRESSION_DEFLATE))
	assert_string_contains(PngCodec.decode(bytes).error, "invalid filter type 5")


func test_rejects_image_data_of_wrong_size() -> void:
	var one_row: PackedByteArray = PackedByteArray([0, 1, 2])
	var bytes: PackedByteArray = _raw_png(2, 2, 8, 0, one_row.compress(FileAccess.COMPRESSION_DEFLATE))
	assert_string_contains(PngCodec.decode(bytes).error, "inflated to 3 bytes, expected 6")


func test_rejects_oversized_header_without_allocating() -> void:
	var tiny_idat: PackedByteArray = PackedByteArray([0x78, 0x9C, 3, 0])
	assert_string_contains(
		PngCodec.decode(_raw_png(16384, 16384, 16, 6, tiny_idat)).error, "larger than the supported"
	)
	assert_string_contains(
		PngCodec.decode(_raw_png(0xFFFFFFFF, 0xFFFFFFFF, 16, 6, tiny_idat)).error,
		"larger than the supported"
	)


func test_rejects_idat_too_small_for_header() -> void:
	# 4000x4000 16-bit gray is within the size cap, but 4 bytes can't inflate to 32 MB.
	var tiny_idat: PackedByteArray = PackedByteArray([0x78, 0x9C, 3, 0])
	assert_string_contains(PngCodec.decode(_raw_png(4000, 4000, 16, 0, tiny_idat)).error, "too small")


func test_rejects_non_zlib_image_data() -> void:
	var garbage: PackedByteArray = PackedByteArray([1, 2, 3, 4, 5, 6, 7, 8])
	assert_string_contains(PngCodec.decode(_raw_png(2, 2, 8, 0, garbage)).error, "not a zlib stream")


func test_crc32_known_value() -> void:
	# Standard CRC-32 check value for the ASCII string "123456789".
	var bytes: PackedByteArray = "123456789".to_ascii_buffer()
	assert_eq(PngCodec.crc32(bytes, 0, bytes.size()), 0xCBF43926)


func _assert_fixture(file_name: String, w: int, h: int, channels: int, depth: int) -> void:
	var raster: PngRaster = PngCodec.decode(FileAccess.get_file_as_bytes(FIXTURE_DIR + file_name))
	assert_true(raster.ok(), raster.error)
	assert_eq([raster.width, raster.height, raster.channels, raster.bit_depth], [w, h, channels, depth])
	var mismatches: int = 0
	for y: int in h:
		for x: int in w:
			for c: int in channels:
				if raster.get_sample(x, y, c) != _fixture_value(x, y, c, depth):
					mismatches += 1
	assert_eq(mismatches, 0, "%s samples differing from the formula" % file_name)


## Same formula as sample_value() in make_png_fixtures.py.
func _fixture_value(x: int, y: int, c: int, depth: int) -> int:
	return (x * 1789 + y * 4093 + c * 7919 + (x * y * 31) % 977) % (1 << depth)


func _assert_matches_libpng(image: Image) -> void:
	var raster: PngRaster = PngCodec.decode(image.save_png_to_buffer())
	assert_true(raster.ok(), raster.error)
	var expected: PackedByteArray = image.get_data()
	assert_eq(raster.samples.size(), expected.size())
	var mismatches: int = 0
	for i: int in mini(expected.size(), raster.samples.size()):
		if raster.samples[i] != expected[i]:
			mismatches += 1
	assert_eq(mismatches, 0, "samples differing from libpng")


func _pattern_raster(w: int, h: int, channels: int, depth: int) -> PngRaster:
	var raster: PngRaster = PngRaster.create(w, h, channels, depth)
	var gen: RandomNumberGenerator = RandomNumberGenerator.new()
	gen.seed = w * 1000 + h * 10 + channels
	var max_value: int = (1 << depth) - 1
	for i: int in raster.samples.size():
		raster.samples[i] = gen.randi_range(0, max_value)
	return raster


func _valid_png() -> PackedByteArray:
	return PngCodec.encode(_pattern_raster(6, 4, 1, 16))


## A valid PNG with one IHDR byte replaced and the IHDR CRC recomputed, so
## the decoder reaches the header validation rather than the CRC check.
func _patched_ihdr(offset: int, value: int) -> PackedByteArray:
	var bytes: PackedByteArray = _valid_png()
	bytes[offset] = value
	var crc: int = PngCodec.crc32(bytes, IHDR_DATA - 4, IHDR_DATA + 13)
	for i: int in 4:
		bytes[IHDR_DATA + 13 + i] = (crc >> (24 - 8 * i)) & 0xFF
	return bytes


## A PNG with the given header fields and raw IDAT bytes, correctly framed
## and checksummed, so decode() reaches the pixel-data checks.
func _raw_png(w: int, h: int, depth: int, color_type: int, idat: PackedByteArray) -> PackedByteArray:
	var ihdr: PackedByteArray = PackedByteArray()
	for value: int in [w, h]:
		ihdr.append_array(PackedByteArray([(value >> 24) & 0xFF, (value >> 16) & 0xFF, (value >> 8) & 0xFF, value & 0xFF]))
	ihdr.append_array(PackedByteArray([depth, color_type, 0, 0, 0]))
	var out: PackedByteArray = PackedByteArray([137, 80, 78, 71, 13, 10, 26, 10])
	_append_chunk(out, "IHDR", ihdr)
	_append_chunk(out, "IDAT", idat)
	_append_chunk(out, "IEND", PackedByteArray())
	return out


func _append_chunk(out: PackedByteArray, type: String, data: PackedByteArray) -> void:
	var size: int = data.size()
	out.append_array(PackedByteArray([(size >> 24) & 0xFF, (size >> 16) & 0xFF, (size >> 8) & 0xFF, size & 0xFF]))
	var body: PackedByteArray = type.to_ascii_buffer()
	body.append_array(data)
	out.append_array(body)
	var crc: int = PngCodec.crc32(body, 0, body.size())
	out.append_array(PackedByteArray([(crc >> 24) & 0xFF, (crc >> 16) & 0xFF, (crc >> 8) & 0xFF, crc & 0xFF]))
