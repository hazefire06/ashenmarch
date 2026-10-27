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


func test_a_sound_layout_has_no_errors() -> void:
	var side: Dictionary = TestArt.sidecar(&"x")
	assert_eq(UnitArtPacker.layout_errors(side, TestArt.grids(side)), PackedStringArray())
	var attack: Dictionary = side["animations"]["attack"]
	attack["frames"] = 30
	attack["columns"] = 24
	attack["rows_per_direction"] = 2
	assert_eq(UnitArtPacker.layout_errors(side, TestArt.grids(side)), PackedStringArray(), "a wrapped one too")


func test_layout_rejects_a_column_or_row_count_that_is_not_positive() -> void:
	var side: Dictionary = TestArt.sidecar(&"x")
	var sheets: Dictionary = TestArt.grids(side) # Before the damage: a blank sheet can't be 0 wide.
	side["animations"]["walk"]["columns"] = 0
	side["animations"]["attack"]["rows_per_direction"] = -1
	var errors: String = " ".join(UnitArtPacker.layout_errors(side, sheets))
	assert_string_contains(errors, "walk: columns must be positive")
	assert_string_contains(errors, "attack: rows_per_direction must be positive")


func test_layout_rejects_too_few_cells_for_the_frames() -> void:
	var side: Dictionary = TestArt.sidecar(&"x")
	var attack: Dictionary = side["animations"]["attack"]
	attack["frames"] = 30
	attack["columns"] = 12
	attack["rows_per_direction"] = 2
	var errors: PackedStringArray = UnitArtPacker.layout_errors(side, TestArt.grids(side))
	assert_eq(errors.size(), 1)
	assert_string_contains(" ".join(errors), "attack: 12 columns x 2 rows hold 24 frames, not 30")


func test_layout_rejects_a_sheet_too_small_for_its_frames() -> void:
	var side: Dictionary = TestArt.sidecar(&"x")
	var sheets: Dictionary = TestArt.grids(side)
	var s: int = TestArt.STRIDE
	var short: Image = Image.create_empty(12 * s, (UnitArt.DIRECTIONS - 1) * s, false, Image.FORMAT_RGBA8)
	sheets[&"walk"] = short
	var errors: String = " ".join(UnitArtPacker.layout_errors(side, sheets))
	assert_string_contains(errors, "walk: frames reach outside the")
	var narrow: Image = Image.create_empty(5 * s, UnitArt.DIRECTIONS * s, false, Image.FORMAT_RGBA8)
	sheets[&"walk"] = TestArt.grids(side)[&"walk"]
	sheets[&"attack"] = narrow
	assert_string_contains(" ".join(UnitArtPacker.layout_errors(side, sheets)), "attack: frames reach outside the")


func test_layout_rejects_a_sheet_larger_than_the_sidecar_implies() -> void:
	# A stale sheet from a longer clip: every frame it needs is inside it, but
	# the builder would cut the wrong cells from it, silently.
	var side: Dictionary = TestArt.sidecar(&"x")
	var s: int = TestArt.STRIDE
	var sheets: Dictionary = TestArt.grids(side)
	sheets[&"walk"] = _blank_sheet(13 * s, UnitArt.DIRECTIONS * s)
	var wider: PackedStringArray = UnitArtPacker.layout_errors(side, sheets)
	assert_eq(wider.size(), 1, "only the walk sheet is wrong")
	assert_string_contains(" ".join(wider), "walk: the sheet is %dx%d, but the sidecar's layout makes it %dx%d" % [13 * s, 8 * s, 12 * s, 8 * s])
	sheets[&"walk"] = TestArt.grids(side)[&"walk"]
	sheets[&"attack"] = _blank_sheet(6 * s, (UnitArt.DIRECTIONS + 1) * s)
	var taller: PackedStringArray = UnitArtPacker.layout_errors(side, sheets)
	assert_eq(taller.size(), 1, "only the attack sheet is wrong")
	assert_string_contains(" ".join(taller), "attack: the sheet is %dx%d, but the sidecar's layout makes it %dx%d" % [6 * s, 9 * s, 6 * s, 8 * s])


func test_layout_rejects_a_wrapped_sheet_of_the_wrong_size() -> void:
	var side: Dictionary = TestArt.sidecar(&"x")
	var attack: Dictionary = side["animations"]["attack"]
	attack["frames"] = 30
	attack["columns"] = 24
	attack["rows_per_direction"] = 2
	var sheets: Dictionary = TestArt.grids(side)
	var s: int = TestArt.STRIDE
	# The sheet a one-row layout would have, and one with a row too many in each direction.
	sheets[&"attack"] = _blank_sheet(24 * s, UnitArt.DIRECTIONS * s)
	assert_string_contains(" ".join(UnitArtPacker.layout_errors(side, sheets)), "attack: frames reach outside")
	sheets[&"attack"] = _blank_sheet(24 * s, UnitArt.DIRECTIONS * 3 * s)
	assert_string_contains(" ".join(UnitArtPacker.layout_errors(side, sheets)), "attack: the sheet is")


func test_layout_rejects_a_missing_sheet() -> void:
	var side: Dictionary = TestArt.sidecar(&"x")
	var sheets: Dictionary = TestArt.grids(side)
	sheets.erase(&"idle")
	assert_string_contains(" ".join(UnitArtPacker.layout_errors(side, sheets)), "idle: no sheet")


func test_layout_ignores_animations_the_game_does_not_play() -> void:
	var side: Dictionary = TestArt.sidecar(&"x", {
		"idle": [1, 12, true, -1], "walk": [12, 12, true, -1],
		"attack": [6, 12, false, 3], "attack_alt": [6, 12, false, 3], "die": [4, 12, false, -1],
	})
	var sheets: Dictionary = TestArt.grids(side)
	side["animations"]["attack_alt"]["columns"] = 0
	assert_eq(UnitArtPacker.layout_errors(side, sheets), PackedStringArray())


func test_a_wrapped_sheet_must_reach_its_second_row() -> void:
	# 30 frames in 24 columns wrap to a second row, which sits in the last
	# direction's rows. Without counting that row, a sheet one stride short would pass.
	var side: Dictionary = TestArt.sidecar(&"x")
	var attack: Dictionary = side["animations"]["attack"]
	attack["frames"] = 30
	attack["columns"] = 24
	attack["rows_per_direction"] = 2
	var sheets: Dictionary = TestArt.grids(side)
	var s: int = TestArt.STRIDE
	var wide: int = 24 * s
	var short: Image = Image.create_empty(wide, (UnitArt.DIRECTIONS * 2 - 1) * s, false, Image.FORMAT_RGBA8)
	sheets[&"attack"] = short
	assert_string_contains(" ".join(UnitArtPacker.layout_errors(side, sheets)), "attack: frames reach outside")


func test_a_sheet_must_be_exactly_the_size_the_sidecar_implies() -> void:
	# The far corner of the last cell is a gutter short of the full stride grid.
	# Short of that corner a frame is cut off ("reach outside"); short of the
	# grid it is still the wrong sheet.
	var side: Dictionary = TestArt.sidecar(&"x")
	var attack: Dictionary = side["animations"]["attack"]
	attack["frames"] = 30
	attack["columns"] = 24
	attack["rows_per_direction"] = 2
	var sheets: Dictionary = TestArt.grids(side)
	var s: int = TestArt.STRIDE
	var right: int = 23 * s + TestArt.GUTTER + TestArt.CELL
	var bottom: int = (7 * 2 + 1) * s + TestArt.GUTTER + TestArt.CELL
	sheets[&"attack"] = _blank_sheet(24 * s, 16 * s)
	assert_eq(UnitArtPacker.layout_errors(side, sheets), PackedStringArray(), "columns * stride by 8 * rows * stride")
	sheets[&"attack"] = _blank_sheet(right, bottom)
	assert_string_contains(" ".join(UnitArtPacker.layout_errors(side, sheets)), "attack: the sheet is", "the last cell fits, but the grid is not whole")
	sheets[&"attack"] = _blank_sheet(right, bottom - 1)
	assert_string_contains(" ".join(UnitArtPacker.layout_errors(side, sheets)), "attack: frames reach outside", "one pixel too short")
	sheets[&"attack"] = _blank_sheet(right - 1, bottom)
	assert_string_contains(" ".join(UnitArtPacker.layout_errors(side, sheets)), "attack: frames reach outside", "one pixel too narrow")


func test_a_sidecar_with_every_key_has_no_sidecar_errors() -> void:
	assert_eq(UnitArtPacker.sidecar_errors(TestArt.sidecar(&"x")), PackedStringArray())


func test_sidecar_errors_name_a_missing_top_level_key() -> void:
	var side: Dictionary = TestArt.sidecar(&"x")
	side.erase("stride")
	side.erase("pixels_per_meter")
	var errors: String = " ".join(UnitArtPacker.sidecar_errors(side))
	assert_string_contains(errors, "no \"stride\"")
	assert_string_contains(errors, "no \"pixels_per_meter\"")


func test_sidecar_errors_catch_animations_that_are_not_an_object() -> void:
	var side: Dictionary = TestArt.sidecar(&"x")
	side["animations"] = ["idle", "walk"]
	assert_string_contains(" ".join(UnitArtPacker.sidecar_errors(side)), "\"animations\" is not an object")
	side.erase("animations")
	var errors: String = " ".join(UnitArtPacker.sidecar_errors(side))
	assert_string_contains(errors, "no \"animations\"")
	assert_false("is not an object" in errors, "missing is reported once, as missing")


func test_sidecar_errors_name_a_missing_key_of_a_game_animation() -> void:
	var side: Dictionary = TestArt.sidecar(&"x")
	side["animations"]["walk"].erase("frames")
	side["animations"]["attack"].erase("sheet")
	side["animations"]["idle"].erase("fps")
	side["animations"]["die"].erase("loop")
	var errors: String = " ".join(UnitArtPacker.sidecar_errors(side))
	assert_string_contains(errors, "walk: no \"frames\"")
	assert_string_contains(errors, "attack: no \"sheet\"")
	assert_string_contains(errors, "idle: no \"fps\"")
	assert_string_contains(errors, "die: no \"loop\"")
	side["animations"]["die"] = 7
	assert_string_contains(" ".join(UnitArtPacker.sidecar_errors(side)), "die: not an object")


func test_sidecar_errors_ignore_animations_the_game_does_not_play() -> void:
	var side: Dictionary = TestArt.sidecar(&"x", {
		"idle": [1, 12, true, -1], "walk": [12, 12, true, -1],
		"attack": [6, 12, false, 3], "attack_alt": [6, 12, false, 3], "die": [4, 12, false, -1],
	})
	side["animations"]["attack_alt"].erase("frames")
	assert_eq(UnitArtPacker.sidecar_errors(side), PackedStringArray())


# A blank grid Image of exactly this size.
func _blank_sheet(width: int, height: int) -> Image:
	return Image.create_empty(width, height, false, Image.FORMAT_RGBA8)


func test_planted_links_are_found() -> void:
	var root: String = "user://test_packer_links"
	DirAccess.make_dir_recursive_absolute(root + "/out")
	DirAccess.make_dir_recursive_absolute(root + "/elsewhere")
	var out: DirAccess = DirAccess.open(root + "/out")
	if not out.is_link("idle.png"):
		assert_eq(out.create_link(ProjectSettings.globalize_path(root + "/elsewhere/victim.png"), "idle.png"), OK)
	assert_eq(UnitArtPacker.planted_links(PackedStringArray([root + "/out"])), PackedStringArray([root + "/out/idle.png"]))
	var top: DirAccess = DirAccess.open(root)
	if not top.is_link("linked"):
		assert_eq(top.create_link(ProjectSettings.globalize_path(root + "/elsewhere"), "linked"), OK)
	assert_eq(UnitArtPacker.planted_links(PackedStringArray([root + "/linked/units"])), PackedStringArray([root + "/linked"]), "a link on the way")
	assert_eq(UnitArtPacker.planted_links(PackedStringArray([root + "/elsewhere", root + "/not_yet"])), PackedStringArray())


func test_the_real_shieldman_grid_has_a_sound_layout() -> void:
	var folder: String = "res://art-src/units/shieldman/sheets/"
	if not FileAccess.file_exists(folder + "shieldman.json"):
		pending("%sshieldman.json is not rendered; run make art-render UNIT=shieldman" % folder)
		return
	var side: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(folder + "shieldman.json"))
	assert_eq(UnitArtPacker.sidecar_errors(side), PackedStringArray())
	var grids: Dictionary = {}
	for key: String in side["animations"]:
		grids[StringName(key)] = Image.load_from_file(ProjectSettings.globalize_path(folder + String(side["animations"][key]["sheet"])))
	assert_eq(UnitArtPacker.layout_errors(side, grids), PackedStringArray())


# A committed PNG, read as pixels (not the imported texture).
func _png(path: String) -> Image:
	var image: Image = Image.load_from_file(ProjectSettings.globalize_path(path))
	if image != null and image.get_format() != Image.FORMAT_RGBA8:
		image.convert(Image.FORMAT_RGBA8)
	return image


func test_every_committed_frame_is_its_grid_cell_byte_for_byte() -> void:
	var checked: int = 0
	for unit: String in DirAccess.get_directories_at("res://art-src/units"):
		var grid_dir: String = "res://art-src/units/%s/sheets/" % unit
		var packed_dir: String = "res://assets/units/%s/" % unit
		if not FileAccess.file_exists(grid_dir + unit + ".json"):
			continue
		var grid_side: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(grid_dir + unit + ".json"))
		var packed_side: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(packed_dir + unit + ".json"))
		var cell: int = int(grid_side["cell"])
		var stride: int = int(grid_side["stride"])
		var gutter: int = int(grid_side["gutter"])
		for key: String in packed_side["animations"]:
			var g: Dictionary = grid_side["animations"][key]
			var p: Dictionary = packed_side["animations"][key]
			var grid: Image = _png(grid_dir + String(g["sheet"]))
			var packed: Image = _png(packed_dir + String(p["sheet"]))
			var count: int = int(g["frames"])
			var columns: int = int(g.get("columns", count))
			var rows: int = int(g.get("rows_per_direction", 1))
			for dir: int in UnitArt.DIRECTIONS:
				for i: int in count:
					var r: Array = p["rects"][dir * count + i]
					@warning_ignore("integer_division") # Floor on purpose: the wrapped row.
					var origin: Vector2i = Vector2i((i % columns) * stride + gutter, (dir * rows + i / columns) * stride + gutter)
					var region: Rect2i = Rect2i(int(r[4]), int(r[5]), int(r[2]), int(r[3]))
					var kept: PackedByteArray = packed.get_region(Rect2i(int(r[0]), int(r[1]), region.size.x, region.size.y)).get_data()
					if kept != grid.get_region(Rect2i(origin + region.position, region.size)).get_data():
						fail_test("%s %s d%d f%d: the packed frame differs from its grid cell" % [unit, key, dir, i])
						return
					var used: Rect2i = grid.get_region(Rect2i(origin, Vector2i(cell, cell))).get_used_rect()
					if used.has_area() and not region.encloses(used):
						fail_test("%s %s d%d f%d: the figure reaches outside its packed region" % [unit, key, dir, i])
						return
					checked += 1
	if checked == 0:
		pending("no grid render in art-src/units/*/sheets/")
		return
	pass_test("%d committed frames are their grid cells" % checked)
