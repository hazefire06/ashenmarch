extends GutTest
## UnitArtCatalog: art per unit id. Broken art is left out (its unit keeps the
## placeholder) and a missing catalog is an empty one, so the game starts
## either way. Also pins the committed, generated Shieldman art.

const SHIELDMAN_PATH: String = "res://data/art/shieldman.tres"


func test_find_and_put_replace_and_keep_order() -> void:
	var catalog: UnitArtCatalog = UnitArtCatalog.new()
	catalog.put(TestArt.art(&"shieldman"))
	catalog.put(TestArt.art(&"reaver"))
	var newer: UnitArt = TestArt.art(&"shieldman")
	catalog.put(newer)
	assert_eq(catalog.arts.size(), 2)
	assert_same(catalog.find(&"shieldman"), newer)
	assert_null(catalog.find(&"husk"))
	assert_eq(catalog.arts[0].unit_id, &"reaver", "sorted by id, so the file diffs cleanly")


func test_invalid_art_is_left_out() -> void:
	var catalog: UnitArtCatalog = UnitArtCatalog.new()
	catalog.put(TestArt.art(&"shieldman"))
	var broken: UnitArt = TestArt.art(&"reaver")
	broken.frames.remove_animation(&"idle_5")
	catalog.put(broken)
	assert_eq(catalog.invalid_reasons().size(), 1)
	assert_string_contains(catalog.invalid_reasons()[0], "reaver")
	var usable: UnitArtCatalog = catalog.without_invalid()
	assert_not_null(usable.find(&"shieldman"))
	assert_null(usable.find(&"reaver"))


func test_a_missing_catalog_is_empty() -> void:
	var catalog: UnitArtCatalog = UnitArtCatalog.load_or_new("res://data/art/no_such_catalog.tres")
	assert_not_null(catalog)
	assert_eq(catalog.arts.size(), 0)


func test_a_file_that_is_not_a_catalog_is_empty() -> void:
	var catalog: UnitArtCatalog = UnitArtCatalog.load_or_new("res://data/units/shieldman.tres")
	assert_eq(catalog.arts.size(), 0)


func test_the_committed_shieldman_art_is_valid_and_laid_out_like_the_render() -> void:
	if not ResourceLoader.exists(SHIELDMAN_PATH):
		pending("%s is not built; run make art-build UNIT=shieldman" % SHIELDMAN_PATH)
		return
	var art: UnitArt = load(SHIELDMAN_PATH) as UnitArt
	assert_not_null(art)
	assert_eq(art.validate(), PackedStringArray())
	assert_eq(art.unit_id, &"shieldman")
	assert_eq(art.frames.get_animation_names().size(), 32, "idle, walk, attack and die in 8 directions; attack_alt is left out")
	assert_eq(art.frames.get_frame_count(&"die_0"), 27)
	# die wraps to 2 rows per direction of 24 columns, so frame 25 is column 1 of the second row.
	var wrapped: AtlasTexture = art.frames.get_frame_texture(&"die_3", 25) as AtlasTexture
	assert_eq(wrapped.region, Rect2(1 * 168 + 4, (3 * 2 + 1) * 168 + 4, 160, 160))
	assert_almost_eq(art.stride_m, 1.49, 0.01)
	assert_eq(art.cell_px, 160)
	assert_eq(art.feet_px, 40)


func test_the_committed_catalog_lists_the_shieldman_by_reference() -> void:
	if not ResourceLoader.exists(SHIELDMAN_PATH):
		pending("%s is not built; run make art-build UNIT=shieldman" % SHIELDMAN_PATH)
		return
	var catalog: UnitArtCatalog = UnitArtCatalog.load_or_new()
	var listed: UnitArt = catalog.find(&"shieldman")
	assert_not_null(listed, "data/art/catalog.tres lists the Shieldman")
	if listed != null:
		assert_eq(listed.resource_path, SHIELDMAN_PATH, "by reference to its own file, not an embedded copy")
	assert_eq(catalog.invalid_reasons(), PackedStringArray())
	assert_eq(catalog.without_invalid().arts.size(), catalog.arts.size())
