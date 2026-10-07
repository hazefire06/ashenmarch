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


func test_the_real_shieldman_sidecar_has_a_sound_layout() -> void:
	var folder: String = "res://assets/units/shieldman/"
	var side: Variant = JSON.parse_string(FileAccess.get_file_as_string(folder + "shieldman.json"))
	if not side is Dictionary:
		pending("%sshieldman.json is not rendered; run make art-render UNIT=shieldman" % folder)
		return
	var sheets: Dictionary = {}
	for key: String in side["animations"]:
		var sheet: Texture2D = load(folder + String(side["animations"][key]["sheet"])) as Texture2D
		assert_not_null(sheet, "%s sheet loads" % key)
		sheets[StringName(key)] = sheet
	assert_eq(UnitArtBuilder.layout_errors(side, sheets), PackedStringArray())
