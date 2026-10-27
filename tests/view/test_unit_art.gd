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
	assert_eq(Vector2i(atlas.get_width(), atlas.get_height()), Vector2i(TestArt.CELL, TestArt.CELL), "a packed frame is its whole cell again")
	var rect: Array = TestArt.pack(TestArt.sidecar(&"shieldman"))["sidecar"]["animations"]["walk"]["rects"][2 * 12 + 1]
	assert_eq(atlas.region, Rect2(rect[0], rect[1], rect[2], rect[3]))
	assert_eq(atlas.margin, Rect2(rect[4], rect[5], TestArt.CELL - int(rect[2]), TestArt.CELL - int(rect[3])))
	assert_false(art.frames.has_animation(&"default"))


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
	var packed: Dictionary = TestArt.pack(side)
	assert_eq(UnitArtBuilder.build(packed["sidecar"], packed["textures"]).figure_height_m, 0.0, "absent: unknown")
	side["figure_height_m"] = 1.41
	packed = TestArt.pack(side)
	assert_almost_eq(UnitArtBuilder.build(packed["sidecar"], packed["textures"]).figure_height_m, 1.41, 0.0001)


func test_a_sound_packed_layout_has_no_errors() -> void:
	var packed: Dictionary = TestArt.pack(TestArt.sidecar(&"x"))
	assert_eq(UnitArtBuilder.sidecar_errors(packed["sidecar"]), PackedStringArray())
	assert_eq(UnitArtBuilder.layout_errors(packed["sidecar"], packed["textures"]), PackedStringArray())


func test_a_grid_sidecar_is_refused_by_the_builder() -> void:
	var errors: String = " ".join(UnitArtBuilder.sidecar_errors(TestArt.sidecar(&"x")))
	assert_string_contains(errors, "no \"layout\"")
	assert_string_contains(errors, "walk: no \"rects\"")


func test_layout_rejects_a_stale_packed_sheet() -> void:
	var packed: Dictionary = TestArt.pack(TestArt.sidecar(&"x"))
	var stale: Image = Image.create_empty(4, 4, false, Image.FORMAT_RGBA8)
	packed["textures"][&"walk"] = ImageTexture.create_from_image(stale)
	assert_string_contains(" ".join(UnitArtBuilder.layout_errors(packed["sidecar"], packed["textures"])), "walk: the sheet is 4x4, but the sidecar packed it")


func test_layout_rejects_rects_that_do_not_fit() -> void:
	var packed: Dictionary = TestArt.pack(TestArt.sidecar(&"x"))
	var side: Dictionary = packed["sidecar"]
	(side["animations"]["walk"]["rects"] as Array).pop_back()
	side["animations"]["attack"]["rects"][0] = [0, 0, 100000, 4, 0, 0]
	side["animations"]["die"]["rects"][0] = [0, 0, 4, 4, TestArt.CELL, 0]
	side["animations"]["idle"]["rects"][0] = [1, 2, 3]
	var errors: String = " ".join(UnitArtBuilder.layout_errors(side, packed["textures"]))
	assert_string_contains(errors, "walk: 95 rects for 12 frames in 8 directions")
	assert_string_contains(errors, "attack: rect 0 (0, 0, 100000, 4) is not inside")
	assert_string_contains(errors, "die: rect 0 sits outside the 8 px cell")
	assert_string_contains(errors, "idle: rect 0 is not [x, y, w, h, cell_x, cell_y]")


func test_validate_catches_a_frame_that_is_not_a_whole_cell() -> void:
	var art: UnitArt = TestArt.art()
	var cut: AtlasTexture = art.frames.get_frame_texture(&"walk_2", 3) as AtlasTexture
	cut.margin = Rect2()
	assert_string_contains(" ".join(art.validate()), "walk frame 3 of direction 2 is not a whole 8 px cell")


func test_the_real_shieldman_sidecar_has_a_sound_layout() -> void:
	var folder: String = "res://assets/units/shieldman/"
	var side: Variant = null
	if FileAccess.file_exists(folder + "shieldman.json"):
		side = JSON.parse_string(FileAccess.get_file_as_string(folder + "shieldman.json"))
	if not side is Dictionary:
		pending("%sshieldman.json is not packed; run make art-build UNIT=shieldman" % folder)
		return
	var missing: PackedStringArray = UnitArtBuilder.sidecar_errors(side)
	assert_eq(missing, PackedStringArray(), "the real packed sidecar has every key the builder reads")
	if not missing.is_empty():
		return
	var sheets: Dictionary = {}
	for key: String in side["animations"]:
		var sheet: Texture2D = load(folder + String(side["animations"][key]["sheet"])) as Texture2D
		assert_not_null(sheet, "%s sheet loads" % key)
		sheets[StringName(key)] = sheet
	assert_eq(UnitArtBuilder.layout_errors(side, sheets), PackedStringArray())


func test_texture_bytes_count_blocks_and_mipmaps() -> void:
	assert_eq(UnitArt.texture_bytes(8, 8, Image.FORMAT_DXT5, false), 64, "four 16-byte blocks")
	assert_eq(UnitArt.texture_bytes(8, 8, Image.FORMAT_DXT5, true), 64 + 16 + 16 + 16, "8x8, then 4x4, 2x2 and 1x1 as one block each")
	assert_eq(UnitArt.texture_bytes(6, 2, Image.FORMAT_DXT1, false), 2 * 8, "a part block counts whole")
	assert_eq(UnitArt.texture_bytes(4, 4, Image.FORMAT_RGBA8, false), 64)
	assert_eq(UnitArt.texture_bytes(4, 2, Image.FORMAT_RGBA8, true), 32 + 8 + 4, "4x2, 2x1, 1x1")


func test_sheet_bytes_count_each_sheet_once() -> void:
	var art: UnitArt = TestArt.art()
	var sheets: Dictionary[Texture2D, bool] = {}
	for name: String in art.frames.get_animation_names():
		sheets[(art.frames.get_frame_texture(name, 0) as AtlasTexture).atlas] = true
	var expected: int = 0
	for sheet: Texture2D in sheets:
		expected += UnitArt.texture_bytes(sheet.get_width(), sheet.get_height(), Image.FORMAT_RGBA8, false)
	assert_eq(sheets.size(), 4, "idle, walk, attack and die")
	assert_eq(art.sheet_bytes(), expected)


func test_an_imported_sheet_counts_its_mipmaps() -> void:
	# CompressedTexture2D.has_mipmaps() says false in Godot 4.7 even for a
	# mipmapped sheet, so this pins the count against the sheet's own data.
	var path: String = "res://assets/units/shieldman/idle.png"
	if not ResourceLoader.exists(path):
		pending("%s is not built; run make art-build UNIT=shieldman" % path)
		return
	var sheet: CompressedTexture2D = load(path) as CompressedTexture2D
	assert_eq(UnitArt.texture_bytes_of(sheet), sheet.get_image().get_data_size())
