extends GutTest
## UnitArt: the direction convention (shared with the Blender renderer:
## direction d faces d * 45 degrees counter-clockwise, seen from above, from
## the camera's forward), the sprite's pivot, validation, and the builder that
## turns a render sidecar into SpriteFrames.

const NORTH: Vector2 = Vector2(0.0, -1.0)


func test_directions_around_a_camera_looking_north() -> void:
	assert_eq(UnitArt.direction_index(Vector2(0, -1), NORTH), 0, "facing away: seen from behind")
	assert_eq(UnitArt.direction_index(Vector2(-1, -1), NORTH), 1)
	assert_eq(UnitArt.direction_index(Vector2(-1, 0), NORTH), 2, "facing west: screen-left")
	assert_eq(UnitArt.direction_index(Vector2(-1, 1), NORTH), 3)
	assert_eq(UnitArt.direction_index(Vector2(0, 1), NORTH), 4, "facing the camera")
	assert_eq(UnitArt.direction_index(Vector2(1, 1), NORTH), 5)
	assert_eq(UnitArt.direction_index(Vector2(1, 0), NORTH), 6, "facing east: screen-right")
	assert_eq(UnitArt.direction_index(Vector2(1, -1), NORTH), 7)


func test_directions_turn_with_the_camera() -> void:
	var east: Vector2 = Vector2(1.0, 0.0)
	assert_eq(UnitArt.direction_index(Vector2(1, 0), east), 0)
	assert_eq(UnitArt.direction_index(Vector2(0, -1), east), 2, "north is left of a camera looking east")
	assert_eq(UnitArt.direction_index(Vector2(-0.99, 0.14), NORTH), 2, "a few degrees off still rounds to 2")
	assert_eq(UnitArt.direction_index(Vector2(-0.17, 0.98), NORTH), 4, "just short of +180 is 4")
	assert_eq(UnitArt.direction_index(Vector2(0.17, 0.98), NORTH), 4, "just short of -180 wraps to 4")


func test_lengths_do_not_matter() -> void:
	var dir_one: int = FixedMath.DIR_ONE
	assert_eq(UnitArt.direction_index(Vector2(-dir_one, 0), NORTH * 75.0), 2)


func test_zero_vectors_still_give_a_direction() -> void:
	assert_between(UnitArt.direction_index(Vector2.ZERO, NORTH), 0, 7)
	assert_between(UnitArt.direction_index(Vector2(1, 0), Vector2.ZERO), 0, 7)


func test_direction_two_is_screen_left_through_a_real_camera() -> void:
	# A sized viewport of its own, so projection works headless.
	var viewport: SubViewport = SubViewport.new()
	viewport.size = Vector2i(640, 360)
	add_child_autofree(viewport)
	var camera: Camera3D = Camera3D.new()
	viewport.add_child(camera)
	camera.position = Vector3(0.0, 10.0, 10.0)
	camera.look_at(Vector3.ZERO)
	camera.current = true
	var forward: Vector3 = -camera.global_basis.z
	var facing: Vector2 = Vector2(-1.0, 0.0)
	assert_eq(UnitArt.direction_index(facing, Vector2(forward.x, forward.z)), 2)
	var here: Vector2 = camera.unproject_position(Vector3.ZERO)
	var ahead: Vector2 = camera.unproject_position(Vector3(facing.x, 0.0, facing.y))
	assert_lt(ahead.x, here.x, "what direction 2 faces is left of the unit on screen")


func test_the_pivot_puts_the_feet_on_the_origin() -> void:
	var art: UnitArt = UnitArt.new()
	art.cell_px = 128
	art.feet_px = 20
	art.pixels_per_meter = 52.0
	assert_eq(art.feet_offset(), Vector2(0.0, 44.0))
	assert_almost_eq(art.pixel_size(), 1.0 / 52.0, 0.000001)


func test_built_art_is_valid_and_laid_out_like_the_sheet() -> void:
	var art: UnitArt = TestArt.art()
	assert_eq(art.validate(), PackedStringArray())
	assert_eq(art.unit_id, &"shieldman")
	assert_eq(art.impact_frames.size(), 1)
	assert_eq(art.impact_frames.get(&"attack"), 3)
	assert_almost_eq(art.stride_m, TestArt.STRIDE_M, 0.0001)
	assert_eq(art.gib_color, Color(0.2, 0.4, 0.6))
	var walk: StringName = UnitArt.anim_name(&"walk", 2)
	assert_eq(walk, &"walk_2")
	assert_eq(art.frames.get_frame_count(walk), 12)
	assert_eq(art.frames.get_animation_speed(walk), 12.0)
	assert_true(art.frames.get_animation_loop(walk))
	assert_false(art.frames.get_animation_loop(&"attack_2"))
	var atlas: AtlasTexture = art.frames.get_frame_texture(walk, 1) as AtlasTexture
	var s: int = TestArt.STRIDE
	assert_eq(atlas.region, Rect2(1 * s + TestArt.GUTTER, 2 * s + TestArt.GUTTER, TestArt.CELL, TestArt.CELL))
	assert_false(art.frames.has_animation(&"default"))


func test_wrapped_sheets_find_each_frame() -> void:
	var side: Dictionary = TestArt.sidecar(&"x")
	var attack: Dictionary = side["animations"]["attack"]
	attack["frames"] = 30
	attack["columns"] = 24
	attack["rows_per_direction"] = 2
	var sheets: Dictionary = TestArt.sheets(side)
	var sheet: Texture2D = sheets[&"attack"]
	var s: int = TestArt.STRIDE
	var g: int = TestArt.GUTTER
	assert_eq(sheet.get_size(), Vector2(24 * s, UnitArt.DIRECTIONS * 2 * s), "blank sheet sized for the wrap")
	var art: UnitArt = UnitArtBuilder.build(side, sheets)
	var attack_3: StringName = UnitArt.anim_name(&"attack", 3)
	assert_eq(art.frames.get_frame_count(attack_3), 30)
	var wrapped: AtlasTexture = art.frames.get_frame_texture(attack_3, 25) as AtlasTexture
	assert_eq(wrapped.region, Rect2(1 * s + g, (3 * 2 + 1) * s + g, TestArt.CELL, TestArt.CELL))
	var first_row: AtlasTexture = art.frames.get_frame_texture(attack_3, 5) as AtlasTexture
	assert_eq(first_row.region, Rect2(5 * s + g, (3 * 2) * s + g, TestArt.CELL, TestArt.CELL))
	# The row boundary, in the last direction: the 24th cell is the end of row one, the next starts row two.
	var attack_7: StringName = UnitArt.anim_name(&"attack", 7)
	var last_of_row: AtlasTexture = art.frames.get_frame_texture(attack_7, 23) as AtlasTexture
	assert_eq(last_of_row.region, Rect2(23 * s + g, (7 * 2) * s + g, TestArt.CELL, TestArt.CELL))
	var first_of_next: AtlasTexture = art.frames.get_frame_texture(attack_7, 24) as AtlasTexture
	assert_eq(first_of_next.region, Rect2(0 * s + g, (7 * 2 + 1) * s + g, TestArt.CELL, TestArt.CELL))
	assert_eq(art.validate(), PackedStringArray())


func test_the_builder_leaves_out_auditioned_alternates() -> void:
	var art: UnitArt = TestArt.art(&"shieldman", {
		"idle": [1, 12, true, -1], "walk": [12, 12, true, -1],
		"attack": [6, 12, false, 3], "attack_alt": [6, 12, false, 3], "die": [4, 12, false, -1],
	})
	assert_false(art.frames.has_animation(&"attack_alt_0"))
	assert_false(art.has_anim(&"attack_alt"))


func test_validate_catches_missing_and_broken_animations() -> void:
	var no_die: UnitArt = TestArt.art(&"x", {"idle": [1, 12, true, -1], "walk": [12, 12, true, -1], "attack": [6, 12, false, 3]})
	assert_string_contains(" ".join(no_die.validate()), "missing die")
	var bursting: UnitArt = TestArt.art(&"x", {"idle": [1, 12, true, -1], "walk": [12, 12, true, -1], "attack": [6, 12, false, 3]}, true)
	assert_eq(bursting.validate(), PackedStringArray(), "a body that bursts needs no death")
	var holed: UnitArt = TestArt.art()
	holed.frames.remove_animation(&"walk_3")
	assert_string_contains(" ".join(holed.validate()), "walk has no frames for direction 3")
	var late: UnitArt = TestArt.art()
	late.impact_frames[&"attack"] = 6
	assert_string_contains(" ".join(late.validate()), "outside 0..5")
	var unaimed: UnitArt = TestArt.art(&"x", {"idle": [1, 12, true, -1], "walk": [12, 12, true, -1], "attack": [6, 12, false, -1], "die": [4, 12, false, -1]})
	assert_string_contains(" ".join(unaimed.validate()), "attack has no impact frame")


func test_a_unit_without_melee_needs_no_attack_clip() -> void:
	var art: UnitArt = TestArt.art(&"x", {
		"idle": [1, 12, true, -1], "walk": [12, 12, true, -1], "shoot": [8, 12, false, 5], "die": [4, 12, false, -1],
	})
	assert_eq(art.validate(), PackedStringArray())


func test_some_strike_clip_is_required() -> void:
	var art: UnitArt = TestArt.art(&"x", {"idle": [1, 12, true, -1], "walk": [12, 12, true, -1], "die": [4, 12, false, -1]})
	assert_string_contains(" ".join(art.validate()), "no strike clip")


func test_every_strike_and_act_clip_needs_an_impact_frame() -> void:
	for anim: String in ["shoot", "throw", "cast", "place"]:
		var anims: Dictionary = {"idle": [1, 12, true, -1], "walk": [12, 12, true, -1], "attack": [6, 12, false, 3], "die": [4, 12, false, -1]}
		anims[anim] = [6, 12, false, -1]
		assert_string_contains(" ".join(TestArt.art(&"x", anims).validate()), "%s has no impact frame" % anim, anim)


func test_a_negative_figure_height_is_invalid() -> void:
	var art: UnitArt = TestArt.art()
	art.figure_height_m = -1.0
	assert_string_contains(" ".join(art.validate()), "figure_height_m")
	art.figure_height_m = 0.0
	assert_eq(art.validate(), PackedStringArray(), "0 is unknown, not an error")


func test_the_builder_reads_figure_height_when_present() -> void:
	var side: Dictionary = TestArt.sidecar(&"x")
	assert_eq(UnitArtBuilder.build(side, TestArt.sheets(side)).figure_height_m, 0.0, "absent: unknown")
	side["figure_height_m"] = 1.41
	assert_almost_eq(UnitArtBuilder.build(side, TestArt.sheets(side)).figure_height_m, 1.41, 0.0001)


func test_a_sound_layout_has_no_errors() -> void:
	var side: Dictionary = TestArt.sidecar(&"x")
	assert_eq(UnitArtBuilder.layout_errors(side, TestArt.sheets(side)), PackedStringArray())
	var attack: Dictionary = side["animations"]["attack"]
	attack["frames"] = 30
	attack["columns"] = 24
	attack["rows_per_direction"] = 2
	assert_eq(UnitArtBuilder.layout_errors(side, TestArt.sheets(side)), PackedStringArray(), "a wrapped one too")


func test_layout_rejects_a_column_or_row_count_that_is_not_positive() -> void:
	var side: Dictionary = TestArt.sidecar(&"x")
	var sheets: Dictionary = TestArt.sheets(side) # Before the damage: a blank sheet can't be 0 wide.
	side["animations"]["walk"]["columns"] = 0
	side["animations"]["attack"]["rows_per_direction"] = -1
	var errors: String = " ".join(UnitArtBuilder.layout_errors(side, sheets))
	assert_string_contains(errors, "walk: columns must be positive")
	assert_string_contains(errors, "attack: rows_per_direction must be positive")


func test_layout_rejects_too_few_cells_for_the_frames() -> void:
	var side: Dictionary = TestArt.sidecar(&"x")
	var attack: Dictionary = side["animations"]["attack"]
	attack["frames"] = 30
	attack["columns"] = 12
	attack["rows_per_direction"] = 2
	var errors: PackedStringArray = UnitArtBuilder.layout_errors(side, TestArt.sheets(side))
	assert_eq(errors.size(), 1)
	assert_string_contains(" ".join(errors), "attack: 12 columns x 2 rows hold 24 frames, not 30")


func test_layout_rejects_a_sheet_too_small_for_its_frames() -> void:
	var side: Dictionary = TestArt.sidecar(&"x")
	var sheets: Dictionary = TestArt.sheets(side)
	var s: int = TestArt.STRIDE
	var short: Image = Image.create_empty(12 * s, (UnitArt.DIRECTIONS - 1) * s, false, Image.FORMAT_RGBA8)
	sheets[&"walk"] = ImageTexture.create_from_image(short)
	var errors: String = " ".join(UnitArtBuilder.layout_errors(side, sheets))
	assert_string_contains(errors, "walk: frames reach outside the")
	var narrow: Image = Image.create_empty(5 * s, UnitArt.DIRECTIONS * s, false, Image.FORMAT_RGBA8)
	sheets[&"walk"] = TestArt.sheets(side)[&"walk"]
	sheets[&"attack"] = ImageTexture.create_from_image(narrow)
	assert_string_contains(" ".join(UnitArtBuilder.layout_errors(side, sheets)), "attack: frames reach outside the")


func test_layout_rejects_a_sheet_larger_than_the_sidecar_implies() -> void:
	# A stale sheet from a longer clip: every frame it needs is inside it, but
	# the builder would cut the wrong cells from it, silently.
	var side: Dictionary = TestArt.sidecar(&"x")
	var s: int = TestArt.STRIDE
	var sheets: Dictionary = TestArt.sheets(side)
	sheets[&"walk"] = _blank_sheet(13 * s, UnitArt.DIRECTIONS * s)
	var wider: PackedStringArray = UnitArtBuilder.layout_errors(side, sheets)
	assert_eq(wider.size(), 1, "only the walk sheet is wrong")
	assert_string_contains(" ".join(wider), "walk: the sheet is %dx%d, but the sidecar's layout makes it %dx%d" % [13 * s, 8 * s, 12 * s, 8 * s])
	sheets[&"walk"] = TestArt.sheets(side)[&"walk"]
	sheets[&"attack"] = _blank_sheet(6 * s, (UnitArt.DIRECTIONS + 1) * s)
	var taller: PackedStringArray = UnitArtBuilder.layout_errors(side, sheets)
	assert_eq(taller.size(), 1, "only the attack sheet is wrong")
	assert_string_contains(" ".join(taller), "attack: the sheet is %dx%d, but the sidecar's layout makes it %dx%d" % [6 * s, 9 * s, 6 * s, 8 * s])


func test_layout_rejects_a_wrapped_sheet_of_the_wrong_size() -> void:
	var side: Dictionary = TestArt.sidecar(&"x")
	var attack: Dictionary = side["animations"]["attack"]
	attack["frames"] = 30
	attack["columns"] = 24
	attack["rows_per_direction"] = 2
	var sheets: Dictionary = TestArt.sheets(side)
	var s: int = TestArt.STRIDE
	# The sheet a one-row layout would have, and one with a row too many in each direction.
	sheets[&"attack"] = _blank_sheet(24 * s, UnitArt.DIRECTIONS * s)
	assert_string_contains(" ".join(UnitArtBuilder.layout_errors(side, sheets)), "attack: frames reach outside")
	sheets[&"attack"] = _blank_sheet(24 * s, UnitArt.DIRECTIONS * 3 * s)
	assert_string_contains(" ".join(UnitArtBuilder.layout_errors(side, sheets)), "attack: the sheet is")


func test_layout_rejects_a_missing_sheet() -> void:
	var side: Dictionary = TestArt.sidecar(&"x")
	var sheets: Dictionary = TestArt.sheets(side)
	sheets.erase(&"idle")
	assert_string_contains(" ".join(UnitArtBuilder.layout_errors(side, sheets)), "idle: no sheet")


func test_layout_ignores_animations_the_game_does_not_play() -> void:
	var side: Dictionary = TestArt.sidecar(&"x", {
		"idle": [1, 12, true, -1], "walk": [12, 12, true, -1],
		"attack": [6, 12, false, 3], "attack_alt": [6, 12, false, 3], "die": [4, 12, false, -1],
	})
	var sheets: Dictionary = TestArt.sheets(side)
	side["animations"]["attack_alt"]["columns"] = 0
	assert_eq(UnitArtBuilder.layout_errors(side, sheets), PackedStringArray())


func test_a_wrapped_sheet_must_reach_its_second_row() -> void:
	# 30 frames in 24 columns wrap to a second row, which sits in the last
	# direction's rows. Without counting that row, a sheet one stride short would pass.
	var side: Dictionary = TestArt.sidecar(&"x")
	var attack: Dictionary = side["animations"]["attack"]
	attack["frames"] = 30
	attack["columns"] = 24
	attack["rows_per_direction"] = 2
	var sheets: Dictionary = TestArt.sheets(side)
	var s: int = TestArt.STRIDE
	var wide: int = 24 * s
	var short: Image = Image.create_empty(wide, (UnitArt.DIRECTIONS * 2 - 1) * s, false, Image.FORMAT_RGBA8)
	sheets[&"attack"] = ImageTexture.create_from_image(short)
	assert_string_contains(" ".join(UnitArtBuilder.layout_errors(side, sheets)), "attack: frames reach outside")


func test_a_sheet_must_be_exactly_the_size_the_sidecar_implies() -> void:
	# The far corner of the last cell is a gutter short of the full stride grid.
	# Short of that corner a frame is cut off ("reach outside"); short of the
	# grid it is still the wrong sheet.
	var side: Dictionary = TestArt.sidecar(&"x")
	var attack: Dictionary = side["animations"]["attack"]
	attack["frames"] = 30
	attack["columns"] = 24
	attack["rows_per_direction"] = 2
	var sheets: Dictionary = TestArt.sheets(side)
	var s: int = TestArt.STRIDE
	var right: int = 23 * s + TestArt.GUTTER + TestArt.CELL
	var bottom: int = (7 * 2 + 1) * s + TestArt.GUTTER + TestArt.CELL
	sheets[&"attack"] = _blank_sheet(24 * s, 16 * s)
	assert_eq(UnitArtBuilder.layout_errors(side, sheets), PackedStringArray(), "columns * stride by 8 * rows * stride")
	sheets[&"attack"] = _blank_sheet(right, bottom)
	assert_string_contains(" ".join(UnitArtBuilder.layout_errors(side, sheets)), "attack: the sheet is", "the last cell fits, but the grid is not whole")
	sheets[&"attack"] = _blank_sheet(right, bottom - 1)
	assert_string_contains(" ".join(UnitArtBuilder.layout_errors(side, sheets)), "attack: frames reach outside", "one pixel too short")
	sheets[&"attack"] = _blank_sheet(right - 1, bottom)
	assert_string_contains(" ".join(UnitArtBuilder.layout_errors(side, sheets)), "attack: frames reach outside", "one pixel too narrow")


func test_a_sidecar_with_every_key_has_no_sidecar_errors() -> void:
	assert_eq(UnitArtBuilder.sidecar_errors(TestArt.sidecar(&"x")), PackedStringArray())


func test_sidecar_errors_name_a_missing_top_level_key() -> void:
	var side: Dictionary = TestArt.sidecar(&"x")
	side.erase("stride")
	side.erase("pixels_per_meter")
	var errors: String = " ".join(UnitArtBuilder.sidecar_errors(side))
	assert_string_contains(errors, "no \"stride\"")
	assert_string_contains(errors, "no \"pixels_per_meter\"")


func test_sidecar_errors_catch_animations_that_are_not_an_object() -> void:
	var side: Dictionary = TestArt.sidecar(&"x")
	side["animations"] = ["idle", "walk"]
	assert_string_contains(" ".join(UnitArtBuilder.sidecar_errors(side)), "\"animations\" is not an object")
	side.erase("animations")
	var errors: String = " ".join(UnitArtBuilder.sidecar_errors(side))
	assert_string_contains(errors, "no \"animations\"")
	assert_false("is not an object" in errors, "missing is reported once, as missing")


func test_sidecar_errors_name_a_missing_key_of_a_game_animation() -> void:
	var side: Dictionary = TestArt.sidecar(&"x")
	side["animations"]["walk"].erase("frames")
	side["animations"]["attack"].erase("sheet")
	side["animations"]["idle"].erase("fps")
	side["animations"]["die"].erase("loop")
	var errors: String = " ".join(UnitArtBuilder.sidecar_errors(side))
	assert_string_contains(errors, "walk: no \"frames\"")
	assert_string_contains(errors, "attack: no \"sheet\"")
	assert_string_contains(errors, "idle: no \"fps\"")
	assert_string_contains(errors, "die: no \"loop\"")
	side["animations"]["die"] = 7
	assert_string_contains(" ".join(UnitArtBuilder.sidecar_errors(side)), "die: not an object")


func test_sidecar_errors_ignore_animations_the_game_does_not_play() -> void:
	var side: Dictionary = TestArt.sidecar(&"x", {
		"idle": [1, 12, true, -1], "walk": [12, 12, true, -1],
		"attack": [6, 12, false, 3], "attack_alt": [6, 12, false, 3], "die": [4, 12, false, -1],
	})
	side["animations"]["attack_alt"].erase("frames")
	assert_eq(UnitArtBuilder.sidecar_errors(side), PackedStringArray())


# A blank texture of exactly this size.
func _blank_sheet(width: int, height: int) -> Texture2D:
	return ImageTexture.create_from_image(Image.create_empty(width, height, false, Image.FORMAT_RGBA8))


func test_the_real_shieldman_sidecar_has_a_sound_layout() -> void:
	var folder: String = "res://assets/units/shieldman/"
	var side: Variant = null
	if FileAccess.file_exists(folder + "shieldman.json"):
		side = JSON.parse_string(FileAccess.get_file_as_string(folder + "shieldman.json"))
	if not side is Dictionary:
		pending("%sshieldman.json is not rendered; run make art-render UNIT=shieldman" % folder)
		return
	assert_eq(UnitArtBuilder.sidecar_errors(side), PackedStringArray(), "the real sidecar has every key the builder reads")
	var sheets: Dictionary = {}
	for key: String in side["animations"]:
		var sheet: Texture2D = load(folder + String(side["animations"][key]["sheet"])) as Texture2D
		assert_not_null(sheet, "%s sheet loads" % key)
		sheets[StringName(key)] = sheet
	assert_eq(UnitArtBuilder.layout_errors(side, sheets), PackedStringArray())
