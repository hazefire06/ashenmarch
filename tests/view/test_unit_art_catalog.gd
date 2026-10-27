extends GutTest
## UnitArtCatalog: where each unit's art is, unit id to UnitArt path. Loading
## it loads no art (a game loads only its own types: UnitArtSet), and a missing
## catalog is an empty one, so the game starts either way. Also pins the
## committed, generated Shieldman art.

const SHIELDMAN_PATH: String = "res://data/art/shieldman.tres"
const TEST_DIR: String = "user://test_unit_art_catalog"
## The ten unit types of the v1 roster (the villager is not one: it is not drawn with art).
const V1_UNITS: Array[StringName] = [
	&"shieldman", &"reaver", &"longbow", &"sapper", &"warden",
	&"husk", &"ripper", &"blightbag", &"drifter", &"stormcaller",
]


func test_put_lists_a_path_per_unit_sorted() -> void:
	var catalog: UnitArtCatalog = UnitArtCatalog.new()
	catalog.put(&"shieldman", "res://a.tres")
	catalog.put(&"reaver", "res://b.tres")
	catalog.put(&"shieldman", "res://c.tres")
	assert_eq(Array(catalog.ids()), [&"reaver", &"shieldman"])
	assert_eq(catalog.path_of(&"shieldman"), "res://c.tres")
	assert_eq(catalog.paths.keys()[0], &"reaver", "sorted in the file too, so it diffs cleanly")
	assert_eq(catalog.path_of(&"husk"), "")
	assert_false(catalog.has(&"husk"))


func test_loading_the_catalog_loads_no_art() -> void:
	DirAccess.make_dir_recursive_absolute(TEST_DIR)
	var art_path: String = TEST_DIR + "/shieldman.tres"
	assert_eq(ResourceSaver.save(TestArt.art(&"shieldman"), art_path), OK)
	var catalog: UnitArtCatalog = UnitArtCatalog.new()
	catalog.put(&"shieldman", art_path)
	var catalog_path: String = TEST_DIR + "/catalog.tres"
	assert_eq(ResourceSaver.save(catalog, catalog_path), OK)
	var loaded: UnitArtCatalog = UnitArtCatalog.load_or_new(catalog_path)
	assert_true(loaded.has(&"shieldman"))
	assert_false(ResourceLoader.has_cached(art_path), "a path, not the art")
	assert_not_null(loaded.load_art(&"shieldman"))
	assert_null(loaded.load_art(&"husk"))


func test_a_missing_catalog_is_empty() -> void:
	var catalog: UnitArtCatalog = UnitArtCatalog.load_or_new("res://data/art/no_such_catalog.tres")
	assert_not_null(catalog)
	assert_eq(catalog.ids().size(), 0)


func test_a_file_that_is_not_a_catalog_is_empty() -> void:
	# A UnitArt is a Resource that isn't a catalog, and loading it pulls in no
	# sim scripts. (The unit data would compile them inside the test body, and
	# GUT counts the engine warnings from that as errors when this file runs alone.)
	if not ResourceLoader.exists(SHIELDMAN_PATH):
		pending("%s is not built; run make art-build UNIT=shieldman" % SHIELDMAN_PATH)
		return
	var catalog: UnitArtCatalog = UnitArtCatalog.load_or_new(SHIELDMAN_PATH)
	assert_not_null(catalog)
	assert_eq(catalog.ids().size(), 0)


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
	# A frame from die's wrapped second row: packed, it is still its whole cell, cut from inside its sheet.
	var wrapped: AtlasTexture = art.frames.get_frame_texture(&"die_3", 25) as AtlasTexture
	assert_eq(Vector2i(wrapped.get_width(), wrapped.get_height()), Vector2i(160, 160), "a packed frame is its whole cell")
	assert_true(Rect2(Vector2.ZERO, wrapped.atlas.get_size()).encloses(wrapped.region), "cut from inside its sheet")
	assert_almost_eq(art.stride_m, 1.49, 0.01)
	assert_eq(art.cell_px, 160)
	assert_eq(art.feet_px, 40)
	# Not written to the file while they equal UnitArt's defaults, so pin them here.
	assert_eq(art.pixels_per_meter, 52.0)
	assert_eq(art.impact_frames.get(&"attack"), 8)
	assert_true(art.frames.get_animation_loop(&"walk_0"))
	assert_false(art.frames.get_animation_loop(&"die_0"))


func test_the_committed_catalog_lists_the_shieldman_by_reference() -> void:
	if not ResourceLoader.exists(SHIELDMAN_PATH):
		pending("%s is not built; run make art-build UNIT=shieldman" % SHIELDMAN_PATH)
		return
	var catalog: UnitArtCatalog = UnitArtCatalog.load_or_new()
	assert_eq(catalog.path_of(&"shieldman"), SHIELDMAN_PATH, "by its path, not the art itself")
	assert_eq(catalog.load_art(&"shieldman").resource_path, SHIELDMAN_PATH)


func test_every_v1_unit_has_valid_committed_art() -> void:
	# A3's deliverable. The catalog tests above validate whatever it lists, so a rebuild that dropped
	# an entry would pass and that unit would quietly become a placeholder.
	var catalog: UnitArtCatalog = UnitArtCatalog.load_or_new()
	if catalog.ids().is_empty():
		pending("%s lists no art; run make art-build UNIT=<id>" % UnitArtCatalog.DEFAULT_PATH)
		return
	var units: UnitCatalog = TestTerrains.catalog()
	for id: StringName in V1_UNITS:
		assert_not_null(units.find(id), "%s is a unit type in data/units" % id)
		var art: UnitArt = catalog.load_art(id)
		assert_not_null(art, "%s has art in the catalog" % id)
		if art != null:
			assert_eq(art.validate(), PackedStringArray(), "%s's art is valid" % id)
	var shieldman: UnitArt = catalog.load_art(&"shieldman")
	if shieldman != null:
		assert_almost_eq(shieldman.figure_height_m, 1.406, 0.001, "the figure height the renderer measured")
