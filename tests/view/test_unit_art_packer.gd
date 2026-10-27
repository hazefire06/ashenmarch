extends GutTest
## UnitArtPacker: a grid render's frames trimmed to the part of the cell that
## holds the figure, padded, and packed, losslessly
## (docs/specs/2026-10-15-art-a4-loading-design.md §4).

const CELL: int = 32
const GUTTER: int = 4
const STRIDE: int = CELL + 2 * GUTTER
const PAD: int = UnitArtPacker.PAD
## Transparent, but coloured: the renderer leaves colour in pixels it never
## drew, so the packer must copy a region's pixels exactly, not just its alpha.
const BACKGROUND: Color = Color(0.5, 0.2, 0.1, 0.0)


# The box frame k (direction-major) draws, or an empty one: boxes move about
# the cell, some touch its left or right and bottom edges, and frame 3 draws nothing.
func _box(k: int) -> Rect2i:
	if k == 3:
		return Rect2i()
	var size: Vector2i = Vector2i(3 + k % 5, 4 + k % 7)
	var at: Vector2i = Vector2i((k * 7) % (CELL - size.x), (k * 5) % (CELL - size.y))
	match k % 4:
		1:
			at.x = 0
		2:
			at = Vector2i(CELL - size.x, CELL - size.y)
	return Rect2i(at, size)


# A grid of `frames` frames per direction, `columns` across and
# rows_per_direction rows each, every cell BACKGROUND with its frame's box in a
# colour of its own.
func _grid(frames: int, columns: int, rows_per_direction: int) -> Image:
	var image: Image = Image.create_empty(columns * STRIDE, UnitArt.DIRECTIONS * rows_per_direction * STRIDE, false, Image.FORMAT_RGBA8)
	image.fill(BACKGROUND)
	for dir: int in UnitArt.DIRECTIONS:
		for i: int in frames:
			var k: int = dir * frames + i
			var box: Rect2i = _box(k)
			if box.has_area():
				image.fill_rect(Rect2i(_origin(i, dir, columns, rows_per_direction) + box.position, box.size), Color8(k * 13 % 256, k * 29 % 256, k * 53 % 256, 255))
	return image


func _origin(i: int, dir: int, columns: int, rows_per_direction: int) -> Vector2i:
	@warning_ignore("integer_division") # Floor on purpose: the wrapped row.
	return Vector2i((i % columns) * STRIDE + GUTTER, (dir * rows_per_direction + i / columns) * STRIDE + GUTTER)


func _pack(frames: int = 30, columns: int = 24, rows_per_direction: int = 2) -> Dictionary:
	return UnitArtPacker.pack_animation(_grid(frames, columns, rows_per_direction), frames, columns, rows_per_direction, CELL, STRIDE, GUTTER)


func test_a_region_is_the_box_padded_out_to_whole_blocks_inside_the_cell() -> void:
	assert_eq(UnitArtPacker.region_in_cell(Rect2i(10, 13, 5, 6), CELL), Rect2i(0, 4, 24, 24))
	assert_eq(UnitArtPacker.region_in_cell(Rect2i(27, 28, 5, 4), CELL), Rect2i(16, 20, 16, 12), "cut short by the cell's edge")
	assert_eq(UnitArtPacker.region_in_cell(Rect2i(), CELL), Rect2i(0, 0, 4, 4), "an empty cell keeps one block")


func test_the_sheet_pads_only_where_the_cell_cut_a_region_short() -> void:
	var inside: Rect2i = Rect2i(10, 13, 5, 6)
	assert_eq(UnitArtPacker.slot_margins(inside, UnitArtPacker.region_in_cell(inside, CELL)), PackedInt32Array([0, 0, 0, 0]))
	var corner: Rect2i = Rect2i(27, 28, 5, 4)
	assert_eq(UnitArtPacker.slot_margins(corner, UnitArtPacker.region_in_cell(corner, CELL)), PackedInt32Array([0, 0, 8, 8]))
	var left_edge: Rect2i = Rect2i(0, 10, 4, 4)
	assert_eq(UnitArtPacker.slot_margins(left_edge, UnitArtPacker.region_in_cell(left_edge, CELL)), PackedInt32Array([8, 0, 0, 0]))


func test_shelves_take_the_tallest_first_and_wrap() -> void:
	var sizes: Array[Vector2i] = [Vector2i(8, 4), Vector2i(8, 12), Vector2i(16, 8), Vector2i(8, 12)]
	var positions: Array[Vector2i] = UnitArtPacker.shelf_pack(sizes, 24)
	assert_eq(positions, [Vector2i(16, 12), Vector2i(0, 0), Vector2i(0, 12), Vector2i(8, 0)] as Array[Vector2i])
	assert_eq(UnitArtPacker.sheet_size(sizes, positions), Vector2i(24, 20))


func test_every_packed_frame_is_its_grid_cell_byte_for_byte() -> void:
	var frames: int = 30
	var grid: Image = _grid(frames, 24, 2)
	var packed: Dictionary = _pack(frames)
	var sheet: Image = packed["image"]
	var rects: Array = packed["rects"]
	assert_eq(rects.size(), UnitArt.DIRECTIONS * frames)
	for dir: int in UnitArt.DIRECTIONS:
		for i: int in frames:
			var r: Array = rects[dir * frames + i]
			var region: Rect2i = Rect2i(r[4], r[5], r[2], r[3])
			var origin: Vector2i = _origin(i, dir, 24, 2)
			var kept: PackedByteArray = sheet.get_region(Rect2i(r[0], r[1], r[2], r[3])).get_data()
			var cut: PackedByteArray = grid.get_region(Rect2i(origin + region.position, region.size)).get_data()
			assert_eq(kept, cut, "d%d f%d: the region's pixels, colour in its transparency too" % [dir, i])
			var used: Rect2i = grid.get_region(Rect2i(origin, Vector2i(CELL, CELL))).get_used_rect()
			if used.has_area():
				assert_true(region.encloses(used), "d%d f%d: everything the figure draws is kept" % [dir, i])


func test_packed_frames_sit_on_whole_blocks_and_never_overlap() -> void:
	var rects: Array = _pack()["rects"]
	var placed: Array[Rect2i] = []
	for r: Array in rects:
		for v: int in [r[0], r[1], r[2], r[3], r[4], r[5]]:
			assert_eq(v % UnitArtPacker.ALIGN, 0, "on the 4 px block grid: %s" % [r])
		var here: Rect2i = Rect2i(r[0], r[1], r[2], r[3])
		for other: Rect2i in placed:
			assert_false(here.intersects(other), "%s overlaps %s" % [here, other])
		placed.append(here)


func test_figures_touching_the_cell_edge_keep_their_distance() -> void:
	var frames: int = 30
	var packed: Dictionary = _pack(frames)
	var rects: Array = packed["rects"]
	# Where each figure ended up in the packed sheet, grown by PAD: no two touch.
	var figures: Array[Rect2i] = []
	for k: int in rects.size():
		var box: Rect2i = _box(k)
		if not box.has_area():
			continue
		var r: Array = rects[k]
		figures.append(Rect2i(Vector2i(r[0], r[1]) + box.position - Vector2i(r[4], r[5]), box.size).grow(PAD))
	for a: int in figures.size():
		for b: int in range(a + 1, figures.size()):
			assert_false(figures[a].intersects(figures[b]), "figures %d and %d are under %d px apart" % [a, b, 2 * PAD])


func test_packing_twice_gives_the_same_bytes() -> void:
	var first: Dictionary = _pack()
	var second: Dictionary = _pack()
	assert_eq(first["rects"], second["rects"])
	assert_eq((first["image"] as Image).save_png_to_buffer(), (second["image"] as Image).save_png_to_buffer())


func test_a_sheet_that_would_be_too_tall_is_an_error() -> void:
	var out: Dictionary = UnitArtPacker.pack_animation(_grid(30, 24, 2), 30, 24, 2, CELL, STRIDE, GUTTER, 64)
	assert_true(out.has("error"))
	assert_string_contains(str(out["error"]), "over 64")


func test_pack_keeps_the_sidecar_and_drops_the_grid_keys() -> void:
	var side: Dictionary = TestArt.sidecar(&"x", {
		"idle": [1, 12, true, -1], "walk": [12, 12, true, -1],
		"attack": [6, 12, false, 3], "attack_alt": [6, 12, false, 3], "die": [4, 12, false, -1],
	})
	side["figure_height_m"] = 1.41
	side["animations"]["attack"]["columns"] = 4
	side["animations"]["attack"]["rows_per_direction"] = 2
	var out: Dictionary = UnitArtPacker.pack(side, TestArt.grids(side))
	assert_eq(out["errors"], PackedStringArray())
	var packed: Dictionary = out["sidecar"]
	assert_eq(packed["layout"], UnitArtPacker.LAYOUT)
	assert_eq(packed["pad"], UnitArtPacker.PAD)
	assert_false(packed.has("stride") or packed.has("gutter"))
	assert_eq(packed["figure_height_m"], 1.41, "every other key carries over")
	assert_false((packed["animations"] as Dictionary).has("attack_alt"), "only the clips the game plays")
	var attack: Dictionary = packed["animations"]["attack"]
	assert_false(attack.has("columns") or attack.has("rows_per_direction"))
	assert_eq((attack["rects"] as Array).size(), UnitArt.DIRECTIONS * 6)
	var image: Image = out["sheets"][&"attack"]
	assert_eq(attack["sheet_size"], [image.get_width(), image.get_height()])
	assert_eq(side["animations"]["attack"]["columns"], 4, "the grid sidecar is left as it was")
